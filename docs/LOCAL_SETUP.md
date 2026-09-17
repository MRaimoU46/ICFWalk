# Local setup and deployment

ICFWalk targets Adobe ColdFusion 2023 and Microsoft SQL Server 2016 or later. This document covers
a clean local install, the verification runtime used when Adobe ColdFusion is not available, and
the production deployment shape. No credentials are stored in the repository; everything
deployment-specific comes from environment variables (see `.env.example`).

## Repository layout

| Path | Purpose |
| --- | --- |
| `app/` | ColdFusion web root. `Application.cfc` and the single entry point `index.cfm`. |
| `src/` | Application source outside the web root (mapped as `/icfwalk`). Controllers, HTTP, core services, instrument import, audit. |
| `tests/cfml/` | CFML test runner and specs (mapped as `/icfwalktests`). |
| `tests/node/` | Node test harness: package checks, reference snapshot, SQL script tests, and a driver for the CFML suite. |
| `scripts/` | Handoff validator, manifest refresh, reference snapshot compiler, schema apply, seed. |
| `database/` | Supplied SQL Server scripts (unchanged). |
| `config/` | Supplied instrument configuration (unchanged). |
| `tools/runtime/` | Local Docker SQL Server and Lucee/Jetty helpers. |

## Prerequisites

- Node.js 20+ (validator, tests, tooling). `npm install` fetches the single dev dependency (`mssql`).
- SQL Server 2016+ (any edition). For local work, Docker and `tools/runtime/mssql-up.sh`.
- Adobe ColdFusion 2023 for the real application server. For verification in environments without
  ColdFusion, `tools/runtime/lucee-up.sh` runs the same code on Lucee 6 (Java 11+ required).

## Clean install (local)

```bash
npm install
node scripts/validate-handoff.mjs             # package integrity (PKG-01)

tools/runtime/mssql-up.sh                     # SQL Server 2022 container, generates .runtime/mssql.env
cp .env.example .env                          # then set ICFWALK_DB_* from .runtime/mssql.env, a
                                              # 32+ char ICFWALK_MAINTENANCE_TOKEN, and
                                              # ICFWALK_MAINTENANCE_ENABLED=true / ICFWALK_TESTS_ENABLED=true
node scripts/db/apply-schema.mjs              # applies database/001_schema.sql then 002_alignment_patch.sql

tools/runtime/lucee-up.sh                     # or deploy app/ to ColdFusion 2023 (below)
node scripts/seed-instrument.mjs              # imports config/instrument-config.json as a DRAFT version
npm test                                      # all Node tests + the CFML suite through the running app
```

`.env`, `.runtime/`, and `app/WEB-INF/` are git-ignored.

## Adobe ColdFusion 2023 deployment

1. Point the web server site (IIS or Apache with the ColdFusion connector) at `app/`. Only
   `index.cfm` is ever served through CFML; `Application.cfc` rejects any other template. Configure
   the connector so `/index.cfm/api/...` requests reach ColdFusion with `PATH_INFO` (ColdFusion's
   IIS connector does this by default). Optional URL rewriting from `/api/*` to `/index.cfm/api/*`
   is a web-server concern.
2. Either create a datasource named by `ICFWALK_DATASOURCE` in the ColdFusion Administrator
   (MS SQL Server driver, least-privilege login), or set `ICFWALK_DB_HOST/PORT/NAME/USER/PASSWORD`
   and `Application.cfc` defines the datasource itself.
3. Set `ICFWALK_ENVIRONMENT` explicitly (`production` is the default and fails closed).
4. Provide environment variables to the ColdFusion service (system environment, or
   `ICFWALK_ENV_FILE` pointing at a file readable only by the service account).
5. Apply `database/001_schema.sql` then `database/002_alignment_patch.sql` with SQL Server tooling
   (`sqlcmd`, SSMS) or `node scripts/db/apply-schema.mjs`.
6. Seed the instrument: enable maintenance temporarily (`ICFWALK_MAINTENANCE_ENABLED=true`, a
   32+ character `ICFWALK_MAINTENANCE_TOKEN`), call the import endpoint from the server itself
   (`node scripts/seed-instrument.mjs` or `curl` against `http://127.0.0.1/index.cfm/api/maintenance/instrument/import`),
   then disable maintenance again. Phase 6 adds the authenticated administration UI for the same
   import/publish operations.
7. The seeded version is a DRAFT. Publishing (Phase 6) compiles and freezes the snapshot.

### Database login permissions

The application login needs SELECT/INSERT/UPDATE/DELETE on the `icf` schema. Schema creation and
migrations run under a separate administrative login. `walk_revision` and `audit_event` are
append-only for the application (no DELETE grants needed).

## Verification runtime (Lucee 6 under Jetty)

`tools/runtime/lucee-up.sh` downloads `lucee-<version>-light.jar`, `jetty-runner`, and the
Microsoft JDBC driver from Maven Central into `.runtime/jars`, generates `app/WEB-INF/`, and starts
Jetty on `ICFWALK_PORT` (default 8888). The application detects the engine at startup and builds the
datasource with the Microsoft JDBC driver on Lucee or the bundled MSSQLServer driver on Adobe
ColdFusion. Stop it with `tools/runtime/lucee-down.sh`. Logs: `.runtime/lucee.log` (Jetty) and
`.runtime/lucee-server/lucee-server/context/logs/icfwalk.log` (application log lines).

This runtime exists to execute the CFML test suite where Adobe ColdFusion cannot be installed. It is
not a supported production platform for ICFWalk.

## Tests

| Command | What it runs |
| --- | --- |
| `npm run validate:handoff` | Supplied handoff validator (PKG-01). |
| `npm run test:package` | PKG-02..05, canonical JSON vectors, reference snapshot golden, schema/DAO contract. No database needed. |
| `npm run test:db` | DB-01..03 against a disposable SQL Server database (needs `ICFWALK_DB_*` admin credentials). |
| `npm run test:cfml` | Health/guard checks, the CFML suite via `/api/maintenance/tests/run` (unit specs plus DB-04..09), and the idempotent seed. Needs the running app, `ICFWALK_TESTS_ENABLED=true`, and the maintenance token. |
| `npm test` | Everything above. |

The CFML suite can also be triggered directly:

```bash
curl -sS -X POST -H "X-ICFWalk-Maintenance-Token: $ICFWALK_MAINTENANCE_TOKEN" \
  http://127.0.0.1:8888/index.cfm/api/maintenance/tests/run
```

## Backups and migrations

Back up before every migration. `001_schema.sql` refuses to run against a database that already
has `icf` tables; changes to an existing installation ship as new, reviewed, transactional scripts
(`database/00N_*.sql`), never by editing the supplied scripts. `002_alignment_patch.sql` is
idempotent and safe to re-run.
