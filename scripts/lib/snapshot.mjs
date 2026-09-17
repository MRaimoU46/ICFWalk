// Reference implementation of the ICFWalk canonical JSON form and compiled instrument
// snapshot. The ColdFusion implementation (src/core/CanonicalJson.cfc and
// src/instrument/SnapshotCompiler.cfc) must produce byte-identical output; the shared
// vectors in tests/fixtures/canonical-json-vectors.json and the golden checksum in
// tests/golden/instrument-snapshot.golden.json prove parity.
//
// Canonical form rules (icfwalk-canonical-json/1):
//   * Objects: keys sorted by UTF-16 code unit order, no whitespace.
//   * Arrays: element order preserved.
//   * Strings: JSON escaping as JSON.stringify (\" \\ \b \f \n \r \t, other control
//     characters and lone surrogates as lowercase \uXXXX); non-ASCII emitted as-is.
//   * Numbers: integers as plain digits; non-integers as the shortest round-trip decimal
//     expansion without exponent notation. NaN/Infinity are rejected.
//   * null for null; undefined is rejected so that every field is explicit.
//   * Checksums are lowercase hex SHA-256 over the UTF-8 bytes of the canonical text.
import crypto from "node:crypto";

export const SNAPSHOT_FORMAT = "icfwalk-instrument-snapshot/1";
export const PLACEHOLDER_REVIEW_STATUS = "Placeholder in source";

function escapeString(value) {
  let out = '"';
  for (let i = 0; i < value.length; i += 1) {
    const code = value.charCodeAt(i);
    const ch = value[i];
    if (ch === '"') out += '\\"';
    else if (ch === "\\") out += "\\\\";
    else if (code === 0x08) out += "\\b";
    else if (code === 0x0c) out += "\\f";
    else if (code === 0x0a) out += "\\n";
    else if (code === 0x0d) out += "\\r";
    else if (code === 0x09) out += "\\t";
    else if (code < 0x20) out += `\\u${code.toString(16).padStart(4, "0")}`;
    else if (code >= 0xd800 && code <= 0xdbff) {
      const next = i + 1 < value.length ? value.charCodeAt(i + 1) : 0;
      if (next >= 0xdc00 && next <= 0xdfff) {
        out += ch + value[i + 1];
        i += 1;
      } else out += `\\u${code.toString(16).padStart(4, "0")}`;
    } else if (code >= 0xdc00 && code <= 0xdfff) out += `\\u${code.toString(16).padStart(4, "0")}`;
    else out += ch;
  }
  return `${out}"`;
}

function formatNumber(value) {
  if (!Number.isFinite(value)) throw new Error("Canonical JSON cannot encode NaN or Infinity.");
  if (Number.isInteger(value)) return BigInt(value).toString();
  // Expand the shortest round-trip representation without exponent notation.
  const text = value.toString();
  if (!/e/i.test(text)) return text;
  const [mantissa, exponentText] = text.toLowerCase().split("e");
  const exponent = Number(exponentText);
  const negative = mantissa.startsWith("-");
  const digits = mantissa.replace("-", "").replace(".", "");
  const pointIndex = (mantissa.replace("-", "").split(".")[0] || "").length + exponent;
  let plain;
  if (pointIndex <= 0) plain = `0.${"0".repeat(-pointIndex)}${digits}`;
  else if (pointIndex >= digits.length) plain = digits + "0".repeat(pointIndex - digits.length);
  else plain = `${digits.slice(0, pointIndex)}.${digits.slice(pointIndex)}`;
  plain = plain.replace(/\.?0+$/, (match) => (match.startsWith(".") ? "" : match));
  return negative ? `-${plain}` : plain;
}

export function canonicalize(value) {
  if (value === null) return "null";
  if (value === undefined) throw new Error("Canonical JSON cannot encode undefined; use null.");
  if (typeof value === "boolean") return value ? "true" : "false";
  if (typeof value === "number") return formatNumber(value);
  if (typeof value === "bigint") return value.toString();
  if (typeof value === "string") return escapeString(value);
  if (Array.isArray(value)) return `[${value.map(canonicalize).join(",")}]`;
  if (typeof value === "object") {
    const keys = Object.keys(value).sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
    return `{${keys.map((key) => `${escapeString(key)}:${canonicalize(value[key])}`).join(",")}}`;
  }
  throw new Error(`Canonical JSON cannot encode type ${typeof value}.`);
}

export function sha256Hex(text) {
  return crypto.createHash("sha256").update(Buffer.from(text, "utf8")).digest("hex");
}

const orNull = (value) => (value === undefined ? null : value);
const byKeys = (...getters) => (a, b) => {
  for (const getter of getters) {
    const left = getter(a);
    const right = getter(b);
    if (left < right) return -1;
    if (left > right) return 1;
  }
  return 0;
};

