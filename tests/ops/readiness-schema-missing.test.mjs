// Finding A8-01 (Phase 8 independent audit): the readiness probe on a reachable SQL Server database that
// holds no ICFWalk schema yet.
//
// docs/OPERATIONS.md (4.3 and 8.1) makes GET /index.cfm/api/health the load balancer's readiness probe:
// HTTP 200 and status "ok" only when the database answers, the schema is present and long text comes
// back whole; HTTP 503 and "degraded" otherwise. Before the correction a reachable database without the
// schema answered 200. This runs the real endpoint of this tree, on the engine ICFWALK_READINESS_ENGINE
// names, in the production profile, against a database no migration has touched:
//
//   1. A brand-new database, created here and shown empty (no table, no icf schema, no
//      [icf].[instrument]), and a runtime login holding db_datareader and db_datawriter on it, as
//      docs/OPERATIONS.md 4.1 provisions one. A direct connection as that login proves the database
//      answers before the application is involved. The database's identity (name, id, creation time,
//      collation, the server's version) is recorded; no credential is.
//   2. The application, started on it. Health must answer 503 "degraded" with database "ok", schema
//      "missing" and longText "ok": a 200 here fails the operation. The body must name no environment,
//      engine, database, login, datasource or secret.
//   3. Migrations 001 to 007, applied the documented way (scripts/db/apply-schema.mjs --database), to
//      this database only.
//   4. Health read again with no restart, and again after restarting the application: both 200 "ok" with
//      schema "present". The first of these is also what shows that the database the application reads
//      is this one: its schema was "missing" before step 3 and is "present" right after it, with no
//      restart between, and step 3 touched no other database. (The count of the runtime login's open
//      sessions on the database is recorded too, but not relied on: Lucee keeps a pooled connection
//      open after a request, ColdFusion's datasource here does not.)
//   5. The engine this started is removed, the database and the login are dropped and shown gone, and the
//      development application, when one was answering before, still answers 200.
//
// ICFWALK_READINESS_ENGINE picks the engine: `lucee` (default; the tree is copied to a scratch directory
// and served by its own Lucee on ICFWALK_READINESS_PORT, default 8894) or `acf` (Adobe ColdFusion 2023
// through tools/runtime/acf-up.sh in its own container on port 8500, so the development container must be
// stopped first; ICFWALK_ACF_IMAGE pins the image). Needs the SQL Server administrative login. Every
// secret is generated for the run and never written to evidence.
//
//   ICFWALK_REQUIRE_APP=1 ICFWALK_EVIDENCE_DIR=<dir> node --test tests/ops/readiness-schema-missing.test.mjs
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync, execSync, spawn } from "node:child_process";
import sql from "mssql";
import { baseUrl, connectionConfig, hasDatabaseConfig, loadRuntimeEnv, requireApp, root } from "../node/helpers.mjs";

const env = loadRuntimeEnv();
const ENGINE = (env.ICFWALK_READINESS_ENGINE || "lucee").toLowerCase();
const tag = `a801ready${Date.now().toString(36)}`;
const database = `icfwalk_${tag}`;
const runtimeLogin = `${tag}_runtime`;
const datasource = `${tag}_ds`;
const work = fs.mkdtempSync(path.join(os.tmpdir(), "icfwalk-ready-"));
const jars = path.join(root, ".runtime", "jars");

// Generated for this run only and never written to evidence; the files that carry them live in the
// scratch directory with mode 0600 and are removed at the end.
const secrets = {
  shared: crypto.randomBytes(24).toString("base64url"),
  maintenance: crypto.randomBytes(24).toString("hex"),
  runtimePassword: `Rt${crypto.randomBytes(18).toString("base64url")}9!`,
};
const evidence = { finding: "A8-01", engine: ENGINE, startedAt: new Date().toISOString(), database, runtimeLogin: "<generated, db_datareader + db_datawriter only>", steps: {} };

const missing = !hasDatabaseConfig(env) ? "no database configuration"
  : ENGINE === "lucee" && !fs.existsSync(path.join(jars, "jetty-runner.jar")) ? "no Lucee jars in .runtime/jars (run tools/runtime/lucee-up.sh once)"
  : !["lucee", "acf"].includes(ENGINE) ? `unknown engine ${ENGINE}` : false;
if (requireApp(env) && missing) throw new Error(`ICFWALK_REQUIRE_APP is set but ${missing}`);
const skip = missing;

let master;
let normalBefore = null;

// ---- the application's environment file: the production profile ------------------------------------

