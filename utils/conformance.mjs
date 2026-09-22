#!/usr/bin/env bun
// Protocol conformance: run the Bun reference server and the Swift port side
// by side against the SAME live herdr, fire the same request at both, and diff
// what comes back. "Same as `maw herdr serve`" is a measurement here, not a
// claim.
//
//   bun utils/conformance.mjs                 # spawn both, run everything
//   bun utils/conformance.mjs --no-ws         # HTTP cases only
//   bun utils/conformance.mjs --claims        # also the slow ticket-lifetime probe
//   bun utils/conformance.mjs --send-probe    # also type into ONE agentless pane
//
// Exit code is non-zero if any case is a real mismatch. A case whose Swift
// side answers 501 where Bun implements the route is reported as
// "not-implemented", not as a failure — the port is explicit about its gaps.
// A case where both servers agree on something odd is a quirk: it passes, and
// the oddity is printed under QUIRKS.
//
// Ports: 3497 = Bun, 3498 = Swift. Both bind 127.0.0.1 only and are killed on
// every exit path, including Ctrl-C and a thrown error.

import { spawn, spawnSync } from 'node:child_process';
import { mkdirSync, writeFileSync, readFileSync, readdirSync, existsSync, statSync, openSync, closeSync, rmSync, chmodSync } from 'node:fs';
import { randomBytes } from 'node:crypto';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import net from 'node:net';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const BUN_PLUGIN = process.env.MAW_HERDR_BUN_DIR || resolve(ROOT, '..', 'maw-herdr-plugin');
const SWIFT_BINARY = resolve(ROOT, '.build/release/MawHerdrServe');
const TMP = resolve(ROOT, '.tmp');
const BUN_PORT = Number(process.env.CONFORMANCE_BUN_PORT || 3497);
const SWIFT_PORT = Number(process.env.CONFORMANCE_SWIFT_PORT || 3498);
const BUN = `http://127.0.0.1:${BUN_PORT}`;
const SWIFT = `http://127.0.0.1:${SWIFT_PORT}`;
const WITH_WS = !process.argv.includes('--no-ws');
const WITH_CLAIMS = process.argv.includes('--claims');
// The ONE case that cannot be measured without touching the fleet: the socket
// `send` command types into a pane and, without `force`, does not submit.
// Opt-in, agentless panes only, and the text is a shell comment so that even a
// stray Enter is a no-op. The pane's line is cleared afterwards.
const WITH_SEND_PROBE = process.argv.includes('--send-probe');

mkdirSync(TMP, { recursive: true });

// ---------------------------------------------------------------- results --

const rows = [];       // { name, bun, swift, verdict, diff }
const quirks = [];     // agreed-on oddities worth printing
const notes = [];      // free-form measurements (claims section)
let realMismatches = 0;
let notImplemented = 0;
let divergences = 0;

const PASS = 'same';
function record(name, bun, swift, verdict, diff) {
  if (verdict === 'MISMATCH') realMismatches++;
  if (verdict === 'not-implemented') notImplemented++;
  if (verdict === 'divergence') divergences++;
  rows.push({ name, bun, swift, verdict, diff: diff || '' });
}

// ------------------------------------------------------------- comparison --

// Fields that MUST differ between the two servers, or that move on their own
// between two calls a few milliseconds apart. Masked before the deep-equal.
const VOLATILE = new Set([
  'runtime', 'uptime', 'clockUtc', 'pid', 'node', 'ticket',
  'ms', 'millis', 'milliseconds', 'elapsed', 'duration', 'durationMs',
  'timestamp', 'ts', 'startedAt', 'updatedAt', 'expires', 'expiresAt', 'now',
  'mtime', 'mtimeMs', 'seconds', 'at',
]);

function mask(value) {
  if (Array.isArray(value)) return value.map(mask);
  if (value && typeof value === 'object') {
    const out = {};
    for (const key of Object.keys(value)) out[key] = VOLATILE.has(key) ? '<volatile>' : mask(value[key]);
    return out;
  }
  return value;
}

// Key ORDER matters for a dashboard that diffs raw text, so the comparison is
// on the re-serialised, masked JSON — which preserves insertion order.
function canonical(text) {
  try { return JSON.stringify(mask(JSON.parse(text))); } catch { return null; }
}

// Federation status with the live-probe outcomes blanked (see the 'federation'
// bodyCompare branch). Peer identity and ordering are kept; reachability,
// latency, the remote agent list, the error string and the reachable count are
// replaced with a placeholder because two sweeps a few ms apart are allowed to
// disagree on exactly those.
function maskFederation(text) {
  let value;
  try { value = JSON.parse(text); } catch { return null; }
  const scrub = (peer) => {
    if (peer && typeof peer === 'object' && !Array.isArray(peer)) {
      for (const key of ['reachable', 'latency', 'agents', 'fetch_error']) if (key in peer) peer[key] = '<probe>';
    }
    return peer;
  };
  if (value && typeof value === 'object') {
    if (Array.isArray(value.peers)) value.peers = value.peers.map(scrub);
    if ('reachablePeers' in value) value.reachablePeers = '<probe>';
  }
  return JSON.stringify(mask(value));
}

function firstDiff(a, b) {
  if (a === b) return '';
  const limit = Math.min(a.length, b.length);
  let i = 0;
  while (i < limit && a[i] === b[i]) i++;
  const window = (s) => s.slice(Math.max(0, i - 30), i + 60).replace(/\n/g, '\\n');
  return `@${i} bun=${JSON.stringify(window(a))} swift=${JSON.stringify(window(b))}`;
}

const HEADERS = [
  'cache-control', 'x-content-type-options', 'content-type', 'vary', 'allow',
  'access-control-allow-origin', 'access-control-allow-methods',
  'access-control-allow-headers', 'access-control-allow-credentials',
  'access-control-max-age', 'access-control-allow-private-network',
  'sec-websocket-protocol',
];

function headerSnapshot(response) {
  const out = {};
  for (const name of HEADERS) {
    const value = response.headers.get(name);
    if (value !== null) out[name] = value;
  }
  return out;
}

// Bun's own pooling fetch races a `Connection: close` server; retry the
// transport error (counted, and reported in the claims section).
let transportRetries = 0;
async function once(base, spec) {
  const url = base + spec.path;
  const init = { method: spec.method || 'GET', headers: { ...(spec.headers || {}) }, redirect: 'manual' };
  if (spec.body !== undefined) {
    init.body = spec.body;
    init.headers['content-type'] = init.headers['content-type'] || 'application/json';
  }
  for (let attempt = 0; ; attempt++) {
    try {
      const response = await fetch(url, init);
      const text = await response.text();
      return { status: response.status, headers: headerSnapshot(response), text };
    } catch (error) {
      if (attempt >= 3) throw error;
      transportRetries++;
      await new Promise((done) => setTimeout(done, 40));
    }
  }
}

// The two servers read the SAME live fleet, and a pane can change status
// between the two calls. Only a difference that survives three fresh pairs is
// a real mismatch.
async function compare(spec) {
  const name = spec.name;
  let last = null;
  for (let attempt = 0; attempt < 3; attempt++) {
    const b = await once(BUN, spec);
    const s = await once(SWIFT, spec);
    last = { b, s };

    const parts = [];
    if (b.status !== s.status) parts.push(`status ${b.status} vs ${s.status}`);
    for (const key of HEADERS) {
      const bv = b.headers[key], sv = s.headers[key];
      if (bv !== sv) parts.push(`${key}: ${JSON.stringify(bv ?? null)} vs ${JSON.stringify(sv ?? null)}`);
    }
    if (!spec.bodyCompare || spec.bodyCompare === 'json') {
      const bc = canonical(b.text), sc = canonical(s.text);
      if (bc === null || sc === null) {
        if (b.text !== s.text) parts.push(`body(text) ${firstDiff(b.text, s.text)}`);
      } else if (bc !== sc) {
        parts.push(`body ${firstDiff(bc, sc)}`);
      }
    } else if (spec.bodyCompare === 'keys') {
      const keys = (t) => { try { return Object.keys(JSON.parse(t)).join(','); } catch { return `<unparsed:${t.slice(0, 40)}>`; } };
      const bk = keys(b.text), sk = keys(s.text);
      if (bk !== sk) parts.push(`body keys ${bk} vs ${sk}`);
    } else if (spec.bodyCompare === 'federation') {
      // /api/federation/status and /fed.json are LIVE outbound probes: each
      // server sweeps the five peers itself, milliseconds apart, so a peer's
      // reachability, latency, agent list or error string can legitimately
      // differ between the two without either being wrong. Compare the stable
      // shape — peer set (url/node/oracle/auth_ok/node_unique), order and count
      // — and blank the probe-outcome fields, exactly the fields the two
      // sweeps are entitled to disagree on.
      const bc = maskFederation(b.text), sc = maskFederation(s.text);
      if (bc === null || sc === null) { if (b.text !== s.text) parts.push(`body(text) ${firstDiff(b.text, s.text)}`); }
      else if (bc !== sc) parts.push(`body ${firstDiff(bc, sc)}`);
    } else if (spec.bodyCompare === 'ignore') {
      // status + headers only
    }

    if (!parts.length) {
      record(name, `${b.status}`, `${s.status}`, PASS);
      if (spec.quirk) quirks.push(`${name}: ${spec.quirk} (both: ${b.status})`);
      return { b, s, ok: true };
    }

    // A 501 where Bun answers 2xx is a declared gap, not a divergence.
    if (s.status === 501 && b.status < 400) {
      record(name, `${b.status}`, '501', 'not-implemented', 'route stubbed in the Swift port');
      return { b, s, ok: false };
    }
    if (attempt === 2) {
      record(name, `${b.status}`, `${s.status}`, 'MISMATCH', parts.join(' | '));
      return { b, s, ok: false };
    }
    await new Promise((done) => setTimeout(done, 150));
  }
  return { ...last, ok: false };
}

