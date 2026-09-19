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
const mutationPatch = fs.readFileSync(path.join(root, "database", "003_walk_mutation.sql"), "utf8");
const fingerprintPatch = fs.readFileSync(path.join(root, "database", "004_mutation_fingerprint.sql"), "utf8");

function columnsOf(table) {
  const source = table === "walk_mutation" ? mutationPatch : schema;
  const start = source.indexOf(`CREATE TABLE [icf].[${table}]`);
  assert.ok(start >= 0, `table ${table} present`);
  const end = source.indexOf(");", start);
  const body = source.slice(start, end);
  const columns = new Set([...body.matchAll(/^\s+\[([a-z0-9_]+)\]\s+(?:uniqueidentifier|nvarchar|int|bit|datetime2|rowversion|decimal|date|char|bigint)/gm)].map((m) => m[1]));
  // Columns added by a later additive patch belong to the same logical table.
  if (table === "walk_mutation") {
    for (const m of fingerprintPatch.matchAll(/ADD \[([a-z0-9_]+)\] (?:char|nvarchar|int|bit|datetime2)/g)) columns.add(m[1]);
  }
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
  walk: ["walk_id", "version_id", "org_unit_id", "owner_user_id", "status", "observed_at", "created_at", "updated_at", "completed_at", "voided_at", "void_reason", "row_version"],
  walk_dimension_value: ["walk_id", "version_id", "dimension_id", "selected_value_id", "text_value", "number_value", "date_value", "boolean_value", "updated_at"],
  walk_response: ["response_id", "walk_id", "version_id", "item_id", "response_state", "selected_option_id", "text_value", "number_value", "date_value", "boolean_value", "updated_at"],
  walk_revision: ["revision_id", "walk_id", "revision_number", "actor_user_id", "reason", "prior_snapshot_json", "created_at"],
  walk_mutation: ["mutation_id", "walk_id", "actor_user_id", "action", "request_fingerprint", "result_json", "created_at"],
  org_unit: ["org_unit_id", "parent_org_unit_id", "org_unit_code", "org_unit_type", "name", "active", "updated_at"],
  app_user: ["user_id", "identity_subject", "display_name", "email", "active", "last_sign_in_at", "updated_at"],
  app_role: ["role_id", "role_code", "scope_type", "can_create_walk", "can_open_walk_details", "can_edit_owned_walks", "can_view_aggregate_reports", "can_manage_instruments", "active"],
  user_role_scope: ["user_role_scope_id", "user_id", "role_id", "org_unit_id", "effective_start", "effective_end", "include_descendants", "created_by_user_id"],
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

test("003 patch adds icf.walk_mutation idempotently", () => {
  assert.match(mutationPatch, /IF OBJECT_ID\(N'\[icf\]\.\[walk_mutation\]', N'U'\) IS NULL/);
  assert.match(mutationPatch, /CHECK \(\[action\] IN \(N'CREATE', N'SAVE', N'COMPLETE', N'VOID'\)\)/);
});

test("004 patch adds walk_mutation.request_fingerprint idempotently and additively", () => {
  assert.match(fingerprintPatch, /IF COL_LENGTH\(N'\[icf\]\.\[walk_mutation\]', N'request_fingerprint'\) IS NULL/);
  assert.match(fingerprintPatch, /ADD \[request_fingerprint\] char\(64\) NULL/);
  // Nullable, so rows written before the patch stay valid and replayable on their original binding.
  assert.doesNotMatch(fingerprintPatch, /request_fingerprint\] char\(64\) NOT NULL/);
  // No CREATE TABLE, no DROP, no UPDATE of existing rows: additive only.
  assert.doesNotMatch(fingerprintPatch, /\bDROP\b/);
  assert.doesNotMatch(fingerprintPatch, /\bCREATE TABLE\b/);
  assert.doesNotMatch(fingerprintPatch, /\bUPDATE \[icf\]/);
  // SQL Server 2016 compatible: no STRING_AGG, no JSON_OBJECT, no GENERATED ALWAYS.
  assert.doesNotMatch(fingerprintPatch, /STRING_AGG|JSON_OBJECT|GENERATED ALWAYS|GREATEST|LEAST/i);
});

test("CFML SQL references only known icf tables", () => {
  const cfml = ["src/instrument/DefinitionRepository.cfc", "src/audit/AuditRepository.cfc", "src/controllers/HealthController.cfc", "src/instrument/InstrumentImportService.cfc",
    "src/identity/UserRepository.cfc", "src/authorization/OrgUnitRepository.cfc", "src/authorization/RoleScopeRepository.cfc", "src/authorization/AuthorizationService.cfc", "src/controllers/MaintenanceController.cfc",
    "src/walks/WalkRepository.cfc", "src/walks/WalkService.cfc", "src/instrument/SnapshotService.cfc"]
    .map((f) => fs.readFileSync(path.join(root, f), "utf8")).join("\n");
  const known = new Set([...(schema + mutationPatch).matchAll(/CREATE TABLE \[icf\]\.\[([a-z_]+)\]/g)].map((m) => m[1]));
  for (const match of cfml.matchAll(/\[icf\]\.\[([a-z_]+)\]/g)) assert.ok(known.has(match[1]), `unknown table icf.${match[1]}`);
});

test("schema-critical constraints the importer relies on are present", () => {
  for (const name of ["UX_section_sibling_order", "UX_response_option_order", "UX_item_section_order", "UX_instrument_dimension_order", "UX_dimension_value_order", "UQ_instrument_version_label", "UQ_item_version_key", "UQ_section_version_key", "UQ_response_set_version_key", "UQ_rule_version_key", "CK_instrument_version_status", "CK_instrument_version_publish_values"]) {
    assert.ok(schema.includes(name), name);
  }
});
