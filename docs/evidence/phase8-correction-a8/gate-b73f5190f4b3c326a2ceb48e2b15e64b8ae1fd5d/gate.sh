#!/usr/bin/env bash
# Phase 8 correction A8: the exact-commit gate, on the correction code commit, from a clean tree, on
# brand-new databases, on both engines.
#
# HEAD must be the correction code commit: its parent the audited Phase 8 handoff tip, and the tested
# Phase 8 code commit, the Phase 0-7 freeze tip and the frozen code commit among its ancestors, the tree
# clean. The branch is not pushed before this gate: the owner's rules push only after the gate and the
# operations pass, so the remote branch is recorded here, not compared; the audited Phase 8 branch and
# the frozen branches are compared and must be unchanged.
#
# The steps are the Phase 8 final gate's (docs/evidence/phase8/gate-282a4ec.../gate.sh): npm ci,
# handoff validation and package tests, every JavaScript file parsed, a brand-new SQL Server container
# pinned to the same digest, migrations 001 to 007 with every re-application and 001 refused, Lucee with
# the seed and the full suite, then Adobe ColdFusion 2023 (pinned) on a brand-new database and container
# with the seed and the full suite (CFML in 12 parts). The baselines move to that gate's results:
#
#   - Node: every one of the 299 test names the Phase 8 gate passed on both engines is present and
#     passes on both engines here, and neither run has fewer than 299 tests.
#   - CFML: every test function of the tested Phase 8 code's specs (534) still exists; the suites run
#     exactly 534 plus the test functions this correction adds (counted from the tree, listed by name),
#     on both engines, with none failed or skipped.
#
# It writes nothing into the repository: TAP copies and screenshots go to OUT, outside it. It rewrites the
# git-ignored .env's ICFWALK_DB_PASSWORD with the new container's generated password (never printed).
# Every command is echoed with its exit code. It stops on the first unexpected result.
#
# usage: gate.sh <expected HEAD sha> <output directory outside the repository>
set -uo pipefail
REPO=/home/user/ICFWalk
BRANCH=claude/icfwalk-phase-8-correction-cgsc7q
AUDITED_TIP=10f476ba9a69359f23a259be0e903afeed64b415   # the audited Phase 8 handoff (records) tip
P8_BRANCH=claude/icfwalk-phase-8-hardening-handoff
P8_CODE=282a4ec27cd5d200ed190b134c0145632a970cee       # the tested Phase 8 code commit
FREEZE_TIP=133f02192a99970029847bc2da2d31b9d8da06e1    # the Phase 0-7 records-only freeze tip
FROZEN_CODE=68f9026d39ba0ff44d12d6398c5e933971dad2f4   # the frozen Phase 0-7 code
INTEGRATION=claude/icfwalk-phase-6-7-integration
P6_BRANCH=claude/icfwalk-phase-6-admin-audit-corrections; P6_TIP=64507deb075e267761179d78be966b7a4d3972cc
P7_BRANCH=claude/icfwalk-phase-7-correction-n62s25;      P7_TIP=e0342143074f727475ae2d4cb6933fa279902f85
MSSQL_IMAGE=mcr.microsoft.com/mssql/server@sha256:4402d880dd4c34bfa7d8705e56a86cd6c88da80a1f6bbbe741f999e76264a090
ACF_IMAGE=adobecoldfusion/coldfusion2023@sha256:e42bbf07745ebd4d8c23d6679738ac13e264218618093bc3689ebfaf8966f30e
P8_GATE=docs/evidence/phase8/gate-282a4ec27cd5d200ed190b134c0145632a970cee
BASE_NODE=299
BASE_CFML=534
CODE_PATHS="src app tests scripts tools database config package.json package-lock.json manifest.json .env.example"
ACF_DB=icfwalk_acf_gate
EXPECTED="$1"
OUT="$2"
cd "$REPO"

