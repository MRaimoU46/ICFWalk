/**
 * Deterministic proof that publication serializes against every operation that competes for the
 * same row -- not because a race happened to come out right, and not because a competitor failed
 * to finish inside a timeout, but because both participants said where they were and the spec
 * released the first one only after it had heard from the second.
 *
 * WHAT THE PREVIOUS FORM OF THIS SPEC COULD NOT SHOW. It started transaction A, started B, joined B
 * with `threadJoin(..., 6000)`, and treated `status != "COMPLETED"` as proof that B had reached the
 * competing row lock. That is an inference. A scheduler delay, a datasource-pool wait, or setup
 * work inside B produces exactly the same reading, and so does an implementation whose lock does
 * nothing on a run where B merely started late. Non-completion is now asserted only as a
 * supplemental fact, after B's arrival has been independently observed.
 *
 * THE TWO-SIDED BARRIER. support/InterceptingDefinitionRepository fires a one-shot callback
 * immediately before and immediately after each statement that takes a production row lock, and
 * support/ConcurrencyBarrier carries the two announcements across the thread boundary:
 *
 *   1. A takes the production lock and, from inside its transaction, emits A_LOCKED. It has done
 *      nothing else at that point.
 *   2. B starts on its own thread, through the real production service.
 *   3. B's own decorated repository emits B_AT_COMPETING_BOUNDARY immediately BEFORE the database
 *      call that will contend for A's lock, and then makes that call and blocks.
 *   4. The spec, still inside A, blocks on ConcurrencyBarrier.await("B_AT_COMPETING_BOUNDARY").
 *      It is released by B's announcement, never by elapsed time.
 *   5. Only then does the callback return: A carries on and commits, releasing the lock at a point
 *      the spec chose.
 *   6. B is joined with a bounded ceiling -- a safety net that turns a hang into a failure, not
 *      evidence -- and the one permitted serial outcome is asserted, together with the final data,
 *      row versions and audit counts.
 *
 * THE CASES. Publish versus publish, publish versus import, import versus publish, publish versus
 * a genuinely new global dimension identity, and publish versus a genuinely new global
 * dimension-value identity. The shared-row cases (metadata versus metadata, and import's shared
 * state check versus an authorized metadata update) live in SharedMetadataConcurrencyBarrierTest,
 * which contends on icf.instrument rather than on icf.instrument_version.
 *
 * NO PRODUCTION SEAM. The decorator and the barrier are test-only components, constructed here and
 * handed to services constructed here. The application container never holds them and no route
 * reaches them, so there is no configuration in which a client can activate a lock hook.
 */
