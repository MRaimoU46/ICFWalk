# Instrument revision 2026-10-14, step 2: evidence

Branch `claude/icfwalk-phase-8-correction-cgsc7q`, starting from step 1's records commit
`9825d1052a295bbef7df4ed132a626950bf5bb9b`. Step 2's **code commit is
`7a639ac41e1253dda75086325419c5764d391755`** (tree `fa4fdea1be2447950b37b974adac57ebf715525b`). The
commits between them are step 2's: five checkpoints marked "not gated", made so the work would survive the
session's container, then the three commits that completed it. The gate covers the whole change from
`9825d10`. The commit that adds this directory changes records, and corrects one sentence of
`docs/INSTRUMENT_REVISION_2026-10-14.md` that the red-before-green run below disproved. What step 2 is, and
why, is `docs/INSTRUMENT_REVISION_2026-10-14.md`, "Step 2".

**Not audited, not frozen, not in service.** The 2026-10-14 version is a DRAFT document until an
administrator imports and publishes it, and this release needs migration 008 applied before it is
deployed. Phase 8's frozen code (`b73f519`) and records (`bbb4d15`, `452bd26`) and step 1's records are
unchanged; this change adds to them.

| Directory or file | What it holds |
| --- | --- |
| `gate/` | The exact-commit gate of `7a639ac`: `gate.sh`, its transcript, each engine's TAP and passing names, and step 1's gate names they are compared with; `stopped-edea2fa-transcript.txt` is a first run on the commit before, stopped by hand (below) |
| `operations/` | The operations scenarios on `7a639ac`, on both engines: `ops.sh`, its transcript, and each scenario's TAP and JSON record |
| `red/` | Red before green for the portability correction made while step 2 was verified, with the seven components reverted to the checkpoint before it and the tests unchanged; `red/isnull-probe/` is the probe that explains its result |
| `environment.md` | What differs from step 1's environment record |
| `SHA256SUMS` | Every file here but itself |

## Results

| Run | Result |
| --- | --- |
| The gate of `7a639ac` (`gate/`) | **GATE PASSED.** Node/HTTP/Playwright 324/324 and CFML 557/557 on Lucee 6.2.8.20, and 324/324 and 557/557 on Adobe ColdFusion 2023 Update 25 (`ColdFusion Server 2023,0,25,330977`), with 0 failed, skipped, todo or cancelled, each on a brand-new SQL Server database migrated 001 to 008, with 002 to 008 re-applied and 001 refused. `test:package` 32/32, `validate:handoff` 51 checks, and the revision document current (`npm run revision:check`). All 316 Node tests step 1's gate passed pass on both engines, both engines passed the same names, and the 8 new names are MULTI-E1 to MULTI-E6, the 008 schema test and the 2026-10-14 workbook round-trip. The CFML suites ran step 1's 548 test functions, every one still present, plus the 9 of `MultipleValuesTest` and `MultipleValuesReportTest`. The change touches the database directory only by adding 008 and describing it, and no dependency, supplied source or baseline, or earlier evidence |
| Operations on `7a639ac` (`operations/`) | **OPERATIONS PASSED.** Restart during autosave (ColdFusion 3/3, Lucee 3/3), the production profile (ColdFusion, Lucee), the readiness probe (ColdFusion, Lucee: 503 `missing` before the migrations, 200 after them, 503 `outdated` with 008 undone and 200 once it is applied again), upgrade and rollback (a Phase 6 installation upgraded with 007 and 008; this release; the frozen release; then the release before step 2 on walks holding several values), and the database operations (3/3: backup and restore, the killed and the refused migration). The verification environment put back with both engines answering 200 and no scratch database or login left |
| Red before green (`red/`) | **The static red confirmed; the behavioral red not observed, and why.** With the seven components reverted to `95ddaf4`, the portability rules fail on rule 7, naming the `isNull()` calls. The browser suite passes on Lucee, as `red.sh` expected, and also passes on ColdFusion 2023, which `red.sh` expected to fail: so the script's verdict is RED BEFORE GREEN NOT CONFIRMED. The probe shows the correction changed no behavior (below). With nothing reverted, all three runs pass, and the tree is clean afterwards |

## Why the ColdFusion red was not observed

