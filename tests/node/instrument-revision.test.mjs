// The 2026-10-14 instrument revision (docs/INSTRUMENT_REVISION_2026-10-14.md): the document in
// config/instrument-config-2026-10-14.json against the prototype it was derived from, without the
// application. The server side -- import, publication, a walk saved and summarized on the new
// version, and the editor rendering it -- is tests/node/browser-revision.test.mjs and the CFML spec
// InstrumentRevisionTest.
//
// The prototype is read as data (scripts/lib/prototype.mjs), so every expectation below is the
// prototype's own table, never a retyped copy of it.
import { test } from "node:test";
import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { compileSnapshot, normalizeConfig } from "../../scripts/lib/snapshot.mjs";
import { codeOf, readPrototype } from "../../scripts/lib/prototype.mjs";
import { deriveFromRepository, REVISION } from "../../scripts/derive-instrument-revision.mjs";
import { root } from "./helpers.mjs";

const read = (rel) => fs.readFileSync(path.join(root, rel));
const sha256 = (bytes) => crypto.createHash("sha256").update(bytes).digest("hex");
const BASE = JSON.parse(read("config/instrument-config.json").toString("utf8"));
const DOC_TEXT = read(REVISION.output).toString("utf8");
const DOC = JSON.parse(DOC_TEXT);
const PROTOTYPE_BYTES = read(REVISION.prototype);
const P = readPrototype(PROTOTYPE_BYTES.toString("utf8"));
const GOLDEN = JSON.parse(read("tests/golden/instrument-snapshot-2026-10-14.golden.json").toString("utf8"));

const itemOf = (doc, key) => doc.items.find((i) => i.itemKey === key);
const setOf = (doc, setKey) => doc.responseSets.find((s) => s.setKey === setKey);
const optionsOf = (doc, setKey) => {
  const set = setOf(doc, setKey);
  return doc.responseOptions.filter((o) => o.responseSetId === set.responseSetId).sort((a, b) => a.displayOrder - b.displayOrder);
};
const sectionOf = (doc, key) => doc.sections.find((s) => s.sectionKey === key);
const dimensionOf = (doc, code) => doc.dimensions.find((d) => d.code === code);
const valuesOf = (doc, code) => {
  const dim = dimensionOf(doc, code);
  return doc.dimensionValues.filter((v) => v.dimensionId === dim.dimensionId).sort((a, b) => a.displayOrder - b.displayOrder);
};

/** Every rated question of the prototype, with the item key the instrument gives it. */
const RATED = [
  ...P.PART1_SECTIONS.flatMap((sec) => sec.qs.map((q) => ({ key: `part1_${sec.id === "targetTask" ? "targettask" : "adopted"}_${q.id}`, q }))),
  ...P.COMPONENTS.flatMap((c) => c.qs.map((q) => ({ key: `comp_${c.id}_${q.id}`, q }))),
  ...P.BELONGING_QS.map((q) => ({ key: `conditions_${q.id}`, q })),
];

/** The prototype's look-for lists, with the section and item-key prefix the instrument gives them. */
const LOOK_FORS = [
  ...P.PART1_SECTIONS.map((sec) => ({ section: `part1_${sec.id === "targetTask" ? "targettask" : "adopted"}`, prefix: `part1_${sec.id === "targetTask" ? "targettask" : "adopted"}`, src: sec })),
  ...P.COMPONENTS.map((c) => ({ section: c.id, prefix: `part2_${c.id}`, src: c })),
];

test("REV-01 the 2026-10-14 document is exactly what the derivation makes of the supplied document and the prototype", () => {
  assert.equal(deriveFromRepository(), DOC_TEXT, "node scripts/derive-instrument-revision.mjs was not re-run after a change");
  assert.equal(DOC.instrument.version.versionLabel, "2026-10-14 prototype revision");
  assert.equal(DOC.instrument.version.status, "DRAFT");
  assert.equal(DOC.instrument.code, BASE.instrument.code, "a new version of the same instrument");
  for (const key of ["instrumentId", "name", "description", "active"]) assert.equal(DOC.instrument[key], BASE.instrument[key], `shared instrument metadata ${key}`);
  assert.notEqual(DOC.instrument.version.versionId, BASE.instrument.version.versionId);
  for (const key of ["sections", "items", "responseSets", "rules", "instrumentDimensions"]) {
    for (const record of DOC[key]) assert.equal(record.versionId, DOC.instrument.version.versionId, `${key} record version`);
  }
});

