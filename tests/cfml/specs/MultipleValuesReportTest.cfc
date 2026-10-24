/**
 * Instrument revision 2026-10-14, step 2: reports over visit fields a walk can hold several values of,
 * against SQL Server. Reports cover the runtime instrument's versions only (config.instrumentCode), so
 * this spec imports the 2026-10-14 document under its own instrument code and reads it through a
 * ReportService of its own, built exactly as Bootstrap builds the application's but configured for
 * that code. Nothing else in the application sees the fixture instrument.
 *
 *   live     a walk counts under each of its values and once among the states; a filter on one value
 *            includes a walk holding it among others; the CSV labels the field (the owner's rule,
 *            docs/OPEN_DECISIONS.md)
 *   release  the combinations of values are one partition, protected like any breakdown
 *            (DisclosureControl); each value is the sum of the published combinations that hold it,
 *            "at least" when one of them is withheld; a combination longer than the 100 characters a
 *            release category held before migration 008 is stored whole
 *
 * Fixtures, the instrument and the release are removed in afterAll.
 */
component extends="icfwalktests.BaseSpec" output="false" {

	public string function skipReason() {
		if (!schemaPresent()) return "icf schema is not present.";
		return "";
	}

	public void function beforeAll() {
		var tag = "mvr-" & lCase(left(replace(createUUID(), "-", "", "all"), 8));
		variables.fx = createObject("component", "icfwalktests.support.Fixtures").init(variables.c, tag);
		variables.cleanup = new icfwalktests.support.FixtureCleanup(variables.c);
		variables.db = variables.c.db;
		variables.code = tag & "-instrument";
		variables.note = "A walk can be counted under more than one value, so these counts can add up to more than the number of walks.";
		variables.DL = fx.orgUnit("live", "DISTRICT");
		variables.DR = fx.orgUnit("released", "DISTRICT");
		variables.walker = fx.user("walker");
		fx.assign(walker.userId, "DISTRICT_WALK_REPORT", DL, true);
		fx.assign(walker.userId, "DISTRICT_WALK_REPORT", DR, true);
		variables.reader = fx.user("reader");
		fx.assign(reader.userId, "DISTRICT_REPORT_ONLY", DR, true);
		variables.admin = fx.user("admin");
		fx.assign(admin.userId, "MASTER_INSTRUMENT_ADMIN", DL, false);
		// Someone who can open every walk in every school: the only kind of person who may release.
		variables.releaser = fx.user("releaser");
		for (var id in structKeyArray(variables.c.orgUnitRepository.loadActiveTree())) fx.assign(releaser.userId, "DISTRICT_WALK_REPORT", id, false);
		variables.releases = [];
		variables.walkIds = [];

		var doc = repoJson("config/instrument-config-2026-10-14.json");
		doc.instrument.code = variables.code;
		variables.versionId = variables.c.instrumentAdminService.importDocument(doc, admin.userId).versionId;
		variables.c.instrumentPublishService.publish(variables.versionId, admin.userId);
		var cfg = duplicate(variables.c.config);
		cfg.instrumentCode = variables.code;
		var c = variables.c;
		variables.svc = new icfwalk.reports.ReportService(
			cfg, c.db, c.errors, c.logger, c.auditRepository, c.canonicalJson, c.authorizationService,
			c.snapshotService, c.visibilityEngine, c.walkRepository, c.orgUnitRepository, c.reportRepository
		);
		// A month no other suite releases (the others use 1901-1999 and 2011-2019).
		variables.releaseDay = dateFormat(createDate(randRange(2000, 2010), randRange(1, 12), 1), "yyyy-mm-dd");
	}

	public void function afterAll() {
		// Releases first (they name the version and the walks), then the walks (they name the
		// version), then the instrument (it names its importer), then the people and units.
		for (var id in variables.releases) fx.deleteRelease(id);
		var stray = db.run("SELECT release_id FROM [icf].[report_release] WHERE released_by_user_id = :u", { "u": db.guid(releaser.userId) });
		for (var r = 1; r <= stray.recordCount; r++) fx.deleteRelease(stray.release_id[r]);
		for (var id in variables.walkIds) fx.deleteWalk(id);
		variables.cleanup.removeInstrumentsCoded(variables.code);
		fx.remove();
	}

	/** Live: under each value, once among the states; a filter on one value includes several. */
	public void function testLiveFiguresCountAWalkUnderEachOfItsValues() {
		var day = "2026-10-15";
		makeWalk(DL, day, { "grade": several(["7", "8"]), "content": several(["ela", "math"]) });
		makeWalk(DL, day, { "grade": several(["7"]), "content": several(["ela"]) });
		makeWalk(DL, day, { "grade": several(["8"]) });
		makeWalk(DL, day, {});
		var r = svc.aggregate(p(walker), { "versionId": versionId, "orgUnitId": DL });
		assertEquals(4, r.population.walks);
		var grade = dimensionOf(r, "grade");
		assertTrue(grade.multiple);
		assertEquals(2, walksOf(grade, "7"), "the 7-and-8 walk counts under 7");
		assertEquals(2, walksOf(grade, "8"), "and under 8");
		assertEquals(3, grade.states.ANSWERED, "each walk once");
		assertEquals(1, grade.states.UNANSWERED);
		assertEquals(0, grade.states.HIDDEN);
		var content = dimensionOf(r, "content");
		assertEquals(2, walksOf(content, "ela"));
		assertEquals(1, walksOf(content, "math"));
		for (var d in r.dimensions) assertExactTextNotEquals("period", d.code, "this version has no Period (owner, 2026-10-24)");

		var filtered = svc.aggregate(p(walker), { "versionId": versionId, "orgUnitId": DL, "dim_grade": "7" });
		assertEquals(2, filtered.population.walks, "the 7 walk and the 7-and-8 walk");
		assertEquals(1, walksOf(dimensionOf(filtered, "grade"), "8"));

		var csv = svc.exportCsv(p(walker), { "versionId": versionId, "orgUnitId": DL }).text;
		for (var field in ["grade", "content", "classType", "visitTiming"]) {
			assertTrue(find(chr(13) & chr(10) & "DIMENSION_NOTE," & field & ",MULTIPLE_VALUES,""" & variables.note & """,,,,," & chr(13) & chr(10), csv) > 0, "the CSV labels " & field);
		}
		assertTrue(find("DIMENSION_STATE,period,", csv) == 0 && find("DIMENSION_VALUE,period,", csv) == 0, "and no Period: this version does not have it");
	}

	/** Release: combinations are one partition; a value is the sum of its published combinations. */
	public void function testAReleaseProtectsCombinationsAndPublishesValuesAsTheirSums() {
		// Visit timing is tied to no rule, so its breakdown is protected on its own: 4 x Beginning,
		// 3 x Middle, 1 x Beginning + Middle. The combination is a primary cell (1), Middle the
		// complementary one, and the audit leaves each withheld cell more than one possible value.
		for (var i = 1; i <= 4; i++) makeWalk(DR, releaseDay, { "visitTiming": several(["beginning_of_lesson"]) });
		for (var i = 1; i <= 3; i++) makeWalk(DR, releaseDay, { "visitTiming": several(["middle_of_the_lesson"]) });
		var programs = ["advanced_placement", "advisory", "avid", "cross_cat", "dhh", "dual_credit", "dual_language", "esl", "general_education", "ib", "ignite"];
		var longCombination = arrayToList(programs, "+");
		assertTrue(len(longCombination) > 100, "longer than a category held before migration 008");
		makeWalk(DR, releaseDay, { "visitTiming": several(["beginning_of_lesson", "middle_of_the_lesson"]), "classType": several(programs) });

		var made = svc.createRelease(p(releaser), { "observedFrom": releaseDay, "observedTo": releaseDay });
		arrayAppend(variables.releases, made.release.releaseId);
		var cells = db.run(
			"SELECT category_type, category_code, responses FROM [icf].[report_release_cell]
			  WHERE release_id = :r AND version_id = :v AND subject_type = N'DIMENSION' AND subject_key IN (N'visitTiming', N'classType')",
			{ "r": db.guid(made.release.releaseId), "v": db.guid(versionId) });
		var stored = {};
		for (var r = 1; r <= cells.recordCount; r++) stored[cells.category_type[r] & ":" & cells.category_code[r]] = cells.responses[r];
		assertEquals(4, storedCount(stored, "VALUE:beginning_of_lesson"));
		assertEquals(3, storedCount(stored, "VALUE:middle_of_the_lesson"));
		assertEquals(1, storedCount(stored, "VALUE:beginning_of_lesson+middle_of_the_lesson"), "the combination is one category");
		assertEquals(1, storedCount(stored, "VALUE:" & longCombination), "the long combination is stored whole");

		var read = svc.aggregate(p(reader), { "releaseId": made.release.releaseId, "versionId": versionId, "orgUnitId": DR });
		assertEquals(8, read.population.walks);
		var timing = dimensionOf(read, "visitTiming");
		assertTrue(timing.multiple);
		var beginning = valueOf(timing, "beginning_of_lesson");
		assertEquals(4, beginning.walks, "4 published");
		assertTrue(beginning.withheld, "and the withheld combination holds it too: at least 4");
		var middle = valueOf(timing, "middle_of_the_lesson");
		assertTrue(isNull(middle.walks), "nothing of Middle is published");
		assertTrue(middle.withheld);
		var ending = valueOf(timing, "end_of_the_lesson");
		assertEquals(0, ending.walks);
		assertFalse(ending.withheld);
		assertEquals(4, timing.states.ANSWERED);
		assertTrue(arrayFind(timing.withheldStates, "ANSWERED") > 0, "answered is a lower bound too");
		assertEquals(4, timing.withheldResponses, "the walks in withheld categories");
		// Program is tied by rules to its classroom cards, so its group is withheld whole.
		for (var v in dimensionOf(read, "classType").values) {
			assertTrue(v.withheld || (!isNull(v.walks) && v.walks == 0), "program " & v.code);
		}
	}

	// ---- helpers ------------------------------------------------------------------------------

	private struct function p(required struct user) { return fx.principal(arguments.user.userId); }

	private struct function several(required array codes) { return { "selectedValueCodes": arguments.codes }; }

	/** A completed walk on the fixture version, placed directly (walks start on the runtime instrument). */
	private string function makeWalk(required string orgUnitId, required string day, required struct dims) {
		var id = db.newGuid();
		arrayAppend(variables.walkIds, id);
		db.run("INSERT INTO [icf].[walk] (walk_id, version_id, org_unit_id, owner_user_id, status) VALUES (:id, :version, :org, :owner, N'DRAFT')",
			{ "id": db.guid(id), "version": db.guid(variables.versionId), "org": db.guid(arguments.orgUnitId), "owner": db.guid(walker.userId) });
		var principal = p(walker);
		var all = { "date": { "dateValue": arguments.day } };
		structAppend(all, arguments.dims);
		var responses = {
			"p1q1": { "storedCode": "Yes" }, "p1q2": { "storedCode": "Analysis" }, "p1q3": { "storedCode": "Comprehension" },
			"part1_targettask_tt1": { "storedCode": "4" }, "part1_targettask_tt2": { "storedCode": "3" },
			"part1_adopted_pacing": { "storedCode": "notevident" }, "part1_adopted_ac1": { "storedCode": "2" }, "part1_adopted_ac2": { "storedCode": "1" }
		};
		var opened = variables.c.walkService.open(principal, id);
		var saved = variables.c.walkService.save(principal, id, { "rowVersion": opened.rowVersion, "clientMutationId": db.newGuid(), "dimensions": all, "responses": responses });
		variables.c.walkService.complete(principal, id, { "rowVersion": saved.rowVersion, "clientMutationId": db.newGuid() });
		return id;
	}

	private struct function dimensionOf(required struct report, required string code) {
		for (var d in arguments.report.dimensions) if (compare(d.code, arguments.code) == 0) return d;
		fail("no dimension " & arguments.code);
	}

	private struct function valueOf(required struct dimension, required string code) {
		for (var v in arguments.dimension.values) if (compare(v.code, arguments.code) == 0) return v;
		fail("no value " & arguments.code);
	}

	private numeric function walksOf(required struct dimension, required string code) {
		return valueOf(arguments.dimension, arguments.code).walks;
	}

	private numeric function storedCount(required struct stored, required string key) {
		return structKeyExists(arguments.stored, arguments.key) ? arguments.stored[arguments.key] : -1;
	}
}
