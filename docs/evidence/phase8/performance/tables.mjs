// Builds the performance README's tables from the workload JSON files.
import fs from "node:fs";
import path from "node:path";
const dir = process.argv[2];
const runs = [
  ["Lucee, before P8-14, completed walks edited", "lucee-run1"],
  ["Lucee, before P8-14, repeat", "lucee-run2-default-mix-repeat"],
  ["Lucee, before P8-14, drafts only edited", "lucee-run3-drafts"],
  ["ColdFusion, before P8-14, completed walks edited", "acf-any"],
  ["ColdFusion, before P8-14, drafts only edited", "acf-drafts"],
  ["ColdFusion, after P8-14, completed walks edited", "acf-after-p814-any"],
  ["ColdFusion, after P8-14, drafts only edited", "acf-after-p814-drafts"],
  ["Lucee, after P8-14, completed walks edited", "lucee-after-p814-any"],
  ["Lucee, after P8-14, drafts only edited", "lucee-after-p814-drafts"],
];
const OPS = ["list mine", "open walk", "save walk", "summary", "create walk", "complete walk", "list district (scope=all)", "report live district", "report CSV district"];
const cell = (st) => (st ? `${st.p50 ?? "-"} / ${st.p95 ?? "-"}${st.errors ? ` (${st.errors} err)` : ""}` : "");
let out = "";
for (const [title, name] of runs) {
  const d = path.join(dir, name);
  if (!fs.existsSync(d)) continue;
  const file = fs.readdirSync(d).find((f) => f.startsWith("workload-") && f.endsWith(".json"));
  if (!file) continue;
  const j = JSON.parse(fs.readFileSync(path.join(d, file), "utf8"));
  out += `\n### ${title} (\`${name}/\`)\n\n`;
  out += `${j.engine}; ${j.data.walks} walks, ${j.data.responses} responses; ${j.method.durationSeconds} s per level; edits: ${j.method.edits ?? "any"}.`;
  if (j.solo) out += ` District report alone: live p50 ${j.solo["report live district (solo)"]?.p50} ms, CSV p50 ${j.solo["report CSV district (solo)"]?.p50} ms.`;
  out += "\n\n| Users | Requests/min | " + OPS.join(" | ") + " |\n| --- | --- | " + OPS.map(() => "---").join(" | ") + " |\n";
  for (const lv of j.levels) {
    const rpm = Math.round((lv.requests / lv.seconds) * 60);
    out += `| ${lv.concurrency} | ${rpm} | ` + OPS.map((op) => cell(lv.operations[op])).join(" | ") + " |\n";
  }
  const kinds = new Set();
  for (const lv of j.levels) for (const st of Object.values(lv.operations)) for (const k of st.errorKinds || []) kinds.add(k);
  if (kinds.size) out += `\nErrors: ${[...kinds].join(", ")}.\n`;
  const lvLast = j.levels.at(-1);
  out += `\nAt ${lvLast.concurrency} users: longest block ${lvLast.blocking.longestWaitMs} ms (${lvLast.blocking.blockedMax} blocked at once); top waits ${lvLast.topWaits.slice(0, 3).map((w) => `${w.wait} ${Math.round(w.ms / 1000)} s`).join(", ")}; engine ${JSON.stringify(lvLast.resourcesAfter.engine)}; temp tables before/after ${j.levels[0].resourcesBefore.tempTablesInTempdb}/${j.leftovers.tempTablesInTempdb}, open transactions after ${j.leftovers.sessionsWithOpenTransactions}.\n`;
}
process.stdout.write(out);
