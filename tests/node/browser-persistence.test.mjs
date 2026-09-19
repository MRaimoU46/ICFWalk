// Phase 4 browser-level checks with Playwright (Chromium) against the real persistent store:
// autosave debounce and status transitions (SAVE-01/02), recoverable network failure with an
// idempotent retry (SAVE-03), a two-session stale write and its resolution UI (SAVE-04/05),
// persistence across a page reload (WALK-02/05), stored markup rendered as text (SAVE-08),
// completion validation and completion (WALK-09/10), void of a completed walk (WALK-06/08), and
// axe checks of the new states (A11Y-02/03). Fixtures are created through the maintenance
// endpoints and removed afterwards.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";
import { api, baseUrl, loadRuntimeEnv, root } from "./helpers.mjs";

const require = createRequire(import.meta.url);
const env = loadRuntimeEnv();
const token = env.ICFWALK_MAINTENANCE_TOKEN || "";
const tag = `persist-${Date.now().toString(36)}`;
const subject = `${tag}-walker`;
const shotDir = path.join(root, "docs", "evidence", "screenshots");

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
const skip = !chromium ? "playwright is not installed" : !up ? `application not reachable in development mode at ${baseUrl(env)}` : !token ? "no maintenance token" : false;

let browser, context, page;
const pageErrors = [];
const home = `${baseUrl(env)}/index.cfm/`;

async function apiWalk(id) {
  const r = await fetch(`${baseUrl(env)}/index.cfm/api/walks/${id}`, { headers: { "X-ICFWalk-Dev-Subject": subject } });
  return (await r.json()).walk;
}
async function apiList() {
  const r = await fetch(`${baseUrl(env)}/index.cfm/api/walks`, { headers: { "X-ICFWalk-Dev-Subject": subject } });
  return (await r.json()).walks;
}

const status = (p = page) => p.textContent("#save-status");
const waitStatus = (text, p = page) => p.waitForFunction((t) => document.getElementById("save-status").textContent === t, text, { timeout: 15000 });
const selectDim = (code, value, p = page) => p.selectOption(`[data-dimension-code="${code}"] select`, value);
const clickPill = (itemKey, code, p = page) => p.click(`[data-item-key="${itemKey}"] .pill[data-code="${code}"]`);
const expand = (key, p = page) => p.click(`[data-section-key="${key}"] > h2 > .acc-head, [data-section-key="${key}"] > h3 > .acc-head`);
async function ensureExpanded(key, p = page) {
  const head = p.locator(`[data-section-key="${key}"] > h2 > .acc-head, [data-section-key="${key}"] > h3 > .acc-head`);
  if ((await head.getAttribute("aria-expanded")) !== "true") await head.click();
}

async function newPage(ctx) {
  const p = await ctx.newPage();
  p.on("pageerror", (e) => pageErrors.push(`pageerror: ${e.message}`));
  p.on("console", (m) => { if (m.type() === "error" && !/ERR_|net::|Failed to load resource/.test(m.text())) pageErrors.push(m.text()); });
  return p;
}
async function openHome(p = page) {
  await p.goto(home, { waitUntil: "networkidle" });
  await p.waitForSelector("body[data-ready=true]", { timeout: 20000 });
}
async function startWalk(p = page) {
  await p.click("#new-walk-btn");
  await p.waitForSelector("#view-walk:not([hidden])");
  const walks = await apiList();
  return walks[0].id;
}
async function openCard(id, p = page) {
  await p.click(`.walk-card[data-walk-id="${id}"] .open-btn`);
  await p.waitForSelector("#view-walk:not([hidden])");
}

before(async () => {
  if (skip) return;
  const units = await api(env, "POST", "/api/maintenance/org-units/import", { token, body: { orgUnits: [
    { code: `${tag}-district`, type: "DISTRICT", name: "Persistence fixture district", parentCode: null },
    { code: `${tag}-school`, type: "SCHOOL", name: "Persistence fixture school", parentCode: `${tag}-district` },
  ] } });
  assert.equal(units.status, 200, units.text);
  const u = await api(env, "POST", "/api/maintenance/identity/provision-user", { token, body: { subject, displayName: "Persistence Walker" } });
  assert.ok(u.status === 201 || u.status === 200, u.text);
  const a = await api(env, "POST", "/api/maintenance/identity/assign-role", { token, body: { subject, roleCode: "SCHOOL_WALK_REPORT", orgUnitCode: `${tag}-school` } });
  assert.equal(a.status, 201, a.text);
  browser = await chromium.launch();
  context = await browser.newContext({ extraHTTPHeaders: { "X-ICFWalk-Dev-Subject": subject }, viewport: { width: 1280, height: 900 } });
  page = await newPage(context);
  fs.mkdirSync(shotDir, { recursive: true });
});

