# Phase 5 final correction pass: what was executed, and what was not

This file records exactly which runtimes were available for this pass and which verification items
could not be run in it. It adds to the earlier evidence and replaces none of it.

## Available and used

| Component | Version | Used for |
| --- | --- | --- |
| Node | 22.22.2 | the full Node/HTTP/Playwright suite in both profiles, the handoff validator, the summary oracle, `node --check` |
| Playwright | 1.56.1, pre-installed Chromium (`/opt/pw-browsers`) | all 11 export regressions, and the probe that established how Chromium surfaces each kind of body failure |
| Lucee | 6.2.8.20 on Jetty 9.4.58 | compiling all 67 CFML components, and running the two `WalkSummaryCoherenceTest` cases that need no database, red and green |

## Not available, and why

**SQL Server.** `tools/runtime/mssql-up.sh` needs Docker, which is not present. A native install
was attempted again this pass: `packages.microsoft.com` serves the package index, but the
`mssql-server` package redirects to `pmc-geofence.trafficmanager.net`, and this session's egress
policy answers that host with HTTP 403 (`connect_rejected` in the proxy's own failure log). That is
an organization policy denial. It was reported rather than worked around.

**Adobe ColdFusion 2023.** Not available, not used, and no claim about it is made. It remains a
target-platform verification item.

**SQL Server 2016.** Not available, not used. It remains a target-platform verification item.

## What that means for this pass

No application could be started against a database, so everything that drives the running
application skipped. Of the 12 verification items the task lists:

**Executed**

1. The corrected `browser-export.test.mjs` suite -- 11/11 pass.
2. The no-mail suite, optional profile -- 5 cases, 4 pass, 1 explicit skip.
3. The no-mail suite with `ICFWALK_REQUIRE_APP=1` -- 5 cases, 4 pass, **1 fail**, which is the
   point: an application that was required and is absent fails the run instead of passing.
4. `npm run validate:handoff` -- ok, 51 checks, 0 errors.
5. `npm run test:package` -- 18/18 pass.
6. `npm run test:summary` -- 20 cases, 4 pass, 16 skipped (the skipped ones need the application).
7. `node --check` over every `.js` and `.mjs` -- 34 files, 0 failures.
8. `npm run oracle:summary` -- 10/10 vectors accounted for, 0 unexplained differences.
9. The targeted `WalkSummaryCoherenceTest` -- **partly**: 2 of its 4 cases run without a database
   and both pass (and one of them fails, as it should, against the interceptor as committed at
   30f46be). The two database-backed cases did not run.

**Not executed**

10. The complete CFML suite. It is driven through `POST /api/maintenance/tests/run`, which needs
    the application and a database. 170 cases are declared and none was executed. This includes
    `testASummaryExportCannotStraddleAConcurrentSave`, the regression the Defect 2 seam correction
    exists to serve.
11. The complete Node, HTTP and Playwright suite as a *green* run. It was executed -- 155 cases --
    but 121 of them skipped for want of the application, and under the required-application profile
    the run fails by design. Only 33 cases actually executed and passed.
12. Migration apply and reapply on a clean SQL Server database. No database. `database/` is
    byte-identical to the baseline in this pass, so nothing about it changed, but "unchanged" is not
    "re-verified" and this is not presented as one.

## The freeze gate is not satisfied by this run

The task's gate is a complete run with zero failures and zero skips under
`ICFWALK_REQUIRE_APP=1 npm test`. This environment produces 155 cases, 33 pass, 1 fail, 121 skipped.
It is not a passing gate run and is not offered as one. Compilation, declared case counts and
inspected transcripts are recorded as what they are and are not counted as executed passes.

What an environment with SQL Server should run, in order:

```bash
tools/runtime/mssql-up.sh
tools/runtime/lucee-up.sh
ICFWALK_REQUIRE_APP=1 npm test
```

Expected there: 155 Node/HTTP/Playwright cases and 170 CFML cases. The Node total is the 151 of the
previous pass plus the 4 new export regressions; the CFML total is the 169 of the previous pass plus
the 1 new seam case.
