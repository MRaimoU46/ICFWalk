/**
 * Discarding a DRAFT by id deletes exactly the version the path names (P6A-03).
 *
 * THE DEFECT. POST /api/admin/instrument/versions/{V1}/discard used to read V1 WITHOUT a lock,
 * turn it into (instrument code, label), and hand that to the label-addressed discard, which locked
 * and deleted whatever row owned the label at that moment. If V1 was discarded and a new DRAFT V2
 * created under the same label in between -- by another administrator, in the ordinary course of
 * re-making a draft -- the request that named V1 deleted V2, and audited V2's id as discarded.
 *
 * THE CORRECTION. discardDraftById is one identity-preserving transaction: it locks the exact path
 * id, derives the instrument, label and status from that locked row, confirms that this id is a
 * DRAFT no walk references, deletes this id only (asserting one version row went), and audits and
 * returns this id. It never resolves a label.
 *
 * WHAT IS PROVED HERE, by forcing the interleaving rather than racing for it. Request A names V1.
 * The spec stops A at the moment it holds its read of V1 and has done nothing else (A_LOCKED), and
 * starts B on another thread: B discards V1 by id and then creates V2 under V1's label. B announces
 * B_AT_COMPETING_BOUNDARY immediately before its own read of V1. Then the spec waits for one of two
 * observations, never for elapsed time:
 *
 *   - SQL Server reports B's request blocked behind A's session (sys.dm_exec_requests), which is
 *     what the corrected code produces: A holds V1's row lock, so B queues on it; or
 *   - B finishes (B_DONE), which is what the uncorrected code produces: A held no lock, so B deleted
 *     V1 and created V2 while A was paused.
 *
 * A is then released. Corrected, A deletes V1 and B, unblocked, finds V1 already gone and creates
 * V2, which survives. Uncorrected, A resolves the label, finds V2, and deletes it -- and the spec
 * fails on that state, not on a timeout.
 *
 * The seams are the test-only InterceptingDefinitionRepository; nothing in src/ can reach them.
 */
