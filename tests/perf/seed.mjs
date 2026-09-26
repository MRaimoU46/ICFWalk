// Phase 8 synthetic performance data: a district-sized database, built from real walks.
//
// Everything is synthetic. The shape is declared up front and recorded with the run:
//
//   schools   every identifying School value of the instrument (50), one SCHOOL org unit each, under
//             one district, each mapped to its School value
//   users     WALKERS_PER_SCHOOL walkers per school (SCHOOL_WALK_REPORT), one district walker
//             (DISTRICT_WALK_REPORT, include descendants), one district report-only user, one admin
//   walks     WALKS in total, spread over the schools and their walkers and over one school year of
//             visit dates; 80 % COMPLETED, 15 % DRAFT, 5 % VOIDED
//
// Walks are made the way the application makes them, then multiplied. For each school group
// (elementary, middle, high) a few template walks are created, saved with a full valid state and
// completed through the HTTP API, so every row they own is the application's own. The seeder then
// copies them in SQL -- the walk row, every dimension value (with the School value rewritten to the
// copy's school and the visit date to the copy's date), every response row and selection -- in
// batches, into walks of other schools of the same group. A copy is therefore exactly what the
// application would have stored for the same answers at that school on that date.
//
// Usage (the application in development mode on its own database, maintenance token set):
//   ICFWALK_DB_NAME=icfwalk_perf ICFWALK_BASE_URL=http://127.0.0.1:8889 node tests/perf/seed.mjs [walks]
// It refuses to run against a database that already holds walks unless PERF_APPEND=1.
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import sql from "mssql";
import { api, baseUrl, connectionConfig, loadRuntimeEnv, root } from "../node/helpers.mjs";

const env = loadRuntimeEnv();
const token = env.ICFWALK_MAINTENANCE_TOKEN || "";
const database = env.ICFWALK_DB_NAME;
const WALKS = Number(process.argv[2] || env.PERF_WALKS || 30000);
const WALKERS_PER_SCHOOL = 6;
const TEMPLATES_PER_GROUP = 4;
const BATCH = 2500;
const TAG = "perf";
const SOURCE = JSON.parse(fs.readFileSync(path.join(root, "config", "instrument-config.json"), "utf8"));
const outDir = env.ICFWALK_EVIDENCE_DIR || path.join(root, ".runtime", "perf");

if (!database || database === "icfwalk_dev") throw new Error("Set ICFWALK_DB_NAME to a database of its own (not icfwalk_dev).");
if (!token) throw new Error("ICFWALK_MAINTENANCE_TOKEN is required.");

const log = (...a) => console.log(new Date().toISOString().slice(11, 19), ...a);

