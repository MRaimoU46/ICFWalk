# Acceptance test tracking

Keyed to `docs/ACCEPTANCE_TESTS.md`. Status values: **PASS** (automated evidence in this
repository), **PASS (manual)**, **NOT TESTABLE HERE** (needs the real Adobe ColdFusion 2023 /
SQL Server deployment or a later phase), **PENDING** (later phase), **N/A** (with reason).

Verification runtime note: Adobe ColdFusion 2023 could not be installed in the build environment.
CFML evidence was produced on Lucee 6.2.8 (Jetty) against Microsoft SQL Server 2022 Developer in
Docker. Every CFML-backed PASS below must be re-run on Adobe ColdFusion 2023 before handoff; the
commands are identical (`npm test`). Items whose behavior depends on Adobe-specific semantics are
marked explicitly.

## Package and configuration

| ID | Status | Method / evidence |
| --- | --- | --- |
| PKG-01 | PASS | `node scripts/validate-handoff.mjs` exit 0, 51 checks (`tests/node/package.test.mjs`). Validator patched to ignore `.git/` and report build files (Phase 0 defect, recorded in `BUILD_STATUS.md`). |
| PKG-02 | PASS | `tests/node/package.test.mjs`; CFML validator rule `RETIRED_CONTENT_PRESENT` (`InstrumentConfigValidatorTest`). |
| PKG-03 | PASS | `tests/node/package.test.mjs` (17 = 3/3/3/3/5); import result reports 17 placeholders (`InstrumentImportServiceTest.testDb04...`). |
| PKG-04 | PASS | `tests/node/package.test.mjs`. |
| PKG-05 | PASS | `tests/node/package.test.mjs` reads the aligned workbook sheets (23/144/29/138/12/10/95/10). |

## Database and seed

| ID | Status | Method / evidence |
| --- | --- | --- |
| DB-01 | PASS | `tests/node/db-scripts.test.mjs` on SQL Server 2022 (16.0.4295): both scripts commit; 20 tables; 5 roles; instrument ICFWALK. |
| DB-02 | PASS | Same test: rerun of 001 raises error 50001, table and role counts unchanged. |
| DB-03 | PASS | Same test: 002 re-applied without error, one `definition` column. Phase 4 migration `003_walk_mutation.sql` applied and re-applied without error in the same test (21 tables). |
| DB-04 | PASS | `InstrumentImportServiceTest.testDb04ImportCreatesDraftWithMappedGuidsAndSnapshot` (GUID mapping, snapshot stored, counts 23/144/29/138/12/10, no orphans, audit event). |
| DB-05 | PASS | `...testDb05ReimportIsIdempotentWithStableGuidsAndChecksum` (same version id, identical checksum, no duplicate rows, GUIDs reused) and `...testReorderedReimportSucceedsAndReturnsToGolden`. Seed endpoint idempotency in `tests/node/cfml-suite.test.mjs`. |
| DB-06 | PASS | `...testDb06ImportAgainstPublishedVersionIsRefusedWithoutChanges` (409 `INSTRUMENT_VERSION_IMMUTABLE`; version and item row versions unchanged). |
| DB-07 | PASS | `...testDb07MissingResponseSetRollsBackWithSpecificError` (`MISSING_REFERENCE` naming `rs_scale_comp_s1_q1`, no version row). |
| DB-08 | PASS | `...testDb08CorruptConditionsJsonRollsBack` (`INVALID_JSON`, no partial version) plus `...testTransactionRollsBackWhenDatabaseRejectsAWrite`. |
| DB-09 | PASS | `...testDb09ResponseOptionDefinitionsMatchTheJsonExactly` (138 options, 136 definitions byte-equal; DB round-trip definitions checksum equals the golden). |

## Authentication and authorization

