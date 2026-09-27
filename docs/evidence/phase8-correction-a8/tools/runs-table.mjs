// A8-03: one Markdown row per workload run, computed from the run's own JSON (and, where the run kept them,
// its deadlock graphs and the log events written during it), so the findings quote numbers, not memory.
//
//   node runs-table.mjs <label>=<run dir> [<label>=<run dir> ...]
import fs from "node:fs";
import path from "node:path";
const rows = [];
for (const arg of process.argv.slice(2)) {
  const [label, dir] = [arg.slice(0, arg.indexOf("=")), arg.slice(arg.indexOf("=") + 1)];
  const file = fs.readdirSync(dir).find((f) => /^workload-.*\.json$/.test(f));
  const r = JSON.parse(fs.readFileSync(path.join(dir, file), "utf8"));
  const lv = (l) => {
    const o = l.operations; const live = o["report live district"] || {}; const csv = o["report CSV district"] || {};
    return `${l.concurrency} users: ${l.requests} requests; live ${live.count ?? 0} (p50 ${live.p50 ?? "-"} ms), CSV ${csv.count ?? 0} (p50 ${csv.p50 ?? "-"} ms)`;
  };
  // Runs recorded before the failure capture existed have no failureTotals: count from the operations.
  let expected = 0, unexpected = 0; const kinds = {};
  for (const l of [{ operations: r.solo || {} }, ...r.levels]) for (const s of Object.values(l.operations)) {
    for (const [k, n] of Object.entries(s.errorCounts || {})) { kinds[k] = (kinds[k] || 0) + n; if (k === "409 REPORT_POPULATION_CHANGED") expected += n; else unexpected += n; }
  }
  if (r.failureTotals) { expected = r.failureTotals.expectedRefusals; unexpected = r.failureTotals.unexpected; }
  const dl = path.join(dir, "deadlocks");
  const graphs = fs.existsSync(dl) ? fs.readdirSync(dl).filter((f) => /^deadlock-\d+\.xml$/.test(f)).length : null;
  const ev = path.join(dir, "log-events-during-run.txt");
  const events = fs.existsSync(ev) ? fs.readFileSync(ev, "utf8") : null;
  const count = (name) => events === null ? "-" : (events.match(new RegExp(`"event":"${name.replace(/\./g, "\\.")}"`, "g")) || []).length;
  rows.push(`| ${label} | ${r.startedAt.slice(0, 19)}Z | ${r.engine} | ${r.method.edits} | ${r.data.walks} | ${r.levels.map(lv).join("<br>")} | ${expected} | ${unexpected}${unexpected ? ` (${Object.entries(kinds).filter(([k]) => k !== "409 REPORT_POPULATION_CHANGED").map(([k, n]) => `${n} ${k}`).join(", ")})` : ""} | ${graphs ?? "-"} | ${count("report.deadlock.victim")} | ${count("request.failed")} |`);
}
console.log("| Run | Started (UTC) | Engine | Edits | Walks | Levels (60 s each) | Expected 409 | Unexpected | Deadlock graphs | report.deadlock.victim logged | request.failed logged |");
console.log("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |");
for (const row of rows) console.log(row);
