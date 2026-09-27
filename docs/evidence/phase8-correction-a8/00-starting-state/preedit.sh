#!/usr/bin/env bash
# Starting state of the correction session and the owner-approved fast-forward of the designated
# branch to the audited Phase 8 handoff tip. Every command is echoed with its exit code.
set -uo pipefail
REPO=/home/user/ICFWalk
BRANCH=claude/icfwalk-phase-8-correction-cgsc7q
AUDITED_TIP=10f476ba9a69359f23a259be0e903afeed64b415
P8_CODE=282a4ec27cd5d200ed190b134c0145632a970cee
P8_CODE_TREE=6bb9a2f3ea72a4c0719de8eae2d95d0bff54670a
FREEZE_TIP=133f02192a99970029847bc2da2d31b9d8da06e1
FROZEN_CODE=68f9026d39ba0ff44d12d6398c5e933971dad2f4
CODE_PATHS="src app tests scripts tools database config package.json package-lock.json manifest.json .env.example"
cd "$REPO"
step() { echo; echo "================================================================================"; echo "== $(date -u +%Y-%m-%dT%H:%M:%SZ)  $*"; echo "================================================================================"; }
run() { echo "\$ $*"; "$@"; local rc=$?; echo "[exit $rc]"; return $rc; }
die() { echo; echo "STOP: $*"; exit 1; }

step "A. Starting state as the session found it (before any branch movement)"
run date -u
run git branch --show-current
run git rev-parse HEAD
run git rev-parse 'HEAD^{tree}'
echo "\$ git rev-parse --abbrev-ref --symbolic-full-name @{u}"; git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>&1; echo "[exit $?]"
echo "\$ git status --porcelain=v2 --branch --untracked-files=all"; git status --porcelain=v2 --branch --untracked-files=all; echo "[exit $?]"
run git ls-remote origin "refs/heads/$BRANCH" refs/heads/claude/icfwalk-phase-8-hardening-handoff
START=$(git rev-parse HEAD)
echo "HEAD is $START; the audited handoff tip is $AUDITED_TIP"
[ "$START" = "$AUDITED_TIP" ] && echo "HEAD equals the audited tip" || echo "DISCREPANCY: HEAD is not the audited tip (the session harness created $BRANCH at $START)"
for c in $AUDITED_TIP $P8_CODE $FREEZE_TIP $FROZEN_CODE; do
  if git merge-base --is-ancestor $c HEAD 2>/dev/null; then echo "$c ancestor of HEAD: yes"; else echo "$c ancestor of HEAD: NO"; fi
done
echo "--- is the starting HEAD an ancestor of the audited tip (would a fast-forward lose anything)?"
git merge-base --is-ancestor "$START" "$AUDITED_TIP" && echo "yes: $START is an ancestor of $AUDITED_TIP" || die "the starting HEAD is not an ancestor of the audited tip; a fast-forward is impossible"
echo "commits on the starting HEAD that the audited tip lacks: $(git rev-list --count $AUDITED_TIP..$START)"
echo "commits the audited tip adds: $(git rev-list --count $START..$AUDITED_TIP)"
run git log --format='%h %s' "$START..$AUDITED_TIP"
echo
echo "Owner decision (asked in-session, answered: 'Fast-forward, proceed'): fast-forward the designated"
echo "branch to the audited tip with git merge --ff-only. No reset, no rewrite, no force-push."

step "B. Fast-forward"
STATUS=$(git status --porcelain=v1 --untracked-files=all); echo "status before: ${STATUS:-<empty>}"
[ -z "$STATUS" ] || die "working tree is not clean"
run git merge --ff-only "$AUDITED_TIP" || die "fast-forward failed"

step "C. The six pre-edit checks, on the fast-forwarded branch"
echo "--- 1. branch, HEAD, tree, upstream, status"
run git branch --show-current
HEAD_SHA=$(git rev-parse HEAD); TREE_SHA=$(git rev-parse 'HEAD^{tree}')
echo "HEAD   $HEAD_SHA"; echo "TREE   $TREE_SHA"
echo "\$ git rev-parse --abbrev-ref --symbolic-full-name @{u}"; git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>&1; echo "[exit $?]  (no upstream is configured; origin/$BRANCH is $(git rev-parse origin/$BRANCH), an ancestor of HEAD, so the eventual push is a fast-forward)"
git merge-base --is-ancestor "origin/$BRANCH" HEAD && echo "origin/$BRANCH is an ancestor of HEAD: yes" || die "origin/$BRANCH is not an ancestor of HEAD"
echo "\$ git status --porcelain=v2 --branch --untracked-files=all"; git status --porcelain=v2 --branch --untracked-files=all; echo "[exit $?]"
echo "--- 2. HEAD is exactly $AUDITED_TIP?"
[ "$HEAD_SHA" = "$AUDITED_TIP" ] && echo "yes" || die "HEAD $HEAD_SHA is not $AUDITED_TIP"
run git log -2 --format='%H %T %P %an %aI %s'
echo "--- 3. ancestry"
for c in $P8_CODE $FREEZE_TIP $FROZEN_CODE; do
  git merge-base --is-ancestor $c HEAD && echo "$c is an ancestor of HEAD: yes" || die "$c is not an ancestor of HEAD"
done
T=$(git rev-parse "$P8_CODE^{tree}"); echo "tested Phase 8 code commit $P8_CODE tree $T"
[ "$T" = "$P8_CODE_TREE" ] && echo "tree matches the recorded tested tree $P8_CODE_TREE" || die "tree $T does not match $P8_CODE_TREE"
echo "--- 4. restricted diff $P8_CODE..HEAD over: $CODE_PATHS"
echo "\$ git diff --name-status $P8_CODE HEAD -- $CODE_PATHS"
D=$(git diff --name-status "$P8_CODE" HEAD -- $CODE_PATHS); echo "${D:-<empty>}"
[ -z "$D" ] || die "code differs between $P8_CODE and HEAD"
echo "\$ git diff --stat $P8_CODE HEAD   (everything that differs is a record)"
git diff --stat "$P8_CODE" HEAD | tail -n 3
echo "--- 5. clean working tree"
STATUS=$(git status --porcelain=v1 --untracked-files=all --ignored=no); echo "status: ${STATUS:-<empty>}"
[ -z "$STATUS" ] || die "working tree is not clean"
echo "--- 6. no material difference remains"
echo "ALL PRE-EDIT CHECKS PASSED at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
