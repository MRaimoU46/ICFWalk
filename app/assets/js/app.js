/**
 * ICFWalk browser application: My Walks list and the walk editor. Loads the signed-in user
 * (/api/me) and the current instrument render model (/api/instrument/current), then renders
 * everything from that model. Walk persistence goes through the WalkStore boundary
 * (walk-store.js): Phase 4 uses ApiWalkStore (server persistence) with a 700 ms debounced
 * autosave, client mutation ids for idempotent retries, row_version concurrency with a
 * conflict-resolution panel, explicit completion with field-level errors, and void instead of
 * delete. Historical walks render against their own pinned instrument version.
 */
import { createApi, ApiError } from "./api.js";
import { ApiWalkStore, newId } from "./walk-store.js";
import { renderEditor } from "./renderer.js";
import { createBlankState, dimensionDisplay } from "./walk-state.js";

// Presentation configuration for the My Walks card (dimension codes, not instrument content):
// title = grade · content; meta = school · date · relative update time (prototype behavior).
const LIST_CARD = { title: ["grade", "content"], meta: ["school", "date"] };
const AUTOSAVE_DELAY_MS = 700;
const STATUS = {
  saved: "All changes saved",
  unsaved: "Unsaved changes",
  saving: "Saving...",
  failed: "Could not save — changes kept on screen only",
  network: "Could not reach the server — your changes are kept on this page. Retry when you are back online.",
  ambiguous: "The last save did not finish — your changes are kept on this page. Retry to finish it.",
  conflict: "This walk was changed elsewhere — resolve the conflict below to continue saving.",
  readOnly: "Read only",
};
const UNSAVED_LEAVE = "Your changes are still on this page and have not reached the server. Keep editing to try again, or discard them and leave.";
const UNSAVED_CONFLICT = "Resolve the conflict above before leaving, or discard your unsent edits.";
const UNSAVED_LIFECYCLE = "An action on this walk did not finish and may or may not have been applied. Retry it, or abandon it and leave.";
const EMPTY_STATE_LINES = ["No walks saved yet.", 'Start one with "New walk" above.'];
const DELETE_CONFIRM = "Delete this walk? This cannot be undone.";
const VOID_CONFIRM = "Void this completed walk? It stays in the audit history but leaves your list. A reason is required.";

const body = document.body;
const api = createApi(body.dataset.apiBase);
const store = new ApiWalkStore(api);
const $ = (id) => document.getElementById(id);

const app = {
  me: null, instrument: null, model: null, policies: null,
  models: {},                // versionId -> { model, policies, version }
  current: null, editor: null, dirty: false,
  baseline: null,            // state as last loaded from / committed to the server (for conflict review)
  timer: null, inFlight: null, queued: false,
  failed: false,             // a definitive failure; the edits are held on this page only
  conflict: null, completionErrors: [],
  // Every mutation whose outcome is not yet definitive owns one immutable operation record here,
  // keyed "ACTION:target" so a CREATE, SAVE, COMPLETE, or VOID is scoped to the org unit or the walk
  // it acts on and never shared between two of them. See beginOp.
  ops: {},
};

// ---- pending mutation operations ---------------------------------------------------------------

/**
 * A CREATE, SAVE, COMPLETE, or VOID can end ambiguously: a transport failure or an HTTP 5xx leaves
 * the browser unable to tell whether the server committed. The only safe retry is the *same*
 * semantic request under the *same* clientMutationId, because that is what the server recognises as
 * a replay -- a rebuilt request is a different request and is refused (409 MUTATION_ID_REUSED).
 *
 * So each pending operation owns an immutable record: its action, its target (the org unit for a
 * create, the walk for everything else), its clientMutationId, the frozen semantic request body,
 * the rowVersion it was issued against where one applies, and its status. The record is created once
 * and never rebuilt from later UI state; it lives until the operation reaches a definitive outcome
 * (a success, or a non-retryable 4xx) or the user explicitly discards it. While it lives it is
 * unsaved work, so the navigation guard and beforeunload both see it.
 *
 *   { key, action, target, mutationId, body (frozen), rowVersion, status }
 *
 * The status distinguishes a record nothing has been sent for from one whose request is already on
 * the wire:
 *
 *   UNSENT     minted, no request carrying this mutation id has left the browser. Nothing on the
 *              server can correspond to it, so a newer payload may replace it outright.
 *   IN_FLIGHT  its request has been sent and no answer has come back. The server may already have
 *              committed it, so from here on the record is the only thing that can resolve it and
 *              nothing but a definitive outcome or an explicit discard may drop it.
 *   AMBIGUOUS  its answer was lost (transport failure) or was an HTTP 5xx. Same rule, plus it is
 *              surfaced for retry.
 *
 * Collapsing the first two was the defect this distinction fixes: an editor change during an
 * in-flight save deleted the record whose request was already on the wire, so when that request's
 * answer was lost there was nothing left to retry, the committed save was never confirmed, and the
 * queued newer state went out under a brand-new id against a row version the server had already
 * moved past.
 */
const OP_UNSENT = "UNSENT";
const OP_IN_FLIGHT = "IN_FLIGHT";
const OP_AMBIGUOUS = "AMBIGUOUS";

function deepFreeze(value) {
  if (value && typeof value === "object" && !Object.isFrozen(value)) {
    Object.freeze(value);
    for (const key of Object.keys(value)) deepFreeze(value[key]);
  }
  return value;
}

function opKey(action, target) {
  return `${action}:${target}`;
}

/** The live record for (action, target), or null. */
function currentOp(action, target) {
  return app.ops[opKey(action, target)] || null;
}

/**
 * Returns the existing record for (action, target) untouched when one is already pending, so a
 * retry reuses its id and its body; otherwise mints one from body/rowVersion and freezes it.
 */
function beginOp(action, target, { body = {}, rowVersion = null } = {}) {
  const existing = currentOp(action, target);
  if (existing) return existing;
  const record = {
    key: opKey(action, target),
    action,
    target,
    mutationId: newId(),
    body: deepFreeze(structuredClone(body)),
    rowVersion,
    status: OP_UNSENT,
  };
  app.ops[record.key] = record;
  return record;
}

/**
 * Called immediately before the request carrying this record's mutation id is dispatched. From this
 * moment the server may hold the mutation, so the record stops being replaceable local intent and
 * becomes the only thing that can resolve it.
 */
