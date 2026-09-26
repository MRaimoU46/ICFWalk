// Phase 8: nothing in the SQL needs a SQL Server newer than 2016 (docs/VERIFICATION_CHECKLISTS.md,
// checklist 2).
//
// SQL Server 2016 is the oldest engine the product supports, and it cannot run here: Microsoft ships
// no Linux image of it, so every database run in this repository is SQL Server 2022, which accepts
// everything 2016 does and a good deal more. Running at compatibility level 130 would not close that
// gap either, because newer built-in functions stay available at every level. This file is the
// standing guard for what can be checked without the engine: no migration and no statement the
// application sends uses T-SQL that SQL Server 2016 (SP3) does not have. It reads the source only.
// Running the migrations and the suites on SQL Server 2016 itself remains checklist 2.
//
// Migrations are read with their comments and string literals masked. Application statements are the
// string literals of every component under src/ (Db.cfc is the only place SQL is executed, and every
// statement reaches it as a string), read whole, since each literal is SQL or text.
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { root } from "./helpers.mjs";

// Each entry: what it is, the first version that has it, and how to find it.
const NEWER = [
  ["STRING_AGG", "2017", /\bSTRING_AGG\s*\(/i],
  ["CONCAT_WS", "2017", /\bCONCAT_WS\s*\(/i],
  ["TRANSLATE", "2017", /\bTRANSLATE\s*\(/i],
  ["TRIM", "2017", /(?<![LR])\bTRIM\s*\(/i],
  ["graph tables (AS NODE / AS EDGE)", "2017", /\bAS\s+(NODE|EDGE)\b/i],
  ["APPROX_COUNT_DISTINCT", "2019", /\bAPPROX_COUNT_DISTINCT\s*\(/i],
  ["OPTIMIZE_FOR_SEQUENTIAL_KEY", "2019", /\bOPTIMIZE_FOR_SEQUENTIAL_KEY\b/i],
  ["UTF-8 collations", "2019", /_UTF8\b/i],
  ["resumable index operations", "2017", /\bRESUMABLE\s*=/i],
  ["GREATEST / LEAST", "2022", /\b(GREATEST|LEAST)\s*\(/i],
  ["GENERATE_SERIES", "2022", /\bGENERATE_SERIES\s*\(/i],
  ["DATE_BUCKET / DATETRUNC", "2022", /\b(DATE_BUCKET|DATETRUNC)\s*\(/i],
  ["JSON_OBJECT / JSON_ARRAY / JSON_PATH_EXISTS", "2022", /\b(JSON_OBJECT|JSON_ARRAY|JSON_PATH_EXISTS)\s*\(/i],
  ["IS [NOT] DISTINCT FROM", "2022", /\bIS\s+(NOT\s+)?DISTINCT\s+FROM\b/i],
  ["APPROX_PERCENTILE", "2022", /\bAPPROX_PERCENTILE_(CONT|DISC)\s*\(/i],
  ["bit manipulation functions", "2022", /\b(BIT_COUNT|LEFT_SHIFT|RIGHT_SHIFT|GET_BIT|SET_BIT)\s*\(/i],
  ["LTRIM / RTRIM with characters", "2022", /\b[LR]TRIM\s*\([^()]*,/i],
  ["STRING_SPLIT with an ordinal", "2022", /\bSTRING_SPLIT\s*\([^()]*,[^()]*,/i],
  ["the WINDOW clause", "2022", /\bWINDOW\s+\w+\s+AS\s*\(/i],
  ["ledger tables", "2022", /\bLEDGER\s*=/i],
];

/** SQL with comments and string literals replaced by spaces, offsets kept. */
function maskSql(text) {
  let out = "";
  let i = 0;
  while (i < text.length) {
    const c = text[i], n = text[i + 1];
    if (c === "-" && n === "-") { while (i < text.length && text[i] !== "\n") { out += " "; i++; } continue; }
    if (c === "/" && n === "*") { const end = text.indexOf("*/", i + 2); const stop = end < 0 ? text.length : end + 2; out += text.slice(i, stop).replace(/[^\n]/g, " "); i = stop; continue; }
    if (c === "'") { let j = i + 1; while (j < text.length) { if (text[j] === "'") { if (text[j + 1] === "'") { j += 2; continue; } break; } j++; } out += text.slice(i, j + 1).replace(/[^\n]/g, " "); i = j + 1; continue; }
    out += c; i++;
  }
  return out;
}

/** The double-quoted string literals of a CFML component ("" is an escaped quote). */
function cfmlStrings(text) {
  const out = [];
  let i = 0;
  while (i < text.length) {
    const c = text[i], n = text[i + 1];
    if (c === "/" && n === "/") { while (i < text.length && text[i] !== "\n") i++; continue; }
    if (c === "/" && n === "*") { const end = text.indexOf("*/", i + 2); i = end < 0 ? text.length : end + 2; continue; }
    if (c === "'") { let j = i + 1; while (j < text.length) { if (text[j] === "'") { if (text[j + 1] === "'") { j += 2; continue; } break; } j++; } out.push({ at: i, text: text.slice(i + 1, j) }); i = j + 1; continue; }
    if (c === "\"") { let j = i + 1; while (j < text.length) { if (text[j] === "\"") { if (text[j + 1] === "\"") { j += 2; continue; } break; } j++; } out.push({ at: i, text: text.slice(i + 1, j) }); i = j + 1; continue; }
    i++;
  }
  return out;
}

function cfcFiles(dir) {
  const out = [];
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) out.push(...cfcFiles(p)); else if (e.name.endsWith(".cfc")) out.push(p);
  }
  return out;
}

const lineOf = (text, index) => text.slice(0, index).split("\n").length;

test("SQL Server 2016: no migration uses T-SQL that SQL Server 2016 does not have", () => {
  const files = fs.readdirSync(path.join(root, "database")).filter((f) => /^\d{3}_.*\.sql$/.test(f)).sort();
  assert.deepEqual(files.map((f) => f.slice(0, 3)), ["001", "002", "003", "004", "005", "006", "007"], "every migration is read");
  const found = [];
  for (const f of files) {
    const text = fs.readFileSync(path.join(root, "database", f), "utf8");
    const masked = maskSql(text);
    for (const [what, since, re] of NEWER) {
      const g = new RegExp(re.source, re.flags.includes("g") ? re.flags : `${re.flags}g`);
      for (const m of masked.matchAll(g)) found.push(`database/${f}:${lineOf(text, m.index)} ${what} (SQL Server ${since})`);
    }
  }
  assert.deepEqual(found, []);
});

test("SQL Server 2016: no statement the application sends uses T-SQL that SQL Server 2016 does not have", () => {
  const found = [];
  let statements = 0;
  for (const file of cfcFiles(path.join(root, "src"))) {
    const text = fs.readFileSync(file, "utf8");
    for (const s of cfmlStrings(text)) {
      if (/\b(SELECT|INSERT|UPDATE|DELETE|MERGE|EXEC)\b/.test(s.text)) statements++;
      for (const [what, since, re] of NEWER) {
        if (re.test(s.text)) found.push(`${path.relative(root, file)}:${lineOf(text, s.at)} ${what} (SQL Server ${since})`);
      }
    }
  }
  assert.ok(statements >= 150, `the scan read the application's statements (${statements} literals with SQL verbs)`);
  assert.deepEqual(found, []);
});

test("SQL Server 2016: the scan finds what it looks for", () => {
  const sample = "SELECT STRING_AGG(x, ',') FROM t WHERE a IS NOT DISTINCT FROM b AND GREATEST(1, 2) = 2 -- STRING_AGG in a comment\n";
  const hits = NEWER.filter(([, , re]) => re.test(maskSql(sample))).map(([what]) => what);
  assert.deepEqual(hits, ["STRING_AGG", "GREATEST / LEAST", "IS [NOT] DISTINCT FROM"]);
  assert.deepEqual(NEWER.filter(([, , re]) => re.test(maskSql("SELECT LTRIM(RTRIM(name)) FROM t -- GREATEST(1)"))).map(([w]) => w), []);
  assert.deepEqual(cfmlStrings('var q = "SELECT CONCAT_WS(\'-\', a) FROM t"; // "TRIM(x)"').map((s) => s.text), ["SELECT CONCAT_WS('-', a) FROM t"]);
});
