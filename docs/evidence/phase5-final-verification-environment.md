# Phase 5 final verification: environment

Full live release-verification gate for the corrected Phase 5 candidate.

| Item | Value |
| --- | --- |
| Branch | `claude/icfwalk-phase-5-corrections-nunm7i` |
| Starting commit | `e63dfd9197786c4ef61ad0281628aa6efb8741e1` |
| Frozen Phase 0-4 baseline | `d8f3736debfb292ff274211b91e58563edd5d09c` (ancestor) |
| Phase 5 implementation | `2522e79` (ancestor) |
| First correction candidate | `30f46be902b0ed5516e0434c8937fcdc6ed579ad` (ancestor) |

## Versions as executed

| Component | Version |
| --- | --- |
| Operating system | Ubuntu 24.04.4 LTS (kernel 6.18.44-fc-v37, x86_64) |
| Node | v22.22.2 |
| npm | 10.9.7 |
| Java | 21.0.10 2026-01-20 (OpenJDK 21.0.10+7-Ubuntu-124.04) |
| Lucee | 6.2.8.20 (lucee-light, under jetty-runner 9.4.58.v20250814) |
| Microsoft JDBC driver | 12.10.2.jre11 |
| SQL Server | 16.0.4295.3 Developer Edition (64-bit), RTM-CU27, Linux |
| SQL Server image | `mcr.microsoft.com/mssql/server:2022-latest` @ `sha256:4402d880dd4c34bfa7d8705e56a86cd6c88da80a1f6bbbe741f999e76264a090` |
| Docker | Docker version 29.3.1 |
| Playwright | 1.56.1 (from the checked-in package-lock.json) |
| Chromium | 141.0.7390.37 (`/opt/pw-browsers/chromium-1194/chrome-linux/chrome`) |
| axe-core | 4.13.0 |
| mssql (Node driver) | 12.7.2 |

Dependencies were installed with `npm ci` against the checked-in `package-lock.json`. No dependency
was added, upgraded, or removed, and the lockfile is byte-identical to the committed one.

## Runtime configuration

```
ICFWALK_ENVIRONMENT=development
ICFWALK_SSO_MODE=development          ICFWALK_DEV_IDENTITY_ENABLED=true
ICFWALK_MAINTENANCE_ENABLED=true      ICFWALK_MAINTENANCE_TOKEN=<44 random characters, not recorded>
ICFWALK_TESTS_ENABLED=true            ICFWALK_COOKIE_SECURE=false
ICFWALK_DB_HOST=127.0.0.1             ICFWALK_DB_NAME=icfwalk_dev
ICFWALK_DB_TRUST_SERVER_CERT=true     (local container certificate only)
ICFWALK_REQUIRE_APP=1                 (release run)
```

`.env` is git-ignored and is not part of this evidence set. The development identity stub and the
maintenance/test routes are enabled only in this development environment; `Application.cfc` refuses
to start with either in production.

## Target-platform limitation

The production target is **Adobe ColdFusion 2023 with SQL Server 2016 or later**. Neither Adobe
ColdFusion 2023 nor SQL Server 2016 is installable in this container, so:

- All CFML execution in this run is on **Lucee 6.2.8.20**, the repository's documented verification
  runtime (`tools/runtime/lucee-up.sh`, `docs/LOCAL_SETUP.md`). Adobe ColdFusion 2023 remains
  **unverified**.
- All SQL execution is against **SQL Server 2022**. SQL Server 2016 remains **unverified**.

No target-platform check could be run separately, and this limitation is unchanged from every prior
phase. It is recorded here and in `BUILD_STATUS.md` rather than being presented as verified.

## Preflight gates confirmed before testing

| Gate | Result |
| --- | --- |
| Application reachable | `http://127.0.0.1:8888/index.cfm/api/health` -> HTTP 200 |
| Health endpoint | `{"status":"ok","checks":{"database":"ok","schema":"present"},"engine":"Lucee 6.2.8.20","environment":"development"}` |
| Maintenance without token | HTTP 404 `NOT_FOUND` (refused) |
| Maintenance with a wrong token | HTTP 404 `NOT_FOUND` (refused) |
| Maintenance with the real token | accepted (instrument seed and test runner both executed) |
| Shell without a development identity header | HTTP 401 |
| Test execution enabled | `/api/maintenance/tests/run` executed 170 CFML cases |
| Application-dependent skips | none: the release run was executed with `ICFWALK_REQUIRE_APP=1` and reports `skipped 0` |
