// Phase 8 hardening: the whole HTTP surface, route by route (SEC-01, SEC-02, SEC-03, SEC-04, AUTH-01,
// AUTH-05, AUTH-06 and the request-size rule).
//
// The route list is read from src/http/Router.cfc, and every route there must be classified below:
// a route added later without a security expectation fails this file instead of going untested.
// For every route it proves, against the running application and real SQL Server:
//
//   - anonymous: 401 UNAUTHENTICATED with a body of `error` only (maintenance routes 404; health 200);
//   - the capability wall: a user without the route's capability gets 403 FORBIDDEN, and a user with
//     it gets past the route (whatever the controller then says about an unknown record);
//   - CSRF on every state-changing route: no token, a malformed token, another live session's token,
//     and the same person's token from a session that has ended are all 403 CSRF_TOKEN_INVALID, and
//     the database is byte-for-byte unchanged;
//   - request size: a declared body one byte over the route's limit is 413, with the limit named,
//     before any byte of it is sent;
//   - injection: SQL, markup, traversal, NUL and oversized values in every path parameter and in every
//     free query parameter are refused as data (400/404), never 5xx, and no answer carries engine,
//     driver or SQL error text;
//   - headers: every answer is no-store, nosniff and correlated, and every API answer is JSON;
//   - the session: an identity's session id is rotated at sign-in, a signed-out session's token is
//     dead, and the session cookie is HttpOnly and SameSite=Lax.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import net from "node:net";
import path from "node:path";
import crypto from "node:crypto";
import sql from "mssql";
import { api, baseUrl, connectionConfig, hasDatabaseConfig, loadRuntimeEnv, requireApp, root } from "./helpers.mjs";

const env = loadRuntimeEnv();
const token = env.ICFWALK_MAINTENANCE_TOKEN || "";
const tag = `p8sec-${Date.now().toString(36)}`;

async function reachable() {
  try {
    const r = await fetch(`${baseUrl(env)}/index.cfm/api/health`, { signal: AbortSignal.timeout(10000) });
    if (r.status !== 200) return false;
    const body = await r.json();
    return body.environment === "development" || body.environment === "test";
  } catch { return false; }
}
const up = await reachable();
if (requireApp(env) && (!up || !token || !hasDatabaseConfig(env))) {
  throw new Error(`ICFWALK_REQUIRE_APP is set but the application (development mode), the maintenance token or the database settings are missing (${baseUrl(env)})`);
}
const skip = !up ? `application not reachable in development mode at ${baseUrl(env)}` : !token ? "no maintenance token" : !hasDatabaseConfig(env) ? "no database settings" : false;

// ---- the route inventory ----------------------------------------------------------------------

function routesFromRouter() {
  const text = fs.readFileSync(path.join(root, "src", "http", "Router.cfc"), "utf8");
  const out = [];
  for (const m of text.matchAll(/add\("([A-Z]+)", "(\^[^"]*\$)", "(\w+)", "(\w+)", ([^\n]*)/g)) {
    out.push({ method: m[1], pattern: m[2], controller: m[3], action: m[4], policyText: m[5] });
  }
  return out;
}
const routes = routesFromRouter();
const key = (r) => `${r.method} ${r.pattern}`;

