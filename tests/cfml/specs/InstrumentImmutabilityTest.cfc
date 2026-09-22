/**
 * ADM-05, at the write boundary rather than at a guard.
 *
 * WHAT WENT WRONG BEFORE. Immutability used to be a helper -- assertDraftForWrite -- that no
 * production mutator called. Calling the helper and watching it throw proved that the helper
 * throws; it proved nothing about whether a published version could be overwritten, because every
 * repository method would still have written happily if asked. The boundary has to be structural,
 * and a test of it has to be a real write attempt against real frozen data.
 *
 * SO THIS SPEC CALLS THE MUTATORS. Every public production method that writes version content is
 * invoked against a PUBLISHED fixture and against a RETIRED one -- inserts, updates, deletes,
 * snapshot replacement, order parking, placement and dimension-value replacement, and the whole
 * cascade delete -- and each must refuse. After every attempt the version's definitions checksum
 * and every child table's row_version are compared with what they were before: a refused write
 * changes no data and moves no row.
 *
 * AND IT PROVES THE INVENTORY. testEveryRepositoryMutatorIsCoveredHere reads the repository's own
 * metadata and fails if a mutating method exists that this spec does not exercise. A future method
 * that forgets the boundary cannot pass unnoticed by simply not being listed here.
 *
 * The durable-refusal cases at the end go through the real application services, not the
 * repository, because that is where the rollback happens and therefore where an audit written
 * inside the transaction would disappear.
 */