function markOpSent(op) {
  if (op && app.ops[op.key] === op && op.status === OP_UNSENT) op.status = OP_IN_FLIGHT;
}

function markOpAmbiguous(op) {
  if (op && app.ops[op.key] === op) op.status = OP_AMBIGUOUS;
  renderPendingOps();
}

/** A definitive outcome (success or non-retryable 4xx): the operation id is spent. */
function settleOp(op) {
  if (op && app.ops[op.key] === op) delete app.ops[op.key];
  renderPendingOps();
}

/**
 * Drops a record nothing has been sent for, so a newer payload can take its place. A record whose
 * request has already left the browser is never dropped this way -- in flight or answered
 * ambiguously, the server may hold it, so only a definitive outcome or an explicit discard clears
 * it. This is what keeps an edit made during an in-flight save from deleting the operation that
 * save has to retry.
 */
function discardPendingOp(action, target) {
  const op = currentOp(action, target);
  if (op && op.status === OP_UNSENT) delete app.ops[op.key];
}

/** Every pending record for one target (used when the user explicitly discards). */
function settleOpsFor(target) {
  for (const op of Object.values(app.ops)) if (op.target === target) delete app.ops[op.key];
  renderPendingOps();
}

function pendingOps() {
  return Object.values(app.ops);
}

function ambiguousOps() {
  return pendingOps().filter((op) => op.status === OP_AMBIGUOUS);
}

/** The current walk's save record while its outcome is unknown, or null. */
function ambiguousSave() {
  if (!app.current) return null;
  const op = currentOp("SAVE", app.current.id);
  return op && op.status === OP_AMBIGUOUS ? op : null;
}

/**
 * The one pending/unsaved state the editor, the navigation guard, and beforeunload all read.
 * Any true field means work exists that the server has not definitively accepted.
 */
function pendingState() {
  return {
    dirty: app.dirty,
    queued: app.timer !== null,
    inFlight: Boolean(app.inFlight),
    ambiguous: Boolean(ambiguousSave()),
    failed: app.failed,
    conflict: Boolean(app.conflict),
    // Operations still pending on the walk that is open: a completion or a void whose outcome is
    // unknown is unsaved work for this editor even though no local edit is waiting.
    operations: app.current ? pendingOps().filter((op) => op.target === app.current.id).length : 0,
  };
}

function hasUnsavedWork() {
  const p = pendingState();
  return p.dirty || p.queued || p.inFlight || p.ambiguous || p.failed || p.conflict || p.operations > 0;
}

/**
 * Unload protection. Editor state counts only while an editable walk is open, but a pending
 * lifecycle operation counts anywhere: a create, completion, or void whose outcome is unknown must
 * not be abandoned by a reload or a closed tab without the browser asking first.
 */
function hasUnfinishedWork() {
  if (app.current && app.current.canEdit && hasUnsavedWork()) return true;
  return pendingOps().length > 0;
}

// ---- resolving an ambiguous operation ----------------------------------------------------------

/**
 * An ambiguous operation has to stay resolvable wherever the user ends up, and the control that
 * started it is not that place. A void is started from a confirmation row the next list render
 * destroys; a completion is started from a button the editor hides as soon as the walk is reloaded
 * and turns out to have been completed after all; a create is started from the list the user may
 * have left. Each of those leaves a record that still blocks unload with nothing left to click.
 *
 * So the records themselves are the source of truth for what is offered: this bar is rebuilt from
 * the registry on every change, lives outside both views, and gives every unresolved operation a
 * retry that re-sends its exact frozen request and a discard that is the user's explicit decision.
 */
function opDescription(op) {
  if (op.action === "CREATE") return "Starting a new walk did not finish. It may already have been created.";
  if (op.action === "COMPLETE") return "Completing a walk did not finish. It may already be complete.";
  if (op.action === "VOID") return "Removing a walk did not finish. It may already have been removed.";
  return "A save did not finish. Your changes are still on this page.";
}

function renderPendingOps() {
  const box = $("pending-ops");
  if (!box) return;
  const list = $("pending-ops-list");
  const ops = ambiguousOps();
  list.innerHTML = "";
  if (!ops.length) { box.hidden = true; return; }
  $("pending-ops-summary").textContent = ops.length === 1
    ? "One action did not finish."
    : `${ops.length} actions did not finish.`;
  for (const op of ops) {
    const li = document.createElement("li");
    li.className = "pending-op";
    li.dataset.opAction = op.action;
    li.dataset.opTarget = op.target;
    const text = document.createElement("span");
    text.className = "pending-op-text";
    text.textContent = `${opDescription(op)} Retrying sends the same request, so it cannot happen twice.`;
    const retry = document.createElement("button");
    retry.type = "button"; retry.className = "btn btn-sm btn-primary pending-op-retry";
    retry.textContent = "Retry";
    retry.addEventListener("click", () => resolveAmbiguousOp(op));
    const drop = document.createElement("button");
    drop.type = "button"; drop.className = "btn btn-sm pending-op-discard";
    drop.textContent = "Stop trying";
    drop.addEventListener("click", () => {
      // An explicit decision, like the unsaved-changes panel: the browser stops tracking the
      // operation and whatever the server holds stands.
      settleOp(op);
      announce("Stopped retrying the unfinished action");
      renderList().catch(() => {});
    });
    li.append(text, retry, drop);
    list.appendChild(li);
  }
  box.hidden = false;
}

/**
 * Re-sends one record exactly as it was issued -- same mutation id, same row version, same frozen
 * semantic body -- so the server replays what it already committed or commits it now. Never
 * rebuilds the request from current UI state: a rebuilt request is a different request and is
 * refused (409 MUTATION_ID_REUSED).
 */
