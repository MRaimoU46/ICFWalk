/**
 * Instrument administration view (Phase 6). Reads and writes only the admin instrument routes, all
 * of which require instrument.manage on the server:
 *
 *   GET  /api/admin/instrument/versions                  every version, with status and walk count
 *   POST /api/admin/instrument/import                    ADM-01 import a document into a DRAFT
 *   GET  /api/admin/instrument/versions/{id}/preview     ADM-02 the render model walks would use
 *   POST /api/admin/instrument/versions/{id}/clone       ADM-06 new DRAFT from any version
 *   GET  /api/admin/instrument/versions/{id}/wording     ADM-06 search a version's editable wording
 *   POST /api/admin/instrument/versions/{id}/edits       ADM-06 change DRAFT wording
 *   GET  /api/admin/instrument/compare?from=&to=         ADM-06 what a candidate changes
 *   POST /api/admin/instrument/versions/{id}/publish     ADM-04 publish a DRAFT
 *   POST /api/admin/instrument/versions/{id}/retire      ADM-07 stop new walks on a version
 *   POST /api/admin/instrument/versions/{id}/discard     remove a DRAFT no walk references
 *   GET  /api/admin/instrument/versions/{id}/placeholders ADM-08 placeholder review queue
 *
 * Every decision is the server's. This module never infers what an action is allowed to do from
 * the list it last loaded: it offers the actions a status makes sensible and shows whatever the
 * server answers, including a refusal. A mutation whose answer never arrived is reported as
 * unknown, with the version list reloaded, never as done or not done.
 *
 * The preview renders through the same renderer.js the walk editor uses, over a blank state that
 * is never saved, so what an administrator reviews is what a walk would render.
 *
 * Every value from the server reaches the page through textContent or an attribute set by the DOM
 * API, never innerHTML, so instrument wording and file content are always text.
 */
import { ApiError, NetworkError, ResponseError } from "./api.js";
import { renderEditor } from "./renderer.js";
import { createBlankState } from "./walk-state.js";

const MAX_DOCUMENT_BYTES = 5000000;   // mirrors the import route's 413 limit
const STATUS_LABEL = { DRAFT: "Draft", PUBLISHED: "Published", RETIRED: "Retired" };
const COUNT_LABELS = [
  ["sections", "Sections"], ["items", "Items"], ["responseSets", "Response sets"], ["responseOptions", "Response options"],
  ["rules", "Rules"], ["dimensions", "Dimensions"], ["dimensionValues", "Dimension values"], ["instrumentDimensions", "Instrument dimensions"],
  ["placeholders", "Placeholder prompts"],
];
const COLLECTION_LABEL = {
  sections: "Section", items: "Item", responseSets: "Response set", responseOptions: "Response option", rules: "Rule",
  dimensions: "Dimension", dimensionValues: "Dimension value", instrumentDimensions: "Instrument dimension",
};
const TARGET_LABEL = { section: "Section", item: "Item", responseOption: "Response option", version: "Version" };
const FIELD_LABEL = {
  title: "Title", instructions: "Instructions", reviewStatus: "Review status", prompt: "Prompt", helpText: "Help text",
  placeholder: "Placeholder text", revisionNotes: "Revision notes", label: "Label", definition: "Definition",
};
const LONG_FIELDS = new Set(["prompt", "instructions", "helpText", "definition", "revisionNotes"]);
const UNKNOWN_OUTCOME = "The server's answer did not arrive, so it is not known whether this was applied. The version list has been reloaded; check it before trying again.";

function el(tag, attrs = {}, ...children) {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (v === null || v === undefined || v === false) continue;
    if (k === "className") node.className = v;
    else if (k === "text") node.textContent = v;
    else if (k === "value") node.value = v;
    else node.setAttribute(k, v === true ? "" : String(v));
  }
  for (const child of children.flat()) {
    if (child === null || child === undefined || child === false) continue;
    node.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }
  return node;
}

function button(text, attrs = {}, onClick = null) {
  const b = el("button", { type: "button", className: "btn btn-sm", ...attrs, text });
  if (onClick) b.addEventListener("click", onClick);
  return b;
}

function formatWhen(iso) {
  if (!iso) return "—";
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? String(iso) : d.toLocaleString("en-US", { dateStyle: "medium", timeStyle: "short" });
}

function shortChecksum(checksum) {
  return checksum ? `${String(checksum).slice(0, 12)}…` : "—";
}

