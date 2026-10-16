/**
 * Derives the 2026-10-14 instrument document from the supplied 2026-09-17 document and the
 * 2026-10-14 prototype (docs/INSTRUMENT_REVISION_2026-10-14.md).
 *
 * The supplied document (config/instrument-config.json) stays exactly as it is: it is the published
 * baseline every walk taken so far is pinned to. This writes a second document, a new DRAFT version
 * of the same ICFWALK instrument, that differs from it only where the prototype changed:
 *
 *   - every rated item uses the prototype's 4-point SCALE, with its new level definitions, and the
 *     level names (SCALE_NAMES) are carried in behavior.ratings.levelNames
 *   - Academic Teaming gains its third question, shown and cleared with the component like the others
 *   - the look-for lists are the prototype's, for Part 1 and every component
 *   - Target/Task Alignment comes before Adopted Curriculum, and Pacing offers "Pacing NOT evident"
 *   - the visit fields carry the prototype's labels and option lists (Content / Subject Area with
 *     Performing Arts and Visual Arts, Program with its seventeen programs), and the content-area
 *     card follows the new trigger list
 *   - "Other disaggregation tag(s)" is gone from Part 1
 *
 * Every prototype-sourced string is read from the prototype itself (scripts/lib/prototype.mjs), so
 * nothing here is retyped. What the prototype does not carry -- authoring ids, keys, display orders,
 * section titles from its markup, rule wiring, reporting flags -- is kept from the supplied document,
 * so an unchanged record is byte-for-byte the record the supplied document has.
 *
 *   - Grade level, Content / Subject Area, Program and Visit timing take several values: every
 *     META_FIELDS entry of type "checkboxes" gives its placement settings.multiple (step 2, migration
 *     008; docs/INSTRUMENT_REVISION_2026-10-14.md)
 *   - the School list is the prototype's as the owner amended it on 2026-10-16 (SCHOOL_AMENDMENT): four
 *     closed schools leave and seven schools the prototype does not list join, in its alphabetical
 *     order with Other last
 *
 *   node scripts/derive-instrument-revision.mjs           # rewrite the document
 *   node scripts/derive-instrument-revision.mjs --check   # exit 1 when the committed document is stale
 *
 * Tooling, not a test: tests/node/instrument-revision.test.mjs runs the --check comparison itself.
 */
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { codeOf, readPrototype } from "./lib/prototype.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

export const REVISION = {
  baseDocument: "config/instrument-config.json",
  prototype: "source/prototype-2026-10-14.html",
  output: "config/instrument-config-2026-10-14.json",
  versionId: "ver_icfwalk_2026_10_14",
  versionLabel: "2026-10-14 prototype revision",
  extractedOn: "2026-10-14",
  generatedAt: "2026-10-14T00:00:00Z",
  reviewStatus: "Aligned to the 2026-10-14 prototype",
  revisionNotes:
    "Supersedes the 2026-09-17 aligned prototype version: 4-point rating scale with level names and new " +
    "level definitions; Academic Teaming question 3; the prototype's look-for lists; Target/Task Alignment " +
    "before Adopted Curriculum; Pacing NOT evident; Content / Subject Area (Performing Arts, Visual Arts) " +
    "and Program (17 programs) options; Other disaggregation tag(s) removed; Grade level, Content / Subject " +
    "Area, Program and Visit timing take several values (the prototype's checkboxes); the School list as the " +
    "owner amended it on 2026-10-16 (four closed schools removed, seven schools added).",
};

/**
 * The owner's School list of 2026-10-16 (docs/OPEN_DECISIONS.md), applied to the prototype's: "Those
 * schools are all closed." for the four, and "those names are correct. Legacy Middle School. Hawk Hollow
 * Middle School, Laurel Hill Elementary, Spring Trail Elementary, Sycamore Trails Elementary." for the
 * seven new schools, named as the owner gave them (Independence and Illinois Park as listed). A new
 * school's value group is its network's grade band (the Middle School Network's are middle schools; the
 * others are in elementary networks), which the version's school-to-grade filter reads.
 */
