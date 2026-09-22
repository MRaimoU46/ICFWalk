/**
 * Phase 5 correction: a summary export describes one committed state of the walk, never a mixture.
 *
 * THE DEFECT. summary() authorized the read and then performed four unlocked reads in sequence --
 * the walk header, the dimension values, the responses, and the pinned render model -- with nothing
 * serializing them against the mutation paths. SAVE, COMPLETE and VOID each open a transaction and
 * take the walk mutation lock as their first act (WalkRepository.findWalk(id, true), which is
 * SELECT ... WITH (UPDLOCK, ROWLOCK)); the export took part in none of that. A mutation could
 * therefore commit between the export's dimension read and its response read, and the file would
 * carry one committed state's dimensions beside another's responses.
 *
 * That is not merely stale, it is unreal: no version of the walk ever held that combination. And
 * because the dimensions are what the visibility engine evaluates, the older dimensions can show a
 * section the committed dimensions hide, so the export prints a retained answer that the walk's
 * actual state excludes -- exactly what SUM-01 (the file describes the walk) and SUM-04 (hidden
 * values are retained but never exported) forbid.
 *
 * THE INVARIANT PROVED HERE. The text, the file name, every visibility decision, the status and the
 * version metadata of one export all describe one serialized database state. Equivalently: no SAVE,
 * COMPLETE or VOID can commit between the beginning and the end of a summary materialization.
 *
 * WHY ONE CONCURRENT SAVE IS ENOUGH. The serialization is not a property of SAVE; it is a property
 * of the one row lock. Every mutation path in WalkService opens variables.db.transact(...) and
 * takes findWalk(id, true) before it reads or writes anything else, so all of them queue on the
 * same walk row. An export that holds that row blocks SAVE, COMPLETE and VOID alike, and an export
 * that wants it waits for whichever of them holds it. testEveryMutationPathTakesTheSameWalkLock
 * below asserts that shared structure directly against the source, so the scenario proved for SAVE
 * is proved for the others by the lock they share rather than by assertion about SAVE alone.
 *
 * HOW THE INTERLEAVING IS FORCED. Deterministically, never by sleeping or racing.
 * support/InterceptingWalkRepository fires at loadResponses, and it fires before delegating, so the
 * callback runs at the seam *between* the export's two child reads: the dimensions are already in
 * hand and the responses have not been read yet. A real second session, running a real SAVE through
 * the real service against the real database, is started exactly there. If it can commit, the
 * aggregate the export goes on to assemble is state A's dimensions beside state B's responses --
 * the mixed state itself, not merely a newer one.
 *
 * The seam matters, and an earlier version of this spec had it wrong: it armed loadDimensionValues,
 * which also fires before delegating and therefore put the writer *ahead of both* child reads.
 * Against the unlocked implementation a writer there can commit before either read, and the export
 * then sees state B coherently. That still detects the missing lock, but it does not reproduce the
 * mixed read the defect is about. loadResponses is the boundary the comments always described.
 *
 * Under the correction the writer is still blocked on the walk mutation lock when the bounded join
 * expires, whichever seam it is started from.
 *
 * Fixtures are synthetic and removed in afterAll.
 */
