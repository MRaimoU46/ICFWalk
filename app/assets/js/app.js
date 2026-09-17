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
import { createBlankState, applyOrgUnitDefaults, dimensionDisplay } from "./walk-state.js";

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
  conflict: "This walk was changed elsewhere — resolve the conflict below to continue saving.",
  readOnly: "Read only",
};
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
  timer: null, inFlight: null, queued: false, pendingMutationId: null,
  conflict: null, completionErrors: [],
};

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
    open.addEventListener("click", () => openWalk(w.id));
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
    if (completed && !reason.value.trim()) { err.textContent = "Enter a reason to void this walk."; err.hidden = false; reason.focus(); return; }
    yes.disabled = true;
    try {
      await store.remove(walk.id, { reason: completed ? reason.value.trim() : "", rowVersion: walk.rowVersion });
      announce(completed ? "Walk voided" : "Walk deleted");
      await renderList();
    } catch (e) {
      yes.disabled = false;
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
  const state = applyOrgUnitDefaults(app.model, createBlankState(app.model), unit.code);
  $("new-walk-btn").disabled = true;
  try {
    const walk = await store.create({ orgUnitId: unit.id, versionId: app.instrument.version.versionId, state, clientMutationId: newId() });
    await openWalk(walk.id, walk);
  } catch (e) {
    showMessage(e instanceof ApiError ? `Could not start a walk (${e.code}): ${e.message}` : "Could not start a walk: the server could not be reached.", "error");
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
  clearTimeout(app.timer);
  app.current = walk;
  app.baseline = structuredClone(walk.state);
  app.dirty = false;
  app.pendingMutationId = null;
  app.conflict = null;
  app.completionErrors = [];
  hideConflict();
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
  for (const el of $("editor").querySelectorAll("select, input, textarea, .pill")) el.disabled = !editable;
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
  app.pendingMutationId = null; // a new payload gets a new mutation id
  if (app.completionErrors.length) refreshCompletionErrors();
  if (app.conflict) return;     // hold saves until the conflict is resolved (edits are kept locally)
  setSaveStatus(STATUS.unsaved);
  scheduleSave();
}

function scheduleSave() {
  clearTimeout(app.timer);
  app.timer = setTimeout(() => saveCurrent(), AUTOSAVE_DELAY_MS);
}

/** Saves the current working state; coalesces concurrent calls and re-runs when edits arrived mid-flight. */
function saveCurrent() {
  if (!app.current || !app.current.canEdit || app.conflict) return Promise.resolve();
  clearTimeout(app.timer);
  if (app.inFlight) { app.queued = true; return app.inFlight; }
  if (!app.dirty) { setSaveStatus(STATUS.saved); return Promise.resolve(); }
  const walk = app.current;
  const mutationId = app.pendingMutationId || newId();
  app.pendingMutationId = mutationId;
  const payload = { ...walk, state: structuredClone(walk.state) };
  app.dirty = false;
  setSaveStatus(STATUS.saving);
  app.inFlight = (async () => {
    try {
      const saved = await store.save(payload, mutationId);
      if (app.current !== walk) return;
      walk.rowVersion = saved.rowVersion;
      walk.updatedAt = saved.updatedAt;
      walk.status = saved.status;
      walk.revisionCount = saved.revisionCount;
      app.baseline = payload.state;
      if (app.pendingMutationId === mutationId) app.pendingMutationId = null;
      if (!app.dirty) setSaveStatus(STATUS.saved);
    } catch (e) {
      if (app.current !== walk) return;
      app.dirty = true;
      if (e instanceof ApiError && e.status === 409 && e.code === "STALE_ROW_VERSION") {
        app.pendingMutationId = null;
        await beginConflict(e);
      } else if (e instanceof ApiError && e.code === "WALK_COMPLETION_INVALID") {
        app.pendingMutationId = null;
        setSaveStatus("Not saved: a completed walk must keep every required response.");
        showCompletionErrors(e.details && e.details.errors ? e.details.errors : []);
      } else if (e instanceof ApiError) {
        app.pendingMutationId = null;
        setSaveStatus(`${STATUS.failed} (${e.code}: ${e.message})`, { retry: true });
        announce("Save failed");
      } else {
        // Transport failure: keep the same mutation id so the retry is idempotent on the server.
        setSaveStatus(STATUS.network, { retry: true });
        announce("Save failed: the server could not be reached");
      }
    } finally {
      app.inFlight = null;
      if (app.queued) { app.queued = false; if (app.dirty && !app.conflict) scheduleSave(); }
    }
  })();
  return app.inFlight;
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
  hideConflict();
  await openWalk(server.id, { ...server, state: merged });
  app.dirty = true;
  app.pendingMutationId = null;
  setSaveStatus(STATUS.unsaved);
  await saveCurrent();
  announce("Your edits were applied to the saved version");
}

// ---- completion --------------------------------------------------------------------------------

async function completeCurrent() {
  if (!app.current || !app.current.canEdit) return;
  if (app.dirty || app.inFlight) await saveCurrent();
  if (app.conflict || app.dirty) return;
  const walk = app.current;
  $("complete-btn").disabled = true;
  try {
    const done = await store.complete(walk, newId());
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
      showCompletionErrors(e.details && e.details.errors ? e.details.errors : []);
    } else if (e instanceof ApiError && e.status === 409 && e.code === "STALE_ROW_VERSION") {
      app.dirty = true;
      await beginConflict(e);
    } else {
      showMessage(e instanceof ApiError ? `Could not complete the walk (${e.code}): ${e.message}` : "Could not complete the walk: the server could not be reached.", "error");
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

async function backToList() {
  if (app.dirty && !app.conflict) await saveCurrent();
  if (app.inFlight) await app.inFlight;
  await renderList();
  showView("list");
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
  window.addEventListener("beforeunload", (ev) => { if (app.dirty && app.current && app.current.canEdit) { ev.preventDefault(); ev.returnValue = ""; } });
  await renderList();
  showView("list");
  body.dataset.ready = "true";
}

init();