export const SCHOOL_AMENDMENT = {
  decidedOn: "2026-10-16",
  closed: ["Ellis Middle School", "Hanover Countryside Elementary School", "Lowrie Elementary School", "Washington Elementary School"],
  added: [
    { label: "Hawk Hollow Middle School", valueGroup: "middle" },
    { label: "Illinois Park", valueGroup: "elementary" },
    { label: "Independence", valueGroup: "elementary" },
    { label: "Laurel Hill Elementary", valueGroup: "elementary" },
    { label: "Legacy Middle School", valueGroup: "middle" },
    { label: "Spring Trail Elementary", valueGroup: "elementary" },
    { label: "Sycamore Trails Elementary", valueGroup: "elementary" },
  ],
};

const PLACEHOLDER = "Placeholder in source";
const STUDENT_HEADING = "Student Actions — look for";
const TEACHER_HEADING = "Teacher Actions — look for";

const sha256 = (bytes) => crypto.createHash("sha256").update(bytes).digest("hex");
const clone = (value) => JSON.parse(JSON.stringify(value));

/** "a", "a or b", "a, b, or c" -- the supplied document's wording for the content-area card. */
function orList(labels) {
  if (labels.length <= 1) return labels.join("");
  if (labels.length === 2) return `${labels[0]} or ${labels[1]}`;
  return `${labels.slice(0, -1).join(", ")}, or ${labels[labels.length - 1]}`;
}

/** A record shaped exactly like `template` (same members, same order) with `values` applied. */
function like(template, values) {
  const out = {};
  for (const key of Object.keys(template)) out[key] = Object.hasOwn(values, key) ? values[key] : template[key];
  for (const key of Object.keys(values)) if (!Object.hasOwn(out, key)) throw new Error(`like(): ${key} is not a member of the template.`);
  return out;
}

/**
 * base: the supplied document (parsed); prototypeBytes: the prototype file exactly as stored, whose
 * SHA-256 the new version records as its source.
 */
