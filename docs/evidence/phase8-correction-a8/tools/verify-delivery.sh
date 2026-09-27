#!/usr/bin/env bash
# A8-02: verifies a delivered archive of the Phase 8 correction offline -- no network, no repository.
#
#   1. The archive's bytes: its SHA-256 equals the sidecar's (<archive>.sha256, next to it).
#   2. The container: `unzip -t` finds no error; no entry is absolute, climbs out with "..", uses a
#      backslash or a drive letter, repeats another entry, collides with another when letter case is
#      ignored, is a symbolic link, or lies outside the one top-level folder; no Git metadata (.git) is
#      present.
#   3. The identity: the ZIP comment is the source commit that DELIVERY-IDENTITY.md names.
#   4. The payload: every file but PAYLOAD-SHA256SUMS is listed in it, and `sha256sum -c` passes for all
#      of them (the manifest leaves out only itself).
#   5. The source: with the two packaging files set aside, `git write-tree` over the extracted files
#      (a new, local, empty repository; nothing is fetched) reproduces the source tree the identity
#      record names -- the packaged source is exactly that commit's tree, byte for byte and mode for mode.
#
# usage: verify-delivery.sh <archive.zip> [<work dir>]
set -uo pipefail
ZIP="$1"; WORK="${2:-$(mktemp -d)}"
FAIL=0
ok() { echo "PASS  $*"; }
bad() { echo "FAIL  $*"; FAIL=1; }
command -v unzip >/dev/null && command -v sha256sum >/dev/null && command -v python3 >/dev/null || { echo "needs unzip, sha256sum and python3"; exit 2; }

echo "== 1. archive bytes against the sidecar"
if [ -f "$ZIP.sha256" ]; then
  (cd "$(dirname "$ZIP")" && sha256sum -c "$(basename "$ZIP").sha256") && ok "sha256 matches $(basename "$ZIP").sha256" || bad "sha256 does not match the sidecar"
else bad "no sidecar $ZIP.sha256"; fi
echo "archive sha256 $(sha256sum "$ZIP" | cut -d' ' -f1), $(stat -c %s "$ZIP") bytes"

echo "== 2. the container"
unzip -tq "$ZIP" && ok "unzip -t: no errors" || bad "unzip -t reported errors"
python3 - "$ZIP" <<'PY' || FAIL=1
import sys, zipfile, stat
z = zipfile.ZipFile(sys.argv[1])
infos = z.infolist()
names = [i.filename for i in infos]
problems = []
tops = {n.split("/", 1)[0] for n in names}
if len(tops) != 1: problems.append(f"entries under {len(tops)} top-level names: {sorted(tops)[:5]}")
seen, folded = set(), {}
for i in infos:
    n = i.filename
    if n.startswith("/") or n.startswith("\\") or (len(n) > 1 and n[1] == ":"): problems.append(f"absolute path {n}")
    if "\\" in n: problems.append(f"backslash in {n}")
    if any(part == ".." for part in n.split("/")): problems.append(f"'..' in {n}")
    if any(part == ".git" for part in n.split("/")): problems.append(f"Git metadata {n}")
    if n in seen: problems.append(f"duplicate {n}")
    seen.add(n)
    k = n.lower()
    if k in folded and folded[k] != n: problems.append(f"case-fold collision {folded[k]} / {n}")
    folded.setdefault(k, n)
    mode = i.external_attr >> 16
    if i.create_system == 3 and stat.S_ISLNK(mode): problems.append(f"symbolic link {n}")
files = [n for n in names if not n.endswith("/")]
print(f"entries {len(infos)} ({len(files)} files, {len(infos) - len(files)} folders), top-level folder {sorted(tops)[0] if tops else None}")
print(f"ZIP comment {z.comment.decode('ascii', 'replace')!r}")
for p in problems: print("FAIL ", p)
print("PASS  no absolute, '..', backslash, drive-letter, duplicate, case-colliding, symbolic-link or .git entry, one top-level folder" if not problems else "FAIL  container problems above")
sys.exit(1 if problems else 0)
PY

echo "== 3. identity"
rm -rf "$WORK/x"; mkdir -p "$WORK/x"; unzip -q "$ZIP" -d "$WORK/x"
TOP=$(ls "$WORK/x"); D="$WORK/x/$TOP"
[ -f "$D/DELIVERY-IDENTITY.md" ] && ok "DELIVERY-IDENTITY.md at the top of $TOP/" || bad "no DELIVERY-IDENTITY.md at the top"
SRC=$(grep -oE '^\| Archive source commit \| `[0-9a-f]{40}`' "$D/DELIVERY-IDENTITY.md" | grep -oE '[0-9a-f]{40}')
TREE=$(grep -oE '^\| Archive source tree \| `[0-9a-f]{40}`' "$D/DELIVERY-IDENTITY.md" | grep -oE '[0-9a-f]{40}')
COMMENT=$(python3 -c 'import sys,zipfile;print(zipfile.ZipFile(sys.argv[1]).comment.decode())' "$ZIP")
echo "identity record: source commit ${SRC:-<none>}, source tree ${TREE:-<none>}; ZIP comment $COMMENT"
[ -n "$SRC" ] && [ "$SRC" = "$COMMENT" ] && ok "the ZIP comment is the source commit the identity record names" || bad "ZIP comment and identity record disagree"
grep -q "$(basename "$ZIP")" "$D/DELIVERY-IDENTITY.md" && ok "the identity record names this archive file" || bad "the identity record does not name $(basename "$ZIP")"

echo "== 4. payload checksums"
if [ -f "$D/PAYLOAD-SHA256SUMS" ]; then
  (cd "$D" && sha256sum --quiet -c PAYLOAD-SHA256SUMS) && ok "sha256sum -c PAYLOAD-SHA256SUMS: $(wc -l < "$D/PAYLOAD-SHA256SUMS") files OK, 0 failed" || bad "sha256sum -c reported failures"
  (cd "$D" && find . -type f ! -name PAYLOAD-SHA256SUMS | sed 's|^\./||' | LC_ALL=C sort) > "$WORK/present.txt"
  sed -E 's/^[0-9a-f]{64}  //' "$D/PAYLOAD-SHA256SUMS" | LC_ALL=C sort > "$WORK/listed.txt"
  if cmp -s "$WORK/present.txt" "$WORK/listed.txt"; then ok "every file but PAYLOAD-SHA256SUMS is listed, and nothing else"; else bad "listed and present files differ"; diff "$WORK/listed.txt" "$WORK/present.txt" | head; fi
else bad "no PAYLOAD-SHA256SUMS"; fi

echo "== 5. the source tree"
if command -v git >/dev/null && [ -n "$TREE" ]; then
  rm -rf "$WORK/src"; cp -a "$D" "$WORK/src"; rm -f "$WORK/src/DELIVERY-IDENTITY.md" "$WORK/src/PAYLOAD-SHA256SUMS"
  GOT=$(cd "$WORK/src" && git init -q . && git -c core.autocrlf=false add --force -A . && git write-tree)
  echo "git write-tree over the extracted source: $GOT"
  [ "$GOT" = "$TREE" ] && ok "the packaged source is exactly tree $TREE" || bad "the packaged source is tree $GOT, not $TREE"
  rm -rf "$WORK/src/.git"
else echo "SKIP  git is not installed here; step 4 still binds every byte to the manifest"; fi

echo; [ "$FAIL" = 0 ] && echo "DELIVERY VERIFIED: $(basename "$ZIP")" || echo "DELIVERY NOT VERIFIED: $(basename "$ZIP")"
exit $FAIL
