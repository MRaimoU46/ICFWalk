import crypto from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(scriptDir, "..");
const expectedHashes = {
  "source/current-prototype.html": "239531267fa1dfaedaf4e1a8842156bc90db425893781330470312e3c34a1361",
  "database/001_schema.sql": "c6c16b6cdc1ae10760e43f0bcbf32a4fd84eed51166f1487fb6b7484532d1374",
  "reference/legacy-configuration-workbook.xlsx": "16212bdbafa9e2429940da89380ef818d9c54c80a5e36ae67b58f8502692407f",
};
const expectedCounts = {
  sections: 23,
  items: 144,
  responseSets: 29,
  responseOptions: 138,
  rules: 12,
  dimensions: 10,
  dimensionValues: 95,
  instrumentDimensions: 10,
};

const errors = [];
const checks = [];

function pass(message) {
  checks.push(message);
}

function fail(message) {
  errors.push(message);
}

async function read(relativePath) {
  return fs.readFile(path.join(root, relativePath));
}

function sha256(bytes) {
  return crypto.createHash("sha256").update(bytes).digest("hex");
}

function checkUnique(records, getter, label) {
  const seen = new Set();
  for (const record of records) {
    const value = getter(record);
    if (value === null || value === undefined || value === "") {
      fail(`${label} contains a blank key.`);
    } else if (seen.has(value)) {
      fail(`${label} contains duplicate key: ${value}`);
    } else {
      seen.add(value);
    }
  }
  if (!errors.some((e) => e.startsWith(label))) pass(`${label} keys are unique.`);
}

for (const [relativePath, expected] of Object.entries(expectedHashes)) {
  try {
    const actual = sha256(await read(relativePath));
    if (actual !== expected) fail(`${relativePath} SHA-256 mismatch: ${actual}`);
    else pass(`${relativePath} SHA-256 verified.`);
  } catch (error) {
    fail(`${relativePath} could not be read: ${error.message}`);
  }
}

for (const required of [
  "README.md",
  "CLAUDE_FABLE_MASTER_PROMPT.md",
  "manifest.json",
  "config/instrument-config.json",
  "config/ICFWalk_Instrument_Configuration_Aligned.xlsx",
  "database/002_alignment_patch.sql",
  "docs/PRODUCT_SPEC.md",
  "docs/SOURCE_ALIGNMENT.md",
  "docs/DATA_CONTRACT.md",
  "docs/ACCEPTANCE_TESTS.md",
  "docs/IMPLEMENTATION_PLAN.md",
  "docs/OPEN_DECISIONS.md",
]) {
  try {
    const stats = await fs.stat(path.join(root, required));
    if (!stats.isFile() || stats.size === 0) fail(`${required} is missing or empty.`);
    else pass(`${required} is present.`);
  } catch {
    fail(`${required} is missing.`);
  }
}

try {
  const manifest = JSON.parse((await read("manifest.json")).toString("utf8"));
  const manifestPaths = new Set(manifest.files.map((entry) => entry.path));
  for (const entry of manifest.files) {
    const bytes = await read(entry.path);
    const actualHash = sha256(bytes);
    if (actualHash !== entry.sha256 || bytes.length !== entry.bytes) {
      fail(`Manifest mismatch for ${entry.path}.`);
    }
  }
  async function listFiles(directory) {
    const out = [];
    for (const entry of await fs.readdir(directory, { withFileTypes: true })) {
      const absolute = path.join(directory, entry.name);
      if (entry.isDirectory()) out.push(...await listFiles(absolute));
      else if (entry.isFile()) out.push(path.relative(root, absolute).split(path.sep).join("/"));
    }
    return out;
  }
  // The handoff package is delivered as a Git repository and is then extended with the
  // application build. Version-control internals and files added by the build are not
  // package members, so they are reported rather than failed. Pass --strict-package to
  // restore the original "no unlisted files" behavior when auditing a pristine package.
  const strictPackage = process.argv.includes("--strict-package");
  const ignoredPrefixes = [".git/", "node_modules/", ".runtime/"];
  const actualPaths = (await listFiles(root))
    .filter((value) => value !== "manifest.json")
    .filter((value) => !ignoredPrefixes.some((prefix) => value.startsWith(prefix)));
  const unlistedPaths = actualPaths.filter((relativePath) => !manifestPaths.has(relativePath));
  if (strictPackage) {
    for (const relativePath of unlistedPaths) fail(`Manifest is missing ${relativePath}.`);
  }
  for (const relativePath of manifestPaths) {
    if (!actualPaths.includes(relativePath)) fail(`Manifest contains nonexistent file ${relativePath}.`);
  }
  if (!errors.some((e) => e.startsWith("Manifest"))) {
    pass(`Package manifest hashes and file list verified (${unlistedPaths.length} build file(s) outside the package manifest).`);
  }
} catch (error) {
  fail(`manifest.json is invalid: ${error.message}`);
}

