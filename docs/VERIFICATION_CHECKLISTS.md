# Target-platform verification checklists

Phase 8 verified ICFWalk on Adobe ColdFusion 2023 (Update 25, Adobe's container image) and on Lucee
6.2.8 against Microsoft SQL Server 2022, in Chromium, with automated accessibility checks. Some of the
production target could not be reached from the build environment. Each item below is **NOT TESTABLE
HERE** until someone with that platform runs it. Each is a checklist a person can follow exactly, and
each ends in an evidence slot: fill it in, keep the files it names, and record the outcome in
`docs/ACCEPTANCE_TRACKING.md`. Nothing here is a PASS until that is done.

Use synthetic data only. Never record production credentials, real staff or student names, walk
narratives or secrets in any of the evidence below.

## 1. Adobe ColdFusion 2023 with its own SQL Server driver, behind IIS or Apache

**Why it was not tested here.** ColdFusion 2023 ships its SQL Server driver (DataDirect, driver name
`MSSQLServer`) as the `sqlserver` package, which `cfpm` downloads from `www.adobe.com`. The build
environment's network policy refused that host, so the ColdFusion runs used Microsoft's JDBC driver
12.10.2 as an administrator-defined "Other" datasource, and ColdFusion's built-in web server (Tomcat,
port 8500) instead of IIS or Apache with the ColdFusion connector.

**Steps.**

1. On the target server, install the `sqlserver` package (ColdFusion Administrator, Package Manager,
   or `cfpm install sqlserver`) and restart ColdFusion.
2. Deploy the release as `docs/OPERATIONS.md`, "Clean installation", describes: the site's document
   root is `<release>/app`; the front-door rule of "Web server" is in place.
3. Configure the datasource one of the two documented ways and run the suite against each you intend
   to support:
   - Option A: a datasource named by `ICFWALK_DATASOURCE` in the Administrator, driver "Microsoft SQL
     Server", encryption on, least-privilege login (`docs/OPERATIONS.md`, "Database logins");
   - Option B: `ICFWALK_DB_HOST/PORT/NAME/USER/PASSWORD` in the environment, so `Application.cfc`
     defines the datasource with driver `MSSQLServer` itself.
4. On a **test** deployment with `ICFWALK_ENVIRONMENT=development`, the development identity stub,
   maintenance and the test route enabled (never on production), run from a machine that can reach it:
   `ICFWALK_BASE_URL=https://<test host> ICFWALK_REQUIRE_APP=1 ICFWALK_SCREENSHOT_DIR=<outside the repo> npm test`.
5. Check the served shell's `data-api-base` (view source of `/index.cfm/`): it must equal
   `<site prefix>/index.cfm/api` under the connector (`ShellController.basePrefix` reads `cgi.script_name`).
6. Request `/Application.cfc`, `/index.cfm/../Application.cfc`, `/assets/../Application.cfc` and a
   made-up `/x.cfm`: each must be 404 from the web server or the application's JSON 404, never
   ColdFusion's error page.

**Expected.** The totals of the Phase 8 gate (see `docs/evidence/phase8/`), 0 failed, 0 skipped, on
both datasource options; steps 5 and 6 as stated.

**Evidence slot.**

| Date | Who | ColdFusion update / driver | Web server + connector | Datasource option | Node totals | CFML totals | Transcript file | Result |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| | | | | | | | | NOT TESTABLE HERE |

## 2. Microsoft SQL Server 2016

**Why it was not tested here.** SQL Server 2016 runs on Windows only; no image of it runs in the build
environment. Every database result in this repository is SQL Server 2022 (16.0.4295.3).

**Steps.**

1. On a SQL Server 2016 instance (SP3 or later), create an empty database with compatibility level 130.
2. `node scripts/db/apply-schema.mjs` with `ICFWALK_DB_*` pointing at it, then re-apply `002` to `007`
   one by one (`--only 00N`) and confirm `--only 001` is refused (error 50001).
