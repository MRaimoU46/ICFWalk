// Acceptance PKG-01 .. PKG-05: handoff package integrity and configuration counts.
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import zlib from "node:zlib";
import { root } from "./helpers.mjs";

const PROTOTYPE_SHA256 = "239531267fa1dfaedaf4e1a8842156bc90db425893781330470312e3c34a1361";
const config = JSON.parse(fs.readFileSync(path.join(root, "config", "instrument-config.json"), "utf8"));

test("PKG-01 validate-handoff exits 0 with all checks confirmed", () => {
  const run = spawnSync(process.execPath, [path.join(root, "scripts", "validate-handoff.mjs")], { encoding: "utf8" });
  assert.equal(run.status, 0, run.stderr || run.stdout);
  const report = JSON.parse(run.stdout);
  assert.equal(report.ok, true);
  assert.equal(report.errors, 0);
  assert.ok(report.checks >= 50);
});

test("PKG-02 no retired SIP hierarchy; Part 3 is Conditions for Learning", () => {
  const activeText = JSON.stringify({ sections: config.sections, items: config.items }).toLowerCase();
  assert.ok(!activeText.includes("school improvement (sip)"));
  assert.ok(!activeText.includes("sip grade"));
  const part3 = config.sections.find((s) => s.sectionKey === "part3");
  assert.equal(part3.title, "Part 3 · Conditions for Learning");
});

test("PKG-03 exactly 17 placeholders split 3/3/3/3/5", () => {
  const placeholders = config.items.filter((i) => i.reviewStatus === "Placeholder in source");
  assert.equal(placeholders.length, 17);
  const bySection = {};
  for (const p of placeholders) bySection[p.sectionId] = (bySection[p.sectionId] ?? 0) + 1;
  assert.deepEqual(bySection, { sec_prek_k: 3, sec_mac_prep: 3, sec_ignite: 3, sec_avid: 3, sec_content_area: 5 });
});

test("PKG-04 prototype SHA-256 equals JSON source metadata", () => {
  const actual = crypto.createHash("sha256").update(fs.readFileSync(path.join(root, "source", "current-prototype.html"))).digest("hex");
  assert.equal(actual, PROTOTYPE_SHA256);
  assert.equal(config.source.sha256, PROTOTYPE_SHA256);
  assert.equal(config.instrument.version.sourceSha256, PROTOTYPE_SHA256);
});

// Minimal .xlsx reader: central directory + raw-deflate, enough to count sheet rows.
function readZipEntries(buffer) {
  const entries = new Map();
  const eocd = buffer.lastIndexOf(Buffer.from([0x50, 0x4b, 0x05, 0x06]));
  const count = buffer.readUInt16LE(eocd + 10);
  let offset = buffer.readUInt32LE(eocd + 16);
  for (let i = 0; i < count; i += 1) {
    const method = buffer.readUInt16LE(offset + 10);
    const compressedSize = buffer.readUInt32LE(offset + 20);
    const nameLength = buffer.readUInt16LE(offset + 28);
    const extraLength = buffer.readUInt16LE(offset + 30);
    const commentLength = buffer.readUInt16LE(offset + 32);
    const localOffset = buffer.readUInt32LE(offset + 42);
    const name = buffer.toString("utf8", offset + 46, offset + 46 + nameLength);
    const localNameLength = buffer.readUInt16LE(localOffset + 26);
    const localExtraLength = buffer.readUInt16LE(localOffset + 28);
    const dataStart = localOffset + 30 + localNameLength + localExtraLength;
    const data = buffer.subarray(dataStart, dataStart + compressedSize);
    entries.set(name, method === 8 ? zlib.inflateRawSync(data) : Buffer.from(data));
    offset += 46 + nameLength + extraLength + commentLength;
  }
  return entries;
}

test("PKG-05 aligned workbook table row counts equal JSON counts", () => {
  const entries = readZipEntries(fs.readFileSync(path.join(root, "config", "ICFWalk_Instrument_Configuration_Aligned.xlsx")));
  const workbook = entries.get("xl/workbook.xml").toString("utf8");
  const rels = entries.get("xl/_rels/workbook.xml.rels").toString("utf8");
  const relTargets = Object.fromEntries([...rels.matchAll(/Target="\/([^"]+)"\s+Id="([^"]+)"/g)].map((m) => [m[2], m[1]]));
  const sheets = [...workbook.matchAll(/<x:sheet name="([^"]+)" sheetId="\d+" r:id="([^"]+)"/g)].map((m) => ({ name: m[1], path: relTargets[m[2]] }));
  const HEADER_ROWS = 3; // title, description, column header
  const rowCount = (name) => {
    const sheet = sheets.find((s) => s.name === name);
    assert.ok(sheet, `sheet ${name} exists`);
    const xml = entries.get(sheet.path).toString("utf8");
    return (xml.match(/<x:row[ >]/g) ?? []).length - HEADER_ROWS;
  };
  const expected = { section_definition: 23, item_definition: 144, response_set: 29, response_option: 138, rule_definition: 12, dimension_definition: 10, dimension_value: 95, instrument_dimension: 10 };
  for (const [sheet, count] of Object.entries(expected)) assert.equal(rowCount(sheet), count, sheet);
  assert.deepEqual(config.counts, { sections: 23, items: 144, responseSets: 29, responseOptions: 138, rules: 12, dimensions: 10, dimensionValues: 95, instrumentDimensions: 10 });
  for (const [key, count] of Object.entries(config.counts)) assert.equal(config[key].length, count, key);
});
