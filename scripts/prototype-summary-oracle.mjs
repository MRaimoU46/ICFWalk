/**
 * Prototype oracle for the Phase 5 summary vectors.
 *
 * Loads source/current-prototype.html in Chromium, rebuilds each vector's working state in the
 * prototype's own shape, and runs the prototype's buildSummaryText() / generateEmailDraftFor()
 * against it. The output is diffed line by line against tests/fixtures/summary-vectors.json.
 *
 * The prototype is source 1 in the governing precedence, so this is what makes the vectors
 * reviewable rather than self-certifying: every remaining difference must be one of the deviations
 * recorded in docs/PHASE_5_IMPLEMENTATION_BRIEF.md section 14, which are classified below.
 * Anything the classifier cannot account for is reported as UNEXPLAINED and exits non-zero.
 *
 *   node scripts/prototype-summary-oracle.mjs            # summary of differences per vector
 *   node scripts/prototype-summary-oracle.mjs --verbose  # every differing line
 *
 * Tooling, not a test: `npm test` does not run it (it needs a browser and the prototype file).
 */
import fs from "node:fs";
import path from "node:path";
import { chromium } from "playwright";
import { root } from "../tests/node/helpers.mjs";

const verbose = process.argv.includes("--verbose");
const vectors = JSON.parse(fs.readFileSync(path.join(root, "tests", "fixtures", "summary-vectors.json"), "utf8"));
// The prototype keys a walk by its own ids; the render model keys it by dimension code and item
// key. These maps are the translation, and they exist only in this script.
const CONDITIONAL_BUCKETS = {
  prek_k: { bucket: "prekK", prefix: "prek_k_", ids: ["q1", "q2", "q3"] },
  dual_language: { bucket: "dualLang", prefix: "dual_language_", ids: ["q1", "q2", "q3"] },
  mac_prep: { bucket: "macPrer", prefix: "mac_prep_", ids: ["q1", "q2", "q3"] },
  ignite: { bucket: "ignite", prefix: "ignite_", ids: ["q1", "q2", "q3"] },
  avid: { bucket: "avid", prefix: "avid_", ids: ["q1", "q2", "q3"] },
  esl: { bucket: "esl", prefix: "esl_", ids: ["q1", "q2", "q3"] },
  content_area: { bucket: "contentArea", prefix: "content_area_", ids: ["q1", "q2", "q3", "q4", "q5"] },
};

/**
 * Longest-common-subsequence alignment, so a line the export deliberately omits shows up as one
 * removal instead of cascading through every line after it.
 */
function alignedOps(expected, actual) {
  const a = expected.split("\n");
  const b = actual.split("\n");
  const n = a.length;
  const m = b.length;
  const lcs = Array.from({ length: n + 1 }, () => new Uint32Array(m + 1));
  for (let i = n - 1; i >= 0; i--) {
    for (let j = m - 1; j >= 0; j--) {
      lcs[i][j] = a[i] === b[j] ? lcs[i + 1][j + 1] + 1 : Math.max(lcs[i + 1][j], lcs[i][j + 1]);
    }
  }
  const ops = [];
  let i = 0;
  let j = 0;
  while (i < n && j < m) {
    if (a[i] === b[j]) {
      ops.push({ kind: "same", vector: a[i], oracle: b[j], at: i + 1 });
      i++;
      j++;
    } else if (lcs[i + 1][j] >= lcs[i][j + 1]) {
      ops.push({ kind: "vectorOnly", vector: a[i], at: i + 1 });
      i++;
    } else {
      ops.push({ kind: "oracleOnly", oracle: b[j], at: i + 1 });
      j++;
    }
  }
  while (i < n) ops.push({ kind: "vectorOnly", vector: a[i], at: ++i });
  while (j < m) ops.push({ kind: "oracleOnly", oracle: b[j++], at: i + 1 });
  return ops;
}

const isHeading = (line) => Boolean(line) && line === line.toUpperCase() && /[A-Z]/.test(line);