const ALL = ["none", "walker", "reportOnly", "admin"];
const ADMIN = { kind: "session", pass: ["admin"] };
const WALKER = { kind: "session", pass: ["walker"] };
const REPORTS = { kind: "session", pass: ["walker", "reportOnly"] };
const SHELL = { kind: "session", pass: ["walker", "reportOnly", "admin"] };
const MAINT = { kind: "maintenance" };
const IMPORT_LIMIT = 5000000;
const SERVER_LIMIT = 20000000;
const EXPECTED = {
  "GET ^/api/health$": { kind: "public" },
  "GET ^/$": SHELL,
  "GET ^/api/instrument/current$": SHELL,
  "GET ^/api/me$": { kind: "session", pass: ALL },
  "GET ^/api/auth/csrf-token$": { kind: "session", pass: ALL },
  "POST ^/api/auth/sign-out$": { kind: "session", pass: ALL },
  "GET ^/api/admin/instrument/versions$": ADMIN,
  "POST ^/api/admin/instrument/versions/([^/]+)/publish$": { ...ADMIN, noBody: true },
  "POST ^/api/admin/instrument/import$": { ...ADMIN, limit: IMPORT_LIMIT, tooLarge: "DOCUMENT_TOO_LARGE" },
  "GET ^/api/admin/instrument/compare$": { ...ADMIN, query: ["from", "to"] },
  "GET ^/api/admin/instrument/versions/([^/]+)/preview$": ADMIN,
  "GET ^/api/admin/instrument/versions/([^/]+)/wording$": ADMIN,
  "GET ^/api/admin/instrument/versions/([^/]+)/document$": ADMIN,
  "GET ^/api/admin/instrument/versions/([^/]+)/placeholders$": { ...ADMIN, query: ["q"] },
  "POST ^/api/admin/instrument/versions/([^/]+)/clone$": ADMIN,
  "POST ^/api/admin/instrument/versions/([^/]+)/edits$": ADMIN,
  "POST ^/api/admin/instrument/versions/([^/]+)/discard$": { ...ADMIN, noBody: true },
  "POST ^/api/admin/instrument/versions/([^/]+)/retire$": { ...ADMIN, noBody: true },
  "GET ^/api/walks$": { ...WALKER, query: ["scope"] },
  "POST ^/api/walks$": { ...WALKER, orgUnitBody: true },
  "GET ^/api/walks/([^/]+)$": WALKER,
  "GET ^/api/walks/([^/]+)/instrument$": WALKER,
  "GET ^/api/walks/([^/]+)/summary$": WALKER,
  "PUT ^/api/walks/([^/]+)$": WALKER,
  "POST ^/api/walks/([^/]+)/complete$": WALKER,
  "POST ^/api/walks/([^/]+)/void$": WALKER,
  "DELETE ^/api/walks/([^/]+)$": WALKER,
  "GET ^/api/reports/options$": REPORTS,
  "GET ^/api/reports/aggregate\\.csv$": { ...REPORTS, query: ["versionId", "orgUnitId", "section", "item", "dateFrom"] },
  "GET ^/api/reports/aggregate$": { ...REPORTS, query: ["versionId", "orgUnitId", "section", "item", "dateFrom"] },
  "POST ^/api/reports/releases$": { ...REPORTS, serviceRefusal: { reportOnly: "REPORT_RELEASE_NOT_PERMITTED" } },
  "POST ^/api/maintenance/instrument/import$": MAINT,
  "GET ^/api/maintenance/instrument/versions$": MAINT,
  "POST ^/api/maintenance/instrument/discard-draft$": MAINT,
  "POST ^/api/maintenance/org-units/import$": MAINT,
  "POST ^/api/maintenance/org-units/align-school-dimension$": MAINT,
  "POST ^/api/maintenance/identity/provision-user$": MAINT,
  "POST ^/api/maintenance/identity/assign-role$": MAINT,
  "POST ^/api/maintenance/identity/cleanup-fixtures$": MAINT,
  "POST ^/api/maintenance/tests/run$": MAINT,
  "GET ^/api/maintenance/tests/run$": MAINT,
};

const MUTATING = new Set(["POST", "PUT", "PATCH", "DELETE"]);
const UNKNOWN_ID = "3F0E6C39-0000-4000-8000-00000000A8E8";
/** A concrete path for a route, with every capture group filled by `value` (already encoded). */
function concrete(route, value = UNKNOWN_ID) {
  return route.pattern.replace(/^\^/, "").replace(/\$$/, "").replace(/\(\[\^\/\]\+\)/g, value).replace(/\\\./g, ".");
}
const hasParam = (route) => route.pattern.includes("([^/]+)");
const expected = (route) => EXPECTED[key(route)];

// ---- HTTP helpers -----------------------------------------------------------------------------

function jar() {
  const cookies = new Map();
  let last = [];
  return {
    header() { return [...cookies.entries()].map(([k, v]) => `${k}=${v}`).join("; "); },
    absorb(response) {
      last = response.headers.getSetCookie ? response.headers.getSetCookie() : [];
      for (const line of last) {
        const [pair] = line.split(";");
        const eq = pair.indexOf("=");
        cookies.set(pair.slice(0, eq).trim(), pair.slice(eq + 1).trim());
      }
    },
    lastSetCookies() { return last; },
    snapshot() { return new Map(cookies); },
    restore(saved) { cookies.clear(); for (const [k, v] of saved) cookies.set(k, v); },
  };
}

