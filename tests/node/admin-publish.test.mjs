// HTTP-level checks of POST /api/admin/instrument/versions/{id}/publish against the running
// application (development identity stub, real SQL Server, real session cookies and CSRF):
// authentication, authorization, CSRF, input validation, the empty-body contract, successful
// publication and publisher attribution, the checksum-matching validation refusal, repeat
// publication, a lost-response retry, two concurrent publishes, and a publish racing a mutation.
//
// Fixtures live under their own instrument code, so publishing here never becomes the ICFWalk
// instrument's current version for the rest of the suite, and they are removed afterwards through
// the test-only maintenance cleanup.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import sql from "mssql";
import { api, baseUrl, connectionConfig, hasDatabaseConfig, loadRuntimeEnv, requireApp } from "./helpers.mjs";
import { canonicalize, sha256Hex } from "../../scripts/lib/snapshot.mjs";

const env = loadRuntimeEnv();
const token = env.ICFWALK_MAINTENANCE_TOKEN || "";
const tag = `httppub-${Date.now().toString(36)}`;
const instrumentCode = `${tag}-instrument`;

async function reachable() {
  try {
    const r = await fetch(`${baseUrl(env)}/index.cfm/api/health`, { signal: AbortSignal.timeout(10000) });
    if (r.status !== 200) return false;
    const body = await r.json();
    return body.environment === "development" || body.environment === "test";
  } catch { return false; }
}
const up = await reachable();
// A release run (ICFWALK_REQUIRE_APP=1) must not silently skip these: an absent application means
// the publish route was never exercised, which is not the same as it having worked.
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
  async function call(method, path, body, { noCsrf = false, badCsrf = false, noIdentity = false } = {}) {
    const headers = { Accept: "application/json" };
    if (!noIdentity) headers["X-ICFWalk-Dev-Subject"] = subject;
    if (body !== undefined) headers["Content-Type"] = "application/json";
    if (badCsrf) headers["X-ICFWalk-CSRF-Token"] = "f".repeat(64);
    else if (csrf && !noCsrf) headers["X-ICFWalk-CSRF-Token"] = csrf;
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
  return { call, me: me.json, csrf };
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
    `SELECT status, checksum_sha256, compiled_snapshot_json, published_by_user_id, published_at, effective_start,
            CAST(row_version AS bigint) AS row_version
       FROM icf.instrument_version WHERE version_id = @id`,
    { id: versionId });
  return rows[0] ?? null;
}
async function auditCount(versionId, eventType) {
  const rows = await query(
    "SELECT COUNT(*) AS n FROM icf.audit_event WHERE entity_id = @id AND event_type = @t",
    { id: versionId, t: eventType });
  return rows[0].n;
}

// ---- fixtures --------------------------------------------------------------------------------

const adminSubject = `${tag}-admin`;
const walkerSubject = `${tag}-walker`;
let admin, walker, adminUserId;
let versionCounter = 0;

/** Imports a fresh DRAFT of the real instrument under this run's own instrument code. */
async function newDraft(suffix) {
  const versionLabel = `${tag}-${suffix}-${++versionCounter}`;
  const r = await api(env, "POST", "/api/maintenance/instrument/import", {
    token, body: { instrumentCode, versionLabel },
  });
  assert.ok(r.status === 201 || r.status === 200, r.text);
  assert.equal(r.json.status, "DRAFT");
  return r.json;
}

const publishPath = (id) => `/api/admin/instrument/versions/${id}/publish`;

/**
 * Whether a response is SQL Server's deadlock victim. Read from the error document only, never
 * from the whole body: a successful publish echoes the version label, and a label is free text.
 */
const deadlocked = (r) => Boolean(r.json?.error) && /deadlock/i.test(JSON.stringify(r.json.error));

