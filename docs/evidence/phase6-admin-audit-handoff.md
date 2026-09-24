# Phase 6 administration: handoff for audit

> **Later:** the audit's findings P6A-01 to P6A-04 were corrected (`06660a238c8dd6c62cacd8a27ed970e757ef22a1`),
> the re-audit's P6A-R01 after them (`158debca5da2c4f3a07f602689cd08af9db9bd6e`), and Phase 6 was then
> frozen on the project owner's direction -- see `phase6-freeze.md`. This handoff is kept as it was
> submitted.

**Status: an implementation candidate submitted for independent audit. It is not accepted, frozen
or complete until that audit says so.**

## What to audit

| | |
| --- | --- |
| Branch | `claude/icfwalk-phase-6-admin-publish` |
| Range | `0c6fa10..786e572` (`git diff 0c6fa10 786e572`) |
| Code commits | `407b0cd` Phase 6 administration; `0a784d5` Excel round-trip |
| Transcript commits | `2b68cc0` (gate of `407b0cd`), `786e572` (gate of `0a784d5`): transcript, result text in `BUILD_STATUS.md`, refreshed `manifest.json` only |
| Branch tip | The commits after `786e572` add only records: this note, the environment record and a pointer in `BUILD_STATUS.md`, no code; audit the branch tip |
| Underneath, not in scope | `0c6fa10` Phase 7 (aggregate reporting), built by another session before this work and also **not yet audited**. This range changes one line of it (below). |
| Frozen baseline below that | `a219d9e` (Phase 0-6 publish foundation) |

The gates ran on the code commits, and each transcript was committed as the next commit, because
committing a transcript changes the commit it describes. That is the pattern earlier Phase 6 rounds
used; the transcript commits contain no code, test or configuration change.

## Scope

1. **The rest of Phase 6** (`docs/IMPLEMENTATION_PLAN.md`): ADM-02 preview, ADM-06 new DRAFT from a
   published version with an edited prompt and a compare view, ADM-07 retire, ADM-08 placeholder
   review queue, and the administration UI for ADM-01 to ADM-08.
2. **The Excel round-trip** -- **not in the plan and with no acceptance ID.** The product owner asked
   for it after confirming the instrument changes once a year, in summer: download a version as a
   workbook, edit it in Excel, upload it as a new DRAFT through the existing import route.

The six product decisions made during the build (wording-only in-app editing, placeholder
resolution by DRAFT edit, retirement attribution by audit, confirmation to retire the last version in
service, any instrument code, no route for shared metadata) and the two added with the round-trip
are in `docs/OPEN_DECISIONS.md`. The product owner reviewed the first six and said they look good;
that is a product review, not an audit.

## Where each claim is

| What | Where |
| --- | --- |
| Acceptance status and the test behind each claim | `docs/ACCEPTANCE_TRACKING.md`: ADM-01 to ADM-08, the administration UI row, the Excel round-trip row |
| What was built and why, files, results, what is not verified | `BUILD_STATUS.md`: "Phase 6 administration ..." and "Excel round-trip ..." (the last two sections) |
| Design | `docs/ARCHITECTURE.md`: "Instrument administration (Phase 6)", "The Excel round-trip" |
| Data rules | `docs/DATA_CONTRACT.md`: "Instrument administration writes and retirement (Phase 6)", "Instrument workbooks (the Excel round-trip)" |
| Every route, body contract and status code | `docs/ENDPOINTS.md` |
| Red before green | `docs/evidence/phase6-admin-red-before-fix.md`, `docs/evidence/excel-roundtrip-red-before-green.md` |
| Full gates on the code commits | `docs/evidence/phase6-admin-release-gate.txt`, `docs/evidence/excel-roundtrip-release-gate.txt` |
| Environment | `docs/evidence/phase6-admin-environment.md` |

## Changes outside Phase 6 files

