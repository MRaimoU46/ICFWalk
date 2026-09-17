// Drives the running CFML application: health, maintenance guard behavior, the CFML test suite
// (unit + database integration specs), and an idempotent seed of the aligned DRAFT version.
// Skipped when the application is not reachable at ICFWALK_BASE_URL / ICFWALK_PORT.
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { api, baseUrl, loadRuntimeEnv, root } from "./helpers.mjs";

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

test("CFML test suite passes (unit specs and DB-04..09 integration specs)", { skip: skip || (token ? false : "ICFWALK_MAINTENANCE_TOKEN not set") }, async (t) => {
  const r = await api(env, "POST", "/api/maintenance/tests/run", { token });
  assert.equal(r.status, 200, r.text);
  const report = r.json;
  for (const spec of report.specs) {
    for (const c of spec.cases) {
      const line = `${spec.name}.${c.name}: ${c.status}${c.message ? ` - ${c.message}` : ""}${c.at ? ` @ ${c.at}` : ""}`;
      t.diagnostic(line);
    }
  }
  t.diagnostic(`engine=${report.engine} passed=${report.totals.passed} failed=${report.totals.failed} skipped=${report.totals.skipped} ms=${report.elapsedMs}`);
  assert.equal(report.totals.failed, 0, "CFML failures reported above");
  assert.equal(report.totals.skipped, 0, "no spec should be skipped when the schema is applied");
  assert.equal(report.ok, true);
  assert.ok(report.totals.passed >= 40);
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
