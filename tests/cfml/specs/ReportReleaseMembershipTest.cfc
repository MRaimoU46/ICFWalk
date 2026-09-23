/**
 * Phase 7 correction, audit finding P7C-02: a walk is counted by at most one release, ever.
 *
 * THE CONCERN. Released dates never overlap, and a release freezes the walks observed on its dates.
 * But a completed walk stays correctable, and its visit date decides observed_at, the date a release
 * selects by. Without more, correcting a released walk's date into later, unreleased dates would let
 * the next release count it again, and two releases that share a walk can be combined to learn
 * about it -- exactly what non-overlapping dates were meant to rule out.
 *
 * THE RULE (docs/DATA_CONTRACT.md, "Aggregate privacy rule (RPT-03)", release membership). Every walk
 * a release counts is recorded when the release is created, in icf.report_release_walk, keyed by the
 * walk alone: a walk can belong to one release, and the database refuses a second. A later release
 * never counts a walk an earlier release counted, wherever its date has moved. The walk itself stays
 * correctable, and the release that counted it keeps the figures it froze. A walk whose date is
 * corrected into dates already released is never released. Both outcomes disclose less, never more.
 *
 * Fixtures: district DM with school M, in a random month of 1945-1949, which no other suite uses.
 * Release A covers days 1-3 of the month and release B days 4-6.
 */