after(async () => {
  if (browser) await browser.close();
  if (!skip) {
    const r = await api(env, "POST", "/api/maintenance/identity/cleanup-fixtures", { token, body: { tag } });
    if (r.status !== 200) console.error("fixture cleanup failed", r.status, r.text);
  }
});

test("SAVE-01 / SAVE-02: several changes within 700 ms coalesce into one save; status advances to All changes saved with a new row version", { skip }, async () => {
  await openHome();
  assert.match(await page.textContent("#list-sub"), /saved to the district server/);
  const id = await startWalk();
  const before = await apiWalk(id);
  const puts = [];
  page.on("request", (r) => { if (r.method() === "PUT" && r.url().includes("/api/walks/")) puts.push(r.postDataJSON()); });
  await expand("part2");
  await expand("s1");
  const t0 = Date.now();
  await selectDim("grade", "4");
  await clickPill("comp_s1_q1", "4");
  await clickPill("comp_s1_q2", "2");
  await page.fill('[data-item-key="comp_s1_notes"] textarea', "typed quickly");
  assert.ok(Date.now() - t0 < 700, "edits made within the debounce window");
  assert.equal(await status(), "Unsaved changes");
  assert.equal(puts.length, 0, "no save fired during the burst");
  await waitStatus("All changes saved");
  await page.waitForTimeout(900);
  assert.equal(puts.length, 1, "one debounced save for the burst");
  assert.equal(puts[0].dimensions.grade.selectedValueCode, "4");
  assert.equal(puts[0].responses.comp_s1_notes.textValue, "typed quickly");
  assert.match(puts[0].clientMutationId, /^[0-9A-F-]{36}$/);
  const after = await apiWalk(id);
  assert.notEqual(after.rowVersion, before.rowVersion, "row version advanced");
  assert.equal(after.state.responses.comp_s1_q2.storedCode, "2");
  // A second, separate edit is another single save with a new mutation id.
  await clickPill("comp_s1_q1", "5");
  assert.equal(await status(), "Unsaved changes");
  await waitStatus("All changes saved");
  await page.waitForTimeout(900);
  assert.equal(puts.length, 2);
  assert.notEqual(puts[1].clientMutationId, puts[0].clientMutationId);
  assert.equal(puts[1].rowVersion, after.rowVersion, "the second save uses the committed row version");
  page.removeAllListeners("request");
});

test("WALK-02 / WALK-05 / SAVE-08: the walk survives a reload; markup typed into notes is shown as text and never executes", { skip }, async () => {
  const id = (await apiList())[0].id;
  const markup = '<img src=x onerror="document.body.dataset.xss=\'1\'"> <b>bold</b> & "quotes"';
  await page.fill('[data-item-key="comp_s1_notes"] textarea', markup);
  await waitStatus("All changes saved");
  await openHome();
  const cards = await page.$$eval(".walk-card", (els) => els.map((e) => ({ id: e.dataset.walkId, title: e.querySelector(".title").textContent })));
  assert.equal(cards.length, 1);
  assert.equal(cards[0].id, id);
  assert.equal(cards[0].title, "4");
  await openCard(id);
  assert.equal(await page.inputValue('[data-dimension-code="grade"] select'), "4");
  await expand("part2");
  await expand("s1");
  assert.deepEqual(await page.$$eval('[data-item-key="comp_s1_q1"] .pill[aria-pressed="true"]', (ps) => ps.map((p) => p.dataset.code)), ["5"]);
  assert.equal(await page.inputValue('[data-item-key="comp_s1_notes"] textarea'), markup);
  assert.equal(await page.$$eval("#editor img", (els) => els.length), 0, "no element was injected");
  assert.equal(await page.evaluate(() => document.body.dataset.xss || ""), "");
  assert.equal(await status(), "All changes saved");
  assert.deepEqual(pageErrors, []);
});

