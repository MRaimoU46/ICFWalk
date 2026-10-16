/**
 * Aggregate reports view (Phase 7). Reads only the report routes:
 *
 *   GET /api/reports/options        versions, the caller's report scope, and what the selected
 *                                   version lets a report filter by
 *   GET /api/reports/aggregate      the report (JSON)
 *   GET /api/reports/aggregate.csv  the same report as a download
 *
 *   POST /api/reports/releases      release dates for report-only users (only when the options
 *                                   say the caller may)
 *
 * Every filter is re-validated and every scope decision is made on the server; this module only
 * builds a query string. It never receives, and so can never show, an individual walk: the report
 * payload carries counts and scores keyed by codes, and there is nothing to drill into.
 *
 * LIVE OR RELEASED (RPT-03 correction). The "Data" control offers current data only when the
 * server says the caller may have it (options.disclosure.liveAvailable: they can open every walk
 * in their scope), and otherwise only released dates. A released report takes the version, network,
 * school, section and question, so those are the only filters shown for it. The server withholds
 * small figures before it answers: a withheld figure arrives as null and is shown as "Withheld"; a
 * figure of which only part could be released arrives with `withheld: true` and is shown as "At
 * least N". There is no withheld value in the page to reveal.
 *
 * SEVERAL VALUES (owner's decisions 2026-10-16). Network, School and every visit field take several
 * values: a walk matches any value of a filter, and every filter together. The School list narrows to
 * the chosen networks. In a live report a Section or Question counts only the walks where it was
 * shown; a released report keeps counting every released walk, and the page says which applies.
 *
 * Every value from the server reaches the page through textContent or an attribute set by the DOM
 * API -- never innerHTML -- so instrument wording and org unit names are always text.
 */

const STATE_LABELS = { ANSWERED: "Answered", UNANSWERED: "Not answered", NOT_APPLICABLE: "Not applicable", HIDDEN: "Hidden" };
// The same words the CSV carries (ReportService MULTIPLE_VALUES_NOTE).
const MULTIPLE_VALUES_NOTE = "A walk can be counted under more than one value, so these counts can add up to more than the number of walks.";
const ALL = "";
const LIVE = "live";

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

/** A released figure: null is withheld; withheld with a number is the part that could be released. */
function figure(count, withheld) {
  if (count === null || count === undefined) return withheld ? "Withheld" : "—";
  return withheld ? `At least ${formatNumber(count)}` : formatNumber(count);
}

