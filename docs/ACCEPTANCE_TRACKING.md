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
| DB-03 | PASS | Same test: 002 re-applied without error, one `definition` column. |
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
| AUTH-05 | PASS | `AuthorizationTest.testAuth05...`: report-only roles have no `walk.read`/`walk.create`/`walk.edit_owned`; walk access is 403 with no identifier in the message. Walk endpoints themselves arrive in Phase 4 and must call `authorizeWalk`. |
| AUTH-06 | PASS | `AuthorizationTest.testAuth06...` (admin has no walk/report capability; walkers lack `instrument.manage`) and `auth.test.mjs` (admin route 403 for walkers and role-less users, 200 for the admin; admin `/api/me` shows no walk/report scope). |
| AUTH-07 | PASS | `AuthorizationTest.testAuth07...` (future and expired assignments yield no scope) and `testEndingAnAssignmentRevokesAccessImmediately`. |
| AUTH-08 | PASS | `AuthorizationTest.testAuth08...`: descendants included, unrelated branch and inactive descendants excluded; `include_descendants = 0` covers only the assigned unit. |
| AUTH-09 | PARTIAL | Org-unit and walk identifiers: `AuthorizationTest.testAuth09...` (out-of-scope 404, unknown 404, malformed 400, injection-shaped input rejected, `resolveScopedOrgUnit` re-resolves). Version/item/option/dimension GUID tampering is exercised with the walk response endpoints in Phase 4. |

## My Walks and lifecycle

Phase 3 covers the browser experience against the in-memory `SessionWalkStore`; server persistence,
pinning, voiding, and completion arrive in Phase 4, when these rows are re-verified end to end.

| ID | Status | Method / evidence |
| --- | --- | --- |
| WALK-01 | PASS (UI) | `tests/node/browser.test.mjs` "WALK-01": empty-state wording `No walks saved yet. Start one with "New walk" above.` and the `+ New walk` action. Server-side listing (Phase 4) will feed the same view. |
| WALK-02 | PARTIAL | New walk creates one DRAFT working copy against the served version id with the configured defaults (applicability = No) and the walk's org unit (single creatable unit, or the school chooser). Persistence and owner pinning: Phase 4. |
| WALK-03 | PENDING (Phase 4) | |
| WALK-04 | PASS (UI) | `browser.test.mjs` "My Walks": cards show grade · content, school (Other text), date, relative time; newest updated first. Sorting by `updated_at` from the server: Phase 4. |
| WALK-05 | PASS (UI) | Open restores the working state (grade, content, ratings, notes) into the rendered editor. Server-loaded dimensions/responses: Phase 4. |
| WALK-06 | PASS (UI) | Delete asks `Delete this walk? This cannot be undone.`; confirming removes the card. Void policy, audit event: Phase 4. |
| WALK-07 | PASS (UI) | Cancel leaves the list unchanged. |
| WALK-08 .. WALK-11 | PENDING (Phase 4) | |

## Metadata and conditional UI

