// Static contract between the supplied SQL schema and the CFML data-access layer: every table
// and column the repository writes or reads must exist in database/001_schema.sql (plus the
// definition column from 002). This catches drift without a database.
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { root } from "./helpers.mjs";

const schema = fs.readFileSync(path.join(root, "database", "001_schema.sql"), "utf8");
const patch = fs.readFileSync(path.join(root, "database", "002_alignment_patch.sql"), "utf8");

function columnsOf(table) {
  const start = schema.indexOf(`CREATE TABLE [icf].[${table}]`);
  assert.ok(start >= 0, `table ${table} present`);
  const end = schema.indexOf(");", start);
  const body = schema.slice(start, end);
  const columns = new Set([...body.matchAll(/^\s+\[([a-z0-9_]+)\]\s+(?:uniqueidentifier|nvarchar|int|bit|datetime2|rowversion|decimal|date|char|bigint)/gm)].map((m) => m[1]));
  return columns;
}

const expected = {
  instrument: ["instrument_id", "code", "name", "description", "active", "updated_at"],
  instrument_version: ["version_id", "instrument_id", "version_label", "status", "effective_start", "effective_end", "compiled_snapshot_json", "checksum_sha256", "created_by_user_id", "published_by_user_id", "created_at", "published_at", "updated_at", "row_version"],
  section_definition: ["section_id", "version_id", "parent_section_id", "section_key", "display_order", "title", "instructions", "notes_enabled", "settings_json", "active", "updated_at"],
  response_set: ["response_set_id", "version_id", "response_set_key", "name", "selection_mode", "settings_json", "active", "updated_at"],
  response_option: ["option_id", "response_set_id", "option_key", "stored_code", "label", "display_order", "numeric_score", "is_na", "active", "updated_at"],
  rule_definition: ["rule_id", "version_id", "rule_key", "target_type", "target_key", "effect", "conditions_json", "active", "updated_at"],
  dimension_definition: ["dimension_id", "code", "label", "data_type", "reportable", "sensitive", "settings_json", "active", "updated_at"],
  dimension_value: ["value_id", "dimension_id", "value_code", "label", "display_order", "effective_start", "effective_end", "active", "updated_at"],
  instrument_dimension: ["version_id", "dimension_id", "section_id", "display_order", "required", "rule_key", "label_override", "settings_json", "updated_at"],
  item_definition: ["item_id", "version_id", "section_id", "response_set_id", "item_key", "reporting_key", "item_type", "prompt", "help_text", "display_order", "required", "settings_json", "active", "updated_at"],
  walk: ["walk_id", "version_id", "org_unit_id", "owner_user_id", "status", "row_version"],
  audit_event: ["event_id", "entity_type", "entity_id", "event_type", "actor_user_id", "event_at", "correlation_id", "details_json"],
};

test("repository columns exist in 001_schema.sql", () => {
  for (const [table, columns] of Object.entries(expected)) {
    const actual = columnsOf(table);
    for (const column of columns) assert.ok(actual.has(column), `${table}.${column}`);
  }
});

test("002 patch adds response_option.definition idempotently", () => {
  assert.match(patch, /IF COL_LENGTH\(N'icf\.response_option', N'definition'\) IS NULL/);
  assert.match(patch, /ADD \[definition\] nvarchar\(max\) NULL/);
});

test("CFML SQL references only known icf tables", () => {
  const cfml = ["src/instrument/DefinitionRepository.cfc", "src/audit/AuditRepository.cfc", "src/controllers/HealthController.cfc", "src/instrument/InstrumentImportService.cfc"]
    .map((f) => fs.readFileSync(path.join(root, f), "utf8")).join("\n");
  const known = new Set([...schema.matchAll(/CREATE TABLE \[icf\]\.\[([a-z_]+)\]/g)].map((m) => m[1]));
  for (const match of cfml.matchAll(/\[icf\]\.\[([a-z_]+)\]/g)) assert.ok(known.has(match[1]), `unknown table icf.${match[1]}`);
});

test("schema-critical constraints the importer relies on are present", () => {
  for (const name of ["UX_section_sibling_order", "UX_response_option_order", "UX_item_section_order", "UX_instrument_dimension_order", "UX_dimension_value_order", "UQ_instrument_version_label", "UQ_item_version_key", "UQ_section_version_key", "UQ_response_set_version_key", "UQ_rule_version_key", "CK_instrument_version_status", "CK_instrument_version_publish_values"]) {
    assert.ok(schema.includes(name), name);
  }
});
