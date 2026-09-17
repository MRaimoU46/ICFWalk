// Reference snapshot compiler: golden checksum, structure, and key-based references.
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { compileSnapshot, normalizeConfig } from "../../scripts/lib/snapshot.mjs";
import { root } from "./helpers.mjs";

const config = JSON.parse(fs.readFileSync(path.join(root, "config", "instrument-config.json"), "utf8"));
const golden = JSON.parse(fs.readFileSync(path.join(root, "tests", "golden", "instrument-snapshot.golden.json"), "utf8"));

test("compiled snapshot matches the golden checksums and counts", () => {
  const compiled = compileSnapshot(normalizeConfig(config));
  assert.equal(compiled.checksum, golden.checksum);
  assert.equal(compiled.definitionsChecksum, golden.definitionsChecksum);
  assert.equal(Buffer.byteLength(compiled.canonicalJson, "utf8"), golden.canonicalBytes);
  assert.deepEqual(compiled.counts, golden.counts);
  assert.equal(compiled.counts.placeholders, 17);
});

test("snapshot references are logical keys, never GUIDs, and rules resolve to keys", () => {
  const compiled = compileSnapshot(normalizeConfig(config));
  assert.ok(!/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i.test(compiled.canonicalJson));
  const rules = compiled.snapshot.definitions.rules;
  assert.equal(rules.find((r) => r.ruleKey === "show_prek_k").targetKey, "prek_k_classroom");
  assert.equal(rules.find((r) => r.ruleKey === "show_period_for_grades_6_12").targetKey, "period");
  assert.equal(rules.find((r) => r.ruleKey === "show_comp_s4_q2").targetKey, "comp_s4_q2");
  assert.equal(rules.find((r) => r.ruleKey === "show_comp_s4_q2").sourceKey, "comp_s4_applicable");
  for (const rule of rules) assert.notEqual(rule.targetKey, null, rule.ruleKey);
  for (const item of compiled.snapshot.definitions.items) assert.notEqual(item.sectionKey, null, item.itemKey);
  for (const option of compiled.snapshot.definitions.responseOptions) assert.notEqual(option.setKey, null, option.optionKey);
});

test("snapshot preserves exact prototype wording and skippable defaults", () => {
  const compiled = compileSnapshot(normalizeConfig(config));
  const sections = compiled.snapshot.definitions.sections;
  assert.equal(sections.find((s) => s.sectionKey === "part1").title, "Part 1 · Target / Taxonomy / Pacing");
  assert.equal(sections.find((s) => s.sectionKey === "part3").title, "Part 3 · Conditions for Learning");
  const s3 = sections.find((s) => s.sectionKey === "s3");
  assert.equal(s3.settings.canBeSkipped, true);
  assert.equal(s3.settings.defaultApplicable, false);
  const items = compiled.snapshot.definitions.items;
  assert.equal(items.find((i) => i.itemKey === "comp_s3_applicable").settings.defaultStoredCode, "no");
  assert.equal(items.find((i) => i.itemKey === "comp_s4_applicable").settings.defaultStoredCode, "no");
  assert.equal(compiled.snapshot.behavior.export.fileNamePattern, "ICFWalk_<grade>_<content>_<date>.txt");
});
