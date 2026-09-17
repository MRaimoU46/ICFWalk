// Applies database/001_schema.sql, 002_alignment_patch.sql, and 003_walk_mutation.sql to a SQL Server database
// using the ICFWALK_DB_* environment (or <repo>/.env, or .runtime/mssql.env for the local
// container). Prints each script's result set. Exit code 1 on any failure.
//
//   node scripts/db/apply-schema.mjs                 apply all scripts in order to ICFWALK_DB_NAME
//   node scripts/db/apply-schema.mjs --only 002      apply one script
//   node scripts/db/apply-schema.mjs --database x    override the database name
import { applyScript, connectionConfig, loadRuntimeEnv, readScript } from "../../tests/node/helpers.mjs";
import sql from "mssql";

const args = process.argv.slice(2);
const only = args.includes("--only") ? args[args.indexOf("--only") + 1] : "";
const database = args.includes("--database") ? args[args.indexOf("--database") + 1] : "";

const env = loadRuntimeEnv();
const config = connectionConfig(env, database || env.ICFWALK_DB_NAME || "icfwalk_dev");
const pool = await sql.connect(config);
try {
  for (const name of ["001_schema.sql", "002_alignment_patch.sql", "003_walk_mutation.sql"]) {
    if (only && !name.startsWith(only)) continue;
    const result = await applyScript(pool, readScript(name));
    console.log(JSON.stringify({ script: name, database: config.database, ok: result.ok, resultSet: result.recordset, error: result.error?.message ?? null, errorNumber: result.error?.number ?? null }, null, 2));
    if (!result.ok) process.exitCode = 1;
  }
} finally {
  await pool.close();
}
