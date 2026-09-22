/**
 * Minimal dependency-free CFML test runner (Adobe ColdFusion 2023 and Lucee compatible).
 * Discovers tests/cfml/specs/*Test.cfc, instantiates each with the application container, runs
 * every public method whose name starts with "test", and reports JSON. Specs extend BaseSpec.
 *
 * TestBox would be the conventional choice; it is not vendored because the build environment
 * cannot reach ForgeBox, and this runner keeps the suite runnable from a clean checkout.
 */
component output="false" {

	public TestRunner function init(required struct container) {
		variables.c = arguments.container;
		variables.specDir = getDirectoryFromPath(getCurrentTemplatePath()) & "specs/";
		return this;
	}

	/**
	 * Runs the discovered specs and reports JSON.
	 *
	 * `part` of `of` runs one deterministic slice of the specs instead of all of them: files are
	 * discovered in a stable name order and dealt out round-robin, so every spec belongs to exactly
	 * one part and the union of all parts is the whole suite.
	 *
	 * WHY PARTITIONING EXISTS. The whole suite runs inside a single /api/maintenance/tests/run
	 * request by design, and Lucee is configured for it (LUCEE_REQUESTTIMEOUT=600 in
	 * tools/runtime/lucee-up.sh). The *client* was never given the same allowance: Node's fetch
	 * gives up after 5 minutes waiting for response headers, and none are sent until the suite
	 * finishes. That ceiling was reached as the suite grew, and it aborted the request mid-run --
	 * which also skipped every spec's afterAll, leaving fixtures behind that then failed later
	 * tests. Running the suite in parts keeps each request well inside the client's limit. It
	 * changes nothing about what runs: every spec still runs exactly once, and the caller sums the
	 * parts.
	 */
	public struct function run(string filter = "", numeric part = 0, numeric of = 0) {
		var started = getTickCount();
		var report = { "ok": true, "engine": variables.c.healthController.engineDescription(), "specs": [], "totals": { "passed": 0, "failed": 0, "skipped": 0 } };
		var files = directoryList(variables.specDir, false, "name", "*Test.cfc", "name asc");
		var index = 0;
		for (var file in files) {
			var name = listFirst(file, ".");
			if (len(arguments.filter) && !findNoCase(arguments.filter, name)) continue;
			// Counted over the specs this run would otherwise have executed, so a filtered run
			// partitions the filtered set rather than the whole directory.
			index++;
			if (arguments.of > 0 && ((index - 1) % arguments.of) != (arguments.part - 1)) continue;
			var specReport = { "name": name, "cases": [], "passed": 0, "failed": 0, "skipped": 0 };
			var spec = "";
			try {
				spec = createObject("component", "icfwalktests.specs." & name).init(variables.c);
			} catch (any e) {
				specReport.failed++;
				arrayAppend(specReport.cases, { "name": "(construct)", "status": "failed", "message": e.message, "detail": structKeyExists(e, "detail") ? e.detail : "", "at": firstFrame(e) });
				arrayAppend(report.specs, specReport);
				report.totals.failed++;
				report.ok = false;
				continue;
			}
			var skipReason = spec.skipReason();
			var methods = testMethods(spec);
			if (len(skipReason)) {
				for (var m in methods) {
					arrayAppend(specReport.cases, { "name": m, "status": "skipped", "message": skipReason });
					specReport.skipped++;
				}
			} else {
				var beforeAllFailed = "";
				try { spec.beforeAll(); } catch (any e) { beforeAllFailed = e.message & " " & (structKeyExists(e, "detail") ? e.detail : "") & " @ " & firstFrame(e); }
				for (var m in methods) {
					var t0 = getTickCount();
					if (len(beforeAllFailed)) {
						arrayAppend(specReport.cases, { "name": m, "status": "failed", "message": "beforeAll failed: " & beforeAllFailed });
						specReport.failed++;
						continue;
					}
					try {
						spec.beforeEach();
						invoke(spec, m);
						arrayAppend(specReport.cases, { "name": m, "status": "passed", "ms": getTickCount() - t0 });
						specReport.passed++;
					} catch (any e) {
						arrayAppend(specReport.cases, { "name": m, "status": "failed", "message": e.message, "detail": structKeyExists(e, "detail") ? e.detail : "", "type": e.type, "at": firstFrame(e), "ms": getTickCount() - t0 });
						specReport.failed++;
					}
				}
				try { spec.afterAll(); } catch (any e) {
					arrayAppend(specReport.cases, { "name": "(afterAll)", "status": "failed", "message": e.message, "at": firstFrame(e) });
					specReport.failed++;
				}
			}
			report.totals.passed += specReport.passed;
			report.totals.failed += specReport.failed;
			report.totals.skipped += specReport.skipped;
			if (specReport.failed) report.ok = false;
			arrayAppend(report.specs, specReport);
		}
		report["elapsedMs"] = getTickCount() - started;
		return report;
	}

	private array function testMethods(required any spec) {
		var out = [];
		var md = getMetadata(arguments.spec);
		var seen = {};
		while (isStruct(md)) {
			if (structKeyExists(md, "functions")) {
				for (var f in md.functions) {
					if (left(f.name, 4) == "test" && !structKeyExists(seen, f.name)) { seen[f.name] = true; arrayAppend(out, f.name); }
				}
			}
			md = structKeyExists(md, "extends") ? md.extends : "";
		}
		arraySort(out, "textnocase");
		return out;
	}

	private string function firstFrame(required any e) {
		if (!structKeyExists(arguments.e, "tagContext") || !isArray(arguments.e.tagContext)) return "";
		for (var frame in arguments.e.tagContext) {
			var t = structKeyExists(frame, "template") ? frame.template : "";
			if (findNoCase("TestRunner", t)) continue;
			return t & ":" & (structKeyExists(frame, "line") ? frame.line : "");
		}
		return "";
	}
}