// ------------------------------------------------------------- the servers --

const children = [];
function launch(label, command, args, cwd, logfile, env) {
  const fd = openSync(logfile, 'w');
  const child = spawn(command, args, { cwd, stdio: ['ignore', fd, fd], env: { ...process.env, ...(env || {}) } });
  closeSync(fd);
  child.on('exit', (code, signal) => { child.exited = { code, signal }; });
  children.push({ label, child, logfile });
  return child;
}

function killAll() {
  for (const { child } of children) {
    if (child.exitCode === null && !child.killed) { try { child.kill('SIGTERM'); } catch { } }
  }
}
process.on('exit', killAll);
for (const sig of ['SIGINT', 'SIGTERM']) process.on(sig, () => { killAll(); process.exit(130); });

async function portFree(port) {
  return await new Promise((done) => {
    const socket = net.connect({ host: '127.0.0.1', port });
    socket.on('connect', () => { socket.destroy(); done(false); });
    socket.on('error', () => done(true));
    setTimeout(() => { socket.destroy(); done(true); }, 500);
  });
}

async function waitHealthy(base, child, seconds = 25) {
  const deadline = Date.now() + seconds * 1000;
  while (Date.now() < deadline) {
    if (child && child.exitCode !== null) throw new Error(`${base} exited early (code ${child.exitCode})`);
    try {
      const response = await fetch(`${base}/api/health`);
      if (response.status === 200 || response.status === 401) { await response.text(); return; }
      await response.text();
    } catch { /* not up yet */ }
    await new Promise((done) => setTimeout(done, 200));
  }
  throw new Error(`${base} never became healthy`);
}

async function startPair(extra, suffix, bunExtra = [], swiftExtra = [], env) {
  const bunChild = launch('bun', process.execPath,
    ['index.mjs', 'serve', '--listen', `127.0.0.1:${BUN_PORT}`, ...extra, ...bunExtra],
    BUN_PLUGIN, `${TMP}/conformance-bun-${suffix}.err`, env);
  // Both servers run from BUN_PLUGIN. Bun must (its argv is a relative
  // `index.mjs`); the Swift binary is an absolute path and could run anywhere,
  // but `/api/worktrees` reports the worktrees of the server's OWN startup cwd
  // (`worktreeRoot = process.cwd()`, no flag), so a differing cwd is the one
  // thing that makes that route diverge for a reason that is not the port. The
  // only other cwd-derived config is the maw-config `.maw` ancestor layers,
  // and neither repo has one, so sharing the cwd changes nothing else.
  const swiftChild = launch('swift', SWIFT_BINARY,
    ['serve', '--listen', `127.0.0.1:${SWIFT_PORT}`, ...extra, ...swiftExtra],
    BUN_PLUGIN, `${TMP}/conformance-swift-${suffix}.err`, env);
  await waitHealthy(BUN, bunChild);
  await waitHealthy(SWIFT, swiftChild);
  return { bunChild, swiftChild };
}

async function stopPair() {
  killAll();
  const deadline = Date.now() + 8000;
  while (Date.now() < deadline) {
    if (await portFree(BUN_PORT) && await portFree(SWIFT_PORT)) return true;
    await new Promise((done) => setTimeout(done, 200));
  }
  return false;
}

// ---------------------------------------------------------------- websocket --

function socket(base, { origin, protocols } = {}) {
  const url = base.replace('http', 'ws');
  return protocols
    ? new WebSocket(url, { protocols, headers: origin ? { Origin: origin } : {} })
    : new WebSocket(url, { headers: origin ? { Origin: origin } : {} });
}

// Collect frames for `ms`, optionally sending `commands` once the socket opens.
function collect(url, { origin, protocols, ms, commands = [], after = [] }) {
  return new Promise((done) => {
    let ws;
    const messages = [];
    const result = { messages, opened: false, error: null, closed: null };
    try { ws = socket(url, { origin, protocols }); } catch (error) { result.error = String(error); done(result); return; }
    const timer = setTimeout(() => { try { ws.close(); } catch { } done(result); }, ms);
    ws.onopen = () => {
      result.opened = true;
      for (const command of commands) ws.send(JSON.stringify(command));
      for (const { delay, command } of after) setTimeout(() => { try { ws.send(JSON.stringify(command)); } catch { } }, delay);
    };
    ws.onmessage = (event) => {
      const text = typeof event.data === 'string' ? event.data : '<binary>';
      try { messages.push(JSON.parse(text)); } catch { messages.push({ type: '<unparsed>', raw: text.slice(0, 80) }); }
    };
    ws.onerror = (event) => { result.error = String(event?.message || 'socket error'); };
    ws.onclose = (event) => { result.closed = { code: event.code, reason: String(event.reason || '') }; clearTimeout(timer); done(result); };
  });
}

const types = (result) => result.messages.map((m) => m.type).join(',');

function captureLikeness(a, b) {
  const lines = (text) => String(text ?? '').split('\n').map((line) => line.replace(/\s+$/, ''));
  const al = lines(a), bl = lines(b);
  const head = Math.max(1, Math.floor(Math.min(al.length, bl.length) * 0.6));
  let same = 0;
  for (let i = 0; i < head; i++) if (al[i] === bl[i]) same++;
  return { head, same, ratio: head ? same / head : 0, lines: [al.length, bl.length] };
}

// ------------------------------------------------------------------- cases --

async function pickTargets() {
  const response = await fetch(`${BUN}/api/sessions`);
  const sessions = await response.json();
  const panes = sessions.flatMap((session) =>
    session.windows.map((window) => ({
      target: `${session.name}:${window.index}`, agent: window.agent || '', status: window.status,
    })));
  const withAgent = panes.filter((pane) => pane.agent);
  const agentless = panes.filter((pane) => !pane.agent);
  return {
    real: withAgent[0]?.target || panes[0]?.target,
    // Wake on a pane that already holds an agent is a no-op (`already-awake`),
    // which is the only wake this harness is allowed to perform on a live fleet.
    wake: withAgent.find((p) => p.status === 'idle' || p.status === 'done')?.target || withAgent[0]?.target,
    agentless: agentless[0]?.target || '',
    panes: panes.length,
  };
}

