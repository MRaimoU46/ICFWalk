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
// The application's autosave debounce; the recovery interleavings below are pinned inside it.
const AUTOSAVE_DEBOUNCE = 700;

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

// ---- second correction session: ambiguous lifecycle operations ---------------------------------

/**
 * Lets the request reach the server and then throws the answer away, so the mutation is committed
 * but the browser cannot know it. `commit` chooses how the answer is lost: "transport" drops the
 * connection, "5xx" replaces the real answer with a server error.
 */
function loseAnswerOnce(p, { method, urlPattern, commit = "transport", seen }) {
  let done = false;
  return p.route(urlPattern, async (route) => {
    const request = route.request();
    if (request.method() !== method) return route.continue();
    if (seen) seen.push(request.postDataJSON());
    if (done) return route.continue();
    done = true;
    const response = await route.fetch();          // the server commits here
    if (commit === "transport") return route.abort("connectionreset");
    return route.fulfill({ status: 502, contentType: "application/json", body: JSON.stringify({ error: { code: "UPSTREAM_TIMEOUT", message: "lost", details: { committed: response.status() } } }) });
  });
}

const walkCount = async () => (await apiList()).length;
const answerEverythingRequired = async (p = page) => {
  await ensureExpanded("part1", p);
  for (const [key, code] of [["p1q1", "Partial"], ["p1q2", "Retrieval"], ["p1q3", "Analysis"], ["part1_adopted_pacing", "on"],
    ["part1_adopted_ac1", "3"], ["part1_adopted_ac2", "4"], ["part1_targettask_tt1", "5"], ["part1_targettask_tt2", "2"]]) {
    await clickPill(key, code, p);
  }
  await waitStatus("All changes saved", p);
};

test("CORR2: a CREATE committed but lost is retried with the same id and body, and yields exactly one walk", { skip }, async () => {
  await openHome();
  const before = await walkCount();
  const posts = [];
  await loseAnswerOnce(page, { method: "POST", urlPattern: "**/api/walks", commit: "transport", seen: posts });
  await page.click("#new-walk-btn");
  await page.waitForFunction(() => /did not finish|could not be reached/i.test(document.getElementById("app-message").textContent), null, { timeout: 15000 });
  assert.equal(await page.isVisible("#view-list"), true, "the list is retained; no walk was opened");
  assert.equal(await walkCount(), before + 1, "the server did commit the create");

  // The pending operation is unfinished work, so a reload is guarded.
  assert.equal(await page.evaluate(() => { const ev = new Event("beforeunload", { cancelable: true }); window.dispatchEvent(ev); return ev.defaultPrevented; }),
    true, "an ambiguous create cannot be silently abandoned by a reload");

  // The retry reuses the operation record: same id, same body. It opens the committed walk.
  await page.click("#new-walk-btn");
  await page.waitForSelector("#view-walk:not([hidden])", { timeout: 15000 });
  await page.unroute("**/api/walks");
  assert.equal(posts.length, 2);
  assert.equal(posts[1].clientMutationId, posts[0].clientMutationId, "the retry reuses the mutation id");
  assert.deepEqual(posts[1], posts[0], "and the exact same semantic body");
  assert.equal(await walkCount(), before + 1, "exactly one walk exists");
  assert.equal(await page.evaluate(() => { const ev = new Event("beforeunload", { cancelable: true }); window.dispatchEvent(ev); return ev.defaultPrevented; }),
    false, "the settled operation releases the guard");
});

test("CORR2: a COMPLETE committed but answered 5xx is retried with the same id, and never reused across walks", { skip }, async () => {
  const completedId = (await apiList())[0].id;
  await answerEverythingRequired();
  const posts = [];
  await loseAnswerOnce(page, { method: "POST", urlPattern: "**/api/walks/*/complete", commit: "5xx", seen: posts });
  await page.click("#complete-btn");
  await page.waitForFunction(() => /did not finish/i.test(document.getElementById("app-message").textContent), null, { timeout: 15000 });
  assert.equal((await apiWalk(completedId)).status, "COMPLETED", "the server did commit the completion");
  assert.equal((await apiWalk(completedId)).revisionCount, 1);

  // Leaving the editor while the completion is unresolved demands an explicit decision.
  await page.click("#back-btn");
  await page.waitForSelector("#unsaved-panel:not([hidden])", { timeout: 15000 });
  assert.match(await page.textContent("#unsaved-summary"), /did not finish/i);
  await page.click("#unsaved-stay");
  await page.waitForSelector("#unsaved-panel", { state: "hidden" });

  // The retry reuses the same id and replays; exactly one revision exists.
  await page.click("#complete-btn");
  await page.waitForSelector("#walk-banner:not([hidden])", { timeout: 15000 });
  await page.unroute("**/api/walks/*/complete");
  assert.equal(posts.length, 2);
  assert.equal(posts[1].clientMutationId, posts[0].clientMutationId, "the completion retry reuses its mutation id");
  assert.equal(posts[1].rowVersion, posts[0].rowVersion, "and the row version it was issued against");
  const done = await apiWalk(completedId);
  assert.equal(done.status, "COMPLETED");
  assert.equal(done.revisionCount, 1, "exactly one completion revision");

  // A different walk's completion gets its own operation id, never the one above.
  await page.click("#back-btn");
  await page.waitForSelector("#view-list:not([hidden])", { timeout: 15000 });
  const second = await startWalk();
  await answerEverythingRequired();
  const secondPosts = [];
  await page.route("**/api/walks/*/complete", (route) => { secondPosts.push(route.request().postDataJSON()); return route.continue(); });
  await page.click("#complete-btn");
  await page.waitForSelector("#walk-banner:not([hidden])", { timeout: 15000 });
  await page.unroute("**/api/walks/*/complete");
  assert.equal(secondPosts.length, 1);
  assert.notEqual(secondPosts[0].clientMutationId, posts[0].clientMutationId, "a COMPLETE id is never reused across walks");
  assert.equal((await apiWalk(second)).status, "COMPLETED");
  assert.equal((await apiWalk(completedId)).status, "COMPLETED");
});

