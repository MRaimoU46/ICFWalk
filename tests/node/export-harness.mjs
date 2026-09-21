/**
 * A deterministic, self-contained harness for the browser export path.
 *
 * WHY IT EXISTS. tests/node/browser-email.test.mjs exercises the export against the real
 * application, the real instrument, and SQL Server, and that is where the instrument's content, the
 * server's bytes and the authorization rules are proven. It cannot, however, hold a save request
 * open at a chosen instant, answer the next one 400 and the one after that 409, or distinguish a
 * transport failure from an HTTP response on demand -- and those are exactly the conditions the
 * export's path selection turns on. This harness serves the real browser modules (app.js,
 * api.js, walk-store.js, renderer.js, rules.js, summary.js, walk-state.js, the real shell) against
 * a scripted API, so each of those conditions is produced on purpose rather than waited for.
 *
 * WHAT IS REAL AND WHAT IS NOT. Every line of browser code under test is the shipped file; nothing
 * is stubbed, shimmed or re-implemented. The shell is src/views/shell.html with the same three
 * substitutions ShellController.cfc makes. The API is a stub, and the instrument is the small
 * synthetic one below rather than the district's: the behavior under test is which URL the export
 * downloads from and what it does with unsent work, which is independent of the instrument's
 * content. The summary route answers with the shared formatter's own output over the server-held
 * state, so "the download carries what the server has" is a real comparison and not a canned string.
 */
import fs from "node:fs";
import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { summaryText, fileName as summaryFileName } from "../../app/assets/js/summary.js";
import { evaluate } from "../../app/assets/js/rules.js";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "..", "..");

// ---- the synthetic instrument -------------------------------------------------------------------
//
// The smallest render model the editor, the rules engine and the formatter all accept: an identity
// card carrying the two dimensions the file name pattern names, and one accordion with a notes
// field to type into. No rules, so nothing is ever hidden and every export is a plain function of
// the state -- which keeps these tests about the export's path selection and nothing else.

const VERSION_ID = "VER-EXPORT-HARNESS";

export const MODEL = {
  format: "icfwalk-render-model/1",
  behavior: { export: { format: "text/plain", fileNamePattern: "ICFWalk_<grade>_<date>.txt" } },
  rules: [],
  optionFilters: [],
  placeholders: [],
  dimensions: {
    grade: {
      code: "grade", label: "Grade level", dataType: "LIST", valueMode: "CONTROLLED_LIST", allowOther: false,
      values: [{ valueCode: "2", label: "2" }, { valueCode: "5", label: "5" }],
    },
    date: { code: "date", label: "Date", dataType: "DATE", valueMode: "TYPED", allowOther: false, values: [] },
  },
  root: section("root", "", "root", {
    children: [
      section("identity", "Visit", "card", {
        placements: [
          placement("grade", "Grade level", "LIST"),
          placement("date", "Date", "DATE"),
        ],
      }),
      section("part3", "Part 3 · Conditions for Learning", "accordion", {
        items: [{
          itemKey: "conditions_notes", layout: "notes", prompt: "Notes", itemType: "LONG_TEXT",
          responseSet: null, questionNumber: 0, isPlaceholder: false, settings: {},
        }],
      }),
    ],
  }),
};

function section(sectionKey, title, presentation, extra = {}) {
  return {
    sectionKey, title, presentation,
    instructions: "", requiredSection: false, headingVisible: true, hasLookFors: false,
    canBeSkipped: false, defaultApplicable: true, applicabilityItemKey: null, ratedItemKeys: [],
    conditional: false, ruleKeys: [], partNumber: null, colorHex: null, notesEnabled: true,
    placements: [], items: [], children: [],
    ...extra,
  };
}

function placement(dimensionCode, label, dataType) {
  return {
    dimensionCode, label, dataType, required: false, allowOther: false, visibleByDefault: true,
    placeholder: "", displayOrder: 10, settings: {},
  };
}

/** The server's own summary bytes for a state: the shared formatter, exactly as the CFML twin does. */
export function serverSummary(state) {
  const evaluation = evaluate(MODEL, state);
  return { text: summaryText(MODEL, state, evaluation), name: summaryFileName(MODEL, state, evaluation, "walk-1") };
}

// ---- the stub application -----------------------------------------------------------------------

const ASSET_TYPES = { ".js": "text/javascript; charset=utf-8", ".css": "text/css; charset=utf-8" };
const WALK_ID = "11111111-2222-4333-8444-555555555555";