test("REV-02 its source is the 2026-10-14 prototype, and the supplied baseline is untouched", () => {
  const actual = sha256(PROTOTYPE_BYTES);
  assert.equal(DOC.source.file, path.basename(REVISION.prototype));
  assert.equal(DOC.source.sha256, actual);
  assert.equal(DOC.instrument.version.sourceFile, path.basename(REVISION.prototype));
  assert.equal(DOC.instrument.version.sourceSha256, actual);
  assert.equal(sha256(read("source/current-prototype.html")), BASE.source.sha256, "the supplied prototype is the one the supplied document names");
  assert.equal(BASE.instrument.version.versionLabel, "2026-09-17 aligned prototype");
});

test("REV-03 the document compiles to its recorded checksums and counts", () => {
  const compiled = compileSnapshot(normalizeConfig(DOC));
  assert.equal(compiled.checksum, GOLDEN.checksum);
  assert.equal(compiled.definitionsChecksum, GOLDEN.definitionsChecksum);
  assert.equal(Buffer.byteLength(compiled.canonicalJson, "utf8"), GOLDEN.canonicalBytes);
  assert.deepEqual(compiled.counts, GOLDEN.counts);
  assert.deepEqual(DOC.counts, Object.fromEntries(Object.keys(BASE.counts).map((k) => [k, DOC[k].length])));
  assert.deepEqual(DOC.counts, { sections: 23, items: 166, responseSets: 30, responseOptions: 119, rules: 13, dimensions: 9, dimensionValues: 107, instrumentDimensions: 9 });
  assert.equal(compiled.counts.placeholders, 17, "the seventeen placeholder prompts are still placeholders");
});

test("REV-04 the document's references resolve and its keys are unique", () => {
  const unique = (records, get, label) => {
    const seen = new Set();
    for (const r of records) {
      const v = get(r);
      assert.ok(v !== null && v !== undefined && v !== "", `${label}: blank key`);
      assert.ok(!seen.has(v), `${label}: duplicate ${v}`);
      seen.add(v);
    }
  };
  unique(DOC.sections, (x) => x.sectionId, "section ids");
  unique(DOC.sections, (x) => x.sectionKey, "section keys");
  unique(DOC.items, (x) => x.itemId, "item ids");
  unique(DOC.items, (x) => x.itemKey, "item keys");
  unique(DOC.responseSets, (x) => x.responseSetId, "set ids");
  unique(DOC.responseSets, (x) => x.setKey, "set keys");
  unique(DOC.responseOptions, (x) => x.optionId, "option ids");
  unique(DOC.responseOptions, (x) => `${x.responseSetId}|${x.storedCode}`, "set/stored-code pairs");
  unique(DOC.rules, (x) => x.ruleKey, "rule keys");
  unique(DOC.dimensions, (x) => x.code, "dimension codes");
  unique(DOC.dimensionValues, (x) => `${x.dimensionId}|${x.valueCode}`, "dimension/value pairs");
  const sections = new Set(DOC.sections.map((s) => s.sectionId));
  const sets = new Set(DOC.responseSets.map((s) => s.responseSetId));
  const items = new Set(DOC.items.map((i) => i.itemId));
  const itemKeys = new Set(DOC.items.map((i) => i.itemKey));
  const dims = new Set(DOC.dimensions.map((d) => d.dimensionId));
  for (const it of DOC.items) {
    assert.ok(sections.has(it.sectionId), `${it.itemKey} section`);
    if (it.responseSetId) assert.ok(sets.has(it.responseSetId), `${it.itemKey} set`);
  }
  for (const o of DOC.responseOptions) assert.ok(sets.has(o.responseSetId), `${o.optionId} set`);
  for (const s of DOC.responseSets) assert.ok(DOC.items.some((i) => i.responseSetId === s.responseSetId), `${s.setKey} is used`);
  for (const v of DOC.dimensionValues) assert.ok(dims.has(v.dimensionId), `${v.dimensionValueId} dimension`);
  for (const pl of DOC.instrumentDimensions) assert.ok(dims.has(pl.dimensionId), `${pl.instrumentDimensionId} dimension`);
  for (const r of DOC.rules) {
    assert.ok(r.targetType !== "ITEM" || items.has(r.targetId), `${r.ruleKey} target`);
    assert.ok(r.sourceType !== "ITEM" || itemKeys.has(r.sourceId), `${r.ruleKey} source`);
    assert.deepEqual(JSON.parse(r.conditionsJson).conditions[0].comparisonValue, (() => {
      try { return JSON.parse(r.comparisonValue); } catch { return r.comparisonValue; }
    })(), `${r.ruleKey} comparison value and conditions agree`);
  }
});

