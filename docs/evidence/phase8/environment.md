# Phase 8 environment

Everything below is as executed in this session's container. No production credential, real person,
narrative or secret is recorded anywhere in this directory: every person, school and walk is
synthetic, and the generated passwords, tokens and secrets are never printed (transcripts redact
cookie values; the scripts that generate secrets keep them in memory or in files outside the
repository with mode 0600).

## Host

Linux 6.18.44 x86_64, Ubuntu 24.04.4 LTS, 4 vCPU (Intel Xeon @ 2.10 GHz), 16 GB RAM; Docker 29.3.1;
OpenJDK 21.0.10; Node v22.22.2, npm 10.9.7.

## Engines

| Engine | How it ran | Datasource |
| --- | --- | --- |
| **Adobe ColdFusion 2023 Update 25** (`ColdFusion Server 2023,0,25,330977`), Developer edition | Adobe's image `adobecoldfusion/coldfusion2023@sha256:e42bbf07745ebd4d8c23d6679738ac13e264218618093bc3689ebfaf8966f30e`, host network, built-in web server (Tomcat) on port 8500 with the rewrite front door, through `tools/runtime/acf-up.sh` | Administrator-defined "Other" datasource, Microsoft JDBC driver 12.10.2.jre11, `disable_clob = false` (long text retrieval on) |
| **Lucee 6.2.8.20** (verification runtime, not a supported production platform) | `lucee-light` jar under jetty-runner 9.4.58, through `tools/runtime/lucee-up.sh`, `LUCEE_REQUESTTIMEOUT=600` | Application-defined, Microsoft JDBC driver 12.10.2.jre11 |

## Database

SQL Server 2022 16.0.4295.3 (Developer Edition, 64-bit) in `mcr.microsoft.com/mssql/server@sha256:4402d880dd4c34bfa7d8705e56a86cd6c88da80a1f6bbbe741f999e76264a090`
(the digest the frozen gate recorded). The final gate replaced the container and created brand-new
databases: `icfwalk_dev` (Lucee) and `icfwalk_acf_gate` (ColdFusion), each migrated 001 to 007 with
every re-application and 001 refused.

## Test harness

`node --test`; Playwright 1.56.1 with Chromium 141.0.7390.37; axe-core 4.13.0; mssql 12.7.2; all from
`package-lock.json` by `npm ci` (gate step 3). Docker reports the ColdFusion container "unhealthy"
throughout: the image's own health check requests `/`, which this application answers 401 (sign-in
required); the application's `/index.cfm/api/health` answered `ok` on every run.

## Configuration (no secrets)

Development profile for the suites: `ICFWALK_ENVIRONMENT=development`, the identity stub on,
maintenance and the CFML test runner on (loopback, token required), cookies without `Secure` over
plain HTTP. Production profile (`tests/ops/production-profile.test.mjs`, its own file per run):
`ICFWALK_ENVIRONMENT=production`, `ICFWALK_SSO_MODE=header` with synthetic header names, trusted
proxy `127.0.0.1`, a generated shared secret, auto-provisioning off, `ICFWALK_COOKIE_SECURE=true`,
maintenance on only for the bootstrap, the test runner requested and refused, and a runtime SQL login
holding `db_datareader` and `db_datawriter` only.

## What was not run

See `README.md`, "Not performed here, and why": ColdFusion's own SQL Server driver and IIS or Apache
with the connector, SQL Server 2016, connector request limits, Microsoft Excel, a real screen reader,
the SSO gateway and TLS, and performance acceptance.
