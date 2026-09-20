/**
 * Shared summary formatting (Phase 5). Twin of src/walks/WalkSummaryFormatter.cfc;
 * tests/fixtures/summary-vectors.json proves both produce byte-identical output.
 *
 * Every function here is a pure, side-effect-free function of the render model
 * (icfwalk-render-model/1), the working state ({ dimensions, responses }) and the engine
 * evaluation (rules.js evaluate / VisibilityEngine.evaluateVisibility). Nothing fetches, logs,
 * or reads the DOM, and no section, item, dimension, or option is named: every string comes from
 * the model (titles, prompts, option labels, placement labels, partNumber, selectableParts,
 * behavior.export) or from SUMMARY_PRESENTATION below, which is the same device as LIST_CARD in
 * app.js (BUILD_STATUS Phase 3 decision 5).
 *
 * Output contract (both twins, byte-identical):
 *   summaryText(model, state, evaluation)                     -> string, "\n" joined, no trailing newline
 *   fileName(model, state, evaluation, walkId)                -> "ICFWalk_<label>.txt"
 *   emailDraft(model, state, evaluation, includedPartKeys)    -> { subject, body }
 *   componentAverage(section, state, evaluation)              -> "3.5" | "n/a"
 *   averageText(sum, count)                                   -> "3.5" | "n/a"
 *   sanitizeFileLabel(label)                                  -> safe filename label
 *
 * Resolved source conflicts are recorded in docs/PHASE_5_IMPLEMENTATION_BRIEF.md section 14 and
 * summarized in BUILD_STATUS.md (Phase 5 decisions). The ones that shape the code below:
 *   14.1 conditional-card export order   (EXPORT_ORDER_HOIST)
 *   14.2 a dimension prints only while ANSWERED (hidden Period and hidden sections are excluded)
 *   14.3 the content-area heading is the section title uppercased
 *   14.4 one trailing colon is stripped from a placement label before ": " is appended
 *   14.5 non-scored choices print the option label; scored choices print <code>/<max>
 *   14.6 Part 4 export labels come from SUMMARY_PRESENTATION.part4Labels
 *   14.8 a non-scored choice among scored siblings prints "<prompt>:  [<label>]"
 *   14.14/14.15 lines join with "\n"; no trailing newline, no BOM
 */
import { dimensionDisplay, ratingSummary } from "./walk-state.js";

export const SUMMARY_CONTRACT = "icfwalk-summary/1";

// Characters that must survive byte-exactly. Written as escapes so the contract never depends on
// how a source file happens to be decoded (the CFML twin builds the same values with chr()).
const MIDDLE_DOT = "\u00B7"; // U+00B7 MIDDLE DOT, separates a part number from its title
const EM_DASH = "\u2014"; // U+2014 EM DASH
const BULLET = "\u2022"; // U+2022 BULLET
const RIGHT_SINGLE_QUOTE = "\u2019"; // U+2019 RIGHT SINGLE QUOTATION MARK

const TITLE_SEPARATOR = ` ${MIDDLE_DOT} `;
const HEADING_SEPARATOR = ` ${EM_DASH} `;

const SUMMARY_TITLE = "ICFWALK SUMMARY";
const SUMMARY_RULE = "================";
const UNANSWERED = "not answered";
const NONE_NOTED = "(none noted)";
const NOT_PART_SUFFIX = "  (not part of this lesson at the time of the visit)";
const AVG_PREFIX = "  (avg: ";
const AVG_SUFFIX = ")";
const NOTES_PREFIX = "Notes: ";
const NO_AVERAGE = "n/a";
const VALUE_GAP = "  "; // two spaces before the bracketed value, as in the prototype

/**
 * The only presentation literals besides the prototype's template sentences. Dimension codes are
 * addressing, not instrument content -- the same justification as LIST_CARD in app.js.
 */
export const SUMMARY_PRESENTATION = {
  // Part 4 export labels by item key (brief 14.6). An `exportLabel` item setting would remove this.
  part4Labels: { summary_strengths: "Strengths", summary_growth: "Growth areas" },
  // Dimensions the teacher email names, in the order the prototype composes them.
  emailTitleDimensions: ["grade", "content"],
  emailDateDimension: "date",
  emailObserverDimension: "observer",
};

