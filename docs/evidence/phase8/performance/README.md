# Phase 8 performance evidence

**No performance target has been set, so nothing here is a pass or a fail** (owner decision D8 in
`../OWNER_DECISIONS.md`). This directory is a reproducible synthetic workload and what it measured,
so that a target, once the district sets one, can be checked by running it again on the production
hardware. Performance acceptance is **not complete**.

## Environment

One virtual machine held everything: 4 vCPU (Intel Xeon @ 2.10 GHz), 16 GB RAM; SQL Server 2022
16.0.4295.3 Developer Edition in Docker (image pinned by digest, as in the gate); the engine under
test; and the Node load generator. Engines: Lucee 6.2.8.20 on jetty-runner 9.4.58 (`-Xmx1g`), and
Adobe ColdFusion 2023 Update 25 in Adobe's image (`sha256:e42bbf07...`), built-in web server,
Microsoft JDBC 12.10.2, long text retrieval on. Only one engine ran during a measurement. The numbers
describe this machine, where SQL Server, the engine and the load generator compete for four CPUs
(the dominant wait is `SOS_SCHEDULER_YIELD`); they are not a prediction for the production servers.

## Data

`tests/perf/seed.mjs` (`seed.json`, `seed-transcript.txt`): one district, 50 schools (every
identifying School value of the instrument), 6 walkers per school, a district walker, a report-only
user and an administrator (303 people); **30,000 walks** over one school year (80 % completed, 15 %
drafts, 5 % voided), **2,190,000 responses** and 219,005 dimension values. Template walks are made
through the HTTP API and then copied in SQL, so every row is one the application itself would store.
The database is about 2 GB.

## Method

`tests/perf/workload.mjs`, closed loop with no think time: each virtual user issues its next request
as soon as the last one answers, so 25 users here is far heavier than 25 people. Four in five users
are school walkers (My Walks, open one of their walks, change a note and save half the time, the
summary one time in ten, create, fill and complete a new walk one time in twenty); one in five is the
district walker (My Walks across the district, a live district report, its CSV). Each level runs 60
seconds. `PERF_EDIT=any` edits any of the walker's walks (mostly completed ones: post-completion
edits); `PERF_EDIT=drafts` edits drafts only (autosave while observing, the common case). Before the
levels, the district report and its CSV are timed five times with nothing else running. Recorded per
level: timings per operation (p50 / p95 in ms below), errors by kind, SQL Server waits, a blocking
sample every second, tempdb, open transactions and the engine's memory; after the run, the fifteen
statements that took the most time with their plans (`plans/*.sqlplan`), scans in those plans, and
SQL Server's missing-index suggestions.

## Results

### Lucee, before P8-14, completed walks edited (`lucee-run1/`)

Lucee 6.2.8.20; 30000 walks, 2190000 responses; 60 s per level; edits: any.

| Users | Requests/min | list mine | open walk | save walk | summary | create walk | complete walk | list district (scope=all) | report live district | report CSV district |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 1522 | 29 / 50 | 21 / 33 | 55 / 77 | 22 / 41 | 86 / 139 | 43 / 58 |  |  |  |
| 10 | 1357 | 459 / 776 | 157 / 390 | 358 / 878 | 158 / 437 | 625 / 1583 | 300 / 725 | 2355 / 3019 | - / - (6 err) | 6256 / 9910 (4 err) |
| 25 | 1292 | 1093 / 1952 | 447 / 914 | 1125 / 2061 | 634 / 1184 | 969 / 3819 | 724 / 1725 | 5320 / 6130 | 11723 / 11975 (7 err) | 1666 / 11839 (5 err) |

Errors: 409 REPORT_POPULATION_CHANGED.

At 25 users: longest block 1402 ms (5 blocked at once); top waits SOS_SCHEDULER_YIELD 270 s, CXCONSUMER 99 s, LCK_M_S 64 s; engine null; temp tables before/after 1/1, open transactions after 0.

### Lucee, before P8-14, repeat (`lucee-run2-default-mix-repeat/`)

Lucee 6.2.8.20; 30088 walks, 2196424 responses; 60 s per level; edits: any. District report alone: live p50 1049 ms, CSV p50 971 ms.