export function deriveRevision(base, prototypeBytes) {
  const p = readPrototype(prototypeBytes.toString("utf8"));
  const doc = clone(base);
  const vid = REVISION.versionId;
  const scale = p.SCALE;
  if (!Array.isArray(scale) || !scale.length || !p.SCALE_NAMES) throw new Error("The prototype declares no SCALE / SCALE_NAMES.");

  // ---- identity -----------------------------------------------------------------------------------
  const prototypeSha = sha256(prototypeBytes);
  const prototypeFile = path.basename(REVISION.prototype);
  doc.generatedAt = REVISION.generatedAt;
  doc.source = { ...doc.source, file: prototypeFile, sha256: prototypeSha };
  doc.instrument.version = like(doc.instrument.version, {
    versionId: vid,
    versionLabel: REVISION.versionLabel,
    status: "DRAFT",
    effectiveStart: null,
    effectiveEnd: null,
    extractedOn: REVISION.extractedOn,
    sourceFile: prototypeFile,
    sourceSha256: prototypeSha,
    reviewStatus: REVISION.reviewStatus,
    revisionNotes: REVISION.revisionNotes,
  });

  const sectionByKey = new Map(doc.sections.map((s) => [s.sectionKey, s]));
  const itemTemplate = (key) => {
    const it = base.items.find((i) => i.itemKey === key);
    if (!it) throw new Error(`The supplied document has no item ${key}.`);
    return it;
  };

  // Items are rebuilt section by section: what a section keeps, what it gains, in display order.
  const keptItems = new Map(); // sectionId -> items
  for (const it of doc.items) {
    if (!keptItems.has(it.sectionId)) keptItems.set(it.sectionId, []);
    keptItems.get(it.sectionId).push(it);
  }
  const setsToRebuild = new Set();
  const newSets = [];
  const newOptions = [];
  const newRules = [];

  /** The look-for rows of one section, from the prototype's lists. */
  function lookForItems(section, prefix, location, studentActions, teacherActions) {
    const heading = itemTemplate(`${prefix}_student_heading`);
    const guidance = itemTemplate(`${prefix}_student_1`);
    const rows = [];
    const add = (list, who, at, title) => {
      rows.push(like(heading, {
        itemId: `item_${prefix}_${who}_heading`, versionId: vid, sectionId: section.sectionId,
        itemKey: `${prefix}_${who}_heading`, prompt: title, displayOrder: at,
        sourceLocation: `${location}.${who}Actions`,
      }));
      list.forEach((text, i) => rows.push(like(guidance, {
        itemId: `item_${prefix}_${who}_${i + 1}`, versionId: vid, sectionId: section.sectionId,
        itemKey: `${prefix}_${who}_${i + 1}`, prompt: text, displayOrder: at + i + 1,
        sourceLocation: `${location}.${who}Actions[${i}]`,
      })));
    };
    add(studentActions, "student", 10, STUDENT_HEADING);
    add(teacherActions, "teacher", 30, TEACHER_HEADING);
    return rows;
  }

  /** A rated item on the prototype's scale: the item, its own response set, and its options. */
  function ratedItem(section, itemKey, question, location, order, template) {
    const setKey = `scale_${itemKey}`;
    const setId = `rs_${setKey}`;
    setsToRebuild.add(setId);
    const setTemplate = base.responseSets.find((s) => s.setKey === `scale_${template.itemKey}`);
    newSets.push(like(setTemplate, {
      responseSetId: setId, versionId: vid, setKey,
      name: `${scale[0]}–${scale[scale.length - 1]} scale for ${itemKey}`, sourceLocation: location,
    }));
    const optionTemplate = base.responseOptions.find((o) => o.responseSetId === setTemplate.responseSetId);
    scale.forEach((level, i) => {
      if (typeof question.defs[level] !== "string") throw new Error(`${location} has no definition for level ${level}.`);
      newOptions.push(like(optionTemplate, {
        optionId: `opt_${setKey}_${level}`, responseSetId: setId, optionKey: level, storedCode: level,
        label: level, definition: question.defs[level], numericScore: Number(level), displayOrder: (i + 1) * 10,
        sourceLocation: `${location}.options[${i}]`,
      }));
    });
    return like(template, {
      itemId: `item_${itemKey}`, versionId: vid, sectionId: section.sectionId, itemKey,
      reportingKey: itemKey, prompt: question.text, responseSetId: setId, displayOrder: order,
      sourceLocation: location,
    });
  }

  // ---- Part 1: the taxonomy questions, then Target/Task Alignment and Adopted Curriculum ----------
  p.PART1.forEach((q, i) => {
    const it = keptItems.get(sectionByKey.get("target_taxonomy").sectionId).find((x) => x.itemKey === q.id);
    it.prompt = q.text;
    const setId = it.responseSetId;
    setsToRebuild.add(setId);
    newSets.push(like(base.responseSets.find((s) => s.responseSetId === setId), { versionId: vid }));
    const optionTemplate = base.responseOptions.find((o) => o.responseSetId === setId);
    q.options.forEach((label, j) => newOptions.push(like(optionTemplate, {
      optionId: `opt_part1_${q.id}_${codeOf(label)}`, responseSetId: setId, optionKey: codeOf(label),
      storedCode: label, label, definition: q.defs ? q.defs[label] ?? null : null, displayOrder: (j + 1) * 10,
      sourceLocation: `PART1[${i}].options[${j}]`,
    })));
  });

  const PART1_KEYS = { targetTask: "targettask", adopted: "adopted" };
  p.PART1_SECTIONS.forEach((ps, i) => {
    const short = PART1_KEYS[ps.id];
    if (!short) throw new Error(`Unknown Part 1 section ${ps.id}.`);
    const section = sectionByKey.get(`part1_${short}`);
    const location = `PART1_SECTIONS[${i}]`;
    section.displayOrder = 20 + i * 10;
    section.title = ps.title;
    section.colorHex = ps.color;
    section.sourceLocation = location;
    section.settings = { ...section.settings, lookFors: { studentActions: ps.studentActions, teacherActions: ps.teacherActions } };
    const prefix = `part1_${short}`;
    const kept = keptItems.get(section.sectionId).filter((it) => it.itemType === "LONG_TEXT");
    const rows = lookForItems(section, prefix, location, ps.studentActions, ps.teacherActions);
    let order = 100;
    if (ps.pacing) {
      const it = clone(itemTemplate(`${prefix}_pacing`));
      Object.assign(it, { versionId: vid, prompt: ps.pacing.label, displayOrder: order, sourceLocation: `${location}.pacing` });
      rows.push(it);
      order += 10;
      setsToRebuild.add(it.responseSetId);
      newSets.push(like(base.responseSets.find((s) => s.responseSetId === it.responseSetId), { versionId: vid, sourceLocation: `${location}.pacing` }));
      const optionTemplate = base.responseOptions.find((o) => o.responseSetId === it.responseSetId);
      ps.pacing.options.forEach((o, j) => newOptions.push(like(optionTemplate, {
        optionId: `opt_${prefix}_pacing_${o.value}`, responseSetId: it.responseSetId, optionKey: o.value,
        storedCode: o.value, label: o.label, definition: o.def, displayOrder: (j + 1) * 10,
        sourceLocation: `${location}.pacing.options[${j}]`,
      })));
    }
    ps.qs.forEach((q, j) => {
      rows.push(ratedItem(section, `${prefix}_${q.id}`, q, `${location}.qs[${j}]`, order, itemTemplate(`${prefix}_${q.id}`)));
      order += 10;
    });
    keptItems.set(section.sectionId, [...rows, ...kept]);
  });

  // ---- Part 2: the seven components --------------------------------------------------------------
  p.COMPONENTS.forEach((c, i) => {
    const section = sectionByKey.get(c.id);
    const location = `COMPONENTS[${i}]`;
    section.title = c.title;
    section.colorHex = c.color;
    section.settings = { ...section.settings, lookFors: { studentActions: c.studentActions, teacherActions: c.teacherActions } };
    const prefix = `part2_${c.id}`;
    const kept = keptItems.get(section.sectionId).filter((it) => it.itemType === "LONG_TEXT" || it.itemKey.endsWith("_applicable"));
    const rows = lookForItems(section, prefix, location, c.studentActions, c.teacherActions);
    const applicable = kept.find((it) => it.itemKey.endsWith("_applicable"));
    c.qs.forEach((q, j) => {
      const itemKey = `comp_${c.id}_${q.id}`;
      const template = base.items.find((x) => x.itemKey === itemKey) ?? itemTemplate(`comp_${c.id}_q1`);
      rows.push(ratedItem(section, itemKey, q, `${location}.qs[${j}]`, 100 + j * 10, template));
      // A skippable component's rated rows show only while it is applicable, exactly like q1 and q2.
      if (applicable && !base.rules.some((r) => r.ruleKey === `show_${itemKey}`)) {
        const ruleTemplate = base.rules.find((r) => r.ruleKey === `show_comp_${c.id}_q1`);
        newRules.push(like(ruleTemplate, { ruleId: `rule_show_${itemKey}`, versionId: vid, ruleKey: `show_${itemKey}`, targetId: `item_${itemKey}` }));
      }
    });
    keptItems.set(section.sectionId, [...rows, ...kept]);
  });

  // ---- Part 3: Conditions for Learning -----------------------------------------------------------
  {
    const section = sectionByKey.get("part3");
    const kept = keptItems.get(section.sectionId).filter((it) => it.itemType === "LONG_TEXT");
    const rows = p.BELONGING_QS.map((q, j) =>
      ratedItem(section, `conditions_${q.id}`, q, `BELONGING_QS[${j}]`, (j + 1) * 10, itemTemplate(`conditions_${q.id}`)));
    keptItems.set(section.sectionId, [...rows, ...kept]);
  }

  // ---- conditional classroom cards (wording only; their wiring is unchanged) ----------------------
  const CARDS = [
    ["prek_k", p.PREK_K_ITEMS], ["dual_language", p.DUAL_LANG_ITEMS], ["mac_prep", p.MAC_PRER_ITEMS],
    ["ignite", p.IGNITE_ITEMS], ["avid", p.AVID_ITEMS], ["esl", p.ESL_ITEMS], ["content_area", p.CONTENT_AREA_ITEMS],
  ];
  for (const [prefix, list] of CARDS) {
    list.forEach((q, j) => {
      const it = doc.items.find((x) => x.itemKey === `${prefix}_${q.id}`);
      if (!it) throw new Error(`The supplied document has no item ${prefix}_${q.id}.`);
      it.prompt = q.text;
      it.linkUrl = q.link ?? null;
      it.helpText = q.link ? q.linkText ?? null : it.helpText;
    });
  }
  const contentArea = sectionByKey.get("content_area_look_fors");
  contentArea.instructions = `Shown automatically for ${orList(p.CONTENT_AREA_TRIGGERS)}.`;

  // ---- the Part 4 composer's parts ------------------------------------------------------------------
  const parts = p.PART_SEQUENCE.map((e) => ({ ...e }));
  const composer = doc.items.find((x) => x.itemType === "EMAIL_DRAFT_JSON");
  composer.settings = { ...composer.settings, selectableParts: parts };

  // ---- assemble in reading order -------------------------------------------------------------------
  // The supplied document lists sections, items, response sets and options in reading order: sections
  // as the form shows them, a section's items by display order, a response set where its first item
  // is, its options in their display order. The same layout here keeps the two documents diffable.
  const part1Id = sectionByKey.get("part1").sectionId;
  const part1Children = doc.sections.filter((s) => s.parentSectionId === part1Id).sort((a, b) => a.displayOrder - b.displayOrder);
  let next = 0;
  doc.sections = doc.sections.map((s) => ({ ...(s.parentSectionId === part1Id ? part1Children[next++] : s), versionId: vid }));

  doc.items = doc.sections
    .filter((s) => keptItems.has(s.sectionId))
    .flatMap((s) => [...keptItems.get(s.sectionId)].sort((a, b) => a.displayOrder - b.displayOrder));
  for (const it of doc.items) it.versionId = vid;

  const setsById = new Map(doc.responseSets.filter((s) => !setsToRebuild.has(s.responseSetId)).map((s) => [s.responseSetId, s]));
  for (const s of newSets) {
    if (setsById.has(s.responseSetId)) throw new Error(`Response set ${s.responseSetId} is built twice.`);
    setsById.set(s.responseSetId, s);
  }
  const setIdsInReadingOrder = [...new Set(doc.items.map((it) => it.responseSetId).filter(Boolean))];
  if (setIdsInReadingOrder.length !== setsById.size) throw new Error("A response set is unused or an item names an unknown set.");
  doc.responseSets = setIdsInReadingOrder.map((id) => ({ ...setsById.get(id), versionId: vid }));
  const keptOptions = doc.responseOptions.filter((o) => !setsToRebuild.has(o.responseSetId));
  doc.responseOptions = doc.responseSets.flatMap((s) =>
    setsToRebuild.has(s.responseSetId)
      ? newOptions.filter((o) => o.responseSetId === s.responseSetId)
      : keptOptions.filter((o) => o.responseSetId === s.responseSetId));

  // ---- rules ------------------------------------------------------------------------------------------
  const triggers = p.CONTENT_AREA_TRIGGERS;
  doc.rules = [...doc.rules, ...newRules].map((r) => ({ ...r, versionId: vid }));
  const contentRule = doc.rules.find((r) => r.ruleKey === "show_content_area");
  contentRule.comparisonValue = JSON.stringify(triggers);
  contentRule.conditionsJson = JSON.stringify({
    logic: "AND",
    conditions: [{ sourceType: "DIMENSION", sourceKey: "content", operator: "IN", comparisonValue: triggers }],
  });
  // New show rules sit with their component's other show rules.
  const ruleOrder = base.rules.map((r) => r.ruleKey);
  const ruleRank = (r) => {
    const at = ruleOrder.indexOf(r.ruleKey);
    if (at >= 0) return at;
    const siblings = ruleOrder.filter((k) => k.startsWith(r.ruleKey.replace(/_q\d+$/, "_q")));
    return ruleOrder.indexOf(siblings[siblings.length - 1]) + 0.5;
  };
  doc.rules.sort((a, b) => ruleRank(a) - ruleRank(b));

  // ---- dimensions: labels and option lists from META_FIELDS; Part 1's tag field is gone ------------
  const metaById = new Map(p.META_FIELDS.map((f) => [f.id, f]));
  const OPTION_LISTS = { content: ["CONTENT_OPTIONS", p.CONTENT_OPTIONS], classType: ["CLASS_TYPE_OPTIONS", p.CLASS_TYPE_OPTIONS] };
  const dropped = new Set();
  if (!p.markup.hasTagField) dropped.add("tag");
  for (const d of doc.dimensions) {
    const field = metaById.get(d.code);
    if (field) d.label = field.label;
    if (field && Object.hasOwn(field, "hasOther")) d.allowOther = Boolean(field.hasOther);
  }
  for (const [code, [listName, labels]] of Object.entries(OPTION_LISTS)) {
    const dim = doc.dimensions.find((d) => d.code === code);
    const template = doc.dimensionValues.find((v) => v.dimensionId === dim.dimensionId);
    const prefix = template.dimensionValueId.slice(0, template.dimensionValueId.length - template.valueCode.length);
    const rebuilt = labels.map((label, i) => like(template, {
      dimensionValueId: `${prefix}${codeOf(label)}`, valueCode: codeOf(label), label, displayOrder: (i + 1) * 10,
      sourceLocation: `${listName}[${i}]`,
    }));
    const at = doc.dimensionValues.findIndex((v) => v.dimensionId === dim.dimensionId);
    doc.dimensionValues = [
      ...doc.dimensionValues.slice(0, at).filter((v) => v.dimensionId !== dim.dimensionId),
      ...rebuilt,
      ...doc.dimensionValues.slice(at).filter((v) => v.dimensionId !== dim.dimensionId),
    ];
  }
  // School: the prototype's list as the owner amended it. A school that stays keeps its record, renumbered
  // to its place; a new school is a record like the others with the owner's decision as its source.
  {
    const dim = doc.dimensions.find((d) => d.code === "school");
    const records = new Map(doc.dimensionValues.filter((v) => v.dimensionId === dim.dimensionId).map((v) => [v.valueCode, v]));
    const listed = p.SCHOOL_OPTIONS;
    if (listed[listed.length - 1] !== "Other") throw new Error("The prototype's School list no longer ends with Other.");
    for (const label of SCHOOL_AMENDMENT.closed) if (!listed.includes(label)) throw new Error(`The prototype does not list the closed school ${label}.`);
    for (const { label } of SCHOOL_AMENDMENT.added) if (listed.includes(label)) throw new Error(`The prototype already lists ${label}.`);
    const kept = listed.slice(0, -1).filter((label) => !SCHOOL_AMENDMENT.closed.includes(label));
    const labels = [...kept, ...SCHOOL_AMENDMENT.added.map((a) => a.label)].sort((a, b) => a.localeCompare(b, "en"));
    if (labels.filter((l) => kept.includes(l)).join("|") !== kept.join("|")) throw new Error("The prototype's School list is not in the order the amendment sorts by.");
    const template = records.get(codeOf(kept[0]));
    const prefix = template.dimensionValueId.slice(0, template.dimensionValueId.length - template.valueCode.length);
    const rebuilt = [...labels, "Other"].map((label, i) => {
      const added = SCHOOL_AMENDMENT.added.findIndex((a) => a.label === label);
      if (added < 0) return like(records.get(codeOf(label)), { displayOrder: (i + 1) * 10 });
      return like(template, {
        dimensionValueId: `${prefix}${codeOf(label)}`, valueCode: codeOf(label), label, displayOrder: (i + 1) * 10,
        valueGroup: SCHOOL_AMENDMENT.added[added].valueGroup, sourceLocation: `SCHOOL_AMENDMENT.added[${added}]`,
        reviewStatus: `Owner decision ${SCHOOL_AMENDMENT.decidedOn}`,
      });
    });
    const at = doc.dimensionValues.findIndex((v) => v.dimensionId === dim.dimensionId);
    doc.dimensionValues = [
      ...doc.dimensionValues.slice(0, at).filter((v) => v.dimensionId !== dim.dimensionId),
      ...rebuilt,
      ...doc.dimensionValues.slice(at).filter((v) => v.dimensionId !== dim.dimensionId),
    ];
  }
  const droppedIds = new Set(doc.dimensions.filter((d) => dropped.has(d.code)).map((d) => d.dimensionId));
  doc.dimensions = doc.dimensions.filter((d) => !droppedIds.has(d.dimensionId));
  doc.dimensionValues = doc.dimensionValues.filter((v) => !droppedIds.has(v.dimensionId));
  // The prototype's checkboxes: a field of type "checkboxes" takes several values.
  const several = new Set(doc.dimensions.filter((d) => metaById.get(d.code)?.type === "checkboxes").map((d) => d.dimensionId));
  doc.instrumentDimensions = doc.instrumentDimensions
    .filter((pl) => !droppedIds.has(pl.dimensionId))
    .map((pl) => ({ ...pl, versionId: vid, ...(several.has(pl.dimensionId) ? { settings: { ...pl.settings, multiple: true } } : {}) }));

  // ---- behavior and content review ------------------------------------------------------------------
  const cs = doc.behavior.conditionalSections;
  doc.behavior.conditionalSections = Object.fromEntries(Object.entries(cs).map(([key, value]) =>
    key === "artMusicOrCte" ? ["performingArtsVisualArtsOrCte", value] : [key, value]));
  doc.behavior.ratings = {
    scale: scale.map(Number),
    levelNames: Object.fromEntries(scale.map((level) => [level, p.SCALE_NAMES[level]])),
    componentAverage: doc.behavior.ratings.componentAverage,
    unanswered: doc.behavior.ratings.unanswered,
  };
  doc.behavior.emailDraft = { ...doc.behavior.emailDraft, selectableParts: parts.map((e) => ({ ...e })) };
  doc.contentReview = {
    ...doc.contentReview,
    unresolvedPlaceholders: doc.items
      .filter((it) => it.reviewStatus === PLACEHOLDER)
      .map((it) => ({ itemKey: it.itemKey, prompt: it.prompt, sourceLocation: it.sourceLocation })),
  };

  doc.counts = Object.fromEntries(Object.keys(base.counts).map((key) => [key, doc[key].length]));
  return doc;
}

export function renderDocument(doc) {
  return `${JSON.stringify(doc, null, 2)}\n`;
}

export function deriveFromRepository() {
  const base = JSON.parse(fs.readFileSync(path.join(root, REVISION.baseDocument), "utf8"));
  return renderDocument(deriveRevision(base, fs.readFileSync(path.join(root, REVISION.prototype))));
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const text = deriveFromRepository();
  const target = path.join(root, REVISION.output);
  if (process.argv.includes("--check")) {
    const current = fs.existsSync(target) ? fs.readFileSync(target, "utf8") : "";
    if (current !== text) {
      console.error(`${REVISION.output} is stale: run node scripts/derive-instrument-revision.mjs`);
      process.exitCode = 1;
    } else {
      console.log(`${REVISION.output} is current.`);
    }
  } else {
    fs.writeFileSync(target, text, "utf8");
    const doc = JSON.parse(text);
    console.log(JSON.stringify({ written: REVISION.output, versionLabel: doc.instrument.version.versionLabel, counts: doc.counts }, null, 2));
  }
}