test("REV-05 every rated item is on the prototype's 4-point scale, with its exact level definitions", () => {
  assert.deepEqual(P.SCALE, ["1", "2", "3", "4"]);
  assert.equal(RATED.length, 25);
  for (const { key, q } of RATED) {
    const it = itemOf(DOC, key);
    assert.ok(it, `${key} exists`);
    assert.equal(it.prompt, q.text, `${key} prompt`);
    const set = setOf(DOC, `scale_${key}`);
    assert.equal(it.responseSetId, set.responseSetId, `${key} has its own scale`);
    assert.equal(set.scoreEnabled, true);
    assert.equal(set.name, `1–4 scale for ${key}`);
    const options = optionsOf(DOC, `scale_${key}`);
    assert.deepEqual(options.map((o) => o.storedCode), P.SCALE, `${key} levels`);
    assert.deepEqual(options.map((o) => o.label), P.SCALE);
    assert.deepEqual(options.map((o) => o.numericScore), [1, 2, 3, 4]);
    assert.deepEqual(options.map((o) => o.definition), P.SCALE.map((level) => q.defs[level]), `${key} definitions`);
    assert.ok(options.every((o) => o.isNa === false && o.active === true));
  }
  const scored = DOC.responseSets.filter((s) => s.scoreEnabled);
  assert.equal(scored.length, 25, "no scored set other than the 25 rated items");
  assert.ok(!DOC.responseOptions.some((o) => scored.some((s) => s.responseSetId === o.responseSetId) && o.numericScore > 4), "nothing scores above 4");
});

test("REV-06 the level names travel with the version, and the 2026-09-17 version keeps its 1-5 scale", () => {
  assert.deepEqual(DOC.behavior.ratings.scale, [1, 2, 3, 4]);
  assert.deepEqual(DOC.behavior.ratings.levelNames, P.SCALE_NAMES);
  assert.deepEqual(DOC.behavior.ratings.levelNames, { 1: "Not evident", 2: "Inconsistent", 3: "Evident", 4: "Evident and student-owned" });
  assert.equal(DOC.behavior.ratings.componentAverage, BASE.behavior.ratings.componentAverage);
  assert.deepEqual(BASE.behavior.ratings.scale, [1, 2, 3, 4, 5]);
  assert.equal(BASE.behavior.ratings.levelNames, undefined);
});

test("REV-07 the look-fors are the prototype's lists, in its order, for Part 1 and every component", () => {
  for (const { section, prefix, src } of LOOK_FORS) {
    const sec = sectionOf(DOC, section);
    const display = DOC.items
      .filter((i) => i.sectionId === sec.sectionId && (i.itemType === "DISPLAY_HEADING" || i.itemType === "DISPLAY_GUIDANCE"))
      .sort((a, b) => a.displayOrder - b.displayOrder);
    const expected = [
      "Student Actions — look for", ...src.studentActions,
      "Teacher Actions — look for", ...src.teacherActions,
    ];
    assert.deepEqual(display.map((i) => i.prompt), expected, `${section} look-fors`);
    assert.equal(display.filter((i) => i.itemType === "DISPLAY_HEADING").length, 2);
    assert.ok(display.every((i) => i.itemKey.startsWith(`${prefix}_`)));
    assert.deepEqual(sec.settings.lookFors, { studentActions: src.studentActions, teacherActions: src.teacherActions }, `${section} settings.lookFors`);
  }
});

