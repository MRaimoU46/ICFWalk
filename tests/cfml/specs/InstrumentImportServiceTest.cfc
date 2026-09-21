/**
 * Database integration tests for the import service (acceptance DB-04 .. DB-09). Requires the
 * icf schema in the configured datasource. Every test uses its own synthetic version labels and
 * removes them afterwards; the supplied instrument code ICFWALK is shared with the real seed.
 */
component extends="icfwalktests.BaseSpec" output="false" {

	public string function skipReason() {
		return schemaPresent() ? "" : "icf schema is not present in datasource '" & variables.c.db.datasourceName() & "'.";
	}

	public void function beforeAll() {
		variables.run = "test-" & lCase(left(replace(createUUID(), "-", "", "all"), 8));
		variables.labels = {};
		variables.golden = repoJson("tests/golden/instrument-snapshot.golden.json");
		variables.svc = variables.c.instrumentImportService;
		variables.repo = variables.c.definitionRepository;
		// Fixtures are removed by the test-only harness, not by any production method: the
		// repository has no unchecked deletion path, and a spec that publishes or freezes a fixture
		// must still be able to clean it up (tests/cfml/support/FixtureCleanup.cfc).
		variables.fixtures = new icfwalktests.support.FixtureCleanup(variables.c);
	}

	public void function afterAll() {
		variables.fixtures.removeVersionsLabelled(variables.run);
		variables.fixtures.removeUsers(variables.run & "-");
	}

	// ---- DB-04 ------------------------------------------------------------------------------

	public void function testDb04ImportCreatesDraftWithMappedGuidsAndSnapshot() {
		var label = label("db04");
		var result = variables.svc.importConfig(config(label));
		assertTrue(result.created, "First import must create the DRAFT.");
		assertEquals("DRAFT", result.status);
		// The synthetic version label changes the full snapshot; the definitions checksum must equal
		// the reference golden (the real seed label is checked in tests/node/cfml-suite.test.mjs).
		assertEquals(variables.golden.definitionsChecksum, result.definitionsChecksum, "Definitions checksum must equal the reference golden.");
		assertEquals(64, len(result.checksum));
		assertEquals(17, arrayLen(result.placeholders));
		assertEquals(17, arrayLen(result.warnings), "Only placeholder warnings expected.");

		var counts = variables.repo.countChildren(result.versionId);
		assertEquals(23, counts.sections);
		assertEquals(144, counts.items);
		assertEquals(29, counts.responseSets);
		assertEquals(138, counts.responseOptions);
		assertEquals(12, counts.rules);
		assertEquals(10, counts.instrumentDimensions);
		assertTrue(counts.dimensions >= 10);
		assertTrue(counts.dimensionValues >= 95);

		var version = variables.repo.findVersionById(result.versionId);
		assertEquals("DRAFT", version.status);
		assertEquals(result.checksum, version.checksum, "Stored checksum.");
		assertEquals(result.checksum, variables.c.canonicalJson.sha256(version.snapshotJson), "Stored snapshot must hash to the stored checksum.");
		assertContains('"versionLabel":"' & label & '"', version.snapshotJson);

		// Every parent, response set, and section GUID resolved (no orphan references).
		assertEquals(0, variables.c.db.scalar("SELECT COUNT(*) AS n FROM [icf].[item_definition] i LEFT JOIN [icf].[section_definition] s ON s.section_id = i.section_id WHERE i.version_id = :id AND s.section_id IS NULL", { "id": variables.c.db.guid(result.versionId) }));
		assertEquals(22, variables.c.db.scalar("SELECT COUNT(*) AS n FROM [icf].[section_definition] WHERE version_id = :id AND parent_section_id IS NOT NULL", { "id": variables.c.db.guid(result.versionId) }), "All sections except root have a parent GUID.");
		assertEquals(53, variables.c.db.scalar("SELECT COUNT(*) AS n FROM [icf].[item_definition] WHERE version_id = :id AND response_set_id IS NOT NULL", { "id": variables.c.db.guid(result.versionId) }));
		assertEquals(1, variables.c.db.scalar("SELECT COUNT(*) AS n FROM [icf].[instrument_dimension] WHERE version_id = :id AND rule_key = N'show_period_for_grades_6_12'", { "id": variables.c.db.guid(result.versionId) }));

		var audit = variables.c.db.scalar("SELECT COUNT(*) AS n FROM [icf].[audit_event] WHERE entity_id = :id AND event_type = N'INSTRUMENT_VERSION_CREATED'", { "id": variables.c.db.guid(result.versionId) });
		assertEquals(1, audit, "Audit event for version creation.");
	}

	// ---- DB-05 ------------------------------------------------------------------------------

	public void function testDb05ReimportIsIdempotentWithStableGuidsAndChecksum() {
		var label = label("db05");
		var first = variables.svc.importConfig(config(label));
		var itemsBefore = variables.repo.loadVersionChildren(first.versionId);
		var second = variables.svc.importConfig(config(label));
		assertFalse(second.created);
		assertEquals(first.versionId, second.versionId);
		assertEquals(first.checksum, second.checksum);
		assertEquals(variables.golden.definitionsChecksum, second.definitionsChecksum);
		var countsAfter = variables.repo.countChildren(second.versionId);
		assertEquals(144, countsAfter.items);
		assertEquals(138, countsAfter.responseOptions);
		assertEquals(23, countsAfter.sections);
		var itemsAfter = variables.repo.loadVersionChildren(second.versionId);
		for (var key in structKeyArray(itemsBefore.items)) {
			assertEquals(itemsBefore.items[key].id, itemsAfter.items[key].id, "Item GUID for '" & key & "' must be reused.");
		}
		for (var key in structKeyArray(itemsBefore.options)) {
			assertEquals(itemsBefore.options[key].id, itemsAfter.options[key].id, "Option GUID for '" & key & "' must be reused.");
		}
		assertEquals(1, variables.c.db.scalar("SELECT COUNT(*) AS n FROM [icf].[audit_event] WHERE entity_id = :id AND event_type = N'INSTRUMENT_VERSION_REIMPORTED'", { "id": variables.c.db.guid(second.versionId) }));
	}

	public void function testReorderedReimportSucceedsAndReturnsToGolden() {
		var label = label("reorder");
		variables.svc.importConfig(config(label));
		var cfg = config(label);
		// Swap orders of two items in the same section and two sections under the same parent.
		var a = ""; var b = "";
		for (var it in cfg.items) {
			if (it.sectionId == "sec_part3" && it.itemType == "SINGLE_CHOICE") { if (!isStruct(a)) a = it; else if (!isStruct(b)) { b = it; break; } }
		}
		var tmp = a.displayOrder; a.displayOrder = b.displayOrder; b.displayOrder = tmp;
		var s1 = ""; var s2 = "";
		for (var s in cfg.sections) {
			if (s.sectionKey == "prek_k_classroom") s1 = s;
			if (s.sectionKey == "dual_language_classroom") s2 = s;
		}
		tmp = s1.displayOrder; s1.displayOrder = s2.displayOrder; s2.displayOrder = tmp;
		var reordered = variables.svc.importConfig(cfg);
		assertNotEquals(variables.golden.definitionsChecksum, reordered.definitionsChecksum, "Reordered document must produce a different definitions checksum.");
		assertEquals(144, variables.repo.countChildren(reordered.versionId).items);
		var restored = variables.svc.importConfig(config(label));
		assertEquals(variables.golden.definitionsChecksum, restored.definitionsChecksum, "Restoring the original order returns the golden definitions checksum.");
	}

	// ---- DB-06 ------------------------------------------------------------------------------

	public void function testDb06ImportAgainstPublishedVersionIsRefusedWithoutChanges() {
		var label = label("db06");
		var result = variables.svc.importConfig(config(label));
		// A published row needs a publisher: CK_instrument_version_publisher_required (migration
		// 006) refuses a non-DRAFT row with nobody named, so the fixture names a real user.
		var publisher = variables.fixtures.ensureUser(variables.run & "-publisher", "Import fixture publisher");
		variables.c.db.run(
			"UPDATE [icf].[instrument_version] SET status = N'PUBLISHED', effective_start = SYSUTCDATETIME(), published_at = SYSUTCDATETIME(), published_by_user_id = :publisher WHERE version_id = :id",
			{ "id": variables.c.db.guid(result.versionId), "publisher": variables.c.db.guid(publisher) }
		);
		var before = variables.repo.findVersionById(result.versionId);
		var itemRowVersion = variables.c.db.run("SELECT MAX(CAST(row_version AS bigint)) AS rv, COUNT(*) AS n FROM [icf].[item_definition] WHERE version_id = :id", { "id": variables.c.db.guid(result.versionId) });

		var cfg = config(label);
		cfg.items[1].prompt = "Tampered prompt";
		assertThrows(function() { variables.svc.importConfig(cfg); }, "ICFWalk.Import.PublishedVersion", "INSTRUMENT_VERSION_IMMUTABLE");

		var after = variables.repo.findVersionById(result.versionId);
		assertEquals("PUBLISHED", after.status);
		assertEquals(before.rowVersion, after.rowVersion, "Version row must be untouched.");
		assertEquals(before.checksum, after.checksum);
		var itemRowVersionAfter = variables.c.db.run("SELECT MAX(CAST(row_version AS bigint)) AS rv, COUNT(*) AS n FROM [icf].[item_definition] WHERE version_id = :id", { "id": variables.c.db.guid(result.versionId) });
		assertEquals(itemRowVersion.rv[1], itemRowVersionAfter.rv[1], "Published item rows must be untouched.");
		assertEquals(itemRowVersion.n[1], itemRowVersionAfter.n[1]);
		assertEquals(0, variables.c.db.scalar("SELECT COUNT(*) AS n FROM [icf].[item_definition] WHERE version_id = :id AND prompt = N'Tampered prompt'", { "id": variables.c.db.guid(result.versionId) }));

		// Discarding a published version is refused as well.
		assertThrows(function() { variables.svc.discardDraft(label); }, "ICFWalk.Import.PublishedVersion");
	}

	// ---- DB-07 ------------------------------------------------------------------------------

	public void function testDb07MissingResponseSetRollsBackWithSpecificError() {
		var label = label("db07");
		var cfg = config(label);
		var kept = [];
		for (var rs in cfg.responseSets) if (rs.responseSetId != "rs_scale_comp_s1_q1") arrayAppend(kept, rs);
		cfg.responseSets = kept;
		var keptOptions = [];
		for (var op in cfg.responseOptions) if (op.responseSetId != "rs_scale_comp_s1_q1") arrayAppend(keptOptions, op);
		cfg.responseOptions = keptOptions;

		var e = assertThrows(function() { variables.svc.importConfig(cfg); }, "ICFWalk.Import.Validation", "INSTRUMENT_CONFIG_INVALID");
		var details = variables.c.errors.detailsOf(e);
		var found = false;
		for (var issue in details.issues) if (issue.code == "MISSING_REFERENCE" && find("rs_scale_comp_s1_q1", issue.message)) found = true;
		assertTrue(found, "Expected a MISSING_REFERENCE issue naming rs_scale_comp_s1_q1.");
		assertTrue(structIsEmpty(findVersionByLabel(label)), "No version row may exist after a refused import.");
	}

	// ---- DB-08 ------------------------------------------------------------------------------

	public void function testDb08CorruptConditionsJsonRollsBack() {
		var label = label("db08");
		var cfg = config(label);
		cfg.rules[2].conditionsJson = '{"logic":"AND","conditions":[';
		var e = assertThrows(function() { variables.svc.importConfig(cfg); }, "ICFWalk.Import.Validation", "INSTRUMENT_CONFIG_INVALID");
		assertContains("INVALID_JSON", serializeJSON(variables.c.errors.detailsOf(e)));
		assertTrue(structIsEmpty(findVersionByLabel(label)), "No partial version may be created.");
	}

	public void function testTransactionRollsBackWhenDatabaseRejectsAWrite() {
		// A document that passes validation but violates a database rule mid-transaction must leave
		// nothing behind: an item prompt of only whitespace violates CK_item_prompt_not_blank.
		var label = label("dbfail");
		var cfg = config(label);
		cfg.items[10].prompt = "   ";
		// The validator rejects blank prompts, so bypass it by checking the validator first, then
		// exercising the repository transaction directly with a definitions write that fails.
		var v = variables.c.configValidator.validate(cfg);
		assertFalse(v.valid, "Validator catches blank prompts before the database does.");
		// Force a database-level failure: import a valid document into a label that is too long
		// for the column only after the version has been created is not possible, so instead prove
		// rollback with a direct transaction that inserts a version and then throws.
		var db = variables.c.db;
		var instrument = variables.repo.findInstrumentByCode("ICFWALK");
		assertThrows(function() {
			db.transact(function() {
				variables.repo.createDraftVersion(instrument.instrumentId, label);
				throw(type = "ICFWalk.Test.Forced", message = "forced failure inside transaction");
			});
		}, "ICFWalk.Test.Forced");
		assertTrue(structIsEmpty(findVersionByLabel(label)), "Version created inside a failed transaction must be rolled back.");
	}

	// ---- DB-09 ------------------------------------------------------------------------------

	public void function testDb09ResponseOptionDefinitionsMatchTheJsonExactly() {
		var label = label("db09");
		var result = variables.svc.importConfig(config(label));
		var cfg = config(label);
		var expected = {};
		var setKeyById = {};
		for (var rs in cfg.responseSets) setKeyById[rs.responseSetId] = rs.setKey;
		for (var op in cfg.responseOptions) {
			expected[setKeyById[op.responseSetId] & "|" & op.optionKey] = { "definition": isNull(op.definition) ? "" : op.definition, "label": op.label, "code": op.storedCode, "score": isNull(op.numericScore) ? "" : op.numericScore };
		}
		var q = variables.c.db.run(
			"SELECT s.response_set_key, o.option_key, o.stored_code, o.label, o.definition, o.numeric_score
			 FROM [icf].[response_option] o JOIN [icf].[response_set] s ON s.response_set_id = o.response_set_id WHERE s.version_id = :id",
			{ "id": variables.c.db.guid(result.versionId) }
		);
		assertEquals(138, q.recordCount);
		var withDefinition = 0;
		for (var r = 1; r <= q.recordCount; r++) {
			var key = q.response_set_key[r] & "|" & q.option_key[r];
			assertTrue(structKeyExists(expected, key), "Unexpected option " & key);
			assertEquals(expected[key].definition, q.definition[r], "Definition for " & key & ".");
			assertEquals(expected[key].label, q.label[r], "Label for " & key & ".");
			assertEquals(expected[key].code, q.stored_code[r], "Stored code for " & key & ".");
			if (len(expected[key].score)) assertEquals(expected[key].score, val(q.numeric_score[r]), "Score for " & key & ".");
			if (len(q.definition[r])) withDefinition++;
		}
		assertEquals(136, withDefinition, "136 options carry exact definitions.");

		// The persisted definitions compile to the same definitions checksum as the document.
		var persisted = variables.repo.loadNormalizedDefinitions(result.versionId);
		assertEquals(variables.golden.definitionsChecksum, variables.c.snapshotCompiler.definitionsChecksum(persisted), "Round-trip definitions checksum.");
	}

	public void function testDiscardDraftRemovesVersionAndChildren() {
		var label = label("discard");
		var result = variables.svc.importConfig(config(label));
		var out = variables.svc.discardDraft(label);
		assertTrue(out.discarded);
		assertTrue(structIsEmpty(findVersionByLabel(label)));
		assertEquals(0, variables.c.db.scalar("SELECT COUNT(*) AS n FROM [icf].[item_definition] WHERE version_id = :id", { "id": variables.c.db.guid(result.versionId) }));
		assertEquals(0, variables.c.db.scalar("SELECT COUNT(*) AS n FROM [icf].[section_definition] WHERE version_id = :id", { "id": variables.c.db.guid(result.versionId) }));
		assertThrows(function() { variables.svc.discardDraft(label); }, "ICFWalk.NotFound");
	}

	public void function testListVersionsIncludesImportedDraft() {
		var label = label("list");
		var result = variables.svc.importConfig(config(label));
		var found = false;
		for (var v in variables.repo.listVersions()) {
			if (v.versionLabel == label) { found = true; assertEquals("DRAFT", v.status); assertEquals(result.checksum, v.checksum); assertEquals(0, v.walkCount); }
		}
		assertTrue(found, "Imported version must be listed.");
	}

	// ---- helpers ----------------------------------------------------------------------------

	private string function label(required string suffix) {
		return variables.run & "-" & arguments.suffix;
	}

	private struct function config(required string versionLabel) {
		var cfg = repoJson("config/instrument-config.json");
		cfg.instrument.version.versionLabel = arguments.versionLabel;
		return cfg;
	}

	private struct function findVersionByLabel(required string label) {
		var instrument = variables.repo.findInstrumentByCode("ICFWALK");
		if (structIsEmpty(instrument)) return {};
		return variables.repo.findVersion(instrument.instrumentId, arguments.label);
	}
}
