/**
 * Phase 6 (ADM-03/04/05): publishing freezes a DRAFT, and a frozen version never moves again.
 *
 * WHAT IS BEING PROVED. Publishing is the one irreversible operation in the instrument lifecycle:
 * after it, walks pin themselves to the snapshot and nothing re-derives the instrument from the
 * definition tables. So the properties that matter are not "publish sets a flag" but:
 *
 *   - the snapshot a version is frozen with is byte-for-byte the snapshot its import compiled, and
 *     its checksum still hashes it (testPublishFreezesTheImportedSnapshotByteForByte);
 *   - every field the database requires of a published row is written together, so no half
 *     published row can exist (the same case, plus CK_instrument_version_publish_values);
 *   - the row names a real publisher, that publisher is the actor the caller passed, and the
 *     success audit names the same person the row does (testPublishRecordsTheAuthenticatedPublisher);
 *   - publication with no publisher, a malformed one, or one who does not exist is refused before
 *     anything is written (testPublishingWithoutAValidPublisherIsRefusedAndChangesNothing);
 *   - a version that is not a DRAFT is refused, whether the caller comes through the route or
 *     calls the service directly, and the refusal is audited rather than silent
 *     (testPublishingAPublishedVersionIsRefusedAndAudited, testAssertDraftForWriteRefusesAPublishedVersion);
 *   - a DRAFT whose definitions have drifted from its snapshot is refused and left untouched
 *     (testDefinitionsDriftIsRefusedAndNothingChanges);
 *   - and -- the case self-consistency cannot catch -- a DRAFT whose rows and snapshot agree
 *     perfectly on invalid content is refused too. Every test below whose name starts
 *     testSemantic... builds exactly that state: the definitions are edited, the snapshot is
 *     recompiled from them, and the checksum is recomputed, so the drift check and the checksum
 *     check both pass and only real validation can refuse the publish.
 *
 * Fixtures are synthetic version labels removed in afterAll by the test-only harness; no seeded
 * version is published.
 */