test("CORR2: a VOID committed but lost is retried from its record, not from the edited input", { skip }, async () => {
  await page.click("#back-btn").catch(() => {});
  await openHome();
  const id = (await apiList()).find((w) => w.status === "COMPLETED").id;
  const posts = [];
  await loseAnswerOnce(page, { method: "POST", urlPattern: "**/api/walks/*/void", commit: "transport", seen: posts });
  await page.click(`.walk-card[data-walk-id="${id}"] .delete-btn`);
  await page.fill(".void-reason", "Recorded in error");
  await page.click(".confirm-delete");
  await page.waitForFunction(() => /could not be reached|did not finish/i.test(document.querySelector(".confirm-row .field-error")?.textContent ?? ""), null, { timeout: 15000 });
  assert.equal((await apiWalk(id)).status, "VOIDED", "the server did commit the void");

  // The reason is owned by the operation record now, so the field cannot be rewritten into the retry.
  assert.equal(await page.getAttribute(".void-reason", "readonly"), "", "the reason field is frozen while the void is unresolved");
  await page.evaluate(() => { const el = document.querySelector(".void-reason"); el.readOnly = false; el.value = "Reason edited after the failure"; el.dispatchEvent(new Event("input", { bubbles: true })); });
  assert.equal(await page.evaluate(() => { const ev = new Event("beforeunload", { cancelable: true }); window.dispatchEvent(ev); return ev.defaultPrevented; }),
    true, "an ambiguous void cannot be silently abandoned by a reload");

  await page.click(".confirm-delete");
  await page.waitForFunction((walkId) => !document.querySelector(`.walk-card[data-walk-id="${walkId}"]`), id, { timeout: 15000 });
  await page.unroute("**/api/walks/*/void");
  assert.equal(posts.length, 2);
  assert.equal(posts[1].clientMutationId, posts[0].clientMutationId, "the void retry reuses its mutation id");
  assert.equal(posts[1].reason, "Recorded in error", "and the reason it was issued with, not the edited field");
  assert.equal(posts[1].rowVersion, posts[0].rowVersion);
  assert.equal((await apiWalk(id)).status, "VOIDED");
  assert.equal(await page.evaluate(() => { const ev = new Event("beforeunload", { cancelable: true }); window.dispatchEvent(ev); return ev.defaultPrevented; }),
    false, "the settled void releases the guard");
});

test("CORR2: a SAVE committed but lost, retried after another session saved, becomes a conflict rather than a silent overwrite", { skip }, async () => {
  await openHome();
  const id = await startWalk();
  await expand("part2");
  await expand("s1");
  await waitStatus("All changes saved");

  // Session A's save commits; the answer is lost, so A keeps its record and its local text.
  const puts = [];
  await loseAnswerOnce(page, { method: "PUT", urlPattern: "**/api/walks/*", commit: "transport", seen: puts });
  await page.fill('[data-item-key="comp_s1_notes"] textarea', "session A text");
  await page.waitForFunction(() => /could not reach the server|did not finish/i.test(document.getElementById("save-status").textContent), null, { timeout: 15000 });
  assert.equal((await apiWalk(id)).state.responses.comp_s1_notes.textValue, "session A text", "the server did commit A's save");
  const afterA = (await apiWalk(id)).rowVersion;

  // Session B saves a different change on top of it.
  const contextB = await browser.newContext({ extraHTTPHeaders: { "X-ICFWalk-Dev-Subject": subject }, viewport: { width: 1280, height: 900 } });
  const pageB = await newPage(contextB);
  await openHome(pageB);
  await openCard(id, pageB);
  await expand("part2", pageB);
  await expand("s1", pageB);
  await pageB.fill('[data-item-key="comp_s1_notes"] textarea', "session B text");
  await waitStatus("All changes saved", pageB);
  const afterB = (await apiWalk(id)).rowVersion;
  assert.notEqual(afterB, afterA);

  // Session A retries. The server refuses to hand its stale state a newer token, so A reconciles.
  await page.click("#save-retry");
  await page.waitForSelector("#conflict-panel:not([hidden])", { timeout: 15000 });
  await page.unroute("**/api/walks/*");
  assert.equal(puts.length, 2);
  assert.equal(puts[1].clientMutationId, puts[0].clientMutationId, "the retry was the same mutation");
  assert.equal(puts[1].rowVersion, puts[0].rowVersion);
  assert.equal((await apiWalk(id)).state.responses.comp_s1_notes.textValue, "session B text", "session B's change stands");
  assert.equal((await apiWalk(id)).rowVersion, afterB, "and nothing advanced the row version");

  // Reloading the saved version is a clean reconciliation; A never overwrote B.
  await page.click("#conflict-reload");
  await page.waitForSelector("#conflict-panel", { state: "hidden", timeout: 15000 });
  assert.equal(await page.inputValue('[data-item-key="comp_s1_notes"] textarea'), "session B text");
  assert.equal((await apiWalk(id)).rowVersion, afterB);
  await pageB.close();
  await contextB.close();
  assert.deepEqual(pageErrors, []);
});

