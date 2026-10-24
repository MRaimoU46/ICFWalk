# Period removed from the 2026-10-14 version (the owner's decision of 2026-10-24), evidence

Branch `claude/icfwalk-phase-8-correction-cgsc7q`. The **code commit is
`6a39e4cf13b81ddeea62a7dc533b28d06618409f`** (tree `4bbd26b3a3acf6429c876cf1a0fd6444c0b5041b`). Its only parent is the district changes'
records commit `f81763d`. The commit that adds this directory changes records only.

**What the owner asked**, verbatim: "in reports we dont need the period filter anymore because we aren't
collecting i[t]". The 2026-10-14 prototype still has Period on the walk form, so they were asked whether
it should leave the form too, and chose "Remove from form and reports (Recommended)"
(`docs/OPEN_DECISIONS.md`).

**What changed.** The derivation drops Period from the 2026-10-14 version as the owner's decision
(`REMOVED_FIELDS`), the way the tag field is dropped. That takes its dimension, its eight values, its
placement, the rule that showed it for grades 6-12 and its conditional-section note. A walk on the
version that sends a Period is refused (`UNKNOWN_DIMENSION`). Its reports have no Period filter or table
with no change to the report code, because that code reads its fields from the version. The 2026-09-17
version keeps Period for its walks. Definitions checksum
`aa5542cdb2dec11aebc64b8fa4a81ec3fa10b9dfa15b9028457c198d690a967a`.

| Directory or file | What it holds |
| --- | --- |
| `gate/` | The exact-commit gate of `6a39e4c`: `gate.sh`, its transcript, each engine's TAP and passing names, and the district changes' gate names they are compared with |
| `SHA256SUMS` | Every file here but itself |

## Result

**GATE PASSED** for `6a39e4c` (tree `4bbd26b3a3acf6429c876cf1a0fd6444c0b5041b`), from a clean tree, each
engine on a brand-new database migrated 001 to 008 (002 to 008 re-applied, 001 refused a second time):

| Engine | Node, HTTP, Playwright | CFML |
| --- | --- | --- |
| Lucee 6.2.8.20 | 328/328 | 559/559 |
| Adobe ColdFusion 2023 Update 25 (`ColdFusion Server 2023,0,25,330977`) | 328/328 | 559/559 |

Every one of the 327 Node test names the district changes' gate passed on both engines passes on both
engines here. The one name it did not have is REV-13, and both engines passed the same names. The 559
CFML test functions at `f81763d` all exist and ran, and this change adds none. Among them,
`MultipleValuesTest`, `MultipleValuesReportTest` and `InstrumentRevisionTest` passed on each engine on
the version without Period, `InstrumentRevisionTest` compiling it to the golden bytes.
`validate:handoff` (51 checks), `revision:check` and `test:package` (34/34) passed.

After the gate the document, imported into Lucee as a DRAFT, has the golden snapshot checksum
`cf63e781f9cd61fa6b7ed1e94bb49477f17a4ab30a3651d72927e0d27738631b` and no Period in its render model; the
draft was then discarded.

## How it was run

`gate/gate.sh 6a39e4cf13b81ddeea62a7dc533b28d06618409f <directory outside the repository>`, its output in
`gate/gate-transcript.txt` (the last line, `gate exit=0`, is the wrapper's record of the script's exit
status). It is the district changes' gate (`../district-schools-and-networks-2026-10-16/gate/gate.sh`) with
its base moved to their records commit, its identity check to this one commit, its diff check to its
thirteen files, and its baselines to that gate's results plus exactly one new Node test (REV-13) and no
new CFML test function. `gate/gate.sh` is byte for byte the copy its transcript prints. Screenshots were
written outside the repository and are not kept.

Before the gate, `test:package` (34/34), `validate:handoff`, `revision:check`, `workbook`, `browser-revision`
(6/6), `browser-multiple` (6/6) and the whole CFML suite (559/559) passed on Lucee. The CFML suite's first
run failed one spec, `ExactAssertionTest`, because an edited spec compared text through `assertNotEquals`;
it now uses `assertExactTextNotEquals`.

No transcript or TAP file here holds a password, token or proxy credential: each was checked against the
session's generated values before it was added.
