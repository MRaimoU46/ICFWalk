// Instrument revision 2026-10-14, step 2: Grade level, Content / Subject Area, Program and Visit timing
// take several values -- the prototype's checkboxes -- through SQL Server, the browser and the reports
// (docs/INSTRUMENT_REVISION_2026-10-14.md, "Step 2"). The engines, the save validator and the summary
// are also checked without a database in tests/cfml/specs/MultipleValuesTest.cfc.
//
//   MULTI-E1  the document imports with its golden checksum and publishes; exactly the four checkbox
//             fields take several values in the model a walk is served
//   MULTI-E2  the JavaScript engine reproduces tests/fixtures/visibility-vectors-multiple.json on that
//             model (the CFML engine runs the same vectors)
//   MULTI-E3  several values save in the version's order and read back the same, one row each; Other's
//             text goes only with Other, and text that spells "null" is text; the same values in another
//             order are no change to a completed walk; and every malformed submission is refused before
//             anything is written
//   MULTI-E4  the server summary equals the browser formatter's, and both read as the 2026-10-14
//             prototype's own buildSummaryText and generateEmailDraftFor do
//   MULTI-E5  the editor: a fieldset of checkboxes per field, from the keyboard; Other's text; a school
//             change keeps the grades it allows; My walks lists every value; axe-core and 375 px
//   MULTI-E6  the Reports view labels a field that takes several values: its counts can add up to more
//             than the walks (the owner's rule, docs/OPEN_DECISIONS.md)
//
// Reports cover the runtime instrument's versions only, so the figures themselves -- live and
// released, against SQL Server -- are tests/cfml/specs/MultipleValuesReportTest.cfc, which reads the
// 2026-10-14 version through a ReportService configured for its fixture instrument. MULTI-E6 checks
// the page's rendering of such a dimension on a report the server sent.
//
// Walks start only on the runtime instrument, so the walks here are placed on the imported version
// directly and then saved and completed through the API. Fixtures are removed by tag afterwards.
//
//   ICFWALK_REQUIRE_APP=1 node --test tests/node/browser-multiple.test.mjs
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { createRequire } from "node:module";
import sql from "mssql";
import { api, baseUrl, connectionConfig, hasDatabaseConfig, loadRuntimeEnv, requireApp, root, screenshotDir } from "./helpers.mjs";
import { readPrototype } from "../../scripts/lib/prototype.mjs";
import { evaluate, normalize } from "../../app/assets/js/rules.js";
import { emailDraft, summaryText } from "../../app/assets/js/summary.js";

const require = createRequire(import.meta.url);
const env = loadRuntimeEnv();
const token = env.ICFWALK_MAINTENANCE_TOKEN || "";
const tag = `brmulti-${Date.now().toString(36)}`;
const instrumentCode = `${tag}-instrument`;
const subjects = { admin: `${tag}-admin`, walker: `${tag}-walker` };
const shotDir = screenshotDir(env);
const DOC = JSON.parse(fs.readFileSync(path.join(root, "config", "instrument-config-2026-10-14.json"), "utf8"));
const GOLDEN = JSON.parse(fs.readFileSync(path.join(root, "tests", "golden", "instrument-snapshot-2026-10-14.golden.json"), "utf8"));
const VECTORS = JSON.parse(fs.readFileSync(path.join(root, "tests", "fixtures", "visibility-vectors-multiple.json"), "utf8"));
const P = readPrototype(fs.readFileSync(path.join(root, "source", "prototype-2026-10-14.html"), "utf8"));
const NOTE = "A walk can be counted under more than one value, so these counts can add up to more than the number of walks.";

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

const who = {};
let districtId, walkerUserId, imported, model, browser;
let mainWalk = null;

/** The required Part 1 answers, so a walk can be completed. */
const REQUIRED = {
  p1q1: { storedCode: "Yes" }, p1q2: { storedCode: "Analysis" }, p1q3: { storedCode: "Comprehension" },
  part1_targettask_tt1: { storedCode: "4" }, part1_targettask_tt2: { storedCode: "3" },
  part1_adopted_pacing: { storedCode: "notevident" }, part1_adopted_ac1: { storedCode: "2" }, part1_adopted_ac2: { storedCode: "1" },
};

