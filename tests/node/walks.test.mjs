// HTTP-level checks of the Phase 4 walk endpoints against the running application (development
// identity stub, real SQL Server): authentication and CSRF on every route, role separation
// (AUTH-05/06), cross-user scope (AUTH-04), tampered identifiers/keys/codes (AUTH-09, SAVE-07),
// stale writes (SAVE-04), idempotent retries (SAVE-06, WALK-03), stored markup returned as data
// (SAVE-08), completion (WALK-09/10), void and delete refusal (WALK-06/08), and the pinned
// instrument route (WALK-11). Fixtures are created through the maintenance endpoints and removed.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { api, baseUrl, connectionConfig, hasDatabaseConfig, loadRuntimeEnv } from "./helpers.mjs";
import sql from "mssql";

const env = loadRuntimeEnv();
const token = env.ICFWALK_MAINTENANCE_TOKEN || "";
const tag = `httpwalk-${Date.now().toString(36)}`;

async function reachable() {
  try {
    const r = await fetch(`${baseUrl(env)}/index.cfm/api/health`, { signal: AbortSignal.timeout(10000) });
    if (r.status !== 200) return false;
    const body = await r.json();
    return body.environment === "development" || body.environment === "test";
  } catch { return false; }
}
const up = await reachable();
const skip = !up ? `application not reachable in development mode at ${baseUrl(env)}` : !token ? "ICFWALK_MAINTENANCE_TOKEN not set" : false;

function jar() {
  const cookies = new Map();
  return {
    header() { return [...cookies.entries()].map(([k, v]) => `${k}=${v}`).join("; "); },
    absorb(response) {
      for (const line of (response.headers.getSetCookie ? response.headers.getSetCookie() : [])) {
        const [pair] = line.split(";");
        const eq = pair.indexOf("=");
        cookies.set(pair.slice(0, eq).trim(), pair.slice(eq + 1).trim());
      }
    },
  };
}