before(async () => {
  if (skip) return;
  const units = await api(env, "POST", "/api/maintenance/org-units/import", { token, body: { orgUnits: [
    { code: `${tag}-district`, type: "DISTRICT", name: "Publish fixture district", parentCode: null },
  ] } });
  assert.equal(units.status, 200, units.text);
  for (const subject of [adminSubject, walkerSubject]) {
    const r = await api(env, "POST", "/api/maintenance/identity/provision-user", { token, body: { subject, displayName: `Publish ${subject}` } });
    assert.ok(r.status === 201 || r.status === 200, r.text);
    if (subject === adminSubject) adminUserId = r.json.userId;
  }
  const a = await api(env, "POST", "/api/maintenance/identity/assign-role", { token, body: { subject: adminSubject, roleCode: "MASTER_INSTRUMENT_ADMIN", orgUnitCode: `${tag}-district` } });
  assert.equal(a.status, 201, a.text);
  const w = await api(env, "POST", "/api/maintenance/identity/assign-role", { token, body: { subject: walkerSubject, roleCode: "DISTRICT_WALK_REPORT", orgUnitCode: `${tag}-district`, includeDescendants: true } });
  assert.equal(w.status, 201, w.text);
  admin = await client(adminSubject);
  walker = await client(walkerSubject);
});

after(async () => {
  if (!skip) {
    const r = await api(env, "POST", "/api/maintenance/identity/cleanup-fixtures", { token, body: { tag } });
    if (r.status !== 200) console.error("publish fixture cleanup failed", r.status, r.text);
  }
  if (pool) { await pool.close(); pool = null; }
});

// ---- authentication, authorization, CSRF -----------------------------------------------------

test("publish refuses an anonymous request and discloses nothing", { skip }, async () => {
  const draft = await newDraft("anon");
  const before = await versionRow(draft.versionId);
  const anonymous = await fetch(`${baseUrl(env)}/index.cfm${publishPath(draft.versionId)}`, {
    method: "POST", headers: { Accept: "application/json" },
  });
  const body = await anonymous.json();
  assert.equal(anonymous.status, 401);
  assert.equal(body.error.code, "UNAUTHENTICATED");
  assert.ok(!("versionId" in body), "no version data leaks to an anonymous caller");
  assert.ok(!("checksum" in body));
  const after = await versionRow(draft.versionId);
  assert.equal(after.status, "DRAFT");
  assert.equal(after.row_version, before.row_version, "nothing moved");
});

test("publish refuses a signed-in user without instrument.manage", { skip }, async () => {
  const draft = await newDraft("forbidden");
  const before = await versionRow(draft.versionId);
  assert.equal(walker.me.permissions["instrument.manage"], false, "precondition: the walker has no instrument.manage");
  const r = await walker.call("POST", publishPath(draft.versionId));
  assert.equal(r.status, 403, r.text);
  assert.equal(r.json.error.code, "FORBIDDEN");
  const after = await versionRow(draft.versionId);
  assert.equal(after.status, "DRAFT");
  assert.equal(after.row_version, before.row_version);
  assert.equal(await auditCount(draft.versionId, "INSTRUMENT_VERSION_PUBLISHED"), 0);
});

test("publish refuses a missing and an invalid CSRF token", { skip }, async () => {
  const draft = await newDraft("csrf");
  const before = await versionRow(draft.versionId);

  const missing = await admin.call("POST", publishPath(draft.versionId), undefined, { noCsrf: true });
  assert.equal(missing.status, 403, missing.text);
  assert.equal(missing.json.error.code, "CSRF_TOKEN_INVALID");

  const invalid = await admin.call("POST", publishPath(draft.versionId), undefined, { badCsrf: true });
  assert.equal(invalid.status, 403, invalid.text);
  assert.equal(invalid.json.error.code, "CSRF_TOKEN_INVALID");

  const after = await versionRow(draft.versionId);
  assert.equal(after.status, "DRAFT", "a CSRF refusal publishes nothing");
  assert.equal(after.row_version, before.row_version);
  assert.equal(await auditCount(draft.versionId, "INSTRUMENT_VERSION_PUBLISHED"), 0);
});

// ---- input ------------------------------------------------------------------------------------

test("publish refuses a malformed version id", { skip }, async () => {
  const r = await admin.call("POST", publishPath("not-a-guid"));
  assert.equal(r.status, 400, r.text);
  assert.equal(r.json.error.code, "INVALID_VERSION_ID");
});

