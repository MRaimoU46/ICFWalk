#!/usr/bin/env bash
# Stops the local Lucee/Jetty process started by lucee-up.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PID_FILE="$ROOT/.runtime/lucee.pid"
if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
  kill "$(cat "$PID_FILE")" && echo "Stopped Lucee (pid $(cat "$PID_FILE"))"
  rm -f "$PID_FILE"
else
  echo "Lucee is not running."
  rm -f "$PID_FILE"
fi