/**
 * Starts the stub on an ephemeral port.
 *
 * The save route's behavior for each request is taken from `plan`, a queue the test fills: an entry
 * may delay the answer, answer with an HTTP status instead of committing, answer 200 with a body of
 * the test's choosing (valid JSON or not), or answer 200 with a body the browser cannot read at
 * all. Everything else is a faithful minimal server: it holds one walk, commits whole states, bumps
 * a row version, and refuses a stale one with 409 the way the real route does.
 */
export async function startStub() {
  const INITIAL_WALK = Object.freeze({
    id: WALK_ID, orgUnitId: "ORG-1", orgUnitName: "Harness School", orgUnitCode: "harness-school",
    lockedDimensions: [], versionId: VERSION_ID, versionLabel: "Harness v1", status: "DRAFT",
    ownerUserId: "USER-1", ownerDisplayName: "Harness Walker", isOwner: true, canEdit: true,
    createdAt: new Date(0).toISOString(), updatedAt: new Date(0).toISOString(),
    completedAt: null, voidedAt: null, rowVersion: "0x0000000000000001", revisionCount: 0,
    state: { dimensions: { grade: { selectedValueCode: "2" }, date: { dateValue: "2026-09-20" } }, responses: {} },
  });
  // One walk, held in memory. reset() puts it back exactly as it was, so a test never inherits the
  // state another test committed.
  const state = { walk: structuredClone(INITIAL_WALK), plan: [], log: [], version: 1 };

  const server = http.createServer(async (req, res) => {
    const url = new URL(req.url, "http://127.0.0.1");
    const body = await readBody(req);
    // The body is logged with the request: a retry has to be provably the *same* request, which is
    // a claim about its clientMutationId and its payload, not about how many requests there were.
    state.log.push({ method: req.method, path: url.pathname, at: state.log.length, body });

    if (url.pathname === "/" || url.pathname === "/index.cfm") return sendShell(res);
    if (url.pathname.startsWith("/assets/")) return sendAsset(res, url.pathname);
    if (url.pathname === "/api/me") {
      return json(res, 200, {
        user: { userId: "USER-1", displayName: "Harness Walker" },
        csrfToken: "harness-csrf",
        permissions: { "walk.create": ["ORG-1"], "walk.read": ["ORG-1"], "walk.edit_owned": ["ORG-1"] },
        orgUnits: { "ORG-1": { code: "harness-school", name: "Harness School", type: "SCHOOL" } },
      });
    }
    if (url.pathname === "/api/instrument/current") {
      return json(res, 200, { version: { versionId: VERSION_ID, versionLabel: "Harness v1", isFallbackDraft: false }, policies: { hiddenDimensionPolicy: "RETAIN" }, model: MODEL });
    }
    if (url.pathname === "/api/walks" && req.method === "GET") return json(res, 200, { walks: [state.walk] });
    if (url.pathname === `/api/walks/${WALK_ID}` && req.method === "GET") return json(res, 200, { walk: state.walk });
    if (url.pathname === `/api/walks/${WALK_ID}` && req.method === "PUT") return save(res, body, state);
    if (url.pathname === `/api/walks/${WALK_ID}/summary` && req.method === "GET") {
      const { text, name } = serverSummary(state.walk.state);
      res.writeHead(200, {
        "Content-Type": "text/plain; charset=utf-8",
        "Content-Disposition": `attachment; filename="${name}"`,
        "Cache-Control": "no-store",
        "X-Content-Type-Options": "nosniff",
      });
      return res.end(text);
    }
    return json(res, 404, { error: { code: "NOT_FOUND", message: "no such route" } });
  });

  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const origin = `http://127.0.0.1:${server.address().port}`;

  return {
    origin,
    walkId: WALK_ID,
    /**
     * Queue one answer for the next save:
     *
     *   { delayMs }        holds the answer open that long before committing normally
     *   { status, code }   refuses it with that HTTP status
     *   { raw }            answers 200 with that exact body, valid JSON or not
     *   { body }           answers 200 with that object serialized, so a well-formed but unusable
     *                      response (no walk, a walk that is not a walk) can be produced
     *   { bodyFails }      answers 200 with headers the browser accepts and a body it cannot read
     *
     * { sticky: true } makes that answer the standing behavior for every save after it, so a test
     * can hold the server in one condition instead of scripting a request count.
     */
    planSave(entry) { state.plan.push(entry); },
    /** Drops whatever is queued, so the next save is served normally. Leaves the walk and the log. */
    clearPlan() { state.plan.length = 0; },
    serverState: () => structuredClone(state.walk.state),
    serverWalk: () => structuredClone(state.walk),
    requests: () => state.log.slice(),
    /** Requests of one shape, in arrival order, as indices into the request log. */
    indicesOf: (method, suffix) => state.log.filter((r) => r.method === method && r.path.endsWith(suffix)).map((r) => r.at),
    /** The body of every save the browser sent, in arrival order. */
    saves: () => state.log.filter((r) => r.method === "PUT" && r.path === `/api/walks/${WALK_ID}`).map((r) => structuredClone(r.body)),
    reset() {
      state.log.length = 0;
      state.plan.length = 0;
      state.walk = structuredClone(INITIAL_WALK);
      state.version = 1;
    },
    async stop() { await new Promise((resolve) => server.close(resolve)); },
  };

  async function save(res, body, s) {
    // A sticky entry stays at the head of the queue: "every save from here on is refused this way",
    // which is what a server that is actually refusing the state looks like. A plain entry answers
    // one request and the next save is served normally again.
    const entry = (s.plan[0] && s.plan[0].sticky ? s.plan[0] : s.plan.shift()) || {};
    if (entry.delayMs) await new Promise((resolve) => setTimeout(resolve, entry.delayMs));
    if (entry.status) {
      return json(res, entry.status, { error: { code: entry.code || "TEST_REFUSED", message: entry.message || "refused by the harness", details: entry.details || null } });
    }
    // A 200 whose headers arrive intact and whose body cannot be read: the response declares gzip
    // and the bytes are not gzip, so the browser accepts the response and then fails decoding it.
    // fetch() resolves, response.text() rejects. That is the "body failed after the headers" case,
    // and it is produced by malformed content rather than by timing, so it is deterministic.
    //
    // Destroying the socket mid-body is NOT this case: Chromium fails the whole request and
    // fetch() itself rejects, which means no response reached the page at all -- a real transport
    // failure, correctly classified as one. Verified in this environment before choosing this
    // mechanism.
    if (entry.bodyFails) {
      res.writeHead(200, { "Content-Type": "application/json; charset=utf-8", "Content-Encoding": "gzip" });
      return res.end("this is declared as gzip and is not gzip");
    }
    // HTTP 200 with a body of the test's choosing. `raw` is sent verbatim, so it can be malformed
    // JSON; `body` is serialized, so it can be well-formed JSON that is not a walk response.
    if (entry.raw !== undefined || entry.body !== undefined) {
      res.writeHead(200, { "Content-Type": "application/json; charset=utf-8" });
      return res.end(entry.raw !== undefined ? entry.raw : JSON.stringify(entry.body));
    }
    if (body.rowVersion !== s.walk.rowVersion) {
      return json(res, 409, { error: { code: "STALE_ROW_VERSION", message: "changed elsewhere", details: { walkId: WALK_ID, serverRowVersion: s.walk.rowVersion } } });
    }
    s.version += 1;
    s.walk.rowVersion = `0x${String(s.version).padStart(16, "0")}`;
    s.walk.updatedAt = new Date(s.version * 1000).toISOString();
    s.walk.state = { dimensions: body.dimensions || {}, responses: body.responses || {} };
    return json(res, 200, { walk: s.walk });
  }

  function sendShell(res) {
    const html = fs.readFileSync(path.join(root, "src", "views", "shell.html"), "utf8")
      .replaceAll("{{assetBase}}", "/assets")
      .replaceAll("{{apiBase}}", "/api")
      .replaceAll("{{environment}}", "test");
    res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
    res.end(html);
  }

  function sendAsset(res, pathname) {
    const file = path.join(root, "app", pathname.replace(/^\/+/, ""));
    if (!file.startsWith(path.join(root, "app", "assets")) || !fs.existsSync(file)) {
      res.writeHead(404); return res.end("not found");
    }
    res.writeHead(200, { "Content-Type": ASSET_TYPES[path.extname(file)] || "application/octet-stream" });
    res.end(fs.readFileSync(file));
  }
}

function json(res, status, payload) {
  const text = JSON.stringify(payload);
  res.writeHead(status, { "Content-Type": "application/json; charset=utf-8" });
  res.end(text);
}

async function readBody(req) {
  if (req.method === "GET" || req.method === "HEAD") return {};
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  const text = Buffer.concat(chunks).toString("utf8");
  try { return text ? JSON.parse(text) : {}; } catch { return {}; }
}
