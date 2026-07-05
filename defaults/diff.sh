#!/usr/bin/env bash
# Find which `defaults write` corresponds to a UI setting:
#   defaults/diff.sh start   — take a baseline snapshot
#   (change the setting in System Settings)
#   defaults/diff.sh stop    — show the delta → move it into defaults.sh
set -euo pipefail
SNAP=/tmp/defaults-baseline.txt
case "${1:-}" in
  start)
    defaults read > "$SNAP" 2>/dev/null || true
    echo "baseline saved → change the setting, then: $0 stop" ;;
  stop)
    [ -f "$SNAP" ] || { echo "no baseline — run first: $0 start"; exit 1; }
    defaults read 2>/dev/null | diff "$SNAP" - | grep -E '^[<>]' \
      || echo "no visible delta (may be a per-host key: try 'defaults -currentHost read')" ;;
  *) echo "usage: $0 start|stop"; exit 2 ;;
esac
