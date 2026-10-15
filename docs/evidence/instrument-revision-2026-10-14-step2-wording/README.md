# Instrument revision 2026-10-14, step 2: report wording correction, evidence

Branch `claude/icfwalk-phase-8-correction-cgsc7q`. The **code commit is
`0b6a8641538aecc38f66fe7220841188b353a879`** (tree `245b060b8651f74654c9ce10cc0ed3d4226e8fee`), whose only parent is step 2's records commit
`3e441a4992023c79d7e9ed6c21c21c4046618a21`. The commit that adds this directory changes records only.

**What it corrects.** Under the table of a field that takes several values, the Reports page said how many
walks hold at least one of its values, naming the field by its label. Visit timing's label is "Visit
occurred at the:", so the page read "Walks with at least one Visit occurred at the: value". The sentence
sits under the field's own table, so it now leaves the label out: "Walks with at least one value: N."
`tests/node/browser-multiple.test.mjs` (MULTI-E6) pins the new wording. Nothing else changes: the
change is exactly `app/assets/js/reports.js` and that test, which the gate checks from the diff.

| Directory or file | What it holds |
| --- | --- |
| `gate/` | The exact-commit gate of `0b6a864`: `gate.sh`, its transcript, each engine's TAP and passing names, and step 2's gate names they are compared with |
| `SHA256SUMS` | Every file here but itself |

## Result

**GATE PASSED.** Node/HTTP/Playwright 324/324 and CFML 557/557 on Lucee 6.2.8.20, and 324/324 and 557/557
on Adobe ColdFusion 2023 Update 25 (`ColdFusion Server 2023,0,25,330977`), with 0 failed, skipped, todo or
cancelled, each on a brand-new SQL Server database migrated 001 to 008, with 002 to 008 re-applied and 001
refused. `test:package` 32/32 and `validate:handoff` 51 checks. All 324 Node tests step 2's gate passed
pass on both engines under the same names, with none added, and the CFML suites ran step 2's 557 test
functions, every one still present.

## How it was run

`gate/gate.sh 0b6a8641538aecc38f66fe7220841188b353a879 <directory outside the repository>`, its output in
`gate/gate-transcript.txt` (the last line, `gate exit=0`, is the wrapper's record of the script's exit
status). It is step 2's gate (`../instrument-revision-2026-10-14-step2/gate/gate.sh`) with its base moved
to step 2's records commit and its baselines to step 2's results; `gate/gate.sh` is byte for byte the copy
its transcript prints. Screenshots were written outside the repository and are not kept.

Before the gate, `browser-multiple`, `browser-reports` and `reports` passed on Lucee (6/6, 7/7 and 15/15),
run one file at a time with Google Fonts out of the browser's reach, as the gate runs them.

No transcript or TAP file here holds a password, token or proxy credential: each was checked against the
session's generated values before it was added.
