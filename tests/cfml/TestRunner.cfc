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

	public struct function run(string filter = "") {
		var started = getTickCount();
		var report = { "ok": true, "engine": variables.c.healthController.engineDescription(), "specs": [], "totals": { "passed": 0, "failed": 0, "skipped": 0 } };
		var files = directoryList(variables.specDir, false, "name", "*Test.cfc", "name asc");
		for (var file in files) {
			var name = listFirst(file, ".");
			if (len(arguments.filter) && !findNoCase(arguments.filter, name)) continue;
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
