#!/usr/bin/env bash
# Stops and removes the Adobe ColdFusion 2023 container started by acf-up.sh. Its generated
# administrator password and application environment file stay in .runtime/acf (git-ignored).
set -euo pipefail
CONTAINER="${ICFWALK_ACF_CONTAINER:-icfwalk-acf}"
if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  docker rm -f "$CONTAINER" >/dev/null && echo "Removed $CONTAINER"
else
  echo "Container $CONTAINER does not exist."
fi
