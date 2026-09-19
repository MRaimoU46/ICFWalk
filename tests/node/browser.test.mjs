// Browser-level checks of the Phase 3 shell with Playwright (Chromium): the editor is rendered
// from the served instrument model, conditional behavior works through real DOM interaction,
// the My Walks flow (empty state, new walk, open, delete with confirmation/cancel) behaves as the
// prototype, keyboard operation works, axe-core finds no serious/critical WCAG 2.1 AA issues,
// and screenshots at phone/tablet/desktop widths are written to docs/evidence/screenshots.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";
import { api, baseUrl, loadRuntimeEnv, root } from "./helpers.mjs";

const require = createRequire(import.meta.url);
const env = loadRuntimeEnv();
const token = env.ICFWALK_MAINTENANCE_TOKEN || "";
const tag = `browser-${Date.now().toString(36)}`;
const subject = `${tag}-walker`;
const groupSubject = `${tag}-group-walker`;
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

let browser, context, page, model;
const consoleErrors = [];

before(async () => {
  if (skip) return;
  const units = await api(env, "POST", "/api/maintenance/org-units/import", { token, body: { orgUnits: [
    { code: `${tag}-district`, type: "DISTRICT", name: "Browser fixture district", parentCode: null },
    // The main fixture school carries no School dimension mapping, so the School value stays empty and
    // the Grade options are unfiltered -- which is what the conditional-visibility cases below need.
    { code: `${tag}-school`, type: "SCHOOL", name: "Browser fixture school", parentCode: `${tag}-district` },
    // A second district of mapped schools, one per school group, for the school-driven Grade filter.
    { code: `${tag}-groups`, type: "DISTRICT", name: "Browser fixture group district", parentCode: null },
    { code: `${tag}-elem`, type: "SCHOOL", name: "Browser fixture elementary", parentCode: `${tag}-groups`, schoolValueCode: "bartlett_elementary_school" },
    { code: `${tag}-mid`, type: "SCHOOL", name: "Browser fixture middle", parentCode: `${tag}-groups`, schoolValueCode: "abbott_middle_school" },
    { code: `${tag}-high`, type: "SCHOOL", name: "Browser fixture high", parentCode: `${tag}-groups`, schoolValueCode: "elgin_high_school" },
  ] } });
  assert.equal(units.status, 200, units.text);
  assert.equal(units.json.schoolValuesMapped, 3, units.text);
  const u = await api(env, "POST", "/api/maintenance/identity/provision-user", { token, body: { subject, displayName: "Browser Walker" } });
  assert.ok(u.status === 201 || u.status === 200, u.text);
  // One creatable school so "New walk" starts immediately without the school chooser.
  const a = await api(env, "POST", "/api/maintenance/identity/assign-role", { token, body: { subject, roleCode: "SCHOOL_WALK_REPORT", orgUnitCode: `${tag}-school` } });
  assert.equal(a.status, 201, a.text);
  // A separate identity for the mapped schools, so the main flow keeps its single creatable unit.
  const gu = await api(env, "POST", "/api/maintenance/identity/provision-user", { token, body: { subject: groupSubject, displayName: "Browser Group Walker" } });
  assert.ok(gu.status === 201 || gu.status === 200, gu.text);
  const ga = await api(env, "POST", "/api/maintenance/identity/assign-role", { token, body: { subject: groupSubject, roleCode: "DISTRICT_WALK_REPORT", orgUnitCode: `${tag}-groups`, includeDescendants: true } });
  assert.equal(ga.status, 201, ga.text);
  browser = await chromium.launch();
  context = await browser.newContext({ extraHTTPHeaders: { "X-ICFWalk-Dev-Subject": subject }, viewport: { width: 1280, height: 900 } });
  page = await context.newPage();
  page.on("pageerror", (e) => consoleErrors.push(`pageerror: ${e.message}`));
  page.on("console", (m) => { if (m.type() === "error" && !/ERR_|net::|Failed to load resource/.test(m.text())) consoleErrors.push(m.text()); });
  const r = await fetch(`${baseUrl(env)}/index.cfm/api/instrument/current`, { headers: { "X-ICFWalk-Dev-Subject": subject } });
  model = (await r.json()).model;
  fs.mkdirSync(shotDir, { recursive: true });
});

after(async () => {
  if (browser) await browser.close();
  if (!skip) {
    const r = await api(env, "POST", "/api/maintenance/identity/cleanup-fixtures", { token, body: { tag } });
    if (r.status !== 200) console.error("fixture cleanup failed", r.status, r.text);
  }
});

