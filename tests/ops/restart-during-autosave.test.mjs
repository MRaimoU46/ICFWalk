// Phase 8: the application server is killed while an autosave is in flight, restarted, and the
// person presses Retry on the page they never left.
//
// This is the real thing, not a simulation: the server process gets SIGKILL (Lucee's JVM, or the
// whole Adobe ColdFusion container), so nothing in the application runs a cleanup path, and SQL
// Server finds out only because the connection drops. Two moments are covered.
//
//   A  Mid-transaction. The save has already written the new answer and moved the walk's row
//      version, and waits to record its mutation id. A test connection holds a shared table lock
//      on icf.walk_mutation, which lets the save read (findMutation) but not insert, so the save
//      stops at exactly that point with its other writes uncommitted -- a dirty read proves they
//      exist. The server dies there. Nothing of it may survive, and Retry must commit it once.
//
//   B  After commit, before the answer. The save commits; the server dies before the browser sees
//      the response. Retry sends the same clientMutationId, and the server must hand back what it
//      committed (a replay) without writing anything a second time.
//
// Either way the page kept the edit, and Retry resends the same request under the same mutation
// id. The restart also replaces the session, so the resend is first refused CSRF_TOKEN_INVALID and
// sent again under the renewed token (P8-01), and the replay rules still hold across that.
//
// It is not part of `npm test` (it kills the server). Run it on its own:
//   ICFWALK_REQUIRE_APP=1 node --test tests/ops/restart-during-autosave.test.mjs
// The engine is read from /api/health: Lucee is restarted with tools/runtime/lucee-up.sh, Adobe
// ColdFusion as the container named by ICFWALK_ACF_CONTAINER (default icfwalk-acf). Set
// ICFWALK_EVIDENCE_DIR to keep a JSON record of every observation.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { createRequire } from "node:module";
import { api, baseUrl, connectionConfig, hasDatabaseConfig, loadRuntimeEnv, requireApp, root } from "../node/helpers.mjs";

const require = createRequire(import.meta.url);
const env = loadRuntimeEnv();
const token = env.ICFWALK_MAINTENANCE_TOKEN || "";
const database = env.ICFWALK_DB_NAME || "icfwalk_dev";
const container = env.ICFWALK_ACF_CONTAINER || "icfwalk-acf";
const tag = `p8restart-${Date.now().toString(36)}`;
const subject = `${tag}-walker`;
const NOTE = "comp_s1_notes";
const evidence = { startedAt: new Date().toISOString(), baseUrl: baseUrl(env), database, scenarios: {} };

let chromium = null;
try { ({ chromium } = require("playwright")); } catch { chromium = null; }
let sql = null;
try { sql = require("mssql"); } catch { sql = null; }

async function health() {
  try {
    const r = await fetch(`${baseUrl(env)}/index.cfm/api/health`, { signal: AbortSignal.timeout(10000) });
    return { status: r.status, body: await r.json() };
  } catch (e) {
    return { status: 0, error: String(e.cause?.code || e.message) };
  }
}
const first = await health();
const engine = first.status === 200 ? (/^Lucee/.test(first.body.engine || "") ? "lucee" : /ColdFusion/.test(first.body.engine || "") ? "acf-container" : null) : null;
const dev = first.status === 200 && (first.body.environment === "development" || first.body.environment === "test");
const missing = !chromium ? "playwright is not installed"
  : !sql ? "mssql is not installed"
  : first.status !== 200 ? `application not reachable at ${baseUrl(env)}`
  : !dev ? "the application is not in development or test mode"
  : !engine ? `unrecognised engine ${first.body.engine}`
  : !token ? "no maintenance token"
  : !hasDatabaseConfig(env) ? "no database configuration" : false;
if (requireApp(env) && missing) throw new Error(`ICFWALK_REQUIRE_APP is set but ${missing}`);
const skip = missing;

let browser;
let pool;
const pageErrors = [];
const home = `${baseUrl(env)}/index.cfm/`;

// ---- the server ---------------------------------------------------------------------------------

function crash() {
  const at = Date.now();
  if (engine === "lucee") {
    const pid = Number(fs.readFileSync(path.join(root, ".runtime", "lucee.pid"), "utf8").trim());
    process.kill(pid, "SIGKILL");
    return { how: `SIGKILL to the Lucee JVM (pid ${pid})`, at };
  }
  execFileSync("docker", ["kill", "--signal", "KILL", container], { stdio: "pipe" });
  return { how: `docker kill --signal KILL ${container} (the whole ColdFusion container)`, at };
}

