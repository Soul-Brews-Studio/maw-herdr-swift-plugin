#!/usr/bin/env bash
# Smoke-tests the compiled MawHerdrServe binary end to end: build it, boot an
# --insecure-no-token demo on 127.0.0.1:3498, hit one route from every class
# the dashboard depends on, and assert the status code. Runs every check
# before deciding pass/fail, prints the exact curl for each failure (so
# re-running by hand needs no guessing), and always kills the server on exit.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

HOST=127.0.0.1
PORT=3498
BASE="http://$HOST:$PORT"
BINARY="$ROOT/.build/release/MawHerdrServe"
LOG="$(mktemp -t maw-herdr-swift-smoke.XXXXXX)"
SERVER_PID=""
FAILED=0

cleanup() {
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null
    wait "$SERVER_PID" 2>/dev/null
  fi
  rm -f "$LOG"
}
trap cleanup EXIT

echo "== build =="
if ! swift build -c release; then
  echo "FAIL: swift build -c release" >&2
  exit 1
fi

echo "== boot: $BASE (insecure demo, self-stopping in 2m) =="
"$BINARY" --insecure-no-token --listen "$HOST:$PORT" --demo-minutes 2 >"$LOG" 2>&1 &
SERVER_PID=$!

echo "== wait for /api/health =="
up=0
for _ in $(seq 1 50); do
  # 2>/dev/null: the listener is not up for the first iteration or two and a
  # "Couldn't connect" line here reads like a failure when it is not.
  if curl -fsS -o /dev/null "$BASE/api/health" 2>/dev/null; then
    up=1
    break
  fi
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "FAIL: server exited before /api/health came up" >&2
    cat "$LOG" >&2
    exit 1
  fi
  sleep 0.2
done
if [[ "$up" -ne 1 ]]; then
  echo "FAIL: /api/health never returned 200 within 10s" >&2
  cat "$LOG" >&2
  exit 1
fi

# check <name> <method> <path> <expect-status> [extra curl args...]
check() {
  local name="$1" method="$2" path="$3" expect="$4"
  shift 4
  local got
  got="$(curl -sS -o /dev/null -w '%{http_code}' -X "$method" "$@" "$BASE$path")"
  if [[ "$got" == "$expect" ]]; then
    echo "ok: $name ($got)"
  else
    echo "FAIL: $name: expected $expect, got $got" >&2
    echo "  curl -sS -i -X $method $* $BASE$path" >&2
    FAILED=1
  fi
}

check "identity"              GET  /api/identity 200
check "sessions"               GET  /api/sessions 200
check "agents"                  GET  /api/agents   200
check "disallowed origin"       GET  /api/sessions 403 -H 'Origin: https://evil.example'
check "send needs a token"      POST /api/send     401 -H 'Content-Type: application/json' -d '{}'
# Measured on BOTH servers: the write gate runs BEFORE the method allow-list,
# so POST to a read route is 401, never 405. DELETE is not a write, so it
# reaches the allow-list and is the method-check that actually fires.
check "write gate precedes method"  POST   /api/sessions 401
check "sessions is GET-only"        DELETE /api/sessions 405
check "unknown route"           GET  /api/does-not-exist 404
check "capture needs a target"  GET  /api/capture 400
check "stub route"              GET  /api/config 501
# A preflight with no Origin is 403 on both servers — the browser always sends
# one, so the check has to as well.
check "preflight"               OPTIONS /api/sessions 204 -H "Origin: $BASE" -H 'Access-Control-Request-Method: GET'
check "preflight needs origin"  OPTIONS /api/sessions 403 -H 'Access-Control-Request-Method: GET'
check "ws needs an origin"      GET  /ws 400

if [[ "$FAILED" -ne 0 ]]; then
  echo "-- server log --" >&2
  cat "$LOG" >&2
  exit 1
fi

echo "smoke: all checks passed"
