# ICFWalk operations runbook

This is the operator's document: how ICFWalk is installed, configured, released, rolled back,
migrated, backed up, restored, monitored and repaired, and what to do in an incident. It describes
the system as built and verified in Phase 8. Where a step has not been exercised on the production
platform it says so, and `docs/VERIFICATION_CHECKLISTS.md` holds the runnable checklist and the
evidence slot for it.

Related documents:

| Document | What it holds |
| --- | --- |
| `docs/LOCAL_SETUP.md` | Developer and verification setup, the test commands, the Lucee verification runtime |
| `docs/ENDPOINTS.md` | Every HTTP route, its policy, request and response contract |
| `docs/DATA_CONTRACT.md` | Data model, concurrency, idempotency, the report privacy rule |
| `database/README.md` | Migration order, what each migration does, detection queries |
| `docs/OPEN_DECISIONS.md` | Product decisions and their defaults |
| `docs/VERIFICATION_CHECKLISTS.md` | Checks that need the production platform, with evidence slots |
| `docs/evidence/phase8/` | Phase 8 transcripts: gates, ColdFusion runs, security, restart, operations, performance, accessibility |

Nothing in this document is a secret, and no secret belongs in it. Values in angle brackets are the
deployment's own.

---

## 1. Topology

```
 browser ──TLS──> district SSO gateway / reverse proxy ──> web server (IIS or Apache)
                  - authenticates the person                - ColdFusion connector
                  - strips client identity headers          - only /index.cfm and /assets/
                  - asserts X-Auth-Subject/Name/Email       - request size limit 20 MB
                                                                    │
                                                            Adobe ColdFusion 2023
                                                            - app/ is the document root
                                                            - src/ outside it (mapping /icfwalk)
                                                            - datasource "icfwalk", long text ON
                                                                    │
                                                            SQL Server 2016 or later
                                                            - database with the icf schema
                                                            - runtime login: data permissions only
```

* **One entry point.** Every request is `/index.cfm/...` (the page and the API) or a static file
  under `/assets/`. `Application.cfc` refuses any other template, and the web server must not serve
  anything else from `app/` (section 4.4).
* **Identity is asserted per request** by the gateway in headers (`ICFWALK_SSO_MODE=header`). The
  application trusts those headers only from `ICFWALK_SSO_TRUSTED_PROXIES`, and optionally only with
  `ICFWALK_SSO_SHARED_SECRET`. It keeps a small server session (user id, subject, CSRF token) and
  re-reads roles and scope from the database on every request, so a revoked role stops working on
  the next request.
* **State lives in SQL Server only.** The application servers hold no data that a restart loses
  except sessions, and a browser recovers from a lost session on its own (P8-01; section 9.3).
  The design allows several ColdFusion servers on one database (nothing but sessions is held per
  server); a load balancer would then need sticky sessions, and a request that reaches another
  server gets a new session that the page renews, exactly as after a restart. More than one server
  was not exercised in Phase 8.
* **Health:** `GET /index.cfm/api/health` (section 8.1).

## 2. What must be decided before production

These are the deployment owner's decisions. The build does not guess them; each is recorded in
`docs/evidence/phase8/OWNER_DECISIONS.md` with its status.

| Decision | Where it lands |
| --- | --- |
| SSO gateway product, the three header names it asserts, its source addresses, and whether it sends a shared secret | `ICFWALK_SSO_*` (section 3) |
| Hosting topology: IIS or Apache, one server or several, the public host name, TLS termination point | Sections 1, 4.4, 4.5 |
| Datasource: administrator-defined (recommended) or application-defined, its name, the SQL Server host and database | Section 4.2 |
| Where secrets live (the datasource password, `ICFWALK_SSO_SHARED_SECRET`, the maintenance token when used) | Section 3.2 |
| Backup schedule, retention, and the recovery point and recovery time objectives | Section 7 |
| Who operates the maintenance endpoints, and when they may be enabled | Section 10.1 |
| The approved wording of the 17 placeholder questions (`docs/OPEN_DECISIONS.md`) | A new DRAFT version (section 10.3) |
| A performance target, if the district sets one | Section 12 |

## 3. Configuration

All deployment-specific values are environment variables named `ICFWALK_*`. The ColdFusion service
reads them from its process environment, or from a file named by `ICFWALK_ENV_FILE` (one
`NAME=value` per line). A real environment variable always wins over the file. `.env.example` lists
every variable with its default.

### 3.1 Reference

