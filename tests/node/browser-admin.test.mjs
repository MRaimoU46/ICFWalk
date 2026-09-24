/**
 * Phase 6 browser checks with Playwright (Chromium) against the real application: an
 * instrument-admin-only user lands on administration and never touches a walk route; a document
 * uploaded from a file is validated and summarized, and an invalid one is refused with its issues
 * (ADM-01); the preview renders through the walk renderer with its conditional behavior and saves
 * nothing (ADM-02); a new DRAFT is made from a published version, a prompt is edited and the
 * comparison shows it, with stored markup staying text (ADM-06, SEC-02); publishing and retiring
 * ask for confirmation, and retiring the only version in service asks twice (ADM-04, ADM-07); the
 * placeholder queue searches and links to the editor (ADM-08); a version downloads as an Excel
 * workbook, and an edited workbook uploads as a new draft, with problems named by sheet, row and
 * column and a changed draft never replaced without asking (the Excel round-trip); and the view passes keyboard,
 * axe-core (WCAG 2.1 AA) and 375 px checks (A11Y-01/03/05).
 *
 * Every fixture lives under this run's own instrument codes, so nothing here publishes or retires
 * the ICFWALK instrument, and everything is removed afterwards through the maintenance cleanup.
 */
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";
import { api, baseUrl, loadRuntimeEnv, root, screenshotDir } from "./helpers.mjs";
import { readWorkbook, readZip, writeWorkbook, writeZip } from "../../app/assets/js/workbook.js";
import { canonicalize } from "../../scripts/lib/snapshot.mjs";

const require = createRequire(import.meta.url);
const env = loadRuntimeEnv();
const token = env.ICFWALK_MAINTENANCE_TOKEN || "";
const tag = `bradm-${Date.now().toString(36)}`;
const instrumentCode = `${tag}-instrument`;
const soloCode = `${tag}-solo`;
const adminSubject = `${tag}-admin`;
const shotDir = screenshotDir(env);
const SOURCE = JSON.parse(fs.readFileSync(path.join(root, "config", "instrument-config.json"), "utf8"));
const PLACEHOLDER_STATUS = "Placeholder in source";
const PLACEHOLDERS = SOURCE.items.filter((i) => i.reviewStatus === PLACEHOLDER_STATUS);
const XSS_PROMPT = "<img src=x onerror=\"window.__admXss=1\">Students explain the goal";

let chromium = null;
try {
  ({ chromium } = require("playwright"));
} catch {
  chromium = null;
}

async function reachable() {
  try {
    const r = await fetch(`${baseUrl(env)}/index.cfm/api/health`, { signal: AbortSignal.timeout(10000) });
    if (r.status !== 200) return false;
    const body = await r.json();
    return body.environment === "development" || body.environment === "test";
  } catch {
    return false;
  }
}
const up = await reachable();
const skip = !chromium ? "playwright is not installed" : !up ? `application not reachable in development mode at ${baseUrl(env)}` : !token ? "no maintenance token" : false;

let browser;
let admin;
const pageErrors = [];
const home = `${baseUrl(env)}/index.cfm/`;
let labelCounter = 0;

async function newContext(viewport = { width: 1280, height: 900 }) {
  const context = await browser.newContext({ extraHTTPHeaders: { "X-ICFWalk-Dev-Subject": adminSubject }, viewport });
  const page = await context.newPage();
  page.on("pageerror", (e) => pageErrors.push(`pageerror: ${e.message}`));
  page.on("console", (m) => {
    if (m.type() === "error" && !/ERR_|net::|Failed to load resource/.test(m.text())) pageErrors.push(m.text());
  });
  return { context, page };
}