function httpCases(picked) {
  const big = 'x'.repeat(300 * 1024);
  const loopback = 'http://localhost:9999';
  return [
    { name: 'GET /api/identity', path: '/api/identity' },
    { name: 'GET /api/health', path: '/api/health' },
    { name: 'GET /health', path: '/health' },
    { name: 'GET /api/sessions', path: '/api/sessions' },
    { name: 'GET /api/agents', path: '/api/agents' },
    { name: 'GET /api/agent', path: '/api/agent' },
    { name: 'GET /api/teams', path: '/api/teams' },
    { name: 'GET /api/feed', path: '/api/feed' },
    { name: 'GET /api/costs', path: '/api/costs' },
    { name: 'GET /api/config', path: '/api/config' },
    { name: 'GET /api/worktrees', path: '/api/worktrees' },
    { name: 'GET /api/asks', path: '/api/asks' },
    { name: 'GET /api/ui-state', path: '/api/ui-state' },
    { name: 'GET /api/federation/status', path: '/api/federation/status', bodyCompare: 'federation' },
    { name: 'GET /fed.json', path: '/fed.json', bodyCompare: 'federation' },
    { name: 'GET /api/capture?target=<real>', path: `/api/capture?target=${encodeURIComponent(picked.real)}`, bodyCompare: 'capture' },
    { name: 'GET /api/capture (no target)', path: '/api/capture' },
    { name: 'GET /api/capture?target=nope', path: '/api/capture?target=nope' },
    { name: 'GET /api/capture?lines=abc', path: `/api/capture?target=${encodeURIComponent(picked.real)}&lines=abc`, bodyCompare: 'capture' },
    { name: 'GET /nope', path: '/nope' },
    { name: 'GET / (dashboard root)', path: '/', bodyCompare: 'json' },
    { name: 'origin: evil -> 403', path: '/api/sessions', headers: { Origin: 'https://evil.example.com' } },
    { name: 'origin: loopback -> 200 + ACAO', path: '/api/sessions', headers: { Origin: loopback } },
    { name: 'origin: god.buildwithoracle.com', path: '/api/sessions', headers: { Origin: 'https://god.buildwithoracle.com' } },
    { name: 'origin: file:// (opaque)', path: '/api/sessions', headers: { Origin: 'null' } },
    // The CORS allowlist runs the SAME predicate as the Host guard, on the raw
    // authority the origin regex captured. These four are the classes that
    // separate a faithful port from a looser one; the mapped-IPv4 form is the
    // one a dashboard page on a dual-stack socket actually sends, so refusing
    // it is a dead UI, and the other three widen an allowlist whose stated
    // contract is exact-match loopback.
    { name: 'origin: [::ffff:127.0.0.1] (dual-stack)', path: '/api/sessions', headers: { Origin: 'http://[::ffff:127.0.0.1]:5173' } },
    { name: 'origin: LOCALHOST (case)', path: '/api/sessions', headers: { Origin: 'http://LOCALHOST:5173' } },
    { name: 'origin: 127.0.0.01 (leading zero)', path: '/api/sessions', headers: { Origin: 'http://127.0.0.01:5173' } },
    { name: 'origin: 127.999.1.1 (not IPv4)', path: '/api/sessions', headers: { Origin: 'http://127.999.1.1:5173' } },
    { name: 'origin: [::1]', path: '/api/sessions', headers: { Origin: 'http://[::1]:5173' } },
    {
      name: 'OPTIONS preflight (valid)', method: 'OPTIONS', path: '/api/sessions',
      headers: { Origin: loopback, 'Access-Control-Request-Method': 'GET' },
    },
    {
      name: 'OPTIONS preflight (bad header)', method: 'OPTIONS', path: '/api/sessions',
      headers: { Origin: loopback, 'Access-Control-Request-Method': 'GET', 'Access-Control-Request-Headers': 'X-Evil' },
    },
    {
      name: 'OPTIONS preflight (allowed headers)', method: 'OPTIONS', path: '/api/sessions',
      headers: { Origin: loopback, 'Access-Control-Request-Method': 'GET', 'Access-Control-Request-Headers': 'authorization, content-type' },
    },
    {
      name: 'OPTIONS preflight (PNA)', method: 'OPTIONS', path: '/api/sessions',
      headers: { Origin: loopback, 'Access-Control-Request-Method': 'POST', 'Access-Control-Request-Private-Network': 'true' },
    },
    { name: 'OPTIONS preflight (no origin)', method: 'OPTIONS', path: '/api/sessions', headers: { 'Access-Control-Request-Method': 'GET' } },
    { name: 'OPTIONS preflight (bad method)', method: 'OPTIONS', path: '/api/sessions', headers: { Origin: loopback, 'Access-Control-Request-Method': 'DELETE' } },
    { name: 'POST /api/sessions (write gate vs method)', method: 'POST', path: '/api/sessions', body: '{}' },
    { name: 'DELETE /api/sessions -> 405 + Allow', method: 'DELETE', path: '/api/sessions' },
    { name: 'PUT /api/send -> 405 + Allow', method: 'PUT', path: '/api/send' },
    { name: 'POST /api/send {}', method: 'POST', path: '/api/send', body: '{}' },
    { name: 'POST /api/send {target:"",text:"x"}', method: 'POST', path: '/api/send', body: '{"target":"","text":"x"}' },
    { name: 'POST /api/send {target:<agentless>,text:"x"}', method: 'POST', path: '/api/send', body: JSON.stringify({ target: picked.agentless, text: 'x' }) },
    { name: 'POST /api/send {inbox:true}', method: 'POST', path: '/api/send', body: JSON.stringify({ target: picked.real, text: 'x', inbox: true }) },
    { name: 'POST /api/send {force:true}', method: 'POST', path: '/api/send', body: JSON.stringify({ target: picked.real, text: 'x', force: true }) },
    { name: 'POST /api/send (bad json)', method: 'POST', path: '/api/send', body: '{not json' },
    { name: 'POST /api/wake {}', method: 'POST', path: '/api/wake', body: '{}' },
    { name: 'POST /api/wake {target:<real>}', method: 'POST', path: '/api/wake', body: JSON.stringify({ target: picked.wake }) },
    { name: 'POST /api/wake {target:nope}', method: 'POST', path: '/api/wake', body: '{"target":"nope"}' },
    { name: 'POST /api/wake (unknown key)', method: 'POST', path: '/api/wake', body: '{"target":"x","nope":"y"}' },
    { name: 'POST /api/captures {}', method: 'POST', path: '/api/captures', body: '{}' },
    { name: 'POST /api/captures {<real>:15}', method: 'POST', path: '/api/captures', body: JSON.stringify({ targets: { [picked.real]: 15 } }), bodyCompare: 'capture' },
    { name: 'POST /api/worktrees/cleanup', method: 'POST', path: '/api/worktrees/cleanup', body: '{}' },
    { name: 'POST /api/auth/ws-ticket {"path":"/ws"}', method: 'POST', path: '/api/auth/ws-ticket', body: '{"path":"/ws"}', headers: { Origin: loopback }, bodyCompare: 'keys' },
    { name: 'POST /api/auth/ws-ticket (no origin)', method: 'POST', path: '/api/auth/ws-ticket', body: '{"path":"/ws"}' },
    { name: 'POST /api/auth/ws-ticket (bad path)', method: 'POST', path: '/api/auth/ws-ticket', body: '{"path":"/nope"}', headers: { Origin: loopback } },
    { name: 'POST /api/auth/ws-ticket (query string)', method: 'POST', path: '/api/auth/ws-ticket?x=1', body: '{"path":"/ws"}', headers: { Origin: loopback } },
    { name: 'Host: evil.example.com -> 403', path: '/api/health', headers: { Host: 'evil.example.com' } },
    { name: 'POST 300 KiB body', method: 'POST', path: '/api/send', body: JSON.stringify({ target: 'x', text: big }) },
    { name: 'GET /ws (no origin)', path: '/ws' },
    { name: 'GET /ws/pty (no origin)', path: '/ws/pty' },
    { name: 'GET /api/../api/health (traversal)', path: '/api/%2e%2e/api/health' },
  ];
}

// -------------------------------------------------------------------- main --