const visibleSections = () => page.$$eval("[data-section-key]", (els) => els.filter((e) => !e.hidden && !e.closest("[hidden]")).map((e) => e.dataset.sectionKey));
const sectionVisible = (key) => page.$eval(`[data-section-key="${key}"]`, (e) => !e.hidden && !e.closest("[hidden]"));
const dimVisible = (code) => page.$eval(`[data-dimension-code="${code}"]`, (e) => !e.hidden);
const gradeOptions = () => page.$$eval(`[data-dimension-code="grade"] select option`, (os) => os.map((o) => o.value).filter(Boolean));
const pressed = (itemKey) => page.$$eval(`[data-item-key="${itemKey}"] .pill`, (ps) => ps.filter((p) => p.getAttribute("aria-pressed") === "true").map((p) => p.dataset.code));
const itemVisible = (itemKey) => page.$eval(`[data-item-key="${itemKey}"]`, (e) => !e.hidden && !e.closest("[hidden]"));
const selectDim = (code, value) => page.selectOption(`[data-dimension-code="${code}"] select`, value);
const clickPill = (itemKey, code) => page.click(`[data-item-key="${itemKey}"] .pill[data-code="${code}"]`);
const expand = (key) => page.click(`[data-section-key="${key}"] > h2 > .acc-head, [data-section-key="${key}"] > h3 > .acc-head`);
// Phase 4: saves go to the server (700 ms debounce), so status assertions wait for the round trip.
const waitSaved = () => page.waitForFunction(() => document.getElementById("save-status").textContent === "All changes saved", null, { timeout: 15000 });

test("WALK-01 empty My Walks state with the prototype wording and a New walk action", { skip }, async () => {
  await page.goto(`${baseUrl(env)}/index.cfm/`, { waitUntil: "networkidle" });
  await page.waitForSelector("body[data-ready=true]", { timeout: 20000 });
  assert.equal(await page.textContent("#list-heading"), "My walks");
  const empty = await page.textContent(".empty-state");
  assert.match(empty, /No walks saved yet\./);
  assert.match(empty, /Start one with "New walk" above\./);
  assert.equal(await page.textContent("#new-walk-btn"), "+ New walk");
  await page.screenshot({ path: path.join(shotDir, "my-walks-empty-desktop.png"), fullPage: true });
});

test("editor renders every section, item, and option from the served instrument model", { skip }, async () => {
  await page.click("#new-walk-btn");
  await page.waitForSelector("#view-walk:not([hidden])");
  // Every section in the model has a DOM node; conditional ones are hidden by rules.
  const keys = await page.$$eval("[data-section-key]", (els) => els.map((e) => e.dataset.sectionKey));
  const modelKeys = [];
  const walk = (n) => { if (n.sectionKey !== model.root.sectionKey) modelKeys.push(n.sectionKey); n.children.forEach(walk); };
  walk(model.root);
  assert.deepEqual([...keys].sort(), [...modelKeys].sort());
  // Every item appears with its exact prompt from the model (display items in look-for lists).
  const items = [];
  const collect = (n) => { items.push(...n.items); n.children.forEach(collect); };
  collect(model.root);
  const domItems = await page.$$eval("[data-item-key]", (els) => Object.fromEntries(els.map((e) => [e.dataset.itemKey, e.textContent.trim()])));
  for (const it of items) {
    assert.ok(it.itemKey in domItems, `item ${it.itemKey} is rendered`);
    if (it.layout !== "email-draft") assert.ok(domItems[it.itemKey].includes(it.prompt), `prompt for ${it.itemKey} is the model prompt`);
  }
  assert.equal(items.length, 144);
  // Response options are the model's options, in order, with stored codes.
  for (const it of items.filter((i) => i.responseSet)) {
    const codes = await page.$$eval(`[data-item-key="${it.itemKey}"] .pill`, (ps) => ps.map((p) => p.dataset.code));
    assert.deepEqual(codes, it.responseSet.options.map((o) => o.storedCode), `options for ${it.itemKey}`);
  }
  // Placements in authored order with labels from the dimensions.
  const dims = await page.$$eval("[data-dimension-code]", (els) => els.map((e) => e.dataset.dimensionCode));
  assert.deepEqual(dims, ["date", "observer", "school", "grade", "content", "period", "classType", "visitTiming", "topic", "tag"]);
  assert.equal(await page.textContent('[data-dimension-code="visitTiming"] label'), "Visit occurred at the:");
  // Placeholder prompts are shown as the prototype shows them and are flagged for later review.
  assert.equal(await page.$$eval("[data-placeholder=true]", (els) => els.length), 17);
  // Part headers, component numbering, and REQUIRED badge come from the model.
  assert.equal(await page.textContent('[data-section-key="part3"] .acc-title'), "Part 3 · Conditions for Learning");
  assert.equal(await page.textContent('[data-section-key="s1"] .acc-title'), "2.1 · Daily Engagement with Complex Texts");
  assert.equal(await page.textContent('[data-section-key="part1"] .required-badge'), "REQUIRED");
  // The School dimension is server-owned: this walk's SCHOOL org unit has no validated School mapping,
  // so the value is empty, and the control is read-only either way (docs/DATA_CONTRACT.md).
  assert.equal(await page.inputValue('[data-dimension-code="school"] select'), "");
  assert.equal(await page.getAttribute('[data-dimension-code="school"]', "data-locked"), "true");
  assert.equal(await page.isDisabled('[data-dimension-code="school"] select'), true, "the School value is not the client's to set");
  assert.equal(await page.textContent('[data-dimension-code="school"] .field-note'), "Set from the school this walk is recorded at.");
  assert.equal(await page.$$eval('[data-dimension-code="school"] .other-input', (els) => els.length), 0, "no free-text escape hatch on a server-owned dimension");
});

