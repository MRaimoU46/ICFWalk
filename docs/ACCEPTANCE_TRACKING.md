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
| DB-03 | PASS | Same test: 002 re-applied without error, one `definition` column. Phase 4 migration `003_walk_mutation.sql` and correction migration `004_mutation_fingerprint.sql` applied and re-applied without error in the same test (21 tables, 7 `walk_mutation` columns, one `request_fingerprint` column, digest constraint accepts lower-case hex and refuses anything else, pre-patch rows stay valid). |
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

## Phase 0-4 correction session (audit findings)

Regression coverage added for the independent architecture/security/data-integrity audit.
Correction IDs are local to this session; each maps to the acceptance IDs it strengthens.
CFML evidence: `tests/cfml/specs/WalkCorrectionTest.cfc` (17 cases),
`tests/cfml/specs/WalkSchoolScopeTest.cfc` (4), `tests/cfml/specs/InstrumentScopeTest.cfc` (4).
HTTP evidence: `tests/node/walks.test.mjs` (3 added cases). Browser evidence:
`tests/node/browser-persistence.test.mjs` (3 added cases). Migration evidence:
`tests/node/db-scripts.test.mjs`, `tests/node/schema-contract.test.mjs`.

| ID | Finding | Status | Method / evidence |
| --- | --- | --- | --- |
| CORR-01 | A create replay could return a walk the current principal can no longer access (`loadDto`'s `skipAuthorization` flag was never read, and create replay ran no record-level check). | CONFIRMED, FIXED | `WalkCorrectionTest.testCorr01CreateReplayIsReauthorizedAfterAccessIsRevoked`: create at School A, revoke A, keep School B, retry the A mutation -- refused, the walk stays invisible, and the exact retry replays once access is restored. `testCorr02ReplayOfARecordedMutationOutsideScopeIsNotFound` forges a mutation row pointing at an out-of-scope walk and gets 404. HTTP: `walks.test.mjs` "a create mutation id from a school the caller lost". Strengthens WALK-03, AUTH-04, AUTH-09, SEC-06. |
| CORR-02 | Misleading `skipAuthorization` parameter. | CONFIRMED, REMOVED | `loadDto(walkId, principal)` no longer takes it; every caller authorizes the record first (`WalkService`). |
| CORR-03 | Mutation ids were bound only to actor/action/walk, so the same id could replay a different semantic request. | CONFIRMED, FIXED | Migration `004_mutation_fingerprint.sql` + `WalkCorrectionTest.testCorr03SameMutationIdWithAnAlteredRequestIsRefused` (create, save, complete, void); HTTP: "a committed mutation whose answer was lost replays on retry". Strengthens SAVE-03, SAVE-06, SEC-06. |
| CORR-04 | A create retry was refused with `INSTRUMENT_VERSION_CHANGED` once a newer version was published, stranding the committed walk. | CONFIRMED, FIXED | `WalkCorrectionTest.testCorr04CreateReplaySurvivesANewerPublishedVersion`. |
| CORR-05 | Whole-state saves relied on the browser resubmitting hidden retained values; an omitted hidden value was deleted. | CONFIRMED, FIXED | `testCorr05OmittedHiddenValueIsRetained` (Period and a conditional classroom section, asserted on `icf.walk_dimension_value` / `icf.walk_response`). Strengthens COND-06, COND-10. |
| CORR-06 | A crafted client could inject or change a currently hidden value. | CONFIRMED, FIXED | `testCorr06HiddenValueInjectionIsIgnored`: crafted hidden values are ignored and the stored values stand. Strengthens SEC-01, SAVE-07. |
| CORR-07 | Hide-then-show lost the retained value when the browser did not echo it. | CONFIRMED, FIXED | `testCorr07HideThenShowRestoresTheStoredValue`. Strengthens COND-06. |
| CORR-08 | CLEAR had to keep working under server-side retention. | VERIFIED | `testCorr08OmittingAVisibleValueClearsIt`. |
| CORR-09 | N/A clearing and note preservation had to keep working under server-side retention. | VERIFIED | `testCorr09NotApplicableClearsRatingsAndKeepsNotes`. Strengthens COND-12, COND-13. |
| CORR-10 | `clientMutationId` was optional on create and void. | CONFIRMED, FIXED | `testCorr10EveryMutationRequiresAClientMutationId`; HTTP envelope table in `walks.test.mjs`. |
| CORR-11 | `rowVersion` was optional on void. | CONFIRMED, FIXED | `testCorr11SaveCompleteAndVoidRequireARowVersionButCreateDoesNot`. |
| CORR-12 | A stale void had to refuse without changing state. | VERIFIED | `testCorr12AStaleVoidIsARefusalThatChangesNothing` (status and row version unchanged). Strengthens SAVE-04. |
| CORR-13 | An identical save to a COMPLETED walk appended a revision and advanced the row version. | CONFIRMED, FIXED | `testCorr13IdenticalCompletedSaveIsANoOpAndAMaterialOneAppendsOneRevision`; HTTP equivalent asserts `revisionCount` and `rowVersion`. Strengthens WALK-10. |
| CORR-14 | `observed_at` kept a stale date after the Visit Date was cleared. | CONFIRMED, FIXED | `testCorr14VisitDateSetThenClearedFallsBackToTheCreationInstant` (asserted against `icf.walk.observed_at` and `created_at`). |
| CORR-15 | A whole-state save accepted a missing `dimensions` or `responses` root object. | CONFIRMED, FIXED | `testCorr15WholeStateSaveRequiresBothRootContainers`; HTTP envelope table. |
| CORR-16 | CFML coercion let a JSON number or boolean stand in for a string code. | CONFIRMED, FIXED | `testCorr16JsonPrimitiveTypesAreCheckedNotCoerced` (JSON `4` is not the option code `"4"`). Strengthens SAVE-07, SEC-01. |
| CORR-17 | Browser-provided response `state` is derived data. | VERIFIED, MADE EXPLICIT | `testCorr17ClientAssertedResponseStateCannotControlPersistedState` (400 `CLIENT_STATE_NOT_ACCEPTED`, nothing written, the server's own state stands). |
| CORR-18 | `walk.org_unit_id` and the School dimension could contradict each other. | CONFIRMED, FIXED | `WalkSchoolScopeTest`: server fill and lock, School A vs School B and "Other" refused with 409 `SCHOOL_ORG_MISMATCH` and nothing written, district-authorized selection of an allowed child SCHOOL accepted, unaligned deployments still refused another school's label. Strengthens AUTH-04, RPT scope work in Phase 7. |
| CORR-19 | Current-version selection was not scoped to ICFWALK and ignored the effective window. | CONFIRMED, FIXED | `InstrumentScopeTest.testASecondInstrumentNeverSuppliesTheCurrentVersion`, `testFutureAndExpiredIcfwalkVersionsAreNotSelected`. Strengthens WALK-01, WALK-11. |
| CORR-20 | Draft discard resolved a version by label alone, across instruments. | CONFIRMED, FIXED | `InstrumentScopeTest.testDiscardDraftCannotReachAnotherInstrumentsSameLabelDraft`. Strengthens DB-06. |
| CORR-21 | The runtime snapshot was parsed and cached without checking its stored checksum. | CONFIRMED, FIXED | `InstrumentScopeTest.testACorruptedSnapshotFailsClosedOnAnUncachedLoad` (mismatch and missing digest both fail closed; the intact copy still loads). Strengthens DB-05, SEC-01. |
| CORR-22 | Failed, conflicted, or in-flight saves could be abandoned by Back/List or reload. | CONFIRMED, FIXED | `browser-persistence.test.mjs`: "a failed save plus Back/List keeps the editor and the unsaved input until an explicit decision", "an unresolved conflict plus Back/List demands an explicit discard", "beforeunload protects in-flight and queued saves". Strengthens SAVE-03, SAVE-04, SAVE-05, A11Y-02. |
| CORR-23 | Ambiguous failures abandoned the pending operation id. | CONFIRMED, FIXED | Transport failures and HTTP 5xx now retain the `clientMutationId` and the exact payload for create, save, complete, and void (`app/assets/js/app.js`); `browser-persistence.test.mjs` SAVE-03 asserts the reused id on both the transport-failure and the 5xx path. |

## Second correction session (independent verification audit)

Findings raised by the second verification audit against commit `b862af9`. All four were confirmed
against the code before anything was changed; none was rejected.

| ID | Finding | Status | Evidence |
| --- | --- | --- | --- |
| CORR2-01 | A replay returned the walk's *current* row version, so an old successful SAVE retried after a later successful save paired the retrying session's stale local state with a live concurrency token, and its next save overwrote the newer work with no conflict. | CONFIRMED, FIXED | `WalkReplayCoherenceTest.testAnOldSaveReplayedAfterALaterSaveCannotOverwriteIt` (the exact session A / session B / retry scenario, asserting the stored value, the stored row version, the mutation-row count, and that the returned recorded token is then refused as stale); `testAReplayIsStillIdempotentWhileTheAggregateHasNotMoved` (the recovery path still works); `WalkServiceTest.testSave06RetryWithSameMutationIdCommitsOneLogicalChange`; `walks.test.mjs` "CORR2: an idempotent SAVE replay never hands stale session state a newer row version" (two HTTP sessions, database-level assertions); `browser-persistence.test.mjs` "CORR2: a SAVE committed but lost, retried after another session saved, becomes a conflict rather than a silent overwrite" (two browsers). |
| CORR2-02 | School-dimension identity rested on `org_unit_code` = the dimension's `valueCode`. Two SCHOOL org units whose codes match no instrument School value were unprotected: any School value, including "Other", was accepted at either. | CONFIRMED, FIXED | `WalkSchoolScopeTest`: `testUnmappedSchoolUnitsAcceptNoSchoolValue` (two unmapped SCHOOL units; every value and "Other" refused 409 `SCHOOL_ORG_UNMAPPED`, nothing filled, no row-version movement, no walk created, every refusal audited), `testCodeEqualityAloneMapsNothing` (a unit whose code *is* an instrument School value still fails closed without a row), `testExplicitMappingIsFilledAndLocked`, `testAWalkAuthorizedAtSchoolACannotBeSubmittedAsSchoolB` (School B and "Other" refused 409 `SCHOOL_ORG_MISMATCH`, stored value and row version unchanged), `testOneSchoolValueBelongsToOneOrgUnit`, `testDistrictUserMaySelectAnAuthorizedDescendantSchool`; `WalkServiceTest.testCond05And06GradeFilterClearsAndHiddenPeriodIsRetained` (aligned/mapped schools continue to drive the grade filter); `walks.test.mjs` "CORR2: the School dimension follows an explicit mapping and fails closed without one" and "CORR2: the alignment endpoint derives mappings only from exact code matches"; `db-scripts.test.mjs` and `schema-contract.test.mjs` for the two uniqueness constraints that carry the invariant. Supersedes CORR-18. |
| CORR2-03 | The completion mutation id was one scalar, not scoped per walk; a void retry rebuilt its reason and row version from the live UI; and an ambiguous create, completion, or void could be abandoned by navigation or reload. | CONFIRMED, FIXED | `browser-persistence.test.mjs`: "CORR2: a CREATE committed but lost is retried with the same id and body, and yields exactly one walk", "CORR2: a COMPLETE committed but answered 5xx is retried with the same id, and never reused across walks", "CORR2: a VOID committed but lost is retried from its record, not from the edited input" (each asserting server commit then answer loss, exact id and body reuse, exactly one database effect, and the navigation/unload guard); `walks.test.mjs` "CORR2: an ambiguous outcome retries the exact same mutation id and body on every route" (CREATE/SAVE/COMPLETE/VOID replay, a rebuilt body refused, a COMPLETE id refused against another walk which stays DRAFT). Supersedes CORR-22 and CORR-23. |
| CORR2-04 | Migration 004 left pre-migration mutation rows with a NULL fingerprint, and those rows replayed as ordinary successes although nothing recorded could prove the new request was the original one. | CONFIRMED, FIXED | `WalkReplayCoherenceTest.testAnExactLookingRetryAgainstALegacyRowIsARefusal`, `testAnAlteredRequestAgainstALegacyRowIsTheSameRefusal`, `testAuthorizationAnswersBeforeTheLegacyConflict` (an authorized target gets 409 `MUTATION_LEGACY_UNVERIFIABLE`; a now-unauthorized target gets 404 with no hint, and neither writes anything); `walks.test.mjs` "CORR2: a legacy mutation row with no request fingerprint is never replayed as a success". |

## Third correction session (residual defects)

Three residual defects reported against commit `d4635b7`. Each was reproduced against the code
before anything was changed, and each regression below was run against the unfixed code first and
observed to fail. Phase 5 was not started.

| ID | Finding | Status | Evidence |
| --- | --- | --- | --- |
| CORR3-01 | `WalkService.replay` compared the recorded row version against an unlocked read and then built the DTO from further unlocked reads, so a concurrent save committing between the two made a replay judged coherent return the newer aggregate and a newer row version to a session still holding the original mutation's state. | CONFIRMED, FIXED | The comparison and the aggregate materialization now happen in one transaction holding the walk mutation lock (`findWalk(..., true)`), the lock every mutation path takes before it writes, and the row version is re-asserted under that lock before the DTO leaves; a mismatch at either point is 409 `MUTATION_REPLAY_SUPERSEDED`. `WalkReplayCoherenceTest.testAConcurrentSaveCannotLandBetweenTheCoherenceCheckAndTheDto` forces the interleaving deterministically through a decorating repository (`tests/cfml/support/InterceptingWalkRepository.cfc`) that fires at the DTO's first aggregate read and starts a real second session saving the same walk: that save is held by the lock (asserted, not hoped for), the replay returns the row version and the state its mutation committed, the deferred save then lands, and the token the replay returned is refused as stale. `testASupersededReplayNeverMaterializesTheNewerAggregate` proves a superseded replay refuses without reading the aggregate at all. Against the unfixed `replay` the first test fails with the concurrent save observed `COMPLETED` inside the window. Supersedes CORR2-01. |
| CORR3-02 | The School dimension's free-text option (`other`) is a value the instrument defines, so every "is this a School value?" check accepted it and it could be stored as a school's identity -- labelling that school's walks "Other" and, because the mapping is unique on (dimension, value), taking a value that names no school away from every other school. Code-equality alignment persisted mappings with no operator decision and stored the org unit's spelling of the code rather than the instrument's. | CONFIRMED, FIXED | `OrgUnitRepository.upsertDimensionMapping` refuses a non-identifying value outright (`ORG_UNIT_DIMENSION_VALUE_NOT_IDENTIFYING`), so no route can store one, and migration `005` adds `CK_org_unit_dimension_map_identifying` so neither can a script or a hand-written statement (existing rows are removed and reported on apply). `schoolValueCode: "other"` is 400 `ORG_UNIT_SCHOOL_VALUE_NOT_IDENTIFYING`. `align-school-dimension` now reports `candidates[]` and persists only pairs an operator confirms in `confirm[]`, each re-derived and re-validated, stored as the instrument spells the code; maintenance authorization is unchanged. `WalkSchoolScopeTest.testANonIdentifyingValueIsRefusedAsAnIdentityMapping` and `testASchoolUnitCodedOtherStaysUnmappedAndFailsClosed` (a SCHOOL unit coded exactly `other` stays unmapped, nothing is filled, every submitted value is refused 409 `SCHOOL_ORG_UNMAPPED`, and no mapping, School value, or row version moves); `walks.test.mjs` "CORR3: the School dimension's free-text value is never stored as a school's identity" (import refused, never a candidate, a forced confirmation refused, no mapping row added or removed, the fail-closed walk path at that unit) and "CORR3: alignment reports candidates and persists nothing without an explicit per-pair confirmation" (candidate-only by default, mismatched and non-candidate confirmations refused, the confirmed pair stored in the instrument's spelling, idempotent, unauthenticated calls refused); `schema-contract.test.mjs` and `db-scripts.test.mjs` for the constraint and the convergence path. Supersedes CORR2-02. |
| CORR3-03 | The operation registry had one `PENDING` status covering both "minted, nothing sent" and "request on the wire", so an editor change during an in-flight save deleted the record whose request had already been sent. When that answer was then lost there was nothing to retry: the committed save was never confirmed and the queued newer state went out under a new id against a row version the server had already moved past. Separately, an ambiguous `COMPLETE` or `VOID` could outlive the only control that could retry it (a destroyed confirmation row, a hidden Complete button), leaving a permanent unload guard with nothing to click. | CONFIRMED, FIXED | The status is now `UNSENT` / `IN_FLIGHT` / `AMBIGUOUS`, and only an `UNSENT` record may be replaced by a newer payload; a reload of the walk releases an `UNSENT` save record but keeps a sent one. Unresolved operations are rendered from the registry into an unfinished-operations bar outside both views, each with a retry that re-sends the exact frozen request. `browser-persistence.test.mjs`: "CORR3: editing during an in-flight SAVE keeps that save's record; a lost response retries it first, then the queued edit under a new id" and the same for "an HTTP 5xx" (the save is held on the wire, the edit lands, the answer is lost, and the three requests are asserted: the original, its byte-for-byte retry under the same id and row version, then the queued state under a new id against the row version the retry settled on, with both edits accounted for and the guard released); "CORR3: an ambiguous COMPLETE stays resolvable after the walk is reloaded from server state" (the completion commits, the stale session conflicts, reconciling reloads the walk as COMPLETED and hides its button, and the retry is still offered and replays to exactly one revision); "CORR3: an ambiguous VOID stays resolvable after navigation destroys the row that started it" (the confirmation row is gone and the walk is not listed, yet the operation is still offered and replays to exactly one void). All four fail against the unfixed browser code. Supersedes CORR2-03. |