/**
 * Brief 14.1. behavior.export.preservePrototypeSectionOrder delegates the conditional-card order
 * to the prototype, whose order differs from the snapshot's displayOrder in exactly one place.
 * The rule is keyed on the SHOW rule's source dimension and never on a section key: conditional
 * cards sourced from `source` print immediately before the LAST conditional card sourced from
 * `beforeLastSourcedBy`. Today that places Content-Area before ESL. When content owners renumber
 * displayOrder (the OPEN item), the rule becomes a no-op because the card is already there.
 */
export const EXPORT_ORDER_HOIST = { source: "content", beforeLastSourcedBy: "classType" };

/** Prototype template sentences, transcribed verbatim (brief sections 5 and 8). */
const EMAIL = {
  opening:
    "I enjoyed my time stopping by your classroom today. I wanted to share a quick feedback note from what I observed during the visit",
  inPrefix: " in ",
  onPrefix: " on ",
  nothingSelected: `(No sections were selected ${EM_DASH} check at least one part above, then update the draft.)`,
  closing: `Stop by whenever you can, as I would love to talk through this with you ${EM_DASH} thanks again for what you do in your classroom for our students.`,
  signaturePlaceholder: "[Your name]",
  subject: `Quick note from today${RIGHT_SINGLE_QUOTE}s walk-through`,
  notApplicableBullet: `${BULLET} Not part of this lesson at the time of the visit.`,
  noPartNotes: "(No notes recorded for this part.)",
  noComponentNotes: "(No notes recorded for this component.)",
  noSummaryNotes: "(No summary notes recorded yet.)",
  nestedNotesInfix: " notes: ",
};

// ---- small model helpers -----------------------------------------------------------------------

const childrenOf = (section) => section.children || [];
const itemsOf = (section) => section.items || [];
const placementsOf = (section) => section.placements || [];

/** Items the export prints as "- <prompt>  [<value>]". Applicability and display rows never print. */
const choiceItems = (section) => itemsOf(section).filter((it) => it.layout === "question" || it.layout === "choice-row");

/** Scored question items -- the ones a component average is taken over. */
const ratedItems = (section) =>
  itemsOf(section).filter((it) => it.layout === "question" && it.responseSet && it.responseSet.scoreEnabled);

const notesItemOf = (section) => itemsOf(section).find((it) => it.layout === "notes") || null;

/** Part 4's free-text items that carry an export label. */
const labelledTextItems = (section) =>
  itemsOf(section).filter((it) => it.layout === "text" && SUMMARY_PRESENTATION.part4Labels[it.itemKey] !== undefined);

const isAnswered = (evaluation, key) => evaluation.responseStates[key] === "ANSWERED";

function textOf(state, itemKey) {
  const r = state.responses[itemKey];
  return r && typeof r.textValue === "string" ? r.textValue : "";
}

/** Answered note text for a section, or "" when the section has no note or it is empty. */
function notesTextOf(section, state, evaluation) {
  const it = notesItemOf(section);
  if (!it || !isAnswered(evaluation, it.itemKey)) return "";
  return textOf(state, it.itemKey);
}

/**
 * A dimension's display text, but only while the engine reports it ANSWERED (brief 14.2): a value
 * the pinned instrument currently hides is retained in the database and never exported, named in a
 * file, or quoted in an email.
 */
function dimensionText(model, state, evaluation, code) {
  if (evaluation.dimensionStates[code] !== "ANSWERED") return "";
  return dimensionDisplay(model, state, code);
}

/** Locale-independent upper case, matching Java's toUpperCase(Locale.ROOT) in the CFML twin. */
const upper = (text) => String(text).toUpperCase();

/** "Part 1 · Target / Taxonomy / Pacing" -> "PART 1 — TARGET / TAXONOMY / PACING" (brief section 5). */
const headingOf = (section) => upper(String(section.title).split(TITLE_SEPARATOR).join(HEADING_SEPARATOR));

/** "Part 3 · Conditions for Learning" -> "Conditions for Learning". */
function titleAfterSeparator(section) {
  const title = String(section.title);
  const at = title.indexOf(TITLE_SEPARATOR);
  return at < 0 ? title : title.slice(at + TITLE_SEPARATOR.length);
}

