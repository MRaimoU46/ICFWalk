/**
 * Fifth Phase 0-4 correction session: a successful mutation's response must describe the state that
 * mutation produced.
 *
 * THE DEFECT. save() and complete() locked the walk, applied the mutation, recorded the resulting
 * rowversion and committed -- and only then called loadDto() to build the response, with the
 * transaction over and the walk mutation lock released. That leaves a window with no lock in it:
 *
 *   1. Session A saves M1 against R0.
 *   2. A commits M1 and produces R1.
 *   3. Before A builds its response, session B saves M2 against R1 and commits R2.
 *   4. A's loadDto() returns B's aggregate and R2.
 *   5. The browser adopts the returned metadata but keeps its own editor state
 *      (app/assets/js/app.js::saveCurrent), so A still holds the state it sent as M1.
 *   6. A now holds stale local state paired with the live R2 token, and its next whole-state save
 *      overwrites B without ever being told STALE_ROW_VERSION.
 *
 * THE INVARIANT PROVED HERE. The rowversion, header, dimensions, responses, evaluation states and
 * revision count in a successful SAVE or COMPLETE response all describe one serialized database
 * state: the one that mutation produced. Equivalently: no other SAVE, COMPLETE or VOID can commit
 * between a mutation and the construction of the DTO it returns.
 *
 * HOW THE INTERLEAVING IS FORCED. Deterministically, never by sleeping or racing:
 *
 *   - support/InterceptingDb decorates Db.transact and runs a callback at the exact instant the
 *     mutation's transaction commits and before the service method resumes. The callback is a real
 *     second session committing a real second mutation through the real service against the real
 *     database. A response built inside the transaction is already complete when it runs; a
 *     response built afterwards sees it. That is step 3 above, on demand.
 *   - support/InterceptingWalkRepository fires at countRevisions, which only response
 *     materialization reaches, and starts a real concurrent writer there. Under the correction that
 *     writer is still holding the lock's door handle when the bounded join expires, which is what
 *     "the response is built under the lock" means operationally.
 *
 * Every assertion is against database state, recorded mutation rows and rowversions rather than the
 * service's own say-so. Fixtures are synthetic and removed in afterAll. The replay path
 * (WalkReplayCoherenceTest) is a different code path and does not cover any of this.
 */
