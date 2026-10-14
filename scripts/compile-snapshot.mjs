// Compiles config/instrument-config.json (or a path given as the first argument) into the
// canonical instrument snapshot and prints its checksums and counts. With --write-golden it
// refreshes tests/golden/instrument-snapshot.golden.json, or the file --golden=<path> names (the
// 2026-10-14 revision keeps its own); with --print it writes the full canonical JSON to stdout
// instead of the summary.
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { compileSnapshot, normalizeConfig } from "./lib/snapshot.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const args = process.argv.slice(2);
const configPath = args.find((a) => !a.startsWith("--")) ?? path.join(root, "config", "instrument-config.json");
const config = JSON.parse(await fs.readFile(configPath, "utf8"));
const compiled = compileSnapshot(normalizeConfig(config));

if (args.includes("--print")) {
  process.stdout.write(compiled.canonicalJson);
} else {
  const summary = {
    configPath: path.relative(root, configPath),
    checksum: compiled.checksum,
    definitionsChecksum: compiled.definitionsChecksum,
    canonicalBytes: Buffer.byteLength(compiled.canonicalJson, "utf8"),
    counts: compiled.counts,
  };
  if (args.includes("--write-golden")) {
    const named = args.find((a) => a.startsWith("--golden="));
    const goldenPath = named
      ? path.resolve(root, named.slice("--golden=".length))
      : path.join(root, "tests", "golden", "instrument-snapshot.golden.json");
    await fs.mkdir(path.dirname(goldenPath), { recursive: true });
    await fs.writeFile(goldenPath, `${JSON.stringify(summary, null, 2)}\n`, "utf8");
    summary.goldenWritten = path.relative(root, goldenPath);
  }
  console.log(JSON.stringify(summary, null, 2));
}
