# Local setup and deployment

ICFWalk targets Adobe ColdFusion 2023 and Microsoft SQL Server 2016 or later. This document covers
a clean local install, the verification runtime used when Adobe ColdFusion is not available, and
the production deployment shape. No credentials are stored in the repository; everything
deployment-specific comes from environment variables (see `.env.example`).

## Repository layout

| Path | Purpose |
| --- | --- |
| `app/` | ColdFusion web root. `Application.cfc`, the single entry point `index.cfm`, and static browser assets in `app/assets/` (CSS and ES modules; no build step). |
| `src/views/` | HTML shell template served by `ShellController` (no instrument content inside). |
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
                                              # 32+ char ICFWALK_MAINTENANCE_TOKEN,
                                              # ICFWALK_MAINTENANCE_ENABLED=true / ICFWALK_TESTS_ENABLED=true,
                                              # and for local sign-in: ICFWALK_SSO_MODE=development,
                                              # ICFWALK_DEV_IDENTITY_ENABLED=true, ICFWALK_COOKIE_SECURE=false
node scripts/db/apply-schema.mjs              # applies database/001_schema.sql, 002_alignment_patch.sql,
                                              # 003_walk_mutation.sql, 004_mutation_fingerprint.sql,
                                              # 005_org_unit_dimension_map.sql

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
5. Apply `database/001_schema.sql`, then `database/002_alignment_patch.sql`, then
   `database/003_walk_mutation.sql`, `database/004_mutation_fingerprint.sql`, and
   `database/005_org_unit_dimension_map.sql` (all idempotent) with SQL Server tooling
   (`sqlcmd`, SSMS) or `node scripts/db/apply-schema.mjs`. Existing installations from before
   Phase 4 need only `003`.
6. Seed the instrument: enable maintenance temporarily (`ICFWALK_MAINTENANCE_ENABLED=true`, a
   32+ character `ICFWALK_MAINTENANCE_TOKEN`), call the import endpoint from the server itself
   (`node scripts/seed-instrument.mjs` or `curl` against `http://127.0.0.1/index.cfm/api/maintenance/instrument/import`),
   then disable maintenance again. After step 9, an instrument administrator can do the same from
   the browser instead: **Instrument admin** (the view an admin-only user lands on) imports an
   uploaded document, previews, compares, edits DRAFT wording, publishes and retires, with no
   maintenance access at all.
7. The seeded version is a DRAFT. Publish it from the administration view (Publish on its row,
   then confirm); publishing freezes the snapshot it was imported with. Until a version is
   published, a production deployment has no version in service and walks cannot start.
   **The yearly update.** Download the current version as an Excel workbook (Download on its row),
   edit it in Excel following its Start Here sheet, and upload it with Import under a new draft
   label. Problems are listed by sheet, row and column and nothing is saved until the file is clean.
   Preview and compare the draft, then publish it. The same workbook can go to content owners for
   review first.
8. Configure identity. In production `ICFWALK_SSO_MODE=header`: the district SSO gateway or reverse
   proxy authenticates users and asserts the subject/name/email in the headers named by
   `ICFWALK_SSO_SUBJECT_HEADER`, `ICFWALK_SSO_NAME_HEADER`, `ICFWALK_SSO_EMAIL_HEADER`. List the
   gateway addresses in `ICFWALK_SSO_TRUSTED_PROXIES` (required in production; nobody is trusted when
   empty) and optionally require `ICFWALK_SSO_SHARED_SECRET` in `ICFWALK_SSO_SECRET_HEADER`. The web
   server must strip those headers from client requests so only the gateway can set them.
