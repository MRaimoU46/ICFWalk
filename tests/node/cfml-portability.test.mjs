// Phase 8 hardening (defect P8-02): the CFML must compile on Adobe ColdFusion 2023, the target engine.
//
// Until Phase 8 the application had only ever run on Lucee, which accepts several constructs Adobe
// ColdFusion 2023 refuses at compile time. Run on ColdFusion 2023 (Update 25, Adobe's own container
// image, through tools/runtime/acf-up.sh), the frozen code did not start at all: Application.cfc did
// not compile, and ColdFusion's cfcompile refused eight application templates and three test specs
// for the first four reasons below. The fifth and sixth compile, and then go wrong at run time.
//
// This file is the standing guard for those six constructs, so a change made and tested on Lucee
// cannot bring them back. It reads the source and needs neither engine. It does not replace the
// authority, which is ColdFusion itself: tools/runtime/acf-up.sh and cfcompile. Each rule was
// established against ColdFusion 2023's own compiler with minimal components before it was written:
//
//   1. A reserved word is not a variable name. ColdFusion rejects `var eq`, `var import` and 27 other
//      words (the operators, and keywords such as `default`, `final`, `interface`); Lucee accepts them.
//   2. A function does not declare a local variable with the name of one of its own arguments
//      (`var principal = arguments.principal`): ColdFusion refuses the template ("X is already
//      defined in argument scope"). A closure inside it is a different function and may.
//   3. A component's own function is not called unscoped under a name ColdFusion resolves first.
//      `evaluateCondition` (a public method of the page class) and `release` (inherited from the JSP
//      page) are resolved to ColdFusion's own methods, so the call is refused ("Parameter validation
//      error") or, with a matching signature, would silently call something else. The names are
//      tests/fixtures/acf2023-reserved-function-names.txt.
//   4. The true branch of a conditional is not a one-element array holding a string literal
//      (`c ? ["A"] : []`): ColdFusion's parser refuses it ("Invalid CFML construct"), while
//      `c ? [x] : []` and `c ? ["A", "B"] : []` compile.
//   5. CFML source is ASCII. ColdFusion reads a template without a byte-order mark in the JVM's
//      default charset, so a literal `·` became two replacement characters where that default
//      is ASCII; it compiles, and is wrong. Lucee reads UTF-8.
//   6. isNull() is given a variable path. ColdFusion evaluates a bracket expression followed by a
//      member (`isNull(x["k"].m)`) and throws when the member holds null; Lucee answers true.
//   7. The application does not ask isNull() about a value (defect P8-08). ColdFusion 2023's isNull()
//      is also true for a STRING whose value is "null" in any letter case -- parsed from a request,
//      read from a struct, passed as an argument -- so every such guard took a person named Null, a
//      note saying "null" or an org unit called NULL for a missing value; Lucee answers false. A
//      real null is asked with structKeyExists (false on both engines for a null-valued key, a null
//      or omitted argument, and a null local) or arrayIsDefined. The one exception is a query cell
//      (`q.col[r]`): SQL NULL reads back as "" on both engines and the quirk does not reach it.
//
// Two more differences are settings, not constructs, and are not linted: Application.cfc sets
// `this.passArrayByReference` (ColdFusion otherwise copies an array passed to a function, and the
// code sorts and fills arrays through arguments), and Db.run returns an empty query for a statement
// with no result set (ColdFusion returns nothing).
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { root } from "./helpers.mjs";

const RESERVED_WORDS = ["abstract", "and", "case", "contains", "default", "eq", "equal", "eqv", "false", "final", "function",
  "ge", "gt", "gte", "imp", "import", "interface", "is", "le", "lt", "lte", "mod", "neq", "not", "or", "return", "switch", "true", "xor"];

function cfmlFiles() {
  const out = [];
  const walk = (dir) => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const p = path.join(dir, entry.name);
      if (entry.isDirectory()) { if (entry.name !== "WEB-INF") walk(p); } else if (/\.(cfc|cfm)$/i.test(entry.name)) out.push(p);
    }
  };
  for (const d of ["app", "src", "tests/cfml"]) walk(path.join(root, d));
  return out.sort();
}