3. `npm run test:db`.
4. Run the full suite against an application pointed at that database (checklist 1, step 4).
5. Run `tests/ops/backup-restore.sh` and `tests/ops/upgrade-001-007.sh` against the instance
   (`docs/OPERATIONS.md`, "Backup and restore" and "Migrations").

**Expected.** Every script commits; the same totals as the Phase 8 gate; the scenario scripts end with
`SCENARIO PASSED`.

**Evidence slot.**

| Date | Who | SQL Server build (`SELECT @@VERSION`) | Compatibility level | test:db | Suite totals | Scenarios | Transcript file | Result |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| | | | | | | | | NOT TESTABLE HERE |

## 3. Request-size limits at IIS or Apache and at the ColdFusion connector

**Why it was not tested here.** No IIS, Apache or ColdFusion connector exists in the build environment.
The application's own limits (5,000,000 bytes for an instrument import, 20,000,000 bytes for anything
else, enforced before a body is parsed) are tested on Lucee and on ColdFusion's built-in server.

**Steps.** With the limits of `docs/OPERATIONS.md`, "Web server", in place, from a machine that can
reach the site:

1. Send `POST /index.cfm/api/admin/instrument/import` with a declared `Content-Length: 5000001` and a
   valid session, CSRF token and `instrument.manage`: expect 413 `DOCUMENT_TOO_LARGE`.
2. Send `PUT /index.cfm/api/walks/<any id>` declaring `Content-Length: 20000001`: expect 413
   `PAYLOAD_TOO_LARGE`, from the application or the web server (record which).
