#!/usr/bin/env bash
# Phase 7 correction, third round (P7C-03, P7C-04): exact-commit release gate.
#
# Runs every suite against the commit checked out in REPO, from a clean tree, on a brand-new
# SQL Server container and database, and writes nothing into the repository (screenshots go to
# SHOTS). Every command is echoed with a UTC timestamp before it runs, and its complete output
# follows. The gate fails (non-zero exit) on the first unexpected result.
#
# usage: gate.sh <expected-commit-sha> <shots-dir>
set -uo pipefail
REPO=/home/user/ICFWalk
BRANCH=claude/icfwalk-phase-7-correction-n62s25
BASELINE=a219d9e0987b85b1a0b587fd62effa4e0ad1ffde
# The re-audited commit (the parent of the commit under test) and its ancestors.
AUDITED=9ef9b97b5b4ee20dd51d6ca023c0841b7ca872ba
ANCESTORS="b67df76a9fe46eefe38d47f7919a89d19c1b5d79 0c74dbd5a8a79684d38ba0b169dce2682a54fad6 0c6fa10972593043508f502538534c2aa95c671b"
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
run git rev-parse --abbrev-ref HEAD
HEAD_SHA=$(git rev-parse HEAD); TREE_SHA=$(git rev-parse 'HEAD^{tree}'); PARENT_SHA=$(git rev-parse 'HEAD^')
echo "HEAD   $HEAD_SHA"; echo "TREE   $TREE_SHA"; echo "PARENT $PARENT_SHA"
[ "$HEAD_SHA" = "$EXPECTED" ] || die "HEAD $HEAD_SHA is not the expected commit $EXPECTED"
[ "$(git rev-parse --abbrev-ref HEAD)" = "$BRANCH" ] || die "not on $BRANCH"
run git log -3 --format='%H %T %P %an %aI %s'
run git merge-base --is-ancestor "$BASELINE" HEAD && echo "frozen Phase 6 baseline $BASELINE is an ancestor of HEAD" || die "baseline not an ancestor"
for A in $ANCESTORS; do run git merge-base --is-ancestor "$A" HEAD && echo "$A is an ancestor of HEAD" || die "$A is not an ancestor"; done
[ "$PARENT_SHA" = "$AUDITED" ] && echo "HEAD's parent is the re-audited commit $AUDITED" || die "parent is not the re-audited commit"
run git log --format='%H %T %s' "a219d9e0987b85b1a0b587fd62effa4e0ad1ffde..HEAD"
echo "\$ git status --porcelain=v1 --untracked-files=all  (tracked, staged, unstaged and untracked)"
STATUS=$(git status --porcelain=v1 --untracked-files=all); echo "${STATUS:-<empty>}"
[ -z "$STATUS" ] || die "working tree is not clean"
run git diff --cached --stat
echo "\$ git status --porcelain=v1 --branch  (tracking: no ahead/behind count means local equals origin)"
git status --porcelain=v1 --branch
run git fetch origin "$BRANCH"
REMOTE_SHA=$(git rev-parse "origin/$BRANCH"); echo "origin/$BRANCH = $REMOTE_SHA"
run git ls-remote origin "refs/heads/$BRANCH"
[ "$REMOTE_SHA" = "$HEAD_SHA" ] && echo "remote branch equals HEAD" || die "remote branch $REMOTE_SHA differs from HEAD"
run git diff --stat "$AUDITED" HEAD

step "2. Runtime versions"
run uname -a
run cat /etc/os-release
run node --version
run npm --version
run java -version
run docker version --format 'client {{.Client.Version}} server {{.Server.Version}}'
run node -e 'for (const p of ["playwright","mssql","axe-core"]) console.log(p, require("/home/user/ICFWalk/node_modules/"+p+"/package.json").version)'
run ls /opt/pw-browsers

step "3. Dependencies from the lockfile"
run npm ci || die "npm ci failed"
STATUS=$(git status --porcelain=v1 --untracked-files=all); echo "status after npm ci: ${STATUS:-<empty>}"
[ -z "$STATUS" ] || die "npm ci changed the tree"

step "4. Handoff validation and package tests"
run node scripts/validate-handoff.mjs || die "handoff validation failed"
run npm run test:package || die "package tests failed"

step "5. JavaScript syntax (every tracked .js and .mjs)"
COUNT=0; FAILED=0
for f in $(git ls-files '*.js' '*.mjs'); do COUNT=$((COUNT+1)); if node --check "$f"; then echo "ok $f"; else echo "SYNTAX ERROR $f"; FAILED=$((FAILED+1)); fi; done
echo "checked $COUNT files, $FAILED syntax errors"
[ "$FAILED" = 0 ] || die "syntax errors"

