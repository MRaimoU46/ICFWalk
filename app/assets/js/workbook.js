/**
 * Instrument workbooks: an instrument version as an Excel file, and an edited Excel file back into
 * the document the import route takes (the Excel round-trip, docs/ARCHITECTURE.md).
 *
 * WHAT THE WORKBOOK IS. One sheet per table of the authoring document, laid out exactly like the
 * reviewed config/ICFWalk_Instrument_Configuration_Aligned.xlsx that content owners already know:
 * a title row, a description row, the column headers on row 3, one row per record from row 4.
 * Sheet and column names are that workbook's (item_definition, response_set_id, settings_json ...).
 * Two sheets are added: "Start Here", which says how to edit, and "document", which carries the
 * parts of the document that are not tables (schemaVersion, source, behavior, contentReview) and
 * which version the file was downloaded from. Nothing on "Start Here" is read back.
 *
 * WHERE THE WORK HAPPENS. Entirely in the browser. The server never parses a spreadsheet: this
 * module turns the workbook into the same JSON document a JSON upload sends, and the existing
 * import route validates it with every rule it applies to any document. There is no new upload
 * path, and a workbook cannot do anything a JSON document could not.
 *
 * ERRORS POINT AT CELLS. A problem the workbook itself has (a missing sheet, a column that is not
 * there, "maybe" in a TRUE/FALSE column) is reported with its sheet, row and column before anything
 * is sent. A problem the server finds is reported against a document path; `locate(path)` turns
 * that path back into the sheet, row and column the value came from -- including the paths into
 * the normalized definitions, whose rows the server sorts by key, by reproducing that sort.
 *
 * NO DEPENDENCIES. An .xlsx file is a zip of XML parts. The zip is read and written here, with the
 * platform's own raw-deflate streams (CompressionStream / DecompressionStream, in every current
 * browser and in Node), and the XML with a small non-validating reader that refuses a DOCTYPE
 * outright, so no entity or external reference is ever expanded. Size limits stop a file that
 * inflates to far more than an instrument could be.
 */

export const WORKBOOK_FORMAT = "icfwalk-instrument-workbook/1";
export const XLSX_MIME = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";

const LIMITS = {
  entries: 2000,
  entryBytes: 20 * 1024 * 1024,
  totalBytes: 64 * 1024 * 1024,
  rowsPerSheet: 20000,
  cellChars: 32767,   // Excel's own limit for one cell
};

const HEADER_ROW = 3;         // where this module writes the column names
const HEADER_SEARCH_ROWS = 10; // how far down a reader looks for them in someone else's workbook

// ---- the format -----------------------------------------------------------------------------

// Column kinds. What a cell may hold, and what the document gets:
//   id    text, trimmed; a reference between rows
//   text  text, exactly as typed
//   int   a whole number
//   num   a number
//   bool  TRUE/FALSE (also 1/0, yes/no)
//   json  a JSON value typed as text (settings)
//   date  a date; an Excel date becomes YYYY-MM-DD
const col = (name, field, kind, width) => ({ name, field, kind, width });
const AUTHORING = [col("source_location", "sourceLocation", "text", 30), col("review_status", "reviewStatus", "text", 24), col("revision_notes", "revisionNotes", "text", 32)];

const TABLES = [
  {
    sheet: "section_definition", collection: "sections", title: "Section Definition", idField: "sectionId", keyField: "sectionKey",
    description: "Sections and subsections, nested through parent_section_id. display_order sets the order among siblings.",
    columns: [
      col("section_id", "sectionId", "id", 26), col("version_id", "versionId", "id", 22), col("parent_section_id", "parentSectionId", "id", 26),
      col("section_key", "sectionKey", "id", 26), col("display_order", "displayOrder", "int", 12), col("title", "title", "text", 44),
      col("instructions", "instructions", "text", 44), col("color_hex", "colorHex", "text", 11), col("notes_enabled", "notesEnabled", "bool", 12),
      col("optional_section", "optionalSection", "bool", 12), col("required_section", "requiredSection", "bool", 12), col("active", "active", "bool", 9),
      col("settings_json", "settings", "json", 30), ...AUTHORING,
    ],
    normalized: { parentSectionKey: "parent_section_id" },
  },
  {
    sheet: "item_definition", collection: "items", title: "Item Definition", idField: "itemId", keyField: "itemKey",
    description: "Every question, note field and look-for. section_id places it; response_set_id gives a choice question its answers; display_order orders it in its section.",
    columns: [
      col("item_id", "itemId", "id", 26), col("version_id", "versionId", "id", 22), col("section_id", "sectionId", "id", 26),
      col("item_key", "itemKey", "id", 24), col("reporting_key", "reportingKey", "id", 22), col("content_family", "contentFamily", "text", 22),
      col("item_type", "itemType", "text", 16), col("prompt", "prompt", "text", 60), col("help_text", "helpText", "text", 36),
      col("placeholder", "placeholder", "text", 30), col("link_url", "linkUrl", "text", 24), col("response_set_id", "responseSetId", "id", 22),
      col("display_order", "displayOrder", "int", 12), col("required", "required", "bool", 10), col("reportable", "reportable", "bool", 11),
      col("active", "active", "bool", 9), col("settings_json", "settings", "json", 30), ...AUTHORING,
    ],
    normalized: { sectionKey: "section_id", responseSetKey: "response_set_id" },
  },
  {
    sheet: "response_set", collection: "responseSets", title: "Response Set", idField: "responseSetId", keyField: "setKey",
    description: "Answer scales. Their answers are on response_option.",
    columns: [
      col("response_set_id", "responseSetId", "id", 24), col("version_id", "versionId", "id", 22), col("set_key", "setKey", "id", 22),
      col("name", "name", "text", 30), col("selection_mode", "selectionMode", "text", 14), col("allow_na", "allowNa", "bool", 10),
      col("score_enabled", "scoreEnabled", "bool", 12), col("active", "active", "bool", 9), ...AUTHORING,
    ],
    normalized: {},
  },
  {
    sheet: "response_option", collection: "responseOptions", title: "Response Option", idField: "optionId", keyField: "optionKey",
    description: "The answers of each scale: the label people see, the code that is stored, the definition, and the score used in reports.",
    columns: [
      col("option_id", "optionId", "id", 30), col("response_set_id", "responseSetId", "id", 24), col("option_key", "optionKey", "id", 16),
      col("stored_code", "storedCode", "text", 14), col("label", "label", "text", 30), col("definition", "definition", "text", 50),
      col("numeric_score", "numericScore", "num", 13), col("is_na", "isNa", "bool", 8), col("display_order", "displayOrder", "int", 12),
      col("active", "active", "bool", 9), ...AUTHORING,
    ],
    normalized: { setKey: "response_set_id" },
  },
  {
    sheet: "rule_definition", collection: "rules", title: "Rule Definition", idField: "ruleId", keyField: "ruleKey",
    description: "Show/hide rules. conditions_json is the rule itself; the flat columns beside it describe the same condition and must agree with it.",
    columns: [
      col("rule_id", "ruleId", "id", 28), col("version_id", "versionId", "id", 22), col("rule_key", "ruleKey", "id", 24),
      col("target_type", "targetType", "text", 12), col("target_id", "targetId", "id", 26), col("effect", "effect", "text", 10),
      col("effect_value", "effectValue", "text", 14), col("source_type", "sourceType", "text", 12), col("source_id", "sourceId", "id", 16),
      col("operator", "operator", "text", 10), col("comparison_value", "comparisonValue", "text", 24), col("condition_logic", "conditionLogic", "text", 10),
      col("conditions_json", "conditionsJson", "text", 60), col("active", "active", "bool", 9), ...AUTHORING,
    ],
    normalized: { targetKey: "target_id", sourceKey: "source_id", conditions: "conditions_json" },
  },
  {
    sheet: "dimension_definition", collection: "dimensions", title: "Dimension Definition", idField: "dimensionId", keyField: "code",
    description: "The walk's descriptive fields (school, grade, content ...) and whether reports use them.",
    columns: [
      col("dimension_id", "dimensionId", "id", 22), col("code", "code", "id", 16), col("label", "label", "text", 26),
      col("data_type", "dataType", "text", 12), col("value_mode", "valueMode", "text", 12), col("reportable", "reportable", "bool", 11),
      col("sensitive", "sensitive", "bool", 10), col("allow_other", "allowOther", "bool", 11), col("active", "active", "bool", 9),
      col("settings_json", "settings", "json", 30), ...AUTHORING,
    ],
    normalized: {},
  },
  {
    sheet: "dimension_value", collection: "dimensionValues", title: "Dimension Value", idField: "dimensionValueId", keyField: "valueCode",
    description: "The choices of each list dimension (schools, grades, content areas ...), in display_order.",
    columns: [
      col("dimension_value_id", "dimensionValueId", "id", 34), col("dimension_id", "dimensionId", "id", 20), col("value_code", "valueCode", "id", 28),
      col("label", "label", "text", 30), col("display_order", "displayOrder", "int", 12), col("value_group", "valueGroup", "text", 14),
      col("grade_band", "gradeBand", "text", 12), col("active", "active", "bool", 9), col("effective_start", "effectiveStart", "date", 14),
      col("effective_end", "effectiveEnd", "date", 14), ...AUTHORING,
    ],
    normalized: { dimensionCode: "dimension_id" },
  },
  {
    sheet: "instrument_dimension", collection: "instrumentDimensions", title: "Instrument Dimension", idField: "instrumentDimensionId", keyField: "dimensionId",
    description: "Where each dimension appears on the walk form, and whether it is required or shown by default.",
    columns: [
      col("instrument_dimension_id", "instrumentDimensionId", "id", 26), col("version_id", "versionId", "id", 22), col("dimension_id", "dimensionId", "id", 20),
      col("section_id", "sectionId", "id", 26), col("display_order", "displayOrder", "int", 12), col("required", "required", "bool", 10),
      col("visible_by_default", "visibleByDefault", "bool", 12), col("rule_key", "ruleKey", "id", 20), col("label_override", "labelOverride", "text", 22),
      col("placeholder", "placeholder", "text", 26), col("active", "active", "bool", 9), col("settings_json", "settings", "json", 30), ...AUTHORING,
    ],
    normalized: { dimensionCode: "dimension_id", sectionKey: "section_id" },
  },
];