| Variable | Production value | Notes |
| --- | --- | --- |
| `ICFWALK_ENVIRONMENT` | `production` | The default. Anything else is a non-production deployment. Production refuses to start when any rule below is broken. |
| `ICFWALK_DATASOURCE` | `icfwalk` (or the name chosen) | The ColdFusion datasource name. |
| `ICFWALK_DB_HOST`, `_PORT`, `_NAME`, `_USER`, `_PASSWORD`, `_ENCRYPT`, `_TRUST_SERVER_CERT` | Unset when the datasource is defined in the Administrator | When `ICFWALK_DB_HOST` is set, `Application.cfc` defines the datasource itself from these. Keep `_ENCRYPT=true` and `_TRUST_SERVER_CERT=false` in production. |
| `ICFWALK_LOG_LEVEL`, `ICFWALK_LOG_NAME` | `INFO`, `icfwalk` | ColdFusion log file name (`cfusion/logs/icfwalk.log`). |
| `ICFWALK_INSTRUMENT_CODE` | `ICFWALK` | The instrument every walk uses. |
| `ICFWALK_SCHOOL_DIMENSION_CODE` | `school` | The dimension that names a walk's school. |
| `ICFWALK_SSO_MODE` | `header` | `development` is refused in production. |
| `ICFWALK_SSO_SUBJECT_HEADER`, `_NAME_HEADER`, `_EMAIL_HEADER` | The gateway's header names | Defaults `X-Auth-Subject`, `X-Auth-Name`, `X-Auth-Email`. |
| `ICFWALK_SSO_TRUSTED_PROXIES` | The gateway's addresses (IPv4 or CIDR, comma separated) | **Required** in production; nobody is trusted when empty. |
| `ICFWALK_SSO_SECRET_HEADER`, `ICFWALK_SSO_SHARED_SECRET` | Recommended | When the secret is set (32+ characters) the gateway must send it in that header. |
| `ICFWALK_AUTO_PROVISION_USERS` | `true` or `false` | `true` creates an account on first sign-in (no access until a role is assigned). |
| `ICFWALK_DEV_IDENTITY_ENABLED` | `false` | `true` is refused in production (AUTH-02). |
| `ICFWALK_SESSION_TIMEOUT_MINUTES` | `60` | 5 to 720. The server session ends after this long without a request. |
| `ICFWALK_COOKIE_SECURE` | `true` | `false` is refused in production. The site must be served over HTTPS. |
| `ICFWALK_MAINTENANCE_ENABLED` | `false` | Enable only for a maintenance task (section 10.1). |
| `ICFWALK_MAINTENANCE_TOKEN` | Unset except during a task | 32+ characters when maintenance is enabled. |
| `ICFWALK_MAINTENANCE_ALLOW_REMOTE` | `false` | Maintenance answers loopback callers only unless this is `true`. |
| `ICFWALK_TESTS_ENABLED` | `false` | The test runner route is always off in production whatever this says. |
| `ICFWALK_ALLOW_UNPUBLISHED_INSTRUMENT` | `false` | `true` is refused in production: walks use a PUBLISHED version only. |
| `ICFWALK_PLACEHOLDER_WARNINGS_BLOCK_PUBLISH` | Owner's choice (`false` default) | Whether the 17 placeholder prompts block publication. |
| `ICFWALK_HIDDEN_PERIOD_POLICY` | `RETAIN_HIDDEN` | Or `CLEAR`. |
| `ICFWALK_REPORT_SUPPRESSION_THRESHOLD` | Empty (means 3) | A whole number of 3 or more raises the report minimum for new releases; anything else refuses startup. |
| `ICFWALK_INSTRUMENT_CONFIG_PATH` | Unset | Only the maintenance seed reads it. |

A configuration the application refuses answers every request `500 STARTUP_FAILED` and logs one
`application.start.failed` line naming the rule, never the value. Fix the variable. A value in the
file named by `ICFWALK_ENV_FILE` is read again on the next request, because an application that did
not start tries again; a process environment variable needs a ColdFusion restart to change.

### 3.2 Secrets

Secrets are the datasource password, `ICFWALK_SSO_SHARED_SECRET`, the ColdFusion Administrator
password and, only while a maintenance task runs, `ICFWALK_MAINTENANCE_TOKEN`.

* Keep them in the district's secret store, and deliver them to the ColdFusion service as environment
  variables or as a file named by `ICFWALK_ENV_FILE` that only the service account can read (mode
  600 on Linux; on Windows, an ACL granting read to the service account and administrators only).
* Prefer an administrator-defined datasource: its password then lives in the ColdFusion
  Administrator (encrypted in `neo-datasource.xml`) and never in the application's environment.
* Never commit them, never paste them into a ticket, and never put them in a URL. The application
  never logs them: the logger redacts any field whose name looks like a secret, token, password or
  cookie, and the health endpoint reports no configuration value in production.
* Rotate the shared secret by setting the new value in the gateway and the application together
  (a brief window refuses sign-ins); rotate the datasource password in SQL Server, then the
  Administrator, then verify health.

## 4. Clean install

The order below is the one exercised end to end on the verification runtime and on Adobe
ColdFusion 2023 in Adobe's container (`docs/evidence/phase8/`). An install on the district's own
ColdFusion, IIS/Apache and SQL Server is the checklist in `docs/VERIFICATION_CHECKLISTS.md`, "Adobe
ColdFusion 2023 on the production stack".

### 4.1 SQL Server

1. Create the database (any collation; `SQL_Latin1_General_CP1_CI_AS` is what verification used),
   recovery model FULL if point-in-time restore is wanted (section 7).