let config;
try {
  config = JSON.parse((await read("config/instrument-config.json")).toString("utf8"));
  pass("instrument-config.json parses as JSON.");
} catch (error) {
  fail(`instrument-config.json is invalid: ${error.message}`);
}

if (config) {
  const currentPrototypeHash = sha256(await read("source/current-prototype.html"));
  if (config.source?.sha256 !== currentPrototypeHash) {
    fail("Configuration source hash does not match current-prototype.html.");
  } else {
    pass("Configuration source hash matches current-prototype.html.");
  }

  for (const [key, expected] of Object.entries(expectedCounts)) {
    const actual = Array.isArray(config[key]) ? config[key].length : null;
    if (actual !== expected || config.counts?.[key] !== expected) {
      fail(`${key} count mismatch: array=${actual}, declared=${config.counts?.[key]}, expected=${expected}`);
    } else {
      pass(`${key} count ${expected} verified.`);
    }
  }

  checkUnique(config.sections, (x) => x.sectionId, "section IDs");
  checkUnique(config.sections, (x) => x.sectionKey, "section keys");
  checkUnique(config.items, (x) => x.itemId, "item IDs");
  checkUnique(config.items, (x) => x.itemKey, "item keys");
  checkUnique(config.responseSets, (x) => x.responseSetId, "response-set IDs");
  checkUnique(config.responseSets, (x) => x.setKey, "response-set keys");
  checkUnique(config.responseOptions, (x) => x.optionId, "response-option IDs");
  checkUnique(config.responseOptions, (x) => `${x.responseSetId}|${x.optionKey}`, "response-option set/key pairs");
  checkUnique(config.responseOptions, (x) => `${x.responseSetId}|${x.storedCode}`, "response-option set/code pairs");
  checkUnique(config.rules, (x) => x.ruleId, "rule IDs");
  checkUnique(config.rules, (x) => x.ruleKey, "rule keys");
  checkUnique(config.dimensions, (x) => x.dimensionId, "dimension IDs");
  checkUnique(config.dimensions, (x) => x.code, "dimension codes");
  checkUnique(config.dimensionValues, (x) => x.dimensionValueId, "dimension-value IDs");
  checkUnique(config.dimensionValues, (x) => `${x.dimensionId}|${x.valueCode}`, "dimension/value-code pairs");
  checkUnique(config.instrumentDimensions, (x) => x.instrumentDimensionId, "instrument-dimension IDs");
  checkUnique(config.instrumentDimensions, (x) => `${x.versionId}|${x.dimensionId}`, "instrument-version/dimension pairs");

  const sectionIds = new Set(config.sections.map((x) => x.sectionId));
  const itemIds = new Set(config.items.map((x) => x.itemId));
  const itemKeys = new Set(config.items.map((x) => x.itemKey));
  const responseSetIds = new Set(config.responseSets.map((x) => x.responseSetId));
  const dimensionIds = new Set(config.dimensions.map((x) => x.dimensionId));
  const dimensionCodes = new Set(config.dimensions.map((x) => x.code));
  const ruleKeys = new Set(config.rules.map((x) => x.ruleKey));

  for (const section of config.sections) {
    if (section.parentSectionId && !sectionIds.has(section.parentSectionId)) {
      fail(`Section ${section.sectionId} references missing parent ${section.parentSectionId}.`);
    }
  }
  for (const item of config.items) {
    if (!sectionIds.has(item.sectionId)) fail(`Item ${item.itemId} references missing section ${item.sectionId}.`);
    if (item.responseSetId && !responseSetIds.has(item.responseSetId)) fail(`Item ${item.itemId} references missing response set ${item.responseSetId}.`);
  }
  for (const option of config.responseOptions) {
    if (!responseSetIds.has(option.responseSetId)) fail(`Option ${option.optionId} references missing response set ${option.responseSetId}.`);
  }
  for (const value of config.dimensionValues) {
    if (!dimensionIds.has(value.dimensionId)) fail(`Dimension value ${value.dimensionValueId} references missing dimension ${value.dimensionId}.`);
  }
  for (const placement of config.instrumentDimensions) {
    if (!dimensionIds.has(placement.dimensionId)) fail(`Placement ${placement.instrumentDimensionId} references missing dimension ${placement.dimensionId}.`);
    if (placement.sectionId && !sectionIds.has(placement.sectionId)) fail(`Placement ${placement.instrumentDimensionId} references missing section ${placement.sectionId}.`);
    if (placement.ruleKey && !ruleKeys.has(placement.ruleKey)) fail(`Placement ${placement.instrumentDimensionId} references missing rule ${placement.ruleKey}.`);
  }
  for (const rule of config.rules) {
    const targetOk = rule.targetType === "SECTION"
      ? sectionIds.has(rule.targetId)
      : rule.targetType === "ITEM"
        ? itemIds.has(rule.targetId)
        : rule.targetType === "DIMENSION"
          ? dimensionIds.has(rule.targetId)
          : false;
    if (!targetOk) fail(`Rule ${rule.ruleKey} has invalid target ${rule.targetType}:${rule.targetId}.`);
    const sourceOk = rule.sourceType === "ITEM"
      ? itemKeys.has(rule.sourceId)
      : rule.sourceType === "DIMENSION"
        ? dimensionCodes.has(rule.sourceId)
        : false;
    if (!sourceOk) fail(`Rule ${rule.ruleKey} has invalid source ${rule.sourceType}:${rule.sourceId}.`);
    try {
      JSON.parse(rule.conditionsJson);
    } catch {
      fail(`Rule ${rule.ruleKey} has invalid conditionsJson.`);
    }
  }
  pass("Configuration references and rule JSON were checked.");

  const part3 = config.sections.find((x) => x.sectionKey === "part3");
  if (part3?.title !== "Part 3 · Conditions for Learning") fail("Part 3 title is not the current Conditions for Learning version.");
  else pass("Current Part 3 title verified.");

  const activeText = JSON.stringify({ sections: config.sections, items: config.items }).toLowerCase();
  if (activeText.includes("school improvement (sip)") || activeText.includes("sip grade")) {
    fail("Retired SIP hierarchy text appears in active configuration.");
  } else {
    pass("No retired SIP hierarchy appears in active configuration.");
  }

  const placeholders = config.items.filter((x) => x.reviewStatus === "Placeholder in source");
  if (placeholders.length !== 17) fail(`Expected 17 placeholders, found ${placeholders.length}.`);
  else pass("Exactly 17 current placeholders verified.");

  const skippable = config.sections.filter((x) => x.settings?.canBeSkipped).map((x) => x.sectionKey).sort();
  if (JSON.stringify(skippable) !== JSON.stringify(["s3", "s4"])) fail(`Unexpected skippable components: ${skippable.join(", ")}`);
  else pass("Workshop Model and Academic Teaming are the only skippable components.");
}

