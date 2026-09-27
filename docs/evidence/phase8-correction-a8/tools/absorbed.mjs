// A8-03: on the correction commit, every deadlock SQL Server recorded during a run, beside the application's
// report.deadlock.victim event for it and what that request finally answered. A graph is paired with the
// event nearest to SQL Server's detection time (deadlocks.txt), within two seconds: the victim's error
// reaches the application as SQL Server resolves the deadlock, and the application logs it as it catches it.
// A request the workload kept no failure for was answered with success; a 409 REPORT_POPULATION_CHANGED
// after the retry is the expected refusal (the retry's later attempt saw walks move).
//   node absorbed.mjs <label>=<run dir> ...
import fs from "node:fs";
import path from "node:path";
console.log("| Run | Deadlock graph (victim spid, detected by SQL Server) | report.deadlock.victim event (UTC) | Attempt | Correlation id | The request's answer |");
console.log("| --- | --- | --- | --- | --- | --- |");
let total = 0, matched = 0;
const outcome = new Map();
for (const arg of process.argv.slice(2)) {
  const [label, dir] = [arg.slice(0, arg.indexOf("=")), arg.slice(arg.indexOf("=") + 1)];
  const run = JSON.parse(fs.readFileSync(path.join(dir, fs.readdirSync(dir).find((f) => /^workload-.*\.json$/.test(f))), "utf8"));
  const failures = new Map([...(run.soloFailures || []), ...run.levels.flatMap((l) => l.failures || []), ...(run.releaseFailures || [])].map((f) => [f.correlationId, f]));
  const events = fs.readFileSync(path.join(dir, "log-events-during-run.txt"), "utf8").split("\n").filter((l) => l.includes('"event":"report.deadlock.victim"'))
    .map((l) => JSON.parse(l.slice(l.indexOf("{"), l.lastIndexOf("}") + 1)));
  const dl = path.join(dir, "deadlocks");
  const detected = new Map([...fs.readFileSync(path.join(dl, "deadlocks.txt"), "utf8").matchAll(/^--- (\d+) at (\S+) victim/gm)].map((m) => [`deadlock-${m[1]}.xml`, `${m[2]}Z`]));
  const graphs = fs.readdirSync(dl).filter((f) => /^deadlock-\d+\.xml$/.test(f)).sort().map((f) => {
    const g = fs.readFileSync(path.join(dl, f), "utf8");
    const v = /<victimProcess id="([^"]+)"/.exec(g)[1];
    return { f, spid: /\bspid="(\d+)"/.exec(new RegExp(`<process id="${v}"[^>]*>`).exec(g)[0])[1], at: detected.get(f) };
  });
  const used = new Set();
  for (const g of graphs) {
    total++;
    const e = events.filter((x) => !used.has(x.correlationId + x.fields.attempt)).map((x) => ({ x, d: Math.abs(Date.parse(x.ts) - Date.parse(g.at)) }))
      .filter((c) => c.d <= 2000).sort((a, b) => a.d - b.d)[0]?.x;
    if (e) { used.add(e.correlationId + e.fields.attempt); matched++; }
    const fail = e ? failures.get(e.correlationId) : null;
    if (e) outcome.set(e.correlationId, fail ? (fail.expected ? "refused" : "failed") : "ok");
    console.log(`| ${label} | ${g.f}: spid ${g.spid}, detected ${g.at} | ${e ? e.ts : "none"} | ${e ? e.fields.attempt : "-"} | ${e ? `\`${e.correlationId}\`` : "-"} | ${e ? (fail ? `${fail.kind}${fail.expected ? " (expected refusal)" : " (UNEXPECTED)"}` : "success: no failure recorded for it") : "-"} |`);
  }
}
const n = (k) => [...outcome.values()].filter((v) => v === k).length;
console.log(`\n${total} deadlock graphs; ${matched} matched to a report.deadlock.victim event, in ${outcome.size} distinct requests: ${n("ok")} answered with success, ${n("refused")} with the expected 409 REPORT_POPULATION_CHANGED, ${n("failed")} with an error.`);
