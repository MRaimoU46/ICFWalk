// Phase 7: aggregate reporting at the HTTP boundary and in source.
//
// Static checks (no application needed): the report repository never names a narrative or
// identifying column, the report code carries no instrument content of its own, and the browser
// module never writes HTML from data.
//
// Live checks against the running application (development identity stub, real SQL Server):
// authentication (AUTH-01), role separation (AUTH-06 / RPT-03), organizational scope over HTTP
// (RPT-01 / RPT-02), exclusions in the payload and the export (RPT-06), the read-only contract, the
// CSV download contract, and injection payloads in every parameter (SEC-01).
//
// RPT-03 correction: report-only roles read frozen releases, never live figures. Every walk here is
// dated in one month no other suite uses (a random month in 1950-1974), and before() releases that
// month as someone who can open every walk, so the report-only checks read a real release over
// HTTP; live figures are checked as a district walk-and-report role. Fixtures, including the
// release, are created through the maintenance and report endpoints and removed afterwards. With
// ICFWALK_REQUIRE_APP=1 an unreachable application fails the run rather than skipping it.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { api, baseUrl, loadRuntimeEnv, provisionReleaser, releaseMonth, requireApp, root } from "./helpers.mjs";

const env = loadRuntimeEnv();
const token = env.ICFWALK_MAINTENANCE_TOKEN || "";
const tag = `httprpt-${Date.now().toString(36)}`;

