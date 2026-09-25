#!/usr/bin/env python3
"""Deliberate-mutation red runs. For each mutation: patch one protection out of the corrected code,
restart Lucee, run the named CFML specs / Node tests, record the raw result, restore the file
byte-for-byte (verified by SHA-256), and restart. Usage: mutate.py <id>... (or all)."""
import difflib, hashlib, subprocess, sys, pathlib, json
REPO = pathlib.Path("/home/user/ICFWalk")
S = pathlib.Path("/tmp/claude-0/-home-user-ICFWalk/49fb0df4-a8fa-5d20-9a14-861bafa45a22/scratchpad")
RS, DC, RR = "src/reports/ReportService.cfc", "src/reports/DisclosureControl.cfc", "src/reports/ReportRepository.cfc"
M = {
 "M1": ("complementary suppression removed: primary cells withheld alone", DC,
   'if (size == 0) return { "mode": "COMPLETE", "withheld": withheld };',
   'if (size == 0) return { "mode": "COMPLETE", "withheld": withheld };\n\t\treturn { "mode": "PARTIAL", "withheld": withheld };',
   ["ReportDisclosureTest", "ReportReleaseTest"], []),
 "M2": ("audit step removed: a partial pattern is published even when a reader who knows the rule can pin a cell", DC,
   'if (structCount(possible[key]) < 2) return { "mode": "WITHHELD", "withheld": allTrue(n) };',
   'if (false) return { "mode": "WITHHELD", "withheld": allTrue(n) };',
   ["ReportDisclosureTest"], []),
 "M3": ("live figures for everyone: report-only roles no longer sent to releases (the pre-correction behaviour)", RS,
   '		var readable = unitSet(variables.authz.visibleOrgUnitIds(arguments.principal, "walk.read"));\n		for (var id in arguments.unitIds) if (!structKeyExists(readable, uCase(id))) return true;\n		return false;',
   '		return false;',
   ["ReportReleaseTest", "ReportServiceTest"], ["tests/node/reports.test.mjs"]),
 "M4": ("a release accepts filters that narrow who is counted", RS,
   'if (arrayLen(refused)) {\n				variables.errors.validation(',
   'if (false) {\n				variables.errors.validation(',
   ["ReportReleaseTest"], []),
 "M5": ("instrument-rule links ignored: linked breakdowns suppressed independently", RS,
   'catalog["linkGroups"] = linkGroupsOf(model, catalog);',
   'catalog["linkGroups"] = {};',
   ["ReportReleaseTest", "ReportDisclosureTest"], []),
 "M6": ("aggregate, then suppress: blocks summed before protection, so district minus schools gives cells back", RS,
   '		for (var b in blocks) {\n			total += b.walks;\n			byUnit[b.orgUnitId] = b.walks;\n			var cells = structKeyExists(stored, b.orgUnitId) ? stored[b.orgUnitId] : {};\n			publishBlock(subjects, cells, catalog.linkGroups, k, totals);\n		}',
   '		var pooledCells = {};\n		for (var b in blocks) {\n			total += b.walks;\n			byUnit[b.orgUnitId] = b.walks;\n			var cells = structKeyExists(stored, b.orgUnitId) ? stored[b.orgUnitId] : {};\n			for (var sk in cells) { if (!structKeyExists(pooledCells, sk)) pooledCells[sk] = {}; for (var ck in cells[sk]) pooledCells[sk][ck] = (structKeyExists(pooledCells[sk], ck) ? pooledCells[sk][ck] : 0) + cells[sk][ck]; }\n		}\n		publishBlock(subjects, pooledCells, catalog.linkGroups, k, totals);',
   ["ReportReleaseTest"], []),
 "M7": ("the protected value is sent alongside the suppression flag", RS,
   '				if (decision.withheld[i]) into[key].withheld = true;\n				else into[key].sum += p.counts[i];',
   '				if (decision.withheld[i]) into[key].withheld = true;\n				into[key].sum += p.counts[i];',
   ["ReportReleaseTest"], ["tests/node/browser-reports.test.mjs"]),
 "M8": ("the CSV writes a number where the JSON withholds one", RS,
   '		if (!structKeyExists(arguments.holder, arguments.key) || isNull(arguments.holder[arguments.key])) return "";',
   '		if (!structKeyExists(arguments.holder, arguments.key) || isNull(arguments.holder[arguments.key])) return "0";',
   ["ReportReleaseTest"], ["tests/node/reports.test.mjs"]),
 "M9": ("the report log line carries figures", RS,
   '"items": arrayLen(report.items), "attempts": report.attempts, "filters": filterCount(f), "ms": getTickCount() - started',
   '"items": arrayLen(report.items), "attempts": report.attempts, "filters": filterCount(f), "ms": getTickCount() - started, "figures": report.items',
   ["ReportReleaseTest"], []),
 "M10": ("the block floor removed where a release is frozen (the database guard is what refuses it)", RS,
   '			if (walksByUnit[unitId] < arguments.k) continue;\n			var cells = [];',
   '			var cells = [];',
   ["ReportReleaseTest"], []),
 "M11": ("the overlap check removed from the service (the database trigger is what refuses it)", RS,
   '			if (reports.overlapsRelease(span.fromText, span.toText)) {',
   '			if (false) {',
   ["ReportReleaseTest"], []),
 "M12": ("P7C-01 as the audit describes it: one fixed pair of global (##) population tables shared by every request", RR,
   [('			"pop": variables.LOCAL_TEMP & "icf_rp_" & token,\n			"units": variables.LOCAL_TEMP & "icf_ru_" & token,',
     '			"pop": variables.LOCAL_TEMP & variables.LOCAL_TEMP & "icf_report_population",\n			"units": variables.LOCAL_TEMP & variables.LOCAL_TEMP & "icf_report_units",'),
    ('		if (!reFind("^" & variables.LOCAL_TEMP & "icf_r[pu]_[0-9A-F]{32}$", arguments.name)) {',
     '		if (false) {')],
   None, ["ReportIsolationTest"], []),
 "M13": ("P7C-01 guard removed: a population may be built outside a transaction", RR,
   '		if (q.open_transactions[1] < 1) {',
   '		if (false) {',
   ["ReportIsolationTest"], []),
 "M14": ("P7C-01 guard removed: a population goes on after its statements reach another connection", RR,
   '		if (spid != arguments.population.spid) {',
   '		if (false) {',
   ["ReportIsolationTest"], []),
 "M15": ("P7C-02: a new release no longer leaves out walks an earlier release counted (the database key is what refuses it)", RS,
   'reports.selectCandidates(population, arguments.versionId, ["COMPLETED"], arguments.observedFrom, arguments.observedBefore, true);',
   'reports.selectCandidates(population, arguments.versionId, ["COMPLETED"], arguments.observedFrom, arguments.observedBefore, false);',
   ["ReportReleaseMembershipTest"], []),
 "M16": ("P7C-02: a release stores its blocks without recording the walks they count (the database trigger is what refuses it)", RS,
   '					reports.insertMembers(releaseId, versionId, b.orgUnitId, b.walkIds);\n',
   '',
   ["ReportReleaseMembershipTest"], []),
}
def sh(cmd, timeout=1800):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
def run(mid):
    desc, rel, old, new, specs, nodes = M[mid]
    path = REPO / rel
    original = path.read_bytes()
    digest = hashlib.sha256(original).hexdigest()
    text = original.decode()
    pairs = old if isinstance(old, list) else [(old, new)]
    mutated = text
    for a, b in pairs:
        assert mutated.count(a) == 1, f"{mid}: anchor not found exactly once: {a[:60]}"
        mutated = mutated.replace(a, b)
    path.write_bytes(mutated.encode())
    out = [f"## {mid}: {desc}", f"file: {rel}  (sha256 before mutation {digest})", "mutation (unified diff of the file before and after the mutation):"]
    out.append("".join(difflib.unified_diff(text.splitlines(True), mutated.splitlines(True), f"a/{rel}", f"b/{rel}", n=1)).rstrip())
    try:
        out.append("restart: " + sh(f"{S}/restart.sh").stdout.strip().splitlines()[-1][:60])
        for spec in specs:
            r = sh(f"{S}/spec.sh {spec}")
            out.append(f"$ CFML {spec}\n" + r.stdout.rstrip())
        for node in nodes:
            r = sh(f"cd {REPO} && ICFWALK_REQUIRE_APP=1 ICFWALK_SCREENSHOT_DIR={S}/shots node --test {node} 2>&1")
            lines = [l for l in r.stdout.splitlines() if l.startswith(("ok ", "not ok ", "# pass", "# fail", "# skipped")) or "error:" in l]
            out.append(f"$ ICFWALK_REQUIRE_APP=1 node --test {node}\n" + "\n".join(lines))
    finally:
        path.write_bytes(original)
        after = hashlib.sha256(path.read_bytes()).hexdigest()
        assert after == digest, "restore failed"
        out.append(f"restored: sha256 {after} (identical to before)")
        sh(f"{S}/restart.sh")
    return "\n".join(out)
ids = list(M) if sys.argv[1:] == ["all"] else sys.argv[1:]
for mid in ids:
    block = run(mid)
    print(block + "\n", flush=True)