| ID | Status | Method / evidence |
| --- | --- | --- |
| AUTH-01 | PASS | `tests/node/auth.test.mjs`: `/api/me`, `/api/auth/csrf-token`, `/api/admin/instrument/versions`, and `POST /api/auth/sign-out` return 401 `UNAUTHENTICATED` with no protected data; SSO gateway headers sent directly are ignored. |
| AUTH-02 | PASS | `ConfigLoaderTest` (startup refused with `CONFIGURATION_INVALID`), `IdentityTest.testDevelopmentStubCannotBeConstructedWhenNotPermitted` (factory and constructor refuse), `IdentityTest.testConfigLoaderRejectsUnsafeIdentitySettings`. |
| AUTH-03 | PASS | `AuthorizationTest.testAuth03...`: district walk/report role reads walks in descendant schools, edits its own, creates in scope. `auth.test.mjs`: `/api/me` permissions for the district walker. |
| AUTH-04 | PASS | `AuthorizationTest.testAuth04...`: school role denied (404, audited) for walks in unassigned schools even with the GUID. |
| AUTH-05 | PASS | `AuthorizationTest.testAuth05...` (service), `WalkServiceTest.testCrossScopeAccessFailsClosedThroughTheService`, and `tests/node/walks.test.mjs` "AUTH-05 / AUTH-06": report-only and instrument-admin roles get 403 `FORBIDDEN` on list, create, open, instrument, save, complete, void, and delete, with no walk identifier, note, or teacher field in the response. |
| AUTH-06 | PASS | `AuthorizationTest.testAuth06...` (admin has no walk/report capability; walkers lack `instrument.manage`) and `auth.test.mjs` (admin route 403 for walkers and role-less users, 200 for the admin; admin `/api/me` shows no walk/report scope). |
| AUTH-07 | PASS | `AuthorizationTest.testAuth07...` (future and expired assignments yield no scope) and `testEndingAnAssignmentRevokesAccessImmediately`. |
| AUTH-08 | PASS | `AuthorizationTest.testAuth08...`: descendants included, unrelated branch and inactive descendants excluded; `include_descendants = 0` covers only the assigned unit. |
| AUTH-09 | PASS | Org-unit and walk identifiers: `AuthorizationTest.testAuth09...`. Version, walk, item, option, dimension, and value tampering through the walk endpoints: `WalkServiceTest.testAuth09TamperedKeysCodesAndIdentifiersAreRejectedAndAudited` (15 payload cases + version/walk/row-version/mutation-id/malformed/unknown ids; nothing written, row version unchanged, each rejection audited `WALK_SAVE_REJECTED`) and `walks.test.mjs` "AUTH-04 / AUTH-09" over HTTP (10 payload cases, 404 for other schools, 403 for a same-school colleague). Item/option/dimension GUIDs are never accepted from the client: keys and codes are resolved to the pinned version's GUIDs on the server. |

## My Walks and lifecycle

Phase 4 re-verified every row end to end against SQL Server through the service
(`WalkServiceTest`), HTTP (`walks.test.mjs`), and the browser (`browser.test.mjs`,
`browser-persistence.test.mjs`).