async function resolveAmbiguousOp(op) {
  if (app.ops[op.key] !== op) { renderPendingOps(); return; }
  if (op.action === "SAVE") {
    // A save belongs to its editor, which holds the local state it is still carrying.
    if (!app.current || app.current.id !== op.target) await openWalk(op.target);
    if (app.current && app.current.id === op.target) await saveCurrent();
    renderPendingOps();
    return;
  }
  // The record stays AMBIGUOUS while the retry is out: it is still the only thing that can resolve
  // the operation, and it keeps its place in the bar until the answer is definitive.
  try {
    if (op.action === "CREATE") {
      const walk = await store.create({ ...op.body, clientMutationId: op.mutationId });
      settleOp(op);
      showMessage("");
      await openWalk(walk.id, walk);
      return;
    }
    if (op.action === "COMPLETE") {
      await store.complete({ id: op.target, rowVersion: op.rowVersion }, op.mutationId);
      settleOp(op);
      announce("Walk completed");
      await refreshAfterResolvedOp(op.target, false);
      return;
    }
    await store.remove(op.target, { reason: op.body.reason, rowVersion: op.rowVersion, clientMutationId: op.mutationId });
    settleOp(op);
    announce("Walk removed");
    await refreshAfterResolvedOp(op.target, true);
  } catch (e) {
    if (isAmbiguousFailure(e)) {
      markOpAmbiguous(op);
      showMessage(e instanceof ApiError
        ? `That still did not finish (${e.code}). Try again; it cannot happen twice.`
        : "The server could not be reached. Try again; it cannot happen twice.", "error");
      return;
    }
    settleOp(op);
    if (e instanceof ApiError && e.code === "MUTATION_REPLAY_SUPERSEDED") {
      // It did commit, and the walk has changed since: the server record is the truth.
      const walkId = op.action === "CREATE" && e.details && e.details.walkId ? e.details.walkId : op.target;
      showMessage("");
      if (op.action === "VOID") await refreshAfterResolvedOp(op.target, true);
      else await openWalk(walkId);
      return;
    }
    showMessage(`That action could not be finished (${e instanceof ApiError ? e.code : "network error"}): ${e.message}`, "error");
    await refreshAfterResolvedOp(op.target, false);
  } finally {
    renderPendingOps();
  }
}

/** Puts the views back in step with the server after an operation finally resolved. */
async function refreshAfterResolvedOp(walkId, leaveEditorView) {
  const open = app.current && app.current.id === walkId;
  if (open && leaveEditorView) {
    app.current = null;
    app.editor = null;
    await renderList();
    showView("list");
    return;
  }
  if (open) { await openWalk(walkId); return; }
  await renderList();
}

function announce(text) {
  const a = $("announcer");
  a.textContent = "";
  setTimeout(() => { a.textContent = text; }, 30);
}

function showMessage(text, kind = "info") {
  const m = $("app-message");
  m.textContent = text;
  m.className = `app-message${kind === "error" ? " error" : ""}`;
  m.hidden = !text;
}

function setSaveStatus(text, { retry = false } = {}) {
  $("save-status").textContent = text;
  $("save-status-bottom").textContent = text;
  $("save-retry").hidden = !retry;
}

function relTime(ts) {
  if (!ts) return "";
  const diff = Date.now() - ts, m = Math.floor(diff / 60000), h = Math.floor(diff / 3600000), d = Math.floor(diff / 86400000);
  if (m < 1) return "just now";
  if (m < 60) return `${m}m ago`;
  if (h < 24) return `${h}h ago`;
  if (d < 7) return `${d}d ago`;
  return new Date(ts).toLocaleDateString();
}

function modelFor(walk) {
  return app.models[walk.versionId] ? app.models[walk.versionId].model : app.model;
}

function summarize(walk) {
  const model = modelFor(walk);
  const display = (code) => dimensionDisplay(model, walk.state, code);
  const title = LIST_CARD.title.map(display).filter(Boolean).join(" · ") || "Untitled walk";
  const meta = LIST_CARD.meta.map(display).filter(Boolean);
  return { title, meta };
}

// ---- views -------------------------------------------------------------------------------------

function showView(name) {
  $("view-list").hidden = name !== "list";
  $("view-walk").hidden = name !== "walk";
  $("nav-list-btn").hidden = name !== "walk";
  // The unfinished-operations bar belongs to neither view, so it is re-asserted on every switch.
  renderPendingOps();
  if (name === "list") $("list-heading").focus?.();
}

async function renderList() {
  const list = $("walk-list");
  list.innerHTML = "";
  let walks;
  try {
    walks = await store.list();
  } catch (e) {
    showMessage(e instanceof ApiError ? `Could not load your walks (${e.code}).` : "Could not load your walks: the server could not be reached.", "error");
    return;
  }
  showMessage("");
  if (!walks.length) {
    const empty = document.createElement("div");
    empty.className = "empty-state";
    empty.append(EMPTY_STATE_LINES[0], document.createElement("br"), EMPTY_STATE_LINES[1]);
    list.appendChild(empty);
    return;
  }
  for (const w of walks) {
    const s = summarize(w);
    const card = document.createElement("article");
    card.className = "walk-card";
    card.dataset.walkId = w.id;
    card.dataset.status = w.status;
    const info = document.createElement("div");
    info.className = "info";
    const title = document.createElement("p");
    title.className = "title";
    title.textContent = s.title;
    if (w.status === "COMPLETED") {
      const badge = document.createElement("span");
      badge.className = "status-badge";
      badge.textContent = "Completed";
      title.append(" ", badge);
    }
    const meta = document.createElement("p");
    meta.className = "meta";
    meta.textContent = [...s.meta, relTime(w.updatedAt)].filter(Boolean).join(" · ");
    info.append(title, meta);
    const open = document.createElement("button");
    open.type = "button"; open.className = "btn btn-sm open-btn"; open.textContent = "Open";
    open.setAttribute("aria-label", `Open ${s.title}`);
    open.addEventListener("click", () => openWalk(w.id));   // the list is only reachable through leaveEditor
    card.append(info, open);
    if (w.canEdit) {
      const del = document.createElement("button");
      del.type = "button"; del.className = "btn btn-sm btn-danger delete-btn"; del.textContent = "Delete";
      del.setAttribute("aria-label", `Delete ${s.title}`);
      del.addEventListener("click", () => confirmDelete(card, w, s.title));
      card.append(del);
    }
    list.appendChild(card);
  }
}

