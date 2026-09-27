# Phase 8 correction A8: findings and dispositions

The independent audit of Phase 8 answered **NOT READY TO FREEZE PHASE 8**. It verified P8-01 to P8-14
within their stated scope and found no new HIGH-severity security, authorization, migration,
concurrency or data-integrity defect. Two MEDIUM findings block acceptance (A8-01, A8-02) and one LOW
finding required evidence follow-up (A8-03). This record adds to `../phase8/DEFECTS.md`, which is
unchanged.

| ID | Severity | What was wrong | Correction or disposition | Regression (red, then green) | Engines |
| --- | --- | --- | --- | --- | --- |
| A8-01 | MEDIUM | `/api/health` answered HTTP 200 and `status: ok` when the database answered but the ICFWalk schema was missing, although the runbook made it the load balancer's readiness probe: a node pointed at an unmigrated database was put in service. The runbook itself said so (`checks.schema = missing` with 200). | `HealthController` answers 200 `ok` only when `database == "ok"`, `schema == "present"` and `longText == "ok"`, and 503 `degraded` otherwise (one condition, `b73f519`). The response shape, the correlation id, production information-hiding and the long-text probe are unchanged. `docs/OPERATIONS.md` 4.3, 8.1 and the go-live checklist, `docs/ENDPOINTS.md` and `docs/LOCAL_SETUP.md` state the contract; the "missing with 200" sentence is gone. `tools/runtime/acf-up.sh` can wait for 503 (`ICFWALK_ACF_EXPECT_HEALTH`) so the live operation can start ColdFusion on an unmigrated database. | `HealthReadinessTest` with `SchemaAbsentDb` (red: `a8-01/red-HealthReadinessTest-lucee.txt`, "Expected [503] but got [200]"; green: `a8-01/green-*`, `targeted-green-coldfusion.txt`); the four states of the audit's table and a fifth (no schema and truncated long text). Live: `tests/ops/readiness-schema-missing.test.mjs`, red on the audited tip's code and green on `b73f519` on both engines (`operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/readiness-*`) | both |
| A8-02 | MEDIUM | The delivered archive's ZIP comment named a later commit than the gated code commit, but the archive did not name the gated commit internally or prove that the difference after the gate was records only. | No product change. The code commit is gated, the evidence goes in a later records-only commit, and the archive is built from that commit by `tools/package.sh` with a generated `DELIVERY-IDENTITY.md` (both commits and trees, the anchors, the empty restricted diff, the full stat and name-status, both evidence directories' checksum verification, the clean status, the archive command, name and comment) and `PAYLOAD-SHA256SUMS`, and verified offline by `tools/verify-delivery.sh`, which also rebuilds the source tree from the extracted files. Its SHA-256 is in a sidecar. | Not a code defect: the check is `verify-delivery.sh` on the delivered archive (`README.md` section 7), which `package.sh` runs before it reports success | n/a |
| A8-03 | LOW | The Lucee drafts-only workload recorded 500 `INTERNAL_ERROR` from live and CSV district reports and kept nothing to explain them. Cause, found here: SQL Server ended the report's item aggregate as a deadlock victim (error 1205) against autosave writes to `icf.walk_response`, and `ReportService.compute` retried a moved walk but not a deadlock, so the error reached the client. | `ReportService.compute` computes again an attempt SQL Server ended as a deadlock victim (1205 or SQLSTATE 40001), within the existing three attempts, and logs `report.deadlock.victim`; a last attempt that is a victim too still fails with the database error, never as `REPORT_POPULATION_CHANGED`. The 409 design is unchanged. The design notes that said a report takes no lock a writer waits on are corrected (`ReportRepository.cfc`, `docs/ARCHITECTURE.md`, `docs/DATA_CONTRACT.md`). `tests/perf/workload.mjs` now keeps, for every unexpected answer, the operation, status, code, correlation id, elapsed time and the matching redacted `request.failed` event. | `ReportDeadlockVictimTest` makes a real deadlock in the report's transaction (red: `a8-03/regression/red-*`; green: `a8-03/regression/green-*`, `targeted-green-coldfusion.txt`). Workload: 7 unexpected 500s in 3 attempts before the correction, each traced to its deadlock; none in 8 runs on the correction commit on both engines, where 12 deadlocks were absorbed (`a8-03/FINDINGS.md`) | both |