test("publish answers 404 for an unknown version without disclosing or mutating anything", { skip }, async () => {
  const unknown = crypto.randomUUID().toUpperCase();
  const versionsBefore = (await query("SELECT COUNT(*) AS n FROM icf.instrument_version"))[0].n;
  const r = await admin.call("POST", publishPath(unknown));
  assert.equal(r.status, 404, r.text);
  assert.equal(r.json.error.code, "INSTRUMENT_VERSION_NOT_FOUND");
  assert.ok(!("versionLabel" in r.json), "the refusal names nothing that exists");
  assert.equal((await query("SELECT COUNT(*) AS n FROM icf.instrument_version"))[0].n, versionsBefore, "no row was created");
  assert.equal(await auditCount(unknown, "INSTRUMENT_VERSION_PUBLISHED"), 0);
});

test("publish takes no request body, and a client cannot name the publisher", { skip }, async () => {
  const draft = await newDraft("body");
  const before = await versionRow(draft.versionId);
  const otherUser = (await query("SELECT TOP (1) user_id FROM icf.app_user WHERE user_id <> @me", { me: adminUserId }))[0].user_id;

  for (const body of [
    { actorUserId: otherUser },
    { publishedByUserId: otherUser },
    { principal: { userId: otherUser } },
    { versionId: crypto.randomUUID() },
    { checksum: "0".repeat(64) },
  ]) {
    const r = await admin.call("POST", publishPath(draft.versionId), body);
    assert.equal(r.status, 400, `${JSON.stringify(body)} -> ${r.text}`);
    assert.equal(r.json.error.code, "PUBLISH_BODY_NOT_ALLOWED");
  }

  const after = await versionRow(draft.versionId);
  assert.equal(after.status, "DRAFT", "none of those attempts published anything");
  assert.equal(after.row_version, before.row_version);

  // With no body at all, the same version publishes, and the publisher is the session's user --
  // not any id a body tried to supply.
  const ok = await admin.call("POST", publishPath(draft.versionId));
  assert.equal(ok.status, 200, ok.text);
  const published = await versionRow(draft.versionId);
  assert.equal(published.published_by_user_id.toUpperCase(), adminUserId.toUpperCase());
  assert.notEqual(published.published_by_user_id.toUpperCase(), otherUser.toUpperCase());
});

// ---- the success path --------------------------------------------------------------------------

test("an administrator publishes a DRAFT: frozen bytes, stored publisher, one audit", { skip }, async () => {
  const draft = await newDraft("success");
  const before = await versionRow(draft.versionId);
  assert.equal(before.status, "DRAFT");

  const r = await admin.call("POST", publishPath(draft.versionId));
  assert.equal(r.status, 200, r.text);
  assert.equal(r.json.status, "PUBLISHED");
  assert.equal(r.json.versionId.toUpperCase(), draft.versionId.toUpperCase());
  assert.equal(r.json.checksum, draft.checksum, "publishing does not recompute the checksum");
  assert.equal(r.json.definitionsChecksum, draft.definitionsChecksum);
  assert.equal(r.json.publishedByUserId.toUpperCase(), adminUserId.toUpperCase(), "the response names the signed-in publisher");
  assert.deepEqual(r.json.counts, draft.counts);

  const after = await versionRow(draft.versionId);
  assert.equal(after.status, "PUBLISHED");
  assert.equal(after.compiled_snapshot_json, before.compiled_snapshot_json, "the frozen snapshot is byte-for-byte the imported one");
  assert.equal(after.checksum_sha256.trim(), before.checksum_sha256.trim());
  assert.equal(sha256Hex(after.compiled_snapshot_json), after.checksum_sha256.trim(), "and the checksum still hashes it");
  assert.equal(after.published_by_user_id.toUpperCase(), adminUserId.toUpperCase(), "the publisher comes from the authenticated principal");
  assert.ok(after.published_at instanceof Date, "published_at is set");
  assert.ok(after.effective_start instanceof Date, "effective_start is set");

  assert.equal(await auditCount(draft.versionId, "INSTRUMENT_VERSION_PUBLISHED"), 1);
  const audit = await query(
    "SELECT actor_user_id FROM icf.audit_event WHERE entity_id = @id AND event_type = N'INSTRUMENT_VERSION_PUBLISHED'",
    { id: draft.versionId });
  assert.equal(audit[0].actor_user_id.toUpperCase(), adminUserId.toUpperCase(), "the audit actor is the stored publisher");
});

