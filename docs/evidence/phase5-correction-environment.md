# Phase 5 correction: verification environment and what it could not verify

This file records exactly which environments the Phase 5 correction was verified in, so a fresh
audit does not have to infer it from a totals table. It does not replace any earlier phase's
evidence.

## What was available

| Component | Version | Used for |
| --- | --- | --- |
| Node | 22.22.2 | the full Node/HTTP/Playwright suite, the handoff validator, the summary oracle, `node --check` |
| Playwright | 1.56.1, pre-installed Chromium (`/opt/pw-browsers`) | the new deterministic export regressions |
| Lucee | 6.2.8.20 on Jetty 9.4.58 | compiling every CFML component, and running the one source-level CFML case that needs no database |

## What was not available, and why

**SQL Server was not available.** The repository's normal local stack
(`tools/runtime/mssql-up.sh`) needs Docker, and Docker is not present in this environment. A native
install was attempted instead: `packages.microsoft.com` served the package index, but the
`mssql-server` package itself redirects to `pmc-geofence.trafficmanager.net`, and this session's
egress policy answered that host with HTTP 403. That is an organization policy denial, not a
transient failure, and it was reported rather than worked around.

**Adobe ColdFusion 2023 was not available and was not used.** No claim of CF2023 verification is
made anywhere in this correction. The CF2023 verification items already listed in `BUILD_STATUS.md`
remain outstanding and are unchanged by this work.

**SQL Server 2016 was not available and was not used.** The frozen Phase 5 evidence records a run
on SQL Server 2022; this correction adds no SQL Server run of any version.

## What follows from that

The application could not be started against a database, so every test that needs a running
application skipped. That is 122 of the 151 Node/HTTP/Playwright cases, and it includes:

- the whole CFML suite (driven through `POST /api/maintenance/tests/run`), and therefore
  **both database-backed cases of the new `WalkSummaryCoherenceTest`**, including the concurrency
  regression itself;
- the existing Phase 5 browser suite (`browser-email.test.mjs`), the Phase 4 persistence suite, the
  HTTP authorization suites, the live summary formatter parity run, and `vectors:summary:check`;
- the live half of the no-mail gate, which now reports as an explicit skip rather than a pass (that
  is the Defect 3 correction working).

A Lucee instance *was* started without a database, purely to compile CFML. All 67 components in
`src/` and `tests/cfml/` compiled with 0 failures, which covers the modified `WalkService.cfc` and
the new `WalkSummaryCoherenceTest.cfc`. Compiling is not running, and this file does not present it
as running.

## The gap an audit should focus on

The HIGH-severity defect's deterministic regression --
`WalkSummaryCoherenceTest.testASummaryExportCannotStraddleAConcurrentSave` -- **has not been
executed**. It is written, it compiles, and the shared-lock invariant it depends on is asserted
against the source by `testEveryMutationPathTakesTheSameWalkLock` (which does run, and which fails
against the unfixed `summary()`); but the interleaving it forces has not been observed on a real
SQL Server. Re-running it is the first thing an environment with SQL Server should do:

```
tools/runtime/mssql-up.sh
tools/runtime/lucee-up.sh
ICFWALK_REQUIRE_APP=1 npm test
```

Expected there: 151 Node/HTTP/Playwright cases and 169 CFML cases, with the CFML total made up of
the 166 recorded in `docs/evidence/phase5-npm-test.txt` plus the 3 in the new spec.
