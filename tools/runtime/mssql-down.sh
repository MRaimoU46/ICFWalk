#!/usr/bin/env bash
# Stops (and with --destroy removes) the local SQL Server container.
set -euo pipefail
CONTAINER="${ICFWALK_MSSQL_CONTAINER:-icfwalk-mssql}"
if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  docker stop "$CONTAINER" >/dev/null && echo "Stopped $CONTAINER"
  if [ "${1:-}" = "--destroy" ]; then docker rm "$CONTAINER" >/dev/null && echo "Removed $CONTAINER"; fi
else
  echo "Container $CONTAINER does not exist."
fi
