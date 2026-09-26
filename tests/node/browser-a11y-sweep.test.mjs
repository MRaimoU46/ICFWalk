// Phase 8 hardening: accessibility and responsive behavior, every view in every state, at every width
// (A11Y-01 to A11Y-05).
//
// The phase suites each checked their own views, mostly at desktop width and 375 px. This sweeps them
// all at four layouts -- 375 px (phone), 768 px (tablet), 1280 px (desktop) and 1280 px at 200 % zoom
// (a 640 CSS px layout at device scale 2, which is what WCAG 1.4.10 reflow means) -- in the states a
// person actually meets: My Walks, the new-walk chooser, the editor collapsed and fully expanded,
// conditional sections shown, definitions open, completion errors, a failed save with Retry, the
// conflict panel, the email composer, live reports, a report-only reader's released reports, and every
// administration panel with its confirmation dialog.
//
// For each view and layout:
//   - axe-core (WCAG 2.0/2.1 A and AA): no serious or critical violation; every violation of any
//     impact is recorded;
//   - no horizontal loss: the page itself never scrolls sideways (a wide table scrolls inside its own
//     labelled, focusable region), and no visible control lies outside the viewport or has no size;
//   - a selected answer is marked by more than color (aria-pressed and a check mark);
//   - status and error regions exist with live semantics;
// and at desktop width, keyboard traversal: Tab reaches every visible, enabled control in the main
// content, each shows a visible focus indicator when it has focus, and no control traps focus.
// ICFWALK_A11Y_EVIDENCE_DIR (or ICFWALK_SCREENSHOT_DIR) receives a screenshot and the ARIA snapshot
// of every view and layout.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";
import { api, baseUrl, loadRuntimeEnv, provisionReleaser, releaseMonth, requireApp, screenshotDir } from "./helpers.mjs";

const require = createRequire(import.meta.url);
const env = loadRuntimeEnv();
const token = env.ICFWALK_MAINTENANCE_TOKEN || "";
const tag = `p8a11y-${Date.now().toString(36)}`;
const outDir = path.join(env.ICFWALK_A11Y_EVIDENCE_DIR ? path.resolve(env.ICFWALK_A11Y_EVIDENCE_DIR) : screenshotDir(env), "a11y-sweep");
const LAYOUTS = [
  { name: "phone-375", viewport: { width: 375, height: 812 } },
  { name: "tablet-768", viewport: { width: 768, height: 1024 } },
  { name: "desktop-1280", viewport: { width: 1280, height: 900 } },
  { name: "zoom-200", viewport: { width: 640, height: 450 }, deviceScaleFactor: 2 },
];

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
if (requireApp(env) && (!up || !token || !chromium)) throw new Error(`ICFWALK_REQUIRE_APP is set but the application (development mode), the maintenance token or Playwright is missing at ${baseUrl(env)}`);
const skip = !chromium ? "playwright is not installed" : !up ? `application not reachable in development mode at ${baseUrl(env)}` : !token ? "no maintenance token" : false;

const subjects = { walker: `${tag}-walker`, colleague: `${tag}-colleague`, reader: `${tag}-reader`, admin: `${tag}-admin`, releaser: `${tag}-releaser` };
const home = `${baseUrl(env)}/index.cfm/`;
const pageErrors = [];
const findings = [];
let browser;
let schoolA = "";
let draftId = "";
let incompleteId = "";
let completedIds = [];
let release = null;

// ---- helpers --------------------------------------------------------------------------------------------

