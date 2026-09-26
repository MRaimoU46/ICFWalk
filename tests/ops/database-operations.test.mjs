// Phase 8 operations: backup and restore to a separate database, and recovery from a migration that
// fails or dies half way. Runs against SQL Server directly with the administrative login
// (ICFWALK_TEST_DB_ADMIN_USER / _PASSWORD, or the local container's sa), and needs no application.
//
// It creates and drops its own databases, named with a run tag, and reads the database named by
// ICFWALK_DB_NAME (default icfwalk_dev) only to back it up. The backup is COPY_ONLY, so it never
// disturbs a backup chain someone else relies on.
//
//   ICFWALK_REQUIRE_APP=1 ICFWALK_EVIDENCE_DIR=<dir> node --test tests/ops/database-operations.test.mjs
//
// ICFWALK_KEEP_RESTORED=1 leaves the restored database in place (to point an application at it).
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import sql from "mssql";
import { applyScript, connectionConfig, hasDatabaseConfig, loadRuntimeEnv, readScript, requireApp } from "../node/helpers.mjs";

const env = loadRuntimeEnv();
const source = env.ICFWALK_DB_NAME || "icfwalk_dev";
const tag = `p8ops${Date.now().toString(36)}`;
const restored = `${source}_restore_${tag}`;
const scratch = `icfwalk_${tag}_mig`;
const evidence = { startedAt: new Date().toISOString(), source, restored, scratch };
const SCRIPTS = ["001_schema.sql", "002_alignment_patch.sql", "003_walk_mutation.sql", "004_mutation_fingerprint.sql", "005_org_unit_dimension_map.sql", "006_version_scoped_dimensions.sql", "007_report_release.sql"];

const missing = !hasDatabaseConfig(env) ? "no database configuration" : false;
if (requireApp(env) && missing) throw new Error(`ICFWALK_REQUIRE_APP is set but ${missing}`);
const skip = missing;

let master;

async function connectTo(database) {
  return new sql.ConnectionPool(connectionConfig(env, database, true)).connect();
}

async function exec(pool, text) {
  return (await pool.request().batch(text)).recordsets;
}

/** Row count and an order-independent checksum of every icf table, and the schema's object list. */
async function fingerprint(database) {
  const pool = await connectTo(database);
  try {
    const tables = (await pool.request().query("SELECT name FROM sys.tables WHERE schema_id = SCHEMA_ID(N'icf') ORDER BY name")).recordset.map((r) => r.name);
    const out = { tables: {} };
    for (const t of tables) {
      const [row] = (await pool.request().query(`SELECT COUNT_BIG(*) AS n, CHECKSUM_AGG(BINARY_CHECKSUM(*)) AS c FROM [icf].[${t}]`)).recordset;
      out.tables[t] = `${row.n}:${row.c}`;
    }
    // Catalog names carry the server's collation, so they are joined into text here rather than in SQL.
    out.objects = (await pool.request().query("SELECT o.type AS type, o.name AS name FROM sys.objects o WHERE o.schema_id = SCHEMA_ID(N'icf')")).recordset.map((r) => `${r.type.trim()}:${r.name}`).sort();
    out.triggers = (await pool.request().query("SELECT t.name AS name, t.is_disabled AS disabled FROM sys.triggers t JOIN sys.objects o ON o.object_id = t.parent_id WHERE o.schema_id = SCHEMA_ID(N'icf')")).recordset.map((r) => `${r.name}${r.disabled ? ":disabled" : ""}`).sort();
    return out;
  } finally {
    await pool.close();
  }
}

async function dropDatabase(name) {
  await exec(master, `IF DB_ID(N'${name}') IS NOT NULL BEGIN ALTER DATABASE [${name}] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [${name}]; END`);
}

before(async () => {
  if (skip) return;
  master = await connectTo("master");
  const [row] = (await master.request().query("SELECT CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(40)) AS v, CAST(SERVERPROPERTY('Edition') AS nvarchar(100)) AS e")).recordset;
  evidence.server = row;
});