function confirmDelete(card, walk, title) {
  if (card.nextElementSibling && card.nextElementSibling.classList.contains("confirm-row")) return;
  const completed = walk.status === "COMPLETED";
  const row = document.createElement("div");
  row.className = "confirm-row";
  row.setAttribute("role", "alertdialog");
  row.setAttribute("aria-label", `${completed ? "Void" : "Delete"} ${title}`);
  const p = document.createElement("p");
  p.textContent = completed ? VOID_CONFIRM : DELETE_CONFIRM;
  row.append(p);
  let reason = null;
  if (completed) {
    const label = document.createElement("label");
    label.className = "sr-only";
    label.setAttribute("for", `void-reason-${walk.id}`);
    label.textContent = "Reason for voiding";
    reason = document.createElement("input");
    reason.type = "text"; reason.id = `void-reason-${walk.id}`; reason.className = "void-reason"; reason.placeholder = "Reason"; reason.required = true; reason.maxLength = 1000;
    row.append(label, reason);
  }
  const err = document.createElement("span");
  err.className = "field-error"; err.hidden = true; err.setAttribute("role", "alert");
  const yes = document.createElement("button");
  yes.type = "button"; yes.className = "btn btn-sm btn-danger confirm-delete"; yes.textContent = completed ? "Void" : "Delete";
  yes.addEventListener("click", async () => {
    // A void whose outcome is unknown owns its request: the reason and the row version come from its
    // record, never from the inputs as they stand now, so a retry is the same semantic request even
    // if the field was edited or the list was refreshed in between.
    const pending = currentOp("VOID", walk.id);
    if (!pending && completed && !reason.value.trim()) { err.textContent = "Enter a reason to void this walk."; err.hidden = false; reason.focus(); return; }
    yes.disabled = true;
    const op = beginOp("VOID", walk.id, {
      body: { reason: completed ? reason.value.trim() : "" },
      rowVersion: walk.rowVersion,
    });
    if (reason) reason.readOnly = true;   // the record owns the reason from here on
    try {
      markOpSent(op);
      await store.remove(walk.id, { reason: op.body.reason, rowVersion: op.rowVersion, clientMutationId: op.mutationId });
      settleOp(op);
      announce(completed ? "Walk voided" : "Walk deleted");
      await renderList();
    } catch (e) {
      yes.disabled = false;
      if (isAmbiguousFailure(e)) {
        markOpAmbiguous(op);
        err.textContent = e instanceof ApiError
          ? `That did not finish (${e.code}). Try again; it will not void the walk twice.`
          : "The server could not be reached. Try again; it will not void the walk twice.";
        err.hidden = false;
        return;
      }
      settleOp(op);
      if (reason) reason.readOnly = false;
      if (e instanceof ApiError && e.code === "MUTATION_REPLAY_SUPERSEDED") {
        // The void did commit; the walk has changed since, so the list is the truth.
        announce("Walk voided");
        await renderList();
        return;
      }
      err.textContent = e instanceof ApiError ? e.message : "The server could not be reached. Try again.";
      err.hidden = false;
    }
  });
  const no = document.createElement("button");
  no.type = "button"; no.className = "btn btn-sm cancel-delete"; no.textContent = "Cancel";
  no.addEventListener("click", () => { row.remove(); card.querySelector(".delete-btn").focus(); });
  row.append(yes, no, err);
  card.after(row);
  (reason || no).focus();
}

function creatableUnits() {
  const ids = app.me.permissions["walk.create"] || [];
  return ids.map((id) => ({ id, ...(app.me.orgUnits[id] || { code: "", name: id, type: "" }) }))
    .sort((a, b) => (a.type === b.type ? a.name.localeCompare(b.name) : a.type === "SCHOOL" ? -1 : 1));
}

async function startNewWalk(unit) {
  // The create operation owns its id and its exact body until the outcome is definitive: an
  // ambiguous answer may already have created the walk, and retrying the same record replays it
  // instead of creating a second one. A definitive 4xx spends the record.
  const op = beginOp("CREATE", unit.id, {
    // The blank state as the engine defines it. Dimensions the server owns (the School value for a
    // SCHOOL unit) are assigned by the server and come back on the create response.
    body: { orgUnitId: unit.id, versionId: app.instrument.version.versionId, state: createBlankState(app.model) },
  });
  $("new-walk-btn").disabled = true;
  try {
    markOpSent(op);
    const walk = await store.create({ ...op.body, clientMutationId: op.mutationId });
    settleOp(op);
    await openWalk(walk.id, walk);
  } catch (e) {
    if (isAmbiguousFailure(e)) {
      markOpAmbiguous(op);
      showMessage(e instanceof ApiError
        ? `Starting the walk did not finish (${e.code}). Try again; it will not create a second walk.`
        : "Could not start a walk: the server could not be reached. Try again; it will not create a second walk.", "error");
    } else {
      settleOp(op);
      if (e instanceof ApiError && e.code === "MUTATION_REPLAY_SUPERSEDED" && e.details && e.details.walkId) {
        // The walk was created; it has changed since, so open what the server holds now.
        await openWalk(e.details.walkId);
      } else {
        showMessage(`Could not start a walk (${e.code}): ${e.message}`, "error");
      }
    }
  } finally {
    $("new-walk-btn").disabled = !creatableUnits().length;
  }
}

function onNewWalk() {
  const units = creatableUnits();
  if (!units.length) { showMessage("You do not have permission to create walks in any school.", "error"); return; }
  if (units.length === 1) { startNewWalk(units[0]); return; }
  const chooser = $("new-walk-chooser");
  const select = $("chooser-unit");
  select.innerHTML = "";
  for (const u of units) {
    const o = document.createElement("option");
    o.value = u.id; o.textContent = u.name;
    select.appendChild(o);
  }
  chooser.hidden = false;
  select.focus();
}

async function ensureModel(walk) {
  if (walk.versionId === app.instrument.version.versionId || app.models[walk.versionId]) return;
  const res = await store.instrument(walk.id);
  app.models[walk.versionId] = { model: res.model, policies: res.policies, version: res.version };
}

