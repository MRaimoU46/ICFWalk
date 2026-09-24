/**
 * Retirement against walk creation (Phase 6, ADM-07: "no new walks use it").
 *
 * THE RACE. WalkService.create asks SnapshotService.currentVersion() which version a new walk should
 * use, does its validation, and only then inserts the walk row pinned to that version. A retirement
 * that commits in between would leave a brand-new walk pinned to a version that is no longer in
 * service -- exactly what retiring it was meant to prevent, and invisible afterwards, because the
 * walk looks like any historical walk of the retired version.
 *
 * THE CORRECTION, AND WHAT IS PROVED HERE. WalkRepository.insertWalk inserts only while the version
 * is not RETIRED, reading the version row under a shared lock it keeps until the walk commits. So
 * exactly two serial outcomes exist, and both are forced here rather than raced:
 *
 *   1. RETIREMENT FIRST. The retirement runs to completion inside creation's window -- after
 *      currentVersion() chose the version, before the insert -- and the insert then matches
 *      nothing: the create is refused 409 INSTRUMENT_VERSION_CHANGED and no walk row exists. The
 *      client's retry would then pick up the successor.
 *
 *   2. WALK FIRST. The walk has been inserted and its transaction still holds the version row when
 *      the retirement arrives. The retirement announces B_AT_COMPETING_BOUNDARY immediately before
 *      its status transition and queues there; the spec releases the walk only after hearing it.
 *      The walk commits, then the retirement does -- so the walk was created while the version was
 *      in service, and it is an ordinary historical walk of the retired version.
 *
 * The two-sided barrier is the one PublishConcurrencyBarrierTest uses: nothing here infers an
 * arrival from a timeout, and every interception component is test-only.
 */
