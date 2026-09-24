/**
 * The Excel round-trip's converter (app/assets/js/workbook.js), run in Node exactly as the browser
 * runs it: no dependency, the platform's own raw-deflate streams, its own XML reader.
 *
 * What is proved here:
 *   - the reviewed aligned workbook in config/ (written by other software) reads to exactly the
 *     supplied instrument -- same definitions checksum, same whole-snapshot checksum;
 *   - download then upload with no change gives back the exact document, and the same document
 *     always produces the same bytes;
 *   - a workbook LibreOffice Calc opened and saved reads back unchanged, and edits made in
 *     LibreOffice come back exactly (fixtures in tests/fixtures/workbooks);
 *   - text survives exactly, and cells typed in a spreadsheet's own ways are read as their column
 *     means them;
 *   - every problem in a workbook is reported with its sheet, row and column, and produces nothing;
 *   - files that are not workbooks, or are hostile, are refused without being expanded;
 *   - every path the server reports, including paths into its key-sorted normalized definitions,
 *     is located on the sheet row it came from;
 *   - the placeholder summary follows the items and is otherwise left exactly as it was.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { root } from "./helpers.mjs";
import {
  readWorkbook, writeWorkbook, readZip, writeZip, parseXml, describeLocation, looksLikeWorkbook, fileBaseName, SHEET_NAMES, WORKBOOK_FORMAT,
} from "../../app/assets/js/workbook.js";
import { canonicalize, compileSnapshot, normalizeConfig } from "../../scripts/lib/snapshot.mjs";

const SOURCE = JSON.parse(fs.readFileSync(path.join(root, "config", "instrument-config.json"), "utf8"));
const FIXTURES = path.join(root, "tests", "fixtures", "workbooks");
const EXPORTED_FROM = { versionId: "V", versionLabel: "L", status: "PUBLISHED", checksum: "c", instrumentCode: "ICFWALK" };
const EXPORTED_AT = "2026-09-24T00:00:00Z";
const COLLECTIONS = ["sections", "items", "responseSets", "responseOptions", "rules", "dimensions", "dimensionValues", "instrumentDimensions"];
// The order writeWorkbook lays sheets out in (sheet1 is Start Here).
const SHEET_FILE = Object.fromEntries(["Start Here", ...SHEET_NAMES].map((name, i) => [name, `xl/worksheets/sheet${i + 1}.xml`]));

/** The document an export produces for the supplied instrument: the source without the two members import ignores. */
function exportedDocument() {
  const doc = structuredClone(SOURCE);
  delete doc.generatedAt;
  delete doc.counts;
  return doc;
}

async function workbookOf(doc = exportedDocument()) {
  return writeWorkbook(doc, { exportedFrom: EXPORTED_FROM, exportedAt: EXPORTED_AT });
}

/** Rewrites one sheet's XML inside a workbook, as a spreadsheet program saving a change would. */
async function patchSheet(bytes, sheet, edit) {
  const files = await readZip(bytes);
  const name = SHEET_FILE[sheet];
  const xml = new TextDecoder().decode(files.get(name));
  const next = edit(xml);
  assert.notEqual(next, xml, `the patch to ${sheet} changed something`);
  files.set(name, new TextEncoder().encode(next));
  return writeZip([...files].map(([n, data]) => ({ name: n, data })));
}

/** Replaces the cell at `ref` (which must exist) with `cellXml`. */
function setCell(xml, ref, cellXml) {
  const re = new RegExp(`<c r="${ref}"[^>]*?(?:/>|>.*?</c>)`);
  assert.match(xml, re, `cell ${ref} exists`);
  return xml.replace(re, cellXml);
}

function inline(ref, text) {
  return `<c r="${ref}" t="inlineStr"><is><t xml:space="preserve">${text}</t></is></c>`;
}

/** The Excel row of the record with `key`, as writeWorkbook lays it out (headers on row 3). */
function rowOf(collection, field, value, doc = exportedDocument()) {
  const i = doc[collection].findIndex((r) => r[field] === value);
  assert.ok(i >= 0, `${collection} has ${field} ${value}`);
  return 4 + i;
}

