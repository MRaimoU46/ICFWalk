/**
 * Phase 7 correction, audit finding P7C-01: concurrent reports are isolated from each other at the
 * boundary that enforces organizational scope.
 *
 * THE CONCERN. A report materializes the org units it may read, and then its walk population, in
 * temporary tables (ReportRepository, "THE POPULATION"), and every aggregate joins them. If two
 * requests could address the same tables -- "##" tables, which SQL Server makes global, or one
 * connection's tables reached from another pooled connection -- one report could block on, drop,
 * replace or read another request's scope. Scope would then no longer be decided per request.
 *
 * HOW IT IS PROVEN. With a barrier, never by timing. Report A pauses inside its transaction once its
 * scope and population are loaded (InterceptingReportRepository, before its first response
 * aggregate). While A is paused, request B runs to completion in a second session (cfthread: its own
 * page context, transaction and connection) and records what it saw at the same boundary: its own
 * connection, and every report table that existed at that instant. Only when B has finished, or 30
 * seconds have passed, does A go on. B must finish without waiting on A, both must succeed, and each
 * must count exactly its own school's walks. The barrier is run between two live reports on disjoint
 * scopes, and between a live report and a release in both orders. A report that fails after loading
 * its population must leave no table behind.
 *
 * Each scenario has its own schools: X with 3 walks rated 1, Y with 4 walks rated 5, observed on a
 * day of a random month in 1940-1944, which no other suite uses. The distinct ratings make any read
 * of the other school's walks visible.
 */