step "6. A brand-new SQL Server container and database"
if [ -f .runtime/lucee.pid ]; then run kill "$(cat .runtime/lucee.pid)"; sleep 5; rm -f .runtime/lucee.pid; fi
run docker rm -f icfwalk-mssql
run rm -f .runtime/mssql.env
run tools/runtime/mssql-up.sh || die "SQL Server did not start"
source .runtime/mssql.env
# .env is git-ignored; point it at the new container's generated password (never printed).
sed -i "s/^ICFWALK_DB_PASSWORD=.*/ICFWALK_DB_PASSWORD=${MSSQL_SA_PASSWORD}/" .env
echo "(.env ICFWALK_DB_PASSWORD updated to the new container's generated password; not printed)"
run docker ps --filter name=icfwalk-mssql --format '{{.ID}} {{.Image}} {{.Status}} created {{.CreatedAt}}'
run docker inspect --format '{{.Image}}' icfwalk-mssql
run docker image inspect --format '{{index .RepoDigests 0}}' mcr.microsoft.com/mssql/server:2022-latest
SQLCMD=(docker exec icfwalk-mssql /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -b)
echo "\$ sqlcmd: SELECT @@VERSION; database list; icfwalk_dev table count"
"${SQLCMD[@]}" -h -1 -Q "SET NOCOUNT ON; SELECT @@VERSION; SELECT name, create_date FROM sys.databases WHERE name LIKE 'icfwalk%'; SELECT COUNT(*) AS icf_tables FROM icfwalk_dev.sys.tables;"

step "7. Schema: 001..007 in order, then every re-application"
run node scripts/db/apply-schema.mjs || die "schema application failed"
for n in 002 003 004 005 006 007; do run node scripts/db/apply-schema.mjs --only "$n" || die "re-applying $n failed"; done
echo "\$ node scripts/db/apply-schema.mjs --only 001   (must refuse: the schema already has tables)"
node scripts/db/apply-schema.mjs --only 001; RC=$?; echo "[exit $RC]"
[ "$RC" != 0 ] && echo "001 refused a second application, as designed" || die "001 re-applied"
"${SQLCMD[@]}" -d icfwalk_dev -h -1 -Q "SET NOCOUNT ON; SELECT COUNT(*) AS icf_tables FROM sys.tables WHERE schema_id = SCHEMA_ID('icf'); SELECT name FROM sys.triggers ORDER BY name; SELECT migration, step, state FROM icf.schema_migration_state;"

step "8. The application on the new database, and the instrument seed"
run tools/runtime/lucee-up.sh || die "application did not start"
run curl -sS http://127.0.0.1:8888/index.cfm/api/health
run node scripts/seed-instrument.mjs || die "seed failed"

step "9. The full suite: ICFWALK_REQUIRE_APP=1 npm test (Node, HTTP, Playwright, CFML)"
echo "\$ ICFWALK_REQUIRE_APP=1 ICFWALK_SCREENSHOT_DIR=$SHOTS npm test"
ICFWALK_REQUIRE_APP=1 ICFWALK_SCREENSHOT_DIR="$SHOTS" npm test 2>&1 | tee "$SHOTS/npm-test.tap"
RC=${PIPESTATUS[0]}; echo "[exit $RC]"

step "10. Totals"
grep -E '^# (tests|suites|pass|fail|cancelled|skipped|todo|duration_ms) ' "$SHOTS/npm-test.tap" | tail -8
grep -E 'engine=Lucee' "$SHOTS/npm-test.tap"
grep -E '^not ok ' "$SHOTS/npm-test.tap" || echo "no failed Node test"
FAIL=$(grep -E '^# fail ' "$SHOTS/npm-test.tap" | tail -1 | awk '{print $3}'); SKIP=$(grep -E '^# skipped ' "$SHOTS/npm-test.tap" | tail -1 | awk '{print $3}')
TODO=$(grep -E '^# todo ' "$SHOTS/npm-test.tap" | tail -1 | awk '{print $3}'); CANC=$(grep -E '^# cancelled ' "$SHOTS/npm-test.tap" | tail -1 | awk '{print $3}')
echo "fail=$FAIL skipped=$SKIP todo=$TODO cancelled=$CANC exit=$RC"

step "11. Repository identity after the gate"
run git rev-parse HEAD 'HEAD^{tree}'
STATUS=$(git status --porcelain=v1 --untracked-files=all); echo "\$ git status --porcelain=v1 --untracked-files=all"; echo "${STATUS:-<empty>}"
run git fetch origin "$BRANCH"
echo "\$ git status --porcelain=v1 --branch"
git status --porcelain=v1 --branch
run git ls-remote origin "refs/heads/$BRANCH"
run date -u

[ "$RC" = 0 ] && [ "$FAIL" = 0 ] && [ "$SKIP" = 0 ] && [ "$TODO" = 0 ] && [ "$CANC" = 0 ] || die "the suite did not pass cleanly"
[ -z "$STATUS" ] || die "the gate changed the working tree"
[ "$(git rev-parse HEAD)" = "$EXPECTED" ] || die "HEAD moved"
echo; echo "GATE PASSED for $EXPECTED"
