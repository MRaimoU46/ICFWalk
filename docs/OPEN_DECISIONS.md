# Open decisions and safe defaults

These items require district or deployment-owner decisions. They must not block the base build, and the implementation must not guess irreversible answers.

| Decision | Safe build default |
| --- | --- |
| Approved wording for 17 placeholder questions | Preserve and visibly flag the current placeholder prompts; make replacement a new DRAFT version edit |
| Whether teacher identifier, name, email, and classroom label should appear | Keep nullable, hidden, and excluded from aggregate reports |
| Production SSO provider and claims | Implement an adapter and environment mapping; use a development stub only outside production |
| Hosting topology, datasource name, base URL, and secret store | Use environment/config placeholders and deployment documentation; commit no secrets |
| Aggregate privacy-suppression threshold | **Decided by the owner on 2026-09-23** (see "Aggregate privacy rule (RPT-03)" below). Owner's decision, verbatim: "K=3, frozen releases". Minimum 3 walks, report-only users read frozen releases only; implemented as described below |
| Which walks a report counts | **COMPLETED** walks by default; DRAFT walks only when the person asks (`includeDrafts=true`, labelled "Include walks still in draft"); VOIDED walks never. A district that wants drafts in its standard reports changes the default, not the data |
| Whether a report may pool instrument versions | **No.** A report covers one pinned version (the current one unless another is chosen). Walks under different versions may have different wording or scoring for the same reporting key, so cross-version trend reporting needs an approved mapping of which items are comparable before it is built |
| Whether hidden Period values should be cleared | Retain as HIDDEN by default, exclude from reports/export, and document the policy |
| Whether placeholder warnings block instrument publication | Treat as warnings by default; make blocking policy configurable |
| Migration of browser-local prototype records | Do not attempt automatic migration without an approved export/import process; production begins with SQL as authority |
| Automated outbound teacher email | Disabled. Preserve copy and mailto only until separately authorized |
| Whether an environment that ran the earlier form of migration `006` more than once carries dimension-value memberships it never authored | Detect, never auto-correct. `006` now records its one-time transition and can no longer infer membership, but it deletes nothing it may have inferred before. `database/README.md` carries two read-only detection queries and a reviewed remediation procedure; where a version's frozen snapshot cannot establish the intended membership, the instrument owner must state it in writing before any row is removed |
| Who may change shared instrument metadata (`icf.instrument` name, description, and whether the instrument is in service) | Not the importer, and not merely somebody the database has heard of. `InstrumentMetadataService.updateMetadata` takes the **current principal** and asks `AuthorizationService` for global `instrument.manage` before any mutation; the audit actor is that principal's `userId` and no argument can name another. `DefinitionRepository.userExists` remains, as an **integrity** check for the audit foreign key, and is not authorization. No route is exposed for the operation in this pass, so the deployment decides how it is reached when the administration UI is built -- the absence of a route is a scope decision and is not the security control |
| Whether a shared-metadata patch that produces no material difference is an audited operation or a no-op | **A no-op.** The locked read establishes, under the row lock, that every supplied value already equals the stored one exactly -- `name` and `description` case-sensitively, `active` as a boolean, so a capitalization-only edit is a change; the row is then not written, `updated_at` and `row_version` do not move, and no `INSTRUMENT_METADATA_UPDATED` event is recorded. The result carries `noOp: true` and an empty `changedFields`, so the caller is told plainly. An administrative action that changed nothing is not a change, and an audit trail that records it makes the events that did change something harder to find. A patch naming no supported field at all is a different case and is refused (`INSTRUMENT_METADATA_NO_CHANGES`) |

Fable should complete the application with these defaults and surface each item in configuration or administration documentation.

## Aggregate privacy rule (RPT-03)

**Status: decided.** RPT-03 requires that a report-only user cannot drill into a walk or infer an
individual row from an API or an export. The Phase 7 audit (P7-01) found that a report narrowed to
one walk returned that walk's categorical answers. No approved disclosure rule existed, so the
correction stopped and proposed one (items D1-D7 below). The owner answered, verbatim:

> K=3, frozen releases