const INSTRUMENT = {
  sheet: "instrument", title: "Instrument", description: "The instrument this version belongs to. One row. Its code decides which instrument the upload updates.",
  columns: [col("instrument_id", "instrumentId", "id", 22), col("code", "code", "id", 16), col("name", "name", "text", 30), col("description", "description", "text", 40), col("active", "active", "bool", 9)],
};
const VERSION = {
  sheet: "instrument_version", title: "Instrument Version", description: "This version. One row. Give it a new version_label before uploading, or enter one when you upload.",
  columns: [
    col("version_id", "versionId", "id", 30), col("instrument_id", "instrumentId", "id", 22), col("version_label", "versionLabel", "text", 34),
    col("status", "status", "text", 10), col("effective_start", "effectiveStart", "date", 14), col("effective_end", "effectiveEnd", "date", 14),
    col("extracted_on", "extractedOn", "date", 13), col("source_file", "sourceFile", "text", 24), col("source_sha256", "sourceSha256", "text", 24),
    col("review_status", "reviewStatus", "text", 26), col("revision_notes", "revisionNotes", "text", 40),
  ],
};
const DOCUMENT = {
  sheet: "document", title: "Document", description: "Do not edit. The parts of the instrument that are not tables, and where this file came from. Each value is JSON.",
  columns: [col("member", "member", "id", 22), col("value_json", "value", "text", 100)],
  members: ["schemaVersion", "source", "behavior", "contentReview"],
  exportMembers: ["export.format", "export.versionId", "export.versionLabel", "export.status", "export.checksum", "export.instrumentCode", "export.exportedAt"],
};
const START_HERE = "Start Here";

export const SHEET_NAMES = [INSTRUMENT.sheet, VERSION.sheet, ...TABLES.map((t) => t.sheet), DOCUMENT.sheet];
const PLACEHOLDER_REVIEW_STATUS = "Placeholder in source";

// ---- small helpers ----------------------------------------------------------------------------

function columnLetter(index) {
  let n = index + 1;
  let out = "";
  while (n > 0) {
    const m = (n - 1) % 26;
    out = String.fromCharCode(65 + m) + out;
    n = Math.floor((n - 1) / 26);
  }
  return out;
}

function columnIndex(letters) {
  let n = 0;
  for (const ch of letters) n = n * 26 + (ch.charCodeAt(0) - 64);
  return n - 1;
}

function isBlank(v) {
  return v === null || v === undefined || (typeof v === "string" && v.trim() === "");
}

/** UTF-16 code unit order with null as "" -- the order the server's normalizer sorts rows in. */
function compareKeys(a, b) {
  for (let i = 0; i < a.length; i++) {
    const left = a[i] ?? "";
    const right = b[i] ?? "";
    if (left < right) return -1;
    if (left > right) return 1;
  }
  return 0;
}

function canonical(value) {
  if (value === null || typeof value !== "object") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  return `{${Object.keys(value).sort().map((k) => `${JSON.stringify(k)}:${canonical(value[k])}`).join(",")}}`;
}

// ---- XML --------------------------------------------------------------------------------------

const ENTITY = { lt: "<", gt: ">", amp: "&", quot: "\"", apos: "'" };

function decodeEntities(text) {
  return text.replace(/&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);/g, (whole, body) => {
    if (body[0] === "#") {
      const code = body[1] === "x" || body[1] === "X" ? parseInt(body.slice(2), 16) : parseInt(body.slice(1), 10);
      return Number.isFinite(code) ? String.fromCodePoint(code) : whole;
    }
    return Object.prototype.hasOwnProperty.call(ENTITY, body) ? ENTITY[body] : whole;
  });
}

/**
 * A minimal, non-validating XML reader for SpreadsheetML: elements (namespace prefixes dropped),
 * attributes (names kept as written), text and CDATA. A DOCTYPE is refused, so no entity is ever
 * declared and none but the five predefined ones and character references is expanded.
 */
