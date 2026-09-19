/**
 * Phase 0-4 correction regressions at the service level, against the real database.
 *
 * Every case here fails against the behaviour delivered in Phase 4 and proves the corrected
 * invariant:
 *
 *   - a create replay re-authorizes the recorded walk and is bound to the semantic request, so an
 *     old mutation id can neither disclose an out-of-scope walk nor stand in for a different
 *     request (CORR-01..CORR-04);
 *   - the server, not the browser, owns visibility and retention: an omitted hidden value is
 *     retained, a crafted hidden value is refused, hide-then-show restores the stored value, CLEAR
 *     clears, and NOT_APPLICABLE clears ratings while keeping notes (CORR-05..CORR-09);
 *   - the mutation/concurrency envelope is mandatory and malformed tokens write nothing
 *     (CORR-10..CORR-12);
 *   - an identical save to a COMPLETED walk is a no-op and a material one appends exactly one
 *     revision (CORR-13);
 *   - observed_at follows the Visit Date and falls back to the creation instant when it is cleared
 *     (CORR-14);
 *   - a whole-state save needs both root containers, JSON primitive types are not coerced, and
 *     client-asserted response state is refused (CORR-15..CORR-17).
 *
 * Fixture tree: D (district) -> S1, S2 (schools); Y (district) -> SY (school, out of every
 * fixture user's scope).
 */
