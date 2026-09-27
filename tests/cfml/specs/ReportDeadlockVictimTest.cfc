/**
 * Finding A8-03 (Phase 8 independent audit): a live report that SQL Server chooses as a deadlock
 * victim is computed again, not answered with a 500.
 *
 * WHAT HAPPENED. Under the Phase 8 synthetic workload (drafts edited, 25 users, Lucee) live district
 * reports and their CSVs failed with 500 INTERNAL_ERROR. Traced by correlation id to the application's
 * request.failed events and to SQL Server's own deadlock graphs (docs/evidence/phase8-correction-a8),
 * every one was SQL Server error 1205: the report's aggregate scan of icf.walk_response held a shared
 * page lock and asked for the next page, while an autosave inserting response rows held an intent
 * lock on that next page and asked for the first. SQL Server ends one of the two; it ended the report
 * (READ COMMITTED takes shared locks while a statement reads, so a report does wait on, and hold up,
 * a writer for as long as one statement's scan). ReportService handled a moved walk (discard and
 * compute again, at most MAX_ATTEMPTS times) but not a deadlock, so the victim's error reached the
 * client.
 *
 * HOW THE DEADLOCK IS FORCED. Deterministically, and for real: nothing here imitates an exception.
 * InterceptingReportRepository fires at itemCounts, inside the report's transaction. There the report
 * takes an update lock on sentinel row A (a fixture user in icf.app_user, a table no report reads) and
 * starts a second session, which takes row B, announces it, and asks for A. The report then asks for
 * B. Each holds what the other wants: SQL Server's lock monitor finds the cycle (within about five
 * seconds) and ends one transaction with error 1205. The second session runs at DEADLOCK_PRIORITY
 * HIGH, so the report is always the one ended. The spec records the error number the report's
 * statement received before letting it propagate, so the evidence of a real deadlock victim is SQL
 * Server's own code, not an inference from timing.
 *
 * Fixtures are synthetic and removed in afterAll.
 */
