/**
 * Phase 5 correction: the browser export flushes the editor state and falls back to a
 * browser-generated file only when the server genuinely cannot be reached.
 *
 * THE DEFECT. exportSummary() decided where to download from by looking at the editor's unsent-work
 * flags:
 *
 *     const unsent = walk.canEdit && (app.dirty || app.failed || Boolean(ambiguousSave()));
 *
 * That expression is true in two cases the Phase 5 contract never allowed a local file in.
 *
 *   1. An edit made while a save is in flight. saveCurrent() coalesces: called with a request
 *      already on the wire it returns that request's promise and leaves the newer state on the
 *      autosave timer. The export awaited the older save, saw app.dirty still set, and produced a
 *      Blob from the page while the queued edit sat unsent. The file was browser-made and the
 *      person was told the server could not be reached, when the server was answering normally and
 *      the export had simply not waited for the second request.
 *   2. A definitive rejection. Any 4xx sets app.failed. The server was reached and refused the
 *      state; the export nevertheless built a local file of the refused state and blamed the
 *      network.
 *
 * Both bypass the authoritative, authorized, audited summary route, and both display a message that
 * is not true.
 *
 * THE RULE NOW ENFORCED. The editor state is flushed to the server first, repeatedly if edits
 * queued behind an in-flight save, and the download comes from GET /api/walks/{id}/summary. The
 * browser formatter is used only when that flush failed with a transport failure -- no HTTP
 * response at all. A 4xx, a 5xx and a conflict each block the export with their own accurate
 * message and no file.
 *
 * The distinction these tests turn on is transport failure versus HTTP response, so they produce
 * each one separately and never by proxy: a transport failure is Playwright aborting the request
 * with connectionreset, so the browser's fetch() rejects and api.js raises NetworkError; an HTTP
 * error is a real response with a real status, which api.js raises as ApiError.
 *
 * The harness (export-harness.mjs) serves the shipped browser modules and the real shell against a
 * scripted API; see its header for what is real in it and what is not.
 */