component extends="icfwalktests.BaseSpec" output="false" {

	public string function skipReason() {
		if (!schemaPresent()) return "icf schema is not present.";
		if (structIsEmpty(variables.c.snapshotService.currentVersion())) return "no renderable instrument version is seeded.";
		return "";
	}

	public void function beforeAll() {
		variables.fx = createObject("component", "icfwalktests.support.Fixtures").init(variables.c, "mutresp-" & lCase(left(replace(createUUID(), "-", "", "all"), 8)));
		variables.svc = variables.c.walkService;
		variables.db = variables.c.db;
		variables.D = variables.fx.orgUnit("d", "DISTRICT");
		variables.S1 = variables.fx.orgUnit("s1", "SCHOOL", variables.D);
		// One person, two sessions: the walk is owner-scoped, so "A" and "B" are the same principal
		// holding two different local states, exactly as two browser tabs do.
		variables.walker = variables.fx.user("walker");
		variables.fx.assign(variables.walker.userId, "SCHOOL_WALK_REPORT", variables.S1, false);
	}

	public void function afterAll() {
		variables.fx.remove();
	}

	// ---- helpers -------------------------------------------------------------------------------

	private struct function p(required struct user) { return variables.fx.principal(arguments.user.userId); }
	private string function newMutationId() { return variables.db.newGuid(); }

	private struct function newWalk() {
		return variables.svc.create(p(variables.walker), { "orgUnitId": variables.S1, "clientMutationId": newMutationId() });
	}

	/** A WalkService whose transaction boundary a spec can stand on. Everything else is the real thing. */
	private struct function lab() {
		var db = createObject("component", "icfwalktests.support.InterceptingDb").init(variables.c.db);
		return { "db": db, "svc": serviceWith(db, variables.c.walkRepository) };
	}

	private any function serviceWith(required any db, required any walkRepository) {
		return createObject("component", "icfwalk.walks.WalkService").init(
			variables.c.config, arguments.db, variables.c.errors, variables.c.logger, variables.c.auditRepository,
			variables.c.canonicalJson, variables.c.authorizationService, variables.c.snapshotService,
			variables.c.visibilityEngine, arguments.walkRepository, variables.c.walkPayloadValidator, variables.c.orgUnitRepository
		);
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

	private string function storedStatus(required string walkId) {
		return variables.db.run("SELECT status FROM [icf].[walk] WHERE walk_id = :id", { "id": variables.db.guid(arguments.walkId) }).status[1];
	}

	private numeric function revisionCount(required string walkId) {
		return variables.db.scalar("SELECT COUNT(*) AS n FROM [icf].[walk_revision] WHERE walk_id = :id", { "id": variables.db.guid(arguments.walkId) });
	}

	/** The rowversion the mutation itself recorded, read back out of icf.walk_mutation. */
	private string function recordedRowVersion(required string mutationId) {
		var q = variables.db.run("SELECT result_json FROM [icf].[walk_mutation] WHERE mutation_id = :id", { "id": variables.db.guid(arguments.mutationId) });
		if (!q.recordCount || !isJSON(q.result_json[1])) return "";
		var recorded = deserializeJSON(q.result_json[1]);
		return structKeyExists(recorded, "rowVersion") ? recorded.rowVersion : "";
	}

	private struct function requiredAnswers() {
		return {
			"p1q1": { "storedCode": "Partial" }, "p1q2": { "storedCode": "Retrieval" }, "p1q3": { "storedCode": "Analysis" },
			"part1_adopted_pacing": { "storedCode": "on" }, "part1_adopted_ac1": { "storedCode": "3" }, "part1_adopted_ac2": { "storedCode": "4" },
			"part1_targettask_tt1": { "storedCode": "5" }, "part1_targettask_tt2": { "storedCode": "2" }
		};
	}

	// ---- the audited SAVE scenario, forced deterministically ------------------------------------

	/**
	 * The reported defect, end to end. Session B commits R2 at the exact instant A's transaction
	 * hands back, and A must still answer with M1/R1.
	 *
	 * Against the uncorrected code A answered with B's observer value and R2: assertions 4 and 5
	 * below both failed, and the "stale token cannot overwrite" assertion failed too, because the
	 * token A was handed was not stale at all -- it was B's live one.
	 */
	public void function testASaveAnsweredWithItsOwnStateWhenAnotherSessionCommitsAtTheCommitBoundary() {
		// 1. Session A begins with R0 and saves M1.
		var w = newWalk();
		var r0 = w.rowVersion;
		var m1 = newMutationId();

		var harness = lab();
		var realSvc = variables.svc;
		var writer = p(variables.walker);
		var walkId = w.id;
		var b = { "r1": "", "result": {} };

		// 3. At the post-transaction boundary -- the precise point save() used to go and read the
		//    walk again -- session B saves M2 against R1 and commits R2.
		harness.db.armAfterCommit(function() {
			b.r1 = storedRowVersion(walkId);
			b.result = realSvc.save(writer, walkId, {
				"rowVersion": b.r1, "clientMutationId": newMutationId(),
				"dimensions": { "observer": { "textValue": "B-M2" } }, "responses": {}
			});
		});

		var a = harness.svc.save(writer, walkId, {
			"rowVersion": r0, "clientMutationId": m1,
			"dimensions": { "observer": { "textValue": "A-M1" } }, "responses": {}
		});

		assertTrue(harness.db.firedAfterCommit(), "session B really did commit at A's post-transaction boundary");
		// 2. A's transaction produced R1, and B's produced a different R2 on top of it.
		var r1 = b.r1;
		var r2 = b.result.rowVersion;
		assertNotEquals(r0, r1, "A's mutation moved the walk off R0");
		assertNotEquals(r1, r2, "and B's commit moved it on again, so the interleaving was real");

		// 4. A nevertheless returns the DTO captured for M1/R1, not B's state or R2.
		assertEquals(r1, a.rowVersion, "A's response carries the rowversion its own mutation produced");
		assertEquals(recordedRowVersion(m1), a.rowVersion, "which is exactly the rowversion M1 recorded");
		assertEquals("A-M1", a.state.dimensions.observer.textValue, "and A's aggregate, never B's");
		assertEquals("DRAFT", a.status);

		// 5. The database ends with B's M2/R2.
		assertEquals("B-M2", storedObserver(walkId));
		assertEquals(r2, storedRowVersion(walkId));

		// 6. A subsequent attempted overwrite using the returned R1 fails with 409 STALE_ROW_VERSION.
		var token = a.rowVersion;
		var conflict = assertThrows(
			function() {
				realSvc.save(writer, walkId, {
					"rowVersion": token, "clientMutationId": newMutationId(),
					"dimensions": { "observer": { "textValue": "A-OVERWRITE" } }, "responses": {}
				});
			},
			"ICFWalk.Conflict", "STALE_ROW_VERSION");
		assertEquals(409, variables.c.errors.statusFor(conflict.type), "which is the 409 the contract names");

		// 7. B's data remains unchanged after that conflict.
		assertEquals("B-M2", storedObserver(walkId), "session A's stale state never overwrote session B");
		assertEquals(r2, storedRowVersion(walkId));
	}

	// ---- the same scenario for COMPLETE ---------------------------------------------------------

	/**
	 * COMPLETE had the identical post-transaction materialization, and it leaks more: status,
	 * completedAt and the revision count are part of the response too. Here B's post-completion edit
	 * commits at the boundary and adds its own revision; the completion must still answer with the
	 * rowversion, aggregate and revision count that completion produced.
	 */
	public void function testACompleteAnsweredWithItsOwnStateWhenAnotherSessionCommitsAtTheCommitBoundary() {
		var w = newWalk();
		var ready = variables.svc.save(p(variables.walker), w.id, {
			"rowVersion": w.rowVersion, "clientMutationId": newMutationId(),
			"dimensions": { "observer": { "textValue": "A-BEFORE" } }, "responses": requiredAnswers()
		});

		var harness = lab();
		var realSvc = variables.svc;
		var writer = p(variables.walker);
		var walkId = w.id;
		var completeId = newMutationId();
		var b = { "r1": "", "revisions": 0, "result": {} };

		harness.db.armAfterCommit(function() {
			b.r1 = storedRowVersion(walkId);
			b.revisions = revisionCount(walkId);
			b.result = realSvc.save(writer, walkId, {
				"rowVersion": b.r1, "clientMutationId": newMutationId(),
				"dimensions": { "observer": { "textValue": "B-AFTER" } }, "responses": requiredAnswers()
			});
		});

		var a = harness.svc.complete(writer, walkId, { "rowVersion": ready.rowVersion, "clientMutationId": completeId });

		assertTrue(harness.db.firedAfterCommit(), "the post-completion edit really did commit at the boundary");
		assertNotEquals(b.r1, b.result.rowVersion, "and it moved the walk on, so the interleaving was real");

		assertEquals(b.r1, a.rowVersion, "COMPLETE answers with the rowversion the completion produced");
		assertEquals(recordedRowVersion(completeId), a.rowVersion, "exactly the one that mutation recorded");
		assertEquals("COMPLETED", a.status);
		assertEquals("A-BEFORE", a.state.dimensions.observer.textValue, "with the aggregate completion froze");
		assertEquals(b.revisions, a.revisionCount, "and the revision count as of that completion");

		// The database moved on, B's revision is there, and the completion's token cannot overwrite it.
		assertEquals("B-AFTER", storedObserver(walkId));
		assertEquals(b.result.rowVersion, storedRowVersion(walkId));
		assertEquals(b.revisions + 1, revisionCount(walkId), "B's post-completion edit added its own revision");
		var token = a.rowVersion;
		assertThrows(
			function() {
				realSvc.save(writer, walkId, {
					"rowVersion": token, "clientMutationId": newMutationId(),
					"dimensions": { "observer": { "textValue": "A-OVERWRITE" } }, "responses": requiredAnswers()
				});
			},
			"ICFWalk.Conflict", "STALE_ROW_VERSION");
		assertEquals("B-AFTER", storedObserver(walkId), "the completion's stale token never overwrote B");
	}

	// ---- the successful no-op SAVE on an already completed walk ---------------------------------

	/**
	 * A save that changes nothing on a COMPLETED walk is still a successful SAVE with a response, and
	 * it has its own branch: it writes no revision and does not move the rowversion, and it recorded
	 * and returned one before the correction from outside the transaction just like the others.
	 * "Nothing changed" is a claim about a specific serialized state, so it has to be that state.
	 */
	public void function testANoopSaveOnACompletedWalkIsAlsoCoherent() {
		var w = newWalk();
		var ready = variables.svc.save(p(variables.walker), w.id, {
			"rowVersion": w.rowVersion, "clientMutationId": newMutationId(),
			"dimensions": { "observer": { "textValue": "A-BEFORE" } }, "responses": requiredAnswers()
		});
		var done = variables.svc.complete(p(variables.walker), w.id, { "rowVersion": ready.rowVersion, "clientMutationId": newMutationId() });

		var harness = lab();
		var realSvc = variables.svc;
		var writer = p(variables.walker);
		var walkId = w.id;
		var noopId = newMutationId();
		var b = { "r1": "", "result": {} };

		harness.db.armAfterCommit(function() {
			b.r1 = storedRowVersion(walkId);
			b.result = realSvc.save(writer, walkId, {
				"rowVersion": b.r1, "clientMutationId": newMutationId(),
				"dimensions": { "observer": { "textValue": "B-AFTER" } }, "responses": requiredAnswers()
			});
		});

		// Byte-for-byte the state already stored: no ops, no revision, no new rowversion.
		var a = harness.svc.save(writer, walkId, {
			"rowVersion": done.rowVersion, "clientMutationId": noopId,
			"dimensions": { "observer": { "textValue": "A-BEFORE" } }, "responses": requiredAnswers()
		});

		assertTrue(harness.db.firedAfterCommit(), "B really did commit at the boundary");
		assertEquals(done.rowVersion, b.r1, "the no-op really was a no-op: it did not move the rowversion");
		assertEquals(done.rowVersion, a.rowVersion, "so the response carries the rowversion it did not move");
		assertEquals(recordedRowVersion(noopId), a.rowVersion, "which is the one the no-op mutation recorded");
		assertEquals("A-BEFORE", a.state.dimensions.observer.textValue, "and the state it observed, not B's");
		assertEquals("COMPLETED", a.status);
		assertEquals("B-AFTER", storedObserver(walkId), "while the database moved on to B");
		assertNotEquals(a.rowVersion, storedRowVersion(walkId));
	}

	// ---- the shared invariant, stated once and exercised for both operations --------------------

	/**
	 * The same contract for SAVE and COMPLETE, driven from one table so neither can drift from it:
	 * a successful mutation's response describes the serialized state that mutation produced, and a
	 * commit landing the instant the transaction ends changes nothing about it.
	 */
	public void function testTheResponseCoherenceInvariantHoldsForBothSaveAndComplete() {
		for (var operation in ["SAVE", "COMPLETE"]) {
			var w = newWalk();
			var ready = variables.svc.save(p(variables.walker), w.id, {
				"rowVersion": w.rowVersion, "clientMutationId": newMutationId(),
				"dimensions": { "observer": { "textValue": "OWN-" & operation } }, "responses": requiredAnswers()
			});

			var harness = lab();
			var realSvc = variables.svc;
			var writer = p(variables.walker);
			var walkId = w.id;
			var mutationId = newMutationId();
			var b = { "r1": "", "result": {} };
			harness.db.armAfterCommit(function() {
				b.r1 = storedRowVersion(walkId);
				b.result = realSvc.save(writer, walkId, {
					"rowVersion": b.r1, "clientMutationId": newMutationId(),
					"dimensions": { "observer": { "textValue": "OTHER-" & operation } }, "responses": requiredAnswers()
				});
			});

			var dto = operation == "SAVE"
				? harness.svc.save(writer, walkId, {
					"rowVersion": ready.rowVersion, "clientMutationId": mutationId,
					"dimensions": { "observer": { "textValue": "OWN-" & operation & "-EDIT" } }, "responses": requiredAnswers() })
				: harness.svc.complete(writer, walkId, { "rowVersion": ready.rowVersion, "clientMutationId": mutationId });

			var expectedObserver = operation == "SAVE" ? "OWN-" & operation & "-EDIT" : "OWN-" & operation;
			assertTrue(harness.db.firedAfterCommit(), operation & ": the competing commit was forced at the boundary");
			assertEquals(b.r1, dto.rowVersion, operation & ": the response carries the rowversion its own mutation produced");
			assertEquals(recordedRowVersion(mutationId), dto.rowVersion, operation & ": which is the rowversion the mutation recorded");
			assertEquals(expectedObserver, dto.state.dimensions.observer.textValue, operation & ": with its own aggregate");
			assertNotEquals(dto.rowVersion, storedRowVersion(walkId), operation & ": while the database has since moved on");
			assertEquals("OTHER-" & operation, storedObserver(walkId), operation & ": to the competing session's state");
			assertEquals(b.result.rowVersion, storedRowVersion(walkId));

			var token = dto.rowVersion;
			assertThrows(
				function() {
					realSvc.save(writer, walkId, {
						"rowVersion": token, "clientMutationId": newMutationId(),
						"dimensions": { "observer": { "textValue": "OVERWRITE" } }, "responses": requiredAnswers() });
				},
				"ICFWalk.Conflict", "STALE_ROW_VERSION");
			assertEquals("OTHER-" & operation, storedObserver(walkId), operation & ": the returned token could not overwrite the newer work");
		}
	}

	// ---- the response is built under the lock, not merely before the next statement --------------

	/**
	 * The stronger form of the invariant, and the one that fails again if response materialization
	 * ever moves back outside the lock: a real concurrent writer, started at the point the response
	 * is being built, cannot commit there at all.
	 *
	 * The seam is countRevisions, which only response materialization reaches. The writer is a real
	 * thread running the real service against the real database; under the correction it is still
	 * blocked on the walk mutation lock when the bounded join expires, and it runs to completion --
	 * and straight into the STALE_ROW_VERSION its now-old token has earned -- once the mutation
	 * releases the lock. Against the uncorrected code countRevisions ran after the commit, so the
	 * writer was never blocked and had finished by the join.
	 */
	public void function testNoConcurrentWriterCanCommitWhileTheResponseIsBeingBuilt() {
		var w = newWalk();
		var m1 = newMutationId();
		var interceptor = createObject("component", "icfwalktests.support.InterceptingWalkRepository").init(variables.c.walkRepository);
		var svc = serviceWith(variables.c.db, interceptor);

		var realSvc = variables.svc;
		var writer = p(variables.walker);
		var walkId = w.id;
		// Deliberately the pre-save token: whenever the writer does get through, A's mutation has
		// moved the rowversion on, so its outcome names the lock's effect rather than a race.
		var staleToken = w.rowVersion;
		var interferenceId = newMutationId();
		var observed = { "status": "" };

		interceptor.arm("countRevisions", function() {
			thread name="mutationResponseInterference" svc=realSvc who=writer wid=walkId rv=staleToken mid=interferenceId {
				try {
					attributes.svc.save(attributes.who, attributes.wid, {
						"rowVersion": attributes.rv, "clientMutationId": attributes.mid,
						"dimensions": { "observer": { "textValue": "INTERFERENCE" } }, "responses": {}
					});
					thread.outcome = "committed";
				} catch (any e) {
					thread.outcome = structKeyExists(e, "errorcode") ? e.errorcode : e.type;
				}
			}
			// Generous: an unobstructed save of this walk takes a small fraction of this, so still
			// running can only mean something is making it wait.
			threadJoin("mutationResponseInterference", 6000);
			observed.status = cfthread.mutationResponseInterference.status;
		});

		try {
			var a = svc.save(writer, walkId, {
				"rowVersion": w.rowVersion, "clientMutationId": m1,
				"dimensions": { "observer": { "textValue": "A-M1" } }, "responses": {}
			});

			assertTrue(interceptor.fired("countRevisions"), "the writer really was started while the response was being built");
			assertNotEquals("COMPLETED", observed.status, "it could not commit there: the walk mutation lock held it");
			assertEquals(recordedRowVersion(m1), a.rowVersion, "so the response is the mutation's own rowversion");
			assertEquals("A-M1", a.state.dimensions.observer.textValue, "and the mutation's own aggregate");
		} finally {
			// Bounded, and unconditional: a failed assertion above must not strand the thread.
			if (structKeyExists(cfthread, "mutationResponseInterference")) threadJoin("mutationResponseInterference", 30000);
		}

		assertEquals("COMPLETED", cfthread.mutationResponseInterference.status, "the deferred writer ran once the lock was released");
		assertEquals("STALE_ROW_VERSION", cfthread.mutationResponseInterference.outcome, "and by then its token was stale, so it conflicted");
		assertEquals("A-M1", storedObserver(walkId), "nothing overwrote the state the mutation committed");
		assertEquals("DRAFT", storedStatus(walkId));
	}
}