| ID | Status | Method / evidence |
| --- | --- | --- |
| WALK-01 | PASS | `browser.test.mjs` "WALK-01" against the server list: empty-state wording and the `+ New walk` action; `browser-persistence.test.mjs` shows the empty state again after the last walk is voided. |
| WALK-02 | PASS | `WalkServiceTest.testWalk02CreatePinsCurrentVersionOwnerAndDefaults` (DRAFT, pinned `version_id` = current version, owner, org unit, defaults, one response row per response-capable item, audit `WALK_CREATED`); `walks.test.mjs` "WALK-02 / WALK-03"; `browser-persistence.test.mjs` "WALK-02 / WALK-05" (reload shows the persisted walk). |
| WALK-03 | PASS | `WalkServiceTest.testWalk03CreateRetryWithSameMutationIdCreatesOneWalk` (same id → same walk, `replayed`, one mutation row, other user refused `MUTATION_ID_REUSED`); `walks.test.mjs` "WALK-02 / WALK-03". |
| WALK-04 | PASS | `WalkServiceTest.testWalk04ListSortsByUpdatedAtDescendingWithCardDimensions` (server order by `updated_at`, card dimensions in the list DTO); `browser.test.mjs` "My Walks" (grade · content, school, date, relative time, newest first). |
| WALK-05 | PASS | `WalkServiceTest.testSaveRoundTripPersistsTypedValuesAndSurvivesRetrieval` (typed columns, Other mapping, date, notes, email draft re-read from the database); `walks.test.mjs` "WALK-05 / SAVE-08 / SEC-01"; `browser-persistence.test.mjs` "WALK-02 / WALK-05" (values restored after a page reload). |
| WALK-06 | PASS | Drafts: `browser.test.mjs` "My Walks" (confirmation wording, card removed) → `POST /void` with the default reason, audit `WALK_VOIDED` (`WalkServiceTest.testWalk06And08VoidLifecycleAndDeleteRefusal`). Completed walks: reason required, voided with reason, rows retained (`browser-persistence.test.mjs` "WALK-06 / WALK-08"). |
| WALK-07 | PASS | `browser.test.mjs` "My Walks": cancel leaves the list unchanged (no request is made). |
| WALK-08 | PASS | `DELETE /api/walks/{id}` is always 409 `WALK_DELETE_REFUSED` and audited; completed walks are voided with a reason and keep every row (`WalkServiceTest.testWalk06And08...`, `walks.test.mjs`). |
| WALK-09 | PASS | `WalkServiceTest.testWalk09CompletionRejectsMissingRequiredResponsesAndKeepsTheDraft` (7 field-specific errors with key/section/message, DRAFT and values untouched, audit `WALK_COMPLETION_REJECTED`); `browser-persistence.test.mjs` "WALK-09 / WALK-10 / A11Y-02" (alert summary, links focus the field, `aria-invalid` + description, errors clear as answered). |
| WALK-10 | PASS | `WalkServiceTest.testWalk10CompletionSetsStatusTimestampRevisionAndAudit` (COMPLETED, `completed_at`, revision 1 `COMPLETE` with the prior snapshot, audit `WALK_COMPLETED`, idempotent retry, second completion refused); post-completion edits append `POST_COMPLETION_EDIT` and must stay complete (`testPostCompletionEditAppendsARevisionAndMustStayComplete`); browser completion and badge. |
| WALK-11 | PASS | `WalkServiceTest.testWalk11OlderWalkRendersFromItsPinnedSnapshotAfterANewVersion`: a newer DRAFT with a changed prompt becomes the version for new walks while the older walk keeps its `version_id`, renders the original prompt through `GET /api/walks/{id}/instrument`, and still saves against its own definitions; `walks.test.mjs` "WALK-11". Publishing itself is Phase 6. |

## Metadata and conditional UI

Each COND row is proven three ways: `VisibilityEngineTest` (CFML engine), `tests/node/visibility.test.mjs`
(browser engine against the served model, plus the shared vectors), and `tests/node/browser.test.mjs`
(real DOM in Chromium). Phase 4 adds the persisted states (`WalkServiceTest`).

| ID | Status | Method / evidence |
| --- | --- | --- |
| COND-01 | PASS | Elementary school → `prek,k,1,2,3,4,5` (engine tests and DOM `<select>` options). |
| COND-02 | PASS | Middle school → `6,7,8`. |
| COND-03 | PASS | High school, Dream Academy, Central School → `9,10,11,12` (from `valueGroup` metadata, not names). |
| COND-04 | PASS | Other → full PreK–12 list; no school → full list. |
| COND-05 | PASS | Grade 5 + middle school → grade cleared (`DIMENSION_CLEARED/OPTION_FILTER`), PreK–K section hides with the cleared grade. Server-side on save: `WalkServiceTest.testCond05And06GradeFilterClearsAndHiddenPeriodIsRetained` (grade row deleted). |
| COND-06 | PASS | Period visible for 6–12 only; hidden value retained as `HIDDEN` (`ICFWALK_HIDDEN_PERIOD_POLICY=RETAIN_HIDDEN`, `CLEAR` also tested). Persisted: the Period row is retained and `dimensionStates.period = HIDDEN` (`WalkServiceTest.testCond05And06...`). |
| COND-07 | PASS | PreK and K show PreK–K Classroom; every other grade hides it. |
| COND-08 | PASS | Dual Language, MAC, PREP, Ignite, AVID, ESL each show only their section; General Education shows none; Other free text never matches. |
| COND-09 | PASS | Art, Music, CTE show Content-Area Look-Fors; other content areas hide it. |
| COND-10 | PASS | Engine + DOM (Phase 3) and persisted: `WalkServiceTest.testCond10HiddenSectionAnswersArePersistedAsHiddenAndReturn` (row state `HIDDEN` with the option retained, `ANSWERED` again when the class type returns). |
| COND-11 | PASS | New walk: both applicability controls pressed `No`, rating rows hidden, header reads `Not part of this lesson`. |
| COND-12 | PASS | Yes → rate → No in the DOM (Phase 3) and on the server in one transaction: `WalkServiceTest.testCond12And13SkippableComponentClearsRatingsKeepsNotesInOneTransaction` (both ratings `NOT_APPLICABLE` with NULL options, notes `ANSWERED`, `changes[]` returned), `walks.test.mjs` "COND-12 persisted". |
| COND-13 | PASS | Back to Yes: rows return `UNANSWERED`, cleared ratings do not reappear, notes remain (DOM and persisted rows, same tests as COND-12). |
| COND-14 | PASS | `RenderModelTest` compares all 138 options and definitions with the JSON; `browser.test.mjs` opens every visible definition toggle and compares the rendered rows. |
| COND-15 | PASS | Counts use answered ratings only (`1/2 rated`); an option code outside the set is `UNANSWERED`; blanks never become zero. |