9. Bootstrap the organization and the first administrator with maintenance enabled temporarily:

   ```bash
   H="X-ICFWalk-Maintenance-Token: $ICFWALK_MAINTENANCE_TOKEN"
   curl -sS -X POST -H "$H" -H 'Content-Type: application/json' -d '{"file":"org-units.example.json"}' \
     http://127.0.0.1/index.cfm/api/maintenance/org-units/import
   curl -sS -X POST -H "$H" -H 'Content-Type: application/json' -d '{"subject":"<sso subject>","displayName":"<name>"}' \
     http://127.0.0.1/index.cfm/api/maintenance/identity/provision-user
   curl -sS -X POST -H "$H" -H 'Content-Type: application/json' \
     -d '{"subject":"<sso subject>","roleCode":"MASTER_INSTRUMENT_ADMIN","orgUnitCode":"district"}' \
     http://127.0.0.1/index.cfm/api/maintenance/identity/assign-role
   ```

   Then map each SCHOOL org unit to the instrument School dimension value that names it, which the
   School-scope invariant depends on (`docs/DATA_CONTRACT.md`, "School and organizational scope").
   Either declare it in the import (`"schoolValueCode": "<instrument School value code>"` on each
   SCHOOL unit) or, when the org-unit codes already are the instrument's School value codes, ask for
   the candidates and confirm the ones that are right:

   ```bash
   curl -sS -X POST -H "$H" -H 'Content-Type: application/json' -d '{}' \
     http://127.0.0.1/index.cfm/api/maintenance/org-units/align-school-dimension   # candidates[] only
   curl -sS -X POST -H "$H" -H 'Content-Type: application/json' \
     -d '{"confirm":[{"orgUnitCode":"<code>","valueCode":"<instrument School value code>"}]}' \
     http://127.0.0.1/index.cfm/api/maintenance/org-units/align-school-dimension
   ```

   Code equality is a coincidence, not a decision, so the first call writes nothing however it is
   phrased: only the pairs in `confirm[]` are stored, and each is re-derived and re-validated first
   (`refused[]` says why any was not). The response's `unmapped[]` names every SCHOOL unit still
   without a mapping and why, including `NON_IDENTIFYING_VALUE_CODE` for a unit coded `other`, which
   is the School dimension's free-text option and never an identity. Walks at an unmapped unit carry
   no School value and refuse a submitted one, so resolve them before going live.

   Walk and report roles (`DISTRICT_WALK_REPORT`, `DISTRICT_REPORT_ONLY`, `SCHOOL_WALK_REPORT`,
   `SCHOOL_REPORT_ONLY`) are assigned the same way with `orgUnitCode` of the district (with
   `"includeDescendants": true`) or of a school. Adjust `config/org-units.example.json` (codes are
   stable identifiers) before the first import; re-importing updates names and parents by code.

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
not a supported production platform for ICFWalk. Lucee compiles components once and does not watch
the source files: after editing a `.cfc`, restart it (`lucee-down.sh` then `lucee-up.sh`); `?reinit=1`
on any request only rebuilds the container from the already compiled classes.

`lucee-up.sh` exports `LUCEE_REQUESTTIMEOUT` (default 600 seconds, override by exporting it first).
The CFML suite runs inside `/api/maintenance/tests/run`, and the walk and publish concurrency specs
deliberately hold a writer blocked for seconds, so on a modest machine that request runs past
Lucee's 50 second default. When it does, Lucee stops the request mid-suite and interrupts the
thread, and the spec that runs *next* fails with `java.nio.channels.ClosedByInterruptException` from
the first file write it attempts, which reads like an unrelated logging fault rather than a timeout.
The ceiling belongs to the verification runtime only: no application or production setting is
involved, and no individual test is given longer to pass.

**The suite is requested in parts.** `?part=<n>&of=<m>` runs one deterministic slice: spec files are
discovered in a stable name order and dealt out round-robin, so every spec runs in exactly one part
and the union of the parts is the whole suite. `tests/node/cfml-suite.test.mjs` asks for three
parts, sums the reports, and asserts that the set of specs that ran equals the set of spec files on
disk -- so a partition that dropped a spec fails rather than looking healthy.

This exists because the *client* has a ceiling too, and it is lower than Lucee's: Node's `fetch`
abandons a request after five minutes without response headers, and none are sent until the suite
finishes. A suite that grew past five minutes therefore failed as `fetch failed`, and the abort also
skipped every spec's `afterAll`, leaving fixtures behind that then failed later, unrelated-looking
tests. Parts keep each request well inside that limit without changing what runs. Omitting `part`
and `of` still runs everything in one request, which is fine for a filtered run.

The seeded DRAFT can be re-imported (idempotently) only while no walk references it: the fixtures of
every test remove their walks, but walks created by hand through the browser keep the DRAFT "in
use" (`INSTRUMENT_VERSION_IN_USE`) until they are removed or the version is published.

## Tests

