# Phase 8 baseline gate evidence

Before any Phase 8 change, the existing full gate was rerun from a clean tree on the new branch
`claude/icfwalk-phase-8-hardening-handoff` at its starting commit
`133f02192a99970029847bc2da2d31b9d8da06e1`, the Phase 0-7 records-only freeze tip, whose code is exactly
the frozen `68f9026d39ba0ff44d12d6398c5e933971dad2f4`. Verdict: **GATE PASSED (baseline reproduced)**,
the last line of the transcript: Node/HTTP/Playwright 245/245 and CFML 517/517, the frozen gate's own
totals, with 0 failed, skipped, todo and cancelled.

This directory is added by a records-only commit made after the gate finished. It changes no code.

| File | What it is |
| --- | --- |
| `phase8-baseline-gate-transcript.txt` | The raw gate: its own script, identity before (the freeze tip, the frozen code as ancestor with an empty code difference, clean tree, remote, the three frozen branches unchanged), versions, `npm ci`, handoff validation and package tests, every JavaScript file parsed, a brand-new SQL Server container, migrations `001` to `007` with every re-application and `001` refused, the application and the seed, the full suite with the application required, totals, identity after, and the verdict. |
| `gate.sh` | The gate script (also printed in section 0 of the transcript). It is the frozen integration gate's steps with the identity checks retargeted at the Phase 8 branch and the freeze tip, and the SQL Server image pinned to the frozen gate's digest. |
| `environment.md` | Versions as executed, configuration with secrets left out, results, and what was not run. |

`SHA256SUMS` lists every file here, this README included. Check it with `sha256sum -c SHA256SUMS`
from this directory.
