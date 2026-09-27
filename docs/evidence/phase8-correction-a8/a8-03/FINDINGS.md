# A8-03: the Lucee 500 responses under the drafts-only workload

**Finding (independent audit, LOW).** The post-P8-14 Lucee drafts-only run recorded one 500
`INTERNAL_ERROR` from the live district report and four from its CSV at 25 users, and an earlier
drafts-only run one CSV 500. The evidence kept no correlation id and no log event, so the cause could
not be reconstructed.

**Disposition.** Reproduced, traced, root-caused and corrected in the correction code commit
`b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d`, with a red-before-green regression. Every reproduced 500
was a SQL Server deadlock victim (error 1205). A limitation remains, stated in section 8.

## 1. The capture added (tests/perf/workload.mjs, in the correction code commit)

Every answer that is not a success is kept with its operation, HTTP status, application error code,
correlation id, elapsed time and the time it was sent. The harness sends its own `X-Correlation-Id`
(`perf-<uuid>`) with every request; the application adopts it, echoes it and writes it on every log
line of the request, so even a request that never answers can be traced. `409
REPORT_POPULATION_CHANGED` is kept as the one expected refusal; everything else is unexpected. For each
unexpected answer the run reads the application's log (`PERF_LOG_FILE`, or the ColdFusion container's
through `PERF_ENGINE_CONTAINER`) and keeps the events written under its correlation id, reduced to
named fields (`type`, `code`, `status`, `path`, `at`, and the exception message with any quoted data
value removed). No cookie, CSRF token, secret, note text, name or email address is recorded.

## 2. Attempts and totals

Same workload as the submitted evidence: the synthetic seed of 30,000 walks (`seed/seed.json`:
24,000 completed, 4,500 drafts, 1,500 voided, 2,190,000 responses), levels 10 and 25 users, 60 seconds
each, drafts only edited, five solo district reports and CSVs first. Every run is listed; none was
left out. Built from each run's own JSON by `tools/runs-table.mjs`.

