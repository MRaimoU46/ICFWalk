#!/usr/bin/env bash
# Diagnosis of the ColdFusion live red that was not observed in the first operations run on b73f519:
# runs exactly what ops.sh's red() runs for ColdFusion (the audited tip's tree, the committed readiness
# operation, its own tools/runtime/acf-up.sh), with a watcher beside it that probes health every 10 s
# and, if ColdFusion has not answered for three minutes after its container appeared, records the
# container's log, ColdFusion's own logs and a thread dump, before the operation's cleanup removes the
# container. Writes into OUT only; the repository is read, never written.
#
# usage: red-acf-diag.sh <output directory outside the repository>
set -uo pipefail
REPO=/home/user/ICFWalk
OUT="$1"
AUDITED_TIP=10f476ba9a69359f23a259be0e903afeed64b415
ACF_IMAGE=adobecoldfusion/coldfusion2023@sha256:e42bbf07745ebd4d8c23d6679738ac13e264218618093bc3689ebfaf8966f30e
C=icfwalk-acf-ready
mkdir -p "$OUT"
echo "== $(date -u +%Y-%m-%dT%H:%M:%SZ)  HEAD $(git -C $REPO rev-parse HEAD), status entries $(git -C $REPO status --porcelain=v1 --untracked-files=all | wc -l)"
tree=$(mktemp -d /tmp/icfwalk-red-XXXXXX)
chmod 755 "$tree"   # ColdFusion (cfuser) must read the bind-mounted tree
git -C "$REPO" archive "$AUDITED_TIP" | tar -x -C "$tree"
git -C "$REPO" show HEAD:tests/ops/readiness-schema-missing.test.mjs > "$tree/tests/ops/readiness-schema-missing.test.mjs"
ln -s "$REPO/node_modules" "$tree/node_modules"; ln -s "$REPO/.runtime" "$tree/.runtime"; ln -s "$REPO/.env" "$tree/.env"
(cd "$tree" && sha256sum src/controllers/HealthController.cfc tools/runtime/acf-up.sh tests/ops/readiness-schema-missing.test.mjs)
echo "containers before: $(docker ps -a --format '{{.Names}}:{{.Status}}' | tr '\n' ' ')"

watch() {
  local seen="" first="" dumped=""
  for i in $(seq 1 150); do
    sleep 10
    local ts; ts=$(date -u +%H:%M:%S)
    if docker ps --format '{{.Names}}' | grep -qx "$C"; then
      [ -n "$seen" ] || { seen=$(date +%s); echo "$ts container $C is running"; }
      local r; r=$(curl -sS -o /dev/null -w '%{http_code} in %{time_total}s' --max-time 10 "http://127.0.0.1:8500/index.cfm/api/health" 2>&1 || true)
      echo "$ts health: $r"
      case "$r" in 200*|503*) [ -n "$first" ] || first="$ts";; esac
      if [ -z "$first" ] && [ -z "$dumped" ] && [ $(( $(date +%s) - seen )) -ge 180 ]; then
        dumped=1
        echo "$ts no answer for three minutes: recording the container's state"
        docker logs --tail 150 "$C" > "$OUT/docker-logs.txt" 2>&1
        docker exec "$C" sh -c 'ps -eo pid,etime,args | cut -c1-200' > "$OUT/ps.txt" 2>&1
        docker exec "$C" sh -c 'ls -la /opt/coldfusion/cfusion/logs; for f in coldfusion-out.log coldfusion-error.log exception.log application.log server.log; do echo "=== $f"; tail -n 120 /opt/coldfusion/cfusion/logs/$f 2>/dev/null; done' > "$OUT/cf-logs.txt" 2>&1
        docker exec "$C" sh -c 'grep -c docBase=\"/icfwalk/app\" /opt/coldfusion/cfusion/runtime/conf/server.xml; ls -la /icfwalk | head -40; ls -la /opt/icfwalk-env' > "$OUT/site.txt" 2>&1
        pid=$(docker exec "$C" sh -c "pgrep -f 'coldfusion.bootstrap' | head -1" 2>/dev/null)
        if [ -n "$pid" ]; then docker exec "$C" sh -c "kill -3 $pid"; sleep 3; docker exec "$C" sh -c 'tail -n 2500 /opt/coldfusion/cfusion/logs/coldfusion-out.log' > "$OUT/thread-dump.txt" 2>&1; fi
      fi
    else
      echo "$ts no container $C"
      [ -n "$seen" ] && return 0
    fi
  done
}
watch > "$OUT/watch.txt" 2>&1 &
W=$!
echo "\$ ICFWALK_READINESS_ENGINE=acf ICFWALK_ACF_IMAGE=<pinned> ICFWALK_REQUIRE_APP=1 ICFWALK_EVIDENCE_DIR=<out> node --test tests/ops/readiness-schema-missing.test.mjs   (in that tree)"
(cd "$tree" && env ICFWALK_READINESS_ENGINE=acf ICFWALK_ACF_IMAGE="$ACF_IMAGE" ICFWALK_REQUIRE_APP=1 ICFWALK_EVIDENCE_DIR="$OUT" node --test tests/ops/readiness-schema-missing.test.mjs > "$OUT/red.tap" 2>&1)
RC=$?
kill "$W" 2>/dev/null; wait "$W" 2>/dev/null
grep -E "^(ok|not ok) |^# (tests|pass|fail) |^  error: |^# (Started|Administrator|Health|The application)" "$OUT/red.tap" | cut -c1-240
echo "[exit $RC]"
if [ "$RC" != 0 ] && grep -q "health answered 200 before the ICFWalk schema exists" "$OUT/red.tap"; then echo "LIVE RED as required"; else echo "LIVE RED NOT OBSERVED"; fi
rm -rf "$tree"
echo "containers after: $(docker ps -a --format '{{.Names}}:{{.Status}}' | tr '\n' ' ')"
