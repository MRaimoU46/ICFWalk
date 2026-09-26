// Phase 8 hardening (SEC-02, defect P8-06): stored and reflected script injection, surface by surface.
//
// Markup, attribute breakers, script URLs and template syntax are put into every label an instrument
// document can carry (section titles, instructions and look-fors, prompts, help text, placeholders,
// option labels and definitions, response-set names, dimension and dimension-value labels, the
// composer's part labels, the version label and notes), into every free-text field a walk stores
// (observer, topic, tag, the "Other" text, every note and summary field, the email draft's subject
// and body), into org unit names and into the user's display name. Then every page that shows them
// is opened: My Walks, the new-walk chooser, the editor, the completion errors, the conflict panel,
// the email composer, the summary download, reports, and every administration view (version list,
// import summary, preview, wording editor, comparison, placeholder queue).
//
// Each must show the payloads as text. Three independent observers watch every page from before its
// first byte: a canary function the payloads call, a MutationObserver that records any element or
// attribute of a payload's making (a data-xss attribute, an on* attribute, a script URL) the moment
// it is created, and the page's securitypolicyviolation events -- the page's CSP would block an
// injected handler, and the violation report is how a blocked injection still shows up. A view also
// has to show at least one payload as text, so a view that rendered nothing cannot pass.
//
// Instrument labels reach reports only for the configured runtime instrument, which a gate cannot
// replace without disturbing every other suite; reports render through the same text-only DOM
// construction, and the org unit names and the version-independent parts of reports are swept here.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";
import sql from "mssql";
import { api, baseUrl, connectionConfig, hasDatabaseConfig, loadRuntimeEnv, requireApp, root } from "./helpers.mjs";

const require = createRequire(import.meta.url);
const env = loadRuntimeEnv();
const token = env.ICFWALK_MAINTENANCE_TOKEN || "";
const tag = `p8xss-${Date.now().toString(36)}`;
const instrumentCode = `${tag}-instrument`;
const SOURCE = JSON.parse(fs.readFileSync(path.join(root, "config", "instrument-config.json"), "utf8"));

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
if (requireApp(env) && (!up || !token || !chromium || !hasDatabaseConfig(env))) {
  throw new Error(`ICFWALK_REQUIRE_APP is set but the application (development mode), the maintenance token, the database settings or Playwright is missing at ${baseUrl(env)}`);
}
const skip = !chromium ? "playwright is not installed" : !up ? `application not reachable in development mode at ${baseUrl(env)}` : !token ? "no maintenance token" : !hasDatabaseConfig(env) ? "no database settings" : false;

// ---- payloads -----------------------------------------------------------------------------------

const SHAPES = [
  (n) => `<img src=x data-xss="${n}" onerror="__x(${n})">`,
  (n) => `<script data-xss="${n}">__x(${n})</script>`,
  (n) => `"><svg data-xss="${n}" onload="__x(${n})">`,
  (n) => `' onmouseover='__x(${n})' data-xss='${n}`,
  (n) => `javascript:__x(${n})`,
  (n) => `<a data-xss="${n}" href="javascript:__x(${n})">x</a>`,
  (n) => `\${__x(${n})}{{__x(${n})}}`,
];
const planted = new Map();   // n -> where it was put
let counter = 0;
function payload(where) {
  const n = ++counter;
  planted.set(n, where);
  return SHAPES[n % SHAPES.length](n);
}
const poison = (text, where) => `${text} ${payload(where)}`;

