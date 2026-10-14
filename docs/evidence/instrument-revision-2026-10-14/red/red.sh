#!/usr/bin/env bash
# Red before green for the two code changes of the revision, run on the code commit after its gate.
#
# Each red reverts ONE production file to the starting point 452bd26 -- the tests are the committed ones,
# unchanged -- runs tests/node/browser-revision.test.mjs against the running application, and puts the
# file back. Each must fail, and fail on the expectation that file is responsible for:
#
#   list-titles   app/assets/js/app.js       REV-E5 cannot find "Open 7 · Visual Arts" in My walks
#   level-names   app/assets/js/renderer.js  REV-E5's definitions read "1:" where "1 · Not evident:" is due
#
# Then the same file runs green with nothing reverted. The tree is checked clean at the end. Run with
# Google Fonts out of the browser's reach, as the gate runs (../environment.md).
#
# usage: red.sh <expected HEAD> <output directory outside the repository>
set -uo pipefail
REPO=/home/user/ICFWalk
BASE=452bd2690f6b29f24cbd0555147f4a2d75e614ba
EXPECTED="$1"; OUT="$2"
NO_PROXY_ENV=(env -u HTTPS_PROXY -u HTTP_PROXY -u https_proxy -u http_proxy -u ALL_PROXY -u all_proxy)
cd "$REPO"
echo "== $(date -u +%Y-%m-%dT%H:%M:%SZ) the script"; cat "$0"
[ "$(git rev-parse HEAD)" = "$EXPECTED" ] || { echo "HEAD is not $EXPECTED"; exit 1; }
[ -z "$(git status --porcelain=v1 --untracked-files=all)" ] || { echo "the tree is not clean"; exit 1; }
echo "HEAD $(git rev-parse HEAD) tree $(git rev-parse 'HEAD^{tree}'), clean"
mkdir -p "$OUT"
RESULT=0
case_run() { # case_run <name> <file> <pattern the failure must show>
  local name="$1" file="$2" pattern="$3"
  echo; echo "== $(date -u +%Y-%m-%dT%H:%M:%SZ) red: $name ($file reverted to ${BASE:0:7})"
  git show "$BASE:$file" > "$file"
  echo "\$ git status --porcelain=v1"; git status --porcelain=v1
  "${NO_PROXY_ENV[@]}" ICFWALK_REQUIRE_APP=1 ICFWALK_SCREENSHOT_DIR="$OUT/shots-$name" node --test tests/node/browser-revision.test.mjs > "$OUT/red-$name.tap" 2>&1
  local rc=$?
  git checkout -- "$file"
  grep -E "^(ok|not ok) |^# (tests|pass|fail) " "$OUT/red-$name.tap"
  echo "[exit $rc]"
  if [ "$rc" != 0 ] && grep -qF -- "$pattern" "$OUT/red-$name.tap"; then echo "RED as required: the failure shows \"$pattern\""; else echo "NOT RED as required"; RESULT=1; fi
}
case_run list-titles app/assets/js/app.js "waiting for getByRole('button', { name: 'Open 7 · Visual Arts' })"
case_run level-names app/assets/js/renderer.js "'1 · Not evident: "
echo; echo "== $(date -u +%Y-%m-%dT%H:%M:%SZ) green: nothing reverted"
"${NO_PROXY_ENV[@]}" ICFWALK_REQUIRE_APP=1 ICFWALK_SCREENSHOT_DIR="$OUT/shots-green" node --test tests/node/browser-revision.test.mjs > "$OUT/green.tap" 2>&1
rc=$?
grep -E "^(ok|not ok) |^# (tests|pass|fail) " "$OUT/green.tap"
echo "[exit $rc]"; [ "$rc" = 0 ] || RESULT=1
rm -rf "$OUT"/shots-*
STATUS=$(git status --porcelain=v1 --untracked-files=all); echo "status after: ${STATUS:-<empty>}"
[ -z "$STATUS" ] || RESULT=1
[ "$RESULT" = 0 ] && echo "RED BEFORE GREEN CONFIRMED" || echo "RED BEFORE GREEN NOT CONFIRMED"
exit $RESULT
