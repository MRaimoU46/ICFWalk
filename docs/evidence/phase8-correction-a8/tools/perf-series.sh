#!/usr/bin/env bash
# A8-03 final performance series on the exact correction code commit: N runs of the drafts-only
# workload (levels 10,25; 60 s; solo 5), each with the deadlocks SQL Server recorded during it and the
# report.deadlock.victim events the application logged during it. The count N is fixed before the first
# run and every run is reported.
# usage: perf-series.sh <expected HEAD> <out dir> <runs> <engine: lucee|acf> [edits: drafts|any] [levels]
set -uo pipefail
REPO=/home/user/ICFWalk
SP=/tmp/claude-0/-home-user-ICFWalk/a404c4d2-07c0-5fa4-b380-b1493028718c/scratchpad
EXPECTED="$1"; OUT="$2"; RUNS="$3"; ENGINE="$4"; EDIT="${5:-drafts}"; LEVELS="${6:-10,25}"
cd "$REPO"
[ "$(git rev-parse HEAD)" = "$EXPECTED" ] || { echo "HEAD is not $EXPECTED"; exit 1; }
[ -z "$(git status --porcelain=v1 --untracked-files=all)" ] || { echo "the tree is not clean"; exit 1; }
echo "# A8-03 series: $RUNS run(s), engine=$ENGINE edits=$EDIT levels=$LEVELS, HEAD $(git rev-parse HEAD) tree $(git rev-parse 'HEAD^{tree}'), clean, $(date -u +%Y-%m-%dT%H:%M:%SZ)"
logtext() { if [ "$ENGINE" = lucee ]; then cat "$SP/perf/lucee/lucee-server/lucee-server/context/logs/"icfwalk*.log 2>/dev/null; else docker exec "${ICFWALK_PERF_ACF_CONTAINER:-icfwalk-acf-perf}" sh -c 'cat /opt/coldfusion/cfusion/logs/icfwalk*.log 2>/dev/null' ; fi; }
for n in $(seq 1 "$RUNS"); do
  R="$OUT/run$n"; mkdir -p "$R"
  L0=$(logtext | wc -l); T0=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
  ICFWALK_PERF_ACF_CONTAINER="${ICFWALK_PERF_ACF_CONTAINER:-icfwalk-acf-perf}" "$SP/tools/perf-run.sh" "$R" "$EDIT" "$LEVELS" "$ENGINE" > "$R/workload.txt" 2>&1; RC=$?
  T1=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
  logtext | tail -n +"$((L0 + 1))" | grep -E 'report\.deadlock\.victim|report\.population\.changed|request\.failed' | sed -e 's/""/"/g' > "$R/log-events-during-run.txt"
  node "$SP/tools/deadlocks.mjs" "$R/deadlocks" "$T0" > "$R/deadlocks.txt" 2>&1
  J=$(ls "$R"/workload-*.json 2>/dev/null | head -1)
  SUMMARY=$(node -e '
    const r=require(process.argv[1]); const t=r.failureTotals||{};
    const lv=r.levels.map(l=>`L${l.concurrency}: ${l.requests} req, live ${l.operations["report live district"]?.count??0} p50 ${l.operations["report live district"]?.p50??"-"} ms, csv ${l.operations["report CSV district"]?.count??0}`).join("; ");
    console.log(`expected409=${t.expectedRefusals??"?"} unexpected=${t.unexpected??"?"} ${JSON.stringify(t.unexpectedByKind||{})} | ${lv}`);' "$J" 2>/dev/null || echo "no JSON")
  echo "run $n: exit $RC, $T0 .. $T1 | $SUMMARY | deadlock graphs: $(head -1 "$R/deadlocks.txt" | cut -d' ' -f1) | report.deadlock.victim logged: $(grep -c 'report.deadlock.victim' "$R/log-events-during-run.txt") | request.failed logged: $(grep -c 'request.failed' "$R/log-events-during-run.txt")"
done
echo "# series finished $(date -u +%Y-%m-%dT%H:%M:%SZ); HEAD $(git rev-parse HEAD); status: $(git status --porcelain=v1 --untracked-files=all | wc -l) changes"