async function waitDown() {
  for (let i = 0; i < 60; i++) {
    const h = await health();
    if (h.status === 0) return h.error;
    await new Promise((r) => setTimeout(r, 500));
  }
  throw new Error("the server still answers after it was killed");
}

/**
 * A killed process stays a zombie until its parent reaps it, and `kill -0` still succeeds on a zombie,
 * so lucee-up.sh would report the dead JVM as "already running" and start nothing.
 */
async function reaped(pid) {
  for (let i = 0; i < 120; i++) {
    try { process.kill(pid, 0); } catch { return; }
    await new Promise((r) => setTimeout(r, 500));
  }
  throw new Error(`the killed JVM (pid ${pid}) was not reaped within 60 s`);
}

async function restart() {
  const at = Date.now();
  if (engine === "lucee") {
    const pidFile = path.join(root, ".runtime", "lucee.pid");
    if (fs.existsSync(pidFile)) await reaped(Number(fs.readFileSync(pidFile, "utf8").trim()));
    execFileSync("bash", [path.join(root, "tools", "runtime", "lucee-up.sh")], { stdio: "pipe", timeout: 240000 });
  } else {
    execFileSync("docker", ["start", container], { stdio: "pipe" });
  }
  for (let i = 0; i < 180; i++) {
    const h = await health();
    if (h.status === 200 && h.body.checks.longText === "ok") return { secondsToHealthy: Math.round((Date.now() - at) / 100) / 10, health: h.body.checks };
    await new Promise((r) => setTimeout(r, 1000));
  }
  throw new Error("the server did not report healthy within 180 s of the restart");
}

// ---- the database ---------------------------------------------------------------------------------

async function q(text, inputs = {}) {
  const request = pool.request();
  for (const [k, v] of Object.entries(inputs)) request.input(k, v);
  return (await request.query(text)).recordset;
}

/** Everything the walk consists of, as values a test can compare. */
async function walkState(walkId) {
  const [row] = await q(`
    SELECT CONVERT(varchar(20), CONVERT(bigint, w.row_version)) AS rowVersion,
      (SELECT COUNT_BIG(*) FROM icf.walk_response r WHERE r.walk_id = w.walk_id) AS responses,
      (SELECT COUNT_BIG(*) FROM (SELECT item_id FROM icf.walk_response r WHERE r.walk_id = w.walk_id GROUP BY item_id HAVING COUNT(*) > 1) d) AS duplicateItems,
      (SELECT CHECKSUM_AGG(BINARY_CHECKSUM(r.response_id, r.item_id, r.response_state, r.selected_option_id, r.number_value, r.date_value, r.boolean_value, r.row_version)) FROM icf.walk_response r WHERE r.walk_id = w.walk_id) AS responseChecksum,
      (SELECT COUNT_BIG(*) FROM icf.walk_response_selection s JOIN icf.walk_response r ON r.response_id = s.response_id WHERE r.walk_id = w.walk_id) AS selections,
      (SELECT COUNT_BIG(*) FROM icf.walk_dimension_value d WHERE d.walk_id = w.walk_id) AS dimensions,
      (SELECT CHECKSUM_AGG(BINARY_CHECKSUM(*)) FROM icf.walk_dimension_value d WHERE d.walk_id = w.walk_id) AS dimensionChecksum,
      (SELECT COUNT_BIG(*) FROM icf.walk_mutation m WHERE m.walk_id = w.walk_id) AS mutations,
      (SELECT COUNT_BIG(*) FROM icf.walk_revision v WHERE v.walk_id = w.walk_id) AS revisions,
      (SELECT r.text_value FROM icf.walk_response r JOIN icf.item_definition i ON i.item_id = r.item_id WHERE r.walk_id = w.walk_id AND i.item_key = @note) AS note
    FROM icf.walk w WHERE w.walk_id = @walk`, { walk: walkId, note: NOTE });
  return { ...row, responses: Number(row.responses), duplicateItems: Number(row.duplicateItems), selections: Number(row.selections), dimensions: Number(row.dimensions), mutations: Number(row.mutations), revisions: Number(row.revisions) };
}

async function mutationRows(mutationId) {
  return q("SELECT action, CONVERT(varchar(40), walk_id) AS walkId, result_json AS result FROM icf.walk_mutation WHERE mutation_id = @m", { m: mutationId });
}