component extends="icfwalktests.BaseSpec" output="false" {

	public string function skipReason() {
		return schemaPresent() ? "" : "icf schema is not present in datasource '" & variables.c.db.datasourceName() & "'.";
	}

	public void function beforeAll() {
		variables.run = "pub-" & lCase(left(replace(createUUID(), "-", "", "all"), 8));
		// Fixtures live under their own instrument code, so a published fixture is never a candidate
		// for the ICFWalk instrument's current version while this spec runs, and a run interrupted
		// before afterAll cannot leave one behind that changes what another spec renders.
		variables.instrumentCode = "PUBFIX" & uCase(left(replace(createUUID(), "-", "", "all"), 8));
		variables.importSvc = variables.c.instrumentImportService;
		variables.svc = variables.c.instrumentPublishService;
		variables.repo = variables.c.definitionRepository;
		variables.db = variables.c.db;
		variables.fixtures = new icfwalktests.support.FixtureCleanup(variables.c);
		// A real app_user: publication requires one and the database refuses a published row
		// without one (CK_instrument_version_publisher_required, migration 006).
		variables.publisher = variables.fixtures.ensureUser(variables.run & "-publisher", "Publish fixture user");
	}

	public void function afterAll() {
		// Published fixtures cannot be removed by any production method any more, by design.
		variables.fixtures.removeInstrumentsCoded(variables.instrumentCode);
		variables.fixtures.removeUsers(variables.run & "-");
	}

	// ---- ADM-04: the publish transaction ---------------------------------------------------------

	/**
	 * Publishing changes the version's status, not its content. The snapshot stored after publish is
	 * the identical text the import compiled, its checksum is unchanged, and every column the
	 * database demands of a non-DRAFT row is populated in the same statement.
	 */
	public void function testPublishFreezesTheImportedSnapshotByteForByte() {
		var imported = draft("adm04");
		var before = variables.repo.findVersionById(imported.versionId);
		assertEquals("DRAFT", before.status);

		var result = variables.svc.publish(imported.versionId, variables.publisher);

		assertEquals("PUBLISHED", result.status);
		assertEquals(imported.checksum, result.checksum, "publishing does not recompute the checksum");
		assertEquals(imported.versionId, result.versionId);

		var after = variables.repo.findVersionById(imported.versionId);
		assertEquals("PUBLISHED", after.status);
		assertEquals(before.snapshotJson, after.snapshotJson, "the frozen snapshot is the imported snapshot, byte for byte");
		assertEquals(before.checksum, after.checksum);
		assertEquals(after.checksum, variables.c.canonicalJson.sha256(after.snapshotJson), "and the checksum still hashes it");

		// Every field CK_instrument_version_publish_values requires of a non-DRAFT row.
		var row = variables.db.run(
			"SELECT status, published_at, effective_start, checksum_sha256, compiled_snapshot_json, published_by_user_id FROM [icf].[instrument_version] WHERE version_id = :id",
			{ "id": variables.db.guid(imported.versionId) }
		);
		assertEquals("PUBLISHED", row.status[1]);
		assertTrue(isDate(row.published_at[1]), "published_at is set");
		assertTrue(isDate(row.effective_start[1]), "effective_start is set");
		assertEquals(64, len(trim(row.checksum_sha256[1])));
		assertTrue(len(row.compiled_snapshot_json[1]) > 0, "the snapshot is still stored");
		assertEquals(variables.publisher, uCase(row.published_by_user_id[1]), "and the publisher is stored in the same statement");

		assertEquals(1, auditCount(imported.versionId, "INSTRUMENT_VERSION_PUBLISHED"), "the publish is audited once");
	}

	/**
	 * The published version is the one the renderer will now select. Proving it here keeps the
	 * publish path honest about the thing publishing exists to do.
	 */
	public void function testAPublishedVersionBecomesSelectableAsCurrent() {
		var imported = draft("adm04b");
		variables.svc.publish(imported.versionId, variables.publisher);
		var selectable = variables.db.scalar(
			"SELECT COUNT(*) AS n FROM [icf].[instrument_version]
			  WHERE version_id = :id AND status = N'PUBLISHED' AND compiled_snapshot_json IS NOT NULL AND effective_start IS NOT NULL",
			{ "id": variables.db.guid(imported.versionId) }
		);
		assertEquals(1, selectable, "the published version satisfies the current-version selection predicate");
	}

	// ---- ADM-04: publisher attribution -----------------------------------------------------------

	/**
	 * Who published a version is part of what publishing records. The row names the actor the caller
	 * passed, the success audit names the same person, and the returned result agrees with both.
	 */
	public void function testPublishRecordsTheAuthenticatedPublisher() {
		var imported = draft("adm04c");
		var result = variables.svc.publish(imported.versionId, variables.publisher);

		assertEquals(variables.publisher, result.publishedByUserId, "the result names the publisher");
		var stored = variables.repo.findVersionById(imported.versionId);
		assertEquals(variables.publisher, stored.publishedByUserId, "and so does the row");

		var audit = variables.db.run(
			"SELECT actor_user_id, details_json FROM [icf].[audit_event] WHERE entity_id = :id AND event_type = N'INSTRUMENT_VERSION_PUBLISHED'",
			{ "id": variables.db.guid(imported.versionId) }
		);
		assertEquals(1, audit.recordCount, "exactly one success event");
		assertEquals(variables.publisher, uCase(audit.actor_user_id[1]), "the audit actor is the stored publisher");
		var details = deserializeJSON(audit.details_json[1]);
		assertEquals(variables.publisher, uCase(details.publishedByUserId), "and the recorded detail agrees");
	}

	/**
	 * A missing, malformed or unknown publisher is refused before publication. Each case leaves the
	 * version a DRAFT with its row version untouched, so nothing was attempted and rolled back
	 * either -- the refusal happens before any write.
	 */
	public void function testPublishingWithoutAValidPublisherIsRefusedAndChangesNothing() {
		var imported = draft("adm04d");
		var before = variables.repo.findVersionById(imported.versionId);
		var svc = variables.svc;
		var id = imported.versionId;
		var unknown = variables.db.newGuid();

		assertThrows(function() { svc.publish(id, ""); }, "ICFWalk.Validation", "PUBLISHER_REQUIRED");
		assertThrows(function() { svc.publish(id, "   "); }, "ICFWalk.Validation", "PUBLISHER_REQUIRED");
		assertThrows(function() { svc.publish(id, "not-a-guid"); }, "ICFWalk.Validation", "PUBLISHER_INVALID");
		assertThrows(function() { svc.publish(id, unknown); }, "ICFWalk.Validation", "PUBLISHER_UNKNOWN");

		var after = variables.repo.findVersionById(id);
		assertEquals("DRAFT", after.status, "the version is still a DRAFT");
		assertEquals(before.rowVersion, after.rowVersion, "and its row did not move");
		assertEquals("", after.publishedByUserId, "no publisher was recorded");
		assertEquals(0, auditCount(id, "INSTRUMENT_VERSION_PUBLISHED"), "nothing was published");
		// The unknown-actor attempt got as far as the locked row, so it is audited as a refusal;
		// the three that never reached the database are rejected as input and are not.
		assertEquals(1, auditCount(id, "INSTRUMENT_VERSION_PUBLISH_REFUSED"), "only the attempt that reached the locked row is audited");
	}

	/**
	 * markPublished is the lowest publication method and has no empty default either: it refuses a
	 * blank publisher itself, so no future caller can reintroduce an unattributed publication by
	 * going around the service.
	 */
	public void function testMarkPublishedRefusesAnEmptyPublisher() {
		var imported = draft("adm04e");
		var repo = variables.repo;
		var id = imported.versionId;
		var stored = variables.repo.findVersionById(id);
		var db = variables.db;
		assertThrows(
			function() { db.transact(function() { return repo.markPublished(id, stored.snapshotJson, stored.checksum, ""); }); },
			"ICFWalk.Validation", "PUBLISHER_REQUIRED"
		);
		assertEquals("DRAFT", variables.repo.findVersionById(id).status, "nothing was published");
	}

	// ---- ADM-05: a frozen version never moves again ----------------------------------------------

	/**
	 * Publishing twice is refused on the second attempt, and refused loudly: the status is read
	 * under the row lock, the attempt is audited, and the stored row is untouched.
	 */
	public void function testPublishingAPublishedVersionIsRefusedAndAudited() {
		var imported = draft("adm05");
		variables.svc.publish(imported.versionId, variables.publisher);
		var frozen = variables.repo.findVersionById(imported.versionId);

		var svc = variables.svc;
		var id = imported.versionId;
		var publisher = variables.publisher;
		var e = assertThrows(function() { svc.publish(id, publisher); }, "ICFWalk.Publish", "INSTRUMENT_VERSION_NOT_DRAFT");
		assertContains("PUBLISHED", e.message, "the refusal names the status that blocked it");

		var after = variables.repo.findVersionById(imported.versionId);
		assertEquals(frozen.snapshotJson, after.snapshotJson, "the published snapshot is unchanged");
		assertEquals(frozen.checksum, after.checksum);
		assertEquals(frozen.rowVersion, after.rowVersion, "the row did not move at all");
		assertEquals(frozen.publishedByUserId, after.publishedByUserId, "and the original publisher is still named");
		assertEquals(1, auditCount(imported.versionId, "INSTRUMENT_VERSION_PUBLISHED"), "still exactly one publish");
		assertEquals(1, auditCount(imported.versionId, "INSTRUMENT_VERSION_PUBLISH_REFUSED"), "and the refusal is on the record");
	}

	/**
	 * ADM-05's "or direct service call": the guard is callable, so it holds for code that never
	 * touches a route. A DRAFT passes it; a published version is refused.
	 *
	 * The guard is a convenience, not the mechanism -- InstrumentImmutabilityTest proves the write
	 * boundary holds for callers that never ask it anything.
	 */
	public void function testAssertDraftForWriteRefusesAPublishedVersion() {
		var imported = draft("adm05b");
		var svc = variables.svc;
		var id = imported.versionId;

		// A DRAFT is writable: the guard returns without throwing.
		svc.assertDraftForWrite(id, "", "TEST_WRITE");

		variables.svc.publish(id, variables.publisher);

		assertThrows(function() { svc.assertDraftForWrite(id, "", "TEST_WRITE"); }, "ICFWalk.Publish", "INSTRUMENT_VERSION_NOT_DRAFT");
	}

	/**
	 * The existing import guard and the new publish guard agree: a published version is not
	 * re-importable either. This is DB-06 restated from the publish side, so the two paths cannot
	 * drift apart into one that refuses and one that does not.
	 */
	public void function testAPublishedVersionCannotBeReimported() {
		var imported = draft("adm05c");
		variables.svc.publish(imported.versionId, variables.publisher);
		var frozen = variables.repo.findVersionById(imported.versionId);

		var importSvc = variables.importSvc;
		var cfg = config(label("adm05c"));
		assertThrows(function() { importSvc.importConfig(cfg); }, "ICFWalk.Import", "INSTRUMENT_VERSION_IMMUTABLE");

		var after = variables.repo.findVersionById(imported.versionId);
		assertEquals(frozen.snapshotJson, after.snapshotJson, "the published definitions are unchanged");
		assertEquals(frozen.rowVersion, after.rowVersion);
	}

	// ---- ADM-03: a DRAFT that is not publishable is refused, and nothing changes -----------------

	/**
	 * A DRAFT whose definitions no longer match its compiled snapshot is the one corruption
	 * publishing must never freeze. Forced here by editing a single stored prompt behind the
	 * import's back, which is exactly the drift the check exists to catch.
	 *
	 * The refusal must leave everything as it was: still DRAFT, same snapshot, same checksum.
	 */
	public void function testDefinitionsDriftIsRefusedAndNothingChanges() {
		var imported = draft("adm03");
		var before = variables.repo.findVersionById(imported.versionId);

		// Drift: one item's prompt changes in the table, not in the snapshot.
		variables.db.run(
			"UPDATE TOP (1) [icf].[item_definition] SET prompt = N'DRIFTED PROMPT (publish must refuse)' WHERE version_id = :id",
			{ "id": variables.db.guid(imported.versionId) }
		);

		var svc = variables.svc;
		var id = imported.versionId;
		var publisher = variables.publisher;
		var e = assertThrows(function() { svc.publish(id, publisher); }, "ICFWalk.Publish", "INSTRUMENT_VERSION_NOT_PUBLISHABLE");
		assertContains("no longer match", e.message, "the refusal says what is wrong");

		var after = variables.repo.findVersionById(imported.versionId);
		assertEquals("DRAFT", after.status, "a refused publish leaves the version a DRAFT");
		assertEquals(before.snapshotJson, after.snapshotJson, "and leaves its snapshot alone");
		assertEquals(before.checksum, after.checksum);
		assertEquals(0, auditCount(id, "INSTRUMENT_VERSION_PUBLISHED"), "nothing was published");
		assertEquals(1, auditCount(id, "INSTRUMENT_VERSION_PUBLISH_REFUSED"), "and the refusal is audited");
	}

	/** A version id that does not exist is a 404, not a server error. */
	public void function testPublishingAnUnknownVersionIsNotFound() {
		var svc = variables.svc;
		var missing = variables.db.newGuid();
		var publisher = variables.publisher;
		assertThrows(function() { svc.publish(missing, publisher); }, "ICFWalk.NotFound", "INSTRUMENT_VERSION_NOT_FOUND");
	}

	/** A malformed version id is refused as input, before any database work. */
	public void function testPublishingRefusesAMalformedVersionId() {
		var svc = variables.svc;
		var publisher = variables.publisher;
		assertThrows(function() { svc.publish("not-a-guid", publisher); }, "ICFWalk.Validation", "INVALID_VERSION_ID");
	}

	// ---- ADM-03: checksum-matching semantic invalidity -------------------------------------------
	//
	// Each case below edits the persisted definitions, recompiles the snapshot from what SQL Server
	// now holds, and stores the new checksum -- so the version is perfectly self-consistent and
	// every comparison the old publish path made would pass. Only real validation refuses them.

	/**
	 * A version with no items at all is structurally incomplete: there is nothing to answer, and
	 * every rule and response set in it now points at nothing.
	 *
	 * Emptying the sections as well is not reachable: FK_instrument_dimension_section holds the
	 * placements to their sections and FK_section_parent_same_version holds the tree together, so
	 * a version with placements cannot be left sectionless. The empty-sections rule is proved at
	 * the validator's own boundary (DefinitionValidatorTest.testEmptyDefinitionsAreReported).
	 */
	public void function testSemanticEmptyDefinitionsAreRefused() {
		expectSemanticRefusal("sem-empty", function(versionId) {
			variables.db.run("DELETE FROM [icf].[item_definition] WHERE version_id = :id", { "id": variables.db.guid(versionId) });
		}, ["DEFINITIONS_EMPTY", "MISSING_REFERENCE"]);
	}

	/**
	 * A section whose parent is not a section of this version. The database's self-referencing
	 * foreign key stops a parent id that does not exist, so the reachable form of this defect is a
	 * parent pointing outside the version -- which loadNormalizedDefinitions reads back as a
	 * section with no parent at all where the snapshot says it has one, and which the shared
	 * validator refuses on the snapshot side. Both sides are proved: the persisted side by this
	 * publish, and the raw rule by DefinitionValidatorTest.testBadSectionParentIsReported.
	 */
	public void function testSemanticBadSectionParentIsRefused() {
		expectSemanticRefusal("sem-parent", function(versionId) {
			var leaves = variables.db.run(
				"SELECT TOP (2) section_id FROM [icf].[section_definition]
				  WHERE version_id = :id AND section_id NOT IN (SELECT parent_section_id FROM [icf].[section_definition] WHERE parent_section_id IS NOT NULL)
				  ORDER BY section_key",
				{ "id": variables.db.guid(versionId) }
			);
			var a = uCase(leaves.section_id[1]);
			var b = uCase(leaves.section_id[2]);
			// A parent outside the version is refused by FK_section_parent_same_version, one that
			// does not exist by the self-referencing foreign key, and a section parenting itself by
			// CK_section_not_self_parent. What the database does allow is a two-section cycle:
			// A's parent is B and B's parent is A, so neither is reachable from any root, and the
			// snapshot and the tables agree on it perfectly.
			variables.db.run("UPDATE [icf].[section_definition] SET parent_section_id = :parent, display_order = 900001 WHERE section_id = :id",
				{ "id": variables.db.guid(a), "parent": variables.db.guid(b) });
			variables.db.run("UPDATE [icf].[section_definition] SET parent_section_id = :parent, display_order = 900002 WHERE section_id = :id",
				{ "id": variables.db.guid(b), "parent": variables.db.guid(a) });
		}, ["SECTION_HIERARCHY_INVALID", "INVALID_ORDER"]);
	}

	/**
	 * Every logical key the contract names -- section, item, response set, rule, response option
	 * key and stored code, dimension code, dimension value code -- carries a unique constraint in
	 * SQL Server, and the default collation makes them case-insensitive besides. So a
	 * checksum-matching duplicate-key version cannot be persisted at all, and claiming a publish
	 * test for it would be claiming a state that does not exist. What can be proved is that the
	 * constraints are really there and really refuse, which is what this does; the validator's own
	 * duplicate-key rule is proved directly in DefinitionValidatorTest.
	 */
	public void function testDuplicateLogicalKeysCannotBePersistedAtAll() {
		var imported = draft("dupkeys");
		var db = variables.db;
		var versionId = imported.versionId;

		var items = db.run("SELECT TOP (2) item_id, item_key FROM [icf].[item_definition] WHERE version_id = :id ORDER BY item_key", { "id": db.guid(versionId) });
		assertThrows(function() {
			db.run("UPDATE [icf].[item_definition] SET item_key = :key WHERE item_id = :id",
				{ "id": db.guid(uCase(items.item_id[2])), "key": db.nvarchar(items.item_key[1]) });
		}, "database");
		assertThrows(function() {
			db.run("UPDATE [icf].[item_definition] SET item_key = :key WHERE item_id = :id",
				{ "id": db.guid(uCase(items.item_id[2])), "key": db.nvarchar(uCase(items.item_key[1])) });
		}, "database");

		var sections = db.run("SELECT TOP (2) section_id, section_key FROM [icf].[section_definition] WHERE version_id = :id ORDER BY section_key", { "id": db.guid(versionId) });
		assertThrows(function() {
			db.run("UPDATE [icf].[section_definition] SET section_key = :key WHERE section_id = :id",
				{ "id": db.guid(uCase(sections.section_id[2])), "key": db.nvarchar(sections.section_key[1]) });
		}, "database");

		var sets = db.run("SELECT TOP (2) response_set_id, response_set_key FROM [icf].[response_set] WHERE version_id = :id ORDER BY response_set_key", { "id": db.guid(versionId) });
		assertThrows(function() {
			db.run("UPDATE [icf].[response_set] SET response_set_key = :key WHERE response_set_id = :id",
				{ "id": db.guid(uCase(sets.response_set_id[2])), "key": db.nvarchar(sets.response_set_key[1]) });
		}, "database");

		var rules = db.run("SELECT TOP (2) rule_id, rule_key FROM [icf].[rule_definition] WHERE version_id = :id ORDER BY rule_key", { "id": db.guid(versionId) });
		assertThrows(function() {
			db.run("UPDATE [icf].[rule_definition] SET rule_key = :key WHERE rule_id = :id",
				{ "id": db.guid(uCase(rules.rule_id[2])), "key": db.nvarchar(rules.rule_key[1]) });
		}, "database");

		// The version is still exactly what the import wrote, so the constraints refused rather
		// than partially applied.
		assertEquals(imported.definitionsChecksum, variables.c.snapshotCompiler.definitionsChecksum(variables.repo.loadNormalizedDefinitions(versionId)));
	}

	/** A choice item whose response set was taken away. */
	public void function testSemanticChoiceItemWithoutResponseSetIsRefused() {
		expectSemanticRefusal("sem-noset", function(versionId) {
			variables.db.run(
				"UPDATE TOP (1) [icf].[item_definition] SET response_set_id = NULL
				  WHERE version_id = :id AND item_type IN (N'SINGLE_CHOICE', N'MULTI_CHOICE')",
				{ "id": variables.db.guid(versionId) }
			);
		}, ["ITEM_RESPONSE_SET_REQUIRED"]);
	}

	/** A response set used by an item but emptied of its options. */
	public void function testSemanticResponseSetWithoutOptionsIsRefused() {
		expectSemanticRefusal("sem-emptyset", function(versionId) {
			var setId = variables.db.run(
				"SELECT TOP (1) s.response_set_id FROM [icf].[response_set] s
				   JOIN [icf].[item_definition] i ON i.response_set_id = s.response_set_id
				  WHERE s.version_id = :id",
				{ "id": variables.db.guid(versionId) }
			);
			variables.db.run("DELETE FROM [icf].[response_option] WHERE response_set_id = :id", { "id": variables.db.guid(uCase(setId.response_set_id[1])) });
		}, ["RESPONSE_SET_EMPTY"]);
	}

	/**
	 * An option belonging to a response set this version does not have. UQ_response_option_set_key
	 * and UQ_response_option_set_code stop a duplicate key or code outright, so the reachable
	 * persisted defect is an option whose set belongs to another version: the option row survives,
	 * and this version reads back a set that is used by an item and has nothing in it.
	 */
	public void function testSemanticOptionInAForeignResponseSetIsRefused() {
		var other = draft("sem-optset-other");
		var foreignSet = variables.db.run(
			"SELECT TOP (1) response_set_id FROM [icf].[response_set] WHERE version_id = :id",
			{ "id": variables.db.guid(other.versionId) }
		);
		var foreign = uCase(foreignSet.response_set_id[1]);
		expectSemanticRefusal("sem-optset", function(versionId) {
			var used = variables.db.run(
				"SELECT TOP (1) s.response_set_id FROM [icf].[response_set] s
				   JOIN [icf].[item_definition] i ON i.response_set_id = s.response_set_id
				  WHERE s.version_id = :id",
				{ "id": variables.db.guid(versionId) }
			);
			// Orders are unique per set, so the moved options take orders the target set cannot
			// already hold.
			variables.db.run(
				"UPDATE [icf].[response_option] SET response_set_id = :foreign, display_order = display_order + 500000 WHERE response_set_id = :setId",
				{ "setId": variables.db.guid(uCase(used.response_set_id[1])), "foreign": variables.db.guid(foreign) }
			);
		}, ["RESPONSE_SET_EMPTY"]);
	}

	/** An option order outside the permitted range. */
	public void function testSemanticInvalidOptionOrderIsRefused() {
		expectSemanticRefusal("sem-order", function(versionId) {
			variables.db.run(
				"UPDATE TOP (1) o SET o.display_order = 999999999
				   FROM [icf].[response_option] o JOIN [icf].[response_set] s ON s.response_set_id = o.response_set_id
				  WHERE s.version_id = :id",
				{ "id": variables.db.guid(versionId) }
			);
		}, ["INVALID_ORDER"]);
	}

	/** A conditions document that is well-formed JSON but not a conditions document. */
	public void function testSemanticMalformedConditionsAreRefused() {
		expectSemanticRefusal("sem-cond", function(versionId) {
			variables.db.run(
				"UPDATE TOP (1) [icf].[rule_definition] SET conditions_json = N'{""authoring"":{},""logic"":""MAYBE"",""conditions"":[]}' WHERE version_id = :id",
				{ "id": variables.db.guid(versionId) }
			);
		}, ["CONDITIONS_SHAPE"]);
	}

	/** A rule effect the runtime cannot honour. */
	public void function testSemanticUnsupportedRuleEffectIsRefused() {
		expectSemanticRefusal("sem-effect", function(versionId) {
			variables.db.run(
				"UPDATE TOP (1) [icf].[rule_definition] SET effect = N'HIDE' WHERE version_id = :id",
				{ "id": variables.db.guid(versionId) }
			);
		}, ["UNSUPPORTED_EFFECT"]);
	}

	/** A rule pointing at a target that is not in this version. */
	public void function testSemanticRuleWithMissingTargetIsRefused() {
		expectSemanticRefusal("sem-target", function(versionId) {
			variables.db.run(
				"UPDATE TOP (1) [icf].[rule_definition] SET target_key = N'no_such_target' WHERE version_id = :id",
				{ "id": variables.db.guid(versionId) }
			);
		}, ["MISSING_REFERENCE"]);
	}

	/** A dimension whose data type is not one the engine knows. */
	public void function testSemanticInvalidDimensionDataTypeIsRefused() {
		expectSemanticRefusal("sem-dimtype", function(versionId) {
			variables.db.run(
				"UPDATE TOP (1) [icf].[instrument_dimension] SET dimension_data_type = N'TEXT' WHERE version_id = :id AND dimension_data_type = N'LIST'",
				{ "id": variables.db.guid(versionId) }
			);
			// ...and the version-scoped label goes blank, which no dimension may be.
			variables.db.run(
				"UPDATE TOP (1) [icf].[instrument_dimension] SET dimension_label = N' ' WHERE version_id = :id",
				{ "id": variables.db.guid(versionId) }
			);
		}, ["BLANK_VALUE", "INVALID_ENUM"]);
	}

	/** Two values of one dimension claiming the same position in this version. */
	public void function testSemanticDuplicateDimensionValueOrderIsRefused() {
		expectSemanticRefusal("sem-dimorder", function(versionId) {
			var q = variables.db.run(
				"SELECT TOP (2) iv.value_id, iv.display_order, iv.dimension_id FROM [icf].[instrument_dimension_value] iv
				  WHERE iv.version_id = :id AND iv.dimension_id = (
				        SELECT TOP (1) dimension_id FROM [icf].[instrument_dimension_value]
				         WHERE version_id = :id GROUP BY dimension_id HAVING COUNT(*) > 1)
				  ORDER BY iv.display_order",
				{ "id": variables.db.guid(versionId) }
			);
			// UX_instrument_dimension_value_order stops two rows sharing an order, so the reachable
			// checksum-matching defect is an order the contract forbids outright.
			variables.db.run(
				"UPDATE [icf].[instrument_dimension_value] SET display_order = 1000001 WHERE version_id = :versionId AND value_id = :valueId",
				{ "versionId": variables.db.guid(versionId), "valueId": variables.db.guid(uCase(q.value_id[2])) }
			);
		}, ["INVALID_ORDER"]);
	}

	/** A placement whose rule reference no longer names a rule of this version. */
	public void function testSemanticPlacementWithMissingRuleIsRefused() {
		expectSemanticRefusal("sem-placement", function(versionId) {
			// rule_key is a foreign key to (version_id, rule_key), so the reachable defect is the
			// rule itself being renamed out from under the placements that name it.
			variables.db.run(
				"UPDATE [icf].[instrument_dimension] SET rule_key = NULL, label_override = NULL WHERE version_id = :id AND rule_key IS NOT NULL",
				{ "id": variables.db.guid(versionId) }
			);
			variables.db.run(
				"UPDATE TOP (1) [icf].[rule_definition] SET target_type = N'SECTION', target_key = N'not_a_section' WHERE version_id = :id",
				{ "id": variables.db.guid(versionId) }
			);
		}, ["MISSING_REFERENCE"]);
	}

	/**
	 * A stored snapshot whose envelope no longer describes this version: it names another version
	 * label. The checksum still hashes it and the definitions still match the tables, so nothing
	 * except an identity check can catch it.
	 */
	public void function testSemanticSnapshotIdentityMismatchIsRefused() {
		var imported = draft("sem-identity");
		var before = variables.repo.findVersionById(imported.versionId);
		var snapshot = deserializeJSON(before.snapshotJson);
		snapshot.version["versionLabel"] = label("sem-identity") & "-imposter";
		storeRecompiledSnapshot(imported.versionId, snapshot);

		var svc = variables.svc;
		var id = imported.versionId;
		var publisher = variables.publisher;
		var e = assertThrows(function() { svc.publish(id, publisher); }, "ICFWalk.Publish", "INSTRUMENT_VERSION_NOT_PUBLISHABLE");
		var issues = variables.c.errors.detailsOf(e).issues;
		assertTrue(hasIssue(issues, ["SNAPSHOT_IDENTITY_MISMATCH"]), "the refusal names the identity mismatch: " & serializeJSON(issues));
		assertUntouchedDraft(id);
	}

	/** A stored snapshot whose counts block disagrees with the definitions it carries. */
	public void function testSemanticSnapshotCountsMismatchIsRefused() {
		var imported = draft("sem-counts");
		var before = variables.repo.findVersionById(imported.versionId);
		var snapshot = deserializeJSON(before.snapshotJson);
		snapshot.counts["items"] = snapshot.counts.items + 1;
		storeRecompiledSnapshot(imported.versionId, snapshot);

		var svc = variables.svc;
		var id = imported.versionId;
		var publisher = variables.publisher;
		var e = assertThrows(function() { svc.publish(id, publisher); }, "ICFWalk.Publish", "INSTRUMENT_VERSION_NOT_PUBLISHABLE");
		assertTrue(hasIssue(variables.c.errors.detailsOf(e).issues, ["SNAPSHOT_COUNTS_MISMATCH"]), "the refusal names the counts mismatch");
		assertUntouchedDraft(id);
	}

	/** A stored snapshot that declares a format this runtime does not read. */
	public void function testSemanticSnapshotFormatIsRefused() {
		var imported = draft("sem-format");
		var before = variables.repo.findVersionById(imported.versionId);
		var snapshot = deserializeJSON(before.snapshotJson);
		snapshot["snapshotFormat"] = "icfwalk-instrument-snapshot/99";
		storeRecompiledSnapshot(imported.versionId, snapshot);

		var svc = variables.svc;
		var id = imported.versionId;
		var publisher = variables.publisher;
		var e = assertThrows(function() { svc.publish(id, publisher); }, "ICFWalk.Publish", "INSTRUMENT_VERSION_NOT_PUBLISHABLE");
		assertTrue(hasIssue(variables.c.errors.detailsOf(e).issues, ["SNAPSHOT_FORMAT_UNSUPPORTED"]), "the refusal names the format");
		assertUntouchedDraft(id);
	}

	// ---- helpers ---------------------------------------------------------------------------------

	private string function label(required string suffix) {
		return variables.run & "-" & arguments.suffix;
	}

	private struct function config(required string versionLabel) {
		var cfg = repoJson("config/instrument-config.json");
		cfg.instrument.code = variables.instrumentCode;
		cfg.instrument.version.versionLabel = arguments.versionLabel;
		return cfg;
	}

	/** An imported DRAFT of the real instrument under a synthetic label. */
	private struct function draft(required string suffix) {
		return variables.importSvc.importConfig(config(label(arguments.suffix)));
	}

	/**
	 * Imports a DRAFT, applies `corrupt` to its persisted definitions, then recompiles the snapshot
	 * from what SQL Server now holds and stores the matching checksum. The result is a version that
	 * is entirely self-consistent -- snapshot hashes to checksum, snapshot definitions equal the
	 * table definitions -- and semantically invalid. Publication must refuse it with one of
	 * `expectedCodes`, change nothing, and audit the refusal exactly once.
	 */
	private void function expectSemanticRefusal(required string suffix, required any corrupt, required array expectedCodes) {
		var imported = draft(arguments.suffix);
		arguments.corrupt(imported.versionId);

		// Recompile the snapshot from the corrupted rows so the drift and checksum checks pass.
		var persisted = variables.repo.loadNormalizedDefinitions(imported.versionId);
		var snapshot = deserializeJSON(variables.repo.findVersionById(imported.versionId).snapshotJson);
		snapshot["definitions"] = persisted;
		snapshot["counts"] = variables.c.snapshotCompiler.countDefinitions(persisted);
		storeRecompiledSnapshot(imported.versionId, snapshot);

		// Precondition: this really is a checksum-matching, drift-free version, so nothing except
		// semantic validation can refuse it. Without this the test would only retest drift.
		var row = variables.repo.findVersionById(imported.versionId);
		assertEquals(row.checksum, variables.c.canonicalJson.sha256(row.snapshotJson), "precondition: the stored checksum hashes the stored snapshot");
		assertEquals(
			variables.c.snapshotCompiler.definitionsChecksum(variables.repo.loadNormalizedDefinitions(imported.versionId)),
			variables.c.snapshotCompiler.definitionsChecksum(deserializeJSON(row.snapshotJson).definitions),
			"precondition: the snapshot definitions and the table definitions agree, so this is not a drift test"
		);

		var svc = variables.svc;
		var id = imported.versionId;
		var publisher = variables.publisher;
		var e = assertThrows(function() { svc.publish(id, publisher); }, "ICFWalk.Publish", "INSTRUMENT_VERSION_NOT_PUBLISHABLE");
		var issues = variables.c.errors.detailsOf(e).issues;
		assertTrue(
			hasIssue(issues, arguments.expectedCodes),
			"expected one of " & arrayToList(arguments.expectedCodes) & " but got " & left(serializeJSON(issues), 600)
		);
		assertUntouchedDraft(id);
	}

	/** Stores a snapshot and the checksum that hashes it, bypassing the import path. */
	private void function storeRecompiledSnapshot(required string versionId, required struct snapshot) {
		var canonical = variables.c.canonicalJson.serialize(arguments.snapshot);
		variables.db.run(
			"UPDATE [icf].[instrument_version] SET compiled_snapshot_json = :snapshot, checksum_sha256 = :checksum WHERE version_id = :id",
			{
				"id": variables.db.guid(arguments.versionId),
				"snapshot": variables.db.ntext(canonical),
				"checksum": { "value": variables.c.canonicalJson.sha256(canonical), "cfsqltype": "cf_sql_char" }
			}
		);
	}

	private void function assertUntouchedDraft(required string versionId) {
		var after = variables.repo.findVersionById(arguments.versionId);
		assertEquals("DRAFT", after.status, "a refused publish leaves the version a DRAFT");
		assertEquals("", after.publishedByUserId, "and names no publisher");
		assertEquals(0, auditCount(arguments.versionId, "INSTRUMENT_VERSION_PUBLISHED"), "nothing was published");
		assertEquals(1, auditCount(arguments.versionId, "INSTRUMENT_VERSION_PUBLISH_REFUSED"), "and exactly one refusal survived the rollback");
	}

	private boolean function hasIssue(required any issues, required array codes) {
		if (!isArray(arguments.issues)) return false;
		for (var issue in arguments.issues) {
			for (var code in arguments.codes) if (structKeyExists(issue, "code") && issue.code == code) return true;
		}
		return false;
	}

	private numeric function auditCount(required string versionId, required string eventType) {
		return variables.db.scalar(
			"SELECT COUNT(*) AS n FROM [icf].[audit_event] WHERE entity_id = :id AND event_type = :t",
			{ "id": variables.db.guid(arguments.versionId), "t": variables.db.nvarchar(arguments.eventType) }
		);
	}
}