test("COND-01..05 grade choices follow the school of the walk's org unit", { skip }, async () => {
  // The School value is the walk's SCHOOL org unit's mapped value, not a control the user sets, so the
  // grade filter is driven by opening a walk at each school group. One context per identity keeps the
  // main flow's single creatable unit intact.
  const groupContext = await browser.newContext({ extraHTTPHeaders: { "X-ICFWalk-Dev-Subject": groupSubject }, viewport: { width: 1280, height: 900 } });
  const gp = await groupContext.newPage();
  gp.on("pageerror", (e) => consoleErrors.push(`pageerror: ${e.message}`));
  const gradeOptionsOn = () => gp.$$eval(`[data-dimension-code="grade"] select option`, (os) => os.map((o) => o.value).filter(Boolean));
  // The chooser lists units by name, so resolve each fixture code to its org unit id through /api/me.
  const me = await (await fetch(`${baseUrl(env)}/index.cfm/api/me`, { headers: { "X-ICFWalk-Dev-Subject": groupSubject } })).json();
  const unitIdOf = (code) => Object.entries(me.orgUnits).find(([, u]) => u.code === code)?.[0];
  const startAt = async (unitCode, expectedSchoolValue) => {
    await gp.goto(`${baseUrl(env)}/index.cfm/`, { waitUntil: "networkidle" });
    await gp.waitForSelector("body[data-ready=true]", { timeout: 20000 });
    await gp.click("#new-walk-btn");
    await gp.waitForSelector("#new-walk-chooser:not([hidden])", { timeout: 15000 });
    const value = unitIdOf(unitCode);
    assert.ok(value, `the chooser offers ${unitCode}`);
    await gp.selectOption("#chooser-unit", value);
    await gp.click("#chooser-start");
    await gp.waitForSelector("#view-walk:not([hidden])", { timeout: 15000 });
    assert.equal(await gp.inputValue('[data-dimension-code="school"] select'), expectedSchoolValue, unitCode);
    assert.equal(await gp.isDisabled('[data-dimension-code="school"] select'), true);
  };
  try {
    await startAt(`${tag}-elem`, "bartlett_elementary_school");
    assert.deepEqual(await gradeOptionsOn(), ["prek", "k", "1", "2", "3", "4", "5"]);
    await startAt(`${tag}-mid`, "abbott_middle_school");
    assert.deepEqual(await gradeOptionsOn(), ["6", "7", "8"]);
    await startAt(`${tag}-high`, "elgin_high_school");
    assert.deepEqual(await gradeOptionsOn(), ["9", "10", "11", "12"]);
    // COND-05: a grade outside the school's band is not offered at all, and the server refuses one
    // anyway (WalkServiceTest.testCond05And06GradeFilterClearsAndHiddenPeriodIsRetained).
    await gp.selectOption('[data-dimension-code="grade"] select', "10");
    await gp.waitForFunction(() => document.getElementById("save-status").textContent === "All changes saved", null, { timeout: 15000 });
    assert.equal(await gp.inputValue('[data-dimension-code="grade"] select'), "10");
  } finally {
    await gp.close();
    await groupContext.close();
  }
  // The unmapped fixture school leaves the filter unconstrained: every grade is offered.
  assert.equal((await gradeOptions()).length, 14);
});