function client(subject) {
  const cookies = new Map();
  let csrf = "";
  const call = async (method, p, body) => {
    const headers = { Accept: "application/json", "X-ICFWalk-Dev-Subject": subject };
    if (body !== undefined) headers["Content-Type"] = "application/json";
    if (csrf && method !== "GET") headers["X-ICFWalk-CSRF-Token"] = csrf;
    const cookie = [...cookies.entries()].map(([k, v]) => `${k}=${v}`).join("; ");
    if (cookie) headers.Cookie = cookie;
    const response = await fetch(`${baseUrl(env)}/index.cfm${p}`, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
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
  return { call, init: () => call("GET", "/api/me") };
}

async function maintenance(p, body) {
  const r = await api(env, "POST", p, { token, body });
  if (r.status !== 200 && r.status !== 201) throw new Error(`${p} ${r.status}: ${r.text.slice(0, 400)}`);
  return r.json;
}

const schoolValues = SOURCE.dimensionValues.filter((v) => v.dimensionId === "dim_school" && v.valueCode !== "other");
const GRADES = { elementary: ["k", "1", "2", "3", "4"], middle: ["6", "7", "8"], high: ["9", "10", "11", "12"] };
const CONTENT = ["ela", "math", "science", "social_studies"];
const RATING = ["1", "2", "3", "4", "5"];

function fullState(group, n, dateValue) {
  const grade = GRADES[group][n % GRADES[group].length];
  const responses = {
    p1q1: { storedCode: ["Yes", "Partial", "No"][n % 3] }, p1q2: { storedCode: ["Retrieval", "Analysis", "Knowledge Utilization"][n % 3] },
    p1q3: { storedCode: ["Analysis", "Retrieval"][n % 2] }, part1_adopted_pacing: { storedCode: ["on", "behind"][n % 2] },
    part1_adopted_ac1: { storedCode: RATING[n % 5] }, part1_adopted_ac2: { storedCode: RATING[(n + 1) % 5] },
    part1_targettask_tt1: { storedCode: RATING[(n + 2) % 5] }, part1_targettask_tt2: { storedCode: RATING[(n + 3) % 5] },
    comp_s1_q1: { storedCode: RATING[(n + 4) % 5] }, comp_s2_q1: { storedCode: RATING[n % 5] },
    comp_s1_notes: { textValue: `Synthetic note ${n}: students discussed the text in pairs.` },
    summary_strengths: { textValue: `Synthetic strengths ${n}.` }, summary_growth: { textValue: `Synthetic growth area ${n}.` },
  };
  return {
    dimensions: {
      date: { dateValue }, grade: { selectedValueCode: grade }, content: { selectedValueCode: CONTENT[n % CONTENT.length] },
      observer: { textValue: `Synthetic Observer ${n}` }, visitTiming: { selectedValueCode: ["beginning_of_lesson", "middle_of_the_lesson", "end_of_the_lesson"][n % 3] },
      classType: { selectedValueCode: "general_education" },
      ...(group !== "elementary" ? { period: { selectedValueCode: ["first", "second", "third"][n % 3] } } : {}),
    },
    responses,
  };
}

const started = Date.now();
const pool = await new sql.ConnectionPool(connectionConfig(env, database, true)).connect();
const [{ walks: existing }] = (await pool.request().query("SELECT COUNT_BIG(*) AS walks FROM icf.walk")).recordset;
if (Number(existing) > 0 && env.PERF_APPEND !== "1") throw new Error(`${database} already holds ${existing} walks (PERF_APPEND=1 to add more).`);

// ---- organization, people, the published instrument -------------------------------------------------
log(`seeding ${database} at ${baseUrl(env)}: ${schoolValues.length} schools, ${WALKS} walks`);
await maintenance("/api/maintenance/org-units/import", { orgUnits: [
  { code: `${TAG}-district`, type: "DISTRICT", name: "Synthetic district", parentCode: null },
  ...schoolValues.map((v) => ({ code: `${TAG}-${v.valueCode}`, type: "SCHOOL", name: `Synthetic ${v.label}`, parentCode: `${TAG}-district`, schoolValueCode: v.valueCode })),
] });
const people = [];
for (const v of schoolValues) for (let i = 1; i <= WALKERS_PER_SCHOOL; i++) people.push({ subject: `${TAG}-${v.valueCode}-w${i}`, role: "SCHOOL_WALK_REPORT", unit: `${TAG}-${v.valueCode}`, school: v });
people.push({ subject: `${TAG}-district-walker`, role: "DISTRICT_WALK_REPORT", unit: `${TAG}-district`, descendants: true });
people.push({ subject: `${TAG}-district-reports`, role: "DISTRICT_REPORT_ONLY", unit: `${TAG}-district`, descendants: true });
people.push({ subject: `${TAG}-admin`, role: "MASTER_INSTRUMENT_ADMIN", unit: `${TAG}-district` });
for (const p of people) {
  await maintenance("/api/maintenance/identity/provision-user", { subject: p.subject, displayName: `Synthetic ${p.subject}` });
  await maintenance("/api/maintenance/identity/assign-role", { subject: p.subject, roleCode: p.role, orgUnitCode: p.unit, includeDescendants: Boolean(p.descendants) });
}
log(`${people.length} users with roles`);

const admin = client(`${TAG}-admin`);
await admin.init();
const versions = await admin.call("GET", "/api/admin/instrument/versions");
const runtime = versions.json.versions.find((v) => v.instrumentCode === (env.ICFWALK_INSTRUMENT_CODE || "ICFWALK") && (v.status === "PUBLISHED" || v.status === "DRAFT"));
if (!runtime) throw new Error("no ICFWALK version: seed the instrument first");
if (runtime.status === "DRAFT") {
  const pub = await admin.call("POST", `/api/admin/instrument/versions/${runtime.versionId}/publish`);
  if (pub.status !== 200) throw new Error(`publish ${pub.status}: ${pub.text.slice(0, 400)}`);
  log(`published ${runtime.versionLabel}`);
}

// ---- template walks, made through the API ------------------------------------------------------------
const templates = [];
for (const group of ["elementary", "middle", "high"]) {
  const school = schoolValues.find((v) => v.valueGroup === group);
  const walker = client(`${TAG}-${school.valueCode}-w1`);
  const me = await walker.init();
  const unit = Object.keys(me.json.orgUnits).find((id) => me.json.orgUnits[id].code === `${TAG}-${school.valueCode}`);
  for (let n = 0; n < TEMPLATES_PER_GROUP; n++) {
    const created = await walker.call("POST", "/api/walks", { orgUnitId: unit, clientMutationId: crypto.randomUUID() });
    if (created.status !== 201) throw new Error(`create ${created.status}: ${created.text.slice(0, 300)}`);
    const state = fullState(group, n, "2026-09-01");
    state.dimensions.school = { selectedValueCode: school.valueCode };
    const saved = await walker.call("PUT", `/api/walks/${created.json.walk.id}`, { rowVersion: created.json.walk.rowVersion, clientMutationId: crypto.randomUUID(), ...state });
    if (saved.status !== 200) throw new Error(`save ${saved.status}: ${saved.text.slice(0, 600)}`);
    const done = await walker.call("POST", `/api/walks/${created.json.walk.id}/complete`, { rowVersion: saved.json.walk.rowVersion, clientMutationId: crypto.randomUUID() });
    if (done.status !== 200) throw new Error(`complete ${done.status}: ${done.text.slice(0, 600)}`);
    templates.push({ id: created.json.walk.id, group });
  }
}
log(`${templates.length} template walks created and completed through the API`);

// ---- copies, in SQL, in batches -----------------------------------------------------------------------
const [{ schoolDim, dateDim }] = (await pool.request().query("SELECT (SELECT dimension_id FROM icf.dimension_definition WHERE code = N'school') AS schoolDim, (SELECT dimension_id FROM icf.dimension_definition WHERE code = N'date') AS dateDim")).recordset;
const units = (await pool.request().query(`
  SELECT o.org_unit_id AS unitId, m.value_code AS valueCode, dv.value_id AS valueId
  FROM icf.org_unit o JOIN icf.org_unit_dimension_map m ON m.org_unit_id = o.org_unit_id AND m.dimension_code = N'school'
  JOIN icf.dimension_value dv ON dv.dimension_id = '${schoolDim}' AND dv.value_code = m.value_code
  WHERE o.org_unit_code LIKE N'${TAG}-%'`)).recordset;
const owners = (await pool.request().query(`SELECT user_id AS userId, identity_subject AS subject FROM icf.app_user WHERE identity_subject LIKE N'${TAG}-%-w%'`)).recordset;
const groupOf = new Map(schoolValues.map((v) => [v.valueCode, v.valueGroup]));
const plan = [];
const yearStart = Date.parse("2025-08-15T00:00:00Z");
for (let i = 0; i < WALKS - templates.length; i++) {
  const unit = units[i % units.length];
  const group = groupOf.get(unit.valueCode);
  const pool_ = templates.filter((t) => t.group === group);
  const template = pool_[i % pool_.length];
  const walkerNo = 1 + (Math.floor(i / units.length) % WALKERS_PER_SCHOOL);
  const owner = owners.find((o) => o.subject === `${TAG}-${unit.valueCode}-w${walkerNo}`);
  const day = Math.floor((i * 7919) % 300);
  const observed = new Date(yearStart + day * 86400000 + ((i % 7) + 8) * 3600000);
  const status = i % 20 === 0 ? "VOIDED" : i % 20 < 4 ? "DRAFT" : "COMPLETED";
  plan.push({ id: crypto.randomUUID().toUpperCase(), template: template.id, unit: unit.unitId, owner: owner.userId, valueId: unit.valueId, observed, status });
}

let copied = 0;
for (let b = 0; b < plan.length; b += BATCH) {
  const slice = plan.slice(b, b + BATCH);
  const tx = new sql.Transaction(pool);
  await tx.begin();
  try {
    const table = new sql.Table("#perf_map");
    table.create = true;
    table.columns.add("new_id", sql.UniqueIdentifier, { nullable: false });
    table.columns.add("template_id", sql.UniqueIdentifier, { nullable: false });
    table.columns.add("org_unit_id", sql.UniqueIdentifier, { nullable: false });
    table.columns.add("owner_id", sql.UniqueIdentifier, { nullable: false });
    table.columns.add("school_value_id", sql.UniqueIdentifier, { nullable: false });
    table.columns.add("observed", sql.DateTime2(3), { nullable: false });
    table.columns.add("status", sql.NVarChar(20), { nullable: false });
    for (const p of slice) table.rows.add(p.id, p.template, p.unit, p.owner, p.valueId, p.observed, p.status);
    await new sql.Request(tx).bulk(table);
    await new sql.Request(tx).batch(`
      INSERT INTO icf.walk (walk_id, version_id, org_unit_id, owner_user_id, status, observed_at, created_at, updated_at, completed_at, voided_at, void_reason)
      SELECT m.new_id, t.version_id, m.org_unit_id, m.owner_id, CASE WHEN m.status = N'VOIDED' THEN N'COMPLETED' ELSE m.status END, m.observed, m.observed, m.observed,
             CASE WHEN m.status <> N'DRAFT' THEN m.observed END, NULL, NULL
      FROM #perf_map m JOIN icf.walk t ON t.walk_id = m.template_id;
      UPDATE w SET status = N'VOIDED', voided_at = m.observed, void_reason = N'Synthetic void'
      FROM icf.walk w JOIN #perf_map m ON m.new_id = w.walk_id WHERE m.status = N'VOIDED';
      INSERT INTO icf.walk_dimension_value (walk_id, version_id, dimension_id, selected_value_id, text_value, number_value, date_value, boolean_value, created_at, updated_at)
      SELECT m.new_id, x.version_id, x.dimension_id,
             CASE WHEN x.dimension_id = '${schoolDim}' THEN m.school_value_id ELSE x.selected_value_id END,
             x.text_value, x.number_value,
             CASE WHEN x.dimension_id = '${dateDim}' THEN CAST(m.observed AS date) ELSE x.date_value END,
             x.boolean_value, m.observed, m.observed
      FROM #perf_map m JOIN icf.walk_dimension_value x ON x.walk_id = m.template_id;
      INSERT INTO icf.walk_response (walk_id, version_id, item_id, response_state, selected_option_id, text_value, number_value, date_value, boolean_value, created_at, updated_at)
      SELECT m.new_id, r.version_id, r.item_id, r.response_state, r.selected_option_id, r.text_value, r.number_value, r.date_value, r.boolean_value, m.observed, m.observed
      FROM #perf_map m JOIN icf.walk_response r ON r.walk_id = m.template_id;
      INSERT INTO icf.walk_response_selection (response_id, option_id, selected_at)
      SELECT nr.response_id, s.option_id, m.observed
      FROM #perf_map m
      JOIN icf.walk_response tr ON tr.walk_id = m.template_id
      JOIN icf.walk_response_selection s ON s.response_id = tr.response_id
      JOIN icf.walk_response nr ON nr.walk_id = m.new_id AND nr.item_id = tr.item_id;
      DROP TABLE #perf_map;`);
    await tx.commit();
  } catch (e) {
    await tx.rollback().catch(() => {});
    throw e;
  }
  copied += slice.length;
  log(`copied ${copied}/${plan.length}`);
}

const counts = (await pool.request().query(`
  SELECT (SELECT COUNT_BIG(*) FROM icf.walk) AS walks,
         (SELECT COUNT_BIG(*) FROM icf.walk WHERE status = N'COMPLETED') AS completed,
         (SELECT COUNT_BIG(*) FROM icf.walk WHERE status = N'DRAFT') AS drafts,
         (SELECT COUNT_BIG(*) FROM icf.walk WHERE status = N'VOIDED') AS voided,
         (SELECT COUNT_BIG(*) FROM icf.walk_dimension_value) AS dimensionValues,
         (SELECT COUNT_BIG(*) FROM icf.walk_response) AS responses,
         (SELECT COUNT_BIG(*) FROM icf.walk_response_selection) AS selections,
         (SELECT COUNT_BIG(*) FROM icf.app_user) AS users,
         (SELECT COUNT_BIG(*) FROM icf.org_unit) AS orgUnits`)).recordset[0];
await pool.request().query("UPDATE STATISTICS icf.walk WITH FULLSCAN; UPDATE STATISTICS icf.walk_response WITH FULLSCAN; UPDATE STATISTICS icf.walk_dimension_value WITH FULLSCAN;");
await pool.close();
const record = { database, baseUrl: baseUrl(env), shape: { schools: schoolValues.length, walkersPerSchool: WALKERS_PER_SCHOOL, templatesPerGroup: TEMPLATES_PER_GROUP, requestedWalks: WALKS }, counts: Object.fromEntries(Object.entries(counts).map(([k, v]) => [k, Number(v)])), seconds: Math.round((Date.now() - started) / 1000) };
fs.mkdirSync(outDir, { recursive: true });
fs.writeFileSync(path.join(outDir, "seed.json"), `${JSON.stringify(record, null, 2)}\n`);
log(JSON.stringify(record));