const source = (rel) => fs.readFileSync(path.join(root, rel), "utf8");
/** CFML source with comments removed, so a check reads only what executes. */
const cfmlCode = (text) => text.replace(/\/\*[\s\S]*?\*\//g, "").replace(/(^|[^:"'])\/\/.*$/gm, "$1");
const jsCode = (text) => text.replace(/\/\*[\s\S]*?\*\//g, "").replace(/(^|[^:"'])\/\/.*$/gm, "$1");

// ---- static ------------------------------------------------------------------------------------

test("RPT-06 (structural): the report repository selects no narrative, identifying or teacher column", () => {
  const code = cfmlCode(source("src/reports/ReportRepository.cfc"));
  for (const forbidden of ["text_value", "teacher_identifier", "teacher_display_name", "teacher_email", "classroom_label", "owner_user_id",
    "void_reason", "app_user", "display_name", "identity_subject", "prior_snapshot_json", "result_json", "details_json", "walk_revision",
    "walk_mutation", "audit_event", "number_value", "date_value", "boolean_value", "email"]) {
    assert.ok(!code.toLowerCase().includes(forbidden), `ReportRepository must not reference ${forbidden}`);
  }
  // Every value reaches SQL as a named parameter; the only concatenations are the generated
  // placeholders, each computation's own temporary table names (server-generated and checked
  // against their exact pattern on every use), and the WHERE clause built from them.
  for (const line of code.split("\n").filter((l) => /queryExecute|db\.run|db\.scalar/.test(l))) {
    assert.doesNotMatch(line, /&\s*arguments\.(?!visibility|alias|params)/, `value concatenated into SQL: ${line.trim()}`);
  }
});

test("P7C-01 / P7C-02 (structural): report tables are connection-local, and release membership is never read out", () => {
  const code = cfmlCode(source("src/reports/ReportRepository.cfc"));
  // No fixed temporary table name, no "##" (a global table) anywhere: the one "#" is chr(35).
  assert.doesNotMatch(code, /icf_report_population|icf_report_units/, "no fixed, shared population table name");
  assert.doesNotMatch(code, /["']#/, "no temporary table name written as a CFML literal");
  assert.match(code, /variables\.LOCAL_TEMP = chr\(35\);/);
  // The membership is written, and consulted only to leave released walks out of a new release.
  const uses = [...code.matchAll(/[^\n]*report_release_walk[^\n]*/g)].map((m) => m[0].trim());
  assert.ok(uses.length >= 3, "membership is written and consulted");
  for (const use of uses) {
    assert.ok(/NOT EXISTS \(SELECT 1 FROM \[icf\]\.\[report_release_walk\] rw WHERE rw\.walk_id = w\.walk_id\)/.test(use) || /INSERT INTO \[icf\]\.\[report_release_walk\]/.test(use),
      `release membership is only written or used to exclude: ${use}`);
  }
  // And nothing in the service returns it.
  assert.doesNotMatch(cfmlCode(source("src/reports/ReportService.cfc")), /report_release_walk/);
});

test("reports are driven by the instrument, not by names written into the report code", () => {
  for (const file of ["src/reports/ReportRepository.cfc", "src/reports/ReportService.cfc", "app/assets/js/reports.js"]) {
    const code = file.endsWith(".js") ? jsCode(source(file)) : cfmlCode(source(file));
    for (const content of ["period", "grade", "workshop", "comp_s", "classtype", "visittiming", "dual_language", "part1", "part2", "part3"]) {
      assert.ok(!code.toLowerCase().includes(content), `${file} names instrument content "${content}"`);
    }
  }
});

test("SEC-02 (structural): the reports view builds its DOM without HTML strings", () => {
  const code = jsCode(source("app/assets/js/reports.js"));
  for (const sink of ["innerHTML", "outerHTML", "insertAdjacentHTML", "document.write", "eval(", "new Function"]) {
    assert.ok(!code.includes(sink), `reports.js must not use ${sink}`);
  }
});

// ---- live ----------------------------------------------------------------------------------------

async function reachable() {
  try {
    const r = await fetch(`${baseUrl(env)}/index.cfm/api/health`, { signal: AbortSignal.timeout(10000) });
    if (r.status !== 200) return false;
    const body = await r.json();
    return body.environment === "development" || body.environment === "test";
  } catch { return false; }
}
const up = await reachable();
if (requireApp(env) && !up) throw new Error(`ICFWALK_REQUIRE_APP is set but the application is not reachable in development mode at ${baseUrl(env)}`);
if (requireApp(env) && !token) throw new Error("ICFWALK_REQUIRE_APP is set but ICFWALK_MAINTENANCE_TOKEN is not");
const skip = !up ? `application not reachable in development mode at ${baseUrl(env)}` : !token ? "ICFWALK_MAINTENANCE_TOKEN not set" : false;

function jar() {
  const cookies = new Map();
  return {
    header() { return [...cookies.entries()].map(([k, v]) => `${k}=${v}`).join("; "); },
    absorb(response) {
      for (const line of (response.headers.getSetCookie ? response.headers.getSetCookie() : [])) {
        const [pair] = line.split(";");
        const eq = pair.indexOf("=");
        cookies.set(pair.slice(0, eq).trim(), pair.slice(eq + 1).trim());
      }
    },
  };
}

/** A signed-in browser-like client: cookie jar plus the session CSRF token from /api/me. */
async function client(subject) {
  const cookieJar = jar();
  let csrf = "";
  async function call(method, apiPath, body, { noIdentity = false, noCsrf = false } = {}) {
    const headers = { Accept: "application/json" };
    if (!noIdentity) headers["X-ICFWalk-Dev-Subject"] = subject;
    if (body !== undefined) headers["Content-Type"] = "application/json";
    if (csrf && !noCsrf) headers["X-ICFWalk-CSRF-Token"] = csrf;
    if (cookieJar.header() && !noIdentity) headers.Cookie = cookieJar.header();
    const response = await fetch(`${baseUrl(env)}/index.cfm${apiPath}`, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
    if (!noIdentity) cookieJar.absorb(response);
    const buffer = Buffer.from(await response.arrayBuffer());
    const text = buffer.toString("utf8");
    let json = null;
    try { json = JSON.parse(text); } catch { json = null; }
    return { status: response.status, json, text, buffer, headers: response.headers };
  }
  const me = await call("GET", "/api/me");
  assert.equal(me.status, 200, me.text);
  csrf = me.json.csrfToken;
  return { call, me: me.json };
}

const uuid = () => crypto.randomUUID().toUpperCase();
const REQUIRED = {
  p1q1: { storedCode: "Partial" }, p1q2: { storedCode: "Retrieval" }, p1q3: { storedCode: "Analysis" }, part1_adopted_pacing: { storedCode: "on" },
  part1_adopted_ac1: { storedCode: "3" }, part1_adopted_ac2: { storedCode: "4" }, part1_targettask_tt1: { storedCode: "5" }, part1_targettask_tt2: { storedCode: "2" },
};
const SENTINELS = {
  note: `${tag}-NOTE-SENTINEL`, observer: `${tag}-OBSERVER-SENTINEL`, strengths: `${tag}-STRENGTH-SENTINEL`,
  subject: `${tag}-EMAIL-SUBJECT-SENTINEL`, body: `${tag}-EMAIL-BODY-SENTINEL`, to: `${tag}-recipient@example.invalid`, other: `${tag}-OTHER-SENTINEL`,
};
// The suite's own released dates: three days of a month no other suite uses.
const FIRST_DAY = releaseMonth(1950, 1974);
const LAST_DAY = `${FIRST_DAY.slice(0, 8)}03`;
const who = {};
const units = {};
const walks = [];
let release = null;

/** Create, fill and complete a walk as `walker` at their school, visited on the period's first day. */
async function completedWalk(walker, rating, extra = {}) {
  const unit = walker.me.permissions["walk.create"][0];
  const created = await walker.call("POST", "/api/walks", { orgUnitId: unit, clientMutationId: uuid() });
  assert.equal(created.status, 201, created.text);
  const w = created.json.walk;
  const saved = await walker.call("PUT", `/api/walks/${w.id}`, {
    rowVersion: w.rowVersion, clientMutationId: uuid(),
    dimensions: { date: { dateValue: FIRST_DAY }, grade: { selectedValueCode: "7" }, observer: { textValue: SENTINELS.observer }, content: { selectedValueCode: "other", otherText: SENTINELS.other }, ...(extra.dimensions || {}) },
    responses: {
      ...REQUIRED, comp_s1_q1: { storedCode: rating }, comp_s1_notes: { textValue: SENTINELS.note }, summary_strengths: { textValue: SENTINELS.strengths },
      email_workflow: { textValue: JSON.stringify({ body: SENTINELS.body, drafted: true, includedPartKeys: ["part1"], subject: SENTINELS.subject, to: SENTINELS.to }) },
    },
  });
  assert.equal(saved.status, 200, saved.text);
  const done = await walker.call("POST", `/api/walks/${w.id}/complete`, { rowVersion: saved.json.walk.rowVersion, clientMutationId: uuid() });
  assert.equal(done.status, 200, done.text);
  walks.push(w.id);
  return w.id;
}

before(async () => {
  if (skip) return;
  const imported = await api(env, "POST", "/api/maintenance/org-units/import", { token, body: { orgUnits: [
    { code: `${tag}-district`, type: "DISTRICT", name: "HTTP report district", parentCode: null },
    { code: `${tag}-school-a`, type: "SCHOOL", name: "HTTP report school A", parentCode: `${tag}-district` },
    { code: `${tag}-school-b`, type: "SCHOOL", name: "HTTP report school B", parentCode: `${tag}-district` },
    { code: `${tag}-elsewhere`, type: "DISTRICT", name: "HTTP report other district", parentCode: null },
    { code: `${tag}-school-c`, type: "SCHOOL", name: "HTTP report school C", parentCode: `${tag}-elsewhere` },
  ] } });
  assert.equal(imported.status, 200, imported.text);
  const roles = [
    ["walkerA", "SCHOOL_WALK_REPORT", "school-a", false], ["walkerB", "SCHOOL_WALK_REPORT", "school-b", false], ["walkerC", "SCHOOL_WALK_REPORT", "school-c", false],
    ["schoolReport", "SCHOOL_REPORT_ONLY", "school-a", false], ["districtReport", "DISTRICT_REPORT_ONLY", "district", true],
    ["districtWalker", "DISTRICT_WALK_REPORT", "district", true],
    ["admin", "MASTER_INSTRUMENT_ADMIN", "district", false], ["nobody", "", "", false],
  ];
  for (const [name, roleCode, unit, descendants] of roles) {
    const subject = `${tag}-${name}`;
    const u = await api(env, "POST", "/api/maintenance/identity/provision-user", { token, body: { subject, displayName: `Fixture ${subject}` } });
    assert.ok(u.status === 201 || u.status === 200, u.text);
    if (roleCode) {
      const a = await api(env, "POST", "/api/maintenance/identity/assign-role", { token, body: { subject, roleCode, orgUnitCode: `${tag}-${unit}`, includeDescendants: descendants } });
      assert.equal(a.status, 201, a.text);
    }
    who[name] = await client(subject);
  }
  who.releaser = await client(await provisionReleaser(env, token, `${tag}-releaser`));
  units.a = who.walkerA.me.permissions["walk.create"][0];
  units.b = who.walkerB.me.permissions["walk.create"][0];
  units.c = who.walkerC.me.permissions["walk.create"][0];
  units.district = who.districtReport.me.permissions["report.view"].find((id) => ![units.a, units.b].includes(id));
  // A: three walks (a block at the minimum, released); B: one; C: one, in another district.
  await completedWalk(who.walkerA, "2");
  await completedWalk(who.walkerA, "4");
  await completedWalk(who.walkerA, "4");
  await completedWalk(who.walkerB, "5");
  await completedWalk(who.walkerC, "1");
  const created = await who.releaser.call("POST", "/api/reports/releases", { observedFrom: FIRST_DAY, observedTo: LAST_DAY });
  assert.equal(created.status, 201, created.text);
  release = created.json.release;
});

after(async () => {
  if (skip) return;
  const r = await api(env, "POST", "/api/maintenance/identity/cleanup-fixtures", { token, body: { tag } });
  if (r.status !== 200) console.error("fixture cleanup failed", r.status, r.text);
});

const ROUTES = ["/api/reports/options", "/api/reports/aggregate", "/api/reports/aggregate.csv"];
const released = (route, extra = "") => `${route}?releaseId=${release.releaseId}${extra}`;

test("AUTH-01: every report route requires an identity and discloses nothing without one", { skip }, async () => {
  for (const route of ROUTES) {
    const r = await who.districtReport.call("GET", route, undefined, { noIdentity: true });
    assert.equal(r.status, 401, route);
    assert.equal(r.json.error.code, "UNAUTHENTICATED");
    assert.deepEqual(Object.keys(r.json), ["error"]);
  }
  const post = await who.districtReport.call("POST", "/api/reports/releases", { observedFrom: FIRST_DAY, observedTo: LAST_DAY }, { noIdentity: true });
  assert.equal(post.status, 401);
});

test("AUTH-06 / RPT-03: instrument administration and role-less users are refused every report route", { skip }, async () => {
  for (const C of [who.admin, who.nobody]) {
    for (const route of ROUTES) {
      const r = await C.call("GET", route);
      assert.equal(r.status, 403, `${route}`);
      assert.equal(r.json.error.code, "FORBIDDEN");
      assert.ok(!r.text.includes("HTTP report school"), "no scope is disclosed");
    }
    const post = await C.call("POST", "/api/reports/releases", { observedFrom: FIRST_DAY, observedTo: LAST_DAY });
    assert.equal(post.status, 403);
  }
  // The shell answers them as it always has (the admin still has instrument.manage).
  assert.equal((await who.nobody.call("GET", "/api/me")).json.permissions["report.view"].length, 0);
});

test("RPT-03: a report-only role is refused every live figure, however the request is narrowed", { skip }, async () => {
  for (const C of [who.schoolReport, who.districtReport]) {
    for (const extra of ["", "?includeDrafts=true", `?from=${FIRST_DAY}&to=${FIRST_DAY}`, "?optionItem=comp_s1_q1&option=2", "?dim_grade=7"]) {
      for (const route of ["/api/reports/aggregate", "/api/reports/aggregate.csv"]) {
        const r = await C.call("GET", `${route}${extra}`);
        assert.equal(r.status, 400, `${route}${extra}`);
        assert.equal(r.json.error.code, "REPORT_RELEASE_REQUIRED");
        assert.ok(!("population" in r.json), "no figures accompany the refusal");
      }
    }
  }
  // On a release, nothing that narrows who is counted is accepted, for anyone.
  for (const C of [who.districtReport, who.districtWalker]) {
    for (const extra of ["&includeDrafts=true", `&from=${FIRST_DAY}`, `&to=${LAST_DAY}`, "&optionItem=comp_s1_q1&option=2", "&dim_grade=7"]) {
      const r = await C.call("GET", released("/api/reports/aggregate", extra));
      assert.equal(r.status, 400, extra);
      assert.equal(r.json.error.code, "REPORT_FILTER_NOT_PERMITTED");
    }
  }
  assert.equal((await who.districtReport.call("GET", `/api/reports/aggregate?releaseId=${uuid()}`)).status, 404);
  assert.equal((await who.districtReport.call("GET", "/api/reports/aggregate?releaseId=x")).json.error.code, "INVALID_RELEASE_ID");
});

test("RPT-01: a school report role reads its school's release; another school is 404 over HTTP", { skip }, async () => {
  const own = await who.schoolReport.call("GET", released("/api/reports/aggregate"));
  assert.equal(own.status, 200, own.text);
  assert.equal(own.json.mode, "RELEASE");
  assert.equal(own.json.population.walks, 3);
  assert.deepEqual(own.json.orgUnits.map((u) => u.orgUnitId), [units.a]);
  for (const other of [units.b, units.c, units.district]) {
    for (const route of ["/api/reports/aggregate", "/api/reports/aggregate.csv"]) {
      for (const url of [`${route}?orgUnitId=${other}`, released(route, `&orgUnitId=${other}`)]) {
        const r = await who.schoolReport.call("GET", url);
        assert.equal(r.status, 404, url);
        assert.equal(r.json.error.code, "NOT_FOUND");
        assert.ok(!r.text.includes("HTTP report school"), "existence is not disclosed");
      }
    }
  }
  const opts = await who.schoolReport.call("GET", "/api/reports/options");
  assert.equal(opts.status, 200, opts.text);
  assert.deepEqual(opts.json.orgUnits.map((u) => u.orgUnitId), [units.a]);
  // The walk-and-report role at that school gets live figures for it.
  const live = await who.walkerA.call("GET", "/api/reports/aggregate");
  assert.equal(live.status, 200, live.text);
  assert.equal(live.json.mode, "LIVE");
  assert.equal(live.json.population.walks, 3);
});

test("RPT-02: district roles aggregate their descendant schools and nothing else, live or released", { skip }, async () => {
  const r = await who.districtWalker.call("GET", "/api/reports/aggregate");
  assert.equal(r.status, 200, r.text);
  assert.equal(r.json.population.walks, 4);
  assert.deepEqual(r.json.orgUnits.map((u) => u.orgUnitId).sort(), [units.a, units.b].sort());
  const rating = r.json.items.find((i) => i.itemKey === "comp_s1_q1");
  assert.deepEqual(rating.options.map((o) => [o.code, o.count]), [["1", 0], ["2", 1], ["3", 0], ["4", 2], ["5", 1]], "school C's rating of 1 is not in scope");
  assert.equal(rating.scored.responses, 4);
  assert.equal(rating.scored.mean, 3.75);
  assert.equal((await who.districtWalker.call("GET", `/api/reports/aggregate?orgUnitId=${units.b}`)).json.population.walks, 1);
  assert.equal((await who.districtWalker.call("GET", `/api/reports/aggregate?orgUnitId=${units.c}`)).status, 404);
  // The report-only district role reads the release: B's single walk was never released.
  const rel = await who.districtReport.call("GET", released("/api/reports/aggregate"));
  assert.equal(rel.status, 200, rel.text);
  assert.equal(rel.json.population.walks, 3, "A's three walks; B's one walk is below the minimum");
  assert.deepEqual(rel.json.orgUnits.map((u) => u.orgUnitId), [units.a]);
  const b = await who.districtReport.call("GET", released("/api/reports/aggregate", `&orgUnitId=${units.b}`));
  assert.equal(b.json.population.withheld, true);
  assert.equal(b.json.population.walks, null);
  assert.equal(b.json.items.length + b.json.dimensions.length + b.json.orgUnits.length, 0, "a one-walk school returns nothing categorical");
  const relRating = rel.json.items.find((i) => i.itemKey === "comp_s1_q1");
  const two = relRating.options.find((o) => o.code === "2");
  assert.equal(two.count, null, "the single rating of 2 is withheld");
  assert.equal(two.withheld, true);
  assert.equal((await who.districtReport.call("GET", released("/api/reports/aggregate", `&orgUnitId=${units.c}`))).status, 404);
});

test("RPT-03 / RPT-06: payload and export carry no walk, owner, narrative, email or free text", { skip }, async () => {
  const bodies = [];
  for (const [C, route] of [[who.schoolReport, released("/api/reports/aggregate")], [who.schoolReport, released("/api/reports/aggregate.csv")],
    [who.districtWalker, "/api/reports/aggregate"], [who.districtWalker, "/api/reports/aggregate.csv"]]) {
    const r = await C.call("GET", route);
    assert.equal(r.status, 200, route);
    bodies.push(r);
  }
  for (const { text } of bodies) {
    for (const id of walks) assert.ok(!text.includes(id), `walk id ${id} leaked`);
    for (const value of [...Object.values(SENTINELS), `${tag}-walkerA`, `Fixture ${tag}-walkerA`]) assert.ok(!text.includes(value), `${value} leaked`);
  }
  // ...while the walks are still counted, "Other" by its code only.
  assert.equal(bodies[0].json.dimensions.find((d) => d.code === "content").values.find((v) => v.code === "other").walks, 3);
  assert.equal(bodies[2].json.dimensions.find((d) => d.code === "content").values.find((v) => v.code === "other").walks, 4);
  // And the report-only role still cannot open one.
  for (const id of walks.slice(0, 2)) {
    const r = await who.schoolReport.call("GET", `/api/walks/${id}`);
    assert.equal(r.status, 403);
    assert.ok(!r.text.includes(id));
  }
});

test("releases: only someone who can open every walk may release, with CSRF, a closed period, and no overlap", { skip }, async () => {
  assert.equal(release.observedFrom, FIRST_DAY);
  assert.equal(release.observedTo, LAST_DAY);
  assert.equal(release.minimumWalks, 3);
  assert.match(release.releaseId, /^[0-9A-F-]{36}$/);
  assert.ok(release.blocks >= 1);
  const next = `${FIRST_DAY.slice(0, 8)}20`;
  for (const C of [who.districtReport, who.districtWalker, who.walkerA]) {
    const r = await C.call("POST", "/api/reports/releases", { observedFrom: next, observedTo: next });
    assert.equal(r.status, 403, "only someone who can open every walk in every school");
    assert.equal(r.json.error.code, "REPORT_RELEASE_NOT_PERMITTED");
  }
  const noCsrf = await who.releaser.call("POST", "/api/reports/releases", { observedFrom: next, observedTo: next }, { noCsrf: true });
  assert.equal(noCsrf.status, 403);
  assert.equal(noCsrf.json.error.code, "CSRF_TOKEN_INVALID");
  for (const [body, code] of [[{ observedFrom: next }, "REPORT_RELEASE_BODY_INVALID"], [{ observedFrom: next, observedTo: next, minimumWalks: 1 }, "REPORT_RELEASE_BODY_INVALID"],
    [{ observedFrom: next, observedTo: "2999-01-01" }, "REPORT_RELEASE_DATES_OPEN"], [{ observedFrom: "x", observedTo: next }, "REPORT_RELEASE_DATES_INVALID"]]) {
    const r = await who.releaser.call("POST", "/api/reports/releases", body);
    assert.equal(r.status, 400, JSON.stringify(body));
    assert.equal(r.json.error.code, code);
  }
  for (const [observedFrom, observedTo] of [[FIRST_DAY, LAST_DAY], [LAST_DAY, LAST_DAY], [`${FIRST_DAY.slice(0, 8)}02`, `${FIRST_DAY.slice(0, 8)}28`]]) {
    const r = await who.releaser.call("POST", "/api/reports/releases", { observedFrom, observedTo });
    assert.equal(r.status, 409, `${observedFrom}..${observedTo} overlaps the release`);
    assert.equal(r.json.error.code, "REPORT_RELEASE_OVERLAP");
  }
  // The release does not move when walks of its period do.
  const before = await who.districtReport.call("GET", released("/api/reports/aggregate"));
  await completedWalk(who.walkerA, "1");
  const after = await who.districtReport.call("GET", released("/api/reports/aggregate"));
  const figures = (j) => JSON.stringify({ p: j.population, u: j.orgUnits, d: j.dimensions, i: j.items, s: j.sections });
  assert.equal(figures(after.json), figures(before.json), "a release never changes");
  assert.equal((await who.walkerA.call("GET", "/api/reports/aggregate")).json.population.walks, 4, "while the live figure moved");
});

test("report routes are read-only: other methods are refused before anything runs", { skip }, async () => {
  for (const route of ROUTES) {
    for (const method of ["POST", "PUT", "DELETE"]) {
      const r = await who.districtReport.call(method, route, {});
      assert.equal(r.status, 405, `${method} ${route}`);
      assert.equal(r.json.error.code, "METHOD_NOT_ALLOWED");
    }
  }
  for (const method of ["GET", "PUT", "DELETE"]) {
    assert.equal((await who.releaser.call(method, "/api/reports/releases", method === "GET" ? undefined : {})).status, 405, `${method} releases`);
  }
});

test("the CSV export is an attachment with a safe name, no-store, nosniff, a BOM and CRLF rows", { skip }, async () => {
  const r = await who.districtWalker.call("GET", `/api/reports/aggregate.csv?orgUnitId=${units.a}`);
  assert.equal(r.status, 200, r.text);
  assert.equal(r.headers.get("content-type").replace(/\s+/g, "").toLowerCase(), "text/csv;charset=utf-8");
  assert.match(r.headers.get("content-disposition"), /^attachment; filename="ICFWalk_report_[A-Za-z0-9_-]+_\d{8}\.csv"$/);
  assert.equal(r.headers.get("cache-control"), "no-store");
  assert.equal(r.headers.get("x-content-type-options"), "nosniff");
  assert.deepEqual([...r.buffer.subarray(0, 3)], [0xef, 0xbb, 0xbf], "UTF-8 byte order mark");
  const text = r.buffer.subarray(3).toString("utf8");
  assert.ok(text.endsWith("\r\n"));
  const lines = text.split("\r\n").slice(0, -1);
  assert.equal(lines[0], "record_type,group,key,label,count,withheld,scored_responses,score_sum,mean");
  assert.ok(lines.every((l) => !l.includes("\n")), "no bare line feed");
  // The same figures as the JSON route (compared, not hard-coded: another test adds a live walk here).
  const live = await who.districtWalker.call("GET", `/api/reports/aggregate?orgUnitId=${units.a}`);
  assert.ok(lines.includes(`POPULATION,,walks,,${live.json.population.walks},0,,,`), "the population row");
  assert.ok(lines.some((l) => l.startsWith("ITEM,s1,comp_s1_q1,")), "item rows");
  const four = live.json.items.find((i) => i.itemKey === "comp_s1_q1").options.find((o) => o.code === "4").count;
  assert.equal(four, 2);
  assert.ok(lines.includes(`OPTION,comp_s1_q1,4,4,${four},0,,,`));
  // A report-only role's export of the release: the same contract, withheld figures empty and flagged.
  const rel = await who.schoolReport.call("GET", released("/api/reports/aggregate.csv"));
  assert.equal(rel.status, 200, rel.text);
  assert.equal(rel.headers.get("cache-control"), "no-store");
  const relLines = rel.buffer.subarray(3).toString("utf8").split("\r\n");
  assert.ok(relLines.includes("META,,mode,RELEASE,,,,,"));
  assert.ok(relLines.includes("POPULATION,,walks,,3,0,,,"));
  assert.ok(relLines.includes("OPTION,comp_s1_q1,2,2,,1,,,"), "the single rating of 2: an empty count, flagged withheld");
  const agg = await who.districtWalker.call("GET", `/api/reports/aggregate?orgUnitId=${units.a}`);
  assert.equal(agg.headers.get("cache-control"), "no-store");
  assert.equal(agg.headers.get("x-content-type-options"), "nosniff");
  assert.match(agg.headers.get("content-type"), /^application\/json/);
});

test("SEC-01: injection payloads in any parameter are refused as data, and nothing is returned", { skip }, async () => {
  const payloads = [
    ["dim_grade", "7' OR '1'='1", "REPORT_FILTER_VALUE_INVALID"],
    ["dim_grade", "7; DROP TABLE icf.walk; --", "REPORT_FILTER_VALUE_INVALID"],
    ["orgUnitId", "1 OR 1=1", "INVALID_ORG_UNIT"],
    ["versionId", "'; SELECT * FROM icf.app_user; --", "INVALID_VERSION_ID"],
    ["releaseId", "'; DELETE FROM icf.report_release; --", "INVALID_RELEASE_ID"],
    ["from", "2026-01-01' OR '1'='1", "REPORT_FILTER_VALUE_INVALID"],
    ["section", "<script>alert(1)</script>", "REPORT_FILTER_VALUE_INVALID"],
    ["item", "comp_s1_q1' --", "REPORT_FILTER_VALUE_INVALID"],
    ["dim_grade]) OR 1=1 --", "7", "REPORT_FILTER_UNKNOWN"],
    ["<img src=x onerror=alert(1)>", "1", "REPORT_FILTER_UNKNOWN"],
  ];
  for (const [name, value, code] of payloads) {
    for (const route of ["/api/reports/aggregate", "/api/reports/aggregate.csv"]) {
      const r = await who.districtWalker.call("GET", `${route}?${new URLSearchParams([[name, value]])}`);
      assert.equal(r.status, 400, `${route} ${name}=${value}`);
      assert.equal(r.json.error.code, code, `${name}=${value}`);
      assert.match(r.headers.get("content-type"), /^application\/json/, "errors are JSON, never HTML");
      assert.equal(r.headers.get("x-content-type-options"), "nosniff");
      assert.ok(!("population" in r.json), "no report accompanies a refusal");
    }
  }
  // The data is still there afterwards, and so is the release.
  assert.ok((await who.districtWalker.call("GET", "/api/reports/aggregate")).json.population.walks >= 4);
  assert.equal((await who.districtReport.call("GET", released("/api/reports/aggregate"))).status, 200);
});

test("options describe the version, the scope, the releases and the reportable surface only", { skip }, async () => {
  const r = await who.districtReport.call("GET", "/api/reports/options");
  assert.equal(r.status, 200, r.text);
  assert.equal(r.json.format, "icfwalk-aggregate-report/2");
  assert.ok(r.json.versions.some((v) => v.isCurrent && v.versionId === r.json.version.versionId));
  assert.deepEqual(r.json.dimensions.map((d) => d.code), ["grade", "content", "period", "classType", "visitTiming"]);
  assert.ok(r.json.items.length > 0 && r.json.items.every((i) => Array.isArray(i.options) && i.options.length > 0), "choice items only");
  assert.ok(!r.json.items.some((i) => /notes$|^email_workflow$|^summary_/.test(i.itemKey)));
  assert.deepEqual(r.json.orgUnits.map((u) => u.orgUnitId).sort(), [units.district, units.a, units.b].sort());
  assert.deepEqual(r.json.disclosure, { minimumWalks: 3, liveAvailable: false });
  assert.equal(r.json.canRelease, false);
  const listed = r.json.releases.find((x) => x.releaseId === release.releaseId);
  assert.ok(listed, "the release is offered");
  assert.deepEqual(listed.versionIds, [r.json.version.versionId], "with the version it holds for this scope");
  assert.equal((await who.districtWalker.call("GET", "/api/reports/options")).json.disclosure.liveAvailable, true);
  assert.equal((await who.releaser.call("GET", "/api/reports/options")).json.canRelease, true);
  assert.equal((await who.districtReport.call("GET", `/api/reports/options?versionId=${uuid()}`)).status, 404);
  assert.equal((await who.districtReport.call("GET", "/api/reports/options?orgUnitId=x")).json.error.code, "REPORT_FILTER_UNKNOWN");
});