// ---- third correction session: sent operations survive ambiguity -------------------------------

/**
 * Holds the first matching request open until `release()` is called, then lets it reach the server
 * (so the mutation really commits) and throws the answer away. That is the interleaving the browser
 * used to lose: the edit arrives while the request is on the wire, before any answer exists.
 */
function holdThenLoseFirst(p, { method, urlPattern, commit = "transport", seen }) {
  let release;
  const gate = new Promise((resolve) => { release = resolve; });
  let taken = false;
  const routed = p.route(urlPattern, async (route) => {
    const request = route.request();
    if (request.method() !== method) return route.continue();
    if (seen) seen.push(request.postDataJSON());
    if (taken) return route.continue();
    taken = true;
    await gate;
    const response = await route.fetch();          // the server commits here
    if (commit === "transport") return route.abort("connectionreset");
    return route.fulfill({ status: 503, contentType: "application/json", body: JSON.stringify({ error: { code: "UPSTREAM_UNAVAILABLE", message: "lost", details: { committed: response.status() } } }) });
  });
  return routed.then(() => release);
}

/** The part of a save request the server fingerprints: the body without its wall-clock stamp. */
const semanticBody = (put) => ({ walkId: put.walkId, versionId: put.versionId, dimensions: put.dimensions, responses: put.responses });
const guarded = (p = page) => p.evaluate(() => { const ev = new Event("beforeunload", { cancelable: true }); window.dispatchEvent(ev); return ev.defaultPrevented; });
const notes = '[data-item-key="comp_s1_notes"] textarea';

/**
 * The residual defect: an editor change during an in-flight save deleted the operation record whose
 * request was already on the wire. When that request's answer was then lost, nothing was left to
 * retry -- the committed save was never confirmed, and the queued newer state went out under a
 * brand-new mutation id against a row version the server had already moved past.
 *
 * Both halves are asserted here: the original request is retried first, byte for byte, and only
 * after it resolves definitively does the newer state go out under a new id.
 */
for (const [label, commit] of [["a lost response", "transport"], ["an HTTP 5xx", "5xx"]]) {
  test(`CORR3: editing during an in-flight SAVE keeps that save's record; ${label} retries it first, then the queued edit under a new id`, { skip }, async () => {
    await openHome();
    const id = await startWalk();
    await expand("part2");
    await expand("s1");
    await waitStatus("All changes saved");
    const startedAt = (await apiWalk(id)).rowVersion;

    const puts = [];
    const release = await holdThenLoseFirst(page, { method: "PUT", urlPattern: "**/api/walks/*", commit, seen: puts });

    // The first save goes out and is held on the wire.
    await page.fill(notes, "in-flight text");
    await page.waitForFunction(() => document.getElementById("save-status").textContent === "Saving...", null, { timeout: 15000 });

    // The edit that used to delete the in-flight record. Nothing local may be dropped, and the
    // request already on the wire must still be the browser's to resolve.
    await page.fill(notes, "edited while in flight");
    assert.equal(await guarded(), true, "an in-flight save plus a newer edit is unfinished work");

    release();
    // The held save committed, its answer was lost, and the retry goes out automatically because a
    // newer edit is waiting behind it. Wait for either outcome so the wrong one is an assertion
    // rather than a timeout: dropping the in-flight record sends the queued state under a new id
    // against a row version its own committed save already moved past, which is a conflict.
    await page.waitForFunction(() => document.getElementById("save-status").textContent === "All changes saved"
      || !document.getElementById("conflict-panel").hidden, null, { timeout: 20000 });
    assert.equal(await page.isVisible("#conflict-panel"), false,
      "retrying the original request first settles it, so the queued edit never collides with the browser's own committed save");
    await waitStatus("All changes saved");
    await page.unroute("**/api/walks/*");

    assert.equal(puts.length, 3, "the held save, its exact retry, then the queued edit");
    assert.equal(puts[1].clientMutationId, puts[0].clientMutationId, "the retry reuses the original mutation id");
    assert.equal(puts[1].rowVersion, puts[0].rowVersion, "and the row version it was issued against");
    assert.deepEqual(semanticBody(puts[1]), semanticBody(puts[0]), "and the exact frozen semantic body");
    assert.equal(puts[0].responses.comp_s1_notes.textValue, "in-flight text");
    assert.equal(puts[0].rowVersion, startedAt);

    assert.notEqual(puts[2].clientMutationId, puts[0].clientMutationId, "the queued newer state gets its own id");
    assert.equal(puts[2].responses.comp_s1_notes.textValue, "edited while in flight", "and carries the newer state");
    assert.notEqual(puts[2].rowVersion, puts[0].rowVersion, "issued against the row version the retry settled on");

    // Both edits are accounted for: nothing was dropped and nothing was written twice.
    const server = await apiWalk(id);
    assert.equal(server.state.responses.comp_s1_notes.textValue, "edited while in flight");
    assert.equal(await page.inputValue(notes), "edited while in flight");
    assert.equal(await guarded(), false, "everything settled, so the unload guard is released");
    assert.equal(await page.isVisible("#pending-ops"), false, "and nothing is left unresolved");
    assert.deepEqual(pageErrors, []);
  });
}

/**
 * An ambiguous COMPLETE has to stay resolvable after the walk is reloaded from server state. The
 * reload is the ordinary one: the completion committed, so this session's row version is stale, its
 * next save conflicts, and reconciling reloads the walk -- which now reads COMPLETED, so the
 * Complete walk button that started the operation is gone. The record must not be stranded behind
 * it, blocking unload with nothing left to click.
 */