/** A comparison value as text: absent is shown as such, never as an empty cell that looks like "". */
function valueText(v) {
  if (v === null || v === undefined) return "(none)";
  if (typeof v === "string") return v.length ? v : "(empty)";
  return JSON.stringify(v);
}

function plural(n, one, many) { return `${n} ${n === 1 ? one : many}`; }

/** A wide table in its own horizontal scroller, reachable by keyboard even when it holds no control. */
function scrollRegion(label, table) {
  return el("div", { className: "admin-table-scroll", role: "region", "aria-label": label, tabindex: "0" }, table);
}

let uid = 0;
const nextId = (prefix) => `${prefix}-${++uid}`;

export function mountAdmin({ api, announce = () => {} }) {
  const $ = (id) => document.getElementById(id);
  const heading = $("admin-heading");
  const status = $("admin-status");
  const error = $("admin-error");
  const versionsBox = $("admin-versions");
  const panel = $("admin-panel");
  const importForm = $("admin-import-form");
  const importFile = $("admin-import-file");
  const importResult = $("admin-import-result");
  const view = { versions: [], busy: false, bound: false };

  function setStatus(text) { status.textContent = text; if (text) announce(text); }
  function showError(message, issues = null) {
    error.replaceChildren();
    if (!message) { error.hidden = true; return; }
    error.append(el("p", { className: "admin-error-message", text: message }));
    if (issues && issues.length) error.append(issueList(issues));
    error.hidden = false;
  }

  function issueList(issues) {
    return el("ul", { className: "admin-issues" }, issues.map((i) =>
      el("li", {}, el("code", { text: i.code || "ISSUE" }), ` ${i.message || ""}`, i.path ? el("span", { className: "muted", text: ` (${i.path})` }) : null)));
  }

  /** A refusal carries the server's message and code; a lost answer is never reported as either outcome. */
  function describe(e, mutation) {
    if (e instanceof ApiError) return { message: `${e.message} (${e.code})`, issues: e.details && Array.isArray(e.details.issues) ? e.details.issues : null };
    if (mutation && (e instanceof NetworkError || e instanceof ResponseError)) return { message: UNKNOWN_OUTCOME, issues: null };
    if (e instanceof NetworkError) return { message: "The server could not be reached. Try again when you are back online.", issues: null };
    if (e instanceof ResponseError) return { message: "The server answered, but the answer could not be read.", issues: null };
    return { message: `This page could not show the result: ${e && e.message ? e.message : String(e)}. Reload to see the current state.`, issues: null };
  }

  async function guarded(fn, { mutation = false } = {}) {
    if (view.busy) return undefined;
    view.busy = true;
    document.body.dataset.adminBusy = "true";
    showError("");
    try {
      return await fn();
    } catch (e) {
      const d = describe(e, mutation);
      showError(d.message, d.issues);
      setStatus("");
      if (mutation && !(e instanceof ApiError)) await loadVersions().catch(() => {});
      return undefined;
    } finally {
      view.busy = false;
      delete document.body.dataset.adminBusy;
    }
  }

  // ---- versions --------------------------------------------------------------------------------

  async function loadVersions() {
    const res = await api.get("/admin/instrument/versions");
    view.versions = res.versions || [];
    renderVersions();
  }

  function versionById(id) { return view.versions.find((v) => v.versionId === id) || null; }

  function statusCell(v) {
    return el("td", {},
      el("span", { className: `status-badge admin-status-${String(v.status).toLowerCase()}`, text: STATUS_LABEL[v.status] || v.status }),
      v.isCurrent ? el("span", { className: "status-badge admin-current", text: "In service", title: "New walks of this instrument start on this version" }) : null);
  }

  function actionsFor(v) {
    const name = `${v.versionLabel} (${v.instrumentCode})`;
    const actions = [
      button("Preview", { "aria-label": `Preview ${name}` }, () => openPreview(v.versionId)),
      button("Compare", { "aria-label": `Compare ${name} with another version` }, () => openCompare(v.versionId)),
      button("Placeholders", { "aria-label": `Placeholder review for ${name}` }, () => openPlaceholders(v.versionId)),
      button("New draft", { "aria-label": `Create a new draft from ${name}` }, () => openClone(v.versionId)),
    ];
    if (v.status === "DRAFT") {
      actions.push(button("Edit wording", { "aria-label": `Edit wording of ${name}` }, () => openWording(v.versionId)));
      actions.push(button("Publish", { className: "btn btn-sm btn-primary", "aria-label": `Publish ${name}` }, () => confirmPublish(v)));
      actions.push(button("Discard", { className: "btn btn-sm btn-danger", "aria-label": `Discard ${name}`, disabled: v.walkCount > 0 ? true : null, title: v.walkCount > 0 ? "Walks reference this draft" : null }, () => confirmDiscard(v)));
    }
    if (v.status === "PUBLISHED") {
      actions.push(button("Retire", { className: "btn btn-sm btn-danger", "aria-label": `Retire ${name}` }, () => confirmRetire(v)));
    }
    return el("td", { className: "admin-actions" }, el("div", { className: "admin-action-row" }, actions));
  }

  function renderVersions() {
    versionsBox.replaceChildren();
    if (!view.versions.length) {
      versionsBox.append(el("p", { className: "muted", text: "No instrument versions exist yet. Import a document above." }));
      return;
    }
    const table = el("table", { className: "report-table admin-versions-table" },
      el("caption", { text: `${plural(view.versions.length, "version", "versions")}. Published versions never change.` }),
      el("thead", {}, el("tr", {}, ["Version", "Instrument", "Status", "Published", "Walks", "Checksum", "Actions"].map((h) => el("th", { scope: "col", text: h })))),
      el("tbody", {}, view.versions.map((v) => el("tr", { "data-version-id": v.versionId, "data-status": v.status },
        el("th", { scope: "row", text: v.versionLabel }),
        el("td", {}, v.instrumentCode, v.isRuntimeInstrument ? el("span", { className: "muted", text: " (walks)" }) : null),
        statusCell(v),
        el("td", { text: formatWhen(v.publishedAt) }),
        el("td", { className: "num", text: String(v.walkCount ?? 0) }),
        el("td", {}, el("code", { title: v.checksum || "", text: shortChecksum(v.checksum) })),
        actionsFor(v)))));
    versionsBox.append(scrollRegion("Instrument versions", table));
  }

  // ---- panel -----------------------------------------------------------------------------------

  function openPanel(title, ...content) {
    const titleId = nextId("admin-panel-title");
    panel.replaceChildren(
      el("div", { className: "admin-panel-head" },
        el("h2", { className: "section-title", id: titleId, tabindex: "-1", text: title }),
        button("Close", { className: "btn btn-sm btn-ghost", "aria-label": `Close ${title}` }, closePanel)),
      ...content);
    panel.setAttribute("aria-labelledby", titleId);
    panel.hidden = false;
    reveal($(titleId));
    return panel;
  }

  /** Focus a control in the panel and bring the panel's top into view, not just its first line. */
  function reveal(target) {
    target.focus({ preventScroll: true });
    panel.scrollIntoView({ block: "start" });
  }

  function closePanel() {
    panel.replaceChildren();
    panel.hidden = true;
    heading.focus();
  }

  // ---- import (ADM-01) -------------------------------------------------------------------------

  async function onImport(ev) {
    ev.preventDefault();
    importResult.replaceChildren();
    const file = importFile.files && importFile.files[0];
    if (!file) { showError("Choose an instrument document (.json) to import."); importFile.focus(); return; }
    if (file.size > MAX_DOCUMENT_BYTES) { showError(`That file is ${file.size.toLocaleString("en-US")} bytes. An instrument document may be at most ${MAX_DOCUMENT_BYTES.toLocaleString("en-US")} bytes.`); return; }
    let document;
    try {
      document = JSON.parse(await file.text());
    } catch (e) {
      showError(`${file.name} is not valid JSON, so nothing was sent. ${e.message}`);
      return;
    }
    await guarded(async () => {
      setStatus(`Validating ${file.name}...`);
      let result;
      try {
        result = await api.post("/admin/instrument/import", { document });
      } catch (e) {
        if (e instanceof ApiError && e.code === "INSTRUMENT_CONFIG_INVALID") {
          importResult.append(invalidSummary(file.name, e));
          setStatus(`${file.name} was not imported: ${plural((e.details?.issues || []).length, "problem", "problems")} found.`);
          return;
        }
        throw e;
      }
      importResult.append(importSummary(file.name, result));
      setStatus(`${result.created ? "Created" : "Re-imported"} draft ${result.versionLabel}.`);
      await loadVersions();
    }, { mutation: true });
  }

  function invalidSummary(fileName, e) {
    const issues = (e.details && e.details.issues) || [];
    return el("div", { className: "admin-summary admin-summary-invalid", role: "group", "aria-label": "Validation summary" },
      el("p", { className: "admin-summary-title", text: `Not imported: ${fileName} has ${plural(issues.length, "problem", "problems")}. Nothing was written.` }),
      issueList(issues));
  }

  function importSummary(fileName, r) {
    const counts = r.counts || {};
    const warnings = r.warnings || [];
    const placeholders = r.placeholders || [];
    return el("div", { className: "admin-summary", role: "group", "aria-label": "Validation summary" },
      el("p", { className: "admin-summary-title", text: `${r.created ? "Created" : "Re-imported"} DRAFT ${r.versionLabel} of ${r.instrumentCode} from ${fileName}.` }),
      el("p", { className: "muted" }, "Checksum ", el("code", { text: r.checksum || "" })),
      el("table", { className: "report-table admin-counts" },
        el("caption", { text: "What the document defines" }),
        el("tbody", {}, COUNT_LABELS.filter(([k]) => counts[k] !== undefined).map(([k, label]) =>
          el("tr", {}, el("th", { scope: "row", text: label }), el("td", { className: "num", text: String(counts[k]) }))))),
      warnings.length
        ? el("div", {}, el("p", { className: "admin-summary-subtitle", text: `${plural(warnings.length, "warning", "warnings")} (imported anyway)` }), issueList(warnings))
        : el("p", { className: "muted", text: "No warnings." }),
      placeholders.length
        ? el("div", { className: "row-actions" },
          el("span", { text: `${plural(placeholders.length, "prompt still carries", "prompts still carry")} placeholder source content.` }),
          button("Review placeholders", {}, () => openPlaceholders(r.versionId)))
        : null,
      el("div", { className: "row-actions" },
        button("Preview", {}, () => openPreview(r.versionId)),
        button("Edit wording", {}, () => openWording(r.versionId))));
  }

  // ---- preview (ADM-02) ------------------------------------------------------------------------

  async function openPreview(versionId) {
    await guarded(async () => {
      setStatus("Loading preview...");
      const p = await api.get(`/admin/instrument/versions/${encodeURIComponent(versionId)}/preview`);
      const holder = el("div", { className: "admin-preview-editor" });
      openPanel(`Preview: ${p.version.versionLabel} (${STATUS_LABEL[p.version.status] || p.version.status})`,
        el("p", { className: "walk-banner admin-preview-note", text: "Preview only. This is the same form a walk on this version renders, with its conditional behavior. Nothing entered here is saved." }),
        holder);
      renderEditor(holder, {
        model: p.model,
        walk: { state: createBlankState(p.model), lockedDimensions: [] },
        policies: p.policies,
        onChange: () => {},
        announce,
      });
      setStatus(`Previewing ${p.version.versionLabel}.`);
    });
  }

  // ---- compare (ADM-06) ------------------------------------------------------------------------

  function versionOptions(selected) {
    return view.versions.map((v) => el("option", { value: v.versionId, selected: v.versionId === selected ? true : null, text: `${v.versionLabel} · ${v.instrumentCode} · ${STATUS_LABEL[v.status] || v.status}${v.isCurrent ? " · in service" : ""}` }));
  }

  /** Baseline for a candidate: the in-service version of the same instrument, else the newest other one. */
  function defaultBaseline(toId) {
    const to = versionById(toId);
    if (!to) return "";
    const same = view.versions.filter((v) => v.instrumentCode === to.instrumentCode && v.versionId !== toId);
    const current = same.find((v) => v.isCurrent);
    return (current || same[0] || to).versionId;
  }

  async function openCompare(toId, fromId = null) {
    const fromSel = el("select", { id: nextId("admin-compare-from") }, versionOptions(fromId || defaultBaseline(toId)));
    const toSel = el("select", { id: nextId("admin-compare-to") }, versionOptions(toId));
    const out = el("div", { className: "admin-compare-result", "aria-live": "polite" });
    const form = el("form", { className: "admin-compare-form", novalidate: true },
      el("div", { className: "field-grid" },
        el("div", {}, el("label", { for: fromSel.id, text: "Before (baseline)" }), fromSel),
        el("div", {}, el("label", { for: toSel.id, text: "After (candidate)" }), toSel)),
      el("div", { className: "row-actions" }, el("button", { type: "submit", className: "btn btn-primary btn-sm", text: "Compare" })));
    form.addEventListener("submit", (ev) => { ev.preventDefault(); runCompare(fromSel.value, toSel.value, out); });
    openPanel("Compare versions", form, out);
    await runCompare(fromSel.value, toSel.value, out);
  }

  async function runCompare(fromId, toId, out) {
    await guarded(async () => {
      setStatus("Comparing...");
      const r = await api.get(`/admin/instrument/compare?from=${encodeURIComponent(fromId)}&to=${encodeURIComponent(toId)}`);
      out.replaceChildren(compareResult(r));
      setStatus(r.identical ? "The two versions have identical content." : `Comparison ready: ${summaryText(r.summary)}.`);
    });
  }

  function summaryText(s) {
    return [plural(s.added, "addition", "additions"), plural(s.removed, "removal", "removals"), plural(s.changed, "change", "changes"), plural(s.metadata, "metadata difference", "metadata differences")].join(", ");
  }

  function diffTable(caption, rows) {
    return el("table", { className: "report-table admin-diff" },
      el("caption", { text: caption }),
      el("thead", {}, el("tr", {}, ["Field", "Before", "After"].map((h) => el("th", { scope: "col", text: h })))),
      el("tbody", {}, rows.map((f) => el("tr", {},
        el("th", { scope: "row", text: f.field }),
        el("td", { className: "admin-before", text: valueText(f.from) }),
        el("td", { className: "admin-after", text: valueText(f.to) })))));
  }

  function compareResult(r) {
    const head = el("p", { className: "admin-summary-title", text: `${r.from.versionLabel} → ${r.to.versionLabel}: ${r.identical ? "identical content" : summaryText(r.summary)}.` });
    if (r.identical) return el("div", {}, head);
    const parts = [head];
    if (r.metadata.length) parts.push(diffTable("Version metadata", r.metadata));
    for (const c of r.changes) {
      const title = `${COLLECTION_LABEL[c.collection] || c.collection} ${c.key}`;
      const badge = el("span", { className: `status-badge admin-change-${c.change}`, text: c.change.toUpperCase() });
      const block = el("div", { className: "admin-change", "data-change": c.change, "data-collection": c.collection, "data-key": c.key },
        el("h3", { className: "admin-change-title" }, title, badge),
        c.label ? el("p", { className: "admin-change-label", text: c.label }) : null);
      if (c.fields && c.fields.length) block.append(diffTable(`${title} fields`, c.fields));
      parts.push(block);
    }
    return el("div", {}, parts);
  }

  // ---- placeholder queue (ADM-08) --------------------------------------------------------------

  async function openPlaceholders(versionId, query = "") {
    await guarded(async () => {
      setStatus("Loading placeholder review...");
      const r = await fetchPlaceholders(versionId, query);
      const search = el("input", { type: "search", id: nextId("admin-ph-q"), value: query, maxlength: "200", placeholder: "Item key, prompt, section, source location or note" });
      const out = el("div", { className: "admin-placeholder-result" });
      const form = el("form", { className: "admin-search", role: "search", novalidate: true },
        el("label", { for: search.id, text: "Search placeholder prompts" }),
        el("div", { className: "admin-search-row" }, search, el("button", { type: "submit", className: "btn btn-sm btn-primary", text: "Search" })));
      form.addEventListener("submit", async (ev) => {
        ev.preventDefault();
        await guarded(async () => {
          const next = await fetchPlaceholders(versionId, search.value);
          out.replaceChildren(placeholderTable(next));
          setStatus(placeholderSummary(next));
        });
      });
      out.append(placeholderTable(r));
      openPanel(`Placeholder review: ${r.version.versionLabel}`,
        el("p", { className: "section-sub", text: r.editable
          ? "These prompts still carry placeholder source content. Replace a prompt and change its review status to resolve it."
          : `This version is ${STATUS_LABEL[r.version.status].toLowerCase()} and cannot change. Create a new draft from it to resolve these prompts.` }),
        form, out);
      setStatus(placeholderSummary(r));
    });
  }

  function fetchPlaceholders(versionId, query) {
    const q = String(query || "").trim();
    return api.get(`/admin/instrument/versions/${encodeURIComponent(versionId)}/placeholders${q ? `?q=${encodeURIComponent(q)}` : ""}`);
  }

  function placeholderSummary(r) {
    return r.query ? `${r.matched} of ${plural(r.total, "placeholder prompt", "placeholder prompts")} match "${r.query}".` : `${plural(r.total, "placeholder prompt", "placeholder prompts")} to review.`;
  }

  function placeholderTable(r) {
    const summary = el("p", { className: "admin-summary-title admin-ph-count", text: placeholderSummary(r) });
    if (!r.items.length) return el("div", {}, summary, el("p", { className: "muted", text: r.total ? "No placeholder prompt matches that search." : "No placeholder prompts remain in this version." }));
    const cols = ["#", "Item", "Section", "Prompt", "Source", "Notes"];
    if (r.editable) cols.push("Action");
    return el("div", {}, summary, scrollRegion("Placeholder prompts", el("table", { className: "report-table admin-ph-table" },
      el("caption", { className: "sr-only", text: "Placeholder prompts" }),
      el("thead", {}, el("tr", {}, cols.map((h) => el("th", { scope: "col", text: h })))),
      el("tbody", {}, r.items.map((it) => el("tr", { "data-item-key": it.itemKey },
        el("td", { text: it.questionNumber ?? "" }),
        el("th", { scope: "row" }, el("code", { text: it.itemKey })),
        el("td", { text: it.sectionTitle || it.sectionKey || "" }),
        el("td", { text: it.prompt }),
        el("td", { text: it.sourceLocation || "" }),
        el("td", { text: it.revisionNotes || "" }),
        r.editable ? el("td", {}, button("Edit", { "aria-label": `Edit ${it.itemKey}` }, () => openWording(r.version.versionId, it.itemKey))) : null))))));
  }

  // ---- wording editor (ADM-06, ADM-08) ---------------------------------------------------------

  async function openWording(versionId, query = "") {
    await guarded(async () => {
      setStatus("Loading wording editor...");
      const w = await fetchWording(versionId, query);
      const state = { versionId, checksum: w.version.checksum, fields: w.fields };
      const search = el("input", { type: "search", id: nextId("admin-w-q"), value: query, maxlength: "200", placeholder: "Item key, section, prompt, label or definition" });
      const out = el("div", { className: "admin-wording-result" });
      const form = el("form", { className: "admin-search", role: "search", novalidate: true },
        el("label", { for: search.id, text: "Find wording to edit" }),
        el("div", { className: "admin-search-row" }, search, el("button", { type: "submit", className: "btn btn-sm btn-primary", text: "Search" })));
      form.addEventListener("submit", async (ev) => {
        ev.preventDefault();
        await guarded(async () => {
          const next = await fetchWording(versionId, search.value);
          state.checksum = next.version.checksum;
          renderWording(out, state, next);
        });
      });
      const title = w.editable ? `Edit wording: ${w.version.versionLabel}` : `Wording: ${w.version.versionLabel} (read only)`;
      openPanel(title,
        el("p", { className: "section-sub", text: w.editable
          ? "Changes apply to this draft only. Structure (items, options, rules) is changed by importing a document."
          : "This version cannot change. Create a new draft from it to edit wording." }),
        form, out);
      renderWording(out, state, w);
      setStatus(w.query ? `${plural(w.results.length, "match", "matches")} for "${w.query}".` : "Search for the wording to edit.");
    });
  }

  function fetchWording(versionId, query) {
    const q = String(query || "").trim();
    return api.get(`/admin/instrument/versions/${encodeURIComponent(versionId)}/wording${q ? `?q=${encodeURIComponent(q)}` : ""}`);
  }

  function renderWording(out, state, w) {
    out.replaceChildren();
    out.append(entityForm(state, w, { target: "version", key: "", label: `Version ${w.version.versionLabel}`, context: "", fields: w.versionFields }));
    if (!w.query) {
      out.append(el("p", { className: "muted", text: "Search above to find a section, item or response option." }));
      return;
    }
    out.append(el("p", { className: "admin-summary-title", text: `${plural(w.results.length, "match", "matches")} for "${w.query}".` }));
    for (const entry of w.results) out.append(entityForm(state, w, entry));
  }

  function entityForm(state, w, entry) {
    const spec = state.fields[entry.target] || {};
    const controls = [];
    const titleId = nextId("admin-entity");
    const form = el("form", { className: "admin-entity", "aria-labelledby": titleId, novalidate: true, "data-target": entry.target, "data-key": entry.key },
      el("h3", { className: "admin-entity-title", id: titleId },
        `${TARGET_LABEL[entry.target] || entry.target}${entry.key ? " " : ""}`, entry.key ? el("code", { text: entry.key }) : null,
        entry.context ? el("span", { className: "muted", text: ` · ${entry.context}` }) : null));
    for (const field of Object.keys(spec)) {
      const original = entry.fields[field] ?? null;
      const id = nextId(`admin-f-${field}`);
      const attrs = { id, name: field, maxlength: String(spec[field].max), disabled: w.editable ? null : true, required: spec[field].required ? true : null };
      const control = LONG_FIELDS.has(field) ? el("textarea", { ...attrs, rows: field === "prompt" ? "3" : "2" }) : el("input", { ...attrs, type: "text" });
      control.value = original ?? "";
      controls.push({ field, control, original });
      form.append(el("div", { className: "admin-field" }, el("label", { for: id, text: `${FIELD_LABEL[field] || field}${spec[field].required ? "" : " (optional)"}` }), control));
    }
    if (w.editable) {
      const save = el("button", { type: "submit", className: "btn btn-sm btn-primary", text: "Save changes" });
      form.append(el("div", { className: "row-actions" }, save));
      form.addEventListener("submit", (ev) => { ev.preventDefault(); saveEntity(state, entry, controls, form); });
    }
    return form;
  }

  async function saveEntity(state, entry, controls, form) {
    const edits = [];
    for (const { field, control, original } of controls) {
      const value = control.value.trim();
      const before = original === null ? "" : String(original).trim();
      if (value === before) continue;
      edits.push({ target: entry.target, ...(entry.target === "version" ? {} : { key: entry.key }), field, value: value.length ? value : null });
    }
    if (!edits.length) { setStatus("Nothing changed."); return; }
    await guarded(async () => {
      setStatus("Saving...");
      let r;
      try {
        r = await api.post(`/admin/instrument/versions/${encodeURIComponent(state.versionId)}/edits`, { expectedChecksum: state.checksum, edits });
      } catch (e) {
        if (e instanceof ApiError && e.code === "DRAFT_CHANGED") {
          showError("This draft changed after you opened it, so nothing was saved. Reload it to see the current wording, then make the change again.");
          form.append(el("div", { className: "row-actions" }, button("Reload this draft", {}, () => openWording(state.versionId, entry.key))));
          setStatus("");
          return;
        }
        throw e;
      }
      state.checksum = r.checksum;
      for (const c of controls) {
        const applied = (r.applied || []).find((a) => a.target === entry.target && a.field === c.field && (entry.target === "version" || a.key === entry.key));
        if (applied) { c.original = applied.to; c.control.value = applied.to ?? ""; }
      }
      setStatus(r.changed ? `Saved ${plural((r.applied || []).length, "change", "changes")} to ${r.versionLabel}.` : "Nothing changed.");
      await loadVersions();
    }, { mutation: true });
  }

  // ---- clone (ADM-06) --------------------------------------------------------------------------

  function openClone(sourceId) {
    const source = versionById(sourceId);
    if (!source) return;
    const labelInput = el("input", { type: "text", id: nextId("admin-clone-label"), maxlength: "100", required: true, "aria-describedby": "admin-clone-hint" });
    const notes = el("textarea", { id: nextId("admin-clone-notes"), maxlength: "2000", rows: "2" });
    const form = el("form", { className: "admin-clone-form", novalidate: true },
      el("p", { className: "section-sub", id: "admin-clone-hint", text: `The new draft starts as an exact copy of ${source.versionLabel}. The version label must be new for ${source.instrumentCode}.` }),
      el("div", { className: "admin-field" }, el("label", { for: labelInput.id, text: "New version label" }), labelInput),
      el("div", { className: "admin-field" }, el("label", { for: notes.id, text: "Revision notes (optional)" }), notes),
      el("div", { className: "row-actions" }, el("button", { type: "submit", className: "btn btn-sm btn-primary", text: "Create draft" })));
    form.addEventListener("submit", async (ev) => {
      ev.preventDefault();
      if (!labelInput.value.trim()) { showError("Enter a version label for the new draft."); labelInput.focus(); return; }
      await guarded(async () => {
        setStatus("Creating draft...");
        const body = { versionLabel: labelInput.value.trim() };
        if (notes.value.trim()) body.revisionNotes = notes.value.trim();
        const r = await api.post(`/admin/instrument/versions/${encodeURIComponent(sourceId)}/clone`, body);
        setStatus(`Created draft ${r.versionLabel} from ${source.versionLabel}.`);
        await loadVersions();
        view.afterClone = r.versionId;
      }, { mutation: true });
      if (view.afterClone) {
        const id = view.afterClone;
        view.afterClone = null;
        await openWording(id);
      }
    });
    openPanel(`New draft from ${source.versionLabel}`, form);
    labelInput.focus();
  }

  // ---- publish, retire, discard ----------------------------------------------------------------

  /** An inline confirmation. Resolves true only on the explicit confirm button. */
  function confirmPanel(title, lines, confirmText, danger) {
    return new Promise((resolve) => {
      const titleId = nextId("admin-confirm-title");
      const descId = nextId("admin-confirm-desc");
      const cancel = button("Cancel", { className: "btn btn-sm" });
      const ok = button(confirmText, { className: danger ? "btn btn-sm btn-danger admin-confirm-danger" : "btn btn-sm btn-primary" });
      const box = el("div", { className: "conflict-panel admin-confirm", role: "alertdialog", "aria-labelledby": titleId, "aria-describedby": descId },
        el("h2", { className: "conflict-title", id: titleId, text: title }),
        el("div", { id: descId }, lines.map((l) => el("p", { text: l }))),
        el("div", { className: "row-actions" }, ok, cancel));
      panel.replaceChildren(box);
      panel.removeAttribute("aria-labelledby");
      panel.hidden = false;
      const finish = (answer) => { panel.replaceChildren(); panel.hidden = true; resolve(answer); };
      cancel.addEventListener("click", () => { finish(false); heading.focus(); });
      ok.addEventListener("click", () => finish(true));
      box.addEventListener("keydown", (ev) => { if (ev.key === "Escape") { finish(false); heading.focus(); } });
      reveal(cancel);
    });
  }

  async function confirmPublish(v) {
    const yes = await confirmPanel(`Publish ${v.versionLabel}?`, [
      `New walks of ${v.instrumentCode} will start on ${v.versionLabel}. Walks already started keep their own version.`,
      "Published content can never be changed. Later wording changes need a new draft.",
    ], "Publish", false);
    if (!yes) return;
    await guarded(async () => {
      setStatus(`Publishing ${v.versionLabel}...`);
      const r = await api.postEmpty(`/admin/instrument/versions/${encodeURIComponent(v.versionId)}/publish`);
      setStatus(`Published ${r.versionLabel || v.versionLabel}.`);
      await loadVersions();
    }, { mutation: true });
    heading.focus();
  }

  async function confirmDiscard(v) {
    const yes = await confirmPanel(`Discard draft ${v.versionLabel}?`, [
      "The draft and its content are deleted. This cannot be undone. The audit history keeps a record that it existed.",
    ], "Discard draft", true);
    if (!yes) return;
    await guarded(async () => {
      setStatus(`Discarding ${v.versionLabel}...`);
      await api.postEmpty(`/admin/instrument/versions/${encodeURIComponent(v.versionId)}/discard`);
      setStatus(`Discarded draft ${v.versionLabel}.`);
      await loadVersions();
    }, { mutation: true });
    heading.focus();
  }

  async function confirmRetire(v) {
    const yes = await confirmPanel(`Retire ${v.versionLabel}?`, [
      `No new walk can start on ${v.versionLabel}. ${plural(v.walkCount || 0, "existing walk", "existing walks")} keep opening, saving and rendering against it exactly as before.`,
      "Retiring cannot be undone. The version stays in the list and in reports.",
    ], "Retire version", true);
    if (!yes) return;
    let needsSecond = false;
    await guarded(async () => {
      setStatus(`Retiring ${v.versionLabel}...`);
      try {
        const r = await api.postEmpty(`/admin/instrument/versions/${encodeURIComponent(v.versionId)}/retire`);
        retired(v, r);
      } catch (e) {
        if (e instanceof ApiError && e.code === "RETIRE_LEAVES_NO_CURRENT_VERSION") { needsSecond = true; setStatus(""); return; }
        throw e;
      }
    }, { mutation: true });
    if (needsSecond) {
      const sure = await confirmPanel(`${v.versionLabel} is the only version in service`, [
        `No other published version of ${v.instrumentCode} exists. After retiring it, nobody can start a new walk of ${v.instrumentCode} until another version is published.`,
        "Existing walks are not affected.",
      ], "Retire anyway", true);
      if (sure) {
        await guarded(async () => {
          setStatus(`Retiring ${v.versionLabel}...`);
          const r = await api.post(`/admin/instrument/versions/${encodeURIComponent(v.versionId)}/retire`, { allowNoCurrentVersion: true });
          retired(v, r);
        }, { mutation: true });
      }
    }
    await loadVersions().catch(() => {});
    heading.focus();
  }

  function retired(v, r) {
    const next = r.successorVersionLabel ? ` New walks now start on ${r.successorVersionLabel}.` : " No version of this instrument is in service now.";
    setStatus(`Retired ${v.versionLabel}.${next}`);
  }

  // ---- lifecycle -------------------------------------------------------------------------------

  function bind() {
    if (view.bound) return;
    view.bound = true;
    importForm.addEventListener("submit", onImport);
  }

  async function show() {
    bind();
    heading.focus();
    await guarded(async () => {
      setStatus("Loading versions...");
      await loadVersions();
      setStatus("");
    });
  }

  return { show };
}
