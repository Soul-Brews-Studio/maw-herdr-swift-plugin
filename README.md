# maw-herdr-swift-plugin

`maw herdr-swift serve` — the same dashboard API as `maw herdr serve`
([maw-herdr-plugin](https://github.com/Soul-Brews-Studio/maw-herdr-plugin)),
reimplemented as a native Swift binary. Dev-tier JS plugin (`runtime:
"bun-dev"`) that wraps a compiled executable — maw still dispatches it under
Bun, but the server itself has no Bun dependency at all.

## Why a second implementation

The Bun/TypeScript server is the reference — it has a 275-assertion suite,
and where the two disagree, it is right. This port exists anyway, for two
reasons:

- **A bug reproduced in both implementations is a bug in the protocol, not in
  one runtime.** Anything the dashboard depends on that only one server gets
  right was never actually specified.
- **A native binary with no Bun dependency.** Nothing here needs `bun`
  installed, `node_modules`, or a JS runtime on the host at all — just the
  Swift toolchain to build it once.

Parity is the goal, not improvement. Where the Swift port found a Bun
behavior that looks like a bug, it was ported as-is and reported, not
silently fixed — see [Parity](#parity) below.

## Install

```bash
maw plugin install Soul-Brews-Studio/maw-herdr-swift-plugin
maw plugin ls               # herdr-swift
maw herdr-swift serve --help
```

`owner/repo` expands to GitHub; `owner/repo@ref` pins branch/tag. The plugin
root is wherever `maw`'s own inventory resolves to (`~/.maw/plugins` unless
`MAW_PLUGINS_DIR`/`MAW_HOME` says otherwise) — there is no `--root` flag on
`maw plugin install` itself; that flag belongs to the legacy `maw-rs` binary
(see `just install-local` below), not the `maw plugin install SOURCE [--ref
REF]` command a plain `maw` on `PATH` runs. Verified 2026-09-22: this exact
`--root` form fails with `maw: usage: maw plugin ls|install SOURCE [--ref
REF]|...` on this machine.

From a clone, use the justfile:

```bash
just build            # swift build -c release
just run              # insecure demo on 127.0.0.1:3467, Ctrl-C to stop
just smoke            # build + boot + curl every route class + assert status codes
just conformance      # protocol parity against the Bun reference server
just install-local    # stage via git archive, install with maw-rs
```

⚠️ **Never `maw plugin install .` from a checkout that went through
`/incubate`.** Its `ψ` symlink cycles back into the oracle vault — the
installer walks it forever. Measured elsewhere in this fleet: 3.5 GB written
before kill, plugin left with no entry point. `just install-local` stages via
`git archive` (tracked files only, no `ψ`), which is immune.

## Run

The first `serve` invocation builds the binary (`swift build -c release`,
needs the Xcode command line tools — if `swift` isn't on `PATH`, the fix is
`xcode-select --install`). Later invocations reuse it unless `Sources/`
changed since the last build.

```bash
test -e "$HOME/.maw-herdr-token" || \
  (umask 077; openssl rand -hex 32 > "$HOME/.maw-herdr-token")
maw herdr-swift serve --token-file "$HOME/.maw-herdr-token" --listen 127.0.0.1:3467
```

Auth is mandatory even on loopback. If `--listen` is omitted, the default is
**3457** — the same default the Bun server uses (`ServeConfig.port` in
`Config.swift` mirrors Bun's `readServeConfig`), so running both on their
defaults at once collides. The examples in this README pass `--listen
127.0.0.1:3467` explicitly for that reason, one above Bun's default, so the
two can run side by side while comparing them; always pass `--listen`
yourself rather than relying on the default when both servers are up.

```bash
# read-only demo: no token, stops itself, logs every request
maw herdr-swift serve --insecure-no-token --listen 127.0.0.1:3467 --demo-minutes 60

# a dashboard on another origin must be named, or it gets 403 origin_not_allowed
maw herdr-swift serve --insecure-no-token --listen 127.0.0.1:3467 --demo-minutes 60 \
  --allow-origin https://village.buildwithoracle.com \
  --allow-origin https://bridge.buildwithoracle.com

# writes — send, wake, cleanup — need the token file
maw herdr-swift serve --token-file ~/.maw-herdr-token --listen 127.0.0.1:3467
```

Loopback pages and `god.buildwithoracle.com` are allowed built-in. Everything
else is opt-in per origin, exact `scheme://host[:port]`, no wildcards: an
allowed origin can read every pane this server can see.

`--access-log` prints an nginx-style line per request to stderr as it
happens, and is on by default under `--insecure-no-token`. Tokens and tickets
never reach it — the query string is scrubbed to a small allowlist of keys
and no header is ever printed, since an operator token rides in
`Authorization` and a socket ticket in `Sec-WebSocket-Protocol`. A page that
sits on "offline" with nothing in the log was blocked by the browser before
the request left — usually Private Network Access on an HTTPS page reaching
loopback.

## Requirements

- Swift 6.3, macOS 14+ (see `Package.swift`)
- `herdr` on `PATH` (the compiled binary shells out to it, same as the Bun
  server does)
- `bun` only to run the maw dispatcher itself — never the server

## Parity

Measured, not asserted. `just conformance` boots the Bun reference server on
3497 and this one on 3498 against the **same live herdr**, fires the same
request at both, and diffs status, headers and parsed body. Last full run —
2026-09-22, m5, 44 sessions / 70 panes, herdr snapshot protocol 22:

```
cases=155 same=153 not-implemented=0 known-divergence=2 mismatch=0
```

`--claims` adds the two ticket-expiry probes: `cases=157 same=155`, same
verdicts (`accepted` at 20 s, `refused` at 40 s on both — the reference mints
at `now + 30_000` and so does this).

(`not-implemented=0`: every route the harness can reach is now implemented —
`/api/worktrees`, `/api/worktrees/cleanup`, `/api/federation/status` and
`/fed.json` were the last four stubs and are ported. `known-divergence=2` is
the `Connection: close` header and the one unmasked-WebSocket-frame case
below, both deliberate.)

| Surface | Bun (reference) | Swift | Notes |
|---|---|---|---|
| HTTP routes | 23 routes | identical | Every route is ported — sessions, agents, capture, captures, send, wake, identity, health, teams, feed, costs, config, asks, ui-state, auth/ws-ticket, **worktrees, worktrees/cleanup, federation/status, fed.json** — byte-identical, key order included. `/api/worktrees` lists `git worktree list --porcelain -z` of the server's startup cwd; the harness runs both servers from the same cwd so the bodies match. `/api/worktrees/cleanup` is the one route that *deletes* a worktree — exercised only by rejection cases (no `path`, a traversal path, a non-JSON content-type), which are refused before anything is removed and, per the reference's single catch, all answer `400 worktree_cleanup_rejected` (a wrong content-type is a `400`, not a `415`). |
| Federation | `mod.createFederation.ts` | identical | `/api/federation/status` and `/fed.json` sweep the peers in `~/.maw/peers.json` (≤ 4 at once, 2.5 s each, a 15 s cache, one flight per config fingerprint) with the same signed `GET /api/sessions` probe, pinned to the first resolved address. The peer set, ordering, `node`/`oracle`/`auth_ok`/`node_unique`/`resolved_ip`/`loopback_self` all match; the harness blanks the live-probe outcomes (`reachable`, `latency`, `agents`, `fetch_error`, `reachablePeers`) because two sweeps a few ms apart are entitled to disagree on exactly those. |
| WebSocket protocol | `maw.ws.v1` | identical | Same frame sequence (`sessions,recent,teams,feed-history`), same `sessions` payload byte-for-byte, same `capture` text, same errors (`operator_token_required_for_writes`, `command_not_supported`, `subscription_target_gone`, `wake_failed`). Tickets are `mwt1_<64 hex>`, single-use, and both expire between 20 s and 40 s after minting (Bun: `now + 30_000`). |
| WebSocket framing / close | uWebSockets | identical (1 divergence) | Driven by a raw fragmenting client. A protocol error (reserved bits, unknown opcode, invalid control frame, non-UTF-8 text, an unexpected/interleaved fragment, an over-cap message — including one accumulated from two under-cap fragments) drops the TCP connection with **no close frame**, matching uWS. A client CLOSE is echoed **verbatim** for an accepted code (`1000`-`1003`, `1007`-`1011`, `4000`-`4999` — *not* the full `3000`-`4999` RFC range; uWS rejects `3000`-`3999`) carried with a valid-UTF-8 reason, and answered with an **empty** close frame for anything else. **The one divergence:** an *unmasked* client frame — uWS mis-parses it and leaves the socket open; this port refuses it with `1002` rather than mis-parse and leak a slot. |
| `/ws/pty` | terminal stream | identical | Ticketed upgrade, `1008 invalid terminal command` for a malformed or out-of-range `attach`, `1011 terminal unavailable` for an unknown target. |
| Error shapes | `{"error": code}` | identical | Including the odd ones, reproduced rather than fixed: `POST` to a read route is `401`, never `405` (the write gate runs before the method allow-list); `/api/send` with an empty target answers `400 {"ok":false,"error":"empty-target","state":"failed"}`; an unparseable `Host` is `500 request_failed` with `Cache-Control` and nothing else. |
| Raw HTTP edges | uWebSockets | identical | No `Host` on HTTP/1.1 → bare `400`; unknown version → bare `505`; garbage request line → bare `400`; body over 257 KiB → bare `413`. Status line only, no headers, no body, on both. |
| Access log format | nginx-style, stderr | identical | Line-for-line after normalising ip / clock / latency, 29 lines over the same 29-request script — including the path percent-encoding (`GET /api/x"y` is logged as `"GET /api/x%22y"` by both, so a request-controlled quote cannot forge fields inside the quoted request) and the note-less `415` that `readJSON` throws. Same query scrubbing (`target`, `lines`, `since`, `limit` kept; everything else collapses to `…`), same `101 … ws read-only` line for an upgrade. A successful preflight and a `500 request_failed` are **not** logged by either — Bun builds both outside its `logged()` wrapper, so this port skips them too. |
| Roster projection | `mod.readRoster.ts` | identical | 49 canned herdr snapshots (`utils/fixtures/`) replayed through both servers: BOM inside an agent name, duplicate pane ids, float protocol version, overflowing workspace suffix, non-array panes. All 49 byte-identical. |
| Request framing | `Content-Length` + chunked | identical | `Transfer-Encoding: chunked` bodies are decoded (including across packet boundaries); any other transfer coding, `identity` included, is a bare `400` on both; a repeated `Content-Length` is accepted when every copy agrees and is a bare `400` when they differ; a 64 KiB head is `431` however it is split across reads. |
| Host / Origin | `mod.loopbackHost.ts` | identical | One predicate for both the Host guard and the CORS allowlist, on the RAW authority: `LOCALHOST` refused (case-sensitive), `127.0.0.01` refused (node's `isIP` has no leading zeros), `127.999.1.1` is `500 request_failed` (WHATWG refuses an IPv4-shaped host that is not valid IPv4), `[::ffff:127.0.0.1]` allowed — that last one is what a dashboard page on a dual-stack socket actually sends. |
| Connections | keep-alive | `Connection: close` | **The one known protocol divergence.** This port answers one request per connection. A graceful half-close was tried and reverted — it made the server the active closer and exhausted TIME_WAIT (150/150 curl failures). Measured 2026-09-22: 300 rapid requests (150 sequential + 150 in 15-way parallel) against this server, 0 client failures. A client that half-closes after a complete request gets no response from **either** server. |
| `/api/identity` `runtime` | `"bun"` | `"swift"` | **The one deliberate body divergence**, recorded in `Contract.swift`. The field exists to tell an operator what is answering the port; a Swift binary claiming to be Bun is the one lie it cannot afford. Every other byte of that body, key order included, is identical. |

**Not implemented: nothing.** Every route the harness can reach is ported
(`not-implemented=0` above). The two things this port cannot show are not
missing routes — they're `503`s inherited from this machine's own registry
state (`/api/wake`, see below) and a route the harness refuses to reach on
purpose before the field it would exercise is examined (`/api/captures`,
also below).

**Bun quirks reproduced on purpose, not fixed** — each one holds on both
servers:

- A write to a read-only route is `401`, never `405` — the write-gate check
  runs before the method allow-list. `DELETE /api/sessions` (a real
  unsupported method on an already-writable route) is the one that gets a
  genuine `405` with `Allow`.
- `POST /api/send` with a blank target answers `400
  {"ok":false,"error":"empty-target","state":"failed"}` — the one endpoint
  whose error body isn't the bare `{"error": code}` shape everything else
  uses.
- An unparseable `Host` (`a b`, a bare `::1`, or none at all on HTTP/1.0)
  reaches the generic `error()` fallback: `500 {"error":"request_failed"}`
  with `Cache-Control` and no `nosniff`/CORS header, and no access-log line.
- Server-level rejections — `413` over 257 KiB, `400` for a missing `Host`
  on HTTP/1.1, `505` for a bad version, `400` for a garbage request line —
  are a bare status line, `Connection: close`, no other header, no body, no
  log line.
- A successful CORS preflight is never access-logged; a refused one is.
- `/api/captures` refuses any fleet over 64 panes outright, so its
  unknown-key branch is unreachable on this 70-pane machine on both servers.
- `/api/feed?limit=` clamps an in-range value up to `200` but answers `400
  invalid_limit` for a *repeated* `limit` key, on both servers.

**Reported, not fixed — a hole both servers share.** Under
`--insecure-no-token`, an unauthenticated caller can mint a `/ws/pty` ticket
and open a fully interactive terminal into any pane:
`/api/auth/ws-ticket` is excluded from the write gate, it accepts
`path: "/ws/pty"`, and the pty session carries no read-only flag on either
side (`mod.createPtySession.ts` takes no `readOnly`; neither does
`WSPtySession`) — unlike the dashboard session, which *does* gate `wake` and
`send` on it. The startup banner both servers print, "writes (send, wake,
cleanup) still require `--token-file`", is therefore wrong about the pty path
on both. The banner is left byte-identical here on purpose: correcting only
this copy would make the two servers disagree about a hole they share. Filed
upstream against the Bun server; a fix belongs in both. Until then, treat
`--insecure-no-token` as a **local-trust** mode, not a read-only one.

Three things the live fleet cannot show, recorded rather than guessed:

- **`/api/wake` state strings.** Both servers answer `503 herdr_unavailable`
  for every target on this machine — `~/.maw/oracles.json` fails the
  registry reader's validation, so wake never gets past identity resolution.
  The three states (`ready` / `already-awake` / `launched`) are implemented
  and compile-checked, but only the error path is measured here.
- **`/api/captures` with an unknown key.** Unreachable: the batch route
  refuses any fleet over 64 panes, and this one has 70.
- **Socket `send` without `force`.** Typing into a live pane is a side effect,
  so it is opt-in: `bun utils/conformance.mjs --send-probe` types a
  `#`-prefixed marker into one **agentless** pane, checks both servers left it
  on the input line unsubmitted, and clears the line again. Verified
  2026-09-22.

```bash
just conformance                            # ~2 min, both servers, live fleet
bun utils/conformance.mjs --no-ws           # HTTP only
bun utils/conformance.mjs --claims          # + the 80 s ticket-expiry probe
bun utils/conformance.mjs --send-probe      # + types into one agentless pane
```

## Traps

- **`--listen` only accepts a loopback host.** `127.0.0.1`, `::1`, or
  `localhost` — anything else is refused before the socket opens.
- **`--token-file` must be a regular file, ≤4096 bytes, mode `0600` or
  tighter, holding 16–4096 bytes of token text.** Anything looser is refused
  with the exact `chmod`/`ls` to run next, not just a generic "invalid token".
- **`--demo-minutes` only applies with `--insecure-no-token`.** A tokenless
  listener that outlives the demo is the actual hazard, so it always expires
  (default 30 minutes) even if the flag is never passed.
