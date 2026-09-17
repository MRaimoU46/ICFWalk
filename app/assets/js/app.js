/**
 * ICFWalk browser application: My Walks list and the walk editor. Loads the signed-in user
 * (/api/me) and the current instrument render model (/api/instrument/current), then renders
 * everything from that model. Walk persistence goes through the WalkStore boundary
 * (walk-store.js); Phase 3 uses the in-memory SessionWalkStore.
 */
import { createApi, ApiError } from "./api.js";
import { SessionWalkStore } from "./walk-store.js";
import { renderEditor } from "./renderer.js";
import { createBlankState, applyOrgUnitDefaults, dimensionDisplay } from "./walk-state.js";

// Presentation configuration for the My Walks card (dimension codes, not instrument content):
// title = grade · content; meta = school · date · relative update time (prototype behavior).
const LIST_CARD = { title: ["grade", "content"], meta: ["school", "date"] };
const STATUS = { saved: "All changes saved", unsaved: "Unsaved changes", saving: "Saving...", failed: "Could not save — changes kept on screen only" };
const EMPTY_STATE_LINES = ["No walks saved yet.", 'Start one with "New walk" above.'];
const DELETE_CONFIRM = "Delete this walk? This cannot be undone.";

const body = document.body;
const api = createApi(body.dataset.apiBase);
const store = new SessionWalkStore();
const $ = (id) => document.getElementById(id);

const app = { me: null, instrument: null, model: null, policies: null, current: null, editor: null, dirty: false };

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

function setSaveStatus(text) {
  $("save-status").textContent = text;
  $("save-status-bottom").textContent = text;
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

function summarize(walk) {
  const display = (code) => dimensionDisplay(app.model, walk.state, code);
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
  const walks = await store.list();
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
    const info = document.createElement("div");
    info.className = "info";
    const title = document.createElement("p");
    title.className = "title";
    title.textContent = s.title;
    const meta = document.createElement("p");
    meta.className = "meta";
    meta.textContent = [...s.meta, relTime(w.updatedAt)].filter(Boolean).join(" · ");
    info.append(title, meta);
    const open = document.createElement("button");
    open.type = "button"; open.className = "btn btn-sm open-btn"; open.textContent = "Open";
    open.setAttribute("aria-label", `Open ${s.title}`);
    open.addEventListener("click", () => openWalk(w.id));
    const del = document.createElement("button");
    del.type = "button"; del.className = "btn btn-sm btn-danger delete-btn"; del.textContent = "Delete";
    del.setAttribute("aria-label", `Delete ${s.title}`);
    del.addEventListener("click", () => confirmDelete(card, w.id, s.title));
    card.append(info, open, del);
    list.appendChild(card);
  }
}

function confirmDelete(card, id, title) {
  if (card.nextElementSibling && card.nextElementSibling.classList.contains("confirm-row")) return;
  const row = document.createElement("div");
  row.className = "confirm-row";
  row.setAttribute("role", "alertdialog");
  row.setAttribute("aria-label", `Delete ${title}`);
  const p = document.createElement("p");
  p.textContent = DELETE_CONFIRM;
  const yes = document.createElement("button");
  yes.type = "button"; yes.className = "btn btn-sm btn-danger confirm-delete"; yes.textContent = "Delete";
  yes.addEventListener("click", async () => { await store.remove(id); announce("Walk deleted"); await renderList(); });
  const no = document.createElement("button");
  no.type = "button"; no.className = "btn btn-sm cancel-delete"; no.textContent = "Cancel";
  no.addEventListener("click", () => { row.remove(); card.querySelector(".delete-btn").focus(); });
  row.append(p, yes, no);
  card.after(row);
  no.focus();
}

function creatableUnits() {
  const ids = app.me.permissions["walk.create"] || [];
  return ids.map((id) => ({ id, ...(app.me.orgUnits[id] || { code: "", name: id, type: "" }) }))
    .sort((a, b) => (a.type === b.type ? a.name.localeCompare(b.name) : a.type === "SCHOOL" ? -1 : 1));
}

async function startNewWalk(unit) {
  const state = applyOrgUnitDefaults(app.model, createBlankState(app.model), unit.code);
  const walk = await store.create({ orgUnitId: unit.id, orgUnitName: unit.name, versionId: app.instrument.version.versionId, state });
  await openWalk(walk.id);
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

async function openWalk(id) {
  const walk = await store.open(id);
  if (!walk) { showMessage("Could not load that walk.", "error"); return; }
  app.current = walk;
  app.dirty = false;
  $("editor").innerHTML = "";
  app.editor = renderEditor($("editor"), {
    model: app.model, walk, policies: app.policies, announce,
    onChange: (state) => { app.current.state = state; app.dirty = true; setSaveStatus(STATUS.unsaved); },
  });
  const note = $("version-note");
  note.textContent = app.instrument.version.isFallbackDraft
    ? `Instrument version: ${app.instrument.version.versionLabel} (DRAFT preview; no version is published yet).`
    : `Instrument version: ${app.instrument.version.versionLabel}.`;
  note.hidden = false;
  setSaveStatus(STATUS.saved);
  showView("walk");
  window.scrollTo(0, 0);
  $("back-btn").focus();
}

async function saveCurrent() {
  if (!app.current) return;
  setSaveStatus(STATUS.saving);
  try {
    app.current = await store.save(app.current);
    app.dirty = false;
    setSaveStatus(STATUS.saved);
  } catch (e) {
    console.error(e);
    setSaveStatus(STATUS.failed);
  }
}

async function backToList() {
  if (app.dirty) await saveCurrent();
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
  $("save-btn").addEventListener("click", saveCurrent);
  $("save-btn-bottom").addEventListener("click", saveCurrent);
  await renderList();
  showView("list");
  body.dataset.ready = "true";
}

init();
