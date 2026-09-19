/**
 * Phase 0-4 correction regressions for School / org-unit consistency.
 *
 * A walk conducted at a SCHOOL org unit must carry the School dimension value that unit is mapped
 * to. Before the first correction, walk.org_unit_id and the School dimension were independent: a
 * walk authorized at School A could be labelled School B or "Other". The first correction bound
 * them, but only through code equality (org_unit_code = the dimension's valueCode), which is a
 * coincidence of two independently owned namespaces rather than an identity relationship: in a
 * deployment whose org-unit codes are not the instrument's school value codes, nothing matched any
 * unit, so a walk at School A could still be stored carrying any School value at all.
 *
 * The identity relationship is now the explicit, validated mapping in icf.org_unit_dimension_map
 * (migration 005). This spec covers both sides of it:
 *
 *   - two SCHOOL units whose codes match no instrument School value and that carry no mapping: the
 *     School dimension fails closed (nothing filled, no value accepted);
 *   - the same two units once an explicit mapping is declared: fill-and-lock, and School A's walk
 *     can never be School B's value (the mapping is unique on (dimension, value));
 *   - a unit whose org_unit_code happens to equal an instrument School value but which has no
 *     mapping: still fails closed, because equality is not the relationship;
 *   - a district-authorized user selecting an authorized descendant SCHOOL;
 *   - that every rejection leaves the database and the walk's row version untouched.
 *
 * Everything is removed in afterAll.
 */
