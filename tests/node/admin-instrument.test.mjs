// HTTP-level checks of the Phase 6 instrument administration routes against the running
// application (development identity stub, real SQL Server, real session cookies and CSRF):
//
//   ADM-01  import a document through the admin route, with a validation summary; an invalid
//           document writes nothing and reports every issue; the body and size contracts
//   ADM-02  preview returns the same render model the walk runtime serves
//   ADM-06  a new DRAFT from a published version, a prompt edited in it (with the stale-read
//           refusal), and the comparison showing exactly that change
//   ADM-07  retirement: stops new walks, keeps a historical walk openable and saveable, refuses
//           a repeat and refuses leaving no version in service unless explicitly confirmed
//   ADM-08  the placeholder review queue, its search, and resolving a placeholder by DRAFT edit
//   Excel   a version exported as its document and as a workbook, and edited workbooks -- one
//           edited here, one edited in LibreOffice Calc -- imported as drafts carrying exactly
//           their edits
//   and     discard of a DRAFT, and the 401 / 403 / CSRF posture of every route
//
// Fixtures live under this run's own instrument code, so nothing here publishes, retires or edits
// the ICFWALK instrument the rest of the suite runs on, and they are removed afterwards through
// the test-only maintenance cleanup.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { randomUUID } from "node:crypto";
import http from "node:http";
import net from "node:net";
import sql from "mssql";
import { api, baseUrl, connectionConfig, hasDatabaseConfig, loadRuntimeEnv, requireApp, root } from "./helpers.mjs";
import { canonicalize } from "../../scripts/lib/snapshot.mjs";
import { readWorkbook, writeWorkbook } from "../../app/assets/js/workbook.js";

const env = loadRuntimeEnv();
const token = env.ICFWALK_MAINTENANCE_TOKEN || "";
const tag = `httpadm-${Date.now().toString(36)}`;
const instrumentCode = `${tag}-instrument`;
const SOURCE = JSON.parse(fs.readFileSync(path.join(root, "config", "instrument-config.json"), "utf8"));
const PLACEHOLDER_STATUS = "Placeholder in source";
const PLACEHOLDER_COUNT = SOURCE.items.filter((i) => i.reviewStatus === PLACEHOLDER_STATUS).length;

async function reachable() {
  try {
    const r = await fetch(`${baseUrl(env)}/index.cfm/api/health`, { signal: AbortSignal.timeout(10000) });
    if (r.status !== 200) return false;
    const body = await r.json();
    return body.environment === "development" || body.environment === "test";
  } catch { return false; }
}
const up = await reachable();
if (requireApp(env) && !up) {
  throw new Error(`ICFWALK_REQUIRE_APP is set but the application is not reachable in development mode at ${baseUrl(env)}`);
}
if (requireApp(env) && !token) throw new Error("ICFWALK_REQUIRE_APP is set but ICFWALK_MAINTENANCE_TOKEN is not");
if (requireApp(env) && !hasDatabaseConfig(env)) throw new Error("ICFWALK_REQUIRE_APP is set but ICFWALK_DB_* is not configured");
const skip = !up ? `application not reachable in development mode at ${baseUrl(env)}`
  : !token ? "ICFWALK_MAINTENANCE_TOKEN not set"
  : !hasDatabaseConfig(env) ? "ICFWALK_DB_* not configured"
  : false;

// ---- a browser-like signed-in client -------------------------------------------------------

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

async function client(subject) {
  const cookieJar = jar();
  let csrf = "";
  async function call(method, p, body, { noCsrf = false, badCsrf = false, noIdentity = false, rawBody = undefined } = {}) {
    const headers = { Accept: "application/json" };
    if (!noIdentity) headers["X-ICFWalk-Dev-Subject"] = subject;
    if (body !== undefined || rawBody !== undefined) headers["Content-Type"] = "application/json";
    if (badCsrf) headers["X-ICFWalk-CSRF-Token"] = "f".repeat(64);
    else if (csrf && !noCsrf) headers["X-ICFWalk-CSRF-Token"] = csrf;
    if (cookieJar.header() && !noIdentity) headers.Cookie = cookieJar.header();
    const payload = rawBody !== undefined ? rawBody : (body === undefined ? undefined : JSON.stringify(body));
    const response = await fetch(`${baseUrl(env)}/index.cfm${p}`, { method, headers, body: payload });
    if (!noIdentity) cookieJar.absorb(response);
    const text = await response.text();
    let json = null;
    try { json = JSON.parse(text); } catch { json = null; }
    return { status: response.status, json, text };
  }
  const me = await call("GET", "/api/me");
  assert.equal(me.status, 200, me.text);
  csrf = me.json.csrfToken;
  return { call, me: me.json, csrf: () => csrf, cookie: () => cookieJar.header() };
}

// ---- direct database reads, for facts the API does not expose ------------------------------

let pool = null;
async function db() {
  if (!pool) pool = await sql.connect(connectionConfig(env, env.ICFWALK_DB_NAME || "icfwalk_dev"));
  return pool;
}
async function query(text, params = {}) {
  const request = (await db()).request();
  for (const [k, v] of Object.entries(params)) request.input(k, v);
  return (await request.query(text)).recordset;
}
async function versionRow(versionId) {
  const rows = await query(
    `SELECT status, checksum_sha256, effective_start, effective_end, CAST(row_version AS bigint) AS row_version
       FROM icf.instrument_version WHERE version_id = @id`, { id: versionId });
  return rows[0] ?? null;
}
async function versionCount() {
  const rows = await query(
    "SELECT COUNT(*) AS n FROM icf.instrument_version v JOIN icf.instrument i ON i.instrument_id = v.instrument_id WHERE i.code LIKE @like",
    { like: `${tag}-%` });
  return rows[0].n;
}
async function audits(versionId, eventType) {
  return query(
    "SELECT actor_user_id, details_json FROM icf.audit_event WHERE entity_id = @id AND event_type = @t ORDER BY event_at, event_id",
    { id: versionId, t: eventType });
}

// ---- fixtures --------------------------------------------------------------------------------

const adminSubject = `${tag}-admin`;
const walkerSubject = `${tag}-walker`;
let admin, walker, adminUserId, walkerUserId, districtId;
let labelCounter = 0;

/** The real instrument document under this run's instrument code and a fresh label. */
function documentFor(suffix, mutate = null) {
  const doc = structuredClone(SOURCE);
  doc.instrument.code = instrumentCode;
  doc.instrument.version.versionLabel = `${tag}-${suffix}-${++labelCounter}`;
  if (mutate) mutate(doc);
  return doc;
}

async function importDraft(suffix, mutate = null) {
  const r = await admin.call("POST", "/api/admin/instrument/import", { document: documentFor(suffix, mutate) });
  assert.equal(r.status, 201, r.text);
  return r.json;
}