test("REV-08 Academic Teaming has three rated questions, each shown only while the component applies", () => {
  const s4 = sectionOf(DOC, "s4");
  const rated = DOC.items.filter((i) => i.sectionId === s4.sectionId && /^comp_s4_q\d$/.test(i.itemKey)).sort((a, b) => a.displayOrder - b.displayOrder);
  assert.deepEqual(rated.map((i) => i.itemKey), ["comp_s4_q1", "comp_s4_q2", "comp_s4_q3"]);
  assert.deepEqual(rated.map((i) => i.prompt), P.COMPONENTS.find((c) => c.id === "s4").qs.map((q) => q.text));
  assert.equal(s4.settings.canBeSkipped, true);
  assert.equal(s4.settings.defaultApplicable, false);
  for (const it of rated) {
    const rule = DOC.rules.find((r) => r.ruleKey === `show_${it.itemKey}`);
    assert.ok(rule, `show_${it.itemKey}`);
    assert.equal(rule.targetType, "ITEM");
    assert.equal(rule.targetId, it.itemId);
    assert.deepEqual(JSON.parse(rule.conditionsJson), { logic: "AND", conditions: [{ sourceType: "ITEM", sourceKey: "comp_s4_applicable", operator: "EQUALS", comparisonValue: "yes" }] });
  }
  assert.equal(itemOf(DOC, "comp_s4_q3").required, itemOf(DOC, "comp_s4_q1").required);
  assert.equal(itemOf(DOC, "comp_s4_q3").reportable, true);
  // Every other component keeps exactly its prototype questions.
  for (const c of P.COMPONENTS) {
    const sec = sectionOf(DOC, c.id);
    const keys = DOC.items.filter((i) => i.sectionId === sec.sectionId && /^comp_s\d_q\d$/.test(i.itemKey)).map((i) => i.itemKey);
    assert.deepEqual(keys, c.qs.map((q) => `comp_${c.id}_${q.id}`), `${c.id} questions`);
  }
});

test("REV-09 Part 1: Target/Task Alignment before Adopted Curriculum, and Pacing offers Pacing NOT evident first", () => {
  const part1 = sectionOf(DOC, "part1");
  const children = DOC.sections.filter((s) => s.parentSectionId === part1.sectionId).sort((a, b) => a.displayOrder - b.displayOrder);
  assert.deepEqual(children.map((s) => s.sectionKey), ["target_taxonomy", "part1_targettask", "part1_adopted"]);
  assert.deepEqual(children.slice(1).map((s) => s.title), P.PART1_SECTIONS.map((s) => s.title));
  const adopted = P.PART1_SECTIONS.find((s) => s.id === "adopted");
  const pacing = optionsOf(DOC, "part1_adopted_pacing");
  assert.deepEqual(pacing.map((o) => o.storedCode), adopted.pacing.options.map((o) => o.value));
  assert.deepEqual(pacing.map((o) => o.storedCode), ["notevident", "behind", "on", "ahead"]);
  assert.deepEqual(pacing.map((o) => o.label), adopted.pacing.options.map((o) => o.label));
  assert.deepEqual(pacing.map((o) => o.definition), adopted.pacing.options.map((o) => o.def));
  assert.ok(pacing.every((o) => o.numericScore === null && o.isNa === false), "pacing stays an unscored choice");
  assert.equal(setOf(DOC, "part1_adopted_pacing").scoreEnabled, false);
  // The three taxonomy questions are unchanged from the prototype.
  for (const [i, q] of P.PART1.entries()) {
    assert.equal(itemOf(DOC, q.id).prompt, q.text);
    assert.deepEqual(optionsOf(DOC, `part1_${q.id}`).map((o) => o.label), q.options, `${q.id} options`);
    assert.deepEqual(optionsOf(DOC, `part1_${q.id}`).map((o) => o.definition), q.options.map((o) => q.defs[o]), `${q.id} definitions`);
    assert.equal(itemOf(DOC, q.id).sourceLocation, `PART1[${i}]`);
  }
});

