# Phase 8 correction A8: acceptance status

What the correction changes in the Phase 8 acceptance status, and what it does not. The Phase 8
ledger (`../phase8/ACCEPTANCE_LEDGER.md`) is unchanged; this record adds to it. **Phase 8 is submitted
for independent re-audit. It is not accepted, frozen, production-ready or production-certified.**

## Every acceptance ID, re-run on the correction code commit

The exact-commit gate ran the full suite on `b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d` from a clean
tree, on brand-new SQL Server 2022 databases, once per engine
(`gate-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/`):

| Engine | Node, HTTP and Playwright | CFML | Failed, skipped, todo, cancelled |
| --- | --- | --- | --- |
| Lucee 6.2.8.20 | 299/299 | 542/542 | 0, 0, 0, 0 |
| Adobe ColdFusion 2023 Update 25 | 299/299 | 542/542 | 0, 0, 0, 0 |

**GATE PASSED**, with `npm ci`, `validate:handoff` (51 checks), `test:package` (20/20), every script
parsed, and migrations 001 to 007 on brand-new databases with 002 to 007 re-applied and 001 refused.

Nothing was removed: every one of the 299 Node, HTTP and Playwright test names the Phase 8 gate passed
on both engines passed on both here, and every one of the 534 CFML test functions of the tested Phase 8
code exists and passed, by name, on each engine (`cfml-names-check.txt`). The CFML total rose by the 8
test functions this correction adds, counted from the tree and listed by name in the gate transcript
(step 6): `HealthReadinessTest` (6) and `ReportDeadlockVictimTest` (2). The Node total is unchanged: the
new live operation is an operations test (`tests/ops/`), run separately, as the other operations are.

The operations ran on the same commit after the gate
(`operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/`):

| Scenario | Adobe ColdFusion 2023 Update 25 | Lucee 6.2.8.20 |
| --- | --- | --- |
| Restart during autosave (SEC-06) | 3/3 | 3/3 |
| Production profile (SEC-03, SEC-04, SEC-05, SEC-07) | 1/1 | 1/1 |
| Readiness on a brand-new database without the schema (A8-01) | 1/1 | 1/1 |
| Its live red on the audited tip's code | fails as required | fails as required |
| Upgrade from the Phase 6 release and rollback (SEC-07) | | 1/1 |
| Backup and restore, killed and refused migrations (DB-03, SEC-07) | | 3/3 |

**OPERATIONS PASSED** (attempt 2). The first run, right after the gate, is kept: it ended OPERATIONS
FAILED because the ColdFusion live red was not observed, a fault of the harness (the audited tip's tree
was extracted into a directory ColdFusion could not read), diagnosed, fixed in the harness only, and
followed by the complete operations again (`operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/attempt-1-coldfusion-live-red-not-observed/`).

Every acceptance ID of `../phase8/ACCEPTANCE_LEDGER.md` whose evidence is the gate or these operations
therefore holds on the correction code commit, with the same method, environment and gaps, except
where the table below says otherwise.

## Rows whose evidence or status changes

| ID | What changes | Evidence added | Result | Gap |
| --- | --- | --- | --- | --- |
| SEC-07 | The health endpoint that the runbook makes the load balancer's readiness probe now fails closed: 200 only when the database answers, the schema is present and long text is whole, 503 otherwise (A8-01). A node started against a database the migrations were not applied to is kept out of service instead of put in it. | `HealthReadinessTest` (6 cases, the four states of the audit's table and one more); `tests/ops/readiness-schema-missing.test.mjs` on both engines in the production profile, against a brand-new database: 503 `schema: missing` before the migrations, 200 after them and after a restart, and its live red on the audited tip's code; `docs/OPERATIONS.md` 4.3, 8.1 and the go-live checklist | PASS here, both engines | As in Phase 8: IIS or Apache with the connector, the DataDirect driver and a real load balancer are NOT TESTABLE HERE (checklist 1); the probe's thresholds are the operator's |
| SEC-05 | The one new log event, `report.deadlock.victim`, carries the version id and the attempt number only. The workload's new failure capture keeps no cookie, CSRF token, secret, note text, name or email address. The readiness operation checks that the production health body carries no configuration value (and that its correlation id is the header's), and that the application's log holds no `request.failed`. | `ReportDeadlockVictimTest` (the logged fields); `readiness-schema-missing-*.json`; `a8-03/FINDINGS.md` section 1 | PASS | As in Phase 8 (D12) |
| RPT-01 to RPT-07 | A live report or CSV that SQL Server ends as a deadlock victim is computed again within its three attempts instead of failing with 500 (A8-03). What a report returns is unchanged: every existing report spec passes unchanged, on both engines. | `ReportDeadlockVictimTest` (red before on Lucee, green after on both engines); the workload on the correction commit: 0 unexpected answers in 8 runs, 12 deadlocks absorbed | PASS | A report that is the victim on all three attempts still answers 500 (not observed); release creation is not retried. The Phase 8 gap "409 ... now rare (D14)" does not hold over the full population: while completed walks were edited, 26 of the 36 live and CSV district reports of the 10- and 25-user levels on Lucee and 40 of 44 on ColdFusion answered the expected 409 (`DEFECTS.md`). D14 stays open |

## Unchanged

* **Performance acceptance remains open until the owner decides D8.** The A8-03 runs measured and
  explained; no figure is a target, a pass or a fail.
* **Owner decisions D1 to D12 and D14 remain open**; none was decided by assumption. D13 (k = 3, frozen
  releases) is decided and unchanged.
* **Not testable here, as in Phase 8** (`docs/VERIFICATION_CHECKLISTS.md`): ColdFusion 2023 with its
  own SQL Server driver behind IIS or Apache with the connector (1), SQL Server 2016 (2), connector
  request limits (3), Microsoft Excel (4), a real screen reader (5), the district SSO gateway and TLS
  (6), performance acceptance (7).
* **Production certification is outside this correction.** Nothing here certifies the application
  for production.
* No migration, dependency, lock file, configuration, instrument JSON or workbook, authentication,
  authorization, report privacy, autosave or instrument behavior, or the k = 3 policy changed, and no
  existing test was weakened, removed, renamed, skipped or filtered.

## Status

Phase 8, with this correction, is **submitted for independent re-audit**. It is not accepted, frozen,
production-ready or production-certified, and no later phase has begun.
