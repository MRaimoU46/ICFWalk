# Phase 6 publish-foundation correction: environment

Live verification environment for the corrected Phase 6 publish foundation.

| Item | Value |
| --- | --- |
| Branch | `claude/icfwalk-phase-6-admin-publish` |
| Starting commit (the audited candidate) | `5b243ed3d5a27142e65cdfbba8fc113ed65853e1` |
| Frozen Phase 5 baseline | `e55ec08af5b8622db5823b6e353423b891918549` (ancestor, verified) |
| Phase 5 baseline tree | `403d964ce250d6b089419a34ac29b91fa0915a38` (verified) |

## Versions as executed

| Component | Version |
| --- | --- |
| Operating system | Ubuntu 24.04.4 LTS (kernel 6.18.44-fc-v37, x86_64) |
| Node | v22.22.2 |
| npm | 10.9.7 |
| Java | 21.0.10 2026-01-20 (OpenJDK 21.0.10+7-Ubuntu-124.04) |
| Lucee | 6.2.8.20 (lucee-light, under jetty-runner 9.4.58.v20250814) |
| Microsoft JDBC driver | 12.10.2.jre11 |
| SQL Server | 16.0.4295.3 Developer Edition (64-bit), RTM, Linux |
| SQL Server image | `mcr.microsoft.com/mssql/server:2022-latest` @ `sha256:4402d880dd4c34bfa7d8705e56a86cd6c88da80a1f6bbbe741f999e76264a090` |
| Docker | Docker version 29.3.1, build c2be9cc |
| Playwright | 1.56.1 (from the checked-in `package-lock.json`) |
| Chromium | 141.0.7390.37 (`/opt/pw-browsers/chromium-1194/chrome-linux/chrome`) |
| axe-core | 4.13.0 |
| mssql (Node driver) | 12.7.2 |

Dependencies were installed from the checked-in `package-lock.json`. No dependency was added,
upgraded, or removed, and the lockfile is byte-identical to the committed one.

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
to start with either in production, and `ConfigLoader` forces `testsEnabled` to false there.

## Target-platform limitation (unchanged from every prior phase)

The production target is **Adobe ColdFusion 2023 with SQL Server 2016 or later**. Neither Adobe
ColdFusion 2023 nor SQL Server 2016 is installable in this container, so:

- All CFML execution in this run is on **Lucee 6.2.8.20**, the repository's documented verification
  runtime (`tools/runtime/lucee-up.sh`, `docs/LOCAL_SETUP.md`). Adobe ColdFusion 2023 remains
  **unverified**.
- All SQL execution is against **SQL Server 2022**. SQL Server 2016 remains **unverified**.

Migration `006_version_scoped_dimensions.sql` was written to SQL Server 2016 syntax and behavior and
is checked for it statically (`tests/node/schema-contract.test.mjs` refuses `STRING_AGG`,
`JSON_OBJECT`, `GENERATED ALWAYS`, `GREATEST`, `LEAST` and `CREATE OR ALTER`), but *running* it on
SQL Server 2016 was not possible here and is not claimed.

## Preflight gates confirmed before testing

| Gate | Result |
| --- | --- |
| Branch | `claude/icfwalk-phase-6-admin-publish` |
| HEAD at start | `5b243ed3d5a27142e65cdfbba8fc113ed65853e1` (exact match) |
| Working tree at start | clean (`git status --short` empty, including untracked) |
| Phase 5 baseline ancestry | `git merge-base --is-ancestor e55ec08… HEAD` → exit 0 |
| Phase 5 baseline tree | `403d964ce250d6b089419a34ac29b91fa0915a38` (exact match) |
| Application reachable | `http://127.0.0.1:8888/index.cfm/api/health` → HTTP 200 |
| Health endpoint | `{"status":"ok","checks":{"database":"ok","schema":"present"},"engine":"Lucee 6.2.8.20","environment":"development"}` |
| Application-dependent skips | none: the release run sets `ICFWALK_REQUIRE_APP=1` and reports `skipped 0` |

## Repository-permission item (unresolved, and separate from the code and test result)

The local `phase-5-freeze` tag **does not exist**, locally or on the remote:

```
$ git tag -l
(no output)
$ git ls-remote --tags origin
(no output)
```

So there was no tag to verify against `e55ec08af5b8622db5823b6e353423b891918549` and no tag to push.
Per the correction's own constraints the tag was **not** created or recreated here; the Phase 5
baseline commit itself is verified as an ancestor of this work and its tree hash matches. Creating
and pushing `phase-5-freeze` at `e55ec08af5b8622db5823b6e353423b891918549` remains an open
repository action for an authorized operator. This is recorded here, outside the code and test
report, because it is a repository-state item and not a verification result.