| Command | What it runs |
| --- | --- |
| `npm run validate:handoff` | Supplied handoff validator (PKG-01). |
| `npm run test:package` | PKG-02..05, canonical JSON vectors, reference snapshot golden, schema/DAO contract. No database needed. |
| `npm run test:db` | DB-01..03 against a disposable SQL Server database (needs `ICFWALK_DB_*` admin credentials). |
| `npm run test:cfml` | Health/guard checks, the CFML suite via `/api/maintenance/tests/run` (unit specs, DB-04..09, identity, authorization, and walk persistence specs, including the deterministic concurrency specs `WalkReplayCoherenceTest`, `WalkMutationResponseTest` and `WalkSummaryCoherenceTest`), and the idempotent seed. Needs the running app, `ICFWALK_TESTS_ENABLED=true`, and the maintenance token. A single spec can be run with `?filter=<SpecName>` on that endpoint, and one slice of the suite with `?part=<n>&of=<m>`. |
| `npm run test:auth` | HTTP identity/authorization checks (AUTH-01, CSRF, cookies, admin route separation). Needs the app in development mode with `ICFWALK_SSO_MODE=development` and `ICFWALK_DEV_IDENTITY_ENABLED=true`. |
| `npm run test:shell` | Phase 3: authorization and headers of the HTML shell and `/api/instrument/current`; browser rules engine against the shared visibility vectors and COND-01..15 (same prerequisites as `test:auth`). |
| `npm run test:walks` | Phase 4: HTTP checks of `/api/walks` (authentication, CSRF, role separation, cross-scope 404s, tampered keys/codes/identifiers, stale writes, idempotent retries, completion, void, delete refusal, pinned instrument). Same prerequisites as `test:auth`. |
| `npm run test:summary` | Phase 5: the browser summary formatter against the shared golden vectors (`tests/fixtures/summary-vectors.json`), the SUM-02..06 behaviors, file-name sanitization, the composer's canonical serialization, and the no-automatic-send gate (no `cfmail`/SMTP/mail library anywhere, no route that accepts a recipient, `mailto:` values percent-encoded). Same prerequisites as `test:auth`. The CFML twin runs inside `npm run test:cfml` (`?filter=WalkSummaryFormatter`). |
| `npm run test:browser` | Phase 3 + 4 + 5 (+ the Phase 7 reports view, `browser-reports.test.mjs`, and the Phase 6 administration view, `browser-admin.test.mjs`): Playwright (Chromium) runs of the real page against the persistent store: dynamic rendering from the served model, conditional behavior, My Walks flow (create, reload, open, void), 700 ms autosave coalescing, network-failure retry, two-session conflict resolution, completion errors and completion, the summary export download (compared byte for byte with the route and the vectors), the Part 4 composer (draft, edit, reload, copy, `mailto:`, clear), keyboard operation, axe-core WCAG checks, screenshots at 375/768/1280 px into `docs/evidence/screenshots/`. Needs `npm install` (Playwright and axe-core are dev dependencies) and a Chromium that Playwright can find (`npx playwright install chromium` where it is not pre-installed). |
| `npm run test:admin` | Phase 6: `tests/node/admin-publish.test.mjs` (the publish route), `tests/node/admin-instrument.test.mjs` (HTTP checks of every administration route: 401/403/CSRF on each, import with its validation summary, the body contracts and the 413 cap, preview equal to the runtime model, clone + edit + compare, stale-edit refusal, retire with a historical walk that still opens and saves, the only-version confirmation, the placeholder queue, discard) and `tests/node/browser-admin.test.mjs` (Playwright: an admin-only user lands on administration, file upload and the summary, preview with conditional behavior and no writes, new draft + prompt edit + compare with markup kept as text, publish and retire confirmations, the placeholder queue, keyboard, axe-core and 375/768 px; screenshots `admin-*.png`). Fixtures use their own instrument codes and never publish or retire `ICFWALK`. The CFML twins run inside `npm run test:cfml` (`InstrumentAdministrationTest`, `DraftEditorTest`, `InstrumentVersionComparerTest`, `RetireConcurrencyBarrierTest`). |
| `npm run test:workbook` | The Excel round-trip's converter (`tests/node/workbook.test.mjs`): the aligned workbook in `config/`, LibreOffice-saved fixtures in `tests/fixtures/workbooks`, round trips, value handling, problems by cell, hostile files, and locating server problems. Needs nothing running. |
| `npm run test:reports` | Phase 7: `tests/node/reports.test.mjs` (static checks that the report repository names no narrative, identifying or teacher column and that the report code carries no instrument content; HTTP checks of `/api/reports/*` -- authentication, role separation, organizational scope, exclusions in the payload and the CSV, the read-only contract, the CSV download contract, injection payloads) and `tests/node/browser-reports.test.mjs` (Playwright: report-only landing without any walk request, filters, answered-only averages, the CSV download against the route, error announcement, My walks / Reports navigation, stored markup rendered as text, keyboard, axe-core and 375/768 px; screenshots `reports-desktop.png` and `reports-phone.png`). Same prerequisites as `test:auth`, plus Playwright for the browser file. The CFML twins run inside `npm run test:cfml` (`?filter=Report`: `ReportServiceTest` and the deterministic `ReportCoherenceTest`). |
| `npm test` | Everything above, plus `tests/node/browser-export.test.mjs`. |
| `node --test tests/node/browser-export.test.mjs` | Phase 5 correction: the export's flush-and-path-selection rules (a save in flight with an edit queued behind it, a definitive 4xx, a conflict, an HTTP 5xx, a genuine transport failure, a 200 that is not JSON, a 200 that is not a walk, a body that fails after its headers, a clean export, a read-only viewer). Runs against `tests/node/export-harness.mjs`, which serves the shipped browser modules and the real shell against a scripted API, so it needs **only Playwright**: no application, no database, no maintenance token. |

