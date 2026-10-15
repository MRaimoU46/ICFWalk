# Instrument revision 2026-10-14

The product owner supplied a new prototype on 2026-10-14 ("the most up-to-date document that shows the
new launch page with the check boxes") and asked for it in two steps:

1. **Step 1.** Everything in the new prototype except the checkboxes, as a new version of the
   ICFWALK instrument (code `36f9db0`).
2. **Step 2.** Grade level, Content / Subject Area, Program and Visit timing as checkboxes: a walk
   holds several values of each, and reports count it under each, by the owner's rule recorded in
   `docs/OPEN_DECISIONS.md`. See "Step 2: several values per visit field" below.

The 2026-09-17 instrument is not edited. It stays the supplied baseline, the default seed and the version
every walk taken so far is pinned to.

## Files

| File | What it is |
| --- | --- |
| `source/prototype-2026-10-14.html` | The 2026-10-14 prototype. Source 1 for this version's wording, choices and behavior |
| `config/instrument-config-2026-10-14.json` | The new version's instrument document: a DRAFT of `ICFWALK`, label `2026-10-14 prototype revision` |
| `scripts/derive-instrument-revision.mjs` | Derives that document from `config/instrument-config.json` and the prototype; `--check` fails when the committed document is stale |
| `scripts/lib/prototype.mjs` | Reads a prototype's instrument tables as data (its DATA MODEL block, in an empty `node:vm` context) |
| `tests/golden/instrument-snapshot-2026-10-14.golden.json` | The new version's compiled checksums and counts |

Nothing in `source/current-prototype.html`, `config/instrument-config.json`, `manifest.json`'s handoff entries for
them, or their hashes changed.

### Source fingerprint and provenance

| Artifact | SHA-256 |
| --- | --- |
| `source/prototype-2026-10-14.html` | `25cd1be1ea475e9de096e09afb9a980ab70184eb17165fd45e2b00e009517cc8` |
| `source/current-prototype.html` (2026-09-17, unchanged) | `239531267fa1dfaedaf4e1a8842156bc90db425893781330470312e3c34a1361` |

The 2026-10-14 file was reconstructed from the prototype as the owner pasted it into the session, not
copied from the owner's file. Like the 2026-09-17 prototype it is pure ASCII, with every non-ASCII
character written as a `\uXXXX` escape. Its content (every string, list and function) is the paste's. Its
bytes may still differ from the owner's own copy (line endings, a trailing newline), and then so does the
fingerprint. If the owner's file differs, replace `source/prototype-2026-10-14.html` with it, run
`npm run revision:derive`, refresh the golden
(`node scripts/compile-snapshot.mjs config/instrument-config-2026-10-14.json --write-golden --golden=tests/golden/instrument-snapshot-2026-10-14.golden.json`),
and run the tests. Do this **before** the version is published, because a published snapshot is
immutable and records the fingerprint.

## What changed

| Area | 2026-09-17 version | 2026-10-14 version |
| --- | --- | --- |
| Rating scale | 1-5 on every rated item | **1-4** on every rated item (Part 1's two rated sections, all of Part 2, Part 3), with new definitions for every level |
| Level names | none | **Not evident, Inconsistent, Evident, Evident and student-owned**, shown in a scored item's definitions as "1 · Not evident: ..." |
| Academic Teaming (2.4) | 2 rated questions | **3**: "When the task becomes challenging, students draw on their teammates' thinking ...", shown and cleared with the component like the other two |
| Look-fors | the earlier lists | the prototype's lists for 2.1 to 2.6 (longer), 2.7 (wording), Part 1 unchanged |
| Part 1 | Adopted Curriculum, then Target/Task Alignment | **Target/Task Alignment, then Adopted Curriculum** (screen, export and email) |
| Pacing | BEHIND, ON, AHEAD | **Pacing NOT evident** first, then BEHIND, ON, AHEAD |
| Content field | "Content area / subject", with Art and Music | **"Content / Subject Area"**, with **Performing Arts** and **Visual Arts** |
| Class type field | "Class type", 8 options | **"Program"**, 17 options in the prototype's order (Advanced Placement, Advisory, AVID, Cross-Cat, DHH, Dual Credit, Dual Language, ESL, General Education, IB, Ignite, MAC, Magnet, Morning Meeting, PREP, VI, Other) |
| Content-area card | shown for Music, Art or CTE | shown for **Performing Arts, Visual Arts or CTE** |
| Other disaggregation tag(s) | a free-text field in Part 1 | **removed** |
| Grade level, Content / Subject Area, Program, Visit timing (step 2) | one value each | **several values each** (checkboxes), in the version's order |
| Header (every version) | "School District U-46" over "ICFWalk · Instructional Clarity Framework" | "School District U-46 · Instructional Clarity Framework" over **INSTRUCTIONAL WALK** |

Counts, 2026-09-17 to 2026-10-14: sections 23 to 23, items 144 to 166 (one rated question and 21 look-for
rows), response sets 29 to 30, response options 138 to 119, rules 12 to 13, dimensions 10 to 9, dimension
values 95 to 104, placements 10 to 9, placeholders 17 to 17.

`tests/node/instrument-revision.test.mjs` REV-11 proves nothing else moved: every record of the
2026-09-17 document the revision does not own is byte for byte the same record.

## Decisions

1. **A new version, not an edit.** The 2026-09-17 version is the one walks are pinned to. Published
   versions are immutable, and reports cover one version at a time (`docs/OPEN_DECISIONS.md`, "Whether
   a report may pool instrument versions"), so 1-5 and 1-4 scores are never averaged together. A walk
   started on 2026-09-17 keeps its 1-5 scale, its single tag field and its Art or Music value.
2. **Where the level names live.** In the version's `behavior.ratings.levelNames`, keyed by stored
   code, beside `behavior.ratings.scale`. The renderer shows them in the definitions of **scored** items
   only (`app/assets/js/renderer.js`, `levelNamesOf`). A version without them renders exactly as
   before. They are not option labels, because the pills show the bare level and reports and exports
   print the level as the prototype does (`3/4`). They are not a new response-option field either: the
   table has no column for it, and changing the normalized definitions shape would change the
   checksums of every version already compiled.
3. **Performing Arts and Visual Arts are new values** (`performing_arts`, `visual_arts`). This version
   does not offer Art or Music, and those two stay the 2026-09-17 version's values. Value codes are
   cross-version reporting identity, and Performing Arts is broader than Music, so continuing `music`
   under a new name would claim the two are one category. This is the reversible default: if the owner
   wants them treated as the same category, the derivation keeps the `art` and `music` codes under the
   new labels instead, before the version is published (`docs/OPEN_DECISIONS.md`).
4. **New programs are new values.** The eight programs the 2026-09-17 version had keep their codes, so a
   DHH walk and an ESL walk mean the same thing in both versions. The nine new ones are named from their
   labels the way every existing code is.
5. **The tag field is gone from this version only.** Its dimension identity stays for the 2026-09-17
   walks that use it. A walk on this version that sends one is refused (`UNKNOWN_DIMENSION`).
6. **The checkboxes are step 2**, below: several values per walk and field is a schema, save-path, rules,
   reports and export change, not instrument content alone.
7. **The recorded summary deviations carry over** (`docs/PHASE_5_IMPLEMENTATION_BRIEF.md` section 14):
   the content-area heading is the section title (14.3), Yes and No print as their labels (14.5), and
   the rest are unchanged. `tests/node/browser-revision.test.mjs` REV-E6 runs the 2026-10-14 prototype's
   own `buildSummaryText()` and `generateEmailDraftFor()` against the server's export of the same walk:
   every line is identical apart from 14.3 and 14.5, and every email draft is identical.
8. **The header belongs to the shell,** so it changes for every version at once.

## A defect this change exposed, and its correction

The My walks list titled every walk ("7 · Visual Arts") from the **current** version's model. While all
versions offered the same values that was invisible. Once a version offers different values, a walk on
another version lost the part of its title the current model did not know: a 2026-09-17 walk at "Music"
would list as just its grade after the 2026-10-14 version is published. `renderList` in
`app/assets/js/app.js` now loads the model of each other version on the list (one request per version,
cached) before titling. REV-E5 failed without the correction and passes with it.

## Putting it into service

1. Import `config/instrument-config-2026-10-14.json`: **Instrument admin**, Import, choose the file; or,
   from the server with maintenance on, `node scripts/seed-instrument.mjs --file instrument-config-2026-10-14.json`.
   The result is a DRAFT labelled `2026-10-14 prototype revision` with definitions checksum
   `4ac0f64ac250e8b8f452957a657f19bbb344f75038f696b3ab906032084187e4` and the 17 placeholder warnings.
   (Step 1's document, before its four checkbox fields took several values, had
   `b9e7d0df0c722a4861d2fdcaddc3b972e7bfc8a24a559f3ad839fecd3d95999a`.) The database must have
   migration 008 first (`database/README.md`): an application of this change answers its health
   probe `outdated` (503) until it has.
2. Preview it, and Compare it with `2026-09-17 aligned prototype`. The comparison lists the changes in
   the table above and nothing else.
3. Confirm the source file (see "Source fingerprint and provenance").
4. Publish it. New walks start on it from that moment. Walks already started stay on 2026-09-17 and open,
   save and export as they did. Retire the 2026-09-17 version when nobody needs to start walks on it.

A brand-new installation can seed this document instead of the 2026-09-17 one with the same `--file`
argument (or `ICFWALK_INSTRUMENT_CONFIG_PATH`). The test suite keeps seeding the 2026-09-17 document,
which its baselines describe.

## Step 2: several values per visit field

The 2026-10-14 prototype's launch page makes four visit fields checkboxes (`META_FIELDS` type
`"checkboxes"`): Grade level, Content / Subject Area, Program and Visit timing. A walk holds any number of
values of each, Other's text goes with Other, and the prototype's own code tests a field with "any of
these values" (`metaHas`, `metaHasAny`).

| Area | What this change does |
| --- | --- |
| The instrument | A placement's `settings.multiple: true` (version-scoped) says its field takes several values. The derivation gives it to exactly the prototype's four checkbox fields. Nothing else in any version changes, so every other version's checksums stay as they were. The authoring validator refuses a non-boolean `multiple` (`MULTIPLE_SETTING_INVALID`), one on a field that is not a list (`MULTIPLE_NOT_A_LIST`), a value code a combination could not carry (`MULTIPLE_VALUE_CODE_INVALID`: letters, digits, `_`, `-`, `.` only), codes that joined by `+` exceed 300 characters (`MULTIPLE_CODES_TOO_LONG`), and an option filter that would read such a field (`OPTION_FILTER_SOURCE_MULTIPLE`) |
| Storage | Migration 008: `icf.walk_dimension_value` holds one row per value (`selection_ordinal` 0, 1, 2 ..., in the version's value order) with the Other text on the Other row; `UQ_walk_dimension_value_selected` and `CK_walk_dimension_value_ordinal` hold the shape. Every existing row is ordinal 0 and reads as before |
| The walk state | `{ "selectedValueCodes": ["7", "8"], "otherText"?: "..." }` for such a field, and `selectedValueCode` for every other list field, on the API, in the browser and in the engines. The server checks each code, refuses duplicates and the wrong shape for the field, and orders the codes by the version; an empty list is no value |
| Rules | A condition on such a field holds for `EQUALS`/`IN` when any value matches and for `NOT_EQUALS`/`NOT_IN` when none does, in both engines (`tests/fixtures/visibility-vectors-multiple.json` is their parity contract). A school change keeps the grades the school allows and removes the rest (`DIMENSION_VALUES_REMOVED`), as the prototype does |
| The editor | A fieldset of checkboxes per field, named by its legend, in the version's order; an option filter hides the values it does not allow; Other shows its text box while ticked and clears it when unticked, as the prototype does |
| Summary, email, file name, My walks | The values joined by `", "`, Other as its text (the prototype's `metaDisplay`): "Grade level: 7, 8", `ICFWalk_7_8_ELA_Visual_Arts_2026-10-15.txt`, "Open 7, 8 · ELA, Visual Arts" |
| Live reports | Each walk counts under each of its values and once among the states (answered, not answered, hidden); a filter on one value includes a walk holding it among others. The report, the CSV (`DIMENSION_NOTE ... MULTIPLE_VALUES`) and the page say that the values can add up to more than the walks |
| Releases | A field's breakdown is the combinations of values (codes joined by `+`, one category per walk), so its categories still never overlap and add up to the block's walks, and the approved rule (D5) protects them unchanged. Each value is then published as the sum of the published combinations holding it, "at least" when one of them is withheld |

### Decisions

1. **Several values are counted the owner's way** (`docs/OPEN_DECISIONS.md`): under each value, a
   filter on one value includes them, and the totals are labelled as able to exceed the walks.
2. **Releases protect combinations, not values.** Counting a walk under each value in a release cell
   would publish overlapping counts, from which a reader could work out small groups the k = 3 rule
   withholds: 3 walks at Grade 7, 3 at Grade 8 and 5 answered mean exactly one walk was both. Protecting
   each combination of values as one category keeps the approved rule exactly as it was (categories that
   do not overlap and add up to the walks), and each value's figure is a sum of figures already
   published, which reveals nothing new. The price is that a value's figure is marked "at least" more
   often when combinations are rare. Live figures, for people who can open every walk counted, are not
   affected.
3. **The flag is a placement setting**, not a new field of the instrument's records, so no version but
   this one changes, and an option filter, a rule or a report can be refused at authoring time when it
   cannot read several values.
4. **A report leaves out a field it cannot decide exactly.** Its visibility is worked out per
   combination of one value per field (`ReportService.visibilityFor`); that is exact for a field that
   holds several values only when one `EQUALS` or `IN` condition reads it. A rule that reads it twice, or
   negates it, leaves the governed field out of the report instead of counting it wrong. No rule of the
   2026-10-14 version does either.
5. **Rolling back** to the previous release on a database with 008 works for every walk on a version
   whose fields take one value. For a walk holding several values of a field, that release shows one of
   them; a save that leaves the field alone goes through and keeps every value, and a change to the field
   fails (`UQ_walk_dimension_value_selected`) and writes nothing. Its live report counts such a walk once
   per value among the answered, it reads this release's report releases with each combination left out
   of the values, and a release it created would count a walk under each value: create no report release
   while rolled back (`docs/OPERATIONS.md`, 5.1, verified by `tests/ops/upgrade-and-rollback.test.mjs`).

## Verification

| Where | What |
| --- | --- |
| `tests/node/instrument-revision.test.mjs` (REV-01 to REV-11, no application) | The document is exactly what the derivation makes; its source fingerprint; its golden checksums; references and keys; every rated item on the prototype's 4-point scale with its exact definitions; the level names; the look-fors; Academic Teaming's third question and its rule; Part 1 order and Pacing; the visit fields, their lists and the content-area triggers; nothing else moved |
| `tests/cfml/specs/InstrumentRevisionTest.cfc` (6) | The CFML compiler produces the golden bytes (parity with the reference compiler); the authoring validator accepts it with only the 17 placeholder warnings; the real renderer builds it; the visibility engine follows the new triggers and the third Teaming question; the summary formatter prints 4-point scores |
| `tests/node/browser-revision.test.mjs` (REV-E1 to REV-E6) | Imported through Instrument admin with the golden definitions checksum, and published; a walk on it is served its own model; it saves, and a 5, a value the version does not offer and the tag field are refused; the server's summary equals the browser formatter's; the editor renders level names, three Teaming questions, the Part 1 order, the visit fields and the header, with keyboard, axe-core and 375 px checks; the prototype's own summary and email code agree |
| `tests/cfml/specs/MultipleValuesTest.cfc` (7, step 2) | The authoring rules for `settings.multiple`; the model's flags; the shared vectors (parity with the browser engine); the operators over several values; a school change; the save validator's checks and order; the summary, file name and email with several values |
| `tests/cfml/specs/MultipleValuesReportTest.cfc` (2, step 2) | Against SQL Server, through a ReportService configured for a fixture instrument holding the 2026-10-14 document: live figures under each value and once per walk, the filter, the CSV label; a release that stores combinations (one longer than 100 characters) and publishes each value as the sum of its published combinations |
| `tests/node/browser-multiple.test.mjs` (MULTI-E1 to E6, step 2) | The flags in the served model; the shared vectors; saves in order, one row per value, Other's text, no change on reordering, every malformed shape refused; the summary and email against the prototype's own code; the checkbox editor with the keyboard, Other, a school change, My walks, axe-core and 375 px; the Reports view's label |
| `tests/ops/upgrade-and-rollback.test.mjs` (steps 5 and 6, step 2) | On a Phase 6 installation upgraded with 007 and 008: this release publishes 2026-10-14, records walks holding several values of Visit timing, reports on them live and releases them as combinations; then the release before step 2 (`36f9db0`) shows one value, saves a walk that leaves the field alone, refuses a change to it with nothing written, counts the answered once per value, reads that release with the combinations left out, and creates a release that counts a walk under each value |
| `tests/node/workbook.test.mjs` (step 2) | The yearly Excel round-trip gives back the 2026-10-14 document exactly, golden checksum included: `settings.multiple` travels in the placement sheet's `settings_json`, so the converter needed no change |
| `tests/ops/readiness-schema-missing.test.mjs` (step 2) | Health answers `outdated` (503) on a database without 008, and 200 once it is applied |
| `tests/node/cfml-portability.test.mjs`, `tests/node/sqlserver-2016.test.mjs` (step 2) | The step-2 CFML asks `structKeyExists` and `arrayIsDefined`, never `isNull()` of a value (rule 7, the guard for Phase 8's P8-08), and 008 uses nothing SQL Server 2016 lacks. The calls it first made changed no behavior on either engine (`docs/evidence/instrument-revision-2026-10-14-step2/`, "Why the ColdFusion red was not observed"); MULTI-E3 saves an Other text "Null" and refuses a value code "null" |
| `tests/node/db-scripts.test.mjs`, `tests/node/schema-contract.test.mjs` (step 2) | Migration 008 over data and twice: ordinal 0 for existing values, the new key, unique value and check refusing what they must, the previous release's insert and update refused, release cells and guards intact through the key rebuild, a long combination refused before and stored after |

The results of the gate on both engines are in `BUILD_STATUS.md`, "Instrument revision 2026-10-14".
