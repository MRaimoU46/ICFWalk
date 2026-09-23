/**
 * Aggregate reports view (Phase 7). Reads only the report routes:
 *
 *   GET /api/reports/options        versions, the caller's report scope, and what the selected
 *                                   version lets a report filter by
 *   GET /api/reports/aggregate      the report (JSON)
 *   GET /api/reports/aggregate.csv  the same report as a download
 *
 * Every filter is re-validated and every scope decision is made on the server; this module only
 * builds a query string. It never receives, and so can never show, an individual walk: the report
 * payload carries counts and scores keyed by codes, and there is nothing to drill into.
 *
 * Every value from the server reaches the page through textContent or an attribute set by the DOM
 * API -- never innerHTML -- so instrument wording and org unit names are always text.
 */

const STATE_LABELS = { ANSWERED: "Answered", UNANSWERED: "Not answered", NOT_APPLICABLE: "Not applicable", HIDDEN: "Hidden" };
const ALL = "";

function el(tag, attrs = {}, ...children) {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (v === null || v === undefined || v === false) continue;
    if (k === "className") node.className = v;
    else if (k === "text") node.textContent = v;
    else node.setAttribute(k, v === true ? "" : String(v));
  }
  for (const child of children) {
    if (child === null || child === undefined || child === false) continue;
    node.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }
  return node;
}

function formatNumber(n) {
  if (n === null || n === undefined) return "—";
  return Number.isInteger(n) ? n.toLocaleString("en-US") : n.toLocaleString("en-US", { maximumFractionDigits: 2 });
}

function plural(n, one, many) { return `${formatNumber(n)} ${n === 1 ? one : many}`; }

