# maw-herdr-swift-plugin — native Swift reimplementation of `maw herdr serve`.
#
# The Bun/TypeScript server in maw-herdr-plugin is the reference (275-assertion
# suite); this port matches it protocol-for-protocol with no shared runtime, so
# a bug reproduced in both is a bug in the protocol, not in one implementation.

default:
    @just --list

# compile the release binary
build:
    swift build -c release

# insecure read-only demo on 3467, beside the Bun server's default (3457)
run: build
    .build/release/MawHerdrServe --insecure-no-token --listen 127.0.0.1:3467

# build + boot on 3498 + curl every route class + assert status codes + kill
smoke: build
    bash utils/smoke.sh

# Boots both servers (Bun on 3497, this one on 3498) against the same live
# herdr, fires the same request at both, diffs status + headers + parsed body,
# and kills both on every exit path. Non-zero exit = a real mismatch.
#   --no-ws       HTTP cases only
#   --claims      + the 80s ticket-expiry probe
#   --send-probe  + types a `#` marker into ONE agentless pane, then clears it

# protocol parity against the Bun reference server, side by side
conformance: build
    bun utils/conformance.mjs

# stage tracked files via `git archive` and install with maw-rs.
#
# NEVER `maw plugin install .` from a checkout that went through /incubate —
# its `ψ` symlink cycles back into the oracle vault, and the installer walks it
# forever (measured: 3.5 GB written before kill, plugin left with no index.mjs).
# `git archive` emits tracked files only, so there is no ψ for it to find.
install-local: build
    #!/usr/bin/env bash
    set -euo pipefail
    stage="$(mktemp -d "${TMPDIR:-/tmp}/maw-herdr-swift-plugin.XXXXXX")"
    trap 'rm -rf "$stage"' EXIT
    git archive HEAD | tar -x -C "$stage"
    maw-rs plugin install "$stage" --root ~/.maw/plugins --force
    maw plugin ls | grep -E '^herdr-swift' || true