component extends="icfwalktests.BaseSpec" output="false" {

	public string function skipReason() {
		return schemaPresent() ? "" : "icf schema is not present in datasource '" & variables.c.db.datasourceName() & "'.";
	}

	public void function beforeAll() {
		variables.run = "rcb-" & lCase(left(replace(createUUID(), "-", "", "all"), 8));
		variables.db = variables.c.db;
		variables.repo = variables.c.definitionRepository;
		variables.cleanup = new icfwalktests.support.FixtureCleanup(variables.c);
		variables.adminId = variables.cleanup.ensureUser(variables.run & "-admin", "Retirement barrier administrator");
		variables.fx = createObject("component", "icfwalktests.support.Fixtures").init(variables.c, variables.run);
		variables.district = variables.fx.orgUnit("d", "DISTRICT");
		variables.school = variables.fx.orgUnit("s", "SCHOOL", variables.district);
		variables.walker = variables.fx.user("walker");
		variables.fx.assign(variables.walker.userId, "SCHOOL_WALK_REPORT", variables.school, false);
		variables.codes = [];
	}

	public void function afterAll() {
		variables.fx.remove();
		for (var code in variables.codes) variables.cleanup.removeInstrumentsCoded(code);
		variables.cleanup.removeUsers(variables.run & "-");
	}

	/**
	 * RETIREMENT FIRST: it commits inside creation's window, and the walk is refused rather than
	 * pinned to a version that is no longer in service.
	 */
	public void function testARetirementInsideCreationsWindowRefusesTheWalk() {
		var setup = twoPublishedVersions("first");
		var walksRepo = createObject("component", "icfwalktests.support.InterceptingWalkRepository").init(variables.c.walkRepository);
		var walks = walkService(setup.code, walksRepo);
		var publish = variables.c.instrumentPublishService;
		var retiring = setup.current;
		var actor = variables.adminId;
		var retiredInWindow = false;
		walksRepo.arm("insertWalk", function() {
			// currentVersion() has chosen `retiring`; the insert has not happened yet.
			publish.retire(retiring, actor);
			retiredInWindow = true;
		});

		var p = principal();
		var unit = variables.school;
		var mutation = variables.db.newGuid();
		assertThrows(function() { walks.create(p, { "orgUnitId": unit, "clientMutationId": mutation }); }, "ICFWalk.Conflict", "INSTRUMENT_VERSION_CHANGED");

		assertTrue(retiredInWindow, "the retirement really committed between the version choice and the insert");
		assertExactTextEquals("RETIRED", variables.repo.findVersionById(retiring).status);
		assertEquals(0, walksOn(retiring), "no walk was pinned to the version retired inside the window");

		// The client's retry uses the version that is now current.
		var retried = walks.create(p, { "orgUnitId": unit, "clientMutationId": variables.db.newGuid() });
		assertExactTextEquals(setup.successor, retried.versionId, "a retry is pinned to the successor");
	}

	/**
	 * WALK FIRST: the walk holds the version row, the retirement queues behind it, and the result is
	 * an ordinary historical walk of the retired version.
	 */
	public void function testARetirementQueuesBehindAWalkAlreadyPinnedToTheVersion() {
		var setup = twoPublishedVersions("second");
		var barrier = createObject("component", "icfwalktests.support.ConcurrencyBarrier").init();
		var walksRepo = createObject("component", "icfwalktests.support.InterceptingWalkRepository").init(variables.c.walkRepository);
		var walks = walkService(setup.code, walksRepo);
		var bRepo = createObject("component", "icfwalktests.support.InterceptingDefinitionRepository").init(variables.repo);
		var bPublish = publishServiceWith(bRepo);
		bRepo.armBefore("markRetired", function() { barrier.signalOnce("B_AT_COMPETING_BOUNDARY"); });

		var retiring = setup.current;
		var actor = variables.adminId;
		var threadName = "retireB" & lCase(left(replace(createUUID(), "-", "", "all"), 10));
		var reached = false;
		var joinedStatus = "";
		walksRepo.arm("afterInsertWalk", function() {
			barrier.signal("A_LOCKED");
			thread name="#threadName#" svc=bPublish vid=retiring who=actor {
				try {
					attributes.svc.retire(attributes.vid, attributes.who);
					thread.outcome = "retired";
				} catch (any e) {
					thread.outcome = structKeyExists(e, "errorcode") && len(e.errorcode) && e.errorcode != "0" ? e.errorcode : e.type;
					thread.detail = left(e.message, 300);
				}
			}
			reached = barrier.await("B_AT_COMPETING_BOUNDARY", 60000);
			threadJoin(threadName, 250);
			joinedStatus = cfthread[threadName].status;
		});

		var created = walks.create(principal(), { "orgUnitId": variables.school, "clientMutationId": variables.db.newGuid() });
		threadJoin(threadName, 60000);

		assertExactTextEquals(retiring, created.versionId, "the walk was pinned to the version while it was in service");
		assertExactTextEquals("COMPLETED", cfthread[threadName].status, "the retirement finished once the walk committed");
		assertExactTextEquals("retired", cfthread[threadName].outcome, "and succeeded" & (structKeyExists(cfthread[threadName], "detail") ? " (retirement failed: " & cfthread[threadName].detail & ")" : ""));
		assertExactTextEquals("RETIRED", variables.repo.findVersionById(retiring).status);

		assertTrue(barrier.observed("A_LOCKED"), "the walk really held the version row");
		assertTrue(reached, "the retirement announced that it had reached its status transition");
		assertTrue(barrier.signalledInOrder("A_LOCKED", "B_AT_COMPETING_BOUNDARY"), "in that order");
		assertExactTextNotEquals("COMPLETED", joinedStatus, "and was still queued there while the walk held the row");

		// Serial order on the record: the walk was created before the version was retired.
		var createdEvent = eventId("WALK", created.id, "WALK_CREATED");
		var retiredEvent = eventId("INSTRUMENT_VERSION", retiring, "INSTRUMENT_VERSION_RETIRED");
		assertTrue(createdEvent > 0 && retiredEvent > createdEvent, "the walk's creation precedes the retirement");
		assertEquals(1, walksOn(retiring), "one historical walk of the retired version");
	}

	/**
	 * TWO RETIREMENTS AT ONCE. V0 and V1 are both in service. Administrator A retires V1 and has
	 * just established that V0 will still serve new walks; administrator B retires V0 at the same
	 * moment. Each alone is allowed. Together, without confirmation, they must not leave the
	 * instrument with nothing in service -- which is exactly what happens if B can decide "V1 is
	 * still in service" before A's retirement of V1 commits.
	 *
	 * The correction serializes retirements of one instrument (DefinitionRepository.lockRetirement,
	 * taken after the version lock and before the successor check). B announces
	 * B_AT_COMPETING_BOUNDARY immediately before asking for it and queues there; A is released only
	 * after that; B then sees V1 retired and is refused RETIRE_LEAVES_NO_CURRENT_VERSION.
	 *
	 * Against code without the lock, B never reaches that boundary: it runs to completion while A
	 * waits, and the spec fails on the state -- both versions retired -- not on a timeout.
	 */
	public void function testTwoRetirementsCannotTogetherLeaveNothingInService() {
		var setup = twoPublishedVersions("pair");
		var barrier = createObject("component", "icfwalktests.support.ConcurrencyBarrier").init();
		var aRepo = createObject("component", "icfwalktests.support.InterceptingDefinitionRepository").init(variables.repo);
		var bRepo = createObject("component", "icfwalktests.support.InterceptingDefinitionRepository").init(variables.repo);
		var aPublish = publishServiceWith(aRepo);
		var bPublish = publishServiceWith(bRepo);
		bRepo.armBefore("lockRetirement", function() { barrier.signalOnce("B_AT_COMPETING_BOUNDARY"); });

		var aVersion = setup.current;
		var bVersion = setup.successor;
		var actor = variables.adminId;
		var threadName = "retirePair" & lCase(left(replace(createUUID(), "-", "", "all"), 10));
		var reached = false;
		var joinedStatus = "";
		aRepo.armAfter("findCurrentVersionExcluding", function() {
			// A holds V1's row (and, corrected, the instrument's retirement lock) and has found V0.
			barrier.signal("A_LOCKED");
			thread name="#threadName#" svc=bPublish vid=bVersion who=actor {
				try {
					attributes.svc.retire(attributes.vid, attributes.who);
					thread.outcome = "retired";
				} catch (any e) {
					thread.outcome = structKeyExists(e, "errorcode") && len(e.errorcode) && e.errorcode != "0" ? e.errorcode : e.type;
					thread.detail = left(e.message, 300);
				}
			}
			// Wait for B to arrive at its competing boundary -- or, against code that has none, to
			// finish without ever arriving. Either is an observation, not a guess from a timeout.
			var deadline = getTickCount() + 60000;
			while (!reached && getTickCount() < deadline) {
				reached = barrier.await("B_AT_COMPETING_BOUNDARY", 250);
				if (!reached && cfthread[threadName].status == "COMPLETED") break;
			}
			threadJoin(threadName, 250);
			joinedStatus = cfthread[threadName].status;
		});

		var a = aPublish.retire(aVersion, actor);
		threadJoin(threadName, 60000);

		assertExactTextEquals("RETIRED", a.status, "A's retirement succeeded");
		assertExactTextEquals("PUBLISHED", variables.repo.findVersionById(bVersion).status, "V0 is still in service: the two retirements did not together leave nothing");
		assertExactTextEquals("RETIRE_LEAVES_NO_CURRENT_VERSION", cfthread[threadName].outcome, "B was refused once it saw V1 retired" & (structKeyExists(cfthread[threadName], "detail") ? " (" & cfthread[threadName].detail & ")" : ""));
		var current = variables.repo.currentVersionIds();
		assertTrue(structKeyExists(current, bVersion), "V0 is the version new walks now start on");

		assertTrue(barrier.observed("A_LOCKED"), "A really held its lock and had chosen its successor");
		assertTrue(reached, "B announced that it had reached the retirement lock");
		assertTrue(barrier.signalledInOrder("A_LOCKED", "B_AT_COMPETING_BOUNDARY"), "in that order");
		assertExactTextNotEquals("COMPLETED", joinedStatus, "and was still queued there while A held it");
	}

	// ---- helpers ---------------------------------------------------------------------------------

	/** V0 then V1 published under a fresh instrument: V1 is current and V0 its successor. */
	private struct function twoPublishedVersions(required string tag) {
		var code = "RCB" & uCase(left(replace(createUUID(), "-", "", "all"), 9));
		arrayAppend(variables.codes, code);
		var import = variables.c.instrumentImportService;
		var publish = variables.c.instrumentPublishService;
		var v0 = import.importConfig(configFor(code, variables.run & "-" & arguments.tag & "-v0"), variables.adminId);
		publish.publish(v0.versionId, variables.adminId);
		// A later effective start, so V1 is unambiguously the current version.
		sleep(20);
		var v1 = import.importConfig(configFor(code, variables.run & "-" & arguments.tag & "-v1"), variables.adminId);
		publish.publish(v1.versionId, variables.adminId);
		var current = variables.repo.currentVersionIds();
		assertTrue(structKeyExists(current, v1.versionId), "precondition: V1 is the current version");
		return { "code": code, "current": v1.versionId, "successor": v0.versionId };
	}

	private any function walkService(required string code, required any walkRepository) {
		var cfg = duplicate(variables.c.config);
		cfg.instrumentCode = arguments.code;
		cfg.allowUnpublishedInstrument = false;
		var snap = createObject("component", "icfwalk.instrument.SnapshotService").init(
			cfg, variables.c.db, variables.c.definitionRepository, variables.c.renderModelBuilder, variables.c.errors, variables.c.logger, variables.c.canonicalJson
		);
		return createObject("component", "icfwalk.walks.WalkService").init(
			cfg, variables.c.db, variables.c.errors, variables.c.logger, variables.c.auditRepository,
			variables.c.canonicalJson, variables.c.authorizationService, snap,
			variables.c.visibilityEngine, arguments.walkRepository, variables.c.walkPayloadValidator, variables.c.orgUnitRepository,
			variables.c.walkSummaryFormatter
		);
	}

	private any function publishServiceWith(required any repository) {
		return createObject("component", "icfwalk.instrument.InstrumentPublishService").init(
			variables.c.config, variables.c.db, variables.c.errors, variables.c.logger,
			arguments.repository, variables.c.auditRepository, variables.c.canonicalJson,
			variables.c.snapshotCompiler, variables.c.definitionValidator, variables.c.renderContractValidator
		);
	}

	private struct function principal() { return variables.fx.principal(variables.walker.userId); }

	private struct function configFor(required string code, required string versionLabel) {
		var cfg = repoJson("config/instrument-config.json");
		cfg.instrument.code = arguments.code;
		cfg.instrument.version.versionLabel = arguments.versionLabel;
		return cfg;
	}

	private numeric function walksOn(required string versionId) {
		return variables.db.scalar("SELECT COUNT(*) AS n FROM [icf].[walk] WHERE version_id = :id", { "id": variables.db.guid(arguments.versionId) });
	}

	private numeric function eventId(required string entityType, required string entityId, required string eventType) {
		return variables.db.scalar(
			"SELECT MAX(event_id) AS n FROM [icf].[audit_event] WHERE entity_type = :et AND entity_id = :id AND event_type = :t",
			{ "et": variables.db.nvarchar(arguments.entityType), "id": variables.db.guid(arguments.entityId), "t": variables.db.nvarchar(arguments.eventType) }
		);
	}
}