/** The walk MULTI-E3 to E5 save: several values in every checkbox field, Other with its text. */
const STATE = {
  dimensions: {
    date: { dateValue: "2026-10-15" },
    observer: { textValue: "Multiple Walker" },
    grade: { selectedValueCodes: ["7", "8"] },
    content: { selectedValueCodes: ["ela", "visual_arts", "other"], otherText: "Robotics" },
    classType: { selectedValueCodes: ["dhh", "esl"] },
    visitTiming: { selectedValueCodes: ["beginning_of_lesson", "middle_of_the_lesson"] },
    topic: { textValue: "RL.7.2" },
  },
  responses: {
    ...REQUIRED,
    part1_targettask_notes: { textValue: "Targets posted and referenced." },
    content_area_q1: { storedCode: "yes" },
    comp_s1_q1: { storedCode: "3" }, comp_s1_q2: { storedCode: "4" },
    comp_s3_applicable: { storedCode: "no" },
    comp_s4_applicable: { storedCode: "yes" }, comp_s4_q1: { storedCode: "4" }, comp_s4_q2: { storedCode: "3" }, comp_s4_q3: { storedCode: "3" },
    conditions_b1: { storedCode: "4" }, conditions_b2: { storedCode: "3" },
    summary_strengths: { textValue: "Students explained their thinking to one another." },
  },
};

/** A walk on the imported version, placed directly (see the header), at the fixture district. */
async function placeWalk() {
  const walkId = randomUUID().toUpperCase();
  await query("INSERT INTO icf.walk (walk_id, version_id, org_unit_id, owner_user_id, status) VALUES (@w, @v, @o, @u, N'DRAFT')",
    { w: walkId, v: imported.versionId, o: districtId, u: walkerUserId });
  return walkId;
}

async function rowVersionOf(walkId) {
  const r = await who.walker.call("GET", `/api/walks/${walkId}`);
  assert.equal(r.status, 200, r.text);
  return r.json.walk.rowVersion;
}

async function save(walkId, state) {
  return who.walker.call("PUT", `/api/walks/${walkId}`, { rowVersion: await rowVersionOf(walkId), clientMutationId: randomUUID(), ...state });
}

/** A completed walk with the given visit fields (and the required answers), visited on `day`. */
async function completedWalk(dimensions, day) {
  const walkId = await placeWalk();
  const saved = await save(walkId, { dimensions: { date: { dateValue: day }, ...dimensions }, responses: REQUIRED });
  assert.equal(saved.status, 200, saved.text);
  const done = await who.walker.call("POST", `/api/walks/${walkId}/complete`, { rowVersion: saved.json.walk.rowVersion, clientMutationId: randomUUID() });
  assert.equal(done.status, 200, done.text);
  return walkId;
}

before(async () => {
  if (skip) return;
  const units = await api(env, "POST", "/api/maintenance/org-units/import", { token, body: { orgUnits: [
    { code: `${tag}-district`, type: "DISTRICT", name: "Multiple values fixture district", parentCode: null },
  ] } });
  assert.equal(units.status, 200, units.text);
  for (const subject of [subjects.admin, subjects.walker]) {
    const r = await api(env, "POST", "/api/maintenance/identity/provision-user", { token, body: { subject, displayName: `Multiple ${subject}` } });
    assert.ok(r.status === 201 || r.status === 200, r.text);
    if (subject === subjects.walker) walkerUserId = r.json.userId;
  }
  const roles = [[subjects.admin, "MASTER_INSTRUMENT_ADMIN", false], [subjects.walker, "DISTRICT_WALK_REPORT", true]];
  for (const [subject, roleCode, includeDescendants] of roles) {
    const a = await api(env, "POST", "/api/maintenance/identity/assign-role", { token, body: { subject, roleCode, orgUnitCode: `${tag}-district`, includeDescendants } });
    assert.equal(a.status, 201, a.text);
    if (subject === subjects.walker) districtId = a.json.orgUnitId;
  }
  for (const [name, subject] of Object.entries(subjects)) who[name] = await client(subject);
  browser = await chromium.launch();
  fs.mkdirSync(shotDir, { recursive: true });
});