/** A signed-in browser-like client: cookie jar plus the session CSRF token from /api/me. */
async function client(subject) {
  const cookieJar = jar();
  let csrf = "";
  async function call(method, path, body, { noCsrf = false, noIdentity = false } = {}) {
    const headers = { Accept: "application/json" };
    if (!noIdentity) headers["X-ICFWalk-Dev-Subject"] = subject;
    if (body !== undefined) headers["Content-Type"] = "application/json";
    if (csrf && !noCsrf) headers["X-ICFWalk-CSRF-Token"] = csrf;
    // Unauthenticated probes go without the session cookie: a cookie without an identity would
    // sign the session out and invalidate this client's CSRF token.
    if (cookieJar.header() && !noIdentity) headers.Cookie = cookieJar.header();
    const response = await fetch(`${baseUrl(env)}/index.cfm${path}`, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
    if (!noIdentity) cookieJar.absorb(response);
    const text = await response.text();
    let json = null;
    try { json = JSON.parse(text); } catch { json = null; }
    return { status: response.status, json, text, response };
  }
  const me = await call("GET", "/api/me");
  assert.equal(me.status, 200, me.text);
  csrf = me.json.csrfToken;
  return { call, me: me.json };
}

const uuid = () => crypto.randomUUID().toUpperCase();
const walker = `${tag}-walker`, colleague = `${tag}-colleague`, other = `${tag}-other`, report = `${tag}-report`, admin = `${tag}-admin`, nobody = `${tag}-nobody`;
let A, B, O, R, M, N, unitA, unitB;

// The School dimension values the two HTTP fixture schools are explicitly mapped to. They are
// deliberately unrelated to the fixture org-unit codes: the stored mapping is the identity
// relationship, not code equality (docs/DATA_CONTRACT.md, "School and organizational scope"). Both
// are middle schools, because the School value now comes from the unit and the grade option filter
// derives the valid grade band from it.
const SCHOOL_VALUE_A = "eastview_middle_school";
const SCHOOL_VALUE_B = "ellis_middle_school";

// The alignment checks need org units whose codes really are instrument School value codes, so
// these two carry no run tag. NON_IDENTIFYING_UNIT is coded exactly like the School dimension's
// free-text option; CANONICAL_CASE_UNIT differs from a real value code only in case, which the
// candidate search matches but the walk path (an exact, case-sensitive comparison) would not, so
// the alignment has to store the instrument's spelling rather than the unit's.
const NON_IDENTIFYING_UNIT = "other";
const CANONICAL_VALUE = "central_school";
const CANONICAL_CASE_UNIT = "CENTRAL_SCHOOL";
const UNTAGGED_UNIT_CODES = [NON_IDENTIFYING_UNIT, CANONICAL_CASE_UNIT];
const mappedValueFor = (orgUnitCode) => scalar(
  "SELECT m.value_code FROM icf.org_unit_dimension_map m JOIN icf.org_unit o ON o.org_unit_id = m.org_unit_id WHERE o.org_unit_code = @code AND m.dimension_code = N'school'",
  { code: orgUnitCode });

/**
 * A direct read-only connection, used only to prove database facts the API does not expose (mutation
 * rows, fingerprints, row versions) and to reproduce a pre-migration-004 mutation row.
 */
let pool = null;
async function db() {
  if (!hasDatabaseConfig(env)) return null;
  if (!pool) pool = await sql.connect(connectionConfig(env, env.ICFWALK_DB_NAME || "icfwalk_dev"));
  return pool;
}
async function scalar(text, params = {}) {
  const p = await db();
  if (!p) return null;
  const request = p.request();
  for (const [k, v] of Object.entries(params)) request.input(k, v);
  const r = await request.query(text);
  return r.recordset.length ? Object.values(r.recordset[0])[0] : null;
}
async function run(text, params = {}) {
  const p = await db();
  if (!p) return null;
  const request = p.request();
  for (const [k, v] of Object.entries(params)) request.input(k, v);
  return request.query(text);
}
const mutationCount = (walkId) => scalar("SELECT COUNT(*) AS n FROM icf.walk_mutation WHERE walk_id = @id", { id: walkId });
const storedRowVersion = (walkId) => scalar("SELECT CONVERT(varchar(18), CAST(row_version AS binary(8)), 1) AS rv FROM icf.walk WHERE walk_id = @id", { id: walkId });
const walkStatus = (walkId) => scalar("SELECT status FROM icf.walk WHERE walk_id = @id", { id: walkId });

before(async () => {
  if (skip) return;
  const units = await api(env, "POST", "/api/maintenance/org-units/import", { token, body: { orgUnits: [
    { code: `${tag}-district`, type: "DISTRICT", name: "HTTP fixture district", parentCode: null },
    { code: `${tag}-school-a`, type: "SCHOOL", name: "HTTP fixture school A", parentCode: `${tag}-district`, schoolValueCode: SCHOOL_VALUE_A },
    { code: `${tag}-school-b`, type: "SCHOOL", name: "HTTP fixture school B", parentCode: `${tag}-district`, schoolValueCode: SCHOOL_VALUE_B },
    { code: `${tag}-school-u`, type: "SCHOOL", name: "HTTP fixture unmapped school", parentCode: `${tag}-district` },
  ] } });
  assert.equal(units.status, 200, units.text);
  assert.equal(units.json.schoolValuesMapped, 2, "both declared School mappings were stored");
  for (const [subject, roleCode, unit] of [[walker, "SCHOOL_WALK_REPORT", "a"], [colleague, "SCHOOL_WALK_REPORT", "a"], [other, "SCHOOL_WALK_REPORT", "b"], [report, "SCHOOL_REPORT_ONLY", "a"], [admin, "MASTER_INSTRUMENT_ADMIN", ""], [nobody, "", ""]]) {
    const u = await api(env, "POST", "/api/maintenance/identity/provision-user", { token, body: { subject, displayName: `Fixture ${subject}` } });
    assert.ok(u.status === 201 || u.status === 200, u.text);
    if (!roleCode) continue;
    const a = await api(env, "POST", "/api/maintenance/identity/assign-role", { token, body: { subject, roleCode, orgUnitCode: unit ? `${tag}-school-${unit}` : `${tag}-district`, includeDescendants: !unit } });
    assert.equal(a.status, 201, a.text);
  }
  A = await client(walker); B = await client(colleague); O = await client(other); R = await client(report); M = await client(admin); N = await client(nobody);
  unitA = A.me.permissions["walk.create"][0];
  unitB = O.me.permissions["walk.create"][0];
});

after(async () => {
  if (skip) return;
  // Two fixture units are deliberately untagged, because their codes have to be exactly an
  // instrument School value code for the alignment checks to mean anything. The tag-based cleanup
  // cannot see them, and they hang off the tagged district, so they go first.
  await removeUntaggedFixtureUnits();
  const r = await api(env, "POST", "/api/maintenance/identity/cleanup-fixtures", { token, body: { tag } });
  if (r.status !== 200) console.error("fixture cleanup failed", r.status, r.text);
  if (pool) { await pool.close(); pool = null; }
});

async function removeUntaggedFixtureUnits() {
  for (const code of UNTAGGED_UNIT_CODES) {
    const walks = "SELECT w.walk_id FROM icf.walk w JOIN icf.org_unit o ON o.org_unit_id = w.org_unit_id WHERE o.org_unit_code = @code";
    await run(`DELETE FROM icf.walk_mutation WHERE walk_id IN (${walks})`, { code });
    await run(`DELETE FROM icf.walk_revision WHERE walk_id IN (${walks})`, { code });
    await run(`DELETE s FROM icf.walk_response_selection s JOIN icf.walk_response r ON r.response_id = s.response_id WHERE r.walk_id IN (${walks})`, { code });
    await run(`DELETE FROM icf.walk_response WHERE walk_id IN (${walks})`, { code });
    await run(`DELETE FROM icf.walk_dimension_value WHERE walk_id IN (${walks})`, { code });
    await run(`DELETE FROM icf.audit_event WHERE entity_type = N'WALK' AND entity_id IN (${walks})`, { code });
    await run(`DELETE FROM icf.walk WHERE walk_id IN (${walks})`, { code });
    await run("DELETE s FROM icf.user_role_scope s JOIN icf.org_unit o ON o.org_unit_id = s.org_unit_id WHERE o.org_unit_code = @code", { code });
    await run("DELETE a FROM icf.audit_event a JOIN icf.org_unit o ON o.org_unit_id = a.entity_id WHERE o.org_unit_code = @code", { code });
    await run("DELETE m FROM icf.org_unit_dimension_map m JOIN icf.org_unit o ON o.org_unit_id = m.org_unit_id WHERE o.org_unit_code = @code", { code });
    await run("DELETE FROM icf.org_unit WHERE org_unit_code = @code", { code });
  }
}

test("AUTH-01 / SEC-03: walk routes require an identity and a CSRF token; role-less users are refused", { skip }, async () => {
  for (const [method, path] of [["GET", "/api/walks"], ["POST", "/api/walks"], ["GET", `/api/walks/${uuid()}`], ["PUT", `/api/walks/${uuid()}`], ["POST", `/api/walks/${uuid()}/complete`], ["POST", `/api/walks/${uuid()}/void`], ["DELETE", `/api/walks/${uuid()}`]]) {
    const r = await A.call(method, path, method === "GET" ? undefined : {}, { noIdentity: true });
    assert.equal(r.status, 401, `${method} ${path}`);
    assert.equal(r.json.error.code, "UNAUTHENTICATED");
    assert.equal(Object.keys(r.json).join(","), "error");
  }
  const noCsrf = await A.call("POST", "/api/walks", { orgUnitId: unitA, clientMutationId: uuid() }, { noCsrf: true });
  assert.equal(noCsrf.status, 403);
  assert.equal(noCsrf.json.error.code, "CSRF_TOKEN_INVALID");
  const list = await A.call("GET", "/api/walks");
  assert.equal(list.status, 200);
  assert.equal(list.json.walks.length, 0, "the CSRF-rejected create wrote nothing");
  const none = await N.call("GET", "/api/walks");
  assert.equal(none.status, 403);
  assert.equal(none.json.error.code, "FORBIDDEN");
});

test("AUTH-05 / AUTH-06: report-only and instrument-admin roles never reach walk data or edit endpoints", { skip }, async () => {
  const created = await A.call("POST", "/api/walks", { orgUnitId: unitA, clientMutationId: uuid() });
  assert.equal(created.status, 201, created.text);
  const id = created.json.walk.id;
  for (const C of [R, M]) {
    for (const [method, path, body] of [["GET", "/api/walks"], ["POST", "/api/walks", { orgUnitId: unitA, clientMutationId: uuid() }], ["GET", `/api/walks/${id}`], ["GET", `/api/walks/${id}/instrument`], ["PUT", `/api/walks/${id}`, { rowVersion: created.json.walk.rowVersion, clientMutationId: uuid(), dimensions: {}, responses: {} }], ["POST", `/api/walks/${id}/complete`, { rowVersion: created.json.walk.rowVersion, clientMutationId: uuid() }], ["POST", `/api/walks/${id}/void`, { reason: "x" }], ["DELETE", `/api/walks/${id}`]]) {
      const r = await C.call(method, path, body);
      assert.equal(r.status, 403, `${method} ${path}`);
      assert.equal(r.json.error.code, "FORBIDDEN");
      assert.ok(!r.text.includes(id), "no walk identifier leaks");
    }
  }
});

test("WALK-02 / WALK-03: create pins the current version and owner; a retried create yields one walk", { skip }, async () => {
  const current = await A.call("GET", "/api/instrument/current");
  const mutation = uuid();
  const first = await A.call("POST", "/api/walks", { orgUnitId: unitA, versionId: current.json.version.versionId, clientMutationId: mutation });
  assert.equal(first.status, 201, first.text);
  const w = first.json.walk;
  assert.equal(w.status, "DRAFT");
  assert.equal(w.versionId, current.json.version.versionId);
  assert.equal(w.ownerUserId, A.me.user.userId);
  assert.equal(w.orgUnitId, unitA);
  assert.equal(w.replayed, false);
  assert.match(w.rowVersion, /^0x[0-9A-F]{16}$/);
  assert.equal(w.state.responses.comp_s3_applicable.storedCode, "no");
  const retry = await A.call("POST", "/api/walks", { orgUnitId: unitA, clientMutationId: mutation });
  assert.equal(retry.status, 200, retry.text);
  assert.equal(retry.json.walk.id, w.id);
  assert.equal(retry.json.walk.replayed, true);
  const list = await A.call("GET", "/api/walks");
  assert.equal(list.json.walks.filter((x) => x.id === w.id).length, 1);
  // Tampered org unit and version on create.
  const foreignUnit = await A.call("POST", "/api/walks", { orgUnitId: O.me.permissions["walk.create"][0], clientMutationId: uuid() });
  assert.equal(foreignUnit.status, 404);
  const badUnit = await A.call("POST", "/api/walks", { orgUnitId: "'; DROP TABLE icf.walk; --", clientMutationId: uuid() });
  assert.equal(badUnit.status, 400);
  const badVersion = await A.call("POST", "/api/walks", { orgUnitId: unitA, versionId: uuid(), clientMutationId: uuid() });
  assert.equal(badVersion.status, 409);
  assert.equal(badVersion.json.error.code, "INSTRUMENT_VERSION_CHANGED");
});

test("WALK-05 / SAVE-08 / SEC-01: saved values survive retrieval; markup and SQL metacharacters are stored and returned as data", { skip }, async () => {
  const created = await A.call("POST", "/api/walks", { orgUnitId: unitA, clientMutationId: uuid() });
  const w = created.json.walk;
  const note = `<img src=x onerror="alert(1)"> & <script>alert('x')</script> '; DROP TABLE icf.walk; -- "quoted"`;
  // The School value is the authorized unit's (see the School-scope cases below), so the "Other"
  // free-text path carries the hostile string on Content area, which also allows Other.
  const saved = await A.call("PUT", `/api/walks/${w.id}`, { walkId: w.id, versionId: w.versionId, rowVersion: w.rowVersion, clientMutationId: uuid(),
    dimensions: { content: { selectedValueCode: "other", otherText: note }, grade: { selectedValueCode: "7" }, date: { dateValue: "2026-09-17" }, period: { selectedValueCode: "first" } },
    responses: { p1q1: { storedCode: "Yes" }, comp_s1_q1: { storedCode: "5" }, comp_s1_notes: { textValue: note } } });
  assert.equal(saved.status, 200, saved.text);
  assert.notEqual(saved.json.walk.rowVersion, w.rowVersion);
  assert.equal(saved.json.walk.states.responseStates.comp_s1_q1, "ANSWERED");
  assert.equal(saved.json.walk.states.dimensionStates.period, "ANSWERED");
  const again = await A.call("GET", `/api/walks/${w.id}`);
  assert.equal(again.status, 200);
  assert.match(again.response.headers.get("content-type"), /^application\/json;\s*charset=utf-8$/i);
  assert.equal(again.response.headers.get("x-content-type-options"), "nosniff");
  assert.equal(again.json.walk.state.responses.comp_s1_notes.textValue, note);
  assert.equal(again.json.walk.state.dimensions.content.otherText, note);
  assert.equal(again.json.walk.state.dimensions.school.selectedValueCode, SCHOOL_VALUE_A, "the School value is the unit's mapped value");
  assert.equal(again.json.walk.state.dimensions.grade.selectedValueCode, "7");
  assert.equal(again.json.walk.state.dimensions.date.dateValue, "2026-09-17");
  assert.equal(again.json.walk.rowVersion, saved.json.walk.rowVersion);
  const list = await A.call("GET", "/api/walks");
  const card = list.json.walks.find((x) => x.id === w.id);
  assert.equal(card.state.dimensions.content.otherText, note, "list carries the card dimensions");
  assert.deepEqual(card.state.responses, {}, "list carries no responses");
});

test("AUTH-04 / AUTH-09: another school's walker, a colleague, tampered and malformed identifiers", { skip }, async () => {
  const created = await A.call("POST", "/api/walks", { orgUnitId: unitA, clientMutationId: uuid() });
  const w = created.json.walk;
  const body = { rowVersion: w.rowVersion, clientMutationId: uuid(), dimensions: {}, responses: {} };
  // Other school: 404 everywhere, existence not disclosed.
  for (const [method, path, b] of [["GET", `/api/walks/${w.id}`], ["GET", `/api/walks/${w.id}/instrument`], ["PUT", `/api/walks/${w.id}`, body], ["POST", `/api/walks/${w.id}/complete`, body], ["POST", `/api/walks/${w.id}/void`, {}], ["DELETE", `/api/walks/${w.id}`]]) {
    const r = await O.call(method, path, b);
    assert.equal(r.status, 404, `${method} ${path}`);
  }
  const otherList = await O.call("GET", "/api/walks?scope=all");
  assert.ok(!otherList.json.walks.some((x) => x.id === w.id));
  // Same-school colleague: may open (read) but never edit, complete, void, or delete.
  const seen = await B.call("GET", `/api/walks/${w.id}`);
  assert.equal(seen.status, 200);
  assert.equal(seen.json.walk.canEdit, false);
  for (const [method, path, b] of [["PUT", `/api/walks/${w.id}`, body], ["POST", `/api/walks/${w.id}/complete`, body], ["POST", `/api/walks/${w.id}/void`, { reason: "x" }], ["DELETE", `/api/walks/${w.id}`]]) {
    const r = await B.call(method, path, b);
    assert.equal(r.status, 403, `${method} ${path}`);
  }
  const mine = await B.call("GET", "/api/walks");
  assert.ok(!mine.json.walks.some((x) => x.id === w.id), "My Walks lists own walks only");
  // Identifiers.
  assert.equal((await A.call("GET", `/api/walks/${uuid()}`)).status, 404);
  assert.equal((await A.call("GET", "/api/walks/1%20OR%201=1")).status, 400);
  assert.equal((await A.call("PUT", `/api/walks/${w.id}`, { ...body, versionId: uuid() })).json.error.code, "VERSION_MISMATCH");
  assert.equal((await A.call("PUT", `/api/walks/${w.id}`, { ...body, walkId: uuid() })).json.error.code, "WALK_ID_MISMATCH");
  assert.equal((await A.call("PUT", `/api/walks/${w.id}`, { ...body, rowVersion: "0" })).json.error.code, "ROW_VERSION_INVALID");
  assert.equal((await A.call("PUT", `/api/walks/${w.id}`, { ...body, clientMutationId: "x" })).json.error.code, "CLIENT_MUTATION_ID_INVALID");
  assert.equal((await A.call("PUT", `/api/walks/${w.id}`, "not an object")).json.error.code, "INVALID_JSON_BODY");
  // SAVE-07 and item/dimension/option tampering: rejected with specific codes, nothing written.
  const cases = [
    ["INVALID_OPTION", { responses: { comp_s1_q1: { storedCode: "yes" } } }],
    ["INVALID_OPTION", { responses: { p1q1: { storedCode: "4" } } }],
    ["UNKNOWN_ITEM", { responses: { teacher_name: { textValue: "x" } } }],
    ["UNKNOWN_DIMENSION", { dimensions: { teacher: { textValue: "x" } } }],
    ["INVALID_DIMENSION_VALUE", { dimensions: { grade: { selectedValueCode: "13" } } }],
    ["INVALID_DIMENSION_VALUE", { dimensions: { school: { selectedValueCode: "'; DROP TABLE icf.walk; --" } } }],
    ["INVALID_DATE", { dimensions: { date: { dateValue: "2026-13-01" } } }],
    ["INVALID_RESPONSE_VALUE", { responses: { part1_adopted_student_heading: { textValue: "x" } } }],
    ["INVALID_RESPONSE_VALUE", { responses: { comp_s1_q1: { storedCode: "3", textValue: "x" } } }],
    ["INVALID_EMAIL_DRAFT", { responses: { email_workflow: { textValue: "not json" } } }],
  ];
  for (const [code, patch] of cases) {
    const r = await A.call("PUT", `/api/walks/${w.id}`, { ...body, dimensions: {}, responses: {}, ...patch, clientMutationId: uuid() });
    assert.equal(r.status, 400, `${code}: ${r.text}`);
    assert.equal(r.json.error.code, code);
    assert.ok(Array.isArray(r.json.error.details.issues) && r.json.error.details.issues.length >= 1);
  }
  const after = await A.call("GET", `/api/walks/${w.id}`);
  assert.equal(after.json.walk.rowVersion, w.rowVersion, "nothing was written");
});

test("SAVE-04 / SAVE-06: a stale write is a 409 without overwrite; the same mutation id replays without duplicates", { skip }, async () => {
  const created = await A.call("POST", "/api/walks", { orgUnitId: unitA, clientMutationId: uuid() });
  const w = created.json.walk;
  const mutation = uuid();
  const payload = { rowVersion: w.rowVersion, clientMutationId: mutation, dimensions: { grade: { selectedValueCode: "7" } }, responses: { comp_s2_q1: { storedCode: "2" } } };
  const first = await A.call("PUT", `/api/walks/${w.id}`, payload);
  assert.equal(first.status, 200, first.text);
  const stale = await A.call("PUT", `/api/walks/${w.id}`, { ...payload, clientMutationId: uuid(), dimensions: { grade: { selectedValueCode: "8" } } });
  assert.equal(stale.status, 409);
  assert.equal(stale.json.error.code, "STALE_ROW_VERSION");
  assert.equal(stale.json.error.details.serverRowVersion, first.json.walk.rowVersion);
  const replay = await A.call("PUT", `/api/walks/${w.id}`, payload);
  assert.equal(replay.status, 200, replay.text);
  assert.equal(replay.json.walk.replayed, true);
  assert.equal(replay.json.walk.rowVersion, first.json.walk.rowVersion);
  const current = await A.call("GET", `/api/walks/${w.id}`);
  assert.equal(current.json.walk.state.dimensions.grade.selectedValueCode, "7", "the stale write did not overwrite");
  assert.equal(current.json.walk.rowVersion, first.json.walk.rowVersion);
  assert.equal(current.json.walk.revisionCount, 0);
  // The colleague cannot replay someone else's mutation id, and cannot reuse it.
  const reuse = await A.call("PUT", `/api/walks/${w.id}`, { ...payload, rowVersion: first.json.walk.rowVersion, clientMutationId: created.json.walk.clientMutationId });
  assert.equal(reuse.status, 409);
  assert.equal(reuse.json.error.code, "MUTATION_ID_REUSED");
});

test("COND-12 persisted: applicability No clears ratings, keeps notes, and stores NOT_APPLICABLE in the same save", { skip }, async () => {
  const created = await A.call("POST", "/api/walks", { orgUnitId: unitA, clientMutationId: uuid() });
  const w = created.json.walk;
  const yes = await A.call("PUT", `/api/walks/${w.id}`, { rowVersion: w.rowVersion, clientMutationId: uuid(), dimensions: {}, responses: { comp_s4_applicable: { storedCode: "yes" }, comp_s4_q1: { storedCode: "5" }, comp_s4_notes: { textValue: "retained" } } });
  assert.equal(yes.json.walk.states.responseStates.comp_s4_q1, "ANSWERED");
  const no = await A.call("PUT", `/api/walks/${w.id}`, { rowVersion: yes.json.walk.rowVersion, clientMutationId: uuid(), dimensions: {}, responses: { comp_s4_applicable: { storedCode: "no" }, comp_s4_q1: { storedCode: "5" }, comp_s4_notes: { textValue: "retained" } } });
  assert.equal(no.status, 200, no.text);
  assert.deepEqual(no.json.walk.changes, [{ key: "comp_s4_q1", kind: "RESPONSE_CLEARED", reason: "NOT_APPLICABLE" }]);
  assert.equal(no.json.walk.state.responses.comp_s4_q1, undefined);
  assert.equal(no.json.walk.state.responses.comp_s4_notes.textValue, "retained");
  const again = await A.call("GET", `/api/walks/${w.id}`);
  assert.equal(again.json.walk.states.persistedResponseStates.comp_s4_q1, "NOT_APPLICABLE");
  assert.equal(again.json.walk.states.persistedResponseStates.comp_s4_notes, "ANSWERED");
  assert.equal(again.json.walk.state.responses.comp_s4_q1, undefined);
});

test("WALK-09 / WALK-10 / WALK-08 / WALK-06: completion validation, completion, delete refusal, and void", { skip }, async () => {
  const created = await A.call("POST", "/api/walks", { orgUnitId: unitA, clientMutationId: uuid() });
  const w = created.json.walk;
  const incomplete = await A.call("POST", `/api/walks/${w.id}/complete`, { rowVersion: w.rowVersion, clientMutationId: uuid() });
  assert.equal(incomplete.status, 400);
  assert.equal(incomplete.json.error.code, "WALK_INCOMPLETE");
  assert.deepEqual(incomplete.json.error.details.errors.map((e) => e.key), ["p1q1", "p1q2", "p1q3", "part1_adopted_pacing", "part1_adopted_ac1", "part1_adopted_ac2", "part1_targettask_tt1", "part1_targettask_tt2"]);
  assert.ok(incomplete.json.error.details.errors.every((e) => e.kind === "ITEM" && e.sectionKey && e.message));
  assert.equal((await A.call("GET", `/api/walks/${w.id}`)).json.walk.status, "DRAFT");
  const full = await A.call("PUT", `/api/walks/${w.id}`, { rowVersion: w.rowVersion, clientMutationId: uuid(), dimensions: { grade: { selectedValueCode: "2" } }, responses: {
    p1q1: { storedCode: "Partial" }, p1q2: { storedCode: "Retrieval" }, p1q3: { storedCode: "Analysis" }, part1_adopted_pacing: { storedCode: "on" },
    part1_adopted_ac1: { storedCode: "3" }, part1_adopted_ac2: { storedCode: "4" }, part1_targettask_tt1: { storedCode: "5" }, part1_targettask_tt2: { storedCode: "2" } } });
  assert.equal(full.status, 200, full.text);
  const mutation = uuid();
  const done = await A.call("POST", `/api/walks/${w.id}/complete`, { rowVersion: full.json.walk.rowVersion, clientMutationId: mutation });
  assert.equal(done.status, 200, done.text);
  assert.equal(done.json.walk.status, "COMPLETED");
  assert.ok(done.json.walk.completedAt);
  assert.equal(done.json.walk.revisionCount, 1);
  const replay = await A.call("POST", `/api/walks/${w.id}/complete`, { rowVersion: full.json.walk.rowVersion, clientMutationId: mutation });
  assert.equal(replay.status, 200);
  assert.equal(replay.json.walk.replayed, true);
  assert.equal((await A.call("POST", `/api/walks/${w.id}/complete`, { rowVersion: done.json.walk.rowVersion, clientMutationId: uuid() })).json.error.code, "WALK_ALREADY_COMPLETED");
  // Physical deletion is refused for every walk; void needs a reason once completed.
  const del = await A.call("DELETE", `/api/walks/${w.id}`);
  assert.equal(del.status, 409);
  assert.equal(del.json.error.code, "WALK_DELETE_REFUSED");
  const noReason = await A.call("POST", `/api/walks/${w.id}/void`, { rowVersion: done.json.walk.rowVersion, clientMutationId: uuid() });
  assert.equal(noReason.json.error.code, "VOID_REASON_REQUIRED");
  const voided = await A.call("POST", `/api/walks/${w.id}/void`, { rowVersion: done.json.walk.rowVersion, clientMutationId: uuid(), reason: "Duplicate entry" });
  assert.equal(voided.status, 200, voided.text);
  assert.equal(voided.json.walk.status, "VOIDED");
  assert.ok(!(await A.call("GET", "/api/walks")).json.walks.some((x) => x.id === w.id), "voided walks leave My Walks");
  assert.equal((await A.call("GET", `/api/walks/${w.id}`)).status, 200, "voided walks remain retrievable (retained history)");
  assert.equal((await A.call("PUT", `/api/walks/${w.id}`, { rowVersion: voided.json.walk.rowVersion, clientMutationId: uuid(), dimensions: {}, responses: {} })).json.error.code, "WALK_VOIDED");
  // A draft voids without a reason (the My Walks delete action).
  const draft = (await A.call("POST", "/api/walks", { orgUnitId: unitA, clientMutationId: uuid() })).json.walk;
  const dv = await A.call("POST", `/api/walks/${draft.id}/void`, { rowVersion: draft.rowVersion, clientMutationId: uuid() });
  assert.equal(dv.status, 200, dv.text);
  assert.equal(dv.json.walk.status, "VOIDED");
});

test("WALK-11: the walk instrument route serves the walk's pinned version render model", { skip }, async () => {
  const created = await A.call("POST", "/api/walks", { orgUnitId: unitA, clientMutationId: uuid() });
  const w = created.json.walk;
  const inst = await A.call("GET", `/api/walks/${w.id}/instrument`);
  assert.equal(inst.status, 200, inst.text);
  assert.equal(inst.json.version.versionId, w.versionId);
  assert.equal(inst.json.model.format, "icfwalk-render-model/1");
  assert.equal(inst.json.model.counts.items, 144);
  assert.equal(typeof inst.json.policies.hiddenDimensionPolicy, "string");
  const current = await A.call("GET", "/api/instrument/current");
  assert.equal(JSON.stringify(inst.json.model), JSON.stringify(current.json.model), "same version, identical model");
});

// ---- Phase 0-4 corrections over HTTP -------------------------------------------------------------

test("CORR: every mutation route requires clientMutationId; save/complete/void also require rowVersion", { skip }, async () => {
  const created = await A.call("POST", "/api/walks", { orgUnitId: unitA, clientMutationId: uuid() });
  const w = created.json.walk;
  const cases = [
    ["POST", "/api/walks", { orgUnitId: unitA }, "CLIENT_MUTATION_ID_REQUIRED"],
    ["PUT", `/api/walks/${w.id}`, { rowVersion: w.rowVersion, dimensions: {}, responses: {} }, "CLIENT_MUTATION_ID_REQUIRED"],
    ["POST", `/api/walks/${w.id}/complete`, { rowVersion: w.rowVersion }, "CLIENT_MUTATION_ID_REQUIRED"],
    ["POST", `/api/walks/${w.id}/void`, { rowVersion: w.rowVersion }, "CLIENT_MUTATION_ID_REQUIRED"],
    ["PUT", `/api/walks/${w.id}`, { clientMutationId: uuid(), dimensions: {}, responses: {} }, "ROW_VERSION_REQUIRED"],
    ["POST", `/api/walks/${w.id}/complete`, { clientMutationId: uuid() }, "ROW_VERSION_REQUIRED"],
    ["POST", `/api/walks/${w.id}/void`, { clientMutationId: uuid() }, "ROW_VERSION_REQUIRED"],
    ["PUT", `/api/walks/${w.id}`, { rowVersion: "0xNOPE", clientMutationId: uuid(), dimensions: {}, responses: {} }, "ROW_VERSION_INVALID"],
    ["PUT", `/api/walks/${w.id}`, { rowVersion: w.rowVersion, clientMutationId: "nope", dimensions: {}, responses: {} }, "CLIENT_MUTATION_ID_INVALID"],
    // A whole-state save needs both root containers, as JSON objects.
    ["PUT", `/api/walks/${w.id}`, { rowVersion: w.rowVersion, clientMutationId: uuid(), responses: {} }, "STATE_CONTAINER_REQUIRED"],
    ["PUT", `/api/walks/${w.id}`, { rowVersion: w.rowVersion, clientMutationId: uuid(), dimensions: {} }, "STATE_CONTAINER_REQUIRED"],
    ["PUT", `/api/walks/${w.id}`, { rowVersion: w.rowVersion, clientMutationId: uuid(), dimensions: [], responses: {} }, "STATE_CONTAINER_INVALID"],
    // JSON primitive types are checked, not coerced, and client-asserted state is refused.
    ["PUT", `/api/walks/${w.id}`, { rowVersion: w.rowVersion, clientMutationId: uuid(), dimensions: {}, responses: { part1_adopted_ac1: { storedCode: 4 } } }, "INVALID_RESPONSE_VALUE"],
    ["PUT", `/api/walks/${w.id}`, { rowVersion: w.rowVersion, clientMutationId: uuid(), dimensions: { grade: { selectedValueCode: 7 } }, responses: {} }, "INVALID_DIMENSION_VALUE"],
    ["PUT", `/api/walks/${w.id}`, { rowVersion: w.rowVersion, clientMutationId: uuid(), dimensions: {}, responses: { comp_s1_q1: { state: "ANSWERED", storedCode: "4" } } }, "CLIENT_STATE_NOT_ACCEPTED"],
  ];
  for (const [method, path, payload, code] of cases) {
    const r = await A.call(method, path, payload);
    assert.equal(r.status, 400, `${method} ${path} ${code}: ${r.text}`);
    assert.equal(r.json.error.code, code, r.text);
  }
  const after = await A.call("GET", `/api/walks/${w.id}`);
  assert.equal(after.json.walk.rowVersion, w.rowVersion, "no rejected request wrote anything");
  assert.equal(after.json.walk.status, "DRAFT");
});

test("CORR: a committed mutation whose answer was lost replays on retry; the same id with a changed request is refused", { skip }, async () => {
  // CREATE: the answer is lost, the client retries with the same id and the same body.
  const createId = uuid();
  const createBody = { orgUnitId: unitA, clientMutationId: createId, dimensions: { observer: { textValue: "Fixture Observer" } }, responses: {} };
  const first = await A.call("POST", "/api/walks", createBody);
  assert.equal(first.status, 201, first.text);
  const retry = await A.call("POST", "/api/walks", createBody);
  assert.equal(retry.status, 200);
  assert.equal(retry.json.walk.replayed, true);
  assert.equal(retry.json.walk.id, first.json.walk.id, "the retry replays, it does not create a second walk");
  const changed = await A.call("POST", "/api/walks", { ...createBody, dimensions: { observer: { textValue: "Someone else" } } });
  assert.equal(changed.status, 409, changed.text);
  assert.equal(changed.json.error.code, "MUTATION_ID_REUSED");

  // SAVE
  const w = first.json.walk;
  const saveId = uuid();
  const saveBody = { rowVersion: w.rowVersion, clientMutationId: saveId, dimensions: { grade: { selectedValueCode: "6" } }, responses: { comp_s1_notes: { textValue: "committed once" } } };
  const saved = await A.call("PUT", `/api/walks/${w.id}`, saveBody);
  assert.equal(saved.status, 200, saved.text);
  const savedAgain = await A.call("PUT", `/api/walks/${w.id}`, saveBody);
  assert.equal(savedAgain.json.walk.replayed, true);
  assert.equal(savedAgain.json.walk.rowVersion, saved.json.walk.rowVersion);
  const savedChanged = await A.call("PUT", `/api/walks/${w.id}`, { ...saveBody, responses: { comp_s1_notes: { textValue: "something else" } } });
  assert.equal(savedChanged.status, 409);
  assert.equal(savedChanged.json.error.code, "MUTATION_ID_REUSED");
  assert.equal((await A.call("GET", `/api/walks/${w.id}`)).json.walk.state.responses.comp_s1_notes.textValue, "committed once");

  // COMPLETE
  const answers = { p1q1: { storedCode: "Partial" }, p1q2: { storedCode: "Retrieval" }, p1q3: { storedCode: "Analysis" }, part1_adopted_pacing: { storedCode: "on" },
    part1_adopted_ac1: { storedCode: "3" }, part1_adopted_ac2: { storedCode: "4" }, part1_targettask_tt1: { storedCode: "5" }, part1_targettask_tt2: { storedCode: "2" } };
  const full = await A.call("PUT", `/api/walks/${w.id}`, { rowVersion: saved.json.walk.rowVersion, clientMutationId: uuid(), dimensions: { grade: { selectedValueCode: "6" } }, responses: answers });
  assert.equal(full.status, 200, full.text);
  const completeId = uuid();
  const done = await A.call("POST", `/api/walks/${w.id}/complete`, { rowVersion: full.json.walk.rowVersion, clientMutationId: completeId });
  assert.equal(done.status, 200, done.text);
  const doneAgain = await A.call("POST", `/api/walks/${w.id}/complete`, { rowVersion: full.json.walk.rowVersion, clientMutationId: completeId });
  assert.equal(doneAgain.json.walk.replayed, true);
  assert.equal(doneAgain.json.walk.revisionCount, 1, "a completion replay appends no second revision");

  // An identical save to the completed walk is a no-op: no revision, no new row version.
  const settled = done.json.walk;
  const noop = await A.call("PUT", `/api/walks/${w.id}`, { rowVersion: settled.rowVersion, clientMutationId: uuid(), dimensions: { grade: { selectedValueCode: "6" } }, responses: answers });
  assert.equal(noop.status, 200, noop.text);
  assert.equal(noop.json.walk.rowVersion, settled.rowVersion, "an identical completed save does not advance the row version");
  assert.equal(noop.json.walk.revisionCount, 1);
  const material = await A.call("PUT", `/api/walks/${w.id}`, { rowVersion: settled.rowVersion, clientMutationId: uuid(), dimensions: { grade: { selectedValueCode: "6" } }, responses: { ...answers, comp_s1_notes: { textValue: "edited after completion" } } });
  assert.equal(material.status, 200, material.text);
  assert.notEqual(material.json.walk.rowVersion, settled.rowVersion);
  assert.equal(material.json.walk.revisionCount, 2, "exactly one pre-edit revision for the material change");

  // VOID
  const voidId = uuid();
  const voided = await A.call("POST", `/api/walks/${w.id}/void`, { rowVersion: material.json.walk.rowVersion, clientMutationId: voidId, reason: "Entered twice" });
  assert.equal(voided.status, 200, voided.text);
  const voidedAgain = await A.call("POST", `/api/walks/${w.id}/void`, { rowVersion: material.json.walk.rowVersion, clientMutationId: voidId, reason: "Entered twice" });
  assert.equal(voidedAgain.json.walk.replayed, true);
  const voidChanged = await A.call("POST", `/api/walks/${w.id}/void`, { rowVersion: material.json.walk.rowVersion, clientMutationId: voidId, reason: "A different reason" });
  assert.equal(voidChanged.status, 409);
  assert.equal(voidChanged.json.error.code, "MUTATION_ID_REUSED");
});

test("CORR: a create mutation id from a school the caller lost never discloses that walk", { skip }, async () => {
  // The other school's walker creates a walk and hands its mutation id to this caller.
  const foreignUnit = O.me.permissions["walk.create"][0];
  const foreignMutation = uuid();
  const foreign = await O.call("POST", "/api/walks", { orgUnitId: foreignUnit, clientMutationId: foreignMutation, dimensions: {}, responses: {} });
  assert.equal(foreign.status, 201, foreign.text);
  // Replaying it while naming a unit this caller may use must not return the other school's walk.
  const replay = await A.call("POST", "/api/walks", { orgUnitId: unitA, clientMutationId: foreignMutation, dimensions: {}, responses: {} });
  assert.ok(replay.status === 404 || replay.status === 409, `expected a refusal, got ${replay.status}: ${replay.text}`);
  assert.notEqual(replay.json.walk?.id, foreign.json.walk.id);
  // And naming the other school's unit is refused by org scope before any replay.
  const scoped = await A.call("POST", "/api/walks", { orgUnitId: foreignUnit, clientMutationId: foreignMutation, dimensions: {}, responses: {} });
  assert.equal(scoped.status, 404);
  assert.equal((await A.call("GET", `/api/walks/${foreign.json.walk.id}`)).status, 404, "the walk stays invisible");
});

// ---- second correction session -----------------------------------------------------------------

test("CORR2: an idempotent SAVE replay never hands stale session state a newer row version", { skip }, async () => {
  // Two sessions of the same owner, exactly as two browser tabs: A saves, loses the answer, B saves.
  const A1 = await client(walker);
  const A2 = await client(walker);
  const created = await A1.call("POST", "/api/walks", { orgUnitId: unitA, clientMutationId: uuid() });
  assert.equal(created.status, 201, created.text);
  const w = created.json.walk;

  // 1. Session A's save commits. A never sees the answer, so it still holds this state and this token.
  const m1 = uuid();
  const bodyA = { rowVersion: w.rowVersion, clientMutationId: m1, dimensions: { observer: { textValue: "A1" } }, responses: {} };
  const committedByA = await A1.call("PUT", `/api/walks/${w.id}`, bodyA);
  assert.equal(committedByA.status, 200, committedByA.text);

  // 2. Session B saves a different valid change on top of it.
  const committedByB = await A2.call("PUT", `/api/walks/${w.id}`, { rowVersion: committedByA.json.walk.rowVersion, clientMutationId: uuid(), dimensions: { observer: { textValue: "B1" } }, responses: {} });
  assert.equal(committedByB.status, 200, committedByB.text);
  const afterB = await storedRowVersion(w.id);
  assert.equal(afterB, committedByB.json.walk.rowVersion);
  const mutationsAfterB = await mutationCount(w.id);

  // 3. Session A retries M1 with exactly the request it sent.
  const retry = await A1.call("PUT", `/api/walks/${w.id}`, bodyA);
  assert.equal(retry.status, 409, retry.text);
  assert.equal(retry.json.error.code, "MUTATION_REPLAY_SUPERSEDED");

  // 4. It received no usable token, nothing was written, and no mutation row was added.
  assert.equal(retry.json.error.details.recordedRowVersion, committedByA.json.walk.rowVersion);
  assert.notEqual(retry.json.error.details.recordedRowVersion, afterB, "the details never carry the current row version");
  assert.equal(await storedRowVersion(w.id), afterB, "the row version did not move");
  assert.equal(await mutationCount(w.id), mutationsAfterB, "the refused replay recorded no mutation");
  const current = await A2.call("GET", `/api/walks/${w.id}`);
  assert.equal(current.json.walk.state.dimensions.observer.textValue, "B1", "session B's change stands");

  // Session A cannot overwrite B with what it was given: the recorded token is stale.
  const overwrite = await A1.call("PUT", `/api/walks/${w.id}`, { rowVersion: retry.json.error.details.recordedRowVersion, clientMutationId: uuid(), dimensions: { observer: { textValue: "A-overwrite" } }, responses: {} });
  assert.equal(overwrite.status, 409);
  assert.equal(overwrite.json.error.code, "STALE_ROW_VERSION");
  assert.equal((await A2.call("GET", `/api/walks/${w.id}`)).json.walk.state.dimensions.observer.textValue, "B1");

  // Reconciliation is the way forward: reload, then save against what the server holds.
  const reloaded = await A1.call("GET", `/api/walks/${w.id}`);
  const reconciled = await A1.call("PUT", `/api/walks/${w.id}`, { rowVersion: reloaded.json.walk.rowVersion, clientMutationId: uuid(), dimensions: { observer: { textValue: "A2" } }, responses: {} });
  assert.equal(reconciled.status, 200, reconciled.text);
  assert.equal((await A1.call("GET", `/api/walks/${w.id}`)).json.walk.state.dimensions.observer.textValue, "A2");
});

test("CORR2: CREATE and COMPLETE replays are refused once the walk has moved on", { skip }, async () => {
  // CREATE: committed, then saved against, so the create can no longer be replayed coherently.
  const createId = uuid();
  const created = await A.call("POST", "/api/walks", { orgUnitId: unitA, clientMutationId: createId, dimensions: {}, responses: {} });
  assert.equal(created.status, 201, created.text);
  const w = created.json.walk;
  const advanced = await A.call("PUT", `/api/walks/${w.id}`, { rowVersion: w.rowVersion, clientMutationId: uuid(), dimensions: { observer: { textValue: "since" } }, responses: {} });
  assert.equal(advanced.status, 200, advanced.text);
  const retry = await A.call("POST", "/api/walks", { orgUnitId: unitA, clientMutationId: createId, dimensions: {}, responses: {} });
  assert.equal(retry.status, 409, retry.text);
  assert.equal(retry.json.error.code, "MUTATION_REPLAY_SUPERSEDED");
  assert.equal(retry.json.error.details.walkId, w.id, "the client can still find the walk it created");
  assert.equal(await scalar("SELECT COUNT(*) AS n FROM icf.walk_mutation WHERE mutation_id = @id", { id: createId }), 1, "exactly one create mutation row");
  assert.equal(await storedRowVersion(w.id), advanced.json.walk.rowVersion, "nothing was written");

  // COMPLETE: completed, then edited as a completed walk, so its replay is superseded too.
  const answers = { p1q1: { storedCode: "Partial" }, p1q2: { storedCode: "Retrieval" }, p1q3: { storedCode: "Analysis" },
    part1_adopted_pacing: { storedCode: "on" }, part1_adopted_ac1: { storedCode: "3" }, part1_adopted_ac2: { storedCode: "4" },
    part1_targettask_tt1: { storedCode: "5" }, part1_targettask_tt2: { storedCode: "2" } };
  const ready = await A.call("PUT", `/api/walks/${w.id}`, { rowVersion: advanced.json.walk.rowVersion, clientMutationId: uuid(), dimensions: {}, responses: answers });
  assert.equal(ready.status, 200, ready.text);
  const completeId = uuid();
  const done = await A.call("POST", `/api/walks/${w.id}/complete`, { rowVersion: ready.json.walk.rowVersion, clientMutationId: completeId });
  assert.equal(done.status, 200, done.text);
  const edited = await A.call("PUT", `/api/walks/${w.id}`, { rowVersion: done.json.walk.rowVersion, clientMutationId: uuid(), dimensions: {}, responses: { ...answers, comp_s1_notes: { textValue: "after" } } });
  assert.equal(edited.status, 200, edited.text);
  const revisions = await scalar("SELECT COUNT(*) AS n FROM icf.walk_revision WHERE walk_id = @id", { id: w.id });
  const completeRetry = await A.call("POST", `/api/walks/${w.id}/complete`, { rowVersion: ready.json.walk.rowVersion, clientMutationId: completeId });
  assert.equal(completeRetry.status, 409, completeRetry.text);
  assert.equal(completeRetry.json.error.code, "MUTATION_REPLAY_SUPERSEDED");
  assert.equal(await scalar("SELECT COUNT(*) AS n FROM icf.walk_revision WHERE walk_id = @id", { id: w.id }), revisions, "no second revision");
  assert.equal(await storedRowVersion(w.id), edited.json.walk.rowVersion);
});

test("CORR2: a legacy mutation row with no request fingerprint is never replayed as a success", { skip }, async () => {
  const created = await A.call("POST", "/api/walks", { orgUnitId: unitA, clientMutationId: uuid() });
  const w = created.json.walk;
  const legacyId = uuid();
  const body = { rowVersion: w.rowVersion, clientMutationId: legacyId, dimensions: { observer: { textValue: "legacy" } }, responses: {} };
  const committed = await A.call("PUT", `/api/walks/${w.id}`, body);
  assert.equal(committed.status, 200, committed.text);
  // Reproduce a row written before migration 004.
  await run("UPDATE icf.walk_mutation SET request_fingerprint = NULL WHERE mutation_id = @id", { id: legacyId });
  assert.equal(await scalar("SELECT COUNT(*) AS n FROM icf.walk_mutation WHERE mutation_id = @id AND request_fingerprint IS NULL", { id: legacyId }), 1);
  const before = await storedRowVersion(w.id);
  const mutations = await mutationCount(w.id);

  // The exact-looking retry is a deterministic conflict, not a replay.
  const exact = await A.call("PUT", `/api/walks/${w.id}`, body);
  assert.equal(exact.status, 409, exact.text);
  assert.equal(exact.json.error.code, "MUTATION_LEGACY_UNVERIFIABLE");
  assert.equal(exact.json.error.details.walkId, w.id);
  // An altered request gets the same answer: the two are indistinguishable against a NULL fingerprint.
  const altered = await A.call("PUT", `/api/walks/${w.id}`, { ...body, dimensions: { observer: { textValue: "tampered" } } });
  assert.equal(altered.status, 409);
  assert.equal(altered.json.error.code, "MUTATION_LEGACY_UNVERIFIABLE");

  // Neither wrote anything.
  assert.equal(await storedRowVersion(w.id), before, "the row version did not move");
  assert.equal(await mutationCount(w.id), mutations, "no mutation row was written");
  assert.equal((await A.call("GET", `/api/walks/${w.id}`)).json.walk.state.dimensions.observer.textValue, "legacy");

  // A caller who may not see the walk gets 404 first: authorization answers before provenance.
  const foreign = await O.call("PUT", `/api/walks/${w.id}`, body);
  assert.equal(foreign.status, 404, foreign.text);
  assert.equal(foreign.json.error.code, "NOT_FOUND");
  assert.equal(Object.keys(foreign.json).join(","), "error");
  assert.equal(await storedRowVersion(w.id), before);
});

test("CORR2: the School dimension follows an explicit mapping and fails closed without one", { skip }, async () => {
  // A mapped unit: the server fills and locks its mapped value and refuses any other, including Other.
  const created = await A.call("POST", "/api/walks", { orgUnitId: unitA, clientMutationId: uuid() });
  const w = created.json.walk;
  assert.equal(w.state.dimensions.school.selectedValueCode, SCHOOL_VALUE_A);
  const before = await storedRowVersion(w.id);
  for (const value of [{ selectedValueCode: SCHOOL_VALUE_B }, { selectedValueCode: "other", otherText: "Somewhere else" }]) {
    const bad = await A.call("PUT", `/api/walks/${w.id}`, { rowVersion: w.rowVersion, clientMutationId: uuid(), dimensions: { school: value }, responses: {} });
    assert.equal(bad.status, 409, bad.text);
    assert.equal(bad.json.error.code, "SCHOOL_ORG_MISMATCH");
    assert.equal(bad.json.error.details.expectedSchoolValueCode, SCHOOL_VALUE_A);
  }
  assert.equal(await storedRowVersion(w.id), before, "a rejected save does not advance the row version");
  const stillMine = await A.call("GET", `/api/walks/${w.id}`);
  assert.equal(stillMine.json.walk.state.dimensions.school.selectedValueCode, SCHOOL_VALUE_A);

  // School A's walk can never carry School B's value, which belongs to School B's unit.
  const atB = await O.call("POST", "/api/walks", { orgUnitId: unitB, clientMutationId: uuid() });
  assert.equal(atB.json.walk.state.dimensions.school.selectedValueCode, SCHOOL_VALUE_B);

  // An unmapped SCHOOL unit: nothing is filled and no School value is accepted at all.
  const unitU = await scalar("SELECT CONVERT(varchar(36), org_unit_id) AS id FROM icf.org_unit WHERE org_unit_code = @code", { code: `${tag}-school-u` });
  const provisionU = await api(env, "POST", "/api/maintenance/identity/provision-user", { token, body: { subject: `${tag}-unmapped`, displayName: "Fixture unmapped walker" } });
  assert.ok(provisionU.status === 201 || provisionU.status === 200, provisionU.text);
  const assign = await api(env, "POST", "/api/maintenance/identity/assign-role", { token, body: { subject: `${tag}-unmapped`, roleCode: "SCHOOL_WALK_REPORT", orgUnitCode: `${tag}-school-u` } });
  assert.ok(assign.status === 201 || assign.status === 200, assign.text);
  const U = await client(`${tag}-unmapped`);
  const blank = await U.call("POST", "/api/walks", { orgUnitId: U.me.permissions["walk.create"][0], clientMutationId: uuid() });
  assert.equal(blank.status, 201, blank.text);
  assert.equal(blank.json.walk.state.dimensions.school, undefined, "nothing is invented for an unmapped unit");
  const walksBefore = await scalar("SELECT COUNT(*) AS n FROM icf.walk WHERE org_unit_id = @id", { id: unitU });
  for (const value of [{ selectedValueCode: SCHOOL_VALUE_A }, { selectedValueCode: "other", otherText: "Unlisted site" }]) {
    const refused = await U.call("PUT", `/api/walks/${blank.json.walk.id}`, { rowVersion: blank.json.walk.rowVersion, clientMutationId: uuid(), dimensions: { school: value }, responses: {} });
    assert.equal(refused.status, 409, refused.text);
    assert.equal(refused.json.error.code, "SCHOOL_ORG_UNMAPPED");
  }
  const refusedCreate = await U.call("POST", "/api/walks", { orgUnitId: U.me.permissions["walk.create"][0], clientMutationId: uuid(), dimensions: { school: { selectedValueCode: SCHOOL_VALUE_A } }, responses: {} });
  assert.equal(refusedCreate.status, 409);
  assert.equal(refusedCreate.json.error.code, "SCHOOL_ORG_UNMAPPED");
  assert.equal(await scalar("SELECT COUNT(*) AS n FROM icf.walk WHERE org_unit_id = @id", { id: unitU }), walksBefore, "a rejected create writes no walk");
  assert.equal(await scalar("SELECT COUNT(*) AS n FROM icf.walk_dimension_value x JOIN icf.dimension_definition d ON d.dimension_id = x.dimension_id WHERE x.walk_id = @id AND d.code = N'school'", { id: blank.json.walk.id }), 0);

  // A district-authorized user still creates at an authorized descendant SCHOOL.
  const provisionD = await api(env, "POST", "/api/maintenance/identity/provision-user", { token, body: { subject: `${tag}-district-walker`, displayName: "Fixture district walker" } });
  assert.ok(provisionD.status === 201 || provisionD.status === 200, provisionD.text);
  const district = await api(env, "POST", "/api/maintenance/identity/assign-role", { token, body: { subject: `${tag}-district-walker`, roleCode: "DISTRICT_WALK_REPORT", orgUnitCode: `${tag}-district`, includeDescendants: true } });
  assert.ok(district.status === 201 || district.status === 200, district.text);
  const D = await client(`${tag}-district-walker`);
  const descendant = await D.call("POST", "/api/walks", { orgUnitId: unitB, clientMutationId: uuid(), dimensions: { school: { selectedValueCode: SCHOOL_VALUE_B } }, responses: {} });
  assert.equal(descendant.status, 201, descendant.text);
  assert.equal(descendant.json.walk.orgUnitId, unitB);
  assert.equal(descendant.json.walk.state.dimensions.school.selectedValueCode, SCHOOL_VALUE_B);
  const crossLabelled = await D.call("POST", "/api/walks", { orgUnitId: unitB, clientMutationId: uuid(), dimensions: { school: { selectedValueCode: SCHOOL_VALUE_A } }, responses: {} });
  assert.equal(crossLabelled.status, 409);
  assert.equal(crossLabelled.json.error.code, "SCHOOL_ORG_MISMATCH");
});

test("CORR2: the alignment endpoint considers exact code matches only, and only as candidates", { skip }, async () => {
  const dry = await api(env, "POST", "/api/maintenance/org-units/align-school-dimension", { token, body: { dryRun: true } });
  assert.equal(dry.status, 200, dry.text);
  assert.equal(dry.json.dryRun, true);
  assert.equal(dry.json.dimensionCode, "school");
  // The fixture units: A and B are already mapped explicitly, U matches no value code by name.
  const already = dry.json.alreadyMapped.filter((m) => [SCHOOL_VALUE_A, SCHOOL_VALUE_B].includes(m.valueCode));
  assert.equal(already.length, 2);
  assert.ok(already.every((m) => m.source === "EXPLICIT"));
  assert.ok(dry.json.unmapped.some((m) => m.orgUnitCode === `${tag}-school-u` && m.reason === "NO_MATCHING_VALUE_CODE"),
    "a unit whose code is not a School value code is reported, never guessed from its name");
  assert.ok(!dry.json.mapped.some((m) => m.orgUnitCode === `${tag}-school-u`));
  assert.ok(!dry.json.candidates.some((m) => m.orgUnitCode === `${tag}-school-u`),
    "and is not even a candidate for confirmation");
  // A dry run writes nothing.
  assert.equal(await scalar("SELECT COUNT(*) AS n FROM icf.org_unit_dimension_map m JOIN icf.org_unit o ON o.org_unit_id = m.org_unit_id WHERE o.org_unit_code = @code", { code: `${tag}-school-u` }), 0);
  // An unknown declared value is refused rather than stored unvalidated.
  const bogus = await api(env, "POST", "/api/maintenance/org-units/import", { token, body: { orgUnits: [
    { code: `${tag}-school-u`, type: "SCHOOL", name: "HTTP fixture unmapped school", parentCode: `${tag}-district`, schoolValueCode: "no_such_school" },
  ] } });
  assert.equal(bogus.status, 400, bogus.text);
  assert.equal(bogus.json.error.code, "ORG_UNIT_SCHOOL_VALUE_UNKNOWN");
  // And a value another unit already holds is refused, never moved.
  const taken = await api(env, "POST", "/api/maintenance/org-units/import", { token, body: { orgUnits: [
    { code: `${tag}-school-u`, type: "SCHOOL", name: "HTTP fixture unmapped school", parentCode: `${tag}-district`, schoolValueCode: SCHOOL_VALUE_A },
  ] } });
  assert.equal(taken.status, 400, taken.text);
  assert.equal(taken.json.error.code, "ORG_UNIT_DIMENSION_VALUE_TAKEN");
  assert.equal(await scalar("SELECT COUNT(*) AS n FROM icf.org_unit_dimension_map m JOIN icf.org_unit o ON o.org_unit_id = m.org_unit_id WHERE o.org_unit_code = @code", { code: `${tag}-school-u` }), 0);
});

test("CORR2: an ambiguous outcome retries the exact same mutation id and body on every route", { skip }, async () => {
  // The browser's contract, proved at the HTTP layer: for each of the four routes, the same id with
  // the same semantic body replays (one database effect), and the same id with a changed body is
  // refused rather than accepted as an equivalent retry.
  const createId = uuid();
  const createBody = { orgUnitId: unitA, clientMutationId: createId, dimensions: { observer: { textValue: "ambiguous" } }, responses: {} };
  const created = await A.call("POST", "/api/walks", createBody);
  assert.equal(created.status, 201, created.text);
  const w = created.json.walk;
  const replayedCreate = await A.call("POST", "/api/walks", createBody);
  assert.equal(replayedCreate.status, 200, replayedCreate.text);
  assert.equal(replayedCreate.json.walk.replayed, true);
  assert.equal(replayedCreate.json.walk.id, w.id);
  assert.equal(await scalar("SELECT COUNT(*) AS n FROM icf.walk WHERE org_unit_id = @id AND owner_user_id = (SELECT user_id FROM icf.app_user WHERE identity_subject = @who) AND created_at >= @since", { id: unitA, who: walker, since: new Date(Date.now() - 120000) }) >= 1, true);
  const rebuiltCreate = await A.call("POST", "/api/walks", { ...createBody, dimensions: { observer: { textValue: "rebuilt from changed UI state" } } });
  assert.equal(rebuiltCreate.status, 409);
  assert.equal(rebuiltCreate.json.error.code, "MUTATION_ID_REUSED");

  // SAVE
  const saveId = uuid();
  const saveBody = { rowVersion: w.rowVersion, clientMutationId: saveId, dimensions: { observer: { textValue: "ambiguous" }, grade: { selectedValueCode: "6" } }, responses: {} };
  const saved = await A.call("PUT", `/api/walks/${w.id}`, saveBody);
  assert.equal(saved.status, 200, saved.text);
  const mutations = await mutationCount(w.id);
  const replayedSave = await A.call("PUT", `/api/walks/${w.id}`, saveBody);
  assert.equal(replayedSave.json.walk.replayed, true);
  assert.equal(replayedSave.json.walk.rowVersion, saved.json.walk.rowVersion);
  assert.equal(await mutationCount(w.id), mutations, "exactly one database effect");
  const rebuiltSave = await A.call("PUT", `/api/walks/${w.id}`, { ...saveBody, dimensions: { observer: { textValue: "ambiguous" }, grade: { selectedValueCode: "7" } } });
  assert.equal(rebuiltSave.status, 409);
  assert.equal(rebuiltSave.json.error.code, "MUTATION_ID_REUSED");

  // COMPLETE: the id belongs to this walk. The same id against another walk is refused.
  const answers = { p1q1: { storedCode: "Partial" }, p1q2: { storedCode: "Retrieval" }, p1q3: { storedCode: "Analysis" },
    part1_adopted_pacing: { storedCode: "on" }, part1_adopted_ac1: { storedCode: "3" }, part1_adopted_ac2: { storedCode: "4" },
    part1_targettask_tt1: { storedCode: "5" }, part1_targettask_tt2: { storedCode: "2" } };
  const ready = await A.call("PUT", `/api/walks/${w.id}`, { rowVersion: saved.json.walk.rowVersion, clientMutationId: uuid(), dimensions: { grade: { selectedValueCode: "6" } }, responses: answers });
  assert.equal(ready.status, 200, ready.text);
  const completeId = uuid();
  const done = await A.call("POST", `/api/walks/${w.id}/complete`, { rowVersion: ready.json.walk.rowVersion, clientMutationId: completeId });
  assert.equal(done.status, 200, done.text);
  const replayedComplete = await A.call("POST", `/api/walks/${w.id}/complete`, { rowVersion: ready.json.walk.rowVersion, clientMutationId: completeId });
  assert.equal(replayedComplete.json.walk.replayed, true);
  assert.equal(await scalar("SELECT COUNT(*) AS n FROM icf.walk_revision WHERE walk_id = @id", { id: w.id }), 1, "exactly one completion revision");

  const otherWalk = await A.call("POST", "/api/walks", { orgUnitId: unitA, clientMutationId: uuid() });
  const otherReady = await A.call("PUT", `/api/walks/${otherWalk.json.walk.id}`, { rowVersion: otherWalk.json.walk.rowVersion, clientMutationId: uuid(), dimensions: {}, responses: answers });
  const crossWalk = await A.call("POST", `/api/walks/${otherWalk.json.walk.id}/complete`, { rowVersion: otherReady.json.walk.rowVersion, clientMutationId: completeId });
  assert.equal(crossWalk.status, 409, crossWalk.text);
  assert.equal(crossWalk.json.error.code, "MUTATION_ID_REUSED");
  assert.equal(await walkStatus(otherWalk.json.walk.id), "DRAFT", "the other walk was not completed by a reused id");

  // VOID: the id is bound to its reason, so a retry must carry the reason it was issued with.
  const voidId = uuid();
  const voidBody = { rowVersion: done.json.walk.rowVersion, clientMutationId: voidId, reason: "Recorded in error" };
  const voided = await A.call("POST", `/api/walks/${w.id}/void`, voidBody);
  assert.equal(voided.status, 200, voided.text);
  const replayedVoid = await A.call("POST", `/api/walks/${w.id}/void`, voidBody);
  assert.equal(replayedVoid.json.walk.replayed, true);
  assert.equal(await scalar("SELECT COUNT(*) AS n FROM icf.walk_mutation WHERE walk_id = @id AND action = N'VOID'", { id: w.id }), 1, "exactly one void mutation");
  const rebuiltVoid = await A.call("POST", `/api/walks/${w.id}/void`, { ...voidBody, reason: "Reason edited in the UI after the failure" });
  assert.equal(rebuiltVoid.status, 409);
  assert.equal(rebuiltVoid.json.error.code, "MUTATION_ID_REUSED");
});

test("CORR3: alignment reports candidates and persists nothing without an explicit per-pair confirmation", { skip }, async () => {
  // A SCHOOL unit whose code differs from a real School value code only in case. Code equality
  // finds it; nothing is written until the operator confirms the exact pair the report gave them.
  const seeded = await api(env, "POST", "/api/maintenance/org-units/import", { token, body: { orgUnits: [
    { code: CANONICAL_CASE_UNIT, type: "SCHOOL", name: "HTTP fixture canonical-case school", parentCode: `${tag}-district` },
  ] } });
  assert.equal(seeded.status, 200, seeded.text);

  const reported = await api(env, "POST", "/api/maintenance/org-units/align-school-dimension", { token, body: {} });
  assert.equal(reported.status, 200, reported.text);
  assert.equal(reported.json.dryRun, false, "this is not a dry run, and it still wrote nothing");
  const candidate = reported.json.candidates.find((c) => c.orgUnitCode === CANONICAL_CASE_UNIT);
  assert.ok(candidate, "the match is reported as a candidate");
  assert.equal(candidate.valueCode, CANONICAL_VALUE, "reported as the instrument spells it");
  assert.ok(!reported.json.mapped.some((m) => m.orgUnitCode === CANONICAL_CASE_UNIT), "and not mapped");
  assert.equal(await mappedValueFor(CANONICAL_CASE_UNIT), null, "code equality alone persists nothing");

  // A confirmation that names a different value than the candidate is refused, not reinterpreted.
  const mismatched = await api(env, "POST", "/api/maintenance/org-units/align-school-dimension", {
    token, body: { confirm: [{ orgUnitCode: CANONICAL_CASE_UNIT, valueCode: SCHOOL_VALUE_A }] } });
  assert.equal(mismatched.status, 200, mismatched.text);
  assert.ok(mismatched.json.refused.some((r) => r.orgUnitCode === CANONICAL_CASE_UNIT && r.reason === "CONFIRMATION_DOES_NOT_MATCH_CANDIDATE"));
  assert.equal(await mappedValueFor(CANONICAL_CASE_UNIT), null, "a mismatched confirmation writes nothing");

  // A confirmation naming a unit that is not a candidate is reported, never guessed at.
  const stray = await api(env, "POST", "/api/maintenance/org-units/align-school-dimension", {
    token, body: { confirm: [{ orgUnitCode: `${tag}-school-u`, valueCode: CANONICAL_VALUE }] } });
  assert.equal(stray.status, 200, stray.text);
  assert.ok(stray.json.refused.some((r) => r.orgUnitCode === `${tag}-school-u` && r.reason === "NOT_A_CANDIDATE"));

  // The exact confirmed pair is stored, with the instrument's spelling of the code.
  const confirmed = await api(env, "POST", "/api/maintenance/org-units/align-school-dimension", {
    token, body: { confirm: [{ orgUnitCode: CANONICAL_CASE_UNIT, valueCode: CANONICAL_VALUE }] } });
  assert.equal(confirmed.status, 200, confirmed.text);
  assert.ok(confirmed.json.mapped.some((m) => m.orgUnitCode === CANONICAL_CASE_UNIT && m.valueCode === CANONICAL_VALUE && m.source === "CODE_ALIGNED"));
  assert.equal(await mappedValueFor(CANONICAL_CASE_UNIT), CANONICAL_VALUE,
    "the stored code is the instrument's, not the org unit's, or the walk path would never match it again");

  // Idempotent: a second run reports it as already mapped and writes nothing new.
  const again = await api(env, "POST", "/api/maintenance/org-units/align-school-dimension", {
    token, body: { confirm: [{ orgUnitCode: CANONICAL_CASE_UNIT, valueCode: CANONICAL_VALUE }] } });
  assert.equal(again.status, 200, again.text);
  assert.ok(again.json.alreadyMapped.some((m) => m.valueCode === CANONICAL_VALUE && m.source === "CODE_ALIGNED"));
  assert.ok(!again.json.mapped.some((m) => m.orgUnitCode === CANONICAL_CASE_UNIT));

  // Maintenance authorization is unchanged: no token, no report and no write.
  const unauthorized = await fetch(`${baseUrl(env)}/index.cfm/api/maintenance/org-units/align-school-dimension`, {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ confirm: [{ orgUnitCode: CANONICAL_CASE_UNIT, valueCode: CANONICAL_VALUE }] }) });
  assert.ok(unauthorized.status === 401 || unauthorized.status === 403 || unauthorized.status === 404, `expected a refusal, got ${unauthorized.status}`);
});

