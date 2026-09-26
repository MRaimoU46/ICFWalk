#!/usr/bin/env bash
# Phase 8 baseline: the existing full gate, rerun from a clean tree on the Phase 8 branch before any
# Phase 8 change is made.
#
# HEAD must be the Phase 0-7 records-only freeze tip. Its code, tests, configuration, dependencies
# and migrations must be exactly those of the frozen code commit 68f9026, so this run re-proves the
# frozen baseline in this session's environment. The steps are the frozen integration gate's
# (docs/evidence/gate/phase6-7-integration-68f9026d39ba0ff44d12d6398c5e933971dad2f4/gate.sh): clean
# tree, npm ci, validate:handoff, test:package, every JavaScript file parsed, a brand-new SQL Server
# container, migrations 001 to 007 with every re-application and 001 refused, the application and
# the seed, ICFWALK_REQUIRE_APP=1 npm test, totals, identity after. What changes: the identity checks
# (the Phase 8 branch and the freeze tip instead of the merge's two parents), and the SQL Server
# image is pinned to the digest the frozen gate recorded, so the database build is the same one.
#
# It writes nothing into the repository: screenshots and the TAP copy go to SHOTS, outside it. It
# rewrites the git-ignored .env's ICFWALK_DB_PASSWORD with the new container's generated password
# (never printed). Every command is echoed with its exit code. It stops on the first unexpected
# result.
#
# usage: gate.sh <expected HEAD sha> <screenshot dir outside the repository>
set -uo pipefail
REPO=/home/user/ICFWalk
BRANCH=claude/icfwalk-phase-8-hardening-handoff
FROZEN_CODE=68f9026d39ba0ff44d12d6398c5e933971dad2f4   # the accepted, frozen Phase 0-7 code commit
FREEZE_TIP=133f02192a99970029847bc2da2d31b9d8da06e1    # the records-only freeze tip Phase 8 starts from
INTEGRATION=claude/icfwalk-phase-6-7-integration
P6_BRANCH=claude/icfwalk-phase-6-admin-audit-corrections; P6_TIP=64507deb075e267761179d78be966b7a4d3972cc
P7_BRANCH=claude/icfwalk-phase-7-correction-n62s25;      P7_TIP=e0342143074f727475ae2d4cb6933fa279902f85
MSSQL_IMAGE=mcr.microsoft.com/mssql/server@sha256:4402d880dd4c34bfa7d8705e56a86cd6c88da80a1f6bbbe741f999e76264a090
CODE_PATHS="src app tests scripts tools database config package.json package-lock.json manifest.json .env.example"
EXPECTED="$1"
SHOTS="$2"
cd "$REPO"

step() { echo; echo "================================================================================"; echo "== $(date -u +%Y-%m-%dT%H:%M:%SZ)  $*"; echo "================================================================================"; }
run() { echo "\$ $*"; "$@"; local rc=$?; echo "[exit $rc]"; return $rc; }
die() { echo; echo "GATE FAILED: $*"; exit 1; }

step "0. The gate script itself"
cat "$0"