test("CORR3: an ambiguous COMPLETE stays resolvable after the walk is reloaded from server state", { skip }, async () => {
  await openHome();
  const id = await startWalk();
  await answerEverythingRequired();

  const posts = [];
  await loseAnswerOnce(page, { method: "POST", urlPattern: "**/api/walks/*/complete", commit: "5xx", seen: posts });
  await page.click("#complete-btn");
  await page.waitForFunction(() => /did not finish/i.test(document.getElementById("app-message").textContent), null, { timeout: 15000 });
  assert.equal((await apiWalk(id)).status, "COMPLETED", "the server did commit the completion");
  assert.equal((await apiWalk(id)).revisionCount, 1);
  await page.waitForSelector("#pending-ops:not([hidden])", { timeout: 15000 });

  // This session still holds the pre-completion row version, so its next save conflicts, and
  // reconciling reloads the walk as the server holds it.
  await expand("part2");
  await expand("s1");
  await page.fill(notes, "after the ambiguous completion");
  await page.waitForSelector("#conflict-panel:not([hidden])", { timeout: 15000 });
  await page.click("#conflict-reload");
  await page.waitForSelector("#conflict-panel", { state: "hidden", timeout: 15000 });

  assert.equal(await page.isVisible("#complete-btn"), false, "the control that started it is gone: the walk reads COMPLETED");
  assert.equal(await guarded(), true, "and the operation still blocks unload");
  assert.equal(await page.isVisible("#pending-ops"), true, "so the retry has to live somewhere that survived the reload");
  assert.equal(await page.getAttribute("#pending-ops .pending-op", "data-op-action"), "COMPLETE");

  // The route stays installed so the retry is recorded; only the first answer was ever lost.
  await page.click("#pending-ops .pending-op-retry");
  await page.waitForSelector("#pending-ops", { state: "hidden", timeout: 15000 });
  await page.unroute("**/api/walks/*/complete");
  assert.equal(posts.length, 2);
  assert.equal(posts[1].clientMutationId, posts[0].clientMutationId, "the retry reuses the completion's mutation id");
  assert.equal(posts[1].rowVersion, posts[0].rowVersion);
  const done = await apiWalk(id);
  assert.equal(done.status, "COMPLETED");
  assert.equal(done.revisionCount, 1, "and the completion happened exactly once");
  assert.equal(await guarded(), false, "the resolved operation releases the guard");
  assert.deepEqual(pageErrors, []);
});

/**
 * An ambiguous VOID is started from a confirmation row inside a list card. Navigating into a walk
 * and back re-renders the list and destroys that row, which used to leave the record with no retry
 * anywhere and a permanent unload guard -- on a view where the voided walk is not even listed.
 */
test("CORR3: an ambiguous VOID stays resolvable after navigation destroys the row that started it", { skip }, async () => {
  await openHome();
  const other = await startWalk();
  await page.click("#back-btn");
  await page.waitForSelector("#view-list:not([hidden])", { timeout: 15000 });
  const target = (await apiList()).find((w) => w.status === "DRAFT" && w.id !== other).id;

  const posts = [];
  await loseAnswerOnce(page, { method: "POST", urlPattern: "**/api/walks/*/void", commit: "transport", seen: posts });
  await page.click(`.walk-card[data-walk-id="${target}"] .delete-btn`);
  await page.click(".confirm-delete");
  await page.waitForFunction(() => /could not be reached|did not finish/i.test(document.querySelector(".confirm-row .field-error")?.textContent ?? ""), null, { timeout: 15000 });
  assert.equal((await apiWalk(target)).status, "VOIDED", "the server did commit the void");
  await page.waitForSelector("#pending-ops:not([hidden])", { timeout: 15000 });

  // Navigate into another walk and back: the list re-renders and the confirmation row is gone.
  await openCard(other);
  await page.click("#back-btn");
  await page.waitForSelector("#view-list:not([hidden])", { timeout: 15000 });
  assert.equal(await page.locator(".confirm-row").count(), 0, "the row that held the retry is gone");
  assert.equal(await page.locator(`.walk-card[data-walk-id="${target}"]`).count(), 0, "and the voided walk is not listed");
  assert.equal(await guarded(), true, "the unresolved void still blocks unload");
  assert.equal(await page.isVisible("#pending-ops"), true, "so it is still offered somewhere reachable");
  assert.equal(await page.getAttribute("#pending-ops .pending-op", "data-op-action"), "VOID");

  // The route stays installed so the retry is recorded; only the first answer was ever lost.
  await page.click("#pending-ops .pending-op-retry");
  await page.waitForSelector("#pending-ops", { state: "hidden", timeout: 15000 });
  await page.unroute("**/api/walks/*/void");
  assert.equal(posts.length, 2);
  assert.equal(posts[1].clientMutationId, posts[0].clientMutationId, "the retry reuses the void's mutation id");
  assert.equal(posts[1].rowVersion, posts[0].rowVersion);
  assert.equal((await apiWalk(target)).status, "VOIDED", "voided exactly once");
  assert.equal(await page.isVisible("#view-list"), true, "and the user is left on a usable view");
  assert.equal(await guarded(), false, "the resolved operation releases the guard");
  assert.deepEqual(pageErrors, []);
});

// ---- fourth correction session: recovery never discards newer work, and never re-enters ---------

/**
 * Records every matching request and holds the first one at the browser boundary until `release()`
 * is called, then lets it reach the server and answer normally. Unlike holdThenLoseFirst this keeps
 * the answer, so it is the barrier for interleavings where a request is genuinely still on the wire
 * while something else happens.
 */