async function call(method, p, { subject, body, rawBody, csrf, cookieJar, accept = "application/json", headers: extra = {} } = {}) {
  const headers = { Accept: accept, ...extra };
  if (subject) headers["X-ICFWalk-Dev-Subject"] = subject;
  if (body !== undefined || rawBody !== undefined) headers["Content-Type"] = "application/json";
  if (csrf) headers["X-ICFWalk-CSRF-Token"] = csrf;
  if (cookieJar && cookieJar.header()) headers.Cookie = cookieJar.header();
  const response = await fetch(`${baseUrl(env)}/index.cfm${p}`, { method, headers, body: rawBody !== undefined ? rawBody : body === undefined ? undefined : JSON.stringify(body), redirect: "manual" });
  if (cookieJar) cookieJar.absorb(response);
  const text = await response.text();
  let json = null;
  try { json = JSON.parse(text); } catch { json = null; }
  return { status: response.status, json, text, headers: response.headers };
}

/** Sends the request head and one byte of a declared body it never finishes, and reads the answer. */
function declaredOnly(method, p, headers, declaredLength, timeoutMs = 30000) {
  return new Promise((resolve, reject) => {
    const url = new URL(`${baseUrl(env)}/index.cfm${p}`);
    const socket = net.connect(Number(url.port || 80), url.hostname);
    const received = [];
    const timer = setTimeout(() => { socket.destroy(); reject(new Error(`${method} ${p}: no answer within ${timeoutMs} ms`)); }, timeoutMs);
    const finish = () => {
      clearTimeout(timer);
      const raw = Buffer.concat(received);
      const split = raw.indexOf("\r\n\r\n");
      if (split < 0) { reject(new Error(`${method} ${p}: no HTTP answer`)); return; }
      const head = raw.subarray(0, split).toString("latin1").split("\r\n");
      const status = Number(head[0].split(" ")[1]);
      let rest = raw.subarray(split + 4);
      if (head.some((l) => /^transfer-encoding:\s*chunked/i.test(l))) {
        const parts = [];
        for (;;) {
          const eol = rest.indexOf("\r\n");
          if (eol < 0) break;
          const size = parseInt(rest.subarray(0, eol).toString("latin1"), 16);
          if (!size) break;
          parts.push(rest.subarray(eol + 2, eol + 2 + size));
          rest = rest.subarray(eol + 2 + size + 2);
        }
        rest = Buffer.concat(parts);
      }
      let json = null;
      try { json = JSON.parse(rest.toString("utf8")); } catch { json = null; }
      resolve({ status, json });
    };
    socket.on("data", (d) => {
      received.push(d);
      // The answer is complete once its JSON body closes; the connection may stay open for the body
      // the client declared and never sent.
      const raw = Buffer.concat(received).toString("latin1");
      if (/\r\n\r\n/.test(raw) && /\}\s*(0\r\n\r\n)?$/.test(raw)) { socket.destroy(); finish(); }
    });
    socket.on("error", () => {});
    socket.on("close", () => { if (received.length) finish(); });
    const h = { Host: url.host, Connection: "close", Accept: "application/json", "Content-Type": "application/json", ...headers, "Content-Length": String(declaredLength) };
    // One byte of the declared body goes with the head. Jetty (the Lucee verification runtime)
    // delays dispatch until some content has arrived (HttpConfiguration.delayDispatchUntilContent,
    // on by default), so a head alone is never handed to the application at all.
    socket.write(`${method} ${url.pathname}${url.search} HTTP/1.1\r\n${Object.entries(h).map(([k, v]) => `${k}: ${v}\r\n`).join("")}\r\n{`);
  });
}

