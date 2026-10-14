# Instrument revision 2026-10-14

The product owner supplied a new prototype on 2026-10-14 ("the most up-to-date document that shows the
new launch page with the check boxes") and asked for it in two steps:

1. **This change.** Everything in the new prototype except the checkboxes, as a new version of the
   ICFWALK instrument.
2. **Next.** Grade level, Content / Subject Area, Program and Visit timing as multi-select checkboxes.
   The owner's reporting rule for it is decided and recorded in `docs/OPEN_DECISIONS.md`.

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
6. **Single-select, for now.** The checkboxes are step 2: a walk stores one value per visit field
   (`icf.walk_dimension_value` is keyed on walk and field), so multi-select is a schema, save-path, rules,
   reports and export change, not instrument content.
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
   `b9e7d0df0c722a4861d2fdcaddc3b972e7bfc8a24a559f3ad839fecd3d95999a` and the 17 placeholder warnings.
2. Preview it, and Compare it with `2026-09-17 aligned prototype`. The comparison lists the changes in
   the table above and nothing else.
3. Confirm the source file (see "Source fingerprint and provenance").
4. Publish it. New walks start on it from that moment. Walks already started stay on 2026-09-17 and open,
   save and export as they did. Retire the 2026-09-17 version when nobody needs to start walks on it.

A brand-new installation can seed this document instead of the 2026-09-17 one with the same `--file`
argument (or `ICFWALK_INSTRUMENT_CONFIG_PATH`). The test suite keeps seeding the 2026-09-17 document,
which its baselines describe.

## Verification

| Where | What |
| --- | --- |
| `tests/node/instrument-revision.test.mjs` (REV-01 to REV-11, no application) | The document is exactly what the derivation makes; its source fingerprint; its golden checksums; references and keys; every rated item on the prototype's 4-point scale with its exact definitions; the level names; the look-fors; Academic Teaming's third question and its rule; Part 1 order and Pacing; the visit fields, their lists and the content-area triggers; nothing else moved |
| `tests/cfml/specs/InstrumentRevisionTest.cfc` (6) | The CFML compiler produces the golden bytes (parity with the reference compiler); the authoring validator accepts it with only the 17 placeholder warnings; the real renderer builds it; the visibility engine follows the new triggers and the third Teaming question; the summary formatter prints 4-point scores |
| `tests/node/browser-revision.test.mjs` (REV-E1 to REV-E6) | Imported through Instrument admin with the golden definitions checksum, and published; a walk on it is served its own model; it saves, and a 5, a value the version does not offer and the tag field are refused; the server's summary equals the browser formatter's; the editor renders level names, three Teaming questions, the Part 1 order, the visit fields and the header, with keyboard, axe-core and 375 px checks; the prototype's own summary and email code agree |

The results of the gate on both engines are in `BUILD_STATUS.md`, "Instrument revision 2026-10-14".