async function apiClient(who) {
  const cookies = new Map();
  let csrf = "";
  const call = async (method, p, body) => {
    const headers = { Accept: "application/json", "X-ICFWalk-Dev-Subject": who };
    if (body !== undefined) headers["Content-Type"] = "application/json";
    if (csrf && method !== "GET") headers["X-ICFWalk-CSRF-Token"] = csrf;
    const cookie = [...cookies.entries()].map(([k, v]) => `${k}=${v}`).join("; ");
    if (cookie) headers.Cookie = cookie;
    const response = await fetch(`${baseUrl(env)}/index.cfm${p}`, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
    for (const line of response.headers.getSetCookie ? response.headers.getSetCookie() : []) {
      const [pair] = line.split(";");
      const eq = pair.indexOf("=");
      cookies.set(pair.slice(0, eq).trim(), pair.slice(eq + 1).trim());
    }
    const text = await response.text();
    let json = null;
    try { json = JSON.parse(text); } catch { json = null; }
    return { status: response.status, json, text };
  };
  const me = await call("GET", "/api/me");
  assert.equal(me.status, 200, me.text);
  csrf = me.json.csrfToken;
  return { call, me: me.json };
}

function documentFor(suffix, { code = instrumentCode, mutate = null } = {}) {
  const doc = structuredClone(SOURCE);
  doc.instrument.code = code;
  doc.instrument.version.versionLabel = `${tag}-${suffix}-${++labelCounter}`;
  if (mutate) mutate(doc);
  return doc;
}

async function importVersion(suffix, options = {}) {
  const r = await admin.call("POST", "/api/admin/instrument/import", { document: documentFor(suffix, options) });
  assert.equal(r.status, 201, r.text);
  return r.json;
}

async function publishVersion(versionId) {
  const r = await admin.call("POST", `/api/admin/instrument/versions/${versionId}/publish`);
  assert.equal(r.status, 200, r.text);
  return r.json;
}

async function statusOf(versionId) {
  const r = await admin.call("GET", "/api/admin/instrument/versions");
  const row = r.json.versions.find((v) => v.versionId === versionId.toUpperCase());
  return row ? row.status : null;
}

async function openHome(page) {
  await page.goto(home, { waitUntil: "networkidle" });
  await page.waitForSelector("body[data-ready=true]", { timeout: 20000 });
  await page.waitForSelector("#admin-versions table", { timeout: 20000 });
}

const row = (page, versionId) => page.locator(`#admin-versions tr[data-version-id="${versionId.toUpperCase()}"]`);
const idle = (page) => page.waitForFunction(() => !document.body.dataset.adminBusy, null, { timeout: 20000 });
const statusText = (page) => page.textContent("#admin-status");
const waitStatus = (page, pattern) => page.waitForFunction((src) => new RegExp(src).test(document.getElementById("admin-status").textContent), pattern.source, { timeout: 20000 });

async function axe(page) {
  if (!(await page.evaluate(() => Boolean(window.axe)))) await page.addScriptTag({ url: `${baseUrl(env)}/assets/js/axe.min.js` });
  const violations = await page.evaluate(async () => {
    const r = await window.axe.run(document, { runOnly: { type: "tag", values: ["wcag2a", "wcag2aa", "wcag21a", "wcag21aa"] } });
    return r.violations.map((v) => ({ id: v.id, impact: v.impact, nodes: v.nodes.length, help: v.help, targets: v.nodes.slice(0, 3).map((n) => n.target.join(" ")) }));
  });
  return violations.filter((v) => v.impact === "serious" || v.impact === "critical");
}

before(async () => {
  if (skip) return;
  const units = await api(env, "POST", "/api/maintenance/org-units/import", { token, body: { orgUnits: [
    { code: `${tag}-district`, type: "DISTRICT", name: "Admin browser district", parentCode: null },
  ] } });
  assert.equal(units.status, 200, units.text);
  const u = await api(env, "POST", "/api/maintenance/identity/provision-user", { token, body: { subject: adminSubject, displayName: "Admin browser fixture" } });
  assert.ok(u.status === 201 || u.status === 200, u.text);
  const a = await api(env, "POST", "/api/maintenance/identity/assign-role", { token, body: { subject: adminSubject, roleCode: "MASTER_INSTRUMENT_ADMIN", orgUnitCode: `${tag}-district` } });
  assert.equal(a.status, 201, a.text);
  admin = await apiClient(adminSubject);
  browser = await chromium.launch();
  fs.mkdirSync(shotDir, { recursive: true });
});

after(async () => {
  if (browser) await browser.close();
  if (!skip) {
    const r = await api(env, "POST", "/api/maintenance/identity/cleanup-fixtures", { token, body: { tag } });
    if (r.status !== 200) console.error("fixture cleanup failed", r.status, r.text);
  }
});

test("ADM-01 (browser): an instrument-admin-only user lands on administration and imports a document from a file", { skip }, async () => {
  const { context, page } = await newContext();
  const requested = [];
  page.on("request", (r) => requested.push(`${r.method()} ${new URL(r.url()).pathname}`));
  await openHome(page);
  assert.equal(await page.isVisible("#view-admin"), true);
  assert.equal(await page.isVisible("#view-list"), false, "My walks is never shown to an admin-only role");
  assert.equal(await page.isVisible("#nav-admin-btn"), false, "already on administration");
  assert.equal(await page.isVisible("#nav-list-btn"), false);
  assert.equal(await page.isVisible("#app-message"), false, "no error from a walk route");
  assert.ok(!requested.some((p) => /\/api\/walks|\/api\/instrument\/current|\/api\/reports/.test(p)), `walk or report routes were requested: ${requested.join(", ")}`);
  assert.equal(await page.evaluate(() => document.activeElement && document.activeElement.id), "admin-heading");

  // A file that is not JSON is refused on the page; nothing is sent.
  await page.setInputFiles("#admin-import-file", { name: "notes.json", mimeType: "application/json", buffer: Buffer.from("{ not json") });
  await page.click("#admin-import-btn");
  await page.waitForSelector("#admin-error:not([hidden])");
  assert.match(await page.textContent("#admin-error"), /notes\.json is neither an Excel workbook \(\.xlsx\) nor valid JSON, so nothing was sent/);
  assert.ok(!requested.some((p) => p.endsWith("/api/admin/instrument/import")));

  // An invalid document: every issue is listed, nothing is written.
  const invalid = documentFor("invalid", { mutate: (d) => { d.items[0].responseSetId = "rs_missing"; d.items[1].itemKey = d.items[2].itemKey; } });
  await page.setInputFiles("#admin-import-file", { name: "broken.json", mimeType: "application/json", buffer: Buffer.from(JSON.stringify(invalid)) });
  await page.click("#admin-import-btn");
  await page.waitForSelector("#admin-import-result .admin-summary-invalid");
  assert.match(await page.textContent("#admin-import-result .admin-summary-title"), /^Not imported: broken\.json has \d+ problems\. Nothing was written\.$/);
  assert.ok(await page.locator("#admin-import-result .admin-issues li").count() >= 2);
  const listed = await admin.call("GET", "/api/admin/instrument/versions");
  assert.ok(!listed.json.versions.some((v) => v.versionLabel === invalid.instrument.version.versionLabel));

  // A valid document: the validation summary, and the new DRAFT in the list.
  const doc = documentFor("import");
  await page.setInputFiles("#admin-import-file", { name: "instrument.json", mimeType: "application/json", buffer: Buffer.from(JSON.stringify(doc)) });
  await page.click("#admin-import-btn");
  await page.waitForSelector("#admin-import-result .admin-summary:not(.admin-summary-invalid)");
  await idle(page);
  const label = doc.instrument.version.versionLabel;
  assert.equal(await page.textContent("#admin-import-result .admin-summary-title"), `Created DRAFT ${label} of ${instrumentCode} from instrument.json.`);
  const counts = await page.$$eval("#admin-import-result .admin-counts tr", (rows) => Object.fromEntries(rows.map((r) => [r.querySelector("th").textContent, r.querySelector("td").textContent])));
  assert.equal(counts.Items, String(SOURCE.counts.items));
  assert.equal(counts.Sections, String(SOURCE.counts.sections));
  assert.equal(counts["Placeholder prompts"], String(PLACEHOLDERS.length));
  assert.match(await page.textContent("#admin-import-result"), new RegExp(`${PLACEHOLDERS.length} prompts still carry placeholder source content`));
  const draftRow = page.locator("#admin-versions tr", { hasText: label });
  assert.equal(await draftRow.getAttribute("data-status"), "DRAFT");
  assert.equal(await draftRow.locator(".status-badge").first().textContent(), "Draft");
  assert.deepEqual(pageErrors, []);
  await context.close();
});

test("ADM-02 (browser): the preview renders through the walk renderer, with conditional behavior, and saves nothing", { skip }, async () => {
  const draft = await importVersion("preview");
  const { context, page } = await newContext();
  const writes = [];
  page.on("request", (r) => { if (r.method() !== "GET") writes.push(`${r.method()} ${new URL(r.url()).pathname}`); });
  await openHome(page);
  await row(page, draft.versionId).getByRole("button", { name: /^Preview / }).click();
  await page.waitForSelector("#admin-panel .admin-preview-editor [data-section-key]");
  await idle(page);
  assert.match(await page.textContent("#admin-panel h2"), new RegExp(`^Preview: ${draft.versionLabel} \\(Draft\\)$`));
  assert.equal(await page.evaluate(() => document.activeElement && document.activeElement.tagName), "H2", "focus moves to the panel heading");

  const scope = "#admin-panel .admin-preview-editor";
  const visible = (key) => page.$eval(`${scope} [data-section-key="${key}"]`, (e) => !e.hidden && !e.closest("[hidden]"));
  const items = await page.$$eval(`${scope} [data-item-key]`, (els) => els.length);
  assert.equal(items, SOURCE.counts.items, "every item renders");
  assert.equal(await page.$$eval(`${scope} [data-placeholder=true]`, (els) => els.length), PLACEHOLDERS.length);
  assert.equal(await visible("prek_k_classroom"), false);
  await page.selectOption(`${scope} [data-dimension-code="grade"] select`, "prek");
  assert.equal(await visible("prek_k_classroom"), true, "choosing PreK shows the PreK/K section, as in a walk");
  await page.selectOption(`${scope} [data-dimension-code="grade"] select`, "9");
  assert.equal(await visible("prek_k_classroom"), false);
  await page.selectOption(`${scope} [data-dimension-code="content"] select`, "music");
  assert.equal(await visible("content_area_look_fors"), true);
  await page.click(`${scope} [data-item-key="prek_k_q1"] .pill[data-code="yes"]`, { force: true }).catch(() => {});
  await page.waitForTimeout(900);   // longer than the walk editor's autosave debounce
  assert.deepEqual(writes, [], "the preview never writes");
  await page.screenshot({ path: path.join(shotDir, "admin-preview-desktop.png"), fullPage: false });

  await page.getByRole("button", { name: /^Close Preview/ }).click();
  assert.equal(await page.isVisible("#admin-panel"), false);
  assert.equal(await page.evaluate(() => document.activeElement && document.activeElement.id), "admin-heading");
  assert.deepEqual(pageErrors, []);
  await context.close();
});

test("ADM-06 (browser): a new draft from a published version, a prompt edited, and the comparison", { skip }, async () => {
  const base = await importVersion("clone-base");
  await publishVersion(base.versionId);
  const item = SOURCE.items.find((i) => i.reviewStatus !== PLACEHOLDER_STATUS && i.itemType === "SINGLE_CHOICE");
  const { context, page } = await newContext();
  await openHome(page);
  const baseRow = row(page, base.versionId);
  assert.equal(await baseRow.getAttribute("data-status"), "PUBLISHED");
  assert.equal(await baseRow.locator(".admin-current").count(), 1, "the published version is marked in service");
  assert.equal(await baseRow.getByRole("button", { name: /^Edit wording/ }).count(), 0, "a published version offers no editing");

  await baseRow.getByRole("button", { name: /^Create a new draft from/ }).click();
  const cloneLabel = `${tag}-clone-${++labelCounter}`;
  await page.fill("#admin-panel input[type=text]", cloneLabel);
  await page.fill("#admin-panel textarea", "Prompt review");
  await page.getByRole("button", { name: "Create draft" }).click();
  await page.waitForFunction((l) => document.querySelector("#admin-panel h2")?.textContent === `Edit wording: ${l}`, cloneLabel, { timeout: 20000 });
  await idle(page);
  const cloneRow = page.locator("#admin-versions tr", { hasText: cloneLabel });
  assert.equal(await cloneRow.getAttribute("data-status"), "DRAFT");
  const cloneId = await cloneRow.getAttribute("data-version-id");

  // Find the item and change its prompt -- to text carrying markup, which must stay text.
  await page.fill("#admin-panel input[type=search]", item.itemKey);
  await page.getByRole("button", { name: "Search", exact: true }).click();
  const form = page.locator(`#admin-panel form.admin-entity[data-target="item"][data-key="${item.itemKey}"]`);
  await form.waitFor();
  const prompt = form.locator('textarea[name="prompt"]');
  assert.equal(await prompt.inputValue(), item.prompt);
  await prompt.fill(XSS_PROMPT);
  await form.getByRole("button", { name: "Save changes" }).click();
  await waitStatus(page, /^Saved 1 change to /);
  assert.equal(await statusText(page), `Saved 1 change to ${cloneLabel}.`);
  assert.equal(await prompt.inputValue(), XSS_PROMPT);

  // The comparison defaults to the in-service version as the baseline.
  await page.locator(`#admin-versions tr[data-version-id="${cloneId}"]`).getByRole("button", { name: /^Compare / }).click();
  await page.waitForSelector("#admin-panel .admin-compare-result .admin-summary-title");
  await idle(page);
  assert.equal(await page.$eval("#admin-panel select", (s) => s.value), base.versionId.toUpperCase());
  assert.match(await page.textContent("#admin-panel .admin-compare-result .admin-summary-title"), /0 additions, 0 removals, 1 change, \d+ metadata differences\.$/);
  const change = page.locator(`#admin-panel .admin-change[data-collection="items"][data-key="${item.itemKey}"]`);
  assert.equal(await change.locator(".status-badge").textContent(), "CHANGED");
  assert.equal(await change.locator("td.admin-before").textContent(), item.prompt);
  assert.equal(await change.locator("td.admin-after").textContent(), XSS_PROMPT, "stored markup is shown as text");
  assert.equal(await page.locator("#admin-panel img").count(), 0);
  assert.equal(await page.evaluate(() => window.__admXss), undefined, "and no handler ran");
  await page.screenshot({ path: path.join(shotDir, "admin-compare-desktop.png"), fullPage: false });

  // A stale edit is refused with a way to reload, not silently applied.
  const stale = await admin.call("POST", `/api/admin/instrument/versions/${cloneId}/edits`, {
    expectedChecksum: (await admin.call("GET", `/api/admin/instrument/versions/${cloneId}/wording`)).json.version.checksum,
    edits: [{ target: "version", field: "revisionNotes", value: "Changed elsewhere" }],
  });
  assert.equal(stale.status, 200, stale.text);
  await page.locator(`#admin-versions tr[data-version-id="${cloneId}"]`).getByRole("button", { name: /^Edit wording/ }).click();
  await page.waitForSelector('#admin-panel form.admin-entity[data-target="version"]');
  await idle(page);
  await admin.call("POST", `/api/admin/instrument/versions/${cloneId}/edits`, {
    expectedChecksum: (await admin.call("GET", `/api/admin/instrument/versions/${cloneId}/wording`)).json.version.checksum,
    edits: [{ target: "version", field: "revisionNotes", value: "Changed elsewhere again" }],
  });
  const versionForm = page.locator('#admin-panel form.admin-entity[data-target="version"]');
  await versionForm.locator('input[name="reviewStatus"]').fill("Ready for review");
  await versionForm.getByRole("button", { name: "Save changes" }).click();
  await page.waitForSelector("#admin-error:not([hidden])");
  assert.match(await page.textContent("#admin-error"), /This draft changed after you opened it, so nothing was saved/);
  assert.equal(await versionForm.getByRole("button", { name: "Reload this draft" }).count(), 1);
  assert.deepEqual(pageErrors, []);
  await context.close();
});

test("ADM-08 (browser): the placeholder queue searches, links to the editor, and shrinks when a placeholder is resolved", { skip }, async () => {
  const draft = await importVersion("placeholders");
  const { context, page } = await newContext();
  await openHome(page);
  await row(page, draft.versionId).getByRole("button", { name: /^Placeholder review/ }).click();
  await page.waitForSelector("#admin-panel .admin-ph-table");
  await idle(page);
  assert.equal(await page.textContent("#admin-panel .admin-ph-count"), `${PLACEHOLDERS.length} placeholder prompts to review.`);
  assert.equal(await page.locator("#admin-panel .admin-ph-table tbody tr").count(), PLACEHOLDERS.length);

  const target = PLACEHOLDERS[4];
  await page.fill("#admin-panel input[type=search]", target.sourceLocation);
  await page.getByRole("button", { name: "Search", exact: true }).click();
  await page.waitForFunction((n) => document.querySelectorAll("#admin-panel .admin-ph-table tbody tr").length < n, PLACEHOLDERS.length, { timeout: 20000 });
  await idle(page);
  assert.match(await page.textContent("#admin-panel .admin-ph-count"), new RegExp(`^\\d+ of ${PLACEHOLDERS.length} placeholder prompts match`));
  const hit = page.locator(`#admin-panel .admin-ph-table tr[data-item-key="${target.itemKey}"]`);
  assert.equal(await hit.locator("td").nth(3).textContent(), target.sourceLocation);
  await page.screenshot({ path: path.join(shotDir, "admin-placeholders-desktop.png"), fullPage: false });

  await hit.getByRole("button", { name: `Edit ${target.itemKey}` }).click();
  const form = page.locator(`#admin-panel form.admin-entity[data-target="item"][data-key="${target.itemKey}"]`);
  await form.waitFor();
  await idle(page);
  await form.locator('textarea[name="prompt"]').fill("Students can explain what they are learning today.");
  await form.locator('input[name="reviewStatus"]').fill("Reviewed");
  await form.getByRole("button", { name: "Save changes" }).click();
  await waitStatus(page, /^Saved 2 changes to /);

  await row(page, draft.versionId).getByRole("button", { name: /^Placeholder review/ }).click();
  await page.waitForSelector("#admin-panel .admin-ph-table");
  await idle(page);
  assert.equal(await page.textContent("#admin-panel .admin-ph-count"), `${PLACEHOLDERS.length - 1} placeholder prompts to review.`);
  assert.equal(await page.locator(`#admin-panel .admin-ph-table tr[data-item-key="${target.itemKey}"]`).count(), 0);
  assert.deepEqual(pageErrors, []);
  await context.close();
});

test("ADM-04 / ADM-07 (browser): publish and retire ask first; retiring the only version in service asks twice", { skip }, async () => {
  const draft = await importVersion("publish-ui", { code: soloCode });
  const { context, page } = await newContext();
  await openHome(page);

  // Publish, cancelled then confirmed.
  await row(page, draft.versionId).getByRole("button", { name: /^Publish / }).click();
  const dialog = page.getByRole("alertdialog");
  await dialog.waitFor();
  assert.match(await dialog.textContent(), /Published content can never be changed/);
  assert.equal(await page.evaluate(() => document.activeElement && document.activeElement.textContent), "Cancel", "focus starts on the safe choice");
  await page.keyboard.press("Escape");
  assert.equal(await page.getByRole("alertdialog").count(), 0);
  assert.equal(await statusOf(draft.versionId), "DRAFT", "a cancelled publish changes nothing");
  await row(page, draft.versionId).getByRole("button", { name: /^Publish / }).click();
  await page.getByRole("alertdialog").getByRole("button", { name: "Publish" }).click();
  await waitStatus(page, /^Published /);
  await idle(page);
  assert.equal(await row(page, draft.versionId).getAttribute("data-status"), "PUBLISHED");
  assert.equal(await statusOf(draft.versionId), "PUBLISHED");

  // Retire: the first confirmation, then the server's refusal to leave nothing in service turns
  // into a second, explicit confirmation.
  await row(page, draft.versionId).getByRole("button", { name: /^Retire / }).click();
  await page.getByRole("alertdialog").waitFor();
  assert.match(await page.getByRole("alertdialog").textContent(), /existing walks? keep opening, saving and rendering against it/);
  await page.getByRole("alertdialog").getByRole("button", { name: "Cancel" }).click();
  assert.equal(await statusOf(draft.versionId), "PUBLISHED", "a cancelled retire changes nothing");
  await row(page, draft.versionId).getByRole("button", { name: /^Retire / }).click();
  await page.getByRole("alertdialog").getByRole("button", { name: "Retire version" }).click();
  const second = page.getByRole("alertdialog", { name: /is the only version in service$/ });
  await second.waitFor({ timeout: 20000 });
  assert.equal(await statusOf(draft.versionId), "PUBLISHED", "the first confirmation alone retires nothing");
  assert.match(await second.textContent(), new RegExp(`nobody can start a new walk of ${soloCode}`));
  await page.screenshot({ path: path.join(shotDir, "admin-retire-confirm-desktop.png"), fullPage: false });
  await second.getByRole("button", { name: "Retire anyway" }).click();
  await waitStatus(page, /^Retired /);
  await idle(page);
  assert.equal(await statusText(page), `Retired ${draft.versionLabel}. No version of this instrument is in service now.`);
  assert.equal(await statusOf(draft.versionId), "RETIRED");
  const retiredRow = row(page, draft.versionId);
  assert.equal(await retiredRow.getAttribute("data-status"), "RETIRED");
  assert.equal(await retiredRow.getByRole("button", { name: /^Retire / }).count(), 0);
  assert.equal(await retiredRow.getByRole("button", { name: /^Publish / }).count(), 0);
  assert.deepEqual(pageErrors, []);
  await context.close();
});

test("Excel round-trip (browser): download a workbook, edit it, upload it as a new draft; problems name their cells", { skip }, async () => {
  const base = await importVersion("excel");
  await publishVersion(base.versionId);
  const { context, page } = await browser.newContext({ extraHTTPHeaders: { "X-ICFWalk-Dev-Subject": adminSubject }, viewport: { width: 1280, height: 900 }, acceptDownloads: true }).then(async (ctx) => ({ context: ctx, page: await ctx.newPage() }));
  page.on("pageerror", (e) => pageErrors.push(`pageerror: ${e.message}`));
  const posts = [];
  page.on("request", (r) => { if (r.method() === "POST") posts.push(new URL(r.url()).pathname); });
  await openHome(page);

  // Download: the workbook carries exactly the version's document.
  await row(page, base.versionId).getByRole("button", { name: /^Download / }).click();
  await page.waitForSelector("#admin-panel h2");
  assert.equal(await page.textContent("#admin-panel h2"), `Download ${base.versionLabel}`);
  const [xlsxDownload] = await Promise.all([page.waitForEvent("download"), page.getByRole("button", { name: "Excel workbook (.xlsx)" }).click()]);
  assert.match(xlsxDownload.suggestedFilename(), new RegExp(`^ICFWalk_${instrumentCode}_.*\\.xlsx$`));
  const downloaded = new Uint8Array(fs.readFileSync(await xlsxDownload.path()));
  const exported = await admin.call("GET", `/api/admin/instrument/versions/${base.versionId}/document`);
  const wb = await readWorkbook(downloaded);
  assert.equal(wb.ok, true, JSON.stringify(wb.errors));
  assert.equal(canonicalize(wb.document), canonicalize(exported.json.document), "the downloaded workbook is the version, exactly");
  assert.equal(wb.meta.versionId.toUpperCase(), base.versionId.toUpperCase());
  assert.equal(wb.meta.checksum, base.checksum);
  const [jsonDownload] = await Promise.all([page.waitForEvent("download"), page.getByRole("button", { name: "JSON document (.json)" }).click()]);
  assert.equal(canonicalize(JSON.parse(fs.readFileSync(await jsonDownload.path(), "utf8"))), canonicalize(exported.json.document));
  await idle(page);
  await page.screenshot({ path: path.join(shotDir, "admin-download-desktop.png"), fullPage: false });

  // Upload an edited workbook under a new label: a new draft that differs by exactly the edit.
  const item = SOURCE.items.find((i) => i.reviewStatus !== PLACEHOLDER_STATUS && i.itemType === "SINGLE_CHOICE");
  const doc = structuredClone(wb.document);
  doc.items.find((i) => i.itemKey === item.itemKey).prompt = `${item.prompt} (revised in Excel)`;
  const edited = await writeWorkbook(doc, { exportedFrom: wb.meta, exportedAt: wb.meta.exportedAt });
  const newLabel = `${tag}-excel-edit-${++labelCounter}`;
  await page.setInputFiles("#admin-import-file", { name: "edited.xlsx", mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", buffer: Buffer.from(edited) });
  await page.fill("#admin-import-label", newLabel);
  await page.click("#admin-import-btn");
  await page.waitForSelector("#admin-import-result .admin-summary:not(.admin-summary-invalid)");
  await idle(page);
  assert.equal(await page.textContent("#admin-import-result .admin-summary-title"), `Created DRAFT ${newLabel} of ${instrumentCode} from edited.xlsx.`);
  const created = page.locator("#admin-versions tr", { hasText: newLabel });
  const createdId = await created.getAttribute("data-version-id");
  const cmp = await admin.call("GET", `/api/admin/instrument/compare?from=${base.versionId}&to=${createdId}`);
  assert.deepEqual(cmp.json.changes.map((c) => `${c.key}:${c.fields.map((f) => f.field).join(",")}`), [`${item.itemKey}:prompt`]);

  // A reference the server cannot resolve is reported on the cell it came from.
  const broken = structuredClone(wb.document);
  const brokenIndex = broken.items.findIndex((i) => i.itemKey === item.itemKey);
  broken.items[brokenIndex].responseSetId = "rs_does_not_exist";
  await page.setInputFiles("#admin-import-file", { name: "broken.xlsx", mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", buffer: Buffer.from(await writeWorkbook(broken, { exportedFrom: wb.meta })) });
  await page.fill("#admin-import-label", `${tag}-excel-broken-${++labelCounter}`);
  await page.click("#admin-import-btn");
  await page.waitForSelector("#admin-import-result .admin-summary-invalid");
  await idle(page);
  const places = await page.$$eval("#admin-import-result .admin-issue-place", (els) => els.map((e) => e.textContent));
  assert.ok(places.includes(` (item_definition, row ${4 + brokenIndex}, column response_set_id (L${4 + brokenIndex}))`), places.join(" | "));

  // A problem in the workbook itself is found before anything is sent.
  const files = await readZip(edited);
  const itemSheet = [...files.keys()].find((k) => k.endsWith("sheet5.xml"));
  files.set(itemSheet, new TextEncoder().encode(new TextDecoder().decode(files.get(itemSheet)).replace(">prompt</t>", ">question</t>")));
  const postsBefore = posts.length;
  await page.setInputFiles("#admin-import-file", { name: "no-prompt.xlsx", mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", buffer: Buffer.from(await writeZip([...files].map(([name, data]) => ({ name, data })))) });
  await page.click("#admin-import-btn");
  await page.waitForFunction(() => /column prompt/.test(document.querySelector("#admin-import-result")?.textContent || ""), null, { timeout: 20000 });
  assert.match(await page.textContent("#admin-import-result .admin-summary-title"), /^Not imported: no-prompt\.xlsx has \d+ problems?\. Nothing was sent\.$/);
  assert.equal(posts.length, postsBefore, "nothing was sent");

  // Replacing a draft that changed after the workbook was downloaded asks first; Cancel sends nothing.
  const draftExport = await admin.call("GET", `/api/admin/instrument/versions/${createdId}/document`);
  const draftBook = await writeWorkbook(draftExport.json.document, { exportedFrom: draftExport.json.version });
  const change = await admin.call("POST", `/api/admin/instrument/versions/${createdId}/edits`, {
    expectedChecksum: draftExport.json.version.checksum,
    edits: [{ target: "version", field: "revisionNotes", value: "Changed in the app after the download" }],
  });
  assert.equal(change.status, 200, change.text);
  await page.reload({ waitUntil: "networkidle" });
  await page.waitForSelector("#admin-versions table");
  await page.setInputFiles("#admin-import-file", { name: "stale.xlsx", mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", buffer: Buffer.from(draftBook) });
  const postsBeforeStale = posts.length;
  await page.click("#admin-import-btn");
  const dialog = page.getByRole("alertdialog", { name: `Replace draft ${newLabel}?` });
  await dialog.waitFor({ timeout: 20000 });
  assert.match(await dialog.textContent(), /changed after this workbook was downloaded/);
  await dialog.getByRole("button", { name: "Cancel" }).click();
  await waitStatus(page, /^Nothing was imported\.$/);
  assert.equal(posts.length, postsBeforeStale, "a cancelled replacement sends nothing");
  assert.deepEqual(pageErrors, []);
  await context.close();
});

test("A11Y-01 / A11Y-03 / A11Y-05 (admin): keyboard operation, axe-core, and 375 px without horizontal loss", { skip }, async () => {
  const draft = await importVersion("a11y");
  const { context, page } = await newContext();
  const axeSource = fs.readFileSync(require.resolve("axe-core/axe.min.js"), "utf8");
  await page.route("**/assets/js/axe.min.js", (route) => route.fulfill({ status: 200, contentType: "application/javascript", body: axeSource }));
  await openHome(page);

  // Every control in the view has an accessible name.
  const unnamed = await page.$$eval("#view-admin button, #view-admin input, #view-admin select, #view-admin textarea", (els) =>
    els.filter((e) => !(e.labels && e.labels.length) && !e.getAttribute("aria-label") && !e.textContent.trim()).map((e) => e.id || e.outerHTML.slice(0, 80)));
  assert.deepEqual(unnamed, []);
  assert.deepEqual(await axe(page), [], "version list");
  await page.screenshot({ path: path.join(shotDir, "admin-desktop.png"), fullPage: false });

  // The placeholder queue, reached and searched from the keyboard alone.
  const phButton = row(page, draft.versionId).getByRole("button", { name: /^Placeholder review/ });
  await phButton.focus();
  await page.keyboard.press("Enter");
  await page.waitForSelector("#admin-panel .admin-ph-table");
  await idle(page);
  assert.equal(await page.evaluate(() => document.activeElement && document.activeElement.tagName), "H2", "focus moves into the panel");
  await page.keyboard.press("Tab");
  assert.equal(await page.evaluate(() => document.activeElement && document.activeElement.textContent), "Close");
  await page.keyboard.press("Tab");
  assert.equal(await page.evaluate(() => document.activeElement && document.activeElement.type), "search");
  await page.keyboard.type(PLACEHOLDERS[0].itemKey);
  await page.keyboard.press("Enter");
  await page.waitForFunction(() => /match/.test(document.querySelector("#admin-panel .admin-ph-count").textContent), null, { timeout: 20000 });
  await idle(page);
  assert.deepEqual(await axe(page), [], "placeholder queue");

  // The wording editor and the import summary, together.
  await page.setInputFiles("#admin-import-file", { name: "instrument.json", mimeType: "application/json", buffer: Buffer.from(JSON.stringify(documentFor("a11y-import"))) });
  await page.click("#admin-import-btn");
  await page.waitForSelector("#admin-import-result .admin-summary");
  await idle(page);
  await row(page, draft.versionId).getByRole("button", { name: /^Edit wording/ }).click();
  await page.waitForSelector('#admin-panel form.admin-entity[data-target="version"]');
  await idle(page);
  await page.fill("#admin-panel input[type=search]", "classroom");
  await page.getByRole("button", { name: "Search", exact: true }).click();
  await page.waitForSelector('#admin-panel form.admin-entity[data-target="section"]');
  await idle(page);
  assert.deepEqual(await axe(page), [], "wording editor and import summary");

  // The download panel, reached from the keyboard.
  await row(page, draft.versionId).getByRole("button", { name: /^Download / }).focus();
  await page.keyboard.press("Enter");
  await page.waitForSelector("#admin-panel h2");
  assert.equal(await page.evaluate(() => document.activeElement && document.activeElement.textContent), "Excel workbook (.xlsx)", "focus lands on the first download");
  assert.deepEqual(await axe(page), [], "download panel");

  for (const width of [768, 375]) {
    await page.setViewportSize({ width, height: 800 });
    await page.waitForTimeout(150);
    const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
    assert.ok(overflow <= 0, `no horizontal overflow at ${width}px (${overflow}px)`);
  }
  assert.deepEqual(await axe(page), [], "375 px");
  await page.locator("#admin-versions").scrollIntoViewIfNeeded();
  await page.screenshot({ path: path.join(shotDir, "admin-phone.png"), fullPage: false });
  assert.deepEqual(pageErrors, [], "no page errors");
  await context.close();
});
