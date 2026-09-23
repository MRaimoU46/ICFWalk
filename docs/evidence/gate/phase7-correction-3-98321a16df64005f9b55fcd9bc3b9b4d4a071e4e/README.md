# Exact-commit gate evidence for `98321a16df64005f9b55fcd9bc3b9b4d4a071e4e`

Everything in this directory describes commit `98321a16df64005f9b55fcd9bc3b9b4d4a071e4e` (tree `01ce5e6d357b1ca452369fecae0e3da811d030ac`, parent `9ef9b97b5b4ee20dd51d6ca023c0841b7ca872ba`), the gated
commit of the Phase 7 correction's third round. The directory was added by the commit after it,
which changes nothing else. Gate verdict: **GATE PASSED**.

| File | SHA-256 | Bytes | What it proves |
| --- | --- | --- | --- |
| `phase7-correction-3-98321a16df64005f9b55fcd9bc3b9b4d4a071e4e-gate-transcript.txt` | `62c4cc06e6b98cbaaf8ebe95e9c4330aca2878d1ae1110fde594e68731c0024c` | 122791 | The raw exact-commit gate of the commit: identity before (commit, tree, parent, every ancestor, clean tree including untracked files, branch tracking, remote), a brand-new SQL Server container, migrations 001-007 and their re-application, 001 refused, application start, seed, the full suite with the application required, totals, and identity after. |
| `phase7-correction-3-98321a16df64005f9b55fcd9bc3b9b4d4a071e4e-environment.md` | `6c612e25ea71551f967b969a213c2cccd31aa7e1d1e5c7e0c7b8cd6e17663159` | 7924 | Versions as executed, configuration with secrets redacted, and the transcript, source archive and push record hashes; the source archive is checked to reproduce the commit's tree. |
| `phase7-correction-3-98321a16df64005f9b55fcd9bc3b9b4d4a071e4e-push.txt` | `7faf4f547eea262355025faa173765bea688c66adcee1bc709ad37328245a0c7` | 633 | The normal (fast-forward) push of the commit and the remote branch hash afterwards. |
| `phase7-correction-3-98321a16df64005f9b55fcd9bc3b9b4d4a071e4e-mutations.txt` | `8a357b1b57b83575b96d0527d4abaf4aa2889ac3ea009f27e40758b5e420a7bb` | 34606 | Sixteen deliberate mutations of the commit's report code, run against its own tests: each diff, each red result, each byte-identical restore (SHA-256 before and after). |
| `gate.sh` | `d686a078a234c91c8fbfeaadbd657acc9fe88859c9f51918cbd8d83e94fd0df4` | 8074 | The gate script (also printed in transcript section 0). |
| `mutate.py` | `b993b2e6d10d20224ff288db18290fec5df28ec6e70684dc55153d6203aa3b6d` | 8143 | The mutation harness. |
| `envrecord.py` | `73b474240a32ac02409976b2749ffc6d74152b9188e3cb22cf4465155e642611` | 11370 | The script that wrote the environment record. |

`SHA256SUMS` lists every file here, this README included.

## Check it from a download of the branch (no git metadata needed)

1. In this directory: `sha256sum -c SHA256SUMS`.
2. The code under test is exactly the gated tree. Copy the download, delete this directory
   (`docs/evidence/gate/phase7-correction-3-98321a16df64005f9b55fcd9bc3b9b4d4a071e4e`, and `docs/evidence/gate` if it is then empty), and in the copy's root
   run `git init -q && git add -A && git write-tree`. It prints `01ce5e6d357b1ca452369fecae0e3da811d030ac`, the tree the transcript
   records for `98321a16df64005f9b55fcd9bc3b9b4d4a071e4e` in sections 1 and 11.
3. Read the transcript: section 1 (identity and clean tree before), 6-8 (a new container, migrations,
   start, seed), 9-10 (the full suite and its totals), 11 (identity and clean tree after), and the last
   line, `GATE PASSED for 98321a16df64005f9b55fcd9bc3b9b4d4a071e4e`.

## Check it with git (the handoff bundle's git bundle, or the repository)

```
git rev-parse 98321a16df64005f9b55fcd9bc3b9b4d4a071e4e^{tree} 98321a16df64005f9b55fcd9bc3b9b4d4a071e4e^     # 01ce5e6d357b1ca452369fecae0e3da811d030ac / 9ef9b97b5b4ee20dd51d6ca023c0841b7ca872ba
git diff --stat 98321a16df64005f9b55fcd9bc3b9b4d4a071e4e <the branch head>   # only docs/evidence/gate/phase7-correction-3-98321a16df64005f9b55fcd9bc3b9b4d4a071e4e/
git merge-base --is-ancestor a219d9e0987b85b1a0b587fd62effa4e0ad1ffde 98321a16df64005f9b55fcd9bc3b9b4d4a071e4e && echo baseline-ok
```