async function publish(versionId) {
  const r = await admin.call("POST", `/api/admin/instrument/versions/${versionId}/publish`);
  assert.equal(r.status, 200, r.text);
  return r.json;
}

const v = (id, action) => `/api/admin/instrument/versions/${id}/${action}`;

before(async () => {
  if (skip) return;
  const units = await api(env, "POST", "/api/maintenance/org-units/import", { token, body: { orgUnits: [
    { code: `${tag}-district`, type: "DISTRICT", name: "Admin fixture district", parentCode: null },
  ] } });
  assert.equal(units.status, 200, units.text);
  for (const subject of [adminSubject, walkerSubject]) {
    const r = await api(env, "POST", "/api/maintenance/identity/provision-user", { token, body: { subject, displayName: `Admin ${subject}` } });
    assert.ok(r.status === 201 || r.status === 200, r.text);
    if (subject === adminSubject) adminUserId = r.json.userId;
    else walkerUserId = r.json.userId;
  }
  const a = await api(env, "POST", "/api/maintenance/identity/assign-role", { token, body: { subject: adminSubject, roleCode: "MASTER_INSTRUMENT_ADMIN", orgUnitCode: `${tag}-district` } });
  assert.equal(a.status, 201, a.text);
  const w = await api(env, "POST", "/api/maintenance/identity/assign-role", { token, body: { subject: walkerSubject, roleCode: "DISTRICT_WALK_REPORT", orgUnitCode: `${tag}-district`, includeDescendants: true } });
  assert.equal(w.status, 201, w.text);
  districtId = w.json.orgUnitId;
  admin = await client(adminSubject);
  walker = await client(walkerSubject);
});

after(async () => {
  if (!skip) {
    const r = await api(env, "POST", "/api/maintenance/identity/cleanup-fixtures", { token, body: { tag } });
    if (r.status !== 200) console.error("admin fixture cleanup failed", r.status, r.text);
  }
  if (pool) { await pool.close(); pool = null; }
});

// ---- authentication, authorization, CSRF on every route --------------------------------------

test("every administration route refuses anonymous callers, users without instrument.manage, and a POST without CSRF", { skip }, async () => {
  const draft = await importDraft("posture");
  const before = await versionRow(draft.versionId);
  const id = draft.versionId;
  const routes = [
    ["GET", "/api/admin/instrument/versions"],
    ["POST", "/api/admin/instrument/import", { document: documentFor("posture-x") }],
    ["GET", `/api/admin/instrument/compare?from=${id}&to=${id}`],
    ["GET", v(id, "preview")],
    ["GET", `${v(id, "wording")}?q=prompt`],
    ["GET", v(id, "placeholders")],
    ["GET", v(id, "document")],
    ["POST", v(id, "clone"), { versionLabel: `${tag}-posture-clone` }],
    ["POST", v(id, "edits"), { expectedChecksum: draft.checksum, edits: [{ target: "version", field: "revisionNotes", value: "x" }] }],
    ["POST", v(id, "discard")],
    ["POST", v(id, "retire")],
    ["POST", v(id, "publish")],
  ];
  assert.equal(walker.me.permissions["instrument.manage"], false, "precondition: the walker has no instrument.manage");
  for (const [method, p, body] of routes) {
    const anonymous = await admin.call(method, p, body, { noIdentity: true });
    assert.equal(anonymous.status, 401, `${method} ${p}: ${anonymous.text}`);
    assert.equal(anonymous.json.error.code, "UNAUTHENTICATED");
    const forbidden = await walker.call(method, p, body);
    assert.equal(forbidden.status, 403, `${method} ${p}: ${forbidden.text}`);
    assert.equal(forbidden.json.error.code, "FORBIDDEN");
    if (method === "POST") {
      const missing = await admin.call(method, p, body, { noCsrf: true });
      assert.equal(missing.status, 403, `${method} ${p}: ${missing.text}`);
      assert.equal(missing.json.error.code, "CSRF_TOKEN_INVALID");
      const wrong = await admin.call(method, p, body, { badCsrf: true });
      assert.equal(wrong.status, 403, `${method} ${p}: ${wrong.text}`);
      assert.equal(wrong.json.error.code, "CSRF_TOKEN_INVALID");
    }
  }
  const after = await versionRow(draft.versionId);
  assert.equal(after.status, "DRAFT", "no refused call changed the draft");
  assert.equal(after.row_version, before.row_version);
  assert.equal(after.checksum_sha256, before.checksum_sha256);
  const labels = await query("SELECT version_label FROM icf.instrument_version WHERE version_label IN (@a, @b)", { a: `${tag}-posture-clone`, b: `${tag}-posture-x-2` });
  assert.equal(labels.length, 0, "no refused import or clone wrote a version");
});

// ---- ADM-01 import ---------------------------------------------------------------------------

test("ADM-01: an administrator imports a document and gets the validation summary; re-import answers 200", { skip }, async () => {
  const doc = documentFor("import");
  const r = await admin.call("POST", "/api/admin/instrument/import", { document: doc });
  assert.equal(r.status, 201, r.text);
  assert.equal(r.json.status, "DRAFT");
  assert.equal(r.json.created, true);
  assert.equal(r.json.instrumentCode, instrumentCode);
  assert.equal(r.json.versionLabel, doc.instrument.version.versionLabel);
  assert.match(r.json.checksum, /^[0-9a-f]{64}$/);
  for (const [k, n] of Object.entries(SOURCE.counts)) assert.equal(r.json.counts[k], n, `count ${k}`);
  assert.equal(r.json.counts.placeholders, PLACEHOLDER_COUNT);
  assert.equal(r.json.placeholders.length, PLACEHOLDER_COUNT);
  assert.ok(r.json.placeholders.every((p) => p.reviewStatus === PLACEHOLDER_STATUS && typeof p.itemKey === "string"));
  assert.ok(Array.isArray(r.json.warnings));

  const created = await audits(r.json.versionId, "INSTRUMENT_VERSION_CREATED");
  assert.equal(created.length, 1);
  assert.equal(created[0].actor_user_id.toUpperCase(), adminUserId.toUpperCase(), "the import is attributed to the signed-in administrator");

  // Re-import is an explicit replacement of the exact DRAFT (P6A-02). Without one it is refused and
  // nothing moves; with one it answers 200 on the same version.
  const rowBefore = await versionRow(r.json.versionId);
  const unasked = await admin.call("POST", "/api/admin/instrument/import", { document: doc });
  assert.equal(unasked.status, 409, unasked.text);
  assert.equal(unasked.json.error.code, "DRAFT_REPLACEMENT_REQUIRED");
  assert.equal(unasked.json.error.details.versionId, r.json.versionId);
  assert.equal(unasked.json.error.details.currentChecksum, r.json.checksum);
  assert.equal((await versionRow(r.json.versionId)).row_version, rowBefore.row_version, "a refused create-only import moved nothing");

  const again = await admin.call("POST", "/api/admin/instrument/import", { document: doc, replace: { versionId: r.json.versionId, expectedChecksum: r.json.checksum } });
  assert.equal(again.status, 200, again.text);
  assert.equal(again.json.created, false);
  assert.equal(again.json.versionId, r.json.versionId);
  assert.equal(again.json.checksum, r.json.checksum);
});