export function parseXml(text) {
  if (/<!DOCTYPE/i.test(text)) throw new WorkbookError("XML_DOCTYPE", "The file contains a DOCTYPE declaration, which a workbook never needs; it was not read.");
  const root = { name: "#document", attrs: {}, children: [] };
  const stack = [root];
  let i = 0;
  const n = text.length;
  while (i < n) {
    const lt = text.indexOf("<", i);
    if (lt === -1) { pushText(stack, text.slice(i)); break; }
    if (lt > i) pushText(stack, text.slice(i, lt));
    if (text.startsWith("<?", lt)) { i = closeAt(text, "?>", lt) + 2; continue; }
    if (text.startsWith("<!--", lt)) { i = closeAt(text, "-->", lt) + 3; continue; }
    if (text.startsWith("<![CDATA[", lt)) {
      const end = closeAt(text, "]]>", lt);
      stack[stack.length - 1].children.push({ text: text.slice(lt + 9, end) });
      i = end + 3;
      continue;
    }
    if (text[lt + 1] === "/") {
      const end = closeAt(text, ">", lt);
      const name = localName(text.slice(lt + 2, end).trim());
      if (stack.length > 1 && stack[stack.length - 1].name === name) stack.pop();
      else throw new WorkbookError("XML_MALFORMED", `Unexpected closing tag </${name}>.`);
      i = end + 1;
      continue;
    }
    let j = lt + 1;
    let quote = null;
    while (j < n) {
      const ch = text[j];
      if (quote) { if (ch === quote) quote = null; } else if (ch === "\"" || ch === "'") quote = ch; else if (ch === ">") break;
      j++;
    }
    if (j >= n) throw new WorkbookError("XML_MALFORMED", "An element is never closed.");
    const selfClosing = text[j - 1] === "/";
    const inner = text.slice(lt + 1, selfClosing ? j - 1 : j);
    const nameMatch = /^([^\s/>]+)/.exec(inner);
    if (!nameMatch) throw new WorkbookError("XML_MALFORMED", "An element has no name.");
    const attrs = {};
    const attrRe = /([^\s=/]+)\s*=\s*("([^"]*)"|'([^']*)')/g;
    let m;
    const rest = inner.slice(nameMatch[1].length);
    while ((m = attrRe.exec(rest))) attrs[m[1]] = decodeEntities(m[3] ?? m[4] ?? "");
    const el = { name: localName(nameMatch[1]), attrs, children: [] };
    stack[stack.length - 1].children.push(el);
    if (!selfClosing) stack.push(el);
    i = j + 1;
  }
  if (stack.length !== 1) throw new WorkbookError("XML_MALFORMED", `Element <${stack[stack.length - 1].name}> is never closed.`);
  return root;
}

function closeAt(text, token, from) {
  const at = text.indexOf(token, from);
  if (at === -1) throw new WorkbookError("XML_MALFORMED", `Unterminated markup (expected ${token}).`);
  return at;
}

function localName(name) {
  const colon = name.indexOf(":");
  return colon === -1 ? name : name.slice(colon + 1);
}

function pushText(stack, raw) {
  if (!raw) return;
  stack[stack.length - 1].children.push({ text: decodeEntities(raw) });
}

function kids(el, name) { return el.children.filter((c) => c.name === name); }
function kid(el, name) { return el.children.find((c) => c.name === name) || null; }
function textOf(el) { return el.children.map((c) => (c.text !== undefined ? c.text : textOf(c))).join(""); }

function escapeXml(text) {
  return String(text).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

/**
 * Cell text as SpreadsheetML stores it: characters XML cannot carry (and CR, which XML parsers fold
 * into LF) are written as Excel's own _xHHHH_ escapes, and a literal _xHHHH_ in the text is itself
 * escaped, so every string comes back exactly as it went in.
 */
function encodeCellText(text) {
  const escaped = String(text)
    .replace(/_x[0-9A-Fa-f]{4}_/g, (s) => `_x005F${s}`)
    .replace(/[\u0000-\u0008\u000B\u000C\u000D\u000E-\u001F￾￿]/g, (ch) => `_x${ch.charCodeAt(0).toString(16).toUpperCase().padStart(4, "0")}_`);
  return escapeXml(escaped);
}

function decodeCellText(text) {
  return text.replace(/_x([0-9A-Fa-f]{4})_/g, (_, hex) => String.fromCharCode(parseInt(hex, 16)));
}

// ---- zip --------------------------------------------------------------------------------------

let crcTable = null;
function crc32(bytes) {
  if (!crcTable) {
    crcTable = new Uint32Array(256);
    for (let n = 0; n < 256; n++) {
      let c = n;
      for (let k = 0; k < 8; k++) c = c & 1 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1;
      crcTable[n] = c >>> 0;
    }
  }
  let crc = 0xFFFFFFFF;
  for (let i = 0; i < bytes.length; i++) crc = crcTable[(crc ^ bytes[i]) & 0xFF] ^ (crc >>> 8);
  return (crc ^ 0xFFFFFFFF) >>> 0;
}

async function pump(stream, limit, code) {
  const reader = stream.getReader();
  const chunks = [];
  let total = 0;
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    total += value.length;
    if (total > limit) {
      await reader.cancel().catch(() => {});
      throw new WorkbookError(code, "The workbook is far larger than an instrument could be; it was not read.");
    }
    chunks.push(value);
  }
  const out = new Uint8Array(total);
  let at = 0;
  for (const c of chunks) { out.set(c, at); at += c.length; }
  return out;
}

async function deflateRaw(bytes) {
  return pump(new Blob([bytes]).stream().pipeThrough(new CompressionStream("deflate-raw")), Infinity, "ZIP_TOO_LARGE");
}

async function inflateRaw(bytes, limit) {
  try {
    return await pump(new Blob([bytes]).stream().pipeThrough(new DecompressionStream("deflate-raw")), limit, "ZIP_TOO_LARGE");
  } catch (e) {
    if (e instanceof WorkbookError) throw e;
    throw new WorkbookError("ZIP_CORRUPT", "A part of the workbook could not be decompressed; the file may be damaged.");
  }
}

// A fixed timestamp, so the same instrument always produces the same bytes.
const DOS_TIME = 0;
const DOS_DATE = (2020 - 1980) << 9 | 1 << 5 | 1;

/** @param entries [{ name, data: Uint8Array }] -> zip bytes, each entry deflated */
export async function writeZip(entries) {
  const local = [];
  const central = [];
  let offset = 0;
  const enc = new TextEncoder();
  for (const entry of entries) {
    const name = enc.encode(entry.name);
    const data = entry.data;
    const crc = crc32(data);
    const packed = entry.stored ? data : await deflateRaw(data);
    const method = entry.stored ? 0 : 8;
    const head = new DataView(new ArrayBuffer(30));
    head.setUint32(0, 0x04034b50, true);
    head.setUint16(4, 20, true);
    head.setUint16(6, 0x0800, true);          // UTF-8 names
    head.setUint16(8, method, true);
    head.setUint16(10, DOS_TIME, true);
    head.setUint16(12, DOS_DATE, true);
    head.setUint32(14, crc, true);
    head.setUint32(18, packed.length, true);
    head.setUint32(22, data.length, true);
    head.setUint16(26, name.length, true);
    head.setUint16(28, 0, true);
    local.push(new Uint8Array(head.buffer), name, packed);
    const dir = new DataView(new ArrayBuffer(46));
    dir.setUint32(0, 0x02014b50, true);
    dir.setUint16(4, 20, true);
    dir.setUint16(6, 20, true);
    dir.setUint16(8, 0x0800, true);
    dir.setUint16(10, method, true);
    dir.setUint16(12, DOS_TIME, true);
    dir.setUint16(14, DOS_DATE, true);
    dir.setUint32(16, crc, true);
    dir.setUint32(20, packed.length, true);
    dir.setUint32(24, data.length, true);
    dir.setUint16(28, name.length, true);
    dir.setUint32(42, offset, true);
    central.push(new Uint8Array(dir.buffer), name);
    offset += 30 + name.length + packed.length;
  }
  const centralSize = central.reduce((s, p) => s + p.length, 0);
  const end = new DataView(new ArrayBuffer(22));
  end.setUint32(0, 0x06054b50, true);
  end.setUint16(8, entries.length, true);
  end.setUint16(10, entries.length, true);
  end.setUint32(12, centralSize, true);
  end.setUint32(16, offset, true);
  const parts = [...local, ...central, new Uint8Array(end.buffer)];
  const out = new Uint8Array(parts.reduce((s, p) => s + p.length, 0));
  let at = 0;
  for (const p of parts) { out.set(p, at); at += p.length; }
  return out;
}

