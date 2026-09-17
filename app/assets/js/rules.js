/**
 * Instrument visibility engine (browser + Node). Twin of src/instrument/VisibilityEngine.cfc;
 * tests/fixtures/visibility-vectors.json proves both produce the same output.
 *
 * Working state shape (docs/DATA_CONTRACT.md autosave payload):
 *   { dimensions: { code: { selectedValueCode?, otherText?, textValue?, dateValue? } },
 *     responses:  { itemKey: { storedCode?, textValue? } } }
 *
 * See the CFML twin for the semantics. Nothing here is keyed to a specific section, item, or
 * dimension: every decision comes from the render model (rules, response sets, option filters).
 */

function str(v, key) {
  if (!v || typeof v !== "object") return "";
  const x = v[key];
  if (x === undefined || x === null) return "";
  return typeof x === "object" ? "" : String(x);
}

export function indexModel(model) {
  if (model.__index) return model.__index;
  const idx = { model, sections: {}, sectionOrder: [], items: {}, rulesByTarget: {} };
  const walk = (node) => {
    idx.sections[node.sectionKey] = node;
    idx.sectionOrder.push(node.sectionKey);
    for (const it of node.items) idx.items[it.itemKey] = it;
    for (const child of node.children) walk(child);
  };
  walk(model.root);
  for (const r of model.rules) {
    const tk = `${r.targetType}:${r.targetKey}`;
    (idx.rulesByTarget[tk] ||= []).push(r);
  }
  Object.defineProperty(model, "__index", { value: idx, enumerable: false });
  return idx;
}

function coerceState(state) {
  const st = { dimensions: {}, responses: {} };
  if (state && typeof state === "object") {
    if (state.dimensions && typeof state.dimensions === "object") st.dimensions = state.dimensions;
    if (state.responses && typeof state.responses === "object") st.responses = state.responses;
  }
  return st;
}

export function blankState(model) {
  const idx = indexModel(model);
  const state = { dimensions: {}, responses: {} };
  for (const key of Object.keys(idx.items)) {
    const it = idx.items[key];
    if (it.defaultStoredCode) state.responses[it.itemKey] = { storedCode: it.defaultStoredCode };
  }
  return state;
}

function dimensionCandidates(model, code, st) {
  const out = [];
  const v = st.dimensions[code];
  if (!v) return out;
  const sel = str(v, "selectedValueCode");
  if (sel) {
    out.push(sel);
    const dim = model.dimensions[code];
    if (dim) for (const dv of dim.values) if (dv.valueCode === sel) out.push(dv.label);
    return out;
  }
  const text = str(v, "textValue");
  if (text) out.push(text);
  const d = str(v, "dateValue");
  if (d) out.push(d);
  return out;
}

function evaluateCondition(c, st, idx) {
  let candidates = [];
  if (c.sourceType === "DIMENSION") {
    candidates = dimensionCandidates(idx.model, c.sourceKey, st);
  } else if (c.sourceType === "ITEM") {
    const code = str(st.responses[c.sourceKey], "storedCode");
    if (code) candidates.push(code);
  } else {
    throw new Error(`Unsupported rule source type '${c.sourceType}'.`);
  }
  const op = String(c.operator || "").toUpperCase();
  let hit = false;
  if (op === "EQUALS" || op === "NOT_EQUALS") {
    const e = c.comparisonValue !== null && typeof c.comparisonValue !== "object" ? String(c.comparisonValue) : "";
    hit = candidates.some((v) => v === e);
    return op === "EQUALS" ? hit : !hit;
  }
  if (op === "IN" || op === "NOT_IN") {
    let list = c.comparisonValue;
    if (typeof list === "string") {
      try { list = JSON.parse(list); } catch { list = [list]; }
    }
    if (!Array.isArray(list)) list = [];
    hit = candidates.some((v) => list.some((e) => typeof e !== "object" && v === String(e)));
    return op === "IN" ? hit : !hit;
  }
  throw new Error(`Unsupported rule operator '${c.operator}'.`);
}

function evaluateRule(rule, st, idx) {
  const conds = rule.conditions || {};
  const logic = String(conds.logic || "AND").toUpperCase();
  const list = Array.isArray(conds.conditions) ? conds.conditions : [];
  if (!list.length) return true;
  const results = list.map((c) => evaluateCondition(c, st, idx));
  return logic === "OR" ? results.some(Boolean) : results.every(Boolean);
}

function targetVisible(rulesByTarget, type, key, results, defaultVisible) {
  const rules = rulesByTarget[`${type}:${key}`];
  if (!rules) return defaultVisible;
  return rules.some((r) => results[r.ruleKey]);
}

function hiddenByItemRule(rulesByTarget, itemKey) {
  const rules = rulesByTarget[`ITEM:${itemKey}`];
  if (!rules) return false;
  return rules.some((r) => (r.conditions?.conditions || []).some((c) => c.sourceType === "ITEM"));
}

