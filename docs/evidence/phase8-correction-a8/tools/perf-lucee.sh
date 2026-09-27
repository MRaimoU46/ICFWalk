#!/usr/bin/env bash
# The performance engine for A8-03: Lucee 6.2.8.20 under jetty-runner with -Xmx1g (the same jars and JVM
# options as tools/runtime/lucee-up.sh and the Phase 8 runs), on port 8889, serving a scratch copy of the
# repository tree in development mode on its own database (icfwalk_perf). The copy is taken from the
# working tree at start; the script prints the HEAD, tree and status it was taken from.
#
# usage: perf-lucee.sh start <scratch dir> | stop <scratch dir>
set -euo pipefail
REPO=/home/user/ICFWalk
ACTION="$1"; DIR="$2"
PORT=8889; DB=icfwalk_perf
case "$ACTION" in
stop)
  if [ -f "$DIR/lucee.pid" ] && kill -0 "$(cat "$DIR/lucee.pid")" 2>/dev/null; then kill "$(cat "$DIR/lucee.pid")"; for i in $(seq 1 60); do kill -0 "$(cat "$DIR/lucee.pid")" 2>/dev/null || break; sleep 0.5; done; echo "stopped perf Lucee"; fi
  rm -f "$DIR/lucee.pid"; exit 0 ;;
start) ;;
*) echo "usage: $0 start|stop <dir>" >&2; exit 2 ;;
esac
mkdir -p "$DIR"
echo "source: HEAD $(git -C "$REPO" rev-parse HEAD) tree $(git -C "$REPO" rev-parse 'HEAD^{tree}')"
S=$(git -C "$REPO" status --porcelain=v1 --untracked-files=all); echo "source status: ${S:-<clean>}"
rm -rf "$DIR/tree" "$DIR/lucee-server"; mkdir -p "$DIR/tree"
tar -C "$REPO" --exclude=./node_modules --exclude=./.git --exclude=./.runtime --exclude=./app/WEB-INF --exclude=./.env -cf - . | tar -x -C "$DIR/tree"
mkdir -p "$DIR/tree/app/WEB-INF/lib"
cp "$REPO/.runtime/jars/lucee-light.jar" "$REPO/.runtime/jars/mssql-jdbc.jar" "$DIR/tree/app/WEB-INF/lib/"
cp "$DIR/tree/tools/runtime/web.xml" "$DIR/tree/app/WEB-INF/web.xml"
grep -v -E '^ICFWALK_(DB_NAME|PORT)=' "$REPO/.env" > "$DIR/app.env"; printf 'ICFWALK_DB_NAME=%s\nICFWALK_PORT=%s\n' "$DB" "$PORT" >> "$DIR/app.env"; chmod 600 "$DIR/app.env"
echo "copied tree sha256 of the running code: $(cd "$DIR/tree" && find src app -type f \( -name '*.cfc' -o -name '*.cfm' -o -name '*.js' \) | sort | xargs sha256sum | sha256sum | cut -d' ' -f1) (src and app .cfc/.cfm/.js)"
echo "        same list in the repository:     $(cd "$REPO" && find src app -path app/WEB-INF -prune -o -type f \( -name '*.cfc' -o -name '*.cfm' -o -name '*.js' \) -print | sort | xargs sha256sum | sha256sum | cut -d' ' -f1)"
cd "$DIR/tree"
env -u ICFWALK_DB_NAME ICFWALK_ENV_FILE="$DIR/app.env" LUCEE_ENABLE_BUNDLE_DOWNLOAD=false LUCEE_ADMIN_ENABLED=false LUCEE_REQUESTTIMEOUT=600 \
  nohup java -Xmx1g -Dlucee.base.dir="$DIR/lucee-server" -jar "$REPO/.runtime/jars/jetty-runner.jar" --port "$PORT" --path / "$DIR/tree/app" > "$DIR/jetty.log" 2>&1 &
echo $! > "$DIR/lucee.pid"
for i in $(seq 1 120); do
  if curl -sS -o /dev/null --max-time 5 "http://127.0.0.1:$PORT/index.cfm/api/health" 2>/dev/null; then echo "perf Lucee pid $(cat "$DIR/lucee.pid") on $PORT: $(curl -sS --max-time 10 "http://127.0.0.1:$PORT/index.cfm/api/health")"; exit 0; fi
  sleep 1
done
echo "perf Lucee did not answer" >&2; exit 1
