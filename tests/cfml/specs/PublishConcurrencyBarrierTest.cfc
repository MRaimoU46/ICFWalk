/**
 * Deterministic proof that publication serializes against a concurrent publish and against a
 * concurrent definition write -- not because a race happened to come out right, but because the
 * intended interleaving was forced and observed.
 *
 * WHAT THE STRESS TESTS COULD NOT SHOW. tests/node/admin-publish.test.mjs races two publishes with
 * Promise.all, repeatedly, and asserts that exactly one wins. That is worth having and it stays.
 * What it cannot establish is that the two requests ever overlapped: it passes identically against
 * an implementation whose lock does nothing, on any run where the first transaction happened to
 * commit before the second began. Timing is not evidence.
 *
 * THE BARRIER. support/InterceptingDefinitionRepository fires a callback immediately after the
 * statement that takes the version's row lock -- findVersionByIdForUpdate for publishing,
 * findVersion(lock = true) for importing. Each case below therefore runs to this shape:
 *
 *   1. Transaction A starts and takes the lock. The callback fires with A holding it and having
 *      done nothing else.
 *   2. Inside the callback, transaction B starts on its own thread against the real service, and
 *      is joined with a bounded wait. B does not finish. That is the observable signal that B
 *      reached the competing boundary and is queued there -- an unobstructed B takes a small
 *      fraction of that wait, so the only thing that can still be holding it is the lock.
 *   3. The callback returns, A carries on and commits: the lock is released by A finishing, at a
 *      point the spec chose, not by a sleep.
 *   4. B is joined again and its outcome is asserted, along with the final database state: one
 *      transition, the right audit counts, and a snapshot, checksum, publisher and row version
 *      that are exactly what the winner wrote.
 *
 * No sleep is used as proof anywhere here. The bounded joins are generous upper bounds on an
 * unobstructed operation; the assertions are about which operations completed and what they left
 * behind.
 *
 * NO PRODUCTION SEAM. The decorator is a test-only component, constructed here and handed to a
 * service constructed here. The application container never holds it and no route reaches it, so
 * there is no configuration in which a client can activate a lock hook.
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
	}

	public void function afterAll() {
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

		var interceptor = createObject("component", "icfwalktests.support.InterceptingDefinitionRepository").init(variables.repo);
		var barriered = publishServiceWith(interceptor);

		var realSvc = variables.publishSvc;
		var loser = variables.other;
		var joinedStatus = "";
		interceptor.armAfter("findVersionByIdForUpdate", function() {
			thread name="barrierSecondPublish" svc=realSvc vid=versionId who=loser {
				try {
					attributes.svc.publish(attributes.vid, attributes.who);
					thread.outcome = "published";
				} catch (any e) {
					thread.outcome = structKeyExists(e, "errorcode") && len(e.errorcode) ? e.errorcode : e.type;
				}
			}
			// Generous: an unobstructed publish of this version takes a small fraction of this. It
			// can only still be running because something is making it wait.
			threadJoin("barrierSecondPublish", 6000);
			joinedStatus = cfthread.barrierSecondPublish.status;
		});

		var winner = barriered.publish(versionId, variables.publisher);

		assertTrue(interceptor.fired("findVersionByIdForUpdate"), "the second publish really was started while the first held the lock");
		assertNotEquals("COMPLETED", joinedStatus, "and it could not proceed inside the first transaction: the row lock held it");

		threadJoin("barrierSecondPublish", 30000);
		assertEquals("COMPLETED", cfthread.barrierSecondPublish.status, "the second publish ran once the lock was released");
		assertEquals("INSTRUMENT_VERSION_NOT_DRAFT", cfthread.barrierSecondPublish.outcome, "and found a version that was no longer a DRAFT");

		var row = variables.repo.findVersionById(versionId);
		assertEquals("PUBLISHED", row.status, "exactly one transition happened");
		assertEquals(variables.publisher, row.publishedByUserId, "and the publisher on the row is the one that won");
		assertEquals(winner.checksum, row.checksum, "the checksum is the winner's");
		assertEquals(expectedSnapshot, row.snapshotJson, "the frozen bytes are the ones the import compiled");
		assertEquals(1, auditCount(versionId, "INSTRUMENT_VERSION_PUBLISHED"), "one success event");
		assertEquals(1, auditCount(versionId, "INSTRUMENT_VERSION_PUBLISH_REFUSED"), "and one refusal event");

		// The loser changed nothing after the fact: the row is still exactly what the winner left.
		var settled = variables.repo.findVersionById(versionId);
		assertEquals(row.rowVersion, settled.rowVersion, "and nothing moved after the winner committed");
	}

	/**
	 * PUBLISH versus IMPORT. A re-import of the same version, started while a publish holds the
	 * version's row lock.
	 *
	 * The only permitted serial outcome: the publish completes, and the import then finds a
	 * PUBLISHED version and is refused with INSTRUMENT_VERSION_IMMUTABLE, having written nothing.
	 * A published version's definitions must be exactly what was frozen.
	 */
	public void function testPublishVersusImportReachesOneSerialOutcome() {
		var imported = variables.importSvc.importConfig(config(label("pub-imp")));
		var versionId = imported.versionId;

		var interceptor = createObject("component", "icfwalktests.support.InterceptingDefinitionRepository").init(variables.repo);
		var barriered = publishServiceWith(interceptor);

		var realImport = variables.importSvc;
		var reimport = config(label("pub-imp"));
		reimport.items[1].prompt = "A prompt a concurrent import must never land on a published version";
		var actor = variables.other;
		var joinedStatus = "";
		interceptor.armAfter("findVersionByIdForUpdate", function() {
			thread name="barrierConcurrentImport" svc=realImport cfg=reimport who=actor {
				try {
					attributes.svc.importConfig(attributes.cfg, attributes.who);
					thread.outcome = "imported";
				} catch (any e) {
					thread.outcome = structKeyExists(e, "errorcode") && len(e.errorcode) ? e.errorcode : e.type;
				}
			}
			threadJoin("barrierConcurrentImport", 6000);
			joinedStatus = cfthread.barrierConcurrentImport.status;
		});

		var published = barriered.publish(versionId, variables.publisher);

		assertTrue(interceptor.fired("findVersionByIdForUpdate"), "the import really was started while the publish held the lock");
		assertNotEquals("COMPLETED", joinedStatus, "and it could not proceed inside the publish transaction");

		threadJoin("barrierConcurrentImport", 30000);
		assertEquals("COMPLETED", cfthread.barrierConcurrentImport.status, "the import ran once the lock was released");
		assertEquals("INSTRUMENT_VERSION_IMMUTABLE", cfthread.barrierConcurrentImport.outcome, "and was refused: the version was published by then");

		var row = variables.repo.findVersionById(versionId);
		assertEquals("PUBLISHED", row.status);
		assertEquals(published.checksum, row.checksum, "the frozen checksum is untouched");
		assertEquals(variables.publisher, row.publishedByUserId);
		assertEquals(0, variables.db.scalar(
			"SELECT COUNT(*) AS n FROM [icf].[item_definition] WHERE version_id = :id AND prompt = N'A prompt a concurrent import must never land on a published version'",
			{ "id": variables.db.guid(versionId) }
		), "and the concurrent import wrote nothing at all");
		assertEquals(1, auditCount(versionId, "INSTRUMENT_VERSION_PUBLISHED"), "one success event");
		assertEquals(1, auditCount(versionId, "INSTRUMENT_VERSION_WRITE_REFUSED"), "and the refused import left exactly one durable record");
		assertEquals(
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
		var versionId = variables.db.run(
			"SELECT v.version_id FROM [icf].[instrument_version] v JOIN [icf].[instrument] i ON i.instrument_id = v.instrument_id
			  WHERE i.code = :code AND v.version_label = :label",
			{ "code": variables.db.nvarchar(variables.instrumentCode, 60), "label": variables.db.nvarchar(label("imp-pub"), 100) }
		).version_id[1];
		versionId = uCase(versionId);

		var interceptor = createObject("component", "icfwalktests.support.InterceptingDefinitionRepository").init(variables.repo);
		var barrieredImport = importServiceWith(interceptor);

		var realPublish = variables.publishSvc;
		var who = variables.publisher;
		var joinedStatus = "";
		interceptor.armAfter("findVersion", function() {
			thread name="barrierConcurrentPublish" svc=realPublish vid=versionId who=who {
				try {
					attributes.svc.publish(attributes.vid, attributes.who);
					thread.outcome = "published";
				} catch (any e) {
					thread.outcome = structKeyExists(e, "errorcode") && len(e.errorcode) ? e.errorcode : e.type;
				}
			}
			threadJoin("barrierConcurrentPublish", 6000);
			joinedStatus = cfthread.barrierConcurrentPublish.status;
		});

		var reimported = barrieredImport.importConfig(config(label("imp-pub")), variables.other);

		assertTrue(interceptor.fired("findVersion"), "the publish really was started while the import held the version lock");
		assertNotEquals("COMPLETED", joinedStatus, "and it queued rather than interleaving");

		threadJoin("barrierConcurrentPublish", 30000);
		assertEquals("COMPLETED", cfthread.barrierConcurrentPublish.status, "the publish ran once the import released the lock");
		assertEquals("published", cfthread.barrierConcurrentPublish.outcome, "and succeeded: the import left a valid DRAFT behind it");
		assertFalse(
			findNoCase("deadlock", toString(cfthread.barrierConcurrentPublish.outcome)) > 0,
			"neither side deadlocked: import and publish take the version row in the same order"
		);

		var row = variables.repo.findVersionById(versionId);
		assertEquals("PUBLISHED", row.status, "the serial order ended with the version published");
		assertEquals(reimported.checksum, row.checksum, "on the snapshot the import that went first had stored");
		assertEquals(1, auditCount(versionId, "INSTRUMENT_VERSION_PUBLISHED"), "exactly one publication");
	}

	// ---- helpers ---------------------------------------------------------------------------------

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

	private numeric function auditCount(required string versionId, required string eventType) {
		return variables.db.scalar(
			"SELECT COUNT(*) AS n FROM [icf].[audit_event] WHERE entity_id = :id AND event_type = :t",
			{ "id": variables.db.guid(arguments.versionId), "t": variables.db.nvarchar(arguments.eventType) }
		);
	}
}
