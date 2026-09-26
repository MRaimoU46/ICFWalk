// Phase 8: the production profile, end to end, on a least-privilege database login (SEC-03, SEC-04,
// SEC-05, SEC-07).
//
// Every other suite runs the development profile: the identity stub, maintenance and the test runner
// on, exception details in error bodies, cookies without Secure over plain HTTP, and the SQL Server
// administrative login. This test runs this tree as docs/OPERATIONS.md (sections 3 and 4) configures
// production, on a new database it creates and migrates, under a runtime login that holds
// db_datareader and db_datawriter and nothing else, and checks what that profile promises:
//
//   1. Bootstrap in the order docs/OPERATIONS.md 4.6 gives (maintenance on, loopback only, token
//      required): the instrument, the org units without their School mapping, the people, the first
//      publication by the administrator through the gateway, and only then the mapping, which
//      production refuses before a version is in service (P8-12). The CFML test runner stays off
//      although the file asks for it.
//   2. It refuses to start misconfigured: header SSO without a trusted proxy list; no
//      ICFWALK_ENVIRONMENT at all (production by default) with the development stub on; Secure
//      cookies switched off. The body is the generic STARTUP_FAILED and names no setting or value;
//      the log names the setting.
//   3. Steady state (maintenance off): only the trusted gateway, with its shared secret, asserts an
//      identity; the development stub's header is ignored; an address outside the list is anonymous
//      even with the right secret; an unprovisioned subject is refused. Session cookies are Secure,
//      HttpOnly, SameSite=Lax and end with the browser, and rotate at sign-in. CSRF is enforced.
//      Health names no environment or engine. Maintenance answers 404 to the right token.
//   4. Real work on the least-privilege login: a walk saved with a narrative note, a stale save
//      refused, completion, the summary export, a live report.
//   5. The database goes away and comes back: health 503, a generic 500 with no SQL text, then
//      service again without a restart.
//   6. The application log and the audit trail hold no secret, token, password or narrative, and the
//      log does record the refused identity assertions and the failures.
//
// ICFWALK_PROD_PROFILE_ENGINE picks the engine: `lucee` (default; the current tree is copied to a
// scratch directory and served by its own Lucee on ICFWALK_PROD_PROFILE_PORT, default 8893) or `acf`
// (Adobe ColdFusion 2023 through tools/runtime/acf-up.sh in its own container on port 8500, so the
// development container must be stopped first; ICFWALK_ACF_IMAGE pins the image). Needs the SQL
// Server administrative login. Every secret is generated for the run and never written to evidence.
//
//   ICFWALK_REQUIRE_APP=1 ICFWALK_EVIDENCE_DIR=<dir> node --test tests/ops/production-profile.test.mjs
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { execFileSync, execSync, spawn } from "node:child_process";
import sql from "mssql";
import { applyScript, connectionConfig, hasDatabaseConfig, loadRuntimeEnv, readScript, requireApp, root } from "../node/helpers.mjs";

const env = loadRuntimeEnv();
const ENGINE = (env.ICFWALK_PROD_PROFILE_ENGINE || "lucee").toLowerCase();
const tag = `p8prod${Date.now().toString(36)}`;
const database = `icfwalk_${tag}`;
const runtimeLogin = `${tag}_runtime`;
const work = fs.mkdtempSync(path.join(os.tmpdir(), "icfwalk-prod-"));
const jars = path.join(root, ".runtime", "jars");

// Generated for this run only. None of them is written to evidence; the files that carry them live in
// the scratch directory with mode 0600 and are removed at the end.
const secrets = {
  shared: crypto.randomBytes(24).toString("base64url"),
  maintenance: crypto.randomBytes(24).toString("hex"),
  runtimePassword: `Rt${crypto.randomBytes(18).toString("base64url")}9!`,
};
// Synthetic sentinels: if any of them appears in a log line or an audit row, something leaked.
const sentinels = {
  note: `P8PROD-NOTE-${crypto.randomUUID()}`,
  name: `P8Prod Walker ${crypto.randomBytes(4).toString("hex")}`,
  email: `p8prod.${crypto.randomBytes(4).toString("hex")}@example.invalid`,
};
const HEADERS = { subject: "X-Gateway-Subject", name: "X-Gateway-Name", email: "X-Gateway-Email", secret: "X-Gateway-Secret" };
const subjects = { walker: `${tag}-walker`, district: `${tag}-district`, admin: `${tag}-admin` };
const evidence = { engine: ENGINE, startedAt: new Date().toISOString(), database, runtimeLogin: "<generated, db_datareader + db_datawriter only>", phases: {} };

const missing = !hasDatabaseConfig(env) ? "no database configuration"
  : ENGINE === "lucee" && !fs.existsSync(path.join(jars, "jetty-runner.jar")) ? "no Lucee jars in .runtime/jars (run tools/runtime/lucee-up.sh once)"
  : !["lucee", "acf"].includes(ENGINE) ? `unknown engine ${ENGINE}` : false;
if (requireApp(env) && missing) throw new Error(`ICFWALK_REQUIRE_APP is set but ${missing}`);
const skip = missing;

let master;