export function mountReports({ api, apiBase }) {
  const $ = (id) => document.getElementById(id);
  const view = { options: null, loaded: false, running: false, last: null };

  const form = $("report-form");
  const filters = $("report-filters");
  const status = $("report-status");
  const error = $("report-error");
  const results = $("report-results");
  const download = $("report-download");

  function setStatus(text) { status.textContent = text; }
  function showError(text) {
    error.textContent = text;
    error.hidden = !text;
  }

  // ---- filters ----------------------------------------------------------------------------------

  function field(id, labelText, control) {
    control.id = id;
    return el("div", { className: "report-field" }, el("label", { for: id, text: labelText }), control);
  }

  function select(options, selected = ALL) {
    const s = el("select");
    for (const o of options) {
      const opt = el("option", { value: o.value, text: o.label, title: o.title || null });
      if (o.value === selected) opt.selected = true;
      s.append(opt);
    }
    return s;
  }

  function shorten(text, max = 90) {
    const t = String(text || "");
    return t.length > max ? `${t.slice(0, max - 1)}…` : t;
  }

  function itemLabel(item, sections) {
    const section = sections.find((s) => s.sectionKey === item.sectionKey);
    const number = item.questionNumber ? `${item.questionNumber}. ` : "";
    return `${section ? `${section.title} — ` : ""}${number}${item.prompt}`;
  }

  /** Current values of every control, by name; used to keep choices across a version change. */
  function currentValues() {
    const out = {};
    for (const control of filters.querySelectorAll("select, input")) {
      out[control.id] = control.type === "checkbox" ? control.checked : control.value;
    }
    return out;
  }

  function buildFilters(opts, keep = {}) {
    filters.replaceChildren();
    const versions = opts.versions.map((v) => ({ value: v.versionId, label: `${v.versionLabel} (${v.status.toLowerCase()}${v.isCurrent ? ", current" : ""})` }));
    const version = select(versions, opts.version.versionId);
    version.addEventListener("change", () => changeVersion(version.value));
    filters.append(field("rf-version", "Instrument version", version));

    const units = [{ value: ALL, label: "All schools I can report on" }, ...opts.orgUnits.map((u) => ({ value: u.orgUnitId, label: u.type === "SCHOOL" ? u.name : `${u.name} (${u.type.toLowerCase()})` }))];
    filters.append(field("rf-org", "School", select(units, keep["rf-org"] ?? ALL)));

    const from = el("input", { type: "date" });
    from.value = keep["rf-from"] ?? "";
    const to = el("input", { type: "date" });
    to.value = keep["rf-to"] ?? "";
    filters.append(field("rf-from", "Observed from", from), field("rf-to", "Observed to", to));

    for (const d of opts.dimensions) {
      const choices = [{ value: ALL, label: "Any" }, ...d.values.map((v) => ({ value: v.code, label: v.label }))];
      const id = `rf-dim-${d.code}`;
      const keepValue = d.values.some((v) => v.code === keep[id]) ? keep[id] : ALL;
      filters.append(field(id, d.label, select(choices, keepValue)));
    }

    const sectionChoices = [{ value: ALL, label: "All sections" }, ...opts.sections.filter((s) => s.depth > 0).map((s) => ({ value: s.sectionKey, label: `${"— ".repeat(Math.max(0, s.depth - 1))}${s.title}` }))];
    const sectionSelect = select(sectionChoices, opts.sections.some((s) => s.sectionKey === keep["rf-section"]) ? keep["rf-section"] : ALL);
    filters.append(field("rf-section", "Section", sectionSelect));

    const itemChoices = [{ value: ALL, label: "All questions" }, ...opts.items.map((i) => ({ value: i.itemKey, label: shorten(itemLabel(i, opts.sections)), title: itemLabel(i, opts.sections) }))];
    const itemSelect = select(itemChoices, opts.items.some((i) => i.itemKey === keep["rf-item"]) ? keep["rf-item"] : ALL);
    filters.append(field("rf-item", "Question", itemSelect));

    // Only walks that gave one answer to one question.
    const answerItem = select([{ value: ALL, label: "No answer filter" }, ...itemChoices.slice(1)], opts.items.some((i) => i.itemKey === keep["rf-answer-item"]) ? keep["rf-answer-item"] : ALL);
    const answer = select([{ value: ALL, label: "Choose a question first" }]);
    const syncAnswers = (selected = ALL) => {
      const item = opts.items.find((i) => i.itemKey === answerItem.value);
      answer.replaceChildren();
      if (!item) {
        answer.append(el("option", { value: ALL, text: "Choose a question first" }));
        answer.disabled = true;
        return;
      }
      answer.disabled = false;
      for (const o of item.options) {
        const opt = el("option", { value: o.code, text: o.label });
        if (o.code === selected) opt.selected = true;
        answer.append(opt);
      }
    };
    answerItem.addEventListener("change", () => syncAnswers());
    filters.append(field("rf-answer-item", "Only walks that answered", answerItem), field("rf-answer", "With the answer", answer));
    syncAnswers(keep["rf-answer"] ?? ALL);

    const drafts = el("input", { type: "checkbox" });
    drafts.checked = Boolean(keep["rf-drafts"]);
    drafts.id = "rf-drafts";
    filters.append(el("div", { className: "report-field report-check" }, drafts, el("label", { for: "rf-drafts", text: "Include walks still in draft" })));

    const note = $("report-scope-note");
    const threshold = opts.suppression && opts.suppression.threshold;
    note.textContent = threshold
      ? `Groups of fewer than ${threshold} walks are withheld. Individual walks are never shown.`
      : "Individual walks are never shown.";
    updateDownload();
  }

  /** The query string the server receives. Empty filters are simply absent. */
  function query() {
    const params = new URLSearchParams();
    const value = (id) => { const c = $(id); return c && !c.disabled ? c.value : ""; };
    if (value("rf-version")) params.set("versionId", value("rf-version"));
    if (value("rf-org")) params.set("orgUnitId", value("rf-org"));
    if (value("rf-from")) params.set("from", value("rf-from"));
    if (value("rf-to")) params.set("to", value("rf-to"));
    for (const d of view.options ? view.options.dimensions : []) {
      const v = value(`rf-dim-${d.code}`);
      if (v) params.set(`dim_${d.code}`, v);
    }
    if (value("rf-section")) params.set("section", value("rf-section"));
    if (value("rf-item")) params.set("item", value("rf-item"));
    if (value("rf-answer-item") && value("rf-answer")) {
      params.set("optionItem", value("rf-answer-item"));
      params.set("option", value("rf-answer"));
    }
    if ($("rf-drafts") && $("rf-drafts").checked) params.set("includeDrafts", "true");
    return params.toString();
  }

  function updateDownload() {
    const qs = query();
    download.href = `${apiBase}/reports/aggregate.csv${qs ? `?${qs}` : ""}`;
  }

  async function loadOptions(versionId = "") {
    const opts = await api.get(`/reports/options${versionId ? `?versionId=${encodeURIComponent(versionId)}` : ""}`);
    view.options = opts;
    return opts;
  }

  async function changeVersion(versionId) {
    const keep = currentValues();
    try {
      setStatus("Loading the selected version…");
      const opts = await loadOptions(versionId);
      buildFilters(opts, keep);
      // Results on screen belong to the previous version; never leave them looking current.
      results.replaceChildren();
      setStatus(`Filters updated for ${opts.version.versionLabel}. Run the report to see its results.`);
      showError("");
    } catch (e) {
      showError(describe(e, "Could not load that instrument version"));
      setStatus("");
    }
  }

  function describe(e, lead) {
    if (e && e.status === 401) return "Sign-in required. Please sign in through the district portal and reload.";
    if (e && e.code && e.code !== "NETWORK_ERROR") return `${lead}: ${e.message} (${e.code})`;
    return `${lead}: the server could not be reached.`;
  }

  // ---- results ----------------------------------------------------------------------------------

  function card(title, id, ...children) {
    return el("section", { className: "section-card report-card", "aria-labelledby": id }, el("h2", { className: "section-title", id, text: title }), ...children);
  }

  function table(caption, headers, rows, { className = "report-table" } = {}) {
    const t = el("table", { className });
    t.append(el("caption", { text: caption }));
    const head = el("tr");
    headers.forEach((h, i) => head.append(el("th", { scope: "col", className: i ? "num" : null, text: h })));
    t.append(el("thead", {}, head));
    const body = el("tbody");
    for (const row of rows) {
      const tr = el("tr");
      row.forEach((cell, i) => tr.append(i === 0 ? el("th", { scope: "row", text: cell }) : el("td", { className: "num", text: cell })));
      body.append(tr);
    }
    t.append(body);
    // Two columns whose text wraps: a table here never needs to scroll sideways, so it is not
    // wrapped in a scrolling region (which would add a tab stop per table).
    return t;
  }

  function populationCard(r) {
    const p = r.population;
    const lines = [];
    if (p.suppressed) {
      lines.push(el("p", { className: "report-suppressed", text: `Fewer than ${r.suppression.threshold} walks match these filters, so the results are withheld.` }));
    } else {
      const parts = Object.entries(p.byStatus).map(([s, n]) => `${s === "COMPLETED" ? "completed" : s.toLowerCase()}: ${formatNumber(n)}`);
      lines.push(el("p", { className: "report-total" }, el("strong", { text: plural(p.walks, "walk", "walks") }), parts.length ? ` (${parts.join(", ")})` : ""));
    }
    lines.push(el("p", { className: "muted report-meta", text: `Instrument version ${r.version.versionLabel}. ${r.filters.includeDrafts ? "Completed and draft walks." : "Completed walks only."}` }));
    return card("Walks in this report", "rr-population", ...lines);
  }

  function schoolsCard(r) {
    if (!r.orgUnits.length) return null;
    const rows = r.orgUnits.map((u) => [u.name, u.suppressed ? "Withheld" : formatNumber(u.walks)]);
    return card("Schools", "rr-schools", table("Walks by school", ["School", "Walks"], rows));
  }

  function dimensionsCard(r) {
    if (!r.dimensions.length) return null;
    const blocks = r.dimensions.map((d) => {
      const rows = d.values.filter((v) => v.suppressed || v.walks > 0).map((v) => [v.label, v.suppressed ? "Withheld" : formatNumber(v.walks)]);
      const notes = [];
      if (d.states.UNANSWERED) notes.push(`${STATE_LABELS.UNANSWERED}: ${formatNumber(d.states.UNANSWERED)}`);
      if (d.states.HIDDEN) notes.push(`${STATE_LABELS.HIDDEN}: ${formatNumber(d.states.HIDDEN)}`);
      return el("div", { className: "report-dimension", "data-dimension": d.code },
        rows.length ? table(d.label, [d.label, "Walks"], rows) : el("p", { className: "muted", text: `${d.label}: no answers.` }),
        notes.length ? el("p", { className: "muted report-states", text: notes.join(" · ") }) : null);
    });
    return card("Visit information", "rr-dimensions", el("div", { className: "report-dimensions" }, ...blocks));
  }

  function itemBlock(item, level = "h4") {
    const s = item.states;
    const heading = `${item.questionNumber ? `${item.questionNumber}. ` : ""}${item.prompt}`;
    const summary = [];
    if (item.scored) {
      summary.push(item.scored.responses
        ? `Average ${formatNumber(item.scored.mean)} from ${plural(item.scored.responses, "rated response", "rated responses")}`
        : "No rated responses");
    }
    const counts = ["ANSWERED", "UNANSWERED", "NOT_APPLICABLE", "HIDDEN"].map((k) => `${STATE_LABELS[k]}: ${formatNumber(s[k])}`);
    if (s.UNRECORDED) counts.push(`No record: ${formatNumber(s.UNRECORDED)}`);
    const rows = item.options.map((o) => [o.label, formatNumber(o.count)]);
    return el("article", { className: "report-item", "data-item-key": item.itemKey },
      el(level, { className: "report-q", text: heading }),
      summary.length ? el("p", { className: "report-avg", text: summary.join(" ") }) : null,
      el("p", { className: "muted report-states", text: counts.join(" · ") }),
      table(`Answers to: ${heading}`, ["Answer", "Responses"], rows, { className: "report-table report-dist" }));
  }

  function questionsCard(r) {
    if (!r.items.length) return null;
    const byKey = new Map(r.items.map((i) => [i.itemKey, i]));
    const blocks = [];
    for (const s of r.sections) {
      if (s.depth === 0) continue;
      const own = s.itemKeys.map((k) => byKey.get(k)).filter(Boolean);
      const headingLevel = s.depth === 1 ? "h3" : "h4";
      const header = el("div", { className: "report-section-head" },
        el(headingLevel, { className: "report-section-title", text: s.title }),
        s.scored && s.scored.responses
          ? el("p", { className: "report-avg", text: `Average of all rated responses: ${formatNumber(s.scored.mean)} (${plural(s.scored.responses, "response", "responses")})` })
          : null);
      const itemLevel = s.depth === 1 ? "h4" : "h5";
      blocks.push(el("div", { className: `report-section depth-${Math.min(s.depth, 3)}`, "data-section-key": s.sectionKey }, header, ...own.map((i) => itemBlock(i, itemLevel))));
    }
    return card("Questions", "rr-questions",
      el("p", { className: "muted report-meta", text: "Averages use answered ratings only. Unanswered, not applicable, and hidden responses are counted separately and never treated as zero." }),
      ...blocks);
  }

  function render(r) {
    results.replaceChildren(...[populationCard(r), ...(r.population.suppressed ? [] : [schoolsCard(r), dimensionsCard(r), questionsCard(r)])].filter(Boolean));
  }

  async function run() {
    if (view.running) return;
    view.running = true;
    // The Run button stays enabled (disabling the focused control would drop keyboard focus); a
    // second press while a report is running is simply ignored, and the results say they are busy.
    results.setAttribute("aria-busy", "true");
    showError("");
    setStatus("Running the report…");
    updateDownload();
    try {
      const qs = query();
      const r = await api.get(`/reports/aggregate${qs ? `?${qs}` : ""}`);
      view.last = r;
      render(r);
      setStatus(r.population.suppressed ? "Report updated. Results are withheld for this selection." : `Report updated: ${plural(r.population.walks, "walk", "walks")}.`);
    } catch (e) {
      results.replaceChildren();
      showError(describe(e, "The report could not be produced"));
      setStatus("");
    } finally {
      view.running = false;
      results.removeAttribute("aria-busy");
    }
  }

  function wire() {
    if (view.wired) return;
    view.wired = true;
    form.addEventListener("submit", (ev) => { ev.preventDefault(); run(); });
    form.addEventListener("change", updateDownload);
    $("report-reset").addEventListener("click", async () => {
      if (!view.options) return;
      buildFilters(view.options, {});
      await run();
    });
  }

  async function show() {
    if (view.loaded) return;
    view.loaded = true;
    wire();
    try {
      setStatus("Loading report options…");
      buildFilters(await loadOptions());
      await run();
    } catch (e) {
      view.loaded = false;
      showError(describe(e, "Reports are not available"));
      setStatus("");
    }
  }

  return { show };
}