component extends="icfwalktests.BaseSpec" output="false" {

	variables.SENTINEL_LOCK = "SELECT user_id FROM [icf].[app_user] WITH (UPDLOCK, ROWLOCK) WHERE user_id = :id";

	public string function skipReason() {
		if (!schemaPresent()) return "icf schema is not present.";
		if (structIsEmpty(variables.c.snapshotService.currentVersion())) return "no renderable instrument version is seeded.";
		return "";
	}

	public void function beforeAll() {
		variables.fx = createObject("component", "icfwalktests.support.Fixtures").init(variables.c, "rptdl-" & lCase(left(replace(createUUID(), "-", "", "all"), 8)));
		variables.DT = fx.orgUnit("dt", "DISTRICT");
		variables.analyst = fx.user("analyst");
		fx.assign(analyst.userId, "DISTRICT_WALK_REPORT", DT, true);
		// The two rows the deadlock forms on. No report statement reads icf.app_user.
		variables.rowA = fx.user("sentinel-a").userId;
		variables.rowB = fx.user("sentinel-b").userId;
		variables.threadSeq = 0;
		variables.otherRounds = {};
	}

	public void function afterAll() {
		fx.remove();
	}

	// ---- the scenarios ------------------------------------------------------------------------------

	/**
	 * The first attempt is ended by SQL Server as a deadlock victim; the report is computed again and
	 * answered. The other session, the one SQL Server let through, commits.
	 */
	public void function testAReportChosenAsADeadlockVictimIsComputedAgain() {
		var spy = interceptor();
		var logger = createObject("component", "icfwalktests.support.CapturingLogger").init(variables.c.logger, variables.c.canonicalJson);
		var reportSvc = serviceWith(spy, logger);
		var round = newRound();
		spy.arm("itemCounts", function() { deadlockHere(round); });

		var r = "";
		var failure = "";
		try {
			r = reportSvc.aggregate(fx.principal(analyst.userId), { "orgUnitId": DT });
		} catch (any e) {
			failure = e.type & ": " & errorText(e);
		} finally {
			joinOther(round);
		}

		// The deadlock was real, and the report was SQL Server's victim.
		assertTrue(round.barrier.signalledInOrder("REPORT_HOLDS_A", "OTHER_HOLDS_B"), "the report held row A before the other session took row B");
		assertTrue(round.barrier.observed("OTHER_REQUESTS_A"), "the other session asked for row A while holding row B");
		assertEquals(1205, round.victimNumber, "SQL Server ended the report's statement as a deadlock victim (error 1205): " & round.victimText);
		assertExactTextEquals("committed", round.otherResult, "the session SQL Server let through committed");

		// And the report was computed again instead of failing.
		assertExactTextEquals("", failure, "a report chosen as a deadlock victim is computed again, not answered with an error");
		assertEquals(1, spy.fired("itemCounts"), "only the first attempt met the deadlock");
		assertEquals(2, spy.calls("selectCandidates"), "the population was selected again");
		assertEquals(2, r.attempts, "the answer is the second attempt's");
		assertEquals(0, r.population.walks, "the district has no completed walk: nothing was counted twice or half");
		var retried = 0;
		for (var line in logger.lines()) if (find('"event":"report.deadlock.victim"', line) && find('"attempt":1', line)) retried++;
		assertEquals(1, retried, "the discarded attempt is logged, with its number: " & arrayToList(logger.events()));
	}

	/**
	 * The bound is the one a moved walk already has: a report that is the victim on every one of its
	 * MAX_ATTEMPTS attempts still fails, with the database's error rather than as
	 * REPORT_POPULATION_CHANGED, which would say something about the walks that is not true.
	 */
	public void function testAReportChosenAsTheVictimOnEveryAttemptStillFails() {
		var spy = interceptor();
		var reportSvc = serviceWith(spy, variables.c.logger);
		var seen = [];
		spy.armEvery("itemCounts", function() {
			var round = newRound();
			arrayAppend(seen, round);
			deadlockHere(round);
		});

		var failure = "";
		var failureCode = "";
		try {
			reportSvc.aggregate(fx.principal(analyst.userId), { "orgUnitId": DT });
		} catch (any e) {
			failure = errorText(e);
			failureCode = errorCodeOf(e);
		} finally {
			joinAll(seen);
		}

		assertEquals(3, spy.fired("itemCounts"), "every attempt, all three, met a deadlock");
		for (var each in seen) assertEquals(1205, each.victimNumber, "and each was ended by SQL Server as its victim: " & each.victimText);
		assertTrue(findNoCase("deadlock", failure) > 0, "after the third, the database's error is the answer: " & failure);
		assertExactTextNotEquals("REPORT_POPULATION_CHANGED", failureCode, "not a claim that the walks changed");
	}

	// ---- the deadlock ------------------------------------------------------------------------------

	/**
	 * Runs inside the report's transaction (the itemCounts seam): hold row A, let the other session
	 * take row B and ask for A, then ask for B. SQL Server ends the report's statement with 1205, which
	 * is recorded on the round and then propagates exactly as a real deadlock would.
	 */
	private void function deadlockHere(required struct round) {
		var db = variables.c.db;
		db.run(variables.SENTINEL_LOCK, { "id": db.guid(variables.rowA) });
		arguments.round.barrier.signal("REPORT_HOLDS_A");
		startOther(arguments.round);
		assertTrue(arguments.round.barrier.await("OTHER_REQUESTS_A", 60000), "the other session took row B and asked for row A");
		try {
			db.run(variables.SENTINEL_LOCK, { "id": db.guid(variables.rowB) });
		} catch (any e) {
			arguments.round.victimNumber = sqlErrorNumber(e);
			arguments.round.victimText = left(errorText(e), 300);
			rethrow;
		}
		fail("the report obtained row B, so no deadlock was formed");
	}

	/**
	 * The other session: its own thread, so its own connection and transaction. The thread only calls
	 * otherSession; the round is found through the variables scope (a thread's attributes are copies
	 * on Adobe ColdFusion).
	 */
	private void function startOther(required struct round) {
		variables.otherRounds[arguments.round.name] = arguments.round;
		thread name="#arguments.round.name#" roundName=arguments.round.name holds=variables.rowB wants=variables.rowA {
			try {
				thread.outcome = otherSession(attributes.roundName, attributes.holds, attributes.wants);
			} catch (any e) {
				thread.outcome = "failed: " & e.message;
			}
		}
	}

	/** Takes row B, announces it, and asks for row A, at a priority that makes the report the victim. */
	private string function otherSession(required string roundName, required string holdsId, required string wantsId) {
		var db = variables.c.db;
		var barrier = variables.otherRounds[arguments.roundName].barrier;
		var lockSql = variables.SENTINEL_LOCK;
		var first = arguments.holdsId;
		var second = arguments.wantsId;
		db.transact(function() {
			// SET is per connection, and a pooled connection keeps it: it is set and put back on the
			// transaction's own connection.
			db.run("SET DEADLOCK_PRIORITY HIGH");
			try {
				db.run(lockSql, { "id": db.guid(first) });
				barrier.signal("OTHER_HOLDS_B");
				barrier.signal("OTHER_REQUESTS_A");
				db.run(lockSql, { "id": db.guid(second) });
			} catch (any e) {
				db.run("SET DEADLOCK_PRIORITY NORMAL");
				rethrow;
			}
			db.run("SET DEADLOCK_PRIORITY NORMAL");
			// Db.transact returns what its function returns; a function that returns nothing leaves it
			// undefined on Lucee.
			return true;
		});
		return "committed";
	}

	// A loop is kept out of the finally block above: Lucee 6.2 emits bytecode its own verifier refuses
	// for a for-in loop inside finally ("Operand stack underflow"), and the spec would not load.
	private void function joinAll(required array roundsSeen) {
		for (var each in arguments.roundsSeen) joinOther(each);
	}

	private void function joinOther(required struct round) {
		if (!structKeyExists(variables.otherRounds, arguments.round.name)) return;
		threadJoin(arguments.round.name, 60000);
		var t = cfthread[arguments.round.name];
		arguments.round.otherStatus = t.status;
		arguments.round.otherResult = structKeyExists(t, "outcome") ? t.outcome : "";
	}

	/** One deadlock: its barrier, the other session's thread name, and what the report's statement received. */
	private struct function newRound() {
		variables.threadSeq++;
		var round = {
			"name": "reportDeadlock" & variables.threadSeq & lCase(left(replace(createUUID(), "-", "", "all"), 8)),
			"barrier": createObject("component", "icfwalktests.support.ConcurrencyBarrier").init(),
			"victimNumber": 0, "victimText": "", "otherStatus": "", "otherResult": ""
		};
		return round;
	}

	/** An exception's error code, or "" when it has none (a database exception may not). */
	private string function errorCodeOf(required any exception) {
		var code = "";
		try { code = arguments.exception.errorcode; } catch (any ignored) {}
		return isSimpleValue(code) ? code : "";
	}

	/** SQL Server's error number on a database exception, on either engine; 0 when there is none. */
	private numeric function sqlErrorNumber(required any exception) {
		var n = "";
		try { n = arguments.exception.nativeErrorCode; } catch (any ignored) {}
		return isNumeric(n) ? n : 0;
	}

	// ---- helpers -----------------------------------------------------------------------------------

	private any function serviceWith(required any reportRepository, required any logger) {
		return createObject("component", "icfwalk.reports.ReportService").init(
			variables.c.config, variables.c.db, variables.c.errors, arguments.logger, variables.c.auditRepository, variables.c.canonicalJson,
			variables.c.authorizationService, variables.c.snapshotService, variables.c.visibilityEngine, variables.c.walkRepository,
			variables.c.orgUnitRepository, arguments.reportRepository
		);
	}

	private any function interceptor() {
		return createObject("component", "icfwalktests.support.InterceptingReportRepository").init(variables.c.reportRepository);
	}
}
