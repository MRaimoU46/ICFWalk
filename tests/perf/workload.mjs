// Phase 8 synthetic performance workload: timings, SQL plans and resource observations.
//
// Runs against a database seeded by tests/perf/seed.mjs and an application in development mode on
// it. It measures; it passes or fails nothing, because no performance target has been set
// (docs/OPERATIONS.md, section 12). A target, once agreed, is checked against these numbers.
//
// Each concurrency level runs for DURATION seconds. Every virtual user is a school walker doing what
// a walker does -- open My Walks, open one of their walks, change a note and save (half the time),
// read its summary (one time in ten), start and complete a new walk (one time in twenty) -- except
// one in five, who is the district walker: My Walks across the whole district, then a live district
// report and its CSV. After the levels, one report release over the synthetic school year is timed.
//
//   ICFWALK_DB_NAME=icfwalk_perf ICFWALK_BASE_URL=http://127.0.0.1:8889 ICFWALK_EVIDENCE_DIR=<dir> \
//     PERF_LEVELS=1,10,25 PERF_DURATION=60 PERF_ENGINE_PID=<jvm pid> | PERF_ENGINE_CONTAINER=<name> \
//     node tests/perf/workload.mjs
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";
import sql from "mssql";
import { baseUrl, connectionConfig, loadRuntimeEnv, root } from "../node/helpers.mjs";

const env = loadRuntimeEnv();
const database = env.ICFWALK_DB_NAME;
const LEVELS = (env.PERF_LEVELS || "1,10,25").split(",").map(Number);
const DURATION = Number(env.PERF_DURATION || 60) * 1000;
const TAG = "perf";
const outDir = env.ICFWALK_EVIDENCE_DIR || path.join(root, ".runtime", "perf");
const REQUEST_TIMEOUT = 60000;
if (!database || database === "icfwalk_dev") throw new Error("Set ICFWALK_DB_NAME to the seeded performance database.");
const log = (...a) => console.log(new Date().toISOString().slice(11, 19), ...a);

// ---- HTTP ---------------------------------------------------------------------------------------------

function client(subject) {
  const cookies = new Map();
  let csrf = "";
  const call = async (op, method, p, body, samples) => {
    const headers = { Accept: "application/json", "X-ICFWalk-Dev-Subject": subject };
    if (body !== undefined) headers["Content-Type"] = "application/json";
    if (csrf && method !== "GET") headers["X-ICFWalk-CSRF-Token"] = csrf;
    const cookie = [...cookies.entries()].map(([k, v]) => `${k}=${v}`).join("; ");
    if (cookie) headers.Cookie = cookie;
    const t0 = performance.now();
    let status = 0, text = "", error = null;
    try {
      const response = await fetch(`${baseUrl(env)}/index.cfm${p}`, { method, headers, body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(REQUEST_TIMEOUT) });
      for (const line of response.headers.getSetCookie()) {
        const [pair] = line.split(";");
        const eq = pair.indexOf("=");
        cookies.set(pair.slice(0, eq).trim(), pair.slice(eq + 1).trim());
      }
      status = response.status;
      text = await response.text();
    } catch (e) {
      error = e.name === "TimeoutError" ? "timeout" : String(e.cause?.code || e.message);
    }
    const ms = performance.now() - t0;
    let json = null;
    try { json = JSON.parse(text); } catch { json = null; }
    if (json && json.csrfToken) csrf = json.csrfToken;
    if (samples) samples.push({ op, ms, status, bytes: text.length, error: error || (status >= 400 ? `${status} ${json?.error?.code || ""}`.trim() : null) });
    return { status, json, text, ms };
  };
  return { call, subject };
}

// ---- SQL observations ---------------------------------------------------------------------------------

let pool;
async function q(text) { return (await pool.request().query(text)).recordset; }

async function queryStats() {
  return q(`
    SELECT CONVERT(varchar(130), qs.sql_handle, 1) + ':' + CAST(qs.statement_start_offset AS varchar(12)) + ':' + CONVERT(varchar(130), qs.plan_handle, 1) AS k,
           qs.execution_count AS n, qs.total_elapsed_time AS elapsedUs, qs.total_worker_time AS cpuUs, qs.total_logical_reads AS reads,
           qs.total_rows AS rowsOut, qs.max_elapsed_time AS maxUs, CONVERT(varchar(130), qs.plan_handle, 1) AS planHandle,
           SUBSTRING(st.text, qs.statement_start_offset / 2 + 1, (CASE WHEN qs.statement_end_offset = -1 THEN DATALENGTH(st.text) ELSE qs.statement_end_offset END - qs.statement_start_offset) / 2 + 1) AS statement
    FROM sys.dm_exec_query_stats qs CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st
    WHERE st.dbid = DB_ID() OR st.text LIKE '%icf%'`);
}