component extends="icfwalktests.BaseSpec" output="false" {

	public string function skipReason() {
		return schemaPresent() ? "" : "icf schema is not present in datasource '" & variables.c.db.datasourceName() & "'.";
	}

	public void function beforeAll() {
		variables.run = "dib-" & lCase(left(replace(createUUID(), "-", "", "all"), 8));
		variables.db = variables.c.db;
		variables.repo = variables.c.definitionRepository;
		variables.cleanup = new icfwalktests.support.FixtureCleanup(variables.c);
		variables.adminA = variables.cleanup.ensureUser(variables.run & "-admin-a", "Discard barrier administrator A");
		variables.adminB = variables.cleanup.ensureUser(variables.run & "-admin-b", "Discard barrier administrator B");
		variables.codes = [];
	}

	public void function afterAll() {
		for (var code in variables.codes) variables.cleanup.removeInstrumentsCoded(code);
		variables.cleanup.removeUsers(variables.run & "-");
	}

	public void function testADiscardNamingV1NeverDeletesTheV2ThatTookItsLabel() {
		var code = "DIB" & uCase(left(replace(createUUID(), "-", "", "all"), 9));
		arrayAppend(variables.codes, code);
		var label = variables.run & "-shared-label";
		var v1 = variables.c.instrumentImportService.importConfig(configFor(code, label), variables.adminA).versionId;
		// V2 will carry different content, so its identity is visible in its checksum as well as its id.
		var v2Config = configFor(code, label);
		v2Config.instrument.version.revisionNotes = "V2: re-made after V1 was discarded";

		var barrier = createObject("component", "icfwalktests.support.ConcurrencyBarrier").init();
		var aRepo = createObject("component", "icfwalktests.support.InterceptingDefinitionRepository").init(variables.repo);
		var bRepo = createObject("component", "icfwalktests.support.InterceptingDefinitionRepository").init(variables.repo);
		var aImporter = importServiceWith(aRepo);
		var bImporter = importServiceWith(bRepo);
		var creator = variables.c.instrumentImportService;

		// B's first read of V1, locked (corrected) or not (uncorrected): the competing boundary.
		var bArrived = function() { barrier.signalOnce("B_AT_COMPETING_BOUNDARY"); };
		var bPassed = function() { barrier.signalOnce("B_PASSED_BOUNDARY"); };
		bRepo.armBefore("findVersionByIdForUpdate", bArrived);
		bRepo.armBefore("findVersionById", bArrived);
		bRepo.armAfter("findVersionByIdForUpdate", bPassed);
		bRepo.armAfter("findVersionById", bPassed);

		var threadName = "discardB" & lCase(left(replace(createUUID(), "-", "", "all"), 10));
		var db = variables.db;
		var who = variables.adminB;
		var observed = { "ran": false, "reached": false, "blockedBehindA": false, "passedWhileHeld": false, "doneWhileHeld": false };
		var holdA = function() {
			if (observed.ran) return;
			observed.ran = true;
			// A has read V1 -- under its row lock, if it takes one -- and has done nothing else.
			barrier.signal("A_LOCKED");
			thread name="#threadName#" importer=bImporter creator=creator vid=v1 who=who cfg=v2Config barrier=barrier {
				try {
					attributes.importer.discardDraftById(attributes.vid, attributes.who);
					thread.discardOutcome = "discarded";
				} catch (any e) {
					thread.discardOutcome = structKeyExists(e, "errorcode") && len(e.errorcode) && e.errorcode != "0" ? e.errorcode : e.type;
				}
				try {
					thread.v2 = attributes.creator.importConfig(attributes.cfg, attributes.who).versionId;
					thread.createOutcome = "created";
				} catch (any e) {
					thread.createOutcome = structKeyExists(e, "errorcode") && len(e.errorcode) && e.errorcode != "0" ? e.errorcode : e.type;
					thread.detail = left(e.message, 300);
				}
				attributes.barrier.signal("B_DONE");
			}
			observed.reached = barrier.await("B_AT_COMPETING_BOUNDARY", 60000);
			// Wait for an observation: B blocked behind this session, or B finished. The ceiling
			// turns a hang into a failure; it is never the evidence.
			var deadline = getTickCount() + 60000;
			while (getTickCount() < deadline) {
				var waiting = db.run("SELECT COUNT(*) AS n FROM sys.dm_exec_requests WHERE blocking_session_id = @@SPID");
				if (waiting.n[1] > 0) { observed.blockedBehindA = true; break; }
				if (barrier.await("B_DONE", 100)) break;
			}
			observed.passedWhileHeld = barrier.observed("B_PASSED_BOUNDARY");
			observed.doneWhileHeld = barrier.observed("B_DONE");
		};
		aRepo.armAfter("findVersionByIdForUpdate", holdA);
		aRepo.armAfter("findVersionById", holdA);

		var discarded = aImporter.discardDraftById(v1, variables.adminA);
		threadJoin(threadName, 60000);
		var b = cfthread[threadName];

		// The request named V1: it deleted V1 and reported V1.
		assertExactTextEquals(v1, discarded.versionId, "the discard reports the version its path named");
		assertExactTextEquals(label, discarded.versionLabel);
		assertTrue(structIsEmpty(variables.repo.findVersionById(v1)), "V1 is gone");

		// V2, which took V1's label while A was paused, survives untouched.
		assertExactTextEquals("COMPLETED", b.status, "B finished");
		assertExactTextEquals("created", b.createOutcome, "B created V2" & (structKeyExists(b, "detail") ? " (" & b.detail & ")" : ""));
		var v2 = variables.repo.findVersionById(b.v2);
		assertFalse(structIsEmpty(v2), "V2 was not deleted by a request that named V1");
		assertExactTextNotEquals(v1, b.v2);
		assertExactTextEquals("DRAFT", v2.status);
		assertExactTextEquals(label, v2.versionLabel);
		assertEquals(0, discardEvents(b.v2), "no discard was ever audited against V2");
		assertEquals(1, discardEvents(v1), "exactly one discard is audited, against V1");
		assertExactTextEquals(variables.adminA, discardActor(v1), "attributed to the request that named V1");
		assertExactTextEquals("INSTRUMENT_VERSION_NOT_FOUND", b.discardOutcome, "B's own discard of V1 found it already gone once A committed");

		// And the interleaving really happened, in this order, with B held back by A.
		assertTrue(barrier.observed("A_LOCKED"), "A really paused holding its read of V1");
		assertTrue(observed.reached, "B announced that it had reached its read of V1");
		assertTrue(barrier.signalledInOrder("A_LOCKED", "B_AT_COMPETING_BOUNDARY"), "in that order");
		assertTrue(observed.blockedBehindA, "SQL Server reported B blocked behind A's session while A held V1");
		assertFalse(observed.passedWhileHeld, "B did not get past its read of V1 while A held it");
		assertFalse(observed.doneWhileHeld, "B did not finish while A held V1");
	}

	/**
	 * The ordinary refusals keep their codes on the id-addressed path, and each is decided on the
	 * locked row: a published version is immutable, a DRAFT walks reference is in use, and an id
	 * that names nothing is not found.
	 */
	public void function testTheIdAddressedDiscardRefusesExactlyAsBefore() {
		var code = "DIB" & uCase(left(replace(createUUID(), "-", "", "all"), 9));
		arrayAppend(variables.codes, code);
		var importer = variables.c.instrumentImportService;
		var published = importer.importConfig(configFor(code, variables.run & "-published"), variables.adminA).versionId;
		variables.c.instrumentPublishService.publish(published, variables.adminA);
		var before = variables.repo.findVersionById(published);
		assertThrows(function() { importer.discardDraftById(published, variables.adminA); }, "ICFWalk.Import.PublishedVersion", "INSTRUMENT_VERSION_IMMUTABLE");
		var after = variables.repo.findVersionById(published);
		assertExactTextEquals(before.rowVersion, after.rowVersion, "the published version is byte-identical");
		assertExactTextEquals(before.checksum, after.checksum);

		var inUse = importer.importConfig(configFor(code, variables.run & "-in-use"), variables.adminA).versionId;
		var unit = variables.cleanup.ensureOrgUnit(variables.run & "-school");
		var walkId = variables.cleanup.insertWalk(inUse, unit, variables.adminA);
		try {
			assertThrows(function() { importer.discardDraftById(inUse, variables.adminA); }, "ICFWalk.Import.VersionInUse", "INSTRUMENT_VERSION_IN_USE");
			assertFalse(structIsEmpty(variables.repo.findVersionById(inUse)), "a DRAFT in use is not deleted");
		} finally {
			variables.cleanup.removeWalk(walkId);
		}
		assertThrows(function() { importer.discardDraftById(variables.db.newGuid(), variables.adminA); }, "ICFWalk.NotFound", "INSTRUMENT_VERSION_NOT_FOUND");
	}

	// ---- helpers ---------------------------------------------------------------------------------

	private any function importServiceWith(required any repository) {
		return createObject("component", "icfwalk.instrument.InstrumentImportService").init(
			variables.c.config, variables.c.db, variables.c.errors, variables.c.logger, arguments.repository,
			variables.c.auditRepository, variables.c.configNormalizer, variables.c.configValidator,
			variables.c.snapshotCompiler, variables.c.requestContext, variables.c.renderContractValidator
		);
	}

	private struct function configFor(required string code, required string versionLabel) {
		var cfg = repoJson("config/instrument-config.json");
		cfg.instrument.code = arguments.code;
		cfg.instrument.version.versionLabel = arguments.versionLabel;
		return cfg;
	}

	private numeric function discardEvents(required string versionId) {
		return variables.db.scalar(
			"SELECT COUNT(*) AS n FROM [icf].[audit_event] WHERE entity_type = N'INSTRUMENT_VERSION' AND entity_id = :id AND event_type = N'INSTRUMENT_VERSION_DISCARDED'",
			{ "id": variables.db.guid(arguments.versionId) }
		);
	}

	private string function discardActor(required string versionId) {
		var q = variables.db.run(
			"SELECT actor_user_id FROM [icf].[audit_event] WHERE entity_type = N'INSTRUMENT_VERSION' AND entity_id = :id AND event_type = N'INSTRUMENT_VERSION_DISCARDED'",
			{ "id": variables.db.guid(arguments.versionId) }
		);
		return q.recordCount ? uCase(q.actor_user_id[1]) : "";
	}
}
