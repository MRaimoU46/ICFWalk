/**
 * Phase 4 walk persistence at the service level against the real database: WALK-02/03/04/05/06/
 * 08/09/10/11, SAVE-04/06/07/08, COND-06/10/12/13 persisted states, AUTH-04/05/06/09 through the
 * walk endpoints' service methods, SEC-01/05 (injection strings stored verbatim, no narrative in
 * audit or mutation logs). Fixtures are synthetic and removed in afterAll (walks with all child
 * rows, users, org units).
 *
 * Fixture tree: D (district) -> S1, S2 (schools); X (district) -> SX (school). S1/S2/SX carry no
 * School dimension mapping (icf.org_unit_dimension_map, migration 005), so walks there carry no
 * School value; HS and MS are mapped units used where the School value drives a visibility rule.
 */
component extends="icfwalktests.BaseSpec" output="false" {

	variables.NOTE = "Line 1 <script>alert('x')</script> & ""quotes"" '; DROP TABLE icf.walk; --";

	public string function skipReason() {
		if (!schemaPresent()) return "icf schema is not present.";
		if (structIsEmpty(variables.c.snapshotService.currentVersion())) return "no renderable instrument version is seeded.";
		return "";
	}

	public void function beforeAll() {
		variables.fx = createObject("component", "icfwalktests.support.Fixtures").init(variables.c, "walks-" & lCase(left(replace(createUUID(), "-", "", "all"), 8)));
		variables.svc = variables.c.walkService;
		variables.db = variables.c.db;
		var fx = variables.fx;
		variables.D = fx.orgUnit("d", "DISTRICT");
		variables.S1 = fx.orgUnit("s1", "SCHOOL", variables.D);
		variables.S2 = fx.orgUnit("s2", "SCHOOL", variables.D);
		variables.X = fx.orgUnit("x", "DISTRICT");
		variables.SX = fx.orgUnit("sx", "SCHOOL", variables.X);
		// Two SCHOOL units with an explicit, validated School mapping: the School dimension a walk
		// carries follows its unit, so a rule driven by the school group needs one unit per group.
		variables.HS = fx.orgUnit("hs", "SCHOOL", variables.D);
		variables.MS = fx.orgUnit("ms", "SCHOOL", variables.D);
		fx.mapSchool(variables.HS, "elgin_high_school");
		fx.mapSchool(variables.MS, "abbott_middle_school");

		variables.walker = fx.user("school-walker");
		fx.assign(variables.walker.userId, "SCHOOL_WALK_REPORT", variables.S1, false);
		variables.walker2 = fx.user("school-walker-2");
		fx.assign(variables.walker2.userId, "SCHOOL_WALK_REPORT", variables.S1, false);
		variables.otherSchool = fx.user("s2-walker");
		fx.assign(variables.otherSchool.userId, "SCHOOL_WALK_REPORT", variables.S2, false);
		variables.districtWalker = fx.user("district-walker");
		fx.assign(variables.districtWalker.userId, "DISTRICT_WALK_REPORT", variables.D, true);
		variables.schoolGroupWalker = fx.user("school-group-walker");
		fx.assign(variables.schoolGroupWalker.userId, "DISTRICT_WALK_REPORT", variables.D, true);
		variables.reportOnly = fx.user("school-report");
		fx.assign(variables.reportOnly.userId, "SCHOOL_REPORT_ONLY", variables.S1, false);
		variables.admin = fx.user("instrument-admin");
		fx.assign(variables.admin.userId, "MASTER_INSTRUMENT_ADMIN", variables.D, true);
		variables.foreign = fx.user("x-walker");
		fx.assign(variables.foreign.userId, "DISTRICT_WALK_REPORT", variables.X, true);

		variables.current = variables.c.snapshotService.currentVersion();
		variables.model = variables.c.snapshotService.renderModelFor(variables.current.versionId);
	}

	public void function afterAll() {
		variables.fx.remove();
	}

	// ---- helpers ------------------------------------------------------------------------------

	private struct function p(required struct user) { return variables.fx.principal(arguments.user.userId); }
	private string function newMutationId() { return variables.db.newGuid(); }

	private struct function newWalk(struct user, string orgUnitId = "") {
		var u = isNull(arguments.user) ? variables.walker : arguments.user;
		var unit = len(arguments.orgUnitId) ? arguments.orgUnitId : variables.S1;
		return variables.svc.create(p(u), { "orgUnitId": unit, "clientMutationId": newMutationId() });
	}

	private struct function saveState(required struct walk, required struct dims, required struct responses, struct user, string mutationId = "", string rowVersion = "") {
		var u = isNull(arguments.user) ? variables.walker : arguments.user;
		return variables.svc.save(p(u), arguments.walk.id, {
			"rowVersion": len(arguments.rowVersion) ? arguments.rowVersion : arguments.walk.rowVersion,
			"clientMutationId": len(arguments.mutationId) ? arguments.mutationId : newMutationId(),
			"dimensions": arguments.dims, "responses": arguments.responses
		});
	}

	private struct function requiredAnswers() {
		return {
			"p1q1": { "storedCode": "Partial" }, "p1q2": { "storedCode": "Retrieval" }, "p1q3": { "storedCode": "Analysis" },
			"part1_adopted_pacing": { "storedCode": "on" }, "part1_adopted_ac1": { "storedCode": "3" }, "part1_adopted_ac2": { "storedCode": "4" },
			"part1_targettask_tt1": { "storedCode": "5" }, "part1_targettask_tt2": { "storedCode": "2" }
		};
	}

	private query function walkRow(required string walkId) {
		return variables.db.run("SELECT status, completed_at, voided_at, void_reason, observed_at, version_id, owner_user_id, org_unit_id FROM [icf].[walk] WHERE walk_id = :id", { "id": variables.db.guid(arguments.walkId) });
	}

	private query function responseRow(required string walkId, required string itemKey) {
		return variables.db.run(
			"SELECT r.response_state, r.selected_option_id, r.text_value, o.stored_code FROM [icf].[walk_response] r JOIN [icf].[item_definition] i ON i.item_id = r.item_id LEFT JOIN [icf].[response_option] o ON o.option_id = r.selected_option_id WHERE r.walk_id = :id AND i.item_key = :key",
			{ "id": variables.db.guid(arguments.walkId), "key": variables.db.nvarchar(arguments.itemKey, 100) });
	}

	private query function dimensionRow(required string walkId, required string code) {
		return variables.db.run(
			"SELECT x.selected_value_id, x.text_value, x.date_value, dv.value_code FROM [icf].[walk_dimension_value] x JOIN [icf].[dimension_definition] d ON d.dimension_id = x.dimension_id LEFT JOIN [icf].[dimension_value] dv ON dv.value_id = x.selected_value_id WHERE x.walk_id = :id AND d.code = :code",
			{ "id": variables.db.guid(arguments.walkId), "code": variables.db.nvarchar(arguments.code, 100) });
	}

	private numeric function count(required string sql, required string walkId) {
		return variables.db.scalar(arguments.sql, { "id": variables.db.guid(arguments.walkId) });
	}

	private query function auditEvents(required string walkId, required string type) {
		return variables.db.run("SELECT details_json FROM [icf].[audit_event] WHERE entity_type = N'WALK' AND entity_id = :id AND event_type = :type ORDER BY event_id", { "id": variables.db.guid(arguments.walkId), "type": variables.db.nvarchar(arguments.type, 80) });
	}

	// ---- WALK-02 / WALK-03: create, pinning, idempotent create ----------------------------------

	public void function testWalk02CreatePinsCurrentVersionOwnerAndDefaults() {
		var w = newWalk();
		assertExactTextEquals("DRAFT", w.status);
		assertExactTextEquals(variables.current.versionId, w.versionId);
		assertExactTextEquals(variables.S1, w.orgUnitId);
		assertExactTextEquals(variables.walker.userId, w.ownerUserId);
		assertTrue(w.isOwner && w.canEdit);
		assertTrue(reFind("^0x[0-9A-F]{16}$", w.rowVersion) > 0, "row version token");
		var row = walkRow(w.id);
		assertExactTextEquals("DRAFT", row.status[1]);
		assertExactTextEquals(variables.current.versionId, uCase(row.version_id[1]));
		// Defaults: skippable components start as not applicable (applicability = no).
		assertExactTextEquals("no", w.state.responses.comp_s3_applicable.storedCode);
		assertExactTextEquals("no", w.state.responses.comp_s4_applicable.storedCode);
		assertExactTextEquals("NOT_APPLICABLE", w.states.responseStates.comp_s3_q1);
		// One response row per response-capable item; none for display items; no dimension rows.
		var expectedRows = structCount(w.states.responseStates);
		assertEquals(expectedRows, count("SELECT COUNT(*) AS n FROM [icf].[walk_response] WHERE walk_id = :id", w.id));
		assertTrue(expectedRows >= 70 && expectedRows < 144, "response rows exclude the 71 display items: " & expectedRows);
		assertEquals(0, count("SELECT COUNT(*) AS n FROM [icf].[walk_dimension_value] WHERE walk_id = :id", w.id));
		assertEquals(1, auditEvents(w.id, "WALK_CREATED").recordCount);
	}

	public void function testWalk03CreateRetryWithSameMutationIdCreatesOneWalk() {
		var id = newMutationId();
		var first = variables.svc.create(p(variables.walker), { "orgUnitId": variables.S1, "clientMutationId": id });
		var second = variables.svc.create(p(variables.walker), { "orgUnitId": variables.S1, "clientMutationId": id });
		assertExactTextEquals(first.id, second.id);
		assertFalse(first.replayed);
		assertTrue(second.replayed);
		assertRowVersionEquals(first.rowVersion, second.rowVersion);
		assertEquals(1, variables.db.scalar("SELECT COUNT(*) AS n FROM [icf].[walk_mutation] WHERE mutation_id = :id", { "id": variables.db.guid(id) }));
		assertEquals(1, auditEvents(first.id, "WALK_MUTATION_REPLAYED").recordCount);
		// The same mutation id from another user is refused, never replayed to them.
		assertThrows(function() { variables.svc.create(p(variables.walker2), { "orgUnitId": variables.S1, "clientMutationId": id }); }, "ICFWalk.Conflict", "MUTATION_ID_REUSED");
	}

	public void function testCreateRequiresAnInScopeActiveOrgUnit() {
		assertThrows(function() { variables.svc.create(p(variables.walker), { "orgUnitId": variables.S2, "clientMutationId": newMutationId() }); }, "ICFWalk.NotFound");
		assertThrows(function() { variables.svc.create(p(variables.walker), { "orgUnitId": "not-a-guid", "clientMutationId": newMutationId() }); }, "ICFWalk.Validation");
		assertThrows(function() { variables.svc.create(p(variables.reportOnly), { "orgUnitId": variables.S1, "clientMutationId": newMutationId() }); }, "ICFWalk.Forbidden");
		assertThrows(function() { variables.svc.create(p(variables.walker), { "orgUnitId": variables.S1, "clientMutationId": newMutationId(), "versionId": variables.db.newGuid() }); }, "ICFWalk.Conflict", "INSTRUMENT_VERSION_CHANGED");
	}

	// ---- WALK-05 / SAVE-08 / SEC-01: persistence round trip -------------------------------------

	public void function testSaveRoundTripPersistsTypedValuesAndSurvivesRetrieval() {
		var w = newWalk();
		// The School dimension is the authorized unit's (see WalkSchoolScopeTest); "other" free text on
		// a CONTROLLED_LIST dimension is exercised here on Content area, which also allows it.
		var saved = saveState(w,
			{ "date": { "dateValue": "2026-09-03" }, "observer": { "textValue": "Fixture Observer" }, "content": { "selectedValueCode": "other", "otherText": "Unlisted <b>Site</b>" }, "grade": { "selectedValueCode": "9" }, "period": { "selectedValueCode": "third" } },
			{ "p1q1": { "storedCode": "Partial" }, "comp_s1_q1": { "storedCode": "4" }, "part1_adopted_notes": { "textValue": variables.NOTE }, "email_workflow": { "textValue": '{"includedPartKeys":["part1"],"drafted":true,"to":"","subject":"S","body":"B"}' } }
		);
		assertRowVersionChanged(w.rowVersion, saved.rowVersion, "row version advances");
		assertExactTextEquals("ANSWERED", saved.states.responseStates.p1q1);
		// Fresh retrieval (new queries, no in-memory state) returns the same values.
		var again = variables.svc.open(p(variables.walker), w.id);
		assertExactTextEquals("2026-09-03", again.state.dimensions.date.dateValue);
		assertExactTextEquals("Fixture Observer", again.state.dimensions.observer.textValue);
		assertExactTextEquals("other", again.state.dimensions.content.selectedValueCode);
		assertExactTextEquals("Unlisted <b>Site</b>", again.state.dimensions.content.otherText);
		assertFalse(structKeyExists(again.state.dimensions, "school"), "an unmapped SCHOOL unit carries no School value");
		assertExactTextEquals("9", again.state.dimensions.grade.selectedValueCode);
		assertExactTextEquals("third", again.state.dimensions.period.selectedValueCode);
		assertExactTextEquals("Partial", again.state.responses.p1q1.storedCode);
		assertExactTextEquals("4", again.state.responses.comp_s1_q1.storedCode);
		assertExactTextEquals(variables.NOTE, again.state.responses.part1_adopted_notes.textValue, "markup and SQL metacharacters are stored verbatim");
		assertExactTextEquals('{"body":"B","drafted":true,"includedPartKeys":["part1"],"subject":"S","to":""}', again.state.responses.email_workflow.textValue, "email draft stored as canonical JSON");
		assertRowVersionEquals(saved.rowVersion, again.rowVersion);
		// Typed columns and the documented Other mapping (selected_value_id = Other, text_value = the text).
		var contentArea = dimensionRow(w.id, "content");
		assertExactTextEquals("other", contentArea.value_code[1]);
		assertExactTextEquals("Unlisted <b>Site</b>", contentArea.text_value[1]);
		var d = dimensionRow(w.id, "date");
		assertExactTextEquals("2026-09-03", dateFormat(d.date_value[1], "yyyy-mm-dd"));
		var obs = walkRow(w.id);
		assertExactTextEquals("2026-09-03", dateFormat(obs.observed_at[1], "yyyy-mm-dd"), "observed_at follows the visit date");
		var r = responseRow(w.id, "comp_s1_q1");
		assertExactTextEquals("ANSWERED", r.response_state[1]);
		assertExactTextEquals("4", r.stored_code[1]);
		assertEquals(1, count("SELECT COUNT(*) AS n FROM [icf].[walk_response] r JOIN [icf].[item_definition] i ON i.item_id = r.item_id WHERE r.walk_id = :id AND i.item_key = N'comp_s1_q1'", w.id), "one row per item");
		// Removing a value deletes the dimension row and returns the response to UNANSWERED.
		var cleared = saveState(again, { "date": { "dateValue": "2026-09-03" } }, { "part1_adopted_notes": { "textValue": variables.NOTE } });
		assertEquals(0, dimensionRow(w.id, "content").recordCount);
		assertExactTextEquals("UNANSWERED", responseRow(w.id, "comp_s1_q1").response_state[1]);
		assertFalse(structKeyExists(cleared.state.responses, "comp_s1_q1"));
	}

	// ---- AUTH-09 / SAVE-07: tampering ------------------------------------------------------------

	public void function testAuth09TamperedKeysCodesAndIdentifiersAreRejectedAndAudited() {
		var w = newWalk();
		var before = count("SELECT COUNT(*) AS n FROM [icf].[walk_response] WHERE walk_id = :id AND response_state = N'ANSWERED'", w.id);
		var cases = [
			{ "code": "UNKNOWN_ITEM", "dims": {}, "responses": { "not_an_item": { "storedCode": "1" } } },
			{ "code": "UNKNOWN_DIMENSION", "dims": { "teacher": { "textValue": "x" } }, "responses": {} },
			{ "code": "INVALID_OPTION", "dims": {}, "responses": { "comp_s1_q1": { "storedCode": "yes" } } },
			{ "code": "INVALID_OPTION", "dims": {}, "responses": { "p1q1": { "storedCode": "1" } } },
			{ "code": "INVALID_OPTION", "dims": {}, "responses": { "comp_s3_applicable": { "storedCode": "4" } } },
			{ "code": "INVALID_DIMENSION_VALUE", "dims": { "grade": { "selectedValueCode": "13" } }, "responses": {} },
			{ "code": "INVALID_DIMENSION_VALUE", "dims": { "grade": { "textValue": "9" } }, "responses": {} },
			{ "code": "INVALID_DIMENSION_VALUE", "dims": { "grade": { "selectedValueCode": "9", "otherText": "x" } }, "responses": {} },
			{ "code": "INVALID_DATE", "dims": { "date": { "dateValue": "2026-02-30" } }, "responses": {} },
			{ "code": "INVALID_DATE", "dims": { "date": { "dateValue": "17/09/2026" } }, "responses": {} },
			{ "code": "INVALID_RESPONSE_VALUE", "dims": {}, "responses": { "p1q1": { "textValue": "Partial" } } },
			{ "code": "INVALID_RESPONSE_VALUE", "dims": {}, "responses": { "comp_s1_notes": { "storedCode": "1" } } },
			{ "code": "INVALID_RESPONSE_VALUE", "dims": {}, "responses": { "part1_adopted_student_heading": { "textValue": "x" } } },
			{ "code": "INVALID_EMAIL_DRAFT", "dims": {}, "responses": { "email_workflow": { "textValue": '{"sendNow":true}' } } },
			{ "code": "VALUE_TOO_LONG", "dims": { "observer": { "textValue": repeatString("a", 1001) } }, "responses": {} }
		];
		for (var i = 1; i <= arrayLen(cases); i++) {
			var local_tc = cases[i];
			var thrown = false;
			try {
				saveState(w, local_tc.dims, local_tc.responses);
			} catch (ICFWalk.Validation e) {
				thrown = true;
				assertExactTextEquals(local_tc.code, e.errorcode, "case " & i & " (" & serializeJSON(local_tc.dims) & " " & serializeJSON(local_tc.responses) & ")");
				var details = variables.c.errors.detailsOf(e);
				assertTrue(structKeyExists(details, "issues") && arrayLen(details.issues) >= 1, "issues listed for " & local_tc.code);
			}
			assertTrue(thrown, "case " & i & " should be rejected with " & local_tc.code & ": " & serializeJSON(local_tc.dims) & " " & serializeJSON(local_tc.responses));
		}
		assertEquals(before, count("SELECT COUNT(*) AS n FROM [icf].[walk_response] WHERE walk_id = :id AND response_state = N'ANSWERED'", w.id), "rejected saves write nothing");
		assertRowVersionEquals(w.rowVersion, variables.svc.open(p(variables.walker), w.id).rowVersion, "row version unchanged");
		assertEquals(arrayLen(cases), auditEvents(w.id, "WALK_SAVE_REJECTED").recordCount);
		// Identifiers: version, walk id, row version format, malformed and unknown walk ids.
		assertThrows(function() { variables.svc.save(p(variables.walker), w.id, { "rowVersion": w.rowVersion, "clientMutationId": newMutationId(), "versionId": variables.db.newGuid(), "dimensions": {}, "responses": {} }); }, "ICFWalk.Validation", "VERSION_MISMATCH");
		assertThrows(function() { variables.svc.save(p(variables.walker), w.id, { "rowVersion": w.rowVersion, "clientMutationId": newMutationId(), "walkId": variables.db.newGuid(), "dimensions": {}, "responses": {} }); }, "ICFWalk.Validation", "WALK_ID_MISMATCH");
		assertThrows(function() { variables.svc.save(p(variables.walker), w.id, { "rowVersion": "12345", "clientMutationId": newMutationId(), "dimensions": {}, "responses": {} }); }, "ICFWalk.Validation", "ROW_VERSION_INVALID");
		assertThrows(function() { variables.svc.save(p(variables.walker), w.id, { "rowVersion": w.rowVersion, "clientMutationId": "not-a-guid", "dimensions": {}, "responses": {} }); }, "ICFWalk.Validation", "CLIENT_MUTATION_ID_INVALID");
		assertThrows(function() { variables.svc.save(p(variables.walker), w.id, { "clientMutationId": newMutationId(), "dimensions": {}, "responses": {} }); }, "ICFWalk.Validation", "ROW_VERSION_REQUIRED");
		assertThrows(function() { variables.svc.open(p(variables.walker), "1 OR 1=1"); }, "ICFWalk.Validation", "INVALID_WALK_ID");
		assertThrows(function() { variables.svc.open(p(variables.walker), variables.db.newGuid()); }, "ICFWalk.NotFound");
		assertThrows(function() { variables.svc.save(p(variables.walker), variables.db.newGuid(), { "rowVersion": w.rowVersion, "clientMutationId": newMutationId(), "dimensions": {}, "responses": {} }); }, "ICFWalk.NotFound");
	}

	// ---- SAVE-04 / SAVE-06: stale writes and idempotent retries ----------------------------------

	public void function testSave04StaleWriteIsRejectedWithoutOverwriting() {
		var w = newWalk();
		var a = saveState(w, { "grade": { "selectedValueCode": "4" } }, { "comp_s1_q1": { "storedCode": "5" } });
		var e = assertThrows(function() { saveState(w, { "grade": { "selectedValueCode": "2" } }, { "comp_s1_q1": { "storedCode": "1" } }); }, "ICFWalk.Conflict", "STALE_ROW_VERSION");
		var details = variables.c.errors.detailsOf(e);
		assertRowVersionEquals(a.rowVersion, details.serverRowVersion);
		var current = variables.svc.open(p(variables.walker), w.id);
		assertExactTextEquals("4", current.state.dimensions.grade.selectedValueCode, "A's write survives");
		assertExactTextEquals("5", current.state.responses.comp_s1_q1.storedCode);
		assertRowVersionEquals(a.rowVersion, current.rowVersion);
		assertEquals(1, auditEvents(w.id, "WALK_SAVE_CONFLICT").recordCount);
		// Same for completion with a stale token.
		assertThrows(function() { variables.svc.complete(p(variables.walker), w.id, { "rowVersion": w.rowVersion, "clientMutationId": newMutationId() }); }, "ICFWalk.Conflict", "STALE_ROW_VERSION");
	}

	public void function testSave06RetryWithSameMutationIdCommitsOneLogicalChange() {
		var w = newWalk();
		var id = newMutationId();
		var first = saveState(w, { "grade": { "selectedValueCode": "6" } }, { "comp_s1_q1": { "storedCode": "3" }, "comp_s1_notes": { "textValue": "n1" } }, variables.walker, id);
		var rows = count("SELECT COUNT(*) AS n FROM [icf].[walk_response] WHERE walk_id = :id", w.id);
		var retry = saveState(w, { "grade": { "selectedValueCode": "6" } }, { "comp_s1_q1": { "storedCode": "3" }, "comp_s1_notes": { "textValue": "n1" } }, variables.walker, id);
		assertTrue(retry.replayed);
		assertRowVersionEquals(first.rowVersion, retry.rowVersion, "replay returns the committed row version");
		assertEquals(rows, count("SELECT COUNT(*) AS n FROM [icf].[walk_response] WHERE walk_id = :id", w.id), "no duplicate response rows");
		assertEquals(1, count("SELECT COUNT(*) AS n FROM [icf].[walk_dimension_value] WHERE walk_id = :id", w.id));
		assertEquals(0, count("SELECT COUNT(*) AS n FROM [icf].[walk_revision] WHERE walk_id = :id", w.id), "draft saves append no revision");
		assertEquals(2, count("SELECT COUNT(*) AS n FROM [icf].[walk_mutation] WHERE walk_id = :id", w.id), "one CREATE and one SAVE mutation recorded");
		// A retry after another save is refused rather than replayed: the retrying session still holds
		// the state that went with this mutation, so handing it back a row version minted for the newer
		// state would let its stale state overwrite that newer work with no conflict. It must reconcile.
		var later = saveState(first, { "grade": { "selectedValueCode": "7" } }, {});
		var walker = variables.walker;
		var walk = w;
		var mutationId = id;
		assertThrows(
			function() { saveState(walk, { "grade": { "selectedValueCode": "6" } }, { "comp_s1_q1": { "storedCode": "3" }, "comp_s1_notes": { "textValue": "n1" } }, walker, mutationId); },
			"ICFWalk.Conflict", "MUTATION_REPLAY_SUPERSEDED");
		// Nothing was re-applied and no second mutation row was written.
		var after = variables.svc.open(p(variables.walker), w.id);
		assertExactTextEquals("7", after.state.dimensions.grade.selectedValueCode);
		assertRowVersionEquals(later.rowVersion, after.rowVersion);
		assertEquals(3, count("SELECT COUNT(*) AS n FROM [icf].[walk_mutation] WHERE walk_id = :id", w.id), "one CREATE and two SAVE mutations; the refused retry recorded none");
		// The mutation id belongs to this walk and actor only.
		var other = newWalk();
		assertThrows(function() { saveState(other, {}, {}, variables.walker, id); }, "ICFWalk.Conflict", "MUTATION_ID_REUSED");
	}

	// ---- COND-12 / COND-13 / COND-10 / COND-06: persisted states and clearing --------------------

	public void function testCond12And13SkippableComponentClearsRatingsKeepsNotesInOneTransaction() {
		var w = newWalk();
		var yes = saveState(w, {}, { "comp_s3_applicable": { "storedCode": "yes" }, "comp_s3_q1": { "storedCode": "4" }, "comp_s3_q2": { "storedCode": "2" }, "comp_s3_notes": { "textValue": "keep these notes" } });
		assertExactTextEquals("ANSWERED", responseRow(w.id, "comp_s3_q1").response_state[1]);
		var no = saveState(yes, {}, { "comp_s3_applicable": { "storedCode": "no" }, "comp_s3_q1": { "storedCode": "4" }, "comp_s3_q2": { "storedCode": "2" }, "comp_s3_notes": { "textValue": "keep these notes" } });
		var kinds = [];
		for (var ch in no.changes) arrayAppend(kinds, ch.kind & ":" & ch.key & ":" & ch.reason);
		assertExactTextEquals("RESPONSE_CLEARED:comp_s3_q1:NOT_APPLICABLE,RESPONSE_CLEARED:comp_s3_q2:NOT_APPLICABLE", arrayToList(kinds));
		assertFalse(structKeyExists(no.state.responses, "comp_s3_q1"), "rating cleared from the returned state");
		assertExactTextEquals("keep these notes", no.state.responses.comp_s3_notes.textValue);
		var q1 = responseRow(w.id, "comp_s3_q1");
		assertExactTextEquals("NOT_APPLICABLE", q1.response_state[1]);
		assertTrue(!len(q1.selected_option_id[1]), "cleared option is null in the database");
		assertExactTextEquals("NOT_APPLICABLE", responseRow(w.id, "comp_s3_q2").response_state[1]);
		var notes = responseRow(w.id, "comp_s3_notes");
		assertExactTextEquals("ANSWERED", notes.response_state[1]);
		assertExactTextEquals("keep these notes", notes.text_value[1]);
		// COND-13: back to Yes -> UNANSWERED, cleared ratings do not reappear, notes remain.
		var back = saveState(no, {}, { "comp_s3_applicable": { "storedCode": "yes" }, "comp_s3_notes": { "textValue": "keep these notes" } });
		assertExactTextEquals("UNANSWERED", back.states.responseStates.comp_s3_q1);
		assertExactTextEquals("UNANSWERED", responseRow(w.id, "comp_s3_q1").response_state[1]);
		assertFalse(structKeyExists(back.state.responses, "comp_s3_q1"));
		assertExactTextEquals("keep these notes", back.state.responses.comp_s3_notes.textValue);
	}

	public void function testCond10HiddenSectionAnswersArePersistedAsHiddenAndReturn() {
		var w = newWalk();
		var shown = saveState(w, { "classType": { "selectedValueCode": "dual_language" } }, { "dual_language_q1": { "storedCode": "yes" } });
		assertExactTextEquals("ANSWERED", shown.states.responseStates.dual_language_q1);
		var hidden = saveState(shown, { "classType": { "selectedValueCode": "general_education" } }, { "dual_language_q1": { "storedCode": "yes" } });
		assertExactTextEquals("HIDDEN", hidden.states.responseStates.dual_language_q1);
		assertExactTextEquals("yes", hidden.state.responses.dual_language_q1.storedCode, "value retained while hidden");
		var row = responseRow(w.id, "dual_language_q1");
		assertExactTextEquals("HIDDEN", row.response_state[1]);
		assertExactTextEquals("yes", row.stored_code[1]);
		var again = saveState(hidden, { "classType": { "selectedValueCode": "dual_language" } }, { "dual_language_q1": { "storedCode": "yes" } });
		assertExactTextEquals("ANSWERED", again.states.responseStates.dual_language_q1);
		assertExactTextEquals("ANSWERED", responseRow(w.id, "dual_language_q1").response_state[1]);
	}

	public void function testCond05And06GradeFilterClearsAndHiddenPeriodIsRetained() {
		// The School value follows the authorized unit, so the school group is a property of the walk's
		// unit: a high-school walk accepts grade 9, a middle-school walk does not.
		var atHigh = newWalk(variables.schoolGroupWalker, variables.HS);
		var hs = saveState(atHigh, { "grade": { "selectedValueCode": "9" }, "period": { "selectedValueCode": "second" } }, {}, variables.schoolGroupWalker);
		assertExactTextEquals("elgin_high_school", hs.state.dimensions.school.selectedValueCode, "the School value is the unit's");
		assertExactTextEquals("ANSWERED", hs.states.dimensionStates.period);

		var atMiddle = newWalk(variables.schoolGroupWalker, variables.MS);
		var valid = saveState(atMiddle, { "grade": { "selectedValueCode": "7" }, "period": { "selectedValueCode": "second" } }, {}, variables.schoolGroupWalker);
		assertExactTextEquals("abbott_middle_school", valid.state.dimensions.school.selectedValueCode);
		assertExactTextEquals("ANSWERED", valid.states.dimensionStates.period);
		// COND-05: a middle school invalidates grade 9 on the server too.
		var ms = saveState(valid, { "grade": { "selectedValueCode": "9" }, "period": { "selectedValueCode": "second" } }, {}, variables.schoolGroupWalker);
		assertEquals(1, arrayLen(ms.changes));
		assertExactTextEquals("DIMENSION_CLEARED", ms.changes[1].kind);
		assertExactTextEquals("grade", ms.changes[1].key);
		assertFalse(structKeyExists(ms.state.dimensions, "grade"));
		assertEquals(0, dimensionRow(atMiddle.id, "grade").recordCount);
		// COND-06: without a 6-12 grade, Period is HIDDEN but retained (RETAIN_HIDDEN policy).
		assertExactTextEquals("HIDDEN", ms.states.dimensionStates.period);
		assertExactTextEquals("second", ms.state.dimensions.period.selectedValueCode);
		assertExactTextEquals("second", dimensionRow(atMiddle.id, "period").value_code[1]);
	}

	// ---- WALK-09 / WALK-10: completion ----------------------------------------------------------

	public void function testWalk09CompletionRejectsMissingRequiredResponsesAndKeepsTheDraft() {
		var w = newWalk();
		var partial = saveState(w, {}, { "p1q1": { "storedCode": "Yes" } });
		var e = assertThrows(function() { variables.svc.complete(p(variables.walker), w.id, { "rowVersion": partial.rowVersion, "clientMutationId": newMutationId() }); }, "ICFWalk.Validation", "WALK_INCOMPLETE");
		var details = variables.c.errors.detailsOf(e);
		var keys = [];
		for (var err in details.errors) { arrayAppend(keys, err.key); assertExactTextEquals("ITEM", err.kind); assertTrue(len(err.sectionKey) > 0); assertTrue(len(err.message) > 0); }
		assertExactTextEquals("p1q2,p1q3,part1_adopted_pacing,part1_adopted_ac1,part1_adopted_ac2,part1_targettask_tt1,part1_targettask_tt2", arrayToList(keys));
		assertExactTextEquals("DRAFT", walkRow(w.id).status[1]);
		assertExactTextEquals("Yes", variables.svc.open(p(variables.walker), w.id).state.responses.p1q1.storedCode, "draft remains saved");
		assertEquals(0, count("SELECT COUNT(*) AS n FROM [icf].[walk_revision] WHERE walk_id = :id", w.id));
		assertEquals(1, auditEvents(w.id, "WALK_COMPLETION_REJECTED").recordCount);
	}

	public void function testWalk10CompletionSetsStatusTimestampRevisionAndAudit() {
		var w = newWalk();
		var full = saveState(w, { "grade": { "selectedValueCode": "3" } }, requiredAnswers());
		var id = newMutationId();
		var done = variables.svc.complete(p(variables.walker), w.id, { "rowVersion": full.rowVersion, "clientMutationId": id });
		assertExactTextEquals("COMPLETED", done.status);
		assertTrue(len(done.completedAt) > 0);
		assertRowVersionChanged(full.rowVersion, done.rowVersion);
		var row = walkRow(w.id);
		assertExactTextEquals("COMPLETED", row.status[1]);
		assertTrue(isDate(row.completed_at[1]));
		var revisions = variables.c.walkRepository.listRevisions(w.id);
		assertEquals(1, arrayLen(revisions));
		assertExactTextEquals("COMPLETE", revisions[1].reason);
		assertExactTextEquals(variables.walker.userId, revisions[1].actorUserId);
		var snapshot = variables.db.run("SELECT prior_snapshot_json FROM [icf].[walk_revision] WHERE walk_id = :id", { "id": variables.db.guid(w.id) });
		assertContains('"status":"DRAFT"', snapshot.prior_snapshot_json[1]);
		assertContains('"p1q1":{"state":"ANSWERED","storedCode":"Partial"}', snapshot.prior_snapshot_json[1]);
		var audit = auditEvents(w.id, "WALK_COMPLETED");
		assertEquals(1, audit.recordCount);
		assertContains('"revisionNumber":1', audit.details_json[1]);
		// Idempotent retry replays; a second completion is refused.
		var replay = variables.svc.complete(p(variables.walker), w.id, { "rowVersion": full.rowVersion, "clientMutationId": id });
		assertTrue(replay.replayed);
		assertEquals(1, count("SELECT COUNT(*) AS n FROM [icf].[walk_revision] WHERE walk_id = :id", w.id));
		assertThrows(function() { variables.svc.complete(p(variables.walker), w.id, { "rowVersion": done.rowVersion, "clientMutationId": newMutationId() }); }, "ICFWalk.Conflict", "WALK_ALREADY_COMPLETED");
		// Completed walks stay in the owner's list and open normally.
		var listed = variables.svc.list(p(variables.walker));
		var found = false;
		for (var item in listed) if (item.id == w.id) { found = true; assertExactTextEquals("COMPLETED", item.status); }
		assertTrue(found);
	}

	public void function testPostCompletionEditAppendsARevisionAndMustStayComplete() {
		var w = newWalk();
		var full = saveState(w, {}, requiredAnswers());
		var done = variables.svc.complete(p(variables.walker), w.id, { "rowVersion": full.rowVersion, "clientMutationId": newMutationId() });
		var answers = requiredAnswers();
		structDelete(answers, "p1q3");
		assertThrows(function() { saveState(done, {}, answers); }, "ICFWalk.Validation", "WALK_COMPLETION_INVALID");
		assertEquals(1, count("SELECT COUNT(*) AS n FROM [icf].[walk_revision] WHERE walk_id = :id", w.id), "rejected edit appends nothing");
		var edited = requiredAnswers();
		edited["p1q1"] = { "storedCode": "Yes" };
		edited["comp_s1_notes"] = { "textValue": "added after completion" };
		var after = saveState(done, {}, edited);
		assertExactTextEquals("COMPLETED", after.status);
		assertEquals(2, after.revisionCount);
		var revisions = variables.c.walkRepository.listRevisions(w.id);
		assertExactTextEquals("POST_COMPLETION_EDIT", revisions[2].reason);
		assertEquals(1, auditEvents(w.id, "WALK_POST_COMPLETION_EDIT").recordCount);
		assertExactTextEquals("Yes", variables.svc.open(p(variables.walker), w.id).state.responses.p1q1.storedCode);
	}

	// ---- WALK-06 / WALK-08: void and delete refusal ----------------------------------------------

	public void function testWalk06And08VoidLifecycleAndDeleteRefusal() {
		var w = newWalk();
		assertThrows(function() { variables.svc.refuseDelete(p(variables.walker), w.id); }, "ICFWalk.Conflict", "WALK_DELETE_REFUSED");
		assertEquals(1, auditEvents(w.id, "WALK_DELETE_REFUSED").recordCount);
		assertExactTextEquals("DRAFT", walkRow(w.id).status[1]);
		var voided = variables.svc.void(p(variables.walker), w.id, { "rowVersion": w.rowVersion, "clientMutationId": newMutationId() });
		assertExactTextEquals("VOIDED", voided.status);
		assertFalse(voided.canEdit);
		var row = walkRow(w.id);
		assertExactTextEquals("VOIDED", row.status[1]);
		assertTrue(isDate(row.voided_at[1]));
		assertExactTextEquals("Deleted by owner from My Walks", row.void_reason[1]);
		assertEquals(1, auditEvents(w.id, "WALK_VOIDED").recordCount);
		assertContains('"priorStatus":"DRAFT"', auditEvents(w.id, "WALK_VOIDED").details_json[1]);
		for (var item in variables.svc.list(p(variables.walker))) assertExactTextNotEquals(w.id, item.id, "voided walks leave the list");
		assertThrows(function() { saveState(voided, {}, {}); }, "ICFWalk.Conflict", "WALK_VOIDED");
		assertThrows(function() { variables.svc.void(p(variables.walker), w.id, { "rowVersion": voided.rowVersion, "clientMutationId": newMutationId() }); }, "ICFWalk.Conflict", "WALK_ALREADY_VOIDED");
		// Completed walks need a reason and are retained (never physically deleted).
		var c = newWalk();
		var full = saveState(c, {}, requiredAnswers());
		var done = variables.svc.complete(p(variables.walker), c.id, { "rowVersion": full.rowVersion, "clientMutationId": newMutationId() });
		assertThrows(function() { variables.svc.void(p(variables.walker), c.id, { "rowVersion": done.rowVersion, "clientMutationId": newMutationId() }); }, "ICFWalk.Validation", "VOID_REASON_REQUIRED");
		assertThrows(function() { variables.svc.void(p(variables.walker), c.id, { "reason": "Duplicate entry", "rowVersion": full.rowVersion, "clientMutationId": newMutationId() }); }, "ICFWalk.Conflict", "STALE_ROW_VERSION");
		assertExactTextEquals("COMPLETED", walkRow(c.id).status[1], "a stale void changes nothing");
		var v = variables.svc.void(p(variables.walker), c.id, { "reason": "Duplicate entry", "rowVersion": done.rowVersion, "clientMutationId": newMutationId() });
		assertExactTextEquals("VOIDED", v.status);
		var crow = walkRow(c.id);
		assertExactTextEquals("Duplicate entry", crow.void_reason[1]);
		assertTrue(isDate(crow.completed_at[1]), "completion history retained");
		assertEquals(structCount(done.states.responseStates), count("SELECT COUNT(*) AS n FROM [icf].[walk_response] WHERE walk_id = :id", c.id), "responses retained");
	}

	// ---- AUTH-04 / AUTH-05 / AUTH-06 / scope through the service ---------------------------------

	public void function testCrossScopeAccessFailsClosedThroughTheService() {
		var w = newWalk();
		saveState(w, { "grade": { "selectedValueCode": "2" } }, { "comp_s1_notes": { "textValue": "private note" } });
		// Another school's walker: 404 (existence not disclosed), audited.
		assertThrows(function() { variables.svc.open(p(variables.otherSchool), w.id); }, "ICFWalk.NotFound");
		assertThrows(function() { variables.svc.save(p(variables.otherSchool), w.id, { "rowVersion": w.rowVersion, "clientMutationId": newMutationId(), "dimensions": {}, "responses": {} }); }, "ICFWalk.NotFound");
		assertThrows(function() { variables.svc.void(p(variables.otherSchool), w.id, {}); }, "ICFWalk.NotFound");
		assertThrows(function() { variables.svc.instrumentFor(p(variables.foreign), w.id); }, "ICFWalk.NotFound");
		// Report-only and instrument-admin roles: 403 with no walk data.
		var e = assertThrows(function() { variables.svc.open(p(variables.reportOnly), w.id); }, "ICFWalk.Forbidden");
		assertFalse(findNoCase("private note", e.message) > 0);
		assertThrows(function() { variables.svc.open(p(variables.admin), w.id); }, "ICFWalk.Forbidden");
		assertThrows(function() { variables.svc.complete(p(variables.reportOnly), w.id, { "rowVersion": w.rowVersion, "clientMutationId": newMutationId() }); }, "ICFWalk.Forbidden");
		// Same-school colleague: may read in scope but never edit, complete, or void someone else's walk.
		var seen = variables.svc.open(p(variables.walker2), w.id);
		assertFalse(seen.isOwner);
		assertFalse(seen.canEdit);
		assertThrows(function() { variables.svc.save(p(variables.walker2), w.id, { "rowVersion": seen.rowVersion, "clientMutationId": newMutationId(), "dimensions": {}, "responses": {} }); }, "ICFWalk.Forbidden");
		assertThrows(function() { variables.svc.void(p(variables.walker2), w.id, { "reason": "x" }); }, "ICFWalk.Forbidden");
		assertExactTextEquals("2", variables.svc.open(p(variables.walker), w.id).state.dimensions.grade.selectedValueCode, "nothing changed");
		// Lists: "mine" is the owner's; "all" adds readable walks in scope; other districts never see it.
		var mine = variables.svc.list(p(variables.walker2));
		for (var item in mine) assertExactTextNotEquals(w.id, item.id);
		var all = variables.svc.list(p(variables.districtWalker), "all");
		var found = false;
		for (var item in all) if (item.id == w.id) { found = true; assertFalse(item.canEdit); assertExactTextEquals("2", item.state.dimensions.grade.selectedValueCode); assertTrue(structIsEmpty(item.state.responses), "list carries dimensions only"); }
		assertTrue(found, "district walker sees the walk with scope=all");
		var foreignAll = variables.svc.list(p(variables.foreign), "all");
		for (var item in foreignAll) assertExactTextNotEquals(w.id, item.id);
		assertEquals(0, arrayLen(variables.svc.list(p(variables.reportOnly), "all")), "report-only lists nothing");
	}

	// ---- WALK-04: list order and card data --------------------------------------------------------

	public void function testWalk04ListSortsByUpdatedAtDescendingWithCardDimensions() {
		var older = newWalk(variables.walker2);
		var newer = newWalk(variables.walker2);
		var list = variables.svc.list(p(variables.walker2));
		assertExactTextEquals(newer.id, list[1].id);
		assertExactTextEquals(older.id, list[2].id);
		saveState(older, { "grade": { "selectedValueCode": "5" }, "content": { "selectedValueCode": "art" }, "date": { "dateValue": "2026-09-10" } }, {}, variables.walker2);
		list = variables.svc.list(p(variables.walker2));
		assertExactTextEquals(older.id, list[1].id, "the updated walk sorts first");
		assertExactTextEquals("5", list[1].state.dimensions.grade.selectedValueCode);
		assertExactTextEquals("art", list[1].state.dimensions.content.selectedValueCode);
		assertExactTextEquals("2026-09-10", list[1].state.dimensions.date.dateValue);
		assertTrue(len(list[1].updatedAt) > 0 && len(list[1].rowVersion) > 0);
	}

	// ---- SEC-05: audit and mutation logs carry no narrative ---------------------------------------

	public void function testAuditAndMutationLogsContainNoNarrativeContent() {
		var w = newWalk();
		var s = saveState(w, { "observer": { "textValue": "Observer Name" } }, { "comp_s1_notes": { "textValue": variables.NOTE }, "summary_strengths": { "textValue": "strength narrative" } });
		var events = variables.db.run("SELECT details_json FROM [icf].[audit_event] WHERE entity_type = N'WALK' AND entity_id = :id", { "id": variables.db.guid(w.id) });
		assertTrue(events.recordCount >= 1);
		for (var r = 1; r <= events.recordCount; r++) {
			assertFalse(findNoCase("strength narrative", events.details_json[r]) > 0, "audit has no narrative");
			assertFalse(findNoCase("alert(", events.details_json[r]) > 0);
			assertFalse(findNoCase("Observer Name", events.details_json[r]) > 0);
		}
		var mutations = variables.db.run("SELECT result_json FROM [icf].[walk_mutation] WHERE walk_id = :id", { "id": variables.db.guid(w.id) });
		for (var r = 1; r <= mutations.recordCount; r++) assertFalse(findNoCase("strength narrative", mutations.result_json[r]) > 0, "mutation log has no narrative");
	}

	// ---- WALK-11: older walks render from their pinned version ------------------------------------

	public void function testWalk11OlderWalkRendersFromItsPinnedSnapshotAfterANewVersion() {
		var oldWalk = newWalk();
		var oldPrompt = variables.svc.instrumentFor(p(variables.walker), oldWalk.id);
		var oldItem = findItem(oldPrompt.model, "p1q1");
		var label = "walk11-" & variables.fx.tag();
		var cfg = repoJson("/config/instrument-config.json");
		cfg.instrument.version.versionLabel = label;
		for (var it in cfg.items) if (it.itemKey == "p1q1") it.prompt = "CHANGED PROMPT " & label;
		var imported = variables.c.instrumentImportService.importConfig(cfg);
		var newWalkId = "";
		try {
			var fresh = newWalk();
			newWalkId = fresh.id;
			assertExactTextEquals(imported.versionId, fresh.versionId, "new walks pin the newest renderable version");
			assertExactTextEquals(variables.current.versionId, variables.svc.open(p(variables.walker), oldWalk.id).versionId, "existing walk keeps its version");
			var stillOld = findItem(variables.svc.instrumentFor(p(variables.walker), oldWalk.id).model, "p1q1");
			assertExactTextEquals(oldItem.prompt, stillOld.prompt, "historical walk renders its pinned prompt");
			var changed = findItem(variables.svc.instrumentFor(p(variables.walker), fresh.id).model, "p1q1");
			assertExactTextEquals("CHANGED PROMPT " & label, changed.prompt);
			// The old walk still saves against its own definitions.
			var saved = saveState(oldWalk, {}, { "p1q1": { "storedCode": "Yes" } });
			assertExactTextEquals(variables.current.versionId, saved.versionId);
		} finally {
			if (len(newWalkId)) variables.fx.deleteWalk(newWalkId);
			variables.c.instrumentImportService.discardDraft(label);
			variables.c.snapshotService.clearCache();
		}
	}

	// ---- Phase 5: summary export and the Part 4 email draft -----------------------------------

	/**
	 * SUM-01: the text a reader downloads is the text the shared formatter produces for the walk as
	 * the database holds it. This is the whole persisted path -- rows, stateOf, the server engine,
	 * the formatter -- so it proves the export agrees with the vectors for a real saved walk and not
	 * only for a hand-built state.
	 */
	public void function testServiceSummaryMatchesTheFormatterForAPersistedWalk() {
		var w = newWalk();
		var responses = requiredAnswers();
		responses["comp_s1_q1"] = { "storedCode": "4" };
		responses["comp_s1_q2"] = { "storedCode": "3" };
		responses["comp_s1_notes"] = { "textValue": variables.NOTE };
		responses["comp_s3_applicable"] = { "storedCode": "no" };
		responses["comp_s3_notes"] = { "textValue": "kept" };
		responses["summary_strengths"] = { "textValue": "strength" };
		var saved = saveState(w, { "observer": { "textValue": "Jane Doe" }, "date": { "dateValue": "2026-09-17" } }, responses);

		var out = variables.svc.summary(p(variables.walker), w.id);
		var model = variables.c.snapshotService.renderModelFor(saved.versionId);
		var evaluation = variables.c.visibilityEngine.evaluateVisibility(model, saved.state);
		var expected = variables.c.walkSummaryFormatter.summaryText(model, saved.state, evaluation);
		assertEquals(0, compare(expected, out.text), "The exported text is the formatter's text for the saved state.");
		assertEquals(0, compare(variables.c.walkSummaryFormatter.fileName(model, saved.state, evaluation, w.id), out.fileName));
		assertContains("2.1 DAILY ENGAGEMENT WITH COMPLEX TEXTS  (avg: 3.5)", out.text);
		assertContains("2.3 WORKSHOP MODEL OF INSTRUCTION  (not part of this lesson at the time of the visit)", out.text);
		// SEC-02: the injection string is text in the export, neither escaped nor stripped.
		assertContains("Notes: " & variables.NOTE, out.text);
		assertExactTextEquals("DRAFT", out.status);
		assertExactTextEquals(saved.versionId, out.versionId, "WALK-11: the walk's pinned version, not the current one.");
		assertTrue(out.bytes > 0);
	}

	/** AUTH-04/05: the export re-authorizes the record exactly as opening the walk does. */
	public void function testSummaryAuthorizationMatchesOpen() {
		var w = newWalk();
		var svc = variables.svc;
		var walkId = w.id;

		// A colleague who may read the walk may export it.
		assertTrue(len(svc.summary(p(variables.walker2), walkId).text) > 0, "A reader in scope may export.");

		// A report-only role and an instrument admin hold no walk capability: 403, and no text.
		assertThrows(function() { svc.summary(p(variables.reportOnly), walkId); }, "ICFWalk.Forbidden");
		assertThrows(function() { svc.summary(p(variables.admin), walkId); }, "ICFWalk.Forbidden");
		// Another school is 404, the same answer open() gives, so the route discloses no existence.
		assertThrows(function() { svc.summary(p(variables.otherSchool), walkId); }, "ICFWalk.NotFound");
		assertThrows(function() { svc.open(p(variables.otherSchool), walkId); }, "ICFWalk.NotFound");
		assertThrows(function() { svc.summary(p(variables.foreign), walkId); }, "ICFWalk.NotFound");
		// A malformed id never reaches the database.
		assertThrows(function() { svc.summary(p(variables.walker), "not-a-guid"); }, "ICFWalk.Validation");
	}

	/** A voided walk stays readable by id in Phase 4, so it stays exportable, and a read writes nothing. */
	public void function testSummaryOfAVoidedWalkExportsAndWritesNothing() {
		var w = newWalk();
		var saved = saveState(w, {}, requiredAnswers());
		var completed = variables.svc.complete(p(variables.walker), w.id, { "rowVersion": saved.rowVersion, "clientMutationId": newMutationId() });
		var voided = variables.svc.void(p(variables.walker), w.id, { "rowVersion": completed.rowVersion, "clientMutationId": newMutationId(), "reason": "Voided in a summary test" });

		var rowsBefore = variables.db.run("SELECT COUNT(*) AS n FROM [icf].[walk_mutation] WHERE walk_id = :id", { "id": variables.db.guid(w.id) }).n[1];
		var out = variables.svc.summary(p(variables.walker), w.id);
		assertExactTextEquals("VOIDED", out.status);
		assertContains("ICFWALK SUMMARY", out.text);
		assertTrue(find("VOIDED", out.text) == 0, "The text carries no status line.");

		var after = variables.db.run(
			"SELECT CONVERT(varchar(18), CAST(row_version AS binary(8)), 1) AS rv, (SELECT COUNT(*) FROM [icf].[walk_mutation] WHERE walk_id = :id) AS n FROM [icf].[walk] WHERE walk_id = :id",
			{ "id": variables.db.guid(w.id) }
		);
		assertRowVersionEquals(voided.rowVersion, after.rv[1], "Exporting does not bump the row version.");
		assertEquals(rowsBefore, after.n[1], "Exporting records no mutation.");
	}

	/** SEC-05: the export audit row names the walk and counts bytes; it never carries the text. */
	public void function testSummaryAuditCarriesNoNarrative() {
		var secret = "A sentence about a teacher that must never be logged.";
		var w = newWalk();
		saveState(w, { "observer": { "textValue": secret } }, { "conditions_notes": { "textValue": secret } });
		var out = variables.svc.summary(p(variables.walker), w.id);
		assertContains(secret, out.text, "The text itself does carry the narrative.");

		var q = variables.db.run(
			"SELECT TOP 1 details_json AS d FROM [icf].[audit_event] WHERE entity_type = N'WALK' AND entity_id = :id AND event_type = N'WALK_SUMMARY_EXPORTED' ORDER BY event_at DESC",
			{ "id": variables.db.guid(w.id) }
		);
		assertEquals(1, q.recordCount, "The export was audited.");
		var details = deserializeJSON(q.d[1]);
		var keys = structKeyArray(details);
		arraySort(keys, "text");
		assertExactJsonEquals(["bytes", "status", "versionId"], keys, "Only approved identifiers and counts.");
		assertTrue(find(secret, q.d[1]) == 0, "No narrative value reached the audit row.");
	}

	/**
	 * SUM-07/09: the draft rides the ordinary save path. It is canonicalized on the way in, restored
	 * exactly on reopen, clearable without touching any other answer, and never a completion issue.
	 */
	public void function testEmailDraftRoundTripAndSchema() {
		var w = newWalk();
		var canonical = '{"body":"Body","drafted":true,"includedPartKeys":["part1","comp_s3"],"subject":"Subject","to":"teacher@u46.org"}';
		var responses = requiredAnswers();
		responses["email_workflow"] = { "textValue": canonical };
		responses["summary_strengths"] = { "textValue": "kept" };
		var saved = saveState(w, {}, responses);
		// The mutation response is what the browser adopts, so the canonical form is already in it.
		assertEquals(0, compare(canonical, saved.state.responses.email_workflow.textValue), "Canonical on the way out of the save.");
		assertExactTextEquals("ANSWERED", saved.states.responseStates.email_workflow);

		var reopened = variables.svc.open(p(variables.walker), w.id);
		assertEquals(0, compare(canonical, reopened.state.responses.email_workflow.textValue), "SUM-07: reopening restores it byte for byte.");

		// Key order on the way in does not matter; the stored document is canonical either way.
		var shuffled = duplicate(responses);
		shuffled["email_workflow"] = { "textValue": '{"to":"teacher@u46.org","subject":"Subject","includedPartKeys":["part1","comp_s3"],"drafted":true,"body":"Body"}' };
		var again = saveState(w, {}, shuffled, variables.walker, "", reopened.rowVersion);
		assertEquals(0, compare(canonical, again.state.responses.email_workflow.textValue), "Canonicalized whatever order arrives.");

		// SUM-09: clearing drops the generated text and keeps the recipient, the ticked parts, and
		// every other answer.
		var cleared = duplicate(responses);
		cleared["email_workflow"] = { "textValue": '{"body":"","drafted":false,"includedPartKeys":["part1","comp_s3"],"subject":"","to":"teacher@u46.org"}' };
		var afterClear = saveState(w, {}, cleared, variables.walker, "", again.rowVersion);
		var doc = deserializeJSON(afterClear.state.responses.email_workflow.textValue);
		assertFalse(doc.drafted);
		assertExactTextEquals("", doc.subject);
		assertExactTextEquals("", doc.body);
		assertExactTextEquals("teacher@u46.org", doc.to, "The recipient is kept.");
		assertExactJsonEquals(["part1", "comp_s3"], doc.includedPartKeys, "The ticked parts are kept.");
		assertExactTextEquals("kept", afterClear.state.responses.summary_strengths.textValue, "Other responses are untouched.");
		assertExactTextEquals("Partial", afterClear.state.responses.p1q1.storedCode);

		// A recipient carrying header-injection characters is stored as text; nothing interprets it.
		var hostile = duplicate(responses);
		hostile["email_workflow"] = { "textValue": serializeJSON({ "body": "b", "drafted": true, "includedPartKeys": [], "subject": "s", "to": "a@b.test" & chr(13) & chr(10) & "bcc: victim@example.test" }) };
		var afterHostile = saveState(w, {}, hostile, variables.walker, "", afterClear.rowVersion);
		var hostileDoc = deserializeJSON(afterHostile.state.responses.email_workflow.textValue);
		assertExactTextEquals("a@b.test" & chr(13) & chr(10) & "bcc: victim@example.test", hostileDoc.to, "Stored verbatim as data.");

		// The draft is not an observation: it never appears in the completion issues.
		var model = variables.c.snapshotService.renderModelFor(afterHostile.versionId);
		var evaluation = variables.c.visibilityEngine.evaluateVisibility(model, afterHostile.state);
		for (var issue in variables.svc.completionIssues(model, evaluation)) {
			assertExactTextNotEquals("email_workflow", issue.key, "The email draft is never a completion issue.");
		}
		var completed = variables.svc.complete(p(variables.walker), w.id, { "rowVersion": afterHostile.rowVersion, "clientMutationId": newMutationId() });
		assertExactTextEquals("COMPLETED", completed.status);
		assertEquals(0, compare(afterHostile.state.responses.email_workflow.textValue, completed.state.responses.email_workflow.textValue), "Completion leaves the draft alone.");
	}

	/** The draft schema is enforced on the server; a rejection writes nothing at all. */
	public void function testEmailDraftSchemaRejectionsWriteNothing() {
		var w = newWalk();
		var svc = variables.svc;
		var walkId = w.id;
		var before = variables.svc.open(p(variables.walker), walkId);
		for (var bad in [
			'{"body":"b","drafted":true,"includedPartKeys":[],"subject":"s","to":"","extra":"x"}',
			'{"includedPartKeys":"part1"}',
			'{"includedPartKeys":[{"nested":true}]}',
			'{"subject":{"nested":true}}',
			'{"drafted":{"nested":true}}',
			"not json at all",
			"[1,2,3]"
		]) {
			var payload = bad;
			// The validator reports the first issue's own code, so the rejection names the email
			// draft rather than a generic payload failure: the browser can point at the right field.
			var e = assertThrows(function() {
				svc.save(p(variables.walker), walkId, {
					"rowVersion": before.rowVersion, "clientMutationId": newMutationId(),
					"dimensions": {}, "responses": { "email_workflow": { "textValue": payload } }
				});
			}, "ICFWalk.Validation", "INVALID_EMAIL_DRAFT");
			assertContains("responses.email_workflow.textValue", serializeJSON(variables.c.errors.detailsOf(e)), "The rejection names the field: " & payload);
		}
		var after = variables.svc.open(p(variables.walker), walkId);
		assertRowVersionEquals(before.rowVersion, after.rowVersion, "Every rejection wrote nothing.");
	}

	private struct function findItem(required struct model, required string key) {
		var stack = [arguments.model.root];
		while (arrayLen(stack)) {
			var node = stack[arrayLen(stack)];
			arrayDeleteAt(stack, arrayLen(stack));
			for (var it in node.items) if (it.itemKey == arguments.key) return it;
			for (var child in node.children) arrayAppend(stack, child);
		}
		return {};
	}
}