component extends="icfwalktests.BaseSpec" output="false" {

	public string function skipReason() {
		if (!schemaPresent()) return "icf schema is not present.";
		if (structIsEmpty(variables.c.snapshotService.currentVersion())) return "no renderable instrument version is seeded.";
		return "";
	}

	public void function beforeAll() {
		variables.fx = createObject("component", "icfwalktests.support.Fixtures").init(variables.c, "relm-" & lCase(left(replace(createUUID(), "-", "", "all"), 8)));
		variables.svc = variables.c.reportService;
		variables.walkSvc = variables.c.walkService;
		variables.db = variables.c.db;
		variables.base = createDate(randRange(1945, 1949), randRange(1, 12), 1);
		variables.DM = fx.orgUnit("dm", "DISTRICT");
		variables.M = fx.orgUnit("m", "SCHOOL", DM);
		variables.walker = fx.user("walker");
		fx.assign(walker.userId, "SCHOOL_WALK_REPORT", M, false);
		variables.reader = fx.user("district-report-only");
		fx.assign(reader.userId, "DISTRICT_REPORT_ONLY", DM, true);
		variables.releaser = fx.user("releaser");
		for (var id in structKeyArray(variables.c.orgUnitRepository.loadActiveTree())) fx.assign(releaser.userId, "DISTRICT_WALK_REPORT", id, false);
		variables.releases = [];
	}

	public void function afterAll() {
		for (var id in variables.releases) deleteRelease(id);
		var stray = db.run("SELECT release_id FROM [icf].[report_release] WHERE released_by_user_id = :u", { "u": db.guid(releaser.userId) });
		for (var r = 1; r <= stray.recordCount; r++) deleteRelease(stray.release_id[r]);
		fx.remove();
	}

	// ---- helpers -----------------------------------------------------------------------------------

	private string function dayText(required numeric day) {
		return dateFormat(dateAdd("d", arguments.day - 1, variables.base), "yyyy-mm-dd");
	}

	private struct function p(required struct user) { return fx.principal(arguments.user.userId); }

	private struct function state(required string day, required string rating) {
		return {
			"dimensions": { "date": { "dateValue": arguments.day }, "grade": { "selectedValueCode": "7" }, "period": { "selectedValueCode": "first" } },
			"responses": {
				"p1q1": { "storedCode": "Partial" }, "p1q2": { "storedCode": "Retrieval" }, "p1q3": { "storedCode": "Analysis" },
				"part1_adopted_pacing": { "storedCode": "on" }, "part1_adopted_ac1": { "storedCode": "3" }, "part1_adopted_ac2": { "storedCode": "4" },
				"part1_targettask_tt1": { "storedCode": "5" }, "part1_targettask_tt2": { "storedCode": "2" },
				"comp_s1_q1": { "storedCode": arguments.rating }
			}
		};
	}

	private string function makeWalk(required string day, required string rating) {
		var principal = p(walker);
		var created = walkSvc.create(principal, { "orgUnitId": M, "clientMutationId": db.newGuid() });
		var s = state(arguments.day, arguments.rating);
		var saved = walkSvc.save(principal, created.id, { "rowVersion": created.rowVersion, "clientMutationId": db.newGuid(), "dimensions": s.dimensions, "responses": s.responses });
		walkSvc.complete(principal, created.id, { "rowVersion": saved.rowVersion, "clientMutationId": db.newGuid() });
		return created.id;
	}

	/** An ordinary correction of a completed walk's visit date, through the walk service. */
	private void function correctDate(required string walkId, required string day, required string rating) {
		var row = variables.c.walkRepository.findWalk(arguments.walkId);
		var s = state(arguments.day, arguments.rating);
		walkSvc.save(p(walker), arguments.walkId, { "rowVersion": row.rowVersion, "clientMutationId": db.newGuid(), "dimensions": s.dimensions, "responses": s.responses });
	}

	private string function observedDay(required string walkId) {
		return db.run("SELECT CONVERT(char(10), observed_at, 23) AS d FROM [icf].[walk] WHERE walk_id = :id", { "id": db.guid(arguments.walkId) }).d[1];
	}

	private struct function release(required numeric fromDay, required numeric toDay) {
		var out = svc.createRelease(p(releaser), { "observedFrom": dayText(arguments.fromDay), "observedTo": dayText(arguments.toDay) }).release;
		arrayAppend(variables.releases, out.releaseId);
		return out;
	}

	/** How many of school M's walks a release counts, as its report-only reader sees it. */
	private numeric function counted(required struct rel) {
		return svc.aggregate(p(reader), { "releaseId": arguments.rel.releaseId, "orgUnitId": M }).population.walks;
	}

	private void function deleteRelease(required string id) {
		var key = { "id": db.guid(arguments.id) };
		db.run("DELETE FROM [icf].[report_release_cell] WHERE release_id = :id", key);
		db.run("DELETE FROM [icf].[report_release_block] WHERE release_id = :id", key);
		db.run("IF OBJECT_ID(N'[icf].[report_release_walk]', N'U') IS NOT NULL DELETE FROM [icf].[report_release_walk] WHERE release_id = :id", key);
		db.run("DELETE FROM [icf].[report_release] WHERE release_id = :id", key);
	}

	// ---- the cases ---------------------------------------------------------------------------------

	/**
	 * The audit's scenario. Release A counts a1..a3. a1's date is then corrected into B's dates, and
	 * b4's into A's. Release B must count b1..b3 only: a1 was already counted by A, and b4's dates
	 * are released. Uncorrected, B counts a1 a second time.
	 */
	public void function testAWalkWhoseDateIsCorrectedIntoLaterDatesIsNeverCountedByASecondRelease() {
		var a = [makeWalk(dayText(2), "1"), makeWalk(dayText(2), "1"), makeWalk(dayText(2), "1")];
		var b = [makeWalk(dayText(5), "5"), makeWalk(dayText(5), "5"), makeWalk(dayText(5), "5"), makeWalk(dayText(5), "5")];
		var relA = release(1, 3);
		assertEquals(3, counted(relA), "release A counts a1, a2 and a3");

		correctDate(a[1], dayText(5), "1");
		correctDate(b[4], dayText(2), "5");
		assertExactTextEquals(dayText(5), observedDay(a[1]), "the walk's own date was corrected: walks stay correctable after release");
		assertExactTextEquals(dayText(2), observedDay(b[4]), "and so was b4's");

		var relB = release(4, 6);
		assertEquals(3, counted(relB), "release B counts b1, b2 and b3 only: a1 was already counted by release A, so no two releases share it");
		assertEquals(3, counted(relA), "release A still counts what it froze");
		assertEquals(6, counted(relA) + counted(relB), "six walks were released, each exactly once");

		// The record behind it: each counted walk belongs to exactly one release.
		var members = db.run(
			"SELECT rw.walk_id, rw.release_id FROM [icf].[report_release_walk] rw WHERE rw.release_id IN (:a, :b)",
			{ "a": db.guid(relA.releaseId), "b": db.guid(relB.releaseId) }
		);
		var owner = {};
		for (var r = 1; r <= members.recordCount; r++) owner[uCase(members.walk_id[r])] = uCase(members.release_id[r]);
		assertEquals(6, members.recordCount, "six membership rows");
		for (var id in a) assertExactTextEquals(uCase(relA.releaseId), owner[uCase(id)], "a1..a3 belong to release A, a1 included");
		for (var i = 1; i <= 3; i++) assertExactTextEquals(uCase(relB.releaseId), owner[uCase(b[i])], "b1..b3 belong to release B");
		assertFalse(structKeyExists(owner, uCase(b[4])), "b4, corrected into released dates, belongs to no release");
	}

	/**
	 * A second writer that bypasses the service still cannot put a released walk into another
	 * release: the membership table is keyed by the walk.
	 */
	public void function testTheDatabaseRefusesToPutAReleasedWalkIntoAnotherRelease() {
		var w = [makeWalk(dayText(12), "3"), makeWalk(dayText(12), "3"), makeWalk(dayText(12), "3")];
		var relC = release(11, 13);
		var versionId = db.run("SELECT version_id FROM [icf].[walk] WHERE walk_id = :id", { "id": db.guid(w[1]) }).version_id[1];
		var thrown = "";
		try {
			db.transact(function() {
				var other = db.newGuid();
				db.run(
					"INSERT INTO [icf].[report_release] (release_id, observed_from, observed_to, minimum_walks, released_by_user_id)
					 VALUES (:id, CAST(:f AS date), CAST(:t AS date), 3, :u)",
					{ "id": db.guid(other), "f": db.nvarchar(dayText(20)), "t": db.nvarchar(dayText(21)), "u": db.guid(releaser.userId) }
				);
				db.run(
					"INSERT INTO [icf].[report_release_walk] (walk_id, release_id, version_id, org_unit_id) VALUES (:w, :r, :v, :o)",
					{ "w": db.guid(w[1]), "r": db.guid(other), "v": db.guid(versionId), "o": db.guid(M) }
				);
			});
		} catch (any e) {
			thrown = e.message;
		}
		assertTrue(findNoCase("PK_report_release_walk", thrown) > 0, "the database refuses a second release of the same walk: " & thrown);
		assertEquals(3, counted(relC), "and the first release is untouched");
	}
}