/** zip bytes -> Map(lower-case name -> Uint8Array), within LIMITS */
export async function readZip(bytes) {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  if (bytes.length < 22 || view.getUint32(0, true) !== 0x04034b50) {
    throw new WorkbookError("NOT_A_WORKBOOK", "This file is not an Excel workbook (.xlsx).");
  }
  let eocd = -1;
  for (let i = bytes.length - 22; i >= Math.max(0, bytes.length - 22 - 65535); i--) {
    if (view.getUint32(i, true) === 0x06054b50) { eocd = i; break; }
  }
  if (eocd === -1) throw new WorkbookError("ZIP_CORRUPT", "The workbook's file directory is missing; the file may be damaged.");
  const count = view.getUint16(eocd + 10, true);
  const dirOffset = view.getUint32(eocd + 16, true);
  if (count > LIMITS.entries) throw new WorkbookError("ZIP_TOO_LARGE", "The workbook has far more parts than an instrument workbook could.");
  const decoder = new TextDecoder();
  const files = new Map();
  let p = dirOffset;
  let total = 0;
  for (let e = 0; e < count; e++) {
    if (p + 46 > bytes.length || view.getUint32(p, true) !== 0x02014b50) throw new WorkbookError("ZIP_CORRUPT", "The workbook's file directory is damaged.");
    const flags = view.getUint16(p + 8, true);
    const method = view.getUint16(p + 10, true);
    const crc = view.getUint32(p + 16, true);
    const packedSize = view.getUint32(p + 20, true);
    const size = view.getUint32(p + 24, true);
    const nameLen = view.getUint16(p + 28, true);
    const extraLen = view.getUint16(p + 30, true);
    const commentLen = view.getUint16(p + 32, true);
    const localOffset = view.getUint32(p + 42, true);
    const name = decoder.decode(bytes.subarray(p + 46, p + 46 + nameLen));
    p += 46 + nameLen + extraLen + commentLen;
    if (flags & 0x1) throw new WorkbookError("WORKBOOK_ENCRYPTED", "The workbook is password-protected. Remove the password in Excel and upload it again.");
    if (packedSize === 0xFFFFFFFF || size === 0xFFFFFFFF) throw new WorkbookError("ZIP_TOO_LARGE", "The workbook is far larger than an instrument could be.");
    if (size > LIMITS.entryBytes) throw new WorkbookError("ZIP_TOO_LARGE", "A part of the workbook is far larger than an instrument could be.");
    total += size;
    if (total > LIMITS.totalBytes) throw new WorkbookError("ZIP_TOO_LARGE", "The workbook is far larger than an instrument could be.");
    if (name.endsWith("/")) continue;
    if (localOffset + 30 > bytes.length || view.getUint32(localOffset, true) !== 0x04034b50) throw new WorkbookError("ZIP_CORRUPT", "A part of the workbook is damaged.");
    const start = localOffset + 30 + view.getUint16(localOffset + 26, true) + view.getUint16(localOffset + 28, true);
    const packed = bytes.subarray(start, start + packedSize);
    let data;
    if (method === 0) data = packed.slice();
    else if (method === 8) data = await inflateRaw(packed, Math.min(size, LIMITS.entryBytes) + 1);
    else throw new WorkbookError("ZIP_UNSUPPORTED", "The workbook uses a compression method this page cannot read. Save it again from Excel as .xlsx.");
    if (data.length !== size || crc32(data) !== crc) throw new WorkbookError("ZIP_CORRUPT", "A part of the workbook is damaged; save it again from Excel and upload the new file.");
    files.set(name.replace(/^\/+/, "").toLowerCase(), data);
  }
  return files;
}

// ---- errors ------------------------------------------------------------------------------------

export class WorkbookError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

function issue(code, message, where = {}) {
  const out = { code, message };
  for (const k of ["sheet", "row", "column", "cell"]) if (where[k] !== undefined && where[k] !== null) out[k] = where[k];
  return out;
}

/** "item_definition, row 17, column prompt (H17)" */
export function describeLocation(loc) {
  if (!loc || !loc.sheet) return "";
  const parts = [loc.sheet];
  if (loc.row) parts.push(`row ${loc.row}`);
  if (loc.column) parts.push(`column ${loc.column}${loc.cell ? ` (${loc.cell})` : ""}`);
  return parts.join(", ");
}

// ---- writing -----------------------------------------------------------------------------------

const STYLE = { title: 1, description: 2, header: 3, text: 4, number: 5, bool: 6, wrap: 7, id: 8 };

