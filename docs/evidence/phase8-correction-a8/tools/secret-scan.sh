#!/usr/bin/env bash
# Checks that no secret value of this environment appears in a directory of evidence. The values are read
# from the git-ignored .env and .runtime/mssql.env and never printed: only the variable name and the files
# that contain its value are. Values shorter than 12 characters are not searched (not secrets; too common).
#
# usage: secret-scan.sh <directory> [<file with extra values, one per line>]
set -uo pipefail
DIR="$1"; EXTRA="${2:-}"
REPO=/home/user/ICFWalk
FOUND=0; CHECKED=0
check() { # check <name> <value>
  local name="$1" value="$2"
  [ "${#value}" -ge 12 ] || return 0
  CHECKED=$((CHECKED+1))
  local hits; hits=$(grep -rlF -- "$value" "$DIR" 2>/dev/null)
  if [ -n "$hits" ]; then echo "FOUND the value of $name in:"; echo "$hits" | sed 's/^/  /'; FOUND=1; fi
}
while IFS= read -r line; do
  case "$line" in ''|\#*) continue;; esac
  name="${line%%=*}"; value="${line#*=}"
  case "$name" in *PASSWORD*|*TOKEN*|*SECRET*|*KEY*) check "$name" "$value";; esac
done < <(cat "$REPO/.env" "$REPO/.runtime/mssql.env")
if [ -n "$EXTRA" ] && [ -f "$EXTRA" ]; then n=0; while IFS= read -r v; do n=$((n+1)); check "extra value $n" "$v"; done < "$EXTRA"; fi
echo "secret values checked: $CHECKED; $( [ $FOUND = 0 ] && echo 'none found' || echo 'FOUND (above)')"
exit $FOUND