async function waits() {
  const rows = await q("SELECT wait_type AS w, wait_time_ms AS ms, waiting_tasks_count AS n FROM sys.dm_os_wait_stats WHERE wait_time_ms > 0");
  return new Map(rows.map((r) => [r.w, r]));
}

const BENIGN_WAITS = /^(SLEEP_|BROKER_|XE_|SQLTRACE_|LAZYWRITER|REQUEST_FOR_DEADLOCK|CHECKPOINT_QUEUE|LOGMGR_QUEUE|DIRTY_PAGE_POLL|HADR_|SP_SERVER_DIAGNOSTICS|QDS_|WAITFOR|FT_IFTS|ONDEMAND_TASK|CLR_|DISPATCHER|PWAIT_|SOS_WORK_DISPATCHER|PREEMPTIVE_XE|KSOURCE|FSAGENT|MEMORY_ALLOCATION_EXT|PARALLEL_REDO|SERVER_IDLE|RESOURCE_QUEUE|XE_DISPATCHER)/;

async function resources() {
  const [mem] = await q("SELECT physical_memory_in_use_kb / 1024 AS sqlMb FROM sys.dm_os_process_memory");
  const [temp] = await q("SELECT SUM(user_object_reserved_page_count) * 8 / 1024.0 AS userMb, SUM(internal_object_reserved_page_count) * 8 / 1024.0 AS internalMb, SUM(version_store_reserved_page_count) * 8 / 1024.0 AS versionMb FROM tempdb.sys.dm_db_file_space_usage");
  const [tempTables] = await q("SELECT COUNT(*) AS n FROM tempdb.sys.objects WHERE name LIKE '#%' AND type = 'U'");
  const [open] = await q(`SELECT COUNT(*) AS n FROM sys.dm_exec_sessions WHERE database_id = DB_ID() AND is_user_process = 1 AND open_transaction_count > 0 AND session_id <> @@SPID`);
  let engine = null;
  try {
    if (env.PERF_ENGINE_PID) {
      const status = fs.readFileSync(`/proc/${env.PERF_ENGINE_PID}/status`, "utf8");
      engine = { rssMb: Math.round(Number(/VmRSS:\s+(\d+)/.exec(status)[1]) / 1024), threads: Number(/Threads:\s+(\d+)/.exec(status)[1]) };
    } else if (env.PERF_ENGINE_CONTAINER) {
      const out = execFileSync("docker", ["stats", "--no-stream", "--format", "{{.MemUsage}}|{{.CPUPerc}}", env.PERF_ENGINE_CONTAINER], { encoding: "utf8" }).trim();
      engine = { dockerStats: out };
    }
  } catch (e) { engine = { error: e.message }; }
  return { sqlServerMb: Number(mem.sqlMb), tempdb: { userMb: Number(temp.userMb), internalMb: Number(temp.internalMb), versionStoreMb: Number(temp.versionMb) }, tempTablesInTempdb: tempTables.n, sessionsWithOpenTransactions: open.n, engine };
}

// ---- the virtual users --------------------------------------------------------------------------------

const pct = (xs, p) => xs.length ? xs[Math.min(xs.length - 1, Math.ceil((p / 100) * xs.length) - 1)] : null;
function summarize(samples, seconds) {
  const byOp = {};
  for (const s of samples) (byOp[s.op] ||= []).push(s);
  const out = {};
  for (const [op, list] of Object.entries(byOp)) {
    const ms = list.filter((s) => !s.error).map((s) => s.ms).sort((a, b) => a - b);
    const errors = list.filter((s) => s.error);
    out[op] = {
      count: list.length, errors: errors.length, errorKinds: [...new Set(errors.map((e) => e.error))].slice(0, 5),
      perSecond: Math.round((list.length / seconds) * 10) / 10,
      p50: ms.length ? Math.round(pct(ms, 50)) : null, p95: ms.length ? Math.round(pct(ms, 95)) : null, p99: ms.length ? Math.round(pct(ms, 99)) : null,
      max: ms.length ? Math.round(ms[ms.length - 1]) : null, meanBytes: Math.round(list.reduce((n, s) => n + s.bytes, 0) / list.length),
    };
  }
  return out;
}

