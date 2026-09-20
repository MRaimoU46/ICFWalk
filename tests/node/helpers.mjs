// Shared helpers for the Node test harness and scripts.
import fs from "node:fs";
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

export async function api(env, method, apiPath, { body, token } = {}) {
  const headers = { "Accept": "application/json" };
  if (body !== undefined) headers["Content-Type"] = "application/json";
  if (token) headers["X-ICFWalk-Maintenance-Token"] = token;
  const response = await fetch(`${baseUrl(env)}/index.cfm${apiPath}`, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
  const text = await response.text();
  let json = null;
  try { json = JSON.parse(text); } catch { json = null; }
  return { status: response.status, headers: response.headers, text, json };
}