/** Brief 14.4: "Visit occurred at the:" labels one trailing colon, which is not doubled. */
function placementLabel(placement) {
  const label = String(placement.label);
  return label.endsWith(":") ? label.slice(0, -1) : label;
}

function eachSection(model, visit) {
  const walk = (node) => {
    visit(node);
    for (const child of childrenOf(node)) walk(child);
  };
  walk(model.root);
}

/** The dimension a section's SHOW rule reads, or "" when it has none. */
function ruleSourceDimension(model, section) {
  for (const ruleKey of section.ruleKeys || []) {
    for (const rule of model.rules) {
      if (rule.ruleKey !== ruleKey) continue;
      for (const condition of (rule.conditions && rule.conditions.conditions) || []) {
        if (condition.sourceType === "DIMENSION") return String(condition.sourceKey);
      }
    }
  }
  return "";
}

// ---- values and lines ---------------------------------------------------------------------------

function maxScoreOf(responseSet) {
  let max = 0;
  for (const option of responseSet.options) {
    if (typeof option.numericScore === "number" && option.numericScore > max) max = option.numericScore;
  }
  return max;
}

function selectedOption(item, state) {
  const stored = (state.responses[item.itemKey] || {}).storedCode;
  if (typeof stored !== "string" || !stored) return null;
  return item.responseSet.options.find((o) => o.storedCode === stored) || null;
}

/** Brief 14.5: scored choices print <code>/<max>; every other choice prints its option label. */
function choiceValue(item, state, evaluation) {
  if (!isAnswered(evaluation, item.itemKey)) return UNANSWERED;
  const option = selectedOption(item, state);
  if (!option) return UNANSWERED;
  if (item.responseSet.scoreEnabled) return `${option.storedCode}/${maxScoreOf(item.responseSet)}`;
  return option.label;
}

/**
 * Brief 14.8: a non-scored choice item sitting among scored siblings prints its prompt with a
 * trailing colon (the prototype's "- Pacing:  [ON pace]"). Stated as a data rule, not a key.
 */
const isLabelledChoice = (item, section) =>
  !(item.responseSet && item.responseSet.scoreEnabled) && ratedItems(section).length > 0;

const choiceLine = (item, section, state, evaluation) =>
  `- ${item.prompt}${isLabelledChoice(item, section) ? ":" : ""}${VALUE_GAP}[${choiceValue(item, state, evaluation)}]`;

/** A choice row prints unless the engine hides it or reports it not applicable. */
const choicePrints = (item, evaluation) =>
  evaluation.items[item.itemKey] !== false && evaluation.responseStates[item.itemKey] !== "NOT_APPLICABLE";

function pushPlacementLines(lines, model, section, state, evaluation) {
  for (const placement of placementsOf(section)) {
    const text = dimensionText(model, state, evaluation, placement.dimensionCode);
    if (!text) continue;
    lines.push(`${placementLabel(placement)}: ${text}`);
  }
}

function pushChoiceLines(lines, section, state, evaluation) {
  for (const item of choiceItems(section)) {
    if (!choicePrints(item, evaluation)) continue;
    lines.push(choiceLine(item, section, state, evaluation));
  }
}

function pushNotesLine(lines, section, state, evaluation) {
  const text = notesTextOf(section, state, evaluation);
  if (text) lines.push(NOTES_PREFIX + text);
}

// ---- averages -----------------------------------------------------------------------------------

/**
 * One decimal place with JavaScript's Number.prototype.toFixed(1) semantics: the IEEE-754 double
 * quotient is rounded half away from zero on its exact binary value, which is why 3.05 (stored as
 * 3.0499999...) formats as "3.0" while 2.25 (exact) formats as "2.3". The CFML twin reproduces this
 * with BigDecimal(double).setScale(1, HALF_UP); the shared vectors pin the agreement.
 */
export function averageText(sum, count) {
  if (!count) return NO_AVERAGE;
  return (sum / count).toFixed(1);
}

/**
 * COND-15 / SUM-02: the mean of the numeric scores of answered rated items only. A blank rating is
 * never counted as zero, and a component with nothing answered has no average.
 */