// ---- the checksum-matching validation refusal --------------------------------------------------

test("a checksum-matching semantically invalid DRAFT is refused with the validation response and changes nothing", { skip }, async () => {
  const draft = await newDraft("invalid");
  const original = await versionRow(draft.versionId);

  // Build a version that is perfectly self-consistent and semantically invalid: an unsupported
  // rule effect written into BOTH the definition table and the stored snapshot, with the snapshot's
  // checksum recomputed. The drift check and the checksum check therefore both pass, and only real
  // validation can refuse the publish.
  const snapshot = JSON.parse(original.compiled_snapshot_json);
  assert.equal(canonicalize(snapshot), original.compiled_snapshot_json, "precondition: the stored snapshot is canonical, so it can be edited and re-serialized exactly");
  const ruleKey = snapshot.definitions.rules[0].ruleKey;
  snapshot.definitions.rules[0].effect = "HIDE";
  const edited = canonicalize(snapshot);
  await query(
    `UPDATE icf.rule_definition SET effect = N'HIDE' WHERE version_id = @id AND rule_key = @ruleKey;
     UPDATE icf.instrument_version SET compiled_snapshot_json = @snapshot, checksum_sha256 = @checksum WHERE version_id = @id;`,
    { id: draft.versionId, ruleKey, snapshot: edited, checksum: sha256Hex(edited) });

  const prepared = await versionRow(draft.versionId);
  assert.equal(sha256Hex(prepared.compiled_snapshot_json), prepared.checksum_sha256.trim(), "precondition: checksum matches the snapshot");

  const r = await admin.call("POST", publishPath(draft.versionId));
  assert.equal(r.status, 422, r.text);
  assert.equal(r.json.error.code, "INSTRUMENT_VERSION_NOT_PUBLISHABLE");
  assert.ok(Array.isArray(r.json.error.details.issues), "the established validation response shape");
  const codes = r.json.error.details.issues.map((i) => i.code);
  assert.ok(codes.includes("UNSUPPORTED_EFFECT"), `expected UNSUPPORTED_EFFECT, got ${codes.join(", ")}`);
  for (const issue of r.json.error.details.issues) {
    assert.equal(typeof issue.code, "string");
    assert.equal(typeof issue.message, "string");
    assert.equal(typeof issue.path, "string");
  }

  const after = await versionRow(draft.versionId);
  assert.equal(after.status, "DRAFT", "a refused publish leaves the version a DRAFT");
  assert.equal(after.published_by_user_id, null, "and names no publisher");
  assert.equal(after.compiled_snapshot_json, prepared.compiled_snapshot_json, "and changes nothing");
  assert.equal(after.checksum_sha256.trim(), prepared.checksum_sha256.trim());
  assert.equal(await auditCount(draft.versionId, "INSTRUMENT_VERSION_PUBLISHED"), 0);
  assert.equal(await auditCount(draft.versionId, "INSTRUMENT_VERSION_PUBLISH_REFUSED"), 1, "exactly one refusal survived the rollback");
});

// ---- repeat publication and lost responses ------------------------------------------------------

test("publishing twice is a deterministic conflict and creates no second success event", { skip }, async () => {
  const draft = await newDraft("repeat");
  const first = await admin.call("POST", publishPath(draft.versionId));
  assert.equal(first.status, 200, first.text);
  const frozen = await versionRow(draft.versionId);

  const second = await admin.call("POST", publishPath(draft.versionId));
  assert.equal(second.status, 409, second.text);
  assert.equal(second.json.error.code, "INSTRUMENT_VERSION_NOT_DRAFT");
  assert.equal(second.json.error.details.status, "PUBLISHED");

  const after = await versionRow(draft.versionId);
  assert.equal(after.row_version, frozen.row_version, "the frozen row did not move");
  assert.equal(after.compiled_snapshot_json, frozen.compiled_snapshot_json);
  assert.equal(after.published_by_user_id, frozen.published_by_user_id);
  assert.equal(await auditCount(draft.versionId, "INSTRUMENT_VERSION_PUBLISHED"), 1, "still exactly one success event");
  assert.equal(await auditCount(draft.versionId, "INSTRUMENT_VERSION_PUBLISH_REFUSED"), 1, "and the second attempt is recorded as a refusal");
});