/**
 * Classifies each difference against the deviations docs/PHASE_5_IMPLEMENTATION_BRIEF.md section 14
 * already resolved. Anything left over is a formatter bug, not a vector to bless.
 *
 * Differences are grouped into maximal runs first and the two sides of a run are zipped, because a
 * single block can carry two deviations at once: the content-area card differs in its heading
 * (14.3) and in every yes/no value (14.5), which leaves the alignment no common line to pair on.
 */
function classifyOps(ops) {
  const findings = [];
  for (let k = 0; k < ops.length; ) {
    if (ops[k].kind === "same") {
      k++;
      continue;
    }
    let end = k;
    while (end < ops.length && ops[end].kind !== "same") end++;
    const run = ops.slice(k, end);
    const vectorLines = run.filter((o) => o.kind === "vectorOnly");
    const oracleLines = run.filter((o) => o.kind === "oracleOnly");
    const paired = Math.min(vectorLines.length, oracleLines.length);

    for (let i = 0; i < paired; i++) {
      const vector = vectorLines[i].vector;
      const oracle = oracleLines[i].oracle;
      let reason = null;
      // 14.4: the prototype doubles the colon of a label that already ends in one.
      if (oracle.startsWith("Visit occurred at the::") && vector.startsWith("Visit occurred at the:")) {
        reason = "14.4 trailing-colon label";
      } else if (oracle.replace(/\[yes\]/g, "[Yes]").replace(/\[no\]/g, "[No]") === vector) {
        // 14.5: the prototype prints the raw yes/no code where the pills show a label.
        reason = "14.5 yes/no option label";
      } else if (/ CLASSROOM$/.test(oracle) && isHeading(vector)) {
        // 14.3: the prototype builds the content-area heading from the content value.
        reason = "14.3 content-area heading";
      }
      findings.push({ at: vectorLines[i].at, reason, vector, oracle });
    }

    // Lines only the prototype prints: a value the export drops because the instrument hides it.
    for (let i = paired; i < oracleLines.length; i++) {
      const oracle = oracleLines[i].oracle;
      if (oracle === "" && oracleLines[i + 1] && isHeading(oracleLines[i + 1].oracle)) {
        findings.push({ at: oracleLines[i].at, reason: "14.2 hidden section excluded", vector: "", oracle: oracleLines[i + 1].oracle });
        i = oracleLines.length; // the whole remaining run belongs to that hidden section
        continue;
      }
      if (/^[^:]+: /.test(oracle)) {
        findings.push({ at: oracleLines[i].at, reason: "14.2 hidden dimension excluded", vector: "", oracle });
        continue;
      }
      findings.push({ at: oracleLines[i].at, reason: null, vector: "", oracle });
    }
    // Lines only the export prints have no recorded deviation: always a finding.
    for (let i = paired; i < vectorLines.length; i++) {
      findings.push({ at: vectorLines[i].at, reason: null, vector: vectorLines[i].vector, oracle: "" });
    }
    k = end;
  }
  return findings;
}

/**
 * Builds the prototype walk for a vector. Option labels, not codes, are what the prototype stores
 * for its meta fields and Part 1 answers, so the vector's stored codes are translated through the
 * prototype's own option lists inside the page.
 */