const schemaText = (await read("database/001_schema.sql")).toString("utf8");
for (const table of [
  "org_unit", "app_user", "app_role", "user_role_scope", "instrument",
  "instrument_version", "section_definition", "response_set", "response_option",
  "rule_definition", "dimension_definition", "dimension_value", "instrument_dimension",
  "item_definition", "walk", "walk_dimension_value", "walk_response",
  "walk_response_selection", "walk_revision", "audit_event",
]) {
  if (!schemaText.includes(`CREATE TABLE [icf].[${table}]`)) fail(`database/001_schema.sql is missing icf.${table}.`);
}
pass("Required SQL tables were checked.");

const patchText = (await read("database/002_alignment_patch.sql")).toString("utf8");
if (!/ADD \[definition\] nvarchar\(max\) NULL/i.test(patchText)) fail("Alignment patch does not add response_option.definition.");
else pass("Response-option definition patch verified.");

const prototypeText = (await read("source/current-prototype.html")).toString("utf8");
if (!prototypeText.includes("Part 3 &middot; Conditions for Learning")) fail("Current prototype Part 3 marker is missing.");
else pass("Current prototype Part 3 marker verified.");

if (errors.length) {
  console.error(JSON.stringify({ ok: false, checks: checks.length, errors }, null, 2));
  process.exitCode = 1;
} else {
  console.log(JSON.stringify({ ok: true, checks: checks.length, errors: 0, counts: expectedCounts }, null, 2));
}
