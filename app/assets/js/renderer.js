/**
 * Dynamic walk-editor renderer. Builds the editor DOM from the render model
 * (/api/instrument/current) and a walk's working state, then keeps it in sync with the rules
 * engine on every edit. No prompt, option, section, or dimension is written here: presentation
 * follows the facts the RenderModelBuilder derived (presentation, layout, questionNumber,
 * hasLookFors, applicabilityItemKey, partNumber, ...).
 *
 * Accessibility: accordion headers are buttons with aria-expanded/aria-controls, choice pills are
 * toggle buttons with aria-pressed inside labelled groups, definition and look-for toggles expose
 * aria-expanded, every input has a programmatic label, and visibility changes are announced.
 */
import { setDimension, setResponse, settle, isOtherValue, ratingSummary } from "./walk-state.js";
import { createEmailComposer } from "./email-composer.js";

const SELECT_PLACEHOLDER = "Select...";
const OTHER_PLACEHOLDER = "Please specify...";
const LOCKED_DIMENSION_NOTE = "Set from the school this walk is recorded at.";
const DEFS_SHOW = "What do these mean?";
const DEFS_HIDE = "Hide definitions";
const LOOKFORS_SHOW = "Look Fors";
const LOOKFORS_HIDE = "Hide Look Fors";
const NOT_PART = "Not part of this lesson";

export function lightTint(hex, amt = 0.85) {
  const h = String(hex || "#000000").replace("#", "");
  const r = parseInt(h.substring(0, 2), 16), g = parseInt(h.substring(2, 4), 16), b = parseInt(h.substring(4, 6), 16);
  const mix = (c) => Math.round(c + (255 - c) * amt);
  return `rgb(${mix(r)},${mix(g)},${mix(b)})`;
}

/** Generic element builder, exported so the Part 4 composer builds its controls the same way. */
export function el(tag, attrs = {}, children = []) {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (v === undefined || v === null || v === false) continue;
    if (k === "class") node.className = v;
    else if (k === "style") { for (const [prop, val] of Object.entries(v)) node.style.setProperty(prop, val); } // CSSOM, allowed under CSP
    else if (k === "text") node.textContent = v;
    else if (k.startsWith("on")) node.addEventListener(k.slice(2), v);
    else node.setAttribute(k, v === true ? "" : v);
  }
  for (const c of children) if (c) node.appendChild(typeof c === "string" ? document.createTextNode(c) : c);
  return node;
}

let uid = 0;
const nextId = (prefix) => `${prefix}-${++uid}`;

/**
 * Renders the editor into container. Returns a controller:
 *   refresh()        re-evaluate rules and sync visibility, options, states, counts
 *   getState()       current working state
 *   evaluation       last engine output
 */
export function renderEditor(container, { model, walk, policies, onChange, announce }) {
  container.innerHTML = "";
  const ctx = {
    model, policies, onChange: onChange || (() => {}), announce: announce || (() => {}),
    // Dimensions the server owns for this walk (walk.lockedDimensions): rendered read-only, because
    // the server derives the value and refuses a client's. See docs/DATA_CONTRACT.md.
    locked: new Set(walk.lockedDimensions || []),
    state: walk.state,
    evaluation: null,
    sectionNodes: new Map(),   // sectionKey -> { node, section, countEl }
    itemNodes: new Map(),      // itemKey -> { node, item, pills[], textarea }
    placementNodes: new Map(), // dimensionCode -> { node, placement, select, input, other }
    lastVisible: {},
  };

  for (const child of model.root.children) container.appendChild(renderSection(child, ctx));

  const controller = {
    getState: () => ctx.state,
    get evaluation() { return ctx.evaluation; },
    refresh: () => refresh(ctx),
  };
  ctx.controller = controller;
  refresh(ctx, true);
  return controller;
}

// ---- change handling ---------------------------------------------------------------------------

function commit(ctx) {
  const result = settle(ctx.model, ctx.state, ctx.policies);
  ctx.state = result.state;
  refresh(ctx);
  ctx.onChange(ctx.state, result.changes);
}