export function componentAverage(section, state, evaluation) {
  let sum = 0;
  let count = 0;
  for (const item of ratedItems(section)) {
    if (!isAnswered(evaluation, item.itemKey)) continue;
    const option = selectedOption(item, state);
    if (!option || typeof option.numericScore !== "number") continue;
    sum += option.numericScore;
    count += 1;
  }
  return averageText(sum, count);
}

// ---- summary text -------------------------------------------------------------------------------

/**
 * Top-level sections in export order. Snapshot order, with the one documented reordering of
 * EXPORT_ORDER_HOIST applied to the conditional classroom cards (brief 14.1).
 */
export function exportSections(model) {
  const top = childrenOf(model.root);
  const hoisted = top.filter((s) => s.conditional && ruleSourceDimension(model, s) === EXPORT_ORDER_HOIST.source);
  if (!hoisted.length) return top;
  const rest = top.filter((s) => !hoisted.includes(s));
  const anchors = rest.filter(
    (s) => s.conditional && ruleSourceDimension(model, s) === EXPORT_ORDER_HOIST.beforeLastSourcedBy,
  );
  if (!anchors.length) return top;
  const at = rest.indexOf(anchors[anchors.length - 1]);
  return [...rest.slice(0, at), ...hoisted, ...rest.slice(at)];
}

/**
 * The walk's identifying block: a top-level section that carries placements and no responses at
 * all. It prints its placement lines directly under the title rule, with no heading and no blank
 * line, exactly as the prototype prints META_FIELDS.
 */
const isIdentityBlock = (section) =>
  !section.conditional && itemsOf(section).length === 0 && childrenOf(section).length === 0;

function emitTopSection(lines, model, section, state, evaluation) {
  if (evaluation.sections[section.sectionKey] === false) return;
  if (isIdentityBlock(section)) {
    pushPlacementLines(lines, model, section, state, evaluation);
    return;
  }
  lines.push("");
  lines.push(headingOf(section));
  pushPlacementLines(lines, model, section, state, evaluation);
  pushChoiceLines(lines, section, state, evaluation);
  for (const item of labelledTextItems(section)) {
    const text = isAnswered(evaluation, item.itemKey) ? textOf(state, item.itemKey) : "";
    lines.push(`${SUMMARY_PRESENTATION.part4Labels[item.itemKey]}: ${text || NONE_NOTED}`);
  }
  pushNotesLine(lines, section, state, evaluation);
  for (const child of childrenOf(section)) emitChildSection(lines, model, child, state, evaluation);
}

function emitChildSection(lines, model, section, state, evaluation) {
  if (evaluation.sections[section.sectionKey] === false) return;
  if (section.presentation === "component") {
    emitComponent(lines, model, section, state, evaluation);
    return;
  }
  // A block the renderer shows without a heading of its own prints straight under the part heading.
  if (section.headingVisible !== false) {
    lines.push("");
    lines.push(headingOf(section));
  }
  pushPlacementLines(lines, model, section, state, evaluation);
  pushChoiceLines(lines, section, state, evaluation);
  pushNotesLine(lines, section, state, evaluation);
  for (const child of childrenOf(section)) emitChildSection(lines, model, child, state, evaluation);
}

function emitComponent(lines, model, section, state, evaluation) {
  lines.push("");
  const heading = `${section.partNumber} ${headingOf(section)}`;
  // SUM-03: a component whose rated rows are all NOT_APPLICABLE is labelled, has no average and no
  // rating lines, and may still carry its retained notes.
  if (ratingSummary(section, evaluation).notApplicable) {
    lines.push(heading + NOT_PART_SUFFIX);
    pushNotesLine(lines, section, state, evaluation);
    return;
  }
  lines.push(heading + AVG_PREFIX + componentAverage(section, state, evaluation) + AVG_SUFFIX);
  pushChoiceLines(lines, section, state, evaluation);
  pushNotesLine(lines, section, state, evaluation);
}

/** The whole text export. Lines join with "\n"; there is no trailing newline and no BOM (14.14/15). */
export function summaryText(model, state, evaluation) {
  const lines = [SUMMARY_TITLE, SUMMARY_RULE];
  for (const section of exportSections(model)) emitTopSection(lines, model, section, state, evaluation);
  return lines.join("\n");
}

// ---- file name ----------------------------------------------------------------------------------

