# Phase 8 acceptance ledger

Every acceptance ID in `docs/ACCEPTANCE_TESTS.md`, with how it was verified, where, the result, and
what is still not verified. "Both engines" means the final gate on the Phase 8 code commit
`282a4ec27cd5d200ed190b134c0145632a970cee`: brand-new SQL Server 2022 databases, the full suite (Node, HTTP, Playwright and CFML)
once against Lucee 6.2.8.20 and once against Adobe ColdFusion 2023 Update 25 (`gate-282a4ec27cd5d200ed190b134c0145632a970cee/`).
The detailed per-test evidence for IDs accepted in Phases 0 to 7 is unchanged and remains in
`docs/ACCEPTANCE_TRACKING.md`; this ledger records what Phase 8 re-ran, added and could not do.

Methods: **A** automated (the named suites), **S** static check (reads the source, no engine),
**O** operations exercise (`tests/ops/`, run separately on the code commit), **M** manual checklist
(`docs/VERIFICATION_CHECKLISTS.md`). NOT TESTABLE HERE always names what is missing and the
checklist that closes it.

## Package and configuration

| ID | Method | Evidence | Environment | Result | Gap |
| --- | --- | --- | --- | --- | --- |
| PKG-01 | A, S | `scripts/validate-handoff.mjs` (gate step 4), `package.test.mjs` | Node 22 | PASS | none |
| PKG-02 | A | `package.test.mjs`; `InstrumentConfigValidatorTest` (`RETIRED_CONTENT_PRESENT`) | Both engines | PASS | none |
| PKG-03 | A | `package.test.mjs`; `InstrumentImportServiceTest` (17 placeholders) | Both engines | PASS | none |
| PKG-04 | A | `package.test.mjs` | Node 22 | PASS | none |
| PKG-05 | A | `package.test.mjs` reads the aligned workbook sheets | Node 22 | PASS | The workbook opened in Microsoft Excel itself: NOT TESTABLE HERE (no Excel; checklist 4) |

## Database and seed

| ID | Method | Evidence | Environment | Result | Gap |
| --- | --- | --- | --- | --- | --- |
| DB-01 | A, O, S | `db-scripts.test.mjs`; gate step 8 applies 001 to 007 to a brand-new database (twice: Lucee's and ColdFusion's); `sqlserver-2016.test.mjs` finds no T-SQL newer than SQL Server 2016 | SQL Server 2022 16.0.4295.3 | PASS on 2022 | SQL Server 2016 itself: NOT TESTABLE HERE (no image; checklist 2) |
| DB-02 | A, O | `db-scripts.test.mjs`; gate step 8 (`--only 001` refused, 50001) on both databases | SQL Server 2022 | PASS | as DB-01 |
| DB-03 | A, O | `db-scripts.test.mjs`; gate step 8 re-applies 002 to 007; `database-operations.test.mjs` (a killed 007 rolls back completely, then applies and re-applies) | SQL Server 2022 | PASS | as DB-01 |
| DB-04 | A | `InstrumentImportServiceTest.testDb04...` | Both engines | PASS | none |
| DB-05 | A | `InstrumentImportServiceTest.testDb05...`, `...testReordered...` | Both engines | PASS | none |
| DB-06 | A | `InstrumentImportServiceTest.testDb06...` | Both engines | PASS | none |
| DB-07 | A | `InstrumentImportServiceTest.testDb07...` | Both engines | PASS | none |
| DB-08 | A | `InstrumentImportServiceTest.testDb08...`, `...testTransactionRollsBack...` | Both engines | PASS | none |
| DB-09 | A | `InstrumentImportServiceTest.testDb09...`; `LongTextRetrievalTest` (P8-04: the whole snapshot reaches ColdFusion) | Both engines | PASS | none |

## Authentication and authorization