test("SAVE-03: a network failure keeps the input on screen with a specific message; Retry saves with the same mutation id", { skip }, async () => {
  const id = (await apiList())[0].id;
  const puts = [];
  await page.route("**/api/walks/*", (route) => {
    if (route.request().method() !== "PUT") return route.continue();
    puts.push(route.request().postDataJSON());
    return puts.length === 1 ? route.abort("connectionreset") : route.continue();
  });
  await page.fill('[data-item-key="comp_s1_notes"] textarea', "saved after a retry");
  await page.waitForFunction(() => /could not reach the server/i.test(document.getElementById("save-status").textContent), null, { timeout: 15000 });
  assert.equal(await page.isVisible("#save-retry"), true, "Retry action is offered");
  assert.equal(await page.inputValue('[data-item-key="comp_s1_notes"] textarea'), "saved after a retry", "input remains on screen");
  assert.notEqual((await apiWalk(id)).state.responses.comp_s1_notes.textValue, "saved after a retry", "nothing reached the server yet");
  await page.click("#save-retry");
  await waitStatus("All changes saved");
  assert.equal(puts.length, 2);
  assert.equal(puts[1].clientMutationId, puts[0].clientMutationId, "the retry reuses the mutation id (idempotent)");
  assert.equal((await apiWalk(id)).state.responses.comp_s1_notes.textValue, "saved after a retry");
  await page.unroute("**/api/walks/*");
  // Server-side rejection also stays visible with the code and keeps the input.
  await page.route("**/api/walks/*", (route) => route.request().method() === "PUT" ? route.fulfill({ status: 500, contentType: "application/json", body: JSON.stringify({ error: { code: "INTERNAL_ERROR", message: "boom" } }) }) : route.continue());
  await page.fill('[data-item-key="comp_s1_notes"] textarea', "after a server error");
  await page.waitForFunction(() => /INTERNAL_ERROR/.test(document.getElementById("save-status").textContent), null, { timeout: 15000 });
  assert.equal(await page.inputValue('[data-item-key="comp_s1_notes"] textarea'), "after a server error");
  await page.unroute("**/api/walks/*");
  await page.click("#save-retry");
  await waitStatus("All changes saved");
  assert.equal((await apiWalk(id)).state.responses.comp_s1_notes.textValue, "after a server error");
});

test("SAVE-04 / SAVE-05: two sessions; the stale session gets a conflict panel, can keep its edits, and the merged save uses the new row version", { skip }, async () => {
  const id = (await apiList())[0].id;
  const contextB = await browser.newContext({ extraHTTPHeaders: { "X-ICFWalk-Dev-Subject": subject }, viewport: { width: 1280, height: 900 } });
  const pageB = await newPage(contextB);
  await openHome(pageB);
  await openCard(id, pageB);
  // A saves first.
  await selectDim("grade", "3");
  await waitStatus("All changes saved");
  const afterA = await apiWalk(id);
  assert.equal(afterA.state.dimensions.grade.selectedValueCode, "3");
  // B, still holding the old row version, changes another field.
  await selectDim("content", "music", pageB);
  await pageB.waitForSelector("#conflict-panel:not([hidden])", { timeout: 15000 });
  assert.match(await status(pageB), /changed elsewhere/);
  assert.equal(await pageB.getAttribute("#conflict-panel", "role"), "alertdialog");
  const items = await pageB.$$eval("#conflict-list li", (els) => els.map((e) => e.textContent));
  assert.equal(items.length, 1, `only B's unsent edit (content) is listed, not the stale grade: ${JSON.stringify(items)}`);
  assert.ok(/Content/i.test(items[0]) && /Yours: Music/.test(items[0]) && /Saved: \(empty\)/.test(items[0]), JSON.stringify(items));
  assert.match(await pageB.textContent("#conflict-summary"), /Your unsent edits \(1\)/);
  assert.equal((await apiWalk(id)).state.dimensions.grade.selectedValueCode, "3", "A's write was not overwritten");
  assert.equal((await apiWalk(id)).state.dimensions.content, undefined);
  // Edits made while the conflict is open are kept locally and not sent.
  await pageB.fill('[data-dimension-code="observer"] input', "Observer B");
  assert.equal(await pageB.isVisible("#conflict-panel"), true);
  await pageB.screenshot({ path: path.join(shotDir, "conflict-panel-desktop.png"), fullPage: false });
  // Keep my edits: content (and the later observer edit) are applied on the server version.
  await pageB.click("#conflict-keep");
  await waitStatus("All changes saved", pageB);
  const merged = await apiWalk(id);
  assert.equal(merged.state.dimensions.grade.selectedValueCode, "3", "server value kept where B had not changed it");
  assert.equal(merged.state.dimensions.content.selectedValueCode, "music", "B's edit preserved");
  assert.equal(merged.state.dimensions.observer.textValue, "Observer B");
  assert.equal(await pageB.isVisible("#conflict-panel"), false);
  assert.equal(await pageB.inputValue('[data-dimension-code="grade"] select'), "3", "B now shows the merged record");
  // The other direction: A is now stale; choosing the saved version discards A's change.
  await selectDim("grade", "5");
  await page.waitForSelector("#conflict-panel:not([hidden])", { timeout: 15000 });
  await page.click("#conflict-reload");
  await waitStatus("All changes saved");
  assert.equal(await page.inputValue('[data-dimension-code="grade"] select'), "3");
  assert.equal(await page.inputValue('[data-dimension-code="content"] select'), "music");
  assert.equal((await apiWalk(id)).state.dimensions.grade.selectedValueCode, "3");
  await contextB.close();
  assert.deepEqual(pageErrors, []);
});