| Users | Requests/min | list mine | open walk | save walk | summary | create walk | complete walk | list district (scope=all) | report live district | report CSV district |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 1210 | 68 / 91 | 23 / 32 | 58 / 76 | 21 / 31 | 90 / 111 | 44 / 58 |  |  |  |
| 10 | 1316 | 502 / 911 | 157 / 370 | 374 / 780 | 180 / 442 | 829 / 1234 | 248 / 555 | 2327 / 3035 | - / - (6 err) | 6390 / 6390 (5 err) |
| 25 | 1096 | 1260 / 2113 | 442 / 842 | 995 / 1923 | 348 / 984 | 1302 / 4979 | 600 / 1341 | 5550 / 7268 | 24750 / 24994 (7 err) | 3768 / 24371 (5 err) |

Errors: 409 REPORT_POPULATION_CHANGED.

At 25 users: longest block 2270 ms (4 blocked at once); top waits SOS_SCHEDULER_YIELD 379 s, CXCONSUMER 148 s, LCK_M_S 77 s; engine null; temp tables before/after 1/1, open transactions after 0.

### Lucee, before P8-14, drafts only edited (`lucee-run3-drafts/`)

Lucee 6.2.8.20; 30154 walks, 2201242 responses; 60 s per level; edits: drafts. District report alone: live p50 1340 ms, CSV p50 1320 ms.

| Users | Requests/min | list mine | open walk | save walk | summary | create walk | complete walk | list district (scope=all) | report live district | report CSV district |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 10 | 1601 | 500 / 861 | 78 / 270 | 177 / 620 | 78 / 354 | 241 / 991 | 125 / 612 | 2197 / 2604 | 1587 / 3835 | 1385 / 3326 |
| 25 | 1446 | 1395 / 2384 | 256 / 735 | 520 / 1576 | 219 / 877 | 829 / 5665 | 466 / 1308 | 5762 / 8098 | 2415 / 8950 | 2073 / 8428 (1 err) |

Errors: 500 INTERNAL_ERROR.

At 25 users: longest block 4700 ms (10 blocked at once); top waits LCK_M_S 91 s, SOS_SCHEDULER_YIELD 62 s, CXCONSUMER 49 s; engine {"rssMb":959,"threads":59}; temp tables before/after 1/1, open transactions after 0.

### ColdFusion, before P8-14, completed walks edited (`acf-any/`)

ColdFusion Server 2023,0,25,330977; 30217 walks, 2205841 responses; 60 s per level; edits: any. District report alone: live p50 1419 ms, CSV p50 1065 ms.

| Users | Requests/min | list mine | open walk | save walk | summary | create walk | complete walk | list district (scope=all) | report live district | report CSV district |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 290 | 406 / 451 | 68 / 82 | 126 / 153 | 44 / 64 | 170 / 195 | 116 / 120 |  |  |  |
| 10 | 480 | 2145 / 3848 | 187 / 571 | 345 / 1008 | 105 / 290 | 292 / 932 | 256 / 1553 | 8081 / 9468 | 3787 / 9244 (3 err) | 2298 / 5925 (2 err) |
| 25 | 329 | 5284 / 10659 | 493 / 8361 | 950 / 7424 | 212 / 5276 | 878 / 6873 | 843 / 5275 | 18622 / 24084 | 4161 / 6198 (4 err) | 4546 / 8980 (4 err) |

Errors: 409 REPORT_POPULATION_CHANGED.

At 25 users: longest block 18 ms (1 blocked at once); top waits SOS_SCHEDULER_YIELD 193 s, CXCONSUMER 100 s, LATCH_EX 35 s; engine {"dockerStats":"869.7MiB / 15.72GiB|0.18%"}; temp tables before/after 1/1, open transactions after 0.

### ColdFusion, before P8-14, drafts only edited (`acf-drafts/`)

ColdFusion Server 2023,0,25,330977; 30241 walks, 2207593 responses; 60 s per level; edits: drafts. District report alone: live p50 1559 ms, CSV p50 1315 ms.

| Users | Requests/min | list mine | open walk | save walk | summary | create walk | complete walk | list district (scope=all) | report live district | report CSV district |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 10 | 475 | 2072 / 3463 | 169 / 569 | 262 / 573 | 75 / 757 | 277 / 787 | 265 / 337 | 7993 / 9642 | 2610 / 4196 | 1582 / 3333 |
| 25 | 449 | 4931 / 10254 | 392 / 1970 | 535 / 2447 | 174 / 883 | 708 / 946 | 570 / 1360 | 22229 / 24297 | 5924 / 9535 | 3319 / 5654 |

At 25 users: longest block 117 ms (1 blocked at once); top waits SOS_SCHEDULER_YIELD 43 s, CXCONSUMER 34 s, LATCH_EX 4 s; engine {"dockerStats":"893.5MiB / 15.72GiB|0.14%"}; temp tables before/after 1/1, open transactions after 0.

