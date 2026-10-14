#!/usr/bin/env bash
# The Google Fonts CORS failure is not this change's: the FROZEN Phase 8 code fails the same way.
#
# A detached worktree of 452bd26 (the Phase 8 freeze records commit, whose code is the frozen b73f519)
# outside the repository is served by its own Lucee on port 8899 against the same development database,
# and one frozen browser test file, browser-email.test.mjs, runs from that worktree twice:
#
#   1. with the container's proxy variables, so Chromium can reach Google Fonts: it must fail, and fail
#      only on "Access to font ... blocked by CORS policy: Request header field x-icfwalk-dev-subject";
#   2. without them, as every gate runs: it must pass.
#
# usage: reproduce.sh <frozen worktree> <output directory>
set -uo pipefail
WT="$1"; OUT="$2"
mkdir -p "$OUT"
cd "$WT"
echo "== worktree $(git rev-parse HEAD) tree $(git rev-parse 'HEAD^{tree}')"
git status --porcelain=v1 | grep -v '^?? node_modules$' | grep -v '^?? \.env$' || echo "worktree clean (node_modules link and .env aside, both git-ignored in the repository)"
ICFWALK_PORT=8899 tools/runtime/lucee-up.sh 2>&1 | tail -1
export ICFWALK_BASE_URL=http://127.0.0.1:8899
echo "== 1. fonts reachable (proxy variables kept)"
ICFWALK_REQUIRE_APP=1 ICFWALK_SCREENSHOT_DIR="$OUT/shots-1" node --test tests/node/browser-email.test.mjs > "$OUT/1-fonts-reachable.tap" 2>&1; R1=$?
grep -E "^(ok|not ok) |^# (tests|pass|fail) " "$OUT/1-fonts-reachable.tap"
echo "[exit $R1]"
echo "distinct page errors reported:"; grep -oE "Access to font at '[^']*' from origin '[^']*' has been blocked by CORS policy: [^\"]*" "$OUT/1-fonts-reachable.tap" | sort | uniq -c
OTHER=$(grep -E '^\s+\+\s+"' "$OUT/1-fonts-reachable.tap" | grep -v "blocked by CORS policy: Request header field x-icfwalk-dev-subject" | wc -l)
echo "page errors other than the font CORS refusal: $OTHER"
echo "== 2. fonts out of reach (proxy variables removed, as the gate runs)"
env -u HTTPS_PROXY -u HTTP_PROXY -u https_proxy -u http_proxy -u ALL_PROXY -u all_proxy ICFWALK_REQUIRE_APP=1 ICFWALK_SCREENSHOT_DIR="$OUT/shots-2" node --test tests/node/browser-email.test.mjs > "$OUT/2-fonts-out-of-reach.tap" 2>&1; R2=$?
grep -E "^(ok|not ok) |^# (tests|pass|fail) " "$OUT/2-fonts-out-of-reach.tap"
echo "[exit $R2]"
ICFWALK_PORT=8899 tools/runtime/lucee-down.sh >/dev/null 2>&1 || kill "$(cat .runtime/lucee.pid)" 2>/dev/null
rm -rf "$OUT/shots-1" "$OUT/shots-2"
if [ "$R1" != 0 ] && [ "$OTHER" = 0 ] && [ "$R2" = 0 ]; then echo "REPRODUCED: the frozen code fails only on the font CORS refusal with Google Fonts reachable, and passes without"; else echo "NOT REPRODUCED as stated"; exit 1; fi
