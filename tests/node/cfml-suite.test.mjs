// Drives the running CFML application: health, maintenance guard behavior, the CFML test suite
// (unit + database integration specs), and an idempotent seed of the aligned DRAFT version.
// Skipped when the application is not reachable at ICFWALK_BASE_URL / ICFWALK_PORT.
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { api, baseUrl, loadRuntimeEnv, requireApp, root } from "./helpers.mjs";

const golden = JSON.parse(fs.readFileSync(path.join(root, "tests", "golden", "instrument-snapshot.golden.json"), "utf8"));

const env = loadRuntimeEnv();
const token = env.ICFWALK_MAINTENANCE_TOKEN || "";

async function reachable() {
  try {
    const r = await fetch(`${baseUrl(env)}/index.cfm/api/health`, { signal: AbortSignal.timeout(10000) });
    return r.status > 0;
  } catch {
    return false;
  }
}
const up = await reachable();
// A release run (ICFWALK_REQUIRE_APP=1) must not silently skip these. This file carries the WHOLE
// CFML suite -- every unit spec, every database integration spec and every deterministic
// concurrency barrier -- so an absent application here means none of it ran, which is not the same
// as it having passed. The gate's own `skipped 0` assertion catches it too; this fails earlier and
// says why. admin-publish.test.mjs and no-mail.test.mjs guard themselves the same way.
if (requireApp(env) && !up) {
  throw new Error(`ICFWALK_REQUIRE_APP is set but the application is not reachable at ${baseUrl(env)}`);
}
if (requireApp(env) && !token) {
  throw new Error("ICFWALK_REQUIRE_APP is set but ICFWALK_MAINTENANCE_TOKEN is not");
}
const skip = up ? false : `application not reachable at ${baseUrl(env)}`;

test("health endpoint reports database and schema state with a correlation id", { skip }, async () => {
  const r = await api(env, "GET", "/api/health");
  assert.equal(r.status, 200, r.text);
  assert.equal(r.json.application, "ICFWalk");
  assert.equal(r.json.status, "ok");
  assert.equal(r.json.checks.database, "ok");
  assert.equal(r.json.checks.schema, "present");
  assert.match(r.headers.get("x-correlation-id"), /^[a-z0-9-]{36}$/);
  assert.equal(r.headers.get("x-correlation-id"), r.json.correlationId);
  const echoed = await fetch(`${baseUrl(env)}/index.cfm/api/health`, { headers: { "X-Correlation-Id": "trace-abc-123" } });
  assert.equal(echoed.headers.get("x-correlation-id"), "trace-abc-123");
});

test("only index.cfm is served; other templates and unknown routes are JSON 404s", { skip }, async () => {
  const direct = await fetch(`${baseUrl(env)}/Application.cfc?method=onApplicationStart`);
  assert.equal(direct.status, 404);
  const unknown = await api(env, "GET", "/api/does-not-exist");
  assert.equal(unknown.status, 404);
  assert.equal(unknown.json.error.code, "NOT_FOUND");
  const wrongMethod = await api(env, "DELETE", "/api/health");
  assert.equal(wrongMethod.status, 405);
});

test("maintenance endpoints are hidden without a valid token", { skip }, async () => {
  const noToken = await api(env, "POST", "/api/maintenance/instrument/import", { body: {} });
  assert.equal(noToken.status, 404);
  const badToken = await api(env, "POST", "/api/maintenance/instrument/import", { body: {}, token: "x".repeat(40) });
  assert.equal(badToken.status, 404);
  const badBody = await api(env, "POST", "/api/maintenance/instrument/discard-draft", { token, body: "not an object" });
  assert.equal(badBody.status, 400);
  assert.equal(badBody.json.error.code, "INVALID_JSON_BODY");
});

/**
 * The whole CFML suite, run in parts.
 *
 * It runs inside /api/maintenance/tests/run, and Lucee is configured to let it
 * (LUCEE_REQUESTTIMEOUT=600 in tools/runtime/lucee-up.sh) because several specs deliberately block
 * a writer for seconds at a time. The client was never given the same allowance: Node's fetch
 * abandons a request after five minutes without response headers, and none are sent until the
 * suite finishes, so a suite that grew past five minutes failed as "fetch failed" -- and, worse,
 * the abort skipped every spec's afterAll, leaving fixtures behind that then failed later tests.
 *
 * So the suite is requested in PARTS. Specs are dealt out round-robin over a stable name order, so
 * every spec runs exactly once across the parts and none runs twice. The reports are summed and
 * the same assertions are made on the totals: nothing is filtered out, nothing is skipped, and a
 * failure in any part fails this test.
 *
 * The parts also each carry an EXPLICIT client ceiling now. Partitioning alone only made the
 * inherited 300-second undici default less likely to be hit; on a slower machine a single heavy
 * spec still reached it and a healthy run was reported as "fetch failed". The ceiling is a harness
 * setting, so it is stated here rather than inherited -- it bounds a hang, and gives no test any
 * more room to pass.
 */