That selects k = 3 for D2 and frozen releases for D6, and approves the rest of the proposal as
written. This section records the approved rule as implemented. Where the implementation had to
settle a detail the proposal did not state, the detail is marked **(implementation)** and in every
case withholds more, never less, than the proposal's text.

| Item | Approved rule | As implemented |
| --- | --- | --- |
| D1 Who is protected | Every caller without `walk.read` on every unit a report draws on. Report-only roles are always protected; walk-and-report roles reporting inside their own `walk.read` scope keep live figures, because they can already open each of those walks. | `ReportService.isProtected`, decided per request from the units the report would count. A mixed principal gets live figures for units whose walks it can open and releases elsewhere. |
| D2 Minimum | k = **3** completed walks. `ICFWALK_REPORT_SUPPRESSION_THRESHOLD` may raise it, never lower it. Unset means 3. A value below 3, including 0, refuses startup. | `ConfigLoader` (`APPROVED_REPORT_MINIMUM = 3`). Each release stores the k it was made with (`report_release.minimum_walks`, `CHECK >= 3`) and is always read with that k. |
| D3 Query surface for protected callers | Version, a covered unit, section and question only. Completed walks only. Date ranges, dimension filters, answer filters and drafts are refused (400 `REPORT_FILTER_NOT_PERMITTED`). | Refused for every release read, protected or not. A protected caller without a release is refused live figures (400 `REPORT_RELEASE_REQUIRED`). The proposal's "one fixed school year" is the time grain; with frozen releases (D6) the release's own dates are that grain **(implementation)**: the caller chooses a release, never a date range. |
| D4 Block floor | A block is (version, org unit) within one release. A block with fewer than k walks contributes to nothing, at any level. Zero and 1..k-1 look identical. | Such a block is never stored (`blocksFrom`; `CK_report_release_block_walks >= 3` and `TR_report_release_block_floor` refuse it in the database). A selection with no stored block returns `population.withheld = true` with no count and nothing categorical. |
| D5 Cells | Each breakdown of each block is split into categories that do not overlap and add up to the block's walks. Cells of 1..k-1 are withheld; complementary cells are added until at least 2 are withheld and they total k or more; if impossible, the breakdown is withheld whole. Parent units sum the published block cells. Scores come from published cells only and are withheld under k responses. | `DisclosureControl.suppress` and `ReportService.publishBlock`. Three conservative additions **(implementation)**: (a) a withheld set whose cells would all be forced to 1 is not accepted; (b) an **audit**: before a partial breakdown is published, the exact set of values each withheld cell could hold, for a reader who knows the algorithm, is computed, and if any cell has only one the whole breakdown is withheld (the exhaustive search found patterns such as (3, 2, 2) that the literal rule would have published in a solvable way); (c) **linked breakdowns**: when instrument rules tie breakdowns together (Period and the PreK-K section to Grade, the classroom-type sections to Class Type, the Music/Art/PE section to Content, each skippable component to its "applicable" question), one breakdown's HIDDEN or NOT_APPLICABLE count is a sum of another's cells, so the group is published only when none of its members has a cell of 1..k-1, and is otherwise withheld whole in that block. |
| D6 Time | Frozen releases. | `POST /api/reports/releases` (migration 007). A release covers dates that have passed, never overlaps another release (`TR_report_release_no_overlap`), is computed once from one coherent read and never changes (`TR_report_release*_immutable`). Only someone holding `walk.read` and `report.view` on every active unit may create one. The proposal said "published once per term"; the system enforces closed, non-overlapping dates and leaves the cadence (per term, per school year) to the district **(implementation)**. |
| D7 Surfaces | JSON, CSV and browser render the one server-side report. A withheld value is never sent. Logs and audit carry published counts only. | Withheld figures are `null`, never 0 and never a number beside a flag; the CSV is built from the same report; the browser receives only what it shows; `report.generated`, `report.exported`, `REPORT_EXPORTED` and `REPORT_RELEASED` carry identifiers and published counts (`-1` for a withheld population). |

Accepted residuals named in the proposal and approved with it: a block where every walk falls in
one category (100%) is published, because its complement is 0. Other known limits are listed in
`docs/DATA_CONTRACT.md`, "Aggregate privacy rule (RPT-03)", and in `BUILD_STATUS.md`.