/** Writes a raw request and returns the status and everything the server sent before it closed. */
function rawExchange(request, timeoutMs = 15000) {
  return new Promise((resolve, reject) => {
    const url = new URL(baseUrl(env));
    const socket = net.connect(Number(url.port || 80), url.hostname);
    const received = [];
    const timer = setTimeout(() => { socket.destroy(); reject(new Error(`no answer within ${timeoutMs} ms`)); }, timeoutMs);
    socket.on("data", (d) => received.push(d));
    socket.on("error", () => {});
    socket.on("close", () => {
      clearTimeout(timer);
      const raw = Buffer.concat(received).toString("latin1");
      resolve({ status: Number((raw.split("\r\n")[0] || "").split(" ")[1] || 0), raw });
    });
    socket.write(request);
  });
}

// ---- the database oracle ------------------------------------------------------------------------

let pool = null;
/** Row count and an order-independent checksum of every icf table, and the database's rowversion. */
async function fingerprint() {
  const tables = (await pool.request().query("SELECT name FROM sys.tables WHERE schema_id = SCHEMA_ID(N'icf') ORDER BY name")).recordset.map((r) => r.name);
  const union = tables.map((t) => `SELECT N'${t}' AS t, COUNT_BIG(*) AS n, CHECKSUM_AGG(BINARY_CHECKSUM(*)) AS c FROM [icf].[${t}]`).join(" UNION ALL ");
  const rows = (await pool.request().query(union)).recordset;
  const dbts = (await pool.request().query("SELECT CONVERT(varchar(18), @@DBTS, 1) AS dbts")).recordset[0].dbts;
  const out = { dbts };
  for (const r of rows) out[r.t] = `${r.n}:${r.c}`;
  return out;
}
async function auditTypesSince(maxId) {
  const r = await pool.request().input("since", sql.BigInt, maxId).query("SELECT event_type FROM [icf].[audit_event] WHERE event_id > @since ORDER BY event_id");
  return r.recordset.map((x) => x.event_type);
}
async function maxAuditId() {
  return Number((await pool.request().query("SELECT ISNULL(MAX(event_id), 0) AS m FROM [icf].[audit_event]")).recordset[0].m);
}

// ---- fixtures ---------------------------------------------------------------------------------

const subjects = { none: `${tag}-none`, walker: `${tag}-walker`, reportOnly: `${tag}-reportonly`, admin: `${tag}-admin`, colleague: `${tag}-colleague` };
let schoolId = "";

/** A signed-in session for `who`: its cookie jar and CSRF token. */
async function session(who) {
  const cookieJar = jar();
  const me = await call("GET", "/api/me", { subject: subjects[who], cookieJar });
  assert.equal(me.status, 200, `${who}: ${me.text}`);
  return { cookieJar, csrf: me.json.csrfToken, subject: subjects[who], userId: me.json.user.userId };
}

before(async () => {
  if (skip) return;
  const units = await api(env, "POST", "/api/maintenance/org-units/import", { token, body: { orgUnits: [
    { code: `${tag}-district`, type: "DISTRICT", name: "Security fixture district", parentCode: null },
    { code: `${tag}-school`, type: "SCHOOL", name: "Security fixture school", parentCode: `${tag}-district` },
  ] } });
  assert.equal(units.status, 200, units.text);
  const roles = { walker: ["SCHOOL_WALK_REPORT", "school"], reportOnly: ["SCHOOL_REPORT_ONLY", "school"], admin: ["MASTER_INSTRUMENT_ADMIN", "district"], colleague: ["SCHOOL_WALK_REPORT", "school"] };
  for (const [who, subject] of Object.entries(subjects)) {
    const u = await api(env, "POST", "/api/maintenance/identity/provision-user", { token, body: { subject, displayName: `Security ${who}` } });
    assert.ok(u.status === 201 || u.status === 200, u.text);
    if (roles[who]) {
      const a = await api(env, "POST", "/api/maintenance/identity/assign-role", { token, body: { subject, roleCode: roles[who][0], orgUnitCode: `${tag}-${roles[who][1]}` } });
      assert.equal(a.status, 201, a.text);
    }
  }
  const me = await call("GET", "/api/me", { subject: subjects.walker });
  schoolId = Object.keys(me.json.orgUnits).find((id) => me.json.orgUnits[id].code === `${tag}-school`);
  assert.ok(schoolId, "the fixture school is in the walker's scope");
  pool = await sql.connect(connectionConfig(env, env.ICFWALK_DB_NAME || "icfwalk_dev"));
});