## A8-01

The one-line cause: `var healthy = database == "ok" && longText != "truncated";` never looked at
`schema`. The correction reads `database == "ok" && schema == "present" && longText == "ok"`, so any
state not positively known to be ready, an unknown or future value included, answers 503.

States covered by `HealthReadinessTest` (the HTTP status is asserted first, with the whole body in the
message, then `status`, the three checks and the correlation id):

| Database | Schema | Long text | Result | Test |
| --- | --- | --- | --- | --- |
| ok | present | ok | 200 `ok` | `testTheDatabaseWithItsSchemaAndWholeLongTextIsReady` |
| ok | missing | ok | 503 `degraded` | `testAReachableDatabaseWithoutTheSchemaIsNotReady`, and in production with no configuration value in the body: `testProductionAnswersTheSameWithoutTheSchemaAndNamesNothing` |
| ok | present | truncated | 503 `degraded` | `testTruncatedLongTextIsNotReadyEvenWithTheSchema` |
| unavailable | unknown | unknown | 503 `degraded` | `testAnUnreachableDatabaseIsNotReady` |
| ok | missing | truncated | 503 `degraded` | `testWithoutTheSchemaAndWithTruncatedLongTextItIsNotReady` |

`SchemaAbsentDb` is a decorator over the real `Db`, in the style of the existing `TruncatingDb`: it
points the schema probe at a table that does not exist and passes everything else through, so the
database really answers and the long-text probe really runs. The existing `LongTextRetrievalTest`
passes unchanged.

The live operation (`tests/ops/readiness-schema-missing.test.mjs`) runs each engine in the production
profile against a brand-new SQL Server database: it records the empty database's identity (name, id,
creation time, collation, compatibility level, server version and edition, and zero tables, zero `icf`
schema and no `icf.instrument`), proves a direct connection as the runtime login, requires 503
`degraded` with `database: ok`, `schema: missing`, `longText: ok` and checks the body carries no
configuration value and its correlation id is the header's, applies migrations 001 to 007, requires 200
on the running application and again after a restart, requires `application.started` in production and
no `request.failed`, then drops its database and login, proves both gone, and, when the development
application answered 200 before, checks that it still does. It fails if health answers 200 before the
schema exists, and did so on the audited tip's code on both engines. (On ColdFusion that live red first
went unobserved because of the harness, not the application:
`operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/attempt-1-coldfusion-live-red-not-observed/`.)

## A8-02

The delivered archive and what binds it are described in `README.md` sections 6 and 7. What the
auditor receives: `ICFWalk-phase8-correction-a8-<first 12 hex of the records commit>.zip`, its
`.sha256` sidecar, and a copy of the `DELIVERY-IDENTITY.md` the archive carries.

## A8-03

`a8-03/FINDINGS.md` is the full account; in short:

* **Reproduced**: 3 attempts of the submitted workload (seed of 30,000 walks, 10 and 25 users, 60 s
  each, drafts-only edits, 5 solo reports first) on the audited tip's report code: 0, 7 and 0
  unexpected answers, all `500 INTERNAL_ERROR` from district reports at 25 users (3 live, 4 CSV), 0
  expected 409 (a draft is never in a live report's population).
* **Traced**: each 500's correlation id to its `request.failed` event (`type: database`, at
  `src/core/Db.cfc:19`, SQL Server's "deadlocked ... chosen as the deadlock victim" naming a process
  id) and that process id to the victim of a deadlock graph in SQL Server's `system_health` record,
  seconds later: 7 of 7.
* **Root cause**: the report's item aggregate, a parallel scan of `icf.walk_response` under locking
  READ COMMITTED, holds a shared page lock and asks for the next; an autosave's INSERT or UPDATE holds
  intent-exclusive on that page and asks for the report's; SQL Server ends the report (1205), and
  nothing retried it.
* **Corrected** in `b73f519`, red before green. On the correction commit: 5 Lucee drafts-only runs,
  1 Lucee run editing any walk, 1 ColdFusion drafts-only run and 1 ColdFusion run editing any walk: 0
  unexpected answers; 26 and 40 expected 409s in the two runs that edit completed walks; 12 deadlocks
  on Lucee, each paired with its `report.deadlock.victim` event, in 10 requests that answered 7
  successes and 3 expected 409s.
