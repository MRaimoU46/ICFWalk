// Acceptance DB-01, DB-02, DB-03 against a real SQL Server (2016+). Creates a disposable
// database with the admin login, applies the supplied scripts, and drops it afterwards.
// Skipped when no database configuration is available.
import { test } from "node:test";
import assert from "node:assert/strict";
import sql from "mssql";
import { applyScript, connectionConfig, hasDatabaseConfig, loadRuntimeEnv, readScript } from "./helpers.mjs";

const env = loadRuntimeEnv();
const available = hasDatabaseConfig(env);
const dbName = `icfwalk_scripts_${Date.now().toString(36)}`;

test("DB-01..03 supplied scripts against an empty SQL Server database", { skip: available ? false : "ICFWALK_DB_* not configured" }, async (t) => {
  const master = await sql.connect(connectionConfig(env, "master", true));
  await master.request().batch(`CREATE DATABASE [${dbName}]`);
  await master.close();
  const pool = await sql.connect(connectionConfig(env, dbName, true));
  try {
    const version = await pool.request().query("SELECT SERVERPROPERTY('ProductVersion') AS v, SERVERPROPERTY('Edition') AS e");
    t.diagnostic(`SQL Server ${version.recordset[0].v} ${version.recordset[0].e}`);
    assert.ok(Number(String(version.recordset[0].v).split(".")[0]) >= 13, "SQL Server 2016 or later");

    // DB-01: both scripts complete and commit.
    const first = await applyScript(pool, readScript("001_schema.sql"));
    assert.equal(first.ok, true, first.error?.message);
    assert.equal(first.recordset[0].result, "ICFWalk database objects created successfully.");
    assert.equal(Number(first.recordset[0].table_count), 20);
    const patch = await applyScript(pool, readScript("002_alignment_patch.sql"));
    assert.equal(patch.ok, true, patch.error?.message);
    assert.equal(patch.recordset[0].response_option_definition_available, 1);
    const roles = await pool.request().query("SELECT role_code, can_manage_instruments, can_open_walk_details FROM icf.app_role ORDER BY role_code");
    assert.deepEqual(roles.recordset.map((r) => r.role_code), ["DISTRICT_REPORT_ONLY", "DISTRICT_WALK_REPORT", "MASTER_INSTRUMENT_ADMIN", "SCHOOL_REPORT_ONLY", "SCHOOL_WALK_REPORT"]);
    const admin = roles.recordset.find((r) => r.role_code === "MASTER_INSTRUMENT_ADMIN");
    assert.equal(admin.can_manage_instruments, true);
    assert.equal(admin.can_open_walk_details, false);
    const instrument = await pool.request().query("SELECT code FROM icf.instrument");
    assert.deepEqual(instrument.recordset.map((r) => r.code), ["ICFWALK"]);

    // DB-02: rerunning 001 aborts without dropping or replacing objects.
    const before = await pool.request().query("SELECT COUNT(*) AS n FROM sys.tables WHERE schema_id = SCHEMA_ID('icf')");
    const rerun = await applyScript(pool, readScript("001_schema.sql"));
    assert.equal(rerun.ok, false);
    assert.equal(rerun.error.number, 50001);
    assert.match(rerun.error.message, /already contains tables/);
    const after = await pool.request().query("SELECT COUNT(*) AS n FROM sys.tables WHERE schema_id = SCHEMA_ID('icf')");
    assert.equal(after.recordset[0].n, before.recordset[0].n);
    const rolesAfter = await pool.request().query("SELECT COUNT(*) AS n FROM icf.app_role");
    assert.equal(rolesAfter.recordset[0].n, 5, "no duplicate seed rows");

    // DB-03: reapplying 002 is a no-op without error or duplicate column.
    const patchAgain = await applyScript(pool, readScript("002_alignment_patch.sql"));
    assert.equal(patchAgain.ok, true, patchAgain.error?.message);
    const cols = await pool.request().query("SELECT COUNT(*) AS n FROM sys.columns WHERE object_id = OBJECT_ID('icf.response_option') AND name = 'definition'");
    assert.equal(cols.recordset[0].n, 1);

    // Phase 4 migration 003: walk mutation log, additive and idempotent.
    const mutation = await applyScript(pool, readScript("003_walk_mutation.sql"));
    assert.equal(mutation.ok, true, mutation.error?.message);
    assert.equal(mutation.recordset[0].walk_mutation_available, 1);
    const mutationAgain = await applyScript(pool, readScript("003_walk_mutation.sql"));
    assert.equal(mutationAgain.ok, true, mutationAgain.error?.message);
    const tables = await pool.request().query("SELECT COUNT(*) AS n FROM sys.tables WHERE schema_id = SCHEMA_ID('icf')");
    assert.equal(tables.recordset[0].n, 21);
    const mutationCols = await pool.request().query("SELECT COUNT(*) AS n FROM sys.columns WHERE object_id = OBJECT_ID('icf.walk_mutation')");
    assert.equal(mutationCols.recordset[0].n, 6);

    // Correction migration 004: the request fingerprint column, additive and idempotent.
    const fingerprint = await applyScript(pool, readScript("004_mutation_fingerprint.sql"));
    assert.equal(fingerprint.ok, true, fingerprint.error?.message);
    assert.equal(fingerprint.recordset[0].request_fingerprint_available, 1);
    const fingerprintAgain = await applyScript(pool, readScript("004_mutation_fingerprint.sql"));
    assert.equal(fingerprintAgain.ok, true, fingerprintAgain.error?.message);
    const fingerprintCol = await pool.request().query("SELECT COUNT(*) AS n FROM sys.columns WHERE object_id = OBJECT_ID('icf.walk_mutation') AND name = 'request_fingerprint'");
    assert.equal(fingerprintCol.recordset[0].n, 1, "one fingerprint column after two applications");
    const mutationColsAfter = await pool.request().query("SELECT COUNT(*) AS n FROM sys.columns WHERE object_id = OBJECT_ID('icf.walk_mutation')");
    assert.equal(mutationColsAfter.recordset[0].n, 7);
    const tablesAfter = await pool.request().query("SELECT COUNT(*) AS n FROM sys.tables WHERE schema_id = SCHEMA_ID('icf')");
    assert.equal(tablesAfter.recordset[0].n, 21, "004 adds no table");
    // The digest constraint accepts a lower-case hexadecimal SHA-256 and refuses anything else.
    await pool.request().batch(`INSERT INTO icf.org_unit (org_unit_id, org_unit_code, org_unit_type, name) VALUES ('11111111-1111-1111-1111-111111111111', 'fp-unit', 'SCHOOL', 'Fingerprint fixture');
      INSERT INTO icf.app_user (user_id, identity_subject, display_name) VALUES ('22222222-2222-2222-2222-222222222222', 'fp-user', 'Fingerprint fixture');
      INSERT INTO icf.instrument (instrument_id, code, name) VALUES ('33333333-3333-3333-3333-333333333333', 'FPTEST', 'Fingerprint fixture');
      INSERT INTO icf.instrument_version (version_id, instrument_id, version_label, status) VALUES ('44444444-4444-4444-4444-444444444444', '33333333-3333-3333-3333-333333333333', 'fp', 'DRAFT');
      INSERT INTO icf.walk (walk_id, version_id, org_unit_id, owner_user_id) VALUES ('55555555-5555-5555-5555-555555555555', '44444444-4444-4444-4444-444444444444', '11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222');`);
    const good = await applyScript(pool, `INSERT INTO icf.walk_mutation (mutation_id, walk_id, actor_user_id, action, request_fingerprint, result_json)
      VALUES ('66666666-6666-6666-6666-666666666666', '55555555-5555-5555-5555-555555555555', '22222222-2222-2222-2222-222222222222', 'SAVE', '${"a".repeat(64)}', '{}');`);
    assert.equal(good.ok, true, good.error?.message);
    const bad = await applyScript(pool, `INSERT INTO icf.walk_mutation (mutation_id, walk_id, actor_user_id, action, request_fingerprint, result_json)
      VALUES ('77777777-7777-7777-7777-777777777777', '55555555-5555-5555-5555-555555555555', '22222222-2222-2222-2222-222222222222', 'SAVE', '${"Z".repeat(64)}', '{}');`);
    assert.equal(bad.ok, false, "a non-hexadecimal digest is refused");
    const legacy = await applyScript(pool, `INSERT INTO icf.walk_mutation (mutation_id, walk_id, actor_user_id, action, result_json)
      VALUES ('88888888-8888-8888-8888-888888888888', '55555555-5555-5555-5555-555555555555', '22222222-2222-2222-2222-222222222222', 'SAVE', '{}');`);
    assert.equal(legacy.ok, true, "rows written before the patch stay valid");
  } finally {
    await pool.close();
    const cleanup = await sql.connect(connectionConfig(env, "master", true));
    await cleanup.request().batch(`ALTER DATABASE [${dbName}] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [${dbName}];`);
    await cleanup.close();
  }
});