const STYLES_XML = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
<fonts count="4"><font><sz val="11"/><name val="Calibri"/><family val="2"/></font><font><b/><sz val="11"/><name val="Calibri"/><family val="2"/></font><font><b/><sz val="14"/><color rgb="FF003466"/><name val="Calibri"/><family val="2"/></font><font><i/><sz val="10"/><color rgb="FF4E5D6C"/><name val="Calibri"/><family val="2"/></font></fonts>
<fills count="4"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FFDCE6F1"/><bgColor indexed="64"/></patternFill></fill><fill><patternFill patternType="solid"><fgColor rgb="FFF2F2F2"/><bgColor indexed="64"/></patternFill></fill></fills>
<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>
<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
<cellXfs count="9"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="2" fillId="0" borderId="0" xfId="0" applyFont="1"/><xf numFmtId="0" fontId="3" fillId="0" borderId="0" xfId="0" applyFont="1"/><xf numFmtId="49" fontId="1" fillId="2" borderId="0" xfId="0" applyNumberFormat="1" applyFont="1" applyFill="1"/><xf numFmtId="49" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0" applyAlignment="1"><alignment horizontal="center"/></xf><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0" applyAlignment="1"><alignment wrapText="1" vertical="top"/></xf><xf numFmtId="49" fontId="0" fillId="3" borderId="0" xfId="0" applyNumberFormat="1" applyFill="1"/></cellXfs>
<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>
</styleSheet>`;

function styleFor(kind) {
  if (kind === "id") return STYLE.id;
  if (kind === "int" || kind === "num") return STYLE.number;
  if (kind === "bool") return STYLE.bool;
  return STYLE.text;
}

function cellXml(ref, value, kind, style) {
  if (value === null || value === undefined) return "";
  if (kind === "bool") {
    if (typeof value === "boolean") return `<c r="${ref}" s="${style}" t="b"><v>${value ? 1 : 0}</v></c>`;
  } else if ((kind === "int" || kind === "num") && typeof value === "number" && Number.isFinite(value)) {
    return `<c r="${ref}" s="${style}"><v>${value}</v></c>`;
  }
  const text = kind === "json" ? JSON.stringify(value) : (typeof value === "string" ? value : JSON.stringify(value));
  if (text.length > LIMITS.cellChars) throw new WorkbookError("CELL_TOO_LONG", `A value in ${ref} is longer than an Excel cell can hold (${LIMITS.cellChars} characters).`);
  return `<c r="${ref}" s="${style}" t="inlineStr"><is><t xml:space="preserve">${encodeCellText(text)}</t></is></c>`;
}

function tableSheetXml(spec, records, selected) {
  const cols = spec.columns;
  const last = columnLetter(cols.length - 1);
  const lastRow = Math.max(HEADER_ROW + records.length, HEADER_ROW + 1);
  const rows = [];
  rows.push(`<row r="1"><c r="A1" s="${STYLE.title}" t="inlineStr"><is><t>${encodeCellText(spec.title)}</t></is></c></row>`);
  rows.push(`<row r="2"><c r="A2" s="${STYLE.description}" t="inlineStr"><is><t xml:space="preserve">${encodeCellText(spec.description)}</t></is></c></row>`);
  rows.push(`<row r="3">${cols.map((c, i) => `<c r="${columnLetter(i)}3" s="${STYLE.header}" t="inlineStr"><is><t>${encodeCellText(c.name)}</t></is></c>`).join("")}</row>`);
  records.forEach((record, index) => {
    const r = HEADER_ROW + 1 + index;
    const cells = cols.map((c, i) => cellXml(`${columnLetter(i)}${r}`, record[c.field], c.kind, styleFor(c.kind))).join("");
    rows.push(`<row r="${r}">${cells}</row>`);
  });
  const widths = cols.map((c, i) => `<col min="${i + 1}" max="${i + 1}" width="${c.width}" style="${styleFor(c.kind)}" customWidth="1"/>`).join("");
  return `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><dimension ref="A1:${last}${lastRow}"/><sheetViews><sheetView workbookViewId="0"${selected ? " tabSelected=\"1\"" : ""}><pane ySplit="${HEADER_ROW}" topLeftCell="A${HEADER_ROW + 1}" activePane="bottomLeft" state="frozen"/><selection pane="bottomLeft" activeCell="A${HEADER_ROW + 1}" sqref="A${HEADER_ROW + 1}"/></sheetView></sheetViews><sheetFormatPr defaultRowHeight="15"/><cols>${widths}</cols><sheetData>${rows.join("")}</sheetData><autoFilter ref="A${HEADER_ROW}:${last}${lastRow}"/></worksheet>`;
}

function startHereXml(summary) {
  const lines = [
    ["ICFWalk instrument workbook", STYLE.title],
    [summary, STYLE.description],
    ["", 0],
    ["How to use this file", STYLE.header],
    ["1. Edit the sheets in Excel. Keep the column names on row 3 as they are. Add a record by adding a row under the others; remove one by deleting its row.", STYLE.wrap],
    ["2. Give the new version a label: change version_label on the instrument_version sheet, or enter a draft label when you upload.", STYLE.wrap],
    ["3. Upload the file in ICFWalk under Instrument administration > Import. It becomes a DRAFT. Nothing changes for walks until you preview and publish it.", STYLE.wrap],
    ["4. If anything is wrong, the upload lists each problem with its sheet, row and column, and nothing is saved.", STYLE.wrap],
    ["", 0],
    ["How the sheets connect", STYLE.header],
    ["Columns ending in _id are how rows point at each other. A question's section_id must be the section_id of a row on section_definition; a question's response_set_id must be a response_set_id on response_set; an answer's response_set_id says which scale it belongs to.", STYLE.wrap],
    ["Keys (section_key, item_key, set_key, option_key, code, value_code) are the permanent names reports use. Change wording freely, but keep a key the same when the meaning stays the same.", STYLE.wrap],
    ["display_order sets the order within the parent section or scale. Gaps are fine (10, 20, 30 ...).", STYLE.wrap],
    ["Yes/no columns take TRUE or FALSE. An empty cell means no value. settings_json and conditions_json hold JSON; change them only if you know what they do.", STYLE.wrap],
    ["Questions still waiting for approved wording have review_status 'Placeholder in source'. To resolve one, replace the prompt and change its review_status.", STYLE.wrap],
    ["Do not edit the document sheet. It carries the parts of the instrument that are not tables, and which version this file came from.", STYLE.wrap],
  ];
  const rows = lines.map(([text, style], i) => (text
    ? `<row r="${i + 1}"><c r="A${i + 1}" s="${style}" t="inlineStr"><is><t xml:space="preserve">${encodeCellText(text)}</t></is></c></row>`
    : `<row r="${i + 1}"/>`)).join("");
  return `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><dimension ref="A1:A${lines.length}"/><sheetViews><sheetView workbookViewId="0" tabSelected="1"/></sheetViews><sheetFormatPr defaultRowHeight="15"/><cols><col min="1" max="1" width="120" customWidth="1"/></cols><sheetData>${rows}</sheetData></worksheet>`;
}

/**
 * The document as an .xlsx file.
 *
 * @param document    the authoring document (GET /api/admin/instrument/versions/{id}/document)
 * @param exportedFrom { versionId, versionLabel, status, checksum, instrumentCode } of the version
 *                    it came from, recorded on the document sheet so an upload can tell whether
 *                    that draft changed since
 * @param exportedAt  ISO timestamp to record; fixed by tests so the bytes are reproducible
 */
export async function writeWorkbook(document, { exportedFrom = null, exportedAt = null } = {}) {
  const enc = new TextEncoder();
  const inst = document.instrument || {};
  const version = inst.version || {};
  const sheets = [];
  const summary = `Instrument ${inst.code ?? ""}, version "${version.versionLabel ?? ""}"${exportedFrom && exportedFrom.status ? ` (${String(exportedFrom.status).toLowerCase()})` : ""}${exportedAt ? `, downloaded ${exportedAt}` : ""}.`;
  sheets.push({ name: START_HERE, xml: startHereXml(summary) });
  sheets.push({ name: INSTRUMENT.sheet, spec: INSTRUMENT, records: [inst] });
  sheets.push({ name: VERSION.sheet, spec: VERSION, records: [{ ...version }] });
  for (const t of TABLES) sheets.push({ name: t.sheet, spec: t, records: Array.isArray(document[t.collection]) ? document[t.collection] : [] });
  const docRows = DOCUMENT.members.map((m) => ({ member: m, value: JSON.stringify(document[m] === undefined ? null : document[m]) }));
  const meta = {
    "export.format": WORKBOOK_FORMAT,
    "export.versionId": exportedFrom?.versionId ?? null,
    "export.versionLabel": exportedFrom?.versionLabel ?? null,
    "export.status": exportedFrom?.status ?? null,
    "export.checksum": exportedFrom?.checksum ?? null,
    "export.instrumentCode": exportedFrom?.instrumentCode ?? null,
    "export.exportedAt": exportedAt ?? null,
  };
  for (const m of DOCUMENT.exportMembers) docRows.push({ member: m, value: JSON.stringify(meta[m]) });
  sheets.push({ name: DOCUMENT.sheet, spec: DOCUMENT, records: docRows });

  const entries = [];
  const overrides = [];
  const rels = [];
  sheets.forEach((s, i) => {
    const xml = s.xml ?? tableSheetXml(s.spec, s.records, false);
    entries.push({ name: `xl/worksheets/sheet${i + 1}.xml`, data: enc.encode(xml) });
    overrides.push(`<Override PartName="/xl/worksheets/sheet${i + 1}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>`);
    rels.push(`<Relationship Id="rId${i + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet${i + 1}.xml"/>`);
  });
  rels.push(`<Relationship Id="rId${sheets.length + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>`);
  const sheetList = sheets.map((s, i) => `<sheet name="${escapeXml(s.name)}" sheetId="${i + 1}" r:id="rId${i + 1}"/>`).join("");
  const filters = sheets.map((s, i) => {
    if (!s.spec) return "";
    const last = columnLetter(s.spec.columns.length - 1);
    const lastRow = Math.max(HEADER_ROW + s.records.length, HEADER_ROW + 1);
    return `<definedName name="_xlnm._FilterDatabase" localSheetId="${i}" hidden="1">'${s.name}'!$A$${HEADER_ROW}:$${last}$${lastRow}</definedName>`;
  }).join("");
  const workbookXml = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><bookViews><workbookView activeTab="0"/></bookViews><sheets>${sheetList}</sheets><definedNames>${filters}</definedNames></workbook>`;
  const contentTypes = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>${overrides.join("")}</Types>`;
  const rootRels = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>`;
  const workbookRels = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">${rels.join("")}</Relationships>`;
  return writeZip([
    { name: "[Content_Types].xml", data: enc.encode(contentTypes) },
    { name: "_rels/.rels", data: enc.encode(rootRels) },
    { name: "xl/workbook.xml", data: enc.encode(workbookXml) },
    { name: "xl/_rels/workbook.xml.rels", data: enc.encode(workbookRels) },
    { name: "xl/styles.xml", data: enc.encode(STYLES_XML) },
    ...entries,
  ]);
}

// ---- reading -----------------------------------------------------------------------------------

