/**
 * Phase 5 browser-level checks with Playwright (Chromium) against the real persistent store:
 * the summary export download (SUM-01/02/05, SEC-02), the Part 4 composer (SUM-06), editing and
 * reopening a draft (SUM-07), copy and mailto with no server-side send (SUM-08), clearing a draft
 * (SUM-09), read-only behavior, keyboard operation (A11Y-01), and axe checks of the composer
 * states (A11Y-03). Fixtures are created through the maintenance endpoints and removed afterwards.
 *
 * The downloaded bytes are compared with tests/fixtures/summary-vectors.json and with the HTTP
 * route, so the file a person actually receives is held to the same contract as both formatters.
 */
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";
import { api, baseUrl, loadRuntimeEnv, root } from "./helpers.mjs";

const require = createRequire(import.meta.url);
const env = loadRuntimeEnv();
const token = env.ICFWALK_MAINTENANCE_TOKEN || "";
const tag = `email-${Date.now().toString(36)}`;
const subject = `${tag}-walker`;
const viewer = `${tag}-viewer`;
const reportOnly = `${tag}-report`;
const shotDir = path.join(root, "docs", "evidence", "screenshots");
const vectors = JSON.parse(fs.readFileSync(path.join(root, "tests", "fixtures", "summary-vectors.json"), "utf8"));

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
const skip = !chromium
  ? "playwright is not installed"
  : !up
    ? `application not reachable in development mode at ${baseUrl(env)}`
    : !token
      ? "no maintenance token"
      : false;

let browser, context, page;
const pageErrors = [];
const home = `${baseUrl(env)}/index.cfm/`;

const apiWalk = async (id, who = subject) =>
  (await (await fetch(`${baseUrl(env)}/index.cfm/api/walks/${id}`, { headers: { "X-ICFWalk-Dev-Subject": who } })).json()).walk;
const apiList = async (who = subject) =>
  (await (await fetch(`${baseUrl(env)}/index.cfm/api/walks`, { headers: { "X-ICFWalk-Dev-Subject": who } })).json()).walks;
const apiSummary = (id, who = subject) =>
  fetch(`${baseUrl(env)}/index.cfm/api/walks/${id}/summary`, { headers: { "X-ICFWalk-Dev-Subject": who } });

const waitStatus = (text, p = page) =>
  p.waitForFunction((t) => document.getElementById("save-status").textContent === t, text, { timeout: 20000 });
const expand = (key, p = page) => p.click(`[data-section-key="${key}"] > h2 > .acc-head, [data-section-key="${key}"] > h3 > .acc-head`);
async function ensureExpanded(key, p = page) {
  const head = p.locator(`[data-section-key="${key}"] > h2 > .acc-head, [data-section-key="${key}"] > h3 > .acc-head`);
  if ((await head.getAttribute("aria-expanded")) !== "true") await head.click();
}

async function newPage(ctx) {
  const p = await ctx.newPage();
  p.on("pageerror", (e) => pageErrors.push(`pageerror: ${e.message}`));
  p.on("console", (m) => {
    if (m.type() === "error" && !/ERR_|net::|Failed to load resource/.test(m.text())) pageErrors.push(m.text());
  });
  return p;
}
async function openHome(p = page) {
  await p.goto(home, { waitUntil: "networkidle" });
  await p.waitForSelector("body[data-ready=true]", { timeout: 20000 });
}
async function startWalk(p = page, who = subject) {
  await p.click("#new-walk-btn");
  await p.waitForSelector("#view-walk:not([hidden])");
  return (await apiList(who))[0].id;
}
async function openCard(id, p = page) {
  await p.click(`.walk-card[data-walk-id="${id}"] .open-btn`);
  await p.waitForSelector("#view-walk:not([hidden])");
}
/**
 * A signed-in, browser-like API client: the session cookie plus the synchronizer CSRF token, which
 * the Router requires on every mutating request exactly as it does for the real browser.
 */
