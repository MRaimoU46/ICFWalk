// Shared helpers for the Node test harness and scripts.
import fs from "node:fs";
import http from "node:http";
import https from "node:https";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");

function parseEnv(text) {
  const out = {};
  for (let line of text.split(/\r?\n/)) {
    line = line.trim();
    if (!line || line.startsWith("#")) continue;
    if (line.startsWith("export ")) line = line.slice(7).trim();
    const eq = line.indexOf("=");
    if (eq <= 0) continue;
    const key = line.slice(0, eq).trim();
    let value = line.slice(eq + 1).trim();
    if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) value = value.slice(1, -1);
    out[key] = value;
  }
  return out;
}

/**
 * Environment for local tooling: process env wins, then <repo>/.env, then .runtime/mssql.env
 * (the local container's SA password, mapped to ICFWALK_DB_* when those are unset).
 */
export function loadRuntimeEnv() {
  const merged = {};
  const envFile = process.env.ICFWALK_ENV_FILE || path.join(root, ".env");
  if (fs.existsSync(envFile)) Object.assign(merged, parseEnv(fs.readFileSync(envFile, "utf8")));
  const mssqlEnv = path.join(root, ".runtime", "mssql.env");
  if (fs.existsSync(mssqlEnv)) {
    const local = parseEnv(fs.readFileSync(mssqlEnv, "utf8"));
    if (local.MSSQL_SA_PASSWORD) {
      merged.ICFWALK_DB_USER ||= "sa";
      merged.ICFWALK_DB_PASSWORD ||= local.MSSQL_SA_PASSWORD;
      merged.ICFWALK_TEST_DB_ADMIN_USER ||= "sa";
      merged.ICFWALK_TEST_DB_ADMIN_PASSWORD ||= local.MSSQL_SA_PASSWORD;
      merged.ICFWALK_DB_HOST ||= "127.0.0.1";
      merged.ICFWALK_DB_TRUST_SERVER_CERT ||= "true";
    }
  }
  for (const [k, v] of Object.entries(process.env)) if (k.startsWith("ICFWALK_") && v !== undefined && v !== "") merged[k] = v;
  return merged;
}

export function connectionConfig(env, database, admin = false) {
  const user = admin ? env.ICFWALK_TEST_DB_ADMIN_USER || env.ICFWALK_DB_USER : env.ICFWALK_DB_USER;
  const password = admin ? env.ICFWALK_TEST_DB_ADMIN_PASSWORD || env.ICFWALK_DB_PASSWORD : env.ICFWALK_DB_PASSWORD;
  return {
    server: env.ICFWALK_DB_HOST || "127.0.0.1",
    port: Number(env.ICFWALK_DB_PORT || 1433),
    database,
    user,
    password,
    options: {
      encrypt: (env.ICFWALK_DB_ENCRYPT || "true") === "true",
      trustServerCertificate: (env.ICFWALK_DB_TRUST_SERVER_CERT || "false") === "true",
    },
    requestTimeout: 120000,
  };
}

export function hasDatabaseConfig(env) {
  return Boolean(env.ICFWALK_DB_HOST && env.ICFWALK_DB_USER && env.ICFWALK_DB_PASSWORD);
}

export function readScript(name) {
  return fs.readFileSync(path.join(root, "database", name), "utf8");
}

/** Runs a T-SQL batch; the supplied scripts contain no GO separators. */
export async function applyScript(pool, text) {
  try {
    const result = await pool.request().batch(text);
    return { ok: true, recordset: result.recordset ?? null, error: null };
  } catch (error) {
    return { ok: false, recordset: null, error };
  }
}

/**
 * Where the browser suites write their screenshots: the tracked docs/evidence/screenshots by
 * default. ICFWALK_SCREENSHOT_DIR redirects them. Playwright's PNG bytes differ from run to run on
 * the same machine (font hinting, antialiasing), so an exact-commit release gate points this
 * outside the repository; otherwise running the gate would change the tree it is proving.
 */
export function screenshotDir(env) {
  return env.ICFWALK_SCREENSHOT_DIR ? path.resolve(env.ICFWALK_SCREENSHOT_DIR) : path.join(root, "docs", "evidence", "screenshots");
}

export function baseUrl(env) {
  return (env.ICFWALK_BASE_URL || `http://127.0.0.1:${env.ICFWALK_PORT || 8888}`).replace(/\/$/, "");
}

/**
 * Whether a running application is *expected* for this run.
 *
 * A test that needs the application has three possible states, and collapsing any two of them
 * hides a real result. It can run and pass; it can be skipped because this is an optional local
 * run with nothing deployed; or it can fail because a run that was supposed to exercise the live
 * application did not exercise it. The third is the one that matters for release verification: an
 * absent application there means the check never happened, which is not the same as the check
 * having succeeded and must not be reported as one.
 *
 * Optional local runs leave ICFWALK_REQUIRE_APP unset and live tests report as explicit skips.
 * The full integration and release-verification profiles set ICFWALK_REQUIRE_APP=1, and then an
 * unreachable application fails the run.
 */