function refresh(ctx, initial = false) {
  const ev = settle(ctx.model, ctx.state, ctx.policies);
  ctx.state = ev.state;
  ctx.evaluation = ev.evaluation;
  const e = ev.evaluation;

  // Sections
  for (const [key, entry] of ctx.sectionNodes) {
    const visible = e.sections[key];
    const was = ctx.lastVisible[`s:${key}`];
    entry.node.hidden = !visible;
    if (!initial && was !== undefined && was !== visible) ctx.announce(`${entry.section.title} ${visible ? "shown" : "hidden"}`);
    ctx.lastVisible[`s:${key}`] = visible;
    if (entry.countEl) {
      const summary = ratingSummary(entry.section, e);
      entry.countEl.textContent = summary.notApplicable ? NOT_PART : `${summary.answered}/${summary.total} rated`;
    }
  }
  // Placements
  for (const [code, entry] of ctx.placementNodes) {
    const visible = e.dimensions[code] !== false;
    const was = ctx.lastVisible[`d:${code}`];
    entry.node.hidden = !visible;
    if (!initial && was !== undefined && was !== visible) ctx.announce(`${entry.placement.label} ${visible ? "shown" : "hidden"}`);
    ctx.lastVisible[`d:${code}`] = visible;
    syncPlacement(entry, ctx);
  }
  // Items
  for (const [key, entry] of ctx.itemNodes) {
    const visible = e.items[key] !== false;
    entry.node.hidden = !visible;
    const value = ctx.state.responses[key] || {};
    if (entry.pills) for (const pill of entry.pills) pill.setAttribute("aria-pressed", value.storedCode === pill.dataset.code ? "true" : "false");
    if (entry.textarea && entry.textarea.value !== (value.textValue || "")) entry.textarea.value = value.textValue || "";
    if (entry.note) entry.note.hidden = !(entry.item.layout === "applicability" && value.storedCode && !entry.section.ratedItemKeys.some((k) => e.items[k]));
    // An item that owns a composite control (the Part 4 email draft) syncs itself from the state.
    if (entry.sync) entry.sync();
  }
}

function syncPlacement(entry, ctx) {
  const { placement, select, input, other } = entry;
  const value = ctx.state.dimensions[placement.dimensionCode] || {};
  if (select) {
    const dim = ctx.model.dimensions[placement.dimensionCode];
    const allowed = ctx.evaluation.dimensionOptions[placement.dimensionCode];
    const values = allowed ? dim.values.filter((v) => allowed.includes(v.valueCode)) : dim.values;
    const signature = values.map((v) => v.valueCode).join("|");
    if (entry.signature !== signature) {
      select.innerHTML = "";
      select.appendChild(el("option", { value: "", text: placement.placeholder || SELECT_PLACEHOLDER }));
      for (const v of values) select.appendChild(el("option", { value: v.valueCode, text: v.label }));
      entry.signature = signature;
    }
    select.value = value.selectedValueCode || "";
    if (other) {
      const selected = dim.values.find((v) => v.valueCode === value.selectedValueCode);
      const showOther = Boolean(selected && isOtherValue(selected));
      other.hidden = !showOther;
      if (other.value !== (value.otherText || "")) other.value = value.otherText || "";
    }
  } else if (input) {
    const key = placement.dataType === "DATE" ? "dateValue" : "textValue";
    if (input.value !== (value[key] || "")) input.value = value[key] || "";
  }
}

// ---- sections ----------------------------------------------------------------------------------

function renderSection(section, ctx) {
  switch (section.presentation) {
    case "card": return renderCard(section, ctx);
    case "accordion": return renderPartAccordion(section, ctx);
    case "component": return renderComponent(section, ctx);
    default: return renderBlock(section, ctx);
  }
}

function register(section, node, ctx, countEl) {
  ctx.sectionNodes.set(section.sectionKey, { node, section, countEl: countEl || null });
  node.dataset.sectionKey = section.sectionKey;
  return node;
}

