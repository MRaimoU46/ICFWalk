// A8-01: one Markdown row per run of tests/ops/readiness-schema-missing.test.mjs, computed from the JSON
// record each run wrote, so the index quotes the records, not memory. Nothing it prints is a secret.
//
//   node readiness-table.mjs <label>=<readiness-schema-missing-*.json> [...]
import fs from "node:fs";
const rows = [];
for (const arg of process.argv.slice(2)) {
  const label = arg.slice(0, arg.indexOf("=")), file = arg.slice(arg.indexOf("=") + 1);
  const r = JSON.parse(fs.readFileSync(file, "utf8"));
  const s = r.steps || {}, d = r.database || {};
  const before = s.beforeMigrations || {};
  const checks = (b) => b && b.checks ? `database ${b.checks.database}, schema ${b.checks.schema}, longText ${b.checks.longText}` : "-";
  const statusOf = (x) => x ? `${x.status}${x.body?.status ? ` ${x.body.status}` : ""}` : "not reached";
  const m = s.migrations;
  const applied = m ? `migrations (exit ${m.exit}): ${(m.scripts || []).filter((x) => x.ok).length} of ${(m.scripts || []).length} scripts OK` : "";
  const later = [applied, ...Object.entries(s).filter(([k]) => k !== "beforeMigrations" && k !== "migrations").map(([k, v]) => `${k}: ${statusOf(v)}`)].filter(Boolean).join("; ");
  const c = r.cleanup || {};
  rows.push(`| ${label} | ${r.engineIdentity?.applicationStarted?.[0]?.engine || ({ acf: "Adobe ColdFusion 2023 Update 25 (pinned image)", lucee: "Lucee 6.2.8.20" }[r.engine] || r.engine)} | \`${d.name}\`: created ${d.createDate}, ${d.serverVersion} ${d.serverEdition}, tables ${d.tables}, icf schemas ${d.icfSchemas}, icf.instrument ${d.instrumentTable} | ${r.directConnection?.asRuntimeLogin ? "yes, as the runtime login (reader and writer, not owner)" : "no"} | ${statusOf(before)}: ${checks(before.body)} | ${later || (before.status === 200 ? "none: the operation failed here, \"health answered 200 before the ICFWalk schema exists\" (the red)" : "-")} | ${r.cleanup ? `engine removed ${c.engineRemoved}, database dropped ${c.databaseDropped}, login dropped ${c.loginDropped}, left ${c.readinessDatabasesLeft}` : "not in this record: the test stopped at its failed assertion, and its after-hook cleanup ran (the operations' final check: no temporary database or login left)"} |`);
}
console.log("| Run | Engine | The brand-new database (no credentials) | Connection | Health before the migrations | Afterwards | Cleanup |");
console.log("| --- | --- | --- | --- | --- | --- | --- |");
for (const row of rows) console.log(row);