2. Create two logins:
   * an **administrative** login used only for migrations (db_owner, or `db_ddladmin` plus data
     rights) -- it is not given to the application;
   * the **runtime** login for the application: `db_datareader` and `db_datawriter` on the database
     and nothing else. No ALTER, CONTROL, `db_owner` or `db_ddladmin`: the report-release guards are
     triggers, and a principal that can alter the schema can switch them off
     (`database/README.md`, "Production responsibilities").
3. Apply the migrations in order with the administrative login, each exactly as shipped:
   `001_schema.sql` through `007_report_release.sql` (`sqlcmd -b -i <file>`, SSMS, or
   `node scripts/db/apply-schema.mjs --database <name>` with the administrative login in
   `ICFWALK_TEST_DB_ADMIN_USER`/`_PASSWORD`). Each one prints a success row. Section 6 covers
   failures.

### 4.2 ColdFusion 2023

1. **Datasource.** In the Administrator create a datasource named `icfwalk` for the runtime login.
   Either driver works; verification used the Microsoft JDBC driver 12.10 ("Other") because the
   bundled DataDirect driver could not be downloaded in the build environment. **Turn on "Enable
   long text retrieval (CLOB)"** (Advanced Settings; `disable_clob = false` through the Admin API).
   Without it ColdFusion returns only the first 32,000 characters of an `nvarchar(max)` value, an
   instrument snapshot is about 218,000, and nothing can render or save (P8-04). The health endpoint
   reports `longText: truncated` and answers 503 when this setting is wrong.
2. **Request size.** Server Settings > Settings > Request Size Limits: Maximum size of post data at
   least 20 MB (the default).
3. **Request timeout.** The default is fine for the application. Only the CFML test suite needs a
   long timeout, and it never runs in production.
4. **Caching.** Enable trusted cache in production, and clear the template cache on every release
   (section 5).
5. **Sessions.** Leave "Use J2EE session variables" at its default. The application issues CFID and
   CFTOKEN as browser-session cookies (no `Expires`), HttpOnly, SameSite=Lax and Secure (P8-05).
6. **Administrator and components.** Do not expose `/CFIDE` or the Administrator on the public site
   (the built-in web server exposes it; the IIS/Apache connector must not route it). Remove the
   sample applications.
7. **Code.** Deploy the repository's `app/`, `src/`, `config/` and `database/` to the server (for
   example `D:\icfwalk\`), with `app/` as the site's document root. `tests/` is not deployed to
   production. `Application.cfc` maps `/icfwalk` to `../src` itself.
8. **Environment.** Set the variables of section 3 for the ColdFusion service, then restart it.

### 4.3 First start and verification

```bash
curl -sS https://<host>/index.cfm/api/health
# {"application":"ICFWalk","status":"ok","checks":{"database":"ok","schema":"present","longText":"ok"},"correlationId":"..."}
```

A 503 names the failing check. `database: unavailable` is the datasource; `longText: truncated` is
section 4.2 step 1; `schema: missing` is section 4.1.

### 4.4 Web server and connector

* Serve only `/index.cfm` (with its path info) and `/assets/`. Every other path answers the
  application's JSON 404. IIS: request filtering (deny `.cfc`, `.cfm` other than `index.cfm`,
  `/WEB-INF`, `/CFIDE`) or a URL Rewrite rule that sends every other path to `/index.cfm/not-found`.
  Apache: the equivalent `RewriteRule`. Verification used Tomcat's rewrite valve with the same four
  rules (`tools/runtime/acf-up.sh`); a direct request for `Application.cfc` otherwise gets
  ColdFusion's own HTML error page.
* Request body limit 20,000,000 bytes: IIS `requestLimits maxAllowedContentLength="20000000"`,
  Apache `LimitRequestBody 20000000`. The application enforces its own limits too (5 MB for an
  instrument import) and answers 413 before reading the body. A body declared over the web server's
  own limit never reaches the application: the server answers with its own page (IIS 404.13, Apache
  413, and ColdFusion's own 400 above its "Maximum size of post data"), not the application's JSON
  (`tests/node/admin-instrument.test.mjs`, the last P6A-01 case).
* **Strip the identity headers from every client request** (`X-Auth-Subject`, `X-Auth-Name`,
  `X-Auth-Email`, the secret header, and `X-ICFWalk-Dev-*`) so that only the gateway sets them.
* Pass `PATH_INFO` to ColdFusion (the IIS connector does by default).
* Static assets are not versioned by file name. Serve `/assets/` with `Cache-Control: no-cache`
  (revalidate) so a release reaches browsers on their next load.

### 4.5 TLS, gateway and cookies

* HTTPS end to end from the browser to the gateway; HSTS at the gateway.
* The gateway authenticates and asserts identity, and its address is in
  `ICFWALK_SSO_TRUSTED_PROXIES`. If there is a load balancer between the gateway and ColdFusion, the
  address ColdFusion sees is the one to list.
* Cookies: the application's session cookies are Secure (production refuses otherwise), HttpOnly,
  SameSite=Lax and end with the browser session. The gateway's own session cookie is the gateway's
  policy: a shared computer is protected by signing out of the gateway.
* Leave the ColdFusion Administrator's "Use J2EE session variables" off (the verified
  configuration): the session is then CFID and CFTOKEN only, and `this.sessionCookie` sets their
  flags. With it on, the servlet container issues JSESSIONID and decides its Secure flag from the
  request it sees, which behind a TLS-terminating gateway is plain HTTP. The verification runtime
  shows exactly that: on Lucee, Jetty's JSESSIONID carries no Secure flag, and
  `tests/ops/production-profile.test.mjs` proves the application's session does not depend on it (a
  CSRF-protected write succeeds without it and fails with it alone).
* The production profile, end to end, is `tests/ops/production-profile.test.mjs`: it refuses to
  start misconfigured, accepts identity only from the trusted gateway with its secret, rotates the
  session at sign-in, enforces CSRF, keeps error bodies free of engine and SQL text, survives a
  database outage without a restart, and runs on a login with `db_datareader` and `db_datawriter`
  only. It serves the tree from its own instance (Lucee, or the ColdFusion container) on a scratch
  database; behind the real gateway, `docs/VERIFICATION_CHECKLISTS.md` checklist 6 covers the same
  ground by hand.

### 4.6 Seed the instrument and bootstrap

The order matters in production. A SCHOOL unit's School mapping is validated against the School
dimension of the version in service, and production serves no DRAFT
(`ICFWALK_ALLOW_UNPUBLISHED_INSTRUMENT` is false there), so a mapping made before the first
publication is refused with 400 `INSTRUMENT_NOT_AVAILABLE` (P8-12). Outside production the seeded
DRAFT is renderable and any order works, which is why only a production install shows it.
`tests/ops/production-profile.test.mjs` runs exactly these steps in the production profile.

1. Enable maintenance for the task only: `ICFWALK_MAINTENANCE_ENABLED=true` and a fresh 32+
   character `ICFWALK_MAINTENANCE_TOKEN`, then restart. Maintenance answers loopback callers only.
2. From the server itself:
   ```bash
   export ICFWALK_BASE_URL=http://127.0.0.1   # the site as seen from the server
   node scripts/seed-instrument.mjs            # imports config/instrument-config.json as a DRAFT
   ```
   or `curl -X POST -H "X-ICFWalk-Maintenance-Token: <token>" http://127.0.0.1/index.cfm/api/maintenance/instrument/import`.
   The result names the version, `checksum` (`c125b4ae...` for the supplied document) and 17
   placeholders.