step "1. Repository identity before the gate"
run date -u
BR=$(git rev-parse --abbrev-ref HEAD); echo "branch $BR"
[ "$BR" = "$BRANCH" ] || die "not on $BRANCH"
HEAD_SHA=$(git rev-parse HEAD); TREE_SHA=$(git rev-parse 'HEAD^{tree}')
echo "HEAD   $HEAD_SHA"; echo "TREE   $TREE_SHA"
[ "$HEAD_SHA" = "$EXPECTED" ] || die "HEAD $HEAD_SHA is not the expected commit $EXPECTED"
[ "$HEAD_SHA" = "$FREEZE_TIP" ] && echo "HEAD is the Phase 0-7 records-only freeze tip" || die "HEAD is not the freeze tip $FREEZE_TIP"
run git log -3 --format='%H %T %P %an %aI %s'
git merge-base --is-ancestor "$FROZEN_CODE" HEAD && echo "$FROZEN_CODE (frozen code) is an ancestor of HEAD" || die "the frozen code commit is not an ancestor"
echo "\$ git diff --name-only $FROZEN_CODE HEAD -- $CODE_PATHS   (records after the frozen code: must be empty)"
D=$(git diff --name-only "$FROZEN_CODE" HEAD -- $CODE_PATHS); echo "${D:-<empty>}"
[ -z "$D" ] || die "HEAD's code differs from the frozen code"
echo "\$ git diff --stat $FROZEN_CODE HEAD   (every difference is a record)"
git diff --stat "$FROZEN_CODE" HEAD
echo "\$ git status --porcelain=v1 --untracked-files=all  (tracked, staged, unstaged and untracked)"
STATUS=$(git status --porcelain=v1 --untracked-files=all); echo "${STATUS:-<empty>}"
[ -z "$STATUS" ] || die "working tree is not clean"
run git fetch origin "$BRANCH" || die "fetch failed"
REMOTE_SHA=$(git rev-parse "origin/$BRANCH"); echo "origin/$BRANCH = $REMOTE_SHA"
[ "$REMOTE_SHA" = "$HEAD_SHA" ] && echo "remote branch equals HEAD" || die "remote branch $REMOTE_SHA differs from HEAD"
echo "--- the frozen integration branch and both source branches are unchanged"
for pair in "$INTEGRATION=$FREEZE_TIP" "$P6_BRANCH=$P6_TIP" "$P7_BRANCH=$P7_TIP"; do
  B=${pair%%=*}; W=${pair#*=}; R=$(git ls-remote origin "refs/heads/$B" | cut -f1)
  echo "$B $R"; [ "$R" = "$W" ] || die "$B is $R, expected $W"
done
echo "tags: local $(git tag -l | wc -l), remote $(git ls-remote --tags origin 2>/dev/null | wc -l)"

step "2. Runtime versions"
run uname -srm
echo "os $(. /etc/os-release; echo "$PRETTY_NAME")"
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
run node scripts/validate-handoff.mjs || die "handoff validation failed"
run npm run test:package || die "package tests failed"

step "5. JavaScript syntax (every tracked .js and .mjs)"
COUNT=0; FAILED=0
for f in $(git ls-files '*.js' '*.mjs'); do COUNT=$((COUNT+1)); if node --check "$f" 2>&1; then :; else echo "SYNTAX ERROR $f"; FAILED=$((FAILED+1)); fi; done
echo "checked $COUNT files, $FAILED syntax errors"
[ "$FAILED" = 0 ] || die "syntax errors"

step "6. A brand-new SQL Server container and database"
tools/runtime/lucee-down.sh; echo "[lucee-down exit $?]"
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
echo "\$ sqlcmd: @@VERSION, the databases, icfwalk_dev table count"
"${SQLCMD[@]}" -h -1 -W -Q "SET NOCOUNT ON; SELECT @@VERSION; SELECT name, create_date FROM sys.databases WHERE name LIKE 'icfwalk%'; SELECT COUNT(*) AS tables_in_icfwalk_dev FROM icfwalk_dev.sys.tables;"

step "7. Schema: 001 to 007 in order, then each of 002 to 007 re-applied, and 001 refused"
run node scripts/db/apply-schema.mjs || die "schema application failed"
for n in 002 003 004 005 006 007; do run node scripts/db/apply-schema.mjs --only "$n" || die "re-applying $n failed"; done
echo "\$ node scripts/db/apply-schema.mjs --only 001   (must refuse: the schema already has tables)"
node scripts/db/apply-schema.mjs --only 001; RC=$?; echo "[exit $RC]"
[ "$RC" != 0 ] && echo "001 refused a second application, as designed" || die "001 re-applied"
"${SQLCMD[@]}" -d icfwalk_dev -h -1 -W -Q "SET NOCOUNT ON; SELECT COUNT(*) AS icf_tables FROM sys.tables WHERE schema_id = SCHEMA_ID('icf'); SELECT name FROM sys.triggers ORDER BY name; SELECT migration, step, state FROM icf.schema_migration_state;"

step "8. The application on the new database, and the instrument seed"
run tools/runtime/lucee-up.sh || die "the application did not start"
echo "lucee jars: $(ls .runtime/jars | tr '\n' ' ')"
run curl -sS http://127.0.0.1:8888/index.cfm/api/health
echo
run node scripts/seed-instrument.mjs || die "seed failed"

step "9. The full suite: ICFWALK_REQUIRE_APP=1 npm test (Node, HTTP, Playwright and CFML)"
rm -rf "$SHOTS"; mkdir -p "$SHOTS"
echo "\$ ICFWALK_REQUIRE_APP=1 ICFWALK_SCREENSHOT_DIR=<a directory outside the repository> npm test"
ICFWALK_REQUIRE_APP=1 ICFWALK_SCREENSHOT_DIR="$SHOTS" npm test 2>&1 | tee "$SHOTS/npm-test.tap"
RC=${PIPESTATUS[0]}; echo "[exit $RC]"

step "10. Totals"
grep -E '^# (tests|suites|pass|fail|cancelled|skipped|todo|duration_ms) ' "$SHOTS/npm-test.tap" | tail -8
grep -E 'engine=Lucee' "$SHOTS/npm-test.tap" || echo "no CFML totals line"
grep -E '^not ok ' "$SHOTS/npm-test.tap" || echo "no failed Node test"
TESTS=$(grep -E '^# tests ' "$SHOTS/npm-test.tap" | tail -1 | awk '{print $3}'); PASS=$(grep -E '^# pass ' "$SHOTS/npm-test.tap" | tail -1 | awk '{print $3}')
FAIL=$(grep -E '^# fail ' "$SHOTS/npm-test.tap" | tail -1 | awk '{print $3}'); SKIP=$(grep -E '^# skipped ' "$SHOTS/npm-test.tap" | tail -1 | awk '{print $3}')
TODO=$(grep -E '^# todo ' "$SHOTS/npm-test.tap" | tail -1 | awk '{print $3}'); CANC=$(grep -E '^# cancelled ' "$SHOTS/npm-test.tap" | tail -1 | awk '{print $3}')
echo "node: tests=$TESTS pass=$PASS fail=$FAIL skipped=$SKIP todo=$TODO cancelled=$CANC exit=$RC"
CFML=$(grep -E '^# engine=Lucee' "$SHOTS/npm-test.tap" | tail -1)
CF_FAIL=$(echo "$CFML" | grep -o 'failed=[0-9]*' | cut -d= -f2); CF_SKIP=$(echo "$CFML" | grep -o 'skipped=[0-9]*' | cut -d= -f2)
CF_PASS=$(echo "$CFML" | grep -o 'passed=[0-9]*' | cut -d= -f2)
echo "cfml: ${CFML:-<no totals line>}"
echo "screenshots written outside the repository: $(find "$SHOTS" -name '*.png' | wc -l)"

step "11. Repository identity after the gate"
run git rev-parse HEAD 'HEAD^{tree}'
STATUS=$(git status --porcelain=v1 --untracked-files=all); echo "\$ git status --porcelain=v1 --untracked-files=all"; echo "${STATUS:-<empty>}"
run git fetch origin "$BRANCH"
run git ls-remote origin "refs/heads/$BRANCH"
run date -u

[ "$RC" = 0 ] && [ "$FAIL" = 0 ] && [ "$SKIP" = 0 ] && [ "$TODO" = 0 ] && [ "$CANC" = 0 ] && [ "$TESTS" = "$PASS" ] || die "the suite did not pass cleanly"
[ "${CF_FAIL:-x}" = 0 ] && [ "${CF_SKIP:-x}" = 0 ] || die "the CFML suite did not pass cleanly"
echo "expected (the frozen gate of 68f9026): node 245, cfml 517; got: node $TESTS, cfml $CF_PASS"
[ "$TESTS" = 245 ] && [ "$CF_PASS" = 517 ] || die "the totals differ from the frozen baseline"
[ -z "$STATUS" ] || die "the gate changed the working tree"
[ "$(git rev-parse HEAD)" = "$EXPECTED" ] || die "HEAD moved"
echo; echo "GATE PASSED for $EXPECTED (baseline reproduced)"