/** Where the report comes from: current data when the server allows it, then every release. */
function sources(opts) {
  const out = [];
  if (opts.disclosure && opts.disclosure.liveAvailable) out.push({ value: LIVE, label: "Current data" });
  for (const r of opts.releases || []) out.push({ value: r.releaseId, label: `Released: walks observed ${r.observedFrom} to ${r.observedTo}` });
  return out;
}

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
    for (const control of filters.querySelectorAll("select, input:not([data-multi])")) {
      out[control.id] = control.type === "checkbox" ? control.checked : control.value;
    }
    for (const m of filters.querySelectorAll("details.multi-select")) out[m.id] = picked(m.id);
    return out;
  }

  /** The values ticked in one multi-select, in its order. */
  function picked(id) {
    const m = $(id);
    return m ? [...m.querySelectorAll("input[type=checkbox]:checked")].map((c) => c.value) : [];
  }

  /**
   * A filter that takes several values: a disclosure holding one checkbox per value, like the
   * editor's checkbox fields. Its summary says what is chosen (the "none" text, up to two names, or
   * how many) and is named by the field's label. Enter or Space opens it, Tab moves through the
   * values, Space ticks one, and Escape closes it; opening one closes the others.
   */
  function multiSelect(id, labelText, options, selected = [], noneText = "Any") {
    const labelId = `${id}-label`;
    const text = el("span", { id: `${id}-text`, className: "multi-text" });
    const summary = el("summary", { className: "multi-summary", "aria-labelledby": `${labelId} ${id}-text` }, text);
    const list = el("fieldset", { className: "multi-options" }, el("legend", { className: "sr-only", text: labelText }));
    options.forEach((o, i) => {
      const box = el("input", { type: "checkbox", id: `${id}-o${i}`, value: o.value, "data-multi": "true" });
      box.checked = selected.includes(o.value);
      list.append(el("label", { className: "multi-option", for: box.id }, box, el("span", { text: o.label })));
    });
    const details = el("details", { className: "multi-select", id }, summary, list);
    const sync = () => {
      const names = [...list.querySelectorAll("input:checked")].map((c) => c.nextElementSibling.textContent);
      text.textContent = !names.length ? noneText : names.length <= 2 ? names.join(", ") : `${names.length} selected`;
    };
    list.addEventListener("change", sync);
    details.addEventListener("keydown", (ev) => {
      if (ev.key !== "Escape" || !details.open) return;
      ev.preventDefault();
      details.open = false;
      summary.focus();
    });
    details.addEventListener("toggle", () => {
      if (!details.open) return;
      for (const other of filters.querySelectorAll("details.multi-select[open]")) if (other !== details) other.open = false;
    });
    sync();
    return el("div", { className: "report-field report-multi" }, el("span", { className: "multi-label", id: labelId, text: labelText }), details);
  }

  /**
   * Network and School. Networks are the NETWORK units the caller covers; the School list is every
   * other unit below a district, narrowed to the chosen networks. A report names the chosen schools,
   * or else the chosen networks (query()), so the two narrow together.
   */
  function appendUnitFilters(opts, keep) {
    const parentOf = new Map(opts.orgUnits.map((u) => [u.orgUnitId, u.parentOrgUnitId]));
    const within = (id, ancestors) => {
      for (let p = parentOf.get(id); p; p = parentOf.get(p)) if (ancestors.includes(p)) return true;
      return false;
    };
    const networks = opts.orgUnits.filter((u) => u.type === "NETWORK");
    const schools = opts.orgUnits.filter((u) => u.type !== "NETWORK" && u.type !== "DISTRICT");
    const label = (u) => (u.type === "SCHOOL" ? u.name : `${u.name} (${u.type.toLowerCase()})`);
    if (networks.length) {
      const kept = (keep["rf-network"] || []).filter((id) => networks.some((u) => u.orgUnitId === id));
      filters.append(multiSelect("rf-network", "Network", networks.map((u) => ({ value: u.orgUnitId, label: u.name })), kept, "All networks"));
    }
    const schoolField = () => {
      const chosen = picked("rf-network");
      const offered = chosen.length ? schools.filter((u) => within(u.orgUnitId, chosen)) : schools;
      const previous = $("rf-org") ? picked("rf-org") : (keep["rf-org"] || []);
      const kept = previous.filter((id) => offered.some((u) => u.orgUnitId === id));
      return multiSelect("rf-org", "School", offered.map((u) => ({ value: u.orgUnitId, label: label(u) })), kept, "All schools I can report on");
    };
    let current = schoolField();
    filters.append(current);
    if (networks.length) {
      $("rf-network").addEventListener("change", () => {
        const next = schoolField();
        current.replaceWith(next);
        current = next;
        updateDownload();
      });
    }
  }

  /** The release the "Data" control names, or null for current data. */
  function selectedRelease() {
    const c = $("rf-source");
    if (!c || !view.options || c.value === LIVE) return null;
    return (view.options.releases || []).find((r) => r.releaseId === c.value) || null;
  }

  function buildFilters(opts, keep = {}) {
    filters.replaceChildren();
    const choices = sources(opts);
    if (!choices.length) {
      $("report-scope-note").textContent = "No reporting dates have been released yet. Individual walks are never shown.";
      updateDownload();
      return;
    }
    const chosen = choices.some((c) => c.value === keep["rf-source"]) ? keep["rf-source"] : choices[0].value;
    const source = select(choices, chosen);
    source.addEventListener("change", () => {
      buildFilters(view.options, currentValues());
      // Results on screen came from the other source; never leave them looking current.
      results.replaceChildren();
      setStatus("Data changed. Run the report to see its results.");
    });
    filters.append(field("rf-source", "Data", source));
    const release = chosen === LIVE ? null : (opts.releases || []).find((r) => r.releaseId === chosen);

    // A release holds some versions for this scope: offer those, plus the version these options were
    // loaded for, so the section and question lists below always belong to the selected version
    // (choosing another reloads the options for it).
    const offered = release ? opts.versions.filter((v) => v.versionId === opts.version.versionId || release.versionIds.includes(v.versionId)) : opts.versions;
    const versions = offered.map((v) => ({ value: v.versionId, label: `${v.versionLabel} (${v.status.toLowerCase()}${v.isCurrent ? ", current" : ""})` }));
    const version = select(versions, opts.version.versionId);
    version.addEventListener("change", () => changeVersion(version.value));
    filters.append(field("rf-version", "Instrument version", version));

    appendUnitFilters(opts, keep);

    const note = $("report-scope-note");
    if (release) {
      note.textContent = `Released results. Groups of fewer than ${release.minimumWalks} walks are never released, and small counts are withheld. Individual walks are never shown.`;
      appendContentFilters(opts, keep);
      updateDownload();
      return;
    }
    note.textContent = "Individual walks are never shown.";

    const from = el("input", { type: "date" });
    from.value = keep["rf-from"] ?? "";
    const to = el("input", { type: "date" });
    to.value = keep["rf-to"] ?? "";
    filters.append(field("rf-from", "Observed from", from), field("rf-to", "Observed to", to));

    for (const d of opts.dimensions) {
      const id = `rf-dim-${d.code}`;
      const kept = (keep[id] || []).filter((code) => d.values.some((v) => v.code === code));
      filters.append(multiSelect(id, d.label, d.values.map((v) => ({ value: v.code, label: v.label })), kept));
    }

    const itemChoices = appendContentFilters(opts, keep);

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
    updateDownload();
  }

  /**
   * Section and question: which questions a report shows, and in a live report also which walks it
   * counts (those where the section or question was shown). Both kinds of report take them.
   */
  function appendContentFilters(opts, keep) {
    const sectionChoices = [{ value: ALL, label: "All sections" }, ...opts.sections.filter((s) => s.depth > 0).map((s) => ({ value: s.sectionKey, label: `${"— ".repeat(Math.max(0, s.depth - 1))}${s.title}` }))];
    const sectionSelect = select(sectionChoices, opts.sections.some((s) => s.sectionKey === keep["rf-section"]) ? keep["rf-section"] : ALL);
    filters.append(field("rf-section", "Section", sectionSelect));

    const itemChoices = [{ value: ALL, label: "All questions" }, ...opts.items.map((i) => ({ value: i.itemKey, label: shorten(itemLabel(i, opts.sections)), title: itemLabel(i, opts.sections) }))];
    const itemSelect = select(itemChoices, opts.items.some((i) => i.itemKey === keep["rf-item"]) ? keep["rf-item"] : ALL);
    filters.append(field("rf-item", "Question", itemSelect));
    return itemChoices;
  }

  /** The query string the server receives. Empty filters are simply absent. */
  function query() {
    const params = new URLSearchParams();
    const value = (id) => { const c = $(id); return c && !c.disabled ? c.value : ""; };
    const release = selectedRelease();
    if (release) params.set("releaseId", release.releaseId);
    if (value("rf-version")) params.set("versionId", value("rf-version"));
    // A filter with several values is one comma-separated list. The chosen schools, or else the
    // chosen networks: the School list only offers schools in the chosen networks.
    const schools = picked("rf-org");
    const units = schools.length ? schools : picked("rf-network");
    if (units.length) params.set("orgUnitId", units.join(","));
    if (value("rf-from")) params.set("from", value("rf-from"));
    if (value("rf-to")) params.set("to", value("rf-to"));
    for (const d of view.options ? view.options.dimensions : []) {
      const values = picked(`rf-dim-${d.code}`);
      if (values.length) params.set(`dim_${d.code}`, values.join(","));
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
    if (p.withheld) {
      lines.push(el("p", { className: "report-suppressed", text: `Nothing is released for this selection: groups of fewer than ${r.disclosure.minimumWalks} walks are never released.` }));
    } else {
      const parts = Object.entries(p.byStatus).map(([s, n]) => `${s === "COMPLETED" ? "completed" : s.toLowerCase()}: ${formatNumber(n)}`);
      lines.push(el("p", { className: "report-total" }, el("strong", { text: plural(p.walks, "walk", "walks") }), parts.length ? ` (${parts.join(", ")})` : ""));
    }
    const origin = r.release ? `Released walks observed ${r.release.observedFrom} to ${r.release.observedTo}. ` : "";
    lines.push(el("p", { className: "muted report-meta", text: `${origin}Instrument version ${r.version.versionLabel}. ${r.filters.includeDrafts ? "Completed and draft walks." : "Completed walks only."}` }));
    if (r.release && !p.withheld) {
      lines.push(el("p", { className: "muted report-meta", text: `Counts below ${r.disclosure.minimumWalks}, and counts that would reveal them, are withheld. "At least" marks a figure of which only part could be released.` }));
    }
    const counted = narrowingNote(r);
    if (counted) lines.push(el("p", { className: "muted report-meta report-counted", text: counted }));
    return card("Walks in this report", "rr-population", ...lines);
  }

  /** How a chosen Section or Question counted walks, or "" when it did not change who is counted. */
  function narrowingNote(r) {
    const f = r.filters || {};
    if (!f.walksWhereShown) {
      return r.mode === "RELEASE" && (f.section || f.item) ? "Released figures count every released walk. Section and Question only choose which questions are shown." : "";
    }
    const opts = view.options || { sections: [], items: [] };
    if (f.item) {
      const item = opts.items.find((i) => i.itemKey === f.item);
      return `Counting only walks where the question ${item ? `"${shorten(item.prompt, 80)}"` : "you chose"} was shown.`;
    }
    const section = opts.sections.find((s) => s.sectionKey === f.section);
    return `Counting only walks where ${section ? section.title : "the section you chose"} was shown.`;
  }

  function schoolsCard(r) {
    if (!r.orgUnits.length) return null;
    const rows = r.orgUnits.map((u) => [u.name, formatNumber(u.walks)]);
    return card("Schools", "rr-schools", table("Walks by school", ["School", "Walks"], rows));
  }

  function dimensionsCard(r) {
    if (!r.dimensions.length) return null;
    const blocks = r.dimensions.map((d) => {
      const rows = d.values.filter((v) => v.withheld || v.walks > 0).map((v) => [v.label, figure(v.walks, v.withheld)]);
      const notes = [];
      for (const k of ["UNANSWERED", "HIDDEN"]) {
        const withheld = d.withheldStates.includes(k);
        if (withheld || d.states[k]) notes.push(`${STATE_LABELS[k]}: ${figure(d.states[k], withheld)}`);
      }
      if (d.withheldResponses) notes.push(`Withheld: ${formatNumber(d.withheldResponses)}`);
      // A field a walk may hold several values of counts the walk under each (the owner's rule), so
      // its rows can add up to more than the walks; the report says so, and how many walks it covers.
      // The sentence sits under the field's own table, so it does not repeat the label, which may not
      // read as a noun ("Visit occurred at the:").
      const several = d.multiple
        ? el("p", { className: "muted report-multiple", text: `${MULTIPLE_VALUES_NOTE} Walks with at least one value: ${figure(d.states.ANSWERED, d.withheldStates.includes("ANSWERED"))}.` })
        : null;
      return el("div", { className: "report-dimension", "data-dimension": d.code },
        rows.length ? table(d.label, [d.label, "Walks"], rows) : el("p", { className: "muted", text: `${d.label}: no answers.` }),
        several,
        notes.length ? el("p", { className: "muted report-states", text: notes.join(" · ") }) : null);
    });
    return card("Visit information", "rr-dimensions", el("div", { className: "report-dimensions" }, ...blocks));
  }

  /** An average line, or null: withheld on too few released ratings, marked when some ratings are withheld. */
  function averageText(scored, lead) {
    if (!scored) return null;
    if (scored.responses === null) return `${lead} withheld: too few ratings could be released.`;
    if (!scored.responses) return "No rated responses";
    const text = `${lead} ${formatNumber(scored.mean)} from ${plural(scored.responses, "rated response", "rated responses")}`;
    return scored.withheld ? `${text} (released ratings only; some are withheld)` : text;
  }

  function itemBlock(item, level = "h4") {
    const s = item.states;
    const heading = `${item.questionNumber ? `${item.questionNumber}. ` : ""}${item.prompt}`;
    const summary = [];
    const average = averageText(item.scored, "Average");
    if (average) summary.push(average);
    const counts = ["ANSWERED", "UNANSWERED", "NOT_APPLICABLE", "HIDDEN"].map((k) => `${STATE_LABELS[k]}: ${figure(s[k], item.withheldStates.includes(k))}`);
    if (s.UNRECORDED || item.withheldStates.includes("UNRECORDED")) counts.push(`No record: ${figure(s.UNRECORDED, item.withheldStates.includes("UNRECORDED"))}`);
    if (item.withheldResponses) counts.push(`Withheld: ${formatNumber(item.withheldResponses)}`);
    const rows = item.options.map((o) => [o.label, figure(o.count, o.withheld)]);
    return el("article", { className: "report-item", "data-item-key": item.itemKey },
      el(level, { className: "report-q", text: heading }),
      summary.length ? el("p", { className: "report-avg", text: summary.join(" ") }) : null,
      el("p", { className: "muted report-states", text: counts.join(" · ") }),
      table(`Answers to: ${heading}`, ["Answer", "Responses"], rows, { className: "report-table report-dist" }));
  }

  function sectionAverage(scored) {
    if (!scored) return null;
    if (scored.responses === null) return el("p", { className: "report-avg", text: "Average of all rated responses withheld: too few ratings could be released." });
    if (!scored.responses) return null;
    const text = `Average of all rated responses: ${formatNumber(scored.mean)} (${plural(scored.responses, "response", "responses")})`;
    return el("p", { className: "report-avg", text: scored.withheld ? `${text}, released ratings only` : text });
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
        sectionAverage(s.scored));
      const itemLevel = s.depth === 1 ? "h4" : "h5";
      blocks.push(el("div", { className: `report-section depth-${Math.min(s.depth, 3)}`, "data-section-key": s.sectionKey }, header, ...own.map((i) => itemBlock(i, itemLevel))));
    }
    return card("Questions", "rr-questions",
      el("p", { className: "muted report-meta", text: "Averages use answered ratings only. Unanswered, not applicable, and hidden responses are counted separately and never treated as zero." }),
      ...blocks);
  }

  function render(r) {
    results.replaceChildren(...[populationCard(r), ...(r.population.withheld ? [] : [schoolsCard(r), dimensionsCard(r), questionsCard(r)])].filter(Boolean));
  }

  async function run() {
    if (view.running) return;
    if (!$("rf-source")) {
      setStatus("No reporting dates have been released yet.");
      return;
    }
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
      setStatus(r.population.withheld ? "Report updated. Results are withheld for this selection." : `Report updated: ${plural(r.population.walks, "walk", "walks")}.`);
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
    // A click outside an open multi-select closes it, as a native select's list closes.
    document.addEventListener("click", (ev) => {
      for (const open of filters.querySelectorAll("details.multi-select[open]")) if (!open.contains(ev.target)) open.open = false;
    });
    $("report-reset").addEventListener("click", async () => {
      if (!view.options) return;
      // Clearing filters keeps the chosen data: it is not a filter.
      const source = $("rf-source");
      buildFilters(view.options, source ? { "rf-source": source.value } : {});
      await run();
    });
    $("release-form").addEventListener("submit", (ev) => { ev.preventDefault(); createRelease(); });
  }

  /** Releases the chosen dates, then offers the new release and shows it. */
  async function createRelease() {
    if (view.running) return;
    const observedFrom = $("release-from").value;
    const observedTo = $("release-to").value;
    showError("");
    setStatus("Releasing…");
    try {
      const out = await api.post("/reports/releases", { observedFrom, observedTo });
      const opts = await loadOptions($("rf-version") ? $("rf-version").value : "");
      buildFilters(opts, { ...currentValues(), "rf-source": out.release.releaseId });
      $("release-form").hidden = !opts.canRelease;
      setStatus(`Released walks observed ${out.release.observedFrom} to ${out.release.observedTo}.`);
    } catch (e) {
      showError(describe(e, "Those dates could not be released"));
      setStatus("");
    }
  }

  async function show() {
    if (view.loaded) return;
    view.loaded = true;
    wire();
    try {
      setStatus("Loading report options…");
      const opts = await loadOptions();
      $("release-form").hidden = !opts.canRelease;
      buildFilters(opts);
      await run();
    } catch (e) {
      view.loaded = false;
      showError(describe(e, "Reports are not available"));
      setStatus("");
    }
  }

  return { show };
}