/** The text with every comment and string literal replaced by spaces, offsets preserved. */
function mask(text) {
  let out = "";
  let i = 0;
  while (i < text.length) {
    const c = text[i];
    const next = text[i + 1];
    if (c === "/" && next === "/") { while (i < text.length && text[i] !== "\n") { out += " "; i++; } continue; }
    if (c === "/" && next === "*") { const end = text.indexOf("*/", i + 2); const stop = end < 0 ? text.length : end + 2; out += text.slice(i, stop).replace(/[^\n]/g, " "); i = stop; continue; }
    if (c === "\"" || c === "'") {
      let j = i + 1;
      while (j < text.length) { if (text[j] === c) { if (text[j + 1] === c) { j += 2; continue; } break; } j++; }
      out += c + text.slice(i + 1, j).replace(/[^\n]/g, " ") + (j < text.length ? c : "");
      i = j + 1;
      continue;
    }
    out += c;
    i++;
  }
  return out;
}

/** Index of the bracket that closes the one at `open` in masked text. */
function closing(masked, open) {
  const pair = { "(": ")", "{": "}", "[": "]" }[masked[open]];
  let depth = 0;
  for (let i = open; i < masked.length; i++) {
    if (masked[i] === masked[open]) depth++;
    else if (masked[i] === pair && --depth === 0) return i;
  }
  return -1;
}

const lineOf = (text, index) => text.slice(0, index).split("\n").length;
const files = cfmlFiles().map((p) => { const text = fs.readFileSync(p, "utf8"); return { rel: path.relative(root, p), text, masked: mask(text) }; });

test("rule 1: no reserved word is a variable name", () => {
  const words = RESERVED_WORDS.join("|");
  const found = [];
  for (const f of files) {
    for (const m of f.masked.matchAll(new RegExp(`\\bvar\\s+(${words})\\b(?!\\s*\\()`, "gi"))) found.push(`${f.rel}:${lineOf(f.text, m.index)} var ${m[1]}`);
  }
  assert.deepEqual(found, []);
});