component extends="icfwalktests.BaseSpec" output="false" {

	public string function skipReason() {
		if (!schemaPresent()) return "icf schema is not present.";
		if (structIsEmpty(variables.c.snapshotService.currentVersion())) return "no renderable instrument version is seeded.";
		return "";
	}

	public void function beforeAll() {
		variables.fx = createObject("component", "icfwalktests.support.Fixtures").init(variables.c, "sumcoh-" & lCase(left(replace(createUUID(), "-", "", "all"), 8)));
		variables.svc = variables.c.walkService;
		variables.db = variables.c.db;
		variables.D = variables.fx.orgUnit("d", "DISTRICT");
		// Unmapped on purpose: the School dimension stays empty and the Grade options stay unfiltered,
		// so grade and classType below are free to be whatever the scenario needs.
		variables.S1 = variables.fx.orgUnit("s1", "SCHOOL", variables.D);
		variables.walker = variables.fx.user("walker");
		variables.fx.assign(variables.walker.userId, "SCHOOL_WALK_REPORT", variables.S1, false);
	}

	public void function afterAll() {
		variables.fx.remove();
	}

	// ---- the two states ------------------------------------------------------------------------
	//
	// A and B differ in all three things an export is built from, so a file that mixes them says so:
	//
	//   classType  drives visibility. "dual_language" shows the Dual Language section;
	//              "general_education" hides it, and the engine retains its stored answers.
	//   grade      drives the file name (behavior.export.fileNamePattern is
	//              ICFWalk_<grade>_<content>_<date>.txt), so A and B produce different names.
	//   a response summary_strengths is visible under both, so its value alone tells which
	//              committed state's responses a given file was built from.

	private struct function stateA() {
		return {
			"dimensions": {
				"date": { "dateValue": "2026-09-20" },
				"observer": { "textValue": "Coherence Observer" },
				"grade": { "selectedValueCode": "2" },
				"content": { "selectedValueCode": "math" },
				"classType": { "selectedValueCode": "dual_language" }
			},
			"responses": {
				"dual_language_notes": { "textValue": "DUAL-LANGUAGE-NOTE-FROM-STATE-A" },
				"summary_strengths": { "textValue": "STRENGTH-FROM-STATE-A" }
			}
		};
	}

	private struct function stateB() {
		return {
			"dimensions": {
				"date": { "dateValue": "2026-09-20" },
				"observer": { "textValue": "Coherence Observer" },
				"grade": { "selectedValueCode": "5" },
				"content": { "selectedValueCode": "math" },
				"classType": { "selectedValueCode": "general_education" }
			},
			"responses": {
				// dual_language_notes is omitted: under B the section is hidden, and the server takes
				// hidden values from the database rather than the request, so the note is retained.
				"summary_strengths": { "textValue": "STRENGTH-FROM-STATE-B" }
			}
		};
	}

	// ---- helpers -------------------------------------------------------------------------------

	private struct function p() { return variables.fx.principal(variables.walker.userId); }
	private string function newMutationId() { return variables.db.newGuid(); }

	private any function serviceWith(required any db, required any walkRepository) {
		return createObject("component", "icfwalk.walks.WalkService").init(
			variables.c.config, arguments.db, variables.c.errors, variables.c.logger, variables.c.auditRepository,
			variables.c.canonicalJson, variables.c.authorizationService, variables.c.snapshotService,
			variables.c.visibilityEngine, arguments.walkRepository, variables.c.walkPayloadValidator, variables.c.orgUnitRepository,
			variables.c.walkSummaryFormatter
		);
	}

	/** A walk committed in state A, with the row version its save produced. */
	private struct function walkInStateA() {
		var created = variables.svc.create(p(), { "orgUnitId": variables.S1, "clientMutationId": newMutationId() });
		var a = stateA();
		var saved = variables.svc.save(p(), created.id, {
			"rowVersion": created.rowVersion, "clientMutationId": newMutationId(),
			"dimensions": a.dimensions, "responses": a.responses
		});
		return { "id": created.id, "rowVersion": saved.rowVersion, "versionId": created.versionId };
	}

	private string function storedRowVersion(required string walkId) {
		return variables.db.run("SELECT CONVERT(varchar(18), CAST(row_version AS binary(8)), 1) AS rv FROM [icf].[walk] WHERE walk_id = :id", { "id": variables.db.guid(arguments.walkId) }).rv[1];
	}

	/** The stored text of one response, read straight from the table. */
	private string function storedResponseText(required string walkId, required string itemKey) {
		var q = variables.db.run(
			"SELECT r.text_value FROM [icf].[walk_response] r JOIN [icf].[item_definition] i ON i.item_id = r.item_id WHERE r.walk_id = :id AND i.item_key = :k",
			{ "id": variables.db.guid(arguments.walkId), "k": variables.db.nvarchar(arguments.itemKey) });
		return q.recordCount && !isNull(q.text_value[1]) ? q.text_value[1] : "";
	}

	private string function storedDimensionCode(required string walkId, required string dimensionCode) {
		var q = variables.db.run(
			"SELECT dv.value_code FROM [icf].[walk_dimension_value] v JOIN [icf].[dimension_definition] d ON d.dimension_id = v.dimension_id LEFT JOIN [icf].[dimension_value] dv ON dv.value_id = v.selected_value_id WHERE v.walk_id = :id AND d.code = :c",
			{ "id": variables.db.guid(arguments.walkId), "c": variables.db.nvarchar(arguments.dimensionCode) });
		return q.recordCount && !isNull(q.value_code[1]) ? q.value_code[1] : "";
	}

	public void function assertDoesNotContain(required string needle, required string haystack, string message = "") {
		if (find(arguments.needle, arguments.haystack)) {
			fail((len(arguments.message) ? arguments.message & " " : "") & "Expected NOT to find [" & arguments.needle & "] but it is present.");
		}
	}

	/**
	 * A file is "mixed" when it shows a section only state A's dimensions make visible while
	 * carrying a response only state B committed. No committed state of the walk has both, so any
	 * export that does was assembled from two of them.
	 */
	private boolean function isMixed(required struct export) {
		return find("DUAL-LANGUAGE-NOTE-FROM-STATE-A", arguments.export.text) > 0
			&& find("STRENGTH-FROM-STATE-B", arguments.export.text) > 0;
	}

	// ---- the audited scenario, forced deterministically -----------------------------------------

	/**
	 * A real concurrent SAVE, started at the export's aggregate-read boundary, cannot commit there,
	 * and the file describes state A alone. Against the uncorrected implementation this fails twice
	 * over: the writer committed inside the bounded join (nothing held it), and the export then read
	 * its responses, so the text carried STRENGTH-FROM-STATE-B under state A's Dual Language
	 * section -- a combination the walk never held.
	 */
	public void function testASummaryExportCannotStraddleAConcurrentSave() {
		var w = walkInStateA();
		var interceptor = createObject("component", "icfwalktests.support.InterceptingWalkRepository").init(variables.c.walkRepository);
		var exportSvc = serviceWith(variables.c.db, interceptor);

		var realSvc = variables.svc;
		var writer = p();
		var walkId = w.id;
		var writerRowVersion = w.rowVersion;
		var writerMutationId = newMutationId();
		var b = stateB();
		var observed = { "duringExport": "", "rowVersionDuringExport": "" };

		// The boundary, exactly: the export has taken the walk lock, has read state A's dimensions,
		// and has not yet read its responses. A commit landing here is the mixed read itself.
		interceptor.arm("loadResponses", function() {
			observed.rowVersionDuringExport = storedRowVersion(walkId);
			thread name="summaryCoherenceWriter" svc=realSvc who=writer wid=walkId rv=writerRowVersion mid=writerMutationId payload=b {
				try {
					attributes.svc.save(attributes.who, attributes.wid, {
						"rowVersion": attributes.rv, "clientMutationId": attributes.mid,
						"dimensions": attributes.payload.dimensions, "responses": attributes.payload.responses
					});
					thread.outcome = "committed";
				} catch (any e) {
					thread.outcome = structKeyExists(e, "errorcode") ? e.errorcode : e.type;
				}
			}
			// Generous: this save runs in a small fraction of this when nothing obstructs it, so
			// "still running" can only mean something is making it wait.
			threadJoin("summaryCoherenceWriter", 6000);
			observed.duringExport = cfthread.summaryCoherenceWriter.status;
		});

		var exportA = "";
		try {
			exportA = exportSvc.summary(writer, walkId);

			assertTrue(interceptor.fired("loadResponses"), "the concurrent save was started between the dimension read and the response read");
			// 4. It could not commit there.
			assertExactTextNotEquals("COMPLETED", observed.duringExport, "the concurrent SAVE was blocked while the summary held the walk mutation lock");
			assertRowVersionEquals(w.rowVersion, observed.rowVersionDuringExport, "and the walk had not moved while the export was materializing");
		} finally {
			// Bounded and unconditional: a failed assertion above must not strand the thread.
			if (structKeyExists(cfthread, "summaryCoherenceWriter")) threadJoin("summaryCoherenceWriter", 30000);
		}

		// 6. The export describes state A, in every part of it.
		assertContains("STRENGTH-FROM-STATE-A", exportA.text, "the text carries state A's response");
		assertDoesNotContain("STRENGTH-FROM-STATE-B", exportA.text, "and never the concurrent save's response");
		assertContains("DUAL-LANGUAGE-NOTE-FROM-STATE-A", exportA.text, "state A's classType makes the Dual Language section visible");
		assertContains("_2_", exportA.fileName, "the file name is built from state A's grade: " & exportA.fileName);
		assertDoesNotContain("_5_", exportA.fileName, "never the concurrent save's grade: " & exportA.fileName);
		assertExactTextEquals("DRAFT", exportA.status);
		assertExactTextEquals(w.versionId, exportA.versionId, "and the walk's own pinned instrument version");
		assertFalse(isMixed(exportA), "the export is not a mixture of state A and state B");

		// 7. The writer ran to completion once the export released the lock, and it committed.
		assertExactTextEquals("COMPLETED", cfthread.summaryCoherenceWriter.status, "the deferred writer ran after the summary transaction finished");
		assertExactTextEquals("committed", cfthread.summaryCoherenceWriter.outcome, "and it committed: the export blocked it, it did not fail it");
		assertExactTextEquals("general_education", storedDimensionCode(walkId, "classType"), "the database now holds state B");
		assertExactTextEquals("5", storedDimensionCode(walkId, "grade"));
		assertRowVersionChanged(w.rowVersion, storedRowVersion(walkId), "on a new row version");

		// 8. A second export, after B committed, describes state B alone.
		var exportB = variables.svc.summary(p(), walkId);
		assertContains("STRENGTH-FROM-STATE-B", exportB.text, "the later export carries state B's response");
		assertDoesNotContain("STRENGTH-FROM-STATE-A", exportB.text, "and not state A's");
		assertContains("_5_", exportB.fileName, "with state B's grade in the file name: " & exportB.fileName);
		assertDoesNotContain("_2_", exportB.fileName, exportB.fileName);
		// SUM-04: state B hides the Dual Language section, so its retained note is excluded from the
		// file -- while still being in the database, which is what makes this a visibility decision
		// and not a deletion.
		assertDoesNotContain("DUAL-LANGUAGE-NOTE-FROM-STATE-A", exportB.text, "a value state B's dimensions hide is never exported");
		assertExactTextEquals("DUAL-LANGUAGE-NOTE-FROM-STATE-A", storedResponseText(walkId, "dual_language_notes"), "though it is retained in the database");
		assertFalse(isMixed(exportB), "the later export is not a mixture either");

		// 9. Stated once over both files: no export produced the mixed state.
		for (var e in [exportA, exportB]) assertFalse(isMixed(e), "no export contains the state A / state B combination");
	}

	// ---- the seam itself ------------------------------------------------------------------------

	/**
	 * Where the concurrent writer starts is the whole scenario, so the seam is asserted rather than
	 * assumed.
	 *
	 * The decorator is exercised against a recording delegate -- this spec itself, which implements
	 * the two aggregate reads below and logs the order they happen in -- so the check needs no
	 * database, no service and no instrument. It is about the interceptor's wiring and nothing else.
	 *
	 * The fact under test: a callback armed on loadResponses runs after the dimension read has
	 * returned and before the response read is delegated. That is the only point at which a commit
	 * produces a mixed aggregate. A callback armed on loadDimensionValues -- which is what this spec
	 * used to arm -- runs ahead of both reads, where a commit yields the newer state coherently
	 * instead of a mixture. This case fails against an interceptor that has no loadResponses seam,
	 * because nothing fires at all.
	 */
	public void function testTheConcurrencySeamFiresBetweenTheTwoAggregateReads() {
		variables.calls = [];
		var interceptor = createObject("component", "icfwalktests.support.InterceptingWalkRepository").init(this);
		interceptor.arm("loadResponses", function() { arrayAppend(variables.calls, "writer-starts"); });

		// Exactly the order WalkService.summary() performs them in, inside its locked transaction.
		interceptor.loadDimensionValues("11111111-1111-4111-8111-111111111111");
		interceptor.loadResponses("11111111-1111-4111-8111-111111111111");

		assertTrue(interceptor.fired("loadResponses"), "the loadResponses seam exists and fired");
		assertExactJsonEquals(
			["read-dimensions", "writer-starts", "read-responses"],
			variables.calls,
			"the writer starts between the two aggregate reads, not before them"
		);

		// And the seam the replay specs depend on is still the earlier one, unchanged.
		variables.calls = [];
		var earlier = createObject("component", "icfwalktests.support.InterceptingWalkRepository").init(this);
		earlier.arm("loadDimensionValues", function() { arrayAppend(variables.calls, "writer-starts"); });
		earlier.loadDimensionValues("11111111-1111-4111-8111-111111111111");
		earlier.loadResponses("11111111-1111-4111-8111-111111111111");
		assertExactJsonEquals(
			["writer-starts", "read-dimensions", "read-responses"],
			variables.calls,
			"loadDimensionValues still fires ahead of both reads, which is what WalkReplayCoherenceTest arms"
		);
	}

	// ---- recording delegate for the seam case ----------------------------------------------------
	//
	// The spec stands in for WalkRepository in that one case. These are not test methods (the runner
	// collects only names beginning with "test") and nothing else in this spec calls them: the
	// scenarios above decorate the real repository.

	public struct function loadDimensionValues(required string walkId) {
		arrayAppend(variables.calls, "read-dimensions");
		return {};
	}

	public struct function loadResponses(required string walkId) {
		arrayAppend(variables.calls, "read-responses");
		return {};
	}

	/**
	 * Why proving it for SAVE proves it for COMPLETE and VOID: they are not three protocols, they
	 * are one lock. Every WalkService transaction that operates on a walk that already exists opens
	 * by taking findWalk(<id>, true) -- the UPDLOCK/ROWLOCK row -- before it reads or writes
	 * anything else, and the summary export now does the same. Two transactions that both begin by
	 * taking the same row lock cannot overlap, whatever either of them goes on to do. So the
	 * serialization proved for SAVE above is a property of the lock, not of SAVE, and it holds for
	 * COMPLETE, VOID and a mutation replay identically.
	 *
	 * create() is the one transaction that does not take it, and cannot: there is no walk row to
	 * lock until its own insert makes one, and until that insert commits no other session can see
	 * the walk at all, so there is nothing for an export to interleave with.
	 *
	 * Asserted against the source rather than described in a comment, so a mutation path added
	 * later without the lock, or a summary export that quietly drops it, fails here.
	 */
	public void function testEveryMutationPathTakesTheSameWalkLock() {
		var source = repoFile("src/walks/WalkService.cfc");

		// The lock is one query shape in one place: nothing else in the repository grants it.
		var repo = repoFile("src/walks/WalkRepository.cfc");
		assertEquals(1, arrayLen(reMatch("WITH \(UPDLOCK, ROWLOCK\)", repo)), "the walk mutation lock is exactly one repository query");
		assertContains("public struct function findWalk(required string walkId, boolean lock = false)", repo, "and findWalk(id, true) is how it is taken");

		// Every transaction opened in WalkService, with the statement it opens with.
		var opener = "variables.db.transact(function() {";
		var openers = [];
		var at = 1;
		while (true) {
			var found = find(opener, source, at);
			if (found == 0) break;
			var rest = mid(source, found + len(opener), 300);
			arrayAppend(openers, trim(listFirst(rest, ";")));
			at = found + 1;
		}
		assertTrue(arrayLen(openers) >= 5, "found only " & arrayLen(openers) & " transactions in WalkService; the scan is not reading the source");

		var unlocked = [];
		for (var statement in openers) {
			if (find("findWalk(", statement) && find(", true)", statement)) continue;
			arrayAppend(unlocked, statement);
		}
		// Exactly one, and it is create's insert: every other transaction locks first.
		assertEquals(1, arrayLen(unlocked), "every WalkService transaction but create's must open by taking the walk mutation lock; these do not: " & arrayToList(unlocked, " | "));
		assertContains("insertWalk(", unlocked[1], "and the one that does not is create, whose walk row does not exist yet: " & unlocked[1]);

		// And the export is one of the locked ones: inside a transaction, lock first, aggregate after.
		var summaryStart = find("public struct function summary(", source);
		assertTrue(summaryStart > 0, "summary() is still in WalkService");
		var summaryBody = mid(source, summaryStart, find("public struct function instrumentFor(", source) - summaryStart);
		assertContains(opener, summaryBody, "the summary export is materialized inside a transaction");
		assertContains("walks.findWalk(id, true)", summaryBody, "which takes the walk mutation lock");
		var lockAt = find("walks.findWalk(id, true)", summaryBody);
		assertTrue(find("walks.loadDimensionValues(id)", summaryBody) > lockAt, "and takes it before it reads the dimensions");
		assertTrue(find("walks.loadResponses(id)", summaryBody) > lockAt, "and before it reads the responses");
		// The audit event and the log line are metadata written after the coherent result exists.
		assertTrue(
			find("variables.audit.record(", summaryBody) > find("});", summaryBody),
			"the export audit event is recorded after the transaction, from the materialized result"
		);
		assertContains("WALK_SUMMARY_EXPORTED", summaryBody, "and the export is still audited");
	}

	/**
	 * The export is still a read. Holding the mutation lock must not turn it into a write: no row
	 * version moves, no revision is appended, no mutation is recorded, and the status is untouched.
	 */
	public void function testTheLockedExportStillWritesNothingAboutTheWalk() {
		var w = walkInStateA();
		var before = storedRowVersion(w.id);
		var revisionsBefore = variables.db.scalar("SELECT COUNT(*) AS n FROM [icf].[walk_revision] WHERE walk_id = :id", { "id": variables.db.guid(w.id) });
		var mutationsBefore = variables.db.scalar("SELECT COUNT(*) AS n FROM [icf].[walk_mutation] WHERE walk_id = :id", { "id": variables.db.guid(w.id) });

		var first = variables.svc.summary(p(), w.id);
		var second = variables.svc.summary(p(), w.id);

		assertRowVersionEquals(before, storedRowVersion(w.id), "an export does not move the walk's row version");
		assertEquals(revisionsBefore, variables.db.scalar("SELECT COUNT(*) AS n FROM [icf].[walk_revision] WHERE walk_id = :id", { "id": variables.db.guid(w.id) }), "nor append a revision");
		assertEquals(mutationsBefore, variables.db.scalar("SELECT COUNT(*) AS n FROM [icf].[walk_mutation] WHERE walk_id = :id", { "id": variables.db.guid(w.id) }), "nor record a mutation");
		assertExactTextEquals(first.text, second.text, "and it is repeatable: the same committed state exports the same bytes");
		assertExactTextEquals(first.fileName, second.fileName);
		assertEquals(first.bytes, second.bytes);
	}
}
