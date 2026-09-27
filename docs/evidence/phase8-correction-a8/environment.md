# Phase 8 correction A8: environment

Everything below is as executed in this session's container. No production credential, real person,
narrative or secret is recorded in this directory: every person, school and walk is synthetic, the
generated passwords, tokens and secrets were never printed, and the workload evidence keeps no cookie,
CSRF token, note text, name or email address (`a8-03/FINDINGS.md`, section 1).

## Host

Linux 6.18.44 x86_64, Ubuntu 24.04.4 LTS, 4 vCPU (Intel Xeon @ 2.80 GHz; the Phase 8 host reported
2.10 GHz), 15 GB RAM as `free -g` reports it; Docker 29.3.1 (client and daemon; the daemon was started
in the session); OpenJDK 21.0.10; Node v22.22.2, npm 10.9.7; git 2.43.0; Python 3.11.15; UnZip 6.00.

The host rebooted once, between the fifth Lucee drafts run on the correction commit (01:52 UTC) and
the Lucee "any" run (10:30 UTC). Docker's data survived: the Docker daemon was started again, SQL
Server's container restarted with its databases (the performance database included, after recovery),
and the performance engine was started again from the same clean commit. The gate and the operations
ran afterwards on brand-new containers and databases.

## Engines

| Engine | How it ran | Datasource |
| --- | --- | --- |
| **Adobe ColdFusion 2023 Update 25** (`ColdFusion Server 2023,0,25,330977`), Developer edition | Adobe's image `adobecoldfusion/coldfusion2023@sha256:e42bbf07745ebd4d8c23d6679738ac13e264218618093bc3689ebfaf8966f30e` (the Phase 8 digest), host network, built-in web server on port 8500 with the rewrite front door, through `tools/runtime/acf-up.sh` | Administrator-defined "Other" datasource, Microsoft JDBC driver 12.10.2.jre11, long text retrieval on |
| **Lucee 6.2.8.20** (verification runtime, not a supported production platform) | `lucee-light` jar under jetty-runner 9.4.58, `-Xmx1g`, through `tools/runtime/lucee-up.sh`; the performance engine and the operations' own engines as scratch copies of the clean tree | Application-defined, Microsoft JDBC driver 12.10.2.jre11 |

The jars `lucee-up.sh` downloads, by SHA-256 (the Phase 8 records name their versions, not their
hashes): `lucee-light.jar` (6.2.8.20)
`e004579cf48a6d0f4d527429ad19d7543070803d3454eacb5e8efe674419be80`, `jetty-runner.jar` (9.4.58)
`b692f66bb7a53bfa739b7eb466dc2bf75bddd5bfa0e7d425cd2a0434233987c2`, `mssql-jdbc.jar` (12.10.2.jre11)
`dbf27d0d7ff85f133bbc80b0282ec2cd4d1fa1f0954033dd6bbd68612a1c0a6e`. Maven Central answered 429 for the
driver; `lucee-up.sh` took it from its Google mirror of Maven Central instead, as it is written to.

## Database

SQL Server 2022 16.0.4295.3 (Developer Edition, 64-bit) in
`mcr.microsoft.com/mssql/server@sha256:4402d880dd4c34bfa7d8705e56a86cd6c88da80a1f6bbbe741f999e76264a090`
(the digest every earlier gate recorded). Until the gate, one container held the development database,
the ColdFusion development database and the performance database (`icfwalk_perf`: the 30,000-walk seed
and the walks the runs created). The gate replaced the container and created brand-new databases:
`icfwalk_dev` (Lucee) and `icfwalk_acf_gate` (ColdFusion), each migrated 001 to 007 with every
re-application and 001 refused. SQL Server's `system_health` record of every deadlock of the session up
to then was saved first (`a8-03/sql-server-deadlock-record/`).

## Test harness

`node --test`; Playwright 1.56.1 with Chromium 141.0.7390.37 (the pre-installed browser matches the
lock file's Playwright); axe-core 4.13.0; mssql 12.7.2; all from `package-lock.json` by `npm ci`.

## Configuration (no secrets)

As in Phase 8. Development profile for the suites and the workload: `ICFWALK_ENVIRONMENT=development`,
the identity stub on, maintenance and the CFML test runner on (loopback, generated token), cookies
without `Secure` over plain HTTP. Production profile for `tests/ops/production-profile.test.mjs` and the
new `tests/ops/readiness-schema-missing.test.mjs`: `ICFWALK_ENVIRONMENT=production`,
`ICFWALK_SSO_MODE=header` with synthetic header names, trusted proxy `127.0.0.1`, a generated shared
secret, `ICFWALK_COOKIE_SECURE=true`, maintenance and the test runner off, and a runtime SQL login
holding `db_datareader` and `db_datawriter` only, each file generated for the run and removed.