// Converts the authoring JSON (logical IDs) into the normalized, key-based contract that the
// snapshot compiler consumes. Referential validation happens elsewhere; unknown references
// become null so that the validator can report them precisely.
export function normalizeConfig(config) {
  const sectionKeyById = new Map(config.sections.map((s) => [s.sectionId, s.sectionKey]));
  const itemKeyById = new Map(config.items.map((i) => [i.itemId, i.itemKey]));
  const setKeyById = new Map(config.responseSets.map((r) => [r.responseSetId, r.setKey]));
  const dimensionCodeById = new Map(config.dimensions.map((d) => [d.dimensionId, d.code]));
  const lookup = (map, id) => (id === null || id === undefined ? null : orNull(map.get(id)));

  const sections = config.sections.map((s) => ({
    authoringId: s.sectionId,
    sectionKey: s.sectionKey,
    parentSectionKey: lookup(sectionKeyById, s.parentSectionId),
    displayOrder: s.displayOrder,
    title: s.title,
    instructions: orNull(s.instructions),
    colorHex: orNull(s.colorHex),
    notesEnabled: Boolean(s.notesEnabled),
    optionalSection: Boolean(s.optionalSection),
    requiredSection: Boolean(s.requiredSection),
    active: Boolean(s.active),
    settings: orNull(s.settings) ?? {},
    sourceLocation: orNull(s.sourceLocation),
    reviewStatus: orNull(s.reviewStatus),
    revisionNotes: orNull(s.revisionNotes),
  })).sort(byKeys((x) => x.sectionKey));

  const items = config.items.map((i) => ({
    authoringId: i.itemId,
    itemKey: i.itemKey,
    sectionKey: lookup(sectionKeyById, i.sectionId),
    responseSetKey: lookup(setKeyById, i.responseSetId),
    reportingKey: orNull(i.reportingKey),
    contentFamily: orNull(i.contentFamily),
    itemType: i.itemType,
    prompt: i.prompt,
    helpText: orNull(i.helpText),
    placeholder: orNull(i.placeholder),
    linkUrl: orNull(i.linkUrl),
    displayOrder: i.displayOrder,
    required: Boolean(i.required),
    reportable: Boolean(i.reportable),
    active: Boolean(i.active),
    settings: orNull(i.settings) ?? {},
    sourceLocation: orNull(i.sourceLocation),
    reviewStatus: orNull(i.reviewStatus),
    revisionNotes: orNull(i.revisionNotes),
  })).sort(byKeys((x) => x.itemKey));

  const responseSets = config.responseSets.map((r) => ({
    authoringId: r.responseSetId,
    setKey: r.setKey,
    name: r.name,
    selectionMode: r.selectionMode,
    allowNa: Boolean(r.allowNa),
    scoreEnabled: Boolean(r.scoreEnabled),
    active: Boolean(r.active),
    sourceLocation: orNull(r.sourceLocation),
    reviewStatus: orNull(r.reviewStatus),
    revisionNotes: orNull(r.revisionNotes),
  })).sort(byKeys((x) => x.setKey));

  const responseOptions = config.responseOptions.map((o) => ({
    authoringId: o.optionId,
    setKey: lookup(setKeyById, o.responseSetId),
    optionKey: o.optionKey,
    storedCode: o.storedCode,
    label: o.label,
    definition: orNull(o.definition),
    numericScore: orNull(o.numericScore),
    isNa: Boolean(o.isNa),
    displayOrder: o.displayOrder,
    active: Boolean(o.active),
    sourceLocation: orNull(o.sourceLocation),
    reviewStatus: orNull(o.reviewStatus),
    revisionNotes: orNull(o.revisionNotes),
  })).sort(byKeys((x) => x.setKey ?? "", (x) => x.optionKey));

  const rules = config.rules.map((r) => {
    let conditions = null;
    try {
      conditions = JSON.parse(r.conditionsJson);
    } catch {
      conditions = null;
    }
    const targetKey = r.targetType === "SECTION"
      ? lookup(sectionKeyById, r.targetId)
      : r.targetType === "ITEM"
        ? lookup(itemKeyById, r.targetId)
        : r.targetType === "DIMENSION"
          ? lookup(dimensionCodeById, r.targetId)
          : null;
    return {
      authoringId: r.ruleId,
      ruleKey: r.ruleKey,
      targetType: r.targetType,
      targetKey,
      effect: r.effect,
      effectValue: orNull(r.effectValue),
      sourceType: r.sourceType,
      sourceKey: r.sourceId,
      operator: r.operator,
      comparisonValue: orNull(r.comparisonValue),
      conditionLogic: orNull(r.conditionLogic),
      conditions,
      active: Boolean(r.active),
      sourceLocation: orNull(r.sourceLocation),
      reviewStatus: orNull(r.reviewStatus),
      revisionNotes: orNull(r.revisionNotes),
    };
  }).sort(byKeys((x) => x.ruleKey));

  const dimensions = config.dimensions.map((d) => ({
    authoringId: d.dimensionId,
    code: d.code,
    label: d.label,
    dataType: d.dataType,
    valueMode: orNull(d.valueMode),
    reportable: Boolean(d.reportable),
    sensitive: Boolean(d.sensitive),
    allowOther: Boolean(d.allowOther),
    active: Boolean(d.active),
    settings: orNull(d.settings) ?? {},
    sourceLocation: orNull(d.sourceLocation),
    reviewStatus: orNull(d.reviewStatus),
    revisionNotes: orNull(d.revisionNotes),
  })).sort(byKeys((x) => x.code));

  const dimensionValues = config.dimensionValues.map((v) => ({
    authoringId: v.dimensionValueId,
    dimensionCode: lookup(dimensionCodeById, v.dimensionId),
    valueCode: v.valueCode,
    label: v.label,
    displayOrder: v.displayOrder,
    valueGroup: orNull(v.valueGroup),
    gradeBand: orNull(v.gradeBand),
    active: Boolean(v.active),
    effectiveStart: orNull(v.effectiveStart),
    effectiveEnd: orNull(v.effectiveEnd),
    sourceLocation: orNull(v.sourceLocation),
    reviewStatus: orNull(v.reviewStatus),
    revisionNotes: orNull(v.revisionNotes),
  })).sort(byKeys((x) => x.dimensionCode ?? "", (x) => x.valueCode));

  const instrumentDimensions = config.instrumentDimensions.map((p) => ({
    authoringId: p.instrumentDimensionId,
    dimensionCode: lookup(dimensionCodeById, p.dimensionId),
    sectionKey: lookup(sectionKeyById, p.sectionId),
    displayOrder: p.displayOrder,
    required: Boolean(p.required),
    visibleByDefault: Boolean(p.visibleByDefault),
    ruleKey: orNull(p.ruleKey),
    labelOverride: orNull(p.labelOverride),
    placeholder: orNull(p.placeholder),
    active: Boolean(p.active),
    settings: orNull(p.settings) ?? {},
    sourceLocation: orNull(p.sourceLocation),
    reviewStatus: orNull(p.reviewStatus),
    revisionNotes: orNull(p.revisionNotes),
  })).sort(byKeys((x) => x.dimensionCode ?? ""));

  const version = config.instrument.version;
  return {
    schemaVersion: orNull(config.schemaVersion),
    source: {
      file: orNull(config.source?.file),
      sha256: orNull(config.source?.sha256),
      authority: orNull(config.source?.authority),
    },
    instrument: {
      authoringId: config.instrument.instrumentId,
      code: config.instrument.code,
      name: config.instrument.name,
      description: orNull(config.instrument.description),
      active: Boolean(config.instrument.active),
    },
    version: {
      authoringId: version.versionId,
      versionLabel: version.versionLabel,
      extractedOn: orNull(version.extractedOn),
      sourceFile: orNull(version.sourceFile),
      sourceSha256: orNull(version.sourceSha256),
      reviewStatus: orNull(version.reviewStatus),
      revisionNotes: orNull(version.revisionNotes),
    },
    definitions: { sections, items, responseSets, responseOptions, rules, dimensions, dimensionValues, instrumentDimensions },
    behavior: orNull(config.behavior),
    contentReview: orNull(config.contentReview),
  };
}