test("P6A-02: an import replaces a DRAFT only when it names that DRAFT's exact id and checksum", { skip }, async () => {
  const doc = documentFor("replace-contract");
  const first = await admin.call("POST", "/api/admin/instrument/import", { document: doc });
  assert.equal(first.status, 201, first.text);
  const id = first.json.versionId;
  const edited = await admin.call("POST", v(id, "edits"), { expectedChecksum: first.json.checksum, edits: [{ target: "version", field: "revisionNotes", value: "Edited after the upload was prepared" }] });
  assert.equal(edited.status, 200, edited.text);
  const before = await versionRow(id);
  const successes = (await audits(id, "INSTRUMENT_VERSION_REIMPORTED")).length;

  // A token made against the state before the edit: refused, nothing moves.
  const stale = await admin.call("POST", "/api/admin/instrument/import", { document: doc, replace: { versionId: id, expectedChecksum: first.json.checksum } });
  assert.equal(stale.status, 409, stale.text);
  assert.equal(stale.json.error.code, "DRAFT_CHANGED");
  assert.equal(stale.json.error.details.currentChecksum, edited.json.checksum);
  // Another id under this label, and a label with nothing under it: refused, nothing created.
  const otherId = await admin.call("POST", "/api/admin/instrument/import", { document: doc, replace: { versionId: randomUUID().toUpperCase(), expectedChecksum: edited.json.checksum } });
  assert.equal(otherId.status, 409, otherId.text);
  assert.equal(otherId.json.error.code, "DRAFT_CHANGED");
  const free = documentFor("replace-free");
  const nothing = await admin.call("POST", "/api/admin/instrument/import", { document: free, replace: { versionId: id, expectedChecksum: edited.json.checksum } });
  assert.equal(nothing.status, 409, nothing.text);
  assert.equal(nothing.json.error.code, "DRAFT_CHANGED");
  const freeRows = await query("SELECT COUNT(*) AS n FROM icf.instrument_version WHERE version_label = @l", { l: free.instrument.version.versionLabel });
  assert.equal(freeRows[0].n, 0, "a replacement never creates");
  // Malformed tokens.
  for (const replace of ["x", [], { versionId: id }, { expectedChecksum: edited.json.checksum }, { versionId: "nope", expectedChecksum: edited.json.checksum },
    { versionId: id, expectedChecksum: "abc" }, { versionId: id, expectedChecksum: edited.json.checksum, force: true }]) {
    const bad = await admin.call("POST", "/api/admin/instrument/import", { document: doc, replace });
    assert.equal(bad.status, 400, `${JSON.stringify(replace)}: ${bad.text}`);
    assert.equal(bad.json.error.code, "REPLACE_INVALID");
  }
  const after = await versionRow(id);
  assert.equal(after.row_version, before.row_version, "no refused import moved the DRAFT");
  assert.equal(after.checksum_sha256, before.checksum_sha256);
  assert.equal((await audits(id, "INSTRUMENT_VERSION_REIMPORTED")).length, successes, "and none was audited as a success");

  // The exact current state: replaced, once, audited against it.
  const ok = await admin.call("POST", "/api/admin/instrument/import", { document: doc, replace: { versionId: id, expectedChecksum: edited.json.checksum } });
  assert.equal(ok.status, 200, ok.text);
  assert.equal(ok.json.versionId, id);
  const replaced = await audits(id, "INSTRUMENT_VERSION_REIMPORTED");
  assert.equal(replaced.length, successes + 1);
  const details = JSON.parse(replaced[replaced.length - 1].details_json);
  assert.equal(details.replacedVersionId, id);
  assert.equal(details.previousChecksum, edited.json.checksum);
  assert.equal(replaced[replaced.length - 1].actor_user_id.toUpperCase(), adminUserId.toUpperCase());
  const replay = await admin.call("POST", "/api/admin/instrument/import", { document: doc, replace: { versionId: id, expectedChecksum: edited.json.checksum } });
  assert.equal(replay.status, 409, replay.text);
  assert.equal(replay.json.error.code, "DRAFT_CHANGED");
});

test("ADM-01: an invalid document is refused with every issue and writes nothing", { skip }, async () => {
  const before = await versionCount();
  const doc = documentFor("invalid", (d) => {
    d.items[0].responseSetId = "rs_does_not_exist";
    d.items[1].itemKey = d.items[2].itemKey;
  });
  const r = await admin.call("POST", "/api/admin/instrument/import", { document: doc });
  assert.equal(r.status, 422, r.text);
  assert.equal(r.json.error.code, "INSTRUMENT_CONFIG_INVALID");
  const issues = r.json.error.details.issues;
  assert.ok(issues.length >= 2, `every issue is reported, not just the first: ${JSON.stringify(issues)}`);
  assert.ok(issues.every((i) => typeof i.code === "string" && typeof i.message === "string" && typeof i.path === "string"));
  assert.equal(await versionCount(), before, "nothing was written");
  const label = await query("SELECT COUNT(*) AS n FROM icf.instrument_version WHERE version_label = @l", { l: doc.instrument.version.versionLabel });
  assert.equal(label[0].n, 0);
});

test("ADM-01: the import body contract and the size cap", { skip }, async () => {
  const before = await versionCount();
  const extra = await admin.call("POST", "/api/admin/instrument/import", { document: documentFor("extra"), versionLabel: "nope" });
  assert.equal(extra.status, 400, extra.text);
  assert.equal(extra.json.error.code, "IMPORT_BODY_INVALID");
  const missing = await admin.call("POST", "/api/admin/instrument/import", {});
  assert.equal(missing.status, 400, missing.text);
  assert.equal(missing.json.error.code, "DOCUMENT_REQUIRED");
  const notObject = await admin.call("POST", "/api/admin/instrument/import", { document: "a string" });
  assert.equal(notObject.status, 400, notObject.text);
  assert.equal(notObject.json.error.code, "DOCUMENT_REQUIRED");
  // The same bytes, the same signed-in headers and the same assertions as before, sent over a raw
  // socket (rawRequest, below). Since P6A-01 the server refuses a body over the limit from its declared
  // length, before reading it, and closes the connection while the client may still be uploading;
  // fetch can then report its own refused write ("fetch failed", cause EPIPE) instead of the 413 the
  // server sent -- reproduced 1 time in 100 on a reused keep-alive connection, 0 in 300 this way.
  const huge = Buffer.from(JSON.stringify({ document: { padding: "x".repeat(5000001) } }));
  const tooLarge = await rawRequest("/api/admin/instrument/import", signedIn(), huge);
  assert.equal(tooLarge.status, 413, tooLarge.text.slice(0, 300));
  assert.equal(tooLarge.json.error.code, "DOCUMENT_TOO_LARGE");
  assert.equal(await versionCount(), before, "no refused body wrote anything");
});

