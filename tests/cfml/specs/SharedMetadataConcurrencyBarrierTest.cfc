/**
 * The shared icf.instrument row, under contention.
 *
 * THE DEFECT THIS EXISTS FOR. InstrumentMetadataService used to read the instrument with an
 * ordinary unlocked `findInstrumentByCode`, derive a COMPLETE replacement row from it (a partial
 * patch keeps the stored value of everything it omits), and only then call
 * DefinitionRepository.updateInstrumentMetadata, where the row lock was finally taken. A lock
 * acquired after a read does not protect that read. Two concurrent partial updates therefore both
 * derived their omitted values from the same stale row:
 *
 *   1. Both read { name: N0, active: true }.
 *   2. Request A changes only `active` to false and commits.
 *   3. Request B, which changes only `name`, was queued on the row lock. It wakes and writes its
 *      new name together with the `active: true` it read before A ran.
 *   4. The deliberate deactivation is gone. icf.instrument.active is part of the predicate
 *      SnapshotService.currentVersion() selects with, so a published version that an administrator
 *      took out of service is silently back in service, and the audit trail records a `before`
 *      image that was never the row the request actually replaced.
 *
 * Import had the same shape: it read icf.instrument before locking the version and then evaluated
 * the document's shared `active` against that earlier object, so an authorized metadata change
 * that committed in between was invisible to the conflict decision.
 *
 * WHAT IS PROVED HERE. The locked read, the merge, the update and the audit are one transaction,
 * and the values a request writes are derived from the row it actually replaces:
 *
 *   - two partial updates that contend both survive, in either arrival order;
 *   - each audit event describes the row that was really replaced and the values really committed;
 *   - import evaluates SHARED_METADATA_CONFLICT against the locked current row, not its earlier
 *     lookup, whether the competing change commits before import reaches the check or while import
 *     is queued on the row lock;
 *   - a conflict refusal moves nothing at all and leaves exactly one durable refusal audit.
 *
 * HOW THE INTERLEAVING IS FORCED. support/ConcurrencyBarrier, exactly as in
 * PublishConcurrencyBarrierTest: A announces A_LOCKED from inside its transaction once it holds
 * the shared row, B announces B_AT_COMPETING_BOUNDARY immediately before the statement that will
 * contend for it, and the spec releases A only after hearing B. Nothing here infers an arrival
 * from a timeout.
 *
 * The decorator arms both the corrected seam (lockInstrumentByCode, lockInstrumentById) and the
 * uncorrected one (findInstrumentByCode, updateInstrumentMetadata), so these specs drive the
 * pre-correction code to the same interleaving and fail there on the lost update itself rather
 * than on an absent method.
 */