/**
 * SUM-05. Runs of characters outside [A-Za-z0-9_-] collapse to a single underscore and case is
 * kept, exactly as the prototype does. Nothing else survives, so "..", "/", "\", and quotes can
 * never reach a Content-Disposition header or a path.
 */
export function sanitizeFileLabel(label) {
  return String(label).replace(/[^a-z0-9_-]+/gi, "_");
}

/**
 * Parses behavior.export.fileNamePattern ("ICFWalk_<grade>_<content>_<date>.txt") into the literal
 * prefix and suffix, the dimension codes it names, and the separator between them. The pattern is
 * the contract for the exported file name, so the codes are read from it rather than restated here.
 */
export function fileNameSpec(model) {
  const pattern = String(((model.behavior || {}).export || {}).fileNamePattern || "");
  const tokens = [];
  const re = /<([^<>]+)>/g;
  let match;
  while ((match = re.exec(pattern)) !== null) tokens.push({ code: match[1], start: match.index, end: re.lastIndex });
  if (!tokens.length) {
    throw new Error("behavior.export.fileNamePattern names no dimension: " + pattern);
  }
  let separator = "";
  for (let i = 1; i < tokens.length; i++) {
    const gap = pattern.slice(tokens[i - 1].end, tokens[i].start);
    if (i === 1) separator = gap;
    else if (gap !== separator) {
      throw new Error("behavior.export.fileNamePattern mixes separators: " + pattern);
    }
  }
  return {
    prefix: pattern.slice(0, tokens[0].start),
    suffix: pattern.slice(tokens[tokens.length - 1].end),
    separator,
    dimensionCodes: tokens.map((t) => t.code),
  };
}

/**
 * "ICFWalk_<label>.txt"; a walk with nothing named falls back to its id (both are sanitized).
 *
 * The label is sanitized, but the pattern's own literals are instrument configuration, so the
 * assembled name is checked before it is handed to a caller that will put it in a
 * Content-Disposition header. A pattern that could smuggle a quote, a path separator, or a
 * traversal sequence into that header is a configuration fault and is refused loudly rather than
 * quietly mangled -- the same treatment fileNameSpec already gives a pattern it cannot read.
 */
export function fileName(model, state, evaluation, walkId) {
  const spec = fileNameSpec(model);
  const parts = spec.dimensionCodes.map((code) => dimensionText(model, state, evaluation, code)).filter(Boolean);
  const label = parts.join(spec.separator) || String(walkId === undefined || walkId === null ? "" : walkId);
  const name = spec.prefix + sanitizeFileLabel(label) + spec.suffix;
  if (!/^[A-Za-z0-9_.-]+$/.test(name) || name.includes("..")) {
    throw new Error(`behavior.export.fileNamePattern yields an unsafe file name: ${name}`);
  }
  return name;
}

// ---- email draft ---------------------------------------------------------------------------------

/** The Part 4 composer item: the one item the model lays out as an email draft. */
export function emailItem(model) {
  let found = null;
  eachSection(model, (section) => {
    for (const item of itemsOf(section)) if (item.layout === "email-draft") found = found || item;
  });
  if (!found) throw new Error("The render model has no email-draft item.");
  return found;
}

/** The selectable parts the composer offers, in the order the item's settings declare them. */
export const selectableParts = (model) => (emailItem(model).settings || {}).selectableParts || [];

/**
 * Resolves a selectable part to the section it summarizes, by data and never by key. A component
 * is the section carrying its partNumber (falling back to its compId); every other kind is the
 * top-level part section whose title opens with the part number. Failing loudly beats quietly
 * dropping a part the person asked for.
 */
export function resolvePartSection(model, part) {
  const partNum = String(part.partNum);
  let found = null;
  if (String(part.kind) === "component") {
    const compId = part.compId === undefined || part.compId === null ? "" : String(part.compId);
    eachSection(model, (section) => {
      if (found) return;
      const number = section.partNumber || (section.settings || {}).partNumber;
      if (number !== undefined && number !== null && String(number) === partNum) found = section;
    });
    if (!found && compId) {
      eachSection(model, (section) => {
        if (!found && section.sectionKey === compId) found = section;
      });
    }
  } else {
    for (const section of childrenOf(model.root)) {
      if (!found && String(section.title).startsWith(partNum)) found = section;
    }
  }
  if (!found) {
    throw new Error(`Selectable part '${part.key}' does not resolve to a section in this instrument version.`);
  }
  return found;
}

