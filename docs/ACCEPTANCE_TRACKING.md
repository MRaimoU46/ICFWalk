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

## My Walks and lifecycle, conditional UI, autosave, summary, administration, reporting

| IDs | Status |
| --- | --- |
| WALK-01 .. WALK-11 | PENDING (Phases 3-4) |
| COND-01 .. COND-15 | PENDING (Phase 3-4). Rules, grade filtering metadata, and skippable defaults are present in the compiled snapshot (`tests/node/snapshot.test.mjs`). |
| SAVE-01 .. SAVE-08 | PENDING (Phase 4) |
| SUM-01 .. SUM-09 | PENDING (Phase 5) |
| ADM-01 | PARTIAL | Import validation summary with counts and 17 placeholder warnings exists at the service/endpoint level; the admin UI and role check are Phase 6. |
| ADM-02 .. ADM-08 | PENDING (Phase 6). ADM-03 error classes already covered by `InstrumentConfigValidatorTest`; ADM-05 immutability covered at import level by DB-06. |
| RPT-01 .. RPT-07 | PENDING (Phase 7) |

## Security, privacy, operations

| ID | Status | Method / evidence |
| --- | --- | --- |
| SEC-01 | PARTIAL | All Phase 1 SQL is parameterized (`core/Db`; `tests/node/schema-contract.test.mjs` checks table references). Payload tests arrive with user-facing endpoints (Phase 8). |
| SEC-02 | PENDING (Phase 3+) | API responses are canonical JSON; HTML output does not exist yet. |
| SEC-03 | PASS | `auth.test.mjs`: `POST /api/auth/sign-out` without or with a wrong `X-ICFWalk-CSRF-Token` is 403 `CSRF_TOKEN_INVALID` with no mutation; with the session token it succeeds. Maintenance routes are token-header authenticated (no cookies). |
| SEC-04 | PASS (local) | Session cookie observed `HttpOnly; SameSite=Lax` (`auth.test.mjs`); `Secure` enforced by configuration (`ICFWALK_COOKIE_SECURE` cannot be false in production, `ConfigLoaderTest`/`IdentityTest`); session id rotated at sign-in, invalidated at sign-out, idle timeout `ICFWALK_SESSION_TIMEOUT_MINUTES`. TLS termination is a deployment responsibility (documented). NOT TESTABLE HERE: Adobe ColdFusion's `this.sessionCookie` handling. |
| SEC-05 | PASS (unit) | `LoggerTest` redaction and truncation; audit details denylist in `AuditRepository`; `AuthorizationTest.testDeniedAccessIsAuditedWithoutNarrativeOrTokens`. Full save/conflict/export log inspection is Phase 8. |
| SEC-06 | PENDING (Phase 4) | |
| SEC-07 | PASS (local) | `docs/LOCAL_SETUP.md` clean-install steps executed end to end in this environment (Docker SQL Server, schema apply, Lucee start, seed, tests). NOT TESTABLE HERE on Adobe ColdFusion 2023 itself. |

## Accessibility and responsive behavior

| IDs | Status |
| --- | --- |
| A11Y-01 .. A11Y-05 | PENDING (Phase 3 and 8) |