export function requireApp(env) {
  const value = String(env.ICFWALK_REQUIRE_APP ?? "").trim().toLowerCase();
  return value === "1" || value === "true" || value === "yes";
}

export async function api(env, method, apiPath, { body, token, timeoutMs } = {}) {
  const headers = { "Accept": "application/json" };
  if (body !== undefined) headers["Content-Type"] = "application/json";
  if (token) headers["X-ICFWalk-Maintenance-Token"] = token;
  const payload = body === undefined ? undefined : JSON.stringify(body);
  if (timeoutMs) return requestWithTimeout(env, method, apiPath, headers, payload, timeoutMs);
  const response = await fetch(`${baseUrl(env)}/index.cfm${apiPath}`, { method, headers, body: payload });
  const text = await response.text();
  let json = null;
  try { json = JSON.parse(text); } catch { json = null; }
  return { status: response.status, headers: response.headers, text, json };
}

/**
 * The same call, for a request whose response headers legitimately take longer than the fetch
 * client is willing to wait.
 *
 * WHY THIS EXISTS. The CFML suite runs inside one /api/maintenance/tests/run request and sends no
 * response headers until it finishes, and several specs deliberately block a writer for seconds at
 * a time. Lucee is configured to allow that (LUCEE_REQUESTTIMEOUT in tools/runtime/lucee-up.sh);
 * the CLIENT was not. Node's fetch inherits undici's 300-second headersTimeout, so on a slower
 * machine a perfectly healthy suite run was reported as "fetch failed" -- and the abort also
 * skipped every spec's afterAll, leaving fixtures behind that then failed later tests. That is a
 * harness ceiling, not a result: nothing about it says anything about the code under test.
 *
 * node:http has no such default, so the ceiling becomes an explicit one this helper is given. It
 * is still a ceiling: a run that really hangs fails rather than waiting forever.
 */
function requestWithTimeout(env, method, apiPath, headers, payload, timeoutMs) {
  const url = new URL(`${baseUrl(env)}/index.cfm${apiPath}`);
  const transport = url.protocol === "https:" ? https : http;
  return new Promise((resolve, reject) => {
    const request = transport.request(
      { protocol: url.protocol, hostname: url.hostname, port: url.port, path: `${url.pathname}${url.search}`, method, headers },
      (response) => {
        let text = "";
        response.setEncoding("utf8");
        response.on("data", (chunk) => { text += chunk; });
        response.on("end", () => {
          let json = null;
          try { json = JSON.parse(text); } catch { json = null; }
          resolve({ status: response.statusCode, headers: new Headers(Object.entries(response.headers).map(([k, v]) => [k, String(v)])), text, json });
        });
      },
    );
    request.setTimeout(timeoutMs, () => request.destroy(new Error(`no response within ${timeoutMs}ms from ${url}`)));
    request.on("error", reject);
    if (payload !== undefined) request.write(payload);
    request.end();
  });
}

/**
 * A fixture user who may create report releases: under the approved RPT-03 rule only someone
 * holding walk.read and report.view on EVERY active org unit may, so the user is given
 * DISTRICT_WALK_REPORT at each active unit (read from the database, because no route lists units).
 * Call it after the suite has imported its own units. Returns the subject.
 */
export async function provisionReleaser(env, token, subject) {
  const provisioned = await api(env, "POST", "/api/maintenance/identity/provision-user", { token, body: { subject, displayName: `Fixture ${subject}` } });
  if (provisioned.status !== 200 && provisioned.status !== 201) throw new Error(`provision-user ${provisioned.status}: ${provisioned.text}`);
  const { default: sql } = await import("mssql");
  const pool = await sql.connect(connectionConfig(env, env.ICFWALK_DB_NAME || "icfwalk_dev"));
  let codes = [];
  try {
    codes = (await pool.request().query("SELECT org_unit_code FROM icf.org_unit WHERE active = 1")).recordset.map((r) => r.org_unit_code);
  } finally {
    await pool.close();
  }
  for (const orgUnitCode of codes) {
    const a = await api(env, "POST", "/api/maintenance/identity/assign-role", { token, body: { subject, roleCode: "DISTRICT_WALK_REPORT", orgUnitCode, includeDescendants: false } });
    if (a.status !== 201) throw new Error(`assign-role ${orgUnitCode} ${a.status}: ${a.text}`);
  }
  return subject;
}

/** A random first-of-the-month date in [fromYear, toYear], as YYYY-MM-DD, for a suite's own release period. */
export function releaseMonth(fromYear, toYear) {
  const year = fromYear + Math.floor(Math.random() * (toYear - fromYear + 1));
  const month = 1 + Math.floor(Math.random() * 12);
  return `${year}-${String(month).padStart(2, "0")}-01`;
}
