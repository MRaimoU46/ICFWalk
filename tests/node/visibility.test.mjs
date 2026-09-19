// Browser rules engine (app/assets/js/rules.js) against the shared visibility vectors and the
// COND-01..13 acceptance behaviors, using the render model served by the running application
// (falls back to the vectors' embedded expectations only for the parity check). The CFML twin
// (VisibilityEngineTest) runs the same vectors, so both engines are proven equivalent.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { evaluate, normalize, blankState } from "../../app/assets/js/rules.js";
import { dimensionDisplay, ratingSummary } from "../../app/assets/js/walk-state.js";
import { baseUrl, loadRuntimeEnv, root } from "./helpers.mjs";

const env = loadRuntimeEnv();
const token = env.ICFWALK_MAINTENANCE_TOKEN || "";
const tag = `nodevis-${Date.now().toString(36)}`;
const subject = `${tag}-walker`;
const vectors = JSON.parse(fs.readFileSync(path.join(root, "tests", "fixtures", "visibility-vectors.json"), "utf8"));

async function reachable() {
  try {
    const r = await fetch(`${baseUrl(env)}/index.cfm/api/health`, { signal: AbortSignal.timeout(10000) });
    if (r.status !== 200) return false;
    const body = await r.json();
    return body.environment === "development" || body.environment === "test";
  } catch { return false; }
}
const up = await reachable();
const skip = !up ? `application not reachable in development mode at ${baseUrl(env)}` : !token ? "no maintenance token" : false;

let model = null;

before(async () => {
  if (skip) return;
  // A walker fixture so /api/instrument/current answers; the model comes from the application so
  // the served contract (not a local compilation) is what the engine is checked against.
  const call = (p, body) => fetch(`${baseUrl(env)}/index.cfm${p}`, { method: "POST", headers: { "Content-Type": "application/json", "X-ICFWalk-Maintenance-Token": token }, body: JSON.stringify(body) });
  await call("/api/maintenance/org-units/import", { orgUnits: [{ code: `${tag}-district`, type: "DISTRICT", name: "Node fixture district", parentCode: null }] });
  await call("/api/maintenance/identity/provision-user", { subject, displayName: "Node fixture" });
  await call("/api/maintenance/identity/assign-role", { subject, roleCode: "DISTRICT_WALK_REPORT", orgUnitCode: `${tag}-district`, includeDescendants: true });
  const r = await fetch(`${baseUrl(env)}/index.cfm/api/instrument/current`, { headers: { "X-ICFWalk-Dev-Subject": subject, Accept: "application/json" } });
  const text = await r.text();
  assert.equal(r.status, 200, text);
  model = JSON.parse(text).model;
});

after(async () => {
  if (skip) return;
  const r = await fetch(`${baseUrl(env)}/index.cfm/api/maintenance/identity/cleanup-fixtures`, { method: "POST", headers: { "Content-Type": "application/json", "X-ICFWalk-Maintenance-Token": token }, body: JSON.stringify({ tag }) });
  if (r.status !== 200) console.error("fixture cleanup failed", r.status, await r.text());
});

test("JS engine reproduces every shared vector (parity contract with the CFML engine)", { skip }, () => {
  assert.equal(vectors.format, "icfwalk-visibility-vectors/1");
  for (const v of vectors.vectors) {
    const ev = evaluate(model, v.state);
    const actual = {
      sections: ev.sections, dimensions: ev.dimensions, dimensionOptions: ev.dimensionOptions, responseStates: ev.responseStates, dimensionStates: ev.dimensionStates,
      hiddenItems: Object.keys(ev.items).filter((k) => !ev.items[k]).sort(),
      normalizedRetain: normalize(model, v.state, { hiddenDimensionPolicy: "RETAIN_HIDDEN" }),
      normalizedClear: normalize(model, v.state, { hiddenDimensionPolicy: "CLEAR" }),
    };
    assert.deepEqual(actual, v.expected, v.name);
  }
});

const st = (dimensions = {}, responses = {}) => ({ dimensions, responses });

