// HTTP-level checks of the Phase 4 walk endpoints against the running application (development
// identity stub, real SQL Server): authentication and CSRF on every route, role separation
// (AUTH-05/06), cross-user scope (AUTH-04), tampered identifiers/keys/codes (AUTH-09, SAVE-07),
// stale writes (SAVE-04), idempotent retries (SAVE-06, WALK-03), stored markup returned as data
// (SAVE-08), completion (WALK-09/10), void and delete refusal (WALK-06/08), and the pinned
// instrument route (WALK-11). Fixtures are created through the maintenance endpoints and removed.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { api, baseUrl, loadRuntimeEnv } from "./helpers.mjs";

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
let A, B, O, R, M, N, unitA;

before(async () => {
  if (skip) return;
  const units = await api(env, "POST", "/api/maintenance/org-units/import", { token, body: { orgUnits: [
    { code: `${tag}-district`, type: "DISTRICT", name: "HTTP fixture district", parentCode: null },
    { code: `${tag}-school-a`, type: "SCHOOL", name: "HTTP fixture school A", parentCode: `${tag}-district` },
    { code: `${tag}-school-b`, type: "SCHOOL", name: "HTTP fixture school B", parentCode: `${tag}-district` },
  ] } });
  assert.equal(units.status, 200, units.text);
  for (const [subject, roleCode, unit] of [[walker, "SCHOOL_WALK_REPORT", "a"], [colleague, "SCHOOL_WALK_REPORT", "a"], [other, "SCHOOL_WALK_REPORT", "b"], [report, "SCHOOL_REPORT_ONLY", "a"], [admin, "MASTER_INSTRUMENT_ADMIN", ""], [nobody, "", ""]]) {
    const u = await api(env, "POST", "/api/maintenance/identity/provision-user", { token, body: { subject, displayName: `Fixture ${subject}` } });
    assert.ok(u.status === 201 || u.status === 200, u.text);
    if (!roleCode) continue;
    const a = await api(env, "POST", "/api/maintenance/identity/assign-role", { token, body: { subject, roleCode, orgUnitCode: unit ? `${tag}-school-${unit}` : `${tag}-district`, includeDescendants: !unit } });
    assert.equal(a.status, 201, a.text);
  }
  A = await client(walker); B = await client(colleague); O = await client(other); R = await client(report); M = await client(admin); N = await client(nobody);
  unitA = A.me.permissions["walk.create"][0];
});

after(async () => {
  if (skip) return;
  const r = await api(env, "POST", "/api/maintenance/identity/cleanup-fixtures", { token, body: { tag } });
  if (r.status !== 200) console.error("fixture cleanup failed", r.status, r.text);
});

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
  const saved = await A.call("PUT", `/api/walks/${w.id}`, { walkId: w.id, versionId: w.versionId, rowVersion: w.rowVersion, clientMutationId: uuid(),
    dimensions: { school: { selectedValueCode: "other", otherText: note }, grade: { selectedValueCode: "7" }, date: { dateValue: "2026-09-17" }, period: { selectedValueCode: "first" } },
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
  assert.equal(again.json.walk.state.dimensions.school.otherText, note);
  assert.equal(again.json.walk.state.dimensions.grade.selectedValueCode, "7");
  assert.equal(again.json.walk.state.dimensions.date.dateValue, "2026-09-17");
  assert.equal(again.json.walk.rowVersion, saved.json.walk.rowVersion);
  const list = await A.call("GET", "/api/walks");
  const card = list.json.walks.find((x) => x.id === w.id);
  assert.equal(card.state.dimensions.school.otherText, note, "list carries the card dimensions");
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
  const payload = { rowVersion: w.rowVersion, clientMutationId: mutation, dimensions: { grade: { selectedValueCode: "4" } }, responses: { comp_s2_q1: { storedCode: "2" } } };
  const first = await A.call("PUT", `/api/walks/${w.id}`, payload);
  assert.equal(first.status, 200, first.text);
  const stale = await A.call("PUT", `/api/walks/${w.id}`, { ...payload, clientMutationId: uuid(), dimensions: { grade: { selectedValueCode: "1" } } });
  assert.equal(stale.status, 409);
  assert.equal(stale.json.error.code, "STALE_ROW_VERSION");
  assert.equal(stale.json.error.details.serverRowVersion, first.json.walk.rowVersion);
  const replay = await A.call("PUT", `/api/walks/${w.id}`, payload);
  assert.equal(replay.status, 200, replay.text);
  assert.equal(replay.json.walk.replayed, true);
  assert.equal(replay.json.walk.rowVersion, first.json.walk.rowVersion);
  const current = await A.call("GET", `/api/walks/${w.id}`);
  assert.equal(current.json.walk.state.dimensions.grade.selectedValueCode, "4", "the stale write did not overwrite");
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
  const dv = await A.call("POST", `/api/walks/${draft.id}/void`, { clientMutationId: uuid() });
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