| Run | Started (UTC) | Engine | Edits | Walks | Levels (60 s each) | Expected 409 | Unexpected | Deadlock graphs | report.deadlock.victim logged | request.failed logged |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Before, 1 | 2026-09-27T01:08:02Z | Lucee 6.2.8.20 | drafts | 30000 | 10 users: 2570 requests; live 14 (p50 3726 ms), CSV 14 (p50 4446 ms)<br>25 users: 2874 requests; live 16 (p50 9600 ms), CSV 16 (p50 8799 ms) | 0 | 0 | 0 | - | - |
| Before, 2 | 2026-09-27T01:13:53Z | Lucee 6.2.8.20 | drafts | 30096 | 10 users: 2948 requests; live 14 (p50 3912 ms), CSV 14 (p50 3922 ms)<br>25 users: 3345 requests; live 16 (p50 12150 ms), CSV 16 (p50 8221 ms) | 0 | 7 (7 500 INTERNAL_ERROR) | 7 | - | - |
| Before, 3 | 2026-09-27T01:16:16Z | Lucee 6.2.8.20 | drafts | 30215 | 10 users: 2832 requests; live 14 (p50 3851 ms), CSV 14 (p50 4102 ms)<br>25 users: 2856 requests; live 15 (p50 10922 ms), CSV 15 (p50 11360 ms) | 0 | 0 | 0 | - | - |
| Pre-commit check | 2026-09-27T01:36:23Z | Lucee 6.2.8.20 | drafts | 30322 | 10 users: 2061 requests; live 14 (p50 3836 ms), CSV 14 (p50 4063 ms)<br>25 users: 2747 requests; live 15 (p50 10765 ms), CSV 15 (p50 9780 ms) | 0 | 0 | 0 | - | - |
| Commit, drafts 1 | 2026-09-27T01:40:46Z | Lucee 6.2.8.20 | drafts | 30409 | 10 users: 2132 requests; live 14 (p50 4243 ms), CSV 14 (p50 4039 ms)<br>25 users: 2807 requests; live 15 (p50 9005 ms), CSV 15 (p50 9240 ms) | 0 | 0 | 1 | 1 | 0 |
| Commit, drafts 2 | 2026-09-27T01:43:13Z | Lucee 6.2.8.20 | drafts | 30536 | 10 users: 2626 requests; live 14 (p50 4439 ms), CSV 14 (p50 4211 ms)<br>25 users: 2878 requests; live 16 (p50 10399 ms), CSV 16 (p50 6775 ms) | 0 | 0 | 0 | 0 | 0 |
| Commit, drafts 3 | 2026-09-27T01:45:37Z | Lucee 6.2.8.20 | drafts | 30664 | 10 users: 2759 requests; live 18 (p50 3349 ms), CSV 18 (p50 2749 ms)<br>25 users: 2759 requests; live 19 (p50 7776 ms), CSV 19 (p50 7210 ms) | 0 | 0 | 0 | 0 | 0 |
| Commit, drafts 4 | 2026-09-27T01:47:57Z | Lucee 6.2.8.20 | drafts | 30776 | 10 users: 2788 requests; live 16 (p50 3584 ms), CSV 16 (p50 3031 ms)<br>25 users: 2999 requests; live 15 (p50 10344 ms), CSV 15 (p50 8439 ms) | 0 | 0 | 3 | 3 | 0 |
| Commit, drafts 5 | 2026-09-27T01:50:17Z | Lucee 6.2.8.20 | drafts | 30916 | 10 users: 2474 requests; live 15 (p50 3811 ms), CSV 15 (p50 4392 ms)<br>25 users: 2817 requests; live 15 (p50 11359 ms), CSV 15 (p50 10125 ms) | 0 | 0 | 1 | 1 | 0 |
| Commit, any | 2026-09-27T10:30:45Z | Lucee 6.2.8.20 | any | 31023 | 1 users: 1314 requests; live 0 (p50 - ms), CSV 0 (p50 - ms)<br>10 users: 2443 requests; live 8 (p50 6177 ms), CSV 8 (p50 1564 ms)<br>25 users: 3079 requests; live 10 (p50 22587 ms), CSV 10 (p50 1088 ms) | 26 | 0 | 7 | 7 | 0 |
| Commit, ColdFusion drafts | 2026-09-27T10:35:54Z | ColdFusion Server 2023,0,25,330977 | drafts | 31142 | 10 users: 918 requests; live 20 (p50 2491 ms), CSV 20 (p50 2796 ms)<br>25 users: 925 requests; live 29 (p50 3948 ms), CSV 29 (p50 3859 ms) | 0 | 0 | 0 | 0 | 0 |
| Commit, ColdFusion any | 2026-09-27T10:38:23Z | ColdFusion Server 2023,0,25,330977 | any | 31185 | 1 users: 770 requests; live 0 (p50 - ms), CSV 0 (p50 - ms)<br>10 users: 868 requests; live 7 (p50 5866 ms), CSV 7 (p50 1146 ms)<br>25 users: 931 requests; live 15 (p50 - ms), CSV 15 (p50 2207 ms) | 40 | 0 | 0 | 0 | 0 |

* **Before, 1 to 3**: the report code of the audited tip. The working tree then held the A8-01
  changes and the new capture, not yet the report correction; the engine's copy of the code is hashed
  in `perf-environment.txt`, and each run's header prints the tree's status.
  `reproduction-before-the-correction/`. The log-event columns read "-": those runs predate the
  per-run log extract, and the retry event did not exist.
* **Pre-commit check**: the corrected tree before it was committed, byte-identical in `src/` and
  `app/` to the commit (its engine-start record compares the hashes). `pre-commit-check-on-the-corrected-tree/`.
* **Commit**: the correction code commit, from a clean tree, the engine restarted from it.
  `on-the-correction-commit/`. The host rebooted between the fifth drafts run and the "any" run; SQL
  Server's container was restarted with its data and the engine restarted from the same commit
  (`lucee-engine-restart-after-the-host-reboot.txt`).