test("a retry after an assumed-lost successful response cannot publish twice or alter the frozen state", { skip }, async () => {
  const draft = await newDraft("lost");
  // The first response is deliberately discarded, the way a client that timed out would.
  await admin.call("POST", publishPath(draft.versionId));
  const frozen = await versionRow(draft.versionId);
  assert.equal(frozen.status, "PUBLISHED", "the committed publication really happened");

  const retry = await admin.call("POST", publishPath(draft.versionId));
  assert.equal(retry.status, 409, retry.text);
  assert.equal(retry.json.error.code, "INSTRUMENT_VERSION_NOT_DRAFT");

  const after = await versionRow(draft.versionId);
  assert.equal(after.row_version, frozen.row_version, "the retry moved nothing");
  assert.equal(after.compiled_snapshot_json, frozen.compiled_snapshot_json, "the frozen snapshot is untouched");
  assert.equal(after.published_at.getTime(), frozen.published_at.getTime(), "and the publication time was not rewritten");
  assert.equal(after.published_by_user_id, frozen.published_by_user_id);
  assert.equal(await auditCount(draft.versionId, "INSTRUMENT_VERSION_PUBLISHED"), 1, "one publication, not two");
});

// ---- concurrency ----------------------------------------------------------------------------------

test("two concurrent publishes produce exactly one transition and one deterministic refusal", { skip }, async () => {
  const draft = await newDraft("race");
  // Two independent signed-in sessions, so neither shares the other's cookie or CSRF token, both
  // released at once. The version row's UPDLOCK is the serializing seam: whatever the interleaving,
  // the second transaction reads the status the first committed.
  const [a, b] = await Promise.all([client(adminSubject), client(adminSubject)]);
  const [ra, rb] = await Promise.all([
    a.call("POST", publishPath(draft.versionId)),
    b.call("POST", publishPath(draft.versionId)),
  ]);

  const statuses = [ra.status, rb.status].sort((x, y) => x - y);
  assert.deepEqual(statuses, [200, 409], `expected one success and one conflict, got ${ra.status} and ${rb.status}: ${ra.text} | ${rb.text}`);
  const loser = ra.status === 409 ? ra : rb;
  const winner = ra.status === 200 ? ra : rb;
  assert.equal(loser.json.error.code, "INSTRUMENT_VERSION_NOT_DRAFT", "the loser is refused deterministically, not by a timeout or a deadlock");
  assert.equal(loser.json.error.details.status, "PUBLISHED");

  const after = await versionRow(draft.versionId);
  assert.equal(after.status, "PUBLISHED");
  assert.equal(after.checksum_sha256.trim(), draft.checksum, "the published checksum is the imported one");
  assert.equal(winner.json.checksum, draft.checksum);
  assert.equal(after.published_by_user_id.toUpperCase(), adminUserId.toUpperCase());
  assert.equal(await auditCount(draft.versionId, "INSTRUMENT_VERSION_PUBLISHED"), 1, "exactly one success audit, so the version was published once");
  assert.equal(await auditCount(draft.versionId, "INSTRUMENT_VERSION_PUBLISH_REFUSED"), 1, "and exactly one refusal audit");
});

