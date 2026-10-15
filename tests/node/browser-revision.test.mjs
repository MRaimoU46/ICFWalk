/**
 * The 2026-10-14 instrument revision against the running application (docs/INSTRUMENT_REVISION_2026-10-14.md):
 *
 *   - config/instrument-config-2026-10-14.json imports through Instrument admin as a DRAFT whose
 *     definitions checksum is the one the reference compiler records, and publishes;
 *   - a walk on that version is served the version's own model, saves on the 4-point scale with
 *     Academic Teaming's third question, "Pacing NOT evident", the new Program and Content / Subject
 *     Area values, and refuses a 5, a value this version does not offer, and the removed tag field;
 *   - the server's summary of that walk is byte-identical to the browser formatter's, prints x/4,
 *     the three-question average, and Target/Task Alignment before Adopted Curriculum;
 *   - the editor renders it: level names in the definitions ("1 · Not evident:") for scored items
 *     only, the new header, the visit fields, keyboard-reachable controls, axe-core and 375 px.
 *
 * Everything lives under this run's own instrument code, so nothing here publishes anything on the
 * ICFWALK instrument the rest of the suite runs on; the maintenance cleanup removes it afterwards.
 * The 2026-09-17 version's own rendering ("1:" definitions) stays covered by browser.test.mjs COND-14.
 */
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { createRequire } from "node:module";
import sql from "mssql";
import { api, baseUrl, connectionConfig, hasDatabaseConfig, loadRuntimeEnv, requireApp, root, screenshotDir } from "./helpers.mjs";
import { evaluate } from "../../app/assets/js/rules.js";
import { summaryText } from "../../app/assets/js/summary.js";
import { readPrototype } from "../../scripts/lib/prototype.mjs";

const require = createRequire(import.meta.url);
const env = loadRuntimeEnv();
const token = env.ICFWALK_MAINTENANCE_TOKEN || "";
const tag = `brrev-${Date.now().toString(36)}`;
const instrumentCode = `${tag}-instrument`;
const adminSubject = `${tag}-admin`;
const walkerSubject = `${tag}-walker`;
const shotDir = screenshotDir(env);
const DOC = JSON.parse(fs.readFileSync(path.join(root, "config", "instrument-config-2026-10-14.json"), "utf8"));
const GOLDEN = JSON.parse(fs.readFileSync(path.join(root, "tests", "golden", "instrument-snapshot-2026-10-14.golden.json"), "utf8"));
const P = readPrototype(fs.readFileSync(path.join(root, "source", "prototype-2026-10-14.html"), "utf8"));

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
if (requireApp(env) && !up) throw new Error(`ICFWALK_REQUIRE_APP is set but the application is not reachable in development mode at ${baseUrl(env)}`);
if (requireApp(env) && !token) throw new Error("ICFWALK_REQUIRE_APP is set but ICFWALK_MAINTENANCE_TOKEN is not");
if (requireApp(env) && !hasDatabaseConfig(env)) throw new Error("ICFWALK_REQUIRE_APP is set but ICFWALK_DB_* is not configured");
if (requireApp(env) && !chromium) throw new Error("ICFWALK_REQUIRE_APP is set but playwright is not installed");
const skip = !chromium ? "playwright is not installed"
  : !up ? `application not reachable in development mode at ${baseUrl(env)}`
  : !token ? "ICFWALK_MAINTENANCE_TOKEN not set"
  : !hasDatabaseConfig(env) ? "ICFWALK_DB_* not configured"
  : false;

// ---- a signed-in API client (cookie session + CSRF), as the browser has ------------------------