function renderCard(section, ctx) {
  const titleId = nextId("sec");
  const card = el("section", { class: "section-card", "aria-labelledby": titleId }, [
    el("h2", { class: "section-title", id: titleId }, [section.title, section.requiredSection ? el("span", { class: "required-badge", text: "REQUIRED" }) : null]),
    section.instructions ? el("p", { class: "section-sub", text: section.instructions }) : null,
  ]);
  if (section.placements.length) card.appendChild(renderPlacements(section, ctx, "grid"));
  appendItems(card, section, ctx);
  for (const child of section.children) card.appendChild(renderSection(child, ctx));
  return register(section, card, ctx);
}

function renderPartAccordion(section, ctx) {
  const bodyId = nextId("acc-body");
  const head = el("button", { type: "button", class: "acc-head", "aria-expanded": "false", "aria-controls": bodyId }, [
    el("i", { class: "chev", "aria-hidden": "true", text: "›" }),
    el("span", { class: "acc-title", text: section.title }),
    section.requiredSection ? el("span", { class: "required-badge", text: "REQUIRED" }) : null,
  ]);
  const body = el("div", { class: "acc-body", id: bodyId });
  if (section.instructions) body.appendChild(el("p", { class: "acc-blurb", text: section.instructions }));
  if (section.placements.length) body.appendChild(renderPlacements(section, ctx, "block"));
  appendItems(body, section, ctx);
  const componentWrap = section.children.some((c) => c.presentation === "component") ? el("div", { class: "accordion" }) : body;
  for (const child of section.children) componentWrap.appendChild(renderSection(child, ctx));
  if (componentWrap !== body) body.appendChild(componentWrap);
  wireAccordion(head, body);
  const acc = el("div", { class: "acc part" }, [el("h2", { class: "acc-heading" }, [head]), body]);
  return register(section, acc, ctx);
}

function renderComponent(section, ctx) {
  const bodyId = nextId("acc-body");
  const countEl = el("span", { class: "acc-count" });
  const title = section.partNumber ? `${section.partNumber} · ${section.title}` : section.title;
  const head = el("button", { type: "button", class: "acc-head", "aria-expanded": "false", "aria-controls": bodyId, style: section.colorHex ? { background: lightTint(section.colorHex, 0.85) } : null }, [
    el("i", { class: "chev", "aria-hidden": "true", text: "›" }),
    section.colorHex ? el("span", { class: "acc-dot", "aria-hidden": "true", style: { background: section.colorHex } }) : null,
    el("span", { class: "acc-title", text: title }),
    countEl,
  ]);
  const body = el("div", { class: "acc-body", id: bodyId });
  if (section.instructions) body.appendChild(el("p", { class: "acc-blurb", text: section.instructions }));
  if (section.placements.length) body.appendChild(renderPlacements(section, ctx, "block"));
  appendItems(body, section, ctx);
  for (const child of section.children) body.appendChild(renderSection(child, ctx));
  wireAccordion(head, body);
  const acc = el("div", { class: "acc" }, [el("h3", { class: "acc-heading" }, [head]), body]);
  return register(section, acc, ctx, countEl);
}

function renderBlock(section, ctx) {
  const block = el("div", { class: `sub-block${section.headingVisible ? "" : " plain"}` });
  block.appendChild(el(section.depth >= 3 ? "h4" : "h3", { class: section.headingVisible ? "sub-heading" : "sr-only", text: section.title }));
  if (section.instructions) block.appendChild(el("p", { class: "section-sub", text: section.instructions }));
  if (section.placements.length) block.appendChild(renderPlacements(section, ctx, "block"));
  appendItems(block, section, ctx);
  for (const child of section.children) block.appendChild(renderSection(child, ctx));
  return register(section, block, ctx);
}

function wireAccordion(head, body) {
  head.addEventListener("click", () => {
    const open = head.getAttribute("aria-expanded") === "true";
    head.setAttribute("aria-expanded", open ? "false" : "true");
    body.classList.toggle("open", !open);
  });
}

// ---- placements (dimension inputs) --------------------------------------------------------------