3. Import the org units **without** `schoolValueCode` yet, provision the first instrument
   administrator and assign the roles (`docs/LOCAL_SETUP.md`, "Adobe ColdFusion 2023 deployment",
   step 8). Every SCHOOL unit is reported unmapped for now.
4. The administrator signs in through the gateway, opens **Instrument admin**, previews the DRAFT and
   publishes it (section 10.3). Until a version is published no walk can start. Maintenance stays
   on: the two are independent.
5. Map every SCHOOL unit to its School value: re-import the org units with `schoolValueCode`, or
   confirm the candidates of `align-school-dimension` (`docs/LOCAL_SETUP.md`, step 10). Resolve
   every entry in `unmapped[]` before going live.
6. Disable maintenance again (`ICFWALK_MAINTENANCE_ENABLED=false`, token removed) and restart.

## 5. Releasing a new application version

A release replaces the code under `app/` and `src/` and, if it ships one, applies a new migration.

1. **Read the release notes** for migrations and configuration changes.
2. **Back up the database** (section 7.2) and record the backup's name.
3. **Check health** on every server and note the version currently deployed (its commit).
4. If the release carries a migration: apply it with the administrative login first (section 6).
   Migrations are additive: the previous code keeps working against the migrated database, so
   migrate before deploying code.
5. **Deploy the code** to each server (a copy of the tree at the release commit), then clear the
   ColdFusion template cache (Administrator > Server Settings > Caching > Clear Template Cache Now)
   or restart ColdFusion. Restarting ends the sessions on that server; open pages renew their token
   and keep their edits (section 9.3).
6. **Smoke test:** health is `ok`; an instrument administrator's `GET /api/admin/instrument/versions`
   lists the published version; a walker opens an existing walk, changes a note and sees "All
   changes saved"; a report runs.
7. Watch the log for `request.failed` for an hour.

Rolling several servers one at a time behind a load balancer works: the request contract is
backward compatible within a release, and a browser that lands on a restarted server renews its
session.

### 5.1 Rolling back

Roll back the code, not the database, when a release misbehaves (the smoke test fails, or
`request.failed` climbs):

1. Redeploy the previous release's tree (the commit noted in step 3 above) to every server and clear
   the template cache or restart ColdFusion. Open pages renew their session and keep their edits.
2. Leave the database as it is. Migrations are additive, so the previous release runs on the migrated
   database, including the rows the newer release wrote. This is verified: the frozen Phase 0-7
   release served, edited and reported on a database that 007 had migrated and this release had
   written to, and read the report release this release had created
   (`tests/ops/upgrade-and-rollback.test.mjs`, evidence in `docs/evidence/phase8/operations/`).