function resolvePart(base, target) {
  if (target.startsWith("/")) return target.slice(1);
  const parts = base.split("/").slice(0, -1);
  for (const seg of target.split("/")) {
    if (seg === "..") parts.pop();
    else if (seg !== ".") parts.push(seg);
  }
  return parts.join("/");
}

function relationships(files, relsPath) {
  const data = files.get(relsPath.toLowerCase());
  const out = new Map();
  if (!data) return out;
  const root = parseXml(new TextDecoder().decode(data));
  const rels = kid(root, "Relationships");
  if (!rels) return out;
  for (const r of kids(rels, "Relationship")) out.set(r.attrs.Id, { type: r.attrs.Type || "", target: r.attrs.Target || "" });
  return out;
}

/** Every sheet by name, each as Map(row number -> Map(column index -> cell)). */
function loadSheets(files) {
  const dec = new TextDecoder();
  const rootRels = relationships(files, "_rels/.rels");
  let workbookPath = "xl/workbook.xml";
  for (const r of rootRels.values()) if (r.type.endsWith("/officeDocument")) workbookPath = resolvePart("", r.target);
  const workbookData = files.get(workbookPath.toLowerCase());
  if (!workbookData) throw new WorkbookError("NOT_A_WORKBOOK", "This file is not an Excel workbook (.xlsx): it has no workbook part.");
  const workbook = kid(parseXml(dec.decode(workbookData)), "workbook");
  if (!workbook) throw new WorkbookError("NOT_A_WORKBOOK", "This file is not an Excel workbook (.xlsx).");
  const date1904 = ["1", "true"].includes(String(kid(workbook, "workbookPr")?.attrs.date1904 || "").toLowerCase());
  const relsPath = workbookPath.replace(/[^/]+$/, (f) => `_rels/${f}.rels`);
  const rels = relationships(files, relsPath);
  let sharedStrings = [];
  for (const r of rels.values()) {
    if (!r.type.endsWith("/sharedStrings")) continue;
    const data = files.get(resolvePart(workbookPath, r.target).toLowerCase());
    if (!data) continue;
    const sst = kid(parseXml(dec.decode(data)), "sst");
    sharedStrings = sst ? kids(sst, "si").map((si) => decodeCellText(
      [...kids(si, "t"), ...kids(si, "r").map((run) => kid(run, "t")).filter(Boolean)].map(textOf).join(""))) : [];
  }
  const sheets = new Map();
  const sheetsEl = kid(workbook, "sheets");
  for (const s of sheetsEl ? kids(sheetsEl, "sheet") : []) {
    const rid = s.attrs["r:id"] ?? Object.entries(s.attrs).find(([k]) => k.endsWith(":id"))?.[1];
    const rel = rels.get(rid);
    if (!rel) continue;
    const data = files.get(resolvePart(workbookPath, rel.target).toLowerCase());
    if (!data) continue;
    sheets.set(s.attrs.name, { name: s.attrs.name, grid: sheetGrid(parseXml(dec.decode(data)), sharedStrings) });
  }
  return { sheets, date1904 };
}

function sheetGrid(root, sharedStrings) {
  const grid = new Map();
  const ws = kid(root, "worksheet");
  const data = ws && kid(ws, "sheetData");
  if (!data) return grid;
  let nextRow = 1;
  const rows = kids(data, "row");
  if (rows.length > LIMITS.rowsPerSheet) throw new WorkbookError("SHEET_TOO_LARGE", "A sheet has far more rows than an instrument could.");
  for (const row of rows) {
    const r = row.attrs.r ? parseInt(row.attrs.r, 10) : nextRow;
    nextRow = r + 1;
    const cells = new Map();
    let nextCol = 0;
    for (const c of kids(row, "c")) {
      const ref = c.attrs.r;
      const ci = ref ? columnIndex(/^[A-Z]+/i.exec(ref)[0].toUpperCase()) : nextCol;
      nextCol = ci + 1;
      const t = c.attrs.t || "n";
      const v = kid(c, "v");
      let cell = null;
      if (t === "s" && v) cell = { t: "s", v: sharedStrings[parseInt(textOf(v), 10)] ?? "" };
      else if (t === "inlineStr") {
        const is = kid(c, "is");
        cell = { t: "s", v: is ? decodeCellText([...kids(is, "t"), ...kids(is, "r").map((run) => kid(run, "t")).filter(Boolean)].map(textOf).join("")) : "" };
      } else if (t === "str" && v) cell = { t: "s", v: decodeCellText(textOf(v)) };
      else if (t === "b" && v) cell = { t: "b", v: textOf(v).trim() === "1" };
      else if (t === "e") cell = { t: "e", v: v ? textOf(v) : "#ERROR" };
      else if (t === "d" && v) cell = { t: "d", v: textOf(v) };
      else if (v && textOf(v).trim() !== "") cell = { t: "n", v: Number(textOf(v)) };
      if (cell) cells.set(ci, cell);
    }
    grid.set(r, cells);
  }
  return grid;
}

function excelDate(serial, date1904) {
  const base = date1904 ? Date.UTC(1904, 0, 1) : Date.UTC(1899, 11, 30);
  const d = new Date(base + Math.round(serial * 86400000));
  return d.toISOString().slice(0, 10);
}

function numberText(n) {
  return Number.isInteger(n) ? String(n) : String(n);
}

/** One cell, coerced to what its column holds. Returns { value } or { error }. */
function coerce(cell, kind, date1904) {
  if (!cell) return { value: null };
  if (cell.t === "e") return { error: ["CELL_ERROR", `The cell shows the Excel error ${cell.v}.`] };
  const { t, v } = cell;
  switch (kind) {
    case "id":
    case "text": {
      let s;
      if (t === "s" || t === "d") s = v;
      else if (t === "n") s = numberText(v);
      else if (t === "b") s = v ? "TRUE" : "FALSE";
      if (kind === "id") s = s.trim();
      return { value: s === "" ? null : s };
    }
    case "int": {
      const n = t === "n" ? v : t === "s" && /^\s*-?\d+\s*$/.test(v) ? Number(v) : NaN;
      if (t === "s" && v.trim() === "") return { value: null };
      if (!Number.isInteger(n)) return { error: ["NOT_A_WHOLE_NUMBER", `Expected a whole number, found "${t === "b" ? (v ? "TRUE" : "FALSE") : v}".`] };
      return { value: n };
    }
    case "num": {
      if (t === "s" && v.trim() === "") return { value: null };
      const n = t === "n" ? v : t === "s" && v.trim() !== "" ? Number(v) : NaN;
      if (!Number.isFinite(n)) return { error: ["NOT_A_NUMBER", `Expected a number, found "${v}".`] };
      return { value: n };
    }
    case "bool": {
      if (t === "b") return { value: v };
      if (t === "n" && (v === 1 || v === 0)) return { value: v === 1 };
      if (t === "s") {
        const s = v.trim().toLowerCase();
        if (s === "") return { value: null };
        if (s === "true" || s === "yes" || s === "1") return { value: true };
        if (s === "false" || s === "no" || s === "0") return { value: false };
      }
      return { error: ["NOT_TRUE_OR_FALSE", `Expected TRUE or FALSE, found "${v}".`] };
    }
    case "json": {
      if (t !== "s") return { error: ["INVALID_JSON", `Expected JSON text, found ${t === "n" ? "a number" : "a TRUE/FALSE value"}.`] };
      if (v.trim() === "") return { value: null };
      try { return { value: JSON.parse(v) }; } catch (e) { return { error: ["INVALID_JSON", `This is not valid JSON: ${e.message}`] }; }
    }
    case "date": {
      if (t === "n") return { value: excelDate(v, date1904) };
      if (t === "d") return { value: v.slice(0, 10) };
      if (t === "s") return { value: v.trim() === "" ? null : v.trim() };
      return { error: ["NOT_A_DATE", `Expected a date, found "${v}".`] };
    }
    default:
      return { value: null };
  }
}