test("rule 2: no function re-declares one of its own arguments", () => {
  const found = [];
  for (const f of files) {
    for (const m of f.masked.matchAll(/\bfunction\s+(\w+)\s*\(/g)) {
      const paramsOpen = m.index + m[0].length - 1;
      const paramsClose = closing(f.masked, paramsOpen);
      const bodyOpen = f.masked.indexOf("{", paramsClose);
      const bodyClose = closing(f.masked, bodyOpen);
      if (paramsClose < 0 || bodyOpen < 0 || bodyClose < 0) continue;
      const params = new Set();
      for (const p of f.masked.slice(paramsOpen + 1, paramsClose).split(",")) {
        const name = p.replace(/=.*$/s, "").trim().split(/\s+/).pop();
        if (name) params.add(name.toLowerCase());
      }
      // Closures inside the body are functions of their own: blank them out.
      let body = f.masked.slice(bodyOpen + 1, bodyClose);
      for (let k = body.search(/\bfunction\s*\(/); k >= 0; k = body.search(/\bfunction\s*\(/)) {
        const po = body.indexOf("(", k); const pc = closing(body, po); const bo = body.indexOf("{", pc); const bc = closing(body, bo);
        if (pc < 0 || bo < 0 || bc < 0) break;
        body = body.slice(0, k) + " ".repeat(bc + 1 - k) + body.slice(bc + 1);
      }
      for (const v of body.matchAll(/\bvar\s+(\w+)/g)) {
        if (params.has(v[1].toLowerCase())) found.push(`${f.rel}:${lineOf(f.text, bodyOpen + 1 + v.index)} ${m[1]}() re-declares its argument ${v[1]}`);
      }
    }
  }
  assert.deepEqual(found, []);
});

test("rule 3: no component function is called unscoped under a name ColdFusion 2023 resolves first", () => {
  const reserved = new Set(fs.readFileSync(path.join(root, "tests", "fixtures", "acf2023-reserved-function-names.txt"), "utf8")
    .split(/\r?\n/).map((l) => l.trim()).filter((l) => l && !l.startsWith("#")));
  assert.ok(reserved.has("evaluatecondition") && reserved.has("release") && reserved.size > 800, "the reserved-name list is present");
  const defined = new Set();
  for (const f of files) for (const m of f.masked.matchAll(/\bfunction\s+(\w+)\s*\(/g)) defined.add(m[1].toLowerCase());
  const colliding = [...defined].filter((n) => reserved.has(n));
  const found = [];
  for (const f of files) {
    for (const m of f.masked.matchAll(/(?<![.\w$])(\w+)\s*\(/g)) {
      const name = m[1].toLowerCase();
      if (!colliding.includes(name)) continue;
      if (/\bfunction\s+$/.test(f.masked.slice(Math.max(0, m.index - 20), m.index))) continue;
      found.push(`${f.rel}:${lineOf(f.text, m.index)} unscoped call to ${m[1]}()`);
    }
  }
  assert.deepEqual(found, []);
});

test("rule 4: no conditional's true branch is a one-element array of a string literal", () => {
  const found = [];
  for (const f of files) {
    for (const m of f.text.matchAll(/\?\s*\(?\s*\[\s*("(?:[^"]|"")*"|'(?:[^']|'')*')\s*\]\s*\)?\s*:/g)) {
      if (f.masked[m.index] !== "?") continue; // inside a string or a comment
      found.push(`${f.rel}:${lineOf(f.text, m.index)} ${m[0]}`);
    }
  }
  assert.deepEqual(found, []);
});

test("rule 5: CFML source is ASCII, so no engine or platform default charset can change a literal", () => {
  // Adobe ColdFusion reads a template without a byte-order mark in the JVM's default charset: US-ASCII
  // in a container without a locale (where `·` in a literal became two U+FFFD), Cp1252 on a
  // typical Windows server. Lucee reads UTF-8. Text outside ASCII is written with chr().
  const found = [];
  for (const f of files) {
    const bad = f.text.search(/[^\x00-\x7F]/);
    if (bad >= 0) found.push(`${f.rel}:${lineOf(f.text, bad)} ${JSON.stringify(f.text.slice(bad, bad + 12))}`);
  }
  assert.deepEqual(found, []);
});

test("rule 6: isNull() tests a variable path, never a bracket expression followed by a member", () => {
  // ColdFusion evaluates `isNull(x["k"].field)` and `isNull(a.b[i].c)` and throws when the last member
  // holds null ("Element FIELD is undefined"); `var y = x["k"]; isNull(y.field)` is true on both engines.
  const found = [];
  for (const f of files) {
    for (const m of f.masked.matchAll(/\bisNull\(([^()]*\[[^\]]*\]\s*\.\s*[A-Za-z_]\w*)\s*\)/g)) found.push(`${f.rel}:${lineOf(f.text, m.index)} isNull(${m[1]})`);
  }
  assert.deepEqual(found, []);
});

test("rule 7: the application never asks isNull() about a value, only about a query cell", () => {
  const found = [];
  for (const f of files) {
    // Application.cfc's own two isNull() calls read an exception object's members (never a string),
    // where structKeyExists does not apply on ColdFusion; its environment lookups are covered by hand.
    if (!f.rel.startsWith(`src${path.sep}`)) continue;
    for (const m of f.masked.matchAll(/(?<![\w.])isNull\(([^()]*(?:\([^()]*\))?[^()]*)\)/g)) {
      if (/^\s*(arguments\.)?q\.\w+\[[^\]]+\]\s*$/.test(m[1])) continue;
      found.push(`${f.rel}:${lineOf(f.text, m.index)} isNull(${m[1]})`);
    }
  }
  assert.deepEqual(found, []);
});

test("the rules read every CFML template and component", () => {
  assert.ok(files.length >= 120, `read ${files.length} files`);
  assert.ok(files.some((f) => f.rel === path.join("app", "Application.cfc")));
});
