// Phase 8 operations: an installation upgraded with its data, a release, and a rollback.
//
//   1. The accepted Phase 6 release (158debc) runs on a new database at migration 006 and makes real
//      data through its own API: org units, people and roles, the instrument seeded and published,
//      walks in every state (draft, completed, completed then edited, voided).
//   2. Migrations 007 and 008 -- the ones after Phase 6 -- are applied to that database. Every table
//      that existed before is compared row for row: 007 is additive and must change nothing that
//      exists; 008 adds icf.walk_dimension_value.selection_ordinal (0 on every existing row) and
//      changes no other column of it, nor any other table.
//   3. This tree (the release) runs on the upgraded database: every walk opens, a draft saves, a
//      completed walk takes a post-completion edit, a voided walk refuses a save, My Walks lists,
//      the summary downloads, a live report runs and a report release is created and read.
//   4. Rollback: the frozen Phase 0-7 release (68f9026, which already has 007) runs on the same
//      database, now holding data written by this release, and does the same.
//   5. Several values of one field (instrument revision 2026-10-14, step 2): this release publishes
//      the 2026-10-14 version, whose visit fields are checkboxes, records walks that hold several
//      values of Visit timing, reports on them and releases the first of their two days.
//   6. Rollback past step 2: the release before it (step 1, 36f9db0, whose walk and report code is
//      the Phase 8 release's) on those walks. It shows one of a field's values; a save that leaves
//      the field alone goes through and keeps every value; a change to the field fails and writes
//      nothing; its live report counts a walk under each value and once per value among the
//      answered; it reads this release's release with each combination left out of the values; a
//      release it creates counts a walk under each value. docs/OPERATIONS.md, 5.1, says the same.
//
// Each release is extracted with `git archive` into a scratch directory and served by its own Lucee
// instance (the jars in .runtime/jars), so nothing here touches the working tree or the running
// application. Needs Java, the SQL Server administrative login and a free port (ICFWALK_UPGRADE_PORT,
// default 8891).
//
//   ICFWALK_REQUIRE_APP=1 ICFWALK_EVIDENCE_DIR=<dir> node --test tests/ops/upgrade-and-rollback.test.mjs
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync, execSync, spawn } from "node:child_process";
import sql from "mssql";
import { applyScript, connectionConfig, hasDatabaseConfig, loadRuntimeEnv, readScript, requireApp, root } from "../node/helpers.mjs";

const env = loadRuntimeEnv();
const token = env.ICFWALK_MAINTENANCE_TOKEN || "";
const PHASE6 = "158debca5da2c4f3a07f602689cd08af9db9bd6e";
const FROZEN = "68f9026d39ba0ff44d12d6398c5e933971dad2f4";
const PREVIOUS = "36f9db09f595294bdc5f8e151706dbb8dc7b758b";
const port = Number(env.ICFWALK_UPGRADE_PORT || 8891);
const tag = `p8upg${Date.now().toString(36)}`;
const database = `icfwalk_${tag}`;
const work = fs.mkdtempSync(path.join(os.tmpdir(), "icfwalk-upgrade-"));
const jars = path.join(root, ".runtime", "jars");
const evidence = { startedAt: new Date().toISOString(), database, phase6: PHASE6, frozen: FROZEN, previous: PREVIOUS, port, steps: {} };

const missing = !hasDatabaseConfig(env) ? "no database configuration" : !token ? "no maintenance token"
  : !fs.existsSync(path.join(jars, "jetty-runner.jar")) ? "no Lucee jars in .runtime/jars (run tools/runtime/lucee-up.sh once)" : false;
if (requireApp(env) && missing) throw new Error(`ICFWALK_REQUIRE_APP is set but ${missing}`);
const skip = missing;

let master;
let server = null;
const base = `http://127.0.0.1:${port}`;

// ---- releases -----------------------------------------------------------------------------------------

function extract(commit, name) {
  const dir = path.join(work, name);
  fs.mkdirSync(dir, { recursive: true });
  if (commit) execSync(`git -C "${root}" archive ${commit} | tar -x -C "${dir}"`);
  else execSync(`tar -C "${root}" --exclude=./node_modules --exclude=./.git --exclude=./.runtime --exclude=./app/WEB-INF -cf - . | tar -x -C "${dir}"`);
  const webInf = path.join(dir, "app", "WEB-INF", "lib");
  fs.mkdirSync(webInf, { recursive: true });
  for (const j of ["lucee-light.jar", "mssql-jdbc.jar"]) fs.copyFileSync(path.join(jars, j), path.join(webInf, j));
  fs.copyFileSync(path.join(dir, "tools", "runtime", "web.xml"), path.join(dir, "app", "WEB-INF", "web.xml"));
  const lines = fs.readFileSync(path.join(root, ".env"), "utf8").split("\n").filter((l) => !/^ICFWALK_(DB_NAME|PORT)=/.test(l));
  fs.writeFileSync(path.join(dir, ".env"), `${lines.join("\n")}\nICFWALK_DB_NAME=${database}\nICFWALK_PORT=${port}\n`, { mode: 0o600 });
  const mssqlEnv = path.join(root, ".runtime", "mssql.env");
  if (fs.existsSync(mssqlEnv)) { fs.mkdirSync(path.join(dir, ".runtime"), { recursive: true }); fs.copyFileSync(mssqlEnv, path.join(dir, ".runtime", "mssql.env")); }
  return dir;
}