**Totals.** Expected `409 REPORT_POPULATION_CHANGED`: 0 in every drafts-only run on either engine (a
draft is never in a live report's population), 26 in the Lucee run and 40 in the ColdFusion run that
edit completed walks. Unexpected: **7 `500 INTERNAL_ERROR` before the correction** (3 live district
reports, 4 CSVs, all at 25 users, all in attempt 2), **none after it** in 8 runs on both engines.

## 3. The seven 500s, traced three ways

Each 500 carries the correlation id the harness sent. Under that id the application logged
`request.failed` with SQL Server's message, which names the victim's process id. SQL Server's own
record (`system_health`) holds a deadlock graph whose victim is that process, seconds later. Built by
`tools/correlate.mjs`; the graphs are `reproduction-before-the-correction/attempt2/deadlocks/`.

| # | Operation | HTTP / code | Correlation id (sent by the harness) | Sent (UTC) | Elapsed | request.failed event | Deadlock graph (victim) |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | report live district | 500 INTERNAL_ERROR | `perf-b00c5fcf-0aea-4d18-9775-a91f64e88be8` | 2026-09-27T01:15:41.523Z | 8858 ms | 2026-09-27T01:15:50.378Z: database, INTERNAL_ERROR, 500, /api/reports/aggregate, at src/core/Db.cfc:19; "Transaction (Process ID 61) was deadlocked on lock resources with another process and has ..." | deadlock-01.xml: spid 61, S on PAGE: 7:1:158351 |
| 2 | report CSV district | 500 INTERNAL_ERROR | `perf-da50dd92-3198-44a0-b412-660f7ff701d2` | 2026-09-27T01:15:50.381Z | 4868 ms | 2026-09-27T01:15:55.248Z: database, INTERNAL_ERROR, 500, /api/reports/aggregate.csv, at src/core/Db.cfc:19; "Transaction (Process ID 63) was deadlocked on lock resources with another process and has ..." | deadlock-02.xml: spid 63, S on PAGE: 7:1:158348 |
| 3 | report CSV district | 500 INTERNAL_ERROR | `perf-c98d8561-7112-4e21-b56b-945a26d269ac` | 2026-09-27T01:15:51.451Z | 6460 ms | 2026-09-27T01:15:57.876Z: database, INTERNAL_ERROR, 500, /api/reports/aggregate.csv, at src/core/Db.cfc:19; "Transaction (Process ID 76) was deadlocked on lock resources with another process and has ..." | deadlock-03.xml: spid 76, S on PAGE: 7:1:158348 |
| 4 | report CSV district | 500 INTERNAL_ERROR | `perf-ebc76400-c923-4e0d-8074-669a81e37971` | 2026-09-27T01:15:55.749Z | 5171 ms | 2026-09-27T01:16:00.918Z: database, INTERNAL_ERROR, 500, /api/reports/aggregate.csv, at src/core/Db.cfc:19; "Transaction (Process ID 81) was deadlocked on lock resources with another process and has ..." | deadlock-04.xml: spid 81, S on PAGE: 7:1:158444 |
| 5 | report live district | 500 INTERNAL_ERROR | `perf-d0e6a4ce-893a-4965-8089-3bdb3c4680f0` | 2026-09-27T01:15:58.630Z | 6068 ms | 2026-09-27T01:16:04.697Z: database, INTERNAL_ERROR, 500, /api/reports/aggregate, at src/core/Db.cfc:19; "Transaction (Process ID 62) was deadlocked on lock resources with another process and has ..." | deadlock-06.xml: spid 62, S on PAGE: 7:1:158348 |
| 6 | report live district | 500 INTERNAL_ERROR | `perf-153006c7-0eb3-42ae-8ae0-5910220fe7ab` | 2026-09-27T01:15:59.230Z | 4240 ms | 2026-09-27T01:16:03.464Z: database, INTERNAL_ERROR, 500, /api/reports/aggregate, at src/core/Db.cfc:19; "Transaction (Process ID 74) was deadlocked on lock resources with another process and has ..." | deadlock-05.xml: spid 74, S on PAGE: 7:1:158348 |
| 7 | report CSV district | 500 INTERNAL_ERROR | `perf-04b915d8-ca9e-4f60-942b-38758cef66ff` | 2026-09-27T01:16:03.470Z | 4112 ms | 2026-09-27T01:16:07.580Z: database, INTERNAL_ERROR, 500, /api/reports/aggregate.csv, at src/core/Db.cfc:19; "Transaction (Process ID 65) was deadlocked on lock resources with another process and has ..." | deadlock-07.xml: spid 65, S on PAGE: 7:1:158569 |

7 unexpected answers; 7 with their request.failed event; 7 matched to a deadlock graph (of 7 graphs in the window).

## 4. Root cause

The seven graphs, their statements resolved from SQL Server's plan cache
(`attempt2/deadlocks/statements.json`, `summary.json`):

* **Victim, every time: the report's item aggregate.** `SELECT r.item_id, r.response_state,
  r.selected_option_id, COUNT(*) AS n FROM #icf_rp_<population> p JOIN [icf].[walk_response] r ON
  r.walk_id = p.walk_id WHERE ...`, under READ COMMITTED, as a parallel scan of `icf.walk_response`
  over the 24,000-walk district population. It holds a shared (S) lock on one page and asks for S on
  the next.
* **Survivor, every time: an autosave writing responses.** `INSERT INTO [icf].[walk_response] ...`
  (five graphs) or `UPDATE [icf].[walk_response] SET response_state = ...` (two) inside a save's
  transaction, holding an intent-exclusive (IX) lock on the page the report wants next and asking for
  IX on the page the report holds. One graph (03) is a four-way cycle of two parallel report threads
  and two updates.
* SQL Server ends the cheaper transaction, the report's (no log used), with error 1205, and rolls it
  back. `ReportService.compute` handled an attempt that saw a walk move (discard, compute again, at
  most three times, then 409) but not a deadlock, so the victim's error reached the client as 500.
* The design notes said the report "takes no lock a writer waits on". Under locking READ COMMITTED that
  holds between statements, not during one: a scan's shared locks are what the autosave waited on (a
  survivor's `waittime` of up to 2.4 s) and what formed the cycle.

## 5. The correction (commit `b73f519`)

`ReportService.compute` discards an attempt that SQL Server ended as a deadlock victim (native error
1205, SQLSTATE 40001) and computes again, within the same `MAX_ATTEMPTS` (3) a moved walk already had,
logging `report.deadlock.victim` with the attempt number. A last attempt that is a victim too still
fails with the database's error, never as `REPORT_POPULATION_CHANGED`, which would say something about
the walks that is not true. The transaction was rolled back whole, temporary tables included, so
nothing from the discarded attempt is returned. The 409 design is unchanged.

**Regression, red before green** (`regression/`): `ReportDeadlockVictimTest` makes a real deadlock
inside the report's transaction, at the item-aggregate seam: the report holds sentinel row A, a second
session at `DEADLOCK_PRIORITY HIGH` holds row B and asks for A, the report asks for B, and SQL Server's
lock monitor ends the report with 1205 (the spec records the number it received). Red on the report
code of the audited tip: "a report chosen as a deadlock victim is computed again, not answered with an
error Expected exactly [] ... but got [database: An error occurred during the current command (Done
status 0). Transaction (Process ID 53) was deadlocked ...]", and the second case "Expected [3] but got
[1]". Green on Lucee and on ColdFusion 2023 (`../targeted-green-coldfusion.txt`), with every existing
report spec. Three earlier runs of the spec were not red evidence and are kept as such: twice Lucee's
compiler refused the spec itself (`not-red-1`, `not-red-2`), once the second session's function
returned nothing and `Db.transact` then failed (`not-red-3`); each was fixed in the spec, never in the
application. SQL Server recorded every deadlock the spec forced: 12 graphs on `icf.app_user`, in
`sql-server-deadlock-record/`.

## 6. On the correction commit

Deadlocks still happen under this load, and are now absorbed. All 12 that SQL Server recorded during
the Lucee runs are paired with the application's `report.deadlock.victim` event, 18 to 317 ms after
SQL Server resolved them, and with what the request finally answered (`tools/absorbed.mjs`,
`on-the-correction-commit/absorbed-deadlocks.md`):

| Run | Deadlock graph (victim spid, detected by SQL Server) | report.deadlock.victim event (UTC) | Attempt | Correlation id | The request's answer |
| --- | --- | --- | --- | --- | --- |
| Lucee drafts 1 | deadlock-01.xml: spid 77, detected 2026-09-27T01:43:02.5410000Z | 2026-09-27T01:43:02.761Z | 1 | `perf-d91123b9-5535-40fe-870a-eeaf665d051b` | success: no failure recorded for it |
| Lucee drafts 4 | deadlock-01.xml: spid 70, detected 2026-09-27T01:48:41.8310000Z | 2026-09-27T01:48:41.862Z | 1 | `perf-63a3c986-2127-4a93-87b0-5f0536bbca64` | success: no failure recorded for it |
| Lucee drafts 4 | deadlock-02.xml: spid 53, detected 2026-09-27T01:49:19.4620000Z | 2026-09-27T01:49:19.612Z | 1 | `perf-426005e0-1101-48a1-bf27-de8384d35e71` | success: no failure recorded for it |
| Lucee drafts 4 | deadlock-03.xml: spid 65, detected 2026-09-27T01:50:02.2110000Z | 2026-09-27T01:50:02.244Z | 1 | `perf-a965412c-3f96-4ca8-b72a-c6d633b244e9` | success: no failure recorded for it |
| Lucee drafts 5 | deadlock-01.xml: spid 54, detected 2026-09-27T01:52:05.4530000Z | 2026-09-27T01:52:05.502Z | 1 | `perf-d4a855de-2a5d-4217-ab2e-028d065dba97` | success: no failure recorded for it |
| Lucee any | deadlock-01.xml: spid 74, detected 2026-09-27T10:33:57.3580000Z | 2026-09-27T10:33:57.675Z | 1 | `perf-15b88d40-7ed4-4d10-90ec-f9a6129aa803` | 409 REPORT_POPULATION_CHANGED (expected refusal) |
| Lucee any | deadlock-02.xml: spid 87, detected 2026-09-27T10:34:02.4160000Z | 2026-09-27T10:34:02.471Z | 1 | `perf-8c145719-f9ed-4b31-b677-7fe01a26a02d` | 409 REPORT_POPULATION_CHANGED (expected refusal) |
| Lucee any | deadlock-03.xml: spid 86, detected 2026-09-27T10:34:04.9570000Z | 2026-09-27T10:34:05.009Z | 2 | `perf-f142e085-8baa-4f90-9fee-228f57dcf1e4` | 409 REPORT_POPULATION_CHANGED (expected refusal) |
| Lucee any | deadlock-04.xml: spid 87, detected 2026-09-27T10:34:06.2620000Z | 2026-09-27T10:34:06.306Z | 2 | `perf-8c145719-f9ed-4b31-b677-7fe01a26a02d` | 409 REPORT_POPULATION_CHANGED (expected refusal) |
| Lucee any | deadlock-05.xml: spid 84, detected 2026-09-27T10:34:06.9200000Z | 2026-09-27T10:34:06.968Z | 2 | `perf-15b88d40-7ed4-4d10-90ec-f9a6129aa803` | 409 REPORT_POPULATION_CHANGED (expected refusal) |
| Lucee any | deadlock-06.xml: spid 69, detected 2026-09-27T10:34:09.6190000Z | 2026-09-27T10:34:09.637Z | 2 | `perf-78f4ef51-14be-4a90-ad34-1a8a1f93839e` | success: no failure recorded for it |
| Lucee any | deadlock-07.xml: spid 85, detected 2026-09-27T10:34:12.1400000Z | 2026-09-27T10:34:12.162Z | 2 | `perf-16f213d5-a507-4f73-b7bb-cd32956a0828` | success: no failure recorded for it |

12 deadlock graphs; 12 matched to a report.deadlock.victim event, in 10 distinct requests: 7 answered with success, 3 with the expected 409 REPORT_POPULATION_CHANGED, 0 with an error.

No request failed. The ColdFusion runs met no deadlock; they ran at about a third of Lucee's request
rate.

## 7. The submitted run's conditions

The submitted evidence's after-P8-14 runs, the one with the five 500s among them, did not report over
the same population as the runs before P8-14. Their own records show it:

* Before P8-14 (`docs/evidence/phase8/performance/lucee-run3-drafts/`, 19:46): the candidate insert
  selected 24,200 walks, and the item aggregate read about 28,200 pages per run with 82 result groups.
* After P8-14 (`.../lucee-after-p814-drafts/`, 20:35): the item aggregate read 1,068 pages with 53
  result groups, with 46 ms of CPU (the one execution among the fifteen slowest statements, there
  because it waited 5.7 s). In the two after-P8-14 runs that kept their plans (`lucee-after-p814-any`,
  `acf-after-p814-any`) no report statement was among the fifteen at all. This correction's
  full-population runs read about 27,100 pages per item aggregate (plan cardinality 24,074 walks in
  attempt 1's plans).
* In between, the P8-14 verification ran CFML specs against the performance database on both engines
  (`docs/evidence/phase8/defects/P8-14-green.txt`); `InstrumentImportServiceTest`, whose case DB-06
  publishes a fixture version of the ICFWALK instrument (`effective_start` now), ran on ColdFusion and
  its cleanup hit the 600 s request limit. A published fixture newer than the seed's version becomes
  the current version, and a live district report counts only the current version's walks: then only
  the few hundred walks the workload itself created.

The last point is the likely cause, not a proven one: that database no longer exists. The effect is
proven by the numbers above. It does not change A8-03's cause (the earlier drafts run, before P8-14 and
over the full population, had its CSV 500 too), but it means the after-P8-14 report timings and refusal
rates describe a population of a few hundred walks. `docs/OPERATIONS.md` section 12 no longer states a
refusal rate from them. The original records are preserved unchanged.

The original six 500s left no correlation id or log event, so they cannot be proven to be deadlocks,
and their elapsed times were not kept (the workload timed successes only). What was recorded matches
the reproduced ones: drafts-only editing, 25 users, district report operations only (live and CSV), and
in the same level a blocking episode of about five seconds (5,209 ms; 4,700 ms in the earlier run),
the interval at which SQL Server's deadlock monitor runs. The reproduced 500s took 4.1 to 8.9 s.

## 8. What remains, and what is not claimed

* **Deadlocks still occur.** The report's aggregate scans take shared page locks under locking READ
  COMMITTED, and so meet autosave. Each deadlock costs the report and the autosave it meets up to SQL
  Server's detection interval (about five seconds), and costs the report one of its three attempts. A
  report that is the victim on all three still fails with `INTERNAL_ERROR` (pinned by
  `testAReportChosenAsTheVictimOnEveryAttemptStillFails`); none did in these runs.
* **Removing the conflict** needs row-versioned reads for the report (the database option
  `READ_COMMITTED_SNAPSHOT`, or `ALLOW_SNAPSHOT_ISOLATION` with SNAPSHOT for the report's transaction):
  a database configuration change, so a migration, and a decision for the owner. Not made here.
* **Releases** (`createRelease`) read the population the same way inside one transaction that also
  writes the release. A deadlock there fails the request (500) and nothing is retried; it was not
  observed (a release is created rarely, by a person) and is left as it is.
* **Performance acceptance remains open (D8).** No figure here is a target or a pass.
* Plans record the parameter values they were compiled with. This correction keeps plans for two runs
  only (attempts 1 and 2), with every compiled value replaced by "(removed)": one had compiled a
  synthetic note's text. The original Phase 8 plans also hold compiled values (synthetic identifiers
  and codes; no note text); they are preserved unchanged.

## Files

| Path | What |
| --- | --- |
| `regression/` | Red, green and the three not-red runs of `ReportDeadlockVictimTest` |
| `reproduction-before-the-correction/` | The seed, the three attempts (JSON, transcripts, attempt 2's graphs, statements, correlation) |
| `pre-commit-check-on-the-corrected-tree/` | One run on the corrected tree before the commit |
| `on-the-correction-commit/` | Five Lucee drafts runs, one Lucee and two ColdFusion runs, each with its graphs and log events; `absorbed-deadlocks.md` |
| `sql-server-deadlock-record/` | Every deadlock SQL Server recorded in the session before the gate replaced its container (31: 19 workload, 12 forced by the spec) |
| `../tools/` | Every script used, including the table builders named above |