component extends="icfwalktests.BaseSpec" output="false" {

	variables.BARRIER_MS = 30000;
	variables.releases = [];
	variables.threads = [];

	public string function skipReason() {
		if (!schemaPresent()) return "icf schema is not present.";
		if (structIsEmpty(variables.c.snapshotService.currentVersion())) return "no renderable instrument version is seeded.";
		return "";
	}

	public void function beforeAll() {
		variables.fx = createObject("component", "icfwalktests.support.Fixtures").init(variables.c, "iso-" & lCase(left(replace(createUUID(), "-", "", "all"), 8)));
		variables.db = variables.c.db;
		variables.walkSvc = variables.c.walkService;
		variables.base = createDate(randRange(1940, 1944), randRange(1, 12), 1);
		variables.DI = fx.orgUnit("di", "DISTRICT");
		// The only kind of person who may release: walk.read on every active unit, including the
		// schools each scenario adds under DI later.
		variables.releaser = fx.user("releaser");
		for (var id in structKeyArray(variables.c.orgUnitRepository.loadActiveTree())) {
			if (compareNoCase(id, DI) != 0) fx.assign(releaser.userId, "DISTRICT_WALK_REPORT", id, false);
		}
		fx.assign(releaser.userId, "DISTRICT_WALK_REPORT", DI, true);
		variables.seq = 0;
	}

	public void function afterAll() {
		// A barrier that failed leaves its second session running; it must end before its fixtures go.
		for (var name in variables.threads) {
			try { threadJoin(name, 60000); } catch (any e) {}
		}
		if (!structKeyExists(variables, "fx")) return;
		for (var id in variables.releases) deleteRelease(id);
		if (structKeyExists(variables, "releaser")) {
			var stray = db.run("SELECT release_id FROM [icf].[report_release] WHERE released_by_user_id = :u", { "u": db.guid(releaser.userId) });
			for (var r = 1; r <= stray.recordCount; r++) deleteRelease(stray.release_id[r]);
		}
		fx.remove();
	}

	// ---- fixtures ----------------------------------------------------------------------------------

	private string function dayText(required numeric offset) {
		return dateFormat(dateAdd("d", arguments.offset, variables.base), "yyyy-mm-dd");
	}

	private struct function p(required struct user) { return fx.principal(arguments.user.userId); }

	/** Schools X (3 walks rated 1) and Y (4 walks rated 5) observed on `day`, and a live reader of each. */
	private struct function scenario(required string day) {
		variables.seq++;
		var s = { "day": arguments.day, "x": fx.orgUnit("x" & variables.seq, "SCHOOL", DI), "y": fx.orgUnit("y" & variables.seq, "SCHOOL", DI) };
		s.readerX = fx.user("reader-x" & variables.seq);
		fx.assign(s.readerX.userId, "SCHOOL_WALK_REPORT", s.x, false);
		s.readerY = fx.user("reader-y" & variables.seq);
		fx.assign(s.readerY.userId, "SCHOOL_WALK_REPORT", s.y, false);
		for (var i = 1; i <= 3; i++) makeWalk(s.readerX, s.x, arguments.day, "1");
		for (var i = 1; i <= 4; i++) makeWalk(s.readerY, s.y, arguments.day, "5");
		return s;
	}

	private void function makeWalk(required struct walker, required string unit, required string day, required string rating) {
		var principal = p(arguments.walker);
		var created = walkSvc.create(principal, { "orgUnitId": arguments.unit, "clientMutationId": db.newGuid() });
		var saved = walkSvc.save(principal, created.id, {
			"rowVersion": created.rowVersion, "clientMutationId": db.newGuid(),
			"dimensions": { "date": { "dateValue": arguments.day }, "grade": { "selectedValueCode": "7" }, "period": { "selectedValueCode": "first" } },
			"responses": {
				"p1q1": { "storedCode": "Partial" }, "p1q2": { "storedCode": "Retrieval" }, "p1q3": { "storedCode": "Analysis" },
				"part1_adopted_pacing": { "storedCode": "on" }, "part1_adopted_ac1": { "storedCode": "3" }, "part1_adopted_ac2": { "storedCode": "4" },
				"part1_targettask_tt1": { "storedCode": "5" }, "part1_targettask_tt2": { "storedCode": "2" },
				"comp_s1_q1": { "storedCode": arguments.rating }
			}
		});
		walkSvc.complete(principal, created.id, { "rowVersion": saved.rowVersion, "clientMutationId": db.newGuid() });
	}

	private any function interceptor() {
		return createObject("component", "icfwalktests.support.InterceptingReportRepository").init(variables.c.reportRepository);
	}

	private any function serviceWith(required any reportRepository) {
		return createObject("component", "icfwalk.reports.ReportService").init(
			variables.c.config, variables.c.db, variables.c.errors, variables.c.logger, variables.c.auditRepository, variables.c.canonicalJson,
			variables.c.authorizationService, variables.c.snapshotService, variables.c.visibilityEngine, variables.c.walkRepository,
			variables.c.orgUnitRepository, arguments.reportRepository
		);
	}

	private void function deleteRelease(required string id) {
		fx.deleteRelease(arguments.id);
	}

	// ---- observation -------------------------------------------------------------------------------

	/**
	 * What exists at this instant, seen from the calling session's own connection: that connection's
	 * id, the report tables of every session (connection-local "#" tables are listed in tempdb with a
	 * per-connection suffix), and any global "##" table at all. The patterns are built from chr(35),
	 * "#", so what they match is exactly what they say.
	 */
	private struct function snapshot() {
		var hash = chr(35);
		// NOLOCK: the catalog rows of a table another session created inside its open transaction are
		// locked until that transaction ends, and this observer must not wait on what it observes.
		var q = db.run(
			"SELECT @@SPID AS spid,
			        (SELECT COUNT(*) FROM tempdb.sys.tables WITH (NOLOCK) WHERE name LIKE :local) AS local_tables,
			        (SELECT COUNT(*) FROM tempdb.sys.tables WITH (NOLOCK) WHERE name LIKE :global) AS global_tables",
			{ "local": db.nvarchar(hash & "icf[_]r%"), "global": db.nvarchar(hash & hash & "%") }
		);
		return { "spid": q.spid[1], "localTables": q.local_tables[1], "globalTables": q.global_tables[1] };
	}

	/** Every request that is waiting on another session right now, and on what: the barrier's diagnosis. */
	private string function waits() {
		var q = db.run(
			"SELECT r.session_id, r.blocking_session_id, r.wait_type, r.wait_resource, r.command
			   FROM sys.dm_exec_requests r
			  WHERE r.blocking_session_id <> 0"
		);
		var out = [];
		for (var i = 1; i <= q.recordCount; i++) {
			arrayAppend(out, "session " & q.session_id[i] & " waits on " & q.blocking_session_id[i] & " (" & q.wait_type[i] & " " & q.wait_resource[i] & ", " & q.command[i] & ")");
		}
		return arrayLen(out) ? arrayToList(out, "; ") : "no session is waiting on another";
	}

	private struct function ratings(required struct report) {
		var out = { "walks": arguments.report.population.walks, "ones": 0, "fives": 0 };
		for (var it in arguments.report.items) {
			if (compare(it.itemKey, "comp_s1_q1") != 0) continue;
			for (var o in it.options) {
				if (o.code == "1") out.ones = o.count;
				if (o.code == "5") out.fives = o.count;
			}
		}
		return out;
	}

	private struct function releasedBlocks(required string releaseId) {
		var q = db.run("SELECT org_unit_id, walks FROM [icf].[report_release_block] WHERE release_id = :id", { "id": db.guid(arguments.releaseId) });
		var out = {};
		for (var r = 1; r <= q.recordCount; r++) out[uCase(q.org_unit_id[r])] = q.walks[r];
		return out;
	}

	/** B's result, read after it was joined: what it saw at the boundary and what it returned. */
	private struct function outcomeOf(required string name) {
		var t = cfthread[arguments.name];
		return {
			"status": t.status,
			"error": structKeyExists(t, "error") ? t.error : "",
			"boundary": structKeyExists(t, "boundary") ? t.boundary : {},
			"result": structKeyExists(t, "result") ? t.result : {}
		};
	}

	private string function threadName(required string label) {
		var name = "iso" & arguments.label & replace(createUUID(), "-", "", "all");
		arrayAppend(variables.threads, name);
		return name;
	}

	// ---- the barriers ------------------------------------------------------------------------------

	public void function testTwoReportsOnDisjointScopesAreIsolatedAtTheScopeBoundary() {
		var s = scenario(dayText(1));
		var query = { "from": s.day, "to": s.day };
		var before = snapshot();
		var a = interceptor();
		var seen = {};
		var nameB = threadName("Report");
		a.arm("itemCounts", function() {
			seen.a = snapshot();
			thread name=nameB action="run" who=p(s.readerY) q=query {
				try {
					var probe = interceptor();
					var boundary = {};
					probe.arm("itemCounts", function() { boundary.snapshot = snapshot(); });
					var r = serviceWith(probe).aggregate(attributes.who, attributes.q);
					thread.boundary = boundary.snapshot;
					thread.result = ratings(r);
				} catch (any e) {
					thread.error = e.type & ": " & e.message;
				}
			}
			threadJoin(nameB, variables.BARRIER_MS);
			seen.bStatusAtBarrier = cfthread[nameB].status;
			seen.waits = waits();
		});
		var reportA = ratings(serviceWith(a).aggregate(p(s.readerX), query));
		threadJoin(nameB, 60000);
		var b = outcomeOf(nameB);
		var after = snapshot();

		assertEquals(1, a.fired("itemCounts"), "report A paused at its boundary once");
		assertExactTextEquals("COMPLETED", seen.bStatusAtBarrier, "report B finished while report A held its scope and population: B did not wait on A (" & b.error & "; " & seen.waits & ")");
		assertExactTextEquals("", b.error, "report B succeeded");
		assertEquals(before.localTables + 2, seen.a.localTables, "at A's boundary, A's two report tables exist");
		assertEquals(before.localTables + 4, b.boundary.localTables, "at B's boundary, A's two tables and B's own two exist side by side");
		assertEquals(0, b.boundary.globalTables, "no global temporary table exists at the boundary");
		assertTrue(seen.a.spid != b.boundary.spid, "the two reports ran on different connections");
		assertExactJsonEquals({ "walks": 3, "ones": 3, "fives": 0 }, reportA, "report A counts exactly school X's walks");
		assertExactJsonEquals({ "walks": 4, "ones": 0, "fives": 4 }, b.result, "report B counts exactly school Y's walks");
		assertEquals(before.localTables, after.localTables, "neither report left a table behind");
	}

	public void function testALiveReportAndAReleaseAreIsolatedAtTheScopeBoundary() {
		var s = scenario(dayText(5));
		var query = { "from": s.day, "to": s.day };
		var body = { "observedFrom": dayText(4), "observedTo": dayText(6) };
		var before = snapshot();
		var a = interceptor();
		var seen = {};
		var nameB = threadName("Release");
		a.arm("itemCounts", function() {
			seen.a = snapshot();
			thread name=nameB action="run" who=p(releaser) body=body {
				try {
					var probe = interceptor();
					var boundary = {};
					probe.arm("unitItemCounts", function() { boundary.snapshot = snapshot(); });
					thread.result = serviceWith(probe).createRelease(attributes.who, attributes.body).release;
					thread.boundary = boundary.snapshot;
				} catch (any e) {
					thread.error = e.type & ": " & e.message;
				}
			}
			threadJoin(nameB, variables.BARRIER_MS);
			seen.bStatusAtBarrier = cfthread[nameB].status;
			seen.waits = waits();
		});
		var reportA = ratings(serviceWith(a).aggregate(p(s.readerX), query));
		threadJoin(nameB, 60000);
		var b = outcomeOf(nameB);
		if (structKeyExists(b.result, "releaseId")) arrayAppend(variables.releases, b.result.releaseId);

		assertExactTextEquals("COMPLETED", seen.bStatusAtBarrier, "the release finished while the live report held its scope and population (" & b.error & "; " & seen.waits & ")");
		assertExactTextEquals("", b.error, "the release succeeded");
		assertEquals(before.localTables + 4, b.boundary.localTables, "at the release's boundary, the report's two tables and the release's own two exist side by side");
		assertEquals(0, b.boundary.globalTables, "no global temporary table exists at the boundary");
		assertTrue(seen.a.spid != b.boundary.spid, "the report and the release ran on different connections");
		assertExactJsonEquals({ "walks": 3, "ones": 3, "fives": 0 }, reportA, "the live report counts exactly school X's walks");
		var blocks = releasedBlocks(b.result.releaseId);
		assertEquals(3, blocks[uCase(s.x)], "the release froze exactly school X's 3 walks");
		assertEquals(4, blocks[uCase(s.y)], "and exactly school Y's 4");
		assertEquals(before.localTables, snapshot().localTables, "neither left a table behind");
	}

	public void function testAReleaseAndALiveReportAreIsolatedAtTheScopeBoundary() {
		var s = scenario(dayText(9));
		var query = { "from": s.day, "to": s.day };
		var body = { "observedFrom": dayText(8), "observedTo": dayText(10) };
		var before = snapshot();
		var a = interceptor();
		var seen = {};
		var nameB = threadName("Live");
		a.arm("unitItemCounts", function() {
			seen.a = snapshot();
			thread name=nameB action="run" who=p(s.readerY) q=query {
				try {
					var probe = interceptor();
					var boundary = {};
					probe.arm("itemCounts", function() { boundary.snapshot = snapshot(); });
					var r = serviceWith(probe).aggregate(attributes.who, attributes.q);
					thread.boundary = boundary.snapshot;
					thread.result = ratings(r);
				} catch (any e) {
					thread.error = e.type & ": " & e.message;
				}
			}
			threadJoin(nameB, variables.BARRIER_MS);
			seen.bStatusAtBarrier = cfthread[nameB].status;
			seen.waits = waits();
		});
		var release = serviceWith(a).createRelease(p(releaser), body).release;
		arrayAppend(variables.releases, release.releaseId);
		threadJoin(nameB, 60000);
		var b = outcomeOf(nameB);

		assertEquals(1, a.fired("unitItemCounts"), "the release paused at its boundary once");
		assertExactTextEquals("COMPLETED", seen.bStatusAtBarrier, "the live report finished while the release held its scope, population and release lock (" & b.error & "; " & seen.waits & ")");
		assertExactTextEquals("", b.error, "the live report succeeded");
		assertEquals(before.localTables + 4, b.boundary.localTables, "at the report's boundary, the release's two tables and the report's own two exist side by side");
		assertEquals(0, b.boundary.globalTables, "no global temporary table exists at the boundary");
		assertTrue(seen.a.spid != b.boundary.spid, "the release and the report ran on different connections");
		assertExactJsonEquals({ "walks": 4, "ones": 0, "fives": 4 }, b.result, "the live report counts exactly school Y's walks");
		var blocks = releasedBlocks(release.releaseId);
		assertEquals(3, blocks[uCase(s.x)], "the release froze exactly school X's 3 walks");
		assertEquals(4, blocks[uCase(s.y)], "and exactly school Y's 4");
		assertEquals(before.localTables, snapshot().localTables, "neither left a table behind");
	}

	public void function testAReportLeavesNoPopulationTableBehindOnSuccessOrFailure() {
		var s = scenario(dayText(13));
		var query = { "from": s.day, "to": s.day };
		var before = snapshot();

		var ok = ratings(serviceWith(interceptor()).aggregate(p(s.readerX), query));
		assertExactJsonEquals({ "walks": 3, "ones": 3, "fives": 0 }, ok);
		assertEquals(before.localTables, snapshot().localTables, "a report that succeeded left no table behind");

		var failing = interceptor();
		var seen = {};
		failing.arm("itemCounts", function() {
			seen.during = snapshot();
			throw(type = "ICFWalk.TestFailure", message = "a failure after the population was loaded");
		});
		var thrown = "";
		try {
			serviceWith(failing).aggregate(p(s.readerX), query);
		} catch (any e) {
			thrown = e.type;
		}
		assertExactTextEquals("ICFWalk.TestFailure", thrown, "the report failed where it was made to");
		assertEquals(before.localTables + 2, seen.during.localTables, "its two tables existed when it failed");
		assertEquals(before.localTables, snapshot().localTables, "a report that failed left no table behind");
	}

	// ---- the guards the barriers rely on ------------------------------------------------------------

	public void function testPopulationTablesAreConnectionLocalAndUniquePerComputation() {
		var repo = variables.c.reportRepository;
		var names = db.transact(function() {
			var one = repo.beginPopulation();
			var two = repo.beginPopulation();
			repo.endPopulation(two);
			repo.endPopulation(one);
			return [one.pop, one.units, two.pop, two.units];
		});
		var pattern = "^" & chr(35) & "icf_r[pu]_[0-9A-F]{32}$";
		for (var name in names) {
			assertTrue(reFind(pattern, name) > 0, name & " is one " & chr(35) & ", icf_rp_ or icf_ru_, and 32 hex digits");
			assertTrue(mid(name, 2, 1) != chr(35), name & " is connection-local, not global");
		}
		assertTrue(names[1] != names[3] && names[2] != names[4], "two computations never share a table name");
	}

	public void function testAPopulationIsRefusedOutsideATransaction() {
		var repo = variables.c.reportRepository;
		assertThrows(function() { repo.beginPopulation(); }, "ICFWalk.Configuration", "REPORT_POPULATION_NO_TRANSACTION");
	}

	public void function testAPopulationRefusesToContinueOnAnotherConnection() {
		var repo = variables.c.reportRepository;
		var outcome = db.transact(function() {
			var population = repo.beginPopulation();
			var elsewhere = duplicate(population);
			elsewhere.spid = population.spid + 1;
			var refused = { "verify": "", "end": "" };
			try { repo.verifyPopulation(elsewhere); } catch (any e) { refused.verify = e.errorcode; }
			try { repo.endPopulation(elsewhere); } catch (any e) { refused.end = e.errorcode; }
			repo.endPopulation(population);
			return refused;
		});
		assertExactTextEquals("REPORT_POPULATION_CONNECTION_CHANGED", outcome.verify, "verification refuses a session other than the one that built the population");
		assertExactTextEquals("REPORT_POPULATION_CONNECTION_CHANGED", outcome.end, "and so does the cleanup");
	}
}