/** The supplied instrument with a payload in every human-readable text it carries. */
function hostileDocument() {
  const doc = structuredClone(SOURCE);
  doc.instrument.code = instrumentCode;
  doc.instrument.description = poison(doc.instrument.description, "instrument.description");
  doc.instrument.version.versionLabel = `${tag} ${payload("version.versionLabel")}`;
  doc.instrument.version.revisionNotes = poison(doc.instrument.version.revisionNotes, "version.revisionNotes");
  for (const s of doc.sections) {
    s.title = poison(s.title, `section ${s.sectionKey} title`);
    if (s.instructions) s.instructions = poison(s.instructions, `section ${s.sectionKey} instructions`);
    const lookFors = s.settings && s.settings.lookFors;
    if (lookFors) for (const side of Object.keys(lookFors)) lookFors[side] = lookFors[side].map((t, i) => poison(t, `section ${s.sectionKey} lookFors.${side}[${i}]`));
  }
  for (const i of doc.items) {
    i.prompt = poison(i.prompt, `item ${i.itemKey} prompt`);
    if (i.helpText) i.helpText = poison(i.helpText, `item ${i.itemKey} helpText`);
    if (i.placeholder) i.placeholder = poison(i.placeholder, `item ${i.itemKey} placeholder`);
    const parts = i.settings && i.settings.selectableParts;
    if (parts) for (const p of parts) {
      p.label = poison(p.label, `item ${i.itemKey} part ${p.key} label`);
      if (p.compTitle) p.compTitle = poison(p.compTitle, `item ${i.itemKey} part ${p.key} compTitle`);
    }
  }
  const promptByKey = new Map(doc.items.map((i) => [i.itemKey, i.prompt]));
  for (const p of doc.contentReview.unresolvedPlaceholders) p.prompt = promptByKey.get(p.itemKey);
  for (const o of doc.responseOptions) {
    o.label = poison(o.label, `option ${o.optionId} label`);
    if (o.definition) o.definition = poison(o.definition, `option ${o.optionId} definition`);
  }
  for (const rs of doc.responseSets) rs.name = poison(rs.name, `response set ${rs.setKey} name`);
  for (const d of doc.dimensions) d.label = poison(d.label, `dimension ${d.code} label`);
  for (const v of doc.dimensionValues) v.label = poison(v.label, `dimension value ${v.dimensionValueId} label`);
  for (const p of doc.instrumentDimensions) if (p.placeholder) p.placeholder = poison(p.placeholder, `placement ${p.instrumentDimensionId} placeholder`);
  return doc;
}

// ---- the observers --------------------------------------------------------------------------------

/** Installed in every page before any of its own script runs. */
function observers() {
  window.__xss = [];
  window.__x = (n) => window.__xss.push(String(n));
  window.__csp = [];
  document.addEventListener("securitypolicyviolation", (e) => window.__csp.push(`${e.violatedDirective} ${e.blockedURI || ""} ${e.sample || ""}`.trim()));
  window.__injected = [];
  const URL_ATTRS = /^(href|src|action|formaction|xlink:href|background|poster|data)$/i;
  const suspicious = (el) => el.nodeType === 1 && (el.hasAttribute("data-xss")
    || [...el.attributes].some((a) => /^on/i.test(a.name) || (URL_ATTRS.test(a.name) && /^\s*(javascript|vbscript):/i.test(a.value)) || (/^(href|action|formaction)$/i.test(a.name) && /^\s*data:/i.test(a.value))));
  new MutationObserver((records) => {
    for (const r of records) {
      if (r.type === "attributes" && suspicious(r.target)) window.__injected.push(`${r.target.tagName} [${r.attributeName}]`);
      for (const n of r.addedNodes || []) {
        if (n.nodeType !== 1) continue;
        for (const e of [n, ...n.querySelectorAll("*")]) if (suspicious(e)) window.__injected.push(`${e.tagName} ${e.outerHTML.slice(0, 160)}`);
      }
    }
  }).observe(document, { subtree: true, childList: true, attributes: true });
}