after(async () => {
  if (browser) await browser.close();
  if (!skip) {
    const r = await api(env, "POST", "/api/maintenance/identity/cleanup-fixtures", { token, body: { tag } });
    if (r.status !== 200) console.error("multiple values fixture cleanup failed", r.status, r.text);
  }
  if (pool) { await pool.close(); pool = null; }
});

// ---- the instrument -------------------------------------------------------------------------------

test("MULTI-E1 the 2026-10-14 document imports and publishes, and exactly its four checkbox fields take several values", { skip }, async () => {
  const doc = structuredClone(DOC);
  doc.instrument.code = instrumentCode;
  const r = await who.admin.call("POST", "/api/admin/instrument/import", { document: doc });
  assert.equal(r.status, 201, r.text);
  imported = r.json;
  assert.equal(imported.definitionsChecksum, GOLDEN.definitionsChecksum, "SQL Server holds exactly the definitions the reference compiler compiled");
  const published = await who.admin.call("POST", `/api/admin/instrument/versions/${imported.versionId}/publish`);
  assert.equal(published.status, 200, published.text);

  mainWalk = await placeWalk();
  const served = await who.walker.call("GET", `/api/walks/${mainWalk}/instrument`);
  assert.equal(served.status, 200, served.text);
  model = served.json.model;
  const checkboxes = P.META_FIELDS.filter((f) => f.type === "checkboxes").map((f) => f.id);
  assert.deepEqual(checkboxes, ["grade", "content", "classType", "visitTiming"]);
  for (const [code, dim] of Object.entries(model.dimensions)) assert.equal(dim.multiple, checkboxes.includes(code), `${code} multiple`);
  const placements = [];
  const walkTree = (n) => { placements.push(...n.placements); n.children.forEach(walkTree); };
  walkTree(model.root);
  for (const p of placements) assert.equal(p.multiple, checkboxes.includes(p.dimensionCode), `placement ${p.dimensionCode}`);
});

test("MULTI-E2 the JavaScript engine reproduces the shared multiple-value vectors on the served model", { skip }, () => {
  assert.equal(VECTORS.format, "icfwalk-visibility-vectors/1");
  for (const v of VECTORS.vectors) {
    const ev = evaluate(model, v.state);
    const actual = {
      sections: ev.sections, dimensions: ev.dimensions, dimensionOptions: ev.dimensionOptions, responseStates: ev.responseStates, dimensionStates: ev.dimensionStates,
      hiddenItems: Object.keys(ev.items).filter((k) => !ev.items[k]).sort(),
      normalizedRetain: normalize(model, v.state, { hiddenDimensionPolicy: "RETAIN_HIDDEN" }),
      normalizedClear: normalize(model, v.state, { hiddenDimensionPolicy: "CLEAR" }),
    };
    assert.deepEqual(actual, v.expected, v.name);
  }
});

// ---- the walk path --------------------------------------------------------------------------------

