// Phase 8 hardening (SEC-06, defect P8-01): the page keeps working after its server session is
// replaced.
//
// Identity is asserted on every request (the production SSO header adapter, and the development
// stub), so when the server no longer holds the browser's session -- after an application restart,
// or after ICFWALK_SESSION_TIMEOUT_MINUTES without a request -- the next request quietly establishes
// a new one. A new session has a new CSRF token. The page read its token once, at load, so from then
// on every state-changing request was refused 403 CSRF_TOKEN_INVALID: an autosave failed, Retry
// sent the same stale token and failed again, and the only way out was a reload that discards the
// edits still on the page.
//
// The session is replaced here the way the browser experiences both causes: its cookie stops naming
// a live session. Clearing the context's cookies does exactly that without restarting the server;
// the real restart, with a save in flight, is tests/ops/restart-during-autosave.mjs.
//
// A refused CSRF check happens before the router reads the request body (P6A-01), so a refused
// request changed nothing and sending it again is safe. Sending it again under someone else's
// identity is not, so the page renews its token only when the new session belongs to the same user.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { api, baseUrl, loadRuntimeEnv, requireApp } from "./helpers.mjs";

const require = createRequire(import.meta.url);
const env = loadRuntimeEnv();
const token = env.ICFWALK_MAINTENANCE_TOKEN || "";
const tag = `p8sess-${Date.now().toString(36)}`;
const subject = `${tag}-walker`;
const otherSubject = `${tag}-colleague`;

let chromium = null;
try { ({ chromium } = require("playwright")); } catch { chromium = null; }

async function reachable() {
  try {
    const r = await fetch(`${baseUrl(env)}/index.cfm/api/health`, { signal: AbortSignal.timeout(10000) });
    if (r.status !== 200) return false;
    const body = await r.json();
    return body.environment === "development" || body.environment === "test";
  } catch { return false; }
}
const up = await reachable();
if (requireApp(env) && (!up || !token || !chromium)) {
  throw new Error(`ICFWALK_REQUIRE_APP is set but the application (development mode), the maintenance token or Playwright is missing at ${baseUrl(env)}`);
}
const skip = !chromium ? "playwright is not installed" : !up ? `application not reachable in development mode at ${baseUrl(env)}` : !token ? "no maintenance token" : false;

let browser;
const pageErrors = [];
const home = `${baseUrl(env)}/index.cfm/`;

async function apiWalk(id, who = subject) {
  const r = await fetch(`${baseUrl(env)}/index.cfm/api/walks/${id}`, { headers: { "X-ICFWalk-Dev-Subject": who } });
  return { status: r.status, walk: r.status === 200 ? (await r.json()).walk : null };
}
async function apiList(who = subject) {
  const r = await fetch(`${baseUrl(env)}/index.cfm/api/walks`, { headers: { "X-ICFWalk-Dev-Subject": who } });
  return (await r.json()).walks;
}

const waitStatus = (p, re) => p.waitForFunction((src) => new RegExp(src).test(document.getElementById("save-status").textContent), re.source, { timeout: 20000 });
const expand = (p, key) => p.click(`[data-section-key="${key}"] > h2 > .acc-head, [data-section-key="${key}"] > h3 > .acc-head`);

async function openEditorOnNewWalk() {
  const context = await browser.newContext({ extraHTTPHeaders: { "X-ICFWalk-Dev-Subject": subject }, viewport: { width: 1280, height: 900 } });
  const page = await context.newPage();
  page.on("pageerror", (e) => pageErrors.push(`pageerror: ${e.message}`));
  await page.goto(home, { waitUntil: "networkidle" });
  await page.waitForSelector("body[data-ready=true]", { timeout: 20000 });
  await page.click("#new-walk-btn");
  await page.waitForSelector("#view-walk:not([hidden])");
  const id = (await apiList())[0].id;
  await expand(page, "part2");
  await expand(page, "s1");
  await page.fill('[data-item-key="comp_s1_notes"] textarea', "saved while the first session was live");
  await waitStatus(page, /^All changes saved$/);
  return { context, page, id };
}

/** Every state-changing request the page sends to a walk route from now on, with its answer. */
function recordWalkMutations(page) {
  const seen = [];
  page.on("response", async (res) => {
    const req = res.request();
    if (req.method() === "GET" || !/\/api\/walks/.test(req.url())) return;
    let code = null;
    try { code = (await res.json())?.error?.code ?? null; } catch { code = null; }
    seen.push({ method: req.method(), status: res.status(), code, body: req.postDataJSON() });
  });
  return seen;
}

