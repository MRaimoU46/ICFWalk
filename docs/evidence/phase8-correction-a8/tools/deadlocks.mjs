// Reads SQL Server's own record of every deadlock (the system_health session's xml_deadlock_report
// events) and writes each graph to <out>/deadlock-NN.xml, then prints a summary per graph. Tests/evidence only.
import fs from "node:fs";
import path from "node:path";
const sql = (await import("/home/user/ICFWalk/node_modules/mssql/index.js")).default;
const { connectionConfig, loadRuntimeEnv } = await import("/home/user/ICFWalk/tests/node/helpers.mjs");
const [out, since, until] = process.argv.slice(2);
const env = loadRuntimeEnv();
const pool = await new sql.ConnectionPool(connectionConfig(env, "master", true)).connect();
const rows = (await pool.request().input("since", sql.NVarChar, since || "2000-01-01T00:00:00Z").input("until", sql.NVarChar, until || "2100-01-01T00:00:00Z").query(`
  SELECT CONVERT(varchar(33), x.value('(@timestamp)[1]', 'datetime2'), 126) AS ts, CAST(x.query('(data/value/deadlock)[1]') AS nvarchar(max)) AS graph
  FROM (SELECT CAST(event_data AS xml) AS e FROM sys.fn_xe_file_target_read_file('system_health*.xel', NULL, NULL, NULL) WHERE object_name = 'xml_deadlock_report') f
  CROSS APPLY f.e.nodes('/event') t(x)
  WHERE x.value('(@timestamp)[1]', 'datetime2') >= CAST(@since AS datetime2) AND x.value('(@timestamp)[1]', 'datetime2') < CAST(@until AS datetime2)
  ORDER BY ts`)).recordset;
await pool.close();
fs.mkdirSync(out, { recursive: true });
rows.forEach((r, i) => fs.writeFileSync(path.join(out, `deadlock-${String(i + 1).padStart(2, "0")}.xml`), r.graph));
console.log(`${rows.length} deadlock graph(s) from ${since || "(any time)"} to ${until || "(now)"}`);
for (const [i, r] of rows.entries()) {
  const g = r.graph;
  const victim = /<victimProcess id="([^"]+)"/.exec(g)?.[1];
  console.log(`--- ${String(i + 1).padStart(2, "0")} at ${r.ts} victim ${victim}`);
  for (const m of g.matchAll(/<process id="([^"]+)"([^>]*)>([\s\S]*?)<\/process>/g)) {
    const attrs = m[2]; const body = m[3];
    const a = (k) => new RegExp(`${k}="([^"]*)"`).exec(attrs)?.[1];
    const stmt = (/<frame [^>]*>([\s\S]*?)<\/frame>/.exec(body)?.[1] || /<inputbuf>([\s\S]*?)<\/inputbuf>/.exec(body)?.[1] || "").replace(/&#x0A;|&#x0D;|\s+/g, " ").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&").trim();
    console.log(`  ${m[1] === victim ? "VICTIM  " : "survivor"} spid ${a("spid")} iso ${a("isolationlevel")} lockMode ${a("lockMode")} waitresource ${a("waitresource")} trancount ${a("trancount")} tran ${a("transactionname")}`);
    console.log(`           ${stmt.slice(0, 260)}`);
  }
  for (const m of g.matchAll(/<(keylock|pagelock|ridlock|objectlock)[^>]*objectname="([^"]*)"[^>]*indexname="([^"]*)"[^>]*mode="([^"]*)"/g)) console.log(`  resource ${m[1]} ${m[2]} index ${m[3]} held-mode ${m[4]}`);
}
