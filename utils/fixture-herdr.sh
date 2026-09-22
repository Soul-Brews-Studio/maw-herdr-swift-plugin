#!/bin/sh
# A stand-in for the `herdr` binary, used by utils/conformance.mjs to feed BOTH
# servers the same canned snapshot. The case directory is read from a pointer
# file on every invocation, so the harness can walk 48 fixtures without
# restarting either server.
CASE="$(cat "$CONFORMANCE_CASE_POINTER" 2>/dev/null)"
case "$*" in
  "session list --json") cat "$CASE/list.json" ;;
  *"api snapshot") cat "$CASE/snap.json" ;;
  *) printf '%s' "PANE-TEXT" ;;
esac
