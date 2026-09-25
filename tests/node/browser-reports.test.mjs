/**
 * Phase 7 browser checks with Playwright (Chromium) against the real application: a report-only
 * user lands on Reports, never touches a walk route and reads released figures only -- the page is
 * never sent a withheld value to hide (RPT-03) -- filters narrow the population and the page shows
 * answered-only averages (RPT-04/07), the CSV download is the route's own file, a refused filter
 * is announced, a walk user can move between My walks and Reports, stored markup in an org unit
 * name stays text (SEC-02), someone who may release dates can do so from the page, and the view
 * passes keyboard, axe-core (WCAG 2.1 AA) and 375 px checks (A11Y-01/03/05).
 *
 * Every walk is dated in a month no other suite uses (a random month in 1975-1999), and before()
 * releases those dates as someone who can open every walk, so the report-only user reads a real
 * release; live figures belong to a district walk-and-report user. Fixtures, the release included,
 * are created through the maintenance and report endpoints and removed afterwards.
 */
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";
import { api, baseUrl, loadRuntimeEnv, provisionReleaser, releaseMonth, screenshotDir } from "./helpers.mjs";

const require = createRequire(import.meta.url);
const env = loadRuntimeEnv();
const token = env.ICFWALK_MAINTENANCE_TOKEN || "";
const tag = `brrpt-${Date.now().toString(36)}`;
const walkerA = `${tag}-walker-a`;
const walkerB = `${tag}-walker-b`;
const analyst = `${tag}-analyst`;
const districtWalker = `${tag}-district-walker`;
const releaser = `${tag}-releaser`;
const FIRST_DAY = releaseMonth(1975, 1999);
const LAST_DAY = `${FIRST_DAY.slice(0, 8)}03`;
let release = null;
const shotDir = screenshotDir(env);
const XSS_NAME = "<img src=x onerror=\"window.__rptXss=1\">School B";

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
const pageErrors = [];
const home = `${baseUrl(env)}/index.cfm/`;
const units = {};

