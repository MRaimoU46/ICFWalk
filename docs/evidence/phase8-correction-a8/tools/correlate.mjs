// A8-03: joins each unexpected answer of a workload run to the application's request.failed event (by the
// correlation id the harness sent) and to SQL Server's deadlock graph (by the process id SQL Server named in
// the exception message, which is the victim's spid, within the minute after the request was sent).
// Prints a Markdown table; nothing it prints is a secret or personal data.
//
//   node correlate.mjs <workload JSON> <directory holding deadlock-NN.xml and summary.json>
import fs from "node:fs";
import path from "node:path";
const [jsonFile, graphsDir] = process.argv.slice(2);
const run = JSON.parse(fs.readFileSync(jsonFile, "utf8"));
const graphs = fs.readdirSync(graphsDir).filter((f) => /^deadlock-\d+\.xml$/.test(f)).sort().map((f) => {
  const g = fs.readFileSync(path.join(graphsDir, f), "utf8");
  const victim = /<victimProcess id="([^"]+)"/.exec(g)[1];
  const p = new RegExp(`<process id="${victim}"[^>]*>`).exec(g)[0];
  return { file: f, spid: Number(/\bspid="(\d+)"/.exec(p)[1]), at: /lasttranstarted="([^"]+)"/.exec(p)?.[1] || "", lockMode: /\blockMode="([^"]+)"/.exec(p)[1], wait: /\bwaitresource="([^"]+)"/.exec(p)[1].trim() };
});
const used = new Set();
console.log("| # | Operation | HTTP / code | Correlation id (sent by the harness) | Sent (UTC) | Elapsed | request.failed event | Deadlock graph (victim) |");
console.log("| --- | --- | --- | --- | --- | --- | --- | --- |");
let n = 0;
for (const f of run.unexpectedFailures || []) {
  n++;
  const e = (f.logEvents || []).find((x) => x.event === "request.failed");
  const pid = e ? Number(/Process ID (\d+)/.exec(e.fields.exceptionMessage || "")?.[1]) : NaN;
  const sent = Date.parse(f.sentAt);
  const g = graphs.find((x) => !used.has(x.file) && x.spid === pid && Date.parse(`${x.at}Z`) >= sent - 60000 && Date.parse(`${x.at}Z`) <= sent + 60000);
  if (g) used.add(g.file);
  const event = e ? `${e.ts}: ${e.fields.type}, ${e.fields.code}, ${e.fields.status}, ${e.fields.path}, at ${String(e.fields.at || "").replace(/^.*\/(src\/)/, "$1")}; "${(e.fields.exceptionMessage || "").replace(/^An error occurred during the current command \(Done status 0\)\. /, "").slice(0, 90)}..."` : "none";
  console.log(`| ${n} | ${f.op} | ${f.status} ${f.code} | \`${f.correlationId}\` | ${f.sentAt} | ${f.ms} ms | ${event} | ${g ? `${g.file}: spid ${g.spid}, ${g.lockMode} on ${g.wait}` : "none"} |`);
}
console.log(`\n${n} unexpected answers; ${[...(run.unexpectedFailures || [])].filter((f) => (f.logEvents || []).some((x) => x.event === "request.failed")).length} with their request.failed event; ${used.size} matched to a deadlock graph (of ${graphs.length} graphs in the window).`);