step() { echo; echo "================================================================================"; echo "== $(date -u +%Y-%m-%dT%H:%M:%SZ)  $*"; echo "================================================================================"; }
run() { echo "\$ $*"; "$@"; local rc=$?; echo "[exit $rc]"; return $rc; }
die() { echo; echo "GATE FAILED: $*"; exit 1; }
totals() { # totals <tap> <label>: prints the Node and CFML totals and sets N_* and C_*
  local tap="$1"
  N_TESTS=$(grep -E '^# tests ' "$tap" | tail -1 | awk '{print $3}'); N_PASS=$(grep -E '^# pass ' "$tap" | tail -1 | awk '{print $3}')
  N_FAIL=$(grep -E '^# fail ' "$tap" | tail -1 | awk '{print $3}'); N_SKIP=$(grep -E '^# skipped ' "$tap" | tail -1 | awk '{print $3}')
  N_TODO=$(grep -E '^# todo ' "$tap" | tail -1 | awk '{print $3}'); N_CANC=$(grep -E '^# cancelled ' "$tap" | tail -1 | awk '{print $3}')
  C_LINE=$(grep -E '^# engine=' "$tap" | tail -1)
  C_PASS=$(echo "$C_LINE" | grep -o 'passed=[0-9]*' | cut -d= -f2); C_FAIL=$(echo "$C_LINE" | grep -o 'failed=[0-9]*' | cut -d= -f2)
  C_SKIP=$(echo "$C_LINE" | grep -o 'skipped=[0-9]*' | cut -d= -f2)
  echo "$2 node: tests=$N_TESTS pass=$N_PASS fail=$N_FAIL skipped=$N_SKIP todo=$N_TODO cancelled=$N_CANC"
  echo "$2 cfml: ${C_LINE:-<no totals line>}"
  grep -E '^not ok ' "$tap" || echo "$2: no failed Node test"
}
clean() { [ "$1" = 0 ] && [ "$N_FAIL" = 0 ] && [ "$N_SKIP" = 0 ] && [ "$N_TODO" = 0 ] && [ "$N_CANC" = 0 ] && [ "$N_TESTS" = "$N_PASS" ] && [ "${C_FAIL:-x}" = 0 ] && [ "${C_SKIP:-x}" = 0 ]; }

step "0. The gate script itself"
cat "$0"

step "1. Repository identity before the gate"
run date -u
BR=$(git rev-parse --abbrev-ref HEAD); echo "branch $BR"
[ "$BR" = "$BRANCH" ] || die "not on $BRANCH"
HEAD_SHA=$(git rev-parse HEAD); TREE_SHA=$(git rev-parse 'HEAD^{tree}')
echo "HEAD   $HEAD_SHA"; echo "TREE   $TREE_SHA"
[ "$HEAD_SHA" = "$EXPECTED" ] || die "HEAD $HEAD_SHA is not the expected commit $EXPECTED"
run git log -3 --format='%H %T %P %an %aI %s'
PARENT=$(git rev-parse HEAD^); echo "parent $PARENT"
[ "$PARENT" = "$AUDITED_TIP" ] && echo "the parent is the audited Phase 8 handoff tip" || die "the parent is not $AUDITED_TIP"
for c in "$AUDITED_TIP" "$P8_CODE" "$FREEZE_TIP" "$FROZEN_CODE"; do
  git merge-base --is-ancestor "$c" HEAD && echo "$c is an ancestor of HEAD" || die "$c is not an ancestor of HEAD"