// ---- P6A-01: authentication, CSRF and the size limit come before the body ----------------------

/**
 * Sends the request line, the headers and only `sent` of the body, then waits for an answer
 * WITHOUT sending the rest. A server that reads the body before deciding can only wait for bytes
 * that never come; one that decides first answers. So an answer here is direct evidence that the
 * body was never acquired -- and therefore never parsed -- which a status code alone cannot show.
 */
function partialRequest(p, headers, sent, timeoutMs = 15000) {
  return new Promise((resolve, reject) => {
    const url = new URL(`${baseUrl(env)}/index.cfm${p}`);
    const req = http.request({ host: url.hostname, port: url.port, path: url.pathname + url.search, method: "POST", headers });
    let settled = false;
    const done = (fn, value) => { if (!settled) { settled = true; clearTimeout(timer); req.destroy(); fn(value); } };
    const timer = setTimeout(() => done(reject, new Error(`no answer within ${timeoutMs} ms: the server was waiting for the rest of the body`)), timeoutMs);
    req.on("response", (res) => {
      let text = "";
      res.setEncoding("utf8");
      res.on("data", (c) => { text += c; });
      res.on("end", () => { let json = null; try { json = JSON.parse(text); } catch { json = null; } done(resolve, { status: res.statusCode, text, json }); });
    });
    req.on("error", (e) => done(reject, e));
    req.write(sent);
  });
}

/**
 * A complete request with an exact raw body (Buffer), optionally chunked, over a raw socket. The
 * whole body is sent, but a server that refuses early may stop reading it and close; the answer it
 * gave is still read and returned (an HTTP client library would report the refused write instead).
 */
function rawRequest(p, headers, body, { chunked = false, timeoutMs = 60000 } = {}) {
  return new Promise((resolve, reject) => {
    const url = new URL(`${baseUrl(env)}/index.cfm${p}`);
    const socket = net.connect(Number(url.port || 80), url.hostname);
    const h = { Host: url.host, Connection: "close", ...headers };
    if (chunked) h["Transfer-Encoding"] = "chunked"; else h["Content-Length"] = String(body.length);
    const received = [];
    const timer = setTimeout(() => { socket.destroy(); reject(new Error(`no complete answer within ${timeoutMs} ms`)); }, timeoutMs);
    socket.on("data", (d) => received.push(d));
    socket.on("error", () => {});  // an early refusal closes the connection under the rest of the body
    socket.on("close", () => {
      clearTimeout(timer);
      const raw = Buffer.concat(received);
      const split = raw.indexOf("\r\n\r\n");
      if (split < 0) { reject(new Error(`no HTTP answer (${raw.length} bytes)`)); return; }
      const head = raw.subarray(0, split).toString("latin1").split("\r\n");
      const status = Number(head[0].split(" ")[1]);
      const isChunked = head.some((l) => /^transfer-encoding:\s*chunked/i.test(l));
      let rest = raw.subarray(split + 4);
      if (isChunked) {
        const parts = [];
        for (;;) {
          const eol = rest.indexOf("\r\n");
          const size = parseInt(rest.subarray(0, eol).toString("latin1"), 16);
          if (!size) break;
          parts.push(rest.subarray(eol + 2, eol + 2 + size));
          rest = rest.subarray(eol + 2 + size + 2);
        }
        rest = Buffer.concat(parts);
      }
      const text = rest.toString("utf8");
      let json = null;
      try { json = JSON.parse(text); } catch { json = null; }
      resolve({ status, text, json });
    });
    socket.write(`POST ${url.pathname}${url.search} HTTP/1.1\r\n${Object.entries(h).map(([k, v]) => `${k}: ${v}\r\n`).join("")}\r\n`);
    if (chunked) {
      // In pieces, as a streaming client sends them.
      for (let i = 0; i < body.length; i += 65536) {
        const piece = body.subarray(i, i + 65536);
        socket.write(`${piece.length.toString(16)}\r\n`);
        socket.write(piece);
        socket.write("\r\n");
      }
      socket.write("0\r\n\r\n");
    } else {
      socket.write(body);
    }
  });
}

const IMPORT = "/api/admin/instrument/import";
const LIMIT = 5000000;
/** Not JSON, and larger than the import limit. */
const MALFORMED_OVERSIZED = Buffer.concat([Buffer.from('{"document": {"items": [ this is not json '), Buffer.alloc(LIMIT, 0x78)]);

function signedIn(extra = {}) {
  return { Accept: "application/json", "Content-Type": "application/json", "X-ICFWalk-Dev-Subject": adminSubject, Cookie: admin.cookie(), "X-ICFWalk-CSRF-Token": admin.csrf(), ...extra };
}

test("P6A-01: an unauthenticated import is answered 401 without its body being read, however large or malformed", { skip }, async () => {
  const before = await versionCount();
  const anonymous = { Accept: "application/json", "Content-Type": "application/json" };
  const complete = await rawRequest(IMPORT, anonymous, MALFORMED_OVERSIZED);
  assert.equal(complete.status, 401, complete.text.slice(0, 300));
  assert.equal(complete.json.error.code, "UNAUTHENTICATED");
  const declared = await partialRequest(IMPORT, { ...anonymous, "Content-Length": "50000000" }, "{ not json");
  assert.equal(declared.status, 401, declared.text.slice(0, 300));
  assert.equal(declared.json.error.code, "UNAUTHENTICATED");
  const chunked = await partialRequest(IMPORT, { ...anonymous, "Transfer-Encoding": "chunked" }, "{ not json");
  assert.equal(chunked.status, 401, chunked.text.slice(0, 300));
  assert.equal(chunked.json.error.code, "UNAUTHENTICATED");
  assert.equal(await versionCount(), before);
});