`red.sh`'s header states the expectation the run was written to prove: that on ColdFusion 2023 the
uncorrected read path dropped an Other text "Null" and the save validator skipped a value code "null". The
run disproved it, and the script is kept exactly as it ran. `red/isnull-probe/` asks each engine, through
the maintenance test runner, which forms of `isNull()` answer true for the text "null"
(`probe-output.txt`): on ColdFusion 2023 Update 25, a struct member (`s.k`, a member of parsed JSON) and the
`arguments` scope (`arguments.x`, `arguments.dim.multiple`) do; a plain local variable, an array element or
a for-in variable held in a local, a query cell and a literal do not. On Lucee none does.

The fourteen calls rule 7 refused fall into the two groups:

| Calls | Form | Why the outcome was the same before the correction |
| --- | --- | --- |
| `isNull(c)`, `isNull(e)`, `isNull(valueCode)`, `isNull(text)`, `isNull(pick)` (VisibilityEngine, WalkPayloadValidator, WalkRepository, WalkSummaryFormatter) | local variables | The quirk does not reach a local, and these are where step 2 held the texts a person sends: a value code, an Other text |
| `isNull(settings.multiple)`, `isNull(arguments.settings.multiple)`, `isNull(arguments.v.selectedValueCodes)`, `isNull(dim.multiple)`, `isNull(arguments.dim.multiple)`, `isNull(arguments.settingsJson)`, `isNull(row.settings)`, `isNull(s.multiple)`, `isNull(v.selectedValueCodes)` | members and arguments | Each is followed by a check that refuses the text "null" anyway (`isJsonBoolean`, `isBoolean`, `isArray`, `isStruct`, `isJSON`), so a "null" there was refused or ignored either way |

So the correction brought step 2's CFML in line with the portability rules, which remain the guard (a future
change could pass a typed text through `arguments`), and changed nothing a person could see on either
engine. MULTI-E3's "Null" and "null" cases stay as regression tests. Phase 8's description of P8-08
("true for any string whose value is null") stays as Phase 8 recorded it; this probe narrows it, for
ColdFusion 2023 Update 25 and the forms probed.

## How each was run

- `gate/gate.sh 7a639ac41e1253dda75086325419c5764d391755 <directory outside the repository>`, its output
  in `gate/gate-transcript.txt` (the last line, `gate exit=0`, is the wrapper's record of the script's exit
  status). The TAP of each engine's `npm test` and the names it passed are `gate/lucee/` and `gate/acf/`;
  `gate/baseline-names.txt` is step 1's gate list they are compared with. Screenshots (95 per engine) were
  written outside the repository and are not kept.
- `operations/ops.sh 7a639ac41e1253dda75086325419c5764d391755 <directory outside the repository>`, after
  the gate, with ColdFusion up from the gate; transcript `operations/ops-transcript.txt` (last line
  `ops exit=0`, the wrapper's).
- `red/red.sh 7a639ac41e1253dda75086325419c5764d391755 <directory outside the repository>`, after the
  operations, with Lucee on the gate's development database and ColdFusion on the gate's ColdFusion
  database, and Google Fonts out of the browser's reach; transcript `red/red-transcript.txt` (last line
  `red exit=1`, the wrapper's), TAP `red/*.tap`. ColdFusion's trusted cache is off (its runtime
  configuration in the container says `trustedCacheEnabled` false), so its development reinit compiled the
  reverted components.
- `red/isnull-probe/ZzIsNullProbeTest.cfc` was copied to `tests/cfml/specs/`, run on each engine through
  `POST /api/maintenance/tests/run?filter=ZzIsNullProbe`, and removed; the output is `probe-output.txt`.
  It fails on purpose, to report every answer in its message. It was never committed under `tests/`.

`gate/gate.sh`, `operations/ops.sh` and `red/red.sh` are byte for byte the copies their transcripts print.

**The stopped run.** The gate first ran on `edea2fa`, the commit before `7a639ac`. While its Lucee suite
ran, with no failure so far, the Excel round-trip of the 2026-10-14 version turned out to have no standing
test (it had been checked by hand and needed no change). The run was stopped by hand, the test was added as
`7a639ac`, and the gate was run again from the start on that commit. The stopped run's transcript is kept as
it was when stopped.

No transcript or TAP file here holds a password, token or proxy credential: each was checked against the
session's generated values before it was added.
