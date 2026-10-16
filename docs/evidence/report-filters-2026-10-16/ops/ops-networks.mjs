// Operations probe for docs/OPERATIONS.md 9.2 "Networks" (owner, 2026-10-16), run against a live
// application (Lucee or ColdFusion) on the gate's database. It follows the documented procedure on a
// district whose schools already have walks and a School mapping:
//
//   1. a district, school A (mapped to a School value) and school B, both under the district, with walks
//   2. the documented re-import: two networks under the district, A and B listed with a network as parent
//   3. checks: walks and the mapping stay, the district lead covers everything as before, a network
//      narrows to its schools, several units count each walk once
//   4. the documented warning: a deactivated network cuts its schools off from the district lead,
//      and reactivating it restores them
//   5. the documented retirement: move the schools first, then deactivate the network: nothing is lost
//
// Fixtures carry a tag and are removed through the maintenance cleanup at the end. Prints each check;
// exits 1 on the first failure. Never prints the maintenance token or a password.
//
// usage: node ops-networks.mjs        (ICFWALK_BASE_URL / ICFWALK_DB_NAME select the engine and database)
import assert from "node:assert/strict";
import { createRequire } from "node:module";
const require = createRequire("/home/user/ICFWalk/package.json");
const { api, baseUrl, connectionConfig, loadRuntimeEnv, releaseMonth } = await import("/home/user/ICFWalk/tests/node/helpers.mjs");

const env = loadRuntimeEnv();
const token = env.ICFWALK_MAINTENANCE_TOKEN || "";
assert.ok(token, "ICFWALK_MAINTENANCE_TOKEN is set (not printed)");
const tag = `opsnet-${Date.now().toString(36)}`;
const DAY = releaseMonth(1975, 1999);
const uuid = () => crypto.randomUUID().toUpperCase();
let step = 0;
const ok = (what) => console.log(`ok ${++step} - ${what}`);