async function walksOwned() {
  const [r] = await q("SELECT COUNT_BIG(*) AS n FROM icf.walk w JOIN icf.app_user u ON u.user_id = w.owner_user_id WHERE u.identity_subject = @s", { s: subject });
  return Number(r.n);
}

/** Sessions in this database, other than this test's own, that still hold a transaction or wait on a lock. */
async function leftovers(ownSessions) {
  return q(`
    SELECT s.session_id AS sessionId, s.program_name AS program, s.open_transaction_count AS openTransactions, r.wait_type AS waitType
    FROM sys.dm_exec_sessions s LEFT JOIN sys.dm_exec_requests r ON r.session_id = s.session_id
    WHERE s.database_id = DB_ID() AND s.is_user_process = 1 AND s.session_id <> @@SPID
      AND (s.open_transaction_count > 0 OR r.blocking_session_id > 0)
      AND s.session_id NOT IN (${ownSessions.length ? ownSessions.join(",") : "-1"})`);
}

/**
 * A shared table lock on icf.walk_mutation, held on its own connection until release(). A save can
 * still look its mutation id up (IS is compatible with S) but cannot record it (IX is not).
 */
async function holdMutationTable() {
  const tx = new sql.Transaction(pool);
  await tx.begin();
  const request = new sql.Request(tx);
  const [held] = (await request.query(`
    SELECT COUNT_BIG(*) AS n FROM icf.walk_mutation WITH (TABLOCK, HOLDLOCK);
    SELECT @@SPID AS spid,
      (SELECT request_mode FROM sys.dm_tran_locks WHERE request_session_id = @@SPID AND resource_type = 'OBJECT' AND resource_associated_entity_id = OBJECT_ID(N'icf.walk_mutation')) AS mode`)).recordsets[1];
  return { spid: held.spid, mode: held.mode, release: () => tx.rollback() };
}

async function waitBlockedBy(spid) {
  for (let i = 0; i < 100; i++) {
    const rows = await q(`
      SELECT r.session_id AS sessionId, r.wait_type AS waitType, r.wait_resource AS waitResource, r.command, s.program_name AS program
      FROM sys.dm_exec_requests r JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id
      WHERE r.blocking_session_id = @spid`, { spid });
    if (rows.length) return rows[0];
    await new Promise((r) => setTimeout(r, 200));
  }
  throw new Error("no save reached the walk_mutation insert within 20 s");
}

async function locksHeldBy(sessionId) {
  return q(`
    SELECT CASE WHEN l.resource_type = 'OBJECT' THEN OBJECT_NAME(l.resource_associated_entity_id) ELSE OBJECT_NAME(p.object_id) END AS tableName,
      l.resource_type AS resourceType, l.request_mode AS mode, l.request_status AS status, COUNT(*) AS n
    FROM sys.dm_tran_locks l LEFT JOIN sys.partitions p ON p.hobt_id = l.resource_associated_entity_id
    WHERE l.request_session_id = @s AND l.resource_database_id = DB_ID()
    GROUP BY CASE WHEN l.resource_type = 'OBJECT' THEN OBJECT_NAME(l.resource_associated_entity_id) ELSE OBJECT_NAME(p.object_id) END, l.resource_type, l.request_mode, l.request_status
    ORDER BY 1, 2, 3`, { s: sessionId });
}

async function sessionGone(sessionId) {
  for (let i = 0; i < 120; i++) {
    const rows = await q("SELECT session_id FROM sys.dm_exec_sessions WHERE session_id = @s AND program_name <> N'node-mssql'", { s: sessionId });
    if (!rows.length) return (i * 250) / 1000;
    await new Promise((r) => setTimeout(r, 250));
  }
  throw new Error(`session ${sessionId} was still there 30 s after the server died`);
}

async function ownSessions() {
  return (await q("SELECT session_id AS s FROM sys.dm_exec_sessions WHERE program_name = N'node-mssql' OR session_id = @@SPID")).map((r) => r.s);
}

// ---- the page ---------------------------------------------------------------------------------------

const waitStatus = (p, re, timeout = 30000) => p.waitForFunction((src) => new RegExp(src).test(document.getElementById("save-status").textContent), re.source, { timeout });
const expand = (p, key) => p.click(`[data-section-key="${key}"] > h2 > .acc-head, [data-section-key="${key}"] > h3 > .acc-head`);

async function apiList() {
  const r = await fetch(`${baseUrl(env)}/index.cfm/api/walks`, { headers: { "X-ICFWalk-Dev-Subject": subject } });
  return (await r.json()).walks;
}

