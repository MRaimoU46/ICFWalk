/**
 * RPT-03 correction: report-only users read frozen releases, and nothing a release publishes lets
 * anyone infer an individual walk. Real database, real walk service, real releases.
 *
 * Fixture district DR with schools A (1 walk), B (2), C (10 completed, 1 draft, 1 outside the
 * period), D (3 = the minimum) and E (none), all in one released period that no other fixture
 * uses: a random month between 1901 and 1929 (ReportCoherenceTest uses 1930-1949, the HTTP suite
 * 1950-1974 and the browser suite 1975-1999), so
 * the release covers these walks and nothing else. School C's walks are built so that its
 * released breakdowns exercise every case of the rule:
 *
 *   comp_s1_q1   ratings 4 x5, 5 x4, 2 x1       partial: 2 withheld, 5 withheld as its complement
 *   comp_s2_q2   ratings 3 x6, 4 x3, unanswered  partial: 4 and UNANSWERED withheld
 *   comp_s2_q1   ratings 5 x2, unanswered x8     withheld whole (and so is its mean: 2 < k)
 *   comp_s6_q1   ratings 5 x2, unanswered x8     withheld whole; section s6 has no other rating
 *   visitTiming  beginning x6, middle x3, none   partial: middle and UNANSWERED withheld
 *   grade        7 x9, 3 x1                     a small cell in the Grade / Period / PreK-K group
 *
 * Releases are removed in afterAll, before the fixture users and units they name.
 */
