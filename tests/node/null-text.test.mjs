// Phase 8, defect P8-08: text that spells "null" is text.
//
// Adobe ColdFusion 2023's isNull() answers true for a string whose value is "null", in any letter
// case -- whether the string is a literal, parsed from a request body or read from a struct -- so
// every `isNull(value)` guard in the application treated such a value as absent. Lucee does not. A
// person named Null, a note that says "null", an org unit called NULL: each was silently dropped or
// refused on the platform the application is built for, and kept on the one it was verified on.
//
// Every case here goes through the HTTP API and reads the stored value back, so it holds on either
// engine without knowing which one it is running on.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import crypto from "node:crypto";
import { api, baseUrl, loadRuntimeEnv, requireApp } from "./helpers.mjs";

const env = loadRuntimeEnv();
const token = env.ICFWALK_MAINTENANCE_TOKEN || "";
const tag = `p8null-${Date.now().toString(36)}`;
const walker = `${tag}-walker`;

async function reachable() {
  try {
    const r = await fetch(`${baseUrl(env)}/index.cfm/api/health`, { signal: AbortSignal.timeout(10000) });
    if (r.status !== 200) return false;
    const body = await r.json();
    return body.environment === "development" || body.environment === "test";
  } catch { return false; }
}
const up = await reachable();
if (requireApp(env) && (!up || !token)) throw new Error(`ICFWALK_REQUIRE_APP is set but the application (development mode) or the maintenance token is missing at ${baseUrl(env)}`);
const skip = !up ? `application not reachable in development mode at ${baseUrl(env)}` : !token ? "no maintenance token" : false;

function client(subject, name) {
  const cookies = new Map();
  let csrf = "";
  const call = async (method, p, body) => {
    const headers = { Accept: "application/json", "X-ICFWalk-Dev-Subject": subject };
    if (name !== undefined) headers["X-ICFWalk-Dev-Name"] = name;
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
  return { call };
}

let schoolId = "";

before(async () => {
  if (skip) return;
  const units = await api(env, "POST", "/api/maintenance/org-units/import", { token, body: { orgUnits: [
    { code: `${tag}-district`, type: "DISTRICT", name: "Null text district", parentCode: null },
    { code: `${tag}-school`, type: "SCHOOL", name: "Null text school", parentCode: `${tag}-district` },
  ] } });
  assert.equal(units.status, 200, units.text);
  const u = await api(env, "POST", "/api/maintenance/identity/provision-user", { token, body: { subject: walker, displayName: "Null" } });
  assert.ok(u.status === 200 || u.status === 201, u.text);
  const a = await api(env, "POST", "/api/maintenance/identity/assign-role", { token, body: { subject: walker, roleCode: "SCHOOL_WALK_REPORT", orgUnitCode: `${tag}-school` } });
  assert.equal(a.status, 201, a.text);
});

after(async () => {
  if (skip) return;
  const r = await api(env, "POST", "/api/maintenance/identity/cleanup-fixtures", { token, body: { tag } });
  if (r.status !== 200) console.error("fixture cleanup failed", r.status, r.text);
});

test("P8-08: a person named Null keeps the name", { skip }, async () => {
  const c = client(walker, "Null");
  const me = await c.call("GET", "/api/me");
  assert.equal(me.status, 200, me.text);
  assert.equal(me.json.user.displayName, "Null");
  schoolId = Object.keys(me.json.orgUnits).find((id) => me.json.orgUnits[id].code === `${tag}-school`);
  assert.ok(schoolId);
});

test("P8-08: org units named null and NULL keep their names", { skip }, async () => {
  const units = await api(env, "POST", "/api/maintenance/org-units/import", { token, body: { orgUnits: [
    { code: `${tag}-null-district`, type: "DISTRICT", name: "NULL", parentCode: null },
    { code: `${tag}-null-school`, type: "SCHOOL", name: "null", parentCode: `${tag}-null-district` },
  ] } });
  assert.equal(units.status, 200, units.text.slice(0, 400));
  const who = `${tag}-district-reader`;
  const u = await api(env, "POST", "/api/maintenance/identity/provision-user", { token, body: { subject: who, displayName: "Reader" } });
  assert.ok(u.status === 200 || u.status === 201, u.text);
  const a = await api(env, "POST", "/api/maintenance/identity/assign-role", { token, body: { subject: who, roleCode: "DISTRICT_WALK_REPORT", orgUnitCode: `${tag}-null-district`, includeDescendants: true } });
  assert.equal(a.status, 201, a.text);
  const me = await client(who).call("GET", "/api/me");
  const names = Object.values(me.json.orgUnits).filter((o) => o.code.startsWith(`${tag}-null-`)).map((o) => `${o.code.slice(tag.length)}=${o.name}`).sort();
  assert.deepEqual(names, ["-null-district=NULL", "-null-school=null"]);
});

test("P8-08: a walk keeps every free-text value that spells null, in any case, exactly", { skip }, async () => {
  const c = client(walker, "Null");
  await c.call("GET", "/api/me");
  const created = await c.call("POST", "/api/walks", { orgUnitId: schoolId, clientMutationId: crypto.randomUUID() });
  assert.equal(created.status, 201, created.text);
  const id = created.json.walk.id;
  const draft = JSON.stringify({ body: "NULL", drafted: true, includedPartKeys: [], subject: "null", to: "" });
  const saved = await c.call("PUT", `/api/walks/${id}`, {
    rowVersion: created.json.walk.rowVersion, clientMutationId: crypto.randomUUID(),
    dimensions: { observer: { textValue: "Null" }, topic: { textValue: "NULL" }, tag: { textValue: "null" }, content: { selectedValueCode: "other", otherText: "nUlL" } },
    responses: { comp_s1_notes: { textValue: "null" }, summary_strengths: { textValue: "Null" }, summary_growth: { textValue: "NULL" }, email_workflow: { textValue: draft } },
  });
  assert.equal(saved.status, 200, saved.text);
  const back = await c.call("GET", `/api/walks/${id}`);
  assert.equal(back.status, 200, back.text);
  const { dimensions: d, responses: r } = back.json.walk.state;
  assert.deepEqual(
    { observer: d.observer?.textValue, topic: d.topic?.textValue, tag: d.tag?.textValue, other: d.content?.otherText, note: r.comp_s1_notes?.textValue, strengths: r.summary_strengths?.textValue, growth: r.summary_growth?.textValue, email: r.email_workflow?.textValue },
    { observer: "Null", topic: "NULL", tag: "null", other: "nUlL", note: "null", strengths: "Null", growth: "NULL", email: draft },
  );
  const summary = await fetch(`${baseUrl(env)}/index.cfm/api/walks/${id}/summary`, { headers: { "X-ICFWalk-Dev-Subject": walker, "X-ICFWalk-Dev-Name": "Null" } });
  assert.equal(summary.status, 200);
  const text = await summary.text();
  assert.match(text, /nUlL/, "the summary carries the Other text");
});
