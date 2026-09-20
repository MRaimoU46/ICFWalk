/**
 * Regenerates tests/fixtures/summary-vectors.json, the parity contract between
 * app/assets/js/summary.js and src/walks/WalkSummaryFormatter.cfc (Phase 5).
 *
 * The render model comes from the running application (GET /api/instrument/current through a
 * throw-away fixture user), never from a local compilation, so the vectors pin the served
 * contract. Each state is normalized with the configured hidden-dimension policy first, so what a
 * vector stores is what the walk tables would actually hold after a save.
 *
 * Expectations are produced by the JavaScript formatter and must then be reviewed against the
 * prototype with scripts/prototype-summary-oracle.mjs: every difference has to be one of the
 * deviations recorded in docs/PHASE_5_IMPLEMENTATION_BRIEF.md section 14. Anything else is a bug
 * in the formatter, not a vector to bless.
 *
 *   node scripts/generate-summary-vectors.mjs            # rewrite the fixture
 *   node scripts/generate-summary-vectors.mjs --check    # fail if the fixture is stale
 *
 * This script is tooling, not a test; `npm test` does not run it.
 */
import fs from "node:fs";
import path from "node:path";
import { evaluate, normalize } from "../app/assets/js/rules.js";
import { averageText, emailDraft, fileName, sanitizeFileLabel, summaryText, SUMMARY_CONTRACT } from "../app/assets/js/summary.js";
import { baseUrl, loadRuntimeEnv, root } from "../tests/node/helpers.mjs";

const env = loadRuntimeEnv();
const token = env.ICFWALK_MAINTENANCE_TOKEN || "";
const tag = `sumvec-${Date.now().toString(36)}`;
const subject = `${tag}-walker`;
const target = path.join(root, "tests", "fixtures", "summary-vectors.json");
const check = process.argv.includes("--check");

const call = (p, body) =>
  fetch(`${baseUrl(env)}/index.cfm${p}`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-ICFWalk-Maintenance-Token": token },
    body: JSON.stringify(body),
  });

async function servedModel() {
  await call("/api/maintenance/org-units/import", {
    orgUnits: [{ code: `${tag}-district`, type: "DISTRICT", name: "Summary vector district", parentCode: null }],
  });
  await call("/api/maintenance/identity/provision-user", { subject, displayName: "Summary vector fixture" });
  await call("/api/maintenance/identity/assign-role", {
    subject,
    roleCode: "DISTRICT_WALK_REPORT",
    orgUnitCode: `${tag}-district`,
    includeDescendants: true,
  });
  const r = await fetch(`${baseUrl(env)}/index.cfm/api/instrument/current`, {
    headers: { "X-ICFWalk-Dev-Subject": subject, Accept: "application/json" },
  });
  const text = await r.text();
  if (r.status !== 200) throw new Error(`instrument/current ${r.status}: ${text}`);
  return JSON.parse(text);
}

const cleanup = () => call("/api/maintenance/identity/cleanup-fixtures", { tag });

// ---- the states under test -----------------------------------------------------------------------

const MARKUP = 'Line 1 <b>bold</b> & "quotes" <script>alert(1)</script>';

const st = (dimensions, responses) => ({ dimensions, responses });

/** Part 1 answered in full; shared by the vectors that are not about Part 1 being blank. */
const part1Full = {
  p1q1: { storedCode: "Partial" },
  p1q2: { storedCode: "Retrieval" },
  p1q3: { storedCode: "Analysis" },
  part1_adopted_pacing: { storedCode: "on" },
  part1_adopted_ac1: { storedCode: "3" },
  part1_adopted_ac2: { storedCode: "4" },
  part1_adopted_notes: { textValue: "Adopted curriculum in use throughout." },
  part1_targettask_tt1: { storedCode: "5" },
  part1_targettask_tt2: { storedCode: "2" },
  part1_targettask_notes: { textValue: "Task matched the target for most students." },
};

const conditionsFull = {
  conditions_b1: { storedCode: "4" },
  conditions_b2: { storedCode: "5" },
  conditions_b3: { storedCode: "4" },
  conditions_b4: { storedCode: "3" },
  conditions_b5: { storedCode: "5" },
  conditions_b6: { storedCode: "4" },
  conditions_notes: { textValue: "Warm, predictable routines." },
};