let exitCode = 0;
try {
  console.log(`# conformance: bun=${BUN} swift=${SWIFT}`);
  for (const port of [BUN_PORT, SWIFT_PORT]) {
    if (!(await portFree(port))) throw new Error(`port ${port} is already in use; free it first:\n  lsof -nP -iTCP:${port} -sTCP:LISTEN`);
  }

  // ---- phase 1: tokenless demo ------------------------------------------
  console.log('\n## phase 1 — insecure demo (no token)');
  await startPair(['--insecure-no-token', '--demo-minutes', '10'], 'insecure');

  const picked = await pickTargets();
  console.log(`   fleet: ${picked.panes} panes | real=${picked.real} | agentless=${picked.agentless || '<none>'} | wake=${picked.wake}`);

  for (const spec of httpCases(picked)) {
    if (spec.bodyCompare === 'capture') {
      // Pane text scrolls between the two reads; compare the leading 60%.
      const pair = await compare({ ...spec, bodyCompare: 'ignore' });
      if (pair.b.status === 200 && pair.s.status === 200) {
        let bt, st;
        try { bt = JSON.stringify(JSON.parse(pair.b.text)); st = JSON.stringify(JSON.parse(pair.s.text)); } catch { bt = pair.b.text; st = pair.s.text; }
        const likeness = captureLikeness(bt, st);
        const row = rows[rows.length - 1];
        if (likeness.ratio < 0.6 && bt !== st) {
          row.verdict = 'MISMATCH'; realMismatches++;
          row.diff = `capture text likeness ${(likeness.ratio * 100).toFixed(0)}% over ${likeness.head} leading lines`;
        } else {
          row.swift += ` (text ${(likeness.ratio * 100).toFixed(0)}% identical)`;
        }
      }
    } else {
      await compare(spec);
    }
  }

  // ---- phase 2: websocket, tokenless -------------------------------------
  if (WITH_WS) {
    console.log('\n## phase 2 — websocket (tokenless demo)');
    const origin = 'http://localhost:9999';
    const opts = { origin, ms: 3000 };
    const [wb, ws] = [await collect(`${BUN}/ws`, opts), await collect(`${SWIFT}/ws`, opts)];
    record('ws open (tokenless)', wb.opened ? 'open' : `closed ${wb.closed?.code}`, ws.opened ? 'open' : `closed ${ws.closed?.code}`,
      wb.opened === ws.opened ? PASS : 'MISMATCH', wb.opened === ws.opened ? '' : 'one side refused the tokenless upgrade');

    // The roster republishes whenever the live fleet changes, so one side can
    // legitimately carry an extra `sessions,recent` pair inside the same 3 s
    // window. Retry once on the raw sequence, then compare with repeated
    // publications collapsed — the ORDER of the distinct frames is the part
    // the protocol actually promises.
    let bSeq = types(wb), sSeq = types(ws);
    if (bSeq !== sSeq) {
      const rb = await collect(`${BUN}/ws`, opts), rs = await collect(`${SWIFT}/ws`, opts);
      bSeq = types(rb); sSeq = types(rs);
    }
    const collapse = (sequence) => {
      const seen = new Set();
      return sequence.split(',').filter((type) => {
        if (type !== 'sessions' && type !== 'recent') return true;
        if (seen.has(type)) return false;
        seen.add(type);
        return true;
      }).join(',');
    };
    const bFlat = collapse(bSeq), sFlat = collapse(sSeq);
    record('ws frame sequence (3s)', bSeq || '<none>', sSeq || '<none>',
      bSeq === sSeq || bFlat === sFlat ? PASS : 'MISMATCH',
      bSeq === sSeq ? '' : bFlat === sFlat
        ? 'one side republished the roster mid-window (the fleet changed); collapsed sequences are identical'
        : `bun=[${bSeq}] swift=[${sSeq}]`);

    const payload = (result, type) => result.messages.find((m) => m.type === type);
    const bSessions = payload(wb, 'sessions'), sSessions = payload(ws, 'sessions');
    if (bSessions && sSessions) {
      let bc = JSON.stringify(mask(bSessions)), sc = JSON.stringify(mask(sSessions));
      if (bc !== sc) {
        // one retry for fleet drift
        const rb = await collect(`${BUN}/ws`, opts), rs = await collect(`${SWIFT}/ws`, opts);
        bc = JSON.stringify(mask(payload(rb, 'sessions') || {}));
        sc = JSON.stringify(mask(payload(rs, 'sessions') || {}));
      }
      record('ws sessions payload', 'json', 'json', bc === sc ? PASS : 'MISMATCH', bc === sc ? '' : firstDiff(bc, sc));
    } else {
      record('ws sessions payload', bSessions ? 'present' : 'absent', sSessions ? 'present' : 'absent', 'MISMATCH', 'one side never sent a sessions frame');
    }

    for (const type of ['recent', 'teams', 'feed-history']) {
      const b = !!payload(wb, type), s = !!payload(ws, type);
      const bm = b ? JSON.stringify(mask(payload(wb, type))) : '', sm = s ? JSON.stringify(mask(payload(ws, type))) : '';
      record(`ws ${type} frame`, b ? 'present' : 'absent', s ? 'present' : 'absent',
        b === s && bm === sm ? PASS : (b === s ? 'MISMATCH' : 'MISMATCH'),
        b !== s ? 'frame present on one side only' : (bm === sm ? '' : firstDiff(bm, sm)));
    }

    // select the same target on both, compare the capture frame
    const selectOpts = { origin, ms: 4000, commands: [{ type: 'select', target: picked.real }] };
    const sb = await collect(`${BUN}/ws`, selectOpts), ss = await collect(`${SWIFT}/ws`, selectOpts);
    const bCap = sb.messages.find((m) => m.type === 'capture'), sCap = ss.messages.find((m) => m.type === 'capture');
    if (bCap && sCap) {
      const likeness = captureLikeness(bCap.content, sCap.content);
      record('ws select -> capture', `${likeness.lines[0]} lines`, `${likeness.lines[1]} lines`,
        likeness.ratio >= 0.6 ? PASS : 'MISMATCH', likeness.ratio >= 0.6 ? `${(likeness.ratio * 100).toFixed(0)}% of leading lines identical`
          : `only ${(likeness.ratio * 100).toFixed(0)}% of the leading ${likeness.head} lines match`);
    } else {
      record('ws select -> capture', bCap ? 'capture' : 'none', sCap ? 'capture' : 'none', 'MISMATCH', 'one side never answered select');
    }

    // wake over a read-only socket: both must refuse, with the same error
    const wakeOpts = { origin, ms: 3000, commands: [{ type: 'wake', target: picked.wake }] };
    const kb = await collect(`${BUN}/ws`, wakeOpts), ks = await collect(`${SWIFT}/ws`, wakeOpts);
    const err = (r) => (r.messages.find((m) => m.type === 'error')?.error) || (r.messages.find((m) => m.type === 'action-ok') ? 'action-ok' : '<none>');
    const be = err(kb), se = err(ks);
    record('ws wake (read-only socket)', be, se, be === se ? PASS : 'MISMATCH', be === se ? '' : 'different refusal');

    // an unknown command
    const badOpts = { origin, ms: 2500, commands: [{ type: 'no-such-command' }] };
    const ub = await collect(`${BUN}/ws`, badOpts), us = await collect(`${SWIFT}/ws`, badOpts);
    const ue = (r) => r.messages.find((m) => m.type === 'error')?.error || '<none>';
    record('ws unknown command', ue(ub), ue(us), ue(ub) === ue(us) ? PASS : 'MISMATCH');

    // select with an unknown target
    const goneOpts = { origin, ms: 2500, commands: [{ type: 'select', target: 'nope:1' }] };
    const gb = await collect(`${BUN}/ws`, goneOpts), gs = await collect(`${SWIFT}/ws`, goneOpts);
    record('ws select unknown target', ue(gb), ue(gs), ue(gb) === ue(gs) ? PASS : 'MISMATCH');

    // /ws with no Origin at all
    const nb = await collect(`${BUN}/ws`, { ms: 1500 }), ns = await collect(`${SWIFT}/ws`, { ms: 1500 });
    record('ws no-origin upgrade', nb.opened ? 'open' : 'refused', ns.opened ? 'open' : 'refused',
      nb.opened === ns.opened ? PASS : 'MISMATCH');

    // /ws/pty tokenless: the demo path only whitelists /ws
    const pb = await collect(`${BUN}/ws/pty`, { origin, ms: 1500 }), ps = await collect(`${SWIFT}/ws/pty`, { origin, ms: 1500 });
    record('ws/pty tokenless upgrade', pb.opened ? 'open' : 'refused', ps.opened ? 'open' : 'refused',
      pb.opened === ps.opened ? PASS : 'MISMATCH');

    // ---- RFC 6455 framing: close handshake + protocol errors --------------
    // The `ws` client above only ever sends well-formed masked text frames and
    // lets a timer close the socket, so none of this is reachable through it.
    // These raw probes drive the framing layer by hand. What the reference
    // (uWebSockets) actually does, measured 2026-09-22:
    //   * a CLIENT close frame is echoed verbatim for an accepted code
    //     (1000-1003, 1007-1011, 4000-4999) with a valid-UTF-8 reason, and
    //     answered with an EMPTY close frame otherwise;
    //   * a framing/protocol error (bad opcode, invalid control frame,
    //     non-UTF-8 text, bad fragmentation, an over-cap message) drops the TCP
    //     connection with NO close frame at all;
    //   * an UNMASKED client frame is the one exception — uWS mis-parses it and
    //     leaves the socket OPEN. The Swift port refuses it cleanly with a 1002
    //     close instead (matching it would mean deliberately mis-parsing and
    //     leaking the connection), so that one is a recorded divergence.
    const maskedFrame = (opcode, payload, { fin = true, rsv = 0, mask = true } = {}) => {
      const body = Buffer.from(payload);
      const head = [(fin ? 0x80 : 0) | (rsv << 4) | opcode];
      if (body.length < 126) head.push((mask ? 0x80 : 0) | body.length);
      else if (body.length <= 0xffff) head.push((mask ? 0x80 : 0) | 126, (body.length >> 8) & 0xff, body.length & 0xff);
      else { head.push((mask ? 0x80 : 0) | 127); const big = BigInt(body.length); for (let sh = 56n; sh >= 0n; sh -= 8n) head.push(Number((big >> sh) & 0xffn)); }
      const key = randomBytes(4);
      const masked = Buffer.from(body);
      if (mask) for (let i = 0; i < masked.length; i++) masked[i] ^= key[i % 4];
      return Buffer.concat([Buffer.from(head), mask ? key : Buffer.alloc(0), masked]);
    };
    const closeBody = (code, reason = '') =>
      code == null ? Buffer.alloc(0) : Buffer.concat([Buffer.from([(code >> 8) & 0xff, code & 0xff]), Buffer.from(reason)]);
    // Drive one raw scenario and return a signature: a close FRAME (code +
    // reason length), a bare EOF with no frame, or still open.
    const rawScenario = (port, frames) => new Promise((done) => {
      const conn = net.connect({ host: '127.0.0.1', port });
      let raw = Buffer.alloc(0), up = false, closeFrame = null, eof = false;
      const finish = () => { try { conn.destroy(); } catch { } done(closeFrame ? `close=${closeFrame.code}/len${closeFrame.len}` : (eof ? 'eof-noframe' : 'open')); };
      const timer = setTimeout(finish, 1400);
      conn.on('connect', () => {
        const key = randomBytes(16).toString('base64');
        conn.write(`GET /ws HTTP/1.1\r\nHost: 127.0.0.1:${port}\r\nOrigin: ${origin}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: ${key}\r\nSec-WebSocket-Version: 13\r\n\r\n`);
      });
      conn.on('data', (chunk) => {
        raw = Buffer.concat([raw, chunk]);
        if (!up) { const end = raw.indexOf('\r\n\r\n'); if (end < 0) return; up = true; raw = raw.subarray(end + 4); setTimeout(() => { for (const f of frames) conn.write(f); }, 500); }
        // Full frame walk: the server streams the dashboard roster first
        // (sessions/recent/teams/feed-history), and those are large TEXT frames
        // — some over 65535 bytes, so 127-length encoding — that a 16-bit-only
        // parser would misalign on and then read as a phantom close frame.
        let off = 0;
        while (off + 2 <= raw.length) {
          const op = raw[off] & 0x0f, masked = (raw[off + 1] & 0x80) !== 0;
          let len = raw[off + 1] & 0x7f, pos = off + 2;
          if (len === 126) { if (pos + 2 > raw.length) break; len = raw.readUInt16BE(pos); pos += 2; }
          else if (len === 127) { if (pos + 8 > raw.length) break; len = Number(raw.readBigUInt64BE(pos)); pos += 8; }
          if (masked) { if (pos + 4 > raw.length) break; pos += 4; }   // server frames are unmasked; guard anyway
          if (pos + len > raw.length) break;
          if (op === 0x8) { const pl = raw.subarray(pos, pos + len); closeFrame = { len: pl.length, code: pl.length >= 2 ? pl.readUInt16BE(0) : null }; }
          off = pos + len;
        }
        raw = raw.subarray(off);
      });
      conn.on('close', () => { eof = true; clearTimeout(timer); setTimeout(finish, 30); });
      conn.on('error', () => { });
    });
    const framingCases = [
      ['ws close 1000+reason (echoed verbatim)', [maskedFrame(0x8, closeBody(1000, 'bye'))], false],
      ['ws close 4999 (private range, echoed)', [maskedFrame(0x8, closeBody(4999))], false],
      ['ws close 3000 (rejected, empty frame)', [maskedFrame(0x8, closeBody(3000))], false],
      ['ws close 1005 (reserved, empty frame)', [maskedFrame(0x8, closeBody(1005))], false],
      ['ws close 1000+bad-utf8 (empty frame)', [maskedFrame(0x8, Buffer.concat([Buffer.from([0x03, 0xe8]), Buffer.from([0xff, 0xfe])]))], false],
      ['ws bad opcode (bare drop, no frame)', [maskedFrame(0x3, Buffer.from('x'))], false],
      ['ws invalid control frame (bare drop)', [maskedFrame(0x9, Buffer.alloc(126, 0x61))], false],
      ['ws non-utf8 text (bare drop)', [maskedFrame(0x1, Buffer.from([0x7b, 0xff, 0x7d]))], false],
      ['ws continuation-first (bare drop)', [maskedFrame(0x0, Buffer.from('x'), { fin: true })], false],
      ['ws oversize 65537 (bare drop)', [maskedFrame(0x1, Buffer.alloc(65537, 0x20))], false],
      // Two 40 KiB fragments: each is under the 64 KiB cap, so a drop here
      // proves the reassembler ACCUMULATES the whole message before enforcing
      // the limit (a per-frame check would let both through). Live-exercises
      // continuation-frame reassembly against a raw fragmenting client.
      ['ws oversize via 2 fragments (accumulated drop)', [maskedFrame(0x1, Buffer.alloc(40000, 0x20), { fin: false }), maskedFrame(0x0, Buffer.alloc(40000, 0x20))], false],
      ['ws unmasked frame (uWS leaves open)', [maskedFrame(0x1, Buffer.from('{}'), { mask: false })], true],
    ];
    for (const [name, frames, isDivergence] of framingCases) {
      const b = await rawScenario(BUN_PORT, frames), s = await rawScenario(SWIFT_PORT, frames);
      record(name, b, s, b === s ? PASS : (isDivergence ? 'divergence' : 'MISMATCH'),
        b === s ? '' : (isDivergence ? 'uWS mis-parses an unmasked frame and holds the socket open; the port refuses it with 1002 rather than leak a connection' : ''));
    }
  }

  // ---- claims ------------------------------------------------------------
  // Claim A: minted tickets expire at now+30s on Bun. Measured behaviourally,
  // since the mint response never carries the expiry.
  if (WITH_CLAIMS) {
    console.log('\n## claims — ticket lifetime (slow: ~80s)');
    const origin = 'http://localhost:9999';
    const mint = async (base) => {
      const response = await fetch(`${base}/api/auth/ws-ticket`, {
        method: 'POST', headers: { Origin: origin, 'content-type': 'application/json' }, body: '{"path":"/ws"}',
      });
      const body = await response.json();
      return body.ticket;                       // never printed
    };
    const spend = async (base, ticket) => {
      const result = await collect(`${base}/ws`, { origin, protocols: ['maw.ws.v1', ticket], ms: 1200 });
      return result.opened;
    };
    for (const [label, wait] of [['20s', 20_000], ['40s', 40_000]]) {
      const bt = await mint(BUN), st = await mint(SWIFT);
      await new Promise((done) => setTimeout(done, wait));
      const bOpen = await spend(BUN, bt), sOpen = await spend(SWIFT, st);
      record(`ticket spendable after ${label}`, bOpen ? 'accepted' : 'refused', sOpen ? 'accepted' : 'refused',
        bOpen === sOpen ? PASS : 'MISMATCH');
      notes.push(`ticket after ${label}: bun=${bOpen ? 'accepted' : 'refused'} swift=${sOpen ? 'accepted' : 'refused'}`);
    }
  }

  // Claim B: `Connection: close` and Bun's pooling fetch. 150 rapid requests
  // at each server, plus a control that is a KNOWN Connection: close server.
  console.log('\n## claims — Connection: close under rapid fetch');
  const burst = async (base) => {
    let failed = 0;
    for (let i = 0; i < 150; i++) {
      try { const response = await fetch(`${base}/api/health`); await response.text(); }
      catch { failed++; }
    }
    return failed;
  };
  const bFail = await burst(BUN), sFail = await burst(SWIFT);
  // Sequential requests never exercise fetch's connection pool the way a
  // parallel fan-out does, so run both shapes before believing either number.
  const parallel = async (base) => {
    let failed = 0;
    for (let round = 0; round < 10; round++) {
      const results = await Promise.allSettled(Array.from({ length: 15 }, async () => {
        const response = await fetch(`${base}/api/health`); await response.text();
      }));
      failed += results.filter((r) => r.status === 'rejected').length;
    }
    return failed;
  };
  const bPar = await parallel(BUN), sPar = await parallel(SWIFT);
  notes.push(`rapid fetch x150 sequential: bun=${bFail} failures, swift=${sFail} failures`);
  notes.push(`rapid fetch 10x15 parallel: bun=${bPar} failures, swift=${sPar} failures (transport retries elsewhere: ${transportRetries})`);
  record('150 rapid fetches (sequential)', `${bFail} failures`, `${sFail} failures`, sFail === 0 ? PASS : 'quirk',
    sFail === 0 ? '' : `Bun fetch races Connection: close (${sFail}/150)`);
  record('150 rapid fetches (parallel)', `${bPar} failures`, `${sPar} failures`, sPar === 0 ? PASS : 'quirk',
    sPar === 0 ? '' : `Bun fetch races Connection: close (${sPar}/150)`);

  if (!(await stopPair())) console.error('WARNING: a port was still bound after SIGTERM');

  // ---- phase 3: token mode ----------------------------------------------
  console.log('\n## phase 3 — token mode (ticketed sockets)');
  const tokenFile = `${TMP}/conformance-token`;
  writeFileSync(tokenFile, randomBytes(24).toString('hex') + '\n', { mode: 0o600 });
  chmodSync(tokenFile, 0o600);
  const token = (await Bun.file(tokenFile).text()).trim();
  children.length = 0;
  // Each side writes `/api/asks` and `/api/ui-state` into its OWN scratch
  // directory: the default data dir is the live dashboard's, and a conformance
  // run must never overwrite what the human's dashboard is holding there.
  const bunState = `${TMP}/conformance-state-bun`, swiftState = `${TMP}/conformance-state-swift`;
  rmSync(bunState, { recursive: true, force: true });
  rmSync(swiftState, { recursive: true, force: true });
  await startPair(['--token-file', tokenFile], 'token', ['--data-dir', bunState], ['--data-dir', swiftState]);

  const auth = { Authorization: `Bearer ${token}` };
  const picked2 = await (async () => {
    const response = await fetch(`${BUN}/api/sessions`, { headers: auth });
    const sessions = await response.json();
    const panes = sessions.flatMap((s) => s.windows.map((w) => ({ target: `${s.name}:${w.index}`, agent: w.agent || '', status: w.status, name: w.name })));
    const withAgent = panes.filter((p) => p.agent);
    const free = panes.find((p) => !p.agent);
    return {
      real: withAgent[0]?.target || panes[0]?.target,
      wake: withAgent.find((p) => p.status === 'idle' || p.status === 'done')?.target || withAgent[0]?.target,
      agentless: free?.target || '',
      // With no label, a window's name IS its herdr pane id — which is what
      // `herdr pane read` and the cleanup `send-keys` need.
      agentlessPaneId: free?.name || '',
    };
  })();

  await compare({ name: 'token: GET /api/health (no auth)', path: '/api/health' });
  await compare({ name: 'token: GET /api/sessions (no auth)', path: '/api/sessions' });
  await compare({ name: 'token: GET /api/sessions (bearer)', path: '/api/sessions', headers: auth });
  await compare({ name: 'token: GET /api/sessions (bad bearer)', path: '/api/sessions', headers: { Authorization: 'Bearer nope' } });
  await compare({ name: 'token: GET /api/captures (71 panes)', path: '/api/captures', headers: auth });
  await compare({ name: 'token: GET /api/teams (bearer)', path: '/api/teams', headers: auth });
  await compare({ name: 'token: POST /api/send {} (bearer)', method: 'POST', path: '/api/send', headers: auth, body: '{}' });
  // Every authenticated write below is chosen to be a no-op on a live fleet:
  // an empty target, a pane with no agent (refused before any keystroke), an
  // option the server answers 501 to, and a wake on a pane that already holds
  // an agent. Nothing here can type into an agent's pane.
  await compare({ name: 'token: POST /api/send empty target', method: 'POST', path: '/api/send', headers: auth, body: '{"target":"","text":"x"}' });
  await compare({ name: 'token: POST /api/send -> agentless pane', method: 'POST', path: '/api/send', headers: auth, body: JSON.stringify({ target: picked2.agentless, text: 'x' }) });
  await compare({ name: 'token: POST /api/send {force:true}', method: 'POST', path: '/api/send', headers: auth, body: JSON.stringify({ target: picked2.real, text: 'x', force: true }) });
  await compare({ name: 'token: POST /api/send {inbox:true}', method: 'POST', path: '/api/send', headers: { ...auth, 'X-Maw-From': 'conformance' }, body: JSON.stringify({ target: picked2.real, text: 'parity probe', inbox: true }) });
  await compare({ name: 'token: POST /api/wake {}', method: 'POST', path: '/api/wake', headers: auth, body: '{}' });
  await compare({ name: 'token: POST /api/wake {target:nope}', method: 'POST', path: '/api/wake', headers: auth, body: '{"target":"nope"}' });
  await compare({ name: 'token: POST /api/wake (unknown key)', method: 'POST', path: '/api/wake', headers: auth, body: '{"target":"x","nope":"y"}' });
  await compare({ name: 'token: POST /api/wake (already-awake pane)', method: 'POST', path: '/api/wake', headers: auth, body: JSON.stringify({ target: picked2.wake }) });

  // Worktrees. GET lists the worktrees of each server's startup cwd, which
  // startPair now shares, so the bodies match byte-for-byte. cleanup is the one
  // route that DELETES; both probes below are rejected by the handler BEFORE it
  // removes anything — an empty object has no `path` key (400
  // worktree_cleanup_rejected), and a non-JSON content-type is a readJSON 415
  // that the reference's single catch collapses into the same 400 (not a 415).
  await compare({ name: 'token: GET /api/worktrees (bearer)', path: '/api/worktrees', headers: auth });
  await compare({ name: 'token: POST /api/worktrees/cleanup {} (no path)', method: 'POST', path: '/api/worktrees/cleanup', headers: auth, body: '{}' });
  await compare({ name: 'token: POST /api/worktrees/cleanup (bad content-type -> 400)', method: 'POST', path: '/api/worktrees/cleanup', headers: { ...auth, 'content-type': 'text/plain' }, body: '{"path":"/tmp"}' });
  await compare({ name: 'token: POST /api/worktrees/cleanup (traversal path)', method: 'POST', path: '/api/worktrees/cleanup', headers: auth, body: '{"path":"/tmp/../etc"}' });

  // State round-trip, each server against its own empty scratch directory.
  await compare({ name: 'state: GET /api/asks (missing file)', path: '/api/asks', headers: auth });
  await compare({ name: 'state: GET /api/ui-state (missing file)', path: '/api/ui-state', headers: auth });
  await compare({ name: 'state: POST /api/asks', method: 'POST', path: '/api/asks', headers: auth, body: '[{"id":"x","q":"probe"}]' });
  await compare({ name: 'state: GET /api/asks (after write)', path: '/api/asks', headers: auth });
  await compare({ name: 'state: POST /api/asks (wrong shape)', method: 'POST', path: '/api/asks', headers: auth, body: '{"a":1}' });
  await compare({ name: 'state: POST /api/asks (bad json)', method: 'POST', path: '/api/asks', headers: auth, body: '{nope' });
  await compare({ name: 'state: POST /api/ui-state', method: 'POST', path: '/api/ui-state', headers: auth, body: '{"tab":"panes"}' });
  await compare({ name: 'state: GET /api/ui-state (after write)', path: '/api/ui-state', headers: auth });
  await compare({ name: 'state: POST /api/ui-state (array)', method: 'POST', path: '/api/ui-state', headers: auth, body: '[]' });
  {
    const mode = (path) => { try { return (statSync(path).mode & 0o777).toString(8); } catch { return '<missing>'; } };
    const bMode = mode(`${bunState}/asks.json`), sMode = mode(`${swiftState}/asks.json`);
    record('state: asks.json mode', bMode, sMode, bMode === sMode ? PASS : 'MISMATCH');
    const bBytes = (() => { try { return readFileSync(`${bunState}/asks.json`, 'utf8'); } catch { return '<missing>'; } })();
    const sBytes = (() => { try { return readFileSync(`${swiftState}/asks.json`, 'utf8'); } catch { return '<missing>'; } })();
    record('state: asks.json bytes', `${bBytes.length}B`, `${sBytes.length}B`, bBytes === sBytes ? PASS : 'MISMATCH', bBytes === sBytes ? '' : firstDiff(bBytes, sBytes));
  }

  const origin = 'http://localhost:9999';
  const mintTicket = async (base, headers) => {
    const response = await fetch(`${base}/api/auth/ws-ticket`, {
      method: 'POST', headers: { Origin: origin, 'content-type': 'application/json', ...headers }, body: '{"path":"/ws"}',
    });
    const text = await response.text();
    let body = null; try { body = JSON.parse(text); } catch { }
    return { status: response.status, keys: body ? Object.keys(body).join(',') : `<unparsed>`, ticket: body?.ticket };
  };
  const bMint = await mintTicket(BUN, auth), sMint = await mintTicket(SWIFT, auth);
  record('token: mint ticket (authed)', `${bMint.status} {${bMint.keys}}`, `${sMint.status} {${sMint.keys}}`,
    bMint.status === sMint.status && bMint.keys === sMint.keys ? PASS : 'MISMATCH');
  const shape = (t) => (typeof t === 'string' && /^mwt1_[0-9a-f]{64}$/.test(t) ? 'mwt1_<64hex>' : `<bad:${typeof t}>`);
  record('token: ticket shape', shape(bMint.ticket), shape(sMint.ticket), shape(bMint.ticket) === shape(sMint.ticket) ? PASS : 'MISMATCH');

  if (WITH_WS) {
    const upgrade = async (base, ticket, commands = []) =>
      await collect(`${base}/ws`, { origin, protocols: ['maw.ws.v1', ticket], ms: 3000, commands });
    // wake on a pane that already holds an agent: a no-op on a live fleet.
    const pickedToken = picked2.wake;

    const bAuthed = await upgrade(BUN, bMint.ticket), sAuthed = await upgrade(SWIFT, sMint.ticket);
    record('token: authed upgrade', bAuthed.opened ? 'open' : `refused ${bAuthed.closed?.code}`, sAuthed.opened ? 'open' : `refused ${sAuthed.closed?.code}`,
      bAuthed.opened === sAuthed.opened ? PASS : 'MISMATCH');
    const bt = types(bAuthed), st = types(sAuthed);
    record('token: authed frame sequence', bt || '<none>', st || '<none>', bt === st ? PASS : 'MISMATCH', bt === st ? '' : `bun=[${bt}] swift=[${st}]`);

    // single use: spending the same ticket twice must fail on both
    const bReuse = await upgrade(BUN, bMint.ticket), sReuse = await upgrade(SWIFT, sMint.ticket);
    record('token: ticket is single-use', bReuse.opened ? 'accepted' : 'refused', sReuse.opened ? 'accepted' : 'refused',
      bReuse.opened === sReuse.opened ? PASS : 'MISMATCH');

    // tokenless upgrade must be refused outright in token mode
    const bNo = await collect(`${BUN}/ws`, { origin, ms: 1500 }), sNo = await collect(`${SWIFT}/ws`, { origin, ms: 1500 });
    record('token: tokenless upgrade refused', bNo.opened ? 'open' : 'refused', sNo.opened ? 'open' : 'refused',
      bNo.opened === sNo.opened ? PASS : 'MISMATCH');

    // an authenticated socket is NOT read-only: wake must not be refused for auth
    const bWakeTicket = await mintTicket(BUN, auth), sWakeTicket = await mintTicket(SWIFT, auth);
    const bWake = await upgrade(BUN, bWakeTicket.ticket, [{ type: 'wake', target: pickedToken }]);
    const sWake = await upgrade(SWIFT, sWakeTicket.ticket, [{ type: 'wake', target: pickedToken }]);
    const outcome = (r) => {
      const e = r.messages.find((m) => m.type === 'error');
      if (e) return `error:${e.error}`;
      const ok = r.messages.find((m) => m.type === 'action-ok');
      return ok ? `action-ok:${ok.action}` : '<none>';
    };
    const bo = outcome(bWake), so = outcome(sWake);
    record('token: authed wake (already-awake pane)', bo, so, bo === so ? PASS : 'MISMATCH');
    if (bo.includes('operator_token_required')) quirks.push('authed socket was still read-only for wake on BOTH servers');

    // The non-force `send`: types the text, leaves it unsubmitted. Measured on
    // a LIVE pane, so it runs only with --send-probe, only against a pane with
    // no agent in it, and only with a `#`-prefixed marker that is inert in any
    // shell. The pane's input line is cleared again immediately afterwards.
    if (WITH_SEND_PROBE && /^w[A-Za-z0-9]+:p[0-9]+$/.test(picked2.agentlessPaneId || '')) {
      const paneId = picked2.agentlessPaneId;
      const sendOnce = async (base, marker) => {
        const ticket = await mintTicket(base, auth);
        const result = await collect(`${base}/ws`, {
          origin, protocols: ['maw.ws.v1', ticket.ticket], ms: 3500,
          after: [{ delay: 400, command: { type: 'send', target: picked2.agentless, text: marker } }],
        });
        return result.messages.find((m) => m.type === 'sent' || m.type === 'error') || { type: '<none>' };
      };
      const before = spawnSync('herdr', ['pane', 'read', paneId, '--source', 'visible', '--lines', '3', '--format', 'text'], { encoding: 'utf8' }).stdout || '';
      const bSent = await sendOnce(BUN, '#maw-conformance-bun');
      const typedBun = spawnSync('herdr', ['pane', 'read', paneId, '--source', 'visible', '--lines', '3', '--format', 'text'], { encoding: 'utf8' }).stdout || '';
      spawnSync('herdr', ['pane', 'send-keys', paneId, 'ctrl+u']);
      const sSent = await sendOnce(SWIFT, '#maw-conformance-swift');
      const typedSwift = spawnSync('herdr', ['pane', 'read', paneId, '--source', 'visible', '--lines', '3', '--format', 'text'], { encoding: 'utf8' }).stdout || '';
      spawnSync('herdr', ['pane', 'send-keys', paneId, 'ctrl+u']);

      const shape = (frame) => JSON.stringify({ ...frame, text: '<marker>' });
      record('send-probe: sent frame', shape(bSent), shape(sSent), shape(bSent) === shape(sSent) ? PASS : 'MISMATCH');
      // "typed but not submitted" = the marker is on the CURRENT input line,
      // and the line count did not grow.
      const landed = (text, marker) => text.includes(marker) && text.trimEnd().split('\n').length === before.trimEnd().split('\n').length;
      const bLanded = landed(typedBun, '#maw-conformance-bun'), sLanded = landed(typedSwift, '#maw-conformance-swift');
      record('send-probe: typed, not submitted', bLanded ? 'typed' : 'not typed / submitted', sLanded ? 'typed' : 'not typed / submitted',
        bLanded === sLanded ? PASS : 'MISMATCH');
    }

    // /ws/pty — routed, ticketed, and driven only with commands that can never
    // reach a live pane: a malformed attach, and an attach to a target that
    // does not exist. Attaching for real would resize somebody's pane.
    const ptyTicket = async (base) => {
      const response = await fetch(`${base}/api/auth/ws-ticket`, {
        method: 'POST', headers: { Origin: origin, 'content-type': 'application/json', ...auth }, body: '{"path":"/ws/pty"}',
      });
      return (await response.json()).ticket;
    };
    const ptyRun = async (base, commands) => {
      const ticket = await ptyTicket(base);
      return await collect(`${base}/ws/pty`, { origin, protocols: ['maw.ws.v1', ticket], ms: 4000, commands });
    };
    const closeOf = (r) => (r.opened ? `${r.closed?.code ?? 'open'}/${r.closed?.reason ?? ''}` : `refused ${r.closed?.code ?? ''}`);

    const bPtyOpen = await ptyRun(BUN, []), sPtyOpen = await ptyRun(SWIFT, []);
    record('token: /ws/pty upgrade', bPtyOpen.opened ? 'open' : 'refused', sPtyOpen.opened ? 'open' : 'refused',
      bPtyOpen.opened === sPtyOpen.opened ? PASS : 'MISMATCH');

    const bBad = await ptyRun(BUN, [{ type: 'attach' }]), sBad = await ptyRun(SWIFT, [{ type: 'attach' }]);
    record('token: /ws/pty malformed attach', closeOf(bBad), closeOf(sBad), closeOf(bBad) === closeOf(sBad) ? PASS : 'MISMATCH');

    const ghost = [{ type: 'attach', target: 'nope:1', cols: 80, rows: 24 }];
    const bGhost = await ptyRun(BUN, ghost), sGhost = await ptyRun(SWIFT, ghost);
    record('token: /ws/pty attach unknown target', closeOf(bGhost), closeOf(sGhost), closeOf(bGhost) === closeOf(sGhost) ? PASS : 'MISMATCH');

    const oversize = [{ type: 'attach', target: 'nope:1', cols: 9999, rows: 24 }];
    const bOver = await ptyRun(BUN, oversize), sOver = await ptyRun(SWIFT, oversize);
    record('token: /ws/pty out-of-range dimensions', closeOf(bOver), closeOf(sOver), closeOf(bOver) === closeOf(sOver) ? PASS : 'MISMATCH');
  }

  if (!(await stopPair())) console.error('WARNING: a port was still bound after SIGTERM');
  rmSync(tokenFile, { force: true });

  // ---- phase 4: roster fixtures ------------------------------------------
  // The live fleet can only show the shapes it happens to be in. These 49
  // canned snapshots are the shapes that BROKE something: a BOM inside an
  // agent name, a duplicate pane id, a float protocol version, a workspace
  // suffix that overflows. Both servers read them through the same stand-in
  // `herdr` binary, so any difference is a projection bug, not fleet drift.
  console.log('\n## phase 4 — roster fixtures (canned herdr snapshots)');
  const fixtureRoot = resolve(ROOT, 'utils/fixtures');
  const pointer = `${TMP}/conformance-case-pointer`;
  let fixtureNames = [];
  try { fixtureNames = readdirSync(fixtureRoot).filter((name) => existsSync(`${fixtureRoot}/${name}/list.json`)).sort(); } catch { }
  if (!fixtureNames.length) {
    record('roster fixtures', 'n/a', 'n/a', 'skipped', `no fixtures under ${fixtureRoot}`);
  } else {
    writeFileSync(pointer, `${fixtureRoot}/${fixtureNames[0]}`);
    children.length = 0;
    await startPair(
      ['--insecure-no-token', '--demo-minutes', '10', '--herdr', resolve(ROOT, 'utils/fixture-herdr.sh')],
      'fixtures', [], [], { CONFORMANCE_CASE_POINTER: pointer });

    const differing = [];
    for (const name of fixtureNames) {
      writeFileSync(pointer, `${fixtureRoot}/${name}`);
      const b = await once(BUN, { path: '/api/sessions' });
      const s = await once(SWIFT, { path: '/api/sessions' });
      // Canned input: byte-for-byte, including key order, no retry budget.
      if (b.status !== s.status || b.text !== s.text) {
        differing.push(`${name} (${b.status}/${s.status}) ${firstDiff(b.text, s.text)}`);
      }
    }
    record(`roster fixtures (${fixtureNames.length})`, `${fixtureNames.length} snapshots`,
      `${fixtureNames.length - differing.length} identical`,
      differing.length ? 'MISMATCH' : PASS, differing.slice(0, 5).join(' ;; '));
    if (!(await stopPair())) console.error('WARNING: a port was still bound after SIGTERM');
    rmSync(pointer, { force: true });
  }

  // ---- phase 5: access log ------------------------------------------------
  // The log is a security surface: it must carry the request but never the
  // credential, and both servers have to scrub the same query keys the same
  // way. Same requests, same order, then diff the lines with only the clock,
  // the latency and the peer address normalised away.
  console.log('\n## phase 5 — access log');
  children.length = 0;
  const logPointer = `${TMP}/conformance-log-pointer`;
  writeFileSync(logPointer, `${fixtureRoot}/happy`);
  await startPair(['--insecure-no-token', '--demo-minutes', '5', '--access-log', '--herdr', resolve(ROOT, 'utils/fixture-herdr.sh')],
    'accesslog', [], [], { CONFORMANCE_CASE_POINTER: logPointer });
  const logSpecs = [
    { path: '/api/health' },
    { path: '/api/capture?target=default-x%2F00%3A1&secret=shhh' },
    { path: '/api/capture?lines=5&target=a+b' },
    { path: '/api/feed?limit=3&token=shhh' },
    { path: '/nope?x=1' },
    { path: '/api/sessions', headers: { Origin: 'http://localhost:9999' } },
    { path: '/api/sessions', headers: { Origin: 'https://evil.example.com' } },
    { method: 'POST', path: '/api/send', body: '{}' },
    { method: 'OPTIONS', path: '/api/sessions', headers: { Origin: 'http://localhost:9999', 'Access-Control-Request-Method': 'GET' } },
    { method: 'OPTIONS', path: '/api/sessions', headers: { Origin: 'http://localhost:9999', 'Access-Control-Request-Method': 'GET', 'Access-Control-Request-Headers': 'X-Evil' } },
    { path: '/api/%2e%2e/api/health' },
    { path: '/api/capture?target=a&target=b' },
    { path: '/api/feed?limit=1&limit=2' },
    { path: '/api/capture?target=%E0%B8%9B%E0%B8%A5%E0%B8%B2' },
    { method: 'DELETE', path: '/api/sessions' },
    { method: 'POST', path: '/api/sessions', body: '{}' },
    { path: '/api/health', headers: { Host: 'evil.example.com' } },
    { method: 'POST', path: '/api/send', body: JSON.stringify({ target: 'x', text: 'y'.repeat(300 * 1024) }) },
  ];
  for (const spec of logSpecs) { await once(BUN, spec); await once(SWIFT, spec); }

  // Raw byte probes: the rejections `fetch` cannot express. Each one is a
  // request Bun refuses at the server level, before its handler — so the
  // response is a bare status line AND there is no access-log entry. Both are
  // compared: the bytes here, the absence in the log diff below.
  const rawProbes = [
    ['no Host (HTTP/1.1)', 'GET /api/health HTTP/1.1\r\n\r\n'],
    ['no Host (HTTP/1.0)', 'GET /api/health HTTP/1.0\r\n\r\n'],
    ['HTTP/1.0 with Host', 'GET /api/health HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n'],
    ['bad version', 'GET /api/health HTTP/9.9\r\nHost: 127.0.0.1\r\n\r\n'],
    ['garbage request line', 'NOT A REQUEST\r\n\r\n'],
    ['Host: a b', 'GET /api/health HTTP/1.1\r\nHost: a b\r\n\r\n'],
    ['Host: ::1 (unbracketed)', 'GET /api/health HTTP/1.1\r\nHost: ::1\r\n\r\n'],
    ['oversized Content-Length', `POST /api/send HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: ${1 << 20}\r\n\r\n`],
    // Host-header guard. The reference runs `loopbackHost()` on the RAW
    // authority and builds `new URL(request.url)` from it BEFORE its handler,
    // so the three below are three different answers, not one.
    ['Host: 127.1.1.1 (loopback)', 'GET /api/health HTTP/1.1\r\nHost: 127.1.1.1\r\n\r\n'],
    ['Host: LOCALHOST (case)', 'GET /api/health HTTP/1.1\r\nHost: LOCALHOST\r\n\r\n'],
    ['Host: 127.0.0.01 (leading zero)', 'GET /api/health HTTP/1.1\r\nHost: 127.0.0.01\r\n\r\n'],
    ['Host: 127.999.1.1 (not IPv4)', 'GET /api/health HTTP/1.1\r\nHost: 127.999.1.1\r\n\r\n'],
    ['Host: [::ffff:127.0.0.1]', 'GET /api/health HTTP/1.1\r\nHost: [::ffff:127.0.0.1]\r\n\r\n'],
    // Header syntax. A control byte anywhere is a malformed request; a TAB is
    // legal OWS and must NOT be.
    ['control byte in header value', 'GET /api/health HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Junk: a\x01b\r\n\r\n'],
    ['control byte in Origin (log injection)', 'GET /api/health HTTP/1.1\r\nHost: 127.0.0.1\r\nOrigin: http://127.0.0.1\x1b[31m\r\n\r\n'],
    ['TAB in header value', 'GET /api/health HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Junk: a\tb\r\n\r\n'],
    // Body framing.
    ['repeated Content-Length (agreeing)', 'POST /api/send HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 2\r\nContent-Length: 2\r\n\r\n{}'],
    ['repeated Content-Length (differing)', 'POST /api/send HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 2\r\nContent-Length: 3\r\n\r\n{}'],
    ['Transfer-Encoding: identity', 'POST /api/auth/ws-ticket HTTP/1.1\r\nHost: 127.0.0.1\r\nOrigin: http://127.0.0.1\r\nTransfer-Encoding: identity\r\nContent-Length: 14\r\n\r\n{"path":"/ws"}'],
    // A chunked body must be decoded, not read as zero bytes. Split across
    // two chunks so a decoder that only handles the single-chunk case fails.
    ['chunked body (two chunks)', 'POST /api/auth/ws-ticket HTTP/1.1\r\nHost: 127.0.0.1\r\nOrigin: http://127.0.0.1\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n7\r\n{"path"\r\n7\r\n:"/ws"}\r\n0\r\n\r\n'],
    ['chunked body (bad json)', 'POST /api/auth/ws-ticket HTTP/1.1\r\nHost: 127.0.0.1\r\nOrigin: http://127.0.0.1\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nnot\r\n0\r\n\r\n'],
    // A 64 KiB head that arrives whole, in one write: the size test has to run
    // even when the terminator is found on the first pass.
    ['oversized head in one write', `GET /api/health HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Big: ${'a'.repeat(70000)}\r\n\r\n`],
    // WHATWG collapses a percent-encoded dot segment before routing, so both
    // servers must hand this to /api/nope and answer 404.
    ['%2e%2e dot segment', 'GET /api/%2e%2e/api/nope HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n'],
  ];
  const rawSend = (port, text) => new Promise((done) => {
    const socket = net.connect({ host: '127.0.0.1', port });
    let data = '';
    const finish = () => { try { socket.destroy(); } catch { } done(data); };
    socket.setTimeout(3000, finish);
    socket.on('connect', () => socket.write(text));
    socket.on('data', (chunk) => { data += chunk.toString('latin1'); });
    socket.on('close', finish);
    socket.on('error', () => finish());
  });
  for (const [name, text] of rawProbes) {
    const b = await rawSend(BUN_PORT, text), s = await rawSend(SWIFT_PORT, text);
    // Compare the status line and the header names; Date and Content-Length
    // move, and a body that is JSON is already covered by the HTTP phase.
    const shape = (raw) => {
      if (!raw) return '<no response>';
      const [head] = raw.split('\r\n\r\n');
      const lines = head.split('\r\n');
      // `connection` is excluded on purpose: the Swift port does not keep
      // connections alive and says so on every response. That single
      // divergence is measured once, in its own row, instead of colouring
      // every raw probe red.
      const skip = new Set(['date', 'content-length', 'connection']);
      const names = lines.slice(1).map((line) => line.split(':')[0].toLowerCase()).filter((n) => n && !skip.has(n)).sort();
      return `${lines[0]} [${names.join(',')}]`;
    };
    const bs = shape(b), ss = shape(s);
    record(`raw: ${name}`, bs, ss, bs === ss ? PASS : 'MISMATCH');
  }
  {
    const b = await rawSend(BUN_PORT, 'GET /api/health HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n');
    const s = await rawSend(SWIFT_PORT, 'GET /api/health HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n');
    const connection = (raw) => (/\r\nConnection: ([^\r]+)/i.exec(raw)?.[1] ?? '<absent>');
    const bc = connection(b), sc = connection(s);
    record('keep-alive / Connection header', bc, sc, bc === sc ? PASS : 'divergence',
      bc === sc ? '' : 'the Swift port closes after every response; the reference keeps the connection alive');
  }

  // One socket, so the 101 line is compared too.
  await collect(`${BUN}/ws`, { origin: 'http://localhost:9999', ms: 700 });
  await collect(`${SWIFT}/ws`, { origin: 'http://localhost:9999', ms: 700 });
  await new Promise((done) => setTimeout(done, 400));
  if (!(await stopPair())) console.error('WARNING: a port was still bound after SIGTERM');

  const logLines = (file) => {
    let text = '';
    try { text = readFileSync(file, 'utf8'); } catch { return []; }
    return text.split('\n')
      .filter((line) => line.trim() && !line.startsWith('maw herdr serve:'))
      // ip | [timestamp] | latency are the only fields allowed to differ.
      .map((line) => line
        .replace(/^\S+ /, 'IP ')
        .replace(/\[[^\]]+\]/, '[TIME]')
        .replace(/ \d+ms/, ' NNms'));
  };
  const bLog = logLines(`${TMP}/conformance-bun-accesslog.err`);
  const sLog = logLines(`${TMP}/conformance-swift-accesslog.err`);
  const logDiff = bLog.findIndex((line, index) => line !== sLog[index]);
  record('access log lines', `${bLog.length} lines`, `${sLog.length} lines`,
    bLog.length === sLog.length && logDiff < 0 ? PASS : 'MISMATCH',
    bLog.length === sLog.length && logDiff < 0 ? ''
      : `first difference at line ${logDiff < 0 ? Math.min(bLog.length, sLog.length) : logDiff}: bun=${JSON.stringify(bLog[logDiff] ?? null)} swift=${JSON.stringify(sLog[logDiff] ?? null)}`);
  const leaked = [...bLog, ...sLog].filter((line) => line.includes('shhh'));
  record('access log scrubs credentials', leaked.length ? 'LEAK' : 'clean', leaked.length ? 'LEAK' : 'clean',
    leaked.length ? 'MISMATCH' : PASS, leaked.length ? `a secret query value reached the log: ${leaked[0]}` : '');

  // ------------------------------------------------------------- report --
  const width = Math.max(...rows.map((r) => r.name.length), 4);
  console.log('\n| case | bun | swift | verdict |');
  console.log(`|${'-'.repeat(width + 2)}|---|---|---|`);
  for (const row of rows) {
    console.log(`| ${row.name.padEnd(width)} | ${row.bun} | ${row.swift} | ${row.verdict} |`);
    if (row.diff) console.log(`    ↳ ${row.diff}`);
  }
  const passed = rows.filter((r) => r.verdict === PASS).length;
  console.log(`\ncases=${rows.length} same=${passed} not-implemented=${notImplemented} known-divergence=${divergences} mismatch=${realMismatches} quirk=${rows.filter((r) => r.verdict === 'quirk').length}`);
  if (quirks.length) { console.log('\nQUIRKS (both servers agree):'); for (const q of quirks) console.log(`  - ${q}`); }
  if (notes.length) { console.log('\nNOTES:'); for (const n of notes) console.log(`  - ${n}`); }

  const free = (await portFree(BUN_PORT)) && (await portFree(SWIFT_PORT));
  console.log(`\nports ${BUN_PORT}/${SWIFT_PORT} free: ${free}`);
  exitCode = realMismatches ? 1 : 0;
} catch (error) {
  console.error(`\nconformance aborted: ${error?.stack || error}`);
  exitCode = 2;
} finally {
  killAll();
}
process.exit(exitCode);