### ColdFusion, after P8-14, completed walks edited (`acf-after-p814-any/`)

ColdFusion Server 2023,0,25,330977; 30262 walks, 2209126 responses; 60 s per level; edits: any. District report alone: live p50 113 ms, CSV p50 96 ms.

| Users | Requests/min | list mine | open walk | save walk | summary | create walk | complete walk | list district (scope=all) | report live district | report CSV district |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 1372 | 52 / 67 | 26 / 32 | 54 / 63 | 29 / 33 | 80 / 91 | 43 / 49 |  |  |  |
| 10 | 2621 | 237 / 362 | 156 / 269 | 221 / 329 | 165 / 278 | 303 / 451 | 190 / 290 | 533 / 706 | 286 / 443 | 286 / 455 |
| 25 | 2629 | 530 / 1064 | 498 / 1081 | 519 / 1075 | 469 / 1062 | 760 / 987 | 553 / 1124 | 942 / 1323 | 734 / 999 | 729 / 1036 |

At 25 users: longest block 0 ms (0 blocked at once); top waits PREEMPTIVE_OS_AUTHENTICATIONOPS 14 s, PREEMPTIVE_OS_GENERICOPS 5 s, SOS_SCHEDULER_YIELD 3 s; engine {"dockerStats":"1.01GiB / 15.72GiB|4.19%"}; temp tables before/after 1/1, open transactions after 0.

### ColdFusion, after P8-14, drafts only edited (`acf-after-p814-drafts/`)

ColdFusion Server 2023,0,25,330977; 30362 walks, 2216426 responses; 60 s per level; edits: drafts. District report alone: live p50 133 ms, CSV p50 122 ms.

| Users | Requests/min | list mine | open walk | save walk | summary | create walk | complete walk | list district (scope=all) | report live district | report CSV district |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 10 | 2603 | 245 / 362 | 157 / 280 | 220 / 345 | 169 / 301 | 304 / 439 | 186 / 292 | 540 / 698 | 332 / 470 | 321 / 438 |
| 25 | 2568 | 530 / 1095 | 509 / 1093 | 494 / 1143 | 512 / 1008 | 801 / 1080 | 494 / 1158 | 991 / 1471 | 704 / 1088 | 689 / 1076 |

At 25 users: longest block 101 ms (2 blocked at once); top waits PREEMPTIVE_OS_AUTHENTICATIONOPS 14 s, PREEMPTIVE_OS_GENERICOPS 6 s, SOS_SCHEDULER_YIELD 5 s; engine {"dockerStats":"1.096GiB / 15.72GiB|0.19%"}; temp tables before/after 1/1, open transactions after 0.

### Lucee, after P8-14, completed walks edited (`lucee-after-p814-any/`)

Lucee 6.2.8.20; 30449 walks, 2222777 responses; 60 s per level; edits: any. District report alone: live p50 190 ms, CSV p50 192 ms.

| Users | Requests/min | list mine | open walk | save walk | summary | create walk | complete walk | list district (scope=all) | report live district | report CSV district |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 1609 | 45 / 63 | 19 / 24 | 50 / 61 | 23 / 29 | 89 / 140 | 39 / 51 |  |  |  |
| 10 | 4077 | 155 / 252 | 54 / 100 | 158 / 250 | 72 / 151 | 267 / 366 | 113 / 178 | 567 / 822 | 470 / 922 (3 err) | 528 / 1014 (1 err) |
| 25 | 3897 | 410 / 622 | 206 / 302 | 388 / 576 | 228 / 335 | 538 / 756 | 309 / 460 | 1240 / 1701 | 877 / 2100 (6 err) | 888 / 2034 (4 err) |

Errors: 409 REPORT_POPULATION_CHANGED.

At 25 users: longest block 181 ms (5 blocked at once); top waits LCK_M_S 49 s, SOS_SCHEDULER_YIELD 22 s, PREEMPTIVE_OS_FLUSHFILEBUFFERS 4 s; engine {"rssMb":724,"threads":61}; temp tables before/after 1/1, open transactions after 0.

### Lucee, after P8-14, drafts only edited (`lucee-after-p814-drafts/`)

Lucee 6.2.8.20; 30625 walks, 2235625 responses; 60 s per level; edits: drafts. District report alone: live p50 184 ms, CSV p50 186 ms.

