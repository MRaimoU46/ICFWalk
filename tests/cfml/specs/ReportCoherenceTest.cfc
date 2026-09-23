/**
 * Phase 7: a report counts every walk in exactly one committed state, never a mixture.
 *
 * THE HAZARD. A report reads many walks in several statements: the population, the dimension
 * aggregates, then the item aggregates. A save commits a walk's dimension and response changes
 * together, and it can commit between two of those statements. Without a check, the report would
 * then pair one committed state's Grade with another committed state's rating for the same walk --
 * a combination the walk never held. For a single walk the Phase 5 export solved this by holding
 * the walk mutation lock; a report over a district cannot hold every walk's lock without stalling
 * every autosave in scope, so it validates optimistically instead, with the row version every
 * mutation already moves (ReportRepository, "COHERENCE").
 *
 * HOW THE INTERLEAVING IS FORCED. Deterministically, never by timing. InterceptingReportRepository
 * fires at itemCounts before delegating, so the callback runs after the population's row versions
 * were captured and every dimension aggregate was read, and before any response is read. A real
 * second session runs a real SAVE through the real walk service there and is joined -- it commits,
 * because a report holds no lock a writer waits on -- and only then does the report go on to read
 * the responses. Uncorrected, that report carries state A's Grade beside state B's rating.
 *
 * The same guarantee holds when a release is created (ReportService.createRelease): it freezes
 * each block from one coherent read, so a release can never store a walk's Grade from one state
 * beside its rating from another (testAReleaseFreezesEveryWalkInOneCommittedState).
 *
 * The analyst is a walk-and-report role: live figures are served only to a caller who can open
 * every walk they count (RPT-03 correction), and live figures are what this spec is about.
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
		variables.fx = createObject("component", "icfwalktests.support.Fixtures").init(variables.c, "rptcoh-" & lCase(left(replace(createUUID(), "-", "", "all"), 8)));
		variables.db = variables.c.db;
		variables.walkSvc = variables.c.walkService;
		variables.DT = fx.orgUnit("dt", "DISTRICT");
		variables.analyst = fx.user("analyst");
		fx.assign(analyst.userId, "DISTRICT_WALK_REPORT", DT, true);
		variables.seq = 0;
		variables.releases = [];
	}

	public void function afterAll() {
		for (var id in variables.releases) {
			db.run("DELETE FROM [icf].[report_release_cell] WHERE release_id = :id", { "id": db.guid(id) });
			db.run("DELETE FROM [icf].[report_release_block] WHERE release_id = :id", { "id": db.guid(id) });
			db.run("DELETE FROM [icf].[report_release_walk] WHERE release_id = :id", { "id": db.guid(id) });
			db.run("DELETE FROM [icf].[report_release] WHERE release_id = :id", { "id": db.guid(id) });
		}
		fx.remove();
	}

	// ---- the two states ----------------------------------------------------------------------------
	//
	// A and B differ in a dimension (Grade 7 / 8) and in a rating (comp_s1_q1 1 / 5). Every committed
	// state of the walk pairs 7 with 1 or 8 with 5; a report showing 7 with 5 read two states.

	private struct function answers(required string rating) {
		return {
			"p1q1": { "storedCode": "Partial" }, "p1q2": { "storedCode": "Retrieval" }, "p1q3": { "storedCode": "Analysis" },
			"part1_adopted_pacing": { "storedCode": "on" }, "part1_adopted_ac1": { "storedCode": "3" }, "part1_adopted_ac2": { "storedCode": "4" },
			"part1_targettask_tt1": { "storedCode": "5" }, "part1_targettask_tt2": { "storedCode": "2" },
			"comp_s1_q1": { "storedCode": arguments.rating }
		};
	}

	private struct function stateA() { return { "dimensions": { "grade": { "selectedValueCode": "7" } }, "responses": answers("1") }; }
	private struct function stateB() { return { "dimensions": { "grade": { "selectedValueCode": "8" } }, "responses": answers("5") }; }

	// ---- helpers -----------------------------------------------------------------------------------

	private struct function p(required struct user) { return fx.principal(arguments.user.userId); }

	/** Its own school and walker, and one walk there completed in state A. */
	private struct function scenario() {
		variables.seq++;
		var unit = fx.orgUnit("s" & variables.seq, "SCHOOL", variables.DT);
		var walker = fx.user("walker" & variables.seq);
		fx.assign(walker.userId, "SCHOOL_WALK_REPORT", unit, false);
		var principal = p(walker);
		var created = walkSvc.create(principal, { "orgUnitId": unit, "clientMutationId": db.newGuid() });
		var a = stateA();
		var saved = walkSvc.save(principal, created.id, { "rowVersion": created.rowVersion, "clientMutationId": db.newGuid(), "dimensions": a.dimensions, "responses": a.responses });
		var done = walkSvc.complete(principal, created.id, { "rowVersion": saved.rowVersion, "clientMutationId": db.newGuid() });
		return { "unit": unit, "walker": walker, "walkId": created.id, "rowVersion": done.rowVersion };
	}

	private any function serviceWith(required any reportRepository) {
		return createObject("component", "icfwalk.reports.ReportService").init(
			variables.c.config, variables.c.db, variables.c.errors, variables.c.logger, variables.c.auditRepository, variables.c.canonicalJson,
			variables.c.authorizationService, variables.c.snapshotService, variables.c.visibilityEngine, variables.c.walkRepository,
			variables.c.orgUnitRepository, arguments.reportRepository
		);
	}

	private any function interceptor() {
		return createObject("component", "icfwalktests.support.InterceptingReportRepository").init(variables.c.reportRepository);
	}

	private string function storedRowVersion(required string walkId) {
		return db.run("SELECT CONVERT(varchar(18), CAST(row_version AS binary(8)), 1) AS rv FROM [icf].[walk] WHERE walk_id = :id", { "id": db.guid(arguments.walkId) }).rv[1];
	}

	private numeric function valueWalks(required struct r, required string dimensionCode, required string valueCode) {
		for (var d in arguments.r.dimensions) {
			if (compare(d.code, arguments.dimensionCode) != 0) continue;
			for (var v in d.values) if (compare(v.code, arguments.valueCode) == 0) return v.walks;
		}
		fail(arguments.dimensionCode & "=" & arguments.valueCode & " is not in the report");
	}

	private numeric function optionCount(required struct r, required string itemKey, required string code) {
		for (var it in arguments.r.items) {
			if (compare(it.itemKey, arguments.itemKey) != 0) continue;
			for (var o in it.options) if (compare(o.code, arguments.code) == 0) return o.count;
		}
		fail(arguments.itemKey & "=" & arguments.code & " is not in the report");
	}

	/** True when the report pairs state A's Grade with state B's rating, or the reverse. */
	private boolean function isMixed(required struct r) {
		return (valueWalks(arguments.r, "grade", "7") == 1 && optionCount(arguments.r, "comp_s1_q1", "5") == 1)
			|| (valueWalks(arguments.r, "grade", "8") == 1 && optionCount(arguments.r, "comp_s1_q1", "1") == 1);
	}

	// ---- the scenarios ------------------------------------------------------------------------------

	/**
	 * A save that commits between the dimension aggregates and the item aggregates is detected, the
	 * report is recomputed, and what comes back is state B throughout. The writer is not held up:
	 * it commits while the report is mid-computation, which is the point of validating instead of
	 * locking.
	 */
	public void function testAReportThatStraddlesACommittedSaveIsRecomputedCoherently() {
		var s = scenario();
		var spy = interceptor();
		var reportSvc = serviceWith(spy);
		var observed = { "status": "", "outcome": "", "before": storedRowVersion(s.walkId), "after": "" };
		var writerSvc = variables.walkSvc;
		var writer = p(s.walker);
		var b = stateB();
		var walkId = s.walkId;
		var rv = s.rowVersion;
		var mutationId = db.newGuid();

		spy.arm("itemCounts", function() {
			thread name="reportCoherenceWriter" svc=writerSvc who=writer wid=walkId rv=rv mid=mutationId payload=b {
				try {
					attributes.svc.save(attributes.who, attributes.wid, {
						"rowVersion": attributes.rv, "clientMutationId": attributes.mid,
						"dimensions": attributes.payload.dimensions, "responses": attributes.payload.responses
					});
					thread.outcome = "committed";
				} catch (any e) {
					thread.outcome = structKeyExists(e, "errorcode") ? e.errorcode : e.type;
				}
			}
			threadJoin("reportCoherenceWriter", 20000);
			observed.status = cfthread.reportCoherenceWriter.status;
			observed.outcome = structKeyExists(cfthread.reportCoherenceWriter, "outcome") ? cfthread.reportCoherenceWriter.outcome : "";
			observed.after = storedRowVersion(walkId);
		});

		var r = "";
		try {
			r = reportSvc.aggregate(p(analyst), { "orgUnitId": s.unit });
		} finally {
			if (isDefined("cfthread") && structKeyExists(cfthread, "reportCoherenceWriter")) threadJoin("reportCoherenceWriter", 30000);
		}

		// The save committed in the middle of the report: nothing the report held made it wait.
		assertEquals(1, spy.fired("itemCounts"), "the save was run between the dimension and the item aggregates");
		assertExactTextEquals("COMPLETED", observed.status, "the concurrent save ran to completion while the report was mid-computation");
		assertExactTextEquals("committed", observed.outcome, "and it committed");
		assertRowVersionChanged(observed.before, observed.after, "the walk moved while the report was reading it");

		// The report describes one committed state -- never state A's grade beside state B's rating,
		// which is what a report that read straight through the save would have returned.
		assertFalse(isMixed(r), "the report mixes two committed states of one walk: grade 7 = " & valueWalks(r, "grade", "7") & ", grade 8 = " & valueWalks(r, "grade", "8") & ", rating 1 = " & optionCount(r, "comp_s1_q1", "1") & ", rating 5 = " & optionCount(r, "comp_s1_q1", "5"));
		// And that state is B, in every part of it.
		assertEquals(1, r.population.walks);
		assertEquals(1, valueWalks(r, "grade", "8"));
		assertEquals(0, valueWalks(r, "grade", "7"));
		assertEquals(1, optionCount(r, "comp_s1_q1", "5"));
		assertEquals(0, optionCount(r, "comp_s1_q1", "1"));

		// Because the report noticed and started over.
		assertEquals(2, spy.calls("selectCandidates"), "the population was selected again");
		assertEquals(2, spy.calls("verifyPopulation"));
		assertEquals(2, r.attempts);
	}

	/** A walk that leaves the population mid-report (voided) is not counted with half its data. */
	public void function testAWalkVoidedMidReportLeavesThePopulationCleanly() {
		var s = scenario();
		var spy = interceptor();
		var reportSvc = serviceWith(spy);
		var writerSvc = variables.walkSvc;
		var writer = p(s.walker);
		var walkId = s.walkId;
		var rv = s.rowVersion;
		var mutationId = db.newGuid();
		var observed = { "outcome": "" };
		spy.arm("itemCounts", function() {
			thread name="reportVoidWriter" svc=writerSvc who=writer wid=walkId rv=rv mid=mutationId {
				try {
					attributes.svc.void(attributes.who, attributes.wid, { "rowVersion": attributes.rv, "clientMutationId": attributes.mid, "reason": "Fixture void during a report" });
					thread.outcome = "committed";
				} catch (any e) {
					thread.outcome = structKeyExists(e, "errorcode") ? e.errorcode : e.type;
				}
			}
			threadJoin("reportVoidWriter", 20000);
			observed.outcome = structKeyExists(cfthread.reportVoidWriter, "outcome") ? cfthread.reportVoidWriter.outcome : "";
		});
		var r = "";
		try {
			r = reportSvc.aggregate(p(analyst), { "orgUnitId": s.unit });
		} finally {
			if (isDefined("cfthread") && structKeyExists(cfthread, "reportVoidWriter")) threadJoin("reportVoidWriter", 30000);
		}
		assertExactTextEquals("committed", observed.outcome);
		assertEquals(2, r.attempts);
		assertEquals(0, r.population.walks, "the voided walk is gone from the recomputed report");
		assertEquals(0, optionCount(r, "comp_s1_q1", "1"), "and none of its answers remain");
	}

	/** A population that never holds still is refused rather than reported. */
	public void function testAReportThatNeverSeesAStableStateIsRefused() {
		var s = scenario();
		var spy = interceptor();
		var reportSvc = serviceWith(spy);
		var writerSvc = variables.walkSvc;
		var writer = p(s.walker);
		var walkId = s.walkId;
		var churn = { "count": 0, "rv": s.rowVersion, "outcomes": [] };
		var states = [stateB(), stateA()];

		spy.armEvery("itemCounts", function() {
			churn.count++;
			var threadName = "reportChurnWriter" & churn.count;
			var payload = states[((churn.count - 1) mod 2) + 1];
			var mutationId = variables.db.newGuid();
			thread name=threadName svc=writerSvc who=writer wid=walkId rv=churn.rv mid=mutationId payload=payload {
				try {
					thread.rv = attributes.svc.save(attributes.who, attributes.wid, {
						"rowVersion": attributes.rv, "clientMutationId": attributes.mid,
						"dimensions": attributes.payload.dimensions, "responses": attributes.payload.responses
					}).rowVersion;
					thread.outcome = "committed";
				} catch (any e) {
					thread.outcome = structKeyExists(e, "errorcode") ? e.errorcode : e.type;
				}
			}
			threadJoin(threadName, 20000);
			arrayAppend(churn.outcomes, structKeyExists(cfthread[threadName], "outcome") ? cfthread[threadName].outcome : "");
			if (structKeyExists(cfthread[threadName], "rv")) churn.rv = cfthread[threadName].rv;
		});

		var e = assertThrows(function() { reportSvc.aggregate(p(analyst), { "orgUnitId": s.unit }); }, "ICFWalk.Conflict", "REPORT_POPULATION_CHANGED");
		assertEquals(3, spy.calls("selectCandidates"), "three attempts");
		assertEquals(3, churn.count, "each saw a save commit mid-report");
		assertExactJsonEquals(["committed", "committed", "committed"], churn.outcomes);
		var details = variables.c.errors.detailsOf(e);
		assertEquals(3, details.attempts);
	}

	/** Nothing moving: one attempt, one verification. */
	public void function testAStablePopulationIsReportedOnTheFirstAttempt() {
		var s = scenario();
		var spy = interceptor();
		var r = serviceWith(spy).aggregate(p(analyst), { "orgUnitId": s.unit });
		assertEquals(1, r.attempts);
		assertEquals(1, spy.calls("selectCandidates"));
		assertEquals(1, spy.calls("verifyPopulation"));
		assertEquals(1, valueWalks(r, "grade", "7"));
		assertEquals(1, optionCount(r, "comp_s1_q1", "1"));
	}

	/**
	 * A release reads every walk of its period in one coherent state, like a live report: a save
	 * that commits after the Grade aggregates were read and before the ratings are is detected by
	 * the row-version check, the freeze is recomputed, and what is stored pairs each walk's Grade
	 * with its own rating. Uncorrected, the block would hold three Grade 7s beside a rating of 5.
	 */
	public void function testAReleaseFreezesEveryWalkInOneCommittedState() {
		variables.seq++;
		var base = createDate(randRange(1930, 1939), randRange(1, 12), 1);
		var visit = dateFormat(base, "yyyy-mm-dd");
		var unit = fx.orgUnit("rel" & variables.seq, "SCHOOL", variables.DT);
		var walker = fx.user("relwalker" & variables.seq);
		fx.assign(walker.userId, "SCHOOL_WALK_REPORT", unit, false);
		var releaser = fx.user("releaser" & variables.seq);
		for (var id in structKeyArray(variables.c.orgUnitRepository.loadActiveTree())) fx.assign(releaser.userId, "DISTRICT_WALK_REPORT", id, false);
		var principal = p(walker);
		var ids = [];
		var rvs = [];
		for (var i = 1; i <= 3; i++) {
			var created = walkSvc.create(principal, { "orgUnitId": unit, "clientMutationId": db.newGuid() });
			var a = stateA();
			a.dimensions["date"] = { "dateValue": visit };
			var saved = walkSvc.save(principal, created.id, { "rowVersion": created.rowVersion, "clientMutationId": db.newGuid(), "dimensions": a.dimensions, "responses": a.responses });
			var done = walkSvc.complete(principal, created.id, { "rowVersion": saved.rowVersion, "clientMutationId": db.newGuid() });
			arrayAppend(ids, created.id);
			arrayAppend(rvs, done.rowVersion);
		}
		var spy = interceptor();
		var releaseSvc = serviceWith(spy);
		var writerSvc = variables.walkSvc;
		var walkId = ids[1];
		var rv = rvs[1];
		var mutationId = db.newGuid();
		var b = stateB();
		b.dimensions["date"] = { "dateValue": visit };
		var observed = { "outcome": "" };
		spy.arm("unitItemCounts", function() {
			thread name="releaseCoherenceWriter" svc=writerSvc who=principal wid=walkId rv=rv mid=mutationId payload=b {
				try {
					attributes.svc.save(attributes.who, attributes.wid, {
						"rowVersion": attributes.rv, "clientMutationId": attributes.mid,
						"dimensions": attributes.payload.dimensions, "responses": attributes.payload.responses
					});
					thread.outcome = "committed";
				} catch (any e) {
					thread.outcome = structKeyExists(e, "errorcode") ? e.errorcode : e.type;
				}
			}
			threadJoin("releaseCoherenceWriter", 20000);
			observed.outcome = structKeyExists(cfthread.releaseCoherenceWriter, "outcome") ? cfthread.releaseCoherenceWriter.outcome : "";
		});
		var created = "";
		try {
			created = releaseSvc.createRelease(p(releaser), { "observedFrom": visit, "observedTo": visit });
			arrayAppend(variables.releases, created.release.releaseId);
		} finally {
			if (isDefined("cfthread") && structKeyExists(cfthread, "releaseCoherenceWriter")) threadJoin("releaseCoherenceWriter", 30000);
		}
		assertExactTextEquals("committed", observed.outcome, "the save committed while the release was being frozen");
		assertEquals(1, spy.fired("unitItemCounts"));
		assertEquals(2, spy.calls("selectCandidates"), "the freeze saw the walk move and started over");
		var cells = db.run(
			"SELECT subject_key, category_code, responses FROM [icf].[report_release_cell]
			  WHERE release_id = :r AND org_unit_id = :u AND ((subject_type = N'DIMENSION' AND subject_key = N'grade') OR (subject_type = N'ITEM' AND subject_key = N'comp_s1_q1' AND category_type = N'OPTION'))
			  ORDER BY subject_key, category_code",
			{ "r": db.guid(created.release.releaseId), "u": db.guid(unit) });
		var stored = {};
		for (var r = 1; r <= cells.recordCount; r++) stored[cells.subject_key[r] & ":" & cells.category_code[r]] = cells.responses[r];
		assertExactJsonEquals({ "comp_s1_q1:1": 2, "comp_s1_q1:5": 1, "grade:7": 2, "grade:8": 1 }, stored, "each walk's Grade stored beside its own rating");
	}
}