async function openWalk(id, preloaded = null) {
  let walk = preloaded;
  if (!walk) {
    try { walk = await store.open(id); } catch (e) { walk = null; }
  }
  if (!walk) { showMessage("Could not load that walk.", "error"); return; }
  try { await ensureModel(walk); } catch (e) { showMessage("Could not load the instrument version for that walk.", "error"); return; }
  cancelScheduledSave();
  app.current = walk;
  app.baseline = structuredClone(walk.state);
  app.dirty = false;
  // This walk's own save record is settled when nothing was ever sent for it: the aggregate just
  // came from the server, so an unsent local intent has nothing left to say. A record whose request
  // did go out is kept -- reloading the walk cannot tell whether the server committed it, and
  // dropping it here would be the same mistake as dropping it on an editor change. Records for
  // other walks and other actions are theirs to resolve.
  const openingSave = currentOp("SAVE", walk.id);
  if (openingSave && openingSave.status === OP_UNSENT) settleOp(openingSave);
  app.failed = false;
  app.conflict = null;
  app.completionErrors = [];
  hideConflict();
  hideUnsavedPanel();
  renderCompletionErrors([]);
  const entry = app.models[walk.versionId];
  const model = entry ? entry.model : app.model;
  const policies = entry ? entry.policies : app.policies;
  $("editor").innerHTML = "";
  app.editor = renderEditor($("editor"), {
    model, walk, policies, announce,
    onChange: (state) => onEditorChange(state),
  });
  applyEditability(walk);
  renderWalkBanner(walk);
  const note = $("version-note");
  const label = walk.versionLabel || app.instrument.version.versionLabel;
  const isFallback = !entry && app.instrument.version.isFallbackDraft;
  note.textContent = isFallback ? `Instrument version: ${label} (DRAFT preview; no version is published yet).` : `Instrument version: ${label}.`;
  note.hidden = false;
  setSaveStatus(walk.canEdit ? STATUS.saved : STATUS.readOnly);
  showView("walk");
  window.scrollTo(0, 0);
  $("back-btn").focus();
}

function applyEditability(walk) {
  const editable = walk.canEdit;
  // A server-owned dimension stays read-only however editable the walk is: the server derives its
  // value and refuses a client's, so offering the control would offer a choice that cannot be made.
  for (const el of $("editor").querySelectorAll("select, input, textarea, .pill")) {
    el.disabled = !editable || Boolean(el.closest('[data-locked="true"]'));
  }
  $("save-btn").hidden = !editable;
  $("save-btn-bottom").hidden = !editable;
  $("complete-btn").hidden = !editable || walk.status !== "DRAFT";
}

function renderWalkBanner(walk) {
  const banner = $("walk-banner");
  if (walk.status === "COMPLETED") {
    banner.textContent = `Completed on ${new Date(walk.completedAt).toLocaleString()}.${walk.canEdit ? " Further edits are saved as revisions." : ""}`;
    banner.hidden = false;
  } else if (walk.status === "VOIDED") {
    banner.textContent = "This walk has been voided and is read only.";
    banner.hidden = false;
  } else if (!walk.canEdit) {
    banner.textContent = `Read only: this walk belongs to ${walk.ownerDisplayName || "another user"}.`;
    banner.hidden = false;
  } else {
    banner.textContent = "";
    banner.hidden = true;
  }
}

// ---- autosave ----------------------------------------------------------------------------------

function onEditorChange(state) {
  if (!app.current || !app.current.canEdit) return;
  app.current.state = state;
  app.dirty = true;
  app.failed = false;
  // A new payload gets a new operation record. An attempt whose outcome is still unknown keeps its
  // own record -- its id and its frozen body -- so editing on never abandons it and never rewrites
  // the request it has to retry.
  discardPendingOp("SAVE", app.current.id);
  hideUnsavedPanel();
  if (app.completionErrors.length) refreshCompletionErrors();
  if (app.conflict) return;     // hold saves until the conflict is resolved (edits are kept locally)
  setSaveStatus(STATUS.unsaved);
  scheduleSave();
}

function scheduleSave() {
  cancelScheduledSave();
  app.timer = setTimeout(() => { app.timer = null; saveCurrent(); }, AUTOSAVE_DELAY_MS);
}

function cancelScheduledSave() {
  if (app.timer !== null) clearTimeout(app.timer);
  app.timer = null;
}

/**
 * Saves the current working state; coalesces concurrent calls and re-runs when edits arrived
 * mid-flight. An attempt whose outcome is unknown (transport failure or HTTP 5xx) is resolved
 * first, with its original clientMutationId and its original payload, so the server either replays
 * what it already committed or commits it now; only then does a newer payload go out under a new
 * id. Nothing local is dropped on any path.
 */
function saveCurrent() {
  if (!app.current || !app.current.canEdit || app.conflict) return Promise.resolve();
  cancelScheduledSave();
  if (app.inFlight) { app.queued = true; return app.inFlight; }
  const walk = app.current;
  const resend = ambiguousSave();
  if (!resend && !app.dirty) { app.failed = false; setSaveStatus(STATUS.saved); return Promise.resolve(); }
  // A resend reuses its record untouched. Otherwise the record for this payload is reused if one is
  // still open (the payload has not changed since it was minted) or minted now from the working
  // state and the row version it is issued against.
  const op = resend || beginOp("SAVE", walk.id, { body: { state: structuredClone(walk.state) }, rowVersion: walk.rowVersion });
  const payload = { ...walk, rowVersion: op.rowVersion, state: op.body.state };
  if (!resend) app.dirty = false;
  setSaveStatus(STATUS.saving);
  markOpSent(op);
  app.inFlight = (async () => {
    try {
      const saved = await store.save(payload, op.mutationId);
      if (app.current !== walk) return;
      walk.rowVersion = saved.rowVersion;
      walk.updatedAt = saved.updatedAt;
      walk.status = saved.status;
      walk.revisionCount = saved.revisionCount;
      app.baseline = op.body.state;
      settleOp(op);
      app.failed = false;
      // A resend that carried exactly the current working state leaves nothing unsaved.
      if (resend && JSON.stringify(walk.state) === JSON.stringify(op.body.state)) app.dirty = false;
      setSaveStatus(app.dirty ? STATUS.unsaved : STATUS.saved);
    } catch (e) {
      if (app.current !== walk) return;
      if (!resend) app.dirty = true;
      if (isAmbiguousFailure(e)) {
        // The server may have committed before the answer was lost: the record keeps the same
        // mutation id and the same frozen body so the retry replays rather than duplicating or
        // dropping the change.
        markOpAmbiguous(op);
        setSaveStatus(e instanceof ApiError ? `${STATUS.ambiguous} (${e.code})` : STATUS.network, { retry: true });
        announce(e instanceof ApiError ? "Save did not finish" : "Save failed: the server could not be reached");
        return;
      }
      // Definitive outcomes below: the operation id is spent and a new payload gets a new record.
      settleOp(op);
      if (resend) app.dirty = true;
      if (e instanceof ApiError && e.status === 409 && (e.code === "STALE_ROW_VERSION" || e.code === "MUTATION_REPLAY_SUPERSEDED")) {
        // MUTATION_REPLAY_SUPERSEDED: this save did commit, but the walk has moved on since, so the
        // server refused to hand a stale editor a token for the newer state. That is a conflict like
        // any other: reload the saved version and reconcile.
        await beginConflict(e);
      } else if (e instanceof ApiError && e.code === "WALK_COMPLETION_INVALID") {
        app.failed = true;
        setSaveStatus("Not saved: a completed walk must keep every required response.", { retry: true });
        showCompletionErrors(e.details && e.details.errors ? e.details.errors : []);
      } else {
        app.failed = true;
        setSaveStatus(`${STATUS.failed} (${e instanceof ApiError ? `${e.code}: ${e.message}` : "unknown error"})`, { retry: true });
        announce("Save failed");
      }
    } finally {
      app.inFlight = null;
      const stillAmbiguous = Boolean(ambiguousSave());
      if (app.queued) { app.queued = false; if ((app.dirty || stillAmbiguous) && !app.conflict) scheduleSave(); }
      else if (!stillAmbiguous && app.dirty && !app.conflict && resend) scheduleSave();
    }
  })();
  return app.inFlight;
}