test("WALK-09 / WALK-10 / A11Y-02: completion errors are field-specific and announced; a valid walk completes and is badged in the list", { skip }, async () => {
  const id = (await apiList())[0].id;
  await page.click("#complete-btn");
  await page.waitForSelector("#completion-errors:not([hidden])");
  assert.equal(await page.getAttribute("#completion-errors", "role"), "alert");
  assert.match(await page.textContent("#completion-errors-title"), /8 required responses are missing/);
  const links = await page.$$eval("#completion-error-list button", (els) => els.map((e) => e.textContent));
  assert.equal(links.length, 8);
  assert.ok(links.every((t) => /A response is required/.test(t)));
  assert.equal(await page.$$eval('[data-item-key="p1q1"][class~="has-error"]', (els) => els.length), 1);
  assert.equal(await page.getAttribute('[data-item-key="p1q1"] [role=group]', "aria-invalid"), "true");
  assert.ok(await page.getAttribute('[data-item-key="p1q1"] [role=group]', "aria-describedby"));
  assert.equal(await page.evaluate(() => document.activeElement.closest("#completion-error-list") !== null), true, "focus moves to the error summary");
  assert.equal((await apiWalk(id)).status, "DRAFT", "the draft stays saved");
  // The first error link opens the section and focuses the control.
  await page.click("#completion-error-list button >> nth=0");
  assert.equal(await page.evaluate(() => document.activeElement.closest('[data-item-key="p1q1"]') !== null), true);
  assert.equal(await page.getAttribute('[data-section-key="part1"] .acc-head', "aria-expanded"), "true");
  await page.screenshot({ path: path.join(shotDir, "completion-errors-desktop.png"), fullPage: false });
  // Answer everything required; errors clear as they are answered.
  await clickPill("p1q1", "Partial");
  assert.equal(await page.$$eval("#completion-error-list button", (els) => els.length), 7);
  await clickPill("p1q2", "Retrieval");
  await clickPill("p1q3", "Analysis");
  await clickPill("part1_adopted_pacing", "on");
  await clickPill("part1_adopted_ac1", "3");
  await clickPill("part1_adopted_ac2", "4");
  await clickPill("part1_targettask_tt1", "5");
  await clickPill("part1_targettask_tt2", "2");
  assert.equal(await page.isVisible("#completion-errors"), false);
  await waitStatus("All changes saved");
  await page.click("#complete-btn");
  await page.waitForSelector("#walk-banner:not([hidden])");
  assert.match(await page.textContent("#walk-banner"), /^Completed on /);
  assert.equal(await page.isVisible("#complete-btn"), false);
  const done = await apiWalk(id);
  assert.equal(done.status, "COMPLETED");
  assert.equal(done.revisionCount, 1);
  // Post-completion edits still save (as revisions).
  await ensureExpanded("part2");
  await ensureExpanded("s1");
  await page.fill('[data-item-key="comp_s1_notes"] textarea', "edited after completion");
  await waitStatus("All changes saved");
  assert.equal((await apiWalk(id)).revisionCount, 2);
  await page.click("#back-btn");
  await page.waitForSelector("#view-list:not([hidden])");
  assert.equal(await page.textContent(".walk-card .status-badge"), "Completed");
});