/** Nothing ran, nothing was injected, nothing was blocked -- and the view did show payload text. */
async function assertClean(page, where, { expectText = true } = {}) {
  await page.waitForTimeout(150);   // let an image error or an onload fire, if one could
  const seen = await page.evaluate(() => {
    const fields = [...document.querySelectorAll("input, textarea")].map((e) => e.value).join("\n");
    return {
      xss: window.__xss, csp: window.__csp, injected: window.__injected,
      live: [...document.querySelectorAll("[data-xss]")].map((e) => e.outerHTML.slice(0, 160)),
      scriptUrls: [...document.querySelectorAll("[href], [src], [action]")].filter((e) => /^\s*(javascript|vbscript):/i.test(e.getAttribute("href") || e.getAttribute("src") || e.getAttribute("action") || "")).map((e) => e.outerHTML.slice(0, 160)),
      handlers: [...document.querySelectorAll("*")].filter((e) => [...e.attributes].some((a) => /^on/i.test(a.name))).map((e) => e.outerHTML.slice(0, 160)),
      shownAsText: /__x\(\d+\)/.test(document.body.textContent) || /__x\(\d+\)/.test(fields),
    };
  });
  assert.deepEqual(seen.xss, [], `${where}: a payload ran (${seen.xss.map((n) => planted.get(Number(n)) || n).join("; ")})`);
  assert.deepEqual(seen.injected, [], `${where}: markup of a payload's making was created`);
  assert.deepEqual(seen.live, [], `${where}: a payload element is in the page`);
  assert.deepEqual(seen.scriptUrls, [], `${where}: a script URL is in the page`);
  assert.deepEqual(seen.handlers, [], `${where}: an inline event handler is in the page`);
  assert.deepEqual(seen.csp, [], `${where}: the Content-Security-Policy blocked something`);
  if (expectText) assert.ok(seen.shownAsText, `${where}: no payload was shown as text, so the view proved nothing`);
}

// ---- fixtures -----------------------------------------------------------------------------------------

const subjects = { walker: `${tag}-walker`, admin: `${tag}-admin` };
const DISPLAY_NAME = `Walker ${payload("user display name")}`;
let browser;
let pool;
let adminApi;
let walkerApi;
let hostile;          // { versionId, versionLabel }
let hostileWalkId = "";
let incompleteWalkId = "";
let runtimeWalkId = "";
let schoolId = "";
const pageErrors = [];
const home = `${baseUrl(env)}/index.cfm/`;
const FIRST_DAY = new Date().toISOString().slice(0, 10);

/** The development stub takes the display name from X-ICFWalk-Dev-Name, as the SSO adapter takes it from its gateway. */
const identityHeaders = (subject) => ({ "X-ICFWalk-Dev-Subject": subject, ...(subject === subjects.walker ? { "X-ICFWalk-Dev-Name": DISPLAY_NAME } : {}) });

