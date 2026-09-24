# Phase 6 administration audit corrections: handoff for re-audit

**Status: an implementation candidate submitted for independent re-audit. It is not accepted,
frozen, production-ready or audited.**

## What to audit

| | |
| --- | --- |
| Branch | `claude/icfwalk-phase-6-admin-audit-corrections` |
| Starting commit | `2a3f2ecb4f070401cba00518c0db8a2de823a29d` (the audited candidate, tip of `claude/icfwalk-phase-6-admin-publish`) |
| Code commit | `06660a238c8dd6c62cacd8a27ed970e757ef22a1` -- the corrections, their regressions and the contract documentation (`git diff 2a3f2ec 06660a2`) |
| Records commit | the commit after it: the gate transcript, the environment record, this handoff, the gate result in `BUILD_STATUS.md` and `docs/ACCEPTANCE_TRACKING.md`. `scripts/refresh-manifest.mjs` was run once this content was final and changed nothing, because no manifest-listed file changes in it (the code commit carries the refresh for `docs/DATA_CONTRACT.md` and `docs/OPEN_DECISIONS.md`). No code, test, dependency, configuration or migration (`git diff 06660a2 <records commit> --stat`) |
| Gated commit | `06660a238c8dd6c62cacd8a27ed970e757ef22a1`, from a clean tree and a fresh database: Node/HTTP/Playwright 240/240, CFML 475/475, 0 failed, 0 skipped, tree and HEAD unchanged afterwards |

The gate ran on the code commit and its transcript is committed in the next commit, because
committing a transcript changes the commit it describes; that is the pattern every earlier Phase 6
round used.

## Scope

Exactly the four findings, plus the regressions, contracts and records that close them. No schema
migration, no dependency, no configuration change (`git diff 2a3f2ec 06660a2 -- database
package.json package-lock.json tools config` is empty). No existing test was removed, skipped,
renamed or loosened; one assertion was changed by the audit's own instruction (below).

## Finding by finding