test("P6A-01: an import with a missing or wrong CSRF token is answered 403 without its body being read", { skip }, async () => {
  const before = await versionCount();
  const complete = await rawRequest(IMPORT, signedIn({ "X-ICFWalk-CSRF-Token": "f".repeat(64) }), MALFORMED_OVERSIZED);
  assert.equal(complete.status, 403, complete.text.slice(0, 300));
  assert.equal(complete.json.error.code, "CSRF_TOKEN_INVALID");
  const noToken = signedIn();
  delete noToken["X-ICFWalk-CSRF-Token"];
  const declared = await partialRequest(IMPORT, { ...noToken, "Content-Length": "50000000" }, "{ not json");
  assert.equal(declared.status, 403, declared.text.slice(0, 300));
  assert.equal(declared.json.error.code, "CSRF_TOKEN_INVALID");
  const chunked = await partialRequest(IMPORT, { ...signedIn({ "X-ICFWalk-CSRF-Token": "0".repeat(64) }), "Transfer-Encoding": "chunked" }, "{ not json");
  assert.equal(chunked.status, 403, chunked.text.slice(0, 300));
  assert.equal(chunked.json.error.code, "CSRF_TOKEN_INVALID");
  // A user without instrument.manage is refused before the body too.
  const walkerHeaders = { Accept: "application/json", "Content-Type": "application/json", "X-ICFWalk-Dev-Subject": walkerSubject, Cookie: walker.cookie(), "X-ICFWalk-CSRF-Token": walker.csrf(), "Content-Length": "50000000" };
  const forbidden = await partialRequest(IMPORT, walkerHeaders, "{ not json");
  assert.equal(forbidden.status, 403, forbidden.text.slice(0, 300));
  assert.equal(forbidden.json.error.code, "FORBIDDEN");
  assert.equal(await versionCount(), before);
});

test("P6A-01: an authorized import over 5,000,000 bytes is 413 DOCUMENT_TOO_LARGE before it is parsed, malformed or not", { skip }, async () => {
  const before = await versionCount();
  // Malformed and oversized: the size is decided first, so this is 413 and not INVALID_JSON_BODY.
  const malformed = await rawRequest(IMPORT, signedIn(), MALFORMED_OVERSIZED);
  assert.equal(malformed.status, 413, malformed.text.slice(0, 300));
  assert.equal(malformed.json.error.code, "DOCUMENT_TOO_LARGE");
  assert.equal(malformed.json.error.details.limitBytes, LIMIT);
  // Valid JSON declaring more than the limit: answered from the declared length, before a byte of
  // the body is read -- the rest of it is never sent.
  const valid = Buffer.from(JSON.stringify({ document: documentFor("declared-too-large") }));
  const declared = await partialRequest(IMPORT, { ...signedIn(), "Content-Length": String(LIMIT + 1) }, valid.subarray(0, 1024));
  assert.equal(declared.status, 413, declared.text.slice(0, 300));
  assert.equal(declared.json.error.code, "DOCUMENT_TOO_LARGE");
  // Exactly at the limit is not too large (it is an invalid document, refused by validation).
  const atLimit = Buffer.concat([Buffer.from('{"document":{"padding":"'), Buffer.alloc(LIMIT - 27, 0x61), Buffer.from('"}}')]);
  assert.equal(atLimit.length, LIMIT);
  const exact = await rawRequest(IMPORT, signedIn(), atLimit);
  assert.notEqual(exact.status, 413, exact.text.slice(0, 300));
  assert.equal(exact.json.error.code, "INSTRUMENT_CONFIG_INVALID");
  assert.equal(await versionCount(), before);
});

test("P6A-01: a chunked import is measured in UTF-8 bytes, so multibyte text cannot slip under the limit", { skip }, async () => {
  const before = await versionCount();
  // 1,700,000 euro signs: 1.7 million characters, 5.1 million UTF-8 bytes, and no Content-Length.
  const body = Buffer.from(`{"document":{"padding":"${"\u20ac".repeat(1700000)}"}}`, "utf8");
  assert.ok(body.length > LIMIT && body.toString("utf8").length < LIMIT, "precondition: over the limit in bytes, under it in characters");
  const r = await rawRequest(IMPORT, signedIn(), body, { chunked: true });
  assert.equal(r.status, 413, r.text.slice(0, 300));
  assert.equal(r.json.error.code, "DOCUMENT_TOO_LARGE");
  // The same, never finished: the reader stops one byte past the limit and answers. (That it takes
  // exactly limit + 1 bytes from the stream is measured on the production loop by the CFML
  // RequestBodyReadBoundTest, P6A-R01; from here only the prompt answer is observable.)
  const partial = await partialRequest(IMPORT, { ...signedIn(), "Transfer-Encoding": "chunked" }, body.subarray(0, LIMIT + 4096));
  assert.equal(partial.status, 413, partial.text.slice(0, 300));
  assert.equal(partial.json.error.code, "DOCUMENT_TOO_LARGE");
  assert.equal(await versionCount(), before);
});

test("P6A-01: a maintenance route without its token is hidden without its body being read", { skip }, async () => {
  const r = await partialRequest("/api/maintenance/instrument/import", { Accept: "application/json", "Content-Type": "application/json", "Content-Length": "50000000" }, "{ not json");
  assert.equal(r.status, 404, r.text.slice(0, 300));
  assert.equal(r.json.error.code, "NOT_FOUND");
});

// ---- ADM-02 preview --------------------------------------------------------------------------

test("ADM-02: preview returns exactly the render model the walk runtime serves", { skip }, async () => {
  const current = await walker.call("GET", "/api/instrument/current");
  assert.equal(current.status, 200, current.text);
  const preview = await admin.call("GET", v(current.json.version.versionId, "preview"));
  assert.equal(preview.status, 200, preview.text);
  assert.equal(preview.json.version.versionId, current.json.version.versionId);
  assert.equal(canonicalize(preview.json.model), canonicalize(current.json.model), "the same model, byte for byte");
  assert.equal(canonicalize(preview.json.policies), canonicalize(current.json.policies));

  const draft = await importDraft("preview");
  const p = await admin.call("GET", v(draft.versionId, "preview"));
  assert.equal(p.status, 200, p.text);
  assert.equal(p.json.version.status, "DRAFT");
  assert.ok(p.json.model.root && Array.isArray(p.json.model.root.children) && p.json.model.root.children.length > 0);

  const bad = await admin.call("GET", v("not-a-guid", "preview"));
  assert.equal(bad.status, 400, bad.text);
  assert.equal(bad.json.error.code, "INVALID_VERSION_ID");
  const none = await admin.call("GET", v(randomUUID(), "preview"));
  assert.equal(none.status, 404, none.text);
  assert.equal(none.json.error.code, "INSTRUMENT_VERSION_NOT_FOUND");
});

// ---- ADM-06 clone, edit, compare -------------------------------------------------------------