function codes(list) { return list.map((i) => i.code); }

// ---- reading what others wrote ------------------------------------------------------------------

test("the reviewed aligned workbook in config/ reads to exactly the supplied instrument", async () => {
  const bytes = new Uint8Array(fs.readFileSync(path.join(root, "config", "ICFWalk_Instrument_Configuration_Aligned.xlsx")));
  const r = await readWorkbook(bytes, { requireDocumentSheet: false });
  assert.equal(r.ok, true, JSON.stringify(r.errors));
  // It carries three descriptive columns on its instrument sheet that the document has no place for.
  assert.deepEqual(r.warnings.map((w) => `${w.code}:${w.column}`), ["COLUMN_IGNORED:source_file", "COLUMN_IGNORED:review_status", "COLUMN_IGNORED:revision_notes"]);
  for (const k of COLLECTIONS) assert.equal(r.document[k].length, SOURCE[k].length, k);
  const doc = { ...r.document, schemaVersion: SOURCE.schemaVersion, source: SOURCE.source, behavior: SOURCE.behavior, contentReview: SOURCE.contentReview };
  const expected = compileSnapshot(normalizeConfig(SOURCE));
  const actual = compileSnapshot(normalizeConfig(doc));
  assert.equal(actual.definitionsChecksum, expected.definitionsChecksum, "the same definitions");
  assert.equal(actual.checksum, expected.checksum, "and the same whole snapshot");
});

