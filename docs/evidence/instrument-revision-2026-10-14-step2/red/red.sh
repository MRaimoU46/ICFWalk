#!/usr/bin/env bash
# Instrument revision 2026-10-14, step 2: red before green for the correction made while step 2 was
# verified, run on step 2's code commit after its gate and operations.
#
# Step 2's CFML first asked isNull() about values in seven components. On Adobe ColdFusion 2023 isNull()
# is also true for a string whose value is "null", in any letter case (Phase 8 defect P8-08), so the read
# path dropped an Other text "Null" and the save validator skipped a value code "null" instead of refusing
# it. The portability rules refused the calls (rule 7), and the components now ask structKeyExists and
# arrayIsDefined; MULTI-E3 saves an Other text "Null" and refuses the code "null".
#
# Red: the seven components as they were before the correction (95ddaf4, the checkpoint before it; the
# script prints the difference, which is the correction alone), with the tests as committed:
#
#   static      tests/node/cfml-portability.test.mjs (no engine): rule 7 names the isNull() calls
#   coldfusion  tests/node/browser-multiple.test.mjs against ColdFusion 2023: MULTI-E3 fails on
#               "Other's text Null is text", and the five others pass
#   lucee       the same file against Lucee: all six pass, which is how the defect got past Lucee
#
# Green: nothing reverted, the same three runs pass. The application reloads its components after every
# change: ColdFusion through the development reinit (its trusted cache is off), Lucee by a restart. Run
# with Google Fonts out of the browser's reach, as the gate runs. The tree is checked clean at the end.
#
# usage: red.sh <expected HEAD> <output directory outside the repository>
set -uo pipefail
REPO=/home/user/ICFWalk
BASE=95ddaf435bef59738d27a0449e78bcec203c110c
FILES=(src/instrument/DefinitionValidator.cfc src/instrument/RenderModelBuilder.cfc src/instrument/VisibilityEngine.cfc src/reports/ReportService.cfc src/walks/WalkPayloadValidator.cfc src/walks/WalkRepository.cfc src/walks/WalkSummaryFormatter.cfc)
ACF_DB=icfwalk_acf_gate
EXPECTED="$1"; OUT="$2"
NO_PROXY_ENV=(env -u HTTPS_PROXY -u HTTP_PROXY -u https_proxy -u http_proxy -u ALL_PROXY -u all_proxy)
cd "$REPO"
echo "== $(date -u +%Y-%m-%dT%H:%M:%SZ) the script"; cat "$0"
[ "$(git rev-parse HEAD)" = "$EXPECTED" ] || { echo "HEAD is not $EXPECTED"; exit 1; }
[ -z "$(git status --porcelain=v1 --untracked-files=all)" ] || { echo "the tree is not clean"; exit 1; }
echo "HEAD $(git rev-parse HEAD) tree $(git rev-parse 'HEAD^{tree}'), clean"
mkdir -p "$OUT"
RESULT=0
echo; echo "== $(date -u +%Y-%m-%dT%H:%M:%SZ) the correction: git diff $BASE HEAD -- the seven components"
git diff "$BASE" HEAD -- "${FILES[@]}"

reload() { # reload <coldfusion|lucee>
  if [ "$1" = coldfusion ]; then
    curl -sS -o /dev/null -w "coldfusion reinit %{http_code}\n" --max-time 300 "http://127.0.0.1:8500/index.cfm/api/health?reinit=1"
  else
    tools/runtime/lucee-down.sh > /dev/null 2>&1; tools/runtime/lucee-up.sh > "$OUT/lucee-up-last.txt" 2>&1; echo "lucee restarted: $(tail -1 "$OUT/lucee-up-last.txt" | cut -c1-120)"
  fi
}
browser() { # browser <engine> <name>: browser-multiple against that engine
  local engine="$1" name="$2"
  if [ "$engine" = coldfusion ]; then
    "${NO_PROXY_ENV[@]}" ICFWALK_BASE_URL=http://127.0.0.1:8500 ICFWALK_DB_NAME="$ACF_DB" ICFWALK_REQUIRE_APP=1 ICFWALK_SCREENSHOT_DIR="$OUT/shots" node --test tests/node/browser-multiple.test.mjs > "$OUT/$name.tap" 2>&1
  else
    "${NO_PROXY_ENV[@]}" ICFWALK_BASE_URL=http://127.0.0.1:8888 ICFWALK_REQUIRE_APP=1 ICFWALK_SCREENSHOT_DIR="$OUT/shots" node --test tests/node/browser-multiple.test.mjs > "$OUT/$name.tap" 2>&1
  fi
  local rc=$?
  grep -E "^(ok|not ok) |^# (tests|pass|fail) " "$OUT/$name.tap"
  echo "[exit $rc]"
  return $rc
}
static() { # static <name>
  node --test tests/node/cfml-portability.test.mjs > "$OUT/$1.tap" 2>&1; local rc=$?
  grep -E "^(ok|not ok) |^# (tests|pass|fail) " "$OUT/$1.tap"; echo "[exit $rc]"; return $rc
}

echo; echo "== $(date -u +%Y-%m-%dT%H:%M:%SZ) red: the seven components reverted to ${BASE:0:7}"
for f in "${FILES[@]}"; do git show "$BASE:$f" > "$f"; done
echo "\$ git status --porcelain=v1"; git status --porcelain=v1
echo; echo "-- static"
static red-static; RC=$?
if [ "$RC" != 0 ] && grep -q "not ok 7 - rule 7" "$OUT/red-static.tap" && [ "$(grep -c "isNull(" "$OUT/red-static.tap")" -gt 0 ]; then echo "RED as required: rule 7 names the isNull() calls"; else echo "NOT RED as required"; RESULT=1; fi
echo; echo "-- coldfusion"
reload coldfusion
browser coldfusion red-coldfusion; RC=$?
if [ "$RC" != 0 ] && grep -q "^not ok 3 - MULTI-E3" "$OUT/red-coldfusion.tap" && grep -qF "Other's text Null is text" "$OUT/red-coldfusion.tap" && [ "$(grep -cE '^not ok ' "$OUT/red-coldfusion.tap")" = 1 ]; then
  echo "RED as required: on ColdFusion 2023 MULTI-E3 alone fails, on the Other text \"Null\""
else echo "NOT RED as required"; RESULT=1; fi
echo; echo "-- lucee"
reload lucee
browser lucee red-lucee; RC=$?
if [ "$RC" = 0 ]; then echo "As expected, Lucee passes the uncorrected components: its isNull() answers false for the text \"null\""; else echo "UNEXPECTED: Lucee failed the uncorrected components"; RESULT=1; fi

echo; echo "== $(date -u +%Y-%m-%dT%H:%M:%SZ) green: nothing reverted"
git checkout -- "${FILES[@]}"
echo "\$ git status --porcelain=v1"; S=$(git status --porcelain=v1); echo "${S:-<empty>}"
echo; echo "-- static"; static green-static || RESULT=1
echo; echo "-- coldfusion"; reload coldfusion; browser coldfusion green-coldfusion || RESULT=1
echo; echo "-- lucee"; reload lucee; browser lucee green-lucee || RESULT=1

rm -rf "$OUT/shots"
STATUS=$(git status --porcelain=v1 --untracked-files=all); echo; echo "status after: ${STATUS:-<empty>}"
[ -z "$STATUS" ] || RESULT=1
[ "$(git rev-parse HEAD)" = "$EXPECTED" ] || RESULT=1
[ "$RESULT" = 0 ] && echo "RED BEFORE GREEN CONFIRMED" || echo "RED BEFORE GREEN NOT CONFIRMED"
exit $RESULT