const EMAIL_KEY_SETS = [
  [],
  ["part1", "comp_s3", "belonging", "summary"],
  ["summary", "belonging", "comp_s3", "part1"],
  ["comp_s1"],
  ["part1", "comp_s1", "comp_s2", "comp_s3", "comp_s4", "comp_s5", "comp_s6", "comp_s7", "belonging", "summary"],
];

const CASES = [
  {
    name: "fully answered high school walk",
    walkId: "11111111-1111-4111-8111-111111111111",
    state: st(
      {
        date: { dateValue: "2026-09-17" },
        observer: { textValue: "Jane Doe" },
        school: { selectedValueCode: "elgin_high_school" },
        grade: { selectedValueCode: "9" },
        content: { selectedValueCode: "ela" },
        period: { selectedValueCode: "second" },
        classType: { selectedValueCode: "general_education" },
        visitTiming: { selectedValueCode: "beginning_of_lesson" },
        topic: { textValue: "RL.9-10.2" },
        tag: { textValue: "cohort B" },
      },
      {
        ...part1Full,
        comp_s1_q1: { storedCode: "4" },
        comp_s1_q2: { storedCode: "3" },
        comp_s1_notes: { textValue: "Students annotated a complex text." },
        // 2 and 3 -> 2.5, the half value the brief asks the vectors to pin.
        comp_s2_q1: { storedCode: "2" },
        comp_s2_q2: { storedCode: "3" },
        comp_s2_notes: { textValue: "Vocabulary was displayed but rarely used." },
        comp_s3_applicable: { storedCode: "yes" },
        comp_s3_q1: { storedCode: "5" },
        comp_s3_q2: { storedCode: "4" },
        comp_s3_notes: { textValue: "Mini-lesson, work time, and share time were all visible." },
        comp_s4_applicable: { storedCode: "yes" },
        comp_s4_q1: { storedCode: "3" },
        comp_s4_q2: { storedCode: "3" },
        comp_s4_notes: { textValue: "Roles were named but not held." },
        comp_s5_q1: { storedCode: "4" },
        comp_s5_q2: { storedCode: "5" },
        comp_s6_q1: { storedCode: "2" },
        comp_s6_q2: { storedCode: "1" },
        comp_s6_notes: { textValue: "Feedback was mostly evaluative." },
        comp_s7_q1: { storedCode: "5" },
        comp_s7_q2: { storedCode: "5" },
        comp_s7_notes: { textValue: "Scaffolds were in place for every group." },
        ...conditionsFull,
        summary_strengths: { textValue: "Every student had access to the grade-level text." },
        summary_growth: { textValue: "Move feedback from evaluative to actionable." },
      },
    ),
  },
  {
    name: "unanswered items",
    walkId: "22222222-2222-4222-8222-222222222222",
    state: st(
      {
        date: { dateValue: "2026-09-18" },
        school: { selectedValueCode: "abbott_middle_school" },
        grade: { selectedValueCode: "7" },
        classType: { selectedValueCode: "general_education" },
      },
      {
        p1q1: { storedCode: "No" },
        part1_adopted_ac1: { storedCode: "4" },
        comp_s1_q1: { storedCode: "2" },
        comp_s3_applicable: { storedCode: "no" },
        comp_s4_applicable: { storedCode: "no" },
        conditions_b1: { storedCode: "5" },
      },
    ),
  },
  {
    name: "workshop model no with notes",
    walkId: "33333333-3333-4333-8333-333333333333",
    state: st(
      {
        date: { dateValue: "2026-09-19" },
        observer: { textValue: "Sam Rivera" },
        school: { selectedValueCode: "elgin_high_school" },
        grade: { selectedValueCode: "11" },
        content: { selectedValueCode: "math" },
        classType: { selectedValueCode: "general_education" },
      },
      {
        ...part1Full,
        // Ratings are submitted but the component is not applicable: the engine clears them and the
        // export prints the not-part line with the retained notes (SUM-03, COND-12/13).
        comp_s3_applicable: { storedCode: "no" },
        comp_s3_q1: { storedCode: "5" },
        comp_s3_q2: { storedCode: "5" },
        comp_s3_notes: { textValue: "Not a workshop day; notes kept for the follow-up." },
        comp_s4_applicable: { storedCode: "no" },
        comp_s1_q1: { storedCode: "4" },
        comp_s1_q2: { storedCode: "4" },
        ...conditionsFull,
        summary_growth: { textValue: "Plan a workshop cycle for the next unit." },
      },
    ),
  },
  {
    name: "dual language answers retained while hidden",
    walkId: "44444444-4444-4444-8444-444444444444",
    state: st(
      {
        date: { dateValue: "2026-09-20" },
        observer: { textValue: "Dana Fox" },
        school: { selectedValueCode: "bartlett_elementary_school" },
        grade: { selectedValueCode: "2" },
        // The section was filled in while the class type was Dual Language and the class type has
        // since changed: the answers stay in the database and must not reach the export (SUM-04).
        classType: { selectedValueCode: "general_education" },
      },
      {
        dual_language_q1: { storedCode: "yes" },
        dual_language_q2: { storedCode: "no" },
        dual_language_notes: { textValue: "Bridge time was protected." },
        comp_s3_applicable: { storedCode: "no" },
        comp_s4_applicable: { storedCode: "no" },
        summary_strengths: { textValue: "Biliteracy routines are established." },
      },
    ),
  },
  {
    name: "period retained but hidden for an elementary grade",
    walkId: "55555555-5555-4555-8555-555555555555",
    state: st(
      {
        date: { dateValue: "2026-09-21" },
        school: { selectedValueCode: "bartlett_elementary_school" },
        grade: { selectedValueCode: "3" },
        // Entered while the grade was 6-12; Period is hidden for grade 3 and never exported.
        period: { selectedValueCode: "fourth" },
        classType: { selectedValueCode: "general_education" },
      },
      { comp_s3_applicable: { storedCode: "no" }, comp_s4_applicable: { storedCode: "no" } },
    ),
  },
  {
    name: "other school and other content with punctuation",
    walkId: "66666666-6666-4666-8666-666666666666",
    state: st(
      {
        date: { dateValue: "2026-09-17" },
        observer: { textValue: "R. O'Neil-Vega" },
        school: { selectedValueCode: "other", otherText: "Unlisted/Site?" },
        grade: { selectedValueCode: "9" },
        content: { selectedValueCode: "other", otherText: "Art & Design" },
        classType: { selectedValueCode: "other", otherText: "Co-taught" },
        visitTiming: { selectedValueCode: "end_of_the_lesson" },
      },
      { comp_s3_applicable: { storedCode: "no" }, comp_s4_applicable: { storedCode: "no" } },
    ),
  },
  {
    name: "content area music",
    walkId: "77777777-7777-4777-8777-777777777777",
    state: st(
      {
        date: { dateValue: "2026-09-22" },
        observer: { textValue: "Pat Lin" },
        school: { selectedValueCode: "elgin_high_school" },
        grade: { selectedValueCode: "10" },
        content: { selectedValueCode: "music" },
        // Both a content-sourced card and a classType-sourced card are visible, so this vector also
        // pins the conditional-card export order (brief 14.1).
        classType: { selectedValueCode: "esl" },
      },
      {
        content_area_q1: { storedCode: "yes" },
        content_area_q2: { storedCode: "no" },
        content_area_notes: { textValue: "Instruments were out and in use." },
        esl_q1: { storedCode: "yes" },
        esl_notes: { textValue: "Language objectives were posted." },
        comp_s3_applicable: { storedCode: "no" },
        comp_s4_applicable: { storedCode: "no" },
      },
    ),
  },
  {
    name: "markup in notes",
    walkId: "88888888-8888-4888-8888-888888888888",
    state: st(
      {
        date: { dateValue: "2026-09-23" },
        observer: { textValue: MARKUP },
        school: { selectedValueCode: "elgin_high_school" },
        grade: { selectedValueCode: "12" },
        classType: { selectedValueCode: "general_education" },
        topic: { textValue: MARKUP },
      },
      {
        part1_adopted_notes: { textValue: MARKUP },
        comp_s1_notes: { textValue: MARKUP },
        comp_s3_applicable: { storedCode: "no" },
        comp_s4_applicable: { storedCode: "no" },
        conditions_notes: { textValue: MARKUP },
        summary_strengths: { textValue: MARKUP },
        summary_growth: { textValue: MARKUP },
      },
    ),
  },
  {
    name: "blank new walk",
    walkId: "99999999-9999-4999-8999-999999999999",
    state: st({}, { comp_s3_applicable: { storedCode: "no" }, comp_s4_applicable: { storedCode: "no" } }),
  },
  {
    name: "no observer and nothing selected",
    walkId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
    state: st(
      {
        date: { dateValue: "2026-09-24" },
        school: { selectedValueCode: "elgin_high_school" },
        grade: { selectedValueCode: "9" },
        content: { selectedValueCode: "science" },
        classType: { selectedValueCode: "avid" },
      },
      {
        avid_q1: { storedCode: "yes" },
        avid_notes: { textValue: "WICOR strategies visible." },
        comp_s3_applicable: { storedCode: "no" },
        comp_s4_applicable: { storedCode: "no" },
        ...conditionsFull,
      },
    ),
  },
];