test("COND-06 Period shows for grades 6-12 only and its value is retained while hidden", { skip }, async () => {
  assert.equal(await dimVisible("period"), false);
  await selectDim("grade", "7");
  assert.equal(await dimVisible("period"), true);
  await selectDim("period", "third");
  await selectDim("grade", "2");
  assert.equal(await dimVisible("period"), false);
  await selectDim("grade", "10");
  assert.equal(await dimVisible("period"), true);
  assert.equal(await page.inputValue('[data-dimension-code="period"] select'), "third", "RETAIN_HIDDEN policy keeps the value");
});

test("COND-07..10 conditional classroom sections and retained hidden answers", { skip }, async () => {
  const conditional = ["prek_k_classroom", "dual_language_classroom", "mac_prep_classroom", "ignite_classroom", "avid_classroom", "esl_classroom", "content_area_look_fors"];
  const only = async (keys, label) => { for (const k of conditional) assert.equal(await sectionVisible(k), keys.includes(k), `${label}: ${k}`); };
  await selectDim("grade", "prek");
  await only(["prek_k_classroom"], "PreK");
  assert.equal(await page.textContent('[data-section-key="prek_k_classroom"] .section-sub'), "Shown automatically because the grade level selected is PreK or K.");
  await clickPill("prek_k_q1", "yes");
  assert.deepEqual(await pressed("prek_k_q1"), ["yes"]);
  await selectDim("grade", "k");
  await only(["prek_k_classroom"], "K");
  await selectDim("grade", "3");
  await only([], "grade 3");
  await selectDim("grade", "prek");
  assert.deepEqual(await pressed("prek_k_q1"), ["yes"], "COND-10: hidden answer reappears");
  await selectDim("grade", "9");
  const byType = { dual_language: "dual_language_classroom", mac: "mac_prep_classroom", prep: "mac_prep_classroom", ignite: "ignite_classroom", avid: "avid_classroom", esl: "esl_classroom" };
  for (const [code, section] of Object.entries(byType)) { await selectDim("classType", code); await only([section], code); }
  await selectDim("classType", "general_education");
  await only([], "general education");
  for (const c of ["art", "music", "cte"]) { await selectDim("content", c); await only(["content_area_look_fors"], c); }
  await selectDim("content", "math");
  await only([], "math");
  await selectDim("content", "music");
  await page.screenshot({ path: path.join(shotDir, "editor-conditional-music-desktop.png"), fullPage: true });
});

test("COND-11..15 skippable components: default No, clear on No, notes kept, counts use answered ratings only", { skip }, async () => {
  await expand("part2");
  for (const c of ["s3", "s4"]) {
    await expand(c);
    assert.deepEqual(await pressed(`comp_${c}_applicable`), ["no"], `${c} defaults to No`);
    assert.equal(await itemVisible(`comp_${c}_q1`), false, `${c} rating rows hidden`);
    assert.equal(await page.textContent(`[data-section-key="${c}"] .acc-count`), "Not part of this lesson");
    assert.equal(await page.isVisible(`[data-item-key="comp_${c}_applicable"] .applic-note`), true);
  }
  await clickPill("comp_s3_applicable", "yes");
  assert.equal(await itemVisible("comp_s3_q1"), true);
  assert.equal(await page.textContent('[data-section-key="s3"] .acc-count'), "0/2 rated");
  await clickPill("comp_s3_q1", "4");
  await page.fill('[data-item-key="comp_s3_notes"] textarea', "retained note");
  assert.equal(await page.textContent('[data-section-key="s3"] .acc-count'), "1/2 rated", "COND-15: one answered, blank never counts as zero");
  await clickPill("comp_s3_applicable", "no");
  assert.equal(await itemVisible("comp_s3_q1"), false);
  assert.equal(await page.textContent('[data-section-key="s3"] .acc-count'), "Not part of this lesson");
  assert.equal(await page.inputValue('[data-item-key="comp_s3_notes"] textarea'), "retained note", "COND-12: notes remain");
  await clickPill("comp_s3_applicable", "yes");
  assert.deepEqual(await pressed("comp_s3_q1"), [], "COND-13: cleared rating does not reappear");
  assert.equal(await page.textContent('[data-section-key="s3"] .acc-count'), "0/2 rated");
  // Non-skippable component counts.
  await expand("s1");
  await clickPill("comp_s1_q2", "5");
  assert.equal(await page.textContent('[data-section-key="s1"] .acc-count'), "1/2 rated");
});