test("COND-01..04 grade choices follow the selected school's group; Other shows PreK-12", { skip }, () => {
  assert.deepEqual(evaluate(model, st({ school: { selectedValueCode: "bartlett_elementary_school" } })).dimensionOptions.grade, ["prek", "k", "1", "2", "3", "4", "5"]);
  assert.deepEqual(evaluate(model, st({ school: { selectedValueCode: "kimball_middle_school" } })).dimensionOptions.grade, ["6", "7", "8"]);
  for (const code of ["larkin_high_school", "dream_academy", "central_school"]) assert.deepEqual(evaluate(model, st({ school: { selectedValueCode: code } })).dimensionOptions.grade, ["9", "10", "11", "12"], code);
  assert.equal(evaluate(model, st({ school: { selectedValueCode: "other", otherText: "Unlisted" } })).dimensionOptions.grade.length, 14);
  assert.equal(evaluate(model, st()).dimensionOptions.grade.length, 14);
});

test("COND-05 an invalid grade is cleared and dependent visibility recalculates", { skip }, () => {
  const s = st({ school: { selectedValueCode: "bartlett_elementary_school" }, grade: { selectedValueCode: "prek" } });
  assert.equal(evaluate(model, s).sections.prek_k_classroom, true);
  s.dimensions.school = { selectedValueCode: "kimball_middle_school" };
  const n = normalize(model, s);
  assert.deepEqual(n.changes, [{ kind: "DIMENSION_CLEARED", key: "grade", reason: "OPTION_FILTER" }]);
  assert.equal(evaluate(model, n.state).sections.prek_k_classroom, false);
  assert.equal(evaluate(model, n.state).dimensionStates.grade, "UNANSWERED");
});

test("COND-06 Period shows for 6-12 only; hidden value retained as HIDDEN by policy", { skip }, () => {
  for (const g of ["6", "7", "8", "9", "10", "11", "12"]) assert.equal(evaluate(model, st({ grade: { selectedValueCode: g } })).dimensions.period, true, g);
  for (const g of ["prek", "k", "1", "2", "3", "4", "5"]) assert.equal(evaluate(model, st({ grade: { selectedValueCode: g } })).dimensions.period, false, g);
  const s = st({ grade: { selectedValueCode: "4" }, period: { selectedValueCode: "second" } });
  assert.deepEqual(normalize(model, s).changes, []);
  assert.equal(evaluate(model, s).dimensionStates.period, "HIDDEN");
  assert.deepEqual(normalize(model, s, { hiddenDimensionPolicy: "CLEAR" }).changes, [{ kind: "DIMENSION_CLEARED", key: "period", reason: "HIDDEN_CLEAR" }]);
});

test("COND-07..09 conditional classroom sections", { skip }, () => {
  const conditional = ["prek_k_classroom", "dual_language_classroom", "mac_prep_classroom", "ignite_classroom", "avid_classroom", "esl_classroom", "content_area_look_fors"];
  const only = (state, keys, label) => {
    const e = evaluate(model, state);
    for (const k of conditional) assert.equal(e.sections[k], keys.includes(k), `${label}: ${k}`);
  };
  only(st({ grade: { selectedValueCode: "prek" } }), ["prek_k_classroom"], "PreK");
  only(st({ grade: { selectedValueCode: "k" } }), ["prek_k_classroom"], "K");
  only(st({ grade: { selectedValueCode: "5" } }), [], "grade 5");
  const byType = { dual_language: "dual_language_classroom", mac: "mac_prep_classroom", prep: "mac_prep_classroom", ignite: "ignite_classroom", avid: "avid_classroom", esl: "esl_classroom" };
  for (const [code, section] of Object.entries(byType)) only(st({ classType: { selectedValueCode: code } }), [section], code);
  only(st({ classType: { selectedValueCode: "general_education" } }), [], "general education");
  for (const c of ["art", "music", "cte"]) only(st({ content: { selectedValueCode: c } }), ["content_area_look_fors"], c);
  only(st({ content: { selectedValueCode: "science" } }), [], "science");
});

test("COND-10 hidden conditional answers are retained and reappear", { skip }, () => {
  const s = st({ classType: { selectedValueCode: "esl" } }, { esl_q1: { storedCode: "no" }, esl_notes: { textValue: "kept" } });
  assert.equal(evaluate(model, s).responseStates.esl_q1, "ANSWERED");
  s.dimensions.classType = { selectedValueCode: "avid" };
  const n = normalize(model, s);
  assert.deepEqual(n.changes, []);
  assert.equal(evaluate(model, n.state).responseStates.esl_q1, "HIDDEN");
  n.state.dimensions.classType = { selectedValueCode: "esl" };
  assert.equal(evaluate(model, n.state).responseStates.esl_q1, "ANSWERED");
});

