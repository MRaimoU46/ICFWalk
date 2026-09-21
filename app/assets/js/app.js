/**
 * ICFWalk browser application: My Walks list and the walk editor. Loads the signed-in user
 * (/api/me) and the current instrument render model (/api/instrument/current), then renders
 * everything from that model. Walk persistence goes through the WalkStore boundary
 * (walk-store.js): Phase 4 uses ApiWalkStore (server persistence) with a 700 ms debounced
 * autosave, client mutation ids for idempotent retries, row_version concurrency with a
 * conflict-resolution panel, explicit completion with field-level errors, and void instead of
 * delete. Historical walks render against their own pinned instrument version.
 */
import { createApi, ApiError, NetworkError, ResponseError } from "./api.js";
import { ApiWalkStore, newId } from "./walk-store.js";
import { renderEditor } from "./renderer.js";
import { createBlankState, dimensionDisplay } from "./walk-state.js";
import { fileName as summaryFileName, summaryText } from "./summary.js";

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
// Recovery messages. An unfinished action is resolved wherever the user happens to be, so resolving
// one can land on an editor that is carrying newer work. None of these ever replaces that work.
const UNSAVED_VOIDED = "That walk was removed, so the changes still on this page can no longer be saved to it. Discard them and return to My walks, or stay here to copy them first.";
const RECOVERY_VOIDED_STAY = "That walk was removed. Your changes are still on screen but cannot be saved to it.";
const RECOVERY_EDITOR_BUSY = "Finish or discard the changes in the walk you have open before retrying that save.";
const RECOVERY_CREATED_ELSEWHERE = "That walk was created and is waiting in My walks. Nothing here was replaced — your changes on this page were kept.";
const RECOVERY_MOVED_ON = "That action did finish, and the walk has changed since. Your changes on this page were kept; saving them will offer the saved version to reconcile with.";
const EMPTY_STATE_LINES = ["No walks saved yet.", 'Start one with "New walk" above.'];
const EXPORT_ANNOUNCE = "Summary exported";
const EXPORT_BLOCKED = "Resolve the conflict above before exporting the summary.";
// SAVE-03 spirit: when the flush did not reach the server, the person still gets the text of what
// is on screen rather than a stale server copy or nothing at all. The message says where the file
// came from, because a browser-generated file is not the saved copy and must not be mistaken for it.
const EXPORT_LOCAL = "The server could not be reached, so this file was generated in your browser from the unsaved information currently on this page. It is not the saved copy.";
// The two ways a flush can end without the server holding the editor state and without the server
// being unreachable. Neither is a network failure and neither gets a browser-generated file: the
// server was reached, so its summary route is still the authority, and exporting is blocked until
// the state it would describe is actually the state on screen.
const EXPORT_REJECTED = "The server did not accept the latest changes, so they are not part of the saved walk. The summary was not exported. Correct the reported problem, save, then export.";
const EXPORT_UNRESOLVED = "The last save did not finish, so the server may not hold the latest changes. The summary was not exported. Retry the save, then export.";
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
  // How the most recent save attempt ended, recorded by saveCurrent for callers that must tell the
  // outcomes apart. app.failed cannot: it is set both by a definitive server rejection and by
  // nothing at all when the answer was merely lost, and it says nothing about whether the server
  // was ever reached. See saveOutcome kinds in saveCurrent.
  saveOutcome: null,
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
 *
 * A retry makes the same transition from AMBIGUOUS: while a request carrying this mutation id is on
 * the wire the operation is IN_FLIGHT, which is what takes its retry control out of the recovery bar
 * and what every dispatch path tests before sending. Retries used to leave the record AMBIGUOUS for
 * the whole round trip, so the control stayed live and a second activation dispatched the same
 * mutation id again -- harmless on the server, which recognises the replay, but two answers racing
 * to refresh and re-open the same views on the way back. The flip happens synchronously before the
 * request is created, so there is no window between the test and the transition.
 */
function markOpSent(op) {
  if (!op || app.ops[op.key] !== op) return;
  if (op.status === OP_UNSENT || op.status === OP_AMBIGUOUS) {
    op.status = OP_IN_FLIGHT;
    renderPendingOps();
  }
}