function componentPartLines(model, part, state, evaluation) {
  const section = resolvePartSection(model, part);
  const lines = [`${part.partNum}${HEADING_SEPARATOR}${part.compTitle}:`];
  const notApplicable = ratingSummary(section, evaluation).notApplicable;
  if (notApplicable) lines.push(EMAIL.notApplicableBullet);
  const notes = notesTextOf(section, state, evaluation);
  if (notes) lines.push(NOTES_PREFIX + notes);
  else if (!notApplicable) lines.push(EMAIL.noComponentNotes);
  return lines;
}

function part1PartLines(model, part, state, evaluation) {
  const section = resolvePartSection(model, part);
  const lines = [`${part.partNum}${HEADING_SEPARATOR}${titleAfterSeparator(section)}:`];
  let any = false;
  for (const child of childrenOf(section)) {
    const notes = notesTextOf(child, state, evaluation);
    if (!notes) continue;
    lines.push(`${child.title}${EMAIL.nestedNotesInfix}${notes}`);
    any = true;
  }
  if (!any) lines.push(EMAIL.noPartNotes);
  return lines;
}

function notesPartLines(model, part, state, evaluation) {
  const section = resolvePartSection(model, part);
  const lines = [`${part.partNum}${HEADING_SEPARATOR}${titleAfterSeparator(section)}:`];
  const notes = notesTextOf(section, state, evaluation);
  lines.push(notes ? NOTES_PREFIX + notes : EMAIL.noPartNotes);
  return lines;
}

function summaryPartLines(model, part, state, evaluation) {
  const section = resolvePartSection(model, part);
  const lines = [`${part.label}:`];
  let any = false;
  for (const item of labelledTextItems(section)) {
    if (!isAnswered(evaluation, item.itemKey)) continue;
    const text = textOf(state, item.itemKey);
    if (!text) continue;
    lines.push(`${SUMMARY_PRESENTATION.part4Labels[item.itemKey]}: ${text}`);
    any = true;
  }
  if (!any) lines.push(EMAIL.noSummaryNotes);
  return lines;
}

function partLines(model, part, state, evaluation) {
  switch (String(part.kind)) {
    case "component":
      return componentPartLines(model, part, state, evaluation);
    case "part1merged":
      return part1PartLines(model, part, state, evaluation);
    case "belonging":
      return notesPartLines(model, part, state, evaluation);
    case "summary":
      return summaryPartLines(model, part, state, evaluation);
    default:
      throw new Error(`Unsupported selectable part kind '${part.kind}'.`);
  }
}

/**
 * SUM-06. The draft the composer puts in the editable box. Parts appear in the order the item's
 * settings declare them however the checkboxes were ticked, and only the checked ones appear.
 * Nothing here sends anything: the result is text for a person to review, edit, copy, or hand to
 * their own mail client.
 */
export function emailDraft(model, state, evaluation, includedPartKeys) {
  const included = new Set((includedPartKeys || []).map(String));
  const chosen = selectableParts(model).filter((part) => included.has(String(part.key)));
  const title = SUMMARY_PRESENTATION.emailTitleDimensions
    .map((code) => dimensionText(model, state, evaluation, code))
    .filter(Boolean)
    .join(" ");
  const date = dimensionText(model, state, evaluation, SUMMARY_PRESENTATION.emailDateDimension);
  const observer = dimensionText(model, state, evaluation, SUMMARY_PRESENTATION.emailObserverDimension);

  let body = EMAIL.opening + (title ? EMAIL.inPrefix + title : "") + (date ? EMAIL.onPrefix + date : "") + ".\n";
  for (const part of chosen) body += "\n" + partLines(model, part, state, evaluation).join("\n") + "\n";
  if (!chosen.length) body += "\n" + EMAIL.nothingSelected + "\n";
  body += "\n" + EMAIL.closing + "\n\n";
  body += observer || EMAIL.signaturePlaceholder;

  const subject =
    EMAIL.subject +
    (title ? HEADING_SEPARATOR + title : "") +
    (chosen.length ? ` (${chosen.map((p) => p.label).join(", ")})` : "");

  return { subject, body };
}