test("MULTI-E3 several values save in the version's order, one row each, and every malformed submission is refused", { skip }, async () => {
  // Out of order, with a stale Other text on a field whose Other is not ticked.
  const submitted = structuredClone(STATE);
  submitted.dimensions.grade = { selectedValueCodes: ["8", "7"] };
  submitted.dimensions.content = { selectedValueCodes: ["other", "visual_arts", "ela"], otherText: "Robotics" };
  submitted.dimensions.classType = { selectedValueCodes: ["esl", "dhh"], otherText: "not kept: Other is not ticked" };
  submitted.dimensions.visitTiming = { selectedValueCodes: ["middle_of_the_lesson", "beginning_of_lesson"] };
  const saved = await save(mainWalk, submitted);
  assert.equal(saved.status, 200, saved.text);
  const state = (await who.walker.call("GET", `/api/walks/${mainWalk}`)).json.walk.state;
  for (const code of ["grade", "content", "classType", "visitTiming"]) {
    assert.deepEqual(state.dimensions[code].selectedValueCodes, STATE.dimensions[code].selectedValueCodes, `${code} in the version's order`);
  }
  assert.equal(state.dimensions.content.otherText, "Robotics");
  assert.equal(Object.hasOwn(state.dimensions.classType, "otherText"), false, "Other's text goes only with Other");
  assert.deepEqual(state.dimensions.topic, { textValue: "RL.7.2" }, "a field that takes one value keeps its shape");
  assert.equal(Object.hasOwn(state.dimensions, "period"), false, "this version has no Period (owner, 2026-10-24)");

  // One row per value, ordinal 0.. in the version's order; the Other text on the Other row only.
  const rows = await query(
    `SELECT d.code, x.selection_ordinal, dv.value_code, x.text_value FROM icf.walk_dimension_value x
       JOIN icf.dimension_definition d ON d.dimension_id = x.dimension_id
       LEFT JOIN icf.dimension_value dv ON dv.value_id = x.selected_value_id
      WHERE x.walk_id = @w AND d.code IN (N'grade', N'content') ORDER BY d.code, x.selection_ordinal`, { w: mainWalk });
  assert.deepEqual(rows.map((r) => `${r.code}:${r.selection_ordinal}:${r.value_code}:${r.text_value ?? ""}`),
    ["content:0:ela:", "content:1:visual_arts:", "content:2:other:Robotics", "grade:0:7:", "grade:1:8:"]);

  // The same values in another order are the same walk. A draft's every save is recorded, so this is
  // shown on a completed walk, whose identical save is no change: no revision, no new row version.
  const done = await completedWalk({ grade: { selectedValueCodes: ["7", "8"] }, visitTiming: { selectedValueCodes: ["beginning_of_lesson", "end_of_the_lesson"] } }, "2026-10-15");
  const settled = await rowVersionOf(done);
  const reordered = await save(done, { dimensions: { date: { dateValue: "2026-10-15" }, grade: { selectedValueCodes: ["8", "7"] }, visitTiming: { selectedValueCodes: ["end_of_the_lesson", "beginning_of_lesson"] } }, responses: REQUIRED });
  assert.equal(reordered.status, 200, reordered.text);
  assert.equal(await rowVersionOf(done), settled, "the same values in another order change nothing");
  const [{ n: revisions }] = await query("SELECT COUNT(*) AS n FROM icf.walk_revision WHERE walk_id = @w AND reason = N'POST_COMPLETION_EDIT'", { w: done });
  assert.equal(revisions, 0, "and append no revision");

  // Text that spells "null" is text (defect P8-08: ColdFusion 2023's isNull() is true for it). Other's
  // text "Null" is kept with its value, and a value code "null" is refused below, never skipped.
  const nulled = await completedWalk({ content: { selectedValueCodes: ["other", "ela"], otherText: "Null" } }, "2026-10-15");
  const nulledState = (await who.walker.call("GET", `/api/walks/${nulled}`)).json.walk.state;
  assert.deepEqual(nulledState.dimensions.content, { selectedValueCodes: ["ela", "other"], otherText: "Null" }, "Other's text Null is text");

  const before = await rowVersionOf(mainWalk);

  const refusals = [
    [{ grade: { selectedValueCode: "7" } }, "dimensions.grade.selectedValueCode"],
    [{ school: { selectedValueCodes: ["abbott_middle_school"] } }, "dimensions.school.selectedValueCodes"],
    [{ grade: { selectedValueCodes: ["7", "7"] } }, "dimensions.grade.selectedValueCodes[1]"],
    [{ grade: { selectedValueCodes: ["7", "13"] } }, "dimensions.grade.selectedValueCodes[1]"],
    [{ grade: { selectedValueCodes: ["7", 8] } }, "dimensions.grade.selectedValueCodes[1]"],
    [{ grade: { selectedValueCodes: ["7", "null"] } }, "dimensions.grade.selectedValueCodes[1]"],
    [{ grade: { selectedValueCodes: "7" } }, "dimensions.grade.selectedValueCodes"],
    [{ content: { selectedValueCodes: ["music"] } }, "dimensions.content.selectedValueCodes[0]"],
  ];
  for (const [dims, at] of refusals) {
    const r = await save(mainWalk, { dimensions: { ...STATE.dimensions, ...dims }, responses: STATE.responses });
    assert.ok(r.status === 400 || r.status === 422, `${at}: ${r.status} ${r.text}`);
    assert.ok(JSON.stringify(r.json).includes(`"${at}"`), `${at} is named: ${r.text}`);
    assert.ok(r.text.includes("INVALID_DIMENSION_VALUE"), r.text);
  }
  assert.equal(await rowVersionOf(mainWalk), before, "a refused save writes nothing");
});

