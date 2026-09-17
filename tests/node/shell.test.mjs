// Authorization on the Phase 3 routes (HTML shell and instrument render model) plus the
// security headers and content type of the shell. Uses the development identity like auth.test.mjs.
import { test, after } from "node:test";
import assert from "node:assert/strict";
import { api, baseUrl, loadRuntimeEnv } from "./helpers.mjs";

const env = loadRuntimeEnv();
const token = env.ICFWALK_MAINTENANCE_TOKEN || "";
const tag = `httpshell-${Date.now().toString(36)}`;

async function reachable() {
  try {
    const r = await fetch(`${baseUrl(env)}/index.cfm/api/health`, { signal: AbortSignal.timeout(10000) });
    if (r.status !== 200) return false;
    const body = await r.json();
    return body.environment === "development" || body.environment === "test";
  } catch { return false; }
}
const up = await reachable();
const skip = up ? false : `application not reachable in development mode at ${baseUrl(env)}`;
const needToken = skip || (token ? false : "no maintenance token");

async function call(method, path, { subject, accept = "application/json" } = {}) {
  const headers = { Accept: accept };
  if (subject) headers["X-ICFWalk-Dev-Subject"] = subject;
  const response = await fetch(`${baseUrl(env)}/index.cfm${path}`, { method, headers, redirect: "manual" });
  const text = await response.text();
  let json = null;
  try { json = JSON.parse(text); } catch { json = null; }
  return { status: response.status, json, text, response };
}

const walker = `${tag}-walker`, reporter = `${tag}-reporter`, admin = `${tag}-admin`, nobody = `${tag}-nobody`;

test("fixtures", { skip: needToken }, async () => {
  const units = await api(env, "POST", "/api/maintenance/org-units/import", { token, body: { orgUnits: [
    { code: `${tag}-district`, type: "DISTRICT", name: "Shell fixture district", parentCode: null },
    { code: `${tag}-school`, type: "SCHOOL", name: "Shell fixture school", parentCode: `${tag}-district` },
  ] } });
  assert.equal(units.status, 200, units.text);
  for (const subject of [walker, reporter, admin, nobody]) {
    const r = await api(env, "POST", "/api/maintenance/identity/provision-user", { token, body: { subject, displayName: `Shell ${subject}` } });
    assert.ok(r.status === 201 || r.status === 200, r.text);
  }
  for (const [subject, roleCode] of [[walker, "SCHOOL_WALK_REPORT"], [reporter, "SCHOOL_REPORT_ONLY"]]) {
    const r = await api(env, "POST", "/api/maintenance/identity/assign-role", { token, body: { subject, roleCode, orgUnitCode: `${tag}-school` } });
    assert.equal(r.status, 201, r.text);
  }
  const a = await api(env, "POST", "/api/maintenance/identity/assign-role", { token, body: { subject: admin, roleCode: "MASTER_INSTRUMENT_ADMIN", orgUnitCode: `${tag}-district` } });
  assert.equal(a.status, 201, a.text);
});

test("AUTH-01: shell and instrument routes deny anonymous callers (HTML page for browsers, JSON for APIs)", { skip }, async () => {
  const page = await call("GET", "/", { accept: "text/html,application/xhtml+xml" });
  assert.equal(page.status, 401);
  assert.match(page.response.headers.get("content-type"), /text\/html/);
  assert.match(page.text, /Sign-in required/);
  assert.doesNotMatch(page.text, /<script/i, "error page carries no scripts");
  assert.ok(!page.text.includes("data-api-base"), "no application shell for anonymous users");
  const json = await call("GET", "/");
  assert.equal(json.status, 401);
  assert.equal(json.json.error.code, "UNAUTHENTICATED");
  const model = await call("GET", "/api/instrument/current");
  assert.equal(model.status, 401);
  assert.equal(model.json.error.code, "UNAUTHENTICATED");
  assert.ok(!("model" in model.json));
});

test("users without any capability are forbidden; walk, report, and admin roles may load the instrument", { skip: needToken }, async () => {
  const none = await call("GET", "/api/instrument/current", { subject: nobody });
  assert.equal(none.status, 403, none.text);
  assert.equal(none.json.error.code, "FORBIDDEN");
  assert.ok(!("model" in none.json));
  const nonePage = await call("GET", "/", { subject: nobody, accept: "text/html" });
  assert.equal(nonePage.status, 403);
  assert.match(nonePage.text, /Access denied/);
  for (const subject of [walker, reporter, admin]) {
    const r = await call("GET", "/api/instrument/current", { subject });
    assert.equal(r.status, 200, `${subject}: ${r.text}`);
    assert.equal(r.json.model.format, "icfwalk-render-model/1");
    assert.equal(r.json.version.versionLabel, "2026-09-17 aligned prototype");
    assert.equal(r.json.policies.hiddenDimensionPolicy, "RETAIN_HIDDEN");
    // The instrument contract never carries walk data or database identifiers.
    assert.doesNotMatch(JSON.stringify(r.json.model), /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i);
    assert.ok(!("walks" in r.json));
  }
});

test("shell page is served to signed-in users with a strict CSP and no embedded content", { skip: needToken }, async () => {
  const r = await call("GET", "/", { subject: walker, accept: "text/html" });
  assert.equal(r.status, 200, r.text);
  assert.match(r.response.headers.get("content-type"), /text\/html/);
  const csp = r.response.headers.get("content-security-policy");
  assert.match(csp, /default-src 'self'/);
  assert.match(csp, /script-src 'self'/);
  assert.match(csp, /frame-ancestors 'none'/);
  assert.equal(r.response.headers.get("x-content-type-options"), "nosniff");
  assert.equal(r.response.headers.get("cache-control"), "no-store");
  assert.match(r.text, /data-api-base="\/index\.cfm\/api"/);
  assert.match(r.text, /assets\/js\/app\.js/);
  assert.doesNotMatch(r.text, /Daily Engagement|Workshop Model|learning target/i, "no instrument content is hard-coded in the shell");
  assert.doesNotMatch(r.text, /csrfToken|Shell httpshell/, "no session data in the page");
  const css = await fetch(`${baseUrl(env)}/assets/css/icfwalk.css`);
  assert.equal(css.status, 200);
  const js = await fetch(`${baseUrl(env)}/assets/js/rules.js`);
  assert.equal(js.status, 200);
});

after(async () => {
  if (!up || !token) return;
  const r = await api(env, "POST", "/api/maintenance/identity/cleanup-fixtures", { token, body: { tag } });
  if (r.status !== 200) console.error("fixture cleanup failed", r.status, r.text);
});
