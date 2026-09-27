#!/usr/bin/env bash
# Copies the gate's and the operations' outputs into the staged evidence (outside the repository), runs the
# after-gate checks that read them, and checks the staged directory for secret values. Screenshots the gate
# wrote outside the repository are not copied (the Phase 8 gate kept none either).
set -euo pipefail
SP=/tmp/claude-0/-home-user-ICFWalk/a404c4d2-07c0-5fa4-b380-b1493028718c/scratchpad
REPO=/home/user/ICFWalk
A=$SP/a8
C=b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d
G=$A/gate-$C
O=$A/operations-$C
grep -q "^GATE PASSED for $C" $SP/gate-run/gate-transcript.txt || { echo "the gate did not pass"; exit 1; }
grep -q "^OPERATIONS PASSED on $C" $SP/ops-run/ops-transcript.txt || { echo "the operations did not pass"; exit 1; }
rm -rf "$G" "$O"; mkdir -p "$G/lucee" "$G/acf" "$O"

# The gate
cp $SP/gate/gate.sh "$G/gate.sh"
cp $SP/gate-run/gate-transcript.txt "$G/gate-transcript.txt"
cp $SP/gate-run/out/baseline-names.txt "$G/baseline-names.txt"
for e in lucee acf; do cp $SP/gate-run/out/$e/npm-test.tap $SP/gate-run/out/$e/passing-names.txt "$G/$e/"; done
cp $A/tools/cfml-names.sh "$G/cfml-names.sh"
{ echo "\$ tools/cfml-names.sh $C lucee/npm-test.tap acf/npm-test.tap   (after the gate, in the repository at $C; reads git objects and the TAP only)";
  echo "at $(date -u +%Y-%m-%dT%H:%M:%SZ), HEAD $(git -C $REPO rev-parse HEAD), status: $(git -C $REPO status --porcelain=v1 --untracked-files=all | wc -l) entries";
  set +e; (cd $REPO && bash $A/tools/cfml-names.sh $C "$G/lucee/npm-test.tap" "$G/acf/npm-test.tap"); echo "[exit $?]"; set -e; } > "$G/cfml-names-check.txt" 2>&1
rm "$G/cfml-names.sh"
grep -q "^EVERY CFML TEST FUNCTION PASSED BY NAME" "$G/cfml-names-check.txt" || { echo "the CFML names check failed"; cat "$G/cfml-names-check.txt"; exit 1; }

# The operations
cp $SP/gate/ops.sh "$O/ops.sh"
cp $SP/ops-run/ops-transcript.txt "$O/ops-transcript.txt"
for d in $SP/ops-run/out/*/; do cp -r "$d" "$O/"; done
for f in $SP/ops-run/out/*.txt; do [ -f "$f" ] && cp "$f" "$O/"; done

# The first operations run (OPERATIONS FAILED: the ColdFusion live red was not observed), the diagnosis
# of why, and the targeted check of the harness fix, kept beside the passing run.
X="$O/attempt-1-coldfusion-live-red-not-observed"
mkdir -p "$X/diagnosis" "$X/targeted-check-after-the-fix"
cp $SP/gate/ops-attempt1.sh "$X/ops.sh"
cp $SP/ops-run-attempt1/ops-transcript.txt "$X/ops-transcript.txt"
for d in $SP/ops-run-attempt1/out/*/; do cp -r "$d" "$X/"; done
for f in $SP/ops-run-attempt1/out/*.txt; do [ -f "$f" ] && cp "$f" "$X/"; done
grep -v '^chmod 755 "\$tree"   # ColdFusion (cfuser) must read the bind-mounted tree$' $SP/red-acf-diag.sh > "$X/diagnosis/red-acf-diag.sh"
cp $SP/red-diag/transcript.txt "$X/diagnosis/transcript.txt"
cp $SP/red-diag/out/* "$X/diagnosis/"
cp $SP/red-acf-diag.sh "$X/targeted-check-after-the-fix/red-acf-diag.sh"
cp $SP/red-fixed/transcript.txt "$X/targeted-check-after-the-fix/transcript.txt"
cp $SP/red-fixed/out/* "$X/targeted-check-after-the-fix/"
cp $SP/attempt1-README.md "$X/README.md"

# Tools used after the gate
cp $SP/secret-scan.sh "$A/tools/secret-scan.sh"
cp $SP/stage-final.sh "$A/tools/stage-final.sh"

# No secret value of this environment anywhere in the staged evidence
bash $SP/secret-scan.sh "$A" $SP/extra-secrets.txt
echo "staged: $(find "$A" -type f | wc -l) files, $(du -sh "$A" | cut -f1)"