function appEnv() {
  const values = {
    ICFWALK_ENVIRONMENT: "production",
    ICFWALK_DATASOURCE: datasource,
    ICFWALK_LOG_LEVEL: "info",
    ICFWALK_LOG_NAME: "icfwalk",
    ICFWALK_INSTRUMENT_CODE: env.ICFWALK_INSTRUMENT_CODE,
    ICFWALK_SCHOOL_DIMENSION_CODE: env.ICFWALK_SCHOOL_DIMENSION_CODE,
    ICFWALK_MAINTENANCE_ENABLED: "false",
    ICFWALK_MAINTENANCE_TOKEN: secrets.maintenance,
    ICFWALK_MAINTENANCE_ALLOW_REMOTE: "false",
    ICFWALK_TESTS_ENABLED: "false",
    ICFWALK_SSO_MODE: "header",
    ICFWALK_SSO_SUBJECT_HEADER: "X-Gateway-Subject",
    ICFWALK_SSO_NAME_HEADER: "X-Gateway-Name",
    ICFWALK_SSO_EMAIL_HEADER: "X-Gateway-Email",
    ICFWALK_SSO_TRUSTED_PROXIES: "127.0.0.1",
    ICFWALK_SSO_SECRET_HEADER: "X-Gateway-Secret",
    ICFWALK_SSO_SHARED_SECRET: secrets.shared,
    ICFWALK_AUTO_PROVISION_USERS: "false",
    ICFWALK_DEV_IDENTITY_ENABLED: "false",
    ICFWALK_SESSION_TIMEOUT_MINUTES: "60",
    ICFWALK_COOKIE_SECURE: "true",
    ICFWALK_ALLOW_UNPUBLISHED_INSTRUMENT: "false",
  };
  // Lucee defines the datasource from ICFWALK_DB_*; on ColdFusion it is the administrator's.
  if (ENGINE === "lucee") {
    Object.assign(values, {
      ICFWALK_DB_HOST: env.ICFWALK_DB_HOST || "127.0.0.1", ICFWALK_DB_PORT: env.ICFWALK_DB_PORT || "1433", ICFWALK_DB_NAME: database,
      ICFWALK_DB_USER: runtimeLogin, ICFWALK_DB_PASSWORD: secrets.runtimePassword,
      ICFWALK_DB_ENCRYPT: env.ICFWALK_DB_ENCRYPT || "true", ICFWALK_DB_TRUST_SERVER_CERT: env.ICFWALK_DB_TRUST_SERVER_CERT || "false",
    });
  }
  return `${Object.entries(values).filter(([, v]) => v !== undefined).map(([k, v]) => `${k}=${v}`).join("\n")}\n`;
}

// ---- engines ------------------------------------------------------------------------------------------

async function probeHealth(base) {
  try {
    const r = await fetch(`${base}/index.cfm/api/health`, { signal: AbortSignal.timeout(10000) });
    const text = await r.text();
    let body = null;
    try { body = JSON.parse(text); } catch { body = null; }
    return { status: r.status, body, text, correlationHeader: r.headers.get("x-correlation-id") };
  } catch (e) { return { status: 0, error: String(e.cause?.code || e.message) }; }
}

async function waitForAnswer(base, seconds) {
  const t0 = Date.now();
  let h = { status: 0 };
  for (let i = 0; i < seconds; i++) {
    h = await probeHealth(base);
    if (h.status !== 0) return { ...h, secondsToAnswer: (Date.now() - t0) / 1000 };
    await new Promise((r) => setTimeout(r, 1000));
  }
  throw new Error(`no answer from ${base} in ${seconds} s (last: ${JSON.stringify(h).slice(0, 300)})`);
}

