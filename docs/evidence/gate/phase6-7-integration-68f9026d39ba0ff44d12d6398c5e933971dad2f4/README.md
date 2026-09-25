# Exact-commit gate evidence for the Phase 6 and Phase 7 integration

Everything in this directory describes the merge commit `68f9026d39ba0ff44d12d6398c5e933971dad2f4`
(tree `9f8201a85cdf31b1e17745c15004f2f32ff065cc`; first parent `64507deb075e267761179d78be966b7a4d3972cc`,
the Phase 6 records tip; second parent `e0342143074f727475ae2d4cb6933fa279902f85`, the Phase 7 tip) on
`claude/icfwalk-phase-6-7-integration`. The directory was added by the commit after it, which adds
records only. Gate verdict: **GATE PASSED** (the last line of the transcript).

| File | SHA-256 | Bytes | What it is |
| --- | --- | --- | --- |
| `phase6-7-integration-gate-transcript.txt` | `76076e11fe3a8ffa7c24212ea993f57104b64038214836e77ae40063e1614057` | 141141 | The raw exact-commit gate of the merge commit: identity before (commit, tree, both parents, merge base, ancestry, every code difference from each parent accounted for, the three shared files, clean tree, remote), versions, `npm ci`, handoff validation and package tests, every JavaScript file parsed, a brand-new SQL Server container, migrations `001` to `007` with every re-application and `001` refused, the application and the seed, the full suite with the application required, totals, identity after, and the verdict. |
| `remerge-diff.txt` | `8204f4a24cf8c2a8ec8f647cfdc1068a2b3b98bc1c2d7d19e6bf77bed614e5de` | 152918 | The conflict-resolution diff: `git show --remerge-diff --format=fuller` of the merge commit. Every hand-made change in the merge, and nothing else. |
| `gate.sh` | `cc1e06799967993c6dcbb004f224be112d1d4fc3237a15d2798650146ffadbc0` | 12907 | The gate script (also printed in section 0 of the transcript). |
| `phase6-7-integration-environment.md` | `6c9854c005503745356e033495451bdfc5debb5b83fffdfd05ef528ed07ce900` | 5133 | Versions as executed, configuration with secrets left out, the results, the development run before the merge commit, and what was not run. |

`SHA256SUMS` lists every file here, this README included. The handoff for the integration audit is
`docs/evidence/phase6-7-integration-handoff.md`.

## Check it from a download of the branch

1. In this directory: `sha256sum -c SHA256SUMS`.
2. Read the transcript: section 1 (identity, both parents, ancestry, every code difference from each
   parent accounted for, the three shared files), 4 (validation and package tests), 6 to 8 (a
   brand-new SQL Server container, migrations `001` to `007` with every re-application, the
   application and the seed), 9 and 10 (the full suite and its totals), 11 (identity after), and
   the last line.

## Check it with git

```
git rev-parse 68f9026^{tree} 68f9026^1 68f9026^2
#   9f8201a85cdf31b1e17745c15004f2f32ff065cc / 64507deb075e267761179d78be966b7a4d3972cc / e0342143074f727475ae2d4cb6933fa279902f85
git diff --stat 68f9026 <the branch head>
#   only docs/evidence/ and the status text of BUILD_STATUS.md and docs/ACCEPTANCE_TRACKING.md
git show --remerge-diff --format=fuller 68f9026 | cmp - docs/evidence/gate/phase6-7-integration-68f9026d39ba0ff44d12d6398c5e933971dad2f4/remerge-diff.txt
#   no output with git 2.43 and default settings
```