before(async () => {
  if (skip) return;
  const units = await api(env, "POST", "/api/maintenance/org-units/import", { token, body: { orgUnits: [
    { code: `${tag}-district`, type: "DISTRICT", name: "Session recovery fixture district", parentCode: null },
    { code: `${tag}-school`, type: "SCHOOL", name: "Session recovery fixture school", parentCode: `${tag}-district` },
  ] } });
  assert.equal(units.status, 200, units.text);
  for (const [who, name] of [[subject, "Session Walker"], [otherSubject, "Session Colleague"]]) {
    const u = await api(env, "POST", "/api/maintenance/identity/provision-user", { token, body: { subject: who, displayName: name } });
    assert.ok(u.status === 201 || u.status === 200, u.text);
    const a = await api(env, "POST", "/api/maintenance/identity/assign-role", { token, body: { subject: who, roleCode: "SCHOOL_WALK_REPORT", orgUnitCode: `${tag}-school` } });
    assert.equal(a.status, 201, a.text);
  }
  browser = await chromium.launch();
});

after(async () => {
  if (browser) await browser.close();
  if (!skip) {
    const r = await api(env, "POST", "/api/maintenance/identity/cleanup-fixtures", { token, body: { tag } });
    if (r.status !== 200) console.error("fixture cleanup failed", r.status, r.text);
  }
});

test("P8-01: an autosave after the server session is replaced is saved, exactly once, for the same person", { skip }, async () => {
  const { context, page, id } = await openEditorOnNewWalk();
  const saved = await apiWalk(id);
  const mutations = recordWalkMutations(page);

  await context.clearCookies();
  await page.fill('[data-item-key="comp_s1_notes"] textarea', "typed after the session was replaced");
  await waitStatus(page, /^(All changes saved|Could not save.*)$/);
  assert.equal(await page.textContent("#save-status"), "All changes saved", "the save succeeds without a reload");

  const after = await apiWalk(id);
  assert.equal(after.walk.state.responses.comp_s1_notes.textValue, "typed after the session was replaced");
  assert.notEqual(after.walk.rowVersion, saved.walk.rowVersion);
  // One refused attempt and the same request once more under the renewed token: the same mutation
  // id and the same body, so the edit is committed once.
  assert.deepEqual(mutations.map((m) => `${m.method} ${m.status} ${m.code ?? ""}`.trim()), ["PUT 403 CSRF_TOKEN_INVALID", "PUT 200"]);
  assert.equal(mutations[1].body.clientMutationId, mutations[0].body.clientMutationId);
  assert.deepEqual(mutations[1].body, mutations[0].body);
  assert.equal(await page.isVisible("#conflict-panel"), false);
  await context.close();
});

test("P8-01: a walk can still be started after the session is replaced", { skip }, async () => {
  const context = await browser.newContext({ extraHTTPHeaders: { "X-ICFWalk-Dev-Subject": subject }, viewport: { width: 1280, height: 900 } });
  const page = await context.newPage();
  await page.goto(home, { waitUntil: "networkidle" });
  await page.waitForSelector("body[data-ready=true]", { timeout: 20000 });
  const before = (await apiList()).length;
  const mutations = recordWalkMutations(page);
  await context.clearCookies();
  await page.click("#new-walk-btn");
  await page.waitForSelector("#view-walk:not([hidden])", { timeout: 20000 });
  assert.equal((await apiList()).length, before + 1, "exactly one walk was created");
  assert.deepEqual(mutations.map((m) => `${m.method} ${m.status}`), ["POST 403", "POST 201"]);
  assert.equal(mutations[1].body.clientMutationId, mutations[0].body.clientMutationId);
  await context.close();
});

test("P8-01: a session that now belongs to someone else is never used to save the page's edits", { skip }, async () => {
  const { context, page, id } = await openEditorOnNewWalk();
  const mutations = recordWalkMutations(page);

  // The browser's sign-in changes hands (a shared computer): the old session is gone and the
  // gateway now asserts a colleague who could edit walks in the same school.
  await context.clearCookies();
  await context.setExtraHTTPHeaders({ "X-ICFWalk-Dev-Subject": otherSubject });
  await page.fill('[data-item-key="comp_s1_notes"] textarea', "must never be saved as the colleague");
  await waitStatus(page, /^Could not save/);

  const status = await page.textContent("#save-status");
  assert.match(status, /SESSION_USER_CHANGED/, status);
  assert.equal(await page.inputValue('[data-item-key="comp_s1_notes"] textarea'), "must never be saved as the colleague", "the edit stays on the page");
  assert.deepEqual(mutations.map((m) => `${m.method} ${m.status} ${m.code ?? ""}`.trim()), ["PUT 403 CSRF_TOKEN_INVALID"], "nothing was sent under the colleague's token");
  const stored = await apiWalk(id);
  assert.equal(stored.walk.state.responses.comp_s1_notes.textValue, "saved while the first session was live");
  await context.close();
});

test("P8-01: no page error in any of the above", { skip }, () => {
  assert.deepEqual(pageErrors, []);
});