test("REV-10 the visit fields carry the prototype's labels and option lists, and Part 1's tag field is gone", () => {
  for (const f of P.META_FIELDS) assert.equal(dimensionOf(DOC, f.id).label, f.label, `${f.id} label`);
  assert.equal(dimensionOf(DOC, "content").label, "Content / Subject Area");
  assert.equal(dimensionOf(DOC, "classType").label, "Program");
  const lists = { grade: P.GRADE_OPTIONS, content: P.CONTENT_OPTIONS, classType: P.CLASS_TYPE_OPTIONS, period: P.PERIOD_OPTIONS, visitTiming: P.VISIT_TIMING_OPTIONS };
  for (const [code, labels] of Object.entries(lists)) {
    assert.deepEqual(valuesOf(DOC, code).map((v) => v.label), labels, `${code} values in the prototype's order`);
    assert.deepEqual(valuesOf(DOC, code).map((v) => v.valueCode), labels.map(codeOf), `${code} value codes`);
  }
  assert.equal(P.CLASS_TYPE_OPTIONS.length, 17);
  // Performing Arts and Visual Arts are new values; this version no longer offers Art or Music.
  const contentCodes = valuesOf(DOC, "content").map((v) => v.valueCode);
  assert.ok(contentCodes.includes("performing_arts") && contentCodes.includes("visual_arts"));
  assert.ok(!contentCodes.includes("art") && !contentCodes.includes("music"));
  // Every value a SHOW rule compares a dimension against is one this version offers.
  for (const rule of DOC.rules.filter((r) => r.sourceType === "DIMENSION")) {
    const cond = JSON.parse(rule.conditionsJson).conditions[0];
    const offered = valuesOf(DOC, cond.sourceKey).flatMap((v) => [v.label, v.valueCode]);
    for (const value of [].concat(cond.comparisonValue)) assert.ok(offered.includes(value), `${rule.ruleKey} compares against ${value}`);
  }
  const contentRule = JSON.parse(DOC.rules.find((r) => r.ruleKey === "show_content_area").conditionsJson).conditions[0];
  assert.deepEqual(contentRule.comparisonValue, P.CONTENT_AREA_TRIGGERS);
  assert.equal(sectionOf(DOC, "content_area_look_fors").instructions, "Shown automatically for Performing Arts, Visual Arts, or CTE.");
  assert.equal(P.markup.hasTagField, false);
  assert.equal(dimensionOf(DOC, "tag"), undefined);
  assert.ok(!DOC.instrumentDimensions.some((p) => p.dimensionId === "dim_tag"));
  assert.deepEqual(DOC.instrumentDimensions.map((p) => p.dimensionId), BASE.instrumentDimensions.map((p) => p.dimensionId).filter((id) => id !== "dim_tag"));
  // The prototype's checkboxes (step 2): exactly the fields of type "checkboxes" take several values,
  // and the 2026-09-17 document has no such field.
  const checkboxes = P.META_FIELDS.filter((f) => f.type === "checkboxes").map((f) => f.id);
  assert.deepEqual(checkboxes, ["grade", "content", "classType", "visitTiming"]);
  for (const placement of DOC.instrumentDimensions) {
    const code = DOC.dimensions.find((d) => d.dimensionId === placement.dimensionId).code;
    if (checkboxes.includes(code)) {
      assert.equal(placement.settings.multiple, true, `${code} takes several values`);
      assert.equal(dimensionOf(DOC, code).dataType, "LIST");
      assert.equal(dimensionOf(DOC, code).valueMode, "CONTROLLED_LIST");
    } else {
      assert.equal(Object.hasOwn(placement.settings, "multiple"), false, `${code} takes one value`);
    }
  }
  assert.ok(BASE.instrumentDimensions.every((p) => !Object.hasOwn(p.settings, "multiple")), "the 2026-09-17 version has no field that takes several values");
  assert.deepEqual(Object.keys(DOC.instrumentDimensions.find((p) => p.dimensionId === "dim_grade").settings).sort(), ["multiple", "optionFilter"], "grade keeps its option filter");
});