function allowedValueCodes(model, filter, st) {
  const dim = model.dimensions[filter.dimensionCode];
  const all = dim.values.map((v) => v.valueCode);
  const src = st.dimensions[filter.sourceDimensionCode];
  const sel = str(src, "selectedValueCode");
  const srcDim = model.dimensions[filter.sourceDimensionCode];
  if (!sel || !srcDim) return all;
  const selected = srcDim.values.find((v) => v.valueCode === sel);
  const group = selected && selected[filter.matchField] !== null && selected[filter.matchField] !== undefined ? String(selected[filter.matchField]) : "";
  if (!selected || !group) return all;
  return dim.values.filter((v) => v[filter.matchField] !== null && v[filter.matchField] !== undefined && String(v[filter.matchField]) === group).map((v) => v.valueCode);
}

function itemAnswered(it, st) {
  const r = st.responses[it.itemKey];
  if (!r) return false;
  if (it.responseSet) {
    const code = str(r, "storedCode");
    if (!code) return false;
    return it.responseSet.options.some((o) => o.storedCode === code);
  }
  return str(r, "textValue").trim().length > 0;
}

function dimensionAnswered(model, p, st) {
  const v = st.dimensions[p.dimensionCode];
  if (!v) return false;
  const sel = str(v, "selectedValueCode");
  if (sel) {
    const dim = model.dimensions[p.dimensionCode];
    return Boolean(dim && dim.values.some((dv) => dv.valueCode === sel));
  }
  return str(v, "textValue").trim().length > 0 || str(v, "dateValue").trim().length > 0;
}

export function evaluate(model, state) {
  const idx = indexModel(model);
  const st = coerceState(state);
  const out = { sections: {}, items: {}, dimensions: {}, dimensionOptions: {}, responseStates: {}, dimensionStates: {} };
  const results = {};
  for (const r of model.rules) results[r.ruleKey] = evaluateRule(r, st, idx);
  for (const key of idx.sectionOrder) {
    const s = idx.sections[key];
    const parentVisible = s.parentSectionKey === null || s.parentSectionKey === undefined ? true : out.sections[s.parentSectionKey];
    out.sections[key] = parentVisible && targetVisible(idx.rulesByTarget, "SECTION", key, results, true);
  }
  for (const f of model.optionFilters) out.dimensionOptions[f.dimensionCode] = allowedValueCodes(model, f, st);
  for (const key of idx.sectionOrder) {
    for (const p of idx.sections[key].placements) {
      const visible = out.sections[key] && targetVisible(idx.rulesByTarget, "DIMENSION", p.dimensionCode, results, p.visibleByDefault);
      out.dimensions[p.dimensionCode] = visible;
      out.dimensionStates[p.dimensionCode] = !visible ? "HIDDEN" : dimensionAnswered(model, p, st) ? "ANSWERED" : "UNANSWERED";
    }
  }
  for (const key of idx.sectionOrder) {
    for (const it of idx.sections[key].items) {
      const sectionVisible = out.sections[key];
      const ownVisible = targetVisible(idx.rulesByTarget, "ITEM", it.itemKey, results, true);
      const visible = sectionVisible && ownVisible;
      out.items[it.itemKey] = visible;
      if (it.layout === "display-heading" || it.layout === "display-guidance") continue;
      if (visible) out.responseStates[it.itemKey] = itemAnswered(it, st) ? "ANSWERED" : "UNANSWERED";
      else if (sectionVisible && hiddenByItemRule(idx.rulesByTarget, it.itemKey)) out.responseStates[it.itemKey] = "NOT_APPLICABLE";
      else out.responseStates[it.itemKey] = "HIDDEN";
    }
  }
  return out;
}

function hasValue(v) {
  return ["selectedValueCode", "otherText", "textValue", "dateValue", "storedCode"].some((k) => str(v, k).length > 0);
}

export function normalize(model, state, policies = {}) {
  const st = structuredClone(coerceState(state));
  const changes = [];
  const policy = policies.hiddenDimensionPolicy || "RETAIN_HIDDEN";
  let ev = evaluate(model, st);
  for (const code of Object.keys(ev.dimensionOptions)) {
    if (!st.dimensions[code]) continue;
    const sel = str(st.dimensions[code], "selectedValueCode");
    if (sel && !ev.dimensionOptions[code].includes(sel)) {
      st.dimensions[code] = {};
      changes.push({ kind: "DIMENSION_CLEARED", key: code, reason: "OPTION_FILTER" });
    }
  }
  ev = evaluate(model, st);
  for (const key of Object.keys(ev.responseStates)) {
    if (ev.responseStates[key] === "NOT_APPLICABLE" && st.responses[key] && hasValue(st.responses[key])) {
      st.responses[key] = {};
      changes.push({ kind: "RESPONSE_CLEARED", key, reason: "NOT_APPLICABLE" });
    }
  }
  if (policy === "CLEAR") {
    for (const code of Object.keys(ev.dimensions)) {
      if (!ev.dimensions[code] && st.dimensions[code] && hasValue(st.dimensions[code])) {
        st.dimensions[code] = {};
        changes.push({ kind: "DIMENSION_CLEARED", key: code, reason: "HIDDEN_CLEAR" });
      }
    }
  }
  changes.sort((a, b) => `${a.kind}:${a.key}`.localeCompare(`${b.kind}:${b.key}`));
  return { state: st, changes };
}
