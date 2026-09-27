// Targeted CFML run with the exact code state stamped on it (Phase 8 correction A8, evidence tool).
//
// Prints what code the engine is running (HEAD, tree, working-tree status, SHA-256 of the named
// files), then runs one or more CFML specs through /api/maintenance/tests/run?filter=<spec> on
// ICFWALK_BASE_URL (default http://127.0.0.1:8888) and prints every case with its status and message.
// Exits 0 only when every case of every spec passed and none was skipped. Prints no secret.
//
//   node cfml-targeted.mjs <label> <Spec>[,<Spec>...] [file to hash ...]
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";
const repo = "/home/user/ICFWalk";
const { api, baseUrl, loadRuntimeEnv } = await import(path.join(repo, "tests/node/helpers.mjs"));
const [label, specs, ...files] = process.argv.slice(2);
const env = loadRuntimeEnv();
const git = (...a) => execFileSync("git", ["-C", repo, ...a], { encoding: "utf8" }).trimEnd();
console.log(`# ${label}`);
console.log(`# at ${new Date().toISOString()} against ${baseUrl(env)}`);
console.log(`# HEAD ${git("rev-parse", "HEAD")} tree ${git("rev-parse", "HEAD^{tree}")} branch ${git("branch", "--show-current")}`);
const status = git("status", "--porcelain=v1", "--untracked-files=all");
console.log(`# git status --porcelain=v1 --untracked-files=all:${status ? "\n" + status.split("\n").map((l) => `#   ${l}`).join("\n") : " <empty>"}`);
for (const f of files) {
  const p = path.join(repo, f);
  const sha = fs.existsSync(p) ? crypto.createHash("sha256").update(fs.readFileSync(p)).digest("hex") : "<absent>";
  let atHead = "<absent at HEAD>";
  try { atHead = crypto.createHash("sha256").update(execFileSync("git", ["-C", repo, "show", `HEAD:${f}`], { stdio: ["ignore", "pipe", "ignore"] })).digest("hex"); } catch { /* new file */ }
  console.log(`# sha256 ${sha}  ${f}  (at HEAD: ${atHead}${sha === atHead ? ", unchanged" : ""})`);
}
const health = await api(env, "GET", "/api/health");
console.log(`# health ${health.status} ${health.text}`);
let allPassed = true;
for (const spec of specs.split(",")) {
  const t0 = Date.now();
  const r = await api(env, "POST", `/api/maintenance/tests/run?filter=${encodeURIComponent(spec)}`, { token: env.ICFWALK_MAINTENANCE_TOKEN, timeoutMs: 600000 });
  const rep = r.json;
  if (!rep) { console.log(`${spec}: HTTP ${r.status} (no report) ${r.text.slice(0, 300)}`); allPassed = false; continue; }
  console.log(`engine=${rep.engine} http=${r.status} ok=${rep.ok} ${JSON.stringify(rep.totals)} wall=${((Date.now() - t0) / 1000).toFixed(1)}s`);
  for (const s of rep.specs) for (const c of s.cases) {
    console.log(`${s.name}.${c.name}: ${c.status}${c.message ? ` - ${c.message}` : ""}${c.at ? ` @ ${c.at.replace(/^.*\/(tests|src)\//, "$1/")}` : ""}`);
  }
  if (!rep.ok || rep.totals.failed || rep.totals.skipped || !rep.totals.passed) allPassed = false;
}
console.log(`# result: ${allPassed ? "ALL PASSED" : "NOT ALL PASSED"}`);
process.exit(allPassed ? 0 : 1);
