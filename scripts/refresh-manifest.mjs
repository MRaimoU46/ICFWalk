// Refreshes byte counts and SHA-256 values for files ALREADY listed in manifest.json.
// It never adds or removes entries: the manifest describes the supplied handoff package,
// and only supplied package files that were deliberately corrected (for example the
// validator script itself) should ever change. Run: node scripts/refresh-manifest.mjs
import crypto from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const manifestPath = path.join(root, "manifest.json");
const manifest = JSON.parse(await fs.readFile(manifestPath, "utf8"));
const changed = [];

for (const entry of manifest.files) {
  const bytes = await fs.readFile(path.join(root, entry.path));
  const sha256 = crypto.createHash("sha256").update(bytes).digest("hex");
  if (entry.sha256 !== sha256 || entry.bytes !== bytes.length) {
    changed.push({ path: entry.path, previousSha256: entry.sha256, sha256, previousBytes: entry.bytes, bytes: bytes.length });
    entry.sha256 = sha256;
    entry.bytes = bytes.length;
  }
}

await fs.writeFile(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`, "utf8");
console.log(JSON.stringify({ updated: changed }, null, 2));