async function openEditorOnNewWalk(firstNote) {
  const context = await browser.newContext({ extraHTTPHeaders: { "X-ICFWalk-Dev-Subject": subject }, viewport: { width: 1280, height: 900 } });
  const page = await context.newPage();
  page.on("pageerror", (e) => pageErrors.push(`pageerror: ${e.message}`));
  await page.goto(home, { waitUntil: "networkidle" });
  await page.waitForSelector("body[data-ready=true]", { timeout: 30000 });
  await page.click("#new-walk-btn");
  await page.waitForSelector("#view-walk:not([hidden])");
  const id = (await apiList())[0].id;
  await expand(page, "part2");
  await expand(page, "s1");
  await page.fill(`[data-item-key="${NOTE}"] textarea`, firstNote);
  await waitStatus(page, /^All changes saved$/);
  return { context, page, id };
}

/** A save request without its send time, which is not part of what the request means. */
const semantic = ({ changedAt, ...rest }) => rest;

/** Every save the page sends for the walk from now on: what went out, and how it ended. */
function recordSaves(page, walkId) {
  const seen = [];
  const mine = (req) => req.method() === "PUT" && req.url().endsWith(`/api/walks/${walkId}`);
  page.on("request", (req) => { if (mine(req)) seen.push({ body: req.postDataJSON(), outcome: "pending" }); });
  page.on("requestfailed", (req) => {
    if (!mine(req)) return;
    const entry = seen.findLast((s) => s.outcome === "pending");
    if (entry) entry.outcome = `failed ${req.failure()?.errorText}`;
  });
  page.on("response", async (res) => {
    if (!mine(res.request())) return;
    const entry = seen.findLast((s) => s.outcome === "pending");
    let json = null;
    try { json = await res.json(); } catch { json = null; }
    if (entry) {
      entry.outcome = `${res.status()}${json?.error?.code ? ` ${json.error.code}` : ""}`;
      entry.replayed = json?.walk ? json.replayed ?? json.walk.replayed ?? null : json?.replayed ?? null;
    }
  });
  return seen;
}

// ---- setup ------------------------------------------------------------------------------------------

before(async () => {
  if (skip) return;
  pool = await new sql.ConnectionPool(connectionConfig(env, database)).connect();
  const units = await api(env, "POST", "/api/maintenance/org-units/import", { token, body: { orgUnits: [
    { code: `${tag}-district`, type: "DISTRICT", name: "Restart fixture district", parentCode: null },
    { code: `${tag}-school`, type: "SCHOOL", name: "Restart fixture school", parentCode: `${tag}-district` },
  ] } });
  assert.equal(units.status, 200, units.text);
  const u = await api(env, "POST", "/api/maintenance/identity/provision-user", { token, body: { subject, displayName: "Restart Walker" } });
  assert.ok(u.status === 201 || u.status === 200, u.text);
  const a = await api(env, "POST", "/api/maintenance/identity/assign-role", { token, body: { subject, roleCode: "SCHOOL_WALK_REPORT", orgUnitCode: `${tag}-school` } });
  assert.equal(a.status, 201, a.text);
  browser = await chromium.launch();
  evidence.engine = first.body.engine;
});

after(async () => {
  if (browser) await browser.close();
  if (!skip) {
    const h = await health();
    if (h.status !== 200) await restart();
    const r = await api(env, "POST", "/api/maintenance/identity/cleanup-fixtures", { token, body: { tag } });
    if (r.status !== 200) console.error("fixture cleanup failed", r.status, r.text);
  }
  if (pool) await pool.close();
  evidence.pageErrors = pageErrors;
  evidence.finishedAt = new Date().toISOString();
  if (env.ICFWALK_EVIDENCE_DIR) {
    fs.mkdirSync(env.ICFWALK_EVIDENCE_DIR, { recursive: true });
    fs.writeFileSync(path.join(env.ICFWALK_EVIDENCE_DIR, `restart-during-autosave-${engine}.json`), `${JSON.stringify(evidence, null, 2)}\n`);
  }
});

// ---- A: killed mid-transaction ----------------------------------------------------------------------

