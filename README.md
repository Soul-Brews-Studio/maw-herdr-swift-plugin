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
maw plugin install Soul-Brews-Studio/maw-herdr-swift-plugin --root ~/.maw/plugins
maw plugin ls               # herdr-swift
maw herdr-swift serve --help
```

`owner/repo` expands to GitHub; `owner/repo@ref` pins branch/tag.

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

Auth is mandatory even on loopback. Default port is **3467**, one above the
Bun server's default (3457), so the two can run side by side while comparing
them.

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

Filled in by the Conformance phase, which runs both servers side by side and
diffs their responses.

| Surface | Bun (reference) | Swift | Notes |
|---|---|---|---|
| HTTP routes | — | — | — |
| WebSocket protocol | — | — | — |
| Error shapes | — | — | — |
| Access log format | — | — | — |

## Traps

- **`--listen` only accepts a loopback host.** `127.0.0.1`, `::1`, or
  `localhost` — anything else is refused before the socket opens.
- **`--token-file` must be a regular file, ≤4096 bytes, mode `0600` or
  tighter, holding 16–4096 bytes of token text.** Anything looser is refused
  with the exact `chmod`/`ls` to run next, not just a generic "invalid token".
- **`--demo-minutes` only applies with `--insecure-no-token`.** A tokenless
  listener that outlives the demo is the actual hazard, so it always expires
  (default 30 minutes) even if the flag is never passed.