function renderPlacements(section, ctx, mode) {
  const wrap = el("div", { class: mode === "grid" ? "field-grid" : "placement-block" });
  for (const p of section.placements) wrap.appendChild(renderPlacement(p, ctx));
  return wrap;
}

function renderPlacement(placement, ctx) {
  const id = nextId(`dim-${placement.dimensionCode}`);
  const locked = ctx.locked && ctx.locked.has(placement.dimensionCode);
  const wrap = el("div", { class: "placement", "data-dimension-code": placement.dimensionCode, "data-locked": locked ? "true" : null });
  const label = el("label", { for: id }, [placement.label, placement.required && !locked ? el("span", { class: "field-required", "aria-hidden": "true", text: "*" }) : null]);
  wrap.appendChild(label);
  const entry = { node: wrap, placement, select: null, input: null, other: null, signature: null };
  if (placement.dataType === "LIST") {
    const select = el("select", { id, "aria-required": placement.required && !locked ? "true" : null, disabled: locked ? "" : null });
    if (locked) {
      // Read-only, and it stays read-only when the walk is editable (see applyEditability).
      select.setAttribute("aria-describedby", `${id}-locked`);
    } else {
      select.addEventListener("change", () => {
        // The typed "Other" text is retained while another value is selected (prototype behavior).
        setDimension(ctx.state, placement.dimensionCode, { selectedValueCode: select.value });
        commit(ctx);
      });
    }
    wrap.appendChild(select);
    entry.select = select;
    if (locked) wrap.appendChild(el("p", { class: "field-note", id: `${id}-locked`, text: LOCKED_DIMENSION_NOTE }));
    if (placement.allowOther && !locked) {
      const otherId = `${id}-other`;
      const other = el("input", { type: "text", id: otherId, class: "other-input", placeholder: OTHER_PLACEHOLDER, "aria-label": `${placement.label} (please specify)`, hidden: true });
      other.addEventListener("input", () => { setDimension(ctx.state, placement.dimensionCode, { otherText: other.value }); commit(ctx); });
      wrap.appendChild(other);
      entry.other = other;
    }
  } else {
    const type = placement.dataType === "DATE" ? "date" : "text";
    const input = el("input", { type, id, placeholder: placement.placeholder || null, "aria-required": placement.required ? "true" : null });
    input.addEventListener("input", () => {
      setDimension(ctx.state, placement.dimensionCode, type === "date" ? { dateValue: input.value } : { textValue: input.value });
      commit(ctx);
    });
    wrap.appendChild(input);
    entry.input = input;
  }
  ctx.placementNodes.set(placement.dimensionCode, entry);
  return wrap;
}

// ---- items -------------------------------------------------------------------------------------

