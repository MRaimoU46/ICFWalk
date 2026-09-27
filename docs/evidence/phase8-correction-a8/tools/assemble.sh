#!/usr/bin/env bash
# Assembles the staged correction evidence (docs/evidence/phase8-correction-a8/) from the session's raw
# outputs. What it changes on the way, and only this: query plans are kept for two runs only, with every
# compiled or runtime parameter value replaced by "(removed)" (a plan records the values it was compiled
# with, and one had compiled a synthetic note's text); the actorUserId of raw log lines is dropped; nothing
# else is edited.
set -euo pipefail
SP=/tmp/claude-0/-home-user-ICFWalk/a404c4d2-07c0-5fa4-b380-b1493028718c/scratchpad
E=$SP/evidence
A=$SP/a8
mkdir -p "$A"
# Only what this script generates is cleared; the tools authored in $A/tools stay.
rm -rf "$A/00-starting-state" "$A/a8-01" "$A/a8-03" "$A/targeted-green-coldfusion.txt"
scrub_plans() { # scrub_plans <src plans dir> <dest plans dir>
  mkdir -p "$2"
  for f in "$1"/*.sqlplan; do sed -E 's/(Parameter(Compiled|Runtime)Value)="[^"]*"/\1="(removed)"/g' "$f" > "$2/$(basename "$f")"; done
}
strip_actor() { sed -E 's/"actorUserId":"[^"]*",//g' "$1" > "$2"; }
copy_run() { # copy_run <src run dir> <dest dir> [keep plans: yes|no]
  local s="$1" d="$2"
  mkdir -p "$d"
  cp "$s"/workload-*.json "$d/"
  [ -f "$s/workload.txt" ] && cp "$s/workload.txt" "$d/"
  [ -f "$s/log-events-during-run.txt" ] && strip_actor "$s/log-events-during-run.txt" "$d/log-events-during-run.txt"
  mkdir -p "$d/deadlocks"
  [ -f "$s/deadlocks.txt" ] && cp "$s/deadlocks.txt" "$d/deadlocks/deadlocks.txt"
  if [ -d "$s/deadlocks" ] && ls "$s/deadlocks"/deadlock-*.xml >/dev/null 2>&1; then
    cp "$s/deadlocks"/deadlock-*.xml "$d/deadlocks/"
    node "$A/tools/summarize-deadlocks.mjs" "$d/deadlocks" > "$d/deadlocks/summary.json"
  fi
  if [ "${3:-no}" = yes ] && [ -d "$s/plans" ]; then scrub_plans "$s/plans" "$d/plans"; fi
}

# 0. Starting state
mkdir -p "$A/00-starting-state"
cp "$SP/preedit.sh" "$A/00-starting-state/preedit.sh"
cp "$E/00-starting-state-and-fast-forward.txt" "$A/00-starting-state/starting-state-and-fast-forward.txt"

# A8-01: red and green of the focused regression
mkdir -p "$A/a8-01"
cp "$E/a8-01-red-lucee.txt" "$A/a8-01/red-HealthReadinessTest-lucee.txt"
cp "$E/a8-01-green-lucee.txt" "$A/a8-01/green-HealthReadinessTest-LongTextRetrievalTest-lucee.txt"

# Both findings' targeted green on ColdFusion
cp "$E/a8-green-acf-targeted.txt" "$A/targeted-green-coldfusion.txt"

# A8-03: red, the attempts that were not red, green
mkdir -p "$A/a8-03/regression"
cp "$E/a8-03-red-lucee.txt" "$A/a8-03/regression/red-ReportDeadlockVictimTest-lucee.txt"
cp "$E/a8-03-red-attempt1-NOT-RED-spec-did-not-compile-on-lucee.txt" "$A/a8-03/regression/not-red-1-spec-did-not-compile-on-lucee.txt"
cp "$E/a8-03-red-attempt2-NOT-RED-spec-did-not-compile-on-lucee.txt" "$A/a8-03/regression/not-red-2-spec-did-not-compile-on-lucee.txt"
cp "$E/a8-03-red-attempt3-NOT-RED-fixture-closure-returned-nothing.txt" "$A/a8-03/regression/not-red-3-fixture-closure-returned-nothing.txt"
cp "$E/a8-03-green-lucee.txt" "$A/a8-03/regression/green-ReportDeadlockVictimTest-and-report-specs-lucee.txt"

# A8-03: reproduction on the uncorrected report code (working tree before the correction commit)
R="$A/a8-03/reproduction-before-the-correction"
mkdir -p "$R/seed"
cp "$E/a8-03/perf-environment.txt" "$R/perf-environment.txt"
cp "$E/a8-03/seed/seed.json" "$E/a8-03/seed/seed-transcript.txt" "$R/seed/"
for n in 1 2 3; do
  mkdir -p "$R/attempt$n"
  cp "$E/a8-03/lucee-drafts-attempt$n.txt" "$R/attempt$n/workload.txt"
  cp "$E/a8-03/lucee-drafts-attempt$n"/workload-*.json "$R/attempt$n/"
done
scrub_plans "$E/a8-03/lucee-drafts-attempt1/plans" "$R/attempt1/plans"
scrub_plans "$E/a8-03/lucee-drafts-attempt2/plans" "$R/attempt2/plans"
mkdir -p "$R/attempt2/deadlocks"
cp "$SP/deadlocks/series-a"/deadlock-*.xml "$R/attempt2/deadlocks/"
cp "$SP/deadlocks/series-a/statements.json" "$R/attempt2/deadlocks/statements.json"
node "$A/tools/summarize-deadlocks.mjs" "$R/attempt2/deadlocks" > "$R/attempt2/deadlocks/summary.json"
node "$A/tools/correlate.mjs" "$R/attempt2"/workload-*.json "$R/attempt2/deadlocks" > "$R/attempt2/correlation.md"

for n in 1 3; do mkdir -p "$R/attempt$n/deadlocks"; cp "$E/a8-03/lucee-drafts-attempt$n"/deadlocks/deadlock-*.xml "$R/attempt$n/deadlocks/" 2>/dev/null || true; done
# SQL Server's own record of every deadlock of the session (system_health), taken before the gate
# replaced the container: the workload's and the ones ReportDeadlockVictimTest forced.
mkdir -p "$A/a8-03/sql-server-deadlock-record"
cp "$E/a8-03/sql-server-deadlock-record"/* "$A/a8-03/sql-server-deadlock-record/"

# A8-03: the check on the corrected working tree before the commit (identical code: see its header)
P="$A/a8-03/pre-commit-check-on-the-corrected-tree"
mkdir -p "$P"
cp "$SP/trial/lucee-drafts-fixed-precommit.txt" "$P/workload.txt"
cp "$SP/trial/lucee-drafts-fixed-precommit"/workload-*.json "$P/"
mkdir -p "$P/deadlocks"; cp "$SP/trial/lucee-drafts-fixed-precommit"/deadlocks/deadlock-*.xml "$P/deadlocks/" 2>/dev/null || true

# A8-03: the final runs on the correction code commit
F="$A/a8-03/on-the-correction-commit"
mkdir -p "$F"
cp "$E/a8-03/perf-engine-start-on-commit.txt" "$F/lucee-engine-start.txt"
cp "$E/a8-03/perf-engine-restart-after-reboot.txt" "$F/lucee-engine-restart-after-the-host-reboot.txt"
cp "$E/a8-03/acf-perf-engine.txt" "$F/coldfusion-engine-start.txt"
for s in lucee-fixed:lucee-drafts lucee-any-fixed:lucee-any acf-drafts-fixed:coldfusion-drafts acf-any-fixed:coldfusion-any; do
  src="$E/a8-03/series-${s%%:*}"; dst="$F/${s#*:}"
  [ -d "$src" ] || continue
  mkdir -p "$dst"; cp "$src/series.txt" "$dst/series.txt"
  for r in "$src"/run*; do copy_run "$r" "$dst/$(basename "$r")" no; done
done

# The runs whose graphs were not saved with them: counted from SQL Server's saved record, by window.
node "$A/tools/window-graphs.mjs" "$A/a8-03/sql-server-deadlock-record" \
  "$R/attempt1=2026-09-27T01:08:02=2026-09-27T01:10:39" "$R/attempt2=2026-09-27T01:13:53=2026-09-27T01:16:16" \
  "$R/attempt3=2026-09-27T01:16:16=2026-09-27T01:18:42" "$P=2026-09-27T01:36:00=2026-09-27T01:38:50"

# Tools
mkdir -p "$A/tools"
cp "$SP/tools/cfml-targeted.mjs" "$SP/tools/perf-lucee.sh" "$SP/tools/perf-run.sh" "$SP/tools/perf-series.sh" "$SP/tools/deadlocks.mjs" "$A/tools/"
cp "$SP/assemble.sh" "$A/tools/assemble.sh"
echo "assembled $(find "$A" -type f | wc -l) files, $(du -sh "$A" | cut -f1)"