| File (phase) | Change | Why |
| --- | --- | --- |
| `src/walks/WalkRepository.cfc` `insertWalk` (4) | Status-qualified `INSERT ... SELECT` from the version row `WITH (HOLDLOCK, ROWLOCK)`, `OUTPUT INSERTED`; `""` when nothing inserted | A retirement between version choice and insert pinned a walk to a RETIRED version; the other order deadlocked (red evidence) |
| `src/walks/WalkService.cfc` `create` (4) | Nothing inserted: 409 `INSTRUMENT_VERSION_CHANGED` | The existing "reload" refusal |
| `src/reports/ReportService.cfc` `resolveVersion` (7) | With nothing in service, default to the newest frozen version | Retiring the last version made Reports unopenable (red evidence) |
| `src/instrument/InstrumentImportService.cfc` (6 foundation) | `importConfig` writes through the new shared `writeNormalizedDraft` | One validated write path for import, clone, edit |
| `src/instrument/InstrumentPublishService.cfc` (6 foundation) | `retire` added; `publish` unchanged (additions only) | The other lifecycle transition |
| `src/controllers/AdminInstrumentController.cfc` `publishVersion` (6 foundation) | Uses the shared `refuseAnyBody` helper | Same contract and codes |
| Shell, `app.js`, `api.js`, CSS | Admin view, `canAdmin`, admin-only landing, `api.postEmpty`, styles | The view |
| `Router.cfc`, `Bootstrap.cfc`, `Errors.cfc` | Ten routes, wiring, 409 `retireNotPublished`, 413 `payloadTooLarge` | No existing route or policy changed |

No schema migration (`git diff 0c6fa10 786e572 -- database` is empty), no new dependency, no test
removed, skipped or weakened.

## Where I would look first

- **The lock claims.** `RetireConcurrencyBarrierTest` (3 cases, two-sided barrier) proves retire
  against walk creation in both orders and two concurrent retirements, on Lucee with SQL Server 2022.
  `HOLDLOCK` on an `INSERT ... SELECT` source and `sp_getapplock` with a transaction owner are the
  parts most likely to behave differently under Adobe ColdFusion's datasource.
- **The shared write path.** `writeNormalizedDraft` now carries the import, and the stale-edit check
  (`expectedChecksum`) runs before the edit is built and again under the version lock.
- **The exporter's exactness.** `InstrumentDocumentExporterTest` asserts checksum equality for the
  supplied instrument only; an instrument using features the supplied one does not may not be covered.
- **The workbook reader on hostile input** (`app/assets/js/workbook.js`): zip limits, CRC, DOCTYPE
  refusal, the hand-written XML reader. It runs in the browser only; the server receives JSON.
- **`locate()`** reproduces the server's normalized sort to map validation paths to cells; a
  divergence would point a person at the wrong row (the Node test checks every row of the supplied
  instrument).
- **The replace confirmation is client-side.** The server replaces a DRAFT on re-import without
  comparing checksums, as JSON import always has; the page asks first.

## Known gaps, stated in the records

1. Not run on Adobe ColdFusion 2023 or SQL Server 2016.
2. Workbooks not opened in Microsoft Excel; LibreOffice Calc 24.2 is the stand-in.
3. No screen-reader test; axe-core and keyboard checks only.
4. A 422 publish refusal is not exercised in the browser (service and HTTP evidence exist).
5. At 375 px the version list scrolls sideways inside its own region.
6. Structure editing in Excel is still technical (ids, JSON in cells); a friendlier editor is planned
   after the first summer update.

## Reproducing

The environment record lists versions and the exact setup. From a clean clone with the runtime up
and `.env` configured for development: drop and recreate `icfwalk_dev`, `node
scripts/db/apply-schema.mjs`, re-apply `006`, restart Lucee, `node scripts/seed-instrument.mjs`,
then `ICFWALK_REQUIRE_APP=1 npm test` with `ICFWALK_SCREENSHOT_DIR` outside the repository. Faster
subsets: `npm run test:admin` (HTTP and browser), `npm run test:workbook` (no server needed), and the
CFML specs `InstrumentAdministrationTest`, `RetireConcurrencyBarrierTest`,
`InstrumentDocumentExporterTest`, `DraftEditorTest`, `InstrumentVersionComparerTest` through
`npm run test:cfml`.