export function countDefinitions(definitions) {
  return {
    sections: definitions.sections.length,
    items: definitions.items.length,
    responseSets: definitions.responseSets.length,
    responseOptions: definitions.responseOptions.length,
    rules: definitions.rules.length,
    dimensions: definitions.dimensions.length,
    dimensionValues: definitions.dimensionValues.length,
    instrumentDimensions: definitions.instrumentDimensions.length,
    placeholders: definitions.items.filter((i) => i.reviewStatus === PLACEHOLDER_REVIEW_STATUS).length,
  };
}

export function compileSnapshot(normalized) {
  const counts = countDefinitions(normalized.definitions);
  const snapshot = {
    snapshotFormat: SNAPSHOT_FORMAT,
    schemaVersion: normalized.schemaVersion,
    source: normalized.source,
    instrument: normalized.instrument,
    version: normalized.version,
    definitions: normalized.definitions,
    behavior: normalized.behavior,
    contentReview: normalized.contentReview,
    counts,
  };
  const canonicalJson = canonicalize(snapshot);
  const definitionsCanonicalJson = canonicalize(normalized.definitions);
  return {
    snapshot,
    canonicalJson,
    checksum: sha256Hex(canonicalJson),
    definitionsCanonicalJson,
    definitionsChecksum: sha256Hex(definitionsCanonicalJson),
    counts,
  };
}
