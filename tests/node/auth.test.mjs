// HTTP-level authentication/authorization checks (AUTH-01, AUTH-06 route separation, CSRF, session
// cookies) against the running application configured with the development identity stub.
// Fixture users and org units are created through the maintenance endpoints and removed afterwards
// via the CFML fixture cleanup (users named with the run tag).
import { test, after } from "node:test";
import assert from "node:assert/strict";
import { api, baseUrl, loadRuntimeEnv } from "./helpers.mjs";

const env = loadRuntimeEnv();
const token = env.ICFWALK_MAINTENANCE_TOKEN || "";
const tag = `httpauth-${Date.now().toString(36)}`;

async function reachable() {
  try {
    const r = await fetch(`${baseUrl(env)}/index.cfm/api/health`, { signal: AbortSignal.timeout(10000) });
    if (r.status !== 200) return false;
    const body = await r.json();
    return body.environment === "development" || body.environment === "test";
  } catch {
    return false;
  }
}
const up = await reachable();
const skip = up ? false : `application not reachable in development mode at ${baseUrl(env)}`;

/** Minimal cookie jar so the session cookie round-trips like a browser. */
function jar() {
  const cookies = new Map();
  return {
    header() { return [...cookies.entries()].map(([k, v]) => `${k}=${v}`).join("; "); },
    absorb(response) {
      const set = response.headers.getSetCookie ? response.headers.getSetCookie() : [];
      for (const line of set) {
        const [pair] = line.split(";");
        const eq = pair.indexOf("=");
        cookies.set(pair.slice(0, eq).trim(), pair.slice(eq + 1).trim());
      }
    },
    flags(response) { return response.headers.getSetCookie ? response.headers.getSetCookie() : []; },
  };
}