test("ADM-06: a new DRAFT from a published version, a prompt changed in it, and the comparison", { skip }, async () => {
  const base = await importDraft("clone-base");
  await publish(base.versionId);
  const publishedBefore = await versionRow(base.versionId);

  const cloneLabel = `${tag}-clone-${++labelCounter}`;
  const clone = await admin.call("POST", v(base.versionId, "clone"), { versionLabel: cloneLabel, revisionNotes: "Prompt review" });
  assert.equal(clone.status, 201, clone.text);
  assert.equal(clone.json.status, "DRAFT");
  assert.equal(clone.json.versionLabel, cloneLabel);
  assert.notEqual(clone.json.versionId, base.versionId);
  assert.equal(clone.json.definitionsChecksum, base.definitionsChecksum, "the clone starts with identical definitions");
  const cloned = await audits(clone.json.versionId, "INSTRUMENT_VERSION_CLONED");
  assert.equal(cloned.length, 1);
  assert.equal(cloned[0].actor_user_id.toUpperCase(), adminUserId.toUpperCase());
  assert.equal(JSON.parse(cloned[0].details_json).sourceVersionId.toUpperCase(), base.versionId.toUpperCase());

  const sameLabel = await admin.call("POST", v(base.versionId, "clone"), { versionLabel: cloneLabel });
  assert.equal(sameLabel.status, 409, sameLabel.text);
  assert.equal(sameLabel.json.error.code, "VERSION_LABEL_EXISTS");
  const noLabel = await admin.call("POST", v(base.versionId, "clone"), {});
  assert.equal(noLabel.status, 400, noLabel.text);
  assert.equal(noLabel.json.error.code, "VERSION_LABEL_INVALID");

  // The edit: find the item through the wording search, then change its prompt.
  const item = SOURCE.items.find((i) => i.reviewStatus !== PLACEHOLDER_STATUS && i.itemType === "SINGLE_CHOICE");
  const found = await admin.call("GET", `${v(clone.json.versionId, "wording")}?q=${encodeURIComponent(item.itemKey)}`);
  assert.equal(found.status, 200, found.text);
  assert.equal(found.json.editable, true);
  const hit = found.json.results.find((e) => e.target === "item" && e.key === item.itemKey);
  assert.ok(hit, "the wording search finds the item by key");
  assert.equal(hit.fields.prompt, item.prompt);

  const newPrompt = `${item.prompt} (revised)`;
  const edit = await admin.call("POST", v(clone.json.versionId, "edits"), {
    expectedChecksum: clone.json.checksum,
    edits: [{ target: "item", key: item.itemKey, field: "prompt", value: newPrompt }],
  });
  assert.equal(edit.status, 200, edit.text);
  assert.equal(edit.json.changed, true);
  assert.equal(edit.json.applied.length, 1);
  assert.equal(edit.json.applied[0].from, item.prompt);
  assert.equal(edit.json.applied[0].to, newPrompt);
  assert.notEqual(edit.json.checksum, clone.json.checksum);
  const edited = await audits(clone.json.versionId, "INSTRUMENT_VERSION_EDITED");
  assert.equal(edited.length, 1);
  assert.equal(edited[0].actor_user_id.toUpperCase(), adminUserId.toUpperCase());

  // A stale read is refused and audited; nothing moves.
  const stale = await admin.call("POST", v(clone.json.versionId, "edits"), {
    expectedChecksum: clone.json.checksum,
    edits: [{ target: "item", key: item.itemKey, field: "prompt", value: "lost update" }],
  });
  assert.equal(stale.status, 409, stale.text);
  assert.equal(stale.json.error.code, "DRAFT_CHANGED");
  assert.equal(stale.json.error.details.currentChecksum, edit.json.checksum);
  assert.equal((await versionRow(clone.json.versionId)).checksum_sha256.toLowerCase(), edit.json.checksum);

  // The published version cannot be edited, and did not move.
  const onPublished = await admin.call("POST", v(base.versionId, "edits"), {
    expectedChecksum: publishedBefore.checksum_sha256.toLowerCase(),
    edits: [{ target: "item", key: item.itemKey, field: "prompt", value: "never" }],
  });
  assert.equal(onPublished.status, 409, onPublished.text);
  const publishedAfter = await versionRow(base.versionId);
  assert.equal(publishedAfter.checksum_sha256, publishedBefore.checksum_sha256);
  assert.equal(publishedAfter.row_version, publishedBefore.row_version);

  // The comparison shows the prompt change and the version metadata, nothing else.
  const cmp = await admin.call("GET", `/api/admin/instrument/compare?from=${base.versionId}&to=${clone.json.versionId}`);
  assert.equal(cmp.status, 200, cmp.text);
  assert.equal(cmp.json.identical, false);
  assert.equal(cmp.json.summary.added, 0);
  assert.equal(cmp.json.summary.removed, 0);
  assert.equal(cmp.json.summary.changed, 1);
  assert.equal(cmp.json.changes.length, 1);
  const change = cmp.json.changes[0];
  assert.equal(change.collection, "items");
  assert.equal(change.key, item.itemKey);
  assert.equal(change.change, "changed");
  assert.deepEqual(change.fields, [{ field: "prompt", from: item.prompt, to: newPrompt }]);
  const metaFields = cmp.json.metadata.map((m) => m.field);
  assert.ok(metaFields.includes("version.versionLabel"));
  assert.ok(metaFields.includes("version.revisionNotes"));
  assert.equal(cmp.json.from.versionId, base.versionId.toUpperCase());

  const self = await admin.call("GET", `/api/admin/instrument/compare?from=${base.versionId}&to=${base.versionId}`);
  assert.equal(self.status, 200, self.text);
  assert.equal(self.json.identical, true);
  assert.equal(self.json.changes.length, 0);
});

test("ADM-06: malformed edit requests are refused with their paths", { skip }, async () => {
  const draft = await importDraft("edit-shape");
  const before = await versionRow(draft.versionId);
  const cases = [
    [{ edits: [] }, 400, "EXPECTED_CHECKSUM_REQUIRED"],
    [{ expectedChecksum: draft.checksum, edits: [] }, 400, "DRAFT_EDIT_INVALID"],
    [{ expectedChecksum: draft.checksum, edits: [{ target: "item", key: "nope", field: "prompt", value: "x" }] }, 400, "DRAFT_EDIT_INVALID"],
    [{ expectedChecksum: draft.checksum, edits: [{ target: "rule", key: "r", field: "x", value: "x" }] }, 400, "DRAFT_EDIT_INVALID"],
    [{ expectedChecksum: draft.checksum, edits: [{ target: "item", key: SOURCE.items[0].itemKey, field: "itemType", value: "TEXT" }] }, 400, "DRAFT_EDIT_INVALID"],
    [{ expectedChecksum: draft.checksum, edits: [], actor: "someone" }, 400, "EDIT_BODY_INVALID"],
  ];
  for (const [body, status, code] of cases) {
    const r = await admin.call("POST", v(draft.versionId, "edits"), body);
    assert.equal(r.status, status, `${JSON.stringify(body)}: ${r.text}`);
    assert.equal(r.json.error.code, code, JSON.stringify(body));
  }
  const unknown = await admin.call("POST", v(draft.versionId, "edits"), { expectedChecksum: draft.checksum, edits: [{ target: "item", key: "nope", field: "prompt", value: "x" }] });
  assert.equal(unknown.json.error.details.issues[0].code, "EDIT_TARGET_NOT_FOUND");
  const after = await versionRow(draft.versionId);
  assert.equal(after.row_version, before.row_version, "no refused edit wrote anything");
});

// ---- ADM-07 retire ---------------------------------------------------------------------------