test("CORR3: the School dimension's free-text value is never stored as a school's identity", { skip }, async () => {
  const before = await scalar("SELECT COUNT(*) AS n FROM icf.org_unit_dimension_map");

  // 1. Declaring it explicitly in the org-unit import is refused.
  const declared = await api(env, "POST", "/api/maintenance/org-units/import", { token, body: { orgUnits: [
    { code: `${tag}-school-u`, type: "SCHOOL", name: "HTTP fixture unmapped school", parentCode: `${tag}-district`, schoolValueCode: NON_IDENTIFYING_UNIT },
  ] } });
  assert.equal(declared.status, 400, declared.text);
  assert.equal(declared.json.error.code, "ORG_UNIT_SCHOOL_VALUE_NOT_IDENTIFYING");
  assert.equal(await mappedValueFor(`${tag}-school-u`), null, "the refused declaration stored nothing");

  // 2. A SCHOOL org unit coded exactly "other" matches that value by pure string equality. The
  //    alignment reports why it cannot be an identity and never offers it as a candidate.
  const seeded = await api(env, "POST", "/api/maintenance/org-units/import", { token, body: { orgUnits: [
    { code: NON_IDENTIFYING_UNIT, type: "SCHOOL", name: "HTTP fixture free-text lookalike", parentCode: `${tag}-district` },
  ] } });
  assert.equal(seeded.status, 200, seeded.text);
  const reported = await api(env, "POST", "/api/maintenance/org-units/align-school-dimension", { token, body: {} });
  assert.equal(reported.status, 200, reported.text);
  assert.ok(reported.json.unmapped.some((u) => u.orgUnitCode === NON_IDENTIFYING_UNIT && u.reason === "NON_IDENTIFYING_VALUE_CODE"));
  assert.ok(!reported.json.candidates.some((c) => c.orgUnitCode === NON_IDENTIFYING_UNIT), "never a candidate");
  assert.ok(!reported.json.mapped.some((m) => m.orgUnitCode === NON_IDENTIFYING_UNIT));

  // 3. Confirming it anyway cannot persist it: it was never a candidate.
  const forced = await api(env, "POST", "/api/maintenance/org-units/align-school-dimension", {
    token, body: { confirm: [{ orgUnitCode: NON_IDENTIFYING_UNIT, valueCode: NON_IDENTIFYING_UNIT }] } });
  assert.equal(forced.status, 200, forced.text);
  assert.ok(forced.json.refused.some((r) => r.orgUnitCode === NON_IDENTIFYING_UNIT && r.reason === "NOT_A_CANDIDATE"));
  assert.ok(!forced.json.mapped.some((m) => m.orgUnitCode === NON_IDENTIFYING_UNIT));
  assert.equal(await mappedValueFor(NON_IDENTIFYING_UNIT), null, "the unit coded 'other' is still unmapped");

  // 4. None of the failed attempts changed a mapping or any walk. The unit fails closed, so a walk
  //    there carries no School value and refuses one, exactly like any other unmapped unit.
  assert.equal(await scalar("SELECT COUNT(*) AS n FROM icf.org_unit_dimension_map"), before,
    "no mapping row was added or removed by any refused attempt");
  assert.equal(await mappedValueFor(`${tag}-school-a`), SCHOOL_VALUE_A, "the real mappings are untouched");
  assert.equal(await mappedValueFor(`${tag}-school-b`), SCHOOL_VALUE_B);

  const unitId = await scalar("SELECT org_unit_id FROM icf.org_unit WHERE org_unit_code = @code", { code: NON_IDENTIFYING_UNIT });
  const assigned = await api(env, "POST", "/api/maintenance/identity/assign-role", { token, body: { subject: walker, roleCode: "SCHOOL_WALK_REPORT", orgUnitCode: NON_IDENTIFYING_UNIT } });
  assert.equal(assigned.status, 201, assigned.text);
  const W = await client(walker);
  const walksBefore = (await W.call("GET", "/api/walks")).json.walks.length;
  const created = await W.call("POST", "/api/walks", { orgUnitId: unitId.toUpperCase(), clientMutationId: uuid(), dimensions: {}, responses: {} });
  assert.equal(created.status, 201, created.text);
  assert.equal(created.json.walk.state.dimensions.school, undefined, "nothing is filled for an unmapped unit");
  const labelled = await W.call("PUT", `/api/walks/${created.json.walk.id}`, {
    rowVersion: created.json.walk.rowVersion, clientMutationId: uuid(),
    dimensions: { school: { selectedValueCode: NON_IDENTIFYING_UNIT, otherText: "Somewhere" } }, responses: {} });
  assert.equal(labelled.status, 409, labelled.text);
  assert.equal(labelled.json.error.code, "SCHOOL_ORG_UNMAPPED");
  assert.equal(await storedRowVersion(created.json.walk.id), created.json.walk.rowVersion, "the refusal wrote nothing");
  assert.equal((await W.call("GET", "/api/walks")).json.walks.length, walksBefore + 1, "and created no extra walk");
});