test("WALK-06 / WALK-08: a completed walk is voided with a reason (never deleted); drafts void from the list", { skip }, async () => {
  const id = (await apiList())[0].id;
  await page.click(`.walk-card[data-walk-id="${id}"] .delete-btn`);
  assert.match(await page.textContent(".confirm-row p"), /^Void this completed walk\?/);
  await page.click(".confirm-delete");
  assert.match(await page.textContent(".confirm-row .field-error"), /Enter a reason/);
  assert.equal((await apiWalk(id)).status, "COMPLETED", "no mutation without a reason");
  await page.fill(".void-reason", "Entered twice");
  await page.click(".confirm-delete");
  await page.waitForFunction(() => document.querySelectorAll(".walk-card").length === 0, null, { timeout: 15000 });
  const voided = await apiWalk(id);
  assert.equal(voided.status, "VOIDED", "history is retained, the walk is voided");
  assert.equal(voided.state.responses.p1q1.storedCode, "Partial", "responses remain in the database");
  assert.match(await page.textContent(".empty-state"), /No walks saved yet\./);
});

test("A11Y-03: axe-core finds no serious or critical violations in the conflict panel and completion-error states", { skip }, async () => {
  const axeSource = fs.readFileSync(require.resolve("axe-core/axe.min.js"), "utf8");
  await page.route("**/assets/js/axe.min.js", (route) => route.fulfill({ status: 200, contentType: "application/javascript", body: axeSource }));
  const run = async () => {
    if (!(await page.evaluate(() => Boolean(window.axe)))) await page.addScriptTag({ url: `${baseUrl(env)}/assets/js/axe.min.js` });
    return page.evaluate(async () => {
      const r = await window.axe.run(document, { runOnly: { type: "tag", values: ["wcag2a", "wcag2aa", "wcag21a", "wcag21aa"] } });
      return r.violations.map((v) => ({ id: v.id, impact: v.impact, nodes: v.nodes.length, help: v.help }));
    });
  };
  await startWalk();
  await page.click("#complete-btn");
  await page.waitForSelector("#completion-errors:not([hidden])");
  const errors = (await run()).filter((v) => v.impact === "serious" || v.impact === "critical");
  assert.deepEqual(errors, []);
  // Force the conflict panel through a stale row version.
  const id = (await apiList())[0].id;
  const stale = await fetch(`${baseUrl(env)}/index.cfm/api/walks/${id}`, { headers: { "X-ICFWalk-Dev-Subject": subject } }).then((r) => r.json());
  await page.route("**/api/walks/*", (route) => route.request().method() === "PUT"
    ? route.fulfill({ status: 409, contentType: "application/json", body: JSON.stringify({ error: { code: "STALE_ROW_VERSION", message: "stale", details: { walkId: id, serverRowVersion: stale.walk.rowVersion } } }) })
    : route.continue());
  await selectDim("grade", "6");
  await page.waitForSelector("#conflict-panel:not([hidden])", { timeout: 15000 });
  const conflict = (await run()).filter((v) => v.impact === "serious" || v.impact === "critical");
  assert.deepEqual(conflict, []);
  await page.unroute("**/api/walks/*");
  await page.click("#conflict-reload");
  await waitStatus("All changes saved");
  assert.deepEqual(pageErrors, []);
});

// ---- Phase 0-4 correction: no unsaved local edit may silently disappear -------------------------

test("CORR: a failed save plus Back/List keeps the editor and the unsaved input until an explicit decision", { skip }, async () => {
  await openHome();
  const id = await startWalk();
  // A definitive server rejection: the edit is held on the page only.
  await page.route("**/api/walks/*", (route) => route.request().method() === "PUT"
    ? route.fulfill({ status: 400, contentType: "application/json", body: JSON.stringify({ error: { code: "TEST_REJECTED", message: "rejected" } }) })
    : route.continue());
  await expand("part2");
  await expand("s1");
  await page.fill('[data-item-key="comp_s1_notes"] textarea', "must not disappear");
  await page.waitForFunction(() => /TEST_REJECTED/.test(document.getElementById("save-status").textContent), null, { timeout: 15000 });

  // Back does not leave: the editor and the typed text stay, and a decision is demanded.
  await page.click("#back-btn");
  await page.waitForSelector("#unsaved-panel:not([hidden])", { timeout: 15000 });
  assert.equal(await page.isVisible("#view-walk"), true, "the editor is retained");
  assert.equal(await page.inputValue('[data-item-key="comp_s1_notes"] textarea'), "must not disappear");
  assert.equal((await apiWalk(id)).state.responses.comp_s1_notes?.textValue ?? "", "", "nothing reached the server");

  // Keep editing puts the user back in the editor with the input intact.
  await page.click("#unsaved-stay");
  await page.waitForSelector("#unsaved-panel", { state: "hidden" });
  assert.equal(await page.isVisible("#view-walk"), true);
  assert.equal(await page.inputValue('[data-item-key="comp_s1_notes"] textarea'), "must not disappear");

  // Once the server accepts the save, Back leaves without asking anything.
  await page.unroute("**/api/walks/*");
  await page.click("#save-retry");
  await waitStatus("All changes saved");
  await page.click("#back-btn");
  await page.waitForSelector("#view-list:not([hidden])", { timeout: 15000 });
  assert.equal((await apiWalk(id)).state.responses.comp_s1_notes.textValue, "must not disappear");
});