/**
 * A failure is ambiguous when the request may have been committed before the answer was lost:
 * a transport failure (offline, reset, timeout) or any HTTP 5xx. Everything else -- a validation
 * rejection, a conflict, an authorization refusal -- is definitive: nothing was committed.
 */
function isAmbiguousFailure(e) {
  if (e instanceof ApiError) return e.status >= 500;
  return true;
}

// ---- conflict resolution (SAVE-04 / SAVE-05) ---------------------------------------------------

async function beginConflict(error) {
  let server = null;
  try { server = await store.open(app.current.id); } catch { server = null; }
  app.conflict = { server, error };
  setSaveStatus(STATUS.conflict);
  announce("This walk was changed elsewhere. Review the conflict panel.");
  renderConflictPanel();
}

function valueText(model, kind, key, value) {
  if (!value) return "(empty)";
  if (kind === "dimension") {
    const dim = model.dimensions[key];
    if (value.selectedValueCode && dim) {
      const v = dim.values.find((x) => x.valueCode === value.selectedValueCode);
      const label = v ? v.label : value.selectedValueCode;
      return value.otherText ? `${label}: ${value.otherText}` : label;
    }
    return value.textValue || value.dateValue || "(empty)";
  }
  const item = findItem(model, key);
  if (value.storedCode && item && item.responseSet) {
    const o = item.responseSet.options.find((x) => x.storedCode === value.storedCode);
    return o ? o.label : value.storedCode;
  }
  return value.textValue || "(empty)";
}

function findItem(model, key) {
  const walk = (n) => { for (const it of n.items) if (it.itemKey === key) return it; for (const c of n.children) { const f = walk(c); if (f) return f; } return null; };
  return walk(model.root);
}

function findPlacement(model, code) {
  const walk = (n) => { for (const p of n.placements) if (p.dimensionCode === code) return p; for (const c of n.children) { const f = walk(c); if (f) return f; } return null; };
  return walk(model.root);
}

function diffStates(model, mine, theirs) {
  const out = [];
  const same = (a, b) => JSON.stringify(a || {}) === JSON.stringify(b || {});
  for (const code of new Set([...Object.keys(mine.dimensions), ...Object.keys(theirs.dimensions)])) {
    if (same(mine.dimensions[code], theirs.dimensions[code])) continue;
    const p = findPlacement(model, code);
    out.push({ kind: "dimension", key: code, label: p ? p.label : code, mine: valueText(model, "dimension", code, mine.dimensions[code]), theirs: valueText(model, "dimension", code, theirs.dimensions[code]) });
  }
  for (const key of new Set([...Object.keys(mine.responses), ...Object.keys(theirs.responses)])) {
    if (same(mine.responses[key], theirs.responses[key])) continue;
    const it = findItem(model, key);
    out.push({ kind: "response", key, label: it ? it.prompt : key, mine: valueText(model, "response", key, mine.responses[key]), theirs: valueText(model, "response", key, theirs.responses[key]) });
  }
  return out;
}

/** The fields this session changed since it last loaded or saved the walk (its unsent edits). */
function unsentEdits() {
  const model = modelFor(app.current);
  return diffStates(model, app.current.state, app.baseline || { dimensions: {}, responses: {} }).map((d) => d.key + ":" + d.kind);
}

function renderConflictPanel() {
  const panel = $("conflict-panel");
  const list = $("conflict-list");
  list.innerHTML = "";
  const { server } = app.conflict;
  const model = modelFor(app.current);
  const edited = new Set(unsentEdits());
  const diffs = server ? diffStates(model, app.current.state, server.state).filter((d) => edited.has(d.key + ":" + d.kind)) : [];
  $("conflict-summary").textContent = server
    ? (diffs.length ? `Your unsent edits (${diffs.length}) compared with the saved version:` : (edited.size ? "Your unsent edits already match the saved version; reload it to continue." : "You have no unsent edits; reload the saved version to continue."))
    : "The saved version could not be loaded. Retry when you are back online.";
  for (const d of diffs) {
    const li = document.createElement("li");
    const label = document.createElement("strong");
    label.textContent = d.label;
    const mine = document.createElement("span");
    mine.textContent = `Yours: ${d.mine}`;
    const theirs = document.createElement("span");
    theirs.textContent = `Saved: ${d.theirs}`;
    li.append(label, document.createElement("br"), mine, document.createElement("br"), theirs);
    list.appendChild(li);
  }
  $("conflict-keep").disabled = !server || !diffs.length;
  $("conflict-reload").disabled = !server;
  $("conflict-retry").hidden = Boolean(server);
  panel.hidden = false;
  $("conflict-reload").focus();
}