component extends="icfwalktests.BaseSpec" output="false" {

	public string function skipReason() {
		if (!schemaPresent()) return "icf schema is not present.";
		if (structIsEmpty(variables.c.snapshotService.currentVersion())) return "no renderable instrument version is seeded.";
		return "";
	}

	public void function beforeAll() {
		variables.fx = createObject("component", "icfwalktests.support.Fixtures").init(variables.c, "corr-" & lCase(left(replace(createUUID(), "-", "", "all"), 8)));
		variables.svc = variables.c.walkService;
		variables.db = variables.c.db;
		var fx = variables.fx;
		variables.D = fx.orgUnit("d", "DISTRICT");
		variables.S1 = fx.orgUnit("s1", "SCHOOL", variables.D);
		variables.S2 = fx.orgUnit("s2", "SCHOOL", variables.D);
		variables.Y = fx.orgUnit("y", "DISTRICT");
		variables.SY = fx.orgUnit("sy", "SCHOOL", variables.Y);

		variables.walker = fx.user("walker");
		variables.walkerAssignment = fx.assign(variables.walker.userId, "SCHOOL_WALK_REPORT", variables.S1, false);
		variables.stranger = fx.user("stranger");
		fx.assign(variables.stranger.userId, "DISTRICT_WALK_REPORT", variables.Y, true);

		variables.current = variables.c.snapshotService.currentVersion();
		variables.model = variables.c.snapshotService.renderModelFor(variables.current.versionId);
	}

	public void function afterAll() {
		variables.fx.remove();
	}

	// ---- helpers ------------------------------------------------------------------------------

	private struct function p(required struct user) { return variables.fx.principal(arguments.user.userId); }
	private string function newMutationId() { return variables.db.newGuid(); }

	private struct function newWalk(string orgUnitId = "", struct user) {
		var u = isNull(arguments.user) ? variables.walker : arguments.user;
		return variables.svc.create(p(u), { "orgUnitId": len(arguments.orgUnitId) ? arguments.orgUnitId : variables.S1, "clientMutationId": newMutationId() });
	}

	private struct function save(required struct walk, required struct dims, required struct responses, string mutationId = "", struct user) {
		var u = isNull(arguments.user) ? variables.walker : arguments.user;
		return variables.svc.save(p(u), arguments.walk.id, {
			"rowVersion": arguments.walk.rowVersion,
			"clientMutationId": len(arguments.mutationId) ? arguments.mutationId : newMutationId(),
			"dimensions": arguments.dims, "responses": arguments.responses
		});
	}

	private query function responseRow(required string walkId, required string itemKey) {
		return variables.db.run(
			"SELECT r.response_state, r.text_value, o.stored_code FROM [icf].[walk_response] r JOIN [icf].[item_definition] i ON i.item_id = r.item_id LEFT JOIN [icf].[response_option] o ON o.option_id = r.selected_option_id WHERE r.walk_id = :id AND i.item_key = :key",
			{ "id": variables.db.guid(arguments.walkId), "key": variables.db.nvarchar(arguments.itemKey, 100) });
	}

	private query function dimensionRow(required string walkId, required string code) {
		return variables.db.run(
			"SELECT x.date_value, dv.value_code FROM [icf].[walk_dimension_value] x JOIN [icf].[dimension_definition] d ON d.dimension_id = x.dimension_id LEFT JOIN [icf].[dimension_value] dv ON dv.value_id = x.selected_value_id WHERE x.walk_id = :id AND d.code = :code",
			{ "id": variables.db.guid(arguments.walkId), "code": variables.db.nvarchar(arguments.code, 100) });
	}

	private query function walkRow(required string walkId) {
		return variables.db.run("SELECT status, observed_at, created_at, CONVERT(varchar(18), CAST(row_version AS binary(8)), 1) AS rv FROM [icf].[walk] WHERE walk_id = :id", { "id": variables.db.guid(arguments.walkId) });
	}

	private numeric function scalarFor(required string sql, required string walkId) {
		return variables.db.scalar(arguments.sql, { "id": variables.db.guid(arguments.walkId) });
	}

	private struct function requiredAnswers() {
		return {
			"p1q1": { "storedCode": "Partial" }, "p1q2": { "storedCode": "Retrieval" }, "p1q3": { "storedCode": "Analysis" },
			"part1_adopted_pacing": { "storedCode": "on" }, "part1_adopted_ac1": { "storedCode": "3" }, "part1_adopted_ac2": { "storedCode": "4" },
			"part1_targettask_tt1": { "storedCode": "5" }, "part1_targettask_tt2": { "storedCode": "2" }
		};
	}

	/** Moves the walker's only assignment from one school to another, as a role change would. */
	private void function moveWalkerTo(required string orgUnitId) {
		variables.c.roleScopeRepository.deleteAssignmentsForUser(variables.walker.userId);
		variables.fx.assign(variables.walker.userId, "SCHOOL_WALK_REPORT", arguments.orgUnitId, false);
	}

	// ---- CORR-01: a create replay never discloses a walk the principal may no longer read --------

	public void function testCorr01CreateReplayIsReauthorizedAfterAccessIsRevoked() {
		var mutationId = newMutationId();
		var atSchoolA = variables.svc.create(p(variables.walker), { "orgUnitId": variables.S1, "clientMutationId": mutationId });
		assertEquals(variables.S1, atSchoolA.orgUnitId);
		// Access to School A is revoked; the walker keeps School B.
		moveWalkerTo(variables.S2);
		try {
			// Retrying the same mutation id while naming the school the walker still has must not
			// hand back the School A walk: the request differs and the record is out of scope.
			assertThrows(function() { variables.svc.create(p(variables.walker), { "orgUnitId": variables.S2, "clientMutationId": mutationId }); }, "ICFWalk");
			// Naming School A again is refused by org scope before anything is replayed.
			assertThrows(function() { variables.svc.create(p(variables.walker), { "orgUnitId": variables.S1, "clientMutationId": mutationId }); }, "ICFWalk.NotFound");
			// And the walk itself is no longer readable.
			assertThrows(function() { variables.svc.open(p(variables.walker), atSchoolA.id); }, "ICFWalk.NotFound");
		} finally {
			moveWalkerTo(variables.S1);
		}
		// With access restored the exact retry replays the original committed result.
		var replayed = variables.svc.create(p(variables.walker), { "orgUnitId": variables.S1, "clientMutationId": mutationId });
		assertTrue(replayed.replayed);
		assertEquals(atSchoolA.id, replayed.id);
		assertEquals(atSchoolA.rowVersion, replayed.rowVersion);
	}

	/**
	 * A recorded mutation that names a walk outside the principal's scope answers 404 and discloses
	 * nothing -- the record-level check runs before the id is compared with the request.
	 */
	public void function testCorr02ReplayOfARecordedMutationOutsideScopeIsNotFound() {
		var foreign = variables.svc.create(p(variables.stranger), { "orgUnitId": variables.SY, "clientMutationId": newMutationId() });
		var mutationId = newMutationId();
		variables.db.run(
			"INSERT INTO [icf].[walk_mutation] (mutation_id, walk_id, actor_user_id, action, result_json) VALUES (:id, :walk, :actor, N'CREATE', :result)",
			{ "id": variables.db.guid(mutationId), "walk": variables.db.guid(foreign.id), "actor": variables.db.guid(variables.walker.userId), "result": variables.db.ntext('{"walkId":"' & foreign.id & '"}') }
		);
		assertThrows(function() { variables.svc.create(p(variables.walker), { "orgUnitId": variables.S1, "clientMutationId": mutationId }); }, "ICFWalk.NotFound");
		variables.db.run("DELETE FROM [icf].[walk_mutation] WHERE mutation_id = :id", { "id": variables.db.guid(mutationId) });
	}

	// ---- CORR-03 / CORR-04: mutation ids are bound to their semantic request ---------------------

	public void function testCorr03SameMutationIdWithAnAlteredRequestIsRefused() {
		var mutationId = newMutationId();
		var first = variables.svc.create(p(variables.walker), { "orgUnitId": variables.S1, "clientMutationId": mutationId, "dimensions": { "observer": { "textValue": "A" } }, "responses": {} });
		// Same id, different semantic content: this is not an equivalent retry.
		assertThrows(function() {
			variables.svc.create(p(variables.walker), { "orgUnitId": variables.S1, "clientMutationId": mutationId, "dimensions": { "observer": { "textValue": "B" } }, "responses": {} });
		}, "ICFWalk.Conflict", "MUTATION_ID_REUSED");
		// The exact request still replays.
		var replay = variables.svc.create(p(variables.walker), { "orgUnitId": variables.S1, "clientMutationId": mutationId, "dimensions": { "observer": { "textValue": "A" } }, "responses": {} });
		assertTrue(replay.replayed);
		assertEquals(first.id, replay.id);
		assertEquals(1, scalarFor("SELECT COUNT(*) AS n FROM [icf].[walk_mutation] WHERE walk_id = :id AND action = N'CREATE'", first.id));

		// The same rule holds for a save, a complete, and a void.
		var w = newWalk();
		var saveId = newMutationId();
		var saved = save(w, { "observer": { "textValue": "first" } }, {}, saveId);
		assertThrows(function() { save(w, { "observer": { "textValue": "second" } }, {}, saveId); }, "ICFWalk.Conflict", "MUTATION_ID_REUSED");
		var saveReplay = variables.svc.save(p(variables.walker), w.id, { "rowVersion": w.rowVersion, "clientMutationId": saveId, "dimensions": { "observer": { "textValue": "first" } }, "responses": {} });
		assertTrue(saveReplay.replayed);
		assertEquals(saved.rowVersion, saveReplay.rowVersion);

		var full = save(saved, {}, requiredAnswers());
		var completeId = newMutationId();
		var done = variables.svc.complete(p(variables.walker), w.id, { "rowVersion": full.rowVersion, "clientMutationId": completeId });
		var completeReplay = variables.svc.complete(p(variables.walker), w.id, { "rowVersion": full.rowVersion, "clientMutationId": completeId });
		assertTrue(completeReplay.replayed);
		assertEquals(1, scalarFor("SELECT COUNT(*) AS n FROM [icf].[walk_revision] WHERE walk_id = :id", w.id), "a completion replay appends no second revision");

		// A void id is bound to its reason: the same id with a different reason is a different request.
		var voidId = newMutationId();
		var voided = variables.svc.void(p(variables.walker), w.id, { "rowVersion": done.rowVersion, "clientMutationId": voidId, "reason": "one" });
		assertEquals("VOIDED", voided.status);
		var voidReplay = variables.svc.void(p(variables.walker), w.id, { "rowVersion": done.rowVersion, "clientMutationId": voidId, "reason": "one" });
		assertTrue(voidReplay.replayed);
		assertThrows(function() { variables.svc.void(p(variables.walker), w.id, { "rowVersion": done.rowVersion, "clientMutationId": voidId, "reason": "two" }); }, "ICFWalk.Conflict", "MUTATION_ID_REUSED");
	}

	/**
	 * A create that committed against the current version still replays after a newer version is
	 * published: the recorded-mutation lookup runs before the version check, and the requested
	 * version is not part of the fingerprint.
	 */
	public void function testCorr04CreateReplaySurvivesANewerPublishedVersion() {
		var mutationId = newMutationId();
		var first = variables.svc.create(p(variables.walker), { "orgUnitId": variables.S1, "clientMutationId": mutationId, "versionId": variables.current.versionId, "dimensions": {}, "responses": {} });
		// The client now holds a version id that is no longer current: a fresh create would be told
		// to reload, but the committed mutation must still replay.
		var stale = variables.db.newGuid();
		var replay = variables.svc.create(p(variables.walker), { "orgUnitId": variables.S1, "clientMutationId": mutationId, "versionId": stale, "dimensions": {}, "responses": {} });
		assertTrue(replay.replayed);
		assertEquals(first.id, replay.id);
		assertEquals(variables.current.versionId, replay.versionId);
		// A new mutation id with that stale version is still refused.
		assertThrows(function() { variables.svc.create(p(variables.walker), { "orgUnitId": variables.S1, "clientMutationId": newMutationId(), "versionId": stale }); }, "ICFWalk.Conflict", "INSTRUMENT_VERSION_CHANGED");
	}

	// ---- CORR-05..CORR-09: server-authoritative visibility, retention, and clearing --------------

	/** A hidden value the browser omits is retained from the database, not deleted. */
	public void function testCorr05OmittedHiddenValueIsRetained() {
		var w = newWalk();
		var visible = save(w, { "grade": { "selectedValueCode": "7" }, "period": { "selectedValueCode": "third" } }, {});
		assertEquals("third", dimensionRow(w.id, "period").value_code[1]);
		// Grade 2 hides Period. The browser sends the whole state without it.
		var hidden = save(visible, { "grade": { "selectedValueCode": "2" } }, {});
		assertEquals("third", dimensionRow(w.id, "period").value_code[1], "the hidden Period value is retained");
		assertEquals("HIDDEN", hidden.states.dimensionStates.period);

		// The same for a conditional classroom section's answers.
		var dual = save(hidden, { "grade": { "selectedValueCode": "2" }, "classType": { "selectedValueCode": "dual_language" } }, { "dual_language_q1": { "storedCode": "yes" }, "dual_language_notes": { "textValue": "observed" } });
		assertEquals("ANSWERED", responseRow(w.id, "dual_language_q1").response_state[1]);
		var general = save(dual, { "grade": { "selectedValueCode": "2" }, "classType": { "selectedValueCode": "general_education" } }, {});
		var row = responseRow(w.id, "dual_language_q1");
		assertEquals("HIDDEN", row.response_state[1]);
		assertEquals("yes", row.stored_code[1], "the hidden answer is retained without the browser echoing it");
		assertEquals("observed", responseRow(w.id, "dual_language_notes").text_value[1]);
	}

	/** A crafted client cannot inject or change a value the instrument currently hides. */
	public void function testCorr06HiddenValueInjectionIsIgnored() {
		var w = newWalk();
		var seeded = save(w, { "grade": { "selectedValueCode": "7" }, "period": { "selectedValueCode": "third" }, "classType": { "selectedValueCode": "dual_language" } }, { "dual_language_q1": { "storedCode": "yes" } });
		var hiddenNow = save(seeded, { "grade": { "selectedValueCode": "2" }, "classType": { "selectedValueCode": "general_education" } }, {});
		// A crafted payload asserts new values for both currently hidden targets.
		var crafted = save(hiddenNow, { "grade": { "selectedValueCode": "2" }, "classType": { "selectedValueCode": "general_education" }, "period": { "selectedValueCode": "first" } }, { "dual_language_q1": { "storedCode": "no" } });
		assertEquals("third", dimensionRow(w.id, "period").value_code[1], "a hidden dimension keeps its stored value");
		assertEquals("yes", responseRow(w.id, "dual_language_q1").stored_code[1], "a hidden response keeps its stored value");
		assertEquals("third", crafted.state.dimensions.period.selectedValueCode, "the response reports the stored value, not the crafted one");
		assertEquals("yes", crafted.state.responses.dual_language_q1.storedCode);
		// An injected value for a target that has no stored value stays empty rather than landing.
		var w2 = newWalk();
		var injected = save(w2, { "grade": { "selectedValueCode": "2" } }, { "dual_language_q1": { "storedCode": "yes" } });
		assertEquals("HIDDEN", responseRow(w2.id, "dual_language_q1").response_state[1]);
		assertTrue(isNull(responseRow(w2.id, "dual_language_q1").stored_code[1]) || !len(responseRow(w2.id, "dual_language_q1").stored_code[1]), "nothing was injected into the hidden item");
	}

	/** Hiding and re-showing a value returns exactly what was stored. */
	public void function testCorr07HideThenShowRestoresTheStoredValue() {
		var w = newWalk();
		var shown = save(w, { "grade": { "selectedValueCode": "8" }, "period": { "selectedValueCode": "fifth" } }, {});
		var hidden = save(shown, { "grade": { "selectedValueCode": "1" } }, {});
		assertEquals("HIDDEN", hidden.states.dimensionStates.period);
		var reshown = save(hidden, { "grade": { "selectedValueCode": "8" } }, {});
		assertEquals("ANSWERED", reshown.states.dimensionStates.period);
		assertEquals("fifth", reshown.state.dimensions.period.selectedValueCode);
		assertEquals("fifth", dimensionRow(w.id, "period").value_code[1]);
	}

	/** A visible value the browser omits is a clear: whole-state saves still clear. */
	public void function testCorr08OmittingAVisibleValueClearsIt() {
		var w = newWalk();
		var withNotes = save(w, { "observer": { "textValue": "Fixture Observer" } }, { "comp_s1_notes": { "textValue": "some notes" } });
		assertEquals("some notes", responseRow(w.id, "comp_s1_notes").text_value[1]);
		var cleared = save(withNotes, {}, {});
		assertEquals(0, dimensionRow(w.id, "observer").recordCount, "a visible dimension the client omits is cleared");
		assertEquals("UNANSWERED", responseRow(w.id, "comp_s1_notes").response_state[1]);
		assertTrue(isNull(responseRow(w.id, "comp_s1_notes").text_value[1]) || !len(responseRow(w.id, "comp_s1_notes").text_value[1]));
	}

	/** NOT_APPLICABLE clears ratings and keeps notes, even when the client insists otherwise. */
	public void function testCorr09NotApplicableClearsRatingsAndKeepsNotes() {
		var w = newWalk();
		var yes = save(w, {}, { "comp_s3_applicable": { "storedCode": "yes" }, "comp_s3_q1": { "storedCode": "4" }, "comp_s3_notes": { "textValue": "kept" } });
		assertEquals("ANSWERED", responseRow(w.id, "comp_s3_q1").response_state[1]);
		// The client marks the component No but keeps sending the rating: the server clears it.
		var no = save(yes, {}, { "comp_s3_applicable": { "storedCode": "no" }, "comp_s3_q1": { "storedCode": "4" }, "comp_s3_notes": { "textValue": "kept" } });
		var rating = responseRow(w.id, "comp_s3_q1");
		assertEquals("NOT_APPLICABLE", rating.response_state[1]);
		assertTrue(isNull(rating.stored_code[1]) || !len(rating.stored_code[1]), "a not-applicable rating is cleared, never retained");
		assertEquals("kept", responseRow(w.id, "comp_s3_notes").text_value[1], "notes are preserved");
		// Switching back to Yes returns the rating as UNANSWERED, not as the cleared value.
		var back = save(no, {}, { "comp_s3_applicable": { "storedCode": "yes" }, "comp_s3_notes": { "textValue": "kept" } });
		assertEquals("UNANSWERED", responseRow(w.id, "comp_s3_q1").response_state[1]);
		assertFalse(structKeyExists(back.state.responses, "comp_s3_q1") && structKeyExists(back.state.responses.comp_s3_q1, "storedCode"));
	}

	// ---- CORR-10..CORR-12: the mandatory mutation/concurrency envelope ---------------------------

	public void function testCorr10EveryMutationRequiresAClientMutationId() {
		var w = newWalk();
		assertThrows(function() { variables.svc.create(p(variables.walker), { "orgUnitId": variables.S1 }); }, "ICFWalk.Validation", "CLIENT_MUTATION_ID_REQUIRED");
		assertThrows(function() { variables.svc.save(p(variables.walker), w.id, { "rowVersion": w.rowVersion, "dimensions": {}, "responses": {} }); }, "ICFWalk.Validation", "CLIENT_MUTATION_ID_REQUIRED");
		assertThrows(function() { variables.svc.complete(p(variables.walker), w.id, { "rowVersion": w.rowVersion }); }, "ICFWalk.Validation", "CLIENT_MUTATION_ID_REQUIRED");
		assertThrows(function() { variables.svc.void(p(variables.walker), w.id, { "rowVersion": w.rowVersion }); }, "ICFWalk.Validation", "CLIENT_MUTATION_ID_REQUIRED");
		// Malformed tokens are refused too, and nothing is written.
		assertThrows(function() { variables.svc.save(p(variables.walker), w.id, { "rowVersion": w.rowVersion, "clientMutationId": "not-a-guid", "dimensions": {}, "responses": {} }); }, "ICFWalk.Validation", "CLIENT_MUTATION_ID_INVALID");
		assertThrows(function() { variables.svc.save(p(variables.walker), w.id, { "rowVersion": w.rowVersion, "clientMutationId": 12345, "dimensions": {}, "responses": {} }); }, "ICFWalk.Validation", "CLIENT_MUTATION_ID_INVALID");
		assertEquals(w.rowVersion, walkRow(w.id).rv[1], "nothing was written");
		assertEquals("DRAFT", walkRow(w.id).status[1]);
	}

	public void function testCorr11SaveCompleteAndVoidRequireARowVersionButCreateDoesNot() {
		var w = newWalk();
		assertThrows(function() { variables.svc.save(p(variables.walker), w.id, { "clientMutationId": newMutationId(), "dimensions": {}, "responses": {} }); }, "ICFWalk.Validation", "ROW_VERSION_REQUIRED");
		assertThrows(function() { variables.svc.complete(p(variables.walker), w.id, { "clientMutationId": newMutationId() }); }, "ICFWalk.Validation", "ROW_VERSION_REQUIRED");
		assertThrows(function() { variables.svc.void(p(variables.walker), w.id, { "clientMutationId": newMutationId() }); }, "ICFWalk.Validation", "ROW_VERSION_REQUIRED");
		assertThrows(function() { variables.svc.void(p(variables.walker), w.id, { "clientMutationId": newMutationId(), "rowVersion": "0xZZ" }); }, "ICFWalk.Validation", "ROW_VERSION_INVALID");
		assertEquals(w.rowVersion, walkRow(w.id).rv[1], "nothing was written");
		// A create needs no prior row version.
		var fresh = variables.svc.create(p(variables.walker), { "orgUnitId": variables.S1, "clientMutationId": newMutationId() });
		assertEquals("DRAFT", fresh.status);
	}

	public void function testCorr12AStaleVoidIsARefusalThatChangesNothing() {
		var w = newWalk();
		var moved = save(w, { "observer": { "textValue": "moved on" } }, {});
		var e = assertThrows(function() { variables.svc.void(p(variables.walker), w.id, { "rowVersion": w.rowVersion, "clientMutationId": newMutationId(), "reason": "stale" }); }, "ICFWalk.Conflict", "STALE_ROW_VERSION");
		var row = walkRow(w.id);
		assertEquals("DRAFT", row.status[1], "a stale void does not void the walk");
		assertEquals(moved.rowVersion, row.rv[1], "and does not advance the row version");
		// The current token works.
		var voided = variables.svc.void(p(variables.walker), w.id, { "rowVersion": moved.rowVersion, "clientMutationId": newMutationId() });
		assertEquals("VOIDED", voided.status);
	}

	// ---- CORR-13: completed-walk no-op saves -----------------------------------------------------

	public void function testCorr13IdenticalCompletedSaveIsANoOpAndAMaterialOneAppendsOneRevision() {
		var w = newWalk();
		var answers = requiredAnswers();
		answers["comp_s1_notes"] = { "textValue": "before completion" };
		var full = save(w, { "observer": { "textValue": "Fixture Observer" } }, answers);
		var done = variables.svc.complete(p(variables.walker), w.id, { "rowVersion": full.rowVersion, "clientMutationId": newMutationId() });
		assertEquals(1, scalarFor("SELECT COUNT(*) AS n FROM [icf].[walk_revision] WHERE walk_id = :id", w.id));

		// An identical save writes nothing: no revision, no new row version.
		var same = variables.svc.save(p(variables.walker), w.id, { "rowVersion": done.rowVersion, "clientMutationId": newMutationId(), "dimensions": { "observer": { "textValue": "Fixture Observer" } }, "responses": answers });
		assertEquals(done.rowVersion, same.rowVersion, "an identical completed save does not advance the row version");
		assertEquals(done.rowVersion, walkRow(w.id).rv[1]);
		assertEquals(1, scalarFor("SELECT COUNT(*) AS n FROM [icf].[walk_revision] WHERE walk_id = :id", w.id), "and appends no revision");
		assertEquals(0, scalarFor("SELECT COUNT(*) AS n FROM [icf].[audit_event] WHERE entity_type = N'WALK' AND entity_id = :id AND event_type = N'WALK_POST_COMPLETION_EDIT'", w.id));

		// A material change appends exactly one revision and one aggregate update.
		answers["comp_s1_notes"] = { "textValue": "after completion" };
		var edited = variables.svc.save(p(variables.walker), w.id, { "rowVersion": same.rowVersion, "clientMutationId": newMutationId(), "dimensions": { "observer": { "textValue": "Fixture Observer" } }, "responses": answers });
		assertNotEquals(done.rowVersion, edited.rowVersion);
		assertEquals(2, scalarFor("SELECT COUNT(*) AS n FROM [icf].[walk_revision] WHERE walk_id = :id", w.id), "exactly one pre-edit revision for the material change");
		assertEquals(1, scalarFor("SELECT COUNT(*) AS n FROM [icf].[audit_event] WHERE entity_type = N'WALK' AND entity_id = :id AND event_type = N'WALK_POST_COMPLETION_EDIT'", w.id));
		assertEquals("after completion", responseRow(w.id, "comp_s1_notes").text_value[1]);
		assertEquals("COMPLETED", walkRow(w.id).status[1]);
	}

	// ---- CORR-14: observed_at follows the Visit Date ---------------------------------------------

	public void function testCorr14VisitDateSetThenClearedFallsBackToTheCreationInstant() {
		var w = newWalk();
		var created = walkRow(w.id);
		assertEquals(dateFormat(created.created_at[1], "yyyy-mm-dd") & " " & timeFormat(created.created_at[1], "HH:mm:ss"), dateFormat(created.observed_at[1], "yyyy-mm-dd") & " " & timeFormat(created.observed_at[1], "HH:mm:ss"), "a new walk observes at its creation instant");
		var dated = save(w, { "date": { "dateValue": "2026-05-04" } }, {});
		assertEquals("2026-05-04", dateFormat(walkRow(w.id).observed_at[1], "yyyy-mm-dd"));
		// Clearing the Visit Date must not leave the old observation timestamp behind.
		var cleared = save(dated, {}, {});
		assertEquals(0, dimensionRow(w.id, "date").recordCount, "the Visit Date value is gone");
		var after = walkRow(w.id);
		assertEquals(dateFormat(after.created_at[1], "yyyy-mm-dd") & " " & timeFormat(after.created_at[1], "HH:mm:ss"), dateFormat(after.observed_at[1], "yyyy-mm-dd") & " " & timeFormat(after.observed_at[1], "HH:mm:ss"), "observed_at falls back to the creation instant");
	}

	// ---- CORR-15..CORR-17: strict whole-state payloads -------------------------------------------

	public void function testCorr15WholeStateSaveRequiresBothRootContainers() {
		var w = newWalk();
		assertThrows(function() { variables.svc.save(p(variables.walker), w.id, { "rowVersion": w.rowVersion, "clientMutationId": newMutationId(), "responses": {} }); }, "ICFWalk.Validation", "STATE_CONTAINER_REQUIRED");
		assertThrows(function() { variables.svc.save(p(variables.walker), w.id, { "rowVersion": w.rowVersion, "clientMutationId": newMutationId(), "dimensions": {} }); }, "ICFWalk.Validation", "STATE_CONTAINER_REQUIRED");
		assertThrows(function() { variables.svc.save(p(variables.walker), w.id, { "rowVersion": w.rowVersion, "clientMutationId": newMutationId(), "dimensions": [], "responses": {} }); }, "ICFWalk.Validation", "STATE_CONTAINER_INVALID");
		assertThrows(function() { variables.svc.save(p(variables.walker), w.id, { "rowVersion": w.rowVersion, "clientMutationId": newMutationId(), "dimensions": {}, "responses": "" }); }, "ICFWalk.Validation", "STATE_CONTAINER_INVALID");
		// A create may omit both (it starts from the engine's blank state) but never just one.
		assertThrows(function() { variables.svc.create(p(variables.walker), { "orgUnitId": variables.S1, "clientMutationId": newMutationId(), "dimensions": {} }); }, "ICFWalk.Validation", "STATE_CONTAINER_REQUIRED");
		assertEquals(w.rowVersion, walkRow(w.id).rv[1], "nothing was written");
	}

	public void function testCorr16JsonPrimitiveTypesAreCheckedNotCoerced() {
		var w = newWalk();
		// The JSON number 4 is not the option code "4", and the JSON boolean is not the code "yes".
		var e = assertThrows(function() {
			variables.svc.save(p(variables.walker), w.id, { "rowVersion": w.rowVersion, "clientMutationId": newMutationId(), "dimensions": {}, "responses": { "part1_adopted_ac1": { "storedCode": deserializeJSON("4") } } });
		}, "ICFWalk.Validation", "INVALID_RESPONSE_VALUE");
		assertThrows(function() {
			variables.svc.save(p(variables.walker), w.id, { "rowVersion": w.rowVersion, "clientMutationId": newMutationId(), "dimensions": {}, "responses": { "comp_s3_applicable": { "storedCode": deserializeJSON("true") } } });
		}, "ICFWalk.Validation", "INVALID_RESPONSE_VALUE");
		assertThrows(function() {
			variables.svc.save(p(variables.walker), w.id, { "rowVersion": w.rowVersion, "clientMutationId": newMutationId(), "dimensions": { "date": { "dateValue": deserializeJSON("20260504") } }, "responses": {} });
		}, "ICFWalk.Validation", "INVALID_DATE");
		assertThrows(function() {
			variables.svc.save(p(variables.walker), w.id, { "rowVersion": w.rowVersion, "clientMutationId": newMutationId(), "dimensions": { "grade": { "selectedValueCode": deserializeJSON("7") } }, "responses": {} });
		}, "ICFWalk.Validation", "INVALID_DIMENSION_VALUE");
		assertEquals(w.rowVersion, walkRow(w.id).rv[1], "nothing was written");
		// The same values as JSON strings are accepted.
		var ok = variables.svc.save(p(variables.walker), w.id, { "rowVersion": w.rowVersion, "clientMutationId": newMutationId(), "dimensions": { "grade": { "selectedValueCode": "7" } }, "responses": { "part1_adopted_ac1": { "storedCode": "4" } } });
		assertEquals("4", responseRow(w.id, "part1_adopted_ac1").stored_code[1]);
	}

	public void function testCorr17ClientAssertedResponseStateCannotControlPersistedState() {
		var w = newWalk();
		var e = assertThrows(function() {
			variables.svc.save(p(variables.walker), w.id, { "rowVersion": w.rowVersion, "clientMutationId": newMutationId(), "dimensions": {}, "responses": { "comp_s1_q1": { "state": "ANSWERED", "storedCode": "4" } } });
		}, "ICFWalk.Validation", "CLIENT_STATE_NOT_ACCEPTED");
		assertEquals(w.rowVersion, walkRow(w.id).rv[1], "nothing was written");
		// And an unanswered item asserted as ANSWERED never reaches the database.
		assertThrows(function() {
			variables.svc.save(p(variables.walker), w.id, { "rowVersion": w.rowVersion, "clientMutationId": newMutationId(), "dimensions": {}, "responses": { "comp_s1_q1": { "state": "ANSWERED" } } });
		}, "ICFWalk.Validation", "CLIENT_STATE_NOT_ACCEPTED");
		assertEquals("UNANSWERED", responseRow(w.id, "comp_s1_q1").response_state[1]);
		// The server derives the state from its own engine: a hidden item is HIDDEN whatever the
		// client would prefer it to be.
		var hidden = variables.svc.save(p(variables.walker), w.id, { "rowVersion": w.rowVersion, "clientMutationId": newMutationId(), "dimensions": { "grade": { "selectedValueCode": "2" } }, "responses": {} });
		assertEquals("HIDDEN", responseRow(w.id, "dual_language_q1").response_state[1]);
	}
}