test("A: a save killed mid-transaction leaves nothing behind, and Retry after the restart saves it exactly once", { skip, timeout: 600000 }, async (t) => {
  const record = (evidence.scenarios.midTransaction = {});
  const { context, page, id } = await openEditorOnNewWalk("saved before the crash");
  const walksBefore = await walksOwned();
  const before = await walkState(id);
  record.before = before;
  const saves = recordSaves(page, id);

  const blocker = await holdMutationTable();
  record.blocker = { sessionId: blocker.spid, lockOnWalkMutation: blocker.mode };
  assert.equal(blocker.mode, "S", "the test holds a shared table lock on icf.walk_mutation");
  let released = false;
  try {
    await page.fill(`[data-item-key="${NOTE}"] textarea`, "typed while the server died");
    const blocked = await waitBlockedBy(blocker.spid);
    record.blockedSave = blocked;
    assert.equal(blocked.waitType, "LCK_M_IX", "the save waits to insert its mutation record");
    assert.equal(blocked.command, "INSERT");
    const locks = await locksHeldBy(blocked.sessionId);
    record.blockedSaveLocks = locks;
    assert.ok(locks.some((l) => l.tableName === "walk_response" && l.mode === "X" && l.resourceType === "KEY"), "the new answer is written, uncommitted");
    assert.ok(locks.some((l) => l.tableName === "walk" && l.mode === "X" && l.resourceType === "KEY"), "the walk row is updated, uncommitted");
    const [dirty] = await q(`SELECT r.text_value AS note, CONVERT(varchar(20), CONVERT(bigint, w.row_version)) AS rowVersion
      FROM icf.walk w WITH (NOLOCK) JOIN icf.walk_response r WITH (NOLOCK) ON r.walk_id = w.walk_id JOIN icf.item_definition i ON i.item_id = r.item_id
      WHERE w.walk_id = @w AND i.item_key = @n`, { w: id, n: NOTE });
    record.uncommittedRead = dirty;
    assert.equal(dirty.note, "typed while the server died", "a dirty read sees the save's uncommitted answer");
    assert.notEqual(dirty.rowVersion, before.rowVersion, "and its uncommitted row version");
    assert.equal(saves.length, 1);
    const mutationId = saves[0].body.clientMutationId;
    record.clientMutationId = mutationId;

    record.crash = crash();
    record.connectionError = await waitDown();
    record.secondsUntilSqlServerDroppedTheSession = await sessionGone(blocked.sessionId);
    await blocker.release();
    released = true;

    const afterCrash = await walkState(id);
    record.afterCrash = afterCrash;
    assert.deepEqual(afterCrash, before, "the walk is exactly as it was before the save began");
    assert.deepEqual(await mutationRows(mutationId), [], "no mutation record for the killed save");
    assert.deepEqual(await leftovers(await ownSessions()), [], "no open transaction or blocked request is left in the database");

    await waitStatus(page, /^Could not reach the server/);
    record.pageStatusWhileDown = await page.textContent("#save-status");
    assert.equal(await page.inputValue(`[data-item-key="${NOTE}"] textarea`), "typed while the server died", "the edit is still on the page");
    assert.equal(await page.isVisible("#save-retry"), true);

    record.restart = await restart();
    await page.click("#save-retry");
    await waitStatus(page, /^(All changes saved|Could not save.*|The last save.*|Could not reach.*)$/);
    record.pageStatusAfterRetry = await page.textContent("#save-status");
    assert.equal(record.pageStatusAfterRetry, "All changes saved");

    record.saves = saves.map((s) => ({ outcome: s.outcome, clientMutationId: s.body.clientMutationId, replayed: s.replayed ?? null }));
    t.diagnostic(`saves: ${record.saves.map((s) => s.outcome).join(" | ")}`);
    assert.equal(saves.length, 3, "the killed attempt, the refused resend, and the resend under the renewed token");
    assert.match(saves[0].outcome, /^failed /, "the killed attempt has no answer");
    assert.equal(saves[1].outcome, "403 CSRF_TOKEN_INVALID", "the restart replaced the session");
    assert.equal(saves[2].outcome, "200");
    // changedAt is the client's send time and is outside the request fingerprint (DATA_CONTRACT.md);
    // everything the request means is identical on every attempt.
    for (const s of saves) assert.deepEqual(semantic(s.body), semantic(saves[0].body), "every attempt is the same request under the same mutation id");

    const afterRetry = await walkState(id);
    record.afterRetry = afterRetry;
    assert.equal(afterRetry.note, "typed while the server died");
    assert.equal(afterRetry.mutations, before.mutations + 1, "exactly one more mutation record");
    assert.equal((await mutationRows(mutationId)).length, 1);
    assert.equal(afterRetry.revisions, before.revisions);
    assert.equal(afterRetry.duplicateItems, 0);
    assert.equal(afterRetry.responses, before.responses, "the answer was updated in place, not added twice");
    assert.notEqual(afterRetry.rowVersion, before.rowVersion);
    assert.equal(await walksOwned(), walksBefore, "no walk was created by the retry");
  } finally {
    if (!released) await blocker.release().catch(() => {});
    await context.close();
  }
});