* **Remains**: deadlocks still occur and cost up to about five seconds each; a report that is the
  victim on all three attempts still answers 500 (pinned by a test, not observed); release creation
  is not retried. Removing the conflict needs row-versioned reads (READ_COMMITTED_SNAPSHOT or
  SNAPSHOT isolation), a database change and so a migration: an owner decision, not taken here.
* **Not claimed**: the six original 500s left no correlation id or log event and cannot be proven to
  be deadlocks; what they recorded matches the reproduced ones.

## Found while correcting: the after-P8-14 performance runs

Not an audit finding; recorded because Phase 8 statements rest on it. The Phase 8 performance runs
after P8-14 (`../phase8/performance/*-after-p814-*`) counted only the few hundred walks the workload
itself created in their live district reports, not the synthetic year's 24,000: their own plans and
row counts show it (`a8-03/FINDINGS.md` section 7). The likely cause is a test fixture version left
published in that database during the P8-14 verification; the database no longer exists, so it is not
proven.

What rests on those runs, and what the correction's full-population runs show instead:

* **Report timings after P8-14.** Over the full population a live district report on Lucee took
  seconds at 10 and 25 users (`a8-03/FINDINGS.md` section 2). No figure is a target (D8).
* **"Refusals are now rare"** (`../phase8/OWNER_DECISIONS.md` D14, current behavior; `BUILD_STATUS.md`,
  Phase 8 risks; `docs/OPERATIONS.md` 12 before `b73f519`). Over the full population, while completed
  walks were edited, 26 of the 36 live and CSV district reports of the 10- and 25-user levels on
  Lucee and 40 of 44 on ColdFusion answered the expected `409 REPORT_POPULATION_CHANGED`
  (`a8-03/on-the-correction-commit/*-any/run1/`). That is the Phase 7 design working as
  designed, and D14 remains open: this is information for the owner's decision, not a decision.
  `docs/OPERATIONS.md` 12 no longer states a rate (`b73f519`); the Phase 8 records are unchanged.

## The starting state

Before any change the designated branch pointed at `2a3f2ecb4f070401cba00518c0db8a2de823a29d` (the tip
of `claude/icfwalk-phase-6-admin-publish`), an ancestor of the audited Phase 8 handoff tip `10f476ba`,
not at the tip itself, and none of the four anchors was its ancestor. That was a stop condition, and it
was reported. The owner chose the fast-forward to `10f476ba`, which loses nothing; after it every
pre-edit check passed (HEAD exactly `10f476ba`, the three anchors its ancestors, the restricted diff
from `282a4ec` empty, the tree clean). Recorded in
`00-starting-state/starting-state-and-fast-forward.txt`, which also corrects its own earlier line about
the push: the designated branch did not exist on the remote, so the first push creates it.

## Observations kept open (not corrected)

| Observation | Why it is left | Where |
| --- | --- | --- |
| A deadlock during release creation (`createRelease`) fails the request with 500; nothing retries it. | Not observed (releases are made rarely, by a person, and the workload does not make them under load); retrying the release path is a change to the frozen-release design that A8-03 did not need. | `a8-03/FINDINGS.md` section 8 |
| A live report that is a deadlock victim on all three attempts answers 500 `INTERNAL_ERROR`. | Answering 409 would say something false about the walks; removing deadlocks needs row-versioned reads, an owner decision. | `ReportDeadlockVictimTest.testAReportChosenAsTheVictimOnEveryAttemptStillFails` |
| The troubleshooting table in `docs/OPERATIONS.md` has rows for health 503 with `longText: truncated` and with `database: unavailable`, none for `schema: missing`. | Nothing in it contradicts the contract; 4.3 and 8.1 say what `schema: missing` means and what to do. | `docs/OPERATIONS.md` 11 |
| The original Phase 8 plans record the values their statements were compiled with (synthetic identifiers and codes, no note text). | Preserved byte for byte, as required; the correction keeps plans for two runs only, with every value removed. | `../phase8/performance/` |