test("MULTI-E4 the summary and the email draft list several values as the 2026-10-14 prototype does", { skip }, async () => {
  const opened = await who.walker.call("GET", `/api/walks/${mainWalk}`);
  const state = opened.json.walk.state;
  const server = await who.walker.call("GET", `/api/walks/${mainWalk}/summary`);
  assert.equal(server.status, 200, server.text);
  const text = server.text;
  assert.equal(text, summaryText(model, state, evaluate(model, state)), "the CFML and JavaScript formatters agree byte for byte");
  const lines = text.split("\n");
  for (const line of ["Grade level: 7, 8", "Content / Subject Area: ELA, Visual Arts, Robotics", "Program: DHH, ESL", "Visit occurred at the: Beginning of Lesson, Middle of the Lesson"]) {
    assert.ok(lines.includes(line), `summary has ${JSON.stringify(line)}\n${text}`);
  }
  assert.ok(!lines.some((l) => l.startsWith("Period:")), "no Period line: this version has no Period (owner, 2026-10-24)");
  assert.equal(server.headers.get("content-disposition"), 'attachment; filename="ICFWalk_7_8_ELA_Visual_Arts_Robotics_2026-10-15.txt"');

  // The prototype's own code, on the same walk.
  const html = fs.readFileSync(path.join(root, "source", "prototype-2026-10-14.html"), "utf8");
  const page = await browser.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e)));
  await page.goto(`file://${path.join(root, "source", "prototype-2026-10-14.html")}`);
  await page.addScriptTag({ content: unwrappedPrototypeScript(html) });
  await page.waitForFunction(() => typeof window.buildSummaryText === "function" && typeof window.__setCurrent === "function");
  const keySets = [[], ["part1"], ["part1", "comp_s1", "comp_s4", "belonging", "summary"]];
  const oracle = await page.evaluate(({ walk, keySets }) => {
    const w = blankWalk();
    for (const [k, v] of Object.entries(walk)) w[k] = typeof v === "object" && v && !Array.isArray(v) ? { ...w[k], ...v } : v;
    window.__setCurrent(w);
    return { summaryText: buildSummaryText(), emails: keySets.map((keys) => generateEmailDraftFor(keys)) };
  }, { walk: prototypeWalk(), keySets });
  await page.close();
  assert.deepEqual(errors, [], "the prototype ran without errors");
  const ours = text.split("\n");
  const theirs = oracle.summaryText.split("\n");
  assert.equal(ours.length, theirs.length, `line count\n--- server\n${text}\n--- prototype\n${oracle.summaryText}`);
  const deviations = [];
  ours.forEach((line, i) => {
    if (line === theirs[i]) return;
    if (theirs[i].replace(/\[yes\]/g, "[Yes]").replace(/\[no\]/g, "[No]") === line) deviations.push("14.5");
    else if (theirs[i] === "VISUAL ARTS CLASSROOM" && line === "CONTENT-AREA LOOK-FORS") deviations.push("14.3");
    else assert.fail(`line ${i + 1} differs without a recorded deviation:\n  server:    ${JSON.stringify(line)}\n  prototype: ${JSON.stringify(theirs[i])}`);
  });
  assert.deepEqual([...new Set(deviations)].sort(), ["14.3", "14.5"]);
  const evaluation = evaluate(model, state);
  keySets.forEach((keys, i) => {
    const mine = emailDraft(model, state, evaluation, keys);
    assert.equal(mine.subject, oracle.emails[i].subject, `subject for [${keys}]`);
    assert.equal(mine.body, oracle.emails[i].body, `body for [${keys}]`);
  });
});

// ---- the editor ------------------------------------------------------------------------------------