// ---- B: killed after commit, before the answer ------------------------------------------------------

test("B: a save committed just before the server died is replayed on Retry, not applied twice", { skip, timeout: 600000 }, async (t) => {
  const record = (evidence.scenarios.afterCommit = {});
  const { context, page, id } = await openEditorOnNewWalk("saved before the second crash");
  const walksBefore = await walksOwned();
  const before = await walkState(id);
  record.before = before;
  const saves = recordSaves(page, id);

  // The first save the page sends goes to the server and commits; the server is then killed, and
  // the page is told the connection was reset, so it never sees the answer.
  let committedAnswer = null;
  await page.route(`**/api/walks/${id}`, async (route) => {
    if (route.request().method() !== "PUT") return route.continue();
    const response = await route.fetch();
    committedAnswer = { status: response.status(), body: await response.json() };
    record.crash = crash();
    await route.abort("connectionreset");
  }, { times: 1 });

  await page.fill(`[data-item-key="${NOTE}"] textarea`, "committed but never answered");
  await waitStatus(page, /^Could not reach the server/);
  record.connectionError = await waitDown();
  record.answerTheServerSent = { status: committedAnswer.status, rowVersion: committedAnswer.body.walk?.rowVersion ?? committedAnswer.body.rowVersion ?? null, replayed: committedAnswer.body.replayed ?? null };
  assert.equal(committedAnswer.status, 200, "the server committed and answered");
  const mutationId = saves[0].body.clientMutationId;
  record.clientMutationId = mutationId;

  const committed = await walkState(id);
  record.afterCrash = committed;
  assert.equal(committed.note, "committed but never answered", "the committed save survived the crash");
  assert.equal(committed.mutations, before.mutations + 1);
  assert.equal((await mutationRows(mutationId)).length, 1);
  assert.deepEqual(await leftovers(await ownSessions()), [], "no open transaction or blocked request is left in the database");
  assert.equal(await page.inputValue(`[data-item-key="${NOTE}"] textarea`), "committed but never answered");

  record.restart = await restart();
  await page.click("#save-retry");
  await waitStatus(page, /^(All changes saved|Could not save.*|The last save.*|Could not reach.*)$/);
  record.pageStatusAfterRetry = await page.textContent("#save-status");
  assert.equal(record.pageStatusAfterRetry, "All changes saved");

  record.saves = saves.map((s) => ({ outcome: s.outcome, clientMutationId: s.body.clientMutationId, replayed: s.replayed ?? null }));
  t.diagnostic(`saves: ${record.saves.map((s) => `${s.outcome}${s.replayed ? " (replayed)" : ""}`).join(" | ")}`);
  assert.equal(saves.length, 3);
  assert.match(saves[0].outcome, /^failed /);
  assert.equal(saves[1].outcome, "403 CSRF_TOKEN_INVALID");
  assert.equal(saves[2].outcome, "200");
  assert.equal(saves[2].replayed, true, "the server recognised the mutation id and replayed its recorded result");
  for (const s of saves) assert.deepEqual(semantic(s.body), semantic(saves[0].body));

  const afterRetry = await walkState(id);
  record.afterRetry = afterRetry;
  assert.deepEqual(afterRetry, committed, "the retry wrote nothing: same row version, answers, mutation records, revisions");
  assert.equal(await walksOwned(), walksBefore);

  // The page carries on from the committed row version: the next edit saves without a conflict.
  await page.fill(`[data-item-key="${NOTE}"] textarea`, "the next edit after the restart");
  await waitStatus(page, /^(All changes saved|Could not save.*)$/);
  assert.equal(await page.textContent("#save-status"), "All changes saved");
  assert.equal(await page.isVisible("#conflict-panel"), false);
  const next = await walkState(id);
  record.afterNextEdit = next;
  assert.equal(next.note, "the next edit after the restart");
  assert.equal(next.mutations, committed.mutations + 1);
  await context.close();
});

test("no page error in either scenario", { skip }, () => {
  assert.deepEqual(pageErrors, []);
});
