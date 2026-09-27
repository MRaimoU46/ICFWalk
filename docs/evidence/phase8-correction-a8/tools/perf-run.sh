#!/usr/bin/env bash
# One run of tests/perf/workload.mjs against the perf engine, with the code identity stamped on it.
# usage: perf-run.sh <out dir> <edits: any|drafts> <levels> [engine: lucee|acf]
set -uo pipefail
REPO=/home/user/ICFWalk
OUT="$1"; EDIT="$2"; LEVELS="$3"; ENGINE="${4:-lucee}"
SP=/tmp/claude-0/-home-user-ICFWalk/a404c4d2-07c0-5fa4-b380-b1493028718c/scratchpad
mkdir -p "$OUT"
cd "$REPO"
echo "# A8-03 workload run: engine=$ENGINE edits=$EDIT levels=$LEVELS duration=60s solo=5, $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "# workload harness: HEAD $(git rev-parse HEAD) tree $(git rev-parse 'HEAD^{tree}'); sha256 $(sha256sum tests/perf/workload.mjs | cut -d' ' -f1) tests/perf/workload.mjs"
S=$(git status --porcelain=v1 --untracked-files=all); echo "# status: ${S:-<clean>}" | sed '2,$s/^/#   /'
if [ "$ENGINE" = lucee ]; then
  BASE=http://127.0.0.1:8889
  EXTRA=(PERF_ENGINE_PID="$(cat $SP/perf/lucee/lucee.pid)" PERF_LOG_FILE="$SP/perf/lucee/lucee-server/lucee-server/context/logs/icfwalk.log")
  echo "# engine: perf Lucee pid $(cat $SP/perf/lucee/lucee.pid) serving $SP/perf/lucee/tree"
else
  BASE=http://127.0.0.1:8500
  EXTRA=(PERF_ENGINE_CONTAINER="${ICFWALK_PERF_ACF_CONTAINER:-icfwalk-acf}")
  echo "# engine: ColdFusion container ${ICFWALK_PERF_ACF_CONTAINER:-icfwalk-acf}"
fi
echo "# other engines answering: 8888=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:8888/index.cfm/api/health) 8889=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:8889/index.cfm/api/health) 8500=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:8500/index.cfm/api/health)"
echo "\$ ICFWALK_DB_NAME=icfwalk_perf ICFWALK_BASE_URL=$BASE PERF_LEVELS=$LEVELS PERF_DURATION=60 PERF_EDIT=$EDIT ${EXTRA[*]} ICFWALK_EVIDENCE_DIR=<out> node tests/perf/workload.mjs"
env ICFWALK_DB_NAME=icfwalk_perf ICFWALK_BASE_URL=$BASE PERF_LEVELS=$LEVELS PERF_DURATION=60 PERF_EDIT=$EDIT "${EXTRA[@]}" ICFWALK_EVIDENCE_DIR="$OUT" node tests/perf/workload.mjs 2>&1 | grep -v -E 'DEP0123|trace-deprecation'
RC=${PIPESTATUS[0]}
echo "[exit $RC]"
exit $RC