test("COND-14 definition toggles show labels 1-5 and the exact per-question definitions", { skip }, async () => {
  const items = [];
  const collect = (n) => { items.push(...n.items); n.children.forEach(collect); };
  collect(model.root);
  await expand("part1");
  await expand("part3");
  for (const it of items.filter((i) => i.layout === "question" && i.responseSet.hasDefinitions && !["s2", "s5", "s6", "s7"].includes(i.sectionKey || ""))) {
    const toggle = page.locator(`[data-item-key="${it.itemKey}"] .defs-toggle`);
    if (!(await toggle.isVisible())) continue; // inside a collapsed component; covered by the engine tests
    assert.equal(await toggle.textContent(), "What do these mean?");
    await toggle.click();
    assert.equal(await toggle.getAttribute("aria-expanded"), "true");
    assert.equal(await toggle.textContent(), "Hide definitions");
    const rows = await page.$$eval(`[data-item-key="${it.itemKey}"] .defs-row`, (els) => els.map((e) => e.textContent));
    const expected = it.responseSet.options.filter((o) => o.definition).map((o) => `${o.label}: ${o.definition}`);
    assert.deepEqual(rows, expected, `definitions for ${it.itemKey}`);
    await toggle.click();
    assert.equal(await toggle.getAttribute("aria-expanded"), "false");
  }
  // Look-fors come from the DISPLAY_HEADING / DISPLAY_GUIDANCE items.
  const lf = page.locator('[data-section-key="part1_adopted"] .lookfor-toggle');
  await lf.click();
  assert.equal(await lf.textContent(), "Hide Look Fors");
  const headings = await page.$$eval('[data-section-key="part1_adopted"] .lookfor-heading', (els) => els.map((e) => e.textContent));
  assert.deepEqual(headings, ["Student Actions — look for", "Teacher Actions — look for"]);
  assert.equal(await page.$$eval('[data-section-key="part1_adopted"] .lookfor-list li', (els) => els.length), 6);
  await page.screenshot({ path: path.join(shotDir, "editor-expanded-desktop.png"), fullPage: true });
});

test("A11Y-01 keyboard: pills toggle with Enter/Space, accordions with Enter, focus stays visible", { skip }, async () => {
  const pill = page.locator('[data-item-key="conditions_b1"] .pill[data-code="3"]');
  await pill.focus();
  await page.keyboard.press("Enter");
  assert.deepEqual(await pressed("conditions_b1"), ["3"]);
  await page.locator('[data-item-key="conditions_b1"] .pill[data-code="5"]').focus();
  await page.keyboard.press("Space");
  assert.deepEqual(await pressed("conditions_b1"), ["5"]);
  const head = page.locator('[data-section-key="part4"] .acc-head');
  await head.focus();
  await page.keyboard.press("Enter");
  assert.equal(await head.getAttribute("aria-expanded"), "true");
  assert.equal(await page.isVisible('[data-item-key="summary_strengths"] textarea'), true);
  const outline = await page.evaluate(() => { const el = document.activeElement; const cs = getComputedStyle(el); return cs.outlineStyle !== "none" && parseFloat(cs.outlineWidth) > 0; });
  assert.equal(outline, true, "focused control has a visible outline");
  const labelled = await page.$$eval("input, select, textarea", (els) => els.filter((e) => !e.hidden && !e.closest("[hidden]")).every((e) => e.labels?.length > 0 || e.getAttribute("aria-label")));
  assert.equal(labelled, true, "every visible form control has a programmatic label");
  const groups = await page.$$eval(".pillrow", (els) => els.every((e) => e.getAttribute("role") === "group" && e.getAttribute("aria-labelledby")));
  assert.equal(groups, true, "every pill row is a labelled group");
});

test("A11Y-03 axe-core: no serious or critical WCAG 2.1 AA violations in the editor and the list", { skip }, async () => {
  // The shell's CSP allows scripts from this origin only, so axe is served through a same-origin route.
  const axeSource = fs.readFileSync(require.resolve("axe-core/axe.min.js"), "utf8");
  await page.route("**/assets/js/axe.min.js", (route) => route.fulfill({ status: 200, contentType: "application/javascript", body: axeSource }));
  const run = async () => {
    if (!(await page.evaluate(() => Boolean(window.axe)))) await page.addScriptTag({ url: `${baseUrl(env)}/assets/js/axe.min.js` });
    return page.evaluate(async () => {
      const r = await window.axe.run(document, { runOnly: { type: "tag", values: ["wcag2a", "wcag2aa", "wcag21a", "wcag21aa"] } });
      return r.violations.map((v) => ({ id: v.id, impact: v.impact, nodes: v.nodes.length, help: v.help }));
    });
  };
  const editor = await run();
  const serious = editor.filter((v) => v.impact === "serious" || v.impact === "critical");
  assert.deepEqual(serious, [], `editor violations: ${JSON.stringify(editor)}`);
  await page.click("#back-btn");
  await page.waitForSelector("#view-list:not([hidden])");
  const list = await run();
  assert.deepEqual(list.filter((v) => v.impact === "serious" || v.impact === "critical"), [], `list violations: ${JSON.stringify(list)}`);
});

