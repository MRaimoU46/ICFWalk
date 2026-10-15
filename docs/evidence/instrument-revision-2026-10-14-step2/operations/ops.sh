#!/usr/bin/env bash
# Instrument revision 2026-10-14, step 2: the operations scenarios, run on step 2's code commit after its
# gate, as Phase 8 correction A8 ran them on its code commit
# (docs/evidence/phase8-correction-a8/operations-b73f.../ops.sh), without A8's live red of its own
# correction:
#
#   restart during autosave (ColdFusion, Lucee), the production profile (ColdFusion, Lucee), the readiness
#   probe (ColdFusion, Lucee: since step 2 it also answers `outdated` without migration 008, and 200 once
#   it is applied), upgrade and rollback (since step 2: 008 on a Phase 6 installation, and the release
#   before step 2 on walks that hold several values of a field), and the database operations (backup and
#   restore, the killed and the refused migration, 008 among them).
#
# At the end the normal verification environment is put back and checked: Lucee on the gate's database
# (8888) and ColdFusion on the gate's ColdFusion database (8500) both answer 200, and no temporary database
# of these operations is left. Each scenario writes its TAP and its JSON record into OUT.
#
# usage: ops.sh <code commit> <output directory outside the repository>
set -uo pipefail
REPO=/home/user/ICFWalk
EXPECTED="$1"; OUT="$2"
ACF_IMAGE=adobecoldfusion/coldfusion2023@sha256:e42bbf07745ebd4d8c23d6679738ac13e264218618093bc3689ebfaf8966f30e
ACF_DB=icfwalk_acf_gate
NO_PROXY_ENV=(-u HTTPS_PROXY -u HTTP_PROXY -u https_proxy -u http_proxy -u ALL_PROXY -u all_proxy)
cd "$REPO"
step() { echo; echo "== $(date -u +%Y-%m-%dT%H:%M:%SZ)  $*"; }
echo "== $(date -u +%Y-%m-%dT%H:%M:%SZ)  the script"; cat "$0"
[ "$(git rev-parse HEAD)" = "$EXPECTED" ] || { echo "HEAD is not $EXPECTED"; exit 1; }
[ -z "$(git status --porcelain=v1 --untracked-files=all)" ] || { echo "the tree is not clean"; exit 1; }
mkdir -p "$OUT"
step "identity before"
echo "HEAD $(git rev-parse HEAD) tree $(git rev-parse 'HEAD^{tree}'), clean"
RESULT=0
run() { # run <label> <env...> -- <test file>
  local label="$1"; shift
  local envs=(); while [ "$1" != "--" ]; do envs+=("$1"); shift; done; shift
  step "$label"
  mkdir -p "$OUT/$label"
  echo "\$ ${envs[*]} ICFWALK_REQUIRE_APP=1 ICFWALK_EVIDENCE_DIR=<out> node --test $*"
  env "${NO_PROXY_ENV[@]}" "${envs[@]}" ICFWALK_REQUIRE_APP=1 ICFWALK_EVIDENCE_DIR="$OUT/$label" ICFWALK_SCREENSHOT_DIR="$OUT/$label/shots" node --test "$@" > "$OUT/$label/$label.tap" 2>&1
  local rc=$?
  rm -rf "$OUT/$label/shots"
  grep -E "^(ok|not ok) |^# (tests|pass|fail|skipped|todo|cancelled) |^# engine " "$OUT/$label/$label.tap"
  echo "[exit $rc]"; [ $rc = 0 ] || RESULT=1
}