function luceeEngine() {
  const port = Number(env.ICFWALK_READINESS_PORT || 8894);
  const base = `http://127.0.0.1:${port}`;
  const dir = path.join(work, "tree");
  const luceeBase = path.join(work, "lucee");
  let child = null;
  let envFile = null;
  const stop = async () => {
    if (!child) return;
    child.kill("SIGTERM");
    for (let i = 0; i < 60 && child.exitCode === null && child.signalCode === null; i++) await new Promise((r) => setTimeout(r, 500));
    if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
    for (let i = 0; i < 60 && (await probeHealth(base)).status !== 0; i++) await new Promise((r) => setTimeout(r, 500));
    child = null;
  };
  const spawnLucee = (label) => {
    // Only the file configures the application: no ICFWALK_* value of this process reaches it.
    const childEnv = Object.fromEntries(Object.entries(process.env).filter(([k]) => !k.startsWith("ICFWALK_")));
    const log = fs.openSync(path.join(work, `${label}.jetty.log`), "a");
    child = spawn("java", ["-Xmx768m", `-Dlucee.base.dir=${luceeBase}`, "-jar", path.join(jars, "jetty-runner.jar"), "--port", String(port), "--path", "/", path.join(dir, "app")],
      { cwd: dir, env: { ...childEnv, ICFWALK_ENV_FILE: envFile, LUCEE_ENABLE_BUNDLE_DOWNLOAD: "false", LUCEE_ADMIN_ENABLED: "false", LUCEE_REQUESTTIMEOUT: "600" }, stdio: ["ignore", log, log] });
  };
  return {
    name: "Lucee", base,
    async start(label, envText) {
      fs.mkdirSync(dir, { recursive: true });
      execSync(`tar -C "${root}" --exclude=./node_modules --exclude=./.git --exclude=./.runtime --exclude=./app/WEB-INF --exclude=./.env -cf - . | tar -x -C "${dir}"`);
      const lib = path.join(dir, "app", "WEB-INF", "lib");
      fs.mkdirSync(lib, { recursive: true });
      for (const j of ["lucee-light.jar", "mssql-jdbc.jar"]) fs.copyFileSync(path.join(jars, j), path.join(lib, j));
      fs.copyFileSync(path.join(dir, "tools", "runtime", "web.xml"), path.join(dir, "app", "WEB-INF", "web.xml"));
      envFile = path.join(work, `${label}.env`);
      fs.writeFileSync(envFile, envText, { mode: 0o600 });
      spawnLucee(label);
      return waitForAnswer(base, 240);
    },
    async restart(label) {
      await stop();
      spawnLucee(label);
      return waitForAnswer(base, 240);
    },
    async remove() { await stop(); return (await probeHealth(base)).status === 0; },
    identity() { return { jar: "lucee-light.jar", sha256: crypto.createHash("sha256").update(fs.readFileSync(path.join(jars, "lucee-light.jar"))).digest("hex"), port }; },
    logText() {
      const found = [];
      const walk = (d) => { if (!fs.existsSync(d)) return; for (const e of fs.readdirSync(d, { withFileTypes: true })) { const p = path.join(d, e.name); if (e.isDirectory()) walk(p); else if (e.name === "icfwalk.log") found.push(p); } };
      walk(luceeBase);
      return found.map((p) => fs.readFileSync(p, "utf8")).join("\n");
    },
  };
}