test("My Walks: card shows grade/content, date and relative time; open, delete with confirmation, cancel", { skip }, async () => {
  if (await page.isVisible("#view-walk")) { await page.click("#back-btn"); await page.waitForSelector("#view-list:not([hidden])"); }
  const cards = page.locator(".walk-card");
  assert.equal(await cards.count(), 1, `cards: ${JSON.stringify(await page.$$eval(".walk-card", (els) => els.map((e) => e.textContent.trim())))}`);
  assert.equal(await page.textContent(".walk-card .title"), "9 · Music");
  // The card's School slot is empty: this walk's SCHOOL org unit has no validated School mapping, so
  // the server assigns no School value and the browser cannot invent one.
  assert.match(await page.textContent(".walk-card .meta"), /^just now$/);
  assert.equal(await page.textContent("#save-status"), "All changes saved");
  // Open restores the working state.
  await page.click(".walk-card .open-btn");
  await page.waitForSelector("#view-walk:not([hidden])");
  assert.equal(await page.inputValue('[data-dimension-code="grade"] select'), "9");
  await page.fill('[data-dimension-code="date"] input', "2026-09-17");
  await page.click("#save-btn");
  await waitSaved();
  assert.equal(await page.textContent("#save-status"), "All changes saved");
  await page.click("#nav-list-btn");
  await page.waitForSelector("#view-list:not([hidden])");
  assert.match(await page.textContent(".walk-card .meta"), /^2026-09-17 · just now$/);
  // Second walk sorts first (newest updated).
  await page.click("#new-walk-btn");
  await page.waitForSelector("#view-walk:not([hidden])");
  await page.click("#back-btn");
  await page.waitForSelector("#view-list:not([hidden])");
  const titles = await page.$$eval(".walk-card .title", (els) => els.map((e) => e.textContent));
  assert.deepEqual(titles, ["Untitled walk", "9 · Music"]);
  // WALK-07 cancel, then WALK-06 confirm.
  await page.locator(".walk-card").first().locator(".delete-btn").click();
  assert.equal(await page.textContent(".confirm-row p"), "Delete this walk? This cannot be undone.");
  await page.click(".cancel-delete");
  assert.equal(await page.locator(".walk-card").count(), 2, "cancel keeps the walk");
  await page.locator(".walk-card").first().locator(".delete-btn").click();
  await page.click(".confirm-delete");
  // Phase 4: deletion voids the walk on the server and re-renders the list afterwards.
  await page.waitForFunction(() => document.querySelectorAll(".walk-card").length === 1, null, { timeout: 15000 });
  assert.equal(await page.locator(".walk-card").count(), 1);
  assert.equal(await page.textContent(".walk-card .title"), "9 · Music");
  await page.screenshot({ path: path.join(shotDir, "my-walks-desktop.png"), fullPage: true });
});

test("A11Y-05 responsive: no horizontal overflow at 375, 768, and 1280 px; screenshots captured", { skip }, async () => {
  for (const [w, name] of [[375, "phone"], [768, "tablet"], [1280, "desktop"]]) {
    await page.setViewportSize({ width: w, height: 800 });
    await page.screenshot({ path: path.join(shotDir, `my-walks-${name}.png`), fullPage: true });
    await page.click(".walk-card .open-btn");
    await page.waitForSelector("#view-walk:not([hidden])");
    await expand("part1");
    await expand("part2");
    await expand("s3");
    const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
    assert.ok(overflow <= 1, `no horizontal overflow at ${w}px (${overflow})`);
    await page.screenshot({ path: path.join(shotDir, `editor-${name}.png`), fullPage: true });
    await page.click("#back-btn");
    await page.waitForSelector("#view-list:not([hidden])");
  }
  assert.deepEqual(consoleErrors, [], "no page errors during the browser run");
});