async function call(method, path, { subject, body, csrf, cookieJar, extraHeaders = {} } = {}) {
  const headers = { Accept: "application/json", ...extraHeaders };
  if (subject) headers["X-ICFWalk-Dev-Subject"] = subject;
  if (body !== undefined) headers["Content-Type"] = "application/json";
  if (csrf) headers["X-ICFWalk-CSRF-Token"] = csrf;
  if (cookieJar && cookieJar.header()) headers.Cookie = cookieJar.header();
  const response = await fetch(`${baseUrl(env)}/index.cfm${path}`, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
  if (cookieJar) cookieJar.absorb(response);
  const text = await response.text();
  let json = null;
  try { json = JSON.parse(text); } catch { json = null; }
  return { status: response.status, json, text, response };
}

const admin = `${tag}-admin`;
const walker = `${tag}-walker`;
const nobody = `${tag}-nobody`;

test("fixtures: org units, users, and roles through maintenance endpoints", { skip: skip || (token ? false : "no maintenance token") }, async () => {
  const units = await api(env, "POST", "/api/maintenance/org-units/import", { token, body: { orgUnits: [
    { code: `${tag}-district`, type: "DISTRICT", name: "HTTP fixture district", parentCode: null },
    { code: `${tag}-school`, type: "SCHOOL", name: "HTTP fixture school", parentCode: `${tag}-district` },
  ] } });
  assert.equal(units.status, 200, units.text);
  assert.equal(units.json.imported, 2);
  for (const subject of [admin, walker, nobody]) {
    const r = await api(env, "POST", "/api/maintenance/identity/provision-user", { token, body: { subject, displayName: `HTTP ${subject}` } });
    assert.ok(r.status === 201 || r.status === 200, r.text);
  }
  const a = await api(env, "POST", "/api/maintenance/identity/assign-role", { token, body: { subject: admin, roleCode: "MASTER_INSTRUMENT_ADMIN", orgUnitCode: `${tag}-district` } });
  assert.equal(a.status, 201, a.text);
  const w = await api(env, "POST", "/api/maintenance/identity/assign-role", { token, body: { subject: walker, roleCode: "DISTRICT_WALK_REPORT", orgUnitCode: `${tag}-district`, includeDescendants: true } });
  assert.equal(w.status, 201, w.text);
  const bad = await api(env, "POST", "/api/maintenance/identity/assign-role", { token, body: { subject: walker, roleCode: "NOPE", orgUnitCode: `${tag}-district` } });
  assert.equal(bad.status, 404);
});

test("AUTH-01 authenticated endpoints deny anonymous requests without leaking data", { skip }, async () => {
  for (const path of ["/api/me", "/api/auth/csrf-token", "/api/admin/instrument/versions"]) {
    const r = await call("GET", path);
    assert.equal(r.status, 401, `${path}: ${r.text}`);
    assert.equal(r.json.error.code, "UNAUTHENTICATED");
    assert.ok(!("versions" in r.json), "no protected data");
    assert.ok(!("permissions" in r.json));
  }
  const signOut = await call("POST", "/api/auth/sign-out", { body: {} });
  assert.equal(signOut.status, 401);
  // SSO gateway headers are ignored by the development stub (and untrusted anyway).
  const spoof = await call("GET", "/api/me", { extraHeaders: { "X-Auth-Subject": "someone" } });
  assert.equal(spoof.status, 401);
});

test("signed-in user gets identity, permissions, CSRF token, and a secure session cookie", { skip: skip || (token ? false : "no maintenance token") }, async () => {
  const cookies = jar();
  const me = await call("GET", "/api/me", { subject: walker, cookieJar: cookies });
  assert.equal(me.status, 200, me.text);
  assert.equal(me.json.user.displayName, `HTTP ${walker}`);
  assert.equal(me.json.identityProvider, "development");
  assert.equal(me.json.assignments.length, 1);
  assert.equal(me.json.assignments[0].roleCode, "DISTRICT_WALK_REPORT");
  assert.equal(me.json.assignments[0].coveredOrgUnitCount, 2);
  assert.equal(me.json.permissions["walk.create"].length, 2);
  assert.equal(me.json.permissions["instrument.manage"], false);
  assert.match(me.json.csrfToken, /^[a-f0-9]{64}$/);
  const flags = cookies.flags(me.response).join("\n").toLowerCase();
  assert.match(flags, /httponly/);
  assert.match(flags, /samesite=lax/);
  // Session persists the token across requests; without the token, a POST is rejected.
  const noCsrf = await call("POST", "/api/auth/sign-out", { subject: walker, cookieJar: cookies, body: {} });
  assert.equal(noCsrf.status, 403);
  assert.equal(noCsrf.json.error.code, "CSRF_TOKEN_INVALID");
  const wrongCsrf = await call("POST", "/api/auth/sign-out", { subject: walker, cookieJar: cookies, body: {}, csrf: "f".repeat(64) });
  assert.equal(wrongCsrf.status, 403);
  const again = await call("GET", "/api/auth/csrf-token", { subject: walker, cookieJar: cookies });
  assert.equal(again.json.csrfToken, me.json.csrfToken, "token is stable within the session");
  const ok = await call("POST", "/api/auth/sign-out", { subject: walker, cookieJar: cookies, body: {}, csrf: me.json.csrfToken });
  assert.equal(ok.status, 200, ok.text);
  assert.equal(ok.json.signedOut, true);
});

test("AUTH-06 admin route is separate from walk roles; users without roles are forbidden", { skip: skip || (token ? false : "no maintenance token") }, async () => {
  const asWalker = await call("GET", "/api/admin/instrument/versions", { subject: walker });
  assert.equal(asWalker.status, 403, asWalker.text);
  assert.equal(asWalker.json.error.code, "FORBIDDEN");
  assert.ok(!("versions" in asWalker.json));
  const asNobody = await call("GET", "/api/admin/instrument/versions", { subject: nobody });
  assert.equal(asNobody.status, 403);
  const asAdmin = await call("GET", "/api/admin/instrument/versions", { subject: admin });
  assert.equal(asAdmin.status, 200, asAdmin.text);
  assert.ok(asAdmin.json.versions.some((v) => v.versionLabel === "2026-09-17 aligned prototype"));
  const adminMe = await call("GET", "/api/me", { subject: admin });
  assert.equal(adminMe.json.permissions["instrument.manage"], true);
  assert.equal(adminMe.json.permissions["walk.read"].length, 0);
  assert.equal(adminMe.json.permissions["report.view"].length, 0);
});

test("maintenance endpoints stay token-guarded even for signed-in admins", { skip: skip || (token ? false : "no maintenance token") }, async () => {
  const r = await call("GET", "/api/maintenance/instrument/versions", { subject: admin });
  assert.equal(r.status, 404);
});

after(async () => {
  if (!up || !token) return;
  // Remove fixture users, assignments, walks, and org units created by this run.
  const r = await api(env, "POST", "/api/maintenance/identity/cleanup-fixtures", { token, body: { tag } });
  if (r.status !== 200) console.error("fixture cleanup failed", r.status, r.text);
});