function findSheet(sheets, name) {
  for (const [k, v] of sheets) if (k.toLowerCase() === name.toLowerCase()) return v;
  return null;
}

/**
 * Reads one table sheet: locates its header row, maps columns by name, coerces every cell, skips
 * blank rows. Returns { records, rows (Excel row number per record), columnOf (field -> letter) }.
 */
function readTable(sheet, spec, date1904, errors, warnings) {
  const where = { sheet: spec.sheet };
  let headerRow = null;
  let headers = null;
  const firstColumn = spec.columns[0].name;
  for (let r = 1; r <= HEADER_SEARCH_ROWS; r++) {
    const cells = sheet.grid.get(r);
    if (!cells) continue;
    const names = new Map();
    for (const [ci, cell] of cells) if (cell.t === "s" && cell.v.trim() !== "") names.set(ci, cell.v.trim().toLowerCase());
    if ([...names.values()].includes(firstColumn)) { headerRow = r; headers = names; break; }
  }
  if (!headerRow) {
    errors.push(issue("HEADER_ROW_MISSING", `No header row naming "${firstColumn}" was found in the first ${HEADER_SEARCH_ROWS} rows.`, where));
    return null;
  }
  const byName = new Map();
  for (const [ci, name] of headers) {
    if (byName.has(name)) errors.push(issue("DUPLICATE_COLUMN", `The column "${name}" appears twice.`, { ...where, row: headerRow, column: name, cell: `${columnLetter(ci)}${headerRow}` }));
    else byName.set(name, ci);
  }
  const known = new Set(spec.columns.map((c) => c.name));
  for (const [name, ci] of byName) {
    if (!known.has(name)) warnings.push(issue("COLUMN_IGNORED", `The column "${name}" is not part of the format and was ignored.`, { ...where, row: headerRow, column: name, cell: `${columnLetter(ci)}${headerRow}` }));
  }
  const columnOf = {};
  let missing = false;
  for (const c of spec.columns) {
    if (!byName.has(c.name)) {
      errors.push(issue("COLUMN_MISSING", `The column "${c.name}" is missing.`, { ...where, row: headerRow, column: c.name }));
      missing = true;
    } else {
      columnOf[c.field] = columnLetter(byName.get(c.name));
    }
  }
  if (missing) return null;
  const records = [];
  const rows = [];
  const rowNumbers = [...sheet.grid.keys()].filter((r) => r > headerRow).sort((a, b) => a - b);
  for (const r of rowNumbers) {
    const cells = sheet.grid.get(r);
    const record = {};
    let any = false;
    const rowErrors = [];
    for (const c of spec.columns) {
      const ci = byName.get(c.name);
      const cell = cells.get(ci);
      if (cell && !(cell.t === "s" && cell.v.trim() === "")) any = true;
      const out = coerce(cell, c.kind, date1904);
      if (out.error) rowErrors.push(issue(out.error[0], out.error[1], { ...where, row: r, column: c.name, cell: `${columnLetter(ci)}${r}` }));
      else record[c.field] = out.value;
    }
    if (!any) continue;
    errors.push(...rowErrors);
    records.push(record);
    rows.push(r);
  }
  return { records, rows, columnOf };
}

function readSingle(sheet, spec, date1904, errors, warnings) {
  const t = readTable(sheet, spec, date1904, errors, warnings);
  if (!t) return null;
  if (t.records.length !== 1) {
    errors.push(issue("ONE_ROW_REQUIRED", `The ${spec.sheet} sheet must have exactly one row below its headers; it has ${t.records.length}.`, { sheet: spec.sheet }));
    return null;
  }
  return { record: t.records[0], row: t.rows[0], columnOf: t.columnOf };
}

/**
 * Keeps contentReview.unresolvedPlaceholders true to the items after an edit in Excel, by the same
 * rule the in-app editor applies (DraftEditor.refreshPlaceholderSummary): surviving entries keep
 * their order and take the item's current prompt and source location, entries for items no longer
 * marked are dropped, newly marked items are appended by key. A summary that already agrees is left
 * exactly as it is. Returns true when it changed.
 */
function refreshPlaceholderSummary(document) {
  const review = document.contentReview;
  if (!review || typeof review !== "object" || !Array.isArray(review.unresolvedPlaceholders)) return false;
  const marked = new Map();
  for (const it of document.items) if (it.reviewStatus === PLACEHOLDER_REVIEW_STATUS && it.itemKey) marked.set(it.itemKey, it);
  const entry = (it) => ({ itemKey: it.itemKey, prompt: it.prompt, sourceLocation: it.sourceLocation ?? null });
  const rebuilt = [];
  const kept = new Set();
  for (const existing of review.unresolvedPlaceholders) {
    if (!existing || typeof existing !== "object" || !marked.has(existing.itemKey) || kept.has(existing.itemKey)) continue;
    rebuilt.push(entry(marked.get(existing.itemKey)));
    kept.add(existing.itemKey);
  }
  for (const key of [...marked.keys()].sort()) if (!kept.has(key)) rebuilt.push(entry(marked.get(key)));
  if (canonical(rebuilt) === canonical(review.unresolvedPlaceholders)) return false;
  review.unresolvedPlaceholders = rebuilt;
  return true;
}

/**
 * For each collection, the document index of each row in the order the server's normalizer sorts
 * them (ConfigNormalizer.fromConfig / normalizeConfig), so a path into the normalized definitions
 * finds its sheet row.
 */
function normalizedOrders(document) {
  const setKeyById = new Map((document.responseSets || []).map((r) => [r.responseSetId, r.setKey]));
  const codeById = new Map((document.dimensions || []).map((d) => [d.dimensionId, d.code]));
  const sortKey = {
    sections: (r) => [r.sectionKey],
    items: (r) => [r.itemKey],
    responseSets: (r) => [r.setKey],
    responseOptions: (r) => [setKeyById.get(r.responseSetId) ?? null, r.optionKey],
    rules: (r) => [r.ruleKey],
    dimensions: (r) => [r.code],
    dimensionValues: (r) => [codeById.get(r.dimensionId) ?? null, r.valueCode],
    instrumentDimensions: (r) => [codeById.get(r.dimensionId) ?? null],
  };
  const out = {};
  for (const t of TABLES) {
    const rows = document[t.collection] || [];
    const keyed = rows.map((r, i) => ({ i, k: sortKey[t.collection](r).map((v) => (v === null || v === undefined ? null : String(v))) }));
    keyed.sort((a, b) => compareKeys(a.k, b.k));
    out[t.collection] = keyed.map((x) => x.i);
  }
  return out;
}