Each COND row is proven three ways: `VisibilityEngineTest` (CFML engine), `tests/node/visibility.test.mjs`
(browser engine against the served model, plus the shared vectors), and `tests/node/browser.test.mjs`
(real DOM in Chromium). The persisted HIDDEN/NOT_APPLICABLE states (COND-10, COND-12 "in one
transaction") are Phase 4 and are listed as PARTIAL.

| ID | Status | Method / evidence |
| --- | --- | --- |
| COND-01 | PASS | Elementary school → `prek,k,1,2,3,4,5` (engine tests and DOM `<select>` options). |
| COND-02 | PASS | Middle school → `6,7,8`. |
| COND-03 | PASS | High school, Dream Academy, Central School → `9,10,11,12` (from `valueGroup` metadata, not names). |
| COND-04 | PASS | Other → full PreK–12 list; no school → full list. |
| COND-05 | PASS | Grade 5 + middle school → grade cleared (`DIMENSION_CLEARED/OPTION_FILTER`), PreK–K section hides with the cleared grade. |
| COND-06 | PASS | Period visible for 6–12 only; hidden value retained as `HIDDEN` (`ICFWALK_HIDDEN_PERIOD_POLICY=RETAIN_HIDDEN`, `CLEAR` also tested). |
| COND-07 | PASS | PreK and K show PreK–K Classroom; every other grade hides it. |
| COND-08 | PASS | Dual Language, MAC, PREP, Ignite, AVID, ESL each show only their section; General Education shows none; Other free text never matches. |
| COND-09 | PASS | Art, Music, CTE show Content-Area Look-Fors; other content areas hide it. |
| COND-10 | PARTIAL | Answer retained while hidden (`HIDDEN`) and reappears when the condition returns (engine + DOM). Persisting the HIDDEN state: Phase 4. |
| COND-11 | PASS | New walk: both applicability controls pressed `No`, rating rows hidden, header reads `Not part of this lesson`. |
| COND-12 | PARTIAL | Yes → rate → No: ratings cleared (`RESPONSE_CLEARED/NOT_APPLICABLE`), rows hidden, notes retained, count/average excludes them. Same-transaction server clearing: Phase 4 (the server engine `normalize` already produces the change list). |
| COND-13 | PASS | Back to Yes: rows return `UNANSWERED`, cleared ratings do not reappear, notes remain. |
| COND-14 | PASS | `RenderModelTest` compares all 138 options and definitions with the JSON; `browser.test.mjs` opens every visible definition toggle and compares the rendered rows. |
| COND-15 | PASS | Counts use answered ratings only (`1/2 rated`); an option code outside the set is `UNANSWERED`; blanks never become zero. |

## Autosave, summary, administration, reporting

| IDs | Status |
| --- | --- |
| SAVE-01 .. SAVE-08 | PENDING (Phase 4). Phase 3 shows the prototype's status strings (`All changes saved`, `Unsaved changes`, `Saving...`) through the `WalkStore` seam; no debounce or server save yet. |
| SUM-01 .. SUM-09 | PENDING (Phase 5) |
| ADM-01 | PARTIAL | Import validation summary with counts and 17 placeholder warnings exists at the service/endpoint level; the admin UI and role check are Phase 6. |
| ADM-02 .. ADM-08 | PENDING (Phase 6). ADM-03 error classes already covered by `InstrumentConfigValidatorTest`; ADM-05 immutability covered at import level by DB-06. |
| RPT-01 .. RPT-07 | PENDING (Phase 7) |

## Security, privacy, operations

| ID | Status | Method / evidence |
| --- | --- | --- |
| SEC-01 | PARTIAL | All Phase 1 SQL is parameterized (`core/Db`; `tests/node/schema-contract.test.mjs` checks table references). Payload tests arrive with user-facing endpoints (Phase 8). |
| SEC-02 | PARTIAL | All browser rendering uses `textContent`/DOM construction (no `innerHTML` with content); server HTML (shell values, error page) is encoded by `core/HtmlEncoder`; strict CSP (`script-src 'self'`, no inline scripts or styles). Payload tests with stored values arrive with the Phase 4 endpoints (SAVE-08). |
| SEC-03 | PASS | `auth.test.mjs`: `POST /api/auth/sign-out` without or with a wrong `X-ICFWalk-CSRF-Token` is 403 `CSRF_TOKEN_INVALID` with no mutation; with the session token it succeeds. Maintenance routes are token-header authenticated (no cookies). |
| SEC-04 | PASS (local) | Session cookie observed `HttpOnly; SameSite=Lax` (`auth.test.mjs`); `Secure` enforced by configuration (`ICFWALK_COOKIE_SECURE` cannot be false in production, `ConfigLoaderTest`/`IdentityTest`); session id rotated at sign-in, invalidated at sign-out, idle timeout `ICFWALK_SESSION_TIMEOUT_MINUTES`. TLS termination is a deployment responsibility (documented). NOT TESTABLE HERE: Adobe ColdFusion's `this.sessionCookie` handling. |
| SEC-05 | PASS (unit) | `LoggerTest` redaction and truncation; audit details denylist in `AuditRepository`; `AuthorizationTest.testDeniedAccessIsAuditedWithoutNarrativeOrTokens`. Full save/conflict/export log inspection is Phase 8. |
| SEC-06 | PENDING (Phase 4) | |
| SEC-07 | PASS (local) | `docs/LOCAL_SETUP.md` clean-install steps executed end to end in this environment (Docker SQL Server, schema apply, Lucee start, seed, tests). NOT TESTABLE HERE on Adobe ColdFusion 2023 itself. |

## Accessibility and responsive behavior

| ID | Status | Method / evidence |
| --- | --- | --- |
| A11Y-01 | PASS (editor) | `browser.test.mjs` "A11Y-01": pills toggle with Enter/Space, accordions with Enter, `aria-expanded`/`aria-pressed` state, visible focus outline, every control labelled, pill rows are labelled groups. Full keyboard completion of a walk (save/complete) re-runs in Phase 4/8. |
| A11Y-02 | PARTIAL | Programmatic names/relationships verified by the same test and axe; save status uses `role="status"`/`aria-live`; section show/hide is announced. Validation-error announcements: Phase 4 (completion). |
| A11Y-03 | PASS (Phase 3 views) | axe-core 4 (WCAG 2.0/2.1 A+AA rules) on the editor (expanded states) and the list: no serious/critical violations. Admin and reports: later phases. |
| A11Y-04 | PASS (Phase 3 views) | Contrast: muted text and the REQUIRED badge darkened from the prototype values (see BUILD_STATUS); selected pills carry a check mark in addition to color; required fields carry a badge, not color alone. |
| A11Y-05 | PASS (automated part) | 375/768/1280 px: no horizontal overflow (`scrollWidth` check) with Part 1, Part 2, and a component expanded; screenshots in `docs/evidence/screenshots/`. 200 % zoom and manual review: listed under browser checks in BUILD_STATUS. |
