/**
 * Working-copy helpers over the rules engine: create a blank walk state from the model, apply
 * edits, and re-normalize (clear filtered/not-applicable values) exactly as the prototype does
 * in the browser. Everything is derived from the render model; no section or item is named.
 */
import { blankState, evaluate, normalize } from "./rules.js";

export function createBlankState(model) {
  return blankState(model);
}

/*
 * There is deliberately no client-side org-unit default. Guessing a School value because its code
 * equals the org unit's code is the same coincidence the server refuses to treat as identity: the
 * School dimension is derived from the unit's validated mapping inside the mutation, and the create
 * response carries the value the server assigned (docs/DATA_CONTRACT.md, "School and organizational
 * scope"). Seeding it here would send a value the server may have to refuse.
 */

export function setDimension(state, code, patch) {
  const current = state.dimensions[code] || {};
  state.dimensions[code] = { ...current, ...patch };
  for (const k of Object.keys(state.dimensions[code])) {
    if (state.dimensions[code][k] === "" || state.dimensions[code][k] === null || state.dimensions[code][k] === undefined) delete state.dimensions[code][k];
  }
}

export function setResponse(state, itemKey, patch) {
  const current = state.responses[itemKey] || {};
  state.responses[itemKey] = { ...current, ...patch };
  for (const k of Object.keys(state.responses[itemKey])) {
    if (state.responses[itemKey][k] === "" || state.responses[itemKey][k] === null || state.responses[itemKey][k] === undefined) delete state.responses[itemKey][k];
  }
}

/** Returns { state, evaluation, changes } after re-normalizing the working state. */
export function settle(model, state, policies) {
  const result = normalize(model, state, policies);
  return { state: result.state, changes: result.changes, evaluation: evaluate(model, result.state) };
}

/** Display text for a dimension value: the selected label, the typed "Other" text, or typed value. */
export function dimensionDisplay(model, state, code) {
  const v = state.dimensions[code];
  if (!v) return "";
  const dim = model.dimensions[code];
  if (v.selectedValueCode && dim) {
    const value = dim.values.find((x) => x.valueCode === v.selectedValueCode);
    if (!value) return "";
    if (isOtherValue(value) && v.otherText) return v.otherText;
    return value.label;
  }
  return v.textValue || v.dateValue || "";
}

/** Convention: on an allowOther dimension, the value coded "other" reveals the free-text field. */
export function isOtherValue(value) {
  return String(value.valueCode).toLowerCase() === "other";
}

/** Component rating summary for a section: rated question items and their answered count. */
export function ratingSummary(section, evaluation) {
  const rated = section.items.filter((it) => it.layout === "question" && it.responseSet && it.responseSet.scoreEnabled);
  const answered = rated.filter((it) => evaluation.responseStates[it.itemKey] === "ANSWERED").length;
  const notApplicable = rated.length > 0 && rated.every((it) => evaluation.responseStates[it.itemKey] === "NOT_APPLICABLE");
  return { total: rated.length, answered, notApplicable };
}
