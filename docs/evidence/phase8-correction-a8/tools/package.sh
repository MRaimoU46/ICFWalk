#!/usr/bin/env bash
# A8-02: builds the offline-verifiable delivery of the Phase 8 correction from the final records-only commit.
#
# No commit can name itself, so what binds the archive to the tested code is generated here, from the
# already-final records-only commit, outside the repository, and put into the archive by `git archive
# --add-file`:
#
#   DELIVERY-IDENTITY.md   the source commit, its parent and tree; the correction code commit and tree;
#                          the audited Phase 8 tip, the tested Phase 8 code, the Phase 0-7 freeze tip and
#                          frozen code; the branch; the restricted diff from the code commit to the source
#                          commit with its (empty) output, and that range's full stat and name-status;
#                          the evidence directory's checksum verification; the clean status immediately
#                          before packaging; the exact archive command; the archive name and ZIP comment.
#   PAYLOAD-SHA256SUMS     the SHA-256 of every file in the archive except itself.
#
# `git archive` writes the source commit as the ZIP comment. The archive is then tested (integrity, unsafe
# or duplicate or case-colliding paths, links, Git metadata, every checksum, and the source tree rebuilt
# from the extracted files) by tools/verify-delivery.sh, and its own SHA-256 goes into <archive>.sha256
# beside it -- outside the archive, so that nothing is circular.
#
# usage: package.sh <records-only commit> <correction code commit> <output directory outside the repository>
set -uo pipefail
REPO=/home/user/ICFWalk
BRANCH=claude/icfwalk-phase-8-correction-cgsc7q
R="$1"; C="$2"; OUT="$3"
AUDITED_TIP=10f476ba9a69359f23a259be0e903afeed64b415
P8_CODE=282a4ec27cd5d200ed190b134c0145632a970cee
FREEZE_TIP=133f02192a99970029847bc2da2d31b9d8da06e1
FROZEN_CODE=68f9026d39ba0ff44d12d6398c5e933971dad2f4
CODE_PATHS="src app tests scripts tools database config package.json package-lock.json manifest.json .env.example"
EV=docs/evidence/phase8-correction-a8
cd "$REPO"
die() { echo "PACKAGING STOPPED: $*"; exit 1; }
step() { echo; echo "== $(date -u +%Y-%m-%dT%H:%M:%SZ)  $*"; }

step "0. The packaging script itself"
cat "$0"

step "1. Identity immediately before packaging"
[ "$(git rev-parse --abbrev-ref HEAD)" = "$BRANCH" ] || die "not on $BRANCH"
[ "$(git rev-parse HEAD)" = "$R" ] || die "HEAD is not $R"
TREE=$(git rev-parse "$R^{tree}"); PARENTS=$(git log -1 --format=%P "$R"); CTREE=$(git rev-parse "$C^{tree}")
[ "$PARENTS" = "$C" ] || die "the records commit's parent is $PARENTS, not the correction code commit $C"
[ "$(git rev-parse "$C^")" = "$AUDITED_TIP" ] || die "the correction code commit's parent is not $AUDITED_TIP"
for a in "$AUDITED_TIP" "$P8_CODE" "$FREEZE_TIP" "$FROZEN_CODE"; do git merge-base --is-ancestor "$a" "$R" || die "$a is not an ancestor"; done
STATUS=$(git status --porcelain=v1 --untracked-files=all)
[ -z "$STATUS" ] || die "the working tree is not clean"
RESTRICTED_CMD="git diff --name-status $C $R -- $CODE_PATHS"
RESTRICTED=$(git diff --name-status "$C" "$R" -- $CODE_PATHS)
[ -z "$RESTRICTED" ] || die "the records commit changes code, tests, tools, migrations, configuration, dependencies or the manifest"
STAT=$(git diff --stat=100 "$C" "$R"); NAMES=$(git diff --name-status "$C" "$R")
P8KEPT=$(git diff --name-status "$AUDITED_TIP" "$R" -- docs/evidence/phase8)
[ -z "$P8KEPT" ] || die "the original Phase 8 evidence changed"
EVCHECK=$(cd "$EV" && sha256sum -c SHA256SUMS 2>&1); EVRC=$?
EVOK=$(printf '%s\n' "$EVCHECK" | grep -c ': OK$'); EVBAD=$(printf '%s\n' "$EVCHECK" | grep -vc ': OK$')
[ "$EVRC" = 0 ] && [ "$EVBAD" = 0 ] || die "sha256sum -c $EV/SHA256SUMS failed"
P8CHECK=$(cd docs/evidence/phase8 && sha256sum -c SHA256SUMS 2>&1); P8RC=$?
P8OK=$(printf '%s\n' "$P8CHECK" | grep -c ': OK$'); P8BAD=$(printf '%s\n' "$P8CHECK" | grep -vc ': OK$')
[ "$P8RC" = 0 ] && [ "$P8BAD" = 0 ] || die "sha256sum -c docs/evidence/phase8/SHA256SUMS failed"
echo "branch $BRANCH; source $R (tree $TREE, parent $PARENTS); code $C (tree $CTREE); clean; restricted diff empty; $EV/SHA256SUMS $EVOK OK; docs/evidence/phase8/SHA256SUMS $P8OK OK and unchanged since $AUDITED_TIP"

NAME="ICFWalk-phase8-correction-a8-${R:0:12}.zip"
PREFIX="ICFWalk-phase8-correction-a8-${R:0:12}/"
STAGE="$OUT/stage"; rm -rf "$OUT"; mkdir -p "$STAGE"
ARCHIVE_CMD="git archive --format=zip --prefix=$PREFIX --add-file=<stage>/DELIVERY-IDENTITY.md --add-file=<stage>/PAYLOAD-SHA256SUMS -o $NAME $R"