3. Never reverse a migration by hand. Restore the backup from step 2 (section 7.3) only when the data
   itself is damaged: everything written since that backup is lost, so decide it with the owner.
4. Repeat the smoke test and record what was rolled back, when, and why.

On Adobe ColdFusion 2023 there is no earlier release to roll back to: the Phase 0-7 release does not
start on it (defect P8-02), so the Phase 8 release is the first one that runs there. A fault found
after the first go-live is corrected forward with a new release, or the service is taken offline
(section 13) while it is. On later releases the steps above apply.

## 6. Migrations

`database/README.md` lists what each script does. The rules:

* Apply in order, with the administrative login, each file exactly as shipped. Never edit a shipped
  script; a correction ships as a new numbered script.
* Every script is one transaction under `SET XACT_ABORT ON`: it commits whole or not at all.
  Scripts 002 to 007 are idempotent -- re-applying one changes nothing -- and 001 refuses to run
  against a database that already has `icf` tables (error 50001).
* Back up first (section 7.2).

**When a migration fails.** It rolled back; the database is exactly as it was before it started.
This is verified: a 007 killed half way, after it had created two tables, left nothing behind, and
the same script then applied and re-applied cleanly (`tests/ops/database-operations.test.mjs`,
evidence in `docs/evidence/phase8/operations/`).

1. Read the error. A `THROW 500xx` is a precondition the script checks (for example 50061: the icf
   schema is missing; 50053: a published version without a publisher; 50054 and 50067: states the
   script refuses to guess about -- `database/README.md` explains each). Anything else is SQL
   Server's own error (permissions, a lock timeout, a lost connection).
2. Fix the cause. Do not hand-edit tables to "finish" a migration.
3. Apply the same script again. If the cause cannot be fixed, restore the backup (section 7.3) and
   stay on the previous release.

**Upgrading an existing installation.** An installation at Phase 7 needs nothing (it has 001 to
007). From the Phase 6 release apply `007_report_release.sql` (the exercise with Phase 6 data is in
`docs/evidence/phase8/operations/`). From earlier, apply the missing scripts in order; the one-time
transition in 006 is described in `database/README.md`.

## 7. Backup and restore

### 7.1 Policy (owner decisions)

