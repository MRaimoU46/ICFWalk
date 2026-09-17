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
  } finally {
    await pool.close();
    const cleanup = await sql.connect(connectionConfig(env, "master", true));
    await cleanup.request().batch(`ALTER DATABASE [${dbName}] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [${dbName}];`);
    await cleanup.close();
  }
});