after(async () => {
  if (pool) await pool.close();
  if (!skip) {
    const r = await api(env, "POST", "/api/maintenance/identity/cleanup-fixtures", { token, body: { tag } });
    if (r.status !== 200) console.error("fixture cleanup failed", r.status, r.text);
  }
});

// ---- the tests --------------------------------------------------------------------------------

test("the route inventory: every route in Router.cfc is classified here, and nothing else is", () => {
  assert.ok(routes.length >= 40, `parsed ${routes.length} routes`);
  assert.deepEqual(routes.map(key).sort(), Object.keys(EXPECTED).sort());
  for (const r of routes) {
    const e = expected(r);
    if (e.kind === "public") assert.match(r.policyText, /^"public"/, key(r));
    else if (e.kind === "maintenance") assert.match(r.policyText, /^"maintenance"/, key(r));
    else assert.match(r.policyText, /^\{/, `${key(r)} declares a session policy`);
  }
});

const LEAK = /SQLServerException|Incorrect syntax|Unclosed quotation|conversion failed|jdbc|java\.[a-z]|lucee\.|coldfusion\.|stack ?trace|tagContext/i;
/**
 * Every answer: no 5xx and nothing from the engine, the driver or SQL. An answer from the application
 * (it carries X-Correlation-Id) is also no-store and nosniff. The servlet container itself refuses a few
 * malformed paths (an encoded slash, a NUL) before the application exists for the request; such an
 * answer must be a 400 and leak nothing, but cannot carry the application's headers.
 */
function assertSafeAnswer(r, label) {
  assert.ok(r.status < 500, `${label}: ${r.status} ${r.text.slice(0, 300)}`);
  assert.doesNotMatch(r.text, LEAK, `${label} leaks engine or SQL detail`);
  const correlation = r.headers.get("x-correlation-id");
  if (!correlation) {
    assert.equal(r.status, 400, `${label}: an answer without the application's headers must be the container's 400 (${r.status})`);
    return;
  }
  assert.match(correlation, /^[A-Za-z0-9._-]{8,64}$/, `${label}: correlation id`);
  assert.equal(r.headers.get("cache-control"), "no-store", `${label}: Cache-Control`);
  assert.equal(r.headers.get("x-content-type-options"), "nosniff", `${label}: nosniff`);
}

test("anonymous: every session route is 401 with nothing but an error; maintenance routes do not exist; health answers", { skip }, async () => {
  const before = await fingerprint();
  for (const r of routes) {
    const e = expected(r);
    const res = await call(r.method, concrete(r), { body: MUTATING.has(r.method) && !e.noBody ? {} : undefined });
    const label = `${r.method} ${concrete(r)}`;
    assertSafeAnswer(res, label);
    if (e.kind === "public") { assert.equal(res.status, 200, label); continue; }
    if (e.kind === "maintenance") { assert.equal(res.status, 404, label); assert.equal(res.json.error.code, "NOT_FOUND", label); continue; }
    assert.equal(res.status, 401, `${label}: ${res.text}`);
    assert.match(res.headers.get("content-type") || "", /^application\/json/, label);
    assert.deepEqual(Object.keys(res.json), ["error"], `${label}: nothing but the error`);
    assert.equal(res.json.error.code, "UNAUTHENTICATED", label);
  }
  assert.deepEqual(await fingerprint(), before, "anonymous requests wrote nothing");
});

test("the capability wall: each route admits exactly the roles that hold its capability, and a refusal writes only its ACCESS_DENIED audit", { skip }, async () => {
  const sessions = {};
  for (const who of ALL) sessions[who] = await session(who);
  for (const r of routes) {
    const e = expected(r);
    if (e.kind !== "session" || key(r) === "POST ^/api/auth/sign-out$") continue;
    for (const who of ALL) {
      const s = sessions[who];
      const body = !MUTATING.has(r.method) || e.noBody ? undefined : e.orgUnitBody ? { orgUnitId: schoolId } : {};
      const auditBefore = await maxAuditId();
      const fp = await fingerprint();
      const res = await call(r.method, concrete(r), { subject: s.subject, cookieJar: s.cookieJar, csrf: MUTATING.has(r.method) ? s.csrf : undefined, body });
      const label = `${who} ${r.method} ${concrete(r)}`;
      assertSafeAnswer(res, label);
      assert.notEqual(res.status, 401, label);
      if (!e.pass.includes(who)) {
        assert.equal(res.status, 403, `${label}: ${res.text}`);
        assert.equal(res.json.error.code, "FORBIDDEN", label);
        assert.deepEqual(Object.keys(res.json), ["error"], `${label}: nothing but the error`);
        const after = await fingerprint();
        const written = await auditTypesSince(auditBefore);
        assert.ok(written.every((t) => t === "ACCESS_DENIED"), `${label}: ${written}`);
        delete fp.audit_event; delete after.audit_event; delete fp.dbts; delete after.dbts;
        assert.deepEqual(after, fp, `${label}: a refusal changed data`);
      } else {
        const allowed = e.serviceRefusal && e.serviceRefusal[who];
        assert.ok(!(res.status === 403 && res.json?.error?.code === "FORBIDDEN"), `${label} was refused at the route: ${res.text}`);
        if (allowed && res.status === 403) assert.equal(res.json.error.code, allowed, label);
      }
    }
  }
});

test("CSRF: every state-changing session route refuses a missing, malformed, foreign or ended session's token, and nothing is written", { skip }, async () => {
  const walker = await session("walker");
  const admin = await session("admin");
  const colleague = await session("colleague");
  // The walker's token from a session that has ended.
  const ended = await session("walker");
  const signOut = await call("POST", "/api/auth/sign-out", { subject: ended.subject, cookieJar: ended.cookieJar, csrf: ended.csrf, body: {} });
  assert.equal(signOut.status, 200, signOut.text);
  // Re-establish the walker's live session after the sign-out (sign-out ends the server session, not the identity).
  const live = await session("walker");
  const fp = await fingerprint();
  const auditBefore = await maxAuditId();
  for (const r of routes) {
    const e = expected(r);
    if (e.kind !== "session" || !MUTATING.has(r.method)) continue;
    const s = e.pass.includes("admin") && !e.pass.includes("walker") ? admin : live;
    const body = e.noBody ? undefined : e.orgUnitBody ? { orgUnitId: schoolId } : {};
    const cases = { missing: undefined, malformed: "not-a-token", wrong: "f".repeat(64), foreign: colleague.csrf, ended: ended.csrf };
    for (const [name, csrf] of Object.entries(cases)) {
      const res = await call(r.method, concrete(r), { subject: s.subject, cookieJar: s.cookieJar, csrf, body });
      const label = `${name} token: ${r.method} ${concrete(r)}`;
      assertSafeAnswer(res, label);
      assert.equal(res.status, 403, `${label}: ${res.text}`);
      assert.equal(res.json.error.code, "CSRF_TOKEN_INVALID", label);
    }
  }
  assert.deepEqual(await fingerprint(), fp, "no refused request wrote anything");
  assert.deepEqual(await auditTypesSince(auditBefore), [], "and nothing was audited");
  assert.notEqual(ended.csrf, live.csrf, "a new session has a new token");
  void walker;
});

test("request size: a declared body one byte over the route's limit is refused 413, naming the limit, before it is sent", { skip }, async () => {
  const walker = await session("walker");
  const admin = await session("admin");
  for (const r of routes) {
    const e = expected(r);
    if (!MUTATING.has(r.method) || e.kind === "public") continue;
    const limit = e.limit || SERVER_LIMIT;
    const code = e.tooLarge || "PAYLOAD_TOO_LARGE";
    let headers;
    if (e.kind === "maintenance") headers = { "X-ICFWalk-Maintenance-Token": token };
    else {
      const s = e.pass.includes("admin") && !e.pass.includes("walker") ? admin : walker;
      headers = { "X-ICFWalk-Dev-Subject": s.subject, "X-ICFWalk-CSRF-Token": s.csrf, Cookie: s.cookieJar.header() };
    }
    const res = await declaredOnly(r.method, concrete(r), headers, limit + 1);
    const label = `${r.method} ${concrete(r)} declaring ${limit + 1} bytes`;
    assert.equal(res.status, 413, `${label}: ${JSON.stringify(res.json)}`);
    assert.equal(res.json.error.code, code, label);
    assert.equal(res.json.error.details.limitBytes, limit, label);
  }
});

const PATH_PAYLOADS = [
  "' OR '1'='1",
  "1; DROP TABLE icf.walk; --",
  "1' WAITFOR DELAY '0:0:5'--",
  "<script>alert(1)</script>",
  "\"><img src=x onerror=alert(1)>",
  "..\\..\\windows\\win.ini",
  "%00",
  "00000000-0000-0000-0000-000000000000",
  "3F0E6C39-0000-4000-8000-00000000A8E8' OR 1=1 --",
  "x".repeat(3000),
  "‮\u0000￿",
];

test("injection: every path parameter refuses SQL, markup, traversal and oversized values as data, quickly and without a leak", { skip }, async () => {
  const walker = await session("walker");
  const admin = await session("admin");
  const fp = await fingerprint();
  for (const r of routes.filter(hasParam)) {
    const e = expected(r);
    const s = e.pass.includes("admin") && !e.pass.includes("walker") ? admin : walker;
    for (const payload of PATH_PAYLOADS) {
      const started = Date.now();
      const res = await call(r.method, concrete(r, encodeURIComponent(payload)), { subject: s.subject, cookieJar: s.cookieJar, csrf: MUTATING.has(r.method) ? s.csrf : undefined, body: MUTATING.has(r.method) && !e.noBody ? {} : undefined });
      const label = `${r.method} ${r.pattern} with ${JSON.stringify(payload.slice(0, 40))}`;
      assertSafeAnswer(res, label);
      assert.ok([400, 404].includes(res.status), `${label}: ${res.status} ${res.text.slice(0, 200)}`);
      assert.ok(Date.now() - started < 4000, `${label} took ${Date.now() - started} ms (a time-based payload must not delay the answer)`);
    }
  }
  const after = await fingerprint();
  // Refusals of records outside the caller's scope are audited (ACCESS_DENIED); nothing else moves.
  delete fp.audit_event; delete after.audit_event; delete fp.dbts; delete after.dbts;
  assert.deepEqual(after, fp, "no payload changed any data");
});

const QUERY_PAYLOADS = ["' OR 1=1 --", "<svg onload=alert(1)>", "1;DROP TABLE icf.walk", "%", "_", "[", "x".repeat(5000)];

test("injection: every free query parameter is data, never SQL, and never a 5xx", { skip }, async () => {
  const walker = await session("walker");
  const admin = await session("admin");
  const versions = await call("GET", "/api/admin/instrument/versions", { subject: admin.subject, cookieJar: admin.cookieJar });
  const versionId = versions.json.versions.find((v) => v.versionLabel === "2026-09-17 aligned prototype").versionId;
  for (const r of routes.filter((x) => expected(x).query)) {
    const e = expected(r);
    const s = e.pass.includes("admin") && !e.pass.includes("walker") ? admin : walker;
    const base = r.pattern.includes("placeholders") ? concrete(r, versionId) : concrete(r);
    for (const param of e.query) {
      for (const payload of QUERY_PAYLOADS) {
        const res = await call("GET", `${base}?${param}=${encodeURIComponent(payload)}`, { subject: s.subject, cookieJar: s.cookieJar });
        const label = `${r.method} ${base}?${param}=${JSON.stringify(payload.slice(0, 30))}`;
        assertSafeAnswer(res, label);
        assert.ok(res.status < 500, label);
        if (res.status === 200 && param === "q") assert.equal(res.json.total, 17, `${label}: a search narrows, never widens or errors`);
      }
    }
  }
});

test("the session: its id is rotated at sign-in, its cookie is HttpOnly and SameSite=Lax and lives no longer than the browser, and a signed-out session's token is dead", { skip }, async (t) => {
  const cookieJar = jar();
  // Fixation: whatever session an anonymous visit is given, signing in must not keep it.
  const anonymous = await call("GET", "/api/me", { cookieJar });
  assert.equal(anonymous.status, 401);
  const planted = cookieJar.snapshot();
  const plantedLines = cookieJar.lastSetCookies();
  const me = await call("GET", "/api/me", { subject: subjects.walker, cookieJar });
  assert.equal(me.status, 200, me.text);
  const signedIn = cookieJar.snapshot();
  const signInLines = cookieJar.lastSetCookies();
  assert.ok(signInLines.length > 0, "signing in sets the session cookie");
  const describe = (line) => {
    const name = line.split("=")[0];
    const persistent = /;\s*Max-Age=[1-9]/i.test(line) || (/;\s*Expires=([^;]+)/i.test(line) && Date.parse(/;\s*Expires=([^;]+)/i.exec(line)[1]) > Date.now());
    return `${name}${persistent ? " (persistent)" : ""}`;
  };
  t.diagnostic(`anonymous visit set: ${plantedLines.map(describe).join(", ") || "nothing"}; sign-in set: ${signInLines.map(describe).join(", ")}`);
  // The session key is every planted cookie with a secret value. Lucee's cftoken is the constant "0"
  // (Lucee keys a session by cfid alone), so it identifies nothing and cannot be rotated.
  const keyCookies = [...planted].filter(([, value]) => value !== "0");
  assert.ok(planted.size === 0 || keyCookies.length > 0, "an anonymous session has a key");
  for (const [name, value] of keyCookies) assert.notEqual(signedIn.get(name), value, `session cookie ${name} was not rotated at sign-in`);
  for (const line of [...plantedLines, ...signInLines]) {
    assert.match(line, /;\s*HttpOnly/i, line.split("=")[0]);
    assert.match(line, /;\s*SameSite=Lax/i, line.split("=")[0]);
    // A session identifier that outlives the browser session is a persistent credential on a shared
    // computer; it may only be a session cookie (or a deletion, which some engines send while rotating).
    assert.doesNotMatch(describe(line), /persistent/, `${line.split("=")[0]} is a persistent cookie: ${line.replace(/=[^;]*/, "=...")}`);
  }
  // The token of a session that has ended opens nothing, even with the same identity and cookie.
  const out = await call("POST", "/api/auth/sign-out", { subject: subjects.walker, cookieJar, csrf: me.json.csrfToken, body: {} });
  assert.equal(out.status, 200, out.text);
  const stale = await call("POST", "/api/walks", { subject: subjects.walker, cookieJar, csrf: me.json.csrfToken, body: { orgUnitId: schoolId } });
  assert.equal(stale.status, 403, stale.text);
  assert.equal(stale.json.error.code, "CSRF_TOKEN_INVALID");
  const fresh = await call("GET", "/api/me", { subject: subjects.walker, cookieJar });
  assert.notEqual(fresh.json.csrfToken, me.json.csrfToken, "a new session has a new token");
});

test("methods: an unknown method is 405 and TRACE never echoes the request", { skip }, async () => {
  const s = await session("walker");
  const patch = await call("PATCH", "/api/walks", { subject: s.subject, cookieJar: s.cookieJar, csrf: s.csrf, body: {} });
  assert.equal(patch.status, 405, patch.text);
  // fetch refuses to send TRACE at all, so it goes over a raw socket.
  const trace = await rawExchange(`TRACE /index.cfm/api/health HTTP/1.1\r\nHost: ${new URL(baseUrl(env)).host}\r\nConnection: close\r\nX-Probe-Echo: icfwalk-trace-probe\r\nCookie: ${s.cookieJar.header()}\r\n\r\n`);
  assert.ok(trace.status >= 400, `TRACE answered ${trace.status}`);
  assert.doesNotMatch(trace.raw, /icfwalk-trace-probe/, "TRACE echoed the request");
  assert.doesNotMatch(trace.raw, /cfid=|jsessionid=/i, "TRACE echoed the session cookie");
});

test("a synthetic identity header is never taken for identity outside the development stub, and the stub validates what it is given", { skip }, async () => {
  const bad = await call("GET", "/api/me", { subject: "bad subject with spaces<script>" });
  assert.equal(bad.status, 401, bad.text);
  const sso = await call("GET", "/api/me", { headers: { "X-Auth-Subject": subjects.admin } });
  assert.equal(sso.status, 401, "the SSO header is not honoured by the development adapter");
  void crypto;
});