async function walkerLoop(c, deadline, samples, ctx) {
  let i = 0;
  while (Date.now() < deadline) {
    i++;
    const list = await c.call("list mine", "GET", "/api/walks", undefined, samples);
    const walks = list.json?.walks || [];
    const mine = walks.filter((w) => w.status !== "VOIDED");
    if (mine.length) {
      const pick = mine[Math.floor(Math.random() * mine.length)];
      const opened = await c.call("open walk", "GET", `/api/walks/${pick.id}`, undefined, samples);
      const walk = opened.json?.walk;
      if (walk && Math.random() < 0.5) {
        const responses = { ...walk.state.responses, comp_s1_notes: { textValue: `Perf note ${crypto.randomUUID()}` } };
        for (const k of Object.keys(responses)) if (responses[k] && typeof responses[k] === "object") delete responses[k].state;
        await c.call("save walk", "PUT", `/api/walks/${pick.id}`, { rowVersion: walk.rowVersion, clientMutationId: crypto.randomUUID(), dimensions: walk.state.dimensions, responses }, samples);
      }
      if (Math.random() < 0.1) await c.call("summary", "GET", `/api/walks/${pick.id}/summary`, undefined, samples);
    }
    if (Math.random() < 0.05 && ctx.unit) {
      const created = await c.call("create walk", "POST", "/api/walks", { orgUnitId: ctx.unit, clientMutationId: crypto.randomUUID() }, samples);
      if (created.status === 201) {
        const state = { dimensions: { date: { dateValue: new Date().toISOString().slice(0, 10) }, school: { selectedValueCode: ctx.schoolValue }, grade: { selectedValueCode: ctx.grade }, content: { selectedValueCode: "math" } },
          responses: { p1q1: { storedCode: "Yes" }, p1q2: { storedCode: "Analysis" }, p1q3: { storedCode: "Analysis" }, part1_adopted_pacing: { storedCode: "on" }, part1_adopted_ac1: { storedCode: "4" }, part1_adopted_ac2: { storedCode: "3" }, part1_targettask_tt1: { storedCode: "4" }, part1_targettask_tt2: { storedCode: "5" } } };
        const saved = await c.call("save walk", "PUT", `/api/walks/${created.json.walk.id}`, { rowVersion: created.json.walk.rowVersion, clientMutationId: crypto.randomUUID(), ...state }, samples);
        if (saved.status === 200) await c.call("complete walk", "POST", `/api/walks/${created.json.walk.id}/complete`, { rowVersion: saved.json.walk.rowVersion, clientMutationId: crypto.randomUUID() }, samples);
      }
    }
  }
}

async function districtLoop(c, deadline, samples, ctx) {
  while (Date.now() < deadline) {
    await c.call("list district (scope=all)", "GET", "/api/walks?scope=all", undefined, samples);
    await c.call("report live district", "GET", `/api/reports/aggregate?versionId=${ctx.versionId}&orgUnitId=${ctx.districtId}`, undefined, samples);
    await c.call("report CSV district", "GET", `/api/reports/aggregate.csv?versionId=${ctx.versionId}&orgUnitId=${ctx.districtId}`, undefined, samples);
  }
}

// ---- run ----------------------------------------------------------------------------------------------