after(async () => {
  if (master) {
    if (env.ICFWALK_KEEP_RESTORED !== "1") await dropDatabase(restored).catch(() => {});
    await dropDatabase(scratch).catch(() => {});
    await master.close();
  }
  evidence.finishedAt = new Date().toISOString();
  if (env.ICFWALK_EVIDENCE_DIR) {
    fs.mkdirSync(env.ICFWALK_EVIDENCE_DIR, { recursive: true });
    fs.writeFileSync(path.join(env.ICFWALK_EVIDENCE_DIR, "database-operations.json"), `${JSON.stringify(evidence, null, 2)}\n`);
  }
});

// ---- backup and restore ---------------------------------------------------------------------------

test("a COPY_ONLY backup verifies, restores to a separate database, passes CHECKDB, and holds exactly the source's data", { skip, timeout: 900000 }, async (t) => {
  const record = (evidence.backupRestore = {});
  const [dataDir] = (await master.request().query("SELECT CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS nvarchar(400)) AS p")).recordset;
  const file = `${dataDir.p}${tag}.bak`;
  record.backupFile = file;

  const before = await fingerprint(source);
  let started = Date.now();
  await exec(master, `BACKUP DATABASE [${source}] TO DISK = N'${file}' WITH COPY_ONLY, CHECKSUM, INIT, FORMAT, NAME = N'${tag}'`);
  record.backupSeconds = (Date.now() - started) / 1000;
  const afterBackup = await fingerprint(source);
  assert.deepEqual(afterBackup, before, "the source did not change during the backup (run this while nothing writes to it)");

  await exec(master, `RESTORE VERIFYONLY FROM DISK = N'${file}' WITH CHECKSUM`);
  const files = (await master.request().query(`RESTORE FILELISTONLY FROM DISK = N'${file}'`)).recordset;
  record.logicalFiles = files.map((f) => `${f.Type}:${f.LogicalName}`);
  const moves = files.map((f) => `MOVE N'${f.LogicalName}' TO N'${dataDir.p}${restored}${f.Type === "L" ? "_log.ldf" : `_${f.FileId}.mdf`}'`).join(", ");
  started = Date.now();
  await exec(master, `RESTORE DATABASE [${restored}] FROM DISK = N'${file}' WITH ${moves}, CHECKSUM, RECOVERY`);
  record.restoreSeconds = (Date.now() - started) / 1000;

  const check = (await master.request().query(`DBCC CHECKDB (N'${restored}') WITH NO_INFOMSGS, ALL_ERRORMSGS, TABLERESULTS`)).recordset || [];
  record.checkdbMessages = check.length;
  assert.equal(check.length, 0, `CHECKDB reported ${check.length} problems: ${JSON.stringify(check.slice(0, 3))}`);

  const copy = await fingerprint(restored);
  record.tables = Object.keys(copy.tables).length;
  record.rows = Object.values(copy.tables).reduce((n, v) => n + Number(v.split(":")[0]), 0);
  assert.deepEqual(copy, before, "every icf table, object and trigger is identical in the restored database");

  // Every published or retired instrument snapshot still hashes to the checksum stored beside it --
  // what the application verifies before it renders one.
  const pool = await connectTo(restored);
  try {
    const versions = (await pool.request().query("SELECT version_id, status, checksum_sha256, compiled_snapshot_json FROM icf.instrument_version WHERE compiled_snapshot_json IS NOT NULL")).recordset;
    record.snapshotsVerified = versions.length;
    for (const v of versions) {
      const hash = crypto.createHash("sha256").update(v.compiled_snapshot_json, "utf8").digest("hex");
      assert.equal(hash, v.checksum_sha256.trim().toLowerCase(), `version ${v.version_id} (${v.status}) snapshot checksum`);
    }
    const [state] = (await pool.request().query("SELECT DB_NAME() AS db, (SELECT COUNT(*) FROM sys.triggers WHERE is_disabled = 1) AS disabledTriggers")).recordset;
    assert.equal(state.disabledTriggers, 0, "no trigger is left disabled");
  } finally {
    await pool.close();
  }
  t.diagnostic(`restored ${record.tables} tables, ${record.rows} rows, ${record.snapshotsVerified} snapshots verified; backup ${record.backupSeconds}s, restore ${record.restoreSeconds}s`);
});

// ---- migrations that fail -------------------------------------------------------------------------

async function applyTo(database, names) {
  const pool = await connectTo(database);
  const results = [];
  try {
    for (const name of names) {
      const r = await applyScript(pool, readScript(name));
      results.push({ script: name, ok: r.ok, errorNumber: r.error?.number ?? null, error: r.error?.message ?? null });
      if (!r.ok) break;
    }
  } finally {
    await pool.close();
  }
  return results;
}