| Users | Requests/min | list mine | open walk | save walk | summary | create walk | complete walk | list district (scope=all) | report live district | report CSV district |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 10 | 4395 | 165 / 254 | 51 / 97 | 147 / 221 | 64 / 146 | 250 / 349 | 113 / 203 | 549 / 746 | 368 / 644 | 374 / 628 |
| 25 | 4598 | 356 / 540 | 179 / 266 | 325 / 481 | 208 / 328 | 481 / 2154 | 286 / 424 | 1089 / 1481 | 697 / 1171 (1 err) | 641 / 1131 (4 err) |

Errors: 500 INTERNAL_ERROR.

At 25 users: longest block 5209 ms (13 blocked at once); top waits LCK_M_S 68 s, LCK_M_IX 38 s, SOS_SCHEDULER_YIELD 16 s; engine {"rssMb":1065,"threads":62}; temp tables before/after 1/1, open transactions after 0.

## What it found

* **P8-11 (corrected).** My Walks read the dimension values of every walk its filter matched to show
  500: 208,205 rows and a median of 1.6 s for a district walker, growing with every walk ever made.
  Now 3,796 rows and 0.9 s on the same data (`../defects/P8-11-*`).
* **P8-14 (corrected).** The canonical JSON writer cost ColdFusion several microseconds per Java call
  and made several per value. Every response paid it: a single walker's My Walks took 406 ms on
  ColdFusion (29 to 68 ms on Lucee), and the district's list 8 to 22 seconds under load. After the
  correction the same request takes about 50 ms on either engine, ColdFusion's throughput at one user
  rose from 292 to 1,372 requests a minute, and a district report alone from 1.4 s to 0.11 s.
* **Live district reports refuse rather than mix states (open, D14).** A report checks after reading
  that no walk in its population changed, and answers 409 `REPORT_POPULATION_CHANGED` after three
  changed attempts. Before P8-14, with reports taking seconds, 3 to 7 of every 6 to 10 live district
  reports were refused at 10 and 25 users while walkers edited completed walks (all six at 10 users
  on Lucee); with drafts only edited, none (and one CSV in 26). After P8-14: none of 232 on
  ColdFusion; on Lucee, whose throughput and so write rate are higher, 3 of 70 and 6 of 88 live
  reports, and 1 of 107 with drafts only edited (`docs/OPERATIONS.md` section 12 rounds this to "a few
  in twenty"; these are the counts). Frozen releases are unaffected (read in 13 to 511 ms).
* **Scans of the walk table (open, D8).** My Walks (`SELECT TOP 500 ... ORDER BY updated_at`) and the
  report's candidate selection read every walk in scope or of the version (clustered index scans).
  SQL Server suggests `icf.walk (version_id, status) INCLUDE (org_unit_id, row_version)`, `(version_id,
  org_unit_id, status) INCLUDE (row_version)` and `(org_unit_id, owner_user_id) INCLUDE (...)`. None
  is added: an index is a migration, and whether it is worth one is a question for the target.
* **The version row is read whole on every walk request (open, lower severity).** The most executed
  statement reads the instrument version including its ~218 KB compiled snapshot, about once per walk
  request (6,718 times in four minutes on ColdFusion, about 2 ms each in SQL Server), although the
  render model is cached by checksum. Reading the checksum first and the snapshot only on a cache miss
  would remove that transfer; left as is because it is a constant cost per request, not growth.
* **No leaks.** Temp tables, open transactions and tempdb are the same after every level as before
  it; nothing was left behind by a refused or retried report.
* **Backup and restore at scale** (`../operations/database-operations-at-scale.json`): a COPY_ONLY
  backup of the 2 GB database took 3.4 s, the restore to a separate database 3.9 s, CHECKDB was clean
  and the restored copy held exactly the source's 2,556,213 rows in 28 tables.

## Running it again

```bash
# An application in development mode on its own, migrated database -- never a production one.
ICFWALK_DB_NAME=icfwalk_perf ICFWALK_BASE_URL=<its site> node tests/perf/seed.mjs 30000
ICFWALK_DB_NAME=icfwalk_perf ICFWALK_BASE_URL=<its site> PERF_LEVELS=1,10,25 PERF_DURATION=60 \
  PERF_EDIT=any ICFWALK_EVIDENCE_DIR=<dir> node tests/perf/workload.mjs
```

`PERF_ENGINE_PID` (Lucee's JVM) or `PERF_ENGINE_CONTAINER` (ColdFusion's container) adds the engine's
memory to each sample.