function hideConflict() {
  $("conflict-panel").hidden = true;
  $("conflict-list").innerHTML = "";
}

/** Discard local edits: re-render from the server record. */
async function resolveConflictReload() {
  const server = app.conflict && app.conflict.server;
  app.conflict = null;
  if (app.current) settleOp(currentOp("SAVE", app.current.id));
  app.failed = false;
  hideConflict();
  if (!server) return;
  await openWalk(server.id, server);
  announce("Reloaded the saved version");
}

/** Keep local edits: apply only the fields this session changed on top of the server record, then save with its row version. */
async function resolveConflictKeep() {
  const { server } = app.conflict;
  const local = app.current.state;
  const model = modelFor(app.current);
  const merged = structuredClone(server.state);
  const edited = new Set(unsentEdits());
  for (const d of diffStates(model, local, server.state)) {
    if (!edited.has(d.key + ":" + d.kind)) continue;
    if (d.kind === "dimension") { if (local.dimensions[d.key]) merged.dimensions[d.key] = local.dimensions[d.key]; else delete merged.dimensions[d.key]; }
    else { if (local.responses[d.key]) merged.responses[d.key] = local.responses[d.key]; else delete merged.responses[d.key]; }
  }
  app.conflict = null;
  if (app.current) settleOp(currentOp("SAVE", app.current.id));
  app.failed = false;
  hideConflict();
  await openWalk(server.id, { ...server, state: merged });
  app.dirty = true;
  discardPendingOp("SAVE", server.id);
  setSaveStatus(STATUS.unsaved);
  await saveCurrent();
  announce("Your edits were applied to the saved version");
}

// ---- completion --------------------------------------------------------------------------------

async function completeCurrent() {
  if (!app.current || !app.current.canEdit) return;
  if (app.dirty || app.inFlight || ambiguousSave()) await saveCurrent();
  if (app.inFlight) await app.inFlight;
  if (app.conflict || app.dirty || ambiguousSave()) return;
  const walk = app.current;
  // The completion operation owns its record until the outcome is definitive, so an ambiguous answer
  // retries the same request instead of starting a second one. The record is keyed to this walk, so
  // completing a different walk later never reuses this id against it.
  const op = beginOp("COMPLETE", walk.id, { rowVersion: walk.rowVersion });
  $("complete-btn").disabled = true;
  try {
    markOpSent(op);
    const done = await store.complete({ ...walk, rowVersion: op.rowVersion }, op.mutationId);
    settleOp(op);
    walk.status = done.status;
    walk.completedAt = done.completedAt;
    walk.rowVersion = done.rowVersion;
    walk.updatedAt = done.updatedAt;
    walk.revisionCount = done.revisionCount;
    renderCompletionErrors([]);
    renderWalkBanner(walk);
    applyEditability(walk);
    setSaveStatus(STATUS.saved);
    announce("Walk completed");
    $("walk-banner").focus?.();
  } catch (e) {
    if (e instanceof ApiError && e.code === "WALK_INCOMPLETE") {
      settleOp(op);
      showCompletionErrors(e.details && e.details.errors ? e.details.errors : []);
    } else if (e instanceof ApiError && e.status === 409 && e.code === "STALE_ROW_VERSION") {
      settleOp(op);
      app.dirty = true;
      await beginConflict(e);
    } else if (isAmbiguousFailure(e)) {
      // Keep the operation record: the completion may already have committed.
      markOpAmbiguous(op);
      showMessage(e instanceof ApiError ? `The completion did not finish (${e.code}). Try again; it will not complete the walk twice.` : "Could not complete the walk: the server could not be reached. Try again; it will not complete the walk twice.", "error");
    } else if (e instanceof ApiError && e.code === "MUTATION_REPLAY_SUPERSEDED") {
      // The completion did commit; the walk has changed since, so re-open what the server holds.
      settleOp(op);
      await openWalk(walk.id);
    } else {
      settleOp(op);
      showMessage(`Could not complete the walk (${e.code}): ${e.message}`, "error");
    }
  } finally {
    $("complete-btn").disabled = false;
  }
}

function showCompletionErrors(errors) {
  app.completionErrors = errors;
  renderCompletionErrors(errors);
  announce(`${errors.length} required ${errors.length === 1 ? "response is" : "responses are"} missing`);
  const first = $("completion-errors").querySelector("button");
  if (first) first.focus();
}

function refreshCompletionErrors() {
  const state = app.current.state;
  const remaining = app.completionErrors.filter((e) => (e.kind === "ITEM" ? !(state.responses[e.key] && (state.responses[e.key].storedCode || state.responses[e.key].textValue)) : !(state.dimensions[e.key] && Object.keys(state.dimensions[e.key]).length)));
  if (remaining.length !== app.completionErrors.length) { app.completionErrors = remaining; renderCompletionErrors(remaining); }
}

function renderCompletionErrors(errors) {
  const box = $("completion-errors");
  const list = $("completion-error-list");
  list.innerHTML = "";
  for (const node of $("editor").querySelectorAll(".has-error")) {
    node.classList.remove("has-error");
    const group = node.querySelector("[role=group], textarea, select, input");
    if (group) { group.removeAttribute("aria-invalid"); group.removeAttribute("aria-describedby"); }
    const msg = node.querySelector(".field-error");
    if (msg) msg.remove();
  }
  if (!errors.length) { box.hidden = true; return; }
  const model = modelFor(app.current);
  $("completion-errors-title").textContent = `The walk cannot be completed yet: ${errors.length} required ${errors.length === 1 ? "response is" : "responses are"} missing.`;
  errors.forEach((err, i) => {
    const selector = err.kind === "ITEM" ? `[data-item-key="${err.key}"]` : `[data-dimension-code="${err.key}"]`;
    const node = $("editor").querySelector(selector);
    const label = err.kind === "ITEM" ? (findItem(model, err.key) || {}).prompt || err.key : err.label || err.key;
    const li = document.createElement("li");
    const btn = document.createElement("button");
    btn.type = "button"; btn.className = "link-btn";
    btn.textContent = `${err.message} ${label}`.trim();
    btn.addEventListener("click", () => focusErrorTarget(node));
    li.appendChild(btn);
    list.appendChild(li);
    if (node) {
      node.classList.add("has-error");
      const msgId = `field-error-${i}`;
      const msg = document.createElement("p");
      msg.className = "field-error"; msg.id = msgId; msg.textContent = err.message;
      node.appendChild(msg);
      const group = node.querySelector("[role=group], textarea, select, input");
      if (group) { group.setAttribute("aria-invalid", "true"); group.setAttribute("aria-describedby", msgId); }
    }
  });
  box.hidden = false;
}