### Requiring the application: `ICFWALK_REQUIRE_APP`

Most of the suite needs the running application, and a test that needs it and cannot reach it has
three possible outcomes, not two. Leave `ICFWALK_REQUIRE_APP` unset for an optional local run and
those tests report as explicit skips naming the reason. Set `ICFWALK_REQUIRE_APP=1` for the full
integration or release-verification profile, where an application that was expected and is not
reachable **fails the run** instead of being quietly absent:

```bash
tools/runtime/mssql-up.sh
tools/runtime/lucee-up.sh
ICFWALK_REQUIRE_APP=1 npm test
```

`tests/node/no-mail.test.mjs` is the gate that enforces this today: its four static scans always
run, and its live route probe is a skip or a failure but never a vacuous pass.

The browser suites write their screenshots into `docs/evidence/screenshots/` by default, and
Playwright's PNG bytes differ from run to run on the same machine. A release gate that has to prove
it ran against an exact, clean commit points them outside the repository, so running the gate does
not change the tree it is proving:

```bash
ICFWALK_REQUIRE_APP=1 ICFWALK_SCREENSHOT_DIR=/some/dir/outside/the/repo npm test
```

### Regenerating and reviewing the summary vectors (Phase 5 tooling, not part of `npm test`)

`tests/fixtures/summary-vectors.json` is the parity contract between `src/walks/WalkSummaryFormatter.cfc`
and `app/assets/js/summary.js`. Change either formatter's output on purpose and the vectors have to
be regenerated and re-reviewed; change it by accident and both suites fail, which is the point.

```bash
npm run vectors:summary:check    # fails if the fixture is stale (needs the running app)
npm run vectors:summary          # regenerate from the SERVED render model with the JS formatter
npm run oracle:summary           # replay every vector through source/current-prototype.html
npm run oracle:summary -- --verbose
```

`oracle:summary` launches Chromium on the prototype, rebuilds each vector's state in the
prototype's own shape, and diffs its `buildSummaryText()` / `generateEmailDraftFor()` output against
the fixture. Every difference must be one of the deviations recorded in `BUILD_STATUS.md` (hidden
values excluded, the content-area heading, the doubled trailing colon, yes/no capitalization);
anything else is reported as UNEXPLAINED and exits non-zero. Never bless a vector the oracle cannot
account for.

The CFML suite can also be triggered directly:

```bash
curl -sS -X POST -H "X-ICFWalk-Maintenance-Token: $ICFWALK_MAINTENANCE_TOKEN" \
  http://127.0.0.1:8888/index.cfm/api/maintenance/tests/run
```

## Opening the application in a browser (development)

The page lives at `http://127.0.0.1:8888/index.cfm/`. With `ICFWALK_SSO_MODE=development` the
identity comes from the `X-ICFWalk-Dev-Subject` request header, which a normal browser does not
send; use a header-injecting browser extension, a local reverse proxy that adds the header, or the
Playwright harness (`npm run test:browser`, which also writes screenshots). In production the SSO
gateway asserts the identity headers instead. The signed-in subject needs a walk, report, or
instrument role (see the bootstrap commands above) or the shell answers 403.

## Backups and migrations

Back up before every migration. `001_schema.sql` refuses to run against a database that already
has `icf` tables; changes to an existing installation ship as new, reviewed, transactional scripts
(`database/00N_*.sql`), never by editing the supplied scripts. `002_alignment_patch.sql` is
idempotent and safe to re-run.
