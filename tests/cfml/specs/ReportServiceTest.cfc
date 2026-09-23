/**
 * Phase 7: aggregate reporting (RPT-01..07) against the real database, through the real walk
 * service, so every response state a report reads was written by the server engine.
 *
 * Two fixture trees keep the populations independent of each other and of anything else in the
 * database. The scope tree (D -> S1, S2; D2 -> S3) is used only by the scope tests, with walks
 * created once in beforeAll. Every other test makes its own school under DT and reads it as
 * `analyst` (DISTRICT_REPORT_ONLY over DT and its descendants) with orgUnitId set to that school.
 *
 * Fixtures are synthetic and removed in afterAll.
 */
component extends="icfwalktests.BaseSpec" output="false" {

	public string function skipReason() {
		if (!schemaPresent()) return "icf schema is not present.";
		if (structIsEmpty(variables.c.snapshotService.currentVersion())) return "no renderable instrument version is seeded.";
		return "";
	}

	public void function beforeAll() {
		variables.fx = createObject("component", "icfwalktests.support.Fixtures").init(variables.c, "rpt-" & lCase(left(replace(createUUID(), "-", "", "all"), 8)));
		variables.svc = variables.c.reportService;
		variables.walkSvc = variables.c.walkService;
		variables.db = variables.c.db;
		variables.json = variables.c.canonicalJson;
		variables.versionId = variables.c.snapshotService.currentVersion().versionId;
		variables.extraWalks = [];
		variables.extraVersions = [];

		// Scope tree. Units are unmapped on purpose: the School dimension stays empty and Grade is
		// unfiltered, so walks can carry whatever grade a test needs.
		variables.D = fx.orgUnit("d", "DISTRICT");
		variables.S1 = fx.orgUnit("s1", "SCHOOL", variables.D);
		variables.S2 = fx.orgUnit("s2", "SCHOOL", variables.D);
		variables.D2 = fx.orgUnit("d2", "DISTRICT");
		variables.S3 = fx.orgUnit("s3", "SCHOOL", variables.D2);
		variables.DT = fx.orgUnit("dt", "DISTRICT");

		variables.w1 = fx.user("w1");
		variables.w2 = fx.user("w2");
		variables.w3 = fx.user("w3");
		fx.assign(w1.userId, "SCHOOL_WALK_REPORT", S1, false);
		fx.assign(w2.userId, "SCHOOL_WALK_REPORT", S2, false);
		fx.assign(w3.userId, "SCHOOL_WALK_REPORT", S3, false);
		variables.schoolReport = fx.user("school-report");
		fx.assign(schoolReport.userId, "SCHOOL_REPORT_ONLY", S1, false);
		variables.districtReport = fx.user("district-report");
		fx.assign(districtReport.userId, "DISTRICT_REPORT_ONLY", D, true);
		variables.districtUnitOnly = fx.user("district-unit-only");
		fx.assign(districtUnitOnly.userId, "DISTRICT_REPORT_ONLY", D, false);
		variables.analyst = fx.user("analyst");
		fx.assign(analyst.userId, "DISTRICT_REPORT_ONLY", DT, true);
		variables.admin = fx.user("admin");
		fx.assign(admin.userId, "MASTER_INSTRUMENT_ADMIN", D, false);
		variables.nobody = fx.user("nobody");
		variables.expired = fx.user("expired-report");
		fx.assign(expired.userId, "SCHOOL_REPORT_ONLY", S1, false, dateAdd("d", -10, now()), dateAdd("d", -1, now()));

		variables.scopeWalks = {
			"s1a": makeWalk(w1, S1, { "grade": { "selectedValueCode": "3" } }, { "comp_s1_q1": { "storedCode": "2" } }),
			"s1b": makeWalk(w1, S1, { "grade": { "selectedValueCode": "3" } }, { "comp_s1_q1": { "storedCode": "4" } }),
			"s2": makeWalk(w2, S2, { "grade": { "selectedValueCode": "4" } }, { "comp_s1_q1": { "storedCode": "5" } }),
			"s3": makeWalk(w3, S3, { "grade": { "selectedValueCode": "4" } }, { "comp_s1_q1": { "storedCode": "1" } })
		};
	}

	public void function afterAll() {
		for (var id in variables.extraWalks) fx.deleteWalk(id);
		for (var v in variables.extraVersions) {
			db.run("DELETE FROM [icf].[instrument_version] WHERE version_id = :id", { "id": db.guid(v.versionId) });
			db.run("DELETE FROM [icf].[instrument] WHERE instrument_id = :id", { "id": db.guid(v.instrumentId) });
		}
		fx.remove();
	}

	// ---- helpers ---------------------------------------------------------------------------------

	private struct function p(required struct user) { return fx.principal(arguments.user.userId); }

	/** The eight Part 1 answers completion requires. */
	private struct function requiredAnswers() {
		return {
			"p1q1": { "storedCode": "Partial" }, "p1q2": { "storedCode": "Retrieval" }, "p1q3": { "storedCode": "Analysis" },
			"part1_adopted_pacing": { "storedCode": "on" }, "part1_adopted_ac1": { "storedCode": "3" }, "part1_adopted_ac2": { "storedCode": "4" },
			"part1_targettask_tt1": { "storedCode": "5" }, "part1_targettask_tt2": { "storedCode": "2" }
		};
	}

	/**
	 * A walk created, saved and (unless complete=false) completed through the real service. When
	 * `then` is given, a second whole-state save applies it before completion -- the way a person
	 * changes a visibility-driving answer after filling in what it governs.
	 */
	private string function makeWalk(required struct who, required string orgUnitId, struct dims = {}, struct responses = {}, boolean complete = true, struct then = {}) {
		var principal = p(arguments.who);
		var created = walkSvc.create(principal, { "orgUnitId": arguments.orgUnitId, "clientMutationId": db.newGuid() });
		var r = requiredAnswers();
		structAppend(r, arguments.responses, true);
		var saved = walkSvc.save(principal, created.id, { "rowVersion": created.rowVersion, "clientMutationId": db.newGuid(), "dimensions": arguments.dims, "responses": r });
		if (!structIsEmpty(arguments.then)) {
			var r2 = requiredAnswers();
			structAppend(r2, structKeyExists(arguments.then, "responses") ? arguments.then.responses : arguments.responses, true);
			saved = walkSvc.save(principal, created.id, { "rowVersion": saved.rowVersion, "clientMutationId": db.newGuid(), "dimensions": arguments.then.dimensions, "responses": r2 });
		}
		if (arguments.complete) walkSvc.complete(principal, created.id, { "rowVersion": saved.rowVersion, "clientMutationId": db.newGuid() });
		return created.id;
	}

	/** A school of its own under DT, with a walker assigned there. */
	private struct function school(required string name) {
		var id = fx.orgUnit(arguments.name, "SCHOOL", variables.DT);
		var walker = fx.user(arguments.name & "-walker");
		fx.assign(walker.userId, "SCHOOL_WALK_REPORT", id, false);
		return { "id": id, "walker": walker };
	}

	private struct function report(required struct who, struct query = {}) {
		return svc.aggregate(p(arguments.who), arguments.query);
	}

	private struct function itemOf(required struct r, required string itemKey) {
		for (var it in arguments.r.items) if (compare(it.itemKey, arguments.itemKey) == 0) return it;
		fail("item " & arguments.itemKey & " is not in the report");
	}

	private struct function sectionOf(required struct r, required string sectionKey) {
		for (var s in arguments.r.sections) if (compare(s.sectionKey, arguments.sectionKey) == 0) return s;
		fail("section " & arguments.sectionKey & " is not in the report");
	}

	private struct function dimensionOf(required struct r, required string code) {
		for (var d in arguments.r.dimensions) if (compare(d.code, arguments.code) == 0) return d;
		fail("dimension " & arguments.code & " is not in the report");
	}

	private numeric function optionCount(required struct item, required string code) {
		for (var o in arguments.item.options) if (compare(o.code, arguments.code) == 0) return o.count;
		fail("option " & arguments.code & " is not an option of " & arguments.item.itemKey);
	}

	private any function valueWalks(required struct dimension, required string code) {
		for (var v in arguments.dimension.values) {
			if (compare(v.code, arguments.code) == 0) return isNull(v.walks) ? "withheld" : v.walks;
		}
		fail("value " & arguments.code & " is not a value of " & arguments.dimension.code);
	}

	private array function unitIds(required struct r) {
		var out = [];
		for (var u in arguments.r.orgUnits) arrayAppend(out, u.orgUnitId);
		arraySort(out, "text");
		return out;
	}

	private void function forceResponseState(required string walkId, required string itemKey, required string state) {
		db.run(
			"UPDATE r SET r.response_state = :state FROM [icf].[walk_response] r JOIN [icf].[item_definition] i ON i.item_id = r.item_id
			  WHERE r.walk_id = :walk AND i.item_key = :key AND i.version_id = :version",
			{ "state": db.nvarchar(arguments.state, 30), "walk": db.guid(arguments.walkId), "key": db.nvarchar(arguments.itemKey, 100), "version": db.guid(variables.versionId) });
	}

	private void function assertDoesNotContain(required string needle, required string haystack, string message = "") {
		if (find(arguments.needle, arguments.haystack)) fail((len(arguments.message) ? arguments.message & " " : "") & "Found [" & arguments.needle & "] where it must never appear.");
	}

	private void function collectKeys(required any value, required struct into) {
		if (isStruct(arguments.value)) {
			for (var k in structKeyArray(arguments.value)) {
				arguments.into[k] = true;
				if (!isNull(arguments.value[k])) collectKeys(arguments.value[k], arguments.into);
			}
		} else if (isArray(arguments.value)) {
			for (var v in arguments.value) if (!isNull(v)) collectKeys(v, arguments.into);
		}
	}

	private any function serviceWith(struct config = variables.c.config, any logger = variables.c.logger) {
		return createObject("component", "icfwalk.reports.ReportService").init(
			arguments.config, variables.c.db, variables.c.errors, arguments.logger, variables.c.auditRepository, variables.c.canonicalJson,
			variables.c.authorizationService, variables.c.snapshotService, variables.c.visibilityEngine, variables.c.walkRepository,
			variables.c.orgUnitRepository, variables.c.reportRepository
		);
	}

	// ---- RPT-01 / RPT-02: organizational scope ---------------------------------------------------

	/** RPT-01: a school report role sees its school; another school is refused, not merely empty. */
	public void function testRpt01SchoolRoleReportsOnlyItsAssignedSchool() {
		var r = report(schoolReport);
		assertEquals(2, r.population.walks, "the two walks at the assigned school");
		assertExactJsonEquals([S1], unitIds(r), "and only that school contributes");
		assertEquals(1, r.scope.orgUnitCount);
		var named = report(schoolReport, { "orgUnitId": S1 });
		assertEquals(2, named.population.walks, "naming the assigned school is the same population");

		var before = db.scalar("SELECT COUNT(*) AS n FROM [icf].[audit_event] WHERE actor_user_id = :u AND event_type = N'ACCESS_DENIED'", { "u": db.guid(schoolReport.userId) });
		for (var other in [S2, S3, D]) {
			assertThrows(function() { report(schoolReport, { "orgUnitId": other }); }, "ICFWalk.NotFound");
			assertThrows(function() { svc.exportCsv(p(schoolReport), { "orgUnitId": other }); }, "ICFWalk.NotFound");
		}
		var after = db.scalar("SELECT COUNT(*) AS n FROM [icf].[audit_event] WHERE actor_user_id = :u AND event_type = N'ACCESS_DENIED'", { "u": db.guid(schoolReport.userId) });
		assertEquals(before + 6, after, "every out-of-scope request is audited as ACCESS_DENIED");

		var opts = svc.options(p(schoolReport), {});
		assertEquals(1, arrayLen(opts.orgUnits), "the filter offers only the assigned school");
		assertExactTextEquals(S1, opts.orgUnits[1].orgUnitId);
	}

	/** RPT-02: a district role draws on its descendant schools and nothing outside them. */
	public void function testRpt02DistrictRoleAggregatesDescendantSchoolsOnly() {
		var r = report(districtReport);
		assertEquals(3, r.population.walks, "S1 (2) and S2 (1); the unrelated district's S3 never contributes");
		var expected = [S1, S2];
		arraySort(expected, "text");
		assertExactJsonEquals(expected, unitIds(r));
		var rating = itemOf(r, "comp_s1_q1");
		assertEquals(1, optionCount(rating, "2"));
		assertEquals(1, optionCount(rating, "4"));
		assertEquals(1, optionCount(rating, "5"));
		assertEquals(0, optionCount(rating, "1"), "S3's rating of 1 is out of scope");
		assertEquals(3, rating.scored.responses);
		assertEquals(11, rating.scored.sum);

		assertEquals(1, report(districtReport, { "orgUnitId": S2 }).population.walks, "a descendant school narrows the population");
		assertEquals(3, report(districtReport, { "orgUnitId": D }).population.walks, "naming the district itself is its whole subtree");
		assertThrows(function() { report(districtReport, { "orgUnitId": D2 }); }, "ICFWalk.NotFound");
		assertThrows(function() { report(districtReport, { "orgUnitId": S3 }); }, "ICFWalk.NotFound");

		// include_descendants = 0 covers the district unit alone, where no walk is conducted.
		assertEquals(0, report(districtUnitOnly).population.walks);
		assertThrows(function() { report(districtUnitOnly, { "orgUnitId": S1 }); }, "ICFWalk.NotFound");
		// An assignment that has ended grants nothing at all.
		assertThrows(function() { report(expired); }, "ICFWalk.Forbidden", "FORBIDDEN");
	}

	/** AUTH-06 for reports: instrument administration and role-less users hold no report.view. */
	public void function testInstrumentAdminAndRolelessUsersAreRefused() {
		for (var who in [admin, nobody]) {
			assertThrows(function() { svc.options(p(who), {}); }, "ICFWalk.Forbidden", "FORBIDDEN");
			assertThrows(function() { report(who); }, "ICFWalk.Forbidden", "FORBIDDEN");
			assertThrows(function() { svc.exportCsv(p(who), {}); }, "ICFWalk.Forbidden", "FORBIDDEN");
		}
		// A walk-and-report role reports on its own school.
		assertEquals(2, report(w1).population.walks);
	}

	// ---- RPT-03: report-only users get nothing individual -----------------------------------------

	public void function testRpt03ReportOnlyUsersReceiveNoIndividualWalkOrIdentifier() {
		var r = report(schoolReport);
		var text = json.serialize(r);
		var csv = svc.exportCsv(p(schoolReport), {}).text;
		for (var id in [scopeWalks.s1a, scopeWalks.s1b, w1.userId]) {
			assertDoesNotContain(id, text, "report payload");
			assertDoesNotContain(id, csv, "report export");
		}
		assertDoesNotContain("Fixture w1", text, "the owner's name");
		assertDoesNotContain("Fixture w1", csv, "the owner's name");
		var keys = {};
		collectKeys(r, keys);
		for (var k in ["walkId", "walkIds", "walks.id", "ownerUserId", "ownerDisplayName", "observedAt", "rowVersion", "textValue", "notes", "teacherIdentifier", "classroomLabel"]) {
			assertFalse(structKeyExists(keys, k), "no [" & k & "] key anywhere in the report");
		}
		// ...and a population narrowed to one walk still yields only aggregates.
		var one = report(schoolReport, { "optionItem": "comp_s1_q1", "option": "2" });
		assertEquals(1, one.population.walks);
		assertDoesNotContain(scopeWalks.s1a, json.serialize(one));
		// The report-only role still cannot open the walk the aggregate counted.
		assertThrows(function() { walkSvc.open(p(schoolReport), scopeWalks.s1a); }, "ICFWalk.Forbidden");
		assertThrows(function() { walkSvc.summary(p(schoolReport), scopeWalks.s1a); }, "ICFWalk.Forbidden");
	}

	// ---- RPT-04 / RPT-05: denominators and weighting ----------------------------------------------

	/**
	 * RPT-04: answered 1 and 5, one unanswered, one hidden and one not applicable. Mean 3.0 over a
	 * denominator of 2, and every state separately countable. The HIDDEN row keeps a retained
	 * rating of 5 and the NOT_APPLICABLE path was submitted with a 4 before the engine cleared it:
	 * either one leaking in would move the mean.
	 */
	public void function testRpt04OnlyAnsweredScoresEnterTheAverage() {
		var s = school("rpt04");
		makeWalk(s.walker, s.id, {}, { "comp_s3_applicable": { "storedCode": "yes" }, "comp_s3_q1": { "storedCode": "1" } });
		makeWalk(s.walker, s.id, {}, { "comp_s3_applicable": { "storedCode": "yes" }, "comp_s3_q1": { "storedCode": "5" } });
		makeWalk(s.walker, s.id, {}, { "comp_s3_applicable": { "storedCode": "yes" } });
		makeWalk(s.walker, s.id, {}, { "comp_s3_applicable": { "storedCode": "no" }, "comp_s3_q1": { "storedCode": "4" } });
		var hidden = makeWalk(s.walker, s.id, {}, { "comp_s3_applicable": { "storedCode": "yes" }, "comp_s3_q1": { "storedCode": "5" } });
		forceResponseState(hidden, "comp_s3_q1", "HIDDEN");

		var it = itemOf(report(analyst, { "orgUnitId": s.id, "item": "comp_s3_q1" }), "comp_s3_q1");
		assertEquals(2, it.states.ANSWERED);
		assertEquals(1, it.states.UNANSWERED);
		assertEquals(1, it.states.HIDDEN);
		assertEquals(1, it.states.NOT_APPLICABLE);
		assertEquals(0, it.states.UNRECORDED);
		assertEquals(1, optionCount(it, "1"));
		assertEquals(1, optionCount(it, "5"), "the hidden row's retained 5 is not an answer");
		assertEquals(0, optionCount(it, "4"), "the cleared not-applicable rating is not an answer");
		assertEquals(2, it.scored.responses, "denominator 2");
		assertEquals(6, it.scored.sum);
		assertEquals(3, it.scored.mean, "mean 3.0");
	}

	/** RPT-05: item-level pooling, never an unweighted average of walk (or component) averages. */
	public void function testRpt05SectionMeansArePooledFromItemLevelResponses() {
		var s = school("rpt05");
		makeWalk(s.walker, s.id, {}, { "comp_s1_q1": { "storedCode": "1" }, "comp_s1_q2": { "storedCode": "1" } });
		makeWalk(s.walker, s.id, {}, { "comp_s1_q1": { "storedCode": "5" } });

		var r = report(analyst, { "orgUnitId": s.id, "section": "s1" });
		var comp = sectionOf(r, "s1");
		assertEquals(3, comp.scored.responses, "three answered ratings, not two walks");
		assertEquals(7, comp.scored.sum);
		assertEquals(2.3333, comp.scored.mean, "(1 + 1 + 5) / 3, where the average of walk averages would be (1 + 5) / 2 = 3");
		assertEquals(3, itemOf(r, "comp_s1_q1").scored.mean);
		assertEquals(1, itemOf(r, "comp_s1_q2").scored.mean);
		assertEquals(2, arrayLen(r.items), "section restricts the reported items to that component");
		assertEquals(2, r.population.walks, "without changing the population");

		// Across the whole instrument: Part 1's four ratings per walk (3, 4, 5, 2) weigh in by count.
		var all = report(analyst, { "orgUnitId": s.id });
		var root = sectionOf(all, "root");
		assertEquals(11, root.scored.responses, "3 component ratings + 2 walks x 4 Part 1 ratings");
		assertEquals(35, root.scored.sum);
		assertEquals(3.1818, root.scored.mean);
		assertEquals(2.3333, sectionOf(all, "part2").scored.mean, "Part 2 is only component 1 here");
	}

	// ---- RPT-06: exclusions -----------------------------------------------------------------------

	/**
	 * Notes, the email draft, free-text dimensions, "Other" text and the database-only teacher and
	 * classroom fields are populated with sentinels; none reaches the payload, the export, the
	 * audit record or the log.
	 */
	public void function testRpt06NarrativeEmailAndTeacherFieldsNeverLeave() {
		var s = school("rpt06");
		var email = json.serialize({ "body": "RPT06-EMAIL-BODY-SENTINEL", "drafted": true, "includedPartKeys": ["part1"], "subject": "RPT06-EMAIL-SUBJECT-SENTINEL", "to": "rpt06-recipient@example.invalid" });
		var id = makeWalk(s.walker, s.id,
			{
				"date": { "dateValue": "2026-09-01" }, "observer": { "textValue": "RPT06-OBSERVER-SENTINEL" },
				"grade": { "selectedValueCode": "7" }, "content": { "selectedValueCode": "other", "otherText": "RPT06-OTHER-SENTINEL" },
				"topic": { "textValue": "RPT06-TOPIC-SENTINEL" }, "tag": { "textValue": "RPT06-TAG-SENTINEL" }
			},
			{
				"comp_s1_notes": { "textValue": "RPT06-NOTE-SENTINEL" }, "summary_strengths": { "textValue": "RPT06-STRENGTH-SENTINEL" },
				"summary_growth": { "textValue": "RPT06-GROWTH-SENTINEL" }, "email_workflow": { "textValue": email },
				"comp_s1_q1": { "storedCode": "3" }
			});
		db.run(
			"UPDATE [icf].[walk] SET teacher_identifier = N'RPT06-TEACHER-ID-SENTINEL', teacher_display_name = N'RPT06-TEACHER-NAME-SENTINEL',
			        teacher_email = N'rpt06-teacher@example.invalid', classroom_label = N'RPT06-CLASSROOM-SENTINEL' WHERE walk_id = :id",
			{ "id": db.guid(id) });

		var logger = createObject("component", "icfwalktests.support.CapturingLogger").init(variables.c.logger, json);
		var capturing = serviceWith(variables.c.config, logger);
		var auditBefore = db.scalar("SELECT ISNULL(MAX(event_id), 0) AS n FROM [icf].[audit_event]");
		var r = capturing.aggregate(p(analyst), { "orgUnitId": s.id });
		var csv = capturing.exportCsv(p(analyst), { "orgUnitId": s.id }).text;
		var audits = db.run("SELECT event_type, details_json FROM [icf].[audit_event] WHERE event_id > :n AND actor_user_id = :u", { "n": db.bigint(auditBefore), "u": db.guid(analyst.userId) });
		var auditText = "";
		for (var i = 1; i <= audits.recordCount; i++) auditText &= audits.event_type[i] & " " & audits.details_json[i] & chr(10);
		assertContains("REPORT_EXPORTED", auditText, "the export is audited");
		var logText = arrayToList(logger.lines(), chr(10));
		assertContains("report.generated", logText, "and logged");
		assertContains("report.exported", logText);

		var surfaces = { "payload": json.serialize(r), "export": csv, "audit": auditText, "log": logText };
		for (var surface in structKeyArray(surfaces)) {
			for (var sentinel in ["RPT06-OBSERVER-SENTINEL", "RPT06-OTHER-SENTINEL", "RPT06-TOPIC-SENTINEL", "RPT06-TAG-SENTINEL", "RPT06-NOTE-SENTINEL",
				"RPT06-STRENGTH-SENTINEL", "RPT06-GROWTH-SENTINEL", "RPT06-EMAIL-BODY-SENTINEL", "RPT06-EMAIL-SUBJECT-SENTINEL", "rpt06-recipient@example.invalid",
				"RPT06-TEACHER-ID-SENTINEL", "RPT06-TEACHER-NAME-SENTINEL", "rpt06-teacher@example.invalid", "RPT06-CLASSROOM-SENTINEL", id]) {
				assertDoesNotContain(sentinel, surfaces[surface], "[" & surface & "]");
			}
		}
		// The walk is counted -- only its identifying and narrative parts are withheld.
		assertEquals(1, r.population.walks);
		assertEquals(1, valueWalks(dimensionOf(r, "content"), "other"), '"Other" is counted by its code; the typed text is not');
		assertEquals(1, optionCount(itemOf(r, "comp_s1_q1"), "3"));
		var codes = [];
		for (var dim in r.dimensions) arrayAppend(codes, dim.code);
		assertExactJsonEquals(["grade", "content", "period", "classType", "visitTiming"], codes, "free-text, date and School dimensions are never reported");
		for (var it in r.items) {
			assertFalse(findNoCase("notes", it.itemKey) > 0 || compare(it.itemKey, "email_workflow") == 0 || findNoCase("summary_", it.itemKey) > 0, it.itemKey & " is not a reportable item");
		}
	}

	// ---- RPT-07: filters --------------------------------------------------------------------------

	public void function testRpt07EveryFilterNarrowsThePopulationWithinScope() {
		var s = school("rpt07a");
		var other = school("rpt07b");
		// w1: grade 7, math, period first, general education, beginning, 2026-03-10, s1q1 4
		makeWalk(s.walker, s.id, { "date": { "dateValue": "2026-03-10" }, "grade": { "selectedValueCode": "7" }, "content": { "selectedValueCode": "math" }, "period": { "selectedValueCode": "first" }, "classType": { "selectedValueCode": "general_education" }, "visitTiming": { "selectedValueCode": "beginning_of_lesson" } }, { "comp_s1_q1": { "storedCode": "4" } });
		// w2: grade 7, ela, period second, ESL, middle, 2026-03-20, s1q1 2
		makeWalk(s.walker, s.id, { "date": { "dateValue": "2026-03-20" }, "grade": { "selectedValueCode": "7" }, "content": { "selectedValueCode": "ela" }, "period": { "selectedValueCode": "second" }, "classType": { "selectedValueCode": "esl" }, "visitTiming": { "selectedValueCode": "middle_of_the_lesson" } }, { "comp_s1_q1": { "storedCode": "2" } });
		// w3: period "first" entered under grade 7, then the grade corrected to 5: Period is hidden and
		// its value retained (RETAIN_HIDDEN). A hidden value never matches a filter or a count.
		makeWalk(s.walker, s.id, { "date": { "dateValue": "2026-04-05" }, "grade": { "selectedValueCode": "7" }, "content": { "selectedValueCode": "math" }, "period": { "selectedValueCode": "first" }, "classType": { "selectedValueCode": "general_education" }, "visitTiming": { "selectedValueCode": "end_of_the_lesson" } }, { "comp_s1_q1": { "storedCode": "4" } }, true,
			{ "dimensions": { "date": { "dateValue": "2026-04-05" }, "grade": { "selectedValueCode": "5" }, "content": { "selectedValueCode": "math" }, "classType": { "selectedValueCode": "general_education" }, "visitTiming": { "selectedValueCode": "end_of_the_lesson" } } });
		// A draft at the same school, and a completed twin of w1 at another school.
		makeWalk(s.walker, s.id, { "date": { "dateValue": "2026-03-10" }, "grade": { "selectedValueCode": "7" }, "content": { "selectedValueCode": "math" } }, { "comp_s1_q1": { "storedCode": "1" } }, false);
		makeWalk(other.walker, other.id, { "date": { "dateValue": "2026-03-10" }, "grade": { "selectedValueCode": "7" }, "content": { "selectedValueCode": "math" }, "period": { "selectedValueCode": "first" } }, { "comp_s1_q1": { "storedCode": "4" } });

		var q = function(struct extra = {}) {
			var query = { "orgUnitId": s.id };
			structAppend(query, arguments.extra, true);
			return report(analyst, query);
		};
		var cases = [
			[{}, 3, "completed walks at the school"],
			[{ "includeDrafts": "true" }, 4, "drafts only on request"],
			[{ "from": "2026-03-15" }, 2, "from is inclusive"],
			[{ "to": "2026-03-15" }, 1, "to is inclusive"],
			[{ "from": "2026-03-10", "to": "2026-03-10" }, 1, "a one-day window"],
			[{ "dim_grade": "7" }, 2, "grade"],
			[{ "dim_content": "math" }, 2, "content"],
			[{ "dim_period": "first" }, 1, "period: the hidden retained value does not match"],
			[{ "dim_classType": "esl" }, 1, "class type"],
			[{ "dim_visitTiming": "end_of_the_lesson" }, 1, "visit timing"],
			[{ "versionId": versionId }, 3, "the walks' own version"],
			[{ "optionItem": "comp_s1_q1", "option": "4" }, 2, "response option"],
			[{ "dim_grade": "7", "dim_content": "math" }, 1, "filters combine"],
			[{ "dim_grade": "7", "dim_content": "math", "includeDrafts": "true" }, 2, "and with drafts"]
		];
		for (var c in cases) {
			assertEquals(c[2], q(c[1]).population.walks, c[3] & " " & json.serialize(c[1]));
		}
		assertEquals(1, report(analyst, { "orgUnitId": other.id, "dim_period": "first" }).population.walks, "the other school is its own population");

		// Section and item restrict what is reported, not who is counted.
		var bySection = q({ "section": "s1" });
		assertEquals(3, bySection.population.walks);
		var keys = [];
		for (var it in bySection.items) arrayAppend(keys, it.itemKey);
		assertExactJsonEquals(["comp_s1_q1", "comp_s1_q2"], keys);
		var byItem = q({ "item": "comp_s1_q1" });
		assertEquals(1, arrayLen(byItem.items));
		assertEquals(2, optionCount(byItem.items[1], "4"));
		assertEquals(1, optionCount(byItem.items[1], "2"));

		// The hidden Period is its own state, distinct from unanswered.
		var period = dimensionOf(q(), "period");
		assertEquals(2, period.states.ANSWERED);
		assertEquals(1, period.states.HIDDEN);
		assertEquals(0, period.states.UNANSWERED);
		assertEquals(1, valueWalks(period, "first"));
		assertEquals(1, valueWalks(period, "second"));

		// Filters are echoed as understood.
		var echoed = q({ "dim_GRADE": "7", "from": "2026-03-01" });
		assertExactTextEquals("7", echoed.filters.dimensions.grade, "dimension parameter names match case-insensitively");
		assertExactTextEquals("2026-03-01", echoed.filters.from);
		assertExactJsonEquals(["COMPLETED"], echoed.filters.statuses);
		assertEquals(2, echoed.population.walks);
	}

	// ---- lifecycle and versions -------------------------------------------------------------------

	public void function testVoidedWalksNeverCountAndDraftsOnlyOnRequest() {
		var s = school("rptdv");
		makeWalk(s.walker, s.id);
		makeWalk(s.walker, s.id, {}, {}, false);
		var voided = makeWalk(s.walker, s.id);
		var row = variables.c.walkRepository.findWalk(voided);
		walkSvc.void(p(s.walker), voided, { "rowVersion": row.rowVersion, "clientMutationId": db.newGuid(), "reason": "Fixture void" });

		var r = report(analyst, { "orgUnitId": s.id });
		assertEquals(1, r.population.walks);
		assertEquals(1, structCount(r.population.byStatus), "only completed walks");
		assertEquals(1, r.population.byStatus.COMPLETED);
		var withDrafts = report(analyst, { "orgUnitId": s.id, "includeDrafts": "true" });
		assertEquals(2, withDrafts.population.walks, "the voided walk is never counted");
		assertEquals(1, withDrafts.population.byStatus.COMPLETED);
		assertEquals(1, withDrafts.population.byStatus.DRAFT);
	}

	/** A report is one version: walks pinned to another version never join it. */
	public void function testWalksOfAnotherVersionNeverJoinTheReport() {
		var s = school("rptvi");
		makeWalk(s.walker, s.id);
		var instrumentId = db.newGuid();
		var otherVersion = db.newGuid();
		db.run("INSERT INTO [icf].[instrument] (instrument_id, code, name) VALUES (:id, :code, N'Report fixture instrument')", { "id": db.guid(instrumentId), "code": db.nvarchar(fx.tag() & "-ins", 60) });
		db.run("INSERT INTO [icf].[instrument_version] (version_id, instrument_id, version_label, status) VALUES (:id, :ins, N'report fixture', N'DRAFT')", { "id": db.guid(otherVersion), "ins": db.guid(instrumentId) });
		arrayAppend(variables.extraVersions, { "versionId": otherVersion, "instrumentId": instrumentId });
		var foreign = db.newGuid();
		db.run(
			"INSERT INTO [icf].[walk] (walk_id, version_id, org_unit_id, owner_user_id, status, completed_at) VALUES (:id, :v, :o, :u, N'COMPLETED', SYSUTCDATETIME())",
			{ "id": db.guid(foreign), "v": db.guid(otherVersion), "o": db.guid(s.id), "u": db.guid(s.walker.userId) });
		arrayAppend(variables.extraWalks, foreign);

		assertEquals(1, report(analyst, { "orgUnitId": s.id }).population.walks, "only the current version's walk");
		assertThrows(function() { report(analyst, { "versionId": otherVersion }); }, "ICFWalk.NotFound", "REPORT_VERSION_NOT_FOUND");
		var versions = svc.options(p(analyst), {}).versions;
		var listed = [];
		for (var v in versions) arrayAppend(listed, v.versionId);
		assertFalse(arrayContains(listed, otherVersion), "another instrument's DRAFT is not a reportable version");
		assertTrue(arrayContains(listed, versionId), "the current version is");
	}

	// ---- validation ----------------------------------------------------------------------------------

	public void function testUnknownMalformedAndOutOfContractFiltersAreRefused() {
		var s = school("rptval");
		var cases = [
			[{ "bogus": "1" }, "ICFWalk.Validation", "REPORT_FILTER_UNKNOWN"],
			[{ "dim_observer": "x" }, "ICFWalk.Validation", "REPORT_FILTER_UNKNOWN"],
			[{ "dim_school": "x" }, "ICFWalk.Validation", "REPORT_FILTER_UNKNOWN"],
			[{ "dim_date": "2026-01-01" }, "ICFWalk.Validation", "REPORT_FILTER_UNKNOWN"],
			[{ "dim_topic": "x" }, "ICFWalk.Validation", "REPORT_FILTER_UNKNOWN"],
			[{ "dim_grade": "13" }, "ICFWalk.Validation", "REPORT_FILTER_VALUE_INVALID"],
			[{ "dim_grade": "K" }, "ICFWalk.Validation", "REPORT_FILTER_VALUE_INVALID"],
			[{ "dim_grade": "7' OR '1'='1" }, "ICFWalk.Validation", "REPORT_FILTER_VALUE_INVALID"],
			[{ "from": "2026-13-01" }, "ICFWalk.Validation", "REPORT_FILTER_VALUE_INVALID"],
			[{ "from": "2026-02-30" }, "ICFWalk.Validation", "REPORT_FILTER_VALUE_INVALID"],
			[{ "to": "03/01/2026" }, "ICFWalk.Validation", "REPORT_FILTER_VALUE_INVALID"],
			[{ "from": "2026-03-01'; DROP TABLE icf.walk; --" }, "ICFWalk.Validation", "REPORT_FILTER_VALUE_INVALID"],
			[{ "from": "2026-04-01", "to": "2026-03-01" }, "ICFWalk.Validation", "REPORT_DATE_RANGE_INVALID"],
			[{ "orgUnitId": "not-a-guid" }, "ICFWalk.Validation", "INVALID_ORG_UNIT"],
			[{ "orgUnitId": db.newGuid() }, "ICFWalk.NotFound", ""],
			[{ "versionId": "1 OR 1=1" }, "ICFWalk.Validation", "INVALID_VERSION_ID"],
			[{ "versionId": db.newGuid() }, "ICFWalk.NotFound", "REPORT_VERSION_NOT_FOUND"],
			[{ "section": "nope" }, "ICFWalk.Validation", "REPORT_FILTER_VALUE_INVALID"],
			[{ "item": "comp_s1_notes" }, "ICFWalk.Validation", "REPORT_FILTER_VALUE_INVALID"],
			[{ "item": "email_workflow" }, "ICFWalk.Validation", "REPORT_FILTER_VALUE_INVALID"],
			[{ "item": "part2_s1_student_heading" }, "ICFWalk.Validation", "REPORT_FILTER_VALUE_INVALID"],
			[{ "section": "s1", "item": "comp_s2_q1" }, "ICFWalk.Validation", "REPORT_FILTER_VALUE_INVALID"],
			[{ "optionItem": "comp_s1_q1" }, "ICFWalk.Validation", "REPORT_FILTER_INCOMPLETE"],
			[{ "option": "4" }, "ICFWalk.Validation", "REPORT_FILTER_INCOMPLETE"],
			[{ "optionItem": "comp_s1_q1", "option": "9" }, "ICFWalk.Validation", "REPORT_FILTER_VALUE_INVALID"],
			[{ "optionItem": "comp_s1_notes", "option": "x" }, "ICFWalk.Validation", "REPORT_FILTER_VALUE_INVALID"],
			[{ "includeDrafts": "yes" }, "ICFWalk.Validation", "REPORT_FILTER_VALUE_INVALID"],
			[{ "item": repeatString("x", 101) }, "ICFWalk.Validation", "REPORT_FILTER_VALUE_INVALID"],
			[{ "dim_grade": { "nested": 1 } }, "ICFWalk.Validation", "REPORT_FILTER_VALUE_INVALID"],
			[{ "dim_grade": ["7", "8"] }, "ICFWalk.Validation", "REPORT_FILTER_VALUE_INVALID"]
		];
		for (var c in cases) {
			var query = { "orgUnitId": s.id };
			structAppend(query, c[1], true);
			var e = assertThrows(function() { report(analyst, query); }, c[2], c[3]);
			if (compare(c[2], "ICFWalk.Validation") == 0) {
				var details = variables.c.errors.detailsOf(e);
				assertTrue(isStruct(details) && structKeyExists(details, "issues") && arrayLen(details.issues) == 1, "one issue names the parameter for " & json.serialize(c[1]));
			}
		}
		// The options route takes nothing but a version.
		assertThrows(function() { svc.options(p(analyst), { "orgUnitId": s.id }); }, "ICFWalk.Validation", "REPORT_FILTER_UNKNOWN");
		// Empty values are absent filters, not errors.
		assertEquals(0, report(analyst, { "orgUnitId": s.id, "from": "", "dim_grade": "", "section": "" }).population.walks);
	}

	// ---- suppression --------------------------------------------------------------------------------

	/**
	 * The undecided threshold (docs/OPEN_DECISIONS.md) defaults to none. When a deployment sets it,
	 * a population below it is withheld whole, and each smaller group within a reported population
	 * is withheld on its own. Zero is never "a small group".
	 */
	public void function testSuppressionThresholdWithholdsSmallGroupsOnlyWhenConfigured() {
		var s = school("rptsup");
		makeWalk(s.walker, s.id, { "grade": { "selectedValueCode": "7" } });
		makeWalk(s.walker, s.id, { "grade": { "selectedValueCode": "7" } });
		makeWalk(s.walker, s.id, { "grade": { "selectedValueCode": "8" } });
		var q = { "orgUnitId": s.id };

		var none = report(analyst, q);
		assertEquals(0, none.suppression.threshold, "no threshold is invented");
		assertFalse(none.suppression.applied);
		assertEquals(1, valueWalks(dimensionOf(none, "grade"), "8"));

		var cfg5 = duplicate(variables.c.config);
		cfg5.reportSuppressionThreshold = 5;
		var five = serviceWith(cfg5).aggregate(p(analyst), q);
		assertTrue(five.population.suppressed, "3 walks under a threshold of 5 are withheld whole");
		assertTrue(five.suppression.applied);
		assertTrue(isNull(five.population.walks), "not even the count");
		assertEquals(0, arrayLen(five.items) + arrayLen(five.dimensions) + arrayLen(five.orgUnits) + arrayLen(five.sections));
		var csv5 = serviceWith(cfg5).exportCsv(p(analyst), q).text;
		assertContains("POPULATION,,walks,,,,,,,,,,,1", csv5, "the export withholds the count and says so");
		assertDoesNotContain("ITEM,", csv5);
		assertDoesNotContain("DIMENSION_VALUE,", csv5);

		var cfg2 = duplicate(variables.c.config);
		cfg2.reportSuppressionThreshold = 2;
		var two = serviceWith(cfg2).aggregate(p(analyst), q);
		assertFalse(two.population.suppressed);
		assertEquals(3, two.population.walks);
		var grade = dimensionOf(two, "grade");
		assertExactTextEquals("withheld", valueWalks(grade, "8"), "a single-walk group is withheld");
		assertEquals(2, valueWalks(grade, "7"));
		assertEquals(0, valueWalks(grade, "9"), "an empty group is not withheld");
		var csv2 = serviceWith(cfg2).exportCsv(p(analyst), q).text;
		assertContains("DIMENSION_VALUE,grade,8,8,,,,,,,,,,1", csv2);
		assertContains("DIMENSION_VALUE,grade,7,7,2,,,,,,,,,0", csv2);
	}

	// ---- CSV ----------------------------------------------------------------------------------------

	public void function testCsvExportIsRfc4180AndNeutralizesFormulas() {
		var formula = fx.orgUnit("rptcsv-f", "SCHOOL", variables.DT);
		var quoted = fx.orgUnit("rptcsv-q", "SCHOOL", variables.DT);
		db.run("UPDATE [icf].[org_unit] SET name = N'=HYPERLINK(""http://example.invalid"")' WHERE org_unit_id = :id", { "id": db.guid(formula) });
		db.run("UPDATE [icf].[org_unit] SET name = N'@SUM(1+1), ""quoted"" school' WHERE org_unit_id = :id", { "id": db.guid(quoted) });
		var walker = fx.user("rptcsv-walker");
		fx.assign(walker.userId, "SCHOOL_WALK_REPORT", formula, false);
		fx.assign(walker.userId, "SCHOOL_WALK_REPORT", quoted, false);
		makeWalk(walker, formula);
		makeWalk(walker, quoted);

		var auditBefore = db.scalar("SELECT ISNULL(MAX(event_id), 0) AS n FROM [icf].[audit_event]");
		var out = svc.exportCsv(p(analyst), { "orgUnitId": formula });
		var text = out.text;
		assertExactTextEquals(chr(65279), left(text, 1), "UTF-8 byte order mark first");
		assertExactTextEquals(chr(13) & chr(10), right(text, 2), "CRLF line ends, the last one included");
		var lines = listToArray(mid(text, 2, len(text)), chr(13) & chr(10), false, true);
		assertExactTextEquals("record_type,group,key,label,count,answered,unanswered,hidden,not_applicable,unrecorded,scored_responses,score_sum,mean,suppressed", lines[1]);
		for (var line in lines) assertFalse(find(chr(10), line) > 0, "no bare line feed inside a record");
		assertContains("ORG_UNIT,SCHOOL," & fx.tag() & "-rptcsv-f,""'=HYPERLINK(""""http://example.invalid"""")"",1,", text, "a formula is neutralized and quoted");
		assertTrue(reFind("^[A-Za-z0-9_-]+\.csv$", out.fileName) > 0, "file name is [A-Za-z0-9_-] only: " & out.fileName);
		assertEquals(out.rows, arrayLen(lines) - 1);

		var both = svc.exportCsv(p(analyst), { "orgUnitId": variables.DT, "dim_grade": "" }).text;
		assertContains(",""'@SUM(1+1), """"quoted"""" school"",", both, "comma and quote are escaped, @ is neutralized");

		var audit = db.run("SELECT details_json FROM [icf].[audit_event] WHERE event_id > :n AND actor_user_id = :u AND event_type = N'REPORT_EXPORTED' ORDER BY event_id",
			{ "n": db.bigint(auditBefore), "u": db.guid(analyst.userId) });
		assertEquals(2, audit.recordCount, "each export is audited once");
		var details = deserializeJSON(audit.details_json[1]);
		var keys = structKeyArray(details);
		arraySort(keys, "text");
		assertExactJsonEquals(["attempts", "bytes", "filters", "orgUnitId", "rows", "suppressed", "versionId", "walks"], keys, "identifiers and counts only");
		assertEquals(1, details.walks);
	}

	// ---- the catalog: what a version makes reportable -----------------------------------------------

	/**
	 * The reportable surface is derived from the version's render model, and dimension visibility
	 * from the instrument's own engine: Period is visible for exactly the grades whose rule shows it.
	 */
	public void function testTheCatalogIsDerivedFromTheVersionAndItsEngine() {
		var catalog = svc.catalogFor(versionId);
		var model = variables.c.snapshotService.renderModelFor(versionId);
		var expected = [];
		var stack = [model.root];
		while (arrayLen(stack)) {
			var node = stack[1];
			arrayDeleteAt(stack, 1);
			for (var it in node.items) if (compare(it.itemType, "SINGLE_CHOICE") == 0 && it.reportable) arrayAppend(expected, it.itemKey);
			for (var i = arrayLen(node.children); i >= 1; i--) arrayPrepend(stack, node.children[i]);
		}
		var actual = [];
		var scored = 0;
		for (var it in catalog.items) {
			arrayAppend(actual, it.itemKey);
			if (it.scored) scored++;
		}
		assertExactJsonEquals(expected, actual, "every reportable single-choice item, in instrument order");
		assertEquals(24, scored, "the 1-5 ratings: Part 1 (4), Part 2 (14), Part 3 (6)");

		var period = {};
		for (var dim in catalog.dimensions) {
			if (compare(dim.code, "period") == 0) period = dim;
			else assertExactTextEquals("ALWAYS", dim.visibility.mode, dim.code & " has no visibility rule");
		}
		assertExactTextEquals("TUPLES", period.visibility.mode);
		var index = variables.c.walkRepository.definitionIndex(versionId);
		var gradeId = index.dimensions.grade;
		assertExactJsonEquals([gradeId], period.visibility.sources, "Period depends on Grade alone");
		var visibleGrades = [];
		for (var tuple in period.visibility.tuples) {
			for (var code in structKeyArray(index.values[gradeId])) if (compare(index.values[gradeId][code], tuple[1]) == 0) arrayAppend(visibleGrades, code);
		}
		arraySort(visibleGrades, "numeric");
		assertExactJsonEquals(["6", "7", "8", "9", "10", "11", "12"], visibleGrades, "as the engine evaluates show_period_for_grades_6_12");
	}

	/** A conditional section's retained answer is HIDDEN, not a distribution entry (COND-10 in reports). */
	public void function testRetainedAnswersOfAHiddenSectionAreCountedAsHidden() {
		var s = school("rptcond");
		makeWalk(s.walker, s.id, { "classType": { "selectedValueCode": "dual_language" } }, { "dual_language_q1": { "storedCode": "yes" } }, true,
			{ "dimensions": { "classType": { "selectedValueCode": "general_education" } }, "responses": {} });
		makeWalk(s.walker, s.id, { "classType": { "selectedValueCode": "dual_language" } }, { "dual_language_q1": { "storedCode": "no" } });
		var it = itemOf(report(analyst, { "orgUnitId": s.id, "item": "dual_language_q1" }), "dual_language_q1");
		assertEquals(1, it.states.ANSWERED);
		assertEquals(1, it.states.HIDDEN);
		assertEquals(1, optionCount(it, "no"));
		assertEquals(0, optionCount(it, "yes"), "the retained yes of the walk that hides the section is not counted");
		assertTrue(isNull(it.scored), "a yes/no item has no score");
	}
}