function appendItems(container, section, ctx) {
  const items = section.items;
  let i = 0;
  let lookForBox = null;
  let textGrid = null;
  let questionWrap = null;
  while (i < items.length) {
    const item = items[i];
    if (item.layout === "display-heading" || item.layout === "display-guidance") {
      if (!lookForBox) {
        lookForBox = renderLookForsShell(section, container);
      }
      if (item.layout === "display-heading") {
        lookForBox.appendChild(el("div", { class: "lookfor-heading", text: item.prompt, "data-item-key": item.itemKey }));
        const ul = el("ul", { class: "lookfor-list" });
        lookForBox.appendChild(ul);
        i++;
        while (i < items.length && items[i].layout === "display-guidance") {
          ul.appendChild(el("li", { text: items[i].prompt, "data-item-key": items[i].itemKey }));
          i++;
        }
        continue;
      }
      // guidance without a heading
      const ul = el("ul", { class: "lookfor-list" }, [el("li", { text: item.prompt, "data-item-key": item.itemKey })]);
      lookForBox.appendChild(ul);
      i++;
      continue;
    }
    if (item.layout === "text") {
      if (!textGrid) { textGrid = el("div", { class: "field-grid" }); container.appendChild(textGrid); }
      textGrid.appendChild(renderTextField(item, section, ctx));
      i++;
      continue;
    }
    if (item.layout === "applicability") {
      container.appendChild(renderApplicability(item, section, ctx));
      i++;
      continue;
    }
    if (item.layout === "question" || item.layout === "choice-row") {
      if (!questionWrap) { questionWrap = el("div", { class: "question-wrap" }); container.appendChild(questionWrap); }
      questionWrap.appendChild(item.layout === "question" ? renderQuestion(item, section, ctx) : renderChoiceRow(item, section, ctx));
      i++;
      continue;
    }
    if (item.layout === "notes") {
      container.appendChild(renderNotes(item, section, ctx));
      i++;
      continue;
    }
    if (item.layout === "email-draft") {
      // Phase 5: the Part 4 email-draft composer, built from the item's own settings. It writes the
      // draft into this item's response and commits through the ordinary save path, so the draft is
      // autosaved, concurrency-checked, and reloaded exactly like every other answer.
      const slot = el("div", { class: "email-slot", "data-item-key": item.itemKey, "data-item-type": item.itemType, hidden: true });
      container.appendChild(slot);
      const composer = createEmailComposer(slot, item, {
        model: ctx.model,
        announce: (text) => ctx.announce(text),
        read: () => ({ state: ctx.state, evaluation: ctx.evaluation }),
        write: (textValue) => {
          setResponse(ctx.state, item.itemKey, { textValue });
          commit(ctx);
        },
      });
      ctx.itemNodes.set(item.itemKey, { node: slot, item, section, sync: () => composer.sync() });
      i++;
      continue;
    }
    i++;
  }
}

function renderLookForsShell(section, container) {
  const boxId = nextId("lookfors");
  const box = el("div", { class: "lookfor-box", id: boxId, style: { background: section.colorHex ? lightTint(section.colorHex, 0.88) : "var(--tint)" } });
  const toggle = el("button", { type: "button", class: "btn btn-sm lookfor-toggle", "aria-expanded": "false", "aria-controls": boxId, text: LOOKFORS_SHOW });
  toggle.addEventListener("click", () => {
    const open = box.classList.toggle("open");
    toggle.setAttribute("aria-expanded", open ? "true" : "false");
    toggle.textContent = open ? LOOKFORS_HIDE : LOOKFORS_SHOW;
    toggle.classList.toggle("btn-primary", open);
  });
  container.appendChild(toggle);
  container.appendChild(box);
  return box;
}

function pillRow(item, labelId, ctx, section) {
  const row = el("div", { class: "pillrow", role: "group", "aria-labelledby": labelId });
  const pills = [];
  for (const o of item.responseSet.options) {
    const pill = el("button", { type: "button", class: `pill${o.isNa ? " na" : ""}`, "aria-pressed": "false", "data-code": o.storedCode, text: o.label });
    pill.addEventListener("click", () => { setResponse(ctx.state, item.itemKey, { storedCode: o.storedCode }); commit(ctx); });
    pills.push(pill);
    row.appendChild(pill);
  }
  return { row, pills };
}

function definitionsToggle(item) {
  const boxId = nextId("defs");
  const box = el("div", { class: "defs-box", id: boxId });
  for (const o of item.responseSet.options) {
    if (!o.definition) continue;
    box.appendChild(el("div", { class: "defs-row" }, [el("b", { text: `${o.label}:` }), ` ${o.definition}`]));
  }
  const toggle = el("button", { type: "button", class: "defs-toggle", "aria-expanded": "false", "aria-controls": boxId, text: DEFS_SHOW });
  toggle.addEventListener("click", () => {
    const open = box.classList.toggle("open");
    toggle.setAttribute("aria-expanded", open ? "true" : "false");
    toggle.textContent = open ? DEFS_HIDE : DEFS_SHOW;
  });
  return [toggle, box];
}

/**
 * An instrument's reference link is followed only when it is an absolute http or https address
 * (P8-06). The server refuses any other at import and at publication; this keeps a version stored
 * before that rule, or any other source of a model, from putting a javascript: or data: URL behind a
 * link a walker trusts. A refused link leaves its help text as plain text.
 */