function acfEngine() {
  const base = "http://127.0.0.1:8500";
  const container = env.ICFWALK_READINESS_ACF_CONTAINER || "icfwalk-acf-ready";
  const image = env.ICFWALK_ACF_IMAGE || "adobecoldfusion/coldfusion2023:latest";
  const docker = (...args) => execFileSync("docker", args, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
  const running = () => { try { return docker("ps", "--format", "{{.Names}}").split("\n").includes(container); } catch { return false; } };
  return {
    name: "Adobe ColdFusion 2023", base,
    async start(label, envText, expectHealth) {
      if (running() || (await probeHealth(base)).status !== 0) throw new Error(`something already answers on ${base}: stop the development ColdFusion container first (tools/runtime/acf-down.sh)`);
      const envFile = path.join(work, `${label}.env`);
      fs.writeFileSync(envFile, envText, { mode: 0o600 });
      // acf-up.sh builds the container, the administrator datasource for the runtime login and the front
      // door, and waits until health answers ICFWALK_ACF_EXPECT_HEALTH: 503 here, as no schema exists yet.
      const childEnv = Object.fromEntries(Object.entries(process.env).filter(([k]) => !k.startsWith("ICFWALK_")));
      execFileSync(path.join(root, "tools", "runtime", "acf-up.sh"), [], {
        stdio: "inherit",
        env: { ...childEnv, ICFWALK_ACF_CONTAINER: container, ICFWALK_ACF_APP_ENV_FILE: envFile, ICFWALK_ACF_IMAGE: image, ICFWALK_ACF_EXPECT_HEALTH: String(expectHealth),
          ICFWALK_DB_HOST: env.ICFWALK_DB_HOST || "127.0.0.1", ICFWALK_DB_PORT: env.ICFWALK_DB_PORT || "1433", ICFWALK_DB_NAME: database,
          ICFWALK_DB_USER: runtimeLogin, ICFWALK_DB_PASSWORD: secrets.runtimePassword, ICFWALK_DB_ENCRYPT: env.ICFWALK_DB_ENCRYPT || "true",
          ICFWALK_DB_TRUST_SERVER_CERT: env.ICFWALK_DB_TRUST_SERVER_CERT || "false", ICFWALK_DATASOURCE: datasource },
      });
      return waitForAnswer(base, 60);
    },
    async restart() {
      docker("exec", container, "/opt/coldfusion/cfusion/bin/coldfusion", "restart");
      return waitForAnswer(base, 240);
    },
    async remove() {
      try { docker("rm", "-f", container); } catch { /* already gone */ }
      return !running();
    },
    identity() {
      try { return { container, image, imageId: docker("inspect", "--format", "{{.Image}}", container).trim() }; } catch { return { container, image }; }
    },
    logText() { try { return docker("exec", container, "sh", "-c", "cat /opt/coldfusion/cfusion/logs/icfwalk.log 2>/dev/null || true"); } catch { return ""; } },
  };
}

const engine = ENGINE === "acf" ? acfEngine() : luceeEngine();

/** The application's log events (one canonical JSON object per line, inside the engine's CSV line). */
function logEvents(text) {
  const out = [];
  for (const line of text.split("\n")) {
    const at = line.indexOf("\"{");
    const end = line.lastIndexOf("}");
    if (at < 0 || end < at) continue;
    try { out.push(JSON.parse(line.slice(at + 1, end + 1).replace(/""/g, "\""))); } catch { /* not an application line */ }
  }
  return out;
}

/** A production health answer names no environment, engine, database, login, datasource or secret. */
function assertSafe(h, label) {
  assert.deepEqual(Object.keys(h.body).sort(), ["application", "checks", "correlationId", "status"], `${label}: production health names no environment and no engine`);
  assert.deepEqual(Object.keys(h.body.checks).sort(), ["database", "longText", "schema"], `${label}: the three checks and nothing else`);
  assert.equal(h.correlationHeader, h.body.correlationId, `${label}: X-Correlation-Id is the body's correlation id`);
  // The correlation id is random hex; it is taken out so a number below cannot match it by chance.
  const text = h.text.split(h.body.correlationId).join("");
  const values = [["the database", database], ["the runtime login", runtimeLogin], ["the datasource", datasource], ["the runtime password", secrets.runtimePassword],
    ["the shared secret", secrets.shared], ["the maintenance token", secrets.maintenance], ["the administrative password", env.ICFWALK_DB_PASSWORD],
    ["the database host", env.ICFWALK_DB_HOST || "127.0.0.1"], ["the database port", env.ICFWALK_DB_PORT || "1433"], ["the environment", "production"],
    ["an engine", "Lucee"], ["an engine", "ColdFusion"], ["a driver", "jdbc"], ["a driver", "sqlserver"], ["an exception", "xception"], ["a setting", "ICFWALK_"]];
  for (const [what, value] of values) if (value) assert.ok(!text.includes(value), `${label}: the body carries no ${what}`);
}

// ---- setup: the empty database and its runtime login ------------------------------------------------

before(async () => {
  if (skip) return;
  normalBefore = await probeHealth(baseUrl(env));
  evidence.normalEnvironmentBefore = { url: baseUrl(env), status: normalBefore.status };
  master = await new sql.ConnectionPool(connectionConfig(env, "master", true)).connect();
  await master.request().batch(`CREATE DATABASE [${database}]`);
  await master.request().input("p", sql.NVarChar, secrets.runtimePassword)
    .batch(`DECLARE @s nvarchar(max) = N'CREATE LOGIN [${runtimeLogin}] WITH PASSWORD = ' + QUOTENAME(@p, '''') + N', DEFAULT_DATABASE = [${database}]'; EXEC (@s);`);
  const admin = await new sql.ConnectionPool(connectionConfig(env, database, true)).connect();
  try {
    await admin.request().batch(`CREATE USER [${runtimeLogin}] FOR LOGIN [${runtimeLogin}]; ALTER ROLE db_datareader ADD MEMBER [${runtimeLogin}]; ALTER ROLE db_datawriter ADD MEMBER [${runtimeLogin}];`);
    const [identity] = (await admin.request().query(`
      SELECT d.name, d.database_id AS databaseId, CONVERT(varchar(33), d.create_date, 126) AS createDate, d.collation_name AS collation,
             d.compatibility_level AS compatibilityLevel, d.state_desc AS state,
             CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(40)) AS serverVersion, CAST(SERVERPROPERTY('Edition') AS nvarchar(100)) AS serverEdition,
             (SELECT COUNT(*) FROM sys.tables) AS tables, (SELECT COUNT(*) FROM sys.schemas WHERE name = N'icf') AS icfSchemas,
             CASE WHEN OBJECT_ID(N'[icf].[instrument]', N'U') IS NULL THEN 0 ELSE 1 END AS instrumentTable
      FROM sys.databases d WHERE d.database_id = DB_ID()`)).recordset;
    evidence.database = identity;
    assert.equal(identity.name, database);
    assert.equal(identity.tables, 0, "the new database has no table");
    assert.equal(identity.icfSchemas, 0, "the new database has no icf schema");
    assert.equal(identity.instrumentTable, 0, "the new database has no [icf].[instrument]");
  } finally { await admin.close(); }
  // The database answers the runtime login directly, before the application is involved.
  const direct = await new sql.ConnectionPool({ ...connectionConfig(env, database), user: runtimeLogin, password: secrets.runtimePassword }).connect();
  try {
    const [who] = (await direct.request().query(`SELECT DB_NAME() AS databaseName, IS_ROLEMEMBER('db_datareader') AS reader, IS_ROLEMEMBER('db_datawriter') AS writer, IS_ROLEMEMBER('db_owner') AS owner`)).recordset;
    evidence.directConnection = { asRuntimeLogin: true, databaseName: who.databaseName, db_datareader: who.reader === 1, db_datawriter: who.writer === 1, db_owner: who.owner === 1 };
    assert.equal(who.databaseName, database);
    assert.deepEqual([who.reader, who.writer, who.owner], [1, 1, 0], "the runtime login reads and writes, and does not own the database");
  } finally { await direct.close(); }
});

after(async () => {
  // A safety net for a run that stopped part way; the scenario itself cleans up and checks it.
  await engine.remove().catch(() => false);
  if (master) {
    await master.request().batch(`IF DB_ID(N'${database}') IS NOT NULL BEGIN ALTER DATABASE [${database}] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [${database}]; END`).catch(() => {});
    await master.request().batch(`IF SUSER_ID(N'${runtimeLogin}') IS NOT NULL DROP LOGIN [${runtimeLogin}]`).catch(() => {});
    await master.close();
  }
  for (const f of fs.readdirSync(work)) if (f.endsWith(".env")) fs.rmSync(path.join(work, f), { force: true });
  evidence.finishedAt = new Date().toISOString();
  if (env.ICFWALK_EVIDENCE_DIR) {
    fs.mkdirSync(env.ICFWALK_EVIDENCE_DIR, { recursive: true });
    const text = `${JSON.stringify(evidence, null, 2)}\n`;
    for (const s of [...Object.values(secrets), env.ICFWALK_DB_PASSWORD]) assert.ok(!s || !text.includes(s), "the evidence carries no secret");
    fs.writeFileSync(path.join(env.ICFWALK_EVIDENCE_DIR, `readiness-schema-missing-${ENGINE}.json`), text);
  }
});

// ---- the scenario ---------------------------------------------------------------------------------

test("the readiness probe on a reachable database without the ICFWalk schema: 503 until it is migrated, 200 after (A8-01)", { skip, timeout: 1800000 }, async (t) => {
  // 2. The application on the empty database, in the production profile.
  const started = await engine.start("before-migrations", appEnv(), 503);
  const beforeMigrations = await probeHealth(engine.base);
  const sessions = await master.request().input("login", sql.NVarChar, runtimeLogin).input("db", sql.NVarChar, database)
    .query("SELECT COUNT(*) AS n FROM sys.dm_exec_sessions WHERE login_name = @login AND database_id = DB_ID(@db)");
  evidence.steps.beforeMigrations = { secondsToAnswer: started.secondsToAnswer, status: beforeMigrations.status, body: beforeMigrations.body, applicationSessionsOnTheDatabase: sessions.recordset[0].n };
  assert.notEqual(beforeMigrations.status, 200, `health answered 200 before the ICFWalk schema exists: ${beforeMigrations.text}`);
  assert.equal(beforeMigrations.status, 503, `health before migrations: ${beforeMigrations.text ?? beforeMigrations.error}`);
  assert.equal(beforeMigrations.body.status, "degraded");
  assert.deepEqual(beforeMigrations.body.checks, { database: "ok", longText: "ok", schema: "missing" });
  assertSafe(beforeMigrations, "before migrations");
  const stillEmpty = await master.request().query(`SELECT COUNT(*) AS n FROM [${database}].sys.tables`);
  assert.equal(stillEmpty.recordset[0].n, 0, "nothing the application did created a table");

  // 3. Migrations 001 to 007, the documented way.
  const command = ["scripts/db/apply-schema.mjs", "--database", database];
  const output = execFileSync(process.execPath, command, { cwd: root, encoding: "utf8" });
  const scripts = [...output.matchAll(/"script": "([^"]+)",\s*"database": "([^"]+)",\s*"ok": (true|false)/g)].map((m) => ({ script: m[1], database: m[2], ok: m[3] === "true" }));
  evidence.steps.migrations = { command: `node ${command.join(" ")}`, exit: 0, scripts };
  assert.deepEqual(scripts.map((s) => s.script), ["001_schema.sql", "002_alignment_patch.sql", "003_walk_mutation.sql", "004_mutation_fingerprint.sql", "005_org_unit_dimension_map.sql", "006_version_scoped_dimensions.sql", "007_report_release.sql"]);
  assert.ok(scripts.every((s) => s.ok && s.database === database), "every script applied to the new database");

  // 4. Ready: with no restart, and after one. "missing" before step 3 and "present" now, with no restart
  // between and only this database migrated, is what shows the application reads this database.
  const noRestart = await probeHealth(engine.base);
  evidence.steps.afterMigrationsWithoutRestart = { status: noRestart.status, body: noRestart.body };
  assert.equal(noRestart.status, 200, `health after migrations, before any restart: ${noRestart.text ?? noRestart.error}`);
  assert.equal(noRestart.body.status, "ok");
  assert.equal(noRestart.body.checks.schema, "present", "the application reads the database just migrated: its schema was missing and is present, with no restart between");
  assert.deepEqual(noRestart.body.checks, { database: "ok", longText: "ok", schema: "present" });
  assertSafe(noRestart, "after migrations");
  const restarted = await engine.restart("after-migrations");
  const afterRestart = await probeHealth(engine.base);
  evidence.steps.afterRestart = { secondsToAnswer: restarted.secondsToAnswer, status: afterRestart.status, body: afterRestart.body };
  assert.equal(afterRestart.status, 200, `health after migrations and a restart: ${afterRestart.text ?? afterRestart.error}`);
  assert.equal(afterRestart.body.status, "ok");
  assert.deepEqual(afterRestart.body.checks, { database: "ok", longText: "ok", schema: "present" });
  assertSafe(afterRestart, "after the restart");

  // What ran, from the application's own log: the engine it started on, and no request failed.
  const events = logEvents(engine.logText());
  const starts = events.filter((e) => e.event === "application.started");
  evidence.engineIdentity = { ...engine.identity(), applicationStarted: starts.map((e) => ({ engine: e.fields?.engine, environment: e.fields?.environment })) };
  assert.ok(starts.length >= 1 && starts.every((e) => e.fields?.environment === "production"), "the application started in the production profile");
  assert.equal(events.filter((e) => e.event === "request.failed").length, 0, "no request failed");

  // 5. Clean up and show it: the engine, the database, the login; and the development application.
  const engineRemoved = await engine.remove();
  await master.request().batch(`ALTER DATABASE [${database}] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [${database}];`);
  await master.request().batch(`DROP LOGIN [${runtimeLogin}]`);
  const [gone] = (await master.request().query(`SELECT DB_ID(N'${database}') AS db, SUSER_ID(N'${runtimeLogin}') AS login, (SELECT COUNT(*) FROM sys.databases WHERE name LIKE N'icfwalk[_]a801ready%') AS leftovers`)).recordset;
  evidence.cleanup = { engineRemoved, databaseDropped: gone.db === null, loginDropped: gone.login === null, readinessDatabasesLeft: gone.leftovers };
  assert.ok(engineRemoved, "the engine this operation started is gone");
  assert.deepEqual([gone.db, gone.login, gone.leftovers], [null, null, 0], "the temporary database and login are gone");
  const normalAfter = await probeHealth(baseUrl(env));
  evidence.normalEnvironmentAfter = { url: baseUrl(env), status: normalAfter.status, checks: normalAfter.body?.checks ?? null };
  if (normalBefore?.status === 200) assert.equal(normalAfter.status, 200, "the development application still answers 200");

  t.diagnostic(`engine ${engine.name}: before migrations ${beforeMigrations.status} ${JSON.stringify(beforeMigrations.body.checks)}; after, no restart ${noRestart.status}; after a restart ${afterRestart.status}`);
});