done
echo "\$ git diff --name-status $AUDITED_TIP HEAD   (the whole correction: every file it changes)"
git diff --name-status "$AUDITED_TIP" HEAD
echo "\$ git diff --stat $P8_CODE HEAD -- $CODE_PATHS   (code, tests and tools against the tested Phase 8 code)"
git diff --stat "$P8_CODE" HEAD -- $CODE_PATHS
echo "\$ git diff --name-only $P8_CODE HEAD -- database config package.json package-lock.json .env.example   (must be empty: no migration, configuration or dependency changes)"
D=$(git diff --name-only "$P8_CODE" HEAD -- database config package.json package-lock.json .env.example); echo "${D:-<empty>}"
[ -z "$D" ] || die "a migration, the configuration or a dependency changed"
echo "\$ git status --porcelain=v1 --untracked-files=all  (tracked, staged, unstaged and untracked)"
STATUS=$(git status --porcelain=v1 --untracked-files=all); echo "${STATUS:-<empty>}"
[ -z "$STATUS" ] || die "working tree is not clean"
echo "\$ git ls-remote origin refs/heads/$BRANCH   (recorded only: pushed after the gate and the operations)"
R=$(git ls-remote origin "refs/heads/$BRANCH" | cut -f1); echo "${R:-<no such branch on origin>}"
echo "--- the audited Phase 8 branch, the frozen integration branch and both source branches are unchanged"
for pair in "$P8_BRANCH=$AUDITED_TIP" "$INTEGRATION=$FREEZE_TIP" "$P6_BRANCH=$P6_TIP" "$P7_BRANCH=$P7_TIP"; do
  B=${pair%%=*}; W=${pair#*=}; R=$(git ls-remote origin "refs/heads/$B" | cut -f1)
  echo "$B $R"; [ "$R" = "$W" ] || die "$B is $R, expected $W"
done

step "2. Runtime versions"
run uname -srm
echo "os $(. /etc/os-release; echo "$PRETTY_NAME")"
echo "cpus $(nproc), memory $(free -g | awk '/^Mem:/ {print $2}') GB"
run node --version
run npm --version
java -version 2>&1 | sed -e 's/^Picked up JAVA_TOOL_OPTIONS: .*/Picked up JAVA_TOOL_OPTIONS: [redacted: container proxy and truststore settings]/'
run docker version --format 'docker client {{.Client.Version}} server {{.Server.Version}}'

step "3. Dependencies from the lock file"
run npm ci || die "npm ci failed"
STATUS=$(git status --porcelain=v1 --untracked-files=all); echo "status after npm ci: ${STATUS:-<empty>}"
[ -z "$STATUS" ] || die "npm ci changed the tree"
run node -e 'for (const p of ["playwright","playwright-core","mssql","axe-core"]) console.log(p, require("/home/user/ICFWalk/node_modules/"+p+"/package.json").version)'
echo "Chromium $(node -e 'const {chromium}=require("playwright");chromium.launch().then(async b=>{console.log(b.version());await b.close()})')"

step "4. Handoff validation and package tests"
run npm run validate:handoff || die "handoff validation failed"
run npm run test:package || die "package tests failed"

step "5. JavaScript syntax (every tracked .js and .mjs)"
COUNT=0; FAILED=0
for f in $(git ls-files '*.js' '*.mjs'); do COUNT=$((COUNT+1)); if node --check "$f" 2>&1; then :; else echo "SYNTAX ERROR $f"; FAILED=$((FAILED+1)); fi; done
echo "checked $COUNT files, $FAILED syntax errors"
[ "$FAILED" = 0 ] || die "syntax errors"

step "6. No CFML test was removed: every test function of the tested Phase 8 code's specs exists at HEAD"
# Files, not pipes: under pipefail, `git show | grep -q` fails when grep stops reading early.
SPECS_TMP=$(mktemp -d)
MISSING=0; FUNCS=0; HEAD_FUNCS=0
for f in $(git ls-tree -r --name-only "$P8_CODE" tests/cfml/specs | grep '\.cfc$'); do
  git show "$P8_CODE:$f" > "$SPECS_TMP/base.cfc"
  git show "HEAD:$f" > "$SPECS_TMP/head.cfc" 2>/dev/null || : > "$SPECS_TMP/head.cfc"
  for fn in $(grep -oE 'function test[A-Za-z0-9_]+' "$SPECS_TMP/base.cfc" | awk '{print $2}'); do
    FUNCS=$((FUNCS+1))
    grep -qE "function $fn\(" "$SPECS_TMP/head.cfc" || { echo "MISSING $f $fn"; MISSING=$((MISSING+1)); }
  done
done
echo "--- test functions this correction adds (at HEAD, not in $P8_CODE)"
for f in $(git ls-tree -r --name-only HEAD tests/cfml/specs | grep '\.cfc$'); do
  git show "HEAD:$f" > "$SPECS_TMP/head.cfc"
  git show "$P8_CODE:$f" > "$SPECS_TMP/base.cfc" 2>/dev/null || : > "$SPECS_TMP/base.cfc"
  for fn in $(grep -oE 'function test[A-Za-z0-9_]+' "$SPECS_TMP/head.cfc" | awk '{print $2}'); do
    HEAD_FUNCS=$((HEAD_FUNCS+1))
    grep -qE "function $fn\(" "$SPECS_TMP/base.cfc" || echo "NEW $f $fn"
  done
done
rm -rf "${SPECS_TMP:?}"
NEW_CFML=$((HEAD_FUNCS - FUNCS))
echo "test functions: $P8_CODE $FUNCS; missing at HEAD: $MISSING; HEAD $HEAD_FUNCS (new: $NEW_CFML)"
[ "$MISSING" = 0 ] || die "a CFML test function was removed"
[ "$FUNCS" = "$BASE_CFML" ] || die "the tested Phase 8 code has $FUNCS test functions, not $BASE_CFML"
EXPECT_CFML=$((BASE_CFML + NEW_CFML))
echo "the CFML suites must run exactly $BASE_CFML + $NEW_CFML = $EXPECT_CFML cases on each engine"

step "7. A brand-new SQL Server container and database"
tools/runtime/lucee-down.sh; echo "[lucee-down exit $?]"
tools/runtime/acf-down.sh; echo "[acf-down exit $?]"
run docker rm -f icfwalk-mssql
run rm -f .runtime/mssql.env
echo "\$ ICFWALK_MSSQL_IMAGE=$MSSQL_IMAGE tools/runtime/mssql-up.sh"
ICFWALK_MSSQL_IMAGE="$MSSQL_IMAGE" tools/runtime/mssql-up.sh; RC=$?; echo "[exit $RC]"; [ "$RC" = 0 ] || die "SQL Server did not start"
source .runtime/mssql.env
[ -n "${MSSQL_SA_PASSWORD:-}" ] || die "the new container's password was not generated"
NEWPW="$MSSQL_SA_PASSWORD" node -e 'const fs=require("fs");const pw=process.env.NEWPW;if(!pw)process.exit(1);const t=fs.readFileSync(".env","utf8");if(!/^ICFWALK_DB_PASSWORD=/m.test(t))process.exit(1);fs.writeFileSync(".env",t.replace(/^ICFWALK_DB_PASSWORD=.*$/m,()=>"ICFWALK_DB_PASSWORD="+pw))' || die "could not update .env"
echo "(.env ICFWALK_DB_PASSWORD set to the new container's generated password; not printed)"
run docker ps --filter name=icfwalk-mssql --format '{{.ID}} {{.Image}} {{.Status}} created {{.CreatedAt}}'
run docker inspect --format '{{.Config.Image}} @ {{.Image}}' icfwalk-mssql
SQLCMD=(docker exec icfwalk-mssql /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -b)
"${SQLCMD[@]}" -h -1 -W -Q "SET NOCOUNT ON; SELECT @@VERSION; SELECT name, create_date FROM sys.databases WHERE name LIKE 'icfwalk%'; SELECT COUNT(*) AS tables_in_icfwalk_dev FROM icfwalk_dev.sys.tables;"

step "8. Schema: 001 to 007 in order, then each of 002 to 007 re-applied, and 001 refused"
run node scripts/db/apply-schema.mjs || die "schema application failed"
for n in 002 003 004 005 006 007; do run node scripts/db/apply-schema.mjs --only "$n" || die "re-applying $n failed"; done
echo "\$ node scripts/db/apply-schema.mjs --only 001   (must refuse: the schema already has tables)"
node scripts/db/apply-schema.mjs --only 001; RC=$?; echo "[exit $RC]"
[ "$RC" != 0 ] && echo "001 refused a second application, as designed" || die "001 re-applied"
"${SQLCMD[@]}" -d icfwalk_dev -h -1 -W -Q "SET NOCOUNT ON; SELECT COUNT(*) AS icf_tables FROM sys.tables WHERE schema_id = SCHEMA_ID('icf'); SELECT name FROM sys.triggers ORDER BY name; SELECT migration, step, state FROM icf.schema_migration_state;"

step "9. Lucee: the application on the new database, and the instrument seed"
run tools/runtime/lucee-up.sh || die "the application did not start"
echo "lucee jars:"; sha256sum .runtime/jars/*.jar
run curl -sS http://127.0.0.1:8888/index.cfm/api/health
echo
run node scripts/seed-instrument.mjs || die "seed failed"

step "10. Lucee: the full suite (ICFWALK_REQUIRE_APP=1 npm test: Node, HTTP, Playwright and CFML)"
rm -rf "${OUT:?}"; mkdir -p "$OUT/lucee" "$OUT/acf"
echo "\$ ICFWALK_REQUIRE_APP=1 ICFWALK_SCREENSHOT_DIR=<outside the repository> npm test"
ICFWALK_REQUIRE_APP=1 ICFWALK_SCREENSHOT_DIR="$OUT/lucee" npm test 2>&1 | tee "$OUT/lucee/npm-test.tap"
L_RC=${PIPESTATUS[0]}; echo "[exit $L_RC]"
totals "$OUT/lucee/npm-test.tap" lucee
L_TESTS=$N_TESTS; L_CFML=$C_PASS
clean "$L_RC" || die "the Lucee run did not pass cleanly"

step "11. Adobe ColdFusion 2023: a brand-new database, a brand-new container, and the seed"
tools/runtime/lucee-down.sh; echo "[lucee-down exit $?] (the machine is left to ColdFusion)"
"${SQLCMD[@]}" -Q "CREATE DATABASE [$ACF_DB]" || die "could not create $ACF_DB"
run node scripts/db/apply-schema.mjs --database "$ACF_DB" || die "schema application failed on $ACF_DB"
for n in 002 003 004 005 006 007; do run node scripts/db/apply-schema.mjs --database "$ACF_DB" --only "$n" || die "re-applying $n failed on $ACF_DB"; done
node scripts/db/apply-schema.mjs --database "$ACF_DB" --only 001; RC=$?; echo "[exit $RC]"
[ "$RC" != 0 ] && echo "001 refused a second application, as designed" || die "001 re-applied on $ACF_DB"
echo "\$ ICFWALK_DB_NAME=$ACF_DB ICFWALK_ACF_IMAGE=$ACF_IMAGE tools/runtime/acf-up.sh"
ICFWALK_DB_NAME="$ACF_DB" ICFWALK_ACF_IMAGE="$ACF_IMAGE" tools/runtime/acf-up.sh; RC=$?; echo "[exit $RC]"; [ "$RC" = 0 ] || die "ColdFusion did not start"
run docker inspect --format '{{.Config.Image}} @ {{.Image}} created {{.Created}}' icfwalk-acf
run curl -sS http://127.0.0.1:8500/index.cfm/api/health
echo
ICFWALK_DB_NAME="$ACF_DB" ICFWALK_BASE_URL=http://127.0.0.1:8500 node scripts/seed-instrument.mjs; RC=$?; echo "[exit $RC]"; [ "$RC" = 0 ] || die "seed failed on ColdFusion"

step "12. Adobe ColdFusion 2023: the full suite against it"
echo "\$ ICFWALK_BASE_URL=http://127.0.0.1:8500 ICFWALK_DB_NAME=$ACF_DB ICFWALK_CFML_SUITE_PARTS=12 ICFWALK_REQUIRE_APP=1 ICFWALK_SCREENSHOT_DIR=<outside> npm test"
ICFWALK_BASE_URL=http://127.0.0.1:8500 ICFWALK_DB_NAME="$ACF_DB" ICFWALK_CFML_SUITE_PARTS=12 ICFWALK_REQUIRE_APP=1 ICFWALK_SCREENSHOT_DIR="$OUT/acf" npm test 2>&1 | tee "$OUT/acf/npm-test.tap"
A_RC=${PIPESTATUS[0]}; echo "[exit $A_RC]"
totals "$OUT/acf/npm-test.tap" coldfusion
A_TESTS=$N_TESTS; A_CFML=$C_PASS
[[ "$C_LINE" == *"engine=ColdFusion Server 2023"* ]] || die "the CFML suite did not run on ColdFusion 2023"
clean "$A_RC" || die "the ColdFusion run did not pass cleanly"

step "13. Nothing was removed: every Node test the Phase 8 gate passed passed in both runs, and the totals"
cp "$P8_GATE/lucee/passing-names.txt" "$OUT/baseline-names.txt"
cmp -s "$P8_GATE/lucee/passing-names.txt" "$P8_GATE/acf/passing-names.txt" && echo "the Phase 8 gate passed the same $(wc -l < "$OUT/baseline-names.txt") names on both engines"
MISSING=0
for run_name in lucee acf; do
  grep -E '^ok [0-9]+ - ' "$OUT/$run_name/npm-test.tap" | sed -E 's/^ok [0-9]+ - //' | sort -u > "$OUT/$run_name/passing-names.txt"
  GONE=$(comm -23 "$OUT/baseline-names.txt" "$OUT/$run_name/passing-names.txt")
  ADDED=$(comm -13 "$OUT/baseline-names.txt" "$OUT/$run_name/passing-names.txt")
  echo "$run_name: baseline names $(wc -l < "$OUT/baseline-names.txt"), passing names $(wc -l < "$OUT/$run_name/passing-names.txt"), baseline names not passing: ${GONE:-<none>}, names not in the baseline: ${ADDED:-<none>}"
  [ -z "$GONE" ] || MISSING=$((MISSING+1))
done
[ "$MISSING" = 0 ] || die "a Node test of the baseline is missing or not passing"
echo "totals: baseline node $BASE_NODE cfml $BASE_CFML (+$NEW_CFML new CFML = $EXPECT_CFML); Lucee node $L_TESTS cfml $L_CFML; ColdFusion node $A_TESTS cfml $A_CFML"
[ "$L_TESTS" -ge "$BASE_NODE" ] && [ "$A_TESTS" -ge "$BASE_NODE" ] || die "fewer Node tests than the baseline"
[ "$L_CFML" = "$EXPECT_CFML" ] && [ "$A_CFML" = "$EXPECT_CFML" ] || die "a CFML suite did not run exactly $EXPECT_CFML cases"
[ "$L_TESTS" = "$A_TESTS" ] && [ "$L_CFML" = "$A_CFML" ] || die "the two engines ran different suites"

step "14. Repository identity after the gate"
run git rev-parse HEAD 'HEAD^{tree}'
STATUS=$(git status --porcelain=v1 --untracked-files=all); echo "\$ git status --porcelain=v1 --untracked-files=all"; echo "${STATUS:-<empty>}"
run git ls-remote origin "refs/heads/$BRANCH" "refs/heads/$P8_BRANCH"
run date -u
[ -z "$STATUS" ] || die "the gate changed the working tree"
[ "$(git rev-parse HEAD)" = "$EXPECTED" ] || die "HEAD moved"
[ "$(git rev-parse 'HEAD^{tree}')" = "$TREE_SHA" ] || die "the tree changed"
echo "screenshots written outside the repository: lucee $(find "$OUT/lucee" -name '*.png' | wc -l), coldfusion $(find "$OUT/acf" -name '*.png' | wc -l)"
echo; echo "GATE PASSED for $EXPECTED tree $TREE_SHA (Lucee node $L_TESTS, cfml $L_CFML; ColdFusion node $A_TESTS, cfml $A_CFML)"
