#!/usr/bin/env bash
# Phase 6 + Phase 7 integration: exact-commit gate on the merge commit.
#
# The union of the two branches' gates: the Phase 6 gate (clean tree, ancestry, npm ci,
# validate:handoff, test:package, every JavaScript file parsed, a freshly created database, the
# application started on it and the aligned DRAFT seeded, ICFWALK_REQUIRE_APP=1 npm test, the tree
# clean and HEAD unmoved afterwards) and the Phase 7 gate (a brand-new SQL Server container, every
# migration re-applied and 001 refused, the remote branch equal to HEAD, totals with 0 failed,
# skipped, todo and cancelled). Added for the merge: both parents named exactly, and every code
# difference from each parent accounted for by the other parent's changes.
#
# It writes nothing into the repository: screenshots and the TAP copy go to SHOTS, outside it.
# Every command is echoed with its exit code. It stops on the first unexpected result.
#
# usage: gate-integration.sh <expected merge commit sha> <screenshot dir outside the repository>
set -uo pipefail
REPO=/home/user/ICFWalk
BRANCH=claude/icfwalk-phase-6-7-integration
P6_TIP=64507deb075e267761179d78be966b7a4d3972cc   # first parent: the Phase 6 records tip
P7_TIP=e0342143074f727475ae2d4cb6933fa279902f85   # second parent: the Phase 7 tip
P6_CODE=158debca5da2c4f3a07f602689cd08af9db9bd6e  # the accepted, frozen Phase 6 code commit
P7_CODE=98321a16df64005f9b55fcd9bc3b9b4d4a071e4e  # Phase 7's gated code commit (third round)
MERGE_BASE=0c6fa10972593043508f502538534c2aa95c671b
BASELINE=a219d9e0987b85b1a0b587fd62effa4e0ad1ffde  # the frozen Phase 0-6 foundation
PHASE5=e55ec08af5b8622db5823b6e353423b891918549
CODE_PATHS="src app tests scripts tools database config package.json package-lock.json .env.example"
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
PARENTS=$(git rev-list --parents -n 1 HEAD | cut -d' ' -f2-); echo "PARENTS $PARENTS"
[ "$PARENTS" = "$P6_TIP $P7_TIP" ] && echo "HEAD is a merge of exactly the Phase 6 records tip (first parent) and the Phase 7 tip (second parent)" || die "parents are not exactly $P6_TIP $P7_TIP"
MB=$(git merge-base "$P6_TIP" "$P7_TIP"); echo "merge base of the parents: $MB"
[ "$MB" = "$MERGE_BASE" ] || die "unexpected merge base"
run git log -1 --format='%H %T %P %an %aI %s'
for A in "$BASELINE" "$PHASE5" "$MERGE_BASE" "$P6_CODE" "$P7_CODE"; do
  git merge-base --is-ancestor "$A" HEAD && echo "$A is an ancestor of HEAD" || die "$A is not an ancestor"
done
echo "\$ git diff --name-only $P6_CODE $P6_TIP -- $CODE_PATHS manifest.json   (the Phase 6 records after the frozen code: must be empty)"
D=$(git diff --name-only "$P6_CODE" "$P6_TIP" -- $CODE_PATHS manifest.json); echo "${D:-<empty>}"
[ -z "$D" ] || die "the Phase 6 records tip changes code"
echo "--- every code difference from each parent must be a file the other parent changed since the merge base"
P6_CHANGED=$(git diff --name-only "$MERGE_BASE" "$P6_TIP" -- $CODE_PATHS | sort)
P7_CHANGED=$(git diff --name-only "$MERGE_BASE" "$P7_TIP" -- $CODE_PATHS | sort)
FROM_P6=$(git diff --name-only "$P6_TIP" HEAD -- $CODE_PATHS | sort)
FROM_P7=$(git diff --name-only "$P7_TIP" HEAD -- $CODE_PATHS | sort)
echo "code files that differ from the Phase 6 parent: $(echo "$FROM_P6" | grep -c .)"; echo "$FROM_P6"
UNEXPLAINED=$(comm -23 <(echo "$FROM_P6") <(echo "$P7_CHANGED") | grep . || true)
echo "  of which Phase 7 did not change: ${UNEXPLAINED:-<none>}"
[ -z "$UNEXPLAINED" ] || die "a code difference from the Phase 6 parent is not a Phase 7 change"
echo "code files that differ from the Phase 7 parent: $(echo "$FROM_P7" | grep -c .)"
UNEXPLAINED=$(comm -23 <(echo "$FROM_P7") <(echo "$P6_CHANGED") | grep . || true)
echo "  of which Phase 6 did not change: ${UNEXPLAINED:-<none>}"
[ -z "$UNEXPLAINED" ] || die "a code difference from the Phase 7 parent is not a Phase 6 change"
echo "code files both parents changed since the merge base:"; comm -12 <(echo "$P6_CHANGED") <(echo "$P7_CHANGED")
echo "--- each of them must be one side's file plus exactly the other side's changed lines (content of the +/- lines)"
changed_lines() { git diff "$1" "$2" -- "$3" | grep '^[-+]' | grep -v '^+++ \|^--- '; }
for f in $(comm -12 <(echo "$P6_CHANGED") <(echo "$P7_CHANGED")); do
  A=$(changed_lines "$MERGE_BASE" "$P7_TIP" "$f" | sha256sum | cut -c1-16); B=$(changed_lines "$P6_CODE" HEAD "$f" | sha256sum | cut -c1-16)
  C=$(changed_lines "$MERGE_BASE" "$P6_CODE" "$f" | sha256sum | cut -c1-16); D=$(changed_lines "$P7_TIP" HEAD "$f" | sha256sum | cut -c1-16)
  echo "$f: Phase 7's change $A, HEAD minus frozen Phase 6 $B; Phase 6's change $C, HEAD minus Phase 7 $D"
  [ "$A" = "$B" ] && [ "$C" = "$D" ] || die "$f is not exactly the two sides' changes combined"