async function newContext(subject, viewport = { width: 1280, height: 900 }) {
  const context = await browser.newContext({ extraHTTPHeaders: { "X-ICFWalk-Dev-Subject": subject }, viewport, acceptDownloads: true });
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

async function completedWalk(who, rating) {
  const c = await apiClient(who);
  const unit = c.me.permissions["walk.create"][0];
  const created = await c.call("POST", "/api/walks", { orgUnitId: unit, clientMutationId: crypto.randomUUID().toUpperCase() });
  assert.equal(created.status, 201, created.text);
  const saved = await c.call("PUT", `/api/walks/${created.json.walk.id}`, {
    rowVersion: created.json.walk.rowVersion, clientMutationId: crypto.randomUUID().toUpperCase(),
    dimensions: { date: { dateValue: FIRST_DAY }, grade: { selectedValueCode: "7" } },
    responses: {
      p1q1: { storedCode: "Partial" }, p1q2: { storedCode: "Retrieval" }, p1q3: { storedCode: "Analysis" }, part1_adopted_pacing: { storedCode: "on" },
      part1_adopted_ac1: { storedCode: "3" }, part1_adopted_ac2: { storedCode: "4" }, part1_targettask_tt1: { storedCode: "5" }, part1_targettask_tt2: { storedCode: "2" },
      comp_s1_q1: { storedCode: rating }, comp_s1_notes: { textValue: `${tag}-NOTE` },
    },
  });
  assert.equal(saved.status, 200, saved.text);
  const done = await c.call("POST", `/api/walks/${created.json.walk.id}/complete`, { rowVersion: saved.json.walk.rowVersion, clientMutationId: crypto.randomUUID().toUpperCase() });
  assert.equal(done.status, 200, done.text);
  return created.json.walk.id;
}

async function openHome(page) {
  await page.goto(home, { waitUntil: "networkidle" });
  await page.waitForSelector("body[data-ready=true]", { timeout: 20000 });
}

/** Home, then Reports: a walk-and-report role lands on My walks, a report-only role on Reports. */
async function openReports(page) {
  await openHome(page);
  if (await page.isVisible("#nav-reports-btn")) await page.click("#nav-reports-btn");
}

/** Chooses this suite's own release (another may be newer) and runs the report. */
async function readOwnRelease(page) {
  await page.waitForFunction(() => /^Report updated/.test(document.getElementById("report-status").textContent), null, { timeout: 20000 });
  await page.selectOption("#rf-source", release.releaseId);
  await page.click("#report-run");
  await waitForReport(page, "Report updated: 3 walks.");
}

async function waitForReport(page, text) {
  try {
    await page.waitForFunction((t) => document.getElementById("report-status").textContent === t, text, { timeout: 20000 });
  } catch (e) {
    const shown = await page.evaluate(() => [document.getElementById("report-status").textContent, document.getElementById("report-error").textContent]);
    throw new Error(`waited for [${text}], the status says [${shown[0]}] and the error says [${shown[1]}]`, { cause: e });
  }
}

async function axe(page) {
  if (!(await page.evaluate(() => Boolean(window.axe)))) await page.addScriptTag({ url: `${baseUrl(env)}/assets/js/axe.min.js` });
  const violations = await page.evaluate(async () => {
    const r = await window.axe.run(document, { runOnly: { type: "tag", values: ["wcag2a", "wcag2aa", "wcag21a", "wcag21aa"] } });
    return r.violations.map((v) => ({ id: v.id, impact: v.impact, nodes: v.nodes.length, help: v.help }));
  });
  return violations.filter((v) => v.impact === "serious" || v.impact === "critical");
}

before(async () => {
  if (skip) return;
  const imported = await api(env, "POST", "/api/maintenance/org-units/import", { token, body: { orgUnits: [
    { code: `${tag}-district`, type: "DISTRICT", name: "Report browser district", parentCode: null },
    { code: `${tag}-school-a`, type: "SCHOOL", name: "Report browser school A", parentCode: `${tag}-district` },
    { code: `${tag}-school-b`, type: "SCHOOL", name: XSS_NAME, parentCode: `${tag}-district` },
  ] } });
  assert.equal(imported.status, 200, imported.text);
  for (const [subject, roleCode, unit, descendants] of [[walkerA, "SCHOOL_WALK_REPORT", "school-a", false], [walkerB, "SCHOOL_WALK_REPORT", "school-b", false],
    [analyst, "DISTRICT_REPORT_ONLY", "district", true], [districtWalker, "DISTRICT_WALK_REPORT", "district", true]]) {
    const u = await api(env, "POST", "/api/maintenance/identity/provision-user", { token, body: { subject, displayName: `Fixture ${subject}` } });
    assert.ok(u.status === 201 || u.status === 200, u.text);
    const a = await api(env, "POST", "/api/maintenance/identity/assign-role", { token, body: { subject, roleCode, orgUnitCode: `${tag}-${unit}`, includeDescendants: descendants } });
    assert.equal(a.status, 201, a.text);
  }
  units.a = (await apiClient(walkerA)).me.permissions["walk.create"][0];
  units.b = (await apiClient(walkerB)).me.permissions["walk.create"][0];
  // A: three walks, a block at the minimum; B: one walk, never released.
  await completedWalk(walkerA, "2");
  await completedWalk(walkerA, "4");
  await completedWalk(walkerA, "4");
  await completedWalk(walkerB, "5");
  await provisionReleaser(env, token, releaser);
  const created = await (await apiClient(releaser)).call("POST", "/api/reports/releases", { observedFrom: FIRST_DAY, observedTo: LAST_DAY });
  assert.equal(created.status, 201, created.text);
  release = created.json.release;
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

test("RPT-03 (browser): a report-only user reads released figures only and is never sent a withheld value", { skip }, async () => {
  const { context, page } = await newContext(analyst);
  const requested = [];
  const reportBodies = [];
  page.on("request", (r) => requested.push(new URL(r.url())));
  page.on("response", async (r) => {
    if (new URL(r.url()).pathname.endsWith("/api/reports/aggregate")) reportBodies.push(await r.json());
  });
  await openHome(page);
  await readOwnRelease(page);
  assert.equal(await page.isVisible("#view-reports"), true);
  assert.equal(await page.isVisible("#view-list"), false, "My walks is never shown to a report-only role");
  assert.equal(await page.isVisible("#nav-list-btn"), false);
  assert.equal(await page.isVisible("#nav-reports-btn"), false, "already on Reports");
  assert.equal(await page.isVisible("#app-message"), false, "no error from a walk route");
  assert.equal(await page.isVisible("#release-form"), false, "a report-only role cannot release dates");
  const paths = requested.map((u) => u.pathname);
  assert.ok(!paths.some((p) => /\/api\/walks|\/api\/instrument\/current/.test(p)), `walk routes were requested: ${paths.join(", ")}`);
  const aggregates = requested.filter((u) => u.pathname.endsWith("/api/reports/aggregate"));
  assert.ok(aggregates.length >= 1 && aggregates.every((u) => u.searchParams.get("releaseId") === release.releaseId), "every report request names the release; none asks for live figures");
  // Only released dates are offered: no current data.
  const sourcesOffered = await page.$$eval("#rf-source option", (o) => o.map((x) => x.value));
  assert.ok(!sourcesOffered.includes("live") && sourcesOffered.includes(release.releaseId), sourcesOffered.join(", "));
  for (const id of ["rf-from", "rf-to", "rf-answer-item", "rf-drafts"]) assert.equal(await page.locator(`#${id}`).count(), 0, `${id} is not offered on a release`);
  assert.match(await page.textContent("#report-results .report-total"), /^3 walks \(completed: 3\)$/);
  // School A's ratings (one 2, two 4s) cannot be released without revealing the single 2, so the
  // whole distribution and its average are withheld -- and the page was never sent them.
  const rating = page.locator('.report-item[data-item-key="comp_s1_q1"]');
  assert.equal(await rating.locator(".report-avg").textContent(), "Average withheld: too few ratings could be released.");
  const cells = await rating.locator("tbody td").allTextContents();
  assert.ok(cells.length === 5 && cells.every((c) => c === "Withheld"), cells.join(", "));
  const body = reportBodies.at(-1);
  const sent = body.items.find((i) => i.itemKey === "comp_s1_q1");
  assert.ok(sent.options.every((o) => o.count === null && o.withheld === true), "the server sent no withheld count to hide");
  assert.equal(sent.scored.mean, null);
  assert.equal(sent.scored.responses, null);
  // The download is the release's export.
  const href = new URL(await page.getAttribute("#report-download", "href"), home);
  assert.equal(href.searchParams.get("releaseId"), release.releaseId);
  // Nothing on the page identifies a walk or carries its narrative.
  const pageText = await page.textContent("body");
  assert.ok(!pageText.includes(`${tag}-NOTE`), "no note text");
  assert.ok(!pageText.includes(`Fixture ${walkerA}`), "no owner name");
  // A school with one walk is withheld, and says so without a count.
  await page.selectOption("#rf-org", units.b);
  await page.click("#report-run");
  await waitForReport(page, "Report updated. Results are withheld for this selection.");
  assert.equal(await page.textContent("#report-results .report-suppressed"), "Nothing is released for this selection: groups of fewer than 3 walks are never released.");
  assert.equal(await page.locator("#report-results .report-item").count(), 0);
  await context.close();
});

test("RPT-07 (browser): filters narrow the population and the CSV download is the route's own file", { skip }, async () => {
  const { context, page } = await newContext(districtWalker);
  await openReports(page);
  await waitForReport(page, "Report updated: 4 walks.");
  assert.equal(await page.$eval("#rf-source", (s) => s.value), "live", "current data first for someone who can open every walk");
  await page.selectOption("#rf-org", units.a);
  await page.click("#report-run");
  await waitForReport(page, "Report updated: 3 walks.");
  assert.equal(await page.locator('.report-item[data-item-key="comp_s1_q1"] .report-avg').textContent(), "Average 3.33 from 3 rated responses");
  const states = await page.locator('.report-item[data-item-key="comp_s3_q1"] .report-states').textContent();
  assert.equal(states, "Answered: 0 · Not answered: 0 · Not applicable: 3 · Hidden: 0", "not applicable is its own count, never a zero rating");

  // The answer filter needs a question first.
  assert.equal(await page.isDisabled("#rf-answer"), true);
  await page.selectOption("#rf-answer-item", "comp_s1_q1");
  assert.equal(await page.isDisabled("#rf-answer"), false);
  await page.selectOption("#rf-answer", "4");
  await page.click("#report-run");
  await waitForReport(page, "Report updated: 2 walks.");

  const href = await page.getAttribute("#report-download", "href");
  const url = new URL(href, home);
  assert.equal(url.searchParams.get("orgUnitId"), units.a);
  assert.equal(url.searchParams.get("optionItem"), "comp_s1_q1");
  assert.equal(url.searchParams.get("option"), "4");
  assert.equal(url.searchParams.get("releaseId"), null, "current data names no release");
  const [download] = await Promise.all([page.waitForEvent("download", { timeout: 20000 }), page.click("#report-download")]);
  assert.match(download.suggestedFilename(), /^ICFWalk_report_[A-Za-z0-9_-]+_\d{8}\.csv$/);
  const file = fs.readFileSync(await download.path());
  const direct = Buffer.from(await (await fetch(url, { headers: { "X-ICFWalk-Dev-Subject": districtWalker } })).arrayBuffer());
  const withoutTimestamp = (b) => b.toString("utf8").split("\r\n").filter((l) => !l.startsWith("META,,generated_at,")).join("\r\n");
  assert.equal(withoutTimestamp(file), withoutTimestamp(direct), "the downloaded file is the route's file (only the generation time differs)");
  assert.deepEqual([...file.subarray(0, 3)], [0xef, 0xbb, 0xbf]);
  assert.ok(file.toString("utf8").includes("\r\nPOPULATION,,walks,,2,0,,,\r\n"));

  // Switching to the release offers only what a release takes, and clears the stale results.
  await page.selectOption("#rf-source", release.releaseId);
  assert.equal(await page.locator("#report-results > *").count(), 0);
  for (const id of ["rf-from", "rf-to", "rf-answer-item", "rf-drafts"]) assert.equal(await page.locator(`#${id}`).count(), 0, `${id} is not offered on a release`);
  await page.click("#report-run");
  await waitForReport(page, "Report updated: 3 walks.");
  await context.close();
});

test("a refused filter is announced and leaves no stale results behind", { skip }, async () => {
  const { context, page } = await newContext(districtWalker);
  await openReports(page);
  await waitForReport(page, "Report updated: 4 walks.");
  await page.fill("#rf-from", "2026-05-01");
  await page.fill("#rf-to", "2026-04-01");
  await page.click("#report-run");
  await page.waitForSelector("#report-error:not([hidden])");
  const message = await page.textContent("#report-error");
  assert.match(message, /REPORT_DATE_RANGE_INVALID/);
  assert.equal(await page.getAttribute("#report-error", "role"), "alert");
  assert.equal(await page.locator("#report-results > *").count(), 0, "the previous report is not left on screen as if it answered this one");
  await page.click("#report-reset");
  await waitForReport(page, "Report updated: 4 walks.");
  assert.equal(await page.isVisible("#report-error"), false);
  await context.close();
});

test("a walk user moves between My walks and Reports and sees only their own scope", { skip }, async () => {
  const { context, page } = await newContext(walkerA);
  await openHome(page);
  assert.equal(await page.isVisible("#view-list"), true);
  assert.equal(await page.locator(".walk-card").count(), 3);
  assert.equal(await page.isVisible("#nav-reports-btn"), true);
  await page.click("#nav-reports-btn");
  await waitForReport(page, "Report updated: 3 walks.");
  assert.equal(await page.isVisible("#view-list"), false);
  assert.equal(await page.isVisible("#nav-list-btn"), true);
  const units = await page.$$eval("#rf-org option", (options) => options.map((o) => o.textContent));
  assert.deepEqual(units, ["All schools I can report on", "Report browser school A"], "a school walker reports on their school only");
  await page.click("#nav-list-btn");
  await page.waitForSelector("#view-list:not([hidden])");
  assert.equal(await page.locator(".walk-card").count(), 3, "My walks is intact");
  assert.equal(await page.isVisible("#nav-reports-btn"), true);
  await context.close();
});

test("SEC-02 (browser): stored markup in an org unit name is shown as text and never runs", { skip }, async () => {
  const { context, page } = await newContext(districtWalker);
  await openReports(page);
  await waitForReport(page, "Report updated: 4 walks.");
  const cells = await page.$$eval('#report-results table tbody th', (ths) => ths.map((t) => t.textContent));
  assert.ok(cells.includes(XSS_NAME), "the name is printed literally");
  assert.equal(await page.locator("#report-results img").count(), 0, "no element was created from it");
  assert.equal(await page.evaluate(() => window.__rptXss), undefined, "and no handler ran");
  const options = await page.$$eval("#rf-org option", (o) => o.map((x) => x.textContent));
  assert.ok(options.includes(XSS_NAME));
  await context.close();
});

test("releases (browser): someone who can open every walk releases dates from the page", { skip }, async () => {
  const { context, page } = await newContext(releaser);
  await openHome(page);
  await page.click("#nav-reports-btn");
  // The releaser can open every walk in the database, so its live total is not this suite's to fix.
  await page.waitForFunction(() => /^Report updated: /.test(document.getElementById("report-status").textContent), null, { timeout: 20000 });
  assert.equal(await page.isVisible("#release-form"), true);
  const first = `${FIRST_DAY.slice(0, 8)}10`;
  const last = `${FIRST_DAY.slice(0, 8)}12`;
  await page.fill("#release-from", first);
  await page.fill("#release-to", last);
  await page.focus("#release-create");
  await page.keyboard.press("Enter");
  await waitForReport(page, `Released walks observed ${first} to ${last}.`);
  const chosen = await page.$eval("#rf-source", (s) => s.options[s.selectedIndex].textContent);
  assert.equal(chosen, `Released: walks observed ${first} to ${last}`, "the new release is offered and chosen");
  await page.click("#report-run");
  await waitForReport(page, "Report updated. Results are withheld for this selection.");
  // The same dates again overlap and are refused, and the refusal is announced.
  await page.focus("#release-create");
  await page.keyboard.press("Enter");
  await page.waitForSelector("#report-error:not([hidden])");
  assert.match(await page.textContent("#report-error"), /REPORT_RELEASE_OVERLAP/);
  assert.deepEqual(pageErrors, [], "no page errors");
  await context.close();
});

test("A11Y-01 / A11Y-03 / A11Y-05: keyboard operation, axe-core, and 375 px without horizontal loss", { skip }, async () => {
  const { context, page } = await newContext(districtWalker);
  const axeSource = fs.readFileSync(require.resolve("axe-core/axe.min.js"), "utf8");
  await page.route("**/assets/js/axe.min.js", (route) => route.fulfill({ status: 200, contentType: "application/javascript", body: axeSource }));
  await openReports(page);
  await waitForReport(page, "Report updated: 4 walks.");

  // Every filter control has an accessible name, and the form runs from the keyboard.
  const unnamed = await page.$$eval("#report-form select, #report-form input, #report-form button, #report-form a", (els) =>
    els.filter((e) => !(e.labels && e.labels.length) && !e.getAttribute("aria-label") && !e.textContent.trim()).map((e) => e.id || e.tagName));
  assert.deepEqual(unnamed, []);
  await page.focus("#rf-org");
  await page.keyboard.press("End");
  const chosen = await page.$eval("#rf-org", (s) => s.value);
  assert.ok(chosen === units.a || chosen === units.b, "End chose the last school in the list");
  await page.focus("#report-run");
  await page.keyboard.press("Enter");
  await waitForReport(page, chosen === units.a ? "Report updated: 3 walks." : "Report updated: 1 walk.");
  assert.equal(await page.evaluate(() => document.activeElement && document.activeElement.id), "report-run", "focus stays on Run while and after the report runs");
  assert.equal(await page.evaluate(() => document.getElementById("report-status").getAttribute("role")), "status");
  await page.keyboard.press("Shift+Tab");
  assert.equal(await page.evaluate(() => document.activeElement && document.activeElement.id), "rf-drafts", "focus order runs through the form");

  await page.click("#report-reset");
  await waitForReport(page, "Report updated: 4 walks.");
  assert.deepEqual(await axe(page), [], "desktop");
  await page.screenshot({ path: path.join(shotDir, "reports-desktop.png"), fullPage: false });

  for (const width of [768, 375]) {
    await page.setViewportSize({ width, height: 800 });
    await page.waitForTimeout(150);
    const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
    assert.ok(overflow <= 0, `no horizontal overflow at ${width}px (${overflow}px)`);
  }
  assert.deepEqual(await axe(page), [], "375 px");
  await page.locator('.report-item[data-item-key="comp_s1_q1"]').scrollIntoViewIfNeeded();
  await page.screenshot({ path: path.join(shotDir, "reports-phone.png"), fullPage: false });
  await context.close();

  // The released view a report-only user sees, withheld figures and all, passes too.
  const released = await newContext(analyst, { width: 375, height: 800 });
  await released.page.route("**/assets/js/axe.min.js", (route) => route.fulfill({ status: 200, contentType: "application/javascript", body: axeSource }));
  await openHome(released.page);
  await readOwnRelease(released.page);
  assert.deepEqual(await axe(released.page), [], "the released view at 375 px");
  const overflow = await released.page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
  assert.ok(overflow <= 0, `no horizontal overflow on the released view (${overflow}px)`);
  assert.deepEqual(pageErrors, [], "no page errors");
  await released.context.close();
});