test("ADM-07: retiring a version with a historical walk keeps that walk openable and saveable", { skip }, async () => {
  const older = await importDraft("retire-old");
  await publish(older.versionId);
  const newer = await importDraft("retire-new");
  await new Promise((r) => setTimeout(r, 20));
  await publish(newer.versionId);

  // A historical walk on the older version, owned by the walker. Walks can only be started on the
  // runtime instrument through the API, so this one is placed directly -- exactly the row a walk
  // started before the fixture instrument's newer version was published would be.
  const walkId = randomUUID().toUpperCase();
  await query(
    `INSERT INTO icf.walk (walk_id, version_id, org_unit_id, owner_user_id, status) VALUES (@w, @v, @o, @u, N'DRAFT')`,
    { w: walkId, v: older.versionId, o: districtId, u: walkerUserId });

  const r = await admin.call("POST", v(older.versionId, "retire"));
  assert.equal(r.status, 200, r.text);
  assert.equal(r.json.status, "RETIRED");
  assert.equal(r.json.walkCount, 1);
  assert.equal(r.json.successorVersionId.toUpperCase(), newer.versionId.toUpperCase());
  assert.equal(r.json.leftNoCurrentVersion, false);
  const row = await versionRow(older.versionId);
  assert.equal(row.status, "RETIRED");
  assert.ok(row.effective_end instanceof Date && row.effective_end > row.effective_start, "effective_end closes the version's service window");
  const retiredAudit = await audits(older.versionId, "INSTRUMENT_VERSION_RETIRED");
  assert.equal(retiredAudit.length, 1);
  assert.equal(retiredAudit[0].actor_user_id.toUpperCase(), adminUserId.toUpperCase());

  const listed = await admin.call("GET", "/api/admin/instrument/versions");
  const olderListed = listed.json.versions.find((x) => x.versionId === older.versionId.toUpperCase());
  const newerListed = listed.json.versions.find((x) => x.versionId === newer.versionId.toUpperCase());
  assert.equal(olderListed.status, "RETIRED");
  assert.equal(olderListed.isCurrent, false);
  assert.equal(newerListed.isCurrent, true);

  // The historical walk still opens, renders against its own version, and saves.
  const opened = await walker.call("GET", `/api/walks/${walkId}`);
  assert.equal(opened.status, 200, opened.text);
  assert.equal(opened.json.walk.versionId.toUpperCase(), older.versionId.toUpperCase());
  const model = await walker.call("GET", `/api/walks/${walkId}/instrument`);
  assert.equal(model.status, 200, model.text);
  assert.equal(model.json.version.versionId.toUpperCase(), older.versionId.toUpperCase());
  const saved = await walker.call("PUT", `/api/walks/${walkId}`, { rowVersion: opened.json.walk.rowVersion, clientMutationId: randomUUID(), dimensions: {}, responses: {} });
  assert.equal(saved.status, 200, saved.text);

  const again = await admin.call("POST", v(older.versionId, "retire"));
  assert.equal(again.status, 409, again.text);
  assert.equal(again.json.error.code, "INSTRUMENT_VERSION_NOT_PUBLISHED");
  assert.equal((await audits(older.versionId, "INSTRUMENT_VERSION_RETIRE_REFUSED")).length, 1, "the refusal is audited");
});

test("ADM-07: retiring the only version in service needs explicit confirmation", { skip }, async () => {
  const code = `${tag}-solo`;
  const doc = documentFor("solo", (d) => { d.instrument.code = code; });
  const imported = await admin.call("POST", "/api/admin/instrument/import", { document: doc });
  assert.equal(imported.status, 201, imported.text);
  await publish(imported.json.versionId);

  const refused = await admin.call("POST", v(imported.json.versionId, "retire"));
  assert.equal(refused.status, 409, refused.text);
  assert.equal(refused.json.error.code, "RETIRE_LEAVES_NO_CURRENT_VERSION");
  assert.equal((await versionRow(imported.json.versionId)).status, "PUBLISHED");

  for (const [body, code2] of [[{ allowNoCurrentVersion: "yes" }, "RETIRE_BODY_INVALID"], [{ reason: "x" }, "RETIRE_BODY_INVALID"]]) {
    const bad = await admin.call("POST", v(imported.json.versionId, "retire"), body);
    assert.equal(bad.status, 400, bad.text);
    assert.equal(bad.json.error.code, code2);
  }
  assert.equal((await versionRow(imported.json.versionId)).status, "PUBLISHED");

  const confirmed = await admin.call("POST", v(imported.json.versionId, "retire"), { allowNoCurrentVersion: true });
  assert.equal(confirmed.status, 200, confirmed.text);
  assert.equal(confirmed.json.leftNoCurrentVersion, true);
  assert.equal(confirmed.json.successorVersionId ?? null, null);
  assert.equal((await versionRow(imported.json.versionId)).status, "RETIRED");

  const draft = await importDraft("retire-draft");
  const onDraft = await admin.call("POST", v(draft.versionId, "retire"));
  assert.equal(onDraft.status, 409, onDraft.text);
  assert.equal(onDraft.json.error.code, "INSTRUMENT_VERSION_NOT_PUBLISHED");
});

// ---- ADM-08 placeholders ---------------------------------------------------------------------

test("ADM-08: the placeholder queue lists every placeholder prompt, searches, and shrinks when one is resolved", { skip }, async () => {
  const draft = await importDraft("placeholders");
  const all = await admin.call("GET", v(draft.versionId, "placeholders"));
  assert.equal(all.status, 200, all.text);
  assert.equal(all.json.total, PLACEHOLDER_COUNT);
  assert.equal(all.json.matched, PLACEHOLDER_COUNT);
  assert.equal(all.json.items.length, PLACEHOLDER_COUNT);
  assert.equal(all.json.editable, true);
  const expected = SOURCE.items.filter((i) => i.reviewStatus === PLACEHOLDER_STATUS);
  assert.deepEqual(new Set(all.json.items.map((i) => i.itemKey)), new Set(expected.map((i) => i.itemKey)));
  for (const it of all.json.items) {
    const src = expected.find((e) => e.itemKey === it.itemKey);
    assert.equal(it.prompt, src.prompt);
    assert.equal(it.sourceLocation, src.sourceLocation);
    assert.equal(it.reviewStatus, PLACEHOLDER_STATUS);
  }

  const target = expected[3];
  const one = await admin.call("GET", `${v(draft.versionId, "placeholders")}?q=${encodeURIComponent(target.sourceLocation)}`);
  assert.equal(one.status, 200, one.text);
  assert.equal(one.json.total, PLACEHOLDER_COUNT, "the total stays visible while a search is applied");
  assert.ok(one.json.matched >= 1 && one.json.matched < PLACEHOLDER_COUNT);
  assert.ok(one.json.items.some((i) => i.itemKey === target.itemKey));
  const nothing = await admin.call("GET", `${v(draft.versionId, "placeholders")}?q=${encodeURIComponent("zz-no-such-text")}`);
  assert.equal(nothing.json.matched, 0);
  const tooLong = await admin.call("GET", `${v(draft.versionId, "placeholders")}?q=${"x".repeat(201)}`);
  assert.equal(tooLong.status, 400, tooLong.text);
  assert.equal(tooLong.json.error.code, "QUERY_TOO_LONG");

  const resolved = await admin.call("POST", v(draft.versionId, "edits"), {
    expectedChecksum: draft.checksum,
    edits: [
      { target: "item", key: target.itemKey, field: "prompt", value: "Students can explain what they are learning today." },
      { target: "item", key: target.itemKey, field: "reviewStatus", value: "Reviewed" },
    ],
  });
  assert.equal(resolved.status, 200, resolved.text);
  assert.equal(resolved.json.placeholders.length, PLACEHOLDER_COUNT - 1);
  const after = await admin.call("GET", v(draft.versionId, "placeholders"));
  assert.equal(after.json.total, PLACEHOLDER_COUNT - 1);
  assert.ok(!after.json.items.some((i) => i.itemKey === target.itemKey));
});