test("COND-11..13 skippable components default to No, clear ratings on No, keep notes, return UNANSWERED on Yes", { skip }, () => {
  const blank = blankState(model);
  for (const c of ["s3", "s4"]) {
    assert.equal(blank.responses[`comp_${c}_applicable`].storedCode, "no");
    const e = evaluate(model, blank);
    assert.equal(e.items[`comp_${c}_q1`], false);
    assert.equal(e.responseStates[`comp_${c}_q1`], "NOT_APPLICABLE");
  }
  const s = st({}, { comp_s4_applicable: { storedCode: "yes" }, comp_s4_q1: { storedCode: "5" }, comp_s4_q2: { storedCode: "3" }, comp_s4_notes: { textValue: "note" } });
  assert.equal(evaluate(model, s).responseStates.comp_s4_q1, "ANSWERED");
  s.responses.comp_s4_applicable = { storedCode: "no" };
  const n = normalize(model, s);
  assert.deepEqual(n.changes, [
    { kind: "RESPONSE_CLEARED", key: "comp_s4_q1", reason: "NOT_APPLICABLE" },
    { kind: "RESPONSE_CLEARED", key: "comp_s4_q2", reason: "NOT_APPLICABLE" },
  ]);
  assert.equal(n.state.responses.comp_s4_notes.textValue, "note");
  assert.equal(evaluate(model, n.state).responseStates.comp_s4_q1, "NOT_APPLICABLE");
  n.state.responses.comp_s4_applicable = { storedCode: "yes" };
  assert.equal(evaluate(model, n.state).responseStates.comp_s4_q1, "UNANSWERED");
  assert.equal(evaluate(model, n.state).responseStates.comp_s4_q2, "UNANSWERED");
});

test("COND-15 answered requires a valid option; unanswered never becomes zero", { skip }, () => {
  const e = evaluate(model, st({}, { comp_s5_q1: { storedCode: "0" }, comp_s5_q2: { storedCode: "2" } }));
  assert.equal(e.responseStates.comp_s5_q1, "UNANSWERED");
  assert.equal(e.responseStates.comp_s5_q2, "ANSWERED");
  assert.ok(!("part2_s5_student_1" in e.responseStates), "display items have no state");
});

test("engine rejects unsupported operators instead of guessing", { skip }, () => {
  const broken = structuredClone(model);
  broken.rules[0].conditions.conditions[0].operator = "LIKE";
  assert.throws(() => evaluate(broken, st()), /Unsupported rule operator/);
});

test("walk-state helpers: a blank state presets no School value; display text; rating summary", { skip }, () => {
  // The browser never guesses a School value from an org-unit code: the server derives it from the
  // unit's validated mapping (docs/DATA_CONTRACT.md, "School and organizational scope").
  const s = blankState(model);
  assert.equal(s.dimensions.school, undefined);
  assert.equal(dimensionDisplay(model, s, "school"), "");
  const labelled = st({ school: { selectedValueCode: "elgin_high_school" } });
  assert.equal(dimensionDisplay(model, labelled, "school"), "Elgin High School");
  const other = st({ school: { selectedValueCode: "other", otherText: "St. Somewhere" }, date: { dateValue: "2026-09-17" } });
  assert.equal(dimensionDisplay(model, other, "school"), "St. Somewhere");
  assert.equal(dimensionDisplay(model, other, "date"), "2026-09-17");
  assert.equal(dimensionDisplay(model, st({ school: { selectedValueCode: "other" } }), "school"), "Other");
  const s3 = (() => { let f; const w = (n) => { if (n.sectionKey === "s3") f = n; n.children.forEach(w); }; w(model.root); return f; })();
  assert.deepEqual(ratingSummary(s3, evaluate(model, blankState(model))), { total: 2, answered: 0, notApplicable: true });
  assert.deepEqual(ratingSummary(s3, evaluate(model, st({}, { comp_s3_applicable: { storedCode: "yes" }, comp_s3_q2: { storedCode: "2" } }))), { total: 2, answered: 1, notApplicable: false });
});