| ID | Method | Evidence | Environment | Result | Gap |
| --- | --- | --- | --- | --- | --- |
| AUTH-01 | A, O | `auth.test.mjs`; `security-surface.test.mjs` (every route anonymous: 401, nothing but an error); `production-profile.test.mjs` (gateway only) | Both engines; production profile on both | PASS | The real SSO gateway: NOT TESTABLE HERE (D1; checklist 6) |
| AUTH-02 | A, O | `ConfigLoaderTest`, `IdentityTest`; `production-profile.test.mjs` (the stub on with no `ICFWALK_ENVIRONMENT` refuses to start and the log names the setting; P8-03) | Both engines | PASS | none |
| AUTH-03 | A | `AuthorizationTest.testAuth03...`, `auth.test.mjs` | Both engines | PASS | none |
| AUTH-04 | A | `AuthorizationTest.testAuth04...`; `security-surface.test.mjs` | Both engines | PASS | none |
| AUTH-05 | A | `AuthorizationTest.testAuth05...`, `WalkServiceTest.testCrossScopeAccessFailsClosedThroughTheService`, `walks.test.mjs` | Both engines | PASS | none |
| AUTH-06 | A | `AuthorizationTest.testAuth06...`; `security-surface.test.mjs` (the capability wall on every route) | Both engines | PASS | none |
| AUTH-07 | A | `AuthorizationTest.testAuth07...`, `testEndingAnAssignmentRevokesAccessImmediately` | Both engines | PASS | none |
| AUTH-08 | A | `AuthorizationTest.testAuth08...` | Both engines | PASS | none |
| AUTH-09 | A | `AuthorizationTest.testAuth09...`, `WalkServiceTest` tampering cases; `security-surface.test.mjs` (every path parameter) | Both engines | PASS | none |

## My Walks and lifecycle

