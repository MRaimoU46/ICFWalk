# Delivery identity: ICFWalk Phase 8 correction A8

Generated at packaging, 2026-09-29T13:35:15Z, from the already-final records-only commit, outside
the repository (a file inside a commit cannot name that commit), and added to the archive by
`git archive --add-file`. `docs/evidence/phase8-correction-a8/tools/verify-delivery.sh` checks everything
below offline.

## Commits

| What | Value |
| --- | --- |
| Archive source commit | `bbb4d1592d09d35d707741af462849622000091a` |
| Archive source commit parent(s) | `b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d` |
| Archive source tree | `4e0afcd710987847081594e4d42d8a15b604aa87` |
| Correction code commit (gated) | `b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d` |
| Correction code tree | `d6458eeb5ae98e705a57a0dd6062de2a91443640` |
| Correction code commit's parent: the audited Phase 8 handoff tip | `10f476ba9a69359f23a259be0e903afeed64b415` |
| Tested Phase 8 code commit | `282a4ec27cd5d200ed190b134c0145632a970cee` |
| Phase 0-7 records-only freeze tip | `133f02192a99970029847bc2da2d31b9d8da06e1` |
| Frozen Phase 0-7 code | `68f9026d39ba0ff44d12d6398c5e933971dad2f4` |
| Branch | `claude/icfwalk-phase-8-correction-cgsc7q` |

The archive source commit is the records-only commit. Its only parent is the correction code commit, the
commit the exact-commit gate and the operations ran on (`docs/evidence/phase8-correction-a8/gate-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/`,
`docs/evidence/phase8-correction-a8/operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/`).

## The records-only commit changes no code

```text
$ git diff --name-status b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d bbb4d1592d09d35d707741af462849622000091a -- src app tests scripts tools database config package.json package-lock.json manifest.json .env.example
<empty output>
```

Everything the records-only commit changes, relative to the correction code commit:

```text
$ git diff --stat=100 b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d bbb4d1592d09d35d707741af462849622000091a
 BUILD_STATUS.md                                                 |   75 +
 docs/ACCEPTANCE_TRACKING.md                                     |   32 +
 docs/evidence/phase8-correction-a8/00-starting-state/preedit.sh |   73 +
 .../00-starting-state/starting-state-and-fast-forward.txt       |  758 ++++
 docs/evidence/phase8-correction-a8/ACCEPTANCE.md                |   76 +
 docs/evidence/phase8-correction-a8/DEFECTS.md                   |  123 +
 docs/evidence/phase8-correction-a8/README.md                    |  196 +
 docs/evidence/phase8-correction-a8/SHA256SUMS                   |  252 ++
 .../green-HealthReadinessTest-LongTextRetrievalTest-lucee.txt   |   24 +
 .../a8-01/red-HealthReadinessTest-lucee.txt                     |   20 +
 docs/evidence/phase8-correction-a8/a8-03/FINDINGS.md            |  214 +
 .../a8-03/on-the-correction-commit/absorbed-deadlocks.md        |   16 +
 .../coldfusion-any/run1/deadlocks/deadlocks.txt                 |    1 +
 .../coldfusion-any/run1/log-events-during-run.txt               |  123 +
 .../run1/workload-ColdFusion-Server-2023-0-25-330977.json       | 1395 +++++++
 .../on-the-correction-commit/coldfusion-any/run1/workload.txt   |   15 +
 .../a8-03/on-the-correction-commit/coldfusion-any/series.txt    |    4 +
 .../coldfusion-drafts/run1/deadlocks/deadlocks.txt              |    1 +
 .../coldfusion-drafts/run1/log-events-during-run.txt            |    0
 .../run1/workload-ColdFusion-Server-2023-0-25-330977.json       |  769 ++++
 .../coldfusion-drafts/run1/workload.txt                         |   14 +
 .../a8-03/on-the-correction-commit/coldfusion-drafts/series.txt |    4 +
 .../a8-03/on-the-correction-commit/coldfusion-engine-start.txt  |    6 +
 .../lucee-any/run1/deadlocks/deadlock-01.xml                    |    7 +
 .../lucee-any/run1/deadlocks/deadlock-02.xml                    |    7 +
 .../lucee-any/run1/deadlocks/deadlock-03.xml                    |    7 +
 .../lucee-any/run1/deadlocks/deadlock-04.xml                    |    7 +
 .../lucee-any/run1/deadlocks/deadlock-05.xml                    |    7 +
 .../lucee-any/run1/deadlocks/deadlock-06.xml                    |    7 +
 .../lucee-any/run1/deadlocks/deadlock-07.xml                    |    7 +
 .../lucee-any/run1/deadlocks/deadlocks.txt                      |   36 +
 .../lucee-any/run1/deadlocks/summary.json                       |  418 ++
 .../lucee-any/run1/log-events-during-run.txt                    |   84 +
 .../lucee-any/run1/workload-Lucee-6.2.8.20.json                 | 1245 ++++++
 .../a8-03/on-the-correction-commit/lucee-any/run1/workload.txt  |   15 +
 .../a8-03/on-the-correction-commit/lucee-any/series.txt         |    4 +
 .../lucee-drafts/run1/deadlocks/deadlock-01.xml                 |    7 +
 .../lucee-drafts/run1/deadlocks/deadlocks.txt                   |    6 +
 .../lucee-drafts/run1/deadlocks/summary.json                    |   64 +
 .../lucee-drafts/run1/log-events-during-run.txt                 |    1 +
 .../lucee-drafts/run1/workload-Lucee-6.2.8.20.json              |  781 ++++
 .../on-the-correction-commit/lucee-drafts/run1/workload.txt     |   14 +
 .../lucee-drafts/run2/deadlocks/deadlocks.txt                   |    1 +
 .../lucee-drafts/run2/log-events-during-run.txt                 |    0
 .../lucee-drafts/run2/workload-Lucee-6.2.8.20.json              |  781 ++++
 .../on-the-correction-commit/lucee-drafts/run2/workload.txt     |   14 +
 .../lucee-drafts/run3/deadlocks/deadlocks.txt                   |    1 +
 .../lucee-drafts/run3/log-events-during-run.txt                 |    0
 .../lucee-drafts/run3/workload-Lucee-6.2.8.20.json              |  781 ++++
 .../on-the-correction-commit/lucee-drafts/run3/workload.txt     |   14 +
 .../lucee-drafts/run4/deadlocks/deadlock-01.xml                 |    7 +
 .../lucee-drafts/run4/deadlocks/deadlock-02.xml                 |   16 +
 .../lucee-drafts/run4/deadlocks/deadlock-03.xml                 |    7 +
 .../lucee-drafts/run4/deadlocks/deadlocks.txt                   |   22 +
 .../lucee-drafts/run4/deadlocks/summary.json                    |  263 ++
 .../lucee-drafts/run4/log-events-during-run.txt                 |    3 +
 .../lucee-drafts/run4/workload-Lucee-6.2.8.20.json              |  779 ++++
 .../on-the-correction-commit/lucee-drafts/run4/workload.txt     |   14 +
 .../lucee-drafts/run5/deadlocks/deadlock-01.xml                 |    7 +
 .../lucee-drafts/run5/deadlocks/deadlocks.txt                   |    6 +
 .../lucee-drafts/run5/deadlocks/summary.json                    |   64 +
 .../lucee-drafts/run5/log-events-during-run.txt                 |    1 +
 .../lucee-drafts/run5/workload-Lucee-6.2.8.20.json              |  781 ++++
 .../on-the-correction-commit/lucee-drafts/run5/workload.txt     |   14 +
 .../a8-03/on-the-correction-commit/lucee-drafts/series.txt      |    8 +
 .../lucee-engine-restart-after-the-host-reboot.txt              |    5 +
 .../a8-03/on-the-correction-commit/lucee-engine-start.txt       |    5 +
 .../deadlocks/deadlocks.txt                                     |    1 +
 .../workload-Lucee-6.2.8.20.json                                |  781 ++++
 .../a8-03/pre-commit-check-on-the-corrected-tree/workload.txt   |   28 +
 .../green-ReportDeadlockVictimTest-and-report-specs-lucee.txt   |   78 +
 .../regression/not-red-1-spec-did-not-compile-on-lucee.txt      |  427 ++
 .../regression/not-red-2-spec-did-not-compile-on-lucee.txt      |  402 ++
 .../regression/not-red-3-fixture-closure-returned-nothing.txt   |   18 +
 .../a8-03/regression/red-ReportDeadlockVictimTest-lucee.txt     |   18 +
 .../attempt1/deadlocks/deadlocks.txt                            |    1 +
 .../attempt1/plans/statement-01.sqlplan                         |    1 +
 .../attempt1/plans/statement-02.sqlplan                         |    1 +
 .../attempt1/plans/statement-03.sqlplan                         |    1 +
 .../attempt1/plans/statement-04.sqlplan                         |    1 +
 .../attempt1/plans/statement-05.sqlplan                         |    1 +
 .../attempt1/plans/statement-06.sqlplan                         |    1 +
 .../attempt1/plans/statement-07.sqlplan                         |    1 +
 .../attempt1/plans/statement-08.sqlplan                         |    1 +
 .../attempt1/plans/statement-09.sqlplan                         |    1 +
 .../attempt1/plans/statement-10.sqlplan                         |    1 +
 .../attempt1/plans/statement-11.sqlplan                         |    1 +
 .../attempt1/plans/statement-12.sqlplan                         |    1 +
 .../attempt1/plans/statement-13.sqlplan                         |    1 +
 .../attempt1/plans/statement-14.sqlplan                         |    1 +
 .../attempt1/plans/statement-15.sqlplan                         |    1 +
 .../attempt1/workload-Lucee-6.2.8.20.json                       |  783 ++++
 .../reproduction-before-the-correction/attempt1/workload.txt    |   19 +
 .../reproduction-before-the-correction/attempt2/correlation.md  |   11 +
 .../attempt2/deadlocks/deadlock-01.xml                          |    7 +
 .../attempt2/deadlocks/deadlock-02.xml                          |    7 +
 .../attempt2/deadlocks/deadlock-03.xml                          |   13 +
 .../attempt2/deadlocks/deadlock-04.xml                          |    7 +
 .../attempt2/deadlocks/deadlock-05.xml                          |    7 +
 .../attempt2/deadlocks/deadlock-06.xml                          |    7 +
 .../attempt2/deadlocks/deadlock-07.xml                          |    7 +
 .../attempt2/deadlocks/deadlocks.txt                            |    1 +
 .../attempt2/deadlocks/statements.json                          |   98 +
 .../attempt2/deadlocks/summary.json                             |  470 +++
 .../attempt2/plans/statement-01.sqlplan                         |    1 +
 .../attempt2/plans/statement-02.sqlplan                         |    1 +
 .../attempt2/plans/statement-03.sqlplan                         |    1 +
 .../attempt2/plans/statement-04.sqlplan                         |    1 +
 .../attempt2/plans/statement-05.sqlplan                         |    1 +
 .../attempt2/plans/statement-06.sqlplan                         |    1 +
 .../attempt2/plans/statement-07.sqlplan                         |    1 +
 .../attempt2/plans/statement-08.sqlplan                         |    1 +
 .../attempt2/plans/statement-09.sqlplan                         |    1 +
 .../attempt2/plans/statement-10.sqlplan                         |    1 +
 .../attempt2/plans/statement-11.sqlplan                         |    1 +
 .../attempt2/plans/statement-12.sqlplan                         |    1 +
 .../attempt2/plans/statement-13.sqlplan                         |    1 +
 .../attempt2/plans/statement-14.sqlplan                         |    1 +
 .../attempt2/plans/statement-15.sqlplan                         |    1 +
 .../attempt2/workload-Lucee-6.2.8.20.json                       | 1271 ++++++
 .../reproduction-before-the-correction/attempt2/workload.txt    |   26 +
 .../attempt3/deadlocks/deadlocks.txt                            |    1 +
 .../attempt3/workload-Lucee-6.2.8.20.json                       |  781 ++++
 .../reproduction-before-the-correction/attempt3/workload.txt    |   19 +
 .../reproduction-before-the-correction/perf-environment.txt     |   39 +
 .../reproduction-before-the-correction/seed/seed-transcript.txt |   17 +
 .../a8-03/reproduction-before-the-correction/seed/seed.json     |   22 +
 .../a8-03/sql-server-deadlock-record/deadlock-01.xml            |    7 +
 .../a8-03/sql-server-deadlock-record/deadlock-02.xml            |    7 +
 .../a8-03/sql-server-deadlock-record/deadlock-03.xml            |   13 +
 .../a8-03/sql-server-deadlock-record/deadlock-04.xml            |    7 +
 .../a8-03/sql-server-deadlock-record/deadlock-05.xml            |    7 +
 .../a8-03/sql-server-deadlock-record/deadlock-06.xml            |    7 +
 .../a8-03/sql-server-deadlock-record/deadlock-07.xml            |    7 +
 .../a8-03/sql-server-deadlock-record/deadlock-08.xml            |    7 +
 .../a8-03/sql-server-deadlock-record/deadlock-09.xml            |    7 +
 .../a8-03/sql-server-deadlock-record/deadlock-10.xml            |    7 +
 .../a8-03/sql-server-deadlock-record/deadlock-11.xml            |    7 +
 .../a8-03/sql-server-deadlock-record/deadlock-12.xml            |    7 +
 .../a8-03/sql-server-deadlock-record/deadlock-13.xml            |    7 +
 .../a8-03/sql-server-deadlock-record/deadlock-14.xml            |    7 +
 .../a8-03/sql-server-deadlock-record/deadlock-15.xml            |    7 +
 .../a8-03/sql-server-deadlock-record/deadlock-16.xml            |    7 +
 .../a8-03/sql-server-deadlock-record/deadlock-17.xml            |    7 +
 .../a8-03/sql-server-deadlock-record/deadlock-18.xml            |    7 +
 .../a8-03/sql-server-deadlock-record/deadlock-19.xml            |    7 +
 .../a8-03/sql-server-deadlock-record/deadlock-20.xml            |    7 +
 .../a8-03/sql-server-deadlock-record/deadlock-21.xml            |    7 +
 .../a8-03/sql-server-deadlock-record/deadlock-22.xml            |   16 +
 .../a8-03/sql-server-deadlock-record/deadlock-23.xml            |    7 +
 .../a8-03/sql-server-deadlock-record/deadlock-24.xml            |    7 +
 .../a8-03/sql-server-deadlock-record/deadlock-25.xml            |    7 +
 .../a8-03/sql-server-deadlock-record/deadlock-26.xml            |    7 +
 .../a8-03/sql-server-deadlock-record/deadlock-27.xml            |    7 +
 .../a8-03/sql-server-deadlock-record/deadlock-28.xml            |    7 +
 .../a8-03/sql-server-deadlock-record/deadlock-29.xml            |    7 +
 .../a8-03/sql-server-deadlock-record/deadlock-30.xml            |    7 +
 .../a8-03/sql-server-deadlock-record/deadlock-31.xml            |    7 +
 .../a8-03/sql-server-deadlock-record/deadlocks.txt              |  190 +
 .../a8-03/sql-server-deadlock-record/statements.json            |  404 ++
 .../a8-03/sql-server-deadlock-record/summary.json               | 1967 +++++++++
 docs/evidence/phase8-correction-a8/environment.md               |   58 +
 .../acf/npm-test.tap                                            | 2376 +++++++++++
 .../acf/passing-names.txt                                       |  299 ++
 .../baseline-names.txt                                          |  299 ++
 .../cfml-names-check.txt                                        |    9 +
 .../gate-transcript.txt                                         | 5929 +++++++++++++++++++++++++++
 .../gate-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/gate.sh       |  245 ++
 .../lucee/npm-test.tap                                          | 2376 +++++++++++
 .../lucee/passing-names.txt                                     |  299 ++
 .../acf-up-after.txt                                            |    3 +
 .../attempt-1-coldfusion-live-red-not-observed/README.md        |   39 +
 .../attempt-1-coldfusion-live-red-not-observed/acf-up-after.txt |    3 +
 .../database-operations/database-operations.json                |   60 +
 .../database-operations/database-operations.tap                 |   32 +
 .../diagnosis/cf-logs.txt                                       |  418 ++
 .../diagnosis/docker-logs.txt                                   |   39 +
 .../attempt-1-coldfusion-live-red-not-observed/diagnosis/ps.txt |    9 +
 .../diagnosis/readiness-schema-missing-acf.json                 |   32 +
 .../diagnosis/red-acf-diag.sh                                   |   61 +
 .../diagnosis/red.tap                                           |   34 +
 .../diagnosis/site.txt                                          |   29 +
 .../diagnosis/thread-dump.txt                                   |  152 +
 .../diagnosis/transcript.txt                                    |   16 +
 .../diagnosis/watch.txt                                         |   26 +
 .../lucee-up-after.txt                                          |    4 +
 .../attempt-1-coldfusion-live-red-not-observed/lucee-up.txt     |    4 +
 .../ops-transcript.txt                                          |  272 ++
 .../attempt-1-coldfusion-live-red-not-observed/ops.sh           |  110 +
 .../production-profile-coldfusion/production-profile-acf.json   |  219 +
 .../production-profile-coldfusion.tap                           |   22 +
 .../production-profile-lucee/production-profile-lucee.json      |  234 ++
 .../production-profile-lucee/production-profile-lucee.tap       |   19 +
 .../readiness-coldfusion-live-red-on-10f476ba.tap               |   35 +
 .../readiness-schema-missing-acf.json                           |   32 +
 .../readiness-coldfusion/readiness-coldfusion.tap               |   24 +
 .../readiness-coldfusion/readiness-schema-missing-acf.json      |  142 +
 .../readiness-lucee-live-red-on-10f476ba.tap                    |   31 +
 .../readiness-schema-missing-lucee.json                         |   48 +
 .../readiness-lucee/readiness-lucee.tap                         |   21 +
 .../readiness-lucee/readiness-schema-missing-lucee.json         |  146 +
 .../restart-coldfusion/restart-coldfusion.tap                   |   32 +
 .../restart-during-autosave-acf-container.json                  |  249 ++
 .../restart-lucee/restart-during-autosave-lucee.json            |  249 ++
 .../restart-lucee/restart-lucee.tap                             |   32 +
 .../readiness-schema-missing-acf.json                           |   48 +
 .../targeted-check-after-the-fix/red-acf-diag.sh                |   62 +
 .../targeted-check-after-the-fix/red.tap                        |   34 +
 .../targeted-check-after-the-fix/transcript.txt                 |   17 +
 .../targeted-check-after-the-fix/watch.txt                      |    7 +
 .../upgrade-and-rollback/upgrade-and-rollback.json              |   92 +
 .../upgrade-and-rollback/upgrade-and-rollback.tap               |   20 +
 .../database-operations/database-operations.json                |   60 +
 .../database-operations/database-operations.tap                 |   32 +
 .../lucee-up-after.txt                                          |    4 +
 .../lucee-up.txt                                                |    4 +
 .../ops-transcript.txt                                          |  279 ++
 .../operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/ops.sh  |  117 +
 .../production-profile-coldfusion/production-profile-acf.json   |  219 +
 .../production-profile-coldfusion.tap                           |   22 +
 .../production-profile-lucee/production-profile-lucee.json      |  234 ++
 .../production-profile-lucee/production-profile-lucee.tap       |   19 +
 .../readiness-coldfusion-live-red-on-10f476ba.tap               |   34 +
 .../readiness-schema-missing-acf.json                           |   48 +
 .../readiness-coldfusion/readiness-coldfusion.tap               |   24 +
 .../readiness-coldfusion/readiness-schema-missing-acf.json      |  142 +
 .../readiness-lucee-live-red-on-10f476ba.tap                    |   31 +
 .../readiness-schema-missing-lucee.json                         |   48 +
 .../readiness-lucee/readiness-lucee.tap                         |   21 +
 .../readiness-lucee/readiness-schema-missing-lucee.json         |  146 +
 .../restart-coldfusion/restart-coldfusion.tap                   |   32 +
 .../restart-during-autosave-acf-container.json                  |  249 ++
 .../restart-lucee/restart-during-autosave-lucee.json            |  249 ++
 .../restart-lucee/restart-lucee.tap                             |   32 +
 .../upgrade-and-rollback/upgrade-and-rollback.json              |   92 +
 .../upgrade-and-rollback/upgrade-and-rollback.tap               |   20 +
 .../evidence/phase8-correction-a8/targeted-green-coldfusion.txt |   69 +
 docs/evidence/phase8-correction-a8/tools/absorbed.mjs           |   39 +
 docs/evidence/phase8-correction-a8/tools/assemble.sh            |  108 +
 docs/evidence/phase8-correction-a8/tools/cfml-names.sh          |   34 +
 docs/evidence/phase8-correction-a8/tools/cfml-targeted.mjs      |   45 +
 docs/evidence/phase8-correction-a8/tools/correlate.mjs          |   31 +
 docs/evidence/phase8-correction-a8/tools/deadlocks.mjs          |   32 +
 docs/evidence/phase8-correction-a8/tools/package.sh             |  180 +
 docs/evidence/phase8-correction-a8/tools/perf-lucee.sh          |   38 +
 docs/evidence/phase8-correction-a8/tools/perf-run.sh            |   27 +
 docs/evidence/phase8-correction-a8/tools/perf-series.sh         |   30 +
 docs/evidence/phase8-correction-a8/tools/readiness-table.mjs    |   22 +
 .../phase8-correction-a8/tools/resolve-deadlock-statements.mjs  |   27 +
 docs/evidence/phase8-correction-a8/tools/runs-table.mjs         |   31 +
 docs/evidence/phase8-correction-a8/tools/secret-scan.sh         |   25 +
 docs/evidence/phase8-correction-a8/tools/stage-final.sh         |   56 +
 .../evidence/phase8-correction-a8/tools/summarize-deadlocks.mjs |   36 +
 docs/evidence/phase8-correction-a8/tools/verify-delivery.sh     |   91 +
 docs/evidence/phase8-correction-a8/tools/window-graphs.mjs      |   20 +
 255 files changed, 36846 insertions(+)

$ git diff --name-status b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d bbb4d1592d09d35d707741af462849622000091a
M	BUILD_STATUS.md
M	docs/ACCEPTANCE_TRACKING.md
A	docs/evidence/phase8-correction-a8/00-starting-state/preedit.sh
A	docs/evidence/phase8-correction-a8/00-starting-state/starting-state-and-fast-forward.txt
A	docs/evidence/phase8-correction-a8/ACCEPTANCE.md
A	docs/evidence/phase8-correction-a8/DEFECTS.md
A	docs/evidence/phase8-correction-a8/README.md
A	docs/evidence/phase8-correction-a8/SHA256SUMS
A	docs/evidence/phase8-correction-a8/a8-01/green-HealthReadinessTest-LongTextRetrievalTest-lucee.txt
A	docs/evidence/phase8-correction-a8/a8-01/red-HealthReadinessTest-lucee.txt
A	docs/evidence/phase8-correction-a8/a8-03/FINDINGS.md
A	docs/evidence/phase8-correction-a8/a8-03/on-the-correction-commit/absorbed-deadlocks.md
A	docs/evidence/phase8-correction-a8/a8-03/on-the-correction-commit/coldfusion-any/run1/deadlocks/deadlocks.txt
A	docs/evidence/phase8-correction-a8/a8-03/on-the-correction-commit/coldfusion-any/run1/log-events-during-run.txt
A	docs/evidence/phase8-correction-a8/a8-03/on-the-correction-commit/coldfusion-any/run1/workload-ColdFusion-Server-2023-0-25-330977.json
A	docs/evidence/phase8-correction-a8/a8-03/on-the-correction-commit/coldfusion-any/run1/workload.txt
A	docs/evidence/phase8-correction-a8/a8-03/on-the-correction-commit/coldfusion-any/series.txt
A	docs/evidence/phase8-correction-a8/a8-03/on-the-correction-commit/coldfusion-drafts/run1/deadlocks/deadlocks.txt
A	docs/evidence/phase8-correction-a8/a8-03/on-the-correction-commit/coldfusion-drafts/run1/log-events-during-run.txt
A	docs/evidence/phase8-correction-a8/a8-03/on-the-correction-commit/coldfusion-drafts/run1/workload-ColdFusion-Server-2023-0-25-330977.json
A	docs/evidence/phase8-correction-a8/a8-03/on-the-correction-commit/coldfusion-drafts/run1/workload.txt
A	docs/evidence/phase8-correction-a8/a8-03/on-the-correction-commit/coldfusion-drafts/series.txt
A	docs/evidence/phase8-correction-a8/a8-03/on-the-correction-commit/coldfusion-engine-start.txt
A	docs/evidence/phase8-correction-a8/a8-03/on-the-correction-commit/lucee-any/run1/deadlocks/deadlock-01.xml
A	docs/evidence/phase8-correction-a8/a8-03/on-the-correction-commit/lucee-any/run1/deadlocks/deadlock-02.xml
A	docs/evidence/phase8-correction-a8/a8-03/on-the-correction-commit/lucee-any/run1/deadlocks/deadlock-03.xml
A	docs/evidence/phase8-correction-a8/a8-03/on-the-correction-commit/lucee-any/run1/deadlocks/deadlock-04.xml
A	docs/evidence/phase8-correction-a8/a8-03/on-the-correction-commit/lucee-any/run1/deadlocks/deadlock-05.xml
A	docs/evidence/phase8-correction-a8/a8-03/on-the-correction-commit/lucee-any/run1/deadlocks/deadlock-06.xml
A	docs/evidence/phase8-correction-a8/a8-03/on-the-correction-commit/lucee-any/run1/deadlocks/deadlock-07.xml
A	docs/evidence/phase8-correction-a8/a8-03/on-the-correction-commit/lucee-any/run1/deadlocks/deadlocks.txt
A	docs/evidence/phase8-correction-a8/a8-03/on-the-correction-commit/lucee-any/run1/deadlocks/summary.json
A	docs/evidence/phase8-correction-a8/a8-03/on-the-correction-commit/lucee-any/run1/log-events-during-run.txt
A	docs/evidence/phase8-correction-a8/a8-03/on-the-correction-commit/lucee-any/run1/workload-Lucee-6.2.8.20.json
A	docs/evidence/phase8-correction-a8/a8-03/on-the-correction-commit/lucee-any/run1/workload.txt
A	docs/evidence/phase8-correction-a8/a8-03/on-the-correction-commit/lucee-any/series.txt
A	docs/evidence/phase8-correction-a8/a8-03/on-the-correction-commit/lucee-drafts/run1/deadlocks/deadlock-01.xml
A	docs/evidence/phase8-correction-a8/a8-03/on-the-correction-commit/lucee-drafts/run1/deadlocks/deadlocks.txt
A	docs/evidence/phase8-correction-a8/a8-03/on-the-correction-commit/lucee-drafts/run1/deadlocks/summary.json
A	docs/evidence/phase8-correction-a8/a8-03/on-the-correction-commit/lucee-drafts/run1/log-events-during-run.txt
A	docs/evidence/phase8-correction-a8/a8-03/on-the-correction-commit/lucee-drafts/run1/workload-Lucee-6.2.8.20.json
A	docs/evidence/phase8-correction-a8/a8-03/on-the-correction-commit/lucee-drafts/run1/workload.txt
A	docs/evidence/phase8-correction-a8/a8-03/on-the-correction-commit/lucee-drafts/run2/deadlocks/deadlocks.txt
A	docs/evidence/phase8-correction-a8/a8-03/on-the-correction-commit/lucee-drafts/run2/log-events-during-run.txt
A	docs/evidence/phase8-correction-a8/a8-03/on-the-correction-commit/lucee-drafts/run2/workload-Lucee-6.2.8.20.json
A	docs/evidence/phase8-correction-a8/a8-03/on-the-correction-commit/lucee-drafts/run2/workload.txt
A	docs/evidence/phase8-correction-a8/a8-03/on-the-correction-commit/lucee-drafts/run3/deadlocks/deadlocks.txt
A	docs/evidence/phase8-correction-a8/a8-03/on-the-correction-commit/lucee-drafts/run3/log-events-during-run.txt
A	docs/evidence/phase8-correction-a8/a8-03/on-the-correction-commit/lucee-drafts/run3/workload-Lucee-6.2.8.20.json
A	docs/evidence/phase8-correction-a8/a8-03/on-the-correction-commit/lucee-drafts/run3/workload.txt
A	docs/evidence/phase8-correction-a8/a8-03/on-the-correction-commit/lucee-drafts/run4/deadlocks/deadlock-01.xml
A	docs/evidence/phase8-correction-a8/a8-03/on-the-correction-commit/lucee-drafts/run4/deadlocks/deadlock-02.xml
A	docs/evidence/phase8-correction-a8/a8-03/on-the-correction-commit/lucee-drafts/run4/deadlocks/deadlock-03.xml
A	docs/evidence/phase8-correction-a8/a8-03/on-the-correction-commit/lucee-drafts/run4/deadlocks/deadlocks.txt
A	docs/evidence/phase8-correction-a8/a8-03/on-the-correction-commit/lucee-drafts/run4/deadlocks/summary.json
A	docs/evidence/phase8-correction-a8/a8-03/on-the-correction-commit/lucee-drafts/run4/log-events-during-run.txt
A	docs/evidence/phase8-correction-a8/a8-03/on-the-correction-commit/lucee-drafts/run4/workload-Lucee-6.2.8.20.json
A	docs/evidence/phase8-correction-a8/a8-03/on-the-correction-commit/lucee-drafts/run4/workload.txt
A	docs/evidence/phase8-correction-a8/a8-03/on-the-correction-commit/lucee-drafts/run5/deadlocks/deadlock-01.xml
A	docs/evidence/phase8-correction-a8/a8-03/on-the-correction-commit/lucee-drafts/run5/deadlocks/deadlocks.txt
A	docs/evidence/phase8-correction-a8/a8-03/on-the-correction-commit/lucee-drafts/run5/deadlocks/summary.json
A	docs/evidence/phase8-correction-a8/a8-03/on-the-correction-commit/lucee-drafts/run5/log-events-during-run.txt
A	docs/evidence/phase8-correction-a8/a8-03/on-the-correction-commit/lucee-drafts/run5/workload-Lucee-6.2.8.20.json
A	docs/evidence/phase8-correction-a8/a8-03/on-the-correction-commit/lucee-drafts/run5/workload.txt
A	docs/evidence/phase8-correction-a8/a8-03/on-the-correction-commit/lucee-drafts/series.txt
A	docs/evidence/phase8-correction-a8/a8-03/on-the-correction-commit/lucee-engine-restart-after-the-host-reboot.txt
A	docs/evidence/phase8-correction-a8/a8-03/on-the-correction-commit/lucee-engine-start.txt
A	docs/evidence/phase8-correction-a8/a8-03/pre-commit-check-on-the-corrected-tree/deadlocks/deadlocks.txt
A	docs/evidence/phase8-correction-a8/a8-03/pre-commit-check-on-the-corrected-tree/workload-Lucee-6.2.8.20.json
A	docs/evidence/phase8-correction-a8/a8-03/pre-commit-check-on-the-corrected-tree/workload.txt
A	docs/evidence/phase8-correction-a8/a8-03/regression/green-ReportDeadlockVictimTest-and-report-specs-lucee.txt
A	docs/evidence/phase8-correction-a8/a8-03/regression/not-red-1-spec-did-not-compile-on-lucee.txt
A	docs/evidence/phase8-correction-a8/a8-03/regression/not-red-2-spec-did-not-compile-on-lucee.txt
A	docs/evidence/phase8-correction-a8/a8-03/regression/not-red-3-fixture-closure-returned-nothing.txt
A	docs/evidence/phase8-correction-a8/a8-03/regression/red-ReportDeadlockVictimTest-lucee.txt
A	docs/evidence/phase8-correction-a8/a8-03/reproduction-before-the-correction/attempt1/deadlocks/deadlocks.txt
A	docs/evidence/phase8-correction-a8/a8-03/reproduction-before-the-correction/attempt1/plans/statement-01.sqlplan
A	docs/evidence/phase8-correction-a8/a8-03/reproduction-before-the-correction/attempt1/plans/statement-02.sqlplan
A	docs/evidence/phase8-correction-a8/a8-03/reproduction-before-the-correction/attempt1/plans/statement-03.sqlplan
A	docs/evidence/phase8-correction-a8/a8-03/reproduction-before-the-correction/attempt1/plans/statement-04.sqlplan
A	docs/evidence/phase8-correction-a8/a8-03/reproduction-before-the-correction/attempt1/plans/statement-05.sqlplan
A	docs/evidence/phase8-correction-a8/a8-03/reproduction-before-the-correction/attempt1/plans/statement-06.sqlplan
A	docs/evidence/phase8-correction-a8/a8-03/reproduction-before-the-correction/attempt1/plans/statement-07.sqlplan
A	docs/evidence/phase8-correction-a8/a8-03/reproduction-before-the-correction/attempt1/plans/statement-08.sqlplan
A	docs/evidence/phase8-correction-a8/a8-03/reproduction-before-the-correction/attempt1/plans/statement-09.sqlplan
A	docs/evidence/phase8-correction-a8/a8-03/reproduction-before-the-correction/attempt1/plans/statement-10.sqlplan
A	docs/evidence/phase8-correction-a8/a8-03/reproduction-before-the-correction/attempt1/plans/statement-11.sqlplan
A	docs/evidence/phase8-correction-a8/a8-03/reproduction-before-the-correction/attempt1/plans/statement-12.sqlplan
A	docs/evidence/phase8-correction-a8/a8-03/reproduction-before-the-correction/attempt1/plans/statement-13.sqlplan
A	docs/evidence/phase8-correction-a8/a8-03/reproduction-before-the-correction/attempt1/plans/statement-14.sqlplan
A	docs/evidence/phase8-correction-a8/a8-03/reproduction-before-the-correction/attempt1/plans/statement-15.sqlplan
A	docs/evidence/phase8-correction-a8/a8-03/reproduction-before-the-correction/attempt1/workload-Lucee-6.2.8.20.json
A	docs/evidence/phase8-correction-a8/a8-03/reproduction-before-the-correction/attempt1/workload.txt
A	docs/evidence/phase8-correction-a8/a8-03/reproduction-before-the-correction/attempt2/correlation.md
A	docs/evidence/phase8-correction-a8/a8-03/reproduction-before-the-correction/attempt2/deadlocks/deadlock-01.xml
A	docs/evidence/phase8-correction-a8/a8-03/reproduction-before-the-correction/attempt2/deadlocks/deadlock-02.xml
A	docs/evidence/phase8-correction-a8/a8-03/reproduction-before-the-correction/attempt2/deadlocks/deadlock-03.xml
A	docs/evidence/phase8-correction-a8/a8-03/reproduction-before-the-correction/attempt2/deadlocks/deadlock-04.xml
A	docs/evidence/phase8-correction-a8/a8-03/reproduction-before-the-correction/attempt2/deadlocks/deadlock-05.xml
A	docs/evidence/phase8-correction-a8/a8-03/reproduction-before-the-correction/attempt2/deadlocks/deadlock-06.xml
A	docs/evidence/phase8-correction-a8/a8-03/reproduction-before-the-correction/attempt2/deadlocks/deadlock-07.xml
A	docs/evidence/phase8-correction-a8/a8-03/reproduction-before-the-correction/attempt2/deadlocks/deadlocks.txt
A	docs/evidence/phase8-correction-a8/a8-03/reproduction-before-the-correction/attempt2/deadlocks/statements.json
A	docs/evidence/phase8-correction-a8/a8-03/reproduction-before-the-correction/attempt2/deadlocks/summary.json
A	docs/evidence/phase8-correction-a8/a8-03/reproduction-before-the-correction/attempt2/plans/statement-01.sqlplan
A	docs/evidence/phase8-correction-a8/a8-03/reproduction-before-the-correction/attempt2/plans/statement-02.sqlplan
A	docs/evidence/phase8-correction-a8/a8-03/reproduction-before-the-correction/attempt2/plans/statement-03.sqlplan
A	docs/evidence/phase8-correction-a8/a8-03/reproduction-before-the-correction/attempt2/plans/statement-04.sqlplan
A	docs/evidence/phase8-correction-a8/a8-03/reproduction-before-the-correction/attempt2/plans/statement-05.sqlplan
A	docs/evidence/phase8-correction-a8/a8-03/reproduction-before-the-correction/attempt2/plans/statement-06.sqlplan
A	docs/evidence/phase8-correction-a8/a8-03/reproduction-before-the-correction/attempt2/plans/statement-07.sqlplan
A	docs/evidence/phase8-correction-a8/a8-03/reproduction-before-the-correction/attempt2/plans/statement-08.sqlplan
A	docs/evidence/phase8-correction-a8/a8-03/reproduction-before-the-correction/attempt2/plans/statement-09.sqlplan
A	docs/evidence/phase8-correction-a8/a8-03/reproduction-before-the-correction/attempt2/plans/statement-10.sqlplan
A	docs/evidence/phase8-correction-a8/a8-03/reproduction-before-the-correction/attempt2/plans/statement-11.sqlplan
A	docs/evidence/phase8-correction-a8/a8-03/reproduction-before-the-correction/attempt2/plans/statement-12.sqlplan
A	docs/evidence/phase8-correction-a8/a8-03/reproduction-before-the-correction/attempt2/plans/statement-13.sqlplan
A	docs/evidence/phase8-correction-a8/a8-03/reproduction-before-the-correction/attempt2/plans/statement-14.sqlplan
A	docs/evidence/phase8-correction-a8/a8-03/reproduction-before-the-correction/attempt2/plans/statement-15.sqlplan
A	docs/evidence/phase8-correction-a8/a8-03/reproduction-before-the-correction/attempt2/workload-Lucee-6.2.8.20.json
A	docs/evidence/phase8-correction-a8/a8-03/reproduction-before-the-correction/attempt2/workload.txt
A	docs/evidence/phase8-correction-a8/a8-03/reproduction-before-the-correction/attempt3/deadlocks/deadlocks.txt
A	docs/evidence/phase8-correction-a8/a8-03/reproduction-before-the-correction/attempt3/workload-Lucee-6.2.8.20.json
A	docs/evidence/phase8-correction-a8/a8-03/reproduction-before-the-correction/attempt3/workload.txt
A	docs/evidence/phase8-correction-a8/a8-03/reproduction-before-the-correction/perf-environment.txt
A	docs/evidence/phase8-correction-a8/a8-03/reproduction-before-the-correction/seed/seed-transcript.txt
A	docs/evidence/phase8-correction-a8/a8-03/reproduction-before-the-correction/seed/seed.json
A	docs/evidence/phase8-correction-a8/a8-03/sql-server-deadlock-record/deadlock-01.xml
A	docs/evidence/phase8-correction-a8/a8-03/sql-server-deadlock-record/deadlock-02.xml
A	docs/evidence/phase8-correction-a8/a8-03/sql-server-deadlock-record/deadlock-03.xml
A	docs/evidence/phase8-correction-a8/a8-03/sql-server-deadlock-record/deadlock-04.xml
A	docs/evidence/phase8-correction-a8/a8-03/sql-server-deadlock-record/deadlock-05.xml
A	docs/evidence/phase8-correction-a8/a8-03/sql-server-deadlock-record/deadlock-06.xml
A	docs/evidence/phase8-correction-a8/a8-03/sql-server-deadlock-record/deadlock-07.xml
A	docs/evidence/phase8-correction-a8/a8-03/sql-server-deadlock-record/deadlock-08.xml
A	docs/evidence/phase8-correction-a8/a8-03/sql-server-deadlock-record/deadlock-09.xml
A	docs/evidence/phase8-correction-a8/a8-03/sql-server-deadlock-record/deadlock-10.xml
A	docs/evidence/phase8-correction-a8/a8-03/sql-server-deadlock-record/deadlock-11.xml
A	docs/evidence/phase8-correction-a8/a8-03/sql-server-deadlock-record/deadlock-12.xml
A	docs/evidence/phase8-correction-a8/a8-03/sql-server-deadlock-record/deadlock-13.xml
A	docs/evidence/phase8-correction-a8/a8-03/sql-server-deadlock-record/deadlock-14.xml
A	docs/evidence/phase8-correction-a8/a8-03/sql-server-deadlock-record/deadlock-15.xml
A	docs/evidence/phase8-correction-a8/a8-03/sql-server-deadlock-record/deadlock-16.xml
A	docs/evidence/phase8-correction-a8/a8-03/sql-server-deadlock-record/deadlock-17.xml
A	docs/evidence/phase8-correction-a8/a8-03/sql-server-deadlock-record/deadlock-18.xml
A	docs/evidence/phase8-correction-a8/a8-03/sql-server-deadlock-record/deadlock-19.xml
A	docs/evidence/phase8-correction-a8/a8-03/sql-server-deadlock-record/deadlock-20.xml
A	docs/evidence/phase8-correction-a8/a8-03/sql-server-deadlock-record/deadlock-21.xml
A	docs/evidence/phase8-correction-a8/a8-03/sql-server-deadlock-record/deadlock-22.xml
A	docs/evidence/phase8-correction-a8/a8-03/sql-server-deadlock-record/deadlock-23.xml
A	docs/evidence/phase8-correction-a8/a8-03/sql-server-deadlock-record/deadlock-24.xml
A	docs/evidence/phase8-correction-a8/a8-03/sql-server-deadlock-record/deadlock-25.xml
A	docs/evidence/phase8-correction-a8/a8-03/sql-server-deadlock-record/deadlock-26.xml
A	docs/evidence/phase8-correction-a8/a8-03/sql-server-deadlock-record/deadlock-27.xml
A	docs/evidence/phase8-correction-a8/a8-03/sql-server-deadlock-record/deadlock-28.xml
A	docs/evidence/phase8-correction-a8/a8-03/sql-server-deadlock-record/deadlock-29.xml
A	docs/evidence/phase8-correction-a8/a8-03/sql-server-deadlock-record/deadlock-30.xml
A	docs/evidence/phase8-correction-a8/a8-03/sql-server-deadlock-record/deadlock-31.xml
A	docs/evidence/phase8-correction-a8/a8-03/sql-server-deadlock-record/deadlocks.txt
A	docs/evidence/phase8-correction-a8/a8-03/sql-server-deadlock-record/statements.json
A	docs/evidence/phase8-correction-a8/a8-03/sql-server-deadlock-record/summary.json
A	docs/evidence/phase8-correction-a8/environment.md
A	docs/evidence/phase8-correction-a8/gate-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/acf/npm-test.tap
A	docs/evidence/phase8-correction-a8/gate-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/acf/passing-names.txt
A	docs/evidence/phase8-correction-a8/gate-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/baseline-names.txt
A	docs/evidence/phase8-correction-a8/gate-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/cfml-names-check.txt
A	docs/evidence/phase8-correction-a8/gate-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/gate-transcript.txt
A	docs/evidence/phase8-correction-a8/gate-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/gate.sh
A	docs/evidence/phase8-correction-a8/gate-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/lucee/npm-test.tap
A	docs/evidence/phase8-correction-a8/gate-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/lucee/passing-names.txt
A	docs/evidence/phase8-correction-a8/operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/acf-up-after.txt
A	docs/evidence/phase8-correction-a8/operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/attempt-1-coldfusion-live-red-not-observed/README.md
A	docs/evidence/phase8-correction-a8/operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/attempt-1-coldfusion-live-red-not-observed/acf-up-after.txt
A	docs/evidence/phase8-correction-a8/operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/attempt-1-coldfusion-live-red-not-observed/database-operations/database-operations.json
A	docs/evidence/phase8-correction-a8/operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/attempt-1-coldfusion-live-red-not-observed/database-operations/database-operations.tap
A	docs/evidence/phase8-correction-a8/operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/attempt-1-coldfusion-live-red-not-observed/diagnosis/cf-logs.txt
A	docs/evidence/phase8-correction-a8/operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/attempt-1-coldfusion-live-red-not-observed/diagnosis/docker-logs.txt
A	docs/evidence/phase8-correction-a8/operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/attempt-1-coldfusion-live-red-not-observed/diagnosis/ps.txt
A	docs/evidence/phase8-correction-a8/operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/attempt-1-coldfusion-live-red-not-observed/diagnosis/readiness-schema-missing-acf.json
A	docs/evidence/phase8-correction-a8/operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/attempt-1-coldfusion-live-red-not-observed/diagnosis/red-acf-diag.sh
A	docs/evidence/phase8-correction-a8/operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/attempt-1-coldfusion-live-red-not-observed/diagnosis/red.tap
A	docs/evidence/phase8-correction-a8/operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/attempt-1-coldfusion-live-red-not-observed/diagnosis/site.txt
A	docs/evidence/phase8-correction-a8/operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/attempt-1-coldfusion-live-red-not-observed/diagnosis/thread-dump.txt
A	docs/evidence/phase8-correction-a8/operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/attempt-1-coldfusion-live-red-not-observed/diagnosis/transcript.txt
A	docs/evidence/phase8-correction-a8/operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/attempt-1-coldfusion-live-red-not-observed/diagnosis/watch.txt
A	docs/evidence/phase8-correction-a8/operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/attempt-1-coldfusion-live-red-not-observed/lucee-up-after.txt
A	docs/evidence/phase8-correction-a8/operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/attempt-1-coldfusion-live-red-not-observed/lucee-up.txt
A	docs/evidence/phase8-correction-a8/operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/attempt-1-coldfusion-live-red-not-observed/ops-transcript.txt
A	docs/evidence/phase8-correction-a8/operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/attempt-1-coldfusion-live-red-not-observed/ops.sh
A	docs/evidence/phase8-correction-a8/operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/attempt-1-coldfusion-live-red-not-observed/production-profile-coldfusion/production-profile-acf.json
A	docs/evidence/phase8-correction-a8/operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/attempt-1-coldfusion-live-red-not-observed/production-profile-coldfusion/production-profile-coldfusion.tap
A	docs/evidence/phase8-correction-a8/operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/attempt-1-coldfusion-live-red-not-observed/production-profile-lucee/production-profile-lucee.json
A	docs/evidence/phase8-correction-a8/operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/attempt-1-coldfusion-live-red-not-observed/production-profile-lucee/production-profile-lucee.tap
A	docs/evidence/phase8-correction-a8/operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/attempt-1-coldfusion-live-red-not-observed/readiness-coldfusion-live-red-on-10f476ba/readiness-coldfusion-live-red-on-10f476ba.tap
A	docs/evidence/phase8-correction-a8/operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/attempt-1-coldfusion-live-red-not-observed/readiness-coldfusion-live-red-on-10f476ba/readiness-schema-missing-acf.json
A	docs/evidence/phase8-correction-a8/operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/attempt-1-coldfusion-live-red-not-observed/readiness-coldfusion/readiness-coldfusion.tap
A	docs/evidence/phase8-correction-a8/operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/attempt-1-coldfusion-live-red-not-observed/readiness-coldfusion/readiness-schema-missing-acf.json
A	docs/evidence/phase8-correction-a8/operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/attempt-1-coldfusion-live-red-not-observed/readiness-lucee-live-red-on-10f476ba/readiness-lucee-live-red-on-10f476ba.tap
A	docs/evidence/phase8-correction-a8/operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/attempt-1-coldfusion-live-red-not-observed/readiness-lucee-live-red-on-10f476ba/readiness-schema-missing-lucee.json
A	docs/evidence/phase8-correction-a8/operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/attempt-1-coldfusion-live-red-not-observed/readiness-lucee/readiness-lucee.tap
A	docs/evidence/phase8-correction-a8/operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/attempt-1-coldfusion-live-red-not-observed/readiness-lucee/readiness-schema-missing-lucee.json
A	docs/evidence/phase8-correction-a8/operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/attempt-1-coldfusion-live-red-not-observed/restart-coldfusion/restart-coldfusion.tap
A	docs/evidence/phase8-correction-a8/operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/attempt-1-coldfusion-live-red-not-observed/restart-coldfusion/restart-during-autosave-acf-container.json
A	docs/evidence/phase8-correction-a8/operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/attempt-1-coldfusion-live-red-not-observed/restart-lucee/restart-during-autosave-lucee.json
A	docs/evidence/phase8-correction-a8/operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/attempt-1-coldfusion-live-red-not-observed/restart-lucee/restart-lucee.tap
A	docs/evidence/phase8-correction-a8/operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/attempt-1-coldfusion-live-red-not-observed/targeted-check-after-the-fix/readiness-schema-missing-acf.json
A	docs/evidence/phase8-correction-a8/operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/attempt-1-coldfusion-live-red-not-observed/targeted-check-after-the-fix/red-acf-diag.sh
A	docs/evidence/phase8-correction-a8/operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/attempt-1-coldfusion-live-red-not-observed/targeted-check-after-the-fix/red.tap
A	docs/evidence/phase8-correction-a8/operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/attempt-1-coldfusion-live-red-not-observed/targeted-check-after-the-fix/transcript.txt
A	docs/evidence/phase8-correction-a8/operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/attempt-1-coldfusion-live-red-not-observed/targeted-check-after-the-fix/watch.txt
A	docs/evidence/phase8-correction-a8/operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/attempt-1-coldfusion-live-red-not-observed/upgrade-and-rollback/upgrade-and-rollback.json
A	docs/evidence/phase8-correction-a8/operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/attempt-1-coldfusion-live-red-not-observed/upgrade-and-rollback/upgrade-and-rollback.tap
A	docs/evidence/phase8-correction-a8/operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/database-operations/database-operations.json
A	docs/evidence/phase8-correction-a8/operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/database-operations/database-operations.tap
A	docs/evidence/phase8-correction-a8/operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/lucee-up-after.txt
A	docs/evidence/phase8-correction-a8/operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/lucee-up.txt
A	docs/evidence/phase8-correction-a8/operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/ops-transcript.txt
A	docs/evidence/phase8-correction-a8/operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/ops.sh
A	docs/evidence/phase8-correction-a8/operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/production-profile-coldfusion/production-profile-acf.json
A	docs/evidence/phase8-correction-a8/operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/production-profile-coldfusion/production-profile-coldfusion.tap
A	docs/evidence/phase8-correction-a8/operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/production-profile-lucee/production-profile-lucee.json
A	docs/evidence/phase8-correction-a8/operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/production-profile-lucee/production-profile-lucee.tap
A	docs/evidence/phase8-correction-a8/operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/readiness-coldfusion-live-red-on-10f476ba/readiness-coldfusion-live-red-on-10f476ba.tap
A	docs/evidence/phase8-correction-a8/operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/readiness-coldfusion-live-red-on-10f476ba/readiness-schema-missing-acf.json
A	docs/evidence/phase8-correction-a8/operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/readiness-coldfusion/readiness-coldfusion.tap
A	docs/evidence/phase8-correction-a8/operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/readiness-coldfusion/readiness-schema-missing-acf.json
A	docs/evidence/phase8-correction-a8/operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/readiness-lucee-live-red-on-10f476ba/readiness-lucee-live-red-on-10f476ba.tap
A	docs/evidence/phase8-correction-a8/operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/readiness-lucee-live-red-on-10f476ba/readiness-schema-missing-lucee.json
A	docs/evidence/phase8-correction-a8/operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/readiness-lucee/readiness-lucee.tap
A	docs/evidence/phase8-correction-a8/operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/readiness-lucee/readiness-schema-missing-lucee.json
A	docs/evidence/phase8-correction-a8/operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/restart-coldfusion/restart-coldfusion.tap
A	docs/evidence/phase8-correction-a8/operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/restart-coldfusion/restart-during-autosave-acf-container.json
A	docs/evidence/phase8-correction-a8/operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/restart-lucee/restart-during-autosave-lucee.json
A	docs/evidence/phase8-correction-a8/operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/restart-lucee/restart-lucee.tap
A	docs/evidence/phase8-correction-a8/operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/upgrade-and-rollback/upgrade-and-rollback.json
A	docs/evidence/phase8-correction-a8/operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/upgrade-and-rollback/upgrade-and-rollback.tap
A	docs/evidence/phase8-correction-a8/targeted-green-coldfusion.txt
A	docs/evidence/phase8-correction-a8/tools/absorbed.mjs
A	docs/evidence/phase8-correction-a8/tools/assemble.sh
A	docs/evidence/phase8-correction-a8/tools/cfml-names.sh
A	docs/evidence/phase8-correction-a8/tools/cfml-targeted.mjs
A	docs/evidence/phase8-correction-a8/tools/correlate.mjs
A	docs/evidence/phase8-correction-a8/tools/deadlocks.mjs
A	docs/evidence/phase8-correction-a8/tools/package.sh
A	docs/evidence/phase8-correction-a8/tools/perf-lucee.sh
A	docs/evidence/phase8-correction-a8/tools/perf-run.sh
A	docs/evidence/phase8-correction-a8/tools/perf-series.sh
A	docs/evidence/phase8-correction-a8/tools/readiness-table.mjs
A	docs/evidence/phase8-correction-a8/tools/resolve-deadlock-statements.mjs
A	docs/evidence/phase8-correction-a8/tools/runs-table.mjs
A	docs/evidence/phase8-correction-a8/tools/secret-scan.sh
A	docs/evidence/phase8-correction-a8/tools/stage-final.sh
A	docs/evidence/phase8-correction-a8/tools/summarize-deadlocks.mjs
A	docs/evidence/phase8-correction-a8/tools/verify-delivery.sh
A	docs/evidence/phase8-correction-a8/tools/window-graphs.mjs
```