function markOpAmbiguous(op) {
  if (op && app.ops[op.key] === op) { op.status = OP_AMBIGUOUS; op.wasAmbiguous = true; }
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

/**
 * What the recovery bar shows: every operation waiting for the user, plus the one whose retry is
 * currently on the wire. Keeping a retrying record on screen (with its controls disabled) is what
 * makes "already retrying" visible instead of making the bar blink out and back; an operation that
 * has never been ambiguous is an ordinary first attempt and belongs nowhere near recovery.
 */
function recoveryOps() {
  return pendingOps().filter((op) => op.status === OP_AMBIGUOUS || (op.status === OP_IN_FLIGHT && op.wasAmbiguous));
}

/** True when a request carrying this operation's mutation id is already on the wire. */
function opInFlight(action, target) {
  const op = currentOp(action, target);
  return Boolean(op && op.status === OP_IN_FLIGHT);
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
  const ops = recoveryOps();
  list.innerHTML = "";
  if (!ops.length) { box.hidden = true; return; }
  $("pending-ops-summary").textContent = ops.length === 1
    ? "One action did not finish."
    : `${ops.length} actions did not finish.`;
  for (const op of ops) {
    const retrying = op.status === OP_IN_FLIGHT;
    const li = document.createElement("li");
    li.className = "pending-op";
    li.dataset.opAction = op.action;
    li.dataset.opTarget = op.target;
    li.dataset.opStatus = op.status;
    const text = document.createElement("span");
    text.className = "pending-op-text";
    text.textContent = retrying
      ? `${opDescription(op)} Retrying it now...`
      : `${opDescription(op)} Retrying sends the same request, so it cannot happen twice.`;
    const retry = document.createElement("button");
    retry.type = "button"; retry.className = "btn btn-sm btn-primary pending-op-retry";
    retry.textContent = retrying ? "Retrying..." : "Retry";
    // While the retry is on the wire the operation owns its mutation id and nothing may dispatch it
    // again: the controls are disabled here, and resolveAmbiguousOp refuses an IN_FLIGHT record
    // whatever managed to reach it.
    retry.disabled = retrying;
    retry.addEventListener("click", () => resolveAmbiguousOp(op));
    const drop = document.createElement("button");
    drop.type = "button"; drop.className = "btn btn-sm pending-op-discard";
    drop.textContent = "Stop trying";
    drop.disabled = retrying;
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
  // A request carrying this mutation id is already on the wire. A second dispatch would be a
  // duplicate the server only tolerates because it recognises the replay, and its answer would race
  // the first one through the refresh below, so it is refused here as well as in the disabled control.
  if (op.status === OP_IN_FLIGHT) { renderPendingOps(); return; }
  if (op.action === "SAVE") {
    // A save belongs to its editor, which holds the local state it is still carrying. Opening it
    // would replace whatever is in the editor now, so a busy editor is asked for first.
    if (!app.current || app.current.id !== op.target) {
      if (editorHoldsNewerWork()) { showMessage(RECOVERY_EDITOR_BUSY, "error"); renderPendingOps(); return; }
      await openWalk(op.target);
    }
    if (app.current && app.current.id === op.target) await saveCurrent();
    renderPendingOps();
    return;
  }
  // From here the record is IN_FLIGHT: it is still the only thing that can resolve the operation,
  // it keeps its (disabled) place in the bar, and no second retry can be dispatched for it.
  markOpSent(op);
  try {
    if (op.action === "CREATE") {
      const walk = await store.create({ ...op.body, clientMutationId: op.mutationId });
      settleOp(op);
      // Recovery never switches the editor away from newer work: the walk exists and is listed,
      // and the user opens it once their own changes are settled.
      if (editorHoldsNewerWork()) { showMessage(RECOVERY_CREATED_ELSEWHERE); return; }
      showMessage("");
      await openWalk(walk.id, walk);
      return;
    }
    if (op.action === "COMPLETE") {
      const done = await store.complete({ id: op.target, rowVersion: op.rowVersion }, op.mutationId);
      settleOp(op);
      announce("Walk completed");
      await refreshAfterResolvedOp(op.target, false, done);
      return;
    }
    const voided = await store.remove(op.target, { reason: op.body.reason, rowVersion: op.rowVersion, clientMutationId: op.mutationId });
    settleOp(op);
    announce("Walk removed");
    await refreshAfterResolvedOp(op.target, true, voided);
  } catch (e) {
    if (isAmbiguousFailure(e)) {
      // Back to AMBIGUOUS, which restores the retry and discard controls for this record.
      markOpAmbiguous(op);
      showMessage(isUnreachable(e)
        ? "The server could not be reached. Try again; it cannot happen twice."
        : `That still did not finish (${classifySaveFailure(e).code}). Try again; it cannot happen twice.`, "error");
      return;
    }
    settleOp(op);
    if (e instanceof ApiError && e.code === "MUTATION_REPLAY_SUPERSEDED") {
      // It did commit, and the walk has changed since: the server record is the truth. Reading it
      // into the editor is still a replacement, so newer editor work comes first and reconciles
      // through the conflict panel on its own next save.
      const walkId = op.action === "CREATE" && e.details && e.details.walkId ? e.details.walkId : op.target;
      if (op.action === "VOID") { await refreshAfterResolvedOp(op.target, true); return; }
      if (editorHoldsNewerWork()) { showMessage(RECOVERY_MOVED_ON, "error"); return; }
      showMessage("");
      await openWalk(walkId);
      return;
    }
    showMessage(`That action could not be finished (${e instanceof ApiError ? e.code : "network error"}): ${e.message}`, "error");
    await refreshAfterResolvedOp(op.target, false);
  } finally {
    renderPendingOps();
  }
}

/**
 * True while the open editor is carrying work the server has not definitively accepted: a dirty
 * field, a debounced save waiting to go out, a save on the wire, a definitively failed save, an
 * unresolved conflict, or any save record still pending for this walk.
 *
 * Recovery reads this before it reloads, replaces, or leaves an editor. Resolving an ambiguous
 * CREATE, COMPLETE, or VOID used to reload or switch the editor unconditionally, and openWalk
 * cancels the scheduled save, replaces the editor state with the server copy, and clears the dirty
 * flag -- so a change typed after the operation went ambiguous disappeared the moment the user
 * pressed Retry, inside the 700 ms before its own autosave had even been dispatched.
 */
function editorHoldsNewerWork() {
  if (!app.current || !app.current.canEdit) return false;
  if (app.dirty || app.timer !== null || app.inFlight || app.failed || app.conflict) return true;
  return Boolean(currentOp("SAVE", app.current.id));
}

/**
 * Applies the lifecycle outcome of a resolved operation to the walk the editor is holding, without
 * touching the state on screen. Only the aggregate's own metadata moves: its status, the row version
 * the replay proved it still stands at, and the stamps that go with them. That is what lets the save
 * waiting behind the recovery go out against the right concurrency token and carry the user's newer
 * edit through, instead of colliding with the browser's own committed operation.
 */
function adoptResolvedWalk(resolved) {
  const walk = app.current;
  if (!walk || !resolved || resolved.id !== walk.id) return;
  walk.status = resolved.status;
  walk.rowVersion = resolved.rowVersion;
  walk.updatedAt = resolved.updatedAt;
  walk.completedAt = resolved.completedAt;
  walk.voidedAt = resolved.voidedAt;
  walk.revisionCount = resolved.revisionCount;
  walk.canEdit = resolved.canEdit;
  renderWalkBanner(walk);
  applyEditability(walk);
}

/**
 * Puts the views back in step with the server after an operation finally resolved -- but never at
 * the cost of newer editor work. When the open editor is carrying changes the server has not
 * definitively accepted, the state on screen is left exactly as it is: a refresh adopts the
 * resolved aggregate's metadata only, and leaving the editor altogether (a void) becomes the
 * user's explicit decision instead of the app's.
 */
async function refreshAfterResolvedOp(walkId, leaveEditorView, resolved = null) {
  const open = app.current && app.current.id === walkId;
  if (open && editorHoldsNewerWork()) {
    if (!leaveEditorView) { adoptResolvedWalk(resolved); renderPendingOps(); return; }
    // The walk is gone, so the changes still on this page can never be saved to it. They are not
    // dropped on the user's behalf: leaving is their decision, and staying keeps them on screen.
    // Staying deliberately leaves the editor as it stands rather than marking it read only from the
    // voided record: the unsaved-work guard is what stops the next navigation from dropping the
    // text silently, and a read-only walk is not guarded. The server refuses the next save with
    // WALK_VOIDED, which is the definitive answer that asks the question again.
    const discarded = await askToDiscard(UNSAVED_VOIDED);
    if (!discarded) { showMessage(RECOVERY_VOIDED_STAY, "error"); renderPendingOps(); return; }
  }
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
  if (name !== "walk") $("export-btn").hidden = true;
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
    if (opInFlight("VOID", walk.id)) return;      // one dispatch at a time for this mutation id
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
        err.textContent = isUnreachable(e)
          ? "The server could not be reached. Try again; it will not void the walk twice."
          : `That did not finish (${classifySaveFailure(e).code}). Try again; it will not void the walk twice.`;
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
  // A request carrying this create's mutation id may already be on the wire (the button is
  // re-enabled after an ambiguous answer, and the recovery bar offers the same retry): one
  // dispatch at a time, whichever control started it.
  if (opInFlight("CREATE", unit.id)) return;
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
      showMessage(isUnreachable(e)
        ? "Could not start a walk: the server could not be reached. Try again; it will not create a second walk."
        : `Starting the walk did not finish (${classifySaveFailure(e).code}). Try again; it will not create a second walk.`, "error");
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
  // The composer's buttons are controls like any other: a read-only walk must not offer Draft,
  // Clear, or Update. Client visibility is never the boundary -- the server refuses the save too.
  for (const button of $("editor").querySelectorAll(".email-slot button")) button.disabled = !editable;
  $("save-btn").hidden = !editable;
  $("save-btn-bottom").hidden = !editable;
  $("complete-btn").hidden = !editable || walk.status !== "DRAFT";
  // Exporting is a read: every walk the person may open, they may export (the route re-authorizes).
  $("export-btn").hidden = false;
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
  if (!resend && !app.dirty) { app.failed = false; app.saveOutcome = SAVE_OK; setSaveStatus(STATUS.saved); return Promise.resolve(); }
  // A resend reuses its record untouched. Otherwise the record for this payload is reused if one is
  // still open (the payload has not changed since it was minted) or minted now from the working
  // state and the row version it is issued against.
  const op = resend || beginOp("SAVE", walk.id, { body: { state: structuredClone(walk.state) }, rowVersion: walk.rowVersion });
  const payload = { ...walk, rowVersion: op.rowVersion, state: op.body.state };
  if (!resend) app.dirty = false;
  setSaveStatus(STATUS.saving);
  markOpSent(op);
  app.inFlight = (async () => {
    // A save's record is settled from the save's own outcome, never from whether its editor is
    // still the one on screen. Returning early on `app.current !== walk` left the record IN_FLIGHT
    // for good: unsaved work the unload guard sees for ever, on an operation the recovery bar
    // cannot offer (it lists what is unresolved, and IN_FLIGHT means a request is still on the
    // wire). The editor-facing work below is what is skipped when the editor has moved on.
    const stillOpen = () => app.current === walk;
    try {
      const saved = await store.save(payload, op.mutationId);
      settleOp(op);
      app.saveOutcome = SAVE_OK;
      walk.rowVersion = saved.rowVersion;
      walk.updatedAt = saved.updatedAt;
      walk.status = saved.status;
      walk.revisionCount = saved.revisionCount;
      if (!stillOpen()) return;
      app.baseline = op.body.state;
      app.failed = false;
      // A resend that carried exactly the current working state leaves nothing unsaved.
      if (resend && JSON.stringify(walk.state) === JSON.stringify(op.body.state)) app.dirty = false;
      setSaveStatus(app.dirty ? STATUS.unsaved : STATUS.saved);
    } catch (e) {
      // Classified once, by type, and every later branch reads that outcome rather than re-deriving
      // it. Re-deriving is how "not an ApiError" became "the server could not be reached".
      const outcome = classifySaveFailure(e);
      app.saveOutcome = outcome;
      if (AMBIGUOUS_KINDS.has(outcome.kind)) {
        // The server may have committed before the outcome was known: the record keeps the same
        // mutation id and the same frozen body so the retry replays rather than duplicating or
        // dropping the change. Marking it here rather than behind the editor check is what keeps
        // it offered in the recovery bar when the editor is no longer on this walk. This is the
        // same guarantee for an unusable answer as for a lost one -- a response existed, so the
        // mutation is exactly as likely to be committed.
        markOpAmbiguous(op);
        if (!stillOpen()) return;
        if (!resend) app.dirty = true;
        // Only a real transport failure is described as one.
        setSaveStatus(outcome.kind === "transport" ? STATUS.network : `${STATUS.ambiguous} (${outcome.code})`, { retry: true });
        announce(outcome.kind === "transport" ? "Save failed: the server could not be reached" : "Save did not finish");
        return;
      }
      // Definitive outcomes below: the operation id is spent and a new payload gets a new record.
      // The server was reached and answered definitively in every one of them.
      settleOp(op);
      if (!stillOpen()) {
        showMessage(`A save for another walk could not be completed (${outcome.code}).`, "error");
        return;
      }
      app.dirty = true;
      if (outcome.kind === "conflict") {
        // MUTATION_REPLAY_SUPERSEDED: this save did commit, but the walk has moved on since, so the
        // server refused to hand a stale editor a token for the newer state. That is a conflict like
        // any other: reload the saved version and reconcile.
        await beginConflict(e);
      } else if (outcome.code === "WALK_COMPLETION_INVALID") {
        app.failed = true;
        setSaveStatus("Not saved: a completed walk must keep every required response.", { retry: true });
        showCompletionErrors(e.details && e.details.errors ? e.details.errors : []);
      } else {
        app.failed = true;
        setSaveStatus(`${STATUS.failed} (${outcome.code}: ${e.message})`, { retry: true });
        announce("Save failed");
      }
    } finally {
      app.inFlight = null;
      // Rescheduling belongs to the editor this save came from; another walk's autosave is not this
      // save's to drive.
      if (stillOpen()) {
        const stillAmbiguous = Boolean(ambiguousSave());
        if (app.queued) { app.queued = false; if ((app.dirty || stillAmbiguous) && !app.conflict) scheduleSave(); }
        else if (!stillAmbiguous && app.dirty && !app.conflict && resend) scheduleSave();
      }
    }
  })();
  return app.inFlight;
}

/**
 * How a save attempt ended, for callers that must act differently on outcomes app.dirty and
 * app.failed cannot tell apart. Exactly one is recorded per attempt, in app.saveOutcome:
 *
 *   saved      the server committed the payload this attempt carried.
 *   transport  fetch() rejected: no response, no status line, no headers. The browser could not
 *              reach the server at all. Ambiguous, and the ONLY kind that means "not reached".
 *   server     the server answered with an HTTP 5xx. Ambiguous, but the server was reached, so
 *              nothing here may be reported to the person as a network failure.
 *   unknown    the server answered and the answer was unusable, or something else entirely went
 *              wrong after the request left the browser: a body that could not be read after the
 *              headers arrived, a 200 that was not JSON, a 200 whose JSON was not a walk, a bug in
 *              the response-handling code. Ambiguous for the same reason as `server` -- a response
 *              existed, so the mutation may be committed -- and just as much not a network failure.
 *   conflict   409 STALE_ROW_VERSION or MUTATION_REPLAY_SUPERSEDED; the conflict workflow owns it.
 *   rejected   any other definitive answer, including every 4xx validation rejection. The server
 *              was reached and it refused the state; nothing was committed.
 */
const SAVE_OK = Object.freeze({ kind: "saved" });

/** The kinds where the server may have committed, so the operation record must be kept and retried. */
const AMBIGUOUS_KINDS = new Set(["transport", "server", "unknown"]);

/**
 * Classifies a failed attempt, by type and never by elimination.
 *
 * The rule this enforces is default-deny: a failure is `transport` only when it is an actual
 * NetworkError, which api.js constructs in exactly one place -- the catch around fetch() itself.
 * Everything unrecognised falls to `unknown`, which is ambiguous (so recovery is preserved) but is
 * never reported as an unreachable server and never permits a browser-generated summary.
 *
 * The defect this replaces read "not an ApiError, therefore transport". An HTTP 200 carrying a
 * malformed body, or carrying JSON that is not a walk, raises neither ApiError nor NetworkError:
 * the first surfaces as ResponseError from api.js, the second as a plain TypeError from
 * ApiWalkStore. Both were classified as an unreachable server, and both then produced a
 * browser-generated file of a state the server may already have committed, under a message saying
 * it could not be reached. A response-shaped failure is not an absent server.
 */
function classifySaveFailure(e) {
  if (e instanceof NetworkError) return { kind: "transport", status: 0, code: e.code };
  if (e instanceof ApiError) {
    if (e.status >= 500) return { kind: "server", status: e.status, code: e.code };
    if (e.status === 409 && (e.code === "STALE_ROW_VERSION" || e.code === "MUTATION_REPLAY_SUPERSEDED")) {
      return { kind: "conflict", status: e.status, code: e.code };
    }
    return { kind: "rejected", status: e.status, code: e.code };
  }
  if (e instanceof ResponseError) return { kind: "unknown", status: e.status, code: e.code };
  return { kind: "unknown", status: 0, code: "UNEXPECTED_ERROR" };
}

/**
 * A failure is ambiguous when the request may have been committed before its outcome was known: a
 * transport failure, any HTTP 5xx, and every unusable or unexpected answer. Only a definitive
 * server answer -- a validation rejection, a conflict, an authorization refusal -- says for certain
 * that nothing was committed.
 */
function isAmbiguousFailure(e) {
  return AMBIGUOUS_KINDS.has(classifySaveFailure(e).kind);
}

/** True only for a real transport failure: the one case that may be called "could not be reached". */
function isUnreachable(e) {
  return e instanceof NetworkError;
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

// ---- summary export (SUM-01..05) ---------------------------------------------------------------

/**
 * How many send-and-settle passes the export flush will make before giving up. Each pass either
 * sends something or finds nothing left to send, so the flush terminates on its own; the bound is
 * there so that a pathological state (an editor that re-dirties itself, a store that reports a
 * success without clearing the payload) ends in a blocked export rather than a spinning tab.
 *
 * A normal flush takes at most three: settle a save already on the wire, send the state queued
 * behind it, confirm nothing is left.
 */
const EXPORT_FLUSH_PASSES = 6;

/**
 * Drives the editor state onto the server, and reports how that ended.
 *
 * saveCurrent() coalesces: called while a request is already on the wire it awaits *that* request
 * and leaves the newer state on the autosave timer. Awaiting it once is therefore not the same as
 * "everything on screen is saved", which is exactly what the export has to know. So this loops:
 * each pass awaits whatever saveCurrent does, then looks again at the real unsaved-work signals
 * (dirty, a queued timer, a request in flight, an unresolved save) and sends again if any is still
 * set, cancelling the autosave timer rather than waiting it out.
 *
 * It stops the moment the outcome is not "saved", because every other outcome is a different
 * answer for the caller and none of them is improved by sending again:
 *
 *   { saved: true }          the editor state is on the server.
 *   { unreachable: true }    the browser could not reach the server at all.
 *   { blocked: "conflict" }  the conflict workflow owns the walk until the person resolves it.
 *   { blocked: "rejected" }  the server was reached and refused the state.
 *   { blocked: "unresolved" }the server answered 5xx, answered something unusable, or the bound
 *                            above was reached: whether it holds the latest state is unknown, and
 *                            it was reached either way.
 *   { blocked: "moved" }     the editor is no longer on this walk.
 */
async function flushForExport(walk) {
  for (let pass = 0; pass < EXPORT_FLUSH_PASSES; pass += 1) {
    if (app.current !== walk) return { blocked: "moved" };
    if (app.conflict) return { blocked: "conflict" };
    if (!app.dirty && app.timer === null && !app.inFlight && !ambiguousSave()) return { saved: true };
    app.saveOutcome = null;
    await saveCurrent();
    if (app.current !== walk) return { blocked: "moved" };
    if (app.conflict) return { blocked: "conflict" };
    const outcome = app.saveOutcome;
    if (!outcome || outcome.kind === "saved") continue;
    if (outcome.kind === "transport") return { unreachable: true };
    if (outcome.kind === "conflict") return { blocked: "conflict" };
    if (outcome.kind === "rejected") return { blocked: "rejected", outcome };
    // "server" (an HTTP 5xx) and "unknown" (an unusable or unexpected answer). Both mean the server
    // was reached and whether it holds the state is not known, which is one answer, not two.
    return { blocked: "unresolved", outcome };
  }
  return { blocked: "unresolved" };
}

/**
 * Downloads the walk summary.
 *
 * The server's copy is authoritative: it is authorized, built from the walk's pinned instrument
 * version, evaluated by the server engine, and audited. So the editor state is flushed onto the
 * server first and the download is a plain GET of the summary route, which carries the session
 * cookie. A read-only viewer has nothing to flush and goes straight there.
 *
 * THE FALLBACK RULE (Phase 5 correction). The browser formatter is used when, and only when, the
 * flush failed with an actual NetworkError -- fetch() rejected, no response was produced, the
 * server was not reached. That is a test of type, not of elimination: "not an ApiError" is not a
 * transport failure, and classifySaveFailure sends everything it does not recognise to `unknown`,
 * which blocks. Every other unsent-work condition blocks the export instead of producing a file:
 *
 *   - Work merely queued or in flight is not a reason for anything: it is flushed (see
 *     flushForExport) and the export then proceeds from the server. Previously an edit made during
 *     an in-flight save left app.dirty set, and the export read that as unsent work and built a
 *     local file while the queued save was still sitting on the autosave timer, never sent.
 *   - A definitive rejection (any 4xx) is not a transport failure: the server was reached and it
 *     refused the state. A browser-generated file would put the refused state into a document that
 *     looks like the saved walk, and the old message would have blamed a network that was working.
 *   - An HTTP 5xx is not a transport failure either. It stays ambiguous and keeps every Phase 4
 *     recovery guarantee (the operation record, its mutation id and its frozen body are untouched
 *     here), but it is reported as an unfinished save, not as an unreachable server.
 *   - An answer the browser cannot use is not a transport failure at all: a 200 with a malformed
 *     body, a 200 whose JSON is not a walk, a body that breaks after its headers, or any other
 *     unexpected failure in the response path. A response existed, so the mutation may already be
 *     committed; handing over a browser-made file of that state, under a message blaming the
 *     network, would be wrong twice over. It blocks, with the same Phase 4 recovery record intact.
 *   - A conflict blocks the export and leaves the conflict workflow exactly as it was.
 *
 * When the fallback does run, the file is the browser formatter's text for the working state
 * (byte-identical to the server's for the same state, per the shared vectors) and the message says
 * it was generated in the browser from unsaved information, so nobody mistakes it for the saved copy.
 */
async function exportSummary() {
  const walk = app.current;
  if (!walk) return;
  if (app.conflict) { blockExport(EXPORT_BLOCKED); return; }

  const flushed = walk.canEdit ? await flushForExport(walk) : { saved: true };
  if (app.current !== walk) return;                 // the editor moved on while the flush ran
  if (flushed.blocked === "conflict" || app.conflict) { blockExport(EXPORT_BLOCKED); return; }
  if (flushed.blocked === "rejected") { blockExport(EXPORT_REJECTED); return; }
  if (flushed.blocked) { blockExport(EXPORT_UNRESOLVED); return; }

  const local = Boolean(flushed.unreachable);
  const href = local ? localSummaryUrl(walk) : `${body.dataset.apiBase}/walks/${encodeURIComponent(walk.id)}/summary`;
  const link = document.createElement("a");
  link.href = href;
  // The server route already answers with Content-Disposition: attachment and the sanitized file
  // name, which is what makes it a download and what names it. A `download` attribute on top of
  // that is redundant -- the header wins over it per the HTML spec -- and it makes the browser
  // fetch the URL on its own terms instead of following the response, so it is set only for the
  // local fallback, whose blob carries no headers at all.
  if (local) link.download = summaryFileName(modelFor(walk), walk.state, app.editor.evaluation, walk.id);
  document.body.appendChild(link);
  link.click();
  link.remove();
  if (local) {
    URL.revokeObjectURL(href);
    showMessage(EXPORT_LOCAL, "error");
  }
  announce(local ? `${EXPORT_ANNOUNCE}. ${EXPORT_LOCAL}` : EXPORT_ANNOUNCE);
}

/** No file, and the person is told why in the same words on screen and to a screen reader. */
function blockExport(message) {
  showMessage(message, "error");
  announce(message);
}

function localSummaryUrl(walk) {
  const text = summaryText(modelFor(walk), walk.state, app.editor.evaluation);
  return URL.createObjectURL(new Blob([text], { type: "text/plain;charset=utf-8" }));
}

// ---- completion --------------------------------------------------------------------------------

async function completeCurrent() {
  if (!app.current || !app.current.canEdit) return;
  if (app.dirty || app.inFlight || ambiguousSave()) await saveCurrent();
  if (app.inFlight) await app.inFlight;
  if (app.conflict || app.dirty || ambiguousSave()) return;
  const walk = app.current;
  if (opInFlight("COMPLETE", walk.id)) return;   // one dispatch at a time for this mutation id
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
      showMessage(isUnreachable(e)
        ? "Could not complete the walk: the server could not be reached. Try again; it will not complete the walk twice."
        : `The completion did not finish (${classifySaveFailure(e).code}). Try again; it will not complete the walk twice.`, "error");
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
  $("export-btn").addEventListener("click", exportSummary);
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