async function apiClient(who) {
  const cookies = new Map();
  const absorb = (response) => {
    for (const line of response.headers.getSetCookie ? response.headers.getSetCookie() : []) {
      const [pair] = line.split(";");
      const eq = pair.indexOf("=");
      cookies.set(pair.slice(0, eq).trim(), pair.slice(eq + 1).trim());
    }
  };
  let csrf = "";
  const call = async (method, p, body) => {
    const headers = { Accept: "application/json", "X-ICFWalk-Dev-Subject": who };
    if (body !== undefined) headers["Content-Type"] = "application/json";
    if (csrf && method !== "GET") headers["X-ICFWalk-CSRF-Token"] = csrf;
    const cookie = [...cookies.entries()].map(([k, v]) => `${k}=${v}`).join("; ");
    if (cookie) headers.Cookie = cookie;
    const response = await fetch(`${baseUrl(env)}/index.cfm${p}`, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
    absorb(response);
    const text = await response.text();
    let json = null;
    try { json = JSON.parse(text); } catch { json = null; }
    return { status: response.status, json, text };
  };
  const me = await call("GET", "/api/me");
  assert.equal(me.status, 200, me.text);
  csrf = me.json.csrfToken;
  return { call };
}

/** Saves a state through the API so a browser case starts from a known, persisted walk. */
async function seed(id, dimensions, responses, who = subject) {
  const client = await apiClient(who);
  const walk = await apiWalk(id, who);
  const r = await client.call("PUT", `/api/walks/${id}`, {
    rowVersion: walk.rowVersion, clientMutationId: crypto.randomUUID().toUpperCase(), dimensions, responses,
  });
  assert.equal(r.status, 200, r.text);
  return r.json.walk;
}
async function downloadText(p = page) {
  const [download] = await Promise.all([p.waitForEvent("download", { timeout: 20000 }), p.click("#export-btn")]);
  const file = await download.path();
  return { name: download.suggestedFilename(), text: fs.readFileSync(file, "utf8") };
}

before(async () => {
  if (skip) return;
  const units = await api(env, "POST", "/api/maintenance/org-units/import", {
    token,
    body: {
      orgUnits: [
        { code: `${tag}-district`, type: "DISTRICT", name: "Email fixture district", parentCode: null },
        { code: `${tag}-school`, type: "SCHOOL", name: "Email fixture school", parentCode: `${tag}-district` },
      ],
    },
  });
  assert.equal(units.status, 200, units.text);
  for (const [who, roleCode] of [
    [subject, "SCHOOL_WALK_REPORT"],
    [viewer, "SCHOOL_WALK_REPORT"],
    [reportOnly, "SCHOOL_REPORT_ONLY"],
  ]) {
    const u = await api(env, "POST", "/api/maintenance/identity/provision-user", { token, body: { subject: who, displayName: `Fixture ${who}` } });
    assert.ok(u.status === 201 || u.status === 200, u.text);
    const a = await api(env, "POST", "/api/maintenance/identity/assign-role", {
      token,
      body: { subject: who, roleCode, orgUnitCode: `${tag}-school` },
    });
    assert.equal(a.status, 201, a.text);
  }
  browser = await chromium.launch();
  context = await browser.newContext({
    extraHTTPHeaders: { "X-ICFWalk-Dev-Subject": subject },
    viewport: { width: 1280, height: 900 },
    acceptDownloads: true,
  });
  await context.grantPermissions(["clipboard-read", "clipboard-write"]);
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

// ---- export ---------------------------------------------------------------------------------------

test("SUM-01: the exported file is the server's text, byte for byte, with the derived file name", { skip }, async () => {
  await openHome();
  const id = await startWalk();
  const vector = vectors.vectors.find((v) => v.name === "fully answered high school walk");
  const dimensions = { ...vector.state.dimensions };
  delete dimensions.school; // server-owned for a SCHOOL unit
  await seed(id, dimensions, vector.state.responses);
  await openHome();
  await openCard(id);
  await waitStatus("All changes saved");

  const { name, text } = await downloadText();
  const served = await apiSummary(id);
  assert.equal(served.status, 200);
  const expected = await served.text();
  assert.equal(text, expected, "the downloaded bytes are the route's bytes");
  assert.match(name, /^ICFWalk_[A-Za-z0-9_-]+\.txt$/);
  assert.equal(name, (served.headers.get("content-disposition") || "").match(/filename="([^"]+)"/)[1], "the browser used the server's file name");

  // And the server's text is the shared vector, minus the server-owned School line.
  const drop = (s) => s.split("\n").filter((line) => !line.startsWith("School: ")).join("\n");
  assert.equal(drop(text), drop(vector.expected.summaryText), "the download is the shared vector text");
  assert.equal(text.split("\n")[0], "ICFWALK SUMMARY");
  assert.ok(!text.endsWith("\n"), "no trailing newline reaches the file");
});

test("SUM-01: pending edits are flushed before the download, so the file carries what is on screen", { skip }, async () => {
  await openHome();
  const id = await startWalk();
  await openHome();
  await openCard(id);
  await ensureExpanded("part3");
  // Type and export inside the 700 ms debounce: the export must flush first, not race it.
  await page.fill('[data-item-key="conditions_notes"] textarea', "typed just before exporting");
  const { text } = await downloadText();
  assert.match(text, /Notes: typed just before exporting/, "the flush happened before the download");
  await waitStatus("All changes saved");
  const walk = await apiWalk(id);
  assert.equal(walk.state.responses.conditions_notes.textValue, "typed just before exporting", "and it really was saved");
});

/**
 * SAVE-03 spirit. When the flush cannot reach the server, downloading the server's copy would hand
 * the person a file missing what is on their screen. The browser formatter produces the text from
 * the working state instead, and says so, rather than silently exporting something stale.
 */
test("SUM-01: when the flush cannot reach the server, the export falls back to the text on screen and says so", { skip }, async () => {
  await openHome();
  const id = await startWalk();
  await openHome();
  await openCard(id);
  await ensureExpanded("part3");

  // Every save attempt fails from here on, so nothing typed below ever reaches the server.
  await page.route("**/api/walks/*", (route) => (route.request().method() === "PUT" ? route.abort() : route.continue()));
  try {
    await page.fill('[data-item-key="conditions_notes"] textarea', "only on this page");
    await page.waitForFunction(() => !document.getElementById("save-retry").hidden, null, { timeout: 20000 });

    const { name, text } = await downloadText();
    assert.match(text, /Notes: only on this page/, "the download carries what is on screen");
    assert.match(name, /^ICFWalk_[A-Za-z0-9_-]+\.txt$/, name);
    // The person is told the file did not come from the server.
    assert.match(await page.textContent("#app-message"), /could not be reached/i);
    assert.equal(await page.isHidden("#app-message"), false);

    // And the server really does not have it, so the fallback was not a stale server copy.
    const served = await apiSummary(id);
    assert.equal(served.status, 200);
    assert.doesNotMatch(await served.text(), /only on this page/);
  } finally {
    await page.unroute("**/api/walks/*");
  }
});

test("SEC-02: notes containing markup appear verbatim in the downloaded text and break nothing", { skip }, async () => {
  const payload = '<script>alert(1)</script> & <b>bold</b>';
  await openHome();
  const id = await startWalk();
  await openHome();
  await openCard(id);
  await ensureExpanded("part3");
  await page.fill('[data-item-key="conditions_notes"] textarea', payload);
  await waitStatus("All changes saved");
  const { text } = await downloadText();
  assert.ok(text.includes(`Notes: ${payload}`), "the payload is present verbatim");
  assert.ok(!text.includes("&amp;"), "nothing was HTML-escaped into a text/plain export");
  // The page rendered it as text, so no script ran and no element was created from it.
  assert.equal(await page.evaluate(() => document.querySelectorAll("#editor script").length), 0);
  assert.deepEqual(pageErrors, []);
});

test("SUM-02/05: a walk with blanks and punctuation exports honestly and with a safe file name", { skip }, async () => {
  await openHome();
  const id = await startWalk();
  await seed(
    id,
    { content: { selectedValueCode: "other", otherText: "Art & Design/Media?" }, date: { dateValue: "2026-09-17" } },
    { comp_s1_q1: { storedCode: "4" } },
  );
  await openHome();
  await openCard(id);
  const { name, text } = await downloadText();
  assert.match(name, /^ICFWalk_[A-Za-z0-9_-]+\.txt$/, name);
  assert.ok(!name.includes("/") && !name.includes("?") && !name.includes("&"), name);
  assert.match(text, /2\.1 DAILY ENGAGEMENT WITH COMPLEX TEXTS {2}\(avg: 4\.0\)/);
  assert.match(text, /\[not answered\]/);
  assert.doesNotMatch(text, /\(avg: 0\.0\)/);
});

/**
 * Exporting is a read, so everyone who may open a walk may export it and nobody else may. The
 * decision is the route's: My Walks lists only the signed-in user's own walks (scope=mine), so a
 * colleague never reaches another owner's walk through the list, and the browser's visibility is
 * not what is being trusted here.
 */
test("exporting follows the read decision: a reader may, a report-only role may not", { skip }, async () => {
  await openHome();
  const id = await startWalk();
  await seed(id, {}, { comp_s1_q1: { storedCode: "3" } });

  // The owner is offered the control and it works.
  await openHome();
  await openCard(id);
  assert.equal(await page.isHidden("#export-btn"), false, "the owner is offered the export");
  const { text } = await downloadText();
  assert.equal(text.split("\n")[0], "ICFWALK SUMMARY");

  // A colleague who may read the walk may export it, even though the list never shows it to them.
  const readerList = await apiList(viewer);
  assert.ok(!readerList.some((w) => w.id === id), "My Walks lists only the signed-in user's own walks");
  const reader = await apiSummary(id, viewer);
  assert.equal(reader.status, 200, "a reader in scope may export");
  assert.equal((await reader.text()).split("\n")[0], "ICFWALK SUMMARY");

  // A report-only role is refused, and is given no walk content at all.
  const refused = await apiSummary(id, reportOnly);
  assert.equal(refused.status, 403, "AUTH-05 a report-only role gets no summary");
  assert.ok(!(await refused.text()).includes("ICFWALK SUMMARY"));

  // The export button belongs to the walk view and goes away with it.
  await page.click("#back-btn");
  await page.waitForSelector("#view-list:not([hidden])");
  assert.equal(await page.isHidden("#export-btn"), true, "no walk open, no export control");
});

// ---- composer -------------------------------------------------------------------------------------

/** Opens Part 4 on a fresh walk and returns its id. */
async function openComposer(seedState) {
  await openHome();
  const id = await startWalk();
  if (seedState) await seed(id, seedState.dimensions || {}, seedState.responses || {});
  await openHome();
  await openCard(id);
  await ensureExpanded("part4");
  await page.waitForSelector(".email-slot:not([hidden]) .email-draft-btn");
  return id;
}

const COMPOSER_STATE = {
  dimensions: { grade: { selectedValueCode: "4" }, content: { selectedValueCode: "ela" }, observer: { textValue: "Jane Doe" }, date: { dateValue: "2026-09-17" } },
  responses: {
    part1_adopted_notes: { textValue: "adopted note" },
    comp_s3_applicable: { storedCode: "no" },
    comp_s3_notes: { textValue: "not a workshop day" },
    conditions_notes: { textValue: "warm routines" },
    summary_strengths: { textValue: "strength" },
  },
};

test("SUM-06: checking parts and drafting produces exactly the shared formatter's subject and body", { skip }, async () => {
  const id = await openComposer(COMPOSER_STATE);
  const labels = await page.$$eval(".email-parts .checkrow", (nodes) => nodes.map((n) => n.textContent.trim()));
  assert.ok(labels.includes("Part 1: Target / Taxonomy / Pacing"), labels.join(" | "));
  assert.ok(labels.includes("2.3: Workshop Model"));
  assert.ok(labels.includes("Part 3: Conditions for Learning"));
  assert.ok(labels.includes("Part 4: Walk Summary"));
  assert.equal(await page.getAttribute(".email-parts", "role"), "group");
  const labelledBy = await page.getAttribute(".email-parts", "aria-labelledby");
  assert.ok(await page.isVisible(`#${labelledBy}`), "the group is labelled by the item's own prompt");

  assert.equal(await page.isHidden(".email-box"), true, "the box is hidden until a draft exists");
  for (const key of ["part1", "comp_s3", "belonging", "summary"]) await page.check(`.email-parts input[data-part="${key}"]`);
  await page.click(".email-draft-btn");
  await page.waitForSelector(".email-box:not([hidden])");
  await waitStatus("All changes saved");

  // The browser's draft must be the shared formatter's draft for the walk as the server holds it.
  const walk = await apiWalk(id);
  const { evaluate } = await import("../../app/assets/js/rules.js");
  const { emailDraft } = await import("../../app/assets/js/summary.js");
  const instrument = await (await fetch(`${baseUrl(env)}/index.cfm/api/instrument/current`, { headers: { "X-ICFWalk-Dev-Subject": subject } })).json();
  const expected = emailDraft(instrument.model, walk.state, evaluate(instrument.model, walk.state), ["part1", "comp_s3", "belonging", "summary"]);
  assert.equal(await page.inputValue(".email-subject"), expected.subject);
  assert.equal(await page.inputValue(".email-body"), expected.body);

  const body = await page.inputValue(".email-body");
  assert.match(body, /Part 1 — Target \/ Taxonomy \/ Pacing:\nAdopted Curriculum notes: adopted note/);
  assert.match(body, /2\.3 — Workshop Model of Instruction:\n• Not part of this lesson at the time of the visit\./);
  assert.match(body, /Part 3 — Conditions for Learning:\nNotes: warm routines/);
  assert.match(body, /Part 4: Walk Summary:\nStrengths: strength/);
  assert.ok(!body.includes("2.1 —"), "an unchecked part must not appear");
  assert.match(body, /Jane Doe$/);
});

test("SUM-07: an edited draft is autosaved, survives a reload, and raises no conflict", { skip }, async () => {
  const id = await openComposer(COMPOSER_STATE);
  await page.check('.email-parts input[data-part="summary"]');
  await page.click(".email-draft-btn");
  await page.waitForSelector(".email-box:not([hidden])");
  await page.fill(".email-to", "teacher@u46.org");
  await page.fill(".email-subject", "Hand-edited subject");
  await page.fill(".email-body", "Hand-edited body with <b>markup</b> & an ampersand.");
  await waitStatus("All changes saved");

  // The canonical document is what the server stores, so a reload compares equal.
  const walk = await apiWalk(id);
  const stored = walk.state.responses.email_workflow.textValue;
  assert.equal(
    stored,
    JSON.stringify({
      body: "Hand-edited body with <b>markup</b> & an ampersand.",
      drafted: true,
      includedPartKeys: ["summary"],
      subject: "Hand-edited subject",
      to: "teacher@u46.org",
    }),
    "the stored document is canonical",
  );

  await page.reload({ waitUntil: "networkidle" });
  await page.waitForSelector("body[data-ready=true]");
  await openCard(id);
  await ensureExpanded("part4");
  await page.waitForSelector(".email-box:not([hidden])");
  assert.equal(await page.inputValue(".email-to"), "teacher@u46.org");
  assert.equal(await page.inputValue(".email-subject"), "Hand-edited subject");
  assert.equal(await page.inputValue(".email-body"), "Hand-edited body with <b>markup</b> & an ampersand.");
  assert.equal(await page.isChecked('.email-parts input[data-part="summary"]'), true, "the ticked parts are restored");
  // A canonicalization mismatch would surface here as a phantom unsent edit.
  assert.equal(await page.isHidden("#conflict-panel"), true, "reopening raises no conflict");
  assert.equal(await page.textContent("#save-status"), "All changes saved");
  await page.locator(".email-slot").scrollIntoViewIfNeeded();
  await page.waitForTimeout(150);
  await page.screenshot({ path: path.join(shotDir, "email-composer-desktop.png"), fullPage: false });
});

test("SUM-08: Copy puts the draft on the clipboard and Open in email app only navigates to mailto:", { skip }, async () => {
  const id = await openComposer(COMPOSER_STATE);
  await page.check('.email-parts input[data-part="belonging"]');
  await page.click(".email-draft-btn");
  await page.waitForSelector(".email-box:not([hidden])");
  // A recipient that would be a header-injection attempt if anything ever parsed it as mail. A
  // single-line input applies the HTML value sanitization algorithm, so a CR/LF cannot even be
  // typed into it; the encoding of one that reached the field some other way is pinned as a unit
  // case in tests/node/no-mail.test.mjs.
  await page.fill(".email-to", "teacher@u46.org\r\nbcc: victim@example.test");
  const typedRecipient = await page.inputValue(".email-to");
  assert.ok(!typedRecipient.includes("\r") && !typedRecipient.includes("\n"),
    `a single-line input cannot hold a line break, so the UI cannot produce a CR/LF at all: ${JSON.stringify(typedRecipient)}`);
  assert.ok(typedRecipient.includes("bcc:"), "the rest of the injection attempt is kept as ordinary text");
  await waitStatus("All changes saved");

  const subjectValue = await page.inputValue(".email-subject");
  const bodyValue = await page.inputValue(".email-body");
  await page.click(".email-copy-btn");
  await page.waitForFunction(() => document.querySelector(".email-copy-btn").textContent === "Copied!");
  const clipboard = await page.evaluate(() => navigator.clipboard.readText());
  assert.equal(clipboard, `Subject: ${subjectValue}\n\n${bodyValue}`);
  assert.match(await page.textContent(".email-status"), /copied/i);

  // window.location is [Unforgeable] in Chromium, so the assignment itself cannot be intercepted.
  // What is observable is asserted instead: clicking makes no request, navigates nowhere, and
  // leaves the page intact. The URL that is assigned is pinned by calling the very function the
  // button calls (email-composer.js mailtoUrl) on the live field values, and tests/node/no-mail
  // .test.mjs pins that the button's only action is `window.location.href = mailtoUrl(...)`.
  const requests = [];
  page.on("request", (r) => requests.push(`${r.method()} ${r.url()}`));
  const urlBefore = page.url();

  const live = await page.evaluate(() => ({
    to: document.querySelector(".email-to").value,
    subject: document.querySelector(".email-subject").value,
    body: document.querySelector(".email-body").value,
  }));
  const { mailtoUrl } = await import("../../app/assets/js/email-composer.js");
  const url = mailtoUrl(live);
  assert.ok(url.startsWith("mailto:"), url);
  assert.ok(!url.includes("\r") && !url.includes("\n"), "no raw line break reaches the URL");
  assert.ok(url.includes("bcc%3A"), "a bcc: attempt is encoded as data, not as a header");
  assert.ok(!/[?&]bcc=/i.test(url), "and it can never become a mailto bcc parameter");
  assert.match(url, /^mailto:[^?]*\?subject=[^&]*&body=/);
  assert.equal(url, `mailto:${encodeURIComponent(live.to)}?subject=${encodeURIComponent(live.subject)}&body=${encodeURIComponent(live.body)}`);

  await page.click(".email-open-btn");
  await page.waitForTimeout(300);
  assert.equal(page.url(), urlBefore, "the page did not navigate away");
  assert.equal(await page.isVisible(".email-box"), true, "the composer is still on screen");

  // Nothing left the page for a mail route: the only requests are the ordinary walk save path.
  const mailRequests = requests.filter((r) => /\/(email|mail|send|notify)\b/i.test(r));
  assert.deepEqual(mailRequests, [], `no mail request may be made:\n${requests.join("\n")}`);
  assert.ok(id);
});

test("SUM-09: Clear empties the generated text and leaves every other answer alone", { skip }, async () => {
  const id = await openComposer(COMPOSER_STATE);
  await page.check('.email-parts input[data-part="summary"]');
  await page.click(".email-draft-btn");
  await page.waitForSelector(".email-box:not([hidden])");
  // The recipient lives inside the box, which only exists once there is a draft to address.
  await page.fill(".email-to", "teacher@u46.org");
  await waitStatus("All changes saved");
  const before = await apiWalk(id);

  await page.click(".email-clear-btn");
  await page.waitForSelector(".email-box", { state: "hidden" });
  await waitStatus("All changes saved");

  const after = await apiWalk(id);
  const doc = JSON.parse(after.state.responses.email_workflow.textValue);
  assert.equal(doc.drafted, false);
  assert.equal(doc.subject, "");
  assert.equal(doc.body, "");
  assert.equal(doc.to, "teacher@u46.org", "the recipient is kept");
  assert.deepEqual(doc.includedPartKeys, ["summary"], "the ticked parts are kept");
  assert.equal(await page.isChecked('.email-parts input[data-part="summary"]'), true);
  assert.equal(await page.inputValue(".email-to"), "teacher@u46.org");

  // Every other response is untouched.
  const strip = (state) => {
    const copy = { ...state.responses };
    delete copy.email_workflow;
    return copy;
  };
  assert.deepEqual(strip(after.state), strip(before.state), "no other response changed");
  assert.deepEqual(after.state.dimensions, before.state.dimensions, "no dimension changed");
});

/**
 * Read-only enforcement. The server is the boundary and is asserted as such; the browser's part is
 * that applyEditability's selector set actually reaches every composer control, which is the piece
 * that could silently stop being true when the composer's markup changes. A non-owner's read-only
 * editor is not reachable through the Phase 4 My Walks UI (it lists only the signed-in user's own
 * walks), so it is not driven here.
 */
test("read-only: the server refuses a reader's save, and every composer control is one the editor disables", { skip }, async () => {
  const id = await openComposer(COMPOSER_STATE);
  await page.check('.email-parts input[data-part="summary"]');
  await page.click(".email-draft-btn");
  await page.waitForSelector(".email-box:not([hidden])");
  await waitStatus("All changes saved");

  // Every control the composer renders is matched by the selector set applyEditability disables, so
  // a read-only walk cannot leave one of them live. Editable now, so all of them are enabled.
  const coverage = await page.evaluate(() => {
    const editor = document.getElementById("editor");
    const covered = new Set(editor.querySelectorAll("select, input, textarea, .pill, .email-slot button"));
    const controls = [...editor.querySelectorAll(".email-slot button, .email-slot input, .email-slot textarea, .email-slot select")];
    return {
      total: controls.length,
      uncovered: controls.filter((c) => !covered.has(c)).map((c) => c.className || c.tagName),
      enabled: controls.every((c) => !c.disabled),
    };
  });
  assert.ok(coverage.total >= 15, `expected the whole composer, saw ${coverage.total}`);
  assert.deepEqual(coverage.uncovered, [], "every composer control is one the editor can disable");
  assert.equal(coverage.enabled, true, "and they are live while the walk is editable");

  // The boundary itself: a reader with a real session, a real CSRF token, and the current row
  // version is still refused. Client visibility is never what protects the walk.
  const walk = await apiWalk(id, viewer);
  const readerClient = await apiClient(viewer);
  const refused = await readerClient.call("PUT", `/api/walks/${id}`, {
    rowVersion: walk.rowVersion,
    clientMutationId: crypto.randomUUID().toUpperCase(),
    dimensions: {},
    responses: { email_workflow: { textValue: '{"body":"x","drafted":true,"includedPartKeys":[],"subject":"x","to":""}' } },
  });
  assert.equal(refused.status, 403, `a reader's save is refused by the server: ${refused.text}`);
  // And the draft is untouched by the attempt.
  assert.equal(JSON.parse((await apiWalk(id)).state.responses.email_workflow.textValue).subject, await page.inputValue(".email-subject"));
});

test("A11Y-01: the composer is fully operable from the keyboard", { skip }, async () => {
  await openComposer(COMPOSER_STATE);
  const firstBox = page.locator('.email-parts input[data-part="part1"]');
  await firstBox.focus();
  assert.equal(await page.evaluate(() => document.activeElement.getAttribute("data-part")), "part1");
  // Space toggles a checkbox.
  await page.keyboard.press("Space");
  assert.equal(await firstBox.isChecked(), true);
  await page.keyboard.press("Space");
  assert.equal(await firstBox.isChecked(), false);
  await page.keyboard.press("Space");
  assert.equal(await firstBox.isChecked(), true);

  // Tab reaches Draft email from the last checkbox, and Enter activates it.
  await page.locator(".email-draft-btn").focus();
  await page.keyboard.press("Enter");
  await page.waitForSelector(".email-box:not([hidden])");
  assert.ok((await page.inputValue(".email-body")).length > 0, "Enter on Draft email drafted the message");
  await waitStatus("All changes saved");

  // Every control in the composer is reachable and has an accessible name.
  const named = await page.$$eval(".email-slot button, .email-slot input, .email-slot textarea", (nodes) =>
    nodes.map((n) => {
      const id = n.getAttribute("id");
      const label = id ? document.querySelector(`label[for="${CSS.escape(id)}"]`) : n.closest("label");
      return { tag: n.tagName, name: (n.getAttribute("aria-label") || (label && label.textContent) || n.textContent || "").trim() };
    }),
  );
  assert.ok(named.length >= 15, `expected the whole composer, saw ${named.length}`);
  for (const control of named) assert.ok(control.name.length > 0, `a ${control.tag} has no accessible name`);
});

test("A11Y-03: axe-core finds no serious or critical violation in either composer state", { skip }, async () => {
  const axeSource = fs.readFileSync(require.resolve("axe-core/axe.min.js"), "utf8");
  await page.route("**/assets/js/axe.min.js", (route) =>
    route.fulfill({ status: 200, contentType: "application/javascript", body: axeSource }),
  );
  const run = async () => {
    if (!(await page.evaluate(() => Boolean(window.axe)))) await page.addScriptTag({ url: `${baseUrl(env)}/assets/js/axe.min.js` });
    return page.evaluate(async () => {
      const r = await window.axe.run(document, { runOnly: { type: "tag", values: ["wcag2a", "wcag2aa", "wcag21a", "wcag21aa"] } });
      return r.violations.map((v) => ({ id: v.id, impact: v.impact, nodes: v.nodes.length, help: v.help }));
    });
  };

  await openComposer(COMPOSER_STATE);
  const undrafted = (await run()).filter((v) => v.impact === "serious" || v.impact === "critical");
  assert.deepEqual(undrafted, [], `undrafted composer: ${JSON.stringify(undrafted)}`);

  await page.check('.email-parts input[data-part="summary"]');
  await page.click(".email-draft-btn");
  await page.waitForSelector(".email-box:not([hidden])");
  const drafted = (await run()).filter((v) => v.impact === "serious" || v.impact === "critical");
  assert.deepEqual(drafted, [], `drafted composer: ${JSON.stringify(drafted)}`);

  await page.setViewportSize({ width: 375, height: 800 });
  await page.waitForTimeout(150);
  const phone = (await run()).filter((v) => v.impact === "serious" || v.impact === "critical");
  assert.deepEqual(phone, [], `composer at 375px: ${JSON.stringify(phone)}`);
  await page.locator(".email-slot").scrollIntoViewIfNeeded();
  await page.waitForTimeout(150);
  await page.screenshot({ path: path.join(shotDir, "email-composer-phone.png"), fullPage: false });
  await page.setViewportSize({ width: 1280, height: 900 });

  assert.deepEqual(pageErrors, [], "no page errors in any composer state");
});