component extends="icfwalktests.BaseSpec" output="false" {

	public string function skipReason() {
		if (!schemaPresent()) return "icf schema is not present.";
		if (structIsEmpty(variables.c.snapshotService.currentVersion())) return "no renderable instrument version is seeded.";
		return "";
	}

	public void function beforeAll() {
		variables.fx = createObject("component", "icfwalktests.support.Fixtures").init(variables.c, "rel-" & lCase(left(replace(createUUID(), "-", "", "all"), 8)));
		variables.svc = variables.c.reportService;
		variables.walkSvc = variables.c.walkService;
		variables.db = variables.c.db;
		variables.json = variables.c.canonicalJson;
		variables.versionId = variables.c.snapshotService.currentVersion().versionId;
		variables.k = svc.minimumWalks();

		// A month no other suite uses, and no release covers yet.
		var base = createDate(randRange(1901, 1929), randRange(1, 12), 1);
		variables.period = { "start": dayText(base, 0), "end": dayText(base, 2) };
		variables.before = dayText(base, -1);
		variables.later = dayText(base, 10);

		variables.DR = fx.orgUnit("dr", "DISTRICT");
		variables.S = {};
		variables.walker = {};
		for (var name in ["a", "b", "c", "d", "e"]) {
			S[name] = fx.orgUnit(name, "SCHOOL", DR);
			walker[name] = fx.user("walker-" & name);
			fx.assign(walker[name].userId, "SCHOOL_WALK_REPORT", S[name], false);
		}
		variables.districtReportOnly = fx.user("district-report-only");
		fx.assign(districtReportOnly.userId, "DISTRICT_REPORT_ONLY", DR, true);
		variables.schoolReportOnly = fx.user("school-report-only");
		fx.assign(schoolReportOnly.userId, "SCHOOL_REPORT_ONLY", S.c, false);
		variables.liveUser = fx.user("district-walk-report");
		fx.assign(liveUser.userId, "DISTRICT_WALK_REPORT", DR, true);
		// Someone who can open every walk in every school: the only kind of person who may release.
		variables.releaser = fx.user("releaser");
		for (var id in structKeyArray(variables.c.orgUnitRepository.loadActiveTree())) fx.assign(releaser.userId, "DISTRICT_WALK_REPORT", id, false);
		variables.releases = [];

		var day1 = period.start;
		var day2 = dayText(base, 1);
		var day3 = period.end;
		variables.walkIds = {};
		walkIds.a = [makeWalk("a", day1, "7", "beginning_of_lesson", { "comp_s1_q1": "5" })];
		walkIds.b = [makeWalk("b", day1, "7", "beginning_of_lesson", { "comp_s1_q1": "5" }), makeWalk("b", day3, "7", "beginning_of_lesson", { "comp_s1_q1": "4" })];
		walkIds.c = [];
		var ratings = ["4", "4", "4", "4", "4", "5", "5", "5", "5", "2"];
		for (var i = 1; i <= 10; i++) {
			var r = { "comp_s1_q1": ratings[i] };
			if (i <= 6) r["comp_s2_q2"] = "3";
			else if (i <= 9) r["comp_s2_q2"] = "4";
			if (i <= 2) { r["comp_s2_q1"] = "5"; r["comp_s6_q1"] = "5"; }
			var timing = i <= 6 ? "beginning_of_lesson" : i <= 9 ? "middle_of_the_lesson" : "";
			arrayAppend(walkIds.c, makeWalk("c", i <= 5 ? day1 : day2, i == 10 ? "3" : "7", timing, r));
		}
		walkIds.cDraft = makeWalk("c", day2, "7", "beginning_of_lesson", { "comp_s1_q1": "1" }, false);
		walkIds.cBefore = makeWalk("c", before, "7", "beginning_of_lesson", { "comp_s1_q1": "1" });
		walkIds.d = [];
		for (var i = 1; i <= 3; i++) arrayAppend(walkIds.d, makeWalk("d", day3, "7", "beginning_of_lesson", { "comp_s1_q1": "3" }));

		variables.rel = makeRelease(period.start, period.end).release;
	}

	public void function afterAll() {
		for (var id in variables.releases) deleteRelease(id);
		// A release a failed assertion created without recording it.
		var stray = db.run("SELECT release_id FROM [icf].[report_release] WHERE released_by_user_id = :u", { "u": db.guid(releaser.userId) });
		for (var r = 1; r <= stray.recordCount; r++) deleteRelease(stray.release_id[r]);
		fx.remove();
	}

	// ---- helpers ---------------------------------------------------------------------------------

	private string function dayText(required date base, required numeric offset) {
		return dateFormat(dateAdd("d", arguments.offset, arguments.base), "yyyy-mm-dd");
	}

	private struct function p(required struct user) { return fx.principal(arguments.user.userId); }

	private string function makeWalk(required string school, required string visitDate, required string grade, required string timing, required struct ratings, boolean complete = true) {
		var principal = p(walker[arguments.school]);
		var created = walkSvc.create(principal, { "orgUnitId": S[arguments.school], "clientMutationId": db.newGuid() });
		var dims = { "date": { "dateValue": arguments.visitDate }, "grade": { "selectedValueCode": arguments.grade }, "content": { "selectedValueCode": "math" }, "classType": { "selectedValueCode": "general_education" } };
		if (arguments.grade != "3") dims["period"] = { "selectedValueCode": "first" };
		if (len(arguments.timing)) dims["visitTiming"] = { "selectedValueCode": arguments.timing };
		var responses = {
			"p1q1": { "storedCode": "Partial" }, "p1q2": { "storedCode": "Retrieval" }, "p1q3": { "storedCode": "Analysis" },
			"part1_adopted_pacing": { "storedCode": "on" }, "part1_adopted_ac1": { "storedCode": "3" }, "part1_adopted_ac2": { "storedCode": "4" },
			"part1_targettask_tt1": { "storedCode": "5" }, "part1_targettask_tt2": { "storedCode": "2" },
			"comp_s1_notes": { "textValue": "REL-NOTE-SENTINEL" }
		};
		for (var key in structKeyArray(arguments.ratings)) responses[key] = { "storedCode": arguments.ratings[key] };
		var saved = walkSvc.save(principal, created.id, { "rowVersion": created.rowVersion, "clientMutationId": db.newGuid(), "dimensions": dims, "responses": responses });
		if (arguments.complete) walkSvc.complete(principal, created.id, { "rowVersion": saved.rowVersion, "clientMutationId": db.newGuid() });
		return created.id;
	}

	private struct function makeRelease(required string startDate, required string endDate, struct who = variables.releaser) {
		var out = svc.createRelease(p(arguments.who), { "observedFrom": arguments.startDate, "observedTo": arguments.endDate });
		arrayAppend(variables.releases, out.release.releaseId);
		return out;
	}

	private void function deleteRelease(required string id) {
		db.run("DELETE FROM [icf].[report_release_cell] WHERE release_id = :id", { "id": db.guid(arguments.id) });
		db.run("DELETE FROM [icf].[report_release_block] WHERE release_id = :id", { "id": db.guid(arguments.id) });
		db.run("DELETE FROM [icf].[report_release] WHERE release_id = :id", { "id": db.guid(arguments.id) });
	}

	private struct function read(required struct who, struct query = {}) {
		var q = { "releaseId": variables.rel.releaseId };
		structAppend(q, arguments.query, true);
		return svc.aggregate(p(arguments.who), q);
	}

	private struct function itemOf(required struct r, required string itemKey) {
		for (var it in arguments.r.items) if (compare(it.itemKey, arguments.itemKey) == 0) return it;
		fail("item " & arguments.itemKey & " is not in the report");
	}

	private struct function optionOf(required struct item, required string code) {
		for (var o in arguments.item.options) if (compare(o.code, arguments.code) == 0) return o;
		fail("option " & arguments.code & " is not an option of " & arguments.item.itemKey);
	}

	private struct function dimensionOf(required struct r, required string code) {
		for (var d in arguments.r.dimensions) if (compare(d.code, arguments.code) == 0) return d;
		fail("dimension " & arguments.code & " is not in the report");
	}

	private struct function valueOf(required struct dimension, required string code) {
		for (var v in arguments.dimension.values) if (compare(v.code, arguments.code) == 0) return v;
		fail("value " & arguments.code & " is not a value of " & arguments.dimension.code);
	}

	private struct function sectionOf(required struct r, required string sectionKey) {
		for (var sec in arguments.r.sections) if (compare(sec.sectionKey, arguments.sectionKey) == 0) return sec;
		fail("section " & arguments.sectionKey & " is not in the report");
	}

	/** A published figure, or 0 where it is withheld (null): for adding published parts up. */
	private numeric function figure(required struct holder, required string key) {
		return (structKeyExists(arguments.holder, arguments.key) && !isNull(arguments.holder[arguments.key])) ? arguments.holder[arguments.key] : 0;
	}

	/** The figures of a report, without its envelope (filters, time, scope size). */
	private string function figures(required struct r) {
		return json.serialize({ "population": arguments.r.population, "orgUnits": arguments.r.orgUnits, "dimensions": arguments.r.dimensions, "items": arguments.r.items, "sections": arguments.r.sections });
	}

	/** A withheld figure is null -- not 0, not the value next to a flag. */
	private void function assertWithheld(required struct holder, required string key, required string what) {
		assertFalse(structKeyExists(arguments.holder, arguments.key) && !isNull(arguments.holder[arguments.key]), arguments.what & " must be withheld (null), found " & (structKeyExists(arguments.holder, arguments.key) && !isNull(arguments.holder[arguments.key]) ? arguments.holder[arguments.key] : ""));
	}

	private string function stable(required struct report) {
		var copy = duplicate(arguments.report);
		structDelete(copy, "generatedAt");
		return json.serialize(copy);
	}

	/** Every flat category of every breakdown in a one-block report: [{ subject, withheld, published }]. */
	private array function breakdowns(required struct r) {
		var out = [];
		for (var it in arguments.r.items) {
			var withheld = 0;
			for (var o in it.options) if (o.withheld) withheld++;
			for (var stateKey in ["UNANSWERED", "HIDDEN", "NOT_APPLICABLE", "UNRECORDED"]) if (arrayContains(it.withheldStates, stateKey)) withheld++;
			arrayAppend(out, { "subject": it.itemKey, "withheld": withheld, "hidden": it.withheldResponses });
		}
		for (var d in arguments.r.dimensions) {
			var withheld = 0;
			for (var v in d.values) if (v.withheld) withheld++;
			for (var stateKey in ["UNANSWERED", "HIDDEN"]) if (arrayContains(d.withheldStates, stateKey)) withheld++;
			arrayAppend(out, { "subject": d.code, "withheld": withheld, "hidden": d.withheldResponses });
		}
		return out;
	}

	// ---- who may read what -----------------------------------------------------------------------

	/** RPT-03: a report-only user gets no live figures at all, however the request is narrowed. */
	public void function testReportOnlyUsersCannotReadLiveFigures() {
		for (var who in [districtReportOnly, schoolReportOnly]) {
			for (var q in [{}, { "orgUnitId": S.c }, { "from": period.start, "to": period.end }, { "optionItem": "comp_s1_q1", "option": "2" }, { "includeDrafts": "true" }]) {
				if (compare(who.userId, schoolReportOnly.userId) == 0 && structKeyExists(q, "orgUnitId")) continue;
				assertThrows(function() { svc.aggregate(p(who), q); }, "ICFWalk.Validation", "REPORT_RELEASE_REQUIRED");
				assertThrows(function() { svc.exportCsv(p(who), q); }, "ICFWalk.Validation", "REPORT_RELEASE_REQUIRED");
			}
		}
		// Scope is still decided first: another unit is not found, not "choose a release".
		assertThrows(function() { svc.aggregate(p(schoolReportOnly), { "orgUnitId": S.d }); }, "ICFWalk.NotFound");
		assertThrows(function() { svc.aggregate(p(schoolReportOnly), { "orgUnitId": S.d, "releaseId": rel.releaseId }); }, "ICFWalk.NotFound");
		// Someone who can open every walk in the scope still has live figures and every filter.
		var live = svc.aggregate(p(liveUser), { "orgUnitId": S.c, "from": period.start, "to": period.end, "includeDrafts": "true" });
		assertExactTextEquals("LIVE", live.mode);
		assertTrue(live.population.walks >= 11 && structKeyExists(live.population.byStatus, "DRAFT"), "the completed walks and the draft, live");
		var opts = svc.options(p(districtReportOnly), {});
		assertFalse(opts.disclosure.liveAvailable);
		assertTrue(svc.options(p(liveUser), {}).disclosure.liveAvailable);
		assertEquals(k, opts.disclosure.minimumWalks);
	}

	/** A released report is narrowed by version, school, section and question -- never by who is counted. */
	public void function testNoFilterThatChangesWhoIsCountedIsAcceptedOnARelease() {
		var cases = [{ "from": period.start }, { "to": period.end }, { "dim_grade": "7" }, { "dim_visitTiming": "middle_of_the_lesson" },
			{ "optionItem": "comp_s1_q1", "option": "2" }, { "includeDrafts": "true" }, { "includeDrafts": "false" }];
		for (var who in [districtReportOnly, liveUser]) {
			for (var c in cases) {
				var e = assertThrows(function() { read(who, c); }, "ICFWalk.Validation", "REPORT_FILTER_NOT_PERMITTED");
				var details = variables.c.errors.detailsOf(e);
				assertEquals(structCount(c), arrayLen(details.issues), "every offending parameter is named: " & json.serialize(c));
				assertFalse(reFind("[0-9]", e.message) > 0, "the refusal carries no figure");
			}
		}
		// Section and question selection remain: they choose what is shown, not who is counted.
		var one = read(districtReportOnly, { "orgUnitId": S.c, "item": "comp_s1_q1" });
		assertEquals(1, arrayLen(one.items));
		assertEquals(10, one.population.walks);
		assertThrows(function() { read(districtReportOnly, { "releaseId": "not-a-guid" }); }, "ICFWalk.Validation", "INVALID_RELEASE_ID");
		assertThrows(function() { read(districtReportOnly, { "releaseId": db.newGuid() }); }, "ICFWalk.NotFound", "REPORT_RELEASE_NOT_FOUND");
	}

	// ---- populations -----------------------------------------------------------------------------

	/**
	 * Required proofs 1 and 2: a one-walk population and a population below the minimum return no
	 * categorical content at all -- and the release never even stored them, so no request of any
	 * kind can reach them. An empty school looks exactly the same.
	 */
	public void function testOneWalkAndBelowMinimumPopulationsAreWithheldAndNeverStored() {
		for (var name in ["a", "b"]) {
			var stored = db.scalar("SELECT COUNT(*) AS n FROM [icf].[report_release_block] WHERE release_id = :r AND org_unit_id = :u", { "r": db.guid(rel.releaseId), "u": db.guid(S[name]) })
				+ db.scalar("SELECT COUNT(*) AS n FROM [icf].[report_release_cell] WHERE release_id = :r AND org_unit_id = :u", { "r": db.guid(rel.releaseId), "u": db.guid(S[name]) });
			assertEquals(0, stored, "school " & name & " (" & arrayLen(walkIds[name]) & " walk(s)) is not in the release at all");
		}
		var shapes = {};
		for (var name in ["a", "b", "e"]) {
			var r = read(districtReportOnly, { "orgUnitId": S[name] });
			assertTrue(r.population.withheld, name & " is withheld");
			assertTrue(isNull(r.population.walks), name & ": not even the count");
			assertEquals(0, structCount(r.population.byStatus));
			assertEquals(0, arrayLen(r.orgUnits) + arrayLen(r.dimensions) + arrayLen(r.items) + arrayLen(r.sections), name & ": nothing categorical");
			var csv = svc.exportCsv(p(districtReportOnly), { "releaseId": rel.releaseId, "orgUnitId": S[name] }).text;
			assertContains(chr(10) & "POPULATION,,walks,,,1,,," & chr(13), chr(10) & csv, name & ": the export withholds the count and says so");
			for (var kind in ["ITEM", "OPTION", "DIMENSION_VALUE", "DIMENSION_STATE", "ITEM_STATE", "SECTION", "ORG_UNIT"]) assertFalse(find(chr(10) & kind & ",", csv) > 0, name & ": no " & kind & " record");
			var copy = duplicate(r);
			structDelete(copy, "generatedAt");
			structDelete(copy.filters, "orgUnitId");
			shapes[name] = json.serialize(copy);
		}
		assertExactTextEquals(shapes.e, shapes.a, "one walk looks exactly like no walk");
		assertExactTextEquals(shapes.e, shapes.b, "two walks look exactly like no walk");
		// The school report-only role's own school, exactly at the minimum, is reported.
		var d = read(districtReportOnly, { "orgUnitId": S.d });
		assertEquals(3, d.population.walks, "a block of exactly k walks is released");
	}

	/** Required proof 7: a release counts completed walks only -- no draft, and no status breakdown to split. */
	public void function testOnlyCompletedWalksOfThePeriodAreReleasedWithNoStatusSplit() {
		var r = read(districtReportOnly, { "orgUnitId": S.c });
		assertEquals(10, r.population.walks, "the draft and the walk before the period are not counted");
		assertExactJsonEquals({ "COMPLETED": 10 }, r.population.byStatus);
		assertExactJsonEquals(["COMPLETED"], r.filters.statuses);
		assertThrows(function() { read(districtReportOnly, { "orgUnitId": S.c, "includeDrafts": "true" }); }, "ICFWalk.Validation", "REPORT_FILTER_NOT_PERMITTED");
		var district = read(districtReportOnly);
		assertEquals(13, district.population.walks, "C (10) and D (3); A (1) and B (2) never were released");
		var units = [];
		for (var u in district.orgUnits) arrayAppend(units, u.orgUnitId);
		arraySort(units, "text");
		var expected = [uCase(S.c), uCase(S.d)];
		arraySort(expected, "text");
		assertExactJsonEquals(expected, units);
	}

	// ---- cells -----------------------------------------------------------------------------------

	/** Required proofs 3, 4, 8: small option and item-state cells, and a mean on too few ratings. */
	public void function testSmallItemCellsAndTheirComplementsAreWithheld() {
		var r = read(districtReportOnly, { "orgUnitId": S.c });
		var q1 = itemOf(r, "comp_s1_q1");
		assertWithheld(optionOf(q1, "2"), "count", "the single rating of 2");
		assertTrue(optionOf(q1, "2").withheld);
		assertWithheld(optionOf(q1, "5"), "count", "its complement, the four ratings of 5");
		assertTrue(optionOf(q1, "5").withheld);
		assertEquals(5, optionOf(q1, "4").count, "a cell of k or more is published");
		assertFalse(optionOf(q1, "4").withheld);
		assertEquals(0, optionOf(q1, "1").count, "a zero is published: it identifies nobody");
		assertEquals(5, q1.withheldResponses, "the withheld total is the population less what is shown");
		assertEquals(5, q1.scored.responses, "the mean is of published ratings only");
		assertEquals(4, q1.scored.mean);
		assertTrue(q1.scored.withheld, "and says some ratings are withheld");
		// ANSWERED is derived from the options, so it is their published part -- 5, a lower bound --
		// flagged as incomplete; the withheld options' own counts are never in it.
		assertEquals(5, q1.states.ANSWERED);
		assertTrue(arrayContains(q1.withheldStates, "ANSWERED"));

		var q2 = itemOf(r, "comp_s2_q2");
		assertWithheld(q2.states, "UNANSWERED", "the single unanswered walk");
		assertTrue(arrayContains(q2.withheldStates, "UNANSWERED"));
		assertWithheld(optionOf(q2, "4"), "count", "its complement");
		assertEquals(6, optionOf(q2, "3").count);
		assertEquals(0, q2.states.HIDDEN);

		var few = itemOf(r, "comp_s2_q1");
		for (var o in few.options) {
			assertWithheld(o, "count", "every option of a breakdown with nothing safe to publish");
			assertTrue(o.withheld);
		}
		for (var stateKey in ["ANSWERED", "UNANSWERED", "HIDDEN", "NOT_APPLICABLE", "UNRECORDED"]) assertWithheld(few.states, stateKey, "state " & stateKey & " of a withheld breakdown");
		assertTrue(isNull(few.scored.mean) && isNull(few.scored.responses) && isNull(few.scored.sum), "a mean of 2 ratings is withheld");
		assertTrue(few.scored.withheld);
	}

	/** Required proof 9: a section mean resting on fewer than k published ratings is withheld. */
	public void function testASectionMeanOnTooFewRatingsIsWithheld() {
		var r = read(districtReportOnly, { "orgUnitId": S.c, "section": "s6" });
		var s6 = sectionOf(r, "s6");
		assertTrue(isNull(s6.scored.responses) && isNull(s6.scored.mean) && isNull(s6.scored.sum), "two ratings in the whole section");
		assertTrue(s6.scored.withheld);
		// A section with enough published ratings keeps its mean, marked as partial when it is.
		var s2 = sectionOf(read(districtReportOnly, { "orgUnitId": S.c, "section": "s2" }), "s2");
		assertEquals(6, s2.scored.responses, "comp_s2_q1 is withheld whole; comp_s2_q2's six 3s are published");
		assertEquals(3, s2.scored.mean);
		assertTrue(s2.scored.withheld);
	}

	/** Required proofs 5 and 6: small dimension-value and dimension-state cells. */
	public void function testSmallDimensionValueAndStateCellsAreWithheld() {
		var r = read(districtReportOnly, { "orgUnitId": S.c });
		var timing = dimensionOf(r, "visitTiming");
		assertEquals(6, valueOf(timing, "beginning_of_lesson").walks);
		assertWithheld(valueOf(timing, "middle_of_the_lesson"), "walks", "three middle-of-lesson visits, the complement");
		assertWithheld(timing.states, "UNANSWERED", "the one walk with no visit timing");
		assertTrue(arrayContains(timing.withheldStates, "UNANSWERED"));
		assertEquals(0, timing.states.HIDDEN);
		// Grade has one grade-3 walk, and Period and the PreK-K section follow Grade: the whole group
		// is withheld in this block, so Period's HIDDEN count cannot give the grade-3 walk back.
		var grade = dimensionOf(r, "grade");
		for (var v in grade.values) assertWithheld(v, "walks", "grade " & v.code);
		var period = dimensionOf(r, "period");
		for (var v in period.values) assertWithheld(v, "walks", "period " & v.code);
		assertWithheld(period.states, "HIDDEN", "Period HIDDEN (= the grade-3 walk)");
		assertWithheld(itemOf(r, "prek_k_q1").states, "HIDDEN", "a PreK-K item's HIDDEN count (= every walk not PreK or K)");
		// Content has no small cell anywhere in its group, so it and its section are complete.
		assertEquals(10, valueOf(dimensionOf(r, "content"), "math").walks);
		assertEquals(10, itemOf(r, "content_area_q1").states.HIDDEN);
	}

	/**
	 * Required proof 10: a withheld cell cannot be recovered by subtracting visible cells from a
	 * visible total. In every breakdown of a one-block report, either nothing is withheld, or at
	 * least two categories are and they hide at least k walks between them. (That no algorithm-aware
	 * reader can pin them either is ReportDisclosureTest's exhaustive proof.)
	 */
	public void function testNoBreakdownWithholdsASingleRecoverableCell() {
		var withheldSomewhere = 0;
		for (var name in ["c", "d"]) {
			var r = read(districtReportOnly, { "orgUnitId": S[name] });
			for (var b in breakdowns(r)) {
				if (b.withheld == 0) {
					assertEquals(0, b.hidden, name & " " & b.subject & " shows everything");
					continue;
				}
				withheldSomewhere++;
				assertTrue(b.withheld >= 2, name & " " & b.subject & " withholds a single category, which the total would give back");
				assertTrue(b.hidden >= k, name & " " & b.subject & " hides only " & b.hidden & " walks between its withheld categories");
			}
		}
		assertTrue(withheldSomewhere >= 5, "the fixture exercises the rule (" & withheldSomewhere & " breakdowns withheld something)");
	}

	// ---- differencing ----------------------------------------------------------------------------

	/**
	 * Required proof 11: the district figure is exactly the sum of what each school's own release
	 * publishes, so district minus schools gives back nothing a school report withholds -- and
	 * nothing at all of A and B, which were never released.
	 */
	public void function testTheDistrictIsTheSumOfWhatEachSchoolPublishes() {
		var district = read(districtReportOnly);
		var c = read(districtReportOnly, { "orgUnitId": S.c });
		var d = read(districtReportOnly, { "orgUnitId": S.d });

		var compared = 0;
		for (var it in district.items) {
			var ci = itemOf(c, it.itemKey);
			var di = itemOf(d, it.itemKey);
			for (var o in it.options) {
				var co = optionOf(ci, o.code);
				var dox = optionOf(di, o.code);
				assertEquals(figure(co, "count") + figure(dox, "count"), figure(o, "count"), it.itemKey & " option " & o.code);
				assertEquals(co.withheld || dox.withheld, o.withheld, it.itemKey & " option " & o.code & " withheld flag");
				compared++;
			}
			for (var stateKey in ["UNANSWERED", "HIDDEN", "NOT_APPLICABLE", "UNRECORDED"]) {
				assertEquals(figure(ci.states, stateKey) + figure(di.states, stateKey), figure(it.states, stateKey), it.itemKey & " " & stateKey);
			}
		}
		for (var dim in district.dimensions) {
			for (var v in dim.values) {
				assertEquals(figure(valueOf(dimensionOf(c, dim.code), v.code), "walks") + figure(valueOf(dimensionOf(d, dim.code), v.code), "walks"), figure(v, "walks"), dim.code & " " & v.code);
				compared++;
			}
		}
		assertTrue(compared > 200, "every option and value was compared (" & compared & ")");
		// The rating of 2 at C stays withheld at district level: no school publishes it.
		var q1 = itemOf(district, "comp_s1_q1");
		assertWithheld(optionOf(q1, "2"), "count", "the district's rating of 2");
		assertEquals(3, optionOf(q1, "3").count, "D's three 3s");
		// A school report-only user sees exactly what the district user sees for that school.
		assertExactTextEquals(figures(read(districtReportOnly, { "orgUnitId": S.c })), figures(read(schoolReportOnly)), "the same block, whoever reads it");
	}

	/**
	 * Required proof 11, over time: a release never changes. Completing, editing and voiding walks
	 * of the period after the release -- the changes that would make two live reports differ by one
	 * walk -- leave every released figure exactly as it was.
	 */
	public void function testAReleaseDoesNotChangeWhenWalksDo() {
		var liveC = svc.aggregate(p(liveUser), { "orgUnitId": S.c, "from": period.start, "to": period.end, "item": "comp_s1_q1" });
		var liveD = svc.aggregate(p(liveUser), { "orgUnitId": S.d, "from": period.start, "to": period.end }).population.walks;
		var beforeDistrict = stable(read(districtReportOnly));
		var beforeC = stable(read(districtReportOnly, { "orgUnitId": S.c }));
		var extra = makeWalk("c", period.start, "7", "beginning_of_lesson", { "comp_s1_q1": "1" });
		var edited = walkIds.c[1];
		var row = variables.c.walkRepository.findWalk(edited);
		walkSvc.save(p(walker.c), edited, { "rowVersion": row.rowVersion, "clientMutationId": db.newGuid(),
			"dimensions": { "date": { "dateValue": period.start }, "grade": { "selectedValueCode": "7" }, "period": { "selectedValueCode": "first" }, "content": { "selectedValueCode": "math" }, "classType": { "selectedValueCode": "general_education" }, "visitTiming": { "selectedValueCode": "beginning_of_lesson" } },
			"responses": { "p1q1": { "storedCode": "Partial" }, "p1q2": { "storedCode": "Retrieval" }, "p1q3": { "storedCode": "Analysis" }, "part1_adopted_pacing": { "storedCode": "on" }, "part1_adopted_ac1": { "storedCode": "3" }, "part1_adopted_ac2": { "storedCode": "4" }, "part1_targettask_tt1": { "storedCode": "5" }, "part1_targettask_tt2": { "storedCode": "2" }, "comp_s1_q1": { "storedCode": "1" }, "comp_s2_q2": { "storedCode": "3" } } });
		var voided = walkIds.d[1];
		var drow = variables.c.walkRepository.findWalk(voided);
		walkSvc.void(p(walker.d), voided, { "rowVersion": drow.rowVersion, "clientMutationId": db.newGuid(), "reason": "Fixture void" });
		assertExactTextEquals(beforeDistrict, stable(read(districtReportOnly)), "the district release is unchanged");
		assertExactTextEquals(beforeC, stable(read(districtReportOnly, { "orgUnitId": S.c })), "the school release is unchanged");
		// ...while the live figures did move, so the comparison is not vacuous.
		var live = svc.aggregate(p(liveUser), { "orgUnitId": S.c, "from": period.start, "to": period.end, "item": "comp_s1_q1" });
		assertEquals(liveC.population.walks + 1, live.population.walks, "one more walk, live");
		assertEquals(optionOf(itemOf(liveC, "comp_s1_q1"), "1").count + 2, optionOf(itemOf(live, "comp_s1_q1"), "1").count, "the new walk and the edited one both rate 1, live");
		assertEquals(liveD - 1, svc.aggregate(p(liveUser), { "orgUnitId": S.d, "from": period.start, "to": period.end }).population.walks, "one voided, live");
	}

	/** Required proof 11, across periods: releases never overlap, so none can be subtracted from another. */
	public void function testReleasedDatesNeverOverlap() {
		var overlapping = [[period.start, period.end], [before, period.start], [period.end, later], [dayText(parseDateText(period.start), 1), dayText(parseDateText(period.start), 1)], [before, later]];
		for (var span in overlapping) {
			assertThrows(function() { makeRelease(span[1], span[2]); }, "ICFWalk.Conflict", "REPORT_RELEASE_OVERLAP");
		}
		// The database refuses it too, whatever writes the row.
		var direct = false;
		try {
			db.run("INSERT INTO [icf].[report_release] (release_id, observed_from, observed_to, minimum_walks, released_by_user_id) VALUES (:id, CAST(:s AS date), CAST(:e AS date), 3, :u)",
				{ "id": db.guid(db.newGuid()), "s": db.nvarchar(period.end, 10), "e": db.nvarchar(later, 10), "u": db.guid(releaser.userId) });
		} catch (any e) {
			direct = findNoCase("another release covers", e.message) > 0 || (structKeyExists(e, "detail") && findNoCase("another release covers", e.detail) > 0);
		}
		assertTrue(direct, "TR_report_release_no_overlap refuses an overlapping row");
		// An adjacent period is a different set of walks and may be released.
		var next = makeRelease(dayText(parseDateText(period.end), 1), dayText(parseDateText(period.end), 3)).release;
		assertEquals(0, db.scalar("SELECT COUNT(*) AS n FROM [icf].[report_release_block] WHERE release_id = :r", { "r": db.guid(next.releaseId) }), "no fixture walk falls in it");
	}

	private date function parseDateText(required string text) {
		return createDate(val(left(arguments.text, 4)), val(mid(arguments.text, 6, 2)), val(right(arguments.text, 2)));
	}

	// ---- surfaces --------------------------------------------------------------------------------

	/** Required proofs 12 and 13: the CSV carries exactly the JSON's figures and never one it withholds. */
	public void function testTheExportCarriesExactlyWhatTheJsonPublishes() {
		var q = { "releaseId": rel.releaseId, "orgUnitId": S.c };
		var r = svc.aggregate(p(districtReportOnly), q);
		var text = svc.exportCsv(p(districtReportOnly), q).text;
		var lines = listToArray(mid(text, 2, len(text)), chr(13) & chr(10), false, true);
		assertExactTextEquals("record_type,group,key,label,count,withheld,scored_responses,score_sum,mean", lines[1]);
		var rows = {};
		for (var line in lines) {
			var cells = listToArray(line, ",", true);
			if (arrayLen(cells) < 6) continue;
			rows[cells[1] & "|" & cells[2] & "|" & cells[3]] = { "count": cells[5], "withheld": cells[6] };
		}
		var checked = 0;
		for (var it in r.items) {
			for (var o in it.options) {
				var row = rows["OPTION|" & it.itemKey & "|" & o.code];
				assertExactTextEquals(isNull(o.count) ? "" : toString(o.count), row.count, it.itemKey & " option " & o.code);
				assertExactTextEquals(o.withheld ? "1" : "0", row.withheld, it.itemKey & " option " & o.code & " flag");
				checked++;
			}
			for (var stateKey in ["ANSWERED", "UNANSWERED", "HIDDEN", "NOT_APPLICABLE", "UNRECORDED"]) {
				var row = rows["ITEM_STATE|" & it.itemKey & "|" & stateKey];
				assertExactTextEquals(isNull(it.states[stateKey]) ? "" : toString(it.states[stateKey]), row.count, it.itemKey & " " & stateKey);
				assertExactTextEquals(arrayContains(it.withheldStates, stateKey) ? "1" : "0", row.withheld, it.itemKey & " " & stateKey & " flag");
				checked++;
			}
		}
		for (var d in r.dimensions) {
			for (var v in d.values) {
				var row = rows["DIMENSION_VALUE|" & d.code & "|" & v.code];
				assertExactTextEquals(isNull(v.walks) ? "" : toString(v.walks), row.count, d.code & " " & v.code);
				assertExactTextEquals(v.withheld ? "1" : "0", row.withheld);
				checked++;
			}
			for (var stateKey in ["ANSWERED", "UNANSWERED", "HIDDEN"]) {
				var row = rows["DIMENSION_STATE|" & d.code & "|" & stateKey];
				assertExactTextEquals(isNull(d.states[stateKey]) ? "" : toString(d.states[stateKey]), row.count, d.code & " " & stateKey);
				checked++;
			}
		}
		assertTrue(checked > 400, "every figure compared (" & checked & ")");
		assertContains(chr(10) & "OPTION,comp_s1_q1,2,2,,1,,," & chr(13), chr(10) & text, "the withheld rating of 2 is an empty count flagged withheld");
		assertContains(chr(10) & "META,,mode,RELEASE,,,,," & chr(13), chr(10) & text);
		assertContains(chr(10) & "META,,minimum_walks," & k & ",,,,," & chr(13), chr(10) & text);
	}

	/**
	 * Required proof 15: the log, the export audit and the release audit carry identifiers and
	 * published counts only, and neither narrative nor a withheld figure reaches any of them.
	 */
	public void function testLogsAndAuditCarryNoWithheldFigureOrNarrative() {
		var logger = createObject("component", "icfwalktests.support.CapturingLogger").init(variables.c.logger, json);
		var capturing = createObject("component", "icfwalk.reports.ReportService").init(
			variables.c.config, variables.c.db, variables.c.errors, logger, variables.c.auditRepository, variables.c.canonicalJson,
			variables.c.authorizationService, variables.c.snapshotService, variables.c.visibilityEngine, variables.c.walkRepository,
			variables.c.orgUnitRepository, variables.c.reportRepository);
		var auditBefore = db.scalar("SELECT ISNULL(MAX(event_id), 0) AS n FROM [icf].[audit_event]");
		capturing.aggregate(p(districtReportOnly), { "releaseId": rel.releaseId, "orgUnitId": S.c });
		capturing.exportCsv(p(districtReportOnly), { "releaseId": rel.releaseId, "orgUnitId": S.a });
		var exportAudit = db.run("SELECT details_json FROM [icf].[audit_event] WHERE event_id > :n AND actor_user_id = :u AND event_type = N'REPORT_EXPORTED'",
			{ "n": db.bigint(auditBefore), "u": db.guid(districtReportOnly.userId) });
		assertEquals(1, exportAudit.recordCount);
		var details = deserializeJSON(exportAudit.details_json[1]);
		var keys = structKeyArray(details);
		arraySort(keys, "text");
		assertExactJsonEquals(["attempts", "bytes", "filters", "mode", "orgUnitId", "releaseId", "rows", "versionId", "walks", "withheld"], keys, "identifiers and counts only");
		assertEquals(-1, details.walks, "a withheld population is not recorded as a count");
		assertTrue(details.withheld);
		var generated = 0;
		for (var line in logger.lines()) {
			var e = deserializeJSON(line);
			if (e.event != "report.generated") continue;
			generated++;
			var fields = structKeyArray(e.fields);
			arraySort(fields, "text");
			assertExactJsonEquals(["attempts", "filters", "items", "mode", "ms", "versionId", "walks"], fields, "the report log line");
			assertTrue(e.fields.walks == 10 || e.fields.walks == -1, "the published population, or -1 when it is withheld: " & e.fields.walks);
		}
		assertEquals(2, generated, "one line per report (the export runs one)");
		var released = db.run("SELECT details_json FROM [icf].[audit_event] WHERE event_type = N'REPORT_RELEASED' AND actor_user_id = :u", { "u": db.guid(releaser.userId) });
		assertTrue(released.recordCount >= 1);
		var rk = structKeyArray(deserializeJSON(released.details_json[1]));
		arraySort(rk, "text");
		assertExactJsonEquals(["attempts", "blocks", "minimumWalks", "observedFrom", "observedTo", "releaseId", "versions"], rk);
		var everything = arrayToList(logger.lines(), chr(10)) & exportAudit.details_json[1] & released.details_json[1];
		assertFalse(find("REL-NOTE-SENTINEL", everything) > 0, "no narrative");
		for (var id in walkIds.c) assertFalse(find(id, everything) > 0, "no walk id");
	}

	// ---- creating a release ----------------------------------------------------------------------

	public void function testOnlySomeoneWhoCanOpenEveryWalkMayRelease() {
		var before = db.scalar("SELECT COUNT(*) AS n FROM [icf].[audit_event] WHERE event_type = N'ACCESS_DENIED' AND actor_user_id IN (:a, :b)",
			{ "a": db.guid(districtReportOnly.userId), "b": db.guid(liveUser.userId) });
		for (var who in [districtReportOnly, liveUser, schoolReportOnly]) {
			assertThrows(function() { makeRelease(dayText(parseDateText(period.end), 5), dayText(parseDateText(period.end), 6), who); }, "ICFWalk.Forbidden", "REPORT_RELEASE_NOT_PERMITTED");
			assertFalse(svc.options(p(who), {}).canRelease);
		}
		var after = db.scalar("SELECT COUNT(*) AS n FROM [icf].[audit_event] WHERE event_type = N'ACCESS_DENIED' AND actor_user_id IN (:a, :b)",
			{ "a": db.guid(districtReportOnly.userId), "b": db.guid(liveUser.userId) });
		assertEquals(before + 2, after, "each refusal is audited");
		assertTrue(svc.options(p(releaser), {}).canRelease);
	}

	public void function testAReleaseRequestIsExactlyAClosedPeriod() {
		var today = dateConvert("local2utc", now());
		var todayText = dateFormat(today, "yyyy-mm-dd");
		var cases = [
			[{ "observedFrom": period.start }, "REPORT_RELEASE_BODY_INVALID"],
			[{ "observedFrom": period.start, "observedTo": period.end, "minimumWalks": 1 }, "REPORT_RELEASE_BODY_INVALID"],
			[{ "observedFrom": period.start, "observedTo": period.end, "releasedBy": districtReportOnly.userId }, "REPORT_RELEASE_BODY_INVALID"],
			[{ "observedFrom": "1920-02-30", "observedTo": "1920-03-01" }, "REPORT_RELEASE_DATES_INVALID"],
			[{ "observedFrom": "03/01/1920", "observedTo": "1920-03-01" }, "REPORT_RELEASE_DATES_INVALID"],
			[{ "observedFrom": "1920-03-02", "observedTo": "1920-03-01" }, "REPORT_RELEASE_DATES_INVALID"],
			[{ "observedFrom": "1920-03-01", "observedTo": todayText }, "REPORT_RELEASE_DATES_OPEN"],
			[{ "observedFrom": "1920-03-01", "observedTo": 19200301 }, "REPORT_RELEASE_DATES_INVALID"]
		];
		for (var c in cases) {
			assertThrows(function() { svc.createRelease(p(releaser), c[1]); }, "ICFWalk.Validation", c[2]);
		}
		assertEquals(k, rel.minimumWalks, "the release records the minimum it was made with");
	}
}
