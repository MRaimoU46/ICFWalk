// A8-03: a deadlock graph's input buffer is cut at about 1,000 characters, and the report's statement
// declares one parameter per reported item, so its buffer holds declarations only. Each graph's execution
// stack names the statement by sqlhandle and offsets; while SQL Server still caches it, this resolves the
// statement text (parameterized: no value is in it) and writes <dir>/statements.json.
//   node resolve-deadlock-statements.mjs <directory of deadlock-NN.xml>
import fs from "node:fs";
import path from "node:path";
const sql = (await import("/home/user/ICFWalk/node_modules/mssql/index.js")).default;
const { connectionConfig, loadRuntimeEnv } = await import("/home/user/ICFWalk/tests/node/helpers.mjs");
const dir = process.argv[2];
const pool = await new sql.ConnectionPool(connectionConfig(loadRuntimeEnv(), "master", true)).connect();
const out = [];
for (const file of fs.readdirSync(dir).filter((f) => /^deadlock-\d+\.xml$/.test(f)).sort()) {
  const g = fs.readFileSync(path.join(dir, file), "utf8");
  const victim = /<victimProcess id="([^"]+)"/.exec(g)[1];
  for (const m of g.matchAll(/<process id="([^"]+)"([\s\S]*?)<\/process>/g)) {
    const f = /<frame procname="adhoc"[^>]*stmtstart="(\d+)"[^>]*stmtend="(-?\d+)"[^>]*sqlhandle="(0x[0-9a-f]+)"/.exec(m[2]);
    if (!f) continue;
    const r = await pool.request().input("h", sql.VarBinary, Buffer.from(f[3].slice(2), "hex")).input("s", sql.Int, Number(f[1])).input("e", sql.Int, Number(f[2]))
      .query("SELECT SUBSTRING(st.text, @s / 2 + 1, CASE WHEN @e = -1 THEN 8000 ELSE (@e - @s) / 2 + 1 END) AS t FROM sys.dm_exec_sql_text(@h) st");
    const text = r.recordset[0]?.t ? r.recordset[0].t.replace(/\s+/g, " ").replace(/#icf_r[pu]_[0-9A-F]{32}/g, "#icf_rp_<population>").trim() : null;
    out.push({ file, process: m[1], role: m[1] === victim ? "victim" : "survivor", statement: text ? text.slice(0, 400) : "<no longer in SQL Server's plan cache>" });
  }
}
await pool.close();
fs.writeFileSync(path.join(dir, "statements.json"), `${JSON.stringify(out, null, 2)}\n`);
for (const o of out) console.log(`${o.file} ${o.role}: ${o.statement.slice(0, 160)}`);