async function client(subject) {
  const cookies = new Map();
  let csrf = "";
  async function call(method, p, body) {
    const headers = { Accept: "application/json", "X-ICFWalk-Dev-Subject": subject };
    if (body !== undefined) headers["Content-Type"] = "application/json";
    if (csrf) headers["X-ICFWalk-CSRF-Token"] = csrf;
    if (cookies.size) headers.Cookie = [...cookies.entries()].map(([k, v]) => `${k}=${v}`).join("; ");
    const response = await fetch(`${baseUrl(env)}/index.cfm${p}`, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
    for (const line of response.headers.getSetCookie ? response.headers.getSetCookie() : []) {
      const [pair] = line.split(";");
      const eq = pair.indexOf("=");
      cookies.set(pair.slice(0, eq).trim(), pair.slice(eq + 1).trim());
    }
    const text = await response.text();
    let json = null;
    try { json = JSON.parse(text); } catch { json = null; }
    return { status: response.status, json, text, headers: response.headers };
  }
  const me = await call("GET", "/api/me");
  assert.equal(me.status, 200, me.text);
  csrf = me.json.csrfToken;
  return { call };
}

let pool = null;
async function query(text, params = {}) {
  if (!pool) pool = await sql.connect(connectionConfig(env, env.ICFWALK_DB_NAME || "icfwalk_dev"));
  const request = pool.request();
  for (const [k, v] of Object.entries(params)) request.input(k, v);
  return (await request.query(text)).recordset;
}

// ---- fixtures ------------------------------------------------------------------------------------

let admin, walker, walkerUserId, districtId, imported, walkId, browser;

/** The walk this file saves: one answer of every kind the revision touches. */
const STATE = {
  dimensions: {
    date: { dateValue: "2026-10-14" },
    observer: { textValue: "Revision Walker" },
    // The prototype's checkboxes take several values (step 2): one each here; several are
    // tests/node/browser-multiple.test.mjs.
    grade: { selectedValueCodes: ["7"] },
    content: { selectedValueCodes: ["visual_arts"] },
    period: { selectedValueCode: "second" },
    classType: { selectedValueCodes: ["dhh"] },
    visitTiming: { selectedValueCodes: ["middle_of_the_lesson"] },
    topic: { textValue: "RL.7.2" },
  },
  responses: {
    p1q1: { storedCode: "Yes" },
    p1q2: { storedCode: "Analysis" },
    p1q3: { storedCode: "Comprehension" },
    part1_targettask_tt1: { storedCode: "4" },
    part1_targettask_tt2: { storedCode: "3" },
    part1_targettask_notes: { textValue: "Targets posted and referenced." },
    part1_adopted_pacing: { storedCode: "notevident" },
    part1_adopted_ac1: { storedCode: "2" },
    part1_adopted_ac2: { storedCode: "1" },
    content_area_q1: { storedCode: "yes" },
    content_area_q2: { storedCode: "no" },
    comp_s1_q1: { storedCode: "3" },
    comp_s1_q2: { storedCode: "4" },
    comp_s2_q1: { storedCode: "2" },
    comp_s2_q2: { storedCode: "2" },
    comp_s3_applicable: { storedCode: "no" },
    comp_s3_notes: { textValue: "Not a workshop day." },
    comp_s4_applicable: { storedCode: "yes" },
    comp_s4_q1: { storedCode: "4" },
    comp_s4_q2: { storedCode: "3" },
    comp_s4_q3: { storedCode: "3" },
    comp_s5_q1: { storedCode: "1" },
    comp_s5_q2: { storedCode: "2" },
    comp_s6_q1: { storedCode: "4" },
    comp_s7_q1: { storedCode: "3" },
    comp_s7_q2: { storedCode: "3" },
    conditions_b1: { storedCode: "4" },
    conditions_b2: { storedCode: "3" },
    conditions_b3: { storedCode: "3" },
    conditions_b4: { storedCode: "2" },
    conditions_b5: { storedCode: "1" },
    conditions_b6: { storedCode: "4" },
    summary_strengths: { textValue: "Students coached one another through the hard part." },
    summary_growth: { textValue: "Make the pacing position visible." },
  },
};

before(async () => {
  if (skip) return;
  const units = await api(env, "POST", "/api/maintenance/org-units/import", { token, body: { orgUnits: [
    { code: `${tag}-district`, type: "DISTRICT", name: "Revision fixture district", parentCode: null },
  ] } });
  assert.equal(units.status, 200, units.text);
  for (const subject of [adminSubject, walkerSubject]) {
    const r = await api(env, "POST", "/api/maintenance/identity/provision-user", { token, body: { subject, displayName: `Revision ${subject}` } });
    assert.ok(r.status === 201 || r.status === 200, r.text);
    if (subject === walkerSubject) walkerUserId = r.json.userId;
  }
  const a = await api(env, "POST", "/api/maintenance/identity/assign-role", { token, body: { subject: adminSubject, roleCode: "MASTER_INSTRUMENT_ADMIN", orgUnitCode: `${tag}-district` } });
  assert.equal(a.status, 201, a.text);
  const w = await api(env, "POST", "/api/maintenance/identity/assign-role", { token, body: { subject: walkerSubject, roleCode: "DISTRICT_WALK_REPORT", orgUnitCode: `${tag}-district`, includeDescendants: true } });
  assert.equal(w.status, 201, w.text);
  districtId = w.json.orgUnitId;
  admin = await client(adminSubject);
  walker = await client(walkerSubject);
  browser = await chromium.launch();
  fs.mkdirSync(shotDir, { recursive: true });
});

after(async () => {
  if (browser) await browser.close();
  if (!skip) {
    const r = await api(env, "POST", "/api/maintenance/identity/cleanup-fixtures", { token, body: { tag } });
    if (r.status !== 200) console.error("revision fixture cleanup failed", r.status, r.text);
  }
  if (pool) { await pool.close(); pool = null; }
});

// ---- import and publication ------------------------------------------------------------------------

test("REV-E1 the 2026-10-14 document imports through Instrument admin with the recorded checksum, and publishes", { skip }, async () => {
  const doc = structuredClone(DOC);
  doc.instrument.code = instrumentCode;
  const r = await admin.call("POST", "/api/admin/instrument/import", { document: doc });
  assert.equal(r.status, 201, r.text);
  imported = r.json;
  assert.equal(imported.status, "DRAFT");
  assert.equal(imported.versionLabel, "2026-10-14 prototype revision");
  assert.equal(imported.definitionsChecksum, GOLDEN.definitionsChecksum, "SQL Server holds exactly the definitions the reference compiler compiled");
  const { placeholders, ...counts } = GOLDEN.counts;
  for (const [key, n] of Object.entries(counts)) assert.equal(imported.counts[key], n, key);
  assert.equal(imported.counts.placeholders, placeholders);

  const published = await admin.call("POST", `/api/admin/instrument/versions/${imported.versionId}/publish`);
  assert.equal(published.status, 200, published.text);
  assert.equal(published.json.status, "PUBLISHED");

  // A walk on the new version, placed directly: walks start only on the ICFWALK runtime instrument,
  // and this fixture instrument is not that.
  walkId = randomUUID().toUpperCase();
  await query(
    "INSERT INTO icf.walk (walk_id, version_id, org_unit_id, owner_user_id, status) VALUES (@w, @v, @o, @u, N'DRAFT')",
    { w: walkId, v: imported.versionId, o: districtId, u: walkerUserId });
});

// ---- the walk path -----------------------------------------------------------------------------------

test("REV-E2 a walk on the new version is served that version's model", { skip }, async () => {
  const r = await walker.call("GET", `/api/walks/${walkId}/instrument`);
  assert.equal(r.status, 200, r.text);
  assert.equal(r.json.version.versionId.toUpperCase(), imported.versionId.toUpperCase());
  const model = r.json.model;
  assert.deepEqual(model.behavior.ratings.levelNames, P.SCALE_NAMES);
  const sections = {};
  const walk = (n) => { sections[n.sectionKey] = n; n.children.forEach(walk); };
  walk(model.root);
  assert.deepEqual(sections.part1.children.map((s) => s.sectionKey), ["target_taxonomy", "part1_targettask", "part1_adopted"]);
  const rated = (key) => sections[key].items.filter((i) => i.layout === "question" && i.responseSet.scoreEnabled);
  assert.deepEqual(rated("s4").map((i) => i.itemKey), ["comp_s4_q1", "comp_s4_q2", "comp_s4_q3"]);
  for (const key of ["part1_targettask", "part1_adopted", "s1", "s4", "s7", "part3"]) {
    for (const it of rated(key)) assert.deepEqual(it.responseSet.options.map((o) => o.storedCode), ["1", "2", "3", "4"], it.itemKey);
  }
  assert.deepEqual(sections.part1_adopted.items.find((i) => i.itemKey === "part1_adopted_pacing").responseSet.options.map((o) => o.label),
    ["Pacing NOT evident", "BEHIND pacing", "ON pace", "AHEAD of pacing"]);
  assert.equal(model.dimensions.classType.label, "Program");
  assert.deepEqual(model.dimensions.classType.values.map((v) => v.label), P.CLASS_TYPE_OPTIONS);
  assert.equal(model.dimensions.content.label, "Content / Subject Area");
  assert.deepEqual(model.dimensions.content.values.map((v) => v.label), P.CONTENT_OPTIONS);
  assert.equal(model.dimensions.tag, undefined, "no tag field in this version");
});

test("REV-E3 the walk saves on the 4-point scale and refuses a 5, a value this version does not offer, and the tag field", { skip }, async () => {
  const opened = await walker.call("GET", `/api/walks/${walkId}`);
  assert.equal(opened.status, 200, opened.text);
  const rowVersion = opened.json.walk.rowVersion;
  const put = (state) => walker.call("PUT", `/api/walks/${walkId}`, { rowVersion, clientMutationId: randomUUID(), ...state });

  const refusals = [
    [{ dimensions: STATE.dimensions, responses: { ...STATE.responses, comp_s1_q1: { storedCode: "5" } } }, "INVALID_OPTION", "responses.comp_s1_q1.storedCode"],
    [{ dimensions: { ...STATE.dimensions, content: { selectedValueCodes: ["music"] } }, responses: STATE.responses }, "INVALID_DIMENSION_VALUE", "dimensions.content"],
    [{ dimensions: { ...STATE.dimensions, tag: { textValue: "cohort B" } }, responses: STATE.responses }, "UNKNOWN_DIMENSION", "dimensions.tag"],
  ];
  for (const [body, code, at] of refusals) {
    const r = await put(body);
    assert.ok(r.status === 400 || r.status === 422, `${at}: ${r.status} ${r.text}`);
    const issues = JSON.stringify(r.json);
    assert.ok(issues.includes(at), `${at} is named: ${issues}`);
    if (code) assert.ok(issues.includes(code), `${code}: ${issues}`);
  }
  const unchanged = await walker.call("GET", `/api/walks/${walkId}`);
  assert.equal(unchanged.json.walk.rowVersion, rowVersion, "a refused save writes nothing");

  const saved = await put(STATE);
  assert.equal(saved.status, 200, saved.text);
  const reread = await walker.call("GET", `/api/walks/${walkId}`);
  const state = reread.json.walk.state;
  assert.equal(state.responses.comp_s4_q3.storedCode, "3");
  assert.equal(state.responses.part1_adopted_pacing.storedCode, "notevident");
  assert.deepEqual(state.dimensions.classType.selectedValueCodes, ["dhh"]);
  assert.deepEqual(state.dimensions.content.selectedValueCodes, ["visual_arts"]);
});

test("REV-E4 the server summary equals the browser formatter's and reads as the new prototype does", { skip }, async () => {
  const instrument = await walker.call("GET", `/api/walks/${walkId}/instrument`);
  const model = instrument.json.model;
  const opened = await walker.call("GET", `/api/walks/${walkId}`);
  const state = opened.json.walk.state;
  const server = await walker.call("GET", `/api/walks/${walkId}/summary`);
  assert.equal(server.status, 200, server.text);
  const text = server.text;
  assert.equal(text, summaryText(model, state, evaluate(model, state)), "the CFML and JavaScript formatters agree byte for byte");

  const lines = text.split("\n");
  const has = (line) => assert.ok(lines.includes(line), `summary has ${JSON.stringify(line)}\n${text}`);
  has("Content / Subject Area: Visual Arts");
  has("Program: DHH");
  has("Visit occurred at the: Middle of the Lesson");
  has("Period: Second");
  has("Lesson Standard: RL.7.2");
  has("- Pacing:  [Pacing NOT evident]");
  has(`- ${P.PART1_SECTIONS[0].qs[0].text}  [4/4]`);
  has(`- ${P.PART1_SECTIONS[1].qs[1].text}  [1/4]`);
  has("2.3 WORKSHOP MODEL OF INSTRUCTION  (not part of this lesson at the time of the visit)");
  has("2.4 ACADEMIC TEAMING  (avg: 3.3)");
  has(`- ${P.COMPONENTS[3].qs[2].text}  [3/4]`);
  has(`- ${P.COMPONENTS[5].qs[1].text}  [not answered]`);
  has("2.6 ACTIONABLE FEEDBACK  (avg: 4.0)");
  has(`- ${P.BELONGING_QS[4].text}  [1/4]`);
  assert.ok(lines.indexOf("TARGET/TASK ALIGNMENT") > 0 && lines.indexOf("TARGET/TASK ALIGNMENT") < lines.indexOf("ADOPTED CURRICULUM"), "Target/Task Alignment prints first");
  assert.ok(!text.includes("/5]"), "nothing is out of 5");
  assert.ok(!text.includes("disaggregation tag"), "no tag line");
  assert.equal(server.headers.get("content-disposition"), 'attachment; filename="ICFWalk_7_Visual_Arts_2026-10-14.txt"');
});

// ---- the editor --------------------------------------------------------------------------------------

test("REV-E5 the editor renders the new version: level names, the third Teaming question, Part 1 order, the visit fields and the header", { skip }, async () => {
  const context = await browser.newContext({ extraHTTPHeaders: { "X-ICFWalk-Dev-Subject": walkerSubject }, viewport: { width: 1280, height: 900 } });
  const page = await context.newPage();
  const pageErrors = [];
  page.on("pageerror", (e) => pageErrors.push(String(e)));
  const axeSource = fs.readFileSync(require.resolve("axe-core/axe.min.js"), "utf8");
  await page.route("**/assets/js/axe.min.js", (route) => route.fulfill({ status: 200, contentType: "application/javascript", body: axeSource }));
  await page.goto(`${baseUrl(env)}/index.cfm/`, { waitUntil: "networkidle" });
  await page.waitForSelector("body[data-ready=true]", { timeout: 20000 });

  // The header the new prototype draws.
  assert.equal((await page.textContent(".brand > div")).replace(/\s+/g, " ").trim(), "School District U-46 · Instructional Clarity FrameworkINSTRUCTIONAL WALK");
  assert.equal(await page.textContent(".brand small"), "INSTRUCTIONAL WALK");

  // The list titles this walk from its own version, although the runtime instrument is another one.
  await page.getByRole("button", { name: "Open 7 · Visual Arts" }).click();
  await page.waitForSelector("#view-walk:not([hidden])");
  assert.equal(await page.textContent("#version-note"), "Instrument version: 2026-10-14 prototype revision.");

  // Visit fields: the new labels and lists, the prototype's checkboxes, and no tag field.
  const dims = await page.$$eval("[data-dimension-code]", (els) => els.map((e) => e.dataset.dimensionCode));
  assert.deepEqual(dims, ["date", "observer", "school", "grade", "content", "period", "classType", "visitTiming", "topic"]);
  assert.equal(await page.textContent('[data-dimension-code="classType"] legend'), "Program");
  assert.equal(await page.textContent('[data-dimension-code="content"] legend'), "Content / Subject Area");
  const optionLabels = (code) => page.$$eval(`[data-dimension-code="${code}"] .check-option span`, (os) => os.map((o) => o.textContent));
  assert.deepEqual(await optionLabels("classType"), P.CLASS_TYPE_OPTIONS);
  assert.deepEqual(await optionLabels("content"), P.CONTENT_OPTIONS);
  assert.deepEqual(await page.$$eval('[data-dimension-code="classType"] input[type=checkbox]:checked', (bs) => bs.map((b) => b.value)), ["dhh"]);
  const visible = (key) => page.$eval(`[data-section-key="${key}"]`, (e) => !e.hidden && !e.closest("[hidden]"));
  assert.equal(await visible("content_area_look_fors"), true, "Visual Arts shows the content-area card");

  const expand = (key) => page.click(`[data-section-key="${key}"] > h2 > .acc-head, [data-section-key="${key}"] > h3 > .acc-head`);
  const pills = (itemKey) => page.$$eval(`[data-item-key="${itemKey}"] .pill`, (ps) => ps.map((p) => ({ code: p.dataset.code, label: p.textContent, pressed: p.getAttribute("aria-pressed") })));
  const defs = async (itemKey) => {
    await page.click(`[data-item-key="${itemKey}"] .defs-toggle`);
    return page.$$eval(`[data-item-key="${itemKey}"] .defs-row`, (els) => els.map((e) => e.textContent));
  };

  // Part 1: Target/Task Alignment first, Pacing with its new first option, the 4-point scale.
  await expand("part1");
  const before = await page.$eval('[data-section-key="part1_targettask"]', (a) =>
    Boolean(a.compareDocumentPosition(document.querySelector('[data-section-key="part1_adopted"]')) & Node.DOCUMENT_POSITION_FOLLOWING));
  assert.equal(before, true, "Target/Task Alignment renders before Adopted Curriculum");
  assert.deepEqual((await pills("part1_adopted_pacing")).map((p) => p.label), ["Pacing NOT evident", "BEHIND pacing", "ON pace", "AHEAD of pacing"]);
  assert.equal((await pills("part1_adopted_pacing")).find((p) => p.pressed === "true").code, "notevident");
  assert.deepEqual((await pills("part1_targettask_tt1")).map((p) => p.label), ["1", "2", "3", "4"]);
  const tt1 = P.PART1_SECTIONS[0].qs[0];
  assert.deepEqual(await defs("part1_targettask_tt1"), P.SCALE.map((l) => `${l} · ${P.SCALE_NAMES[l]}: ${tt1.defs[l]}`), "scored definitions lead with the level name");
  const p1q1 = P.PART1[0];
  assert.deepEqual(await defs("p1q1"), p1q1.options.map((o) => `${o}: ${p1q1.defs[o]}`), "an unscored choice keeps its own labels");
  const pacingDefs = await defs("part1_adopted_pacing");
  assert.equal(pacingDefs[0], `Pacing NOT evident: ${P.PART1_SECTIONS[1].pacing.options[0].def}`);

  // Academic Teaming: three questions while it applies, each on the 4-point scale.
  await expand("part2");
  await expand("s4");
  for (const key of ["comp_s4_q1", "comp_s4_q2", "comp_s4_q3"]) {
    assert.equal(await page.$eval(`[data-item-key="${key}"]`, (e) => !e.hidden), true, `${key} is shown`);
    assert.deepEqual((await pills(key)).map((p) => p.code), ["1", "2", "3", "4"]);
  }
  assert.deepEqual(await Promise.all(["comp_s4_q1", "comp_s4_q2", "comp_s4_q3"].map(async (k) => (await pills(k)).find((p) => p.pressed === "true").code)), ["4", "3", "3"]);
  assert.equal(await page.textContent('[data-section-key="s4"] .acc-count'), "3/3 rated");
  assert.equal(await page.textContent('[data-section-key="s3"] .acc-count'), "Not part of this lesson");
  const q3 = P.COMPONENTS[3].qs[2];
  assert.deepEqual(await defs("comp_s4_q3"), P.SCALE.map((l) => `${l} · ${P.SCALE_NAMES[l]}: ${q3.defs[l]}`));
  const lf = page.locator('[data-section-key="s4"] .lookfor-toggle');
  await lf.click();
  assert.deepEqual(await page.$$eval('[data-section-key="s4"] .lookfor-list li', (els) => els.map((e) => e.textContent)),
    [...P.COMPONENTS[3].studentActions, ...P.COMPONENTS[3].teacherActions]);

  await expand("part3");
  assert.deepEqual((await pills("conditions_b1")).map((p) => p.code), ["1", "2", "3", "4"]);
  await page.screenshot({ path: path.join(shotDir, "revision-editor-desktop.png"), fullPage: true });

  // axe-core (WCAG 2.1 AA) on the expanded editor, then 768 and 375 px without horizontal loss.
  const axe = async () => {
    if (!(await page.evaluate(() => Boolean(window.axe)))) await page.addScriptTag({ url: `${baseUrl(env)}/assets/js/axe.min.js` });
    const violations = await page.evaluate(async () => {
      const r = await window.axe.run(document, { runOnly: { type: "tag", values: ["wcag2a", "wcag2aa", "wcag21a", "wcag21aa"] } });
      return r.violations.map((v) => ({ id: v.id, impact: v.impact, nodes: v.nodes.length, targets: v.nodes.slice(0, 3).map((n) => n.target.join(" ")) }));
    });
    return violations.filter((v) => v.impact === "serious" || v.impact === "critical");
  };
  assert.deepEqual(await axe(), [], "desktop");
  for (const width of [768, 375]) {
    await page.setViewportSize({ width, height: 800 });
    await page.waitForTimeout(150);
    const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
    assert.ok(overflow <= 0, `no horizontal overflow at ${width}px (${overflow}px)`);
  }
  assert.deepEqual(await axe(), [], "375 px");
  await page.evaluate(() => window.scrollTo(0, 0));
  await page.screenshot({ path: path.join(shotDir, "revision-editor-phone.png"), fullPage: false });
  assert.deepEqual(pageErrors, [], "no page errors");
  await context.close();
});

// ---- the prototype as oracle ---------------------------------------------------------------------

/**
 * The prototype wraps its application in an IIFE, so its summary and email functions are private
 * to that closure. The page is loaded first (its wire-up needs the DOM), then the same script body
 * is injected again without the wrapper, with an epilogue that lets this test set its `current`
 * walk -- the device scripts/prototype-summary-oracle.mjs uses for the 2026-09-17 prototype.
 */
function unwrappedPrototypeScript(html) {
  const body = html.slice(html.indexOf("<script>") + "<script>".length, html.lastIndexOf("</script>"));
  const inner = body.slice(body.indexOf("(function(){") + "(function(){".length, body.lastIndexOf("})();"));
  return `${inner}\n;window.__setCurrent = function (w) { current = w; };\n`;
}

/** STATE in the prototype's own walk shape (labels where it stores labels, arrays for checkboxes). */
function prototypeWalk() {
  const r = (key) => (STATE.responses[key] || {}).storedCode || "";
  const t = (key) => (STATE.responses[key] || {}).textValue || "";
  return {
    meta: {
      date: "2026-10-14", observer: "Revision Walker", school: "", school_other: "",
      grade: ["7"], content: ["Visual Arts"], content_other: "", period: "Second", period_other: "",
      classType: ["DHH"], classType_other: "", visitTiming: ["Middle of the Lesson"], topic: "RL.7.2", tag: "",
    },
    part1: { p1q1: r("p1q1"), p1q2: r("p1q2"), p1q3: r("p1q3") },
    part1Sections: {
      targetTask: { tt1: r("part1_targettask_tt1"), tt2: r("part1_targettask_tt2"), notes: t("part1_targettask_notes") },
      adopted: { pacing: r("part1_adopted_pacing"), ac1: r("part1_adopted_ac1"), ac2: r("part1_adopted_ac2"), notes: t("part1_adopted_notes") },
    },
    part1Notes: "",
    components: Object.fromEntries(P.COMPONENTS.map((c) => {
      const applicable = r(`comp_${c.id}_applicable`);
      return [c.id, {
        applicable: applicable === "yes" ? true : applicable === "no" ? false : null,
        ratings: c.qs.map((q) => r(`comp_${c.id}_${q.id}`)),
        notes: t(`comp_${c.id}_notes`),
      }];
    })),
    belonging: { ...Object.fromEntries(P.BELONGING_QS.map((q) => [q.id, r(`conditions_${q.id}`)])), notes: t("conditions_notes") },
    summaryStrengths: t("summary_strengths"),
    summaryGrowth: t("summary_growth"),
    contentArea: { ...Object.fromEntries(P.CONTENT_AREA_ITEMS.map((q) => [q.id, r(`content_area_${q.id}`)])), notes: t("content_area_notes") },
  };
}

test("REV-E6 the summary and the email draft are the 2026-10-14 prototype's own, apart from the recorded deviations", { skip }, async () => {
  const instrument = await walker.call("GET", `/api/walks/${walkId}/instrument`);
  const model = instrument.json.model;
  const opened = await walker.call("GET", `/api/walks/${walkId}`);
  const state = opened.json.walk.state;
  const serverText = (await walker.call("GET", `/api/walks/${walkId}/summary`)).text;
  const html = fs.readFileSync(path.join(root, "source", "prototype-2026-10-14.html"), "utf8");
  const page = await browser.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e)));
  await page.goto(`file://${path.join(root, "source", "prototype-2026-10-14.html")}`);
  await page.addScriptTag({ content: unwrappedPrototypeScript(html) });
  await page.waitForFunction(() => typeof window.buildSummaryText === "function" && typeof window.__setCurrent === "function");
  const keySets = [[], ["part1"], ["comp_s4", "belonging"], ["part1", "comp_s1", "comp_s3", "comp_s4", "belonging", "summary"]];
  const oracle = await page.evaluate(({ walk, keySets }) => {
    const w = blankWalk();
    for (const [k, v] of Object.entries(walk)) w[k] = typeof v === "object" && v && !Array.isArray(v) ? { ...w[k], ...v } : v;
    window.__setCurrent(w);
    return { summaryText: buildSummaryText(), emails: keySets.map((keys) => generateEmailDraftFor(keys)) };
  }, { walk: prototypeWalk(), keySets });
  await page.close();
  assert.deepEqual(errors, [], "the prototype ran without errors");

  // Line by line: equal, or one of the deviations docs/PHASE_5_IMPLEMENTATION_BRIEF.md section 14
  // resolved for the 2026-09-17 prototype, which carry over unchanged.
  const ours = serverText.split("\n");
  const theirs = oracle.summaryText.split("\n");
  assert.equal(ours.length, theirs.length, `line count\n--- server\n${serverText}\n--- prototype\n${oracle.summaryText}`);
  const deviations = [];
  ours.forEach((line, i) => {
    if (line === theirs[i]) return;
    if (theirs[i].replace(/\[yes\]/g, "[Yes]").replace(/\[no\]/g, "[No]") === line) deviations.push("14.5");
    else if (theirs[i] === "VISUAL ARTS CLASSROOM" && line === "CONTENT-AREA LOOK-FORS") deviations.push("14.3");
    else assert.fail(`line ${i + 1} differs without a recorded deviation:\n  server:    ${JSON.stringify(line)}\n  prototype: ${JSON.stringify(theirs[i])}`);
  });
  assert.deepEqual([...new Set(deviations)].sort(), ["14.3", "14.5"]);

  // The email draft has no recorded deviation: the prototype's sentences are the contract.
  const { emailDraft } = await import("../../app/assets/js/summary.js");
  const evaluation = evaluate(model, state);
  keySets.forEach((keys, i) => {
    const mine = emailDraft(model, state, evaluation, keys);
    assert.equal(mine.subject, oracle.emails[i].subject, `subject for [${keys}]`);
    assert.equal(mine.body, oracle.emails[i].body, `body for [${keys}]`);
  });
});