/** Parity of the one-decimal average with JavaScript toFixed(1) on the exact double quotient. */
const AVERAGE_CASES = [
  [0, 0],
  [3, 1],
  [7, 2],
  [9, 4],
  [5, 2],
  [61, 20],
  [89, 20],
  [1, 3],
  [2, 3],
  [10, 3],
  [25, 6],
  [1, 8],
  [15, 4],
];

/** SUM-05 sanitizer cases, asserted on the shared primitive rather than only through a file name. */
const FILE_LABELS = [
  "Unlisted/Site?",
  "Art & Design",
  "../../etc/passwd",
  "..\\..\\windows",
  'quote"and;semi',
  "already_safe-label",
  "  leading and trailing  ",
  "café résumé",
  "9_Art & Design_2026-09-17",
  "",
];

// ---- build ----------------------------------------------------------------------------------------

function build(payload) {
  const model = payload.model;
  const policies = payload.policies || { hiddenDimensionPolicy: "RETAIN_HIDDEN" };
  const vectors = CASES.map((c) => {
    // Store the state as the walk tables would hold it, so a vector can be replayed through a real
    // save and still describe the same walk.
    const state = normalize(model, c.state, policies).state;
    const evaluation = evaluate(model, state);
    const emails = {};
    for (const keys of EMAIL_KEY_SETS) emails[keys.join(",")] = emailDraft(model, state, evaluation, keys);
    return {
      name: c.name,
      walkId: c.walkId,
      state,
      expected: {
        summaryText: summaryText(model, state, evaluation),
        fileName: fileName(model, state, evaluation, c.walkId),
        emails,
      },
    };
  });
  return {
    format: "icfwalk-summary-vectors/1",
    contract: SUMMARY_CONTRACT,
    source: payload.version ? payload.version.checksum || payload.version.versionLabel || "" : "",
    policies,
    averages: AVERAGE_CASES.map(([sum, count]) => ({ sum, count, expected: averageText(sum, count) })),
    fileLabels: FILE_LABELS.map((label) => ({ label, expected: sanitizeFileLabel(label) })),
    vectors,
  };
}

const payload = await servedModel();
try {
  const next = JSON.stringify(build(payload), null, 2) + "\n";
  if (check) {
    const current = fs.existsSync(target) ? fs.readFileSync(target, "utf8") : "";
    if (current !== next) {
      console.error("summary-vectors.json is stale; run: node scripts/generate-summary-vectors.mjs");
      process.exitCode = 1;
    } else {
      console.log("summary-vectors.json is current.");
    }
  } else {
    fs.writeFileSync(target, next);
    console.log(`wrote ${target} (${JSON.parse(next).vectors.length} vectors)`);
  }
} finally {
  await cleanup();
}
