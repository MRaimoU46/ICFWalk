/**
 * Acceptance AUTH-03 .. AUTH-09 at the authorization-service level with synthetic org units,
 * users, assignments, and bare walk rows. Every denial must fail closed and be audited.
 *
 * Fixture tree:   D (district) -> S1, S2 (schools);  X (district) -> SX (school)
 */
component extends="icfwalktests.BaseSpec" output="false" {

	public string function skipReason() {
		return schemaPresent() ? "" : "icf schema is not present.";
	}

	public void function beforeAll() {
		variables.fx = createObject("component", "icfwalktests.support.Fixtures").init(variables.c, "authz-" & lCase(left(replace(createUUID(), "-", "", "all"), 8)));
		variables.authz = variables.c.authorizationService;
		var fx = variables.fx;
		variables.D = fx.orgUnit("d", "DISTRICT");
		variables.S1 = fx.orgUnit("s1", "SCHOOL", variables.D);
		variables.S2 = fx.orgUnit("s2", "SCHOOL", variables.D);
		variables.X = fx.orgUnit("x", "DISTRICT");
		variables.SX = fx.orgUnit("sx", "SCHOOL", variables.X);
		variables.SINACTIVE = fx.orgUnit("s-inactive", "SCHOOL", variables.D, false);

		variables.districtWalker = fx.user("district-walker");
		fx.assign(variables.districtWalker.userId, "DISTRICT_WALK_REPORT", variables.D, true);
		variables.districtNoDesc = fx.user("district-nodesc");
		fx.assign(variables.districtNoDesc.userId, "DISTRICT_WALK_REPORT", variables.D, false);
		variables.districtReport = fx.user("district-report");
		fx.assign(variables.districtReport.userId, "DISTRICT_REPORT_ONLY", variables.D, true);
		variables.schoolWalker = fx.user("school-walker");
		fx.assign(variables.schoolWalker.userId, "SCHOOL_WALK_REPORT", variables.S1, false);
		variables.schoolReport = fx.user("school-report");
		fx.assign(variables.schoolReport.userId, "SCHOOL_REPORT_ONLY", variables.S1, false);
		variables.admin = fx.user("instrument-admin");
		fx.assign(variables.admin.userId, "MASTER_INSTRUMENT_ADMIN", variables.D, true);
		variables.future = fx.user("future");
		fx.assign(variables.future.userId, "SCHOOL_WALK_REPORT", variables.S1, false, dateAdd("d", 1, now()));
		variables.expired = fx.user("expired");
		fx.assign(variables.expired.userId, "SCHOOL_WALK_REPORT", variables.S1, false, dateAdd("d", -10, now()), dateAdd("d", -1, now()));
		variables.noRoles = fx.user("no-roles");
		variables.otherDistrictWalker = fx.user("x-walker");
		fx.assign(variables.otherDistrictWalker.userId, "DISTRICT_WALK_REPORT", variables.X, true);

		variables.w1 = fx.walk(variables.S1, variables.schoolWalker.userId);
		variables.w2 = fx.walk(variables.S2, variables.districtWalker.userId);
		variables.wx = fx.walk(variables.SX, variables.otherDistrictWalker.userId);
	}

	public void function afterAll() {
		variables.fx.remove();
	}

	// ---- AUTH-03: in-scope access is allowed according to role permissions ----------------------

	public void function testAuth03DistrictWalkRoleReachesWalksAcrossDescendantSchools() {
		var p = variables.fx.principal(variables.districtWalker.userId);
		assertTrue(variables.authz.can(p, "walk.create", variables.S1));
		assertTrue(variables.authz.can(p, "walk.create", variables.S2));
		assertTrue(variables.authz.can(p, "walk.read", variables.S1));
		assertTrue(variables.authz.can(p, "report.view", variables.D));
		assertFalse(variables.authz.can(p, "instrument.manage"));
		var access = variables.authz.authorizeWalk(p, variables.w1, "read");
		assertExactTextEquals(variables.S1, access.orgUnitId);
		assertFalse(access.isOwner);
		var own = variables.authz.authorizeWalk(p, variables.w2, "edit");
		assertTrue(own.isOwner);
		variables.authz.requirePermission(p, "walk.create", variables.S2);
	}

	public void function testSchoolWalkRoleWorksInsideItsOwnSchool() {
		var p = variables.fx.principal(variables.schoolWalker.userId);
		assertTrue(variables.authz.can(p, "walk.create", variables.S1));
		assertTrue(variables.authz.can(p, "walk.read", variables.S1));
		assertTrue(variables.authz.can(p, "report.view", variables.S1));
		var own = variables.authz.authorizeWalk(p, variables.w1, "edit");
		assertTrue(own.isOwner);
		assertEquals(1, arrayLen(variables.authz.visibleOrgUnitIds(p, "walk.read")));
	}

	// ---- AUTH-04: unassigned school is denied even with a known walk GUID ------------------------

	public void function testAuth04SchoolRoleCannotReachWalkInUnassignedSchool() {
		var p = variables.fx.principal(variables.schoolWalker.userId);
		var w2 = variables.w2;
		var wx = variables.wx;
		var s2 = variables.S2;
		assertFalse(variables.authz.can(p, "walk.read", variables.S2));
		assertThrows(function() { variables.authz.authorizeWalk(p, w2, "read"); }, "ICFWalk.NotFound");
		assertThrows(function() { variables.authz.authorizeWalk(p, wx, "read"); }, "ICFWalk.NotFound");
		assertThrows(function() { variables.authz.authorizeWalk(p, w2, "edit"); }, "ICFWalk.NotFound");
		assertThrows(function() { variables.authz.requirePermission(p, "walk.create", s2); }, "ICFWalk.NotFound");
		assertTrue(deniedAuditCount(variables.schoolWalker.userId) >= 4, "Each denial is audited.");
	}

	// ---- AUTH-05: report-only never reaches walk details or edits ------------------------------

	public void function testAuth05ReportOnlyRolesCannotOpenOrEditWalks() {
		for (var user in [variables.schoolReport, variables.districtReport]) {
			var p = variables.fx.principal(user.userId);
			var w1 = variables.w1;
			assertEquals(0, arrayLen(p.permissions["walk.read"]));
			assertEquals(0, arrayLen(p.permissions["walk.create"]));
			assertEquals(0, arrayLen(p.permissions["walk.edit_owned"]));
			assertTrue(arrayLen(p.permissions["report.view"]) >= 1);
			var e = assertThrows(function() { variables.authz.authorizeWalk(p, w1, "read"); }, "ICFWalk.Forbidden");
			assertFalse(find(w1, e.message) > 0, "Denial message must not echo identifiers.");
			assertThrows(function() { variables.authz.authorizeWalk(p, w1, "edit"); }, "ICFWalk.Forbidden");
			assertThrows(function() { variables.authz.requirePermission(p, "walk.read", variables.S1); }, "ICFWalk.Forbidden");
		}
		var schoolReport = variables.fx.principal(variables.schoolReport.userId);
		assertTrue(variables.authz.can(schoolReport, "report.view", variables.S1));
		assertFalse(variables.authz.can(schoolReport, "report.view", variables.S2));
	}

	// ---- AUTH-06: instrument admin is separate from walks and reports --------------------------

	public void function testAuth06InstrumentAdminHasNoWalkOrReportAccess() {
		var p = variables.fx.principal(variables.admin.userId);
		var w2 = variables.w2;
		var d = variables.D;
		assertTrue(variables.authz.can(p, "instrument.manage"));
		variables.authz.requirePermission(p, "instrument.manage");
		assertFalse(variables.authz.can(p, "walk.read"));
		assertFalse(variables.authz.can(p, "report.view"));
		assertThrows(function() { variables.authz.authorizeWalk(p, w2, "read"); }, "ICFWalk.Forbidden");
		assertThrows(function() { variables.authz.requirePermission(p, "report.view", d); }, "ICFWalk.Forbidden");
		var walker = variables.fx.principal(variables.districtWalker.userId);
		assertThrows(function() { variables.authz.requirePermission(walker, "instrument.manage"); }, "ICFWalk.Forbidden");
	}

	// ---- AUTH-07: effective dates ---------------------------------------------------------------

	public void function testAuth07NotYetEffectiveAndExpiredAssignmentsGrantNothing() {
		var s1 = variables.S1;
		for (var user in [variables.future, variables.expired, variables.noRoles]) {
			var p = variables.fx.principal(user.userId);
			assertEquals(0, arrayLen(p.assignments), "No effective assignment for " & user.subject);
			assertFalse(variables.authz.can(p, "walk.read", variables.S1));
			assertThrows(function() { variables.authz.requirePermission(p, "walk.create", s1); }, "ICFWalk.Forbidden");
		}
	}

	public void function testEndingAnAssignmentRevokesAccessImmediately() {
		var u = variables.fx.user("revoked");
		var assignmentId = variables.fx.assign(u.userId, "SCHOOL_WALK_REPORT", variables.S1, false);
		assertTrue(variables.authz.can(variables.fx.principal(u.userId), "walk.create", variables.S1));
		variables.c.roleScopeRepository.endAssignment(assignmentId);
		assertFalse(variables.authz.can(variables.fx.principal(u.userId), "walk.create", variables.S1));
	}

	// ---- AUTH-08: descendants -------------------------------------------------------------------

	public void function testAuth08IncludeDescendantsCoversOnlyTheAssignedBranch() {
		var withDesc = variables.fx.principal(variables.districtWalker.userId);
		var covered = withDesc.permissions["walk.read"];
		assertTrue(arrayContains(covered, variables.D));
		assertTrue(arrayContains(covered, variables.S1));
		assertTrue(arrayContains(covered, variables.S2));
		assertFalse(arrayContains(covered, variables.SX), "Unrelated branch excluded.");
		assertFalse(arrayContains(covered, variables.X));
		assertFalse(arrayContains(covered, variables.SINACTIVE), "Inactive descendants excluded.");
		var wx = variables.wx;
		assertThrows(function() { variables.authz.authorizeWalk(withDesc, wx, "read"); }, "ICFWalk.NotFound");

		var without = variables.fx.principal(variables.districtNoDesc.userId);
		assertEquals(1, arrayLen(without.permissions["walk.read"]));
		assertTrue(arrayContains(without.permissions["walk.read"], variables.D));
		assertFalse(variables.authz.can(without, "walk.read", variables.S1));
	}

	// ---- AUTH-09: tampered identifiers are re-resolved server side ------------------------------

	public void function testAuth09TamperedOrgUnitAndWalkIdentifiersAreRejected() {
		var p = variables.fx.principal(variables.schoolWalker.userId);
		var sx = variables.SX;
		var unknown = variables.c.db.newGuid();
		assertThrows(function() { variables.authz.requirePermission(p, "walk.create", sx); }, "ICFWalk.NotFound", "NOT_FOUND");
		assertThrows(function() { variables.authz.requirePermission(p, "walk.create", unknown); }, "ICFWalk.NotFound");
		assertThrows(function() { variables.authz.requirePermission(p, "walk.create", "not-a-guid"); }, "ICFWalk.Validation", "INVALID_ORG_UNIT");
		assertThrows(function() { variables.authz.requirePermission(p, "walk.create", "'; DROP TABLE icf.walk; --"); }, "ICFWalk.Validation");
		assertThrows(function() { variables.authz.authorizeWalk(p, unknown, "read"); }, "ICFWalk.NotFound");
		assertThrows(function() { variables.authz.authorizeWalk(p, "not-a-guid", "read"); }, "ICFWalk.Validation", "INVALID_WALK_ID");
		assertThrows(function() { variables.authz.resolveScopedOrgUnit(p, "walk.create", sx); }, "ICFWalk.NotFound");
		assertExactTextEquals(variables.S1, variables.authz.resolveScopedOrgUnit(p, "walk.create", lCase(variables.S1)), "Canonical id returned for an in-scope unit.");
		assertThrows(function() { variables.authz.requirePermission(p, "made.up"); }, "ICFWalk.Configuration", "UNKNOWN_PERMISSION");
	}

	// ---- owner rule and inactive states --------------------------------------------------------

	public void function testOnlyTheOwnerMayEditEvenWhenDetailsAreReadable() {
		var districtWalker = variables.fx.principal(variables.districtWalker.userId);
		var w1 = variables.w1;
		variables.authz.authorizeWalk(districtWalker, w1, "read");
		assertThrows(function() { variables.authz.authorizeWalk(districtWalker, w1, "edit"); }, "ICFWalk.Forbidden");
		assertThrows(function() { variables.authz.authorizeWalk(districtWalker, w1, "void"); }, "ICFWalk.Forbidden");
	}

	public void function testInactiveOrgUnitAssignmentGrantsNothing() {
		var u = variables.fx.user("inactive-unit");
		variables.fx.assign(u.userId, "SCHOOL_WALK_REPORT", variables.SINACTIVE, false);
		var p = variables.fx.principal(u.userId);
		assertEquals(0, arrayLen(p.assignments));
	}

	public void function testDeniedAccessIsAuditedWithoutNarrativeOrTokens() {
		var q = variables.c.db.run("SELECT TOP 1 details_json FROM [icf].[audit_event] WHERE event_type = N'ACCESS_DENIED' AND actor_user_id = :id ORDER BY event_id DESC", { "id": variables.c.db.guid(variables.schoolWalker.userId) });
		assertEquals(1, q.recordCount);
		var details = deserializeJSON(q.details_json[1]);
		assertTrue(structKeyExists(details, "permission"));
		assertTrue(structKeyExists(details, "kind"));
		assertFalse(structKeyExists(details, "notes"));
	}

	private numeric function deniedAuditCount(required string userId) {
		return variables.c.db.scalar("SELECT COUNT(*) AS n FROM [icf].[audit_event] WHERE event_type = N'ACCESS_DENIED' AND actor_user_id = :id", { "id": variables.c.db.guid(arguments.userId) });
	}
}
