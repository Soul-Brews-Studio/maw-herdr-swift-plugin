#!/usr/bin/env bun
// maw herdr-swift <verb> — native Swift reimplementation of `maw herdr serve`.
//
// The reference is maw-herdr-plugin's Bun/TypeScript server. Where the two
// disagree, the Bun one is right — it has the test suite. This plugin exists
// so a bug reproduced in both is a bug in the protocol, not in one runtime.
//
// This file is only a dispatcher: it never speaks HTTP itself. `serve` makes
// sure the compiled binary is up to date, then hands the terminal to it —
// same argv, same stdio, same exit code.
import { spawn, spawnSync } from 'node:child_process';
import { readdirSync, statSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const PLUGIN_DIR = dirname(fileURLToPath(import.meta.url));
const BINARY_PATH = join(PLUGIN_DIR, '.build', 'release', 'MawHerdrServe');

const HELP = `maw herdr-swift <serve> [--token-file PATH|--insecure-no-token] [--listen 127.0.0.1:3467] — herdr serve, in Swift

  serve --token-file PATH [--listen 127.0.0.1:3467]     dashboard API, authenticated
  serve --insecure-no-token [--listen 127.0.0.1:3467]   read-only demo, self-stopping
  serve --help                                          full flag reference (printed by the binary)

Native Swift port of 'maw herdr serve' (maw-herdr-plugin, Bun/TypeScript). Same
protocol, same JSON shapes, no shared runtime with the reference server — a bug
reproduced in both is a bug in the protocol, not in one implementation.

Default port is 3467, so it can run beside the Bun server's default (3457).

First run compiles the binary ('swift build -c release', needs the Xcode
command line tools) — later runs reuse it unless Sources/ changed since.`;

function hasSwift() {
  const probe = spawnSync('swift', ['--version'], { stdio: 'ignore' });
  return !probe.error;
}

/** Newest mtime (ms) of any regular file under `dir`, walked recursively. */
function newestMtimeMs(dir) {
  let newest = 0;
  const stack = [dir];
  while (stack.length > 0) {
    const current = stack.pop();
    let entries;
    try {
      entries = readdirSync(current, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const entry of entries) {
      const full = join(current, entry.name);
      if (entry.isDirectory()) {
        stack.push(full);
        continue;
      }
      try {
        const mtimeMs = statSync(full).mtimeMs;
        if (mtimeMs > newest) newest = mtimeMs;
      } catch {
        // File vanished between readdir and stat — skip it.
      }
    }
  }
  return newest;
}

function needsBuild() {
  let binaryMtimeMs;
  try {
    binaryMtimeMs = statSync(BINARY_PATH).mtimeMs;
  } catch {
    return true; // no binary yet
  }
  let sourcesMtimeMs = newestMtimeMs(join(PLUGIN_DIR, 'Sources'));
  try {
    const packageMtimeMs = statSync(join(PLUGIN_DIR, 'Package.swift')).mtimeMs;
    if (packageMtimeMs > sourcesMtimeMs) sourcesMtimeMs = packageMtimeMs;
  } catch {
    // Package.swift always ships with the plugin; ignore if somehow absent.
  }
  return sourcesMtimeMs > binaryMtimeMs;
}

/** Ensure BINARY_PATH is current, building it if missing or stale. */
function ensureBinary() {
  if (!needsBuild()) return;
  if (!hasSwift()) {
    console.error('herdr-swift: swift is not on PATH');
    console.error('  xcode-select --install');
    process.exit(2);
  }
  console.error('herdr-swift: building (swift build -c release)…');
  const result = spawnSync('swift', ['build', '-c', 'release'], {
    cwd: PLUGIN_DIR,
    stdio: 'inherit',
  });
  if (result.error) {
    console.error(`herdr-swift: failed to run swift build: ${result.error.message}`);
    process.exit(1);
  }
  if (result.status !== 0) {
    process.exit(result.status ?? 1);
  }
}

const SIGNAL_EXIT_CODE = { SIGINT: 130, SIGTERM: 143 };

/** Build (if needed), then exec the binary with `rest` and inherited stdio. */
function serve(rest) {
  ensureBinary();
  const child = spawn(BINARY_PATH, rest, { stdio: 'inherit' });

  const forward = (signal) => {
    if (!child.killed) child.kill(signal);
  };
  process.on('SIGINT', forward);
  process.on('SIGTERM', forward);

  child.on('error', (error) => {
    console.error(`herdr-swift: failed to start ${BINARY_PATH}: ${error.message}`);
    process.exit(1);
  });
  child.on('exit', (code, signal) => {
    process.off('SIGINT', forward);
    process.off('SIGTERM', forward);
    process.exit(code !== null ? code : (SIGNAL_EXIT_CODE[signal] ?? 1));
  });
}

const args = process.argv.slice(2);
const verb = args[0] ?? '';

if (!verb || ['--help', '-h', 'help'].includes(verb)) {
  console.log(HELP);
  process.exit(0);
}

if (verb === 'serve') {
  // `serve --help` is forwarded too — the binary owns its own full flag
  // reference, so there is exactly one place that text can go stale.
  serve(args.slice(1));
} else {
  console.error(`maw herdr-swift: unknown verb "${verb}"`);
  console.error('  maw herdr-swift --help');
  process.exit(2);
}