import { test, before, after, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { startStub, serverSummary } from "./export-harness.mjs";

const require = createRequire(import.meta.url);
let chromium = null;
try { ({ chromium } = require("playwright")); } catch { chromium = null; }
const skip = chromium ? false : "playwright is not installed";

const SUMMARY_ROUTE = "/summary";
const STATUS_SAVED = "All changes saved";

let stub = null, browser = null, context = null, page = null;
let pageErrors = [];

before(async () => {
  if (skip) return;
  stub = await startStub();
  browser = await chromium.launch();
});

after(async () => {
  await browser?.close();
  await stub?.stop();
});

/**
 * Each test gets its own browser context and its own copy of the stub's walk, so no test can
 * inherit a state, a cookie or a download from another.
 */
beforeEach(async () => {
  if (skip) return;
  stub.reset();
  context = await browser.newContext({ viewport: { width: 1280, height: 900 }, acceptDownloads: true });
  page = await context.newPage();
  pageErrors = [];
  page.on("pageerror", (e) => pageErrors.push(`pageerror: ${e.message}`));
  // The shell links a web font and a logo from the district's CDN; neither is reachable here and
  // neither is under test. Every other console error is a real fault and is asserted on.
  page.on("console", (m) => { if (m.type() === "error" && !/ERR_|net::|Failed to load resource/.test(m.text())) pageErrors.push(m.text()); });
  // Records every browser-generated object URL. A local fallback cannot happen without one, so an
  // empty list is proof that the download came from the server route.
  await page.addInitScript(() => {
    window.__objectUrls = [];
    const real = URL.createObjectURL.bind(URL);
    URL.createObjectURL = (blob) => { const url = real(blob); window.__objectUrls.push(url); return url; };
  });
});

afterEach(async () => {
  const closing = context;
  context = null;
  page = null;
  await closing?.close();
});

// ---- page helpers --------------------------------------------------------------------------------

async function openEditor() {
  await page.goto(`${stub.origin}/`);
  await page.waitForFunction(() => document.body.dataset.ready === "true", null, { timeout: 20000 });
  await page.click(".walk-card .open-btn");
  await page.waitForSelector("#view-walk:not([hidden])", { timeout: 20000 });
  await expandNotes();
}

/** The notes field lives in a collapsed accordion, exactly as it does in the application. */
async function expandNotes() {
  const head = page.locator('[data-section-key="part3"] > h2 > .acc-head');
  if ((await head.getAttribute("aria-expanded")) !== "true") await head.click();
  await page.waitForSelector('[data-item-key="conditions_notes"] textarea:not([hidden])', { timeout: 20000 });
}

const status = () => page.textContent("#save-status");
const message = () => page.textContent("#app-message");
const announced = () => page.textContent("#announcer");
/** announce() clears the live region and fills it a tick later, so it is waited for, not sampled. */
const waitAnnounced = (pattern) =>
  page.waitForFunction((src) => new RegExp(src, "i").test(document.getElementById("announcer").textContent), pattern.source, { timeout: 10000 });
const waitStatus = (text) => page.waitForFunction((t) => document.getElementById("save-status").textContent === t, text, { timeout: 20000 });
const type = (value) => page.fill('[data-item-key="conditions_notes"] textarea', value);
const objectUrls = () => page.evaluate(() => window.__objectUrls.slice());

/**
 * Clicks Export and returns { url, fileName, text } for the file it produced, or null when it
 * produced none.
 *
 * The bytes are read here rather than by the caller, always: the local fallback revokes its object
 * URL the instant it clicks the link, so a download nobody reads never finishes and keeps the
 * browser context from closing. Reading it here means a test that fails on its first assertion
 * still reports that failure instead of hanging the run.
 */
async function exportAndWait({ timeout = 8000 } = {}) {
  const pending = page.waitForEvent("download", { timeout }).catch(() => null);
  await page.click("#export-btn");
  const download = await pending;
  if (!download) return null;
  const stream = await download.createReadStream();
  const chunks = [];
  for await (const chunk of stream) chunks.push(chunk);
  return { url: download.url(), fileName: download.suggestedFilename(), text: Buffer.concat(chunks).toString("utf8") };
}

/** Clicks Export and asserts no file was produced within the window. */
async function exportExpectingNothing() {
  const file = await exportAndWait({ timeout: 3000 });
  assert.equal(file, null, file ? `no file may be downloaded, but one arrived from ${file.url}` : "no file may be downloaded");
  assert.deepEqual(await objectUrls(), [], "and no browser-generated blob may be created");
}

// ---- the queued-save case: the audited regression -------------------------------------------------

/**
 * The first defect, end to end. A save is held open, a second edit is made while it is on the wire,
 * and Export is clicked before the first save has answered.
 *
 * Against the uncorrected code: the export awaited the in-flight save, found app.dirty still set
 * because of the second edit, and downloaded a Blob built in the browser -- while the second edit
 * was still waiting on the 700 ms autosave timer and had never been sent. The summary GET never
 * happened, and the person was told the server could not be reached.
 */
test("a save in flight and an edit behind it are both flushed before the summary is fetched", { skip }, async () => {
  await openEditor();
  // The first save is held open long enough for a second edit to land behind it with certainty.
  stub.planSave({ delayMs: 1200 });

  await type("first edit");
  await page.click("#save-btn");                       // send it now rather than waiting out the debounce
  await page.waitForFunction(() => document.getElementById("save-status").textContent === "Saving...", null, { timeout: 5000 });
  await type("second edit, made while the first save was on the wire");

  const file = await exportAndWait({ timeout: 20000 });
  assert.ok(file, "the export produced a file");

  // 4. The queued edit really was sent, and it was sent before the summary was fetched.
  const puts = stub.indicesOf("PUT", `/walks/${stub.walkId}`);
  const summaries = stub.indicesOf("GET", SUMMARY_ROUTE);
  assert.equal(puts.length, 2, "both the in-flight save and the edit queued behind it were sent");
  assert.equal(summaries.length, 1, "and the summary was fetched once");
  assert.ok(puts[1] < summaries[0], "the queued save completed before the summary GET began");

  // 5. The server holds the latest edit, and the downloaded file is the server's own text.
  assert.equal(
    stub.serverState().responses.conditions_notes.textValue,
    "second edit, made while the first save was on the wire",
    "the server committed the edit made during the in-flight save",
  );
  
  assert.equal(file.text, serverSummary(stub.serverState()).text, "the download is the server's summary bytes");
  assert.match(file.text, /Notes: second edit, made while the first save was on the wire/);

  // 6 and 7. The editor settled, and nothing was generated in the browser.
  await waitStatus(STATUS_SAVED);
  assert.equal(await status(), STATUS_SAVED);
  assert.deepEqual(await objectUrls(), [], "no local Blob fallback was used");
  assert.ok(!file.url.startsWith("blob:"), `the download came from the server route, not a blob: ${file.url}`);
  assert.match(file.url, /\/api\/walks\/[^/]+\/summary$/);
  assert.equal(await page.isHidden("#app-message"), true, "and nothing claimed the server could not be reached");
  assert.deepEqual(pageErrors, []);
});

// ---- definitive rejection ------------------------------------------------------------------------

/**
 * A 4xx is the server refusing the state, with the server plainly reachable. The old code set
 * app.failed and downloaded the refused state as a local file that looked like the saved walk,
 * under a message blaming the network.
 */
test("a definitive 4xx save rejection produces no download and an accurate message", { skip }, async () => {
  await openEditor();
  stub.planSave({ status: 400, code: "INVALID_RESPONSE_VALUE", message: "rejected by the harness", sticky: true });

  await type("an edit the server will refuse");
  await page.click("#save-btn");
  await page.waitForFunction(() => document.getElementById("save-status").textContent.startsWith("Could not save"), null, { timeout: 20000 });

  await exportExpectingNothing();

  const shown = await message();
  assert.match(shown, /did not accept the latest changes/i, shown);
  assert.doesNotMatch(shown, /could not be reached/i, "a rejection is never reported as a network failure");
  assert.equal(await page.isHidden("#app-message"), false);
  await waitAnnounced(/did not accept the latest changes/);
  assert.equal((await announced()).trim(), shown.trim(), "and the same words reach a screen reader");
  assert.equal(stub.indicesOf("GET", SUMMARY_ROUTE).length, 0, "the server summary is not fetched for a state the server refused");
  assert.deepEqual(pageErrors, []);
});

// ---- conflict -------------------------------------------------------------------------------------

test("a conflict produces no download and leaves the conflict workflow open", { skip }, async () => {
  await openEditor();
  stub.planSave({ status: 409, code: "STALE_ROW_VERSION", message: "changed elsewhere", details: { walkId: stub.walkId, serverRowVersion: "0x00000000000000ff" }, sticky: true });

  await type("an edit that will conflict");
  await page.click("#save-btn");
  await page.waitForSelector("#conflict-panel:not([hidden])", { timeout: 20000 });

  await exportExpectingNothing();

  assert.match(await message(), /Resolve the conflict/i);
  assert.equal(await page.isHidden("#conflict-panel"), false, "the conflict panel is still open");
  assert.equal(stub.indicesOf("GET", SUMMARY_ROUTE).length, 0);
  assert.deepEqual(pageErrors, []);
});

// ---- HTTP 5xx: ambiguous, but the server was reached -----------------------------------------------

/**
 * An unfinished save is not an unreachable server. The Phase 4 guarantee is unchanged -- the
 * operation record keeps its mutation id and its frozen body so the retry replays rather than
 * duplicating -- but the export refuses to hand over a file and says what actually happened.
 */
test("an HTTP 5xx blocks the export as an unfinished save, not as a network failure", { skip }, async () => {
  await openEditor();
  stub.planSave({ status: 503, code: "UPSTREAM_UNAVAILABLE", message: "lost", sticky: true });

  await type("an edit whose save does not finish");
  await page.click("#save-btn");
  await page.waitForFunction(() => !document.getElementById("save-retry").hidden, null, { timeout: 20000 });

  await exportExpectingNothing();

  const shown = await message();
  assert.match(shown, /last save did not finish/i, shown);
  assert.doesNotMatch(shown, /could not be reached/i, "an HTTP 5xx is never reported as a network failure");
  assert.equal(stub.indicesOf("GET", SUMMARY_ROUTE).length, 0);
  // The Phase 4 recovery record survives: the retry is still offered.
  assert.equal(await page.isHidden("#save-retry"), false, "the ambiguous save is still offered for retry");
  assert.deepEqual(pageErrors, []);
});

// ---- genuine transport failure ---------------------------------------------------------------------

/**
 * The one case the browser formatter is for. Playwright aborts the request, so no response is
 * produced and api.js raises NetworkError rather than ApiError -- a transport failure, told apart
 * from an HTTP error by its kind and not by its status.
 */
test("a genuine transport failure produces a browser-generated file from the screen state", { skip }, async () => {
  await openEditor();
  await page.route(`**/api/walks/${stub.walkId}`, (route) => (route.request().method() === "PUT" ? route.abort("connectionreset") : route.continue()));
  try {
    await type("only on this page");
    await page.click("#save-btn");
    await page.waitForFunction(() => !document.getElementById("save-retry").hidden, null, { timeout: 20000 });

    const file = await exportAndWait({ timeout: 20000 });
    assert.ok(file, "the export produced a file");
    assert.ok(file.url.startsWith("blob:"), `the file was generated in the browser: ${file.url}`);
    assert.equal((await objectUrls()).length, 1, "exactly one browser-generated blob");

    // The text is the formatter's output for what is on screen, byte for byte: the same function the
    // server runs, over the state the server does not have.
    const onScreen = { ...stub.serverState(), responses: { conditions_notes: { textValue: "only on this page" } } };
    assert.equal(file.text, serverSummary(onScreen).text, "the file is the working state's summary text");
    assert.equal(file.fileName, serverSummary(onScreen).name, "with the same derived, safe file name");
    assert.match(file.fileName, /^ICFWalk_[A-Za-z0-9_-]+\.txt$/);

    // The person is told where the file came from, in the same words on screen and to a screen reader.
    const shown = await message();
    assert.match(shown, /could not be reached/i, shown);
    assert.match(shown, /generated in your browser/i, "and that the browser made it");
    assert.match(shown, /unsaved/i, "from information that is not saved");
    await waitAnnounced(/generated in your browser/);

    // And the server really does not have it, so this was not a stale server copy relabelled.
    assert.equal(stub.serverState().responses.conditions_notes, undefined, "nothing reached the server");
  } finally {
    await page.unroute(`**/api/walks/${stub.walkId}`);
  }
  assert.deepEqual(pageErrors, []);
});

// ---- the ordinary paths still work ------------------------------------------------------------------

test("a clean export with nothing unsent uses the authenticated summary GET", { skip }, async () => {
  await openEditor();
  await waitStatus(STATUS_SAVED);

  const file = await exportAndWait({ timeout: 20000 });
  assert.ok(file, "the export produced a file");
  assert.match(file.url, /\/api\/walks\/[^/]+\/summary$/, file.url);
  assert.deepEqual(await objectUrls(), [], "no browser-generated file when there is nothing unsent");
  assert.equal(file.text, serverSummary(stub.serverState()).text);
  assert.equal(stub.indicesOf("PUT", `/walks/${stub.walkId}`).length, 0, "and nothing was saved: an export of a clean editor writes nothing");
  assert.deepEqual(pageErrors, []);
});

/**
 * A reader who may not edit has no editor state to flush, so the export goes straight to the server
 * route. The flush must not run for them at all: there is nothing to send and no save they could
 * make.
 */
test("a read-only viewer exports straight from the server route", { skip }, async () => {
  await page.route(`**/api/walks/${stub.walkId}`, async (route) => {
    if (route.request().method() !== "GET") return route.continue();
    const response = await route.fetch();
    const body = await response.json();
    body.walk = { ...body.walk, canEdit: false, isOwner: false, ownerDisplayName: "Someone Else" };
    return route.fulfill({ response, body: JSON.stringify(body) });
  });
  try {
    await page.goto(`${stub.origin}/`);
    await page.waitForFunction(() => document.body.dataset.ready === "true", null, { timeout: 20000 });
    await page.click(".walk-card .open-btn");
    await page.waitForSelector("#view-walk:not([hidden])", { timeout: 20000 });
    assert.equal(await page.isHidden("#export-btn"), false, "a reader is still offered the export");
    assert.equal(await status(), "Read only");

    const file = await exportAndWait({ timeout: 20000 });
    assert.ok(file, "the export produced a file");
    assert.match(file.url, /\/api\/walks\/[^/]+\/summary$/, file.url);
    assert.deepEqual(await objectUrls(), [], "a reader never gets a browser-generated file");
    assert.equal(stub.indicesOf("PUT", `/walks/${stub.walkId}`).length, 0, "and no save was attempted on their behalf");
  } finally {
    await page.unroute(`**/api/walks/${stub.walkId}`);
  }
  assert.deepEqual(pageErrors, []);
});
