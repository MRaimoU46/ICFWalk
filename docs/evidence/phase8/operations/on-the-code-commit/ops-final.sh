#!/usr/bin/env bash
# Phase 8: the operations scenarios, run separately on the exact code commit after the final gate.
# Each writes its TAP and its JSON record into OUT. The tree must be clean and at the code commit.
#
# usage: ops-final.sh <code commit> <output directory outside the repository>
set -uo pipefail
REPO=/home/user/ICFWalk
EXPECTED="$1"; OUT="$2"
ACF_IMAGE=adobecoldfusion/coldfusion2023@sha256:e42bbf07745ebd4d8c23d6679738ac13e264218618093bc3689ebfaf8966f30e
cd "$REPO"
step() { echo; echo "== $(date -u +%Y-%m-%dT%H:%M:%SZ)  $*"; }
[ "$(git rev-parse HEAD)" = "$EXPECTED" ] || { echo "HEAD is not $EXPECTED"; exit 1; }
[ -z "$(git status --porcelain=v1 --untracked-files=all)" ] || { echo "the tree is not clean"; exit 1; }
mkdir -p "$OUT"
echo "HEAD $(git rev-parse HEAD) tree $(git rev-parse 'HEAD^{tree}'), clean"
RESULT=0
run() { # run <label> <env...> -- <test file>
  local label="$1"; shift
  local envs=(); while [ "$1" != "--" ]; do envs+=("$1"); shift; done; shift
  step "$label"
  mkdir -p "$OUT/$label"
  env "${envs[@]}" ICFWALK_REQUIRE_APP=1 ICFWALK_EVIDENCE_DIR="$OUT/$label" node --test "$@" > "$OUT/$label/$label.tap" 2>&1
  local rc=$?
  grep -E "^(ok|not ok) |^# (tests|pass|fail|skipped|todo|cancelled) " "$OUT/$label/$label.tap"
  echo "[exit $rc]"; [ $rc = 0 ] || RESULT=1
}
# 1. ColdFusion is up from the gate on its own database: restart during autosave there.
curl -sS http://127.0.0.1:8500/index.cfm/api/health; echo
run restart-coldfusion ICFWALK_BASE_URL=http://127.0.0.1:8500 ICFWALK_DB_NAME=icfwalk_acf_gate -- tests/ops/restart-during-autosave.test.mjs
# 2. The production profile on ColdFusion needs port 8500: the gate's container goes.
tools/runtime/acf-down.sh
run production-profile-coldfusion ICFWALK_PROD_PROFILE_ENGINE=acf ICFWALK_ACF_IMAGE=$ACF_IMAGE -- tests/ops/production-profile.test.mjs
# 3. Lucee on the gate's database: restart during autosave, then its own production profile.
tools/runtime/lucee-up.sh > "$OUT/lucee-up.txt" 2>&1; tail -1 "$OUT/lucee-up.txt"
run restart-lucee ICFWALK_BASE_URL=http://127.0.0.1:8888 -- tests/ops/restart-during-autosave.test.mjs
run production-profile-lucee ICFWALK_PROD_PROFILE_ENGINE=lucee -- tests/ops/production-profile.test.mjs
# 4. Upgrade from the Phase 6 release through 007, this release, and rollback to the frozen one.
run upgrade-and-rollback ICFWALK_DB_NAME=icfwalk_dev -- tests/ops/upgrade-and-rollback.test.mjs
# 5. Backup and restore of the gate's Lucee database, and the killed and refused migrations.
tools/runtime/lucee-down.sh
run database-operations ICFWALK_DB_NAME=icfwalk_dev -- tests/ops/database-operations.test.mjs
step "identity after"
git rev-parse HEAD; S=$(git status --porcelain=v1 --untracked-files=all); echo "status: ${S:-<clean>}"
[ -z "$S" ] || RESULT=1
echo; [ $RESULT = 0 ] && echo "OPERATIONS PASSED on $EXPECTED" || echo "OPERATIONS FAILED on $EXPECTED"
exit $RESULT
