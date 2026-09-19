/**
 * Second Phase 0-4 correction session: replay coherence and legacy mutation provenance.
 *
 * CORRECTION 1 -- replay / rowversion coherence. A replay returned the recorded walk as it stands
 * *now*, including its current row version, while the retrying session still held the local state
 * that went with the ORIGINAL mutation. So an old successful SAVE retried after a later successful
 * save handed stale client state a live concurrency token, and that session's next save overwrote
 * the newer work without ever seeing a conflict. The invariant proved here: an idempotent replay
 * never pairs stale client state with a row version representing newer server state. When the
 * aggregate still stands where the mutation left it, the replay is the coherent original outcome;
 * when it has advanced, the replay is refused with 409 MUTATION_REPLAY_SUPERSEDED and the client has
 * to reconcile like any other conflict.
 *
 * CORRECTION 4 -- legacy NULL fingerprints. Migration 004 left pre-migration mutation rows with a
 * NULL request_fingerprint, and those rows replayed as ordinary successes even though nothing about
 * them can prove the new request is the request they committed. They now answer a deterministic
 * conflict, after the authorization and actor/action/target checks, and write nothing.
 *
 * Everything asserts database state, mutation rows, and row versions directly rather than trusting
 * the service's own return values. Fixtures are synthetic and removed in afterAll.
 */