// Six parts keep each request comfortably inside Lucee's allowance on the verification machine.
// Adobe ColdFusion 2023 runs the same specs two to three times slower (its instrument import and
// publication especially), and one part of six took 872 seconds there -- inside the client ceiling
// below by less than half a minute (P8-07). ICFWALK_CFML_SUITE_PARTS deals the same specs into more,
// smaller parts; every spec still runs exactly once and every assertion below is unchanged.
const SUITE_PARTS = Math.max(1, Number.parseInt(env.ICFWALK_CFML_SUITE_PARTS || "6", 10) || 6);
// Response headers are not sent until a part finishes, and a part legitimately runs for minutes:
// several specs hold a production row lock while a second transaction queues on it. This is the
// client-side ceiling for that, set explicitly rather than inherited from undici's 300-second
// default -- see helpers.mjs. It bounds a hang; it does not give any test longer to pass.
const SUITE_PART_TIMEOUT_MS = 900000;

test("CFML test suite passes (unit specs and DB-04..09 integration specs)", { skip: skip || (token ? false : "ICFWALK_MAINTENANCE_TOKEN not set") }, async (t) => {
  const totals = { passed: 0, failed: 0, skipped: 0 };
  const seen = new Set();
  let engine = "";
  let elapsedMs = 0;

  for (let part = 1; part <= SUITE_PARTS; part++) {
    const r = await api(env, "POST", `/api/maintenance/tests/run?part=${part}&of=${SUITE_PARTS}`, { token, timeoutMs: SUITE_PART_TIMEOUT_MS });
    assert.equal(r.status, 200, `part ${part}/${SUITE_PARTS}: ${r.text}`);
    const report = r.json;
    for (const spec of report.specs) {
      assert.equal(seen.has(spec.name), false, `${spec.name} ran in more than one part`);
      seen.add(spec.name);
      for (const c of spec.cases) {
        const line = `${spec.name}.${c.name}: ${c.status}${c.message ? ` - ${c.message}` : ""}${c.at ? ` @ ${c.at}` : ""}`;
        t.diagnostic(line);
      }
    }
    totals.passed += report.totals.passed;
    totals.failed += report.totals.failed;
    totals.skipped += report.totals.skipped;
    engine = report.engine;
    elapsedMs += report.elapsedMs;
    assert.equal(report.ok, true, `part ${part}/${SUITE_PARTS} reported failures`);
  }

  // Every spec on disk ran, in exactly one part. Without this the partitioning could silently
  // drop a spec and the totals would still look healthy.
  const onDisk = fs.readdirSync(path.join(root, "tests", "cfml", "specs"))
    .filter((f) => f.endsWith("Test.cfc")).map((f) => f.replace(/\.cfc$/, ""));
  assert.deepEqual([...seen].sort(), onDisk.sort(), "every spec file ran exactly once across the parts");

  t.diagnostic(`engine=${engine} passed=${totals.passed} failed=${totals.failed} skipped=${totals.skipped} ms=${elapsedMs} parts=${SUITE_PARTS}`);
  assert.equal(totals.failed, 0, "CFML failures reported above");
  assert.equal(totals.skipped, 0, "no spec should be skipped when the schema is applied");
  assert.ok(totals.passed >= 40);
});

test("seed import of the aligned DRAFT is idempotent through the maintenance endpoint", { skip: skip || (token ? false : "ICFWALK_MAINTENANCE_TOKEN not set") }, async () => {
  const first = await api(env, "POST", "/api/maintenance/instrument/import", { body: {}, token });
  assert.ok(first.status === 200 || first.status === 201, first.text);
  assert.equal(first.json.status, "DRAFT");
  assert.equal(first.json.versionLabel, "2026-09-17 aligned prototype");
  assert.equal(first.json.counts.items, 144);
  assert.equal(first.json.placeholders.length, 17);
  assert.equal(first.json.checksum, golden.checksum, "seeded snapshot checksum equals the reference golden");
  assert.equal(first.json.definitionsChecksum, golden.definitionsChecksum);
  const second = await api(env, "POST", "/api/maintenance/instrument/import", { body: {}, token });
  assert.equal(second.status, 200, second.text);
  assert.equal(second.json.created, false);
  assert.equal(second.json.versionId, first.json.versionId);
  assert.equal(second.json.checksum, first.json.checksum);
  const traversal = await api(env, "POST", "/api/maintenance/instrument/import", { body: { configFile: "../database/001_schema.sql" }, token });
  assert.equal(traversal.status, 400);
  const versions = await api(env, "GET", "/api/maintenance/instrument/versions", { token });
  assert.equal(versions.status, 200);
  const seeded = versions.json.versions.find((v) => v.versionLabel === "2026-09-17 aligned prototype");
  assert.equal(seeded.status, "DRAFT");
  assert.equal(seeded.checksum, first.json.checksum);
});