// ---- discard ---------------------------------------------------------------------------------

test("a DRAFT can be discarded through the admin route; a published version cannot; a body is refused", { skip }, async () => {
  const draft = await importDraft("discard");
  const withBody = await admin.call("POST", v(draft.versionId, "discard"), {});
  assert.equal(withBody.status, 400, withBody.text);
  assert.equal(withBody.json.error.code, "DISCARD_BODY_NOT_ALLOWED");
  assert.ok(await versionRow(draft.versionId), "a refused discard removed nothing");

  const ok = await admin.call("POST", v(draft.versionId, "discard"));
  assert.equal(ok.status, 200, ok.text);
  assert.equal(await versionRow(draft.versionId), null);
  const gone = await admin.call("GET", v(draft.versionId, "preview"));
  assert.equal(gone.status, 404, gone.text);

  const published = await importDraft("discard-published");
  await publish(published.versionId);
  const refused = await admin.call("POST", v(published.versionId, "discard"));
  assert.equal(refused.status, 409, refused.text);
  assert.equal((await versionRow(published.versionId)).status, "PUBLISHED");
});

// ---- the Excel round-trip ----------------------------------------------------------------------

test("Excel round-trip: a version exports as its document and as a workbook, and an edited workbook imports as a draft with exactly the edit", { skip }, async () => {
  const base = await importDraft("excel-base");
  await publish(base.versionId);

  const exported = await admin.call("GET", v(base.versionId, "document"));
  assert.equal(exported.status, 200, exported.text);
  assert.equal(exported.json.version.status, "PUBLISHED");
  assert.equal(exported.json.document.instrument.version.status, "DRAFT", "an import can only create a DRAFT");
  assert.equal(exported.json.document.items.length, SOURCE.items.length);
  const missing = await admin.call("GET", v(randomUUID(), "document"));
  assert.equal(missing.status, 404, missing.text);

  // Through a workbook and back, unchanged: the same definitions as the published version.
  const bytes = await writeWorkbook(exported.json.document, { exportedFrom: exported.json.version, exportedAt: "2026-09-24T00:00:00Z" });
  const unchanged = await readWorkbook(bytes);
  assert.equal(unchanged.ok, true, JSON.stringify(unchanged.errors));
  assert.equal(canonicalize(unchanged.document), canonicalize(exported.json.document), "the workbook carries the document exactly");
  assert.equal(unchanged.meta.checksum, base.checksum);
  unchanged.document.instrument.version.versionLabel = `${tag}-excel-same-${++labelCounter}`;
  const same = await admin.call("POST", "/api/admin/instrument/import", { document: unchanged.document });
  assert.equal(same.status, 201, same.text);
  assert.equal(same.json.definitionsChecksum, base.definitionsChecksum, "a workbook round trip changes nothing");

  // One prompt edited in the workbook's document.
  const edited = await readWorkbook(bytes);
  const item = SOURCE.items.find((i) => i.reviewStatus !== PLACEHOLDER_STATUS && i.itemType === "SINGLE_CHOICE");
  edited.document.items.find((i) => i.itemKey === item.itemKey).prompt = `${item.prompt} (edited in Excel)`;
  edited.document.instrument.version.versionLabel = `${tag}-excel-edit-${++labelCounter}`;
  const draft = await admin.call("POST", "/api/admin/instrument/import", { document: edited.document });
  assert.equal(draft.status, 201, draft.text);
  const cmp = await admin.call("GET", `/api/admin/instrument/compare?from=${base.versionId}&to=${draft.json.versionId}`);
  assert.equal(cmp.status, 200, cmp.text);
  assert.deepEqual(cmp.json.changes, [{ collection: "items", key: item.itemKey, change: "changed", label: `${item.prompt} (edited in Excel)`, fields: [{ field: "prompt", from: item.prompt, to: `${item.prompt} (edited in Excel)` }] }]);
});

test("Excel round-trip: a workbook edited in LibreOffice Calc imports, and the comparison shows exactly its edits", { skip }, async () => {
  // The same instrument as the fixture's starting point, under this run's code.
  const base = await importDraft("excel-lo-base");
  const fixture = await readWorkbook(new Uint8Array(fs.readFileSync(path.join(root, "tests", "fixtures", "workbooks", "libreoffice-edited.xlsx"))));
  assert.equal(fixture.ok, true, JSON.stringify(fixture.errors));
  fixture.document.instrument.code = instrumentCode;
  fixture.document.instrument.version.versionLabel = `${tag}-excel-lo-${++labelCounter}`;
  const r = await admin.call("POST", "/api/admin/instrument/import", { document: fixture.document });
  assert.equal(r.status, 201, r.text);
  assert.equal(r.json.counts.placeholders, PLACEHOLDER_COUNT - 1, "the placeholder resolved in LibreOffice is resolved");
  assert.equal(r.json.counts.responseOptions, SOURCE.counts.responseOptions + 1, "and the answer added there is there");

  const cmp = await admin.call("GET", `/api/admin/instrument/compare?from=${base.versionId}&to=${r.json.versionId}`);
  assert.equal(cmp.status, 200, cmp.text);
  const changes = Object.fromEntries(cmp.json.changes.map((c) => [`${c.collection}/${c.key}/${c.change}`, c.fields.map((f) => `${f.field}=${JSON.stringify(f.to)}`).sort()]));
  assert.deepEqual(changes, {
    "items/prek_k_q1/changed": ['prompt="Students can describe today\'s learning goal."', 'reviewStatus="Reviewed"'],
    "items/prek_k_q2/changed": ["displayOrder=15"],
    "items/prek_k_q3/changed": ["required=true"],
    "dimensionValues/school/abbott_middle_school/changed": ['label="2024"'],
    "responseOptions/yes_no/maybe/added": [],
  });
});