async function client(subject) {
  const cookies = new Map();
  let csrf = "";
  async function call(method, apiPath, body) {
    const headers = { Accept: "application/json", "X-ICFWalk-Dev-Subject": subject };
    if (body !== undefined) headers["Content-Type"] = "application/json";
    if (csrf) headers["X-ICFWalk-CSRF-Token"] = csrf;
    if (cookies.size) headers.Cookie = [...cookies.entries()].map(([k, v]) => `${k}=${v}`).join("; ");
    const response = await fetch(`${baseUrl(env)}/index.cfm${apiPath}`, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
    for (const line of response.headers.getSetCookie ? response.headers.getSetCookie() : []) {
      const [pair] = line.split(";");
      const eq = pair.indexOf("=");
      cookies.set(pair.slice(0, eq).trim(), pair.slice(eq + 1).trim());
    }
    const text = await response.text();
    let json = null;
    try { json = JSON.parse(text); } catch { json = null; }
    return { status: response.status, json, text };
  }
  const me = await call("GET", "/api/me");
  assert.equal(me.status, 200, me.text);
  csrf = me.json.csrfToken;
  return { call, me: me.json };
}

const importUnits = async (orgUnits) => {
  const r = await api(env, "POST", "/api/maintenance/org-units/import", { token, body: { orgUnits } });
  assert.equal(r.status, 200, r.text);
  return r.json;
};
const unit = (name, type, parentName, extra = {}) => ({ code: `${tag}-${name}`, type, name: `Ops ${name}`, parentCode: parentName ? `${tag}-${parentName}` : null, ...extra });

let failed = false;
try {
  console.log(`engine at ${baseUrl(env)}, database ${env.ICFWALK_DB_NAME || "icfwalk_dev"}, tag ${tag}, visit date ${DAY}`);
  const health = await (await fetch(`${baseUrl(env)}/index.cfm/api/health`)).json();
  console.log(`health: status ${health.status}, environment ${health.environment}`);

  // A School value of the current version that no unit holds yet, for school A's mapping.
  const sql = require("mssql");
  const pool = await sql.connect(connectionConfig(env, env.ICFWALK_DB_NAME || "icfwalk_dev"));
  const held = new Set((await pool.request().query("SELECT value_code FROM icf.org_unit_dimension_map")).recordset.map((r) => r.value_code));
  await pool.close();

  // 1. The district as it is today: two schools directly under it, A mapped, walks at both.
  const firstImport = [unit("district", "DISTRICT", null), unit("school-a", "SCHOOL", "district"), unit("school-b", "SCHOOL", "district")];
  await importUnits(firstImport);
  const subjects = { lead: `${tag}-lead`, a: `${tag}-walker-a`, b: `${tag}-walker-b` };
  for (const [key, roleCode, at, descendants] of [["lead", "DISTRICT_WALK_REPORT", "district", true], ["a", "SCHOOL_WALK_REPORT", "school-a", false], ["b", "SCHOOL_WALK_REPORT", "school-b", false]]) {
    const u = await api(env, "POST", "/api/maintenance/identity/provision-user", { token, body: { subject: subjects[key], displayName: `Ops ${key}` } });
    assert.ok(u.status === 200 || u.status === 201, u.text);
    const r = await api(env, "POST", "/api/maintenance/identity/assign-role", { token, body: { subject: subjects[key], roleCode, orgUnitCode: `${tag}-${at}`, includeDescendants: descendants } });
    assert.equal(r.status, 201, r.text);
  }
  const lead = await client(subjects.lead);
  const walkerA = await client(subjects.a);
  const walkerB = await client(subjects.b);
  const ids = { a: walkerA.me.permissions["walk.create"][0], b: walkerB.me.permissions["walk.create"][0] };
  const model = (await walkerA.call("GET", "/api/instrument/current")).json.model;
  const free = model.dimensions.school.values.map((v) => v.valueCode).find((code) => code !== "other" && !held.has(code));
  assert.ok(free, "a School value no unit holds");
  await importUnits([unit("school-a", "SCHOOL", "district", { schoolValueCode: free })]);
  ok(`district ${tag}-district with school A (mapped to School value ${free}) and school B, both directly under it`);

  const REQUIRED = {
    p1q1: { storedCode: "Partial" }, p1q2: { storedCode: "Retrieval" }, p1q3: { storedCode: "Analysis" }, part1_adopted_pacing: { storedCode: "on" },
    part1_adopted_ac1: { storedCode: "3" }, part1_adopted_ac2: { storedCode: "4" }, part1_targettask_tt1: { storedCode: "5" }, part1_targettask_tt2: { storedCode: "2" },
  };
  const walk = async (walker, orgUnitId) => {
    const created = await walker.call("POST", "/api/walks", { orgUnitId, clientMutationId: uuid() });
    assert.equal(created.status, 201, created.text);
    const w = created.json.walk;
    const saved = await walker.call("PUT", `/api/walks/${w.id}`, {
      rowVersion: w.rowVersion, clientMutationId: uuid(),
      dimensions: { ...w.state.dimensions, date: { dateValue: DAY }, grade: { selectedValueCode: "7" }, observer: { textValue: "ops probe" } },
      responses: { ...REQUIRED, comp_s1_q1: { storedCode: "3" } },
    });
    assert.equal(saved.status, 200, saved.text);
    const done = await walker.call("POST", `/api/walks/${w.id}/complete`, { rowVersion: saved.json.walk.rowVersion, clientMutationId: uuid() });
    assert.equal(done.status, 200, done.text);
    return created.json.walk;
  };
  const firstA = await walk(walkerA, ids.a);
  await walk(walkerA, ids.a);
  await walk(walkerB, ids.b);
  assert.equal(firstA.state.dimensions.school?.selectedValueCode, free, "a walk at A carries A's School value");
  ok("two completed walks at A (each carrying A's School value), one at B");

  const total = async (who, qs = "") => {
    const r = await who.call("GET", `/api/reports/aggregate?from=${DAY}&to=${DAY}${qs}`);
    assert.equal(r.status, 200, r.text);
    return r.json.population.walks;
  };
  assert.equal(await total(lead), 3);
  assert.equal(await total(lead, `&orgUnitId=${ids.a}`), 2);
  ok("before: the district lead counts 3 walks, school A 2");

  // 2. The documented re-import: networks under the district, each school listed with its network.
  const moved = await importUnits([unit("north", "NETWORK", "district"), unit("south", "NETWORK", "district"), unit("school-a", "SCHOOL", "north"), unit("school-b", "SCHOOL", "south")]);
  console.log(`re-import: ${JSON.stringify(moved)}`);
  const opts = (await lead.call("GET", "/api/reports/options")).json;
  const mine = opts.orgUnits.filter((u) => u.code.startsWith(tag));
  const byCode = Object.fromEntries(mine.map((u) => [u.code.slice(tag.length + 1), u]));
  assert.deepEqual(mine.map((u) => `${u.type}:${u.code.slice(tag.length + 1)}`), ["DISTRICT:district", "NETWORK:north", "NETWORK:south", "SCHOOL:school-a", "SCHOOL:school-b"]);
  assert.equal(byCode["school-a"].parentOrgUnitId, byCode.north.orgUnitId);
  assert.equal(byCode["school-b"].parentOrgUnitId, byCode.south.orgUnitId);
  assert.equal(byCode.north.parentOrgUnitId, byCode.district.orgUnitId);
  ok("after the re-import the lead's options list district, networks and schools, each school under its network");

  // 3. Nothing else moved.
  assert.equal(await total(lead), 3);
  assert.equal(await total(lead, `&orgUnitId=${byCode.north.orgUnitId}`), 2);
  assert.equal(await total(lead, `&orgUnitId=${byCode.south.orgUnitId}`), 1);
  assert.equal(await total(lead, `&orgUnitId=${byCode.north.orgUnitId},${byCode.south.orgUnitId}`), 3);
  assert.equal(await total(lead, `&orgUnitId=${byCode.north.orgUnitId},${ids.a}`), 2, "a school inside a named network counts once");
  ok("the district lead still counts 3 walks; North is A's 2, South is B's 1, both networks 3, North with A 2");
  const listA = (await walkerA.call("GET", "/api/walks")).json.walks.filter((w) => w.orgUnitId === ids.a);
  assert.equal(listA.length, 2);
  assert.equal(await total(walkerA), 2);
  ok("A's walker still lists A's 2 walks and reports on them");
  const again = await walkerA.call("POST", "/api/walks", { orgUnitId: ids.a, clientMutationId: uuid() });
  assert.equal(again.status, 201, again.text);
  assert.equal(again.json.walk.state.dimensions.school?.selectedValueCode, free);
  // Walks are voided, never deleted (WALK-08): the probe voids its scratch draft.
  const discard = await walkerA.call("POST", `/api/walks/${again.json.walk.id}/void`, { reason: "ops probe draft", rowVersion: again.json.walk.rowVersion, clientMutationId: uuid() });
  assert.equal(discard.status, 200, discard.text);
  ok("a new walk at A still carries A's School value: the mapping stayed");

  // 4. The documented warning, and its undoing.
  await importUnits([unit("north", "NETWORK", "district", { active: false })]);
  assert.equal(await total(lead), 1, "only B's walk is left in the lead's scope");
  const cut = (await lead.call("GET", "/api/reports/options")).json.orgUnits.filter((u) => u.code.startsWith(tag)).map((u) => u.code.slice(tag.length + 1));
  assert.deepEqual(cut, ["district", "south", "school-b"]);
  assert.equal(await total(walkerA), 2, "A's own walker, assigned at A, still has A");
  ok("WARNING CONFIRMED: with North inactive the district lead loses school A (1 walk, A gone from the options); A's own walker keeps it");
  await importUnits([unit("north", "NETWORK", "district", { active: true })]);
  assert.equal(await total(lead), 3);
  ok("reactivating North gives the lead school A back (3 walks)");

  // 5. The documented retirement: move the schools first, then deactivate the network.
  await importUnits([unit("school-a", "SCHOOL", "south")]);
  await importUnits([unit("north", "NETWORK", "district", { active: false })]);
  assert.equal(await total(lead), 3);
  assert.equal(await total(lead, `&orgUnitId=${byCode.south.orgUnitId}`), 3);
  ok("retiring North after moving A to South loses nothing: the lead counts 3, South 3");
} catch (e) {
  failed = true;
  console.log(`not ok ${++step} - ${e.message}`);
} finally {
  const r = await api(env, "POST", "/api/maintenance/identity/cleanup-fixtures", { token, body: { tag } });
  console.log(`fixture cleanup: ${r.status}`);
  if (r.status !== 200) failed = true;
}
console.log(failed ? "OPS PROBE FAILED" : "OPS PROBE PASSED");
process.exit(failed ? 1 : 0);
