/**
 * Phase 8, defect P8-11: My Walks reads the dimension values of the walks it lists, and no others.
 *
 * WalkRepository.listWalks returns at most LIST_LIMIT (500) walks, newest first, and then attaches
 * each one's dimension values. The second query selected them for every walk the list's WHERE clause
 * matched, not for the walks it had kept: a district walker's "all walks in my scope" read the
 * dimension values of the whole district -- every walk of every year -- to show 500 of them. On the
 * Phase 8 synthetic district (30,000 walks) that one request took 3.6 seconds and moved some 200,000
 * rows from SQL Server into the application, and it grows with every walk ever made.
 *
 * The spec gives a district reader 520 walks and checks, through a Db that records what it returns,
 * that the list is 500 walks long, that every one carries its dimension values, and that the
 * dimension read returned rows for those 500 walks only.
 */
component extends="icfwalktests.BaseSpec" output="false" {

	public string function skipReason() {
		return schemaPresent() ? "" : "database schema not applied";
	}

	public void function beforeAll() {
		variables.fx = new icfwalktests.support.Fixtures(variables.c, "p8list-" & lCase(left(replace(createUUID(), "-", "", "all"), 10)));
		var district = variables.fx.orgUnit("district", "DISTRICT");
		variables.school = variables.fx.orgUnit("school", "SCHOOL", district);
		variables.reader = variables.fx.user("reader");
		variables.fx.assign(variables.reader.userId, "DISTRICT_WALK_REPORT", district, true);
		var db = variables.c.db;
		var first = variables.fx.walk(variables.school, variables.reader.userId, "DRAFT");
		var dim = db.run("SELECT TOP 1 d.dimension_id FROM [icf].[instrument_dimension] i JOIN [icf].[dimension_definition] d ON d.dimension_id = i.dimension_id JOIN [icf].[walk] w ON w.version_id = i.version_id WHERE w.walk_id = :w AND d.code = N'observer'", { "w": db.guid(first) });
		variables.dimensionId = uCase(dim.dimension_id[1]);
		// 519 more walks like the first, each a second older, each with its observer recorded.
		db.run("
			WITH n AS (SELECT TOP 519 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i FROM sys.all_objects a CROSS JOIN sys.all_objects b)
			INSERT INTO [icf].[walk] (walk_id, version_id, org_unit_id, owner_user_id, status, observed_at, created_at, updated_at)
			SELECT NEWID(), w.version_id, w.org_unit_id, w.owner_user_id, N'DRAFT', w.observed_at, DATEADD(second, -n.i, w.created_at), DATEADD(second, -n.i, w.updated_at)
			FROM n CROSS JOIN [icf].[walk] w WHERE w.walk_id = :w", { "w": db.guid(first) });
		db.run("
			INSERT INTO [icf].[walk_dimension_value] (walk_id, version_id, dimension_id, text_value)
			SELECT w.walk_id, w.version_id, :d, N'Observer ' + CONVERT(nvarchar(40), w.walk_id)
			FROM [icf].[walk] w WHERE w.owner_user_id = :u", { "d": db.guid(variables.dimensionId), "u": db.guid(variables.reader.userId) });
	}

	public void function afterAll() {
		if (structKeyExists(variables, "fx")) {
			var db = variables.c.db;
			if (structKeyExists(variables, "reader")) {
				var owned = "SELECT walk_id FROM [icf].[walk] WHERE owner_user_id = :u";
				var u = { "u": db.guid(variables.reader.userId) };
				db.run("DELETE FROM [icf].[walk_dimension_value] WHERE walk_id IN (" & owned & ")", u);
				db.run("DELETE FROM [icf].[walk] WHERE owner_user_id = :u", u);
			}
			variables.fx.remove();
		}
	}

	public void function testAWideScopeReadsTheDimensionValuesOfTheListedWalksOnly() {
		var recording = new icfwalktests.support.RecordingDb(variables.c.db);
		var repo = new icfwalk.walks.WalkRepository(recording, variables.c.canonicalJson, variables.c.definitionRepository);
		var principal = variables.fx.principal(variables.reader.userId);
		var readUnits = variables.c.authorizationService.visibleOrgUnitIds(principal, "walk.read");
		var editUnits = variables.c.authorizationService.visibleOrgUnitIds(principal, "walk.edit_owned");
		var listed = repo.listWalks(variables.reader.userId, readUnits, editUnits, "all");

		assertEquals(500, arrayLen(listed), "the list keeps its limit");
		var ids = {};
		for (var w in listed) {
			ids[uCase(w.walkId)] = true;
			assertTrue(structKeyExists(w.dimensions, "observer"), "every listed walk carries its dimension values");
			assertExactTextEquals("Observer " & w.walkId, w.dimensions.observer.textValue);
		}
		var reads = recording.statementsContaining("walk_dimension_value");
		assertEquals(1, arrayLen(reads), "one dimension read");
		var result = reads[1].result;
		var outside = 0;
		for (var r = 1; r <= result.recordCount; r++) if (!structKeyExists(ids, uCase(result.walk_id[r]))) outside++;
		assertEquals(0, outside, "the dimension read returned " & result.recordCount & " rows, " & outside & " of them for walks the list did not keep");
	}

	public void function testMineStillListsTheOwnersWalksWithTheirValues() {
		var principal = variables.fx.principal(variables.reader.userId);
		var readUnits = variables.c.authorizationService.visibleOrgUnitIds(principal, "walk.read");
		var editUnits = variables.c.authorizationService.visibleOrgUnitIds(principal, "walk.edit_owned");
		var listed = variables.c.walkRepository.listWalks(variables.reader.userId, readUnits, editUnits, "mine");
		assertEquals(500, arrayLen(listed));
		for (var w in listed) assertTrue(structKeyExists(w.dimensions, "observer"));
	}
}
