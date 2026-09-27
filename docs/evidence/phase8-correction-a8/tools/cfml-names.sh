#!/usr/bin/env bash
# A8: after the gate, from its TAP files. Checks by name, not only by count, that every CFML test function
# ran and passed on each engine: the expected names are Spec.testFunction for every `function test...` of
# every spec at the code commit, the passed names are the CFML runner's "# Spec.test: passed" lines. It
# also names which expected tests are the tested Phase 8 code's (282a4ec) and which this correction adds.
#
# usage: cfml-names.sh <code commit> <tap> [<tap> ...]      (run in the repository; reads git objects only)
set -uo pipefail
C="$1"; shift
P8_CODE=282a4ec27cd5d200ed190b134c0145632a970cee
T=$(mktemp -d)
names() { # names <commit>: Spec.testFunction for every spec of that commit
  for f in $(git ls-tree -r --name-only "$1" tests/cfml/specs | grep '\.cfc$'); do
    git show "$1:$f" > "$T/spec.cfc"
    for fn in $(grep -oE 'function test[A-Za-z0-9_]+' "$T/spec.cfc" | awk '{print $2}'); do echo "$(basename "$f" .cfc).$fn"; done
  done | LC_ALL=C sort
}
names "$C" > "$T/expected.txt"; names "$P8_CODE" > "$T/p8.txt"
echo "expected at $C: $(wc -l < "$T/expected.txt") (unique $(LC_ALL=C sort -u "$T/expected.txt" | wc -l)); of the tested Phase 8 code $P8_CODE: $(wc -l < "$T/p8.txt")"
echo "added by this correction: $(LC_ALL=C comm -13 "$T/p8.txt" "$T/expected.txt" | tr '\n' ' ')"
echo "of the Phase 8 code, not expected at $C: $(LC_ALL=C comm -23 "$T/p8.txt" "$T/expected.txt" | wc -l)"
RC=0
for tap in "$@"; do
  engine=$(grep -oE '^# engine=[^=]*[A-Za-z0-9.,]+' "$tap" | tail -1 | sed -E 's/^# engine=//; s/ passed$//')
  grep -E '^# [A-Za-z0-9_]+\.test[A-Za-z0-9_]+: passed$' "$tap" | sed -E 's/^# //; s/: passed$//' | LC_ALL=C sort > "$T/passed.txt"
  other=$(grep -cE '^# [A-Za-z0-9_]+\.test[A-Za-z0-9_]+: ' "$tap"); passed=$(wc -l < "$T/passed.txt")
  notrun=$(LC_ALL=C comm -23 "$T/expected.txt" "$T/passed.txt"); extra=$(LC_ALL=C comm -13 "$T/expected.txt" "$T/passed.txt")
  dup=$(uniq -d "$T/passed.txt")
  echo "$(basename "$(dirname "$tap")")/$(basename "$tap") ($engine): result lines $other, passed $passed; expected but not passed: ${notrun:-<none>}; passed but not expected: ${extra:-<none>}; passed twice: ${dup:-<none>}"
  [ -z "$notrun" ] && [ -z "$extra" ] && [ -z "$dup" ] && [ "$other" = "$passed" ] || RC=1
done
rm -rf "$T"
[ $RC = 0 ] && echo "EVERY CFML TEST FUNCTION PASSED BY NAME on every engine given" || echo "CFML NAMES CHECK FAILED"
exit $RC