done
echo "\$ git status --porcelain=v1 --untracked-files=all  (tracked, staged, unstaged and untracked)"
STATUS=$(git status --porcelain=v1 --untracked-files=all); echo "${STATUS:-<empty>}"
[ -z "$STATUS" ] || die "working tree is not clean"
run git fetch origin "$BRANCH" || die "fetch failed"
REMOTE_SHA=$(git rev-parse "origin/$BRANCH"); echo "origin/$BRANCH = $REMOTE_SHA"
run git ls-remote origin "refs/heads/$BRANCH"
[ "$REMOTE_SHA" = "$HEAD_SHA" ] && echo "remote branch equals HEAD" || die "remote branch $REMOTE_SHA differs from HEAD"
echo "tags: local $(git tag -l | wc -l), remote $(git ls-remote --tags origin 2>/dev/null | wc -l)"

step "2. Runtime versions"
run uname -srm
echo "os $(. /etc/os-release; echo "$PRETTY_NAME")"
run node --version
run npm --version
java -version 2>&1 | sed -e 's/^Picked up JAVA_TOOL_OPTIONS: .*/Picked up JAVA_TOOL_OPTIONS: [redacted: container proxy and truststore settings]/'
run docker version --format 'docker client {{.Client.Version}} server {{.Server.Version}}'
echo "lucee jars: $(ls .runtime/jars | tr '\n' ' ')"

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
run tools/runtime/mssql-up.sh || die "SQL Server did not start"
source .runtime/mssql.env
# .env is git-ignored: point it at the new container's generated password (never printed).
[ -n "${MSSQL_SA_PASSWORD:-}" ] || die "the new container's password was not generated"
NEWPW="$MSSQL_SA_PASSWORD" node -e 'const fs=require("fs");const pw=process.env.NEWPW;if(!pw)process.exit(1);const t=fs.readFileSync(".env","utf8");if(!/^ICFWALK_DB_PASSWORD=/m.test(t))process.exit(1);fs.writeFileSync(".env",t.replace(/^ICFWALK_DB_PASSWORD=.*$/m,()=>"ICFWALK_DB_PASSWORD="+pw))' || die "could not update .env"
echo "(.env ICFWALK_DB_PASSWORD set to the new container's generated password; not printed)"
run docker ps --filter name=icfwalk-mssql --format '{{.ID}} {{.Image}} {{.Status}} created {{.CreatedAt}}'
run docker inspect --format '{{.Config.Image}} @ {{.Image}}' icfwalk-mssql
run docker image inspect --format '{{index .RepoDigests 0}}' mcr.microsoft.com/mssql/server:2022-latest
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
# No test file was changed by both parents, so the merged suite is the merge base's plus each side's
# additions: Node 193 + 47 (Phase 6: 240) + 5 (Phase 7: 198) = 245; CFML 411 + 72 (483) + 34 (445) = 517.
CF_PASS=$(echo "$CFML" | grep -o 'passed=[0-9]*' | cut -d= -f2)
echo "expected: node 245, cfml 517; got: node $TESTS, cfml $CF_PASS"
[ "$TESTS" = 245 ] && [ "$CF_PASS" = 517 ] || die "the merged suite is not exactly both sides' tests"
[ -z "$STATUS" ] || die "the gate changed the working tree"
[ "$(git rev-parse HEAD)" = "$EXPECTED" ] || die "HEAD moved"
echo; echo "GATE PASSED for $EXPECTED"