The recovery point objective (how much work may be lost) and recovery time objective (how long the
service may be down) are the district's to set. The build recommends, as a starting point for that
decision: FULL recovery model; a nightly full backup; a differential at midday; transaction log
backups every 15 minutes; backups written with `CHECKSUM` to storage that is not the database
server; retention of at least one school year of nightly fulls (walks are the district's record);
and a restore drill each term. Record the decision in `docs/evidence/phase8/OWNER_DECISIONS.md`.

### 7.2 Taking a backup

```sql
BACKUP DATABASE [<db>] TO DISK = N'<path>\<db>_<yyyymmdd_hhmm>.bak'
  WITH CHECKSUM, COMPRESSION, NAME = N'<reason>';        -- scheduled backups
BACKUP DATABASE [<db>] TO DISK = N'<path>\<db>_pre_<release>.bak'
  WITH COPY_ONLY, CHECKSUM, COMPRESSION;                  -- before a release; leaves the chain alone
BACKUP LOG [<db>] TO DISK = N'<path>\<db>_<yyyymmdd_hhmm>.trn' WITH CHECKSUM;
RESTORE VERIFYONLY FROM DISK = N'<file>' WITH CHECKSUM;   -- every backup, every time
```

`COMPRESSION` is unavailable on SQL Server Express; omit it there. Nothing in the application needs
to stop for a backup.

### 7.3 Restoring

Restore to a **separate database first**, verify it, and only then decide whether to swap it in.

```sql
RESTORE FILELISTONLY FROM DISK = N'<file>';
RESTORE DATABASE [<db>_restore] FROM DISK = N'<file>'
  WITH MOVE N'<logical data name>' TO N'<data dir>\<db>_restore.mdf',
       MOVE N'<logical log name>'  TO N'<data dir>\<db>_restore_log.ldf',
       CHECKSUM, RECOVERY;             -- NORECOVERY, then RESTORE LOG ... STOPAT = '<time>' for point in time
DBCC CHECKDB (N'<db>_restore') WITH NO_INFOMSGS, ALL_ERRORMSGS;
```

Verify the restored copy:

1. `CHECKDB` reports nothing.
2. Every published or retired instrument snapshot still hashes to its stored checksum:
   `node --test tests/ops/database-operations.test.mjs` does this, or compute SHA-256 (UTF-8) of
   `icf.instrument_version.compiled_snapshot_json` and compare with `checksum_sha256`.
3. Row counts of `icf.walk`, `icf.walk_response`, `icf.walk_mutation`, `icf.audit_event` and
   `icf.report_release` are what the backup time implies.
4. No trigger is disabled: `SELECT name FROM sys.triggers WHERE is_disabled = 1` returns nothing.
5. Point a non-production application at it (`ICFWALK_DB_NAME=<db>_restore` or a second datasource)
   and check health, an existing walk, a report.

To put the restored copy into service: stop the application (or put the web server into a
maintenance page), take a tail-log backup of the damaged database if it is still readable, rename
the databases (`ALTER DATABASE ... MODIFY NAME`) or repoint the datasource, re-grant the runtime
login if it was restored from another server (orphaned user: `ALTER USER <user> WITH LOGIN = <login>`),
start the application, check health.

The drill with the verification database -- a COPY_ONLY backup verified, restored to a separate
database, CHECKDB clean, every table, object and trigger identical, every snapshot checksum
verified, and the application run against the restored copy -- is in
`docs/evidence/phase8/operations/`.

## 8. Monitoring

### 8.1 Health endpoint

`GET /index.cfm/api/health` needs no identity and answers:

| HTTP | `status` | Meaning |
| --- | --- | --- |
| 200 | `ok` | The database answers, the schema is present, long text comes back whole. |
| 503 | `degraded` | `checks.database = unavailable` (datasource, network, login) or `checks.longText = truncated` (section 4.2). |

`checks.schema = missing` with 200 means the database answers but migrations were not applied.
The long-text check runs at most every ten minutes. In production the body carries no environment
or engine information. Point the load balancer's health probe at it; alert on two consecutive
non-200 answers.

### 8.2 Logs

The application writes one JSON object per line to the ColdFusion log named by `ICFWALK_LOG_NAME`
(`cfusion/logs/icfwalk.log`). Every line has `event`, `level`, `ts` and `correlationId`; the same
`correlationId` is returned to the browser in `X-Correlation-Id` and in every error body, so a
person's screenshot of an error finds its log lines. Notes, email drafts, teacher fields, tokens
and secrets are never logged (SEC-05).

Events worth alerting on:

| Event | Level | Meaning |
| --- | --- | --- |
| `application.start.failed` | error | Configuration refused; every request fails. |
| `request.failed` | error | An unexpected exception (a 500). Any rate above zero deserves a look. |
| `instrument.snapshot.checksum.mismatch`, `instrument.snapshot.checksum.missing` | error | A stored snapshot does not match its checksum: data tampering, or a datasource that truncates long text. |
| `instrument.publish.definitions_drift`, `instrument.import.roundtrip_mismatch`, `instrument.discard.unexpected_delete_count` | error | An integrity guard stopped a write. |
| `identity.header.untrusted_source`, `identity.header.secret_invalid` | warn | Identity headers from somewhere other than the gateway. A burst is an attack or a misconfigured proxy. |
| `csrf.rejected` | warn | Normal after a restart (pages renew); a sustained rate from one user is not. |
| `authorization.denied` | warn | Someone reached for something outside their role or scope. |
| `maintenance.invoked`, `maintenance.denied` | info/warn | Maintenance use; in production both should be rare and expected. |

Other events (`walk.*`, `report.*`, `instrument.*`, `auth.signed_in`) are routine and useful for
tracing.

### 8.3 Audit trail

`icf.audit_event` is append-only for the application. Event types include `USER_SIGNED_IN`,
`USER_SIGNED_OUT`, `USER_PROVISIONED`, `ROLE_ASSIGNED`, `ACCESS_DENIED`, `WALK_CREATED`,
`WALK_COMPLETED`, `WALK_VOIDED`, `WALK_POST_COMPLETION_EDIT`, `WALK_SAVE_CONFLICT`,
`WALK_SAVE_REJECTED`, `WALK_MUTATION_REPLAYED`, `WALK_MUTATION_ID_REUSED`,
`WALK_SCHOOL_SCOPE_REJECTED`, `WALK_SUMMARY_EXPORTED`, `INSTRUMENT_VERSION_PUBLISHED`,
`INSTRUMENT_VERSION_RETIRED`, `INSTRUMENT_VERSION_DISCARDED`, `INSTRUMENT_VERSION_WRITE_REFUSED`,
`ORG_UNITS_IMPORTED`, `REPORT_RELEASED`, `REPORT_EXPORTED` and `MAINTENANCE_TASK_INVOKED`. Each
row has the actor, the entity, the time, the correlation id and details without narrative content.

```sql
-- Everything one person did in a window
SELECT event_at, event_type, entity_type, entity_id, details_json
FROM icf.audit_event
WHERE actor_user_id = (SELECT user_id FROM icf.app_user WHERE identity_subject = N'<subject>')
  AND event_at >= '<from>' ORDER BY event_id;
-- Refusals in the last day, by kind
SELECT event_type, COUNT(*) FROM icf.audit_event
WHERE event_at >= DATEADD(day, -1, SYSUTCDATETIME())
  AND event_type IN (N'ACCESS_DENIED', N'WALK_SAVE_REJECTED', N'WALK_SCHOOL_SCOPE_REJECTED', N'WALK_MUTATION_ID_REUSED')
GROUP BY event_type;
```

### 8.4 SQL Server

Watch the usual: failed backups, log growth, blocking longer than a few seconds
(`sys.dm_exec_requests` with `blocking_session_id <> 0`), deadlocks (the application retries
nothing on its own; a person sees "could not save" and Retry), and CHECKDB results.

## 9. Routine operations

### 9.1 People and roles

* **A new person** signs in through the gateway. With `ICFWALK_AUTO_PROVISION_USERS=true` the
  account exists from then on, with no access until a role is assigned.
* **Roles** (`DISTRICT_WALK_REPORT`, `DISTRICT_REPORT_ONLY`, `SCHOOL_WALK_REPORT`,
  `SCHOOL_REPORT_ONLY`, `MASTER_INSTRUMENT_ADMIN`) are assigned to an org unit through the
  maintenance endpoint `POST /api/maintenance/identity/assign-role` (section 10.1). An assignment
  can carry effective dates; access follows them on the next request.
* **Someone leaves:** end their assignments (effective end date) or deactivate the account
  (`UPDATE icf.app_user SET active = 0 WHERE identity_subject = N'<subject>'` with an audited change
  ticket); either takes effect on their next request. Their walks remain.
* **Access review** each term: the query in section 8.3 for `ROLE_ASSIGNED`, and a list of
  assignments by role and unit.

### 9.2 Org units

Re-import `config/org-units` (codes are stable identifiers; names and parents update by code), then
map any new SCHOOL unit (`docs/LOCAL_SETUP.md`, step 10). A unit that closes is set inactive by
import; its walks stay and report under it.

### 9.3 Sessions and restarts

A ColdFusion restart ends every session on that server. Open pages are unaffected: the next save is
refused once with `CSRF_TOKEN_INVALID`, the page fetches a new token and sends the same request
again, and the person sees "All changes saved" (P8-01). A save that was on the wire when the server
died is shown as "Could not reach the server" with Retry; Retry resends the same request under the
same mutation id, so it is committed exactly once, whether or not the server had committed it
before dying (SEC-06; `tests/ops/restart-during-autosave.test.mjs`).

### 9.4 The yearly instrument update, and report releases

See `docs/LOCAL_SETUP.md` step 9 (Excel round trip, preview, compare, publish) and
`docs/OPEN_DECISIONS.md`, "Aggregate privacy rule (RPT-03)" (releases are created by someone with
walk and report access across every active unit, cover closed past dates, never overlap and never
change).

### 9.5 Log and data retention

The ColdFusion log rotates by size (Administrator > Logging). Keep `icfwalk.log` for at least the
audit retention the district sets; `icf.audit_event` keeps its own history in the database.
Nothing in the application deletes walks, audit events or releases.

## 10. Maintenance endpoints

### 10.1 Rules

The `/api/maintenance/*` routes seed the instrument, import org units, provision users, assign
roles and align School values. They exist only while `ICFWALK_MAINTENANCE_ENABLED=true`, answer only
loopback callers unless `ICFWALK_MAINTENANCE_ALLOW_REMOTE=true`, and require the token header.
Every invocation is logged and audited (`MAINTENANCE_TASK_INVOKED`). Enable, do the task from the
server itself, disable, restart. Never leave maintenance enabled.

### 10.2 The test runner

`/api/maintenance/tests/run` runs the CFML suite. It needs `ICFWALK_TESTS_ENABLED=true` and is
refused in production regardless. Never run it against a production database: specs create and
delete their own fixtures.

### 10.3 Publishing, retiring, discarding

Done in the browser by an instrument administrator (**Instrument admin**). Publishing freezes the
snapshot; retiring the only version in service asks twice; discarding is possible only for a DRAFT
no walk uses. `docs/ENDPOINTS.md` has the routes.

## 11. Troubleshooting

| Symptom | Likely cause | What to do |
| --- | --- | --- |
| Every request answers `STARTUP_FAILED` | A configuration rule (section 3.1) | Read `application.start.failed` in the log; fix; restart. |
| Health 503, `longText: truncated`; walks will not open; `instrument.snapshot.checksum.mismatch` | The datasource returns only 32,000 characters of long text | Enable long text retrieval (CLOB) on the datasource (section 4.2); restart or wait ten minutes. |
| Health 503, `database: unavailable` | SQL Server down, login refused, network, certificate | Check the datasource in the Administrator (Verify). |
| Nobody can sign in; `identity.header.untrusted_source` | The gateway's address is not in `ICFWALK_SSO_TRUSTED_PROXIES`, or a load balancer changed the source address | List the address ColdFusion sees. |
| Sign-in refused, `identity.header.secret_invalid` | Shared secret mismatch | Set the same secret in the gateway and the application. |
| A person gets 403 on the page | Signed in, but no role | Assign a role (section 9.1). |
| "New walk" does nothing useful; walks cannot start | No PUBLISHED version of `ICFWALK_INSTRUMENT_CODE` | Publish one (section 10.3). |
| A save is refused `SCHOOL_ORG_UNMAPPED` | The walk's SCHOOL unit has no School value mapping | Map it (section 9.2). |
| "This walk was changed elsewhere" | Two sessions edited one walk | Expected (SAVE-04); the person reviews and keeps their edits. |
| 413 on an import | The document is over 5 MB (or the connector's limit is lower than 20 MB) | Check the file; check the connector limit (section 4.4). |
| A direct request for a `.cfc` shows a ColdFusion error page | The web server serves more than `/index.cfm` and `/assets/` | Section 4.4. |
| Browsers keep old JavaScript after a release | `/assets/` cached without revalidation | Section 4.4; clear the ColdFusion template cache. |
| Reports show "withheld" everywhere for report-only users | Expected below the minimum of 3 walks per block, or no release covers the period | `docs/OPEN_DECISIONS.md`, RPT-03. |

## 12. Capacity and performance

No performance target has been set, so none is claimed (owner decision D8). `docs/evidence/phase8/performance/`
holds a reproducible synthetic workload -- its data sizes, concurrency, environment, timings, SQL
plans and resource observations -- and what it found; a target, once the district sets one, is
checked by re-running it:

```bash
# an application in development mode on its own, migrated database (never a production one)
ICFWALK_DB_NAME=icfwalk_perf ICFWALK_BASE_URL=<its site> node tests/perf/seed.mjs 30000
ICFWALK_DB_NAME=icfwalk_perf ICFWALK_BASE_URL=<its site> PERF_LEVELS=1,10,25 PERF_DURATION=60 \
  PERF_EDIT=any ICFWALK_EVIDENCE_DIR=<dir> node tests/perf/workload.mjs   # PERF_EDIT=drafts: edit drafts only
```

What to know from it, on one 4-CPU machine holding SQL Server, the engine and the load generator:

* **The engine matters.** Adobe ColdFusion paid for every Java call the JSON writer made; after P8-14
  a single walker's My Walks answers in about 50 ms on either engine (it was 400 ms on ColdFusion),
  and 25 walkers working without pause see medians around half a second.
* **Live district reports refuse rather than mix states.** A report reads its population, then
  checks that no walk in it changed; after three changed attempts it answers 409
  `REPORT_POPULATION_CHANGED` ("run the report again"). Edits to completed walks while a district
  report runs are what trigger it; edits to drafts do not. It was frequent before P8-14 made reports
  fast, and is now rare (none on ColdFusion at 25 walkers; a few in twenty on Lucee at its higher
  write rate). Frozen releases (section 9.4) are unaffected and answer in tens of milliseconds.
* **My Walks scans the walk table.** Its `TOP 500 ... ORDER BY updated_at` reads every walk in scope,
  and the report's candidate selection reads every walk of the version; SQL Server suggests indexes
  on `icf.walk (org_unit_id, owner_user_id)` and `(version_id, org_unit_id, status) INCLUDE
  (row_version)`. Neither is added: an index is a migration, and whether it is needed is a question
  for the target (D8), answered by re-running the workload on the production hardware.
* Nothing leaks: temp tables, open transactions and tempdb use are the same after every level as
  before it, and a backup and restore of the 2 GB synthetic database takes seconds.

## 13. Incident response

1. **Contain.** For a compromised account: end its role assignments or set `app_user.active = 0`
   (section 9.1) and ask the gateway team to end its SSO sessions; access stops on the next
   request. For a compromised server: take it out of the load balancer.
2. **Preserve.** Copy `icfwalk.log` and the web server logs for the window; do not modify
   `icf.audit_event`.
3. **Investigate.** Trace by correlation id (logs) and by actor (section 8.3). Walks keep every
   revision (`icf.walk_revision`) and every mutation (`icf.walk_mutation`), so what changed and who
   changed it is answerable from the database.
4. **Recover.** Wrong data in a walk is corrected in the application by its owner (a completed walk
   keeps a revision of every post-completion edit) or voided with a reason; never deleted. A damaged
   database is restored (section 7.3). A release made in error cannot be removed by the application
   (RPT-03); removing one is a schema-level change by the database administrator, recorded as an
   incident.
5. **Report** according to district policy. Walk notes can hold personal information about
   teachers; treat an exposure of walk details as a data incident.

## 14. Hardening checklist

- [ ] `ICFWALK_ENVIRONMENT=production`; the application starts (every fail-closed rule satisfied).
- [ ] HTTPS only; HSTS at the gateway; `ICFWALK_COOKIE_SECURE=true`.
- [ ] Identity headers stripped from client requests; `ICFWALK_SSO_TRUSTED_PROXIES` lists only the
      gateway; shared secret set.
- [ ] Only `/index.cfm` and `/assets/` served; `/CFIDE` and the Administrator not reachable from
      the public site.
- [ ] Request body limit 20 MB at the connector and in ColdFusion.
- [ ] Datasource with long text retrieval on; runtime login with data permissions only.
- [ ] Maintenance and the test runner off; no maintenance token configured.
- [ ] Secrets in the secret store; environment file readable by the service account only.
- [ ] Backups scheduled, verified, and restored in a drill.
- [ ] Health probe and log alerts in place (section 8).
- [ ] ColdFusion and SQL Server patched to current updates; trusted cache on.