test("a publish racing a mutation ends in one serial order, and published content never changes after", { skip }, async () => {
  const draft = await newDraft("mutrace");
  const label = draft.versionLabel;
  const publisher = await client(adminSubject);

  // Released together: a publish of this DRAFT and a re-import of the same DRAFT. Both take the
  // instrument_version row first and hold it to commit, so one of exactly two serial orders
  // happens -- there is no interleaving that leaves a half-frozen version.
  const [publishResult, importResult] = await Promise.all([
    publisher.call("POST", publishPath(draft.versionId)),
    api(env, "POST", "/api/maintenance/instrument/import", { token, body: { instrumentCode, versionLabel: label } }),
  ]);

  // Neither transaction may die on the way. A 500 here is what a lock-order inversion looks like:
  // publication locks icf.instrument_version and then reads icf.instrument for the snapshot's
  // identity, so an import that locked icf.instrument first would deadlock instead of queueing,
  // and SQL Server would pick one of them as the victim.
  for (const [what, r] of [["publish", publishResult], ["import", importResult]]) {
    assert.ok(r.status < 500, `${what} must queue on the version row, not die: ${r.status} ${r.text}`);
    assert.ok(!deadlocked(r), `${what} deadlocked, so the two paths do not share one lock order: ${r.text}`);
  }

  const after = await versionRow(draft.versionId);
  if (publishResult.status === 200) {
    // Publication won: the import found a frozen version and was refused, changing nothing.
    assert.equal(after.status, "PUBLISHED");
    assert.equal(importResult.status, 409, `the mutation must be refused once publication committed: ${importResult.text}`);
    assert.equal(importResult.json.error.code, "INSTRUMENT_VERSION_IMMUTABLE");
  } else {
    // The mutation won: it committed, and publication then refused or froze the re-imported DRAFT.
    assert.ok(importResult.status === 200 || importResult.status === 201, importResult.text);
    assert.ok([200, 409, 422].includes(publishResult.status), `unexpected publish outcome ${publishResult.status}: ${publishResult.text}`);
  }
  assert.equal(await auditCount(draft.versionId, "INSTRUMENT_VERSION_PUBLISHED"), after.status === "PUBLISHED" ? 1 : 0);

  // Whatever the order, the version is now internally consistent, and if it is published it stays
  // exactly as it is.
  assert.equal(sha256Hex(after.compiled_snapshot_json), after.checksum_sha256.trim(), "the stored checksum hashes the stored snapshot");
  if (after.status !== "PUBLISHED") {
    const late = await publisher.call("POST", publishPath(draft.versionId));
    assert.equal(late.status, 200, late.text);
  }
  const frozen = await versionRow(draft.versionId);
  assert.equal(frozen.status, "PUBLISHED");

  const retryImport = await api(env, "POST", "/api/maintenance/instrument/import", { token, body: { instrumentCode, versionLabel: label } });
  assert.equal(retryImport.status, 409, "the published version can never be mutated again");
  assert.equal(retryImport.json.error.code, "INSTRUMENT_VERSION_IMMUTABLE");
  const stillFrozen = await versionRow(draft.versionId);
  assert.equal(stillFrozen.row_version, frozen.row_version, "published content never changes afterward");
  assert.equal(stillFrozen.compiled_snapshot_json, frozen.compiled_snapshot_json);
});

test("repeated publish/mutation races never deadlock: the two paths share one lock order", { skip }, async () => {
  // One race can miss an inversion by luck. This releases several, on fresh DRAFTs, and asserts
  // the same two-outcome contract every time -- no 5xx, no deadlock victim, and exactly one of the
  // two serial orders.
  for (let round = 0; round < 4; round++) {
    const draft = await newDraft(`serialorder-${round}`);
    const publisher = await client(adminSubject);
    const [p, i] = await Promise.all([
      publisher.call("POST", publishPath(draft.versionId)),
      api(env, "POST", "/api/maintenance/instrument/import", { token, body: { instrumentCode, versionLabel: draft.versionLabel } }),
    ]);
    for (const [what, r] of [["publish", p], ["import", i]]) {
      assert.ok(r.status < 500, `round ${round}: ${what} answered ${r.status}: ${r.text}`);
      assert.ok(!deadlocked(r), `round ${round}: ${what} deadlocked: ${r.text}`);
    }
    const publishWon = p.status === 200;
    if (publishWon) assert.equal(i.status, 409, `round ${round}: the mutation must be refused once publication committed: ${i.text}`);
    else assert.ok(i.status === 200 || i.status === 201, `round ${round}: one of them has to have committed: ${i.text}`);
    const row = await versionRow(draft.versionId);
    assert.equal(sha256Hex(row.compiled_snapshot_json), row.checksum_sha256.trim(), `round ${round}: the version is internally consistent either way`);
  }
});
