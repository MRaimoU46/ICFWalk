#!/usr/bin/env bash
# Report filters (the owner's decisions of 2026-10-16): red before green, run on the change's last code
# commit after its gate.
#
# Red: the code the change touched as it was at the wording correction's records commit (eb0d4ef) --
# the report service and repository, the page's two scripts and its stylesheet -- with the tests as
# committed at HEAD. The script prints the difference it reverts, which is the change's code alone.
#
#   http     tests/node/reports.test.mjs against Lucee: the options route's format and the owner's test
#            ("a repeated parameter is a list ... live only") fail
#   browser  tests/node/browser-reports.test.mjs against Lucee: the owner's browser test (Network, the
#            School list, several values, the Section note, the chooser) fails
#
# Green: nothing reverted, the same two runs pass in full. Lucee reloads its components only on a restart,
# so it is restarted after each change of files. Run with Google Fonts out of the browser's reach, as the
# gate runs. The tree is checked clean at the end.
#
# usage: red.sh <expected HEAD> <output directory outside the repository>
set -uo pipefail
REPO=/home/user/ICFWalk
BASE=eb0d4efc7fe9bc2f9c0dd89fcf1447db8716d8f7
FILES=(src/reports/ReportService.cfc src/reports/ReportRepository.cfc app/assets/js/reports.js app/assets/js/app.js app/assets/css/icfwalk.css)
EXPECTED="$1"; OUT="$2"
NO_PROXY_ENV=(env -u HTTPS_PROXY -u HTTP_PROXY -u https_proxy -u http_proxy -u ALL_PROXY -u all_proxy)
HTTP_OWNER="owner 2026-10-16: a repeated parameter is a list, several schools and values narrow together, and a Section counts the walks where it was shown, live only"
HTTP_OPTIONS="options describe the version, the scope, the releases and the reportable surface only"
BROWSER_OWNER="owner 2026-10-16 (browser): networks narrow the School list, filters take several values, and a Section counts the walks where it was shown"
cd "$REPO"
echo "== $(date -u +%Y-%m-%dT%H:%M:%SZ) the script"; cat "$0"
[ "$(git rev-parse HEAD)" = "$EXPECTED" ] || { echo "HEAD is not $EXPECTED"; exit 1; }
[ -z "$(git status --porcelain=v1 --untracked-files=all)" ] || { echo "the tree is not clean"; exit 1; }
echo "HEAD $(git rev-parse HEAD) tree $(git rev-parse 'HEAD^{tree}'), clean"
rm -rf "$OUT"; mkdir -p "$OUT"
RESULT=0

restart() {
  tools/runtime/lucee-down.sh > /dev/null 2>&1; tools/runtime/lucee-up.sh > "$OUT/lucee-up-last.txt" 2>&1; local rc=$?
  echo "lucee restarted (exit $rc): $(curl -sS --max-time 60 http://127.0.0.1:8888/index.cfm/api/health | cut -c1-160)"
}
suite() { # suite <file> <name>: one test file against Lucee
  "${NO_PROXY_ENV[@]}" ICFWALK_BASE_URL=http://127.0.0.1:8888 ICFWALK_REQUIRE_APP=1 ICFWALK_SCREENSHOT_DIR="$OUT/shots" node --test --test-concurrency=1 "tests/node/$1.test.mjs" > "$OUT/$2.tap" 2>&1
  local rc=$?
  grep -E "^(ok|not ok) |^# (tests|pass|fail) " "$OUT/$2.tap"
  echo "[exit $rc]"
  return $rc
}
# Files, not pipes: under pipefail a pipe into grep -q fails when grep stops reading early.
fails() { # fails <tap name> <test name>: whether that test failed in that run
  grep -E "^not ok [0-9]+ - " "$OUT/$1.tap" | sed -E 's/^not ok [0-9]+ - //' > "$OUT/$1.failed.txt"
  grep -qxF "$2" "$OUT/$1.failed.txt"
}

echo; echo "== $(date -u +%Y-%m-%dT%H:%M:%SZ) the change's code: git diff --stat $BASE HEAD -- the five files"
git diff --stat "$BASE" HEAD -- "${FILES[@]}"
echo; echo "== $(date -u +%Y-%m-%dT%H:%M:%SZ) RED: the five files as at $BASE, the tests as at HEAD"
git checkout "$BASE" -- "${FILES[@]}"
git status --porcelain=v1
restart
echo "-- http (reports.test.mjs)"; suite reports red-http
echo "-- browser (browser-reports.test.mjs)"; suite browser-reports red-browser
fails red-http "$HTTP_OWNER" && echo "RED as expected: $HTTP_OWNER" || { echo "NOT RED: $HTTP_OWNER"; RESULT=1; }
fails red-http "$HTTP_OPTIONS" && echo "RED as expected: $HTTP_OPTIONS" || { echo "NOT RED: $HTTP_OPTIONS"; RESULT=1; }
fails red-browser "$BROWSER_OWNER" && echo "RED as expected: $BROWSER_OWNER" || { echo "NOT RED: $BROWSER_OWNER"; RESULT=1; }

echo; echo "== $(date -u +%Y-%m-%dT%H:%M:%SZ) GREEN: the five files restored to HEAD"
git checkout HEAD -- "${FILES[@]}"
STATUS=$(git status --porcelain=v1 --untracked-files=all); echo "status: ${STATUS:-<empty>}"
[ -z "$STATUS" ] || RESULT=1
restart
echo "-- http (reports.test.mjs)"; suite reports green-http || RESULT=1
echo "-- browser (browser-reports.test.mjs)"; suite browser-reports green-browser || RESULT=1

echo; echo "== $(date -u +%Y-%m-%dT%H:%M:%SZ) the tree after"
git rev-parse HEAD 'HEAD^{tree}'
STATUS=$(git status --porcelain=v1 --untracked-files=all); echo "status: ${STATUS:-<empty>}"
[ -z "$STATUS" ] && [ "$(git rev-parse HEAD)" = "$EXPECTED" ] || RESULT=1
echo; [ "$RESULT" = 0 ] && echo "RED BEFORE GREEN: as expected" || echo "RED BEFORE GREEN: NOT as expected"
exit "$RESULT"