function protoWalkFor(state) {
  const dims = state.dimensions || {};
  const responses = state.responses || {};
  const dim = (code) => dims[code] || {};
  const val = (code) => {
    const v = dim(code);
    return v.selectedValueCode || v.textValue || v.dateValue || "";
  };
  const stored = (key) => (responses[key] || {}).storedCode || "";
  const text = (key) => (responses[key] || {}).textValue || "";

  const conditional = {};
  for (const cfg of Object.values(CONDITIONAL_BUCKETS)) {
    const bucket = { notes: text(`${cfg.prefix}notes`) };
    cfg.ids.forEach((id, i) => {
      bucket[`q${i + 1}`] = stored(`${cfg.prefix}${id}`);
    });
    conditional[cfg.bucket] = bucket;
  }

  return {
    meta: {
      date: val("date"),
      observer: val("observer"),
      school: dim("school").selectedValueCode || "",
      school_other: dim("school").otherText || "",
      grade: dim("grade").selectedValueCode || "",
      content: dim("content").selectedValueCode || "",
      content_other: dim("content").otherText || "",
      period: dim("period").selectedValueCode || "",
      period_other: dim("period").otherText || "",
      classType: dim("classType").selectedValueCode || "",
      classType_other: dim("classType").otherText || "",
      visitTiming: dim("visitTiming").selectedValueCode || "",
      topic: val("topic"),
      tag: val("tag"),
    },
    part1: { p1q1: stored("p1q1"), p1q2: stored("p1q2"), p1q3: stored("p1q3") },
    part1Sections: {
      adopted: {
        pacing: stored("part1_adopted_pacing"),
        ac1: stored("part1_adopted_ac1"),
        ac2: stored("part1_adopted_ac2"),
        notes: text("part1_adopted_notes"),
      },
      targetTask: {
        tt1: stored("part1_targettask_tt1"),
        tt2: stored("part1_targettask_tt2"),
        notes: text("part1_targettask_notes"),
      },
    },
    part1Notes: "",
    components: Object.fromEntries(
      ["s1", "s2", "s3", "s4", "s5", "s6", "s7"].map((id) => [
        id,
        {
          applicable:
            stored(`comp_${id}_applicable`) === "yes" ? true : stored(`comp_${id}_applicable`) === "no" ? false : null,
          ratings: [stored(`comp_${id}_q1`), stored(`comp_${id}_q2`)],
          notes: text(`comp_${id}_notes`),
        },
      ]),
    ),
    belonging: {
      b1: stored("conditions_b1"),
      b2: stored("conditions_b2"),
      b3: stored("conditions_b3"),
      b4: stored("conditions_b4"),
      b5: stored("conditions_b5"),
      b6: stored("conditions_b6"),
      notes: text("conditions_notes"),
    },
    summaryStrengths: text("summary_strengths"),
    summaryGrowth: text("summary_growth"),
    ...conditional,
  };
}

/**
 * The prototype wraps its whole application in an IIFE, so buildSummaryText and its data tables are
 * private to that closure. The page is loaded first (the wire-up at the end of the script needs the
 * real DOM), then the same script body is injected once more with the outer wrapper removed, which
 * publishes the functions on window without editing the source file.
 */
function unwrappedPrototypeScript(html) {
  const open = html.indexOf("<script>");
  const close = html.lastIndexOf("<\/script>");
  if (open < 0 || close < 0) throw new Error("current-prototype.html has no inline script.");
  let body = html.slice(open + "<script>".length, close);
  const head = body.indexOf("(function(){");
  const tail = body.lastIndexOf("})();");
  if (head < 0 || tail < 0) throw new Error("current-prototype.html is not wrapped in the expected IIFE.");
  body = body.slice(head + "(function(){".length, tail);
  // `current` is a lexical binding of the script, so it never appears on window; the epilogue is the
  // only way to drive the prototype's own state without editing source/current-prototype.html.
  return body + "\n;window.__setCurrent = function (w) { current = w; };\n";
}

const prototypeHtml = fs.readFileSync(path.join(root, "source", "current-prototype.html"), "utf8");
const browser = await chromium.launch();
const page = await browser.newPage();
const pageErrors = [];
page.on("pageerror", (e) => pageErrors.push(String(e)));
await page.goto(`file://${path.join(root, "source", "current-prototype.html")}`);
await page.addScriptTag({ content: unwrappedPrototypeScript(prototypeHtml) });
await page.waitForFunction(() => typeof window.buildSummaryText === "function" && typeof window.__setCurrent === "function");