component extends="icfwalktests.BaseSpec" output="false" {

	/**
	 * THE INVENTORY IS NOW EXHAUSTIVE, AND NOTHING IS EXCLUDED FROM IT BY ASSERTION.
	 *
	 * It used to carry a NOT_VERSION_CONTENT list -- createInstrument, updateInstrument,
	 * createDimensionIdentity, createDimensionValueIdentity -- whose members were skipped on the
	 * grounds that they write shared or global rows rather than version content. That reasoning
	 * was wrong twice over. They are real public production writes, so "not version content" is a
	 * statement about which contract applies, not a reason to test nothing. And one of them,
	 * updateInstrument, was exactly where the damage was: icf.instrument.active is part of the
	 * runtime's current-version predicate, so an ordinary DRAFT import could make an already
	 * PUBLISHED version disappear -- through a method the inventory had declared out of scope.
	 *
	 * So every public mutator is now in one of the two lists below and is exercised against its
	 * real ownership contract:
	 *
	 *   VERSION_OWNED    writes a version's own content. Contract: refused unless the owning
	 *                    version is a DRAFT, under that version's row lock.
	 *   SHARED_OR_GLOBAL writes icf.instrument or the global reporting-identity rows. Contract:
	 *                    named per method in testEverySharedOrGlobalMutatorEnforcesItsOwnContract.
	 *
	 * NOT_A_WRITE holds the one public method whose name matches the write-detecting pattern and
	 * which writes nothing at all.
	 */
	variables.NOT_A_WRITE = {
		"parkOffset": "returns the parking constant; executes no statement"
	};

	variables.SHARED_OR_GLOBAL = [
		"createInstrument", "updateInstrumentMetadata", "createDraftVersion",
		"createDimensionIdentity", "createDimensionValueIdentity"
	];

	public string function skipReason() {
		return schemaPresent() ? "" : "icf schema is not present in datasource '" & variables.c.db.datasourceName() & "'.";
	}

	public void function beforeAll() {
		variables.run = "imm-" & lCase(left(replace(createUUID(), "-", "", "all"), 8));
		// Its own instrument, for the same reason the publish spec has one: a frozen fixture must
		// never be a candidate for the ICFWalk instrument's current version.
		variables.instrumentCode = "IMMFIX" & uCase(left(replace(createUUID(), "-", "", "all"), 8));
		variables.db = variables.c.db;
		variables.repo = variables.c.definitionRepository;
		variables.importSvc = variables.c.instrumentImportService;
		variables.publishSvc = variables.c.instrumentPublishService;
		variables.fixtures = new icfwalktests.support.FixtureCleanup(variables.c);
		variables.publisher = variables.fixtures.ensureUser(variables.run & "-publisher", "Immutability fixture publisher");

		variables.published = freeze("published", "PUBLISHED");
		variables.retired = freeze("retired", "RETIRED");
		// A DRAFT of the same content, so every mutator can be shown to work when it should.
		variables.draftImport = variables.importSvc.importConfig(config(label("draft")));
		variables.draft = handles(variables.draftImport.versionId);

		// Which version-content mutators this spec exercises. Read by the inventory test.
		variables.covered = [
			"storeSnapshot", "markPublished", "parkVersionOrders",
			"insertSection", "updateSectionContent", "placeSection", "deleteSections",
			"upsertResponseSet", "deleteResponseSet", "upsertOption", "deleteOption",
			"upsertRule", "deleteRule", "upsertItem", "deleteItem",
			"upsertPlacement", "replaceVersionDimensionValues", "deletePlacement",
			"deleteDraftVersionCascade"
		];
	}

	public void function afterAll() {
		variables.fixtures.removeInstrumentsCoded(variables.instrumentCode);
		variables.fixtures.removeUsers(variables.run & "-");
	}

	// ---- the inventory ---------------------------------------------------------------------------

	/**
	 * Every public method on DefinitionRepository whose name says it writes is either exercised by
	 * this spec or explicitly declared not to be version content. A new mutator that neither joins
	 * the list nor declares itself fails here, which is the only way an inventory stays true.
	 */
	public void function testEveryRepositoryMutatorIsCoveredHere() {
		var md = getMetadata(variables.repo);
		var uncovered = [];
		for (var f in md.functions) {
			if (structKeyExists(f, "access") && f.access != "public") continue;
			if (!reFindNoCase("^(insert|update|upsert|delete|place|park|store|mark|replace|create|set)", f.name)) continue;
			if (structKeyExists(variables.NOT_A_WRITE, f.name)) continue;
			if (arrayFindNoCase(variables.covered, f.name)) continue;
			if (arrayFindNoCase(variables.SHARED_OR_GLOBAL, f.name)) continue;
			arrayAppend(uncovered, f.name);
		}
		assertEquals(0, arrayLen(uncovered), "DefinitionRepository mutators with no immutability coverage: " & arrayToList(uncovered));
	}

	/**
	 * ...and the shared/global list is not a place to hide. Every name on it must still exist as a
	 * public method, so a mutator cannot be "covered" by a stale entry after being renamed away.
	 */
	public void function testTheSharedAndGlobalInventoryNamesOnlyRealMethods() {
		var md = getMetadata(variables.repo);
		var present = {};
		for (var f in md.functions) {
			if (!structKeyExists(f, "access") || f.access == "public") present[f.name] = true;
		}
		var missing = [];
		for (var name in variables.SHARED_OR_GLOBAL) if (!structKeyExists(present, name)) arrayAppend(missing, name);
		for (var name in structKeyArray(variables.NOT_A_WRITE)) if (!structKeyExists(present, name)) arrayAppend(missing, name);
		assertEquals(0, arrayLen(missing), "the inventory names methods that no longer exist: " & arrayToList(missing));
		assertEquals(0, arrayLen(structFindKey({ "x": variables.SHARED_OR_GLOBAL }, "updateInstrument", "all")), "updateInstrument is gone; updateInstrumentMetadata replaced it");
	}

	// ---- the shared and global write boundary ----------------------------------------------------

	/**
	 * Each shared or global mutator, against the contract it actually has. None of these is
	 * "refused for a non-DRAFT version" in the way a version-content write is, and pretending
	 * otherwise is how they ended up untested; each is checked against the guard that is really
	 * supposed to hold it.
	 */
	public void function testEverySharedOrGlobalMutatorEnforcesItsOwnContract() {
		var repo = variables.repo;
		var before = sharedState();

		// createInstrument: insert-only. A second call for a code that exists must fail rather
		// than reach the existing row, so it can never rewrite shared metadata.
		var existingCode = variables.instrumentCode;
		var threw = false;
		try {
			repo.createInstrument(existingCode, "Attempted overwrite", "", true);
		} catch (any e) {
			threw = true;
		}
		assertTrue(threw, "createInstrument must not be able to reach an instrument that already exists");

		// updateInstrumentMetadata: a named, known user is required.
		var instrumentId = repo.findInstrumentByCode(existingCode).instrumentId;
		assertThrows(
			function() { repo.updateInstrumentMetadata(instrumentId, "Renamed by nobody", "", false, ""); },
			"ICFWalk.Validation", "INSTRUMENT_METADATA_ACTOR_REQUIRED"
		);
		var strangerId = uCase(createUUID());
		assertThrows(
			function() { repo.updateInstrumentMetadata(instrumentId, "Renamed by a stranger", "", false, strangerId); },
			"ICFWalk.Validation", "INSTRUMENT_METADATA_ACTOR_REQUIRED"
		);

		// createDimensionIdentity / createDimensionValueIdentity: the requesting version is an
		// argument, and must be a DRAFT. A PUBLISHED or RETIRED version cannot mint global
		// reporting identity that every later version will point at.
		var dimRow = { "code": "imm_probe_" & lCase(left(replace(createUUID(), "-", "", "all"), 8)), "label": "Probe", "dataType": "LIST", "reportable": false, "sensitive": false, "settingsJson": "{}", "active": true };
		for (var frozen in [variables.published, variables.retired]) {
			var frozenId = frozen.versionId;
			var frozenDimensionId = frozen.dimensionId;
			assertThrows(
				function() { repo.createDimensionIdentity(frozenId, dimRow); },
				"ICFWalk.Publish.NotDraft", "INSTRUMENT_VERSION_NOT_DRAFT"
			);
			assertThrows(
				function() { repo.createDimensionValueIdentity(frozenId, frozenDimensionId, { "valueCode": "probe_value", "label": "Probe value", "active": true }); },
				"ICFWalk.Publish.NotDraft", "INSTRUMENT_VERSION_NOT_DRAFT"
			);
		}

		// createDraftVersion: creates a DRAFT, so there is nothing frozen to protect -- but it must
		// not be usable to attach a version to an instrument that does not exist.
		var noSuchInstrument = uCase(createUUID());
		var created = false;
		try {
			repo.createDraftVersion(noSuchInstrument, "imm-probe-" & createUUID(), variables.publisher);
			created = true;
		} catch (any e) {
			created = false;
		}
		assertFalse(created, "createDraftVersion must not create a version under an instrument that does not exist");

		assertSharedUnchanged(before, "no refused shared or global mutation changed anything");
	}

	/**
	 * A refused global identity creation writes no row and moves no row version. The point is that
	 * the guard runs *before* the INSERT, not that the INSERT happened to fail afterwards.
	 */
	public void function testARefusedGlobalIdentityCreationWritesNothing() {
		var repo = variables.repo;
		var probeCode = "imm_refused_" & lCase(left(replace(createUUID(), "-", "", "all"), 8));
		var before = sharedState();
		var frozenId = variables.published.versionId;
		var dimRow = { "code": probeCode, "label": "Refused probe", "dataType": "LIST", "reportable": false, "sensitive": false, "settingsJson": "{}", "active": true };

		assertThrows(
			function() { repo.createDimensionIdentity(frozenId, dimRow); },
			"ICFWalk.Publish.NotDraft", "INSTRUMENT_VERSION_NOT_DRAFT"
		);

		assertEquals(0, variables.db.scalar(
			"SELECT COUNT(*) AS n FROM [icf].[dimension_definition] WHERE code = :code",
			{ "code": variables.db.nvarchar(probeCode, 100) }
		), "the refused identity row was never inserted");
		assertSharedUnchanged(before, "a refused global identity creation changes nothing");
	}

	/** The same mutators do work when a DRAFT asks, so the guard is a boundary and not a wall. */
	public void function testGlobalIdentityCreationStillWorksForADraft() {
		var draftImport = variables.importSvc.importConfig(config(label("global-draft")));
		var probeCode = "imm_ok_" & lCase(left(replace(createUUID(), "-", "", "all"), 8));
		var dimensionId = variables.repo.createDimensionIdentity(draftImport.versionId, {
			"code": probeCode, "label": "Draft probe", "dataType": "LIST", "reportable": false, "sensitive": false, "settingsJson": "{}", "active": true
		});
		assertTrue(len(dimensionId) > 0, "a DRAFT may mint reporting identity");
		var valueId = variables.repo.createDimensionValueIdentity(draftImport.versionId, dimensionId, { "valueCode": "draft_value", "label": "Draft value", "active": true });
		assertTrue(len(valueId) > 0, "and a value identity under it");
		assertEquals(1, variables.db.scalar(
			"SELECT COUNT(*) AS n FROM [icf].[dimension_value] WHERE value_id = :id",
			{ "id": variables.db.guid(valueId) }
		), "the value identity really was written");
	}

	// ---- every mutator, against PUBLISHED and against RETIRED -------------------------------------

	public void function testEveryMutatorIsRefusedForAPublishedVersion() {
		assertEveryMutatorRefused(variables.published, "PUBLISHED");
	}

	public void function testEveryMutatorIsRefusedForARetiredVersion() {
		assertEveryMutatorRefused(variables.retired, "RETIRED");
	}

	/**
	 * The same calls against a DRAFT do write. Without this the spec would pass just as well if the
	 * repository refused everything, which would prove nothing about the boundary being a boundary.
	 */
	public void function testTheSameMutatorsStillWriteForADraft() {
		var h = variables.draft;
		var before = definitionsChecksum(h.versionId);

		variables.repo.updateSectionContent(h.versionId, h.sectionId, sectionRow("Immutability probe title"));
		assertExactTextNotEquals(before, definitionsChecksum(h.versionId), "a DRAFT section really was rewritten");

		variables.repo.deleteOption(h.versionId, h.optionId);
		assertEquals(0, variables.db.scalar("SELECT COUNT(*) AS n FROM [icf].[response_option] WHERE option_id = :id", { "id": variables.db.guid(h.optionId) }), "a DRAFT option really was deleted");

		variables.repo.deleteItem(h.versionId, h.itemId);
		assertEquals(0, variables.db.scalar("SELECT COUNT(*) AS n FROM [icf].[item_definition] WHERE item_id = :id", { "id": variables.db.guid(h.itemId) }), "a DRAFT item really was deleted");

		variables.repo.deleteDraftVersionCascade(h.versionId);
		assertEquals(0, variables.db.scalar("SELECT COUNT(*) AS n FROM [icf].[instrument_version] WHERE version_id = :id", { "id": variables.db.guid(h.versionId) }), "a DRAFT version really was removed");
	}

	/**
	 * A child id from another version cannot be used to reach into this one: the owner is resolved
	 * from the child row in the database, not taken from the caller's argument.
	 */
	public void function testAChildOfAnotherVersionCannotBeWrittenThroughThisOne() {
		var mine = variables.importSvc.importConfig(config(label("owner")));
		var mineHandles = handles(mine.versionId);
		var repo = variables.repo;
		var foreignItem = variables.published.itemId;
		var myVersion = mine.versionId;
		assertThrows(
			function() { repo.deleteItem(myVersion, foreignItem); },
			"ICFWalk.Validation", "INSTRUMENT_DEFINITION_VERSION_MISMATCH"
		);
		assertEquals(1, variables.db.scalar("SELECT COUNT(*) AS n FROM [icf].[item_definition] WHERE item_id = :id", { "id": variables.db.guid(foreignItem) }), "the published item is still there");
	}

	// ---- durable refusal audits (the real service transactions) ------------------------------------

	/**
	 * The complete import transaction against a PUBLISHED version: it rolls back, and the record of
	 * the attempt survives the rollback. An audit written inside that transaction would have gone
	 * with it, which is the defect this proves is fixed.
	 *
	 * Retrying produces a second record because there was a second attempt -- not two records for
	 * one attempt.
	 */
	public void function testRefusedImportRollsBackAndLeavesExactlyOneDurableAudit() {
		var frozen = freeze("audit-import", "PUBLISHED");
		var before = snapshotOfEverything(frozen.versionId);
		assertEquals(0, auditCount(frozen.versionId, "INSTRUMENT_VERSION_WRITE_REFUSED"), "precondition: no refusals yet");

		var importSvc = variables.importSvc;
		var cfg = config(label("audit-import"));
		cfg.items[1].prompt = "Tampered prompt that must never be stored";
		assertThrows(function() { importSvc.importConfig(cfg, variables.publisher); }, "ICFWalk.Import.PublishedVersion", "INSTRUMENT_VERSION_IMMUTABLE");

		assertUnchanged(before, frozen.versionId, "the refused import changed nothing");
		assertEquals(0, variables.db.scalar(
			"SELECT COUNT(*) AS n FROM [icf].[item_definition] WHERE version_id = :id AND prompt = N'Tampered prompt that must never be stored'",
			{ "id": variables.db.guid(frozen.versionId) }
		), "the attempted prompt was not written");
		assertEquals(1, auditCount(frozen.versionId, "INSTRUMENT_VERSION_WRITE_REFUSED"), "exactly one refusal survived the rollback");
		assertEquals(0, auditCount(frozen.versionId, "INSTRUMENT_VERSION_REIMPORTED"), "and no success event was written");

		// One attempt, one record. A second attempt is a second attempt.
		assertThrows(function() { importSvc.importConfig(cfg, variables.publisher); }, "ICFWalk.Import.PublishedVersion", "INSTRUMENT_VERSION_IMMUTABLE");
		assertEquals(2, auditCount(frozen.versionId, "INSTRUMENT_VERSION_WRITE_REFUSED"), "two attempts, two records -- not four");
		assertUnchanged(before, frozen.versionId, "and the second refusal changed nothing either");
	}

	/** The same, for the discard transaction. */
	public void function testRefusedDiscardRollsBackAndLeavesExactlyOneDurableAudit() {
		var frozen = freeze("audit-discard", "PUBLISHED");
		var before = snapshotOfEverything(frozen.versionId);
		var importSvc = variables.importSvc;
		var discardLabel = label("audit-discard");

		var fixtureInstrument = variables.instrumentCode;
		assertThrows(function() { importSvc.discardDraft(discardLabel, variables.publisher, fixtureInstrument); }, "ICFWalk.Import.PublishedVersion", "INSTRUMENT_VERSION_IMMUTABLE");

		assertUnchanged(before, frozen.versionId, "the refused discard changed nothing");
		assertEquals(1, auditCount(frozen.versionId, "INSTRUMENT_VERSION_WRITE_REFUSED"), "exactly one refusal survived the rollback");
		assertEquals(0, auditCount(frozen.versionId, "INSTRUMENT_VERSION_DISCARDED"), "and nothing claims it was discarded");
	}

	/**
	 * A DRAFT that walks already reference cannot be re-imported over, and the refusal is as
	 * durable as every other one.
	 *
	 * This branch used to throw INSTRUMENT_VERSION_IN_USE without marking the refusal first, so the
	 * catch that writes the post-rollback audit had nothing to write: the attempt rolled back and
	 * left no trace whatsoever. It is a DRAFT, so unlike the PUBLISHED cases above there is no
	 * status guard standing behind it -- the refusal record was the only evidence there would ever
	 * have been.
	 */
	public void function testRefusedImportOfADraftInUseRollsBackAndLeavesExactlyOneDurableAudit() {
		var h = draftReferencedByAWalk("inuse-import");
		var before = snapshotOfEverything(h.versionId);
		assertExactTextEquals("DRAFT", before.status, "precondition: the version really is a DRAFT");
		assertEquals(0, auditCount(h.versionId, "INSTRUMENT_VERSION_WRITE_REFUSED"), "precondition: no refusals yet");

		var importSvc = variables.importSvc;
		var cfg = config(label("inuse-import"));
		cfg.items[1].prompt = "A prompt that must never reach a draft walks are using";
		assertThrows(function() { importSvc.importConfig(cfg, variables.publisher); }, "ICFWalk.Import.VersionInUse", "INSTRUMENT_VERSION_IN_USE");

		assertUnchanged(before, h.versionId, "the refused import of a DRAFT in use changed nothing");
		assertEquals(0, variables.db.scalar(
			"SELECT COUNT(*) AS n FROM [icf].[item_definition] WHERE version_id = :id AND prompt = N'A prompt that must never reach a draft walks are using'",
			{ "id": variables.db.guid(h.versionId) }
		), "the attempted prompt was not written");
		assertEquals(1, auditCount(h.versionId, "INSTRUMENT_VERSION_WRITE_REFUSED"), "exactly one refusal survived the rollback");
		assertEquals(0, auditCount(h.versionId, "INSTRUMENT_VERSION_REIMPORTED"), "and no success event was written");
		assertRefusalDetails(h.versionId, label("inuse-import"), "DRAFT", "IMPORT", "VERSION_IN_USE");

		variables.fixtures.removeWalk(h.walkId);
	}

	/** The same for discarding a DRAFT that walks reference. */
	public void function testRefusedDiscardOfADraftInUseRollsBackAndLeavesExactlyOneDurableAudit() {
		var h = draftReferencedByAWalk("inuse-discard");
		var before = snapshotOfEverything(h.versionId);
		assertEquals(0, auditCount(h.versionId, "INSTRUMENT_VERSION_WRITE_REFUSED"), "precondition: no refusals yet");

		var importSvc = variables.importSvc;
		var discardLabel = label("inuse-discard");
		var fixtureInstrument = variables.instrumentCode;
		assertThrows(function() { importSvc.discardDraft(discardLabel, variables.publisher, fixtureInstrument); }, "ICFWalk.Import.VersionInUse", "INSTRUMENT_VERSION_IN_USE");

		assertUnchanged(before, h.versionId, "the refused discard changed nothing");
		assertEquals(1, variables.db.scalar(
			"SELECT COUNT(*) AS n FROM [icf].[instrument_version] WHERE version_id = :id",
			{ "id": variables.db.guid(h.versionId) }
		), "and the version is still there");
		assertEquals(1, auditCount(h.versionId, "INSTRUMENT_VERSION_WRITE_REFUSED"), "exactly one refusal survived the rollback");
		assertEquals(0, auditCount(h.versionId, "INSTRUMENT_VERSION_DISCARDED"), "and nothing claims it was discarded");
		assertRefusalDetails(h.versionId, discardLabel, "DRAFT", "DISCARD_DRAFT", "VERSION_IN_USE");

		variables.fixtures.removeWalk(h.walkId);
	}

	/** The refusal record names the facts and carries no instrument content. */
	public void function testRefusalAuditCarriesLifecycleFactsAndNoContent() {
		var frozen = freeze("audit-detail", "PUBLISHED");
		var importSvc = variables.importSvc;
		var cfg = config(label("audit-detail"));
		assertThrows(function() { importSvc.importConfig(cfg, variables.publisher); }, "ICFWalk.Import.PublishedVersion");

		var q = variables.db.run(
			"SELECT actor_user_id, details_json FROM [icf].[audit_event] WHERE entity_id = :id AND event_type = N'INSTRUMENT_VERSION_WRITE_REFUSED'",
			{ "id": variables.db.guid(frozen.versionId) }
		);
		assertEquals(1, q.recordCount);
		assertExactTextEquals(variables.publisher, uCase(q.actor_user_id[1]), "the actor who attempted the write is named");
		var details = deserializeJSON(q.details_json[1]);
		assertExactTextEquals("PUBLISHED", details.status, "the prior status is recorded");
		assertExactTextEquals("IMPORT", details.operation, "and the operation");
		assertExactTextEquals("VERSION_NOT_DRAFT", details.reason, "and a stable reason code");
		assertExactTextEquals(label("audit-detail"), details.versionLabel);
		var text = q.details_json[1];
		assertFalse(find("sectionKey", text) > 0, "no definitions in the audit details");
		assertFalse(find("snapshotFormat", text) > 0, "no snapshot in the audit details");
		assertFalse(find("prompt", text) > 0, "no narrative content in the audit details");
		assertTrue(len(text) < 500, "the record stays a lifecycle fact, not a payload: " & len(text) & " bytes");
	}

	/** The shape every refusal record must have, wherever the refusal came from. */
	private void function assertRefusalDetails(
		required string versionId, required string versionLabel, required string status,
		required string operation, required string reason
	) {
		var q = variables.db.run(
			"SELECT TOP (1) actor_user_id, details_json FROM [icf].[audit_event]
			  WHERE entity_id = :id AND event_type = N'INSTRUMENT_VERSION_WRITE_REFUSED' ORDER BY event_id DESC",
			{ "id": variables.db.guid(arguments.versionId) }
		);
		assertEquals(1, q.recordCount, "a refusal record exists");
		assertExactTextEquals(variables.publisher, uCase(q.actor_user_id[1]), "the actor who attempted the write is named");
		var details = deserializeJSON(q.details_json[1]);
		assertExactTextEquals(arguments.versionLabel, details.versionLabel, "the version label is recorded");
		assertExactTextEquals(arguments.status, details.status, "the prior status is recorded");
		assertExactTextEquals(arguments.operation, details.operation, "and the operation");
		assertExactTextEquals(arguments.reason, details.reason, "and a stable reason code");
		var text = q.details_json[1];
		assertFalse(find("sectionKey", text) > 0, "no definitions in the audit details");
		assertFalse(find("snapshotFormat", text) > 0, "no snapshot in the audit details");
		assertFalse(find("prompt", text) > 0, "no narrative content in the audit details");
		assertTrue(len(text) < 500, "the record stays a lifecycle fact, not a payload: " & len(text) & " bytes");
	}

	/**
	 * An imported DRAFT with one walk pinned to it, which is what makes it "in use". The walk needs
	 * an org unit and an owner, so the fixture supplies both and hands back the walk id for
	 * teardown.
	 */
	private struct function draftReferencedByAWalk(required string suffix) {
		var imported = variables.importSvc.importConfig(config(label(arguments.suffix)));
		var orgUnitId = variables.fixtures.ensureOrgUnit(variables.run & "-" & arguments.suffix, "SCHOOL");
		var owner = variables.fixtures.ensureUser(variables.run & "-" & arguments.suffix & "-walker", "Draft-in-use fixture walker");
		var walkId = variables.fixtures.insertWalk(imported.versionId, orgUnitId, owner);
		assertEquals(1, variables.repo.countWalksForVersion(imported.versionId), "the fixture walk really pins the DRAFT");
		return { "versionId": imported.versionId, "walkId": walkId, "orgUnitId": orgUnitId, "ownerUserId": owner };
	}

	// ---- helpers -----------------------------------------------------------------------------------

	/**
	 * Calls every production mutator against a frozen version. Each must raise the established
	 * typed refusal, and the version must be bit-for-bit what it was before the attempt.
	 */
	private void function assertEveryMutatorRefused(required struct h, required string status) {
		var repo = variables.repo;
		var versionId = arguments.h.versionId;
		var before = snapshotOfEverything(versionId);

		refused(function() { repo.storeSnapshot(versionId, '{"definitions":{}}', repeatString("a", 64)); }, "storeSnapshot", arguments.status);
		refused(function() { repo.markPublished(versionId, '{"definitions":{}}', repeatString("a", 64), variables.publisher); }, "markPublished", arguments.status);
		refused(function() { repo.parkVersionOrders(versionId); }, "parkVersionOrders", arguments.status);

		refused(function() { repo.insertSection(versionId, sectionRow("Injected section"), 999001); }, "insertSection", arguments.status);
		refused(function() { repo.updateSectionContent(versionId, h.sectionId, sectionRow("Rewritten title")); }, "updateSectionContent", arguments.status);
		refused(function() { repo.placeSection(versionId, h.sectionId, "", 999002); }, "placeSection", arguments.status);
		refused(function() { repo.deleteSections(versionId, [h.sectionId]); }, "deleteSections", arguments.status);

		refused(function() { repo.upsertResponseSet(versionId, "", responseSetRow("injected_set")); }, "upsertResponseSet (insert)", arguments.status);
		refused(function() { repo.upsertResponseSet(versionId, h.responseSetId, responseSetRow("rewritten")); }, "upsertResponseSet (update)", arguments.status);
		refused(function() { repo.deleteResponseSet(versionId, h.responseSetId); }, "deleteResponseSet", arguments.status);

		refused(function() { repo.upsertOption(versionId, h.responseSetId, "", optionRow("injected_option", 999003)); }, "upsertOption (insert)", arguments.status);
		refused(function() { repo.upsertOption(versionId, h.responseSetId, h.optionId, optionRow("rewritten_option", 999004)); }, "upsertOption (update)", arguments.status);
		refused(function() { repo.deleteOption(versionId, h.optionId); }, "deleteOption", arguments.status);

		refused(function() { repo.upsertRule(versionId, "", ruleRow("injected_rule")); }, "upsertRule (insert)", arguments.status);
		refused(function() { repo.upsertRule(versionId, h.ruleId, ruleRow("rewritten_rule")); }, "upsertRule (update)", arguments.status);
		refused(function() { repo.deleteRule(versionId, h.ruleId); }, "deleteRule", arguments.status);

		refused(function() { repo.upsertItem(versionId, "", itemRow("injected_item", 999005), h.sectionId, ""); }, "upsertItem (insert)", arguments.status);
		refused(function() { repo.upsertItem(versionId, h.itemId, itemRow("rewritten_item", 999006), h.sectionId, ""); }, "upsertItem (update)", arguments.status);
		refused(function() { repo.deleteItem(versionId, h.itemId); }, "deleteItem", arguments.status);

		refused(function() { repo.upsertPlacement(versionId, h.dimensionId, true, placementRow(999007), ""); }, "upsertPlacement (update)", arguments.status);
		refused(function() { repo.upsertPlacement(versionId, h.dimensionId, false, placementRow(999008), ""); }, "upsertPlacement (insert)", arguments.status);
		refused(function() { repo.replaceVersionDimensionValues(versionId, h.dimensionId, []); }, "replaceVersionDimensionValues", arguments.status);
		refused(function() { repo.deletePlacement(versionId, h.dimensionId); }, "deletePlacement", arguments.status);

		refused(function() { repo.deleteDraftVersionCascade(versionId); }, "deleteDraftVersionCascade", arguments.status);

		assertUnchanged(before, versionId, "after every refused mutator on a " & arguments.status & " version");
	}

	private void function refused(required any fn, required string what, required string status) {
		try {
			arguments.fn();
		} catch (any e) {
			// Types are matched as CFML resolves them, case-insensitively; the errorcode is compared exactly.
			if (compareNoCase(left(e.type, len("ICFWalk.Publish.NotDraft")), "ICFWalk.Publish.NotDraft") != 0) {
				fail(arguments.what & " on a " & arguments.status & " version raised [" & e.type & "] instead of the DRAFT-only refusal: " & e.message);
			}
			if (!structKeyExists(e, "errorcode") || compare(e.errorcode, "INSTRUMENT_VERSION_NOT_DRAFT") != 0) {
				fail(arguments.what & " on a " & arguments.status & " version raised errorcode [" & (structKeyExists(e, "errorcode") ? e.errorcode : "") & "].");
			}
			return;
		}
		fail(arguments.what & " was NOT refused for a " & arguments.status & " version.");
	}

	/** The shared and global rows, as they stand: nothing a refused write may move. */
	private struct function sharedState() {
		return {
			"instruments": variables.db.scalar("SELECT COUNT(*) AS n FROM [icf].[instrument]"),
			"instrumentDigest": digest("SELECT instrument_id, code, name, description, active FROM [icf].[instrument] ORDER BY code"),
			"dimensions": variables.db.scalar("SELECT COUNT(*) AS n FROM [icf].[dimension_definition]"),
			"dimensionDigest": digest("SELECT dimension_id, code FROM [icf].[dimension_definition] ORDER BY code"),
			"dimensionValues": variables.db.scalar("SELECT COUNT(*) AS n FROM [icf].[dimension_value]"),
			"dimensionValueDigest": digest("SELECT value_id, dimension_id, value_code FROM [icf].[dimension_value] ORDER BY dimension_id, value_code"),
			"instrumentRowVersion": maxRowVersion("SELECT CONVERT(varchar(20), MAX(CAST(row_version AS bigint))) AS rv FROM [icf].[instrument]", {})
		};
	}

	/**
	 * Each shared field under its own contract -- counts numerically, digests as exact text, the
	 * high row_version as an opaque token -- and every field sharedState() records is compared.
	 */
	private void function assertSharedUnchanged(required struct before, required string message) {
		var after = sharedState();
		var counts = ["instruments", "dimensions", "dimensionValues"];
		var digests = ["instrumentDigest", "dimensionDigest", "dimensionValueDigest"];
		var compared = ["instrumentRowVersion"];
		arrayAppend(compared, counts, true);
		arrayAppend(compared, digests, true);
		arraySort(compared, "text");
		assertExactJsonEquals(sortedKeys(arguments.before), compared, arguments.message & ": every shared field is compared");
		for (var field in counts) assertEquals(arguments.before[field], after[field], arguments.message & ": " & field);
		for (var field in digests) assertExactTextEquals(arguments.before[field], after[field], arguments.message & ": " & field);
		assertRowVersionEquals(arguments.before.instrumentRowVersion, after.instrumentRowVersion, arguments.message & ": instrumentRowVersion");
	}

	private array function sortedKeys(required struct s) {
		var keys = structKeyArray(arguments.s);
		arraySort(keys, "text");
		return keys;
	}

	private string function digest(required string sql) {
		var q = variables.db.run(arguments.sql);
		return variables.c.canonicalJson.sha256(variables.c.canonicalJson.serialize(q));
	}

	/** Everything that must not move: content, and every owning table's high row_version. */
	private struct function snapshotOfEverything(required string versionId) {
		var row = variables.repo.findVersionById(arguments.versionId);
		return {
			"status": row.status,
			"snapshotJson": isNull(row.snapshotJson) ? "" : row.snapshotJson,
			"checksum": isNull(row.checksum) ? "" : row.checksum,
			"publishedBy": row.publishedByUserId,
			"versionRowVersion": row.rowVersion,
			"definitionsChecksum": definitionsChecksum(arguments.versionId),
			"childRowVersions": childRowVersions(arguments.versionId),
			"counts": variables.repo.countChildren(arguments.versionId)
		};
	}

	private void function assertUnchanged(required struct before, required string versionId, required string message) {
		var after = snapshotOfEverything(arguments.versionId);
		assertExactTextEquals(arguments.before.status, after.status, arguments.message & ": status");
		assertExactTextEquals(arguments.before.snapshotJson, after.snapshotJson, arguments.message & ": stored snapshot");
		assertExactTextEquals(arguments.before.checksum, after.checksum, arguments.message & ": checksum");
		assertExactTextEquals(arguments.before.publishedBy, after.publishedBy, arguments.message & ": publisher");
		assertRowVersionEquals(arguments.before.versionRowVersion, after.versionRowVersion, arguments.message & ": version row_version");
		assertExactTextEquals(arguments.before.definitionsChecksum, after.definitionsChecksum, arguments.message & ": definitions");
		assertExactJsonEquals(sortedKeys(arguments.before.childRowVersions), sortedKeys(after.childRowVersions), arguments.message & ": child tables");
		for (var table in sortedKeys(arguments.before.childRowVersions)) {
			assertRowVersionEquals(arguments.before.childRowVersions[table], after.childRowVersions[table], arguments.message & ": " & table & " row_version");
		}
		assertExactJsonEquals(arguments.before.counts, after.counts, arguments.message & ": child counts");
	}

	private struct function childRowVersions(required string versionId) {
		var p = { "id": variables.db.guid(arguments.versionId) };
		var out = {};
		out["sections"] = maxRowVersion("SELECT CONVERT(varchar(20), MAX(CAST(row_version AS bigint))) AS rv FROM [icf].[section_definition] WHERE version_id = :id", p);
		out["items"] = maxRowVersion("SELECT CONVERT(varchar(20), MAX(CAST(row_version AS bigint))) AS rv FROM [icf].[item_definition] WHERE version_id = :id", p);
		out["responseSets"] = maxRowVersion("SELECT CONVERT(varchar(20), MAX(CAST(row_version AS bigint))) AS rv FROM [icf].[response_set] WHERE version_id = :id", p);
		out["responseOptions"] = maxRowVersion("SELECT CONVERT(varchar(20), MAX(CAST(o.row_version AS bigint))) AS rv FROM [icf].[response_option] o JOIN [icf].[response_set] s ON s.response_set_id = o.response_set_id WHERE s.version_id = :id", p);
		out["rules"] = maxRowVersion("SELECT CONVERT(varchar(20), MAX(CAST(row_version AS bigint))) AS rv FROM [icf].[rule_definition] WHERE version_id = :id", p);
		out["placements"] = maxRowVersion("SELECT CONVERT(varchar(20), MAX(CAST(row_version AS bigint))) AS rv FROM [icf].[instrument_dimension] WHERE version_id = :id", p);
		out["dimensionValues"] = maxRowVersion("SELECT CONVERT(varchar(20), MAX(CAST(row_version AS bigint))) AS rv FROM [icf].[instrument_dimension_value] WHERE version_id = :id", p);
		return out;
	}

	private string function maxRowVersion(required string sql, required struct params) {
		var q = variables.db.run(arguments.sql, arguments.params);
		if (!q.recordCount || isNull(q.rv[1]) || !len(toString(q.rv[1]))) return "none";
		return toString(q.rv[1]);
	}

	private string function definitionsChecksum(required string versionId) {
		return variables.c.snapshotCompiler.definitionsChecksum(variables.repo.loadNormalizedDefinitions(arguments.versionId));
	}

	private numeric function auditCount(required string versionId, required string eventType) {
		return variables.db.scalar(
			"SELECT COUNT(*) AS n FROM [icf].[audit_event] WHERE entity_id = :id AND event_type = :t",
			{ "id": variables.db.guid(arguments.versionId), "t": variables.db.nvarchar(arguments.eventType) }
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

	/** Imports a DRAFT, publishes it, and optionally retires it. Returns child handles. */
	private struct function freeze(required string suffix, required string status) {
		var imported = variables.importSvc.importConfig(config(label(arguments.suffix)));
		variables.publishSvc.publish(imported.versionId, variables.publisher);
		if (arguments.status == "RETIRED") {
			variables.db.run(
				"UPDATE [icf].[instrument_version] SET status = N'RETIRED', effective_end = SYSUTCDATETIME() WHERE version_id = :id",
				{ "id": variables.db.guid(imported.versionId) }
			);
		}
		return handles(imported.versionId);
	}

	/** One real child id per definition family, for a version. */
	private struct function handles(required string versionId) {
		var p = { "id": variables.db.guid(arguments.versionId) };
		var h = { "versionId": arguments.versionId };
		h["sectionId"] = uCase(variables.db.run(
			"SELECT TOP (1) section_id FROM [icf].[section_definition]
			  WHERE version_id = :id AND section_id NOT IN (SELECT parent_section_id FROM [icf].[section_definition] WHERE parent_section_id IS NOT NULL)
			  ORDER BY section_key", p).section_id[1]);
		h["itemId"] = uCase(variables.db.run("SELECT TOP (1) item_id FROM [icf].[item_definition] WHERE version_id = :id ORDER BY item_key", p).item_id[1]);
		h["responseSetId"] = uCase(variables.db.run("SELECT TOP (1) response_set_id FROM [icf].[response_set] WHERE version_id = :id ORDER BY response_set_key", p).response_set_id[1]);
		h["optionId"] = uCase(variables.db.run(
			"SELECT TOP (1) o.option_id FROM [icf].[response_option] o JOIN [icf].[response_set] s ON s.response_set_id = o.response_set_id
			  WHERE s.response_set_id = :setId ORDER BY o.display_order",
			{ "setId": variables.db.guid(h.responseSetId) }).option_id[1]);
		h["ruleId"] = uCase(variables.db.run("SELECT TOP (1) rule_id FROM [icf].[rule_definition] WHERE version_id = :id ORDER BY rule_key", p).rule_id[1]);
		h["dimensionId"] = uCase(variables.db.run("SELECT TOP (1) dimension_id FROM [icf].[instrument_dimension] WHERE version_id = :id ORDER BY display_order", p).dimension_id[1]);
		return h;
	}

	// Minimal, valid row shapes for the mutators under test. None of them should ever be stored.
	private struct function sectionRow(required string title) {
		return { "sectionKey": "injected_section", "parentSectionKey": javaCast("null", ""), "displayOrder": 999000, "title": arguments.title,
			"instructions": javaCast("null", ""), "notesEnabled": false, "active": true, "settingsJson": "{}" };
	}

	private struct function responseSetRow(required string key) {
		return { "setKey": arguments.key, "name": "Injected set", "selectionMode": "SINGLE", "active": true, "settingsJson": "{}" };
	}

	private struct function optionRow(required string key, required numeric order) {
		return { "optionKey": arguments.key, "storedCode": arguments.key, "label": "Injected option", "definition": javaCast("null", ""),
			"numericScore": javaCast("null", ""), "isNa": false, "displayOrder": arguments.order, "active": true };
	}

	private struct function ruleRow(required string key) {
		return { "ruleKey": arguments.key, "targetType": "SECTION", "targetKey": "injected_section", "effect": "SHOW",
			"conditionsJson": '{"logic":"AND","conditions":[]}', "active": true };
	}

	private struct function itemRow(required string key, required numeric order) {
		return { "itemKey": arguments.key, "reportingKey": javaCast("null", ""), "itemType": "LONG_TEXT", "prompt": "Injected prompt",
			"helpText": javaCast("null", ""), "displayOrder": arguments.order, "required": false, "active": true, "settingsJson": "{}" };
	}

	private struct function placementRow(required numeric order) {
		return { "displayOrder": arguments.order, "required": false, "ruleKey": javaCast("null", ""), "labelOverride": javaCast("null", ""),
			"settingsJson": "{}", "dimensionLabel": "Injected dimension", "dimensionDataType": "TEXT", "dimensionReportable": false,
			"dimensionSensitive": false, "dimensionActive": true, "dimensionSettingsJson": "{}" };
	}
}