test("a migration killed half way rolls back completely, and the same script then applies and re-applies cleanly", { skip, timeout: 900000 }, async (t) => {
  const record = (evidence.killedMigration = {});
  await dropDatabase(scratch);
  await exec(master, `CREATE DATABASE [${scratch}]`);
  const upTo006 = await applyTo(scratch, SCRIPTS.slice(0, 6));
  assert.ok(upTo006.every((r) => r.ok), JSON.stringify(upTo006));
  const at006 = await fingerprint(scratch);

  // 007 creates report_release and report_release_block, then report_release_walk with a foreign key
  // to icf.walk. A session holding an exclusive lock on icf.walk stops it exactly there, with its
  // first tables created and uncommitted.
  const holder = await connectTo(scratch);
  const tx = new sql.Transaction(holder);
  await tx.begin();
  await new sql.Request(tx).query("SELECT COUNT_BIG(*) FROM icf.walk WITH (TABLOCKX, HOLDLOCK)");
  const [{ spid: holderSpid }] = (await new sql.Request(tx).query("SELECT @@SPID AS spid")).recordset;

  const migrator = await connectTo(scratch);
  const [{ spid: migratorSpid }] = (await migrator.request().query("SELECT @@SPID AS spid")).recordset;
  const running = applyScript(migrator, readScript("007_report_release.sql"));
  let blocked = null;
  for (let i = 0; i < 100 && !blocked; i++) {
    const rows = (await master.request().input("s", migratorSpid).query("SELECT wait_type, blocking_session_id, command FROM sys.dm_exec_requests WHERE session_id = @s AND blocking_session_id <> 0")).recordset;
    if (rows.length) blocked = rows[0];
    else await new Promise((r) => setTimeout(r, 200));
  }
  assert.ok(blocked, "007 reached the lock on icf.walk");
  record.blockedAt = blocked;
  assert.equal(blocked.blocking_session_id, holderSpid);
  const dirty = (await master.request().input("s", migratorSpid).query(`SELECT COUNT(*) AS n FROM sys.dm_tran_locks WHERE request_session_id = @s AND resource_database_id = DB_ID(N'${scratch}') AND request_mode IN (N'Sch-M', N'X') AND request_status = N'GRANT'`)).recordset[0].n;
  record.exclusiveLocksHeldByTheMigration = dirty;
  assert.ok(dirty > 0, "the migration had written schema changes, uncommitted");

  // The migration's connection dies (the process running it is gone).
  await exec(master, `KILL ${migratorSpid}`);
  const outcome = await running;
  record.migrationOutcome = { ok: outcome.ok, error: outcome.error?.message ?? null };
  assert.equal(outcome.ok, false);
  await migrator.close().catch(() => {});
  await tx.rollback();
  await holder.close();

  const afterKill = await fingerprint(scratch);
  assert.deepEqual(afterKill, at006, "nothing of 007 is left: the database is exactly as it was at 006");

  const reapplied = await applyTo(scratch, ["007_report_release.sql", "007_report_release.sql"]);
  record.reapplied = reapplied;
  assert.ok(reapplied.every((r) => r.ok), JSON.stringify(reapplied));
  const at007 = await fingerprint(scratch);
  assert.ok(at007.objects.includes("U:report_release"), "report_release exists");
  assert.equal(at007.triggers.filter((n) => n.endsWith(":disabled")).length, 0, "no trigger disabled");
  t.diagnostic(`007 blocked on ${blocked.wait_type}, killed, rolled back to the 006 state, then applied twice`);
});

test("a migration refused by its own precondition changes nothing", { skip, timeout: 300000 }, async () => {
  const record = (evidence.refusedMigration = {});
  const empty = `${scratch}_empty`;
  await dropDatabase(empty);
  await exec(master, `CREATE DATABASE [${empty}]`);
  try {
    const before = await fingerprint(empty);
    const results = await applyTo(empty, ["007_report_release.sql"]);
    record.results = results;
    assert.equal(results[0].ok, false);
    assert.equal(results[0].errorNumber, 50061, results[0].error);
    assert.deepEqual(await fingerprint(empty), before, "the refused patch created nothing");
  } finally {
    await dropDatabase(empty);
  }
});