test("MULTI-E5 the editor: checkboxes per field from the keyboard, Other's text, a school change, My walks, axe-core and 375 px", { skip }, async () => {
  const context = await browser.newContext({ extraHTTPHeaders: { "X-ICFWalk-Dev-Subject": subjects.walker }, viewport: { width: 1280, height: 900 } });
  const page = await context.newPage();
  const pageErrors = [];
  page.on("pageerror", (e) => pageErrors.push(String(e)));
  const axeSource = fs.readFileSync(require.resolve("axe-core/axe.min.js"), "utf8");
  // axe-core is served from the application's own origin, as its content security policy requires.
  await page.route("**/assets/js/axe.min.js", (route) => route.fulfill({ status: 200, contentType: "application/javascript", body: axeSource }));
  await page.goto(`${baseUrl(env)}/index.cfm/`, { waitUntil: "networkidle" });
  await page.waitForSelector("body[data-ready=true]", { timeout: 20000 });

  // My walks titles the walk with every grade and content it holds.
  await page.getByRole("button", { name: "Open 7, 8 · ELA, Visual Arts, Robotics" }).click();
  await page.waitForSelector("#view-walk:not([hidden])");

  // One fieldset per checkbox field, named by its legend; School keeps its select, and Period is not on
  // this version (owner, 2026-10-24).
  for (const [code, label] of [["grade", "Grade level"], ["content", "Content / Subject Area"], ["classType", "Program"], ["visitTiming", "Visit occurred at the:"]]) {
    assert.equal(await page.textContent(`[data-dimension-code="${code}"] fieldset legend`), label);
  }
  assert.equal(await page.locator('[data-dimension-code="school"] select').count(), 1);
  assert.equal(await page.locator('[data-dimension-code="period"]').count(), 0);
  const ticked = (code) => page.$$eval(`[data-dimension-code="${code}"] input[type=checkbox]:checked`, (bs) => bs.map((b) => b.value));
  assert.deepEqual(await ticked("grade"), ["7", "8"]);
  assert.deepEqual(await ticked("content"), ["ela", "visual_arts", "other"]);
  assert.equal(await page.inputValue('[data-dimension-code="content"] .other-input'), "Robotics");
  const visible = (key) => page.$eval(`[data-section-key="${key}"]`, (e) => !e.hidden && !e.closest("[hidden]"));
  assert.equal(await visible("content_area_look_fors"), true, "Visual Arts among the contents shows the content-area card");
  assert.equal(await visible("esl_classroom"), true, "ESL among the programs shows its card");

  // From the keyboard: Space ticks a checkbox; the values stay in the version's order.
  await page.focus('[data-dimension-code="grade"] input[value="6"]');
  await page.keyboard.press("Space");
  assert.deepEqual(await ticked("grade"), ["6", "7", "8"]);
  // Unticking Other hides and clears its text, as the prototype does.
  await page.click('[data-dimension-code="content"] input[value="other"]');
  assert.equal(await page.isVisible('[data-dimension-code="content"] .other-input'), false);
  // A middle school keeps the grades it allows (6-8) and hides the rest.
  await page.click('[data-dimension-code="grade"] input[value="5"]');
  assert.deepEqual(await ticked("grade"), ["5", "6", "7", "8"]);
  await page.selectOption('[data-dimension-code="school"] select', "abbott_middle_school");
  assert.deepEqual(await ticked("grade"), ["6", "7", "8"], "5 is removed, the rest stay");
  const shown = await page.$$eval('[data-dimension-code="grade"] .check-option', (ls) => ls.filter((l) => !l.hidden).map((l) => l.querySelector("input").value));
  assert.deepEqual(shown, ["6", "7", "8"]);
  await page.click("#save-btn");
  await page.waitForFunction(() => /saved/i.test(document.querySelector("#save-status")?.textContent || ""), null, { timeout: 20000 });
  const reread = (await who.walker.call("GET", `/api/walks/${mainWalk}`)).json.walk.state;
  assert.deepEqual(reread.dimensions.grade.selectedValueCodes, ["6", "7", "8"]);
  assert.deepEqual(reread.dimensions.content, { selectedValueCodes: ["ela", "visual_arts"] }, "Other and its text are gone");

  // axe-core on the editor, then the phone width.
  await page.addScriptTag({ url: `${baseUrl(env)}/assets/js/axe.min.js` });
  const axe = await page.evaluate(async () => (await window.axe.run(document, { runOnly: { type: "tag", values: ["wcag2a", "wcag2aa", "wcag21a", "wcag21aa"] } })).violations
    .filter((v) => v.impact === "serious" || v.impact === "critical").map((v) => `${v.id}: ${v.nodes.map((n) => n.target.join(" ")).join(", ")}`));
  assert.deepEqual(axe, [], "no serious or critical axe-core violation");
  await page.locator('[data-dimension-code="grade"]').scrollIntoViewIfNeeded();
  await page.screenshot({ path: path.join(shotDir, "multiple-editor-desktop.png") });
  await page.setViewportSize({ width: 375, height: 800 });
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
  assert.ok(overflow <= 0, `no horizontal overflow at 375 px (${overflow})`);
  await page.locator('[data-dimension-code="classType"]').scrollIntoViewIfNeeded();
  await page.screenshot({ path: path.join(shotDir, "multiple-editor-phone.png") });
  const real = pageErrors.filter((e) => !/ERR_|net::|Failed to load resource/.test(e));
  assert.deepEqual(real, [], "no page error");
  await context.close();

  // Put the walk back as MULTI-E6 counts it: a draft with several grades.
  const restored = await save(mainWalk, STATE);
  assert.equal(restored.status, 200, restored.text);
});