pool = await new sql.ConnectionPool(connectionConfig(env, database, true)).connect();
const seed = (await q("SELECT COUNT_BIG(*) AS walks, (SELECT COUNT_BIG(*) FROM icf.walk_response) AS responses FROM icf.walk"))[0];
const [server] = await q("SELECT CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(40)) AS version, CAST(SERVERPROPERTY('Edition') AS nvarchar(100)) AS edition, (SELECT cpu_count FROM sys.dm_os_sys_info) AS cpus, (SELECT physical_memory_kb / 1024 FROM sys.dm_os_sys_info) AS memoryMb");
const health = await (await fetch(`${baseUrl(env)}/index.cfm/api/health`)).json();
const walkers = (await q(`SELECT identity_subject AS subject FROM icf.app_user WHERE identity_subject LIKE N'${TAG}-%-w%' ORDER BY identity_subject`)).map((r) => r.subject);
const district = client(`${TAG}-district-walker`);
const dm = await district.call("me", "GET", "/api/me");
const districtId = Object.keys(dm.json.orgUnits).find((id) => dm.json.orgUnits[id].code === `${TAG}-district`);
const current = await district.call("instrument", "GET", "/api/instrument/current");
const versionId = current.json.version.versionId;
const GRADE_OF = { elementary: "3", middle: "7", high: "10" };
const groups = Object.fromEntries(JSON.parse(fs.readFileSync(path.join(root, "config", "instrument-config.json"), "utf8")).dimensionValues.filter((v) => v.dimensionId === "dim_school").map((v) => [v.valueCode, v.valueGroup]));

const run = {
  startedAt: new Date().toISOString(), database, baseUrl: baseUrl(env), engine: health.engine, server, data: { walks: Number(seed.walks), responses: Number(seed.responses) },
  method: { durationSeconds: DURATION / 1000, levels: LEVELS, mix: "4 of 5 virtual users are school walkers (list mine, open, save 50 %, summary 10 %, create+save+complete 5 %); 1 of 5 is the district walker (list scope=all, live district report, district CSV)", requestTimeoutMs: REQUEST_TIMEOUT },
  levels: [],
};
log(`${run.engine} on ${database}: ${run.data.walks} walks, ${run.data.responses} responses; levels ${LEVELS.join(",")} for ${DURATION / 1000}s`);

const statsBefore = new Map((await queryStats()).map((r) => [r.k, r]));
for (const level of LEVELS) {
  const waitsBefore = await waits();
  const before = await resources();
  const samples = [];
  const blocking = { samples: 0, blockedMax: 0, longestWaitMs: 0 };
  const deadline = Date.now() + DURATION;
  const sampler = setInterval(async () => {
    try {
      const [b] = await q("SELECT COUNT(*) AS n, ISNULL(MAX(wait_time), 0) AS w FROM sys.dm_exec_requests WHERE blocking_session_id <> 0");
      blocking.samples++; blocking.blockedMax = Math.max(blocking.blockedMax, b.n); blocking.longestWaitMs = Math.max(blocking.longestWaitMs, b.w);
    } catch { /* sampling only */ }
  }, 1000);
  const users = [];
  for (let v = 0; v < level; v++) {
    if (v % 5 === 4) { users.push(districtLoop(client(`${TAG}-district-walker`), deadline, samples, { versionId, districtId })); continue; }
    const subject = walkers[(v * 37) % walkers.length];
    const c = client(subject);
    const me = await c.call("me", "GET", "/api/me");
    const unit = Object.keys(me.json.orgUnits).find((id) => me.json.orgUnits[id].type === "SCHOOL");
    const schoolValue = subject.slice(TAG.length + 1, subject.lastIndexOf("-w"));
    users.push(walkerLoop(c, deadline, samples, { unit, schoolValue, grade: GRADE_OF[groups[schoolValue]] }));
  }
  const t0 = Date.now();
  await Promise.all(users);
  clearInterval(sampler);
  const seconds = (Date.now() - t0) / 1000;
  const waitsAfter = await waits();
  const topWaits = [...waitsAfter.values()].map((w) => ({ wait: w.w, ms: Number(w.ms) - Number(waitsBefore.get(w.w)?.ms || 0), count: Number(w.n) - Number(waitsBefore.get(w.w)?.n || 0) }))
    .filter((w) => w.ms > 0 && !BENIGN_WAITS.test(w.wait)).sort((a, b) => b.ms - a.ms).slice(0, 8);
  const after = await resources();
  const result = { concurrency: level, seconds, requests: samples.length, operations: summarize(samples, seconds), blocking, topWaits, resourcesBefore: before, resourcesAfter: after };
  run.levels.push(result);
  log(`level ${level}: ${samples.length} requests in ${seconds.toFixed(0)}s; ${Object.entries(result.operations).map(([op, s]) => `${op} p50=${s.p50} p95=${s.p95} max=${s.max} err=${s.errors}`).join("; ")}`);
}