step "2. The delivery identity record"
{
cat <<EOF
# Delivery identity: ICFWalk Phase 8 correction A8

Generated at packaging, $(date -u +%Y-%m-%dT%H:%M:%SZ), from the already-final records-only commit, outside
the repository (a file inside a commit cannot name that commit), and added to the archive by
\`git archive --add-file\`. \`docs/evidence/phase8-correction-a8/tools/verify-delivery.sh\` checks everything
below offline.

## Commits

| What | Value |
| --- | --- |
| Archive source commit | \`$R\` |
| Archive source commit parent(s) | \`$PARENTS\` |
| Archive source tree | \`$TREE\` |
| Correction code commit (gated) | \`$C\` |
| Correction code tree | \`$CTREE\` |
| Correction code commit's parent: the audited Phase 8 handoff tip | \`$AUDITED_TIP\` |
| Tested Phase 8 code commit | \`$P8_CODE\` |
| Phase 0-7 records-only freeze tip | \`$FREEZE_TIP\` |
| Frozen Phase 0-7 code | \`$FROZEN_CODE\` |
| Branch | \`$BRANCH\` |

The archive source commit is the records-only commit. Its only parent is the correction code commit, the
commit the exact-commit gate and the operations ran on (\`$EV/gate-$C/\`,
\`$EV/operations-$C/\`).

## The records-only commit changes no code

\`\`\`text
\$ $RESTRICTED_CMD
${RESTRICTED:-<empty output>}
\`\`\`

Everything the records-only commit changes, relative to the correction code commit:

\`\`\`text
\$ git diff --stat=100 $C $R
$STAT

\$ git diff --name-status $C $R
$NAMES
\`\`\`

The original Phase 8 evidence is unchanged since the audited tip:

\`\`\`text
\$ git diff --name-status $AUDITED_TIP $R -- docs/evidence/phase8
${P8KEPT:-<empty output>}
\$ (cd docs/evidence/phase8 && sha256sum -c SHA256SUMS)
$P8OK files OK, $P8BAD failed
\`\`\`

The correction's evidence directory against its own checksum manifest:

\`\`\`text
\$ (cd $EV && sha256sum -c SHA256SUMS)
$EVOK files OK, $EVBAD failed
\`\`\`

## Working tree immediately before packaging

\`\`\`text
\$ git status --porcelain=v1 --untracked-files=all
${STATUS:-<empty output: clean>}
\$ git rev-parse HEAD HEAD^{tree}
$R
$TREE
\`\`\`

## The archive

| What | Value |
| --- | --- |
| File name | \`$NAME\` |
| Top-level folder | \`$PREFIX\` |
| ZIP comment | \`$R\` (written by \`git archive\`: the source commit) |
| Construction command | \`$ARCHIVE_CMD\` |
| Payload checksums | \`${PREFIX}PAYLOAD-SHA256SUMS\`: every file of the archive except itself |
| Archive checksum | \`$NAME.sha256\`, beside the archive, outside it |

The archive holds exactly the files of the source tree, under the top-level folder, plus this record and
PAYLOAD-SHA256SUMS. With those two set aside, \`git write-tree\` over the extracted files reproduces the
source tree \`$TREE\`.
EOF
} > "$STAGE/DELIVERY-IDENTITY.md"
echo "written $STAGE/DELIVERY-IDENTITY.md ($(wc -c < "$STAGE/DELIVERY-IDENTITY.md") bytes)"

step "3. The payload checksum manifest"
mkdir -p "$OUT/payload"; git archive --format=tar "$R" | tar -x -C "$OUT/payload"
cp "$STAGE/DELIVERY-IDENTITY.md" "$OUT/payload/DELIVERY-IDENTITY.md"
(cd "$OUT/payload" && find . -type f | sed 's|^\./||' | LC_ALL=C sort | while IFS= read -r f; do sha256sum "$f"; done) > "$STAGE/PAYLOAD-SHA256SUMS"
echo "PAYLOAD-SHA256SUMS: $(wc -l < "$STAGE/PAYLOAD-SHA256SUMS") files (the source tree's $(git ls-tree -r --name-only "$R" | wc -l) and DELIVERY-IDENTITY.md)"
rm -rf "$OUT/payload"

step "4. The archive"
echo "\$ $ARCHIVE_CMD"
git archive --format=zip --prefix="$PREFIX" --add-file="$STAGE/DELIVERY-IDENTITY.md" --add-file="$STAGE/PAYLOAD-SHA256SUMS" -o "$OUT/$NAME" "$R" || die "git archive failed"
(cd "$OUT" && sha256sum "$NAME" > "$NAME.sha256")
echo "$(cat "$OUT/$NAME.sha256")"
echo "size $(stat -c %s "$OUT/$NAME") bytes; ZIP comment $(python3 -c 'import sys,zipfile;print(zipfile.ZipFile(sys.argv[1]).comment.decode())' "$OUT/$NAME")"
cp "$STAGE/DELIVERY-IDENTITY.md" "$OUT/DELIVERY-IDENTITY.md"

step "5. The archive, verified as a recipient would (no repository, no network)"
bash "$EV/tools/verify-delivery.sh" "$OUT/$NAME" "$OUT/verify"; VRC=$?
rm -rf "$OUT/verify"
[ "$VRC" = 0 ] || die "the delivery did not verify"

step "6. Identity after packaging"
git rev-parse HEAD 'HEAD^{tree}'; S=$(git status --porcelain=v1 --untracked-files=all); echo "status: ${S:-<clean>}"
[ -z "$S" ] && [ "$(git rev-parse HEAD)" = "$R" ] || die "packaging changed the repository"
echo; echo "PACKAGED $NAME from $R"