test("download then upload with no change gives back the exact document, and the bytes are reproducible", async () => {
  const doc = exportedDocument();
  const bytes = await workbookOf(doc);
  assert.equal(looksLikeWorkbook(bytes), true);
  const r = await readWorkbook(bytes);
  assert.equal(r.ok, true, JSON.stringify(r.errors));
  assert.deepEqual(r.warnings, []);
  assert.equal(canonicalize(r.document), canonicalize(doc));
  assert.deepEqual(r.meta, { ...EXPORTED_FROM, exportedAt: EXPORTED_AT });
  const again = await workbookOf(doc);
  assert.equal(Buffer.compare(Buffer.from(bytes), Buffer.from(again)), 0, "same document, same bytes");
  const files = await readZip(bytes);
  const workbookXml = new TextDecoder().decode(files.get("xl/workbook.xml"));
  assert.deepEqual([...workbookXml.matchAll(/<sheet name="([^"]+)"/g)].map((m) => m[1]), ["Start Here", ...SHEET_NAMES]);
});

test("a workbook LibreOffice Calc opened and saved reads back unchanged", async () => {
  const r = await readWorkbook(new Uint8Array(fs.readFileSync(path.join(FIXTURES, "libreoffice-resaved.xlsx"))));
  assert.equal(r.ok, true, JSON.stringify(r.errors));
  assert.deepEqual(r.warnings, []);
  assert.equal(canonicalize(r.document), canonicalize(exportedDocument()));
  assert.equal(r.meta.versionId, "V");
});

test("edits made in LibreOffice Calc come back exactly, and nothing else moves", async () => {
  const r = await readWorkbook(new Uint8Array(fs.readFileSync(path.join(FIXTURES, "libreoffice-edited.xlsx"))));
  assert.equal(r.ok, true, JSON.stringify(r.errors));
  assert.deepEqual(codes(r.warnings), ["PLACEHOLDER_SUMMARY_UPDATED"]);
  const expected = exportedDocument();
  const item = (d, k) => d.items.find((i) => i.itemKey === k);
  item(expected, "prek_k_q1").prompt = "Students can describe today's learning goal.";
  item(expected, "prek_k_q1").reviewStatus = "Reviewed";
  item(expected, "prek_k_q2").displayOrder = 15;
  item(expected, "prek_k_q3").required = true;
  expected.dimensionValues.find((v) => v.valueCode === "abbott_middle_school").label = "2024";
  expected.responseOptions.push({
    optionId: "opt_yes_no_maybe", responseSetId: "rs_yes_no", optionKey: "maybe", storedCode: "maybe", label: "Maybe", definition: null,
    numericScore: null, isNa: false, displayOrder: 30, active: true, sourceLocation: "added in LibreOffice", reviewStatus: "Reviewed", revisionNotes: null,
  });
  expected.contentReview.unresolvedPlaceholders = expected.contentReview.unresolvedPlaceholders.filter((p) => p.itemKey !== "prek_k_q1");
  assert.equal(r.document.contentReview.unresolvedPlaceholders.length, 16);
  assert.equal(typeof item(r.document, "prek_k_q2").displayOrder, "number");
  assert.equal(item(r.document, "prek_k_q3").required, true);
  for (const k of Object.keys(expected)) assert.equal(canonicalize(r.document[k]), canonicalize(expected[k]), k);
});

// ---- values ------------------------------------------------------------------------------------

test("text survives exactly: markup, quotes, accents, emoji, line breaks, edge spaces, Excel escapes, long text", async () => {
  const doc = exportedDocument();
  const tricky = [
    "<b>bold</b> & \"quoted\" & 'single'",
    "Élève naïve · café — ¿qué? 学习 😀",
    "line one\nline two\r\nline three\ttabbed",
    "  leading and trailing  ",
    "literal _x0041_ and _x005F_ must stay literal",
    "control \u0001 character",
    "007",
    "TRUE",
    "x".repeat(4000),
  ];
  // Questions that are not placeholders, so the placeholder summary is not involved.
  const targets = doc.items.map((it, i) => ({ it, i })).filter(({ it }) => it.reviewStatus !== "Placeholder in source").slice(0, tricky.length + 1);
  tricky.forEach((text, n) => { targets[n].it.prompt = text; });
  targets[tricky.length].it.helpText = "=SUM(A1:A2)";
  const r = await readWorkbook(await workbookOf(doc));
  assert.equal(r.ok, true, JSON.stringify(r.errors));
  assert.deepEqual(r.warnings, []);
  tricky.forEach((text, n) => assert.equal(r.document.items[targets[n].i].prompt, text, JSON.stringify(text.slice(0, 40))));
  assert.equal(r.document.items[targets[tricky.length].i].helpText, "=SUM(A1:A2)", "a formula-looking value stays text");
  assert.equal(canonicalize(r.document), canonicalize(doc));
});

test("cells typed in a spreadsheet's own ways are read as their column means them", async () => {
  const doc = exportedDocument();
  let bytes = await workbookOf(doc);
  const q1 = rowOf("items", "itemKey", "prek_k_q1");
  const q2 = rowOf("items", "itemKey", "prek_k_q2");
  // item_definition: G item_type, H prompt, M display_order, N required, O reportable, P active
  bytes = await patchSheet(bytes, "item_definition", (xml) => {
    let x = setCell(xml, `H${q1}`, `<c r="H${q1}"><v>42</v></c>`);                 // a number typed into a text column
    x = setCell(x, `M${q1}`, inline(`M${q1}`, " 25 "));                            // a whole number typed as text
    x = setCell(x, `N${q1}`, inline(`N${q1}`, "yes"));                             // yes/no words in a TRUE/FALSE column
    x = setCell(x, `O${q1}`, `<c r="O${q1}"><v>0</v></c>`);                        // 1/0 numbers
    x = setCell(x, `P${q1}`, inline(`P${q1}`, "False"));
    x = setCell(x, `H${q2}`, `<c r="H${q2}" t="b"><v>1</v></c>`);                  // a TRUE typed into a text column
    return x;
  });
  const abbott = rowOf("dimensionValues", "valueCode", "abbott_middle_school");
  // dimension_value: C value_code, I effective_start, J effective_end
  bytes = await patchSheet(bytes, "dimension_value", (xml) => {
    let x = xml.replace(`<row r="${abbott}">`, `<row r="${abbott}"><c r="I${abbott}"><v>46023</v></c><c r="J${abbott}" t="d"><v>2027-06-30T00:00:00Z</v></c>`);
    x = setCell(x, `C${abbott}`, `<c r="C${abbott}"><v>7</v></c>`);                // a code that looks like a number
    return x;
  });
  const r = await readWorkbook(bytes);
  assert.equal(r.ok, true, JSON.stringify(r.errors));
  const item = (k) => r.document.items.find((i) => i.itemKey === k);
  assert.equal(item("prek_k_q1").prompt, "42");
  assert.equal(item("prek_k_q1").displayOrder, 25);
  assert.equal(item("prek_k_q1").required, true);
  assert.equal(item("prek_k_q1").reportable, false);
  assert.equal(item("prek_k_q1").active, false);
  assert.equal(item("prek_k_q2").prompt, "TRUE");
  const value = r.document.dimensionValues[abbott - 4];
  assert.equal(value.valueCode, "7");
  assert.equal(value.effectiveStart, "2026-01-01", "an Excel date serial is a date");
  assert.equal(value.effectiveEnd, "2027-06-30");
});

// ---- problems ------------------------------------------------------------------------------------

test("problems in a workbook are reported by sheet, row and column, and nothing is produced", async () => {
  const doc = exportedDocument();
  const q1 = rowOf("items", "itemKey", "prek_k_q1");
  let bytes = await workbookOf(doc);
  bytes = await patchSheet(bytes, "item_definition", (xml) => {
    let x = setCell(xml, `N${q1}`, inline(`N${q1}`, "maybe"));
    x = setCell(x, `M${q1}`, inline(`M${q1}`, "ten"));
    x = setCell(x, `Q${q1}`, inline(`Q${q1}`, "{not json"));
    x = setCell(x, `P${q1}`, `<c r="P${q1}" t="e"><v>#REF!</v></c>`);
    return x;
  });
  bytes = await patchSheet(bytes, "response_option", (xml) => setCell(xml, "I4", `<c r="I4"><v>1.5</v></c>`));  // display_order
  bytes = await patchSheet(bytes, "instrument", (xml) => xml.replace("</sheetData>", `<row r="5">${inline("A5", "inst_second")}${inline("B5", "SECOND")}</row></sheetData>`));
  const r = await readWorkbook(bytes);
  assert.equal(r.ok, false);
  assert.equal(r.document, null);
  const found = r.errors.map((e) => `${e.code}@${e.sheet}!${e.cell ?? ""}`);
  assert.ok(found.includes(`NOT_TRUE_OR_FALSE@item_definition!N${q1}`), found.join(" "));
  assert.ok(found.includes(`NOT_A_WHOLE_NUMBER@item_definition!M${q1}`), found.join(" "));
  assert.ok(found.includes(`INVALID_JSON@item_definition!Q${q1}`), found.join(" "));
  assert.ok(found.includes(`CELL_ERROR@item_definition!P${q1}`), found.join(" "));
  assert.ok(found.includes("NOT_A_WHOLE_NUMBER@response_option!I4"), found.join(" "));
  assert.ok(found.includes("ONE_ROW_REQUIRED@instrument!"), found.join(" "));
  const bad = r.errors.find((e) => e.code === "NOT_TRUE_OR_FALSE");
  assert.equal(describeLocation(bad), `item_definition, row ${q1}, column required (N${q1})`);
  assert.match(bad.message, /maybe/);
});

test("a missing sheet, a missing column, a duplicate column and a damaged document sheet are each named", async () => {
  let bytes = await workbookOf();
  bytes = await patchSheet(bytes, "item_definition", (xml) => xml.replace(">prompt</t>", ">question_text</t>").replace(">help_text</t>", ">item_type</t>"));
  bytes = await patchSheet(bytes, "document", (xml) => xml.replace("{&quot;file&quot;:", "{broken&quot;file&quot;:"));
  const files = await readZip(bytes);
  const workbookXml = new TextDecoder().decode(files.get("xl/workbook.xml")).replace(/<sheet name="rule_definition"[^>]*\/>/, "");
  files.set("xl/workbook.xml", new TextEncoder().encode(workbookXml));
  const r = await readWorkbook(await writeZip([...files].map(([name, data]) => ({ name, data }))));
  assert.equal(r.ok, false);
  const found = r.errors.map((e) => `${e.code}:${e.sheet}:${e.column ?? ""}`);
  assert.ok(found.includes("SHEET_MISSING:rule_definition:"), found.join(" "));
  assert.ok(found.includes("COLUMN_MISSING:item_definition:prompt"), found.join(" "));
  assert.ok(found.includes("DUPLICATE_COLUMN:item_definition:item_type"), found.join(" "));
  assert.ok(found.includes("INVALID_JSON:document:value_json"), found.join(" "));
  assert.ok(r.warnings.some((w) => w.code === "COLUMN_IGNORED" && w.column === "question_text"));
});

test("files that are not workbooks, or are hostile, are refused without being expanded", async () => {
  const enc = new TextEncoder();
  const notZip = await readWorkbook(enc.encode("name,prompt\nq1,hello\n"));
  assert.deepEqual(codes(notZip.errors), ["NOT_A_WORKBOOK"]);

  const noWorkbook = await readWorkbook(await writeZip([{ name: "hello.txt", data: enc.encode("hi") }]));
  assert.deepEqual(codes(noWorkbook.errors), ["NOT_A_WORKBOOK"]);

  let doctype = await workbookOf();
  doctype = await patchSheet(doctype, "instrument", (xml) => xml.replace("<worksheet", "<!DOCTYPE x [<!ENTITY e SYSTEM \"file:///etc/passwd\">]><worksheet"));
  assert.deepEqual(codes((await readWorkbook(doctype)).errors), ["XML_DOCTYPE"]);

  // An entry that would inflate past the limit is stopped while it inflates.
  const { deflateRawSync } = await import("node:zlib");
  const bombData = deflateRawSync(Buffer.alloc(30 * 1024 * 1024));
  const bomb = await writeZip([{ name: "xl/workbook.xml", data: new Uint8Array(bombData), stored: true }]);
  // Rewrite the stored entry as deflated with the true size: a small file that claims little and expands a lot.
  const view = new DataView(bomb.buffer, bomb.byteOffset, bomb.byteLength);
  view.setUint16(8, 8, true);
  const dir = bomb.length - 22 - 46 - "xl/workbook.xml".length;
  view.setUint16(dir + 10, 8, true);
  view.setUint32(dir + 24, 30 * 1024 * 1024, true);
  assert.deepEqual(codes((await readWorkbook(bomb)).errors), ["ZIP_TOO_LARGE"]);
  view.setUint32(dir + 24, 1000, true);
  assert.deepEqual(codes((await readWorkbook(bomb)).errors), ["ZIP_TOO_LARGE"], "a part that inflates past its declared size is stopped too");

  const encrypted = await workbookOf();
  const ev = new DataView(encrypted.buffer, encrypted.byteOffset, encrypted.byteLength);
  const eocd = encrypted.length - 22;
  const dirStart = ev.getUint32(eocd + 16, true);
  ev.setUint16(dirStart + 8, ev.getUint16(dirStart + 8, true) | 1, true);
  assert.deepEqual(codes((await readWorkbook(encrypted)).errors), ["WORKBOOK_ENCRYPTED"]);

  const stored = await workbookOf();
  const sv = new DataView(stored.buffer, stored.byteOffset, stored.byteLength);
  sv.setUint16(sv.getUint32(stored.length - 22 + 16, true) + 10, 12, true);  // bzip2
  assert.deepEqual(codes((await readWorkbook(stored)).errors), ["ZIP_UNSUPPORTED"]);

  assert.throws(() => parseXml("<a><b></a>"), /Unexpected closing tag/);
});

// ---- locating server problems ---------------------------------------------------------------------

test("every path the server reports is located on the sheet row it came from", async () => {
  const doc = exportedDocument();
  const r = await readWorkbook(await workbookOf(doc));
  assert.equal(r.ok, true);
  assert.deepEqual(r.locate("$.items[3].prompt"), { sheet: "item_definition", row: 7, column: "prompt", cell: "H7" });
  assert.deepEqual(r.locate("$.items[prek_k_q1]"), { sheet: "item_definition", row: rowOf("items", "itemKey", "prek_k_q1") });
  assert.deepEqual(r.locate("$.instrument.version.versionLabel"), { sheet: "instrument_version", row: 4, column: "version_label", cell: "C4" });
  assert.deepEqual(r.locate("$.instrument.code"), { sheet: "instrument", row: 4, column: "code", cell: "B4" });
  const review = r.locate("$.contentReview.unresolvedPlaceholders");
  assert.equal(review.sheet, "document");
  assert.equal(review.column, "value_json");
  assert.equal(r.locate("$.definitions"), null);
  assert.equal(r.locate("nonsense"), null);

  // The server's normalized definitions are sorted by key; every index maps back to its own row.
  const normalized = normalizeConfig(doc).definitions;
  const keyOf = { sections: "sectionKey", items: "itemKey", responseSets: "setKey", responseOptions: "authoringId", rules: "ruleKey", dimensions: "code", dimensionValues: "authoringId", instrumentDimensions: "authoringId" };
  const idOf = { responseOptions: "optionId", dimensionValues: "dimensionValueId", instrumentDimensions: "instrumentDimensionId" };
  for (const k of COLLECTIONS) {
    normalized[k].forEach((row, i) => {
      const loc = r.locate(`$.definitions.${k}[${i}]`);
      const record = doc[k][loc.row - 4];
      const field = keyOf[k];
      const expected = field === "authoringId" ? row.authoringId : row[field];
      const actual = field === "authoringId" ? record[idOf[k]] : record[field];
      assert.equal(actual, expected, `${k}[${i}]`);
    });
  }
  const rule = r.locate("$.definitions.rules[0].conditions.conditions[0].sourceKey");
  assert.equal(rule.column, "conditions_json");
  const option = r.locate("$.definitions.responseOptions[5].setKey");
  assert.equal(option.column, "response_set_id");
});

// ---- the placeholder summary ------------------------------------------------------------------------

test("the placeholder summary follows the items and is otherwise left exactly as it was", async () => {
  const doc = exportedDocument();
  const unchanged = await readWorkbook(await workbookOf(doc));
  assert.equal(canonicalize(unchanged.document.contentReview), canonicalize(doc.contentReview));
  assert.ok(!unchanged.warnings.some((w) => w.code === "PLACEHOLDER_SUMMARY_UPDATED"));

  const edited = exportedDocument();
  const marked = edited.items.find((i) => i.reviewStatus !== "Placeholder in source" && i.itemType === "SINGLE_CHOICE");
  const resolved = edited.items.find((i) => i.itemKey === "prek_k_q2");
  resolved.reviewStatus = "Reviewed";
  marked.reviewStatus = "Placeholder in source";
  const before = edited.contentReview.unresolvedPlaceholders.map((p) => p.itemKey);
  const r = await readWorkbook(await workbookOf(edited));
  assert.ok(r.warnings.some((w) => w.code === "PLACEHOLDER_SUMMARY_UPDATED"));
  const after = r.document.contentReview.unresolvedPlaceholders.map((p) => p.itemKey);
  assert.deepEqual(after, [...before.filter((k) => k !== "prek_k_q2"), marked.itemKey], "survivors keep their order; the newly marked item is appended");
  assert.equal(r.document.contentReview.unresolvedPlaceholders.at(-1).prompt, marked.prompt);
});

test("file names are safe and the format is named", () => {
  assert.equal(fileBaseName("ICFWALK", "2026-09-17 aligned prototype"), "ICFWalk_ICFWALK_2026-09-17_aligned_prototype");
  assert.equal(fileBaseName("x/../y", "a\"b<c>"), "ICFWalk_x_y_a_b_c");
  assert.equal(WORKBOOK_FORMAT, "icfwalk-instrument-workbook/1");
  assert.equal(looksLikeWorkbook(new TextEncoder().encode("{}")), false);
});