test("REV-11 nothing else moved: every record the revision does not own is the supplied record", () => {
  const ratedKeys = new Set(RATED.map((r) => r.key));
  const owned = {
    sections: (s) => ["part1_targettask", "part1_adopted", "content_area_look_fors", ...P.COMPONENTS.map((c) => c.id)].includes(s.sectionKey),
    items: (i) => ratedKeys.has(i.itemKey) || i.itemType === "DISPLAY_HEADING" || i.itemType === "DISPLAY_GUIDANCE" || i.itemKey === "part1_adopted_pacing",
    responseSets: (s) => s.setKey.startsWith("scale_") || s.setKey === "part1_adopted_pacing",
    responseOptions: (o) => o.optionId.startsWith("opt_scale_") || o.optionId.startsWith("opt_part1_adopted_pacing_"),
    rules: (r) => r.ruleKey === "show_content_area" || r.ruleKey === "show_comp_s4_q3",
    dimensions: (d) => d.code === "content" || d.code === "classType" || d.code === "tag",
    dimensionValues: (v) => v.dimensionId === "dim_content" || v.dimensionId === "dim_classtype" || v.dimensionId === "dim_school",
    instrumentDimensions: (p) => p.dimensionId === "dim_tag",
  };
  const ids = { sections: "sectionId", items: "itemId", responseSets: "responseSetId", responseOptions: "optionId", rules: "ruleId", dimensions: "dimensionId", dimensionValues: "dimensionValueId", instrumentDimensions: "instrumentDimensionId" };
  // A placement's settings.multiple is the revision's (REV-10); everything else about it is not.
  const strip = (r) => {
    const { versionId, ...rest } = r;
    if (rest.settings && Object.hasOwn(rest.settings, "multiple")) { const { multiple, ...settings } = rest.settings; rest.settings = settings; }
    return rest;
  };
  for (const [key, id] of Object.entries(ids)) {
    const before = new Map(BASE[key].filter((r) => !owned[key](r)).map((r) => [r[id], r]));
    const after = new Map(DOC[key].filter((r) => !owned[key](r)).map((r) => [r[id], r]));
    assert.deepEqual([...after.keys()].sort(), [...before.keys()].sort(), `${key}: the records outside the revision are the same records`);
    for (const [k, r] of before) assert.deepEqual(strip(after.get(k)), strip(r), `${key} ${k} is unchanged`);
  }
  for (const key of ["schemaVersion", "contentReview"]) assert.deepEqual(DOC[key], BASE[key], key);
  const { ratings: r2, conditionalSections: c2, ...behaviorAfter } = DOC.behavior;
  const { ratings: r1, conditionalSections: c1, ...behaviorBefore } = BASE.behavior;
  assert.deepEqual(behaviorAfter, behaviorBefore, "behavior other than ratings and the renamed content-area entry");
  assert.deepEqual(Object.values(c2), Object.values(c1));
});

test("REV-12 the School list is the prototype's as the owner amended it on 2026-10-16: four closed schools out, seven in", () => {
  // docs/OPEN_DECISIONS.md: the seven under the names the owner gave, alphabetical with Other last; a
  // school that stays is its supplied record, renumbered to its place.
  const closed = ["ellis_middle_school", "hanover_countryside_elementary_school", "lowrie_elementary_school", "washington_elementary_school"];
  const added = {
    hawk_hollow_middle_school: ["Hawk Hollow Middle School", "middle"], illinois_park: ["Illinois Park", "elementary"],
    independence: ["Independence", "elementary"], laurel_hill_elementary: ["Laurel Hill Elementary", "elementary"],
    legacy_middle_school: ["Legacy Middle School", "middle"], spring_trail_elementary: ["Spring Trail Elementary", "elementary"],
    sycamore_trails_elementary: ["Sycamore Trails Elementary", "elementary"],
  };
  const schools = valuesOf(DOC, "school");
  const schoolCodes = schools.map((v) => v.valueCode);
  assert.equal(schoolCodes.length, P.SCHOOL_OPTIONS.length - closed.length + Object.keys(added).length);
  for (const code of closed) assert.ok(P.SCHOOL_OPTIONS.map(codeOf).includes(code) && !schoolCodes.includes(code), `${code} is closed`);
  assert.deepEqual(schoolCodes.filter((c) => !Object.hasOwn(added, c)), P.SCHOOL_OPTIONS.map(codeOf).filter((c) => !closed.includes(c)), "the prototype's schools that stay, in its order");
  assert.equal(schoolCodes[schoolCodes.length - 1], "other");
  const schoolLabels = schools.slice(0, -1).map((v) => v.label);
  assert.deepEqual(schoolLabels, [...schoolLabels].sort((a, b) => a.localeCompare(b, "en")), "alphabetical, Other last");
  for (const [code, [label, group]] of Object.entries(added)) {
    const v = schools.find((x) => x.valueCode === code);
    assert.ok(v, `${code} is offered`);
    assert.deepEqual([v.label, v.valueGroup, v.reviewStatus, v.active], [label, group, "Owner decision 2026-10-16", true], code);
    assert.equal(codeOf(v.label), code);
  }
  const suppliedSchools = new Map(valuesOf(BASE, "school").map((v) => [v.valueCode, v]));
  for (const v of schools.filter((x) => suppliedSchools.has(x.valueCode))) {
    const { displayOrder: renumbered, ...after } = v;
    const { displayOrder: was, ...before } = suppliedSchools.get(v.valueCode);
    assert.deepEqual(after, before, `${v.valueCode} is its supplied record`);
  }
  assert.deepEqual(schools.map((v) => v.displayOrder), schools.map((_, i) => (i + 1) * 10));
});