The original Phase 8 evidence is unchanged since the audited tip:

```text
$ git diff --name-status 10f476ba9a69359f23a259be0e903afeed64b415 bbb4d1592d09d35d707741af462849622000091a -- docs/evidence/phase8
<empty output>
$ (cd docs/evidence/phase8 && sha256sum -c SHA256SUMS)
200 files OK, 0 failed
```

The correction's evidence directory against its own checksum manifest:

```text
$ (cd docs/evidence/phase8-correction-a8 && sha256sum -c SHA256SUMS)
252 files OK, 0 failed
```

## Working tree immediately before packaging

```text
$ git status --porcelain=v1 --untracked-files=all
<empty output: clean>
$ git rev-parse HEAD HEAD^{tree}
bbb4d1592d09d35d707741af462849622000091a
4e0afcd710987847081594e4d42d8a15b604aa87
```

## The archive

| What | Value |
| --- | --- |
| File name | `ICFWalk-phase8-correction-a8-bbb4d1592d09.zip` |
| Top-level folder | `ICFWalk-phase8-correction-a8-bbb4d1592d09/` |
| ZIP comment | `bbb4d1592d09d35d707741af462849622000091a` (written by `git archive`: the source commit) |
| Construction command | `git archive --format=zip --prefix=ICFWalk-phase8-correction-a8-bbb4d1592d09/ --add-file=<stage>/DELIVERY-IDENTITY.md --add-file=<stage>/PAYLOAD-SHA256SUMS -o ICFWalk-phase8-correction-a8-bbb4d1592d09.zip bbb4d1592d09d35d707741af462849622000091a` |
| Payload checksums | `ICFWalk-phase8-correction-a8-bbb4d1592d09/PAYLOAD-SHA256SUMS`: every file of the archive except itself |
| Archive checksum | `ICFWalk-phase8-correction-a8-bbb4d1592d09.zip.sha256`, beside the archive, outside it |

The archive holds exactly the files of the source tree, under the top-level folder, plus this record and
PAYLOAD-SHA256SUMS. With those two set aside, `git write-tree` over the extracted files reproduces the
source tree `4e0afcd710987847081594e4d42d8a15b604aa87`.