// One report release over the synthetic school year, timed once.
const releaser = client(`${TAG}-district-walker`);
await releaser.call("me", "GET", "/api/me");
const releaseSamples = [];
const release = await releaser.call("create release", "POST", "/api/reports/releases", { observedFrom: "2025-08-15", observedTo: "2026-06-30" }, releaseSamples);
run.release = { status: release.status, ms: Math.round(release.ms), code: release.json?.error?.code ?? null, blocks: release.json?.release?.blockCount ?? release.json?.blockCount ?? null };
const reportOnly = client(`${TAG}-district-reports`);
await reportOnly.call("me", "GET", "/api/me");
const releasedRead = await reportOnly.call("report release read", "GET", `/api/reports/aggregate?versionId=${versionId}&orgUnitId=${districtId}&releaseId=${release.json?.release?.releaseId || release.json?.releaseId || ""}`, undefined, releaseSamples);
run.releaseRead = { status: releasedRead.status, ms: Math.round(releasedRead.ms) };
log(`release: ${JSON.stringify(run.release)}; release read ${JSON.stringify(run.releaseRead)}`);

// The statements that took the most time over the whole run, with their plans.
const statsAfter = await queryStats();
const deltas = statsAfter.map((r) => {
  const b = statsBefore.get(r.k);
  return { ...r, n: Number(r.n) - Number(b?.n || 0), elapsedUs: Number(r.elapsedUs) - Number(b?.elapsedUs || 0), cpuUs: Number(r.cpuUs) - Number(b?.cpuUs || 0), reads: Number(r.reads) - Number(b?.reads || 0), rowsOut: Number(r.rowsOut) - Number(b?.rowsOut || 0) };
}).filter((r) => r.n > 0 && /icf\]?\.\[?/i.test(r.statement)).sort((a, b) => b.elapsedUs - a.elapsedUs).slice(0, 15);
fs.mkdirSync(path.join(outDir, "plans"), { recursive: true });
run.topStatements = [];
let rank = 0;
for (const d of deltas) {
  rank++;
  const [plan] = (await pool.request().input("h", sql.VarBinary, Buffer.from(d.planHandle.slice(2), "hex")).query("SELECT query_plan AS p FROM sys.dm_exec_query_plan(@h)")).recordset;
  const xml = plan?.p || "";
  if (xml) fs.writeFileSync(path.join(outDir, "plans", `statement-${String(rank).padStart(2, "0")}.sqlplan`), xml);
  const scans = [...xml.matchAll(/PhysicalOp="(Clustered Index Scan|Index Scan|Table Scan)"[\s\S]*?Table="\[([^\]]+)\]"/g)].map((m) => `${m[1]} ${m[2]}`);
  run.topStatements.push({
    rank, executions: d.n, totalMs: Math.round(d.elapsedUs / 1000), avgMs: Math.round(d.elapsedUs / d.n / 100) / 10, avgCpuMs: Math.round(d.cpuUs / d.n / 100) / 10,
    avgLogicalReads: Math.round(d.reads / d.n), avgRows: Math.round(d.rowsOut / d.n), maxMs: Math.round(Number(d.maxUs) / 1000), scans: [...new Set(scans)],
    statement: d.statement.replace(/\s+/g, " ").trim().slice(0, 400), plan: xml ? `plans/statement-${String(rank).padStart(2, "0")}.sqlplan` : null,
  });
}
run.missingIndexes = (await q(`
  SELECT d.statement AS tableName, d.equality_columns AS equality, d.inequality_columns AS inequality, d.included_columns AS included,
         s.user_seeks AS seeks, s.user_scans AS scans, ROUND(s.avg_total_user_cost * s.avg_user_impact * (s.user_seeks + s.user_scans), 0) AS benefit
  FROM sys.dm_db_missing_index_details d JOIN sys.dm_db_missing_index_groups g ON g.index_handle = d.index_handle
  JOIN sys.dm_db_missing_index_group_stats s ON s.group_handle = g.index_group_handle
  WHERE d.database_id = DB_ID() ORDER BY benefit DESC`)).slice(0, 10);
run.finishedAt = new Date().toISOString();
run.leftovers = await resources();
fs.mkdirSync(outDir, { recursive: true });
const file = path.join(outDir, `workload-${(run.engine || "engine").replace(/[^A-Za-z0-9.]+/g, "-")}.json`);
fs.writeFileSync(file, `${JSON.stringify(run, null, 2)}\n`);
log(`written ${file}`);
await pool.close();