function focusErrorTarget(node) {
  if (!node) return;
  let acc = node.closest(".acc-body");
  while (acc) {
    acc.classList.add("open");
    const head = document.querySelector(`[aria-controls="${acc.id}"]`);
    if (head) head.setAttribute("aria-expanded", "true");
    acc = acc.parentElement ? acc.parentElement.closest(".acc-body") : null;
  }
  const target = node.querySelector(".pill, textarea, select, input");
  (target || node).focus?.();
  node.scrollIntoView({ block: "center" });
}

// ---- navigation guard --------------------------------------------------------------------------

/**
 * Internal navigation never abandons unsaved work. Leaving the editor does one of three things:
 * the save completes successfully, the editor and the unsaved input are retained, or the user
 * makes an explicit decision to discard. Nothing local disappears on its own.
 */
async function leaveEditor(go) {
  if (app.current && app.current.canEdit && hasUnsavedWork()) {
    const settled = await settleBeforeLeaving();
    if (!settled) return false;
  }
  hideUnsavedPanel();
  await go();
  return true;
}

async function settleBeforeLeaving() {
  if (!app.conflict && (app.dirty || ambiguousSave() || app.timer !== null)) await saveCurrent();
  if (app.inFlight) await app.inFlight;
  if (!hasUnsavedWork()) return true;
  const lifecycle = ambiguousOps().filter((op) => op.action !== "SAVE" && op.target === app.current.id);
  return askToDiscard(app.conflict ? UNSAVED_CONFLICT : (lifecycle.length ? UNSAVED_LIFECYCLE : UNSAVED_LEAVE));
}

/** Resolves true only when the user explicitly chooses to discard the unsaved work. */
function askToDiscard(message) {
  return new Promise((resolve) => {
    const panel = $("unsaved-panel");
    $("unsaved-summary").textContent = message;
    panel.hidden = false;
    const stay = $("unsaved-stay");
    const discard = $("unsaved-discard");
    const finish = (answer) => {
      stay.removeEventListener("click", onStay);
      discard.removeEventListener("click", onDiscard);
      panel.hidden = true;
      resolve(answer);
    };
    const onStay = () => { finish(false); (app.conflict ? $("conflict-reload") : $("save-retry")).focus?.(); };
    const onDiscard = () => {
      // An explicit decision: the local edits are dropped, every operation still pending for this
      // walk is abandoned by the user rather than by the app, and the server record stands.
      app.dirty = false;
      app.queued = false;
      app.failed = false;
      if (app.current) settleOpsFor(app.current.id);
      app.conflict = null;
      cancelScheduledSave();
      hideConflict();
      announce("Unsaved changes discarded");
      finish(true);
    };
    stay.addEventListener("click", onStay);
    discard.addEventListener("click", onDiscard);
    stay.focus();
  });
}

function hideUnsavedPanel() {
  const panel = $("unsaved-panel");
  if (panel) panel.hidden = true;
}

async function backToList() {
  await leaveEditor(async () => {
    await renderList();
    showView("list");
  });
}

// ---- bootstrap ---------------------------------------------------------------------------------

async function init() {
  $("global-status").textContent = "Loading...";
  const logo = $("brand-logo");
  logo.addEventListener("error", () => logo.classList.add("is-missing"));
  if (logo.complete && logo.naturalWidth === 0) logo.classList.add("is-missing");
  try {
    app.me = await api.get("/me");
    api.setCsrfToken(app.me.csrfToken);
    $("user-name").textContent = app.me.user.displayName || "";
    app.instrument = await api.get("/instrument/current");
    app.model = app.instrument.model;
    app.policies = app.instrument.policies;
  } catch (e) {
    $("global-status").textContent = "";
    if (e instanceof ApiError && e.code === "INSTRUMENT_NOT_AVAILABLE") showMessage(e.message, "error");
    else if (e instanceof ApiError && e.status === 401) showMessage("Sign-in required. Please sign in through the district portal and reload.", "error");
    else showMessage(`Could not load ICFWalk (${e instanceof ApiError ? e.code : "network error"}).`, "error");
    $("new-walk-btn").disabled = true;
    return;
  }
  $("global-status").textContent = "";
  $("list-sub").textContent = store.description();
  if (!creatableUnits().length) {
    $("new-walk-btn").disabled = true;
    $("new-walk-btn").title = "You do not have permission to create walks.";
  }
  $("new-walk-btn").addEventListener("click", onNewWalk);
  $("chooser-start").addEventListener("click", () => {
    const unit = creatableUnits().find((u) => u.id === $("chooser-unit").value);
    $("new-walk-chooser").hidden = true;
    if (unit) startNewWalk(unit);
  });
  $("chooser-cancel").addEventListener("click", () => { $("new-walk-chooser").hidden = true; $("new-walk-btn").focus(); });
  $("back-btn").addEventListener("click", backToList);
  $("nav-list-btn").addEventListener("click", backToList);
  $("save-btn").addEventListener("click", () => saveCurrent());
  $("save-btn-bottom").addEventListener("click", () => saveCurrent());
  $("save-retry").addEventListener("click", () => saveCurrent());
  $("complete-btn").addEventListener("click", completeCurrent);
  $("conflict-reload").addEventListener("click", resolveConflictReload);
  $("conflict-keep").addEventListener("click", resolveConflictKeep);
  $("conflict-retry").addEventListener("click", () => beginConflict(app.conflict && app.conflict.error));
  // Unload protection covers every pending state, not just dirty: a queued, in-flight, ambiguous,
  // failed, or conflicted save is unsaved work, and so is any create, completion, or void whose
  // outcome is still unknown -- including one started from the list, where no walk is open.
  window.addEventListener("beforeunload", (ev) => { if (hasUnfinishedWork()) { ev.preventDefault(); ev.returnValue = ""; } });
  renderPendingOps();
  await renderList();
  showView("list");
  body.dataset.ready = "true";
}

init();
