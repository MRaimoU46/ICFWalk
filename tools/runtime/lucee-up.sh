#!/usr/bin/env bash
# Runs the application on Lucee 6 under Jetty for local verification when Adobe ColdFusion 2023
# is not available. The production target remains Adobe ColdFusion 2023; see docs/LOCAL_SETUP.md
# for the ColdFusion deployment. Downloads three jars from Maven Central into .runtime/jars,
# generates app/WEB-INF (git-ignored), and starts Jetty on ICFWALK_PORT (default 8888).
#
# Configuration is read by the application from environment variables or <repo>/.env.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RUNTIME="$ROOT/.runtime"
JARS="$RUNTIME/jars"
mkdir -p "$JARS"
PORT="${ICFWALK_PORT:-8888}"
LUCEE_VERSION="${LUCEE_VERSION:-6.2.8.20}"
JETTY_VERSION="${JETTY_RUNNER_VERSION:-9.4.58.v20250814}"
MSSQL_JDBC_VERSION="${MSSQL_JDBC_VERSION:-12.10.2.jre11}"

fetch() { # fetch <relative maven path> <target>
  local rel="$1" target="$2" base code
  [ -s "$target" ] && return 0
  for base in "https://repo1.maven.org/maven2" "https://maven-central.storage-download.googleapis.com/maven2" "https://repo.maven.apache.org/maven2"; do
    code=$(curl -sS -L -o "$target.part" -w '%{http_code}' --max-time 900 "$base/$rel" || true)
    if [ "$code" = "200" ]; then mv "$target.part" "$target"; echo "Downloaded $(basename "$target") from $base"; return 0; fi
    rm -f "$target.part"
    echo "  $base returned $code for $rel; trying next mirror" >&2
  done
  echo "Could not download $rel" >&2
  return 1
}

fetch "org/lucee/lucee/$LUCEE_VERSION/lucee-$LUCEE_VERSION-light.jar" "$JARS/lucee-light.jar"
fetch "org/eclipse/jetty/jetty-runner/$JETTY_VERSION/jetty-runner-$JETTY_VERSION.jar" "$JARS/jetty-runner.jar"
fetch "com/microsoft/sqlserver/mssql-jdbc/$MSSQL_JDBC_VERSION/mssql-jdbc-$MSSQL_JDBC_VERSION.jar" "$JARS/mssql-jdbc.jar"

WEBINF="$ROOT/app/WEB-INF"
mkdir -p "$WEBINF/lib"
cp -f "$JARS/lucee-light.jar" "$JARS/mssql-jdbc.jar" "$WEBINF/lib/"
cp -f "$ROOT/tools/runtime/web.xml" "$WEBINF/web.xml"

if [ -f "$RUNTIME/lucee.pid" ] && kill -0 "$(cat "$RUNTIME/lucee.pid")" 2>/dev/null; then
  echo "Lucee already running (pid $(cat "$RUNTIME/lucee.pid"))."
  exit 0
fi

export LUCEE_ENABLE_BUNDLE_DOWNLOAD=false
export LUCEE_ADMIN_ENABLED=false
cd "$ROOT"
nohup java -Xmx1g -Dlucee.base.dir="$RUNTIME/lucee-server" -jar "$JARS/jetty-runner.jar" --port "$PORT" --path / "$ROOT/app" > "$RUNTIME/lucee.log" 2>&1 &
echo $! > "$RUNTIME/lucee.pid"
echo "Starting Lucee/Jetty on port $PORT (pid $(cat "$RUNTIME/lucee.pid"), log $RUNTIME/lucee.log)"
for i in $(seq 1 90); do
  if curl -sS -o /dev/null --max-time 5 "http://127.0.0.1:$PORT/index.cfm/api/health"; then
    echo "Health: $(curl -sS --max-time 10 "http://127.0.0.1:$PORT/index.cfm/api/health")"
    exit 0
  fi
  sleep 2
done
echo "Application did not answer on port $PORT; see $RUNTIME/lucee.log" >&2
exit 1