async function health() {
  try {
    const r = await fetch(`${base}/index.cfm/api/health`, { signal: AbortSignal.timeout(10000) });
    return { status: r.status, body: await r.json() };
  } catch (e) { return { status: 0, error: String(e.cause?.code || e.message) }; }
}

async function start(dir, label) {
  const log = fs.openSync(path.join(work, `${label}.log`), "a");
  const child = spawn("java", ["-Xmx768m", `-Dlucee.base.dir=${path.join(dir, ".lucee")}`, "-jar", path.join(jars, "jetty-runner.jar"), "--port", String(port), "--path", "/", path.join(dir, "app")],
    { cwd: dir, env: { ...process.env, ICFWALK_DB_NAME: database, ICFWALK_ENV_FILE: path.join(dir, ".env"), LUCEE_ENABLE_BUNDLE_DOWNLOAD: "false", LUCEE_ADMIN_ENABLED: "false", LUCEE_REQUESTTIMEOUT: "600" }, stdio: ["ignore", log, log], detached: false });
  const t0 = Date.now();
  for (let i = 0; i < 180; i++) {
    const h = await health();
    if (h.status === 200 || h.status === 503) return { child, secondsToAnswer: (Date.now() - t0) / 1000, health: h.body };
    await new Promise((r) => setTimeout(r, 1000));
  }
  child.kill("SIGKILL");
  throw new Error(`${label} did not answer on ${base}; see ${path.join(work, `${label}.log`)}`);
}

async function stop() {
  if (!server) return;
  const { child } = server;
  child.kill("SIGTERM");
  for (let i = 0; i < 60 && child.exitCode === null && child.signalCode === null; i++) await new Promise((r) => setTimeout(r, 500));
  if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
  for (let i = 0; i < 60 && (await health()).status !== 0; i++) await new Promise((r) => setTimeout(r, 500));
  server = null;
}

// ---- HTTP against the release under test ----------------------------------------------------------------

async function maintenance(p, body) {
  const r = await fetch(`${base}/index.cfm${p}`, { method: "POST", headers: { "Content-Type": "application/json", Accept: "application/json", "X-ICFWalk-Maintenance-Token": token }, body: JSON.stringify(body ?? {}) });
  const text = await r.text();
  assert.ok(r.status === 200 || r.status === 201, `${p} ${r.status}: ${text.slice(0, 400)}`);
  return JSON.parse(text);
}