async function apiClient(subject) {
  const cookies = new Map();
  let csrf = "";
  const call = async (method, p, body) => {
    const headers = { Accept: "application/json", ...identityHeaders(subject) };
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

async function newPage(subject, viewport = { width: 1280, height: 900 }) {
  const context = await browser.newContext({ extraHTTPHeaders: identityHeaders(subject), viewport, acceptDownloads: true });
  await context.addInitScript(observers);
  const page = await context.newPage();
  page.on("pageerror", (e) => pageErrors.push(`pageerror: ${e.message}`));
  page.on("dialog", async (d) => { pageErrors.push(`dialog: ${d.message()}`); await d.dismiss(); });
  return { context, page };
}

async function expand(page, key) {
  const head = page.locator(`[data-section-key="${key}"] > h2 > .acc-head, [data-section-key="${key}"] > h3 > .acc-head`);
  if ((await head.getAttribute("aria-expanded")) !== "true") await head.click();
}

async function openHome(page) {
  await page.goto(home, { waitUntil: "networkidle" });
  await page.waitForSelector("body[data-ready=true]", { timeout: 30000 });
}

/** The free text a walk stores, each field with its own payload. */
function hostileWalkState(rating) {
  const notes = ["part1_adopted_notes", "part1_targettask_notes", "comp_s1_notes", "comp_s2_notes", "comp_s4_notes", "conditions_notes", "summary_strengths", "summary_growth"];
  const responses = {
    p1q1: { storedCode: "Partial" }, p1q2: { storedCode: "Retrieval" }, p1q3: { storedCode: "Analysis" }, part1_adopted_pacing: { storedCode: "on" },
    part1_adopted_ac1: { storedCode: "3" }, part1_adopted_ac2: { storedCode: "4" }, part1_targettask_tt1: { storedCode: "5" }, part1_targettask_tt2: { storedCode: "2" },
    comp_s1_q1: { storedCode: rating },
  };
  for (const key of notes) responses[key] = { textValue: `Note ${payload(`walk note ${key}`)}` };
  responses.email_workflow = { textValue: JSON.stringify({ body: `Body ${payload("email body")}`, drafted: true, includedPartKeys: [], subject: `Subject ${payload("email subject")}`, to: "teacher@example.test" }) };
  return {
    dimensions: {
      date: { dateValue: FIRST_DAY }, grade: { selectedValueCode: "7" },
      observer: { textValue: `Observer ${payload("dimension observer")}` },
      topic: { textValue: `Topic ${payload("dimension topic")}` },
      tag: { textValue: `Tag ${payload("dimension tag")}` },
      content: { selectedValueCode: "other", otherText: `Other ${payload("dimension content other text")}` },
    },
    responses,
  };
}

before(async () => {
  if (skip) return;
  const units = await api(env, "POST", "/api/maintenance/org-units/import", { token, body: { orgUnits: [
    { code: `${tag}-district`, type: "DISTRICT", name: `District ${payload("org unit district name")}`, parentCode: null },
    { code: `${tag}-school`, type: "SCHOOL", name: `School ${payload("org unit school name")}`, parentCode: `${tag}-district` },
  ] } });
  assert.equal(units.status, 200, units.text);
  const w = await api(env, "POST", "/api/maintenance/identity/provision-user", { token, body: { subject: subjects.walker, displayName: DISPLAY_NAME } });
  assert.ok(w.status === 201 || w.status === 200, w.text);
  const a = await api(env, "POST", "/api/maintenance/identity/provision-user", { token, body: { subject: subjects.admin, displayName: `Admin ${payload("admin display name")}` } });
  assert.ok(a.status === 201 || a.status === 200, a.text);
  assert.equal((await api(env, "POST", "/api/maintenance/identity/assign-role", { token, body: { subject: subjects.walker, roleCode: "SCHOOL_WALK_REPORT", orgUnitCode: `${tag}-school` } })).status, 201);
  assert.equal((await api(env, "POST", "/api/maintenance/identity/assign-role", { token, body: { subject: subjects.admin, roleCode: "MASTER_INSTRUMENT_ADMIN", orgUnitCode: `${tag}-district` } })).status, 201);
  adminApi = await apiClient(subjects.admin);
  walkerApi = await apiClient(subjects.walker);
  schoolId = Object.keys(walkerApi.me.orgUnits).find((id) => walkerApi.me.orgUnits[id].code === `${tag}-school`);
  assert.ok(schoolId);
  pool = await sql.connect(connectionConfig(env, env.ICFWALK_DB_NAME || "icfwalk_dev"));

  // The hostile instrument: imported and published under this run's own code.
  const imported = await adminApi.call("POST", "/api/admin/instrument/import", { document: hostileDocument() });
  assert.equal(imported.status, 201, imported.text.slice(0, 2000));
  hostile = { versionId: imported.json.versionId.toUpperCase(), versionLabel: imported.json.versionLabel };
  const published = await adminApi.call("POST", `/api/admin/instrument/versions/${hostile.versionId}/publish`);
  assert.equal(published.status, 200, published.text.slice(0, 2000));

  // A walk pinned to it. Walks start only on the runtime instrument, so this row is placed directly,
  // as tests/node/admin-instrument.test.mjs does for a historical walk; it is then saved through the API.
  hostileWalkId = crypto.randomUUID().toUpperCase();
  await pool.request().input("w", hostileWalkId).input("v", hostile.versionId).input("o", schoolId).input("u", walkerApi.me.user.userId)
    .query("INSERT INTO icf.walk (walk_id, version_id, org_unit_id, owner_user_id, status) VALUES (@w, @v, @o, @u, N'DRAFT')");
  const opened = await walkerApi.call("GET", `/api/walks/${hostileWalkId}`);
  assert.equal(opened.status, 200, opened.text);
  const saved = await walkerApi.call("PUT", `/api/walks/${hostileWalkId}`, { rowVersion: opened.json.walk.rowVersion, clientMutationId: crypto.randomUUID(), ...hostileWalkState("4") });
  assert.equal(saved.status, 200, saved.text.slice(0, 2000));

  // A second one holding notes only, which completion must refuse.
  incompleteWalkId = crypto.randomUUID().toUpperCase();
  await pool.request().input("w", incompleteWalkId).input("v", hostile.versionId).input("o", schoolId).input("u", walkerApi.me.user.userId)
    .query("INSERT INTO icf.walk (walk_id, version_id, org_unit_id, owner_user_id, status) VALUES (@w, @v, @o, @u, N'DRAFT')");
  const bare = await walkerApi.call("GET", `/api/walks/${incompleteWalkId}`);
  const notesOnly = await walkerApi.call("PUT", `/api/walks/${incompleteWalkId}`, { rowVersion: bare.json.walk.rowVersion, clientMutationId: crypto.randomUUID(), dimensions: {}, responses: { conditions_notes: { textValue: `Only ${payload("incomplete walk note")}` } } });
  assert.equal(notesOnly.status, 200, notesOnly.text.slice(0, 2000));

  // A completed walk on the runtime instrument, with the same kinds of free text, for reports.
  const created = await walkerApi.call("POST", "/api/walks", { orgUnitId: schoolId, clientMutationId: crypto.randomUUID() });
  assert.equal(created.status, 201, created.text);
  runtimeWalkId = created.json.walk.id;
  const filled = await walkerApi.call("PUT", `/api/walks/${runtimeWalkId}`, { rowVersion: created.json.walk.rowVersion, clientMutationId: crypto.randomUUID(), ...hostileWalkState("5") });
  assert.equal(filled.status, 200, filled.text.slice(0, 2000));
  const done = await walkerApi.call("POST", `/api/walks/${runtimeWalkId}/complete`, { rowVersion: filled.json.walk.rowVersion, clientMutationId: crypto.randomUUID() });
  assert.equal(done.status, 200, done.text.slice(0, 2000));
  browser = await chromium.launch();
});

after(async () => {
  if (browser) await browser.close();
  if (pool) await pool.close();
  if (!skip) {
    const r = await api(env, "POST", "/api/maintenance/identity/cleanup-fixtures", { token, body: { tag } });
    if (r.status !== 200) console.error("fixture cleanup failed", r.status, r.text);
  }
});

// ---- the walker's pages ---------------------------------------------------------------------------

test("control: the observers do catch markup that reaches the page as HTML", { skip }, async () => {
  const { context, page } = await newPage(subjects.walker);
  await openHome(page);
  await page.evaluate(() => document.body.insertAdjacentHTML("beforeend", '<img src=x data-xss="0" onerror="__x(0)"><a href="javascript:__x(0)">x</a>'));
  await assert.rejects(assertClean(page, "a page with a deliberate injection"), (e) => {
    assert.match(e.message, /a deliberate injection: (markup of a payload's making was created|a payload element is in the page)/);
    return true;
  });
  const seen = await page.evaluate(() => ({ injected: window.__injected.length, csp: window.__csp.length }));
  assert.ok(seen.injected >= 2, "the MutationObserver saw the image and the script URL");
  assert.ok(seen.csp >= 1, `the page's CSP refused the inline handler and reported it (${seen.csp})`);
  await context.close();
});

test("SEC-02: My Walks, the display name and the new-walk chooser show every payload as text", { skip }, async () => {
  const { context, page } = await newPage(subjects.walker);
  await openHome(page);
  await page.waitForSelector(`.walk-card[data-walk-id="${hostileWalkId}"]`);
  assert.equal(await page.textContent("#user-name"), DISPLAY_NAME);
  await assertClean(page, "My Walks");
  await page.click("#new-walk-btn");
  await page.waitForSelector("#new-walk-chooser:not([hidden])", { timeout: 5000 }).catch(() => {});
  await assertClean(page, "the new-walk chooser");
  await context.close();
});

test("SEC-02: the editor, its email composer and its summary download keep every instrument label and stored value as text", { skip }, async () => {
  const { context, page } = await newPage(subjects.walker);
  await openHome(page);
  await page.click(`.walk-card[data-walk-id="${hostileWalkId}"] .open-btn`);
  await page.waitForSelector("#view-walk:not([hidden])");
  await page.waitForSelector("#editor [data-section-key]");
  for (const head of await page.$$("#editor .acc-head[aria-expanded=false]")) await head.click().catch(() => {});
  await assertClean(page, "the editor on the hostile instrument");

  const heads = page.locator('[data-section-key="part4"] > h2 > .acc-head, [data-section-key="part4"] > h3 > .acc-head');
  if ((await heads.count()) && (await heads.first().getAttribute("aria-expanded")) !== "true") await heads.first().click();
  await page.waitForSelector(".email-slot:not([hidden]) .email-draft-btn");
  for (const box of await page.$$(".email-parts input[data-part]")) await box.check().catch(() => {});
  await page.click(".email-draft-btn");
  await page.waitForSelector(".email-box:not([hidden])");
  await assertClean(page, "the email composer");

  // A typed edit autosaves through the same page.
  await expand(page, "part2");
  await expand(page, "s1");
  await page.fill('[data-item-key="comp_s1_notes"] textarea', `Edited ${payload("typed note")}`);
  await page.waitForFunction(() => /^All changes saved$/.test(document.getElementById("save-status").textContent), null, { timeout: 20000 });

  // The summary download is a plain-text file with a safe name.
  const [download] = await Promise.all([page.waitForEvent("download", { timeout: 20000 }), page.click("#export-btn")]);
  const name = download.suggestedFilename();
  assert.match(name, /^[A-Za-z0-9_.-]+$/, `the summary's file name is sanitized: ${name}`);
  const text = fs.readFileSync(await download.path(), "utf8");
  assert.match(text, /data-xss=/, "the summary carries the payloads as text");
  await assertClean(page, "the page after the summary download");
  assert.deepEqual(pageErrors, []);
  await context.close();
});

test("SEC-02: the completion errors name the hostile instrument's items as text", { skip }, async () => {
  const { context, page } = await newPage(subjects.walker);
  await openHome(page);
  await page.click(`.walk-card[data-walk-id="${incompleteWalkId}"] .open-btn`);
  await page.waitForSelector("#editor [data-section-key]");
  await page.click("#complete-btn");
  await page.waitForSelector("#completion-errors:not([hidden])", { timeout: 20000 });
  assert.ok((await page.$$eval("#completion-error-list li", (l) => l.length)) > 0, "the refusal lists the missing items");
  await assertClean(page, "the completion errors");
  await context.close();
});

test("SEC-02: the conflict panel lists another session's values and the hostile labels as text", { skip }, async () => {
  const { context, page } = await newPage(subjects.walker);
  await openHome(page);
  await page.click(`.walk-card[data-walk-id="${hostileWalkId}"] .open-btn`);
  await page.waitForSelector("#editor [data-section-key]");
  const current = await walkerApi.call("GET", `/api/walks/${hostileWalkId}`);
  const moved = await walkerApi.call("PUT", `/api/walks/${hostileWalkId}`, {
    rowVersion: current.json.walk.rowVersion, clientMutationId: crypto.randomUUID(),
    dimensions: current.json.walk.state.dimensions,
    responses: { ...current.json.walk.state.responses, comp_s2_notes: { textValue: `Elsewhere ${payload("conflicting note")}` } },
  });
  assert.equal(moved.status, 200, moved.text.slice(0, 500));
  await expand(page, "part2");
  await expand(page, "s2");
  await page.fill('[data-item-key="comp_s2_notes"] textarea', `Mine ${payload("stale note")}`);
  await page.waitForSelector("#conflict-panel:not([hidden])", { timeout: 20000 });
  await assertClean(page, "the conflict panel");
  await context.close();
});

test("SEC-02: reports show hostile org unit names and never a stored note, as text", { skip }, async () => {
  const { context, page } = await newPage(subjects.walker);
  await openHome(page);
  await page.click("#nav-reports-btn");
  await page.waitForSelector("#rf-org");
  await page.click("#report-run");
  await page.waitForFunction(() => /^Report updated/.test(document.getElementById("report-status").textContent), null, { timeout: 30000 });
  await assertClean(page, "reports");
  const text = await page.evaluate(() => document.body.textContent);
  assert.doesNotMatch(text, /Note <|Observer |Subject |Body /, "no stored free text reaches a report");
  await context.close();
});

// ---- administration -------------------------------------------------------------------------------

test("SEC-02: every administration view shows the hostile instrument as text", { skip }, async () => {
  const { context, page } = await newPage(subjects.admin);
  await openHome(page);
  await page.waitForSelector("#admin-versions table");
  await assertClean(page, "the version list");

  const row = page.locator(`#admin-versions tr[data-version-id="${hostile.versionId}"]`);
  await row.getByRole("button", { name: /^Preview / }).click();
  await page.waitForSelector("#admin-panel .admin-preview-editor [data-section-key]");
  await assertClean(page, "the preview");

  await page.locator(`#admin-versions tr[data-version-id="${hostile.versionId}"]`).getByRole("button", { name: /^Placeholder review for / }).click().catch(() => {});
  await page.waitForSelector("#admin-panel .admin-ph-table", { timeout: 20000 }).catch(() => {});
  await assertClean(page, "the placeholder queue");

  // A draft from the hostile version, a prompt edited, and the comparison between them.
  await page.locator(`#admin-versions tr[data-version-id="${hostile.versionId}"]`).getByRole("button", { name: /^Create a new draft from/ }).click();
  const cloneLabel = `${tag}-clone`;
  await page.fill("#admin-panel input[type=text]", cloneLabel);
  await page.fill("#admin-panel textarea", `Review ${payload("clone revision notes")}`);
  await page.getByRole("button", { name: "Create draft" }).click();
  await page.waitForFunction((l) => document.querySelector("#admin-panel h2")?.textContent === `Edit wording: ${l}`, cloneLabel, { timeout: 30000 });
  await page.fill("#admin-panel input[type=search]", "comp_s1_q1");
  await page.getByRole("button", { name: "Search", exact: true }).click();
  const form = page.locator('#admin-panel form.admin-entity[data-target="item"][data-key="comp_s1_q1"]');
  await form.waitFor();
  await assertClean(page, "the wording editor");
  await form.locator('textarea[name="prompt"]').fill(`Changed ${payload("edited prompt")}`);
  await form.getByRole("button", { name: "Save changes" }).click();
  await page.waitForFunction(() => /^Saved 1 change to /.test(document.getElementById("admin-status").textContent), null, { timeout: 20000 });
  const cloneRow = page.locator("#admin-versions tr", { hasText: cloneLabel });
  await cloneRow.getByRole("button", { name: /^Compare / }).click();
  await page.waitForSelector("#admin-panel .admin-compare-result .admin-summary-title", { timeout: 30000 });
  await page.selectOption("#admin-panel select", hostile.versionId).catch(() => {});
  await page.waitForTimeout(500);
  await assertClean(page, "the comparison");

  // The import summary of a hostile document uploaded through the page.
  const doc = hostileDocument();
  doc.instrument.version.versionLabel = `${tag}-upload`;
  await page.setInputFiles("#admin-import-file", { name: "hostile.json", mimeType: "application/json", buffer: Buffer.from(JSON.stringify(doc)) });
  await page.click("#admin-import-btn");
  await page.waitForSelector("#admin-import-result .admin-summary", { timeout: 60000 });
  await assertClean(page, "the import summary");
  assert.deepEqual(pageErrors, []);
  await context.close();
});

// ---- reflected ------------------------------------------------------------------------------------

test("SEC-02: a payload in the path or query is never reflected as markup", { skip }, async () => {
  const probe = payload("reflected path");
  for (const [p, accept] of [
    [`/index.cfm/${encodeURIComponent(probe)}`, "text/html"],
    [`/index.cfm/api/walks/${encodeURIComponent(probe)}`, "text/html"],
    [`/index.cfm/api/walks/${encodeURIComponent(probe)}`, "application/json"],
    [`/index.cfm/?q=${encodeURIComponent(probe)}`, "text/html"],
    [`/index.cfm/api/reports/aggregate?orgUnitId=${encodeURIComponent(probe)}`, "text/html"],
  ]) {
    const r = await fetch(`${baseUrl(env)}${p}`, { headers: { Accept: accept, ...identityHeaders(subjects.walker) } });
    const body = await r.text();
    const type = r.headers.get("content-type") || "";
    assert.ok(!body.includes(probe) || /^application\/json/.test(type), `${p} (${accept}) reflected the payload unencoded as ${type}`);
    if (/^application\/json/.test(type)) assert.equal(r.headers.get("x-content-type-options"), "nosniff", `${p}: a JSON answer is never sniffed as HTML`);
  }
  // And a browser that opens such an address shows nothing of the payload's making.
  const { context, page } = await newPage(subjects.walker);
  await page.goto(`${baseUrl(env)}/index.cfm/${encodeURIComponent(probe)}`, { waitUntil: "load" });
  await assertClean(page, "a not-found page for a hostile path", { expectText: false });
  await page.goto(`${home}?q=${encodeURIComponent(probe)}`, { waitUntil: "networkidle" });
  await assertClean(page, "the shell with a hostile query", { expectText: false });
  await context.close();
});

// ---- P8-06: links from an instrument ----------------------------------------------------------------

test("P8-06: the editor links an instrument's reference only when it is an http or https address", { skip }, async () => {
  const { context, page } = await newPage(subjects.walker);
  await openHome(page);
  const cases = ["javascript:__x(9001)", " JavaScript:__x(9002)", "java\tscript:__x(9003)", "data:text/html,<script>__x(9004)</script>", "vbscript:__x(9005)", "https://example.test/reference", "http://example.test/reference"];
  const rendered = await page.evaluate(async (urls) => {
    const [{ renderEditor }, { createBlankState }] = await Promise.all([import("/assets/js/renderer.js"), import("/assets/js/walk-state.js")]);
    const r = await fetch("/index.cfm/api/instrument/current", { headers: { Accept: "application/json" } });
    const { model, policies } = await r.json();
    const items = [];
    (function walk(node) { for (const i of node.items || []) items.push(i); for (const c of node.children || []) walk(c); })(model.root);
    const rated = items.filter((i) => i.responseSet && i.responseSet.options && i.responseSet.options.length >= 3).slice(0, urls.length);
    const choice = items.filter((i) => i.responseSet && i.responseSet.options && i.responseSet.options.length === 2).slice(0, urls.length);
    const out = [];
    urls.forEach((u, n) => {
      for (const it of [rated[n], choice[n]]) if (it) { it.linkUrl = u; it.helpText = `Reference ${n}`; out.push({ itemKey: it.itemKey, url: u, n }); }
    });
    const holder = document.createElement("div");
    document.body.append(holder);
    renderEditor(holder, { model, walk: { state: createBlankState(model), lockedDimensions: [] }, policies, onChange: () => {}, announce: () => {} });
    const result = out.map((o) => {
      const node = holder.querySelector(`[data-item-key="${o.itemKey}"]`);
      const a = node ? node.querySelector("a") : null;
      return { ...o, href: a ? a.getAttribute("href") : null, text: node ? node.textContent.includes(`Reference ${o.n}`) : false };
    });
    holder.remove();
    return result;
  }, cases);
  assert.ok(rendered.length >= cases.length, `rendered ${rendered.length} linked items`);
  for (const r of rendered) {
    const safe = /^https?:\/\//.test(r.url);
    if (safe) assert.equal(r.href, r.url, `${r.itemKey}: an https/http reference is a link`);
    else assert.equal(r.href, null, `${r.itemKey}: ${JSON.stringify(r.url)} was rendered as a link`);
    assert.ok(r.text, `${r.itemKey}: the reference text is still shown`);
  }
  await assertClean(page, "the renderer with hostile links", { expectText: false });
  await context.close();
});