// ---- the application's environment file ------------------------------------------------------------

function appEnv(overrides = {}) {
  const values = {
    ICFWALK_ENVIRONMENT: "production",
    ICFWALK_DATASOURCE: ENGINE === "acf" ? (env.ICFWALK_DATASOURCE || "icfwalk") : "icfwalk",
    ICFWALK_LOG_LEVEL: "info",
    ICFWALK_LOG_NAME: "icfwalk",
    ICFWALK_INSTRUMENT_CODE: env.ICFWALK_INSTRUMENT_CODE,
    ICFWALK_SCHOOL_DIMENSION_CODE: env.ICFWALK_SCHOOL_DIMENSION_CODE,
    ICFWALK_MAINTENANCE_ENABLED: "false",
    ICFWALK_MAINTENANCE_TOKEN: secrets.maintenance,
    ICFWALK_MAINTENANCE_ALLOW_REMOTE: "false",
    ICFWALK_TESTS_ENABLED: "false",
    ICFWALK_SSO_MODE: "header",
    ICFWALK_SSO_SUBJECT_HEADER: HEADERS.subject,
    ICFWALK_SSO_NAME_HEADER: HEADERS.name,
    ICFWALK_SSO_EMAIL_HEADER: HEADERS.email,
    ICFWALK_SSO_TRUSTED_PROXIES: "127.0.0.1",
    ICFWALK_SSO_SECRET_HEADER: HEADERS.secret,
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
  for (const [k, v] of Object.entries(overrides)) { if (v === null) delete values[k]; else values[k] = v; }
  return `${Object.entries(values).filter(([, v]) => v !== undefined).map(([k, v]) => `${k}=${v}`).join("\n")}\n`;
}

// ---- engines ---------------------------------------------------------------------------------------------

async function probeHealth(base) {
  try {
    const r = await fetch(`${base}/index.cfm/api/health`, { signal: AbortSignal.timeout(10000) });
    const text = await r.text();
    let body = null;
    try { body = JSON.parse(text); } catch { body = null; }
    return { status: r.status, body, text };
  } catch (e) { return { status: 0, error: String(e.cause?.code || e.message) }; }
}

async function waitForAnswer(base, seconds, accept = (h) => h.status !== 0) {
  const t0 = Date.now();
  let h = { status: 0 };
  for (let i = 0; i < seconds; i++) {
    h = await probeHealth(base);
    if (accept(h)) return { ...h, secondsToAnswer: (Date.now() - t0) / 1000 };
    await new Promise((r) => setTimeout(r, 1000));
  }
  throw new Error(`no answer from ${base} in ${seconds} s (last: ${JSON.stringify(h).slice(0, 300)})`);
}

function luceeEngine() {
  const port = Number(env.ICFWALK_PROD_PROFILE_PORT || 8893);
  const base = `http://127.0.0.1:${port}`;
  const dir = path.join(work, "tree");
  const luceeBase = path.join(work, "lucee");
  let child = null;
  let prepared = false;
  const prepare = () => {
    fs.mkdirSync(dir, { recursive: true });
    execSync(`tar -C "${root}" --exclude=./node_modules --exclude=./.git --exclude=./.runtime --exclude=./app/WEB-INF --exclude=./.env -cf - . | tar -x -C "${dir}"`);
    const lib = path.join(dir, "app", "WEB-INF", "lib");
    fs.mkdirSync(lib, { recursive: true });
    for (const j of ["lucee-light.jar", "mssql-jdbc.jar"]) fs.copyFileSync(path.join(jars, j), path.join(lib, j));
    fs.copyFileSync(path.join(dir, "tools", "runtime", "web.xml"), path.join(dir, "app", "WEB-INF", "web.xml"));
    prepared = true;
  };
  const stop = async () => {
    if (!child) return;
    child.kill("SIGTERM");
    for (let i = 0; i < 60 && child.exitCode === null && child.signalCode === null; i++) await new Promise((r) => setTimeout(r, 500));
    if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
    for (let i = 0; i < 60 && (await probeHealth(base)).status !== 0; i++) await new Promise((r) => setTimeout(r, 500));
    child = null;
  };
  return {
    name: "Lucee", base,
    async start(label, envText) {
      if (!prepared) prepare();
      await stop();
      const envFile = path.join(work, `${label}.env`);
      fs.writeFileSync(envFile, envText, { mode: 0o600 });
      // Only the file configures the application: no ICFWALK_* value of this process reaches it.
      const childEnv = Object.fromEntries(Object.entries(process.env).filter(([k]) => !k.startsWith("ICFWALK_")));
      const log = fs.openSync(path.join(work, `${label}.jetty.log`), "a");
      child = spawn("java", ["-Xmx768m", `-Dlucee.base.dir=${luceeBase}`, "-jar", path.join(jars, "jetty-runner.jar"), "--port", String(port), "--path", "/", path.join(dir, "app")],
        { cwd: dir, env: { ...childEnv, ICFWALK_ENV_FILE: envFile, LUCEE_ENABLE_BUNDLE_DOWNLOAD: "false", LUCEE_ADMIN_ENABLED: "false", LUCEE_REQUESTTIMEOUT: "600" }, stdio: ["ignore", log, log] });
      return waitForAnswer(base, 240);
    },
    stop,
    async remove() { await stop(); },
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
  const container = env.ICFWALK_PROD_PROFILE_ACF_CONTAINER || "icfwalk-acf-prod";
  const docker = (...args) => execFileSync("docker", args, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
  const running = () => { try { return docker("ps", "--format", "{{.Names}}").split("\n").includes(container); } catch { return false; } };
  return {
    name: "Adobe ColdFusion 2023", base,
    async start(label, envText) {
      const envFile = path.join(work, `${label}.env`);
      fs.writeFileSync(envFile, envText, { mode: 0o600 });
      if (!running()) {
        if ((await probeHealth(base)).status !== 0) throw new Error(`something already answers on ${base}: stop the development ColdFusion container first (tools/runtime/acf-down.sh)`);
        // acf-up.sh builds the container, the administrator datasource for the runtime login and the
        // front door, and waits for health 200 -- so the first start must be a valid configuration.
        const childEnv = Object.fromEntries(Object.entries(process.env).filter(([k]) => !k.startsWith("ICFWALK_")));
        execFileSync(path.join(root, "tools", "runtime", "acf-up.sh"), [], {
          stdio: "inherit",
          env: { ...childEnv, ICFWALK_ACF_CONTAINER: container, ICFWALK_ACF_APP_ENV_FILE: envFile, ICFWALK_ACF_IMAGE: env.ICFWALK_ACF_IMAGE || "adobecoldfusion/coldfusion2023:latest",
            ICFWALK_DB_HOST: env.ICFWALK_DB_HOST || "127.0.0.1", ICFWALK_DB_PORT: env.ICFWALK_DB_PORT || "1433", ICFWALK_DB_NAME: database,
            ICFWALK_DB_USER: runtimeLogin, ICFWALK_DB_PASSWORD: secrets.runtimePassword, ICFWALK_DB_ENCRYPT: env.ICFWALK_DB_ENCRYPT || "true",
            ICFWALK_DB_TRUST_SERVER_CERT: env.ICFWALK_DB_TRUST_SERVER_CERT || "false", ICFWALK_DATASOURCE: env.ICFWALK_DATASOURCE || "icfwalk" },
        });
        return waitForAnswer(base, 60);
      }
      // A new environment file takes effect when ColdFusion restarts: the application reads it once.
      docker("cp", envFile, `${container}:/opt/icfwalk-env/app.env`);
      docker("exec", container, "sh", "-c", "chown cfuser:cfuser /opt/icfwalk-env/app.env && chmod 600 /opt/icfwalk-env/app.env");
      docker("exec", container, "/opt/coldfusion/cfusion/bin/coldfusion", "restart");
      return waitForAnswer(base, 240);
    },
    async stop() {},
    async remove() { try { docker("rm", "-f", container); } catch { /* already gone */ } },
    logText() { try { return docker("exec", container, "sh", "-c", "cat /opt/coldfusion/cfusion/logs/icfwalk.log 2>/dev/null || true"); } catch { return ""; } },
  };
}

const engine = ENGINE === "acf" ? acfEngine() : luceeEngine();

// ---- HTTP, with control of every header and of the source address ---------------------------------------

function request(method, p, { headers = {}, body, localAddress } = {}) {
  const u = new URL(`${engine.base}/index.cfm${p}`);
  const payload = body === undefined ? undefined : (typeof body === "string" ? body : JSON.stringify(body));
  const h = { Accept: "application/json", ...headers };
  if (payload !== undefined) { h["Content-Type"] ||= "application/json"; h["Content-Length"] = Buffer.byteLength(payload); }
  return new Promise((resolve, reject) => {
    const req = http.request({ host: u.hostname, port: u.port, path: u.pathname + u.search, method, headers: h, localAddress }, (res) => {
      const chunks = [];
      res.on("data", (c) => chunks.push(c));
      res.on("end", () => {
        const text = Buffer.concat(chunks).toString("utf8");
        let json = null;
        try { json = JSON.parse(text); } catch { json = null; }
        const setCookies = [].concat(res.headers["set-cookie"] || []);
        resolve({ status: res.statusCode, headers: res.headers, setCookies, text, json });
      });
    });
    req.setTimeout(120000, () => req.destroy(new Error(`timeout ${method} ${p}`)));
    req.on("error", reject);
    if (payload !== undefined) req.write(payload);
    req.end();
  });
}

function gatewayHeaders(subject, { secret = secrets.shared, name = sentinels.name, email = sentinels.email } = {}) {
  const h = { [HEADERS.subject]: subject };
  if (secret !== null) h[HEADERS.secret] = secret;
  if (name) h[HEADERS.name] = name;
  if (email) h[HEADERS.email] = email;
  return h;
}

/** A person behind the gateway: its cookie jar, its CSRF token, and every Set-Cookie it received. */
function person(subject, options = {}) {
  const cookies = new Map();
  let csrf = "";
  const received = [];
  const call = async (method, p, body, extra = {}) => {
    const headers = { ...gatewayHeaders(subject, options), ...extra.headers };
    if (csrf && method !== "GET" && !extra.noCsrf) headers["X-ICFWalk-CSRF-Token"] = csrf;
    const cookie = [...cookies.entries()].map(([k, v]) => `${k}=${v}`).join("; ");
    if (cookie) headers.Cookie = cookie;
    const r = await request(method, p, { headers, body, localAddress: options.localAddress });
    for (const line of r.setCookies) {
      received.push(line);
      const [pair] = line.split(";");
      const eq = pair.indexOf("=");
      cookies.set(pair.slice(0, eq).trim(), pair.slice(eq + 1).trim());
    }
    if (r.json && r.json.csrfToken) csrf = r.json.csrfToken;
    return r;
  };
  return { call, received, cookies, csrf: () => csrf };
}

async function maintenance(p, body, token = secrets.maintenance) {
  return request("POST", p, { headers: { "X-ICFWalk-Maintenance-Token": token }, body: body ?? {} });
}

/** A cookie line, reduced to what the evidence may show: the name and its attributes, never its value. */
function cookieShape(line) {
  const [pair, ...attrs] = line.split(";").map((s) => s.trim());
  return { name: pair.slice(0, pair.indexOf("=")), attributes: attrs };
}

const REQUIRED = { p1q1: { storedCode: "Partial" }, p1q2: { storedCode: "Retrieval" }, p1q3: { storedCode: "Analysis" }, part1_adopted_pacing: { storedCode: "on" },
  part1_adopted_ac1: { storedCode: "3" }, part1_adopted_ac2: { storedCode: "4" }, part1_targettask_tt1: { storedCode: "5" }, part1_targettask_tt2: { storedCode: "2" } };

// ---- setup ------------------------------------------------------------------------------------------------

before(async () => {
  if (skip) return;
  master = await new sql.ConnectionPool(connectionConfig(env, "master", true)).connect();
  await master.request().batch(`CREATE DATABASE [${database}]`);
  const admin = await new sql.ConnectionPool(connectionConfig(env, database, true)).connect();
  try {
    for (const name of ["001_schema.sql", "002_alignment_patch.sql", "003_walk_mutation.sql", "004_mutation_fingerprint.sql", "005_org_unit_dimension_map.sql", "006_version_scoped_dimensions.sql", "007_report_release.sql"]) {
      const r = await applyScript(admin, readScript(name));
      assert.ok(r.ok, `${name}: ${r.error?.message}`);
    }
    // docs/OPERATIONS.md 4.1: the runtime login holds db_datareader and db_datawriter, nothing else.
    await master.request().input("p", sql.NVarChar, secrets.runtimePassword)
      .batch(`DECLARE @s nvarchar(max) = N'CREATE LOGIN [${runtimeLogin}] WITH PASSWORD = ' + QUOTENAME(@p, '''') + N', DEFAULT_DATABASE = [${database}]'; EXEC (@s);`);
    await admin.request().batch(`CREATE USER [${runtimeLogin}] FOR LOGIN [${runtimeLogin}]; ALTER ROLE db_datareader ADD MEMBER [${runtimeLogin}]; ALTER ROLE db_datawriter ADD MEMBER [${runtimeLogin}];`);
    const roles = await admin.request().query(`SELECT r.name FROM sys.database_role_members m JOIN sys.database_principals r ON r.principal_id = m.role_principal_id JOIN sys.database_principals u ON u.principal_id = m.member_principal_id WHERE u.name = N'${runtimeLogin}' ORDER BY r.name`);
    const perms = await admin.request().query(`SELECT COUNT(*) AS n FROM sys.database_permissions p JOIN sys.database_principals u ON u.principal_id = p.grantee_principal_id WHERE u.name = N'${runtimeLogin}' AND p.permission_name <> N'CONNECT'`);
    evidence.runtimeRoles = roles.recordset.map((r) => r.name);
    evidence.runtimeExtraPermissions = perms.recordset[0].n;
    assert.deepEqual(evidence.runtimeRoles, ["db_datareader", "db_datawriter"]);
    assert.equal(evidence.runtimeExtraPermissions, 0, "no permission beyond the two roles and CONNECT");
  } finally { await admin.close(); }
});

after(async () => {
  await engine.remove().catch(() => {});
  if (master) {
    await master.request().batch(`IF DB_ID(N'${database}') IS NOT NULL BEGIN ALTER DATABASE [${database}] SET ONLINE; END`).catch(() => {});
    if (env.ICFWALK_KEEP_PROD_PROFILE_DB !== "1") {
      await master.request().batch(`IF DB_ID(N'${database}') IS NOT NULL BEGIN ALTER DATABASE [${database}] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [${database}]; END`).catch(() => {});
      await master.request().batch(`IF SUSER_ID(N'${runtimeLogin}') IS NOT NULL DROP LOGIN [${runtimeLogin}]`).catch(() => {});
    }
    await master.close();
  }
  for (const f of fs.readdirSync(work)) if (f.endsWith(".env")) fs.rmSync(path.join(work, f), { force: true });
  evidence.finishedAt = new Date().toISOString();
  if (env.ICFWALK_EVIDENCE_DIR) {
    fs.mkdirSync(env.ICFWALK_EVIDENCE_DIR, { recursive: true });
    const text = `${JSON.stringify(evidence, null, 2)}\n`;
    for (const s of Object.values(secrets)) assert.ok(!text.includes(s), "the evidence carries no secret");
    fs.writeFileSync(path.join(env.ICFWALK_EVIDENCE_DIR, `production-profile-${ENGINE}.json`), text);
  }
});

// ---- the scenario -------------------------------------------------------------------------------------------

test("the production profile: fail-closed start, gateway-only identity, session and CSRF rules, safe errors, a database outage, and clean logs, on a least-privilege login", { skip, timeout: 3600000 }, async (t) => {
  // 1. Bootstrap: maintenance on for the seed, loopback only. The file also asks for the test runner.
  const boot = await engine.start("bootstrap", appEnv({ ICFWALK_MAINTENANCE_ENABLED: "true", ICFWALK_TESTS_ENABLED: "true" }));
  assert.equal(boot.status, 200, `bootstrap health: ${boot.text?.slice(0, 300)}`);
  const bootstrap = { secondsToAnswer: boot.secondsToAnswer, health: boot.body };
  assert.deepEqual(Object.keys(boot.body).sort(), ["application", "checks", "correlationId", "status"], "production health names no environment and no engine");
  assert.deepEqual(boot.body.checks, { database: "ok", longText: "ok", schema: "present" });

  const runner = await maintenance("/api/maintenance/tests/run");
  assert.equal(runner.status, 404, "the CFML test runner is never enabled in production, even when the file asks");
  bootstrap.testRunner = runner.status;
  const wrongToken = await maintenance("/api/maintenance/instrument/import", {}, crypto.randomBytes(24).toString("hex"));
  assert.equal(wrongToken.status, 404, "a wrong maintenance token is answered as if nothing were there");
  bootstrap.wrongToken = wrongToken.status;

  const seeded = await maintenance("/api/maintenance/instrument/import", {});
  assert.ok(seeded.status === 200 || seeded.status === 201, `seed: ${seeded.text.slice(0, 300)}`);
  const versionId = seeded.json.versionId;
  const district = { code: `${tag}-district`, type: "DISTRICT", name: "Production profile district", parentCode: null };
  const school = { code: `${tag}-school`, type: "SCHOOL", name: "Production profile school", parentCode: `${tag}-district` };
  const units = await maintenance("/api/maintenance/org-units/import", { orgUnits: [district, school] });
  assert.equal(units.status, 200, units.text.slice(0, 300));
  for (const [who, role, unit, desc] of [["walker", "SCHOOL_WALK_REPORT", `${tag}-school`, false], ["district", "DISTRICT_WALK_REPORT", `${tag}-district`, true], ["admin", "MASTER_INSTRUMENT_ADMIN", `${tag}-district`, false]]) {
    const u = await maintenance("/api/maintenance/identity/provision-user", { subject: subjects[who], displayName: `Production profile ${who}` });
    assert.ok(u.status === 200 || u.status === 201, u.text.slice(0, 300));
    const r = await maintenance("/api/maintenance/identity/assign-role", { subject: subjects[who], roleCode: role, orgUnitCode: unit, includeDescendants: desc });
    assert.ok(r.status === 200 || r.status === 201, r.text.slice(0, 300));
  }
  // Production serves no DRAFT, so a School mapping has nothing to be validated against yet.
  const early = await maintenance("/api/maintenance/org-units/import", { orgUnits: [district, { ...school, schoolValueCode: "abbott_middle_school" }] });
  assert.equal(early.status, 400, `a mapping before the first publication is refused: ${early.text.slice(0, 200)}`);
  assert.equal(early.json.error.code, "INSTRUMENT_NOT_AVAILABLE");
  const admin = person(subjects.admin, { name: "Production profile admin", email: "" });
  assert.equal((await admin.call("GET", "/api/me")).status, 200);
  const pub = await admin.call("POST", `/api/admin/instrument/versions/${versionId}/publish`);
  assert.equal(pub.status, 200, `publish: ${pub.text.slice(0, 300)}`);
  const mapped = await maintenance("/api/maintenance/org-units/import", { orgUnits: [district, { ...school, schoolValueCode: "abbott_middle_school" }] });
  assert.equal(mapped.status, 200, mapped.text.slice(0, 300));
  assert.equal(mapped.json.schoolValuesMapped, 1);
  bootstrap.seeded = { instrument: seeded.status, orgUnits: units.status, people: 3, mappingBeforePublication: `${early.status} ${early.json.error.code}`, publish: pub.status, mapping: mapped.status };
  evidence.phases.bootstrap = bootstrap;

  // 2. Misconfiguration refuses to start, with nothing in the body but the generic message.
  const refusals = {};
  for (const [label, overrides, setting] of [
    ["no-trusted-proxies", { ICFWALK_SSO_TRUSTED_PROXIES: "" }, "ICFWALK_SSO_TRUSTED_PROXIES"],
    ["environment-unset-with-dev-stub", { ICFWALK_ENVIRONMENT: null, ICFWALK_SSO_MODE: "development", ICFWALK_DEV_IDENTITY_ENABLED: "true" }, "ICFWALK_DEV_IDENTITY_ENABLED"],
    ["insecure-cookies", { ICFWALK_COOKIE_SECURE: "false" }, "ICFWALK_COOKIE_SECURE"],
  ]) {
    const logBefore = engine.logText().length;
    const h = await engine.start(`refuse-${label}`, appEnv(overrides));
    assert.equal(h.status, 500, `${label}: the application refuses to start (${h.text?.slice(0, 200)})`);
    assert.equal(h.body?.error?.code, "STARTUP_FAILED", label);
    for (const leak of [setting, "ICFWALK_", secrets.shared, secrets.maintenance, secrets.runtimePassword, database, runtimeLogin]) assert.ok(!h.text.includes(leak), `${label}: the body does not carry ${leak === setting || leak === "ICFWALK_" ? leak : "a configuration value"}`);
    const api = await request("GET", "/api/me", { headers: gatewayHeaders(subjects.walker) });
    assert.equal(api.status, 500, `${label}: no request is served`);
    const logged = engine.logText().slice(logBefore);
    assert.ok(logged.includes(setting), `${label}: the log names ${setting} for the operator`);
    refusals[label] = { health: h.status, code: h.body.error.code, apiStatus: api.status, logNamesSetting: true };
  }
  evidence.phases.refusals = refusals;

  // 3. Steady state: maintenance off.
  const steady = await engine.start("steady", appEnv());
  assert.equal(steady.status, 200, steady.text?.slice(0, 300));
  const s = { secondsToAnswer: steady.secondsToAnswer, health: steady.body };
  assert.deepEqual(Object.keys(steady.body).sort(), ["application", "checks", "correlationId", "status"]);
  for (const p of ["/api/maintenance/instrument/import", "/api/maintenance/tests/run", "/api/maintenance/identity/provision-user"]) {
    const r = await maintenance(p, {});
    assert.equal(r.status, 404, `${p}: maintenance off answers 404 to the right token`);
  }
  s.maintenanceWithRightToken = 404;

  const identity = {};
  const expect401 = async (label, headers, localAddress) => {
    const r = await request("GET", "/api/me", { headers, localAddress });
    assert.equal(r.status, 401, `${label}: ${r.status} ${r.text.slice(0, 200)}`);
    assert.ok(!r.text.includes(secrets.shared));
    identity[label] = { status: r.status, code: r.json?.error?.code };
    return r;
  };
  await expect401("the development stub's header", { "X-ICFWalk-Dev-Subject": subjects.walker });
  await expect401("the gateway subject without the secret", gatewayHeaders(subjects.walker, { secret: null }));
  await expect401("a wrong secret", gatewayHeaders(subjects.walker, { secret: crypto.randomBytes(24).toString("base64url") }));
  await expect401("a wrong secret of the same length", gatewayHeaders(subjects.walker, { secret: `${secrets.shared.slice(0, -1)}${secrets.shared.endsWith("A") ? "B" : "A"}` }));
  await expect401("the right secret from an address outside the list", gatewayHeaders(subjects.walker), "127.0.0.2");
  const unknown = await expect401("an unprovisioned subject", gatewayHeaders(`${tag}-nobody`));
  assert.equal(unknown.json?.error?.code, "USER_NOT_PROVISIONED");
  s.identity = identity;

  // Sign-in through the gateway, and the session cookies it sets.
  const walker = person(subjects.walker);
  const me = await walker.call("GET", "/api/me");
  assert.equal(me.status, 200, me.text.slice(0, 300));
  // The sign-in stores the gateway's name claim; the response to that same request was built from the
  // row read before the update, so the claim shows from the next request (recorded, LOW).
  const again = await walker.call("GET", "/api/me");
  assert.equal(again.json.user.displayName, sentinels.name, "the gateway's name claim is recorded at sign-in");
  s.displayNameOnTheSignInResponse = me.json.user.displayName === sentinels.name ? "the claim" : "the provisioned name; the claim from the next request";
  const sessionCookies = walker.received.map(cookieShape);
  assert.ok(sessionCookies.length > 0, "the sign-in sets session cookies");
  const cookieFindings = [];
  for (const c of sessionCookies) {
    const attrs = c.attributes.map((a) => a.toLowerCase());
    if (!attrs.includes("secure")) cookieFindings.push(`${c.name} lacks Secure`);
    if (!attrs.includes("httponly")) cookieFindings.push(`${c.name} lacks HttpOnly`);
    if (!attrs.includes("samesite=lax")) cookieFindings.push(`${c.name} lacks SameSite=Lax`);
    if (attrs.some((a) => a.startsWith("expires=") || a.startsWith("max-age="))) cookieFindings.push(`${c.name} is persistent`);
  }
  s.sessionCookies = sessionCookies;

  // A cookie without Secure is acceptable only if the application's session does not depend on it:
  // a CSRF-protected write succeeds without it, and it alone carries no session. (On Lucee the
  // servlet container adds JSESSIONID, which it marks Secure only on an HTTPS request, and behind a
  // TLS-terminating gateway the request it sees is HTTP.)
  const unitId = Object.keys(me.json.orgUnits).find((id) => me.json.orgUnits[id].code === `${tag}-school`);
  const insecure = [...new Set(sessionCookies.filter((c) => !c.attributes.some((a) => a.toLowerCase() === "secure")).map((c) => c.name))];
  const withoutAuthority = [];
  for (const name of insecure) {
    const jar = [...walker.cookies.entries()];
    const header = (keep) => jar.filter(([k]) => keep(k)).map(([k, v]) => `${k}=${v}`).join("; ");
    const write = (cookie) => request("POST", "/api/walks", { headers: { ...gatewayHeaders(subjects.walker), Cookie: cookie, "X-ICFWalk-CSRF-Token": walker.csrf() }, body: { orgUnitId: unitId, clientMutationId: crypto.randomUUID() } });
    const without = await write(header((k) => k !== name));
    const alone = await write(header((k) => k === name));
    if (without.status === 201 && alone.status === 403) withoutAuthority.push(name);
    s[`authorityOf ${name}`] = { writeWithoutIt: without.status, writeWithItAlone: alone.status };
  }
  const findingsThatMatter = cookieFindings.filter((f) => !withoutAuthority.some((n) => f === `${n} lacks Secure`));
  s.cookieFindings = cookieFindings;
  s.cookiesWithoutSessionAuthority = withoutAuthority;
  const before = new Map(walker.cookies);

  // CSRF: a state change without the token is refused and changes nothing.
  const walksBefore = (await walker.call("GET", "/api/walks")).json.walks.length;
  const noCsrf = await walker.call("POST", "/api/walks", { orgUnitId: unitId, clientMutationId: crypto.randomUUID() }, { noCsrf: true });
  assert.equal(noCsrf.status, 403, noCsrf.text.slice(0, 200));
  assert.equal(noCsrf.json.error.code, "CSRF_TOKEN_INVALID");
  const badCsrf = await walker.call("POST", "/api/walks", { orgUnitId: unitId, clientMutationId: crypto.randomUUID() }, { noCsrf: true, headers: { "X-ICFWalk-CSRF-Token": crypto.randomBytes(32).toString("hex") } });
  assert.equal(badCsrf.status, 403);
  assert.equal((await walker.call("GET", "/api/walks")).json.walks.length, walksBefore, "nothing was created");
  s.csrf = { missing: noCsrf.status, wrong: badCsrf.status };

  // 4. Work on the least-privilege login: a walk with a narrative note, a stale save, completion, the export, a report.
  const created = await walker.call("POST", "/api/walks", { orgUnitId: unitId, clientMutationId: crypto.randomUUID() });
  assert.equal(created.status, 201, created.text.slice(0, 300));
  const walkId = created.json.walk.id;
  const saved = await walker.call("PUT", `/api/walks/${walkId}`, { rowVersion: created.json.walk.rowVersion, clientMutationId: crypto.randomUUID(),
    dimensions: { date: { dateValue: "2026-02-10" }, grade: { selectedValueCode: "7" }, school: { selectedValueCode: "abbott_middle_school" } },
    responses: { ...REQUIRED, comp_s1_q1: { storedCode: "4" }, comp_s1_notes: { textValue: sentinels.note } } });
  assert.equal(saved.status, 200, saved.text.slice(0, 300));
  const stale = await walker.call("PUT", `/api/walks/${walkId}`, { rowVersion: created.json.walk.rowVersion, clientMutationId: crypto.randomUUID(), dimensions: {}, responses: { comp_s1_notes: { textValue: "stale" } } });
  assert.equal(stale.status, 409, `a stale save is refused: ${stale.text.slice(0, 200)}`);
  const done = await walker.call("POST", `/api/walks/${walkId}/complete`, { rowVersion: saved.json.walk.rowVersion, clientMutationId: crypto.randomUUID() });
  assert.equal(done.status, 200, done.text.slice(0, 300));
  const summary = await walker.call("GET", `/api/walks/${walkId}/summary`);
  assert.equal(summary.status, 200);
  assert.ok(summary.text.includes(sentinels.note), "the export carries the note, so the log checks below are not vacuous");
  const reader = person(subjects.district, { name: "Production profile district reader", email: "" });
  const dme = await reader.call("GET", "/api/me");
  const districtId = Object.keys(dme.json.orgUnits).find((id) => dme.json.orgUnits[id].code === `${tag}-district`);
  const report = await reader.call("GET", `/api/reports/aggregate?versionId=${versionId}&orgUnitId=${districtId}`);
  assert.equal(report.status, 200, report.text.slice(0, 300));
  s.work = { create: created.status, save: saved.status, staleSave: stale.status, complete: done.status, summary: summary.status, report: report.status };

  // The session rotates when another identity signs in on the same browser.
  const other = await walker.call("GET", "/api/me", undefined, { headers: gatewayHeaders(subjects.district, { name: "Production profile district reader", email: "" }) });
  assert.equal(other.status, 200);
  const rotated = [...walker.cookies.entries()].filter(([k, v]) => before.has(k) && before.get(k) !== v).map(([k]) => k);
  assert.ok(rotated.length > 0, "a new identity on the same browser gets a new session");
  s.rotatedOnIdentityChange = rotated;

  // Errors carry a code, a message and a correlation id, and nothing about the engine or the code.
  const errors = {};
  assert.equal((await walker.call("GET", "/api/me")).status, 200, "the walker signs back in");
  const malformed = await walker.call("PUT", `/api/walks/${walkId}`, "{not json");
  const notFound = await walker.call("GET", "/api/no-such-route");
  const badId = await walker.call("GET", "/api/walks/not-a-guid");
  for (const [label, r] of [["malformed JSON", malformed], ["unknown route", notFound], ["malformed id", badId]]) {
    assert.ok(r.status >= 400 && r.status < 500, `${label}: ${r.status}`);
    assert.ok(r.json?.error?.code && r.json.error.correlationId, `${label}: code and correlation id`);
    for (const k of ["exceptionType", "exceptionMessage", "exceptionDetail", "tagContext", "stackTrace"]) assert.ok(!r.text.includes(k), `${label}: no ${k}`);
    errors[label] = { status: r.status, code: r.json.error.code, keys: Object.keys(r.json.error).sort() };
  }

  // 5. The database goes away, then comes back.
  await master.request().batch(`ALTER DATABASE [${database}] SET OFFLINE WITH ROLLBACK IMMEDIATE`);
  const down = await probeHealth(engine.base);
  assert.equal(down.status, 503, `health reports the outage: ${down.text?.slice(0, 200)}`);
  assert.equal(down.body.status, "degraded");
  assert.equal(down.body.checks.database, "unavailable");
  const failed = await walker.call("GET", "/api/walks");
  assert.equal(failed.status, 500, failed.text.slice(0, 300));
  assert.equal(failed.json.error.code, "INTERNAL_ERROR");
  assert.equal(failed.json.error.message, "An unexpected error occurred.");
  for (const leak of ["SQL", "sql", "database", "Database", "offline", "jdbc", database, runtimeLogin, "Exception", ".cfc"]) assert.ok(!failed.text.includes(leak), `the outage response carries no ${leak}`);
  errors["database offline"] = { status: failed.status, code: failed.json.error.code, keys: Object.keys(failed.json.error).sort(), correlationId: Boolean(failed.json.error.correlationId) };
  await master.request().batch(`ALTER DATABASE [${database}] SET ONLINE`);
  const t0 = Date.now();
  let back = null;
  for (let i = 0; i < 120; i++) {
    const h = await probeHealth(engine.base);
    const list = await walker.call("GET", "/api/walks");
    if (h.status === 200 && list.status === 200) { back = { health: h.body.status, walks: list.json.walks.length }; break; }
    await new Promise((r) => setTimeout(r, 1000));
  }
  assert.ok(back, "the application serves again once the database is back, without a restart");
  s.outage = { health: down.status, api: failed.status, recoveredWithoutRestartSeconds: (Date.now() - t0) / 1000, after: back };
  s.errors = errors;

  // 6. Logs and audit: no secret, token, password or narrative; the refusals and failures are recorded.
  const log = engine.logText();
  assert.ok(log.length > 0, "the application log was found");
  for (const [label, value] of [["the shared secret", secrets.shared], ["the maintenance token", secrets.maintenance], ["the runtime password", secrets.runtimePassword], ["the note", sentinels.note], ["the display name", sentinels.name], ["the email", sentinels.email]]) {
    assert.ok(!log.includes(value), `the log carries no ${label}`);
  }
  for (const event of ["identity.header.untrusted_source", "identity.header.secret_invalid", "auth.unknown_subject", "request.failed", "maintenance.disabled"]) {
    assert.ok(log.includes(event), `the log records ${event}`);
  }
  const auditPool = await new sql.ConnectionPool(connectionConfig(env, database, true)).connect();
  try {
    const leaks = await auditPool.request().input("a", sql.NVarChar, `%${sentinels.note}%`).input("b", sql.NVarChar, `%${secrets.shared}%`).input("c", sql.NVarChar, `%${sentinels.email}%`)
      .query("SELECT COUNT(*) AS n FROM [icf].[audit_event] WHERE details_json LIKE @a OR details_json LIKE @b OR details_json LIKE @c");
    assert.equal(leaks.recordset[0].n, 0, "no audit row carries the note, the secret or the email");
    const audited = await auditPool.request().query("SELECT event_type, COUNT(*) AS n FROM [icf].[audit_event] GROUP BY event_type ORDER BY event_type");
    s.auditEvents = Object.fromEntries(audited.recordset.map((r) => [r.event_type, r.n]));
  } finally { await auditPool.close(); }
  s.logLines = log.split("\n").filter(Boolean).length;
  evidence.phases.steady = s;

  // The findings, stated for the report rather than hidden in the transcript.
  t.diagnostic(`engine ${engine.name}; session cookies: ${JSON.stringify(sessionCookies)}; without session authority: ${JSON.stringify(withoutAuthority)}`);
  assert.deepEqual(findingsThatMatter, [], "every cookie the session depends on is Secure, HttpOnly, SameSite=Lax and ends with the browser");
});