function makeLocator(document, found) {
  const orders = normalizedOrders(document);
  const bySheet = Object.fromEntries(TABLES.map((t) => [t.collection, t]));
  const columnFor = (spec, field, columnOf) => {
    const c = spec.columns.find((x) => x.field === field);
    const name = c ? c.name : (spec.normalized && spec.normalized[field]) || null;
    if (!name) return {};
    const fieldOf = c ? c.field : spec.columns.find((x) => x.name === name)?.field;
    return { column: name, letter: fieldOf ? columnOf[fieldOf] : undefined };
  };
  return function locate(path) {
    if (typeof path !== "string") return null;
    let m = /^\$\.(definitions\.)?([A-Za-z]+)\[([^\]]+)\](?:\.([A-Za-z]+))?/.exec(path);
    if (m && bySheet[m[2]] && found.tables[m[2]]) {
      const spec = bySheet[m[2]];
      const table = found.tables[m[2]];
      let index = null;
      if (/^\d+$/.test(m[3])) {
        const n = parseInt(m[3], 10);
        index = m[1] ? orders[m[2]][n] : n;
      } else {
        index = (document[m[2]] || []).findIndex((r) => String(r[spec.keyField]) === m[3]);
      }
      if (index === undefined || index === null || index < 0 || index >= table.rows.length) return { sheet: spec.sheet };
      const row = table.rows[index];
      const loc = { sheet: spec.sheet, row };
      if (m[4]) {
        const { column, letter } = columnFor(spec, m[4], table.columnOf);
        if (column) { loc.column = column; if (letter) loc.cell = `${letter}${row}`; }
      }
      return loc;
    }
    m = /^\$\.instrument\.version(?:\.([A-Za-z]+))?/.exec(path);
    if (m && found.version) {
      const loc = { sheet: VERSION.sheet, row: found.version.row };
      if (m[1]) {
        const c = VERSION.columns.find((x) => x.field === m[1]);
        if (c) { loc.column = c.name; loc.cell = `${found.version.columnOf[c.field]}${found.version.row}`; }
      }
      return loc;
    }
    m = /^\$\.instrument(?:\.([A-Za-z]+))?/.exec(path);
    if (m && found.instrument) {
      const loc = { sheet: INSTRUMENT.sheet, row: found.instrument.row };
      if (m[1]) {
        const c = INSTRUMENT.columns.find((x) => x.field === m[1]);
        if (c) { loc.column = c.name; loc.cell = `${found.instrument.columnOf[c.field]}${found.instrument.row}`; }
      }
      return loc;
    }
    m = /^\$\.([A-Za-z]+)/.exec(path);
    if (m && found.documentRows && found.documentRows[m[1]]) {
      return { sheet: DOCUMENT.sheet, row: found.documentRows[m[1]], column: "value_json", cell: `${found.documentColumn}${found.documentRows[m[1]]}` };
    }
    return null;
  };
}

/**
 * An .xlsx file -> the document the import route takes.
 *
 * @return {
 *   ok, document, errors[], warnings[] (each { code, message, sheet?, row?, column?, cell? }),
 *   meta: where the file was downloaded from (or null),
 *   locate(path): the sheet, row and column a document path came from (or null)
 * }
 * `ok` is false when any error was found; the document is then not to be sent. Pass
 * { requireDocumentSheet: false } to read only the tables of a workbook that has no document sheet.
 */
export async function readWorkbook(bytes, { requireDocumentSheet = true } = {}) {
  const errors = [];
  const warnings = [];
  const data = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  let loaded;
  try {
    loaded = loadSheets(await readZip(data));
  } catch (e) {
    if (e instanceof WorkbookError) return { ok: false, document: null, errors: [issue(e.code, e.message)], warnings, meta: null, locate: () => null };
    throw e;
  }
  const { sheets, date1904 } = loaded;
  const expected = new Set(SHEET_NAMES.map((s) => s.toLowerCase()).concat(START_HERE.toLowerCase()));
  for (const name of sheets.keys()) {
    if (!expected.has(name.toLowerCase())) warnings.push(issue("SHEET_IGNORED", `The sheet "${name}" is not part of the format and was ignored.`, { sheet: name }));
  }
  const need = (name) => {
    const s = findSheet(sheets, name);
    if (!s) errors.push(issue("SHEET_MISSING", `The sheet "${name}" is missing.`, { sheet: name }));
    return s;
  };

  const found = { tables: {} };
  const instSheet = need(INSTRUMENT.sheet);
  const versionSheet = need(VERSION.sheet);
  if (instSheet) found.instrument = readSingle(instSheet, INSTRUMENT, date1904, errors, warnings);
  if (versionSheet) found.version = readSingle(versionSheet, VERSION, date1904, errors, warnings);
  for (const t of TABLES) {
    const s = need(t.sheet);
    if (s) {
      const table = readTable(s, t, date1904, errors, warnings);
      if (table) found.tables[t.collection] = table;
    }
  }

  let meta = null;
  const docValues = {};
  const docSheet = findSheet(sheets, DOCUMENT.sheet);
  if (!docSheet && requireDocumentSheet) errors.push(issue("SHEET_MISSING", `The sheet "${DOCUMENT.sheet}" is missing. Start from a workbook downloaded from ICFWalk.`, { sheet: DOCUMENT.sheet }));
  if (docSheet) {
    const table = readTable(docSheet, DOCUMENT, date1904, errors, warnings);
    if (table) {
      found.documentRows = {};
      found.documentColumn = table.columnOf.value;
      const known = new Set([...DOCUMENT.members, ...DOCUMENT.exportMembers]);
      table.records.forEach((rec, i) => {
        const row = table.rows[i];
        const where = { sheet: DOCUMENT.sheet, row, column: "value_json", cell: `${table.columnOf.value}${row}` };
        if (!rec.member || !known.has(rec.member)) {
          warnings.push(issue("MEMBER_IGNORED", `"${rec.member ?? ""}" is not a document member and was ignored.`, { sheet: DOCUMENT.sheet, row }));
          return;
        }
        let value = null;
        try { value = rec.value === null ? null : JSON.parse(rec.value); } catch (e) {
          errors.push(issue("INVALID_JSON", `The value of ${rec.member} is not valid JSON: ${e.message}`, where));
          return;
        }
        docValues[rec.member] = value;
        found.documentRows[rec.member] = row;
      });
      for (const m of DOCUMENT.members) {
        if (!(m in docValues) && requireDocumentSheet) errors.push(issue("MEMBER_MISSING", `The document sheet has no row for ${m}.`, { sheet: DOCUMENT.sheet }));
      }
      if (docValues["export.format"] !== undefined && docValues["export.format"] !== WORKBOOK_FORMAT) {
        warnings.push(issue("FORMAT_UNKNOWN", `This workbook says it is "${docValues["export.format"]}", not "${WORKBOOK_FORMAT}". It was read anyway.`, { sheet: DOCUMENT.sheet }));
      }
      if (docValues["export.versionId"]) {
        meta = {
          versionId: docValues["export.versionId"], versionLabel: docValues["export.versionLabel"] ?? null, status: docValues["export.status"] ?? null,
          checksum: docValues["export.checksum"] ?? null, instrumentCode: docValues["export.instrumentCode"] ?? null, exportedAt: docValues["export.exportedAt"] ?? null,
        };
      }
    }
  }

  if (errors.length) return { ok: false, document: null, errors, warnings, meta, locate: () => null };

  const document = {};
  for (const m of DOCUMENT.members) if (m in docValues) document[m] = docValues[m];
  document.instrument = { ...found.instrument.record, version: { ...found.version.record } };
  for (const t of TABLES) document[t.collection] = found.tables[t.collection].records;
  if (refreshPlaceholderSummary(document)) {
    warnings.push(issue("PLACEHOLDER_SUMMARY_UPDATED", "The list of questions still awaiting approved wording was brought up to date with the items' review status.", { sheet: DOCUMENT.sheet }));
  }
  return { ok: true, document, errors, warnings, meta, locate: makeLocator(document, found) };
}

/** True when the bytes start like a zip file (every .xlsx does). */
export function looksLikeWorkbook(bytes) {
  const b = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  return b.length > 4 && b[0] === 0x50 && b[1] === 0x4B && b[2] === 0x03 && b[3] === 0x04;
}

/** "ICFWalk_ICFWALK_2026-09-17_aligned_prototype" -- safe in every file system. */
export function fileBaseName(instrumentCode, versionLabel) {
  const safe = (s) => String(s ?? "").replace(/[^A-Za-z0-9_-]+/g, "_").replace(/^_+|_+$/g, "").slice(0, 80);
  return ["ICFWalk", safe(instrumentCode), safe(versionLabel)].filter(Boolean).join("_");
}