function safeLinkUrl(value) {
  if (typeof value !== "string" || !/^https?:\/\/[^\s\x00-\x1f\x7f"<>\\`]+$/i.test(value)) return null;
  try {
    const url = new URL(value);
    return url.protocol === "https:" || url.protocol === "http:" ? value : null;
  } catch {
    return null;
  }
}

function renderQuestion(item, section, ctx) {
  const labelId = nextId("q");
  const prefix = item.questionNumber ? `${item.questionNumber}. ` : "";
  const row = el("div", { class: "q-block", "data-item-key": item.itemKey, "data-placeholder": item.isPlaceholder ? "true" : null });
  row.appendChild(el("p", { class: "q-text", id: labelId, text: `${prefix}${item.prompt}` }));
  const { row: pills, pills: buttons } = pillRow(item, labelId, ctx, section);
  row.appendChild(pills);
  const href = safeLinkUrl(item.linkUrl);
  if (href) row.appendChild(el("p", { class: "item-help" }, [el("a", { href, target: "_blank", rel: "noopener", text: item.helpText || "Reference" })]));
  else if (item.helpText) row.appendChild(el("p", { class: "item-help", text: item.helpText }));
  if (item.responseSet.hasDefinitions) for (const n of definitionsToggle(item)) row.appendChild(n);
  ctx.itemNodes.set(item.itemKey, { node: row, item, section, pills: buttons });
  return row;
}

function renderChoiceRow(item, section, ctx) {
  const labelId = nextId("yn");
  const row = el("div", { class: "yn-row", "data-item-key": item.itemKey, "data-placeholder": item.isPlaceholder ? "true" : null });
  const text = el("span", { class: "yn-text", id: labelId, text: item.prompt });
  const href = safeLinkUrl(item.linkUrl);
  if (href) {
    text.appendChild(el("br"));
    text.appendChild(el("a", { href, target: "_blank", rel: "noopener", text: item.helpText || "Reference" }));
  } else if (item.helpText) {
    text.appendChild(el("span", { class: "item-help", text: ` ${item.helpText}` }));
  }
  row.appendChild(text);
  const { row: pills, pills: buttons } = pillRow(item, labelId, ctx, section);
  row.appendChild(pills);
  ctx.itemNodes.set(item.itemKey, { node: row, item, section, pills: buttons });
  return row;
}

function renderApplicability(item, section, ctx) {
  const labelId = nextId("applic");
  const wrap = el("div", { class: "applic-block", "data-item-key": item.itemKey });
  wrap.appendChild(el("p", { class: "applic-q", id: labelId, text: item.prompt }));
  const { row, pills } = pillRow(item, labelId, ctx, section);
  wrap.appendChild(row);
  const note = item.helpText ? el("p", { class: "applic-note", text: item.helpText, hidden: true }) : null;
  if (note) wrap.appendChild(note);
  ctx.itemNodes.set(item.itemKey, { node: wrap, item, section, pills, note });
  return wrap;
}

function renderNotes(item, section, ctx) {
  const id = nextId("notes");
  const wrap = el("div", { class: "notes", "data-item-key": item.itemKey });
  wrap.appendChild(el("label", { class: "notes-label", for: id, text: item.prompt }));
  const textarea = el("textarea", { id, placeholder: item.placeholder || null });
  textarea.addEventListener("input", () => { setResponse(ctx.state, item.itemKey, { textValue: textarea.value }); commit(ctx); });
  wrap.appendChild(textarea);
  ctx.itemNodes.set(item.itemKey, { node: wrap, item, section, textarea });
  return wrap;
}

function renderTextField(item, section, ctx) {
  const id = nextId("text");
  const wrap = el("div", { "data-item-key": item.itemKey });
  wrap.appendChild(el("label", { for: id, text: item.prompt }));
  const textarea = el("textarea", { id, placeholder: item.placeholder || null });
  textarea.addEventListener("input", () => { setResponse(ctx.state, item.itemKey, { textValue: textarea.value }); commit(ctx); });
  wrap.appendChild(textarea);
  ctx.itemNodes.set(item.itemKey, { node: wrap, item, section, textarea });
  return wrap;
}
