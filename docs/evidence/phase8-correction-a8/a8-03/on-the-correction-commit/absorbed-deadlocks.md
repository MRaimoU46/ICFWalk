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