let unexplained = 0;
for (const vector of vectors.vectors) {
  const walk = protoWalkFor(vector.state);
  const result = await page.evaluate(
    ({ walk, keySets }) => {
      // Translate the codes the render model stores into the labels the prototype stores.
      const label = (options, code) => {
        if (!code) return "";
        const hit = (options || []).find((o) => (typeof o === "string" ? o : o.value) === code);
        if (!hit) return code;
        return typeof hit === "string" ? hit : hit.label;
      };
      const byCode = (list, code) => {
        if (!code) return "";
        const hit = (list || []).find((x) => x.toLowerCase().replace(/[^a-z0-9]+/g, "_") === code);
        return hit || code;
      };
      const w = blankWalk();
      Object.assign(w, JSON.parse(JSON.stringify(walk)));
      w.meta.school = byCode(SCHOOL_OPTIONS, walk.meta.school) || "";
      if (walk.meta.school === "other") w.meta.school = "Other";
      w.meta.grade = byCode(GRADE_OPTIONS, walk.meta.grade) || "";
      w.meta.content = byCode(CONTENT_OPTIONS, walk.meta.content) || "";
      if (walk.meta.content === "other") w.meta.content = "Other";
      w.meta.period = byCode(PERIOD_OPTIONS, walk.meta.period) || "";
      w.meta.classType = byCode(CLASS_TYPE_OPTIONS, walk.meta.classType) || "";
      if (walk.meta.classType === "other") w.meta.classType = "Other";
      w.meta.visitTiming = byCode(VISIT_TIMING_OPTIONS, walk.meta.visitTiming) || "";
      w.part1.p1q1 = label(PART1[0] && PART1[0].options, walk.part1.p1q1) || walk.part1.p1q1;
      w.part1.p1q2 = walk.part1.p1q2;
      w.part1.p1q3 = walk.part1.p1q3;
      window.__setCurrent(w);
      const emails = {};
      for (const keys of keySets) emails[keys.join(",")] = generateEmailDraftFor(keys);
      return { summaryText: buildSummaryText(), emails };
    },
    { walk, keySets: Object.keys(vector.expected.emails).map((k) => (k ? k.split(",") : [])) },
  );

  const diffs = classifyOps(alignedOps(vector.expected.summaryText, result.summaryText));
  const bad = diffs.filter((d) => !d.reason);
  unexplained += bad.length;
  const reasons = {};
  for (const d of diffs) reasons[d.reason || "UNEXPLAINED"] = (reasons[d.reason || "UNEXPLAINED"] || 0) + 1;
  console.log(
    `${bad.length ? "FAIL" : "ok  "}  ${vector.name}: ${diffs.length} difference(s) ` +
      (diffs.length ? JSON.stringify(reasons) : ""),
  );
  if (verbose || bad.length) {
    for (const d of diffs) {
      if (!verbose && d.reason) continue;
      console.log(`    line ${d.at} [${d.reason || "UNEXPLAINED"}]`);
      console.log(`      vector: ${JSON.stringify(d.vector)}`);
      console.log(`      oracle: ${JSON.stringify(d.oracle)}`);
    }
  }

  // The email draft has no documented deviation: the prototype's template sentences are the
  // contract, so every generated draft must match the oracle exactly.
  for (const [key, expected] of Object.entries(vector.expected.emails)) {
    const actual = result.emails[key];
    for (const field of ["subject", "body"]) {
      if (actual && actual[field] === expected[field]) continue;
      unexplained++;
      console.log(`    FAIL email[${key}].${field}`);
      console.log(`      vector: ${JSON.stringify(expected[field])}`);
      console.log(`      oracle: ${JSON.stringify(actual ? actual[field] : null)}`);
    }
  }
}

if (pageErrors.length) {
  console.error("prototype page errors:", pageErrors);
  unexplained += pageErrors.length;
}
await browser.close();
console.log(unexplained ? `\n${unexplained} UNEXPLAINED difference(s).` : "\nEvery difference is a recorded Phase 5 deviation.");
process.exitCode = unexplained ? 1 : 0;