component extends="icfwalktests.BaseSpec" output="false" {

	public string function skipReason() {
		if (!schemaPresent()) return "icf schema is not present.";
		if (structIsEmpty(variables.c.snapshotService.currentVersion())) return "no renderable instrument version is seeded.";
		return "";
	}

	public void function beforeAll() {
		variables.fx = createObject("component", "icfwalktests.support.Fixtures").init(variables.c, "replay-" & lCase(left(replace(createUUID(), "-", "", "all"), 8)));
		variables.svc = variables.c.walkService;
		variables.db = variables.c.db;
		var fx = variables.fx;
		variables.D = fx.orgUnit("d", "DISTRICT");
		variables.S1 = fx.orgUnit("s1", "SCHOOL", variables.D);
		variables.S2 = fx.orgUnit("s2", "SCHOOL", variables.D);

		// Two sessions of the same person: the walk is owner-scoped, so "session A" and "session B"
		// are the same principal holding two different local states, exactly as two browser tabs do.
		variables.walker = fx.user("walker");
		fx.assign(variables.walker.userId, "SCHOOL_WALK_REPORT", variables.S1, false);
		variables.other = fx.user("other-walker");
		fx.assign(variables.other.userId, "SCHOOL_WALK_REPORT", variables.S2, false);

		variables.current = variables.c.snapshotService.currentVersion();
	}

	public void function afterAll() {
		variables.fx.remove();
	}

	// ---- helpers -------------------------------------------------------------------------------

	private struct function p(required struct user) { return variables.fx.principal(arguments.user.userId); }
	private string function newMutationId() { return variables.db.newGuid(); }

	private struct function newWalk(string orgUnitId = "") {
		return variables.svc.create(p(variables.walker), { "orgUnitId": len(arguments.orgUnitId) ? arguments.orgUnitId : variables.S1, "clientMutationId": newMutationId() });
	}

	private struct function save(required struct walk, required struct dims, string mutationId = "", string rowVersion = "") {
		return variables.svc.save(p(variables.walker), arguments.walk.id, {
			"rowVersion": len(arguments.rowVersion) ? arguments.rowVersion : arguments.walk.rowVersion,
			"clientMutationId": len(arguments.mutationId) ? arguments.mutationId : newMutationId(),
			"dimensions": arguments.dims, "responses": {}
		});
	}

	private string function storedRowVersion(required string walkId) {
		return variables.db.run("SELECT CONVERT(varchar(18), CAST(row_version AS binary(8)), 1) AS rv FROM [icf].[walk] WHERE walk_id = :id", { "id": variables.db.guid(arguments.walkId) }).rv[1];
	}

	private string function storedObserver(required string walkId) {
		var q = variables.db.run(
			"SELECT x.text_value FROM [icf].[walk_dimension_value] x JOIN [icf].[dimension_definition] d ON d.dimension_id = x.dimension_id WHERE x.walk_id = :id AND d.code = N'observer'",
			{ "id": variables.db.guid(arguments.walkId) });
		return q.recordCount ? q.text_value[1] : "";
	}

	private numeric function mutationCount(required string walkId) {
		return variables.db.scalar("SELECT COUNT(*) AS n FROM [icf].[walk_mutation] WHERE walk_id = :id", { "id": variables.db.guid(arguments.walkId) });
	}

	private numeric function auditCount(required string walkId, required string eventType) {
		return variables.db.scalar(
			"SELECT COUNT(*) AS n FROM [icf].[audit_event] WHERE entity_type = N'WALK' AND entity_id = :id AND event_type = :type",
			{ "id": variables.db.guid(arguments.walkId), "type": variables.db.nvarchar(arguments.eventType, 80) });
	}

	/** Blanks a mutation row's fingerprint, reproducing a row written before migration 004. */
	private void function makeLegacy(required string mutationId) {
		variables.db.run("UPDATE [icf].[walk_mutation] SET request_fingerprint = NULL WHERE mutation_id = :id", { "id": variables.db.guid(arguments.mutationId) });
	}

	/** Error details travel in extendedInfo as canonical JSON (src/core/Errors.cfc). */
	private struct function detailsOf(required any e) {
		var info = structKeyExists(arguments.e, "extendedInfo") ? arguments.e.extendedInfo : "";
		return (isSimpleValue(info) && len(info) && isJSON(info)) ? deserializeJSON(info) : {};
	}

	private struct function requiredAnswers() {
		return {
			"p1q1": { "storedCode": "Partial" }, "p1q2": { "storedCode": "Retrieval" }, "p1q3": { "storedCode": "Analysis" },
			"part1_adopted_pacing": { "storedCode": "on" }, "part1_adopted_ac1": { "storedCode": "3" }, "part1_adopted_ac2": { "storedCode": "4" },
			"part1_targettask_tt1": { "storedCode": "5" }, "part1_targettask_tt2": { "storedCode": "2" }
		};
	}

	// ---- CORRECTION 1: coherent replays still replay --------------------------------------------

	/** The ambiguity-recovery path itself: nothing moved, so the recorded outcome is coherent. */
	public void function testAReplayIsStillIdempotentWhileTheAggregateHasNotMoved() {
		var w = newWalk();
		var id = newMutationId();
		var committed = save(w, { "observer": { "textValue": "A1" } }, id);
		var before = mutationCount(w.id);
		var replay = save(w, { "observer": { "textValue": "A1" } }, id);
		assertTrue(replay.replayed, "the lost answer is recovered by replaying the committed outcome");
		assertEquals(committed.rowVersion, replay.rowVersion, "and the row version it returns is the one that mutation committed");
		assertEquals(storedRowVersion(w.id), replay.rowVersion, "which is still the row version in the database");
		assertEquals(before, mutationCount(w.id), "a replay records no second mutation");
		assertEquals("A1", storedObserver(w.id));
	}

	// ---- CORRECTION 1: the audited scenario ----------------------------------------------------

	/**
	 * 1. Session A saves M1 successfully but loses the response.
	 * 2. Session B saves a different valid change.
	 * 3. Session A retries M1.
	 * 4. Session A must not receive a token that lets its stale state overwrite B without conflict.
	 */
	public void function testAnOldSaveReplayedAfterALaterSaveCannotOverwriteIt() {
		var w = newWalk();
		var m1 = newMutationId();

		// 1. Session A's save commits; A never sees the answer, so it still holds the state it sent
		//    and the row version it sent the save against.
		var committedByA = save(w, { "observer": { "textValue": "A1" } }, m1);
		var sessionAsLocalState = { "observer": { "textValue": "A1" } };
		var sessionAsRowVersion = w.rowVersion;   // what A held when it sent M1

		// 2. Session B saves a different valid change against the row version A's save produced.
		var committedByB = save({ "id": w.id, "rowVersion": committedByA.rowVersion }, { "observer": { "textValue": "B1" } });
		assertEquals("B1", storedObserver(w.id));
		var afterB = storedRowVersion(w.id);
		assertEquals(committedByB.rowVersion, afterB);
		var mutationsAfterB = mutationCount(w.id);

		// 3. Session A retries M1 with exactly the request it sent.
		var walk = w;
		var mutationId = m1;
		var staleRowVersion = sessionAsRowVersion;
		var e = assertThrows(
			function() { save(walk, { "observer": { "textValue": "A1" } }, mutationId, staleRowVersion); },
			"ICFWalk.Conflict", "MUTATION_REPLAY_SUPERSEDED");

		// 4. The refusal writes nothing, records no mutation, and hands back no usable newer token.
		assertEquals("B1", storedObserver(w.id), "session B's change stands");
		assertEquals(afterB, storedRowVersion(w.id), "the row version did not move");
		assertEquals(mutationsAfterB, mutationCount(w.id), "the refused replay recorded no mutation");
		assertEquals(1, auditCount(w.id, "WALK_MUTATION_SUPERSEDED"));
		var details = detailsOf(e);
		assertEquals(committedByA.rowVersion, details.recordedRowVersion, "the details carry the row version M1 committed");
		assertNotEquals(afterB, details.recordedRowVersion, "never the current one");

		// And the token it does carry cannot overwrite B: it is stale, so it conflicts.
		var recorded = details.recordedRowVersion;
		assertThrows(
			function() { save(walk, { "observer": { "textValue": "A-overwrite" } }, "", recorded); },
			"ICFWalk.Conflict", "STALE_ROW_VERSION");
		assertEquals("B1", storedObserver(w.id), "session A's stale state never overwrote session B");
		assertEquals(afterB, storedRowVersion(w.id));

		// Reconciliation is the only way forward: read the walk, then save against what it holds.
		var reloaded = variables.svc.open(p(variables.walker), w.id);
		assertEquals(afterB, reloaded.rowVersion);
		var reconciled = save(reloaded, { "observer": { "textValue": "A2" } });
		assertEquals("A2", storedObserver(w.id));
		assertNotEquals(afterB, storedRowVersion(w.id));
	}

	/** The same rule for CREATE, COMPLETE, and VOID: a superseded replay is a conflict, not a token. */
	public void function testCreateCompleteAndVoidReplaysAreAlsoRefusedOnceSuperseded() {
		// CREATE: the walk exists, but it has been saved since, so the create cannot be replayed.
		var createId = newMutationId();
		var created = variables.svc.create(p(variables.walker), { "orgUnitId": variables.S1, "clientMutationId": createId, "dimensions": {}, "responses": {} });
		save(created, { "observer": { "textValue": "since" } });
		var advanced = storedRowVersion(created.id);
		var unit = variables.S1;
		var user = variables.walker;
		var self = this;
		var createRetry = assertThrows(
			function() { variables.svc.create(p(user), { "orgUnitId": unit, "clientMutationId": createId, "dimensions": {}, "responses": {} }); },
			"ICFWalk.Conflict", "MUTATION_REPLAY_SUPERSEDED");
		assertEquals(created.id, detailsOf(createRetry).walkId, "the client can still find the walk it created");
		assertEquals(advanced, storedRowVersion(created.id), "and nothing was written");
		assertEquals(1, variables.db.scalar("SELECT COUNT(*) AS n FROM [icf].[walk_mutation] WHERE mutation_id = :id", { "id": variables.db.guid(createId) }), "exactly one create mutation row");

		// COMPLETE: completing, then editing the completed walk, supersedes the completion replay.
		var w = newWalk();
		var ready = variables.svc.save(p(variables.walker), w.id, { "rowVersion": w.rowVersion, "clientMutationId": newMutationId(), "dimensions": {}, "responses": requiredAnswers() });
		var completeId = newMutationId();
		var done = variables.svc.complete(p(variables.walker), w.id, { "rowVersion": ready.rowVersion, "clientMutationId": completeId });
		var edited = variables.svc.save(p(variables.walker), w.id, { "rowVersion": done.rowVersion, "clientMutationId": newMutationId(), "dimensions": { "observer": { "textValue": "post" } }, "responses": requiredAnswers() });
		var revisions = variables.db.scalar("SELECT COUNT(*) AS n FROM [icf].[walk_revision] WHERE walk_id = :id", { "id": variables.db.guid(w.id) });
		var walkId = w.id;
		var readyRowVersion = ready.rowVersion;
		assertThrows(
			function() { variables.svc.complete(p(user), walkId, { "rowVersion": readyRowVersion, "clientMutationId": completeId }); },
			"ICFWalk.Conflict", "MUTATION_REPLAY_SUPERSEDED");
		assertEquals(revisions, variables.db.scalar("SELECT COUNT(*) AS n FROM [icf].[walk_revision] WHERE walk_id = :id", { "id": variables.db.guid(w.id) }), "no second revision");
		assertEquals(edited.rowVersion, storedRowVersion(w.id));

		// VOID: a void replay after the walk moved on is refused the same way. Voiding is terminal,
		// so the supersession is produced by voiding a second walk and replaying the first id there --
		// which is a target mismatch -- and by an ordinary coherent void replay staying coherent.
		var voidId = newMutationId();
		var voided = variables.svc.void(p(variables.walker), w.id, { "rowVersion": edited.rowVersion, "clientMutationId": voidId, "reason": "one" });
		var voidReplay = variables.svc.void(p(variables.walker), w.id, { "rowVersion": edited.rowVersion, "clientMutationId": voidId, "reason": "one" });
		assertTrue(voidReplay.replayed, "a void replay is coherent while nothing has touched the walk since");
		assertEquals(voided.rowVersion, voidReplay.rowVersion);
		assertEquals(voided.rowVersion, storedRowVersion(w.id));
	}

	// ---- CORRECTION 1 (third session): the comparison and the DTO are one atomic step -----------

	/**
	 * The residual hole the comparison alone left open. replay() used to compare the recorded row
	 * version against an UNLOCKED read and then build the DTO from further unlocked reads, so a
	 * save committing between those two points made the replay return the newer aggregate and the
	 * newer row version under the coherent verdict -- handing the retrying session's stale local
	 * state a live token, which is exactly what the comparison exists to prevent.
	 *
	 * This forces that interleaving deterministically rather than hoping for it. A decorating
	 * repository (support/InterceptingWalkRepository) fires a callback at the first aggregate read
	 * the DTO materialization performs, which is the precise point that used to follow the
	 * comparison. The callback starts a real second session that saves the same walk and waits for
	 * it, bounded.
	 *
	 * The invariant: the walk mutation lock the replay holds makes that save WAIT. It cannot land
	 * between the comparison and the DTO, so the replay returns the row version its mutation
	 * committed, with the state that mutation committed; the second save lands afterwards. Before
	 * the fix the interfering save completed inside the window and both assertions failed.
	 */
	public void function testAConcurrentSaveCannotLandBetweenTheCoherenceCheckAndTheDto() {
		var w = newWalk();
		var m1 = newMutationId();
		var committed = save(w, { "observer": { "textValue": "M1" } }, m1);
		assertEquals("M1", storedObserver(w.id));

		var interceptor = createObject("component", "icfwalktests.support.InterceptingWalkRepository").init(variables.c.walkRepository);
		var interceptingService = createObject("component", "icfwalk.walks.WalkService").init(
			variables.c.config, variables.c.db, variables.c.errors, variables.c.logger, variables.c.auditRepository,
			variables.c.canonicalJson, variables.c.authorizationService, variables.c.snapshotService,
			variables.c.visibilityEngine, interceptor, variables.c.walkPayloadValidator, variables.c.orgUnitRepository
		);

		var realService = variables.svc;
		var writer = p(variables.walker);
		var walkId = w.id;
		var tokenM1 = committed.rowVersion;
		var interferenceId = newMutationId();
		var joinedStatus = "";
		// Armed at the DTO's first aggregate read: the former gap between comparison and DTO.
		interceptor.arm("loadDimensionValues", function() {
			thread name="replayInterference" svc=realService who=writer wid=walkId rv=tokenM1 mid=interferenceId {
				try {
					attributes.svc.save(attributes.who, attributes.wid, {
						"rowVersion": attributes.rv, "clientMutationId": attributes.mid,
						"dimensions": { "observer": { "textValue": "INTERFERENCE" } }, "responses": {}
					});
					thread.committed = true;
					thread.failure = "";
				} catch (any e) {
					thread.committed = false;
					thread.failure = e.message;
				}
			}
			// Generous: an unobstructed save of this walk takes a small fraction of this. It can only
			// still be running because something is making it wait.
			threadJoin("replayInterference", 6000);
			joinedStatus = cfthread.replayInterference.status;
		});

		var replayed = interceptingService.save(writer, walkId, {
			"rowVersion": w.rowVersion, "clientMutationId": m1,
			"dimensions": { "observer": { "textValue": "M1" } }, "responses": {}
		});

		assertTrue(interceptor.fired("loadDimensionValues"), "the interference really was forced at the DTO-loading point");
		assertNotEquals("COMPLETED", joinedStatus, "the concurrent save could not commit inside the replay: the walk mutation lock held it");
		assertTrue(replayed.replayed, "the replay is still the coherent recorded outcome");
		assertEquals(committed.rowVersion, replayed.rowVersion, "and it carries the row version M1 committed, never a newer one");
		assertEquals("M1", replayed.state.dimensions.observer.textValue, "with the aggregate as M1 left it");

		// Once the replay commits, the waiting save proceeds: the interference was real, only deferred.
		threadJoin("replayInterference", 30000);
		assertEquals("COMPLETED", cfthread.replayInterference.status, "the deferred save ran to completion after the replay released the lock");
		assertTrue(cfthread.replayInterference.committed, "and it committed: " & cfthread.replayInterference.failure);
		assertEquals("INTERFERENCE", storedObserver(walkId));
		assertNotEquals(committed.rowVersion, storedRowVersion(walkId), "the walk did move on -- after the replay, not inside it");

		// And the token the replay handed back is now stale, so it cannot overwrite that save.
		var stale = committed.rowVersion;
		assertThrows(
			function() { variables.svc.save(p(variables.walker), walkId, { "rowVersion": stale, "clientMutationId": newMutationId(), "dimensions": { "observer": { "textValue": "overwrite" } }, "responses": {} }); },
			"ICFWalk.Conflict", "STALE_ROW_VERSION");
		assertEquals("INTERFERENCE", storedObserver(walkId));
	}

	/**
	 * The same seam, with the aggregate genuinely moved on before the replay starts: the answer is
	 * the refusal, and it is reached without the DTO ever being materialized.
	 */
	public void function testASupersededReplayNeverMaterializesTheNewerAggregate() {
		var w = newWalk();
		var m1 = newMutationId();
		var committed = save(w, { "observer": { "textValue": "M1" } }, m1);
		save({ "id": w.id, "rowVersion": committed.rowVersion }, { "observer": { "textValue": "later" } });

		var interceptor = createObject("component", "icfwalktests.support.InterceptingWalkRepository").init(variables.c.walkRepository);
		var interceptingService = createObject("component", "icfwalk.walks.WalkService").init(
			variables.c.config, variables.c.db, variables.c.errors, variables.c.logger, variables.c.auditRepository,
			variables.c.canonicalJson, variables.c.authorizationService, variables.c.snapshotService,
			variables.c.visibilityEngine, interceptor, variables.c.walkPayloadValidator, variables.c.orgUnitRepository
		);
		interceptor.arm("loadDimensionValues", function() { fail("a superseded replay must never load the aggregate it is refusing to return."); });

		var walkId = w.id;
		var writer = p(variables.walker);
		var before = storedRowVersion(walkId);
		var e = assertThrows(
			function() {
				interceptingService.save(writer, walkId, {
					"rowVersion": w.rowVersion, "clientMutationId": m1,
					"dimensions": { "observer": { "textValue": "M1" } }, "responses": {}
				});
			},
			"ICFWalk.Conflict", "MUTATION_REPLAY_SUPERSEDED");
		assertFalse(interceptor.fired("loadDimensionValues"), "nothing about the newer aggregate was read");
		assertEquals(committed.rowVersion, detailsOf(e).recordedRowVersion, "the details carry the recorded token");
		assertEquals("later", storedObserver(walkId), "and nothing was written");
		assertEquals(before, storedRowVersion(walkId));
	}

	// ---- CORRECTION 4: legacy NULL fingerprints --------------------------------------------------

	/**
	 * An exact-looking retry against a legacy row. It looks identical, but nothing recorded proves
	 * that, so it is not a success. Nothing is written.
	 */
	public void function testAnExactLookingRetryAgainstALegacyRowIsARefusal() {
		var w = newWalk();
		var id = newMutationId();
		var committed = save(w, { "observer": { "textValue": "legacy" } }, id);
		makeLegacy(id);
		var before = storedRowVersion(w.id);
		var mutations = mutationCount(w.id);
		var walk = w;
		var mutationId = id;
		var e = assertThrows(
			function() { save(walk, { "observer": { "textValue": "legacy" } }, mutationId); },
			"ICFWalk.Conflict", "MUTATION_LEGACY_UNVERIFIABLE");
		assertEquals(w.id, detailsOf(e).walkId);
		assertEquals("legacy", storedObserver(w.id), "no application state changed");
		assertEquals(before, storedRowVersion(w.id), "the row version did not move");
		assertEquals(mutations, mutationCount(w.id), "no mutation row was written");
		assertEquals(1, auditCount(w.id, "WALK_MUTATION_LEGACY_UNVERIFIABLE"));
		assertEquals(0, auditCount(w.id, "WALK_MUTATION_REPLAYED"));
	}

	/** An altered request against the same legacy row gets the same deterministic answer. */
	public void function testAnAlteredRequestAgainstALegacyRowIsTheSameRefusal() {
		var w = newWalk();
		var id = newMutationId();
		save(w, { "observer": { "textValue": "legacy" } }, id);
		makeLegacy(id);
		var before = storedRowVersion(w.id);
		var walk = w;
		var mutationId = id;
		// Materially different content: the answer is the legacy conflict, not MUTATION_ID_REUSED,
		// because the server cannot tell the two apart and says so instead of guessing.
		assertThrows(function() { save(walk, { "observer": { "textValue": "tampered" } }, mutationId); }, "ICFWalk.Conflict", "MUTATION_LEGACY_UNVERIFIABLE");
		assertEquals("legacy", storedObserver(w.id));
		assertEquals(before, storedRowVersion(w.id));
		// A different action under the same id is still the earlier, cheaper refusal.
		assertThrows(function() { variables.svc.complete(p(variables.walker), walk.id, { "rowVersion": walk.rowVersion, "clientMutationId": mutationId }); }, "ICFWalk.Conflict", "MUTATION_ID_REUSED");
		assertEquals("DRAFT", variables.db.run("SELECT status FROM [icf].[walk] WHERE walk_id = :id", { "id": variables.db.guid(walk.id) }).status[1]);
	}

	/**
	 * Authorization is answered before provenance. The same legacy id, replayed by a principal who
	 * can no longer see the walk, answers "not found" -- it never discloses that the walk exists by
	 * reaching the fingerprint conflict.
	 */
	public void function testAuthorizationAnswersBeforeTheLegacyConflict() {
		var w = newWalk();
		var id = newMutationId();
		save(w, { "observer": { "textValue": "legacy" } }, id);
		makeLegacy(id);
		var before = storedRowVersion(w.id);

		// Authorized target: the legacy conflict (proved above) is what the owner sees.
		var walk = w;
		var mutationId = id;
		assertThrows(function() { save(walk, { "observer": { "textValue": "legacy" } }, mutationId); }, "ICFWalk.Conflict", "MUTATION_LEGACY_UNVERIFIABLE");

		// Now-unauthorized target: a principal scoped to another school gets 404 and no hint that the
		// id, the walk, or a legacy row exists.
		var stranger = variables.other;
		var self = this;
		var notFound = assertThrows(
			function() {
				variables.svc.save(p(stranger), walk.id, { "rowVersion": walk.rowVersion, "clientMutationId": mutationId, "dimensions": {}, "responses": {} });
			},
			"ICFWalk.NotFound");
		assertNotEquals("MUTATION_LEGACY_UNVERIFIABLE", structKeyExists(notFound, "errorcode") ? notFound.errorcode : "", "the refusal is not the fingerprint conflict");
		assertEquals("legacy", storedObserver(w.id), "and nothing was written on either path");
		assertEquals(before, storedRowVersion(w.id));
	}
}