# 1. ColdFusion is up from the gate on its own database: restart during autosave there.
step "ColdFusion from the gate"
curl -sS http://127.0.0.1:8500/index.cfm/api/health; echo
run restart-coldfusion ICFWALK_BASE_URL=http://127.0.0.1:8500 ICFWALK_DB_NAME=$ACF_DB -- tests/ops/restart-during-autosave.test.mjs
# 2. The production profile and the readiness probe on ColdFusion need port 8500: the gate's container goes.
tools/runtime/acf-down.sh
run production-profile-coldfusion ICFWALK_PROD_PROFILE_ENGINE=acf ICFWALK_ACF_IMAGE=$ACF_IMAGE -- tests/ops/production-profile.test.mjs
run readiness-coldfusion ICFWALK_READINESS_ENGINE=acf ICFWALK_ACF_IMAGE=$ACF_IMAGE -- tests/ops/readiness-schema-missing.test.mjs
# 3. Lucee on the gate's database: restart during autosave, its own production profile, the readiness probe.
step "Lucee on the gate's database"
tools/runtime/lucee-up.sh > "$OUT/lucee-up.txt" 2>&1; tail -1 "$OUT/lucee-up.txt"
run restart-lucee ICFWALK_BASE_URL=http://127.0.0.1:8888 -- tests/ops/restart-during-autosave.test.mjs
run production-profile-lucee ICFWALK_PROD_PROFILE_ENGINE=lucee -- tests/ops/production-profile.test.mjs
run readiness-lucee ICFWALK_READINESS_ENGINE=lucee -- tests/ops/readiness-schema-missing.test.mjs
# 4. Upgrade from the Phase 6 release through 007 and 008, this release, rollback to the frozen one, and
#    the release before step 2 on walks that hold several values.
run upgrade-and-rollback ICFWALK_DB_NAME=icfwalk_dev -- tests/ops/upgrade-and-rollback.test.mjs
# 5. Backup and restore of the gate's Lucee database, and the killed and refused migrations.
tools/runtime/lucee-down.sh
run database-operations ICFWALK_DB_NAME=icfwalk_dev -- tests/ops/database-operations.test.mjs

# 6. The normal verification environment, put back and checked.
step "the normal verification environment"
tools/runtime/lucee-up.sh > "$OUT/lucee-up-after.txt" 2>&1; tail -1 "$OUT/lucee-up-after.txt"
ICFWALK_DB_NAME=$ACF_DB ICFWALK_ACF_IMAGE=$ACF_IMAGE tools/runtime/acf-up.sh > "$OUT/acf-up-after.txt" 2>&1; tail -1 "$OUT/acf-up-after.txt"
L=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 http://127.0.0.1:8888/index.cfm/api/health); A=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 http://127.0.0.1:8500/index.cfm/api/health)
echo "health: Lucee (8888, icfwalk_dev) $L; ColdFusion (8500, $ACF_DB) $A"
[ "$L" = 200 ] && [ "$A" = 200 ] || RESULT=1
source .runtime/mssql.env
LEFT=$(docker exec icfwalk-mssql /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -b -h -1 -W -Q "SET NOCOUNT ON; SELECT name FROM sys.databases WHERE name LIKE N'icfwalk[_]a801ready%' OR name LIKE N'icfwalk[_]p8prod%' OR name LIKE N'icfwalk[_]p8upg%' OR name LIKE N'icfwalk[_]p8ops%' ORDER BY name; SELECT name FROM sys.server_principals WHERE name LIKE N'a801ready%' OR name LIKE N'p8prod%' ORDER BY name;")
echo "temporary databases and logins left by the operations: ${LEFT:-<none>}"
[ -z "$LEFT" ] || RESULT=1
docker exec icfwalk-mssql /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -b -h -1 -W -Q "SET NOCOUNT ON; SELECT name FROM sys.databases ORDER BY name;"

step "identity after"
git rev-parse HEAD 'HEAD^{tree}'; S=$(git status --porcelain=v1 --untracked-files=all); echo "status: ${S:-<clean>}"
[ -z "$S" ] || RESULT=1
[ "$(git rev-parse HEAD)" = "$EXPECTED" ] || RESULT=1
echo; [ $RESULT = 0 ] && echo "OPERATIONS PASSED on $EXPECTED" || echo "OPERATIONS FAILED on $EXPECTED"
exit $RESULT
