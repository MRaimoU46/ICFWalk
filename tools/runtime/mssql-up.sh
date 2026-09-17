#!/usr/bin/env bash
# Starts a disposable SQL Server 2022 (Developer edition) container for local development and
# tests, generates a random SA password into .runtime/mssql.env (git-ignored), and creates the
# icfwalk_dev and icfwalk_test databases. Requires Docker.
#
# Usage: tools/runtime/mssql-up.sh [--host-network]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RUNTIME="$ROOT/.runtime"
mkdir -p "$RUNTIME"
ENV_FILE="$RUNTIME/mssql.env"
CONTAINER="${ICFWALK_MSSQL_CONTAINER:-icfwalk-mssql}"
IMAGE="${ICFWALK_MSSQL_IMAGE:-mcr.microsoft.com/mssql/server:2022-latest}"
PORT="${ICFWALK_DB_PORT:-1433}"

if [ ! -f "$ENV_FILE" ]; then
  PW="Icf$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)!7"
  printf 'MSSQL_SA_PASSWORD=%s\n' "$PW" > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  echo "Generated SA password into $ENV_FILE"
fi
# shellcheck disable=SC1090
source "$ENV_FILE"

if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    docker start "$CONTAINER" >/dev/null
  fi
  echo "Container $CONTAINER is running."
else
  NET_ARGS=(-p "127.0.0.1:${PORT}:1433")
  if [ "${1:-}" = "--host-network" ]; then NET_ARGS=(--network host); fi
  docker run -d --name "$CONTAINER" "${NET_ARGS[@]}" \
    -e ACCEPT_EULA=Y -e "MSSQL_SA_PASSWORD=$MSSQL_SA_PASSWORD" -e MSSQL_PID=Developer \
    "$IMAGE" >/dev/null
  echo "Started $CONTAINER from $IMAGE"
fi

SQLCMD=(docker exec "$CONTAINER" /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -b)
for i in $(seq 1 60); do
  if "${SQLCMD[@]}" -Q "SELECT 1" >/dev/null 2>&1; then break; fi
  sleep 2
  if [ "$i" = "60" ]; then echo "SQL Server did not become ready" >&2; exit 1; fi
done
"${SQLCMD[@]}" -Q "IF DB_ID(N'icfwalk_dev') IS NULL CREATE DATABASE [icfwalk_dev]; IF DB_ID(N'icfwalk_test') IS NULL CREATE DATABASE [icfwalk_test];"
echo "Databases icfwalk_dev and icfwalk_test are available on 127.0.0.1:${PORT} (user sa, password in $ENV_FILE)."