test("CORR: an unresolved conflict plus Back/List demands an explicit discard before leaving", { skip }, async () => {
  const id = (await apiList())[0].id;
  await openCard(id);
  const server = await apiWalk(id);
  await page.route("**/api/walks/*", (route) => route.request().method() === "PUT"
    ? route.fulfill({ status: 409, contentType: "application/json", body: JSON.stringify({ error: { code: "STALE_ROW_VERSION", message: "stale", details: { walkId: id, serverRowVersion: server.rowVersion } } }) })
    : route.continue());
  await expand("part2");
  await expand("s1");
  await page.fill('[data-item-key="comp_s1_notes"] textarea', "unsent while conflicted");
  await page.waitForSelector("#conflict-panel:not([hidden])", { timeout: 15000 });

  // The My walks button in the header is the same navigation path.
  await page.click("#nav-list-btn");
  await page.waitForSelector("#unsaved-panel:not([hidden])", { timeout: 15000 });
  assert.equal(await page.isVisible("#view-walk"), true, "the editor and the conflict panel are retained");
  assert.equal(await page.inputValue('[data-item-key="comp_s1_notes"] textarea'), "unsent while conflicted");
  await page.click("#unsaved-stay");
  await page.waitForSelector("#unsaved-panel", { state: "hidden" });
  assert.equal(await page.isVisible("#conflict-panel"), true);

  // Discarding is explicit; only then does the list appear, with the server record unchanged.
  await page.click("#nav-list-btn");
  await page.waitForSelector("#unsaved-panel:not([hidden])", { timeout: 15000 });
  await page.click("#unsaved-discard");
  await page.waitForSelector("#view-list:not([hidden])", { timeout: 15000 });
  await page.unroute("**/api/walks/*");
  assert.notEqual((await apiWalk(id)).state.responses.comp_s1_notes?.textValue ?? "", "unsent while conflicted", "the discarded edit never reached the server");
});

test("CORR: beforeunload protects in-flight and queued saves, not only dirty state", { skip }, async () => {
  const id = (await apiList())[0].id;
  await openCard(id);
  await expand("part2");
  await expand("s1");
  const guarded = () => page.evaluate(() => {
    const ev = new Event("beforeunload", { cancelable: true });
    window.dispatchEvent(ev);
    return ev.defaultPrevented;
  });
  assert.equal(await guarded(), false, "a settled editor does not block unload");

  // Dirty and still inside the debounce window.
  await page.fill('[data-item-key="comp_s1_notes"] textarea', "queued edit");
  assert.equal(await guarded(), true, "a queued (debounced) edit blocks unload");
  await waitStatus("All changes saved");
  assert.equal(await guarded(), false);

  // In flight: the request is held open, so app.dirty is already false while the save is pending.
  let release;
  const held = new Promise((resolve) => { release = resolve; });
  await page.route("**/api/walks/*", async (route) => {
    if (route.request().method() !== "PUT") return route.continue();
    await held;
    return route.continue();
  });
  await page.fill('[data-item-key="comp_s1_notes"] textarea', "in flight edit");
  await page.waitForFunction(() => document.getElementById("save-status").textContent === "Saving...", null, { timeout: 15000 });
  assert.equal(await guarded(), true, "an in-flight save blocks unload");
  release();
  await waitStatus("All changes saved");
  await page.unroute("**/api/walks/*");
  assert.equal(await guarded(), false, "a committed save releases the guard");
  assert.deepEqual(pageErrors, []);
});
