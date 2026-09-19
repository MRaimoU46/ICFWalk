/**
 * Phase 0-4 correction regressions for School / org-unit consistency.
 *
 * A walk conducted at a SCHOOL org unit must carry the School dimension value that names that
 * unit. Before the correction, walk.org_unit_id and the School dimension were independent: a walk
 * authorized at School A could be labelled School B or "Other", and reports would group it under a
 * school the author was never authorized for.
 *
 * The fixture tree uses two org units whose codes match real School dimension values
 * (bartlett_elementary_school, canton_middle_school) plus one unmapped SCHOOL unit, so both the
 * fill-and-lock path and the unaligned-deployment path are exercised. Everything is removed in
 * afterAll.
 */
component extends="icfwalktests.BaseSpec" output="false" {

	variables.MAPPED_A = "bartlett_elementary_school";
	variables.MAPPED_B = "canton_middle_school";

	public string function skipReason() {
		if (!schemaPresent()) return "icf schema is not present.";
		var current = variables.c.snapshotService.currentVersion();
		if (structIsEmpty(current)) return "no renderable instrument version is seeded.";
		var model = variables.c.snapshotService.renderModelFor(current.versionId);
		if (!structKeyExists(model.dimensions, variables.c.config.schoolDimensionCode)) return "the instrument has no School dimension.";
		return "";
	}

	public void function beforeAll() {
		variables.fx = createObject("component", "icfwalktests.support.Fixtures").init(variables.c, "school-" & lCase(left(replace(createUUID(), "-", "", "all"), 8)));
		variables.svc = variables.c.walkService;
		variables.db = variables.c.db;
		variables.schoolCode = variables.c.config.schoolDimensionCode;
		var fx = variables.fx;
		variables.D = fx.orgUnit("district", "DISTRICT");
		variables.A = fx.orgUnitExact(variables.MAPPED_A, "SCHOOL", variables.D);
		variables.B = fx.orgUnitExact(variables.MAPPED_B, "SCHOOL", variables.D);
		variables.UNMAPPED = fx.orgUnit("unmapped-school", "SCHOOL", variables.D);
		variables.OUTSIDE = fx.orgUnit("outside-district", "DISTRICT");

		variables.atA = fx.user("walker-a");
		fx.assign(variables.atA.userId, "SCHOOL_WALK_REPORT", variables.A, false);
		variables.atUnmapped = fx.user("walker-unmapped");
		fx.assign(variables.atUnmapped.userId, "SCHOOL_WALK_REPORT", variables.UNMAPPED, false);
		variables.districtUser = fx.user("district-walker");
		fx.assign(variables.districtUser.userId, "DISTRICT_WALK_REPORT", variables.D, true);
	}

	public void function afterAll() {
		variables.fx.remove();
	}

	private struct function p(required struct user) { return variables.fx.principal(arguments.user.userId); }
	private string function newMutationId() { return variables.db.newGuid(); }

	private query function schoolRow(required string walkId) {
		return variables.db.run(
			"SELECT x.text_value, dv.value_code FROM [icf].[walk_dimension_value] x JOIN [icf].[dimension_definition] d ON d.dimension_id = x.dimension_id LEFT JOIN [icf].[dimension_value] dv ON dv.value_id = x.selected_value_id WHERE x.walk_id = :id AND d.code = :code",
			{ "id": variables.db.guid(arguments.walkId), "code": variables.db.nvarchar(variables.schoolCode, 100) });
	}

	private struct function create(required struct user, required string orgUnitId, struct school) {
		var body = { "orgUnitId": arguments.orgUnitId, "clientMutationId": newMutationId(), "dimensions": {}, "responses": {} };
		if (!isNull(arguments.school)) body.dimensions[variables.schoolCode] = arguments.school;
		return variables.svc.create(p(arguments.user), body);
	}

	private struct function save(required struct user, required struct walk, required struct dims) {
		return variables.svc.save(p(arguments.user), arguments.walk.id, {
			"rowVersion": arguments.walk.rowVersion, "clientMutationId": newMutationId(), "dimensions": arguments.dims, "responses": {}
		});
	}

	// ---- the authorized unit is authoritative ----------------------------------------------------

	public void function testSchoolDimensionIsServerFilledFromTheAuthorizedUnit() {
		// The browser sends no School at all: the server fills the value naming the walk's unit.
		var w = create(variables.atA, variables.A);
		assertEquals(variables.MAPPED_A, w.state.dimensions[variables.schoolCode].selectedValueCode);
		assertEquals(variables.MAPPED_A, schoolRow(w.id).value_code[1]);
		// And it stays filled across a save that omits it.
		var saved = save(variables.atA, w, {});
		assertEquals(variables.MAPPED_A, saved.state.dimensions[variables.schoolCode].selectedValueCode);
		assertEquals(variables.MAPPED_A, schoolRow(w.id).value_code[1]);
		// Sending the matching value is accepted unchanged.
		var explicit = save(variables.atA, saved, { "#variables.schoolCode#": { "selectedValueCode": variables.MAPPED_A } });
		assertEquals(variables.MAPPED_A, schoolRow(w.id).value_code[1]);
	}

	public void function testAWalkAuthorizedAtSchoolACannotBeLabelledSchoolB() {
		var schoolCode = variables.schoolCode;
		var mappedB = variables.MAPPED_B;
		var unit = variables.A;
		var user = variables.atA;
		var e = assertThrows(function() { create(user, unit, { "selectedValueCode": mappedB }); }, "ICFWalk.Conflict", "SCHOOL_ORG_MISMATCH");
		assertEquals(0, variables.db.scalar("SELECT COUNT(*) AS n FROM [icf].[walk] WHERE org_unit_id = :id AND owner_user_id = :me AND created_at > DATEADD(second, -5, SYSUTCDATETIME())",
			{ "id": variables.db.guid(variables.A), "me": variables.db.guid(variables.atA.userId) }), "no walk was created");
		// The same on a save: the stored value never becomes School B.
		var w = create(variables.atA, variables.A);
		var walk = w;
		assertThrows(function() { save(user, walk, { "#schoolCode#": { "selectedValueCode": mappedB } }); }, "ICFWalk.Conflict", "SCHOOL_ORG_MISMATCH");
		assertEquals(variables.MAPPED_A, schoolRow(w.id).value_code[1]);
		assertEquals(w.rowVersion, variables.db.run("SELECT CONVERT(varchar(18), CAST(row_version AS binary(8)), 1) AS rv FROM [icf].[walk] WHERE walk_id = :id", { "id": variables.db.guid(w.id) }).rv[1], "nothing was written");
		// "Other" free text is a conflicting label too.
		assertThrows(function() { save(user, walk, { "#schoolCode#": { "selectedValueCode": "other", "otherText": "Somewhere else" } }); }, "ICFWalk.Conflict", "SCHOOL_ORG_MISMATCH");
		assertEquals(variables.MAPPED_A, schoolRow(w.id).value_code[1]);
		// The rejection is audited without carrying narrative content.
		var audit = variables.db.run("SELECT details_json FROM [icf].[audit_event] WHERE entity_type = N'WALK' AND event_type = N'WALK_SCHOOL_SCOPE_REJECTED' AND actor_user_id = :me ORDER BY event_id", { "me": variables.db.guid(variables.atA.userId) });
		assertTrue(audit.recordCount >= 2, "every rejection is audited");
		assertContains('"expectedSchool":"' & variables.MAPPED_A & '"', audit.details_json[1]);
	}

	// ---- district scope -------------------------------------------------------------------------

	public void function testDistrictUserMaySelectAnAuthorizedDescendantSchool() {
		// A district-scoped user creates at an authorized child SCHOOL; the School follows that unit.
		var atB = create(variables.districtUser, variables.B, { "selectedValueCode": variables.MAPPED_B });
		assertEquals(variables.B, atB.orgUnitId);
		assertEquals(variables.MAPPED_B, schoolRow(atB.id).value_code[1]);
		var atA = create(variables.districtUser, variables.A);
		assertEquals(variables.MAPPED_A, schoolRow(atA.id).value_code[1]);
		// But not at a unit outside the authorized subtree, and not labelled as another school.
		var outside = variables.OUTSIDE;
		var user = variables.districtUser;
		var schoolCode = variables.schoolCode;
		var mappedA = variables.MAPPED_A;
		var unitB = variables.B;
		assertThrows(function() { create(user, outside); }, "ICFWalk.NotFound");
		assertThrows(function() { create(user, unitB, { "selectedValueCode": mappedA }); }, "ICFWalk.Conflict", "SCHOOL_ORG_MISMATCH");
	}

	// ---- deployments whose org-unit codes are not aligned with the instrument ---------------------

	public void function testUnmappedSchoolUnitStillRefusesAnotherSchoolsLabel() {
		// No School value names this unit, so the server cannot fill one...
		var w = create(variables.atUnmapped, variables.UNMAPPED);
		assertEquals(0, schoolRow(w.id).recordCount, "nothing is invented for an unmapped unit");
		// ...but a value naming a different active SCHOOL org unit is still refused.
		var user = variables.atUnmapped;
		var walk = w;
		var schoolCode = variables.schoolCode;
		var mappedA = variables.MAPPED_A;
		assertThrows(function() { save(user, walk, { "#schoolCode#": { "selectedValueCode": mappedA } }); }, "ICFWalk.Conflict", "SCHOOL_ORG_MISMATCH");
		assertEquals(0, schoolRow(w.id).recordCount);
		// A School value that names no org unit at all is accepted: there is nothing to contradict.
		var free = save(variables.atUnmapped, w, { "#variables.schoolCode#": { "selectedValueCode": "other", "otherText": "Unlisted site" } });
		assertEquals("other", schoolRow(w.id).value_code[1]);
		assertEquals("Unlisted site", schoolRow(w.id).text_value[1]);
	}
}