component extends="icfwalktests.BaseSpec" output="false" {

	public string function skipReason() {
		return schemaPresent() ? "" : "icf schema is not present in datasource '" & variables.c.db.datasourceName() & "'.";
	}

	public void function beforeAll() {
		variables.run = "metabar-" & lCase(left(replace(createUUID(), "-", "", "all"), 8));
		variables.instrumentCode = "MBRFIX" & uCase(left(replace(createUUID(), "-", "", "all"), 8));
		variables.db = variables.c.db;
		variables.repo = variables.c.definitionRepository;
		variables.importSvc = variables.c.instrumentImportService;
		variables.fixtures = new icfwalktests.support.FixtureCleanup(variables.c);
		variables.orgUnit = variables.fixtures.ensureOrgUnit(variables.run & "-district", "DISTRICT");
		variables.adminId = variables.fixtures.ensureUser(variables.run & "-admin", "Shared metadata barrier administrator");
		variables.fixtures.grantRole(variables.adminId, "MASTER_INSTRUMENT_ADMIN", variables.orgUnit, true);
		variables.admin = variables.fixtures.principalFor(variables.adminId);
		variables.secondAdminId = variables.fixtures.ensureUser(variables.run & "-admin2", "Shared metadata barrier second administrator");
		variables.fixtures.grantRole(variables.secondAdminId, "MASTER_INSTRUMENT_ADMIN", variables.orgUnit, true);
		variables.secondAdmin = variables.fixtures.principalFor(variables.secondAdminId);
		// One DRAFT of the fixture instrument, so the shared row exists and refusals have a version
		// to be recorded against.
		variables.seed = variables.importSvc.importConfig(config(label("v1")));
	}

	public void function afterAll() {
		variables.fixtures.removeInstrumentsCoded(variables.instrumentCode);
		variables.fixtures.removeUsers(variables.run & "-");
		variables.c.orgUnitRepository.deleteUnreferenced(variables.orgUnit);
	}

	public void function beforeEach() {
		// Every case starts from a known shared row, written through the authorized operation.
		variables.c.instrumentMetadataService.updateMetadata(
			variables.instrumentCode, { "name": "Barrier baseline", "description": "baseline", "active": true }, variables.admin
		);
	}

	// ---- two partial updates that contend ---------------------------------------------------------

	/**
	 * A deactivates. B, queued behind A on the row lock, changes only the name.
	 *
	 * Both changes are independent and both must survive. Against the uncorrected service B writes
	 * the `active: true` it read before A ran, and the deactivation is lost.
	 */
	public void function testADeactivationIsNotLostByAConcurrentRename() {
		var outcome = contendingUpdates(
			{ "active": false },                       // A: holds the lock first
			{ "name": "Renamed while deactivating" }   // B: queues behind it
		);

		var row = instrumentRow();
		assertExactTextEquals("Renamed while deactivating", row.name, "the rename survived");
		assertFalse(row.active, "and so did the deactivation: the rename did not restore the value it had read before");
		assertExactTextEquals("committed", outcome.bOutcome, "both requests committed");
	}

	/** The same two changes, with the arrival order at the row lock reversed. */
	public void function testARenameIsNotLostByAConcurrentDeactivation() {
		var outcome = contendingUpdates(
			{ "name": "Renamed first" },  // A: holds the lock first
			{ "active": false }           // B: queues behind it
		);

		var row = instrumentRow();
		assertExactTextEquals("Renamed first", row.name, "the rename survived");
		assertFalse(row.active, "and the deactivation that arrived second was applied to the renamed row");
		assertExactTextEquals("committed", outcome.bOutcome, "both requests committed");
	}

	/**
	 * Each audit event describes the row it actually replaced.
	 *
	 * The second writer's `before` image must be what the first writer committed -- not the row
	 * either of them read before the contention started. A stale `before` image is an audit trail
	 * that records a change that did not happen.
	 */
	public void function testEachAuditDescribesTheRowItActuallyReplaced() {
		var instrumentId = instrumentId();
		var baselineName = instrumentRow().name;
		var firstAudit = auditCount(instrumentId, "INSTRUMENT_METADATA_UPDATED");

		contendingUpdates({ "active": false }, { "name": "Second writer name" });

		var events = metadataAudits(instrumentId, 2);
		assertEquals(firstAudit + 2, auditCount(instrumentId, "INSTRUMENT_METADATA_UPDATED"), "one audit event per committed change");

		// events[1] is the earlier one (A, the deactivation); events[2] is B, which committed after it.
		var a = events[1];
		var b = events[2];
		assertExactTextEquals(baselineName, a.previousName, "A replaced the baseline row");
		assertTrue(a.previousActive, "which was active");
		assertFalse(a.active, "and A committed the deactivation");

		assertExactTextEquals(baselineName, b.previousName, "B's before image carries the name A left in place");
		assertFalse(b.previousActive, "and -- the point -- the active flag A had already committed, not the one B first read");
		assertExactTextEquals("Second writer name", b.name, "B committed its own name");
		assertFalse(b.active, "and did not resurrect the value it had read before A ran");

		var row = instrumentRow();
		assertExactTextEquals(b.name, row.name, "the last audit's after image is the committed row");
		assertEquals(b.active, row.active);
	}

	// ---- import's shared-state conflict check -----------------------------------------------------

	/**
	 * Import reads the instrument, an authorized metadata change commits, and import then reaches
	 * its conflict check. The check must use the locked current row.
	 *
	 * No lock contention is involved here on purpose: this is the read-then-decide hazard on its
	 * own. The metadata change runs to completion inside import's own callback, so the ordering is
	 * forced rather than raced, and the document (which says the instrument is active) now
	 * disagrees with the committed row (which says it is not).
	 */
	public void function testImportDecidesTheSharedConflictOnTheLockedCurrentRowNotItsEarlierLookup() {
		var aRepo = intercept();
		var aImport = importServiceWith(aRepo);
		var metadataSvc = variables.c.instrumentMetadataService;
		var code = variables.instrumentCode;
		var deactivator = variables.secondAdmin;
		var committed = false;

		// Fires once import has read icf.instrument and before it decides the conflict.
		aRepo.armAfter("findInstrumentByCode", function() {
			metadataSvc.updateMetadata(code, { "active": false }, deactivator);
			committed = true;
		});

		var cfg = config(label("v2-after-deactivation"));
		// The document says the instrument is active, which was true when import read the row.
		cfg.instrument["active"] = true;
		var refused = "";
		try {
			aImport.importConfig(cfg, variables.adminId);
			refused = "(imported)";
		} catch (any e) {
			refused = structKeyExists(e, "errorcode") && len(e.errorcode) ? e.errorcode : e.type;
		}

		assertTrue(committed, "the competing authorized metadata change really committed while import was in flight");
		assertFalse(instrumentRow().active, "and it is the committed state of the shared row");
		assertExactTextEquals("INSTRUMENT_CONFIG_INVALID", refused, "import was refused: it judged the conflict on the locked current row, not on the object it read first");
		assertEquals(0, variables.db.scalar(
			"SELECT COUNT(*) AS n FROM [icf].[instrument_version] v JOIN [icf].[instrument] i ON i.instrument_id = v.instrument_id WHERE i.code = :code AND v.version_label = :label",
			{ "code": variables.db.nvarchar(variables.instrumentCode, 60), "label": variables.db.nvarchar(label("v2-after-deactivation"), 100) }
		), "and the version it was writing was rolled back entirely");
	}

	/**
	 * The same decision under real lock contention: the metadata change holds the shared row while
	 * import, which has already taken its version lock, queues for it.
	 *
	 * This is also the lock-order case. Import takes icf.instrument_version first and icf.instrument
	 * second; the metadata operation takes only icf.instrument. There is no path that takes them in
	 * the other order, so these two queue instead of deadlocking.
	 */
	public void function testImportQueuesForTheSharedRowAndThenDecidesOnIt() {
		var barrier = newBarrier();
		var aRepo = intercept();
		var aMetadata = metadataServiceWith(aRepo);
		var bRepo = intercept();
		var bImport = importServiceWith(bRepo);
		// The corrected seam, and the uncorrected one it replaced.
		bRepo.armBefore("lockInstrumentById", function() { barrier.signalOnce("B_AT_COMPETING_BOUNDARY"); });

		var cfg = config(label("v2-queued"));
		cfg.instrument["active"] = true;
		var importActor = variables.adminId;
		var threadName = threadName("metaBarrierImport");
		var reached = false;
		var joinedStatus = "";
		var started = false;
		// The corrected seam is the locked read; before the correction the metadata service took no
		// lock until the update itself, so both are armed and whichever the code reaches starts B.
		var startImport = function() {
			if (started) return;
			started = true;
			barrier.signal("A_LOCKED");
			thread name="#threadName#" svc=bImport cfg=cfg who=importActor {
				try {
					attributes.svc.importConfig(attributes.cfg, attributes.who);
					thread.outcome = "imported";
				} catch (any e) {
					thread.outcome = structKeyExists(e, "errorcode") && len(e.errorcode) ? e.errorcode : e.type;
				}
			}
			reached = barrier.await("B_AT_COMPETING_BOUNDARY", 60000);
			threadJoin(threadName, 250);
			joinedStatus = cfthread[threadName].status;
		};
		aRepo.armAfter("lockInstrumentByCode", startImport);
		aRepo.armAfter("updateInstrumentMetadata", startImport);

		aMetadata.updateMetadata(variables.instrumentCode, { "active": false }, variables.admin);

		threadJoin(threadName, 60000);
		assertExactTextEquals("COMPLETED", cfthread[threadName].status, "the import finished once the shared row was released");
		assertExactTextEquals("INSTRUMENT_CONFIG_INVALID", cfthread[threadName].outcome, "and was refused on the row the metadata change had just committed");
		assertFalse(instrumentRow().active, "the authorized deactivation stands");

		// The barrier evidence, asserted after the behaviour it exists to make deterministic.
		assertTrue(barrier.observed("A_LOCKED"), "the metadata change really held the shared row");
		assertTrue(reached, "and the import announced that it had reached the same row's lock");
		assertTrue(barrier.signalledInOrder("A_LOCKED", "B_AT_COMPETING_BOUNDARY"), "in that order");
		assertExactTextNotEquals("COMPLETED", joinedStatus, "the import was still queued there while the metadata change held it");
	}

	/**
	 * A conflict refusal changes nothing at all: not the version row, not a definition row, not the
	 * snapshot or its checksum, not the shared row, not a row version. And it leaves exactly one
	 * durable refusal audit.
	 */
	public void function testAConflictRefusalMovesNothingAndLeavesOneDurableAudit() {
		var draft = variables.importSvc.importConfig(config(label("v2-refusal")));
		variables.c.instrumentMetadataService.updateMetadata(variables.instrumentCode, { "active": false }, variables.admin);

		var beforeVersion = variables.repo.findVersionById(draft.versionId);
		var beforeInstrument = instrumentRow();
		var beforeRefusals = auditCount(draft.versionId, "INSTRUMENT_VERSION_WRITE_REFUSED");
		var beforeDefinitions = variables.c.snapshotCompiler.definitionsChecksum(variables.repo.loadNormalizedDefinitions(draft.versionId));
		var beforeMetadataAudits = auditCount(instrumentId(), "INSTRUMENT_METADATA_UPDATED");

		var cfg = config(label("v2-refusal"));
		cfg.instrument["active"] = true;
		cfg.items[1].prompt = "A prompt a refused import must never store";
		var svc = variables.importSvc;
		var actor = variables.adminId;
		assertThrows(function() { svc.importConfig(cfg, actor); }, "ICFWalk.Import.Validation", "INSTRUMENT_CONFIG_INVALID");

		var afterVersion = variables.repo.findVersionById(draft.versionId);
		assertRowVersionEquals(beforeVersion.rowVersion, afterVersion.rowVersion, "the version row did not move");
		assertExactTextEquals(beforeVersion.checksum, afterVersion.checksum, "nor its checksum");
		assertExactTextEquals(beforeVersion.snapshotJson, afterVersion.snapshotJson, "nor its snapshot bytes");
		assertExactTextEquals(beforeVersion.status, afterVersion.status, "nor its status");
		assertExactTextEquals(beforeDefinitions, variables.c.snapshotCompiler.definitionsChecksum(variables.repo.loadNormalizedDefinitions(draft.versionId)), "nor any definition row");
		assertEquals(0, variables.db.scalar(
			"SELECT COUNT(*) AS n FROM [icf].[item_definition] WHERE version_id = :id AND prompt = N'A prompt a refused import must never store'",
			{ "id": variables.db.guid(draft.versionId) }
		), "nothing from the refused document was written");

		var afterInstrument = instrumentRow();
		assertExactTextEquals(beforeInstrument.name, afterInstrument.name, "the shared row did not move");
		assertEquals(beforeInstrument.active, afterInstrument.active, "including its active flag");
		assertRowVersionEquals(beforeInstrument.rowVersion, afterInstrument.rowVersion, "nor its row version");
		assertEquals(beforeMetadataAudits, auditCount(instrumentId(), "INSTRUMENT_METADATA_UPDATED"), "and no metadata audit was written by a refused import");

		assertEquals(beforeRefusals + 1, auditCount(draft.versionId, "INSTRUMENT_VERSION_WRITE_REFUSED"), "exactly one durable refusal audit survived the rollback");
		var q = variables.db.run(
			"SELECT TOP (1) details_json FROM [icf].[audit_event] WHERE entity_id = :id AND event_type = N'INSTRUMENT_VERSION_WRITE_REFUSED' ORDER BY event_id DESC",
			{ "id": variables.db.guid(draft.versionId) }
		);
		assertExactTextEquals("SHARED_METADATA_CONFLICT", deserializeJSON(q.details_json[1]).reason, "with a stable reason code");
		assertFalse(find("prompt", q.details_json[1]) > 0, "and no narrative content");
	}

	// ---- helpers ---------------------------------------------------------------------------------

	/**
	 * Runs two partial metadata updates that really contend: A takes the shared row's lock and
	 * announces it, B starts on its own thread and announces the moment it reaches the statement
	 * that will queue on that lock, and A is released only once B has been heard from.
	 */
	private struct function contendingUpdates(required struct aChanges, required struct bChanges) {
		var barrier = newBarrier();
		var aRepo = intercept();
		var aSvc = metadataServiceWith(aRepo);
		var bRepo = intercept();
		var bSvc = metadataServiceWith(bRepo);
		// The corrected boundary is the locked read; before the correction the row lock was first
		// taken inside the update itself, so both are armed and whichever the code reaches announces.
		var announce = function() { barrier.signalOnce("B_AT_COMPETING_BOUNDARY"); };
		bRepo.armBefore("lockInstrumentByCode", announce);
		bRepo.armBefore("updateInstrumentMetadata", announce);

		var code = variables.instrumentCode;
		var bPrincipal = variables.secondAdmin;
		var bPatch = arguments.bChanges;
		// The whole CFML suite runs inside one request, and a thread name must be unique within it.
		var threadName = threadName("metaBarrierB");
		var reached = false;
		var joinedStatus = "";
		var started = false;
		var start = function() {
			if (started) return;
			started = true;
			barrier.signal("A_LOCKED");
			thread name="#threadName#" svc=bSvc code=code changes=bPatch who=bPrincipal {
				try {
					attributes.svc.updateMetadata(attributes.code, attributes.changes, attributes.who);
					thread.outcome = "committed";
				} catch (any e) {
					thread.outcome = structKeyExists(e, "errorcode") && len(e.errorcode) ? e.errorcode : e.type;
				}
			}
			reached = barrier.await("B_AT_COMPETING_BOUNDARY", 60000);
			threadJoin(threadName, 250);
			joinedStatus = cfthread[threadName].status;
		};
		aRepo.armAfter("lockInstrumentByCode", start);
		aRepo.armAfter("findInstrumentByCode", start);

		aSvc.updateMetadata(variables.instrumentCode, arguments.aChanges, variables.admin);
		threadJoin(threadName, 60000);

		assertExactTextEquals("COMPLETED", cfthread[threadName].status, "the second update finished once the shared row was released");
		assertTrue(barrier.observed("A_LOCKED"), "the first update really held the shared row");
		assertTrue(reached, "and the second announced that it had reached the same row's lock");
		assertTrue(barrier.signalledInOrder("A_LOCKED", "B_AT_COMPETING_BOUNDARY"), "in that order");
		assertExactTextNotEquals("COMPLETED", joinedStatus, "the second update was still queued there while the first held it");
		return { "bOutcome": cfthread[threadName].outcome };
	}

	/** A thread name that is unique inside the single request the whole CFML suite runs in. */
	private string function threadName(required string prefix) {
		return arguments.prefix & lCase(left(replace(createUUID(), "-", "", "all"), 10));
	}

	private any function newBarrier() {
		return createObject("component", "icfwalktests.support.ConcurrencyBarrier").init();
	}

	private any function intercept() {
		return createObject("component", "icfwalktests.support.InterceptingDefinitionRepository").init(variables.repo);
	}

	/** A real metadata service whose only difference is the decorated repository. */
	private any function metadataServiceWith(required any repository) {
		return createObject("component", "icfwalk.instrument.InstrumentMetadataService").init(
			variables.c.db, variables.c.errors, variables.c.logger,
			arguments.repository, variables.c.auditRepository, variables.c.authorizationService
		);
	}

	/** A real import service whose only difference is the decorated repository. */
	private any function importServiceWith(required any repository) {
		return createObject("component", "icfwalk.instrument.InstrumentImportService").init(
			variables.c.config, variables.c.db, variables.c.errors, variables.c.logger,
			arguments.repository, variables.c.auditRepository, variables.c.configNormalizer,
			variables.c.configValidator, variables.c.snapshotCompiler, variables.c.requestContext,
			variables.c.renderContractValidator
		);
	}

	private string function label(required string suffix) {
		return variables.run & "-" & arguments.suffix;
	}

	private struct function config(required string versionLabel) {
		var cfg = repoJson("config/instrument-config.json");
		cfg.instrument.code = variables.instrumentCode;
		cfg.instrument.version.versionLabel = arguments.versionLabel;
		return cfg;
	}

	private string function instrumentId() {
		return variables.repo.findInstrumentByCode(variables.instrumentCode).instrumentId;
	}

	private struct function instrumentRow() {
		var q = variables.db.run(
			"SELECT name, description, active, row_version FROM [icf].[instrument] WHERE code = :code",
			{ "code": variables.db.nvarchar(variables.instrumentCode, 60) }
		);
		return {
			"name": q.name[1],
			"description": isNull(q.description[1]) ? "" : q.description[1],
			"active": q.active[1] ? true : false,
			"rowVersion": binaryEncode(q.row_version[1], "hex")
		};
	}

	/** The last `n` metadata audit events for the instrument, oldest first. */
	private array function metadataAudits(required string instrumentId, required numeric n) {
		var q = variables.db.run(
			"SELECT TOP (:n) details_json, event_id FROM [icf].[audit_event]
			  WHERE entity_id = :id AND event_type = N'INSTRUMENT_METADATA_UPDATED' ORDER BY event_id DESC",
			{ "id": variables.db.guid(arguments.instrumentId), "n": variables.db.integer(arguments.n) }
		);
		var out = [];
		for (var r = q.recordCount; r >= 1; r--) arrayAppend(out, deserializeJSON(q.details_json[r]));
		return out;
	}

	private numeric function auditCount(required string entityId, required string eventType) {
		return variables.db.scalar(
			"SELECT COUNT(*) AS n FROM [icf].[audit_event] WHERE entity_id = :id AND event_type = :t",
			{ "id": variables.db.guid(arguments.entityId), "t": variables.db.nvarchar(arguments.eventType) }
		);
	}
}