component extends="icfwalktests.BaseSpec" output="false" {

	// Instrument School values used for the explicit mappings. They are deliberately NOT the org
	// unit codes: the mapping, not code equality, is what binds them.
	variables.VALUE_A = "bartlett_elementary_school";
	variables.VALUE_B = "canton_middle_school";
	// An instrument School value that is also an existing org unit code in the example hierarchy,
	// used to prove that equality alone maps nothing.
	variables.VALUE_LOOKALIKE = "bartlett_high_school";

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
		variables.orgUnits = variables.c.orgUnitRepository;
		variables.schoolCode = variables.c.config.schoolDimensionCode;
		var fx = variables.fx;
		variables.D = fx.orgUnit("district", "DISTRICT");
		// Two SCHOOL units whose codes (tag-prefixed) match no instrument School value at all.
		variables.A = fx.orgUnit("school-a", "SCHOOL", variables.D);
		variables.B = fx.orgUnit("school-b", "SCHOOL", variables.D);
		// A third SCHOOL unit whose code IS an instrument School value, left unmapped on purpose.
		variables.LOOKALIKE = fx.orgUnitExact(variables.VALUE_LOOKALIKE, "SCHOOL", variables.D);
		variables.OUTSIDE = fx.orgUnit("outside-district", "DISTRICT");

		variables.atA = fx.user("walker-a");
		fx.assign(variables.atA.userId, "SCHOOL_WALK_REPORT", variables.A, false);
		variables.atLookalike = fx.user("walker-lookalike");
		fx.assign(variables.atLookalike.userId, "SCHOOL_WALK_REPORT", variables.LOOKALIKE, false);
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

	private string function storedRowVersion(required string walkId) {
		return variables.db.run("SELECT CONVERT(varchar(18), CAST(row_version AS binary(8)), 1) AS rv FROM [icf].[walk] WHERE walk_id = :id", { "id": variables.db.guid(arguments.walkId) }).rv[1];
	}

	private numeric function walkCountAt(required string orgUnitId, required string userId) {
		return variables.db.scalar(
			"SELECT COUNT(*) AS n FROM [icf].[walk] WHERE org_unit_id = :id AND owner_user_id = :me",
			{ "id": variables.db.guid(arguments.orgUnitId), "me": variables.db.guid(arguments.userId) });
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

	// ---- unmapped SCHOOL units fail closed -------------------------------------------------------

	/**
	 * The audited hole: two SCHOOL org units whose codes match no instrument School value. Nothing
	 * could contradict a School value there, so any value was accepted. Now nothing is filled and no
	 * value is accepted at all.
	 */
	public void function testUnmappedSchoolUnitsAcceptNoSchoolValue() {
		variables.fx.unmapSchool(variables.A);
		variables.fx.unmapSchool(variables.B);
		var user = variables.atA;
		var unit = variables.A;
		var schoolCode = variables.schoolCode;
		var valueA = variables.VALUE_A;
		var valueB = variables.VALUE_B;

		// Nothing is invented: a walk at an unmapped unit simply carries no School value.
		var w = create(variables.atA, variables.A);
		assertEquals(0, schoolRow(w.id).recordCount, "nothing is invented for an unmapped unit");
		assertFalse(structKeyExists(w.state.dimensions, schoolCode));

		// An arbitrary instrument School value is refused, whether or not it names another org unit.
		var before = walkCountAt(variables.A, variables.atA.userId);
		var rv = storedRowVersion(w.id);
		var walk = w;
		assertThrows(function() { save(user, walk, { "#schoolCode#": { "selectedValueCode": valueA } }); }, "ICFWalk.Conflict", "SCHOOL_ORG_UNMAPPED");
		assertThrows(function() { save(user, walk, { "#schoolCode#": { "selectedValueCode": valueB } }); }, "ICFWalk.Conflict", "SCHOOL_ORG_UNMAPPED");
		// "Other" free text is not a way around it either.
		assertThrows(function() { save(user, walk, { "#schoolCode#": { "selectedValueCode": "other", "otherText": "Somewhere else" } }); }, "ICFWalk.Conflict", "SCHOOL_ORG_UNMAPPED");
		// And a create carrying one writes no walk at all.
		assertThrows(function() { create(user, unit, { "selectedValueCode": valueA } ); }, "ICFWalk.Conflict", "SCHOOL_ORG_UNMAPPED");

		// No database change and no row version movement from any of the four rejections.
		assertEquals(0, schoolRow(w.id).recordCount);
		assertEquals(rv, storedRowVersion(w.id), "a rejected save does not advance the row version");
		assertEquals(before, walkCountAt(variables.A, variables.atA.userId), "a rejected create writes no walk");
		var audit = variables.db.run(
			"SELECT details_json FROM [icf].[audit_event] WHERE entity_type = N'WALK' AND event_type = N'WALK_SCHOOL_SCOPE_UNMAPPED' AND actor_user_id = :me ORDER BY event_id",
			{ "me": variables.db.guid(variables.atA.userId) });
		assertTrue(audit.recordCount >= 4, "every fail-closed rejection is audited");
	}

	/**
	 * A SCHOOL unit whose org_unit_code IS an instrument School value, with no mapping row: still
	 * fails closed. Code equality is not the identity relationship, and the previous correction's
	 * fill-and-lock must not come back through it.
	 */
	public void function testCodeEqualityAloneMapsNothing() {
		variables.fx.unmapSchool(variables.LOOKALIKE);
		var w = create(variables.atLookalike, variables.LOOKALIKE);
		assertEquals(0, schoolRow(w.id).recordCount, "an equal code fills nothing without a mapping row");
		var user = variables.atLookalike;
		var walk = w;
		var schoolCode = variables.schoolCode;
		var lookalike = variables.VALUE_LOOKALIKE;
		// Not even the value whose code equals the unit's own code.
		assertThrows(function() { save(user, walk, { "#schoolCode#": { "selectedValueCode": lookalike } }); }, "ICFWalk.Conflict", "SCHOOL_ORG_UNMAPPED");
		assertEquals(0, schoolRow(w.id).recordCount);
	}

	// ---- an explicit mapping is authoritative ----------------------------------------------------

	public void function testExplicitMappingIsFilledAndLocked() {
		variables.fx.mapSchool(variables.A, variables.VALUE_A);
		variables.fx.mapSchool(variables.B, variables.VALUE_B);
		// The browser sends no School at all: the server fills the mapped value.
		var w = create(variables.atA, variables.A);
		assertEquals(variables.VALUE_A, w.state.dimensions[variables.schoolCode].selectedValueCode);
		assertEquals(variables.VALUE_A, schoolRow(w.id).value_code[1]);
		// And it stays filled across a save that omits it.
		var saved = save(variables.atA, w, {});
		assertEquals(variables.VALUE_A, saved.state.dimensions[variables.schoolCode].selectedValueCode);
		assertEquals(variables.VALUE_A, schoolRow(w.id).value_code[1]);
		// Sending the mapped value is accepted unchanged.
		save(variables.atA, saved, { "#variables.schoolCode#": { "selectedValueCode": variables.VALUE_A } });
		assertEquals(variables.VALUE_A, schoolRow(w.id).value_code[1]);
		// The mapping is stored, not inferred: the unit's own code is nothing like the value.
		assertNotEquals(variables.orgUnits.findById(variables.A).code, variables.VALUE_A);
		assertEquals(variables.VALUE_A, variables.orgUnits.findDimensionMapping(variables.A, variables.schoolCode).valueCode);
	}

	public void function testAWalkAuthorizedAtSchoolACannotBeSubmittedAsSchoolB() {
		variables.fx.mapSchool(variables.A, variables.VALUE_A);
		variables.fx.mapSchool(variables.B, variables.VALUE_B);
		var schoolCode = variables.schoolCode;
		var valueB = variables.VALUE_B;
		var unit = variables.A;
		var user = variables.atA;
		var before = walkCountAt(variables.A, variables.atA.userId);
		assertThrows(function() { create(user, unit, { "selectedValueCode": valueB }); }, "ICFWalk.Conflict", "SCHOOL_ORG_MISMATCH");
		assertEquals(before, walkCountAt(variables.A, variables.atA.userId), "no walk was created");

		// The same on a save: the stored value never becomes School B.
		var w = create(variables.atA, variables.A);
		var rv = storedRowVersion(w.id);
		var walk = w;
		assertThrows(function() { save(user, walk, { "#schoolCode#": { "selectedValueCode": valueB } }); }, "ICFWalk.Conflict", "SCHOOL_ORG_MISMATCH");
		assertEquals(variables.VALUE_A, schoolRow(w.id).value_code[1]);
		assertEquals(rv, storedRowVersion(w.id), "nothing was written");
		// "Other" free text is a conflicting label too.
		assertThrows(function() { save(user, walk, { "#schoolCode#": { "selectedValueCode": "other", "otherText": "Somewhere else" } }); }, "ICFWalk.Conflict", "SCHOOL_ORG_MISMATCH");
		assertEquals(variables.VALUE_A, schoolRow(w.id).value_code[1]);
		assertEquals(rv, storedRowVersion(w.id));
		// The rejection is audited without carrying narrative content.
		var audit = variables.db.run("SELECT details_json FROM [icf].[audit_event] WHERE entity_type = N'WALK' AND event_type = N'WALK_SCHOOL_SCOPE_REJECTED' AND actor_user_id = :me ORDER BY event_id", { "me": variables.db.guid(variables.atA.userId) });
		assertTrue(audit.recordCount >= 2, "every rejection is audited");
		assertContains('"expectedSchool":"' & variables.VALUE_A & '"', audit.details_json[1]);
	}

	/** School B's value belongs to School B: the mapping table refuses to hand it to School A. */
	public void function testOneSchoolValueBelongsToOneOrgUnit() {
		variables.fx.mapSchool(variables.B, variables.VALUE_B);
		var unitA = variables.A;
		var valueB = variables.VALUE_B;
		var schoolCode = variables.schoolCode;
		var repo = variables.orgUnits;
		assertThrows(function() { repo.upsertDimensionMapping(unitA, schoolCode, valueB, "EXPLICIT"); }, "ICFWalk.Validation", "ORG_UNIT_DIMENSION_VALUE_TAKEN");
		assertEquals(variables.B, variables.orgUnits.findUnitByDimensionValue(variables.schoolCode, variables.VALUE_B).orgUnitId);
	}

	// ---- district scope -------------------------------------------------------------------------

	public void function testDistrictUserMaySelectAnAuthorizedDescendantSchool() {
		variables.fx.mapSchool(variables.A, variables.VALUE_A);
		variables.fx.mapSchool(variables.B, variables.VALUE_B);
		// A district-scoped user creates at an authorized child SCHOOL; the School follows that unit.
		var atB = create(variables.districtUser, variables.B, { "selectedValueCode": variables.VALUE_B });
		assertEquals(variables.B, atB.orgUnitId);
		assertEquals(variables.VALUE_B, schoolRow(atB.id).value_code[1]);
		var atA = create(variables.districtUser, variables.A);
		assertEquals(variables.VALUE_A, schoolRow(atA.id).value_code[1]);
		// But not at a unit outside the authorized subtree, and not labelled as another school.
		var outside = variables.OUTSIDE;
		var user = variables.districtUser;
		var valueA = variables.VALUE_A;
		var unitB = variables.B;
		assertThrows(function() { create(user, outside); }, "ICFWalk.NotFound");
		assertThrows(function() { create(user, unitB, { "selectedValueCode": valueA }); }, "ICFWalk.Conflict", "SCHOOL_ORG_MISMATCH");
	}
}