// ---- reports -----------------------------------------------------------------------------------------

test("MULTI-E6 the Reports view labels a field that takes several values, and only such a field", { skip }, async () => {
  const context = await browser.newContext({ extraHTTPHeaders: { "X-ICFWalk-Dev-Subject": subjects.walker }, viewport: { width: 1280, height: 900 } });
  const page = await context.newPage();
  // The server's own report for the runtime version, with its Grade level marked as a field that
  // takes several values, as a report on the 2026-10-14 version marks it (MultipleValuesReportTest).
  let marked = false;
  await page.route("**/api/reports/aggregate?**", async (route) => {
    const response = await route.fetch();
    const report = await response.json();
    for (const d of report.dimensions) {
      if (d.code !== "grade") continue;
      d.multiple = true;
      d.states.ANSWERED = 3;
      d.values = d.values.map((v) => (v.code === "7" ? { ...v, walks: 2 } : v.code === "8" ? { ...v, walks: 2 } : v));
      marked = true;
    }
    await route.fulfill({ response, json: report });
  });
  await page.goto(`${baseUrl(env)}/index.cfm/`, { waitUntil: "networkidle" });
  await page.waitForSelector("body[data-ready=true]", { timeout: 20000 });
  await page.click("#nav-reports-btn");
  await page.waitForSelector('.report-dimension[data-dimension="grade"]', { timeout: 20000 });
  assert.ok(marked, "the report carried a Grade level");
  assert.equal(await page.textContent('.report-dimension[data-dimension="grade"] .report-multiple'), `${NOTE} Walks with at least one value: 3.`);
  assert.equal(await page.locator(".report-multiple").count(), 1, "no other field is labelled");
  await page.locator('.report-dimension[data-dimension="grade"]').scrollIntoViewIfNeeded();
  await page.screenshot({ path: path.join(shotDir, "multiple-report-label.png") });
  await context.close();
});

// ---- the prototype as oracle ---------------------------------------------------------------------

/** As in browser-revision.test.mjs: the prototype's application without its IIFE, with a setter. */
function unwrappedPrototypeScript(html) {
  const body = html.slice(html.indexOf("<script>") + "<script>".length, html.lastIndexOf("</script>"));
  const inner = body.slice(body.indexOf("(function(){") + "(function(){".length, body.lastIndexOf("})();"));
  return `${inner}\n;window.__setCurrent = function (w) { current = w; };\n`;
}

/** STATE as the prototype stores it: checkbox fields are arrays of labels, Other's text beside them. */
function prototypeWalk() {
  const r = (key) => (STATE.responses[key] || {}).storedCode || "";
  const t = (key) => (STATE.responses[key] || {}).textValue || "";
  return {
    meta: {
      date: "2026-10-15", observer: "Multiple Walker", school: "", school_other: "",
      grade: ["7", "8"], content: ["ELA", "Visual Arts", "Other"], content_other: "Robotics", period: "", period_other: "",
      classType: ["DHH", "ESL"], classType_other: "", visitTiming: ["Beginning of Lesson", "Middle of the Lesson"], topic: "RL.7.2", tag: "",
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
