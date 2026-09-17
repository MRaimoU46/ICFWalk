// Seeds (imports) the current aligned instrument configuration as a DRAFT version through the
// running application's maintenance endpoint. Idempotent: re-running updates the same DRAFT.
//
//   ICFWALK_MAINTENANCE_TOKEN=... node scripts/seed-instrument.mjs [--base-url http://127.0.0.1:8888] [--file instrument-config.json]
import { api, loadRuntimeEnv } from "../tests/node/helpers.mjs";

const args = process.argv.slice(2);
const env = loadRuntimeEnv();
if (args.includes("--base-url")) env.ICFWALK_BASE_URL = args[args.indexOf("--base-url") + 1];
const token = env.ICFWALK_MAINTENANCE_TOKEN;
if (!token) {
  console.error("ICFWALK_MAINTENANCE_TOKEN is required (environment or .env).");
  process.exit(2);
}
const body = {};
if (args.includes("--file")) body.configFile = args[args.indexOf("--file") + 1];

const result = await api(env, "POST", "/api/maintenance/instrument/import", { body, token });
if (result.status !== 200 && result.status !== 201) {
  console.error(JSON.stringify({ status: result.status, response: result.json ?? result.text }, null, 2));
  process.exit(1);
}
const r = result.json;
console.log(JSON.stringify({
  status: result.status,
  created: r.created,
  versionId: r.versionId,
  versionLabel: r.versionLabel,
  versionStatus: r.status,
  checksum: r.checksum,
  definitionsChecksum: r.definitionsChecksum,
  counts: r.counts,
  warningCount: r.warnings.length,
  placeholderCount: r.placeholders.length,
  elapsedMs: r.elapsedMs,
}, null, 2));