## Autosave, summary, administration, reporting

| IDs | Status |
| --- | --- |
| SAVE-01 | PASS. `browser-persistence.test.mjs` "SAVE-01 / SAVE-02": four edits within 700 ms show `Unsaved changes` immediately and produce exactly one `PUT` after activity stops; a later edit is a second save with a new mutation id and the committed row version. |
| SAVE-02 | PASS. Same test: `Saving...` → `All changes saved`, row version advanced on the server; `WalkServiceTest.testSaveRoundTrip...` (new `rowVersion` on every save). |
| SAVE-03 | PASS. `browser-persistence.test.mjs` "SAVE-03": aborted `PUT` shows the network message with a Retry action, input stays on screen, nothing reached the server; Retry sends the same `clientMutationId` and succeeds; a server 500 shows its code and retries the same way. |
| SAVE-04 | PASS. `WalkServiceTest.testSave04StaleWriteIsRejectedWithoutOverwriting` (409 with the server row version, A's write intact, audit `WALK_SAVE_CONFLICT`), `walks.test.mjs` "SAVE-04 / SAVE-06", `browser-persistence.test.mjs` "SAVE-04 / SAVE-05" (two browser contexts). |
| SAVE-05 | PASS. Browser: the stale session gets an `alertdialog` listing only its unsent edits against the saved values; "Keep my edits and save" applies them on the server record and saves with the new row version (both sessions' values end up stored); "Use the saved version" discards them. |
| SAVE-06 | PASS. `WalkServiceTest.testSave06RetryWithSameMutationIdCommitsOneLogicalChange` (replay returns the committed row version, no duplicate response/dimension/revision rows, one CREATE + one SAVE mutation, later replay still replays, foreign reuse refused); HTTP equivalent in `walks.test.mjs`. |
| SAVE-07 | PASS. `WalkServiceTest.testAuth09...` and `walks.test.mjs`: `yes` on a 1–5 item, `1` on a No/Partial/Yes item, `4` on a yes/no item are 400 `INVALID_OPTION`; codes are compared exactly (the CFML `==` coercion of `yes`/`1` was found and fixed; `visibility-vectors.json` carries three vectors for it). |
| SAVE-08 | PASS. Markup and SQL metacharacters in notes and Other text are stored verbatim and returned as JSON data (`WalkServiceTest.testSaveRoundTrip...`, `walks.test.mjs` with `nosniff`); in the browser the text is shown in the textarea, no element is injected, no script runs (`browser-persistence.test.mjs` "WALK-02 / WALK-05 / SAVE-08"). Export preview, admin, and reports: later phases. |
| SUM-01 .. SUM-09 | PENDING (Phase 5) |
| ADM-01 | PARTIAL | Import validation summary with counts and 17 placeholder warnings exists at the service/endpoint level; the admin UI and role check are Phase 6. |
| ADM-02 .. ADM-08 | PENDING (Phase 6). ADM-03 error classes already covered by `InstrumentConfigValidatorTest`; ADM-05 immutability covered at import level by DB-06. |
| RPT-01 .. RPT-07 | PENDING (Phase 7) |

## Security, privacy, operations

| ID | Status | Method / evidence |
| --- | --- | --- |
| SEC-01 | PASS (walk endpoints) | All SQL parameterized (`core/Db`; `schema-contract.test.mjs` now also covers `src/walks`). Injection payloads (`'; DROP TABLE icf.walk; --`, `1 OR 1=1`) in notes, Other text, org-unit ids, value codes, and walk ids are stored as text or rejected with 400 (`WalkServiceTest`, `walks.test.mjs`). Remaining surfaces (admin, reports) in their phases. |
| SEC-02 | PASS (editor and list) | DOM construction only, `core/HtmlEncoder`, strict CSP (unchanged); stored payload round trip proven by SAVE-08 (editor and My Walks card render the text; no `<img>`/`<script>` injected, no page error). Export preview, admin, reports: later phases. |
| SEC-03 | PASS | `auth.test.mjs`: `POST /api/auth/sign-out` without or with a wrong `X-ICFWalk-CSRF-Token` is 403 `CSRF_TOKEN_INVALID` with no mutation; with the session token it succeeds. Maintenance routes are token-header authenticated (no cookies). |
| SEC-04 | PASS (local) | Session cookie observed `HttpOnly; SameSite=Lax` (`auth.test.mjs`); `Secure` enforced by configuration (`ICFWALK_COOKIE_SECURE` cannot be false in production, `ConfigLoaderTest`/`IdentityTest`); session id rotated at sign-in, invalidated at sign-out, idle timeout `ICFWALK_SESSION_TIMEOUT_MINUTES`. TLS termination is a deployment responsibility (documented). NOT TESTABLE HERE: Adobe ColdFusion's `this.sessionCookie` handling. |
| SEC-05 | PASS (saves, conflicts, rejections) | `WalkServiceTest.testAuditAndMutationLogsContainNoNarrativeContent`: after saves with notes, summary text, and an observer name, no audit `details_json` or `walk_mutation.result_json` row for the walk contains them; save/conflict/rejection log lines carry walk id, codes, paths, and row versions only. Export logs: Phase 5/8. |
| SEC-06 | PASS (idempotency) / NOT TESTABLE HERE (restart) | The retry path is proven: a save whose response was lost is retried with the same `clientMutationId` and replays the committed result without duplicate rows (SAVE-03 browser, SAVE-06 service/HTTP). Restarting the application server mid-request was not automated in this environment; the mutation log is written in the same transaction as the change, so a restart leaves either both or neither. |
| SEC-07 | PASS (local) | `docs/LOCAL_SETUP.md` clean-install steps executed end to end in this environment (Docker SQL Server, schema apply, Lucee start, seed, tests). NOT TESTABLE HERE on Adobe ColdFusion 2023 itself. |

## Accessibility and responsive behavior

| ID | Status | Method / evidence |
| --- | --- | --- |
| A11Y-01 | PASS (editor, save, complete) | `browser.test.mjs` "A11Y-01" plus the Phase 4 states: Save/Retry/Complete are buttons, completion-error links move focus to the control and expand its section, the conflict panel receives focus on its primary action. |
| A11Y-02 | PASS (Phase 3 + 4 views) | Save status `role="status"`/`aria-live`; completion errors in a `role="alert"` summary, each field `aria-invalid` with `aria-describedby`, announced count; conflict panel `role="alertdialog"` with label and description; void reason field labelled. Screen-reader verification with NVDA/VoiceOver remains a manual check. |
| A11Y-03 | PASS (Phase 3 + 4 views) | axe-core 4 (WCAG 2.0/2.1 A+AA) on the editor, the list, the completion-error state, and the conflict panel: no serious/critical violations. Admin and reports: later phases. |
| A11Y-04 | PASS (Phase 3 views) | Contrast: muted text and the REQUIRED badge darkened from the prototype values (see BUILD_STATUS); selected pills carry a check mark in addition to color; required fields carry a badge, not color alone. |
| A11Y-05 | PASS (automated part) | 375/768/1280 px: no horizontal overflow (`scrollWidth` check) with Part 1, Part 2, and a component expanded; screenshots in `docs/evidence/screenshots/`. 200 % zoom and manual review: listed under browser checks in BUILD_STATUS. |