| Finding | Production change | Regressions |
| --- | --- | --- |
| **P6A-01** body processing, authentication and size limits | `src/http/Router.cfc` (`handle(source)`: metadata, pre-body checks, bounded read under route `maxBodyBytes`, parse, body-dependent permission), `src/http/HttpRequestSource.cfc` (new: metadata, and a byte-counted read of the servlet container's stream, at most one byte past the limit), `src/http/JsonBodyParser.cfc` (new), `src/http/MaintenanceGuard.cfc` (`precheck`), `src/Bootstrap.cfc`, `src/controllers/AdminInstrumentController.cfc` (size check removed; it is the route's), `app/assets/js/admin.js` (8-byte probe, `file.size`, then the read) | `RouterBodyOrderTest` (12, spy parser and recording request source); `admin-instrument.test.mjs` "P6A-01" (5, including bodies that never finish); `browser-admin.test.mjs` "P6A-01 (browser)" (1, every Blob read recorded) |
| **P6A-02** authoritative DRAFT re-import concurrency | `src/instrument/InstrumentImportService.cfc` (`createOnly` / `replaceVersionId` + `expectedChecksum` decided on the locked row; replacement audit), `src/instrument/InstrumentAdminService.cfc` (create-only default, `REPLACE_INVALID` token validation, one-read export), `src/instrument/SnapshotService.cfc` (`loadVersion`), `src/controllers/AdminInstrumentController.cfc` (`replace` member), `app/assets/js/admin.js` (tokens, 409 handling; the confirmation kept) | `DraftReplacementConcurrencyTest` (6: stale C1 vs C2; create-only queued behind the label's creation; replacement queued behind a later edit; correct replacement once, audited; every other token refused; export pairing); `admin-instrument.test.mjs` "P6A-02" and the ADM-01 case; `browser-admin.test.mjs` "P6A-02 (browser)" (2: two sessions; late-created label) |
| **P6A-03** discard the exact path version | `src/instrument/InstrumentImportService.cfc` (`discardDraftById` as one transaction on the locked id), `src/instrument/DefinitionRepository.cfc` (`deleteDraftVersionCascade` returns the version rows deleted) | `DiscardIdentityBarrierTest` (2: the delete/recreate interleaving forced; the refusal codes) |
| **P6A-04** structured workbook XML errors | `app/assets/js/workbook.js` (XML `Char` validation, cell/row reference validation, `readWorkbook` never throws), `app/assets/js/admin.js` (read and parse inside `guarded`) | `workbook.test.mjs` "P6A-04" (4); `browser-admin.test.mjs` "P6A-04 (browser)" (2) |

Test-only support: `tests/cfml/support/FakeRequestSource.cfc`, `SpyJsonBodyParser.cfc`,
`RouterTestDoubles.cfc` (new), and a `findVersionById` seam on `InterceptingDefinitionRepository.cfc`.
Nothing in `src/` references any of them.

**The one changed assertion.** `admin-instrument.test.mjs`, "ADM-01 ... re-import answers 200",
re-imported the same label with `{ document }` and expected 200. The audit requires that to be
refused, so the case now asserts 409 `DRAFT_REPLACEMENT_REQUIRED` (with the row version unmoved)
first, and then sends the same re-import with the exact replacement token, keeping every original
assertion on its 200. The name is unchanged.

## Where each claim is

| What | Where |
| --- | --- |
| Red before green, per finding | `docs/evidence/phase6-admin-audit-corrections-red-before-fix.md` |
| The full gate on the code commit (raw) | `docs/evidence/phase6-admin-audit-corrections-release-gate.txt` |
| Environment | `docs/evidence/phase6-admin-audit-corrections-environment.md` |
| Acceptance rows | `docs/ACCEPTANCE_TRACKING.md`: "Phase 6 administration audit corrections (P6A-01 to P6A-04)", and the ADM-01 row |
| What was built, files, results, what is not verified | `BUILD_STATUS.md`: "Phase 6 administration audit corrections" |
| Routes, body contracts, codes | `docs/ENDPOINTS.md`: "Request bodies", the import, document and discard rows |
| Design | `docs/ARCHITECTURE.md`: "The body comes last", "Replacing a DRAFT is the server's decision", "An export is one state", "A discard deletes the version it names", "A hostile or damaged file is a problem on the page" |
| Data rules | `docs/DATA_CONTRACT.md`: the refusal reasons table, "Instrument administration writes", "Instrument workbooks" |
| Connector limits (Lucee and Adobe ColdFusion) | `docs/LOCAL_SETUP.md`: "Request size limits" |
| Decisions | `docs/OPEN_DECISIONS.md`: replacement by name only; the body limits |

## Where I would look first

- **`HttpRequestSource` on Adobe ColdFusion.** On Lucee the bounded read works only because the
  source unwraps Lucee's request (`getOriginalRequest()`), whose own `getInputStream` copies the
  whole body into memory first (found by thread dump; recorded in the red evidence). On ColdFusion it
  unwraps through `ServletRequestWrapper.getRequest()`; whether ColdFusion has already consumed the
  body at that point is unverified. If it has, the fallback measures the engine's copy in UTF-8
  bytes before parsing -- the order still holds, but then the connector's "Maximum size of post
  data" is what bounds a chunked body.
- **The lock claims of the replacement.** The create-only refusal of a label created concurrently
  relies on `UPDLOCK, HOLDLOCK` holding the key range of a label that does not exist yet.
  `DraftReplacementConcurrencyTest` proves it on SQL Server 2022 by releasing the holder only after
  `sys.dm_exec_requests` shows the competitor blocked behind it.
- **The maintenance import still re-imports by label.** Deliberate (the seed path, behind the
  maintenance token, which a signed-in user cannot reach), and documented; worth confirming the
  audit agrees.
- **Adjacent, unchanged.** `preview`, `wording`, `placeholders`, `compareVersions` and `editDraft`
  still read the row and then the snapshot in two reads; `editDraft`'s under-lock checksum covers
  every case except an A-B-A change between its two reads. Outside the four findings; noted in
  `BUILD_STATUS.md`.

## Not performed

1. Adobe ColdFusion 2023: not run.
2. SQL Server 2016: not run (SQL Server 2022 only).
3. IIS, Apache, or any connector-level request limit: documented, not exercised.
4. Microsoft Excel: not used (LibreOffice-saved fixtures only, unchanged by this work).
5. Screen reader: not used (axe-core and keyboard checks only).

## Reproducing

From a clean clone at the code commit with the runtime up and `.env` configured for development:
drop and recreate `icfwalk_dev`, `node scripts/db/apply-schema.mjs`, `node scripts/db/apply-schema.mjs
--only 006`, restart Lucee, `node scripts/seed-instrument.mjs`, then
`ICFWALK_REQUIRE_APP=1 ICFWALK_SCREENSHOT_DIR=<outside the repository> npm test`. Faster subsets:
`npm run test:admin`, `npm run test:workbook`, and the CFML specs `RouterBodyOrderTest`,
`DraftReplacementConcurrencyTest`, `DiscardIdentityBarrierTest` through
`/api/maintenance/tests/run?filter=<Spec>`.