component extends="icfwalktests.BaseSpec" output="false" {

	public string function skipReason() {
		return schemaPresent() ? "" : "icf schema is not present in datasource '" & variables.c.db.datasourceName() & "'.";
	}

	public void function beforeAll() {
		variables.run = "barrier-" & lCase(left(replace(createUUID(), "-", "", "all"), 8));
		variables.instrumentCode = "BARFIX" & uCase(left(replace(createUUID(), "-", "", "all"), 8));
		variables.db = variables.c.db;
		variables.repo = variables.c.definitionRepository;
		variables.importSvc = variables.c.instrumentImportService;
		variables.publishSvc = variables.c.instrumentPublishService;
		variables.fixtures = new icfwalktests.support.FixtureCleanup(variables.c);
		variables.publisher = variables.fixtures.ensureUser(variables.run & "-publisher", "Barrier fixture publisher");
		variables.other = variables.fixtures.ensureUser(variables.run & "-other", "Barrier fixture second publisher");
		variables.mintedDimensionCodes = [];
	}

	public void function afterAll() {
		for (var code in variables.mintedDimensionCodes) {
			variables.db.run("DELETE FROM [icf].[dimension_value] WHERE dimension_id IN (SELECT dimension_id FROM [icf].[dimension_definition] WHERE code = :code)", { "code": variables.db.nvarchar(code, 100) });
			variables.db.run("DELETE FROM [icf].[dimension_definition] WHERE code = :code", { "code": variables.db.nvarchar(code, 100) });
		}
		variables.fixtures.removeInstrumentsCoded(variables.instrumentCode);
		variables.fixtures.removeUsers(variables.run & "-");
	}

	/**
	 * PUBLISH versus PUBLISH. Two publishers, the same DRAFT, the second one started while the
	 * first holds the version's row lock and has not yet written anything.
	 *
	 * The only permitted serial outcome: one of them publishes, the other finds a version that is
	 * no longer a DRAFT and is refused with INSTRUMENT_VERSION_NOT_DRAFT. Not two publications, not
	 * a publication whose publisher is the loser, and not a deadlock.
	 */
	public void function testPublishVersusPublishReachesOneSerialOutcome() {
		var imported = variables.importSvc.importConfig(config(label("pub-pub")));
		var versionId = imported.versionId;
		var expectedSnapshot = variables.repo.findVersionById(versionId).snapshotJson;

		var barrier = newBarrier();
		var aRepo = intercept();
		var aPublish = publishServiceWith(aRepo);
		var bRepo = intercept();
		var bPublish = publishServiceWith(bRepo);
		announceBoundary(bRepo, barrier, "findVersionByIdForUpdate");

		var loser = variables.other;
		// The whole CFML suite runs inside one request, and a thread name must be unique within it.
		var threadName = uniqueThreadName();
		var joinedStatus = "";
		aRepo.armAfter("findVersionByIdForUpdate", function() {
			barrier.signal("A_LOCKED");
			thread name="#threadName#" svc=bPublish vid=versionId who=loser {
				try {
					attributes.svc.publish(attributes.vid, attributes.who);
					thread.outcome = "published";
				} catch (any e) {
					thread.outcome = structKeyExists(e, "errorcode") && len(e.errorcode) ? e.errorcode : e.type;
				}
			}
			assertTrue(barrier.await("B_AT_COMPETING_BOUNDARY", 60000), "the second publish announced that it had reached the competing row lock");
			// Supplemental only, and only now that B's arrival has been independently observed:
			// B is at the lock and therefore cannot have finished.
			threadJoin(threadName, 250);
			joinedStatus = cfthread[threadName].status;
		});

		var winner = aPublish.publish(versionId, variables.publisher);

		assertTrue(barrier.observed("A_LOCKED"), "the first publish really held the version row lock");
		assertTrue(barrier.observed("B_AT_COMPETING_BOUNDARY"), "and the second publish really reached the same lock");
		assertTrue(barrier.signalledInOrder("A_LOCKED", "B_AT_COMPETING_BOUNDARY"), "in that order: A held it before B arrived");
		assertExactTextNotEquals("COMPLETED", joinedStatus, "B was still queued on the lock while A held it");

		threadJoin(threadName, 60000);
		assertExactTextEquals("COMPLETED", cfthread[threadName].status, "the second publish ran once the lock was released");
		assertExactTextEquals("INSTRUMENT_VERSION_NOT_DRAFT", cfthread[threadName].outcome, "and found a version that was no longer a DRAFT");

		var row = variables.repo.findVersionById(versionId);
		assertExactTextEquals("PUBLISHED", row.status, "exactly one transition happened");
		assertExactTextEquals(variables.publisher, row.publishedByUserId, "and the publisher on the row is the one that won");
		assertExactTextEquals(winner.checksum, row.checksum, "the checksum is the winner's");
		assertExactTextEquals(expectedSnapshot, row.snapshotJson, "the frozen bytes are the ones the import compiled");
		assertEquals(1, auditCount(versionId, "INSTRUMENT_VERSION_PUBLISHED"), "one success event");
		assertEquals(1, auditCount(versionId, "INSTRUMENT_VERSION_PUBLISH_REFUSED"), "and one refusal event");

		var settled = variables.repo.findVersionById(versionId);
		assertRowVersionEquals(row.rowVersion, settled.rowVersion, "and nothing moved after the winner committed");
	}

	/**
	 * PUBLISH versus IMPORT. A re-import of the same version, started while a publish holds the
	 * version's row lock.
	 *
	 * The only permitted serial outcome: the publish completes, and the import then finds a
	 * PUBLISHED version and is refused with INSTRUMENT_VERSION_IMMUTABLE, having written nothing.
	 */
	public void function testPublishVersusImportReachesOneSerialOutcome() {
		var imported = variables.importSvc.importConfig(config(label("pub-imp")));
		var versionId = imported.versionId;

		var barrier = newBarrier();
		var aRepo = intercept();
		var aPublish = publishServiceWith(aRepo);
		var bRepo = intercept();
		var bImport = importServiceWith(bRepo);
		announceBoundary(bRepo, barrier, "findVersion");

		var reimport = config(label("pub-imp"));
		reimport.items[1].prompt = "A prompt a concurrent import must never land on a published version";
		var actor = variables.other;
		// The whole CFML suite runs inside one request, and a thread name must be unique within it.
		var threadName = uniqueThreadName();
		var joinedStatus = "";
		aRepo.armAfter("findVersionByIdForUpdate", function() {
			barrier.signal("A_LOCKED");
			thread name="#threadName#" svc=bImport cfg=reimport who=actor {
				try {
					attributes.svc.importConfig(attributes.cfg, attributes.who);
					thread.outcome = "imported";
				} catch (any e) {
					thread.outcome = structKeyExists(e, "errorcode") && len(e.errorcode) ? e.errorcode : e.type;
				}
			}
			assertTrue(barrier.await("B_AT_COMPETING_BOUNDARY", 60000), "the import announced that it had reached the version's row lock");
			threadJoin(threadName, 250);
			joinedStatus = cfthread[threadName].status;
		});

		var published = aPublish.publish(versionId, variables.publisher);

		assertTrue(barrier.signalledInOrder("A_LOCKED", "B_AT_COMPETING_BOUNDARY"), "the publish held the lock before the import reached it");
		assertExactTextNotEquals("COMPLETED", joinedStatus, "and the import was still queued there");

		threadJoin(threadName, 60000);
		assertExactTextEquals("COMPLETED", cfthread[threadName].status, "the import ran once the lock was released");
		assertExactTextEquals("INSTRUMENT_VERSION_IMMUTABLE", cfthread[threadName].outcome, "and was refused: the version was published by then");

		var row = variables.repo.findVersionById(versionId);
		assertExactTextEquals("PUBLISHED", row.status);
		assertExactTextEquals(published.checksum, row.checksum, "the frozen checksum is untouched");
		assertExactTextEquals(variables.publisher, row.publishedByUserId);
		assertEquals(0, variables.db.scalar(
			"SELECT COUNT(*) AS n FROM [icf].[item_definition] WHERE version_id = :id AND prompt = N'A prompt a concurrent import must never land on a published version'",
			{ "id": variables.db.guid(versionId) }
		), "and the concurrent import wrote nothing at all");
		assertEquals(1, auditCount(versionId, "INSTRUMENT_VERSION_PUBLISHED"), "one success event");
		assertEquals(1, auditCount(versionId, "INSTRUMENT_VERSION_WRITE_REFUSED"), "and the refused import left exactly one durable record");
		assertExactTextEquals(
			variables.c.snapshotCompiler.definitionsChecksum(deserializeJSON(row.snapshotJson).definitions),
			variables.c.snapshotCompiler.definitionsChecksum(variables.repo.loadNormalizedDefinitions(versionId)),
			"the published version's definitions still equal its frozen snapshot"
		);
	}

	/**
	 * The other direction, which is what a lock-order inversion would break: an import holds the
	 * version row and a publish arrives. One order, so it queues rather than deadlocking.
	 */
	public void function testImportVersusPublishQueuesRatherThanDeadlocking() {
		variables.importSvc.importConfig(config(label("imp-pub")));
		var versionId = versionIdFor(label("imp-pub"));

		var barrier = newBarrier();
		var aRepo = intercept();
		var aImport = importServiceWith(aRepo);
		var bRepo = intercept();
		var bPublish = publishServiceWith(bRepo);
		announceBoundary(bRepo, barrier, "findVersionByIdForUpdate");

		var who = variables.publisher;
		// The whole CFML suite runs inside one request, and a thread name must be unique within it.
		var threadName = uniqueThreadName();
		var joinedStatus = "";
		aRepo.armAfter("findVersion", function() {
			barrier.signal("A_LOCKED");
			thread name="#threadName#" svc=bPublish vid=versionId who=who {
				try {
					attributes.svc.publish(attributes.vid, attributes.who);
					thread.outcome = "published";
				} catch (any e) {
					thread.outcome = structKeyExists(e, "errorcode") && len(e.errorcode) ? e.errorcode : e.type;
				}
			}
			assertTrue(barrier.await("B_AT_COMPETING_BOUNDARY", 60000), "the publish announced that it had reached the version's row lock");
			threadJoin(threadName, 250);
			joinedStatus = cfthread[threadName].status;
		});

		var reimported = aImport.importConfig(config(label("imp-pub")), variables.other);

		assertTrue(barrier.signalledInOrder("A_LOCKED", "B_AT_COMPETING_BOUNDARY"), "the import held the version lock before the publish reached it");
		assertExactTextNotEquals("COMPLETED", joinedStatus, "and the publish queued rather than interleaving");

		threadJoin(threadName, 60000);
		assertExactTextEquals("COMPLETED", cfthread[threadName].status, "the publish ran once the import released the lock");
		assertExactTextEquals("published", cfthread[threadName].outcome, "and succeeded: the import left a valid DRAFT behind it");
		assertFalse(
			findNoCase("deadlock", toString(cfthread[threadName].outcome)) > 0,
			"neither side deadlocked: import and publish take the version row in the same order"
		);

		var row = variables.repo.findVersionById(versionId);
		assertExactTextEquals("PUBLISHED", row.status, "the serial order ended with the version published");
		assertExactTextEquals(reimported.checksum, row.checksum, "on the snapshot the import that went first had stored");
		assertEquals(1, auditCount(versionId, "INSTRUMENT_VERSION_PUBLISHED"), "exactly one publication");
	}

	/**
	 * PUBLISH versus a genuinely new GLOBAL DIMENSION IDENTITY.
	 *
	 * icf.dimension_definition is global: the row minted here is the reporting identity every
	 * future version of every instrument will point at, and it is minted on the authority of a
	 * DRAFT. So a caller must not be able to mint one against a version that is being frozen.
	 *
	 * The code raced for is one that has never existed, so this is a mint and not the reuse path
	 * a re-import takes.
	 */
	public void function testPublishVersusNewDimensionIdentityReachesOneSerialOutcome() {
		var imported = variables.importSvc.importConfig(config(label("pub-dim")));
		var versionId = imported.versionId;
		var probeCode = "barrier_dim_" & lCase(left(replace(createUUID(), "-", "", "all"), 10));
		arrayAppend(variables.mintedDimensionCodes, probeCode);
		var globalBefore = globalIdentityCounts();

		var barrier = newBarrier();
		var aRepo = intercept();
		var aPublish = publishServiceWith(aRepo);
		var bRepo = intercept();
		announceBoundary(bRepo, barrier, "createDimensionIdentity");

		var dimRow = { "code": probeCode, "label": "Barrier probe", "dataType": "LIST", "reportable": false, "sensitive": false, "settingsJson": "{}", "active": true };
		// The whole CFML suite runs inside one request, and a thread name must be unique within it.
		var threadName = uniqueThreadName();
		var joinedStatus = "";
		aRepo.armAfter("findVersionByIdForUpdate", function() {
			barrier.signal("A_LOCKED");
			thread name="#threadName#" repo=bRepo vid=versionId row=dimRow {
				try {
					thread.created = attributes.repo.createDimensionIdentity(attributes.vid, attributes.row);
					thread.outcome = "minted";
				} catch (any e) {
					thread.outcome = structKeyExists(e, "errorcode") && len(e.errorcode) ? e.errorcode : e.type;
				}
			}
			assertTrue(barrier.await("B_AT_COMPETING_BOUNDARY", 60000), "the identity creation announced that it had reached the version's row lock");
			threadJoin(threadName, 250);
			joinedStatus = cfthread[threadName].status;
		});

		aPublish.publish(versionId, variables.publisher);

		assertTrue(barrier.signalledInOrder("A_LOCKED", "B_AT_COMPETING_BOUNDARY"), "the publish held the version lock before the mint reached it");
		assertExactTextNotEquals("COMPLETED", joinedStatus, "and the mint queued on it");

		threadJoin(threadName, 60000);
		assertExactTextEquals("COMPLETED", cfthread[threadName].status, "the mint ran once the lock was released");
		assertExactTextEquals("INSTRUMENT_VERSION_NOT_DRAFT", cfthread[threadName].outcome, "publish won, so the mint was refused: its authority was a version that is now frozen");

		assertExactTextEquals("PUBLISHED", variables.repo.findVersionById(versionId).status);
		assertEquals(0, variables.db.scalar(
			"SELECT COUNT(*) AS n FROM [icf].[dimension_definition] WHERE code = :code",
			{ "code": variables.db.nvarchar(probeCode, 100) }
		), "no global dimension identity appeared");
		assertExactJsonEquals(globalBefore, globalIdentityCounts(), "and the global identity tables are exactly as they were");
	}

	/** The same, for a genuinely new global dimension-VALUE identity. */
	public void function testPublishVersusNewDimensionValueIdentityReachesOneSerialOutcome() {
		var imported = variables.importSvc.importConfig(config(label("pub-dimval")));
		var versionId = imported.versionId;
		// A dimension this fixture already has, so only the value identity is new.
		var dimensionId = anyDimensionIdOf(versionId);
		var probeValue = "barrier_val_" & lCase(left(replace(createUUID(), "-", "", "all"), 10));
		var globalBefore = globalIdentityCounts();

		var barrier = newBarrier();
		var aRepo = intercept();
		var aPublish = publishServiceWith(aRepo);
		var bRepo = intercept();
		announceBoundary(bRepo, barrier, "createDimensionValueIdentity");

		var valueRow = { "valueCode": probeValue, "label": "Barrier probe value", "active": true };
		// The whole CFML suite runs inside one request, and a thread name must be unique within it.
		var threadName = uniqueThreadName();
		var joinedStatus = "";
		aRepo.armAfter("findVersionByIdForUpdate", function() {
			barrier.signal("A_LOCKED");
			thread name="#threadName#" repo=bRepo vid=versionId dim=dimensionId row=valueRow {
				try {
					thread.created = attributes.repo.createDimensionValueIdentity(attributes.vid, attributes.dim, attributes.row);
					thread.outcome = "minted";
				} catch (any e) {
					thread.outcome = structKeyExists(e, "errorcode") && len(e.errorcode) ? e.errorcode : e.type;
				}
			}
			assertTrue(barrier.await("B_AT_COMPETING_BOUNDARY", 60000), "the value mint announced that it had reached the version's row lock");
			threadJoin(threadName, 250);
			joinedStatus = cfthread[threadName].status;
		});

		aPublish.publish(versionId, variables.publisher);

		assertTrue(barrier.signalledInOrder("A_LOCKED", "B_AT_COMPETING_BOUNDARY"), "the publish held the version lock before the value mint reached it");
		assertExactTextNotEquals("COMPLETED", joinedStatus, "and the value mint queued on it");

		threadJoin(threadName, 60000);
		assertExactTextEquals("COMPLETED", cfthread[threadName].status, "the value mint ran once the lock was released");
		assertExactTextEquals("INSTRUMENT_VERSION_NOT_DRAFT", cfthread[threadName].outcome, "publish won, so the value mint was refused");

		assertExactTextEquals("PUBLISHED", variables.repo.findVersionById(versionId).status);
		assertEquals(0, variables.db.scalar(
			"SELECT COUNT(*) AS n FROM [icf].[dimension_value] WHERE value_code = :code",
			{ "code": variables.db.nvarchar(probeValue, 100) }
		), "no global dimension-value identity appeared");
		assertExactJsonEquals(globalBefore, globalIdentityCounts(), "and the global identity tables are exactly as they were");
	}

	// ---- helpers ---------------------------------------------------------------------------------

	/** A thread name that is unique inside the single request the whole CFML suite runs in. */
	private string function uniqueThreadName() {
		return "barrierB" & lCase(left(replace(createUUID(), "-", "", "all"), 10));
	}

	private any function newBarrier() {
		return createObject("component", "icfwalktests.support.ConcurrencyBarrier").init();
	}

	private any function intercept() {
		return createObject("component", "icfwalktests.support.InterceptingDefinitionRepository").init(variables.repo);
	}

	/**
	 * Arms B's decorated repository to announce B_AT_COMPETING_BOUNDARY immediately before the
	 * statement that will contend for A's lock. This is the half the previous form of this spec
	 * did not have, and it is what turns "B has not finished" into "B is at the lock".
	 */
	private void function announceBoundary(required any repository, required any barrier, required string seam) {
		var b = arguments.barrier;
		arguments.repository.armBefore(arguments.seam, function() { b.signalOnce("B_AT_COMPETING_BOUNDARY"); });
	}

	/** A real publish service whose only difference is the decorated repository. */
	private any function publishServiceWith(required any repository) {
		return createObject("component", "icfwalk.instrument.InstrumentPublishService").init(
			variables.c.config, variables.c.db, variables.c.errors, variables.c.logger,
			arguments.repository, variables.c.auditRepository, variables.c.canonicalJson,
			variables.c.snapshotCompiler, variables.c.definitionValidator, variables.c.renderContractValidator
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

	private string function versionIdFor(required string versionLabel) {
		var q = variables.db.run(
			"SELECT v.version_id FROM [icf].[instrument_version] v JOIN [icf].[instrument] i ON i.instrument_id = v.instrument_id
			  WHERE i.code = :code AND v.version_label = :label",
			{ "code": variables.db.nvarchar(variables.instrumentCode, 60), "label": variables.db.nvarchar(arguments.versionLabel, 100) }
		);
		return uCase(q.version_id[1]);
	}

	private string function anyDimensionIdOf(required string versionId) {
		var q = variables.db.run(
			"SELECT TOP (1) dimension_id FROM [icf].[instrument_dimension] WHERE version_id = :id ORDER BY display_order",
			{ "id": variables.db.guid(arguments.versionId) }
		);
		return uCase(q.dimension_id[1]);
	}

	/** The size of both global identity tables, so a refusal can be shown to have added nothing. */
	private struct function globalIdentityCounts() {
		return {
			"dimensions": variables.db.scalar("SELECT COUNT(*) AS n FROM [icf].[dimension_definition]"),
			"values": variables.db.scalar("SELECT COUNT(*) AS n FROM [icf].[dimension_value]")
		};
	}

	private numeric function auditCount(required string versionId, required string eventType) {
		return variables.db.scalar(
			"SELECT COUNT(*) AS n FROM [icf].[audit_event] WHERE entity_id = :id AND event_type = :t",
			{ "id": variables.db.guid(arguments.versionId), "t": variables.db.nvarchar(arguments.eventType) }
		);
	}
}