function client(subject) {
  const cookies = new Map();
  let csrf = "";
  const call = async (method, p, body) => {
    const headers = { Accept: "application/json", "X-ICFWalk-Dev-Subject": subject };
    if (body !== undefined) headers["Content-Type"] = "application/json";
    if (csrf && method !== "GET") headers["X-ICFWalk-CSRF-Token"] = csrf;
    const cookie = [...cookies.entries()].map(([k, v]) => `${k}=${v}`).join("; ");
    if (cookie) headers.Cookie = cookie;
    const response = await fetch(`${base}/index.cfm${p}`, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
    for (const line of response.headers.getSetCookie()) {
      const [pair] = line.split(";");
      const eq = pair.indexOf("=");
      cookies.set(pair.slice(0, eq).trim(), pair.slice(eq + 1).trim());
    }
    const text = await response.text();
    let json = null;
    try { json = JSON.parse(text); } catch { json = null; }
    if (json && json.csrfToken) csrf = json.csrfToken;
    return { status: response.status, json, text };
  };
  return { call };
}

const REQUIRED = { p1q1: { storedCode: "Partial" }, p1q2: { storedCode: "Retrieval" }, p1q3: { storedCode: "Analysis" }, part1_adopted_pacing: { storedCode: "on" },
  part1_adopted_ac1: { storedCode: "3" }, part1_adopted_ac2: { storedCode: "4" }, part1_targettask_tt1: { storedCode: "5" }, part1_targettask_tt2: { storedCode: "2" } };

async function makeWalk(c, unitId, { complete = false, rating = "4", note = "note", date = "2026-02-10" } = {}) {
  const created = await c.call("POST", "/api/walks", { orgUnitId: unitId, clientMutationId: crypto.randomUUID() });
  assert.equal(created.status, 201, created.text.slice(0, 300));
  const saved = await c.call("PUT", `/api/walks/${created.json.walk.id}`, { rowVersion: created.json.walk.rowVersion, clientMutationId: crypto.randomUUID(),
    dimensions: { date: { dateValue: date }, grade: { selectedValueCode: "7" }, school: { selectedValueCode: "abbott_middle_school" } },
    responses: { ...REQUIRED, comp_s1_q1: { storedCode: rating }, comp_s1_notes: { textValue: note } } });
  assert.equal(saved.status, 200, saved.text.slice(0, 300));
  if (!complete) return { id: created.json.walk.id, rowVersion: saved.json.walk.rowVersion };
  const done = await c.call("POST", `/api/walks/${created.json.walk.id}/complete`, { rowVersion: saved.json.walk.rowVersion, clientMutationId: crypto.randomUUID() });
  assert.equal(done.status, 200, done.text.slice(0, 300));
  return { id: created.json.walk.id, rowVersion: done.json.walk.rowVersion };
}

/** Everything the icf schema holds, table by table: rows and an order-independent checksum. */
async function fingerprint(tables, { except = {} } = {}) {
  const pool = await new sql.ConnectionPool(connectionConfig(env, database, true)).connect();
  try {
    const names = tables || (await pool.request().query("SELECT name FROM sys.tables WHERE schema_id = SCHEMA_ID(N'icf')")).recordset.map((r) => r.name).sort();
    const out = {};
    for (const t of names) {
      // `except` names columns a later migration added, so a table's original columns are compared.
      let columns = "*";
      if (except[t]) {
        const all = (await pool.request().query(`SELECT name FROM sys.columns WHERE object_id = OBJECT_ID(N'[icf].[${t}]') ORDER BY column_id`)).recordset.map((r) => r.name);
        columns = all.filter((c) => !except[t].includes(c)).map((c) => `[${c}]`).join(", ");
      }
      const [row] = (await pool.request().query(`SELECT COUNT_BIG(*) AS n, CHECKSUM_AGG(BINARY_CHECKSUM(${columns})) AS c FROM [icf].[${t}]`)).recordset;
      out[t] = `${row.n}:${row.c}`;
    }
    return out;
  } finally { await pool.close(); }
}

/** What a release under test must still do with the data it finds. */
async function exercise(label, walks) {
  const record = {};
  const walker = client(`${tag}-walker`);
  const me = await walker.call("GET", "/api/me");
  assert.equal(me.status, 200, `${label}: ${me.text.slice(0, 200)}`);
  const list = await walker.call("GET", "/api/walks");
  assert.equal(list.status, 200);
  const listed = new Set(list.json.walks.map((w) => w.id.toUpperCase()));
  for (const w of walks.filter((x) => x.status !== "VOIDED")) assert.ok(listed.has(w.id.toUpperCase()), `${label}: My Walks lists ${w.kind}`);
  record.listed = list.json.walks.length;
  for (const w of walks) {
    const opened = await walker.call("GET", `/api/walks/${w.id}`);
    assert.equal(opened.status, 200, `${label}: ${w.kind} opens: ${opened.text.slice(0, 200)}`);
    assert.equal(opened.json.walk.status, w.status, `${label}: ${w.kind} keeps its status`);
    assert.equal(opened.json.walk.state.responses.comp_s1_notes.textValue, w.note, `${label}: ${w.kind} keeps its note`);
    const model = await walker.call("GET", `/api/walks/${w.id}/instrument`);
    assert.equal(model.status, 200, `${label}: ${w.kind} renders its pinned version`);
    w.rowVersion = opened.json.walk.rowVersion;
  }
  const draft = walks.find((w) => w.kind === "draft");
  const note = `${label} edit ${crypto.randomUUID().slice(0, 8)}`;
  const current = await walker.call("GET", `/api/walks/${draft.id}`);
  const saved = await walker.call("PUT", `/api/walks/${draft.id}`, { rowVersion: current.json.walk.rowVersion, clientMutationId: crypto.randomUUID(), dimensions: current.json.walk.state.dimensions, responses: { ...stripStates(current.json.walk.state.responses), comp_s1_notes: { textValue: note } } });
  assert.equal(saved.status, 200, `${label}: the draft saves: ${saved.text.slice(0, 300)}`);
  draft.note = note;
  const completed = walks.find((w) => w.kind === "completed");
  const cur2 = await walker.call("GET", `/api/walks/${completed.id}`);
  const edit = await walker.call("PUT", `/api/walks/${completed.id}`, { rowVersion: cur2.json.walk.rowVersion, clientMutationId: crypto.randomUUID(), dimensions: cur2.json.walk.state.dimensions, responses: { ...stripStates(cur2.json.walk.state.responses), comp_s1_q1: { storedCode: cur2.json.walk.state.responses.comp_s1_q1.storedCode === "5" ? "4" : "5" } } });
  assert.equal(edit.status, 200, `${label}: a completed walk takes a post-completion edit: ${edit.text.slice(0, 300)}`);
  const voided = walks.find((w) => w.kind === "voided");
  const cur3 = await walker.call("GET", `/api/walks/${voided.id}`);
  const refused = await walker.call("PUT", `/api/walks/${voided.id}`, { rowVersion: cur3.json.walk.rowVersion, clientMutationId: crypto.randomUUID(), dimensions: {}, responses: {} });
  assert.equal(refused.status, 409, `${label}: a voided walk refuses a save`);
  const summary = await fetch(`${base}/index.cfm/api/walks/${completed.id}/summary`, { headers: { "X-ICFWalk-Dev-Subject": `${tag}-walker` } });
  assert.equal(summary.status, 200, `${label}: the summary downloads`);
  const reporter = client(`${tag}-district`);
  const rme = await reporter.call("GET", "/api/me");
  const districtId = Object.keys(rme.json.orgUnits).find((id) => rme.json.orgUnits[id].code === `${tag}-district`);
  const version = (await reporter.call("GET", "/api/instrument/current")).json.version.versionId;
  const report = await reporter.call("GET", `/api/reports/aggregate?versionId=${version}&orgUnitId=${districtId}`);
  assert.equal(report.status, 200, `${label}: a live report runs: ${report.text.slice(0, 300)}`);
  record.reportWalks = report.json.report?.population?.walks ?? report.json.population?.walks ?? null;
  const health = await fetch(`${base}/index.cfm/api/health`);
  record.health = (await health.json()).checks;
  return { record, reporter, version, districtId };
}

function stripStates(responses) {
  const out = {};
  for (const [k, v] of Object.entries(responses)) {
    if (!v || typeof v !== "object") continue;
    const { state, ...rest } = v;
    out[k] = rest;
  }
  return out;
}

// ---- several values of one field (steps 5 and 6) ---------------------------------------------------------

const DAY1 = "2026-04-15";
const DAY2 = "2026-04-16";
const BEGINNING = "beginning_of_lesson";
const MIDDLE = "middle_of_the_lesson";
const END = "end_of_the_lesson";
const REQUIRED_1014 = { p1q1: { storedCode: "Yes" }, p1q2: { storedCode: "Analysis" }, p1q3: { storedCode: "Comprehension" }, part1_targettask_tt1: { storedCode: "4" },
  part1_targettask_tt2: { storedCode: "3" }, part1_adopted_pacing: { storedCode: "notevident" }, part1_adopted_ac1: { storedCode: "2" }, part1_adopted_ac2: { storedCode: "1" } };

async function query(text, params = {}) {
  const pool = await new sql.ConnectionPool(connectionConfig(env, database, true)).connect();
  try {
    const request = pool.request();
    for (const [k, v] of Object.entries(params)) request.input(k, v);
    return (await request.query(text)).recordset;
  } finally { await pool.close(); }
}

/** A walk's Visit timing values, in the order it holds them. */
async function timingValues(walkId) {
  const rows = await query(`SELECT dv.value_code FROM icf.walk_dimension_value x JOIN icf.dimension_definition d ON d.dimension_id = x.dimension_id
    JOIN icf.dimension_value dv ON dv.value_id = x.selected_value_id WHERE x.walk_id = @w AND d.code = N'visitTiming' ORDER BY x.selection_ordinal`, { w: walkId });
  return rows.map((r) => r.value_code);
}

/** Everything a save writes for one walk: its row version, mutations, revisions, values and answers. */
async function walkStamp(walkId) {
  const [row] = await query(`SELECT CONVERT(bigint, w.row_version) AS rv,
      (SELECT COUNT(*) FROM icf.walk_mutation m WHERE m.walk_id = w.walk_id) AS mutations,
      (SELECT COUNT(*) FROM icf.walk_revision r WHERE r.walk_id = w.walk_id) AS revisions,
      (SELECT CHECKSUM_AGG(BINARY_CHECKSUM(*)) FROM icf.walk_dimension_value x WHERE x.walk_id = w.walk_id) AS dims,
      (SELECT CHECKSUM_AGG(BINARY_CHECKSUM(*)) FROM icf.walk_response r WHERE r.walk_id = w.walk_id) AS responses
    FROM icf.walk w WHERE w.walk_id = @w`, { w: walkId });
  return { ...row, rv: String(row.rv) };
}

/** A release's stored Visit timing values, by category code, nonzero only. */
async function releasedTiming(releaseId) {
  const rows = await query(`SELECT category_code, SUM(responses) AS n FROM icf.report_release_cell WHERE release_id = @r AND subject_type = N'DIMENSION'
    AND subject_key = N'visitTiming' AND category_type = N'VALUE' GROUP BY category_code HAVING SUM(responses) > 0`, { r: releaseId });
  return Object.fromEntries(rows.map((r) => [r.category_code, r.n]));
}

function timingOf(body) { return (body.report ?? body).dimensions.find((d) => d.code === "visitTiming"); }
function walksOf(body) { return (body.report ?? body).population.walks; }
function figures(d) {
  const of = (code) => d.values.find((v) => v.code === code)?.walks ?? null;
  return { beginning: of(BEGINNING), middle: of(MIDDLE), end: of(END), answered: d.states.ANSWERED };
}

/** Step 5, on this release: the 2026-10-14 version published, walks holding several values, a release. */
async function recordSeveral(unit) {
  const imported = await maintenance("/api/maintenance/instrument/import", { configFile: "instrument-config-2026-10-14.json" });
  const admin = client(`${tag}-admin`);
  await admin.call("GET", "/api/me");
  const pub = await admin.call("POST", `/api/admin/instrument/versions/${imported.versionId}/publish`);
  assert.equal(pub.status, 200, pub.text.slice(0, 300));
  const walker = client(`${tag}-walker`);
  await walker.call("GET", "/api/me");
  const made = [];
  for (const [day, codes, n] of [[DAY1, [BEGINNING], 3], [DAY1, [MIDDLE], 3], [DAY1, [BEGINNING, MIDDLE], 3], [DAY2, [MIDDLE, BEGINNING], 1]]) {
    for (let i = 0; i < n; i++) {
      const created = await walker.call("POST", "/api/walks", { orgUnitId: unit, clientMutationId: crypto.randomUUID() });
      assert.equal(created.status, 201, created.text.slice(0, 300));
      const saved = await walker.call("PUT", `/api/walks/${created.json.walk.id}`, { rowVersion: created.json.walk.rowVersion, clientMutationId: crypto.randomUUID(),
        dimensions: { date: { dateValue: day }, visitTiming: { selectedValueCodes: codes } }, responses: REQUIRED_1014 });
      assert.equal(saved.status, 200, saved.text.slice(0, 300));
      const done = await walker.call("POST", `/api/walks/${created.json.walk.id}/complete`, { rowVersion: saved.json.walk.rowVersion, clientMutationId: crypto.randomUUID() });
      assert.equal(done.status, 200, done.text.slice(0, 300));
      made.push({ id: created.json.walk.id, day, codes });
    }
  }
  const both = made.find((w) => w.day === DAY2);
  assert.deepEqual(await timingValues(both.id), [BEGINNING, MIDDLE], "this release holds both values, in the version's order");
  const reporter = client(`${tag}-district`);
  const me = await reporter.call("GET", "/api/me");
  const districtId = Object.keys(me.json.orgUnits).find((id) => me.json.orgUnits[id].code === `${tag}-district`);
  const live = await reporter.call("GET", `/api/reports/aggregate?versionId=${imported.versionId}&orgUnitId=${districtId}`);
  assert.equal(live.status, 200, live.text.slice(0, 300));
  assert.equal(walksOf(live.json), 10);
  assert.equal(timingOf(live.json).multiple, true);
  assert.deepEqual(figures(timingOf(live.json)), { beginning: 7, middle: 7, end: 0, answered: 10 }, "this release: a walk under each of its values, once among the answered");
  const created = await reporter.call("POST", "/api/reports/releases", { observedFrom: DAY1, observedTo: DAY1 });
  assert.equal(created.status, 201, created.text.slice(0, 400));
  const releaseId = created.json.release?.releaseId ?? created.json.releaseId;
  assert.deepEqual(await releasedTiming(releaseId), { [BEGINNING]: 3, [MIDDLE]: 3, [`${BEGINNING}+${MIDDLE}`]: 3 }, "this release stores a combination as one category");
  const read = await reporter.call("GET", `/api/reports/aggregate?versionId=${imported.versionId}&orgUnitId=${districtId}&releaseId=${releaseId}`);
  assert.equal(read.status, 200, read.text.slice(0, 300));
  assert.deepEqual(figures(timingOf(read.json)), { beginning: 6, middle: 6, end: 0, answered: 9 }, "this release reads a value as the sum of the published combinations that hold it");
  return { versionId: imported.versionId, districtId, releaseId, both,
    record: { versionId: imported.versionId, walks: made.length, live: figures(timingOf(live.json)), releaseId, released: await releasedTiming(releaseId), read: figures(timingOf(read.json)) } };
}

/** Step 6, on the release before step 2. */
async function previousOnSeveral(several) {
  const record = {};
  const walker = client(`${tag}-walker`);
  await walker.call("GET", "/api/me");
  const id = several.both.id;
  const opened = await walker.call("GET", `/api/walks/${id}`);
  assert.equal(opened.status, 200, opened.text.slice(0, 300));
  const shown = opened.json.walk.state.dimensions.visitTiming;
  assert.ok([BEGINNING, MIDDLE].includes(shown.selectedValueCode) && !("selectedValueCodes" in shown), `it shows one of the values: ${JSON.stringify(shown)}`);
  record.shown = shown.selectedValueCode;
  const kept = await walker.call("PUT", `/api/walks/${id}`, { rowVersion: opened.json.walk.rowVersion, clientMutationId: crypto.randomUUID(),
    dimensions: opened.json.walk.state.dimensions, responses: { ...stripStates(opened.json.walk.state.responses), p1q1: { storedCode: "Partial" } } });
  assert.equal(kept.status, 200, `a save that leaves the field alone goes through: ${kept.text.slice(0, 300)}`);
  assert.deepEqual(await timingValues(id), [BEGINNING, MIDDLE], "and keeps both values");
  const again = await walker.call("GET", `/api/walks/${id}`);
  assert.equal(again.json.walk.state.responses.p1q1.storedCode, "Partial");
  const before = await walkStamp(id);
  const changed = await walker.call("PUT", `/api/walks/${id}`, { rowVersion: again.json.walk.rowVersion, clientMutationId: crypto.randomUUID(),
    dimensions: { ...again.json.walk.state.dimensions, visitTiming: { selectedValueCode: END } }, responses: stripStates(again.json.walk.state.responses) });
  assert.equal(changed.status, 500, `a change to the field fails: ${changed.text.slice(0, 300)}`);
  assert.equal(changed.json?.error?.code, "INTERNAL_ERROR");
  assert.deepEqual(await walkStamp(id), before, "and writes nothing");
  assert.deepEqual(await timingValues(id), [BEGINNING, MIDDLE]);
  record.changeStatus = changed.status;
  const reporter = client(`${tag}-district`);
  await reporter.call("GET", "/api/me");
  const live = await reporter.call("GET", `/api/reports/aggregate?versionId=${several.versionId}&orgUnitId=${several.districtId}`);
  assert.equal(live.status, 200, live.text.slice(0, 300));
  assert.equal(walksOf(live.json), 10);
  assert.deepEqual(figures(timingOf(live.json)), { beginning: 7, middle: 7, end: 0, answered: 14 }, "its live report: a walk under each value, and once per value among the answered");
  record.live = figures(timingOf(live.json));
  const read = await reporter.call("GET", `/api/reports/aggregate?versionId=${several.versionId}&orgUnitId=${several.districtId}&releaseId=${several.releaseId}`);
  assert.equal(read.status, 200, read.text.slice(0, 300));
  assert.deepEqual(figures(timingOf(read.json)), { beginning: 3, middle: 3, end: 0, answered: 9 }, "it reads this release's release: the combination is left out of the values, the answered are right");
  record.read = figures(timingOf(read.json));
  const created = await reporter.call("POST", "/api/reports/releases", { observedFrom: DAY2, observedTo: DAY2 });
  assert.equal(created.status, 201, created.text.slice(0, 400));
  const releaseId = created.json.release?.releaseId ?? created.json.releaseId;
  assert.deepEqual(await releasedTiming(releaseId), { [BEGINNING]: 1, [MIDDLE]: 1 }, "a release it creates counts the walk under each value: 2 for 1 walk");
  record.released = await releasedTiming(releaseId);
  return record;
}

before(async () => {
  if (skip) return;
  master = await new sql.ConnectionPool(connectionConfig(env, "master", true)).connect();
  await master.request().batch(`CREATE DATABASE [${database}]`);
});

after(async () => {
  await stop().catch(() => {});
  if (master) {
    if (env.ICFWALK_KEEP_UPGRADE_DB !== "1") await master.request().batch(`IF DB_ID(N'${database}') IS NOT NULL BEGIN ALTER DATABASE [${database}] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [${database}]; END`).catch(() => {});
    await master.close();
  }
  evidence.finishedAt = new Date().toISOString();
  evidence.workDirectory = work;
  if (env.ICFWALK_EVIDENCE_DIR) {
    fs.mkdirSync(env.ICFWALK_EVIDENCE_DIR, { recursive: true });
    fs.writeFileSync(path.join(env.ICFWALK_EVIDENCE_DIR, "upgrade-and-rollback.json"), `${JSON.stringify(evidence, null, 2)}\n`);
  }
});

const walks = [];

test("an installation made by the Phase 6 release upgrades with 007 and 008, changing nothing that existed, and this release serves it; the frozen release serves it after a rollback, and the release before step 2 keeps walks holding several values of a field", { skip, timeout: 3600000 }, async (t) => {
  // 1. Phase 6, on a database at 006.
  const phase6 = extract(PHASE6, "phase6");
  const pool = await new sql.ConnectionPool(connectionConfig(env, database, true)).connect();
  try {
    for (const name of ["001_schema.sql", "002_alignment_patch.sql", "003_walk_mutation.sql", "004_mutation_fingerprint.sql", "005_org_unit_dimension_map.sql", "006_version_scoped_dimensions.sql"]) {
      const r = await applyScript(pool, fs.readFileSync(path.join(phase6, "database", name), "utf8"));
      assert.ok(r.ok, `${name}: ${r.error?.message}`);
    }
  } finally { await pool.close(); }
  server = await start(phase6, "phase6");
  evidence.steps.phase6Start = { secondsToAnswer: server.secondsToAnswer, health: server.health };
  const seeded = await maintenance("/api/maintenance/instrument/import", {});
  await maintenance("/api/maintenance/org-units/import", { orgUnits: [
    { code: `${tag}-district`, type: "DISTRICT", name: "Upgrade district", parentCode: null },
    { code: `${tag}-school`, type: "SCHOOL", name: "Upgrade school", parentCode: `${tag}-district`, schoolValueCode: "abbott_middle_school" },
  ] });
  for (const [subject, role, unit, desc] of [[`${tag}-walker`, "SCHOOL_WALK_REPORT", `${tag}-school`, false], [`${tag}-district`, "DISTRICT_WALK_REPORT", `${tag}-district`, true], [`${tag}-admin`, "MASTER_INSTRUMENT_ADMIN", `${tag}-district`, false]]) {
    await maintenance("/api/maintenance/identity/provision-user", { subject, displayName: `Upgrade ${subject.split("-").pop()}` });
    await maintenance("/api/maintenance/identity/assign-role", { subject, roleCode: role, orgUnitCode: unit, includeDescendants: desc });
  }
  const admin = client(`${tag}-admin`);
  await admin.call("GET", "/api/me");
  const pub = await admin.call("POST", `/api/admin/instrument/versions/${seeded.versionId}/publish`);
  assert.equal(pub.status, 200, pub.text.slice(0, 300));
  const walker = client(`${tag}-walker`);
  const me = await walker.call("GET", "/api/me");
  const unit = Object.keys(me.json.orgUnits).find((id) => me.json.orgUnits[id].code === `${tag}-school`);
  const draft = await makeWalk(walker, unit, { note: "phase 6 draft" });
  walks.push({ kind: "draft", id: draft.id, status: "DRAFT", note: "phase 6 draft" });
  for (let i = 0; i < 3; i++) {
    const done = await makeWalk(walker, unit, { complete: true, rating: String(3 + i), note: `phase 6 completed ${i}` });
    walks.push({ kind: i === 0 ? "completed" : `completed ${i}`, id: done.id, status: "COMPLETED", note: `phase 6 completed ${i}` });
  }
  const edited = walks.find((w) => w.kind === "completed 1");
  const cur = await walker.call("GET", `/api/walks/${edited.id}`);
  const edit = await walker.call("PUT", `/api/walks/${edited.id}`, { rowVersion: cur.json.walk.rowVersion, clientMutationId: crypto.randomUUID(), dimensions: cur.json.walk.state.dimensions, responses: { ...stripStates(cur.json.walk.state.responses), comp_s1_q1: { storedCode: "1" } } });
  assert.equal(edit.status, 200, edit.text.slice(0, 300));
  const toVoid = await makeWalk(walker, unit, { note: "phase 6 voided" });
  const voided = await walker.call("POST", `/api/walks/${toVoid.id}/void`, { reason: "Upgrade exercise", rowVersion: toVoid.rowVersion, clientMutationId: crypto.randomUUID() });
  assert.equal(voided.status, 200, voided.text.slice(0, 300));
  walks.push({ kind: "voided", id: toVoid.id, status: "VOIDED", note: "phase 6 voided" });
  await stop();
  const at006 = await fingerprint();
  evidence.steps.phase6Data = { tables: Object.keys(at006).length, walks: at006.walk, responses: at006.walk_response, mutations: at006.walk_mutation, revisions: at006.walk_revision, audit: at006.audit_event };
  t.diagnostic(`Phase 6 made ${walks.length} walks; ${Object.keys(at006).length} tables`);

  // 2. The upgrade: 007, then 008.
  const up = await new sql.ConnectionPool(connectionConfig(env, database, true)).connect();
  let applied;
  try { applied = await applyScript(up, readScript("007_report_release.sql")); } finally { await up.close(); }
  assert.ok(applied.ok, applied.error?.message);
  const at007 = await fingerprint();
  for (const [table, value] of Object.entries(at006)) assert.equal(at007[table], value, `007 changed nothing in icf.${table}`);
  const added = Object.keys(at007).filter((k) => !(k in at006));
  assert.deepEqual(added.sort(), ["report_release", "report_release_block", "report_release_cell", "report_release_walk"]);
  const up008 = await new sql.ConnectionPool(connectionConfig(env, database, true)).connect();
  let applied008;
  let ordinals;
  try {
    applied008 = await applyScript(up008, readScript("008_multiple_dimension_values.sql"));
    ordinals = (await up008.request().query("SELECT COUNT(*) AS n, SUM(CASE WHEN selection_ordinal = 0 THEN 1 ELSE 0 END) AS zero FROM icf.walk_dimension_value")).recordset[0];
  } finally { await up008.close(); }
  assert.ok(applied008.ok, applied008.error?.message);
  const at008 = await fingerprint(Object.keys(at007), { except: { walk_dimension_value: ["selection_ordinal"] } });
  for (const [table, value] of Object.entries(at007)) assert.equal(at008[table], value, `008 changed nothing else in icf.${table}`);
  assert.ok(ordinals.n > 0 && ordinals.zero === ordinals.n, `every existing value is ordinal 0 (${ordinals.zero} of ${ordinals.n})`);
  evidence.steps.upgrade = { applied: ["007_report_release.sql", "008_multiple_dimension_values.sql"], tablesAdded: added, existingTablesUnchanged: Object.keys(at006).length, dimensionValuesAtOrdinalZero: ordinals.zero };

  // 3. This release on the upgraded database.
  const release = extract(null, "release");
  server = await start(release, "release");
  evidence.steps.releaseStart = { secondsToAnswer: server.secondsToAnswer, health: server.health };
  const onRelease = await exercise("release", walks);
  const releaseCreated = await onRelease.reporter.call("POST", "/api/reports/releases", { observedFrom: "2026-02-01", observedTo: "2026-02-28" });
  assert.equal(releaseCreated.status, 201, `a report release can be created on the upgraded data: ${releaseCreated.text.slice(0, 400)}`);
  const releaseId = releaseCreated.json.release?.releaseId ?? releaseCreated.json.releaseId;
  const later = client(`${tag}-walker`);
  await later.call("GET", "/api/me");
  const newer = await makeWalk(later, unit, { complete: true, rating: "2", note: "release completed", date: "2026-03-05" });
  walks.push({ kind: "made by the release", id: newer.id, status: "COMPLETED", note: "release completed" });
  evidence.steps.release = { ...onRelease.record, releaseCreated: releaseCreated.status, releaseId };
  await stop();

  // 4. Rollback to the frozen release, on the same database.
  const frozen = extract(FROZEN, "frozen");
  server = await start(frozen, "frozen");
  evidence.steps.rollbackStart = { secondsToAnswer: server.secondsToAnswer, health: server.health };
  const onFrozen = await exercise("rollback", walks);
  const read = await onFrozen.reporter.call("GET", `/api/reports/aggregate?versionId=${onFrozen.version}&orgUnitId=${onFrozen.districtId}&releaseId=${releaseId}`);
  assert.equal(read.status, 200, `the frozen release reads the release this release created: ${read.text.slice(0, 300)}`);
  evidence.steps.rollback = { ...onFrozen.record, releaseRead: read.status };
  await stop();

  // 5. Several values of one field, on this release.
  server = await start(release, "release-several");
  const several = await recordSeveral(unit);
  evidence.steps.several = several.record;
  await stop();

  // 6. Rolling back past step 2: the release before it, on those walks.
  const previous = extract(PREVIOUS, "previous");
  server = await start(previous, "previous");
  assert.equal(server.health?.status, "ok", `the release before step 2 is ready on the database at 008: ${JSON.stringify(server.health)}`);
  evidence.steps.previous = { secondsToAnswer: server.secondsToAnswer, health: server.health, ...(await previousOnSeveral(several)) };
  await stop();
  t.diagnostic(`upgrade and rollback exercised on ${walks.length} walks, and ${several.record.walks} holding several values`);
});