3. Send the same with `Content-Length: 30000001` (over IIS's default of 30,000,000): expect a refusal
   by the web server before ColdFusion (IIS 404.13, Apache 413).
4. Send a chunked body that never ends to the same route: the connection must be closed by a timeout
   configured on the web server (record it).

**Evidence slot.**

| Date | Who | Web server / connector versions | Limits configured | 1 | 2 | 3 | 4 | Transcript | Result |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| | | | | | | | | | NOT TESTABLE HERE |

## 4. Microsoft Excel round trip

**Why it was not tested here.** Microsoft Excel does not run in the build environment. The workbook
converter is tested against files written by LibreOffice Calc 24.2 (`tests/fixtures/workbooks/`) and
against the aligned workbook in `config/`, which other software wrote.

**Steps** (Excel for Microsoft 365, desktop, current channel; record the build number):

1. In the administration view, **Download** the current version as an Excel workbook.
2. Open it in Excel. Confirm the Start Here sheet reads correctly and no cell shows `#NAME?`, `#VALUE!`
   or a formula. Save it as a new file with **no change** (File, Save As, Excel Workbook).
3. **Import** that file under a new draft label. Expect a DRAFT whose comparison with the source
   version shows **no change**.
4. Open the downloaded workbook again. Make exactly these edits and save:
   - `item_definition`, item `prek_k_q1`: prompt "Students can describe today's learning goal.",
     review_status "Reviewed";
   - item `prek_k_q2`: display_order typed as `15`;
   - item `prek_k_q3`: required typed as `TRUE`;
   - `dimension_value`, `abbott_middle_school`: label typed as the number 2024;
   - `response_option`: a new row `opt_yes_no_maybe` / "Maybe" below the others.
5. Import it as another draft. Expect the comparison to show exactly those five edits (the same five
   `tests/node/workbook.test.mjs` asserts for the LibreOffice fixture).
6. Enter `=1+1` into a prompt cell, save and import: the text `=1+1` must arrive as text or the import
   must name the cell as a problem; it must never import `2`.
7. Discard the drafts.

**Evidence slot.**

| Date | Who | Excel build | 2 | 3 | 5 | 6 | Files kept (synthetic) | Result |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| | | | | | | | | NOT TESTABLE HERE |

## 5. A real screen reader

**Why it was not tested here.** No screen reader runs in the build environment. Automated evidence:
axe-core (WCAG 2.0/2.1 A and AA) on every view and state, keyboard-only operation in Chromium, and the
accessibility tree Chromium computes (`docs/evidence/phase8/`).

**Steps.** NVDA 2024 or later with Chrome or Edge on Windows, and VoiceOver with Safari on macOS or
iOS. Synthetic fixture users only. For each: sign in as a school walker.

1. My Walks: the heading, the empty state, **New walk**, each card's title, school, date and relative
   time are read; **Open** and **Delete** are announced with the walk they act on.
2. A new walk: move through the accordions with the screen reader's heading and button navigation;
   each section's expanded or collapsed state is announced.
3. Rate a question: the rating group's name (the question), each option's name and selection state,
   and the definition toggle are announced.
4. Type in a notes field: after 700 ms "Saving..." then "All changes saved" is announced without
   moving focus.
5. Disconnect the network and type: the failure message and **Retry** are announced; reconnect and
   Retry: "All changes saved" is announced.
6. **Complete** with required answers missing: the error summary is announced; each error link moves
   focus to its field, whose error text is announced.
7. Open the same walk in a second browser, save there, then save in the first: the conflict dialog is
   announced with its title and description, and focus is on its primary action.
8. Part 4 email draft: the part checkboxes are a named group; To, Subject and Message are named; Copy
   announces its result.
9. Reports (a report-only user): the filters are named, running a report announces progress and the
   result, and each table's caption and column headers are read.
10. Instrument administration (an instrument administrator): the version list, the Publish and Retire
    confirmations (announced as dialogs, focus on Cancel), the placeholder queue and the wording editor.

**Evidence slot.**

| Date | Who | Screen reader + version | Browser + version | Steps passed | Issues found (with severity) | Result |
| --- | --- | --- | --- | --- | --- | --- |
| | | | | | | NOT TESTABLE HERE |

## 6. The district SSO gateway, TLS and the production cookie

**Why it was not tested here.** The identity provider, the gateway product and the hosting topology
are open decisions (`docs/OPEN_DECISIONS.md`). Phase 8 exercised the production configuration on the
verification runtimes: the header adapter trusting only listed proxy addresses and a shared secret, a
refused start for every unsafe setting, and the session cookie flags (`docs/evidence/phase8/`).

**Steps**, on the staging deployment behind the real gateway:

1. Sign in through the gateway. The session cookie carries `Secure`, `HttpOnly` and `SameSite=Lax`
   and no expiry (browser developer tools).
2. From a machine that is not the gateway, send a request to the site with the identity headers
   (`ICFWALK_SSO_SUBJECT_HEADER` etc.) set to an administrator's subject: it must be answered 401
   (the gateway strips those headers from client requests, and the application trusts only
   `ICFWALK_SSO_TRUSTED_PROXIES`).
3. Leave a walk open without a request for longer than `ICFWALK_SESSION_TIMEOUT_MINUTES`, then type:
   the save succeeds without a reload (P8-01), as the same person.
4. Sign out of the gateway in the same browser and sign in as someone else, then type in the walk
   still open from step 3: the page must say someone else is signed in and send nothing.
5. `https://` only: `http://` is redirected or refused at the gateway; the response carries
   `Strict-Transport-Security` if the district's policy requires it (a gateway setting).
6. When the gateway's own sign-in expires, a background save must be answered 401 (or the gateway's
   equivalent), never a redirect the page cannot follow: record what the gateway does.

**Evidence slot.**

| Date | Who | Gateway product + version | Identity provider | 1 | 2 | 3 | 4 | 5 | 6 | Result |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| | | | | | | | | | | NOT TESTABLE HERE |

## 7. Performance acceptance

**Why it is open.** No business service level has been set, and Phase 8 does not invent one. The
synthetic workload, its sizes, timings and query plans are in `docs/evidence/phase8/` and
`docs/OPERATIONS.md`, "Capacity and performance". The owner approves explicit criteria (for example, a
95th-percentile autosave time at a stated concurrency and data size) and then runs
`node tests/perf/workload.mjs` on the production-sized environment against them.

**Evidence slot.**

| Date | Approved criteria (who, when) | Environment | Data size | Concurrency | Measured | Result |
| --- | --- | --- | --- | --- | --- | --- |
| | | | | | | NOT TESTABLE HERE |