| ID | Method | Evidence | Environment | Result | Gap |
| --- | --- | --- | --- | --- | --- |
| WALK-01 | A | `browser.test.mjs`, `browser-persistence.test.mjs` | Both engines (Chromium) | PASS | none |
| WALK-02 | A | `WalkServiceTest.testWalk02...` | Both engines | PASS | none |
| WALK-03 | A | `WalkServiceTest.testWalk03...` | Both engines | PASS | none |
| WALK-04 | A | `WalkServiceTest.testWalk04...`, `browser.test.mjs`; `WalkListBoundTest` (P8-11: the list reads the listed walks' values only) | Both engines | PASS | none |
| WALK-05 | A | `WalkServiceTest.testSaveRoundTrip...`, browser suites; `null-text.test.mjs` (P8-08) | Both engines | PASS | none |
| WALK-06 | A | `browser.test.mjs` "My Walks", `WalkServiceTest` | Both engines | PASS | none |
| WALK-07 | A | `browser.test.mjs` "My Walks" | Both engines | PASS | none |
| WALK-08 | A | `WalkServiceTest`, `walks.test.mjs` | Both engines | PASS | none |
| WALK-09 | A | `WalkServiceTest.testWalk09...`, browser suites | Both engines | PASS | none |
| WALK-10 | A | `WalkServiceTest.testWalk10...` | Both engines | PASS | none |
| WALK-11 | A, O | `WalkServiceTest.testWalk11...`; `upgrade-and-rollback.test.mjs` (walks made by the Phase 6 release open on this release and on the frozen one) | Both engines; upgrade on Lucee | PASS | none |

## Metadata and conditional UI

| ID | Method | Evidence | Environment | Result | Gap |
| --- | --- | --- | --- | --- | --- |
| COND-01 to COND-04 | A | `VisibilityEngineTest` (shared vectors), `visibility.test.mjs`, `browser.test.mjs` | Both engines | PASS | none |
| COND-05 | A | as above; `VisibilityEngineTest.testMatchesTheSharedVectorsExactly` ("9.0 is not grade 9", P8-10) | Both engines | PASS | none |
| COND-06 to COND-09 | A | `VisibilityEngineTest`, `visibility.test.mjs`, `browser.test.mjs`, `WalkServiceTest` | Both engines | PASS | none |
| COND-10 | A | `WalkServiceTest.testCond10...`, browser | Both engines | PASS | none |
| COND-11 | A | `browser.test.mjs` | Both engines | PASS | none |
| COND-12, COND-13 | A | `WalkServiceTest.testCond12And13...`, browser | Both engines | PASS | none |
| COND-14 | A | `RenderModelTest`, `browser.test.mjs` | Both engines | PASS | none |
| COND-15 | A | `visibility.test.mjs`, browser | Both engines | PASS | none |

## Autosave and concurrency

| ID | Method | Evidence | Environment | Result | Gap |
| --- | --- | --- | --- | --- | --- |
| SAVE-01, SAVE-02 | A | `browser-persistence.test.mjs` | Both engines | PASS | none |
| SAVE-03 | A, O | `browser-persistence.test.mjs`; `browser-session-recovery.test.mjs` (P8-01); `restart-during-autosave.test.mjs` | Both engines; restart on both | PASS | none |
| SAVE-04, SAVE-05 | A | `WalkServiceTest.testSave04...`, `walks.test.mjs`, `browser-persistence.test.mjs` | Both engines | PASS | none |
| SAVE-06 | A, O | `WalkServiceTest.testSave06...`, `walks.test.mjs`; `restart-during-autosave.test.mjs` (a save killed mid-transaction and one committed just before the kill, each retried once) | Both engines; restart on both | PASS | none |
| SAVE-07 | A | `WalkServiceTest`, `walks.test.mjs` | Both engines | PASS | none |
| SAVE-08 | A | `WalkServiceTest`, `walks.test.mjs`, `browser-persistence.test.mjs`; `browser-xss-sweep.test.mjs` (editor, list, export, admin, reports) | Both engines | PASS | none |

## Summary export and email draft

| ID | Method | Evidence | Environment | Result | Gap |
| --- | --- | --- | --- | --- | --- |
| SUM-01 to SUM-06 | A | `WalkSummaryFormatterTest` and `summary.test.mjs` (shared vectors, byte for byte), `walks.test.mjs`, `browser-email.test.mjs` | Both engines | PASS | none |
| SUM-07, SUM-09 | A | `browser-email.test.mjs`, `WalkServiceTest`, `walks.test.mjs` | Both engines | PASS | none |
| SUM-08 | A | `browser-email.test.mjs`, `no-mail.test.mjs` | Both engines | PASS | Opening the draft in a real mail client: not automated (the `mailto:` URL is asserted) |

## Instrument administration

| ID | Method | Evidence | Environment | Result | Gap |
| --- | --- | --- | --- | --- | --- |
| ADM-01 | A | `admin-instrument.test.mjs`, `browser-admin.test.mjs`; the Excel round trip through the workbook reader and writer | Both engines | PASS | The round trip in Microsoft Excel itself: NOT TESTABLE HERE (checklist 4) |
| ADM-02 | A | `admin-instrument.test.mjs`, `browser-admin.test.mjs` | Both engines | PASS | none |
| ADM-03 | A | `InstrumentPublishServiceTest` (26 semantic cases), `ValidatorRendererContractTest`, `ImportPublishEquivalenceTest`, `admin-publish.test.mjs` | Both engines | PASS | none |
| ADM-04 | A | `InstrumentPublishServiceTest`, `admin-publish.test.mjs`, the barrier specs; `browser-admin.test.mjs` | Both engines | PASS | none |
| ADM-05 | A | `InstrumentImmutabilityTest`, `GlobalIdentityBoundaryTest`, `SharedInstrumentBoundaryTest`, `InstrumentMetadataServiceTest` | Both engines | PASS | none |
| ADM-06 | A | `InstrumentAdministrationTest`, `admin-instrument.test.mjs`, `browser-admin.test.mjs`; "P8-13" | Both engines | PASS | none |
| ADM-07 | A | `InstrumentAdministrationTest`, `browser-admin.test.mjs` | Both engines | PASS | none |
| ADM-08 | A | `InstrumentAdministrationTest`, `browser-admin.test.mjs`; "P8-13" | Both engines | PASS | none |

## Aggregate reporting

| ID | Method | Evidence | Environment | Result | Gap |
| --- | --- | --- | --- | --- | --- |
| RPT-01, RPT-02 | A | `ReportServiceTest`, `reports.test.mjs` | Both engines | PASS | none |
| RPT-03 | A | `ReportServiceTest`, `ReportReleaseTest`, `ReportReleaseMembershipTest`, `ReportIsolationTest`, `reports.test.mjs`, `browser-reports.test.mjs` | Both engines | PASS | none |
| RPT-04 to RPT-07 | A | `ReportServiceTest.testRpt04...` to `testRpt07...`, `reports.test.mjs` | Both engines | PASS | Under sustained edits to completed walks a live district report can answer 409 "run the report again" (by design); now rare (D14) |

## Security, privacy and operations

| ID | Method | Evidence | Environment | Result | Gap |
| --- | --- | --- | --- | --- | --- |
| SEC-01 | A, S | `security-surface.test.mjs` (SQL, markup, traversal, NUL and oversized values in every path and free query parameter), earlier SEC-01 suites, `schema-contract.test.mjs` | Both engines | PASS | none |
| SEC-02 | A | `browser-xss-sweep.test.mjs` (stored and reflected payloads in every view, with a control proving the observers see markup), `LinkUrlSchemeTest` (P8-06), CSV formula neutralization (`ReportServiceTest`) | Both engines | PASS | none |
| SEC-03 | A, O | `security-surface.test.mjs` (every state-changing route refuses a missing, malformed, foreign or ended session's token, and nothing is written); `production-profile.test.mjs` | Both engines | PASS | none |
| SEC-04 | A, O | `security-surface.test.mjs` (rotation at sign-in, no Expires/Max-Age, HttpOnly, SameSite=Lax; P8-05); `production-profile.test.mjs` (Secure, gateway-only identity, trusted addresses, shared secret, refused unsafe starts) | Both engines; production profile on both | PASS in the production profile on both engines | TLS and the real gateway: NOT TESTABLE HERE (D1, D2; checklist 6) |
| SEC-05 | A, O | Earlier SEC-05 suites; `production-profile.test.mjs` (the log and the audit hold no secret, token, password, note, name or email, and do record refused identity assertions and failures) | Both engines | PASS | Log retention and the monitoring tool: owner decision D12 |
| SEC-06 | O | `restart-during-autosave.test.mjs`: the server killed mid-transaction and after commit, Retry after the restart | Lucee (JVM SIGKILL) and ColdFusion (container kill) | PASS | none |
| SEC-07 | O | The final gate itself (a brand-new SQL Server, schema, seed, application, full suite, twice); `production-profile.test.mjs` runs the documented bootstrap order in production (P8-12 corrected it); `upgrade-and-rollback.test.mjs`; `database-operations.test.mjs` | Lucee and ColdFusion's built-in web server | PASS here | IIS or Apache with the ColdFusion connector, the DataDirect driver: NOT TESTABLE HERE (D2, D3; checklist 1) |

## Accessibility and responsive behavior

| ID | Method | Evidence | Environment | Result | Gap |
| --- | --- | --- | --- | --- | --- |
| A11Y-01 | A | `browser-a11y-sweep.test.mjs` (keyboard traversal of My Walks, the expanded editor, reports and administration: every control reached, a visible focus indicator on each, no trap), earlier A11Y-01 suites | Both engines (Chromium) | PASS | A real screen reader: NOT TESTABLE HERE (checklist 5) |
| A11Y-02 | A | Earlier A11Y-02 suites (names, groups, live regions, `aria-invalid`/`aria-describedby`); the sweep's ARIA snapshots and live-region checks | Both engines | PASS (automated) | Announcements heard through a screen reader: NOT TESTABLE HERE (checklist 5) |
| A11Y-03 | A | `browser-a11y-sweep.test.mjs`: axe-core 4.13 (WCAG 2.0/2.1 A and AA) on 17 views in their real states -- My Walks, the chooser, every editor state, completion errors, a failed save, the conflict panel, the composer, live and released reports, every administration panel and its dialog -- at four layouts: no serious or critical violation | Both engines | PASS | Manual checks beyond axe: checklist 5 |
| A11Y-04 | A | axe color contrast in every state above; a selected answer is marked by more than color (`aria-pressed` and a check mark) | Both engines | PASS | Disabled controls are exempt from WCAG 1.4.3 contrast; their state is programmatic (`disabled`) |
| A11Y-05 | A | The sweep at 375 px, 768 px, 1280 px and 1280 px at 200 % zoom (a 640 CSS px layout): no horizontal page scroll, no control outside the viewport or without size | Both engines | PASS | Smallest measured target 13 px (a WCAG 2.2 readiness observation, not a 2.1 AA requirement) |