function holdFirst(p, { method, urlPattern, seen }) {
  let release;
  const gate = new Promise((resolve) => { release = resolve; });
  let taken = false;
  const routed = p.route(urlPattern, async (route) => {
    const request = route.request();
    if (request.method() !== method) return route.continue();
    if (seen) seen.push(request.postDataJSON());
    if (taken) return route.continue();
    taken = true;
    await gate;
    return route.continue();
  });
  return routed.then(() => release);
}

/**
 * Waits for state the harness itself holds (requests the route handlers have recorded). The page's
 * own status text changes synchronously before the matching request is created, so "Saving..." is
 * not by itself proof that anything has reached the wire; this is.
 */
async function until(predicate, what, timeout = 15000) {
  const deadline = Date.now() + timeout;
  while (!predicate()) {
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
}

/**
 * Types into the notes field and activates the recovery Retry control in the same browser task, so
 * the retry is guaranteed to land inside the 700 ms autosave debounce: the edit is dirty, its save
 * is scheduled, and nothing carrying it has left the browser yet. That is the exact window the
 * defect lived in, and a wall-clock race would not pin it down.
 */
const editThenRetry = (text, p = page) => p.evaluate((value) => {
  const area = document.querySelector('[data-item-key="comp_s1_notes"] textarea');
  area.value = value;
  area.dispatchEvent(new Event("input", { bubbles: true }));
  const dispatched = performance.now();
  document.querySelector("#pending-ops .pending-op-retry").click();
  return performance.now() - dispatched;
}, text);

/** The recovery bar's current shape, as the user sees it. */
const recoveryBar = (p = page) => p.evaluate(() => {
  const box = document.getElementById("pending-ops");
  if (!box || box.hidden) return { visible: false, ops: [] };
  return {
    visible: true,
    ops: [...box.querySelectorAll(".pending-op")].map((li) => ({
      action: li.dataset.opAction,
      status: li.dataset.opStatus,
      retryDisabled: li.querySelector(".pending-op-retry").disabled,
      discardDisabled: li.querySelector(".pending-op-discard").disabled,
    })),
  };
});

/**
 * DEFECT 1. Resolving an ambiguous COMPLETE called refreshAfterResolvedOp, which re-opened the same
 * walk, and openWalk cancels the scheduled save, replaces the editor state with the server copy and
 * clears the dirty flag. A change typed after the completion went ambiguous therefore disappeared
 * the moment the user pressed Retry -- inside the 700 ms before its own autosave had been
 * dispatched, so nothing carrying it had ever left the browser and the server never saw it either.
 */
test("CORR4: retrying an ambiguous COMPLETE keeps a newer editor change that autosave has not dispatched", { skip }, async () => {
  await openHome();
  const id = await startWalk();
  await answerEverythingRequired();
  await expand("part2");
  await expand("s1");

  const completes = [];
  await loseAnswerOnce(page, { method: "POST", urlPattern: "**/api/walks/*/complete", commit: "5xx", seen: completes });
  await page.click("#complete-btn");
  await page.waitForSelector("#pending-ops:not([hidden])", { timeout: 15000 });
  assert.equal((await apiWalk(id)).status, "COMPLETED", "the server did commit the completion");
  const committedAt = (await apiWalk(id)).rowVersion;

  const puts = [];
  page.on("request", (r) => { if (r.method() === "PUT" && r.url().includes("/api/walks/")) puts.push(r.postDataJSON()); });

  // The newer editor change, and the Retry, in one browser task: dirty, scheduled, not dispatched.
  const elapsed = await editThenRetry("typed while the completion was unresolved");
  assert.ok(elapsed < AUTOSAVE_DEBOUNCE, `retry landed ${elapsed}ms after the edit, inside the debounce window`);
  assert.equal(puts.length, 0, "no save carrying the newer edit had left the browser");

  await page.waitForSelector("#pending-ops", { state: "hidden", timeout: 15000 });
  assert.equal(completes.length, 2, "the completion was replayed under its own record");
  assert.equal(completes[1].clientMutationId, completes[0].clientMutationId);

  // The edit survived recovery, on screen and on its way to the server.
  assert.equal(await page.inputValue(notes), "typed while the completion was unresolved",
    "recovery did not replace the editor state");
  await waitStatus("All changes saved");
  await page.waitForTimeout(900);
  await page.unroute("**/api/walks/*/complete");
  page.removeAllListeners("request");

  assert.equal(puts.length, 1, "the scheduled autosave was never cancelled, and ran exactly once");
  assert.equal(puts[0].responses.comp_s1_notes.textValue, "typed while the completion was unresolved");
  assert.equal(puts[0].rowVersion, committedAt,
    "and went out against the row version the resolved completion committed, so it did not collide with it");

  const server = await apiWalk(id);
  assert.equal(server.state.responses.comp_s1_notes.textValue, "typed while the completion was unresolved",
    "the newer edit reached the server");
  assert.equal(server.status, "COMPLETED");
  assert.equal(await page.isVisible("#conflict-panel"), false, "and needed no conflict to get there");
  assert.equal(await guarded(), false, "everything settled");
  assert.deepEqual(await recoveryBar(), { visible: false, ops: [] });
  assert.deepEqual(pageErrors, []);
});

/**
 * DEFECT 1, second half. A SAVE whose answer arrived after the editor had moved on returned early
 * from `app.current !== walk` before settling its record, so the operation stayed IN_FLIGHT for
 * good: unfinished work the unload guard sees, on an operation the recovery bar never lists (it
 * offers what is unresolved, and IN_FLIGHT means a request is still on the wire). Recovery re-opening
 * the walk was what moved the editor underneath it.
 */
test("CORR4: an ambiguous COMPLETE resolved while a SAVE is on the wire strands neither operation", { skip }, async () => {
  await openHome();
  const id = await startWalk();
  await answerEverythingRequired();
  await expand("part2");
  await expand("s1");

  const completes = [];
  await loseAnswerOnce(page, { method: "POST", urlPattern: "**/api/walks/*/complete", commit: "5xx", seen: completes });
  await page.click("#complete-btn");
  await page.waitForSelector("#pending-ops:not([hidden])", { timeout: 15000 });
  assert.equal((await apiWalk(id)).status, "COMPLETED");

  // A save is put on the wire and held there: it has left the browser and has no answer.
  const puts = [];
  const releaseSave = await holdFirst(page, { method: "PUT", urlPattern: "**/api/walks/*", seen: puts });
  await page.fill(notes, "saved while the completion was unresolved");
  await page.waitForFunction(() => document.getElementById("save-status").textContent === "Saving...", null, { timeout: 15000 });
  await until(() => puts.length === 1, "the save to reach the wire");
  assert.equal(await guarded(), true);

  // Resolve the completion underneath it.
  await page.click("#pending-ops .pending-op-retry");
  await page.waitForFunction(() => !document.querySelector('#pending-ops .pending-op[data-op-action="COMPLETE"]'), null, { timeout: 15000 });
  assert.equal(completes.length, 2, "the completion replayed");
  assert.equal(await page.inputValue(notes), "saved while the completion was unresolved",
    "and did not replace the editor state behind the in-flight save");

  // Release the save. It was issued against the pre-completion row version, so the server refuses
  // it -- a definitive answer, which must settle the record wherever the editor ended up.
  releaseSave();
  await page.waitForSelector("#conflict-panel:not([hidden])", { timeout: 20000 });
  await page.unroute("**/api/walks/*");
  await page.unroute("**/api/walks/*/complete");

  // The save is resolvable: the conflict panel holds the unsent edit and offers the decision.
  assert.equal(await page.isEnabled("#conflict-keep"), true, "the unsent edit is offered, not discarded");
  await page.click("#conflict-keep");
  await waitStatus("All changes saved");
  assert.equal((await apiWalk(id)).state.responses.comp_s1_notes.textValue, "saved while the completion was unresolved",
    "and it reached the server");

  assert.equal(await guarded(), false, "no operation is left blocking unload");
  assert.deepEqual(await recoveryBar(), { visible: false, ops: [] }, "and nothing is left unresolved with no control");
  assert.deepEqual(pageErrors, []);
});

/**
 * DEFECT 1, across walks. Resolving an ambiguous CREATE opened the newly created walk
 * unconditionally, so it switched the editor away from whatever the user was working in -- taking
 * the scheduled save and the dirty state with it.
 */
test("CORR4: retrying an ambiguous CREATE never switches the editor away from a dirty walk", { skip }, async () => {
  await openHome();
  const host = await startWalk();
  await expand("part2");
  await expand("s1");
  await page.click("#back-btn");
  await page.waitForSelector("#view-list:not([hidden])", { timeout: 15000 });

  const before = await walkCount();
  const posts = [];
  await loseAnswerOnce(page, { method: "POST", urlPattern: "**/api/walks", commit: "transport", seen: posts });
  await page.click("#new-walk-btn");
  await page.waitForSelector("#pending-ops:not([hidden])", { timeout: 15000 });
  assert.equal(await walkCount(), before + 1, "the server did commit the create");

  // Work in a different walk while the create is unresolved.
  await openCard(host);
  await ensureExpanded("part2");
  await ensureExpanded("s1");
  const puts = [];
  page.on("request", (r) => { if (r.method() === "PUT" && r.url().includes("/api/walks/")) puts.push(r.postDataJSON()); });

  const elapsed = await editThenRetry("dirty work in another walk");
  assert.ok(elapsed < AUTOSAVE_DEBOUNCE, `retry landed ${elapsed}ms after the edit, inside the debounce window`);
  assert.equal(puts.length, 0, "no save carrying the edit had left the browser");

  await page.waitForSelector("#pending-ops", { state: "hidden", timeout: 15000 });
  assert.equal(posts.length, 2, "the create replayed under its own record");
  assert.equal(posts[1].clientMutationId, posts[0].clientMutationId);
  assert.equal(await walkCount(), before + 1, "and created exactly one walk");

  assert.equal(await page.inputValue(notes), "dirty work in another walk", "the editor was not replaced");
  await waitStatus("All changes saved");
  await page.waitForTimeout(900);
  await page.unroute("**/api/walks");
  page.removeAllListeners("request");
  assert.equal(puts.length, 1, "the scheduled autosave survived recovery and ran once");
  assert.equal((await apiWalk(host)).state.responses.comp_s1_notes.textValue, "dirty work in another walk",
    "and the edit reached the walk it belonged to");
  assert.equal(await guarded(), false);
  assert.deepEqual(await recoveryBar(), { visible: false, ops: [] });
  assert.deepEqual(pageErrors, []);
});

/** DEFECT 1: the same, with the other walk's save genuinely on the wire rather than scheduled. */
test("CORR4: retrying an ambiguous CREATE while another walk's SAVE is on the wire strands neither", { skip }, async () => {
  await openHome();
  const host = await startWalk();
  await expand("part2");
  await expand("s1");
  await page.click("#back-btn");
  await page.waitForSelector("#view-list:not([hidden])", { timeout: 15000 });

  const before = await walkCount();
  const posts = [];
  await loseAnswerOnce(page, { method: "POST", urlPattern: "**/api/walks", commit: "transport", seen: posts });
  await page.click("#new-walk-btn");
  await page.waitForSelector("#pending-ops:not([hidden])", { timeout: 15000 });
  assert.equal(await walkCount(), before + 1);

  await openCard(host);
  await ensureExpanded("part2");
  await ensureExpanded("s1");
  const puts = [];
  const releaseSave = await holdFirst(page, { method: "PUT", urlPattern: "**/api/walks/*", seen: puts });
  await page.fill(notes, "on the wire during create recovery");
  await page.waitForFunction(() => document.getElementById("save-status").textContent === "Saving...", null, { timeout: 15000 });
  await until(() => puts.length === 1, "the save to reach the wire");

  await page.click("#pending-ops .pending-op-retry");
  await page.waitForFunction(() => !document.querySelector('#pending-ops .pending-op[data-op-action="CREATE"]'), null, { timeout: 15000 });
  assert.equal(posts.length, 2);
  assert.equal(await walkCount(), before + 1, "exactly one walk was created");
  assert.equal(await page.inputValue(notes), "on the wire during create recovery", "the editor was not switched away");

  releaseSave();
  await waitStatus("All changes saved");
  await page.unroute("**/api/walks/*");
  await page.unroute("**/api/walks");
  assert.equal((await apiWalk(host)).state.responses.comp_s1_notes.textValue, "on the wire during create recovery",
    "the save settled against the walk it belonged to");
  assert.equal(await guarded(), false, "and neither operation is left blocking unload");
  assert.deepEqual(await recoveryBar(), { visible: false, ops: [] });
  assert.deepEqual(pageErrors, []);
});

/**
 * DEFECT 2. An ambiguous operation stayed AMBIGUOUS for the whole of its retry round trip, so the
 * recovery bar kept offering Retry and a second activation dispatched the same mutation id again.
 * The server recognises the replay, so the database was never at risk, but the client lifecycle was
 * wrong and the two answers raced each other through the refresh on the way back.
 */
for (const shape of [
  {
    action: "CREATE",
    label: "CREATE",
    method: "POST",
    urlPattern: "**/api/walks",
    async provoke() {
      await openHome();
      await page.click("#new-walk-btn");
    },
  },
  {
    action: "COMPLETE",
    label: "COMPLETE",
    method: "POST",
    urlPattern: "**/api/walks/*/complete",
    async provoke() {
      await openHome();
      await startWalk();
      await answerEverythingRequired();
      await page.click("#complete-btn");
    },
  },
  {
    action: "VOID",
    label: "VOID",
    method: "POST",
    urlPattern: "**/api/walks/*/void",
    async provoke() {
      await openHome();
      const id = await startWalk();
      await page.click("#back-btn");
      await page.waitForSelector("#view-list:not([hidden])", { timeout: 15000 });
      await page.click(`.walk-card[data-walk-id="${id}"] .delete-btn`);
      await page.click(".confirm-delete");
    },
  },
]) {
  test(`CORR4: activating Retry twice on an ambiguous ${shape.label} dispatches one request and offers no second Retry`, { skip }, async () => {
    await loseAnswerOnce(page, { method: shape.method, urlPattern: shape.urlPattern, commit: "transport" });
    await shape.provoke();
    await page.waitForSelector("#pending-ops:not([hidden])", { timeout: 15000 });
    assert.equal(await page.getAttribute("#pending-ops .pending-op", "data-op-action"), shape.action);
    assert.deepEqual(await recoveryBar(), {
      visible: true,
      ops: [{ action: shape.action, status: "AMBIGUOUS", retryDisabled: false, discardDisabled: false }],
    }, "the recovery controls are live while the operation waits for the user");
    await page.unroute(shape.urlPattern);

    // The retry is held on the wire, and Retry is activated twice in one browser task.
    const sent = [];
    const release = await holdFirst(page, { method: shape.method, urlPattern: shape.urlPattern, seen: sent });
    await page.evaluate(() => {
      const button = document.querySelector("#pending-ops .pending-op-retry");
      button.click();
      button.click();
    });
    await page.waitForFunction(() => document.querySelector("#pending-ops .pending-op")?.dataset.opStatus === "IN_FLIGHT", null, { timeout: 15000 });
    await until(() => sent.length >= 1, "the retry to reach the wire");

    assert.equal(sent.length, 1, "exactly one request carries the mutation id while the retry is in flight");
    assert.deepEqual(await recoveryBar(), {
      visible: true,
      ops: [{ action: shape.action, status: "IN_FLIGHT", retryDisabled: true, discardDisabled: true }],
    }, "and the recovery controls are disabled until it comes back");

    // A third activation while IN_FLIGHT is refused by the lifecycle, not only by the control.
    await page.evaluate(() => {
      const button = document.querySelector("#pending-ops .pending-op-retry");
      button.disabled = false;
      button.click();
    });
    await page.waitForTimeout(250);
    assert.equal(sent.length, 1, "an operation whose request is in flight cannot be dispatched again");

    release();
    await page.waitForSelector("#pending-ops", { state: "hidden", timeout: 20000 });
    await page.unroute(shape.urlPattern);
    assert.equal(sent.length, 1, "and the resolved operation sent exactly one retry in total");
    assert.equal(await guarded(), false, "the settled operation releases the guard");
    assert.deepEqual(pageErrors, []);
  });
}

/**
 * DEFECT 2, restoring the controls: an ambiguous outcome for the retry itself has to put the
 * operation back where the user can act on it, rather than leaving it IN_FLIGHT with no control.
 */
test("CORR4: a retry that is itself ambiguous returns the operation to AMBIGUOUS with live controls", { skip }, async () => {
  await openHome();
  let calls = 0;
  await page.route("**/api/walks", async (route) => {
    if (route.request().method() !== "POST") return route.continue();
    calls += 1;
    if (calls > 2) return route.continue();
    const response = await route.fetch();          // the server commits here
    return route.fulfill({ status: 503, contentType: "application/json", body: JSON.stringify({ error: { code: "UPSTREAM_UNAVAILABLE", message: "lost", details: { committed: response.status() } } }) });
  });
  const before = await walkCount();
  await page.click("#new-walk-btn");
  await page.waitForSelector("#pending-ops:not([hidden])", { timeout: 15000 });

  await page.click("#pending-ops .pending-op-retry");
  await page.waitForFunction(() => /still did not finish/i.test(document.getElementById("app-message").textContent), null, { timeout: 15000 });
  assert.deepEqual(await recoveryBar(), {
    visible: true,
    ops: [{ action: "CREATE", status: "AMBIGUOUS", retryDisabled: false, discardDisabled: false }],
  }, "the operation is offered again, not stuck IN_FLIGHT");

  await page.click("#pending-ops .pending-op-retry");
  await page.waitForSelector("#pending-ops", { state: "hidden", timeout: 20000 });
  await page.unroute("**/api/walks");
  assert.equal(calls, 3, "two ambiguous attempts and one that resolved");
  assert.equal(await walkCount(), before + 1, "replayed, never duplicated");
  assert.equal(await guarded(), false);
  assert.deepEqual(pageErrors, []);
});

/**
 * DEFECT 1, VOID equivalence. A resolved void leaves the editor view, which would drop whatever is
 * on screen. The walk is gone, so those changes can never be saved to it -- but discarding them is
 * the user's decision to make, not the app's.
 *
 * The void here is lost *before* it reaches the server, which is the only way this interleaving is
 * reachable: a void that already committed makes the walk read only, so no newer editor work can
 * exist on it. The browser cannot tell the two apart, which is exactly why the record is ambiguous.
 */
test("CORR4: a resolved VOID never leaves a dirty editor without an explicit decision", { skip }, async () => {
  await openHome();
  const id = await startWalk();
  await expand("part2");
  await expand("s1");
  await page.click("#back-btn");
  await page.waitForSelector("#view-list:not([hidden])", { timeout: 15000 });

  const posts = [];
  let dropped = false;
  await page.route("**/api/walks/*/void", async (route) => {
    if (route.request().method() !== "POST") return route.continue();
    posts.push(route.request().postDataJSON());
    if (dropped) return route.continue();
    dropped = true;
    return route.abort("connectionreset");          // never reaches the server
  });
  await page.click(`.walk-card[data-walk-id="${id}"] .delete-btn`);
  await page.click(".confirm-delete");
  await page.waitForSelector("#pending-ops:not([hidden])", { timeout: 15000 });
  assert.equal((await apiWalk(id)).status, "DRAFT", "this void never reached the server");

  // The user opens the walk the unresolved void is aimed at, and types into it.
  await openCard(id);
  await ensureExpanded("part2");
  await ensureExpanded("s1");
  const elapsed = await editThenRetry("typed into a walk that was being voided");
  assert.ok(elapsed < AUTOSAVE_DEBOUNCE, `retry landed ${elapsed}ms after the edit, inside the debounce window`);

  // Recovery asks before it takes the editor away.
  await page.waitForSelector("#unsaved-panel:not([hidden])", { timeout: 15000 });
  assert.match(await page.textContent("#unsaved-summary"), /removed/i);
  assert.equal((await apiWalk(id)).status, "VOIDED", "the retry did commit the void");
  assert.equal(await page.inputValue(notes), "typed into a walk that was being voided",
    "and the text is still on screen while the question is open");

  // Staying keeps it on screen rather than discarding it silently.
  await page.click("#unsaved-stay");
  await page.waitForSelector("#unsaved-panel", { state: "hidden", timeout: 15000 });
  assert.equal(await page.isVisible("#view-walk"), true, "the user was not moved off their work");
  assert.equal(await page.inputValue(notes), "typed into a walk that was being voided");
  assert.match(await page.textContent("#app-message"), /removed/i);
  assert.equal(await guarded(), true, "and the work is still guarded, so nothing drops it on the way out");

  // The explicit decision is what ends it: the server refuses the save on a voided walk, which is
  // the definitive answer that asks again.
  await page.click("#back-btn");
  await page.waitForSelector("#unsaved-panel:not([hidden])", { timeout: 20000 });
  await page.click("#unsaved-discard");
  await page.waitForSelector("#view-list:not([hidden])", { timeout: 15000 });
  await page.unroute("**/api/walks/*/void");
  assert.equal(posts.length, 2, "the void replayed under its own record");
  assert.equal(posts[1].clientMutationId, posts[0].clientMutationId);
  assert.equal(posts[1].rowVersion, posts[0].rowVersion);
  assert.equal((await apiWalk(id)).status, "VOIDED", "voided exactly once");
  assert.equal(await guarded(), false, "and nothing is left blocking unload");
  assert.deepEqual(await recoveryBar(), { visible: false, ops: [] });
  assert.deepEqual(pageErrors, []);
});
