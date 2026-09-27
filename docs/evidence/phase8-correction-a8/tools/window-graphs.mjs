// A8-03: for runs whose deadlock graphs were not saved with them, counts the graphs of SQL Server's saved
// record of the session (system_health) whose victim transaction started in the run's window, and writes
// that count, with the graphs' file names, to <run>/deadlocks/deadlocks.txt.
//   node window-graphs.mjs <record dir> <run dir>=<from>=<to> ...   (times UTC, "YYYY-MM-DDTHH:MM:SS")
import fs from "node:fs";
import path from "node:path";
const [record, ...windows] = process.argv.slice(2);
const graphs = fs.readdirSync(record).filter((f) => /^deadlock-\d+\.xml$/.test(f)).sort().map((f) => {
  const g = fs.readFileSync(path.join(record, f), "utf8");
  const v = /<victimProcess id="([^"]+)"/.exec(g)[1];
  return { f, t: /lasttranstarted="([^"]+)"/.exec(new RegExp(`<process id="${v}"[^>]*>`).exec(g)[0])[1], obj: /objectname="([^"]+)"/.exec(g)[1] };
});
for (const w of windows) {
  const [dir, from, to] = w.split("=");
  const hit = graphs.filter((x) => x.obj.endsWith(".icf.walk_response") && x.t >= from && x.t < to);
  fs.mkdirSync(path.join(dir, "deadlocks"), { recursive: true });
  const rel = path.relative(path.join(dir, "deadlocks"), record);
  fs.writeFileSync(path.join(dir, "deadlocks", "deadlocks.txt"), `${hit.length} deadlock graph(s) on icf.walk_response with a victim transaction started from ${from}Z to ${to}Z, in SQL Server's record of the session (${rel}/)${hit.length ? `: ${hit.map((x) => x.f).join(", ")}` : ""}\n`);
  console.log(`${path.basename(dir)}: ${hit.length}`);
}
