# Phase 6 publish-foundation second correction: environment

Live verification environment for the second correction of the Phase 6 publish foundation.

| Item | Value |
| --- | --- |
| Branch | `claude/icfwalk-phase-6-admin-publish` |
| Starting commit (the audited candidate) | `332f89f929ff5a9f1e81fe5273c830698fdc80af` |
| Frozen Phase 5 baseline | `e55ec08af5b8622db5823b6e353423b891918549` (ancestor, verified) |
| First correction commit (the audited candidate's parent) | `5b243ed3d5a27142e65cdfbba8fc113ed65853e1` |

## Versions as executed

| Component | Version |
| --- | --- |
| Operating system | Ubuntu 24.04.4 LTS (kernel 6.18.44-fc-v37, x86_64) |
| Node | v22.22.2 |
| npm | 10.9.7 |
| Java | OpenJDK 21.0.10 2026-01-20 (build 21.0.10+7-Ubuntu-124.04) |
| Lucee | 6.2.8.20 (lucee-light, under jetty-runner 9.4.58.v20250814) |
| Microsoft JDBC driver | 12.10.2.jre11 |
| SQL Server | 16.0.4295.3 Developer Edition (64-bit) |
| SQL Server image | `mcr.microsoft.com/mssql/server:2022-latest` @ `sha256:4402d880dd4c34bfa7d8705e56a86cd6c88da80a1f6bbbe741f999e76264a090` |
| Docker | Docker version 29.3.1, build c2be9cc |
| Playwright | 1.56.1 (from the checked-in `package-lock.json`) |
| Chromium | 141.0.7390.37 (`/opt/pw-browsers/chromium-1194/chrome-linux/chrome`) |
| axe-core | 4.13.0 |
| mssql (Node driver) | 12.7.2 |

Dependencies were installed with `npm ci` from the checked-in `package-lock.json`. No dependency was
added, upgraded or removed, and the lockfile is byte-identical to the committed one.

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

## Database state for the release run

The development database was dropped and recreated before the final gate, then taken through the
documented setup path, so the gate ran against a database whose whole history is known:

```
001_schema.sql .. 005_org_unit_dimension_map.sql   applied in order
006_version_scoped_dimensions.sql                  applied once
    legacy_membership_backfill_state  = COMPLETED
    legacy_membership_backfill_ran_now = 1
node scripts/seed-instrument.mjs                   imports the aligned prototype as a DRAFT
```

This matters for one of the required cases: because the database goes Phase 5 schema → `006` → data,
the `Migration006LifecycleTest` scenario (publish V1, prime the caches, import V2 with a new value,
re-apply `006`) runs on a database that really did come through the one-time transition, not on one
that was constructed to look like it had.

## Target-platform limitation (unchanged from every prior phase)

The production target is **Adobe ColdFusion 2023 with SQL Server 2016 or later**. Neither is
installable in this container, so:

- All CFML execution in this run is on **Lucee 6.2.8.20**, the repository's documented verification
  runtime (`tools/runtime/lucee-up.sh`, `docs/LOCAL_SETUP.md`). Adobe ColdFusion 2023 remains
  **unverified**.
- All SQL execution is against **SQL Server 2022**. SQL Server 2016 remains **unverified**.

Migration `006` is written to SQL Server 2016 syntax and behaviour and is checked for it statically
(`tests/node/schema-contract.test.mjs` refuses `STRING_AGG`, `JSON_OBJECT`, `GENERATED ALWAYS`,
`GREATEST`, `LEAST` and `CREATE OR ALTER`). The constructs this correction adds to it -- a plain
`CREATE TABLE` with a composite primary key and a `CHECK` constraint, `OBJECT_ID`/`COL_LENGTH`
catalog probes, `sp_executesql`, `;THROW` with a composed `nvarchar` message, and
`INSERT ... SELECT` -- are all SQL Server 2016 constructs. *Running* it on SQL Server 2016 was not
possible here and is not claimed.

The detection queries in `database/README.md` use `JSON_VALUE`, `ISJSON` and `TRY_CONVERT`, all
available from SQL Server 2016. They are read-only and are not executed by the migration.

## Preflight gates confirmed before testing

| Gate | Result |
| --- | --- |
| Branch | `claude/icfwalk-phase-6-admin-publish` |
| HEAD at start | `332f89f929ff5a9f1e81fe5273c830698fdc80af` (the audited candidate, exact match) |
| Commits after the audited candidate | none |
| Working tree at start | clean (`git status --short` empty, including untracked) |
| Phase 5 baseline ancestry | `git merge-base --is-ancestor e55ec08… HEAD` → exit 0 |
| Application reachable | `http://127.0.0.1:8888/index.cfm/api/health` → HTTP 200 |
| Health endpoint | `{"status":"ok","checks":{"database":"ok","schema":"present"},"engine":"Lucee 6.2.8.20","environment":"development"}` |
| Application-dependent skips | none: the release run sets `ICFWALK_REQUIRE_APP=1` and reports `skipped 0` |

### One starting-state discrepancy, resolved before any edit

The container's checkout was **stale**: the local branch pointed at
`5b243ed3d5a27142e65cdfbba8fc113ed65853e1` (the first correction's parent) while
`origin/claude/icfwalk-phase-6-admin-publish` was at the audited
`332f89f929ff5a9f1e81fe5273c830698fdc80af`. The working tree was clean and `332f89f` had `5b243ed`
as its parent, so this was resolved with a plain fast-forward to the published remote tip
(`git merge --ff-only origin/claude/icfwalk-phase-6-admin-publish`). Nothing was reset, discarded or
force-checked-out, and no commit was rewritten. HEAD was then verified to be exactly the audited
candidate with no commits after it.

## Repository-permission item (unresolved, and separate from the code and test result)

The local `phase-5-freeze` tag **does not exist**, locally or on the remote:

```
$ git tag -l
(no output)
$ git ls-remote --tags origin
(no output)
```

There was no tag to verify against `e55ec08af5b8622db5823b6e353423b891918549` and no tag to push.
Per this correction's own constraints the tag was **not** created, moved or force-pushed here; the
Phase 5 baseline commit itself is verified as an ancestor of this work. Creating and pushing
`phase-5-freeze` at `e55ec08af5b8622db5823b6e353423b891918549` remains an open repository action for
an authorized operator. This is recorded here, outside the code and test report, because it is a
repository-state item and not a verification result.

## The release gate, as executed

```
ICFWALK_REQUIRE_APP=1 npm test
# tests 174 / pass 174 / fail 0 / cancelled 0 / skipped 0 / todo 0        exit 0
engine=Lucee 6.2.8.20 passed=330 failed=0 skipped=0 ms=274011 parts=3
```

Node / HTTP / Playwright: **174 passed, 0 failed, 0 skipped**.
CFML, live in-run: **330 passed, 0 failed, 0 skipped**.

The CFML suite is requested in three deterministic parts. That is not a reduction in what runs:
`tests/node/cfml-suite.test.mjs` sums the parts, refuses a spec that appears in more than one, and
asserts that the set of specs that ran equals the set of `*Test.cfc` files on disk. It exists
because the whole suite in one request outgrew Node's five-minute response-header timeout once it
reached 330 cases -- the first full run of this correction failed as `fetch failed` at 300.7
seconds, and the abort skipped every spec's `afterAll`, leaving a fixture version behind that then
failed an unrelated later test. Lucee was already configured for the long request
(`LUCEE_REQUESTTIMEOUT=600`); the client never had the same allowance.