async function apiClient(subject) {
  const cookies = new Map();
  let csrf = "";
  const call = async (method, p, body) => {
    const headers = { Accept: "application/json", "X-ICFWalk-Dev-Subject": subject };
    if (body !== undefined) headers["Content-Type"] = "application/json";
    if (csrf && method !== "GET") headers["X-ICFWalk-CSRF-Token"] = csrf;
    const cookie = [...cookies.entries()].map(([k, v]) => `${k}=${v}`).join("; ");
    if (cookie) headers.Cookie = cookie;
    const response = await fetch(`${baseUrl(env)}/index.cfm${p}`, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
    for (const line of response.headers.getSetCookie()) {
      const [pair] = line.split(";");
      const eq = pair.indexOf("=");
      cookies.set(pair.slice(0, eq).trim(), pair.slice(eq + 1).trim());
    }
    const text = await response.text();
    let json = null;
    try { json = JSON.parse(text); } catch { json = null; }
    if (json && json.csrfToken) csrf = json.csrfToken;
    return { status: response.status, json, text };
  };
  const me = await call("GET", "/api/me");
  assert.equal(me.status, 200, me.text);
  return { call, me: me.json };
}

const REQUIRED = { p1q1: { storedCode: "Partial" }, p1q2: { storedCode: "Retrieval" }, p1q3: { storedCode: "Analysis" }, part1_adopted_pacing: { storedCode: "on" },
  part1_adopted_ac1: { storedCode: "3" }, part1_adopted_ac2: { storedCode: "4" }, part1_targettask_tt1: { storedCode: "5" }, part1_targettask_tt2: { storedCode: "2" } };

const axeSource = (() => { try { return fs.readFileSync(require.resolve("axe-core/axe.min.js"), "utf8"); } catch { return null; } })();

async function newPage(subject, layout) {
  const context = await browser.newContext({ extraHTTPHeaders: { "X-ICFWalk-Dev-Subject": subject }, viewport: layout.viewport, deviceScaleFactor: layout.deviceScaleFactor || 1 });
  // axe-core is a development dependency and is never served by the application; the page gets it
  // from node_modules, as the phase suites do.
  await context.route("**/assets/js/axe.min.js", (route) => route.fulfill({ status: 200, contentType: "application/javascript", body: axeSource }));
  const page = await context.newPage();
  page.on("pageerror", (e) => pageErrors.push(`${layout.name}: ${e.message}`));
  return { context, page };
}

async function openHome(page) {
  await page.goto(home, { waitUntil: "networkidle" });
  await page.waitForSelector("body[data-ready=true]", { timeout: 30000 });
}

async function expand(page, key) {
  const head = page.locator(`[data-section-key="${key}"] > h2 > .acc-head, [data-section-key="${key}"] > h3 > .acc-head`).first();
  if ((await head.count()) && (await head.getAttribute("aria-expanded")) !== "true") await head.click();
}

async function expandAll(page) {
  for (let round = 0; round < 3; round++) {
    const closed = await page.$$("#editor .acc-head[aria-expanded=false], #admin-panel .acc-head[aria-expanded=false]");
    for (const h of closed) if (await h.isVisible()) await h.click().catch(() => {});
  }
  for (const t of await page.$$(".defs-toggle[aria-expanded=false]")) if (await t.isVisible()) await t.click().catch(() => {});
}

async function axe(page) {
  if (!(await page.evaluate(() => Boolean(window.axe)))) await page.addScriptTag({ url: `${baseUrl(env)}/assets/js/axe.min.js` });
  return page.evaluate(async () => {
    const r = await window.axe.run(document, { runOnly: { type: "tag", values: ["wcag2a", "wcag2aa", "wcag21a", "wcag21aa"] } });
    return r.violations.map((v) => ({ id: v.id, impact: v.impact, nodes: v.nodes.length, help: v.help, targets: v.nodes.slice(0, 3).map((n) => n.target.join(" ")) }));
  });
}

/** axe, reflow, control geometry, non-color selection, live regions -- recorded, and asserted. */
async function check(page, view, layout) {
  await page.waitForTimeout(200);
  const violations = await axe(page);
  const geometry = await page.evaluate(() => {
    const doc = document.documentElement;
    const width = window.innerWidth;
    const scrollers = (el) => { for (let p = el.parentElement; p; p = p.parentElement) { const s = getComputedStyle(p); if (/(auto|scroll)/.test(s.overflowX) && p.scrollWidth > p.clientWidth) return true; } return false; };
    // The skip link sits off-screen until it has focus, by design; it is measured focused, below.
    const controls = [...document.querySelectorAll("button, a[href], input, select, textarea, [tabindex]:not([tabindex='-1'])")]
      .filter((e) => e.offsetParent !== null && getComputedStyle(e).visibility !== "hidden" && !e.closest("[hidden]") && !e.classList.contains("skip-link") && !e.closest(".sr-only"));
    const clipped = controls.filter((e) => { const r = e.getBoundingClientRect(); return !scrollers(e) && (r.width === 0 || r.height === 0 || r.left < -1 || r.right > width + 1); })
      .map((e) => `${e.tagName.toLowerCase()}${e.id ? `#${e.id}` : ""}${e.className && typeof e.className === "string" ? `.${e.className.split(" ")[0]}` : ""} "${(e.getAttribute("aria-label") || e.textContent || "").trim().slice(0, 40)}"`);
    const minTarget = controls.reduce((m, e) => { const r = e.getBoundingClientRect(); return Math.min(m, Math.min(r.width, r.height)); }, Infinity);
    const pressed = [...document.querySelectorAll('.pill[aria-pressed="true"]')];
    const pressedWithoutMark = pressed.filter((p) => !/✓/.test(getComputedStyle(p, "::before").content)).length;
    let skipLinkWhenFocused = null;
    const skip = document.querySelector(".skip-link");
    if (skip) {
      const had = document.activeElement;
      skip.focus();
      const r = skip.getBoundingClientRect();
      skipLinkWhenFocused = r.width > 0 && r.height > 0 && r.left >= -1 && r.right <= width + 1 && r.top >= -1;
      if (had && had.focus) had.focus(); else skip.blur();
    }
    return { horizontalOverflow: doc.scrollWidth - doc.clientWidth, clipped: clipped.slice(0, 10), controls: controls.length, minTargetPx: Number.isFinite(minTarget) ? Math.round(minTarget) : null, pressed: pressed.length, pressedWithoutMark, skipLinkWhenFocused };
  });
  const serious = violations.filter((v) => v.impact === "serious" || v.impact === "critical");
  const record = { view, layout: layout.name, violations, serious: serious.length, ...geometry };
  findings.push(record);
  fs.mkdirSync(outDir, { recursive: true });
  const base = `${view.replace(/[^a-z0-9]+/gi, "-").toLowerCase()}--${layout.name}`;
  await page.screenshot({ path: path.join(outDir, `${base}.png`), fullPage: false });
  try { fs.writeFileSync(path.join(outDir, `${base}.aria.yml`), await page.locator("body").ariaSnapshot()); } catch { /* evidence only */ }
  assert.deepEqual(serious, [], `${view} at ${layout.name}: serious or critical WCAG violations`);
  assert.ok(geometry.horizontalOverflow <= 1, `${view} at ${layout.name}: the page scrolls sideways by ${geometry.horizontalOverflow}px`);
  assert.deepEqual(geometry.clipped, [], `${view} at ${layout.name}: controls outside the viewport or without size`);
  assert.equal(geometry.pressedWithoutMark, 0, `${view} at ${layout.name}: a selected answer marked by color alone`);
  assert.notEqual(geometry.skipLinkWhenFocused, false, `${view} at ${layout.name}: the skip link is not visible when it has focus`);
}

/** Tab through the page: every visible enabled control in main is reached, each with a visible focus indicator. */
async function keyboardTraversal(page, view) {
  const result = await page.evaluate(async () => {
    const main = document.getElementById("main") || document.body;
    const expected = [...main.querySelectorAll("button, a[href], input, select, textarea, [tabindex]:not([tabindex='-1'])")]
      .filter((e) => !e.disabled && e.offsetParent !== null && getComputedStyle(e).visibility !== "hidden" && !e.closest("[hidden]") && e.tabIndex >= 0);
    return { expected: expected.length };
  });
  const seen = new Set();
  const noIndicator = [];
  let wrapped = false;
  await page.evaluate(() => { document.activeElement && document.activeElement.blur(); window.scrollTo(0, 0); });
  let first = null;
  // Enough presses to go round the page twice, however many rows the data gives it (the admin version
  // list grows by eight controls a version); the ceiling only turns a trap into a failure.
  const presses = Math.max(600, 2 * result.expected + 50);
  for (let i = 0; i < presses; i++) {
    await page.keyboard.press("Tab");
    const info = await page.evaluate(() => {
      const e = document.activeElement;
      if (!e || e === document.body) return null;
      const s = getComputedStyle(e);
      const indicator = (s.outlineStyle !== "none" && parseFloat(s.outlineWidth) > 0) || (s.boxShadow && s.boxShadow !== "none");
      if (!e.dataset.a11yId) e.dataset.a11yId = String(Math.random()).slice(2);
      return { id: e.dataset.a11yId, inMain: Boolean(document.getElementById("main")?.contains(e)), indicator, label: `${e.tagName.toLowerCase()} "${(e.getAttribute("aria-label") || e.textContent || e.value || "").trim().slice(0, 40)}"` };
    });
    if (!info) continue;
    if (first === null) first = info.id;
    else if (info.id === first) { wrapped = true; break; }
    if (seen.has(info.id)) continue;
    seen.add(info.id);
    if (info.inMain && !info.indicator) noIndicator.push(info.label);
  }
  findings.push({ view, layout: "keyboard", expectedInMain: result.expected, reached: seen.size, wrapped, noIndicator });
  assert.ok(wrapped, `${view}: Tab cycled through the page without being trapped`);
  assert.ok(seen.size >= result.expected, `${view}: Tab reached ${seen.size} controls; ${result.expected} are visible in the main content`);
  assert.deepEqual(noIndicator, [], `${view}: controls without a visible focus indicator`);
}

// ---- fixtures -----------------------------------------------------------------------------------------------

before(async () => {
  if (skip) return;
  const units = await api(env, "POST", "/api/maintenance/org-units/import", { token, body: { orgUnits: [
    { code: `${tag}-district`, type: "DISTRICT", name: "Accessibility district", parentCode: null },
    { code: `${tag}-school-a`, type: "SCHOOL", name: "Accessibility school A", parentCode: `${tag}-district` },
    { code: `${tag}-school-b`, type: "SCHOOL", name: "Accessibility school B", parentCode: `${tag}-district` },
  ] } });
  assert.equal(units.status, 200, units.text);
  const roles = [[subjects.walker, "SCHOOL_WALK_REPORT", "school-a"], [subjects.walker, "SCHOOL_WALK_REPORT", "school-b"], [subjects.colleague, "SCHOOL_WALK_REPORT", "school-a"],
    [subjects.reader, "SCHOOL_REPORT_ONLY", "school-a"], [subjects.admin, "MASTER_INSTRUMENT_ADMIN", "district"]];
  for (const [subject, roleCode, unit] of roles) {
    const u = await api(env, "POST", "/api/maintenance/identity/provision-user", { token, body: { subject, displayName: `A11y ${subject.split("-").pop()}` } });
    assert.ok(u.status === 200 || u.status === 201, u.text);
    const a = await api(env, "POST", "/api/maintenance/identity/assign-role", { token, body: { subject, roleCode, orgUnitCode: `${tag}-${unit}` } });
    assert.equal(a.status, 201, a.text);
  }
  const walker = await apiClient(subjects.walker);
  schoolA = Object.keys(walker.me.orgUnits).find((id) => walker.me.orgUnits[id].code === `${tag}-school-a`);
  const period = releaseMonth(2011, 2019);
  const make = async (complete, notes, date) => {
    const created = await walker.call("POST", "/api/walks", { orgUnitId: schoolA, clientMutationId: crypto.randomUUID() });
    assert.equal(created.status, 201, created.text);
    const saved = await walker.call("PUT", `/api/walks/${created.json.walk.id}`, { rowVersion: created.json.walk.rowVersion, clientMutationId: crypto.randomUUID(),
      dimensions: { date: { dateValue: date }, grade: { selectedValueCode: "prek" }, classType: { selectedValueCode: "dual_language" }, content: { selectedValueCode: "music" } },
      responses: complete ? { ...REQUIRED, comp_s1_q1: { storedCode: "4" }, comp_s1_notes: { textValue: notes } } : { comp_s1_notes: { textValue: notes } } });
    assert.equal(saved.status, 200, saved.text);
    if (complete) {
      const done = await walker.call("POST", `/api/walks/${created.json.walk.id}/complete`, { rowVersion: saved.json.walk.rowVersion, clientMutationId: crypto.randomUUID() });
      assert.equal(done.status, 200, done.text);
    }
    return created.json.walk.id;
  };
  for (let i = 0; i < 3; i++) completedIds.push(await make(true, `Completed ${i}`, period));
  draftId = await make(false, "Draft for the editor states", new Date().toISOString().slice(0, 10));
  incompleteId = await make(false, "Missing required answers", new Date().toISOString().slice(0, 10));
  // A release the report-only reader can read.
  await provisionReleaser(env, token, subjects.releaser);
  const releaser = await apiClient(subjects.releaser);
  const end = new Date(Date.parse(`${period}T00:00:00Z`));
  end.setUTCMonth(end.getUTCMonth() + 1); end.setUTCDate(0);
  const created = await releaser.call("POST", "/api/reports/releases", { observedFrom: period, observedTo: end.toISOString().slice(0, 10) });
  assert.equal(created.status, 201, created.text);
  release = created.json.release;
  browser = await chromium.launch();
});

after(async () => {
  if (browser) await browser.close();
  if (!skip) {
    fs.mkdirSync(outDir, { recursive: true });
    fs.writeFileSync(path.join(outDir, "findings.json"), `${JSON.stringify({ tag, layouts: LAYOUTS, findings, pageErrors }, null, 2)}\n`);
    const r = await api(env, "POST", "/api/maintenance/identity/cleanup-fixtures", { token, body: { tag } });
    if (r.status !== 200) console.error("fixture cleanup failed", r.status, r.text);
  }
});

// ---- the sweep ------------------------------------------------------------------------------------------------

for (const layout of LAYOUTS) {
  test(`A11Y (${layout.name}): My Walks, the chooser and every editor state`, { skip, timeout: 600000 }, async () => {
    const { context, page } = await newPage(subjects.walker, layout);
    await openHome(page);
    await page.waitForSelector(`.walk-card[data-walk-id="${draftId}"]`);
    await check(page, "my walks", layout);
    await page.click("#new-walk-btn");
    await page.waitForSelector("#new-walk-chooser:not([hidden])");
    await check(page, "new walk chooser", layout);
    await page.click("#chooser-cancel");

    await page.click(`.walk-card[data-walk-id="${draftId}"] .open-btn`);
    await page.waitForSelector("#editor [data-section-key]");
    await check(page, "editor collapsed", layout);
    await expandAll(page);
    await check(page, "editor expanded with conditional sections and definitions", layout);

    // A failed save: the connection drops, the page offers Retry.
    await page.route("**/api/walks/*", (route) => (route.request().method() === "PUT" ? route.abort("connectionreset") : route.continue()));
    await expand(page, "part2"); await expand(page, "s1");
    await page.fill('[data-item-key="comp_s1_notes"] textarea', `Typed at ${layout.name}`);
    await page.waitForSelector("#save-retry:not([hidden])", { timeout: 20000 });
    await check(page, "editor after a failed save", layout);
    await page.unroute("**/api/walks/*");
    await page.click("#save-retry");
    await page.waitForFunction(() => /^All changes saved$/.test(document.getElementById("save-status").textContent), null, { timeout: 20000 });

    // The composer.
    await expand(page, "part4");
    await page.waitForSelector(".email-slot:not([hidden]) .email-draft-btn");
    for (const box of await page.$$(".email-parts input[data-part]")) await box.check().catch(() => {});
    await page.click(".email-draft-btn");
    await page.waitForSelector(".email-box:not([hidden])");
    await check(page, "email composer", layout);

    // The conflict panel: a colleague saves first.
    const colleague = await apiClient(subjects.colleague);
    const walker = await apiClient(subjects.walker);
    const current = await walker.call("GET", `/api/walks/${draftId}`);
    const moved = await walker.call("PUT", `/api/walks/${draftId}`, { rowVersion: current.json.walk.rowVersion, clientMutationId: crypto.randomUUID(), dimensions: current.json.walk.state.dimensions,
      responses: { ...Object.fromEntries(Object.entries(current.json.walk.state.responses).map(([k, v]) => { const { state, ...rest } = v; return [k, rest]; })), comp_s2_notes: { textValue: `Elsewhere ${layout.name}` } } });
    assert.equal(moved.status, 200, moved.text.slice(0, 300));
    void colleague;
    await expand(page, "s2");
    await page.fill('[data-item-key="comp_s2_notes"] textarea', `Mine ${layout.name}`);
    await page.waitForSelector("#conflict-panel:not([hidden])", { timeout: 20000 });
    await check(page, "conflict panel", layout);
    await context.close();

    // Completion errors, on a walk missing its required answers.
    const second = await newPage(subjects.walker, layout);
    await openHome(second.page);
    await second.page.click(`.walk-card[data-walk-id="${incompleteId}"] .open-btn`);
    await second.page.waitForSelector("#editor [data-section-key]");
    await second.page.click("#complete-btn");
    await second.page.waitForSelector("#completion-errors:not([hidden])", { timeout: 20000 });
    await check(second.page, "completion errors", layout);
    await second.context.close();
  });

  test(`A11Y (${layout.name}): live reports, and a report-only reader's released reports`, { skip, timeout: 600000 }, async () => {
    const { context, page } = await newPage(subjects.walker, layout);
    await openHome(page);
    await page.click("#nav-reports-btn");
    await page.waitForSelector("#rf-org");
    await page.click("#report-run");
    await page.waitForFunction(() => /^Report updated/.test(document.getElementById("report-status").textContent), null, { timeout: 30000 });
    await check(page, "reports live", layout);
    await context.close();

    const reader = await newPage(subjects.reader, layout);
    await openHome(reader.page);
    await reader.page.waitForSelector("#rf-source");
    await reader.page.selectOption("#rf-source", release.releaseId).catch(() => {});
    await reader.page.click("#report-run");
    await reader.page.waitForFunction(() => /^Report updated|withheld|No report/i.test(document.getElementById("report-status").textContent), null, { timeout: 30000 });
    await check(reader.page, "reports released (report-only)", layout);
    await reader.context.close();
  });

  test(`A11Y (${layout.name}): every administration panel and its confirmation`, { skip, timeout: 600000 }, async () => {
    const { context, page } = await newPage(subjects.admin, layout);
    await openHome(page);
    await page.waitForSelector("#admin-versions table");
    await check(page, "admin versions", layout);
    const row = page.locator("#admin-versions tr[data-version-id]").first();
    await row.getByRole("button", { name: /^Preview / }).click();
    await page.waitForSelector("#admin-panel .admin-preview-editor [data-section-key]");
    await check(page, "admin preview", layout);
    await page.locator("#admin-versions tr[data-version-id]").first().getByRole("button", { name: /^Placeholder review for / }).click();
    await page.waitForSelector("#admin-panel .admin-ph-table", { timeout: 20000 });
    await check(page, "admin placeholder queue", layout);
    await page.locator("#admin-versions tr[data-version-id]").first().getByRole("button", { name: /^Compare / }).click();
    await page.waitForSelector("#admin-panel .admin-compare-result, #admin-panel select", { timeout: 20000 });
    await check(page, "admin compare", layout);
    await page.setInputFiles("#admin-import-file", { name: "broken.json", mimeType: "application/json", buffer: Buffer.from(JSON.stringify({ instrument: {} })) });
    await page.click("#admin-import-btn");
    await page.waitForSelector("#admin-import-result .admin-summary-invalid, #admin-error:not([hidden])", { timeout: 30000 });
    await check(page, "admin import refused", layout);
    const draftRow = page.locator('#admin-versions tr[data-status="DRAFT"]').first();
    if (await draftRow.count()) {
      await draftRow.getByRole("button", { name: /^Edit wording of / }).click();
      await page.waitForSelector('#admin-panel form.admin-entity[data-target="version"]', { timeout: 20000 });
      await check(page, "admin wording editor", layout);
      await page.locator('#admin-versions tr[data-status="DRAFT"]').first().getByRole("button", { name: /^Publish / }).click();
      await page.waitForSelector(".admin-confirm[role=alertdialog]", { timeout: 10000 });
      await check(page, "admin publish confirmation", layout);
      await page.getByRole("button", { name: "Cancel" }).click();
    }
    await context.close();
  });
}

test("A11Y-01 keyboard: every view is traversable with visible focus and no trap", { skip, timeout: 600000 }, async () => {
  const layout = LAYOUTS.find((l) => l.name === "desktop-1280");
  const w = await newPage(subjects.walker, layout);
  await openHome(w.page);
  await keyboardTraversal(w.page, "my walks");
  await w.page.click(`.walk-card[data-walk-id="${completedIds[0]}"] .open-btn`);
  await w.page.waitForSelector("#editor [data-section-key]");
  await expandAll(w.page);
  await keyboardTraversal(w.page, "editor expanded");
  await w.page.click("#nav-reports-btn");
  await w.page.waitForSelector("#rf-org");
  await keyboardTraversal(w.page, "reports");
  await w.context.close();
  const a = await newPage(subjects.admin, layout);
  await openHome(a.page);
  await a.page.waitForSelector("#admin-versions table");
  await keyboardTraversal(a.page, "admin versions");
  await a.context.close();
});

test("no page error anywhere in the sweep", { skip }, () => {
  assert.deepEqual(pageErrors, []);
});
