/**
 * The Excel round-trip starts from InstrumentDocumentExporter: a stored version turned back into the
 * authoring document an import takes. Everything the workbook does rests on that inverse being
 * exact, so it is proved here rather than assumed:
 *
 *   - the supplied instrument, normalized and exported, normalizes back to the same definitions
 *     checksum AND the same whole-snapshot checksum;
 *   - the export passes the authoring validator exactly as the supplied document does (no errors,
 *     the same seventeen placeholder warnings, no content-review mismatch);
 *   - every row keeps its own authoring id and every reference resolves to the id it had;
 *   - rows come out in reading order (sections in tree order, questions by section);
 *   - a PUBLISHED version exported and imported under a new label is a DRAFT with exactly the
 *     published definitions, and the published version does not move.
 */
component extends="icfwalktests.BaseSpec" output="false" {

	public void function beforeAll() {
		variables.exporter = variables.c.instrumentDocumentExporter;
		variables.normalizer = variables.c.configNormalizer;
		variables.compiler = variables.c.snapshotCompiler;
		variables.source = repoJson("config/instrument-config.json");
		variables.normalized = variables.normalizer.fromConfig(variables.source);
		variables.exported = variables.exporter.toDocument(variables.normalized);
	}

	// ---- the inverse ----------------------------------------------------------------------------

	public void function testTheExportNormalizesBackToTheSameVersion() {
		var original = variables.compiler.compile(variables.normalized);
		var roundTrip = variables.compiler.compile(variables.normalizer.fromConfig(variables.exported));
		assertExactTextEquals(original.definitionsChecksum, roundTrip.definitionsChecksum, "the same definitions");
		assertExactTextEquals(original.checksum, roundTrip.checksum, "and the same whole snapshot");
	}

	public void function testTheExportPassesTheAuthoringValidatorLikeTheSuppliedDocument() {
		var fromSource = variables.c.configValidator.validate(variables.source);
		var fromExport = variables.c.configValidator.validate(variables.exported);
		assertTrue(fromExport.valid, "valid: " & serializeJSON(fromExport.errors));
		assertEquals(0, arrayLen(fromExport.errors));
		assertEquals(arrayLen(fromSource.warnings), arrayLen(fromExport.warnings), "the same warnings");
		assertEquals(17, arrayLen(fromExport.placeholders));
		for (var w in fromExport.warnings) {
			assertExactTextNotEquals("CONTENT_REVIEW_MISMATCH", w.code, "the placeholder summary still agrees with the items");
		}
	}

	public void function testEveryRowKeepsItsAuthoringIdAndItsReferences() {
		var item = rowWhere(variables.exported.items, "itemKey", "prek_k_q1");
		assertExactTextEquals("item_prek_k_q1", item.itemId);
		assertExactTextEquals("sec_prek_k", item.sectionId);
		assertExactTextEquals("rs_yes_no", item.responseSetId);
		assertExactTextEquals("1 - Question place holder", item.prompt);

		var rule = rowWhere(variables.exported.rules, "ruleKey", "show_prek_k");
		assertExactTextEquals("rule_show_prek_k", rule.ruleId);
		assertExactTextEquals("sec_prek_k", rule.targetId);
		assertExactTextEquals("grade", rule.sourceId);
		var sourceRule = rowWhere(variables.source.rules, "ruleKey", "show_prek_k");
		assertExactTextEquals(canonical(deserializeJSON(sourceRule.conditionsJson)), canonical(deserializeJSON(rule.conditionsJson)), "the conditions document is the same document");

		var option = rowWhere(variables.exported.responseOptions, "optionId", "opt_yes_no_yes");
		assertExactTextEquals("rs_yes_no", option.responseSetId);
		var value = rowWhere(variables.exported.dimensionValues, "dimensionValueId", "dval_school_abbott_middle_school");
		assertExactTextEquals("dim_school", value.dimensionId);
		var placement = rowWhere(variables.exported.instrumentDimensions, "instrumentDimensionId", "inst_dim_date");
		assertExactTextEquals("dim_date", placement.dimensionId);
		assertExactTextEquals("sec_visit_information", placement.sectionId);

		for (var s in variables.exported.sections) {
			assertExactTextEquals(variables.source.instrument.version.versionId, s.versionId, "rows name the version they belong to");
		}
		assertExactTextEquals("DRAFT", variables.exported.instrument.version.status, "an import can only create a DRAFT");
		assertFalse(structKeyExists(variables.exported.instrument.version, "effectiveStart") && !isNull(variables.exported.instrument.version.effectiveStart), "no effective window");
		assertExactTextEquals(variables.source.instrument.instrumentId, variables.exported.instrument.instrumentId);
		assertExactTextEquals(variables.source.instrument.version.versionLabel, variables.exported.instrument.version.versionLabel);
	}

	public void function testEveryCollectionExportsEveryRow() {
		for (var key in ["sections", "items", "responseSets", "responseOptions", "rules", "dimensions", "dimensionValues", "instrumentDimensions"]) {
			assertEquals(arrayLen(variables.source[key]), arrayLen(variables.exported[key]), key);
		}
	}

	public void function testRowsComeOutInReadingOrder() {
		assertExactTextEquals("root", variables.exported.sections[1].sectionKey, "the root first");
		var position = {};
		var i = 0;
		for (var s in variables.exported.sections) position[s.sectionId] = ++i;
		for (var s in variables.exported.sections) {
			if (isNull(s.parentSectionId)) continue;
			assertTrue(position[s.parentSectionId] < position[s.sectionId], "a parent comes before its child: " & s.sectionKey);
		}
		var last = 0;
		var lastOrder = -1;
		for (var it in variables.exported.items) {
			var here = position[it.sectionId];
			assertTrue(here >= last, "questions are grouped by section in tree order: " & it.itemKey);
			if (here == last) assertTrue(it.displayOrder >= lastOrder, "and by display order within a section: " & it.itemKey);
			last = here;
			lastOrder = it.displayOrder;
		}
	}

	// ---- a stored version ------------------------------------------------------------------------

	public void function testAPublishedVersionExportsToADraftWithTheSameDefinitions() {
		if (!schemaPresent()) return;
		var run = "exp-" & lCase(left(replace(createUUID(), "-", "", "all"), 8));
		var code = "EXPFIX" & uCase(left(replace(createUUID(), "-", "", "all"), 8));
		var cleanup = new icfwalktests.support.FixtureCleanup(variables.c);
		var admin = cleanup.ensureUser(run & "-admin", "Export fixture administrator");
		try {
			var cfg = duplicate(variables.source);
			cfg.instrument.code = code;
			cfg.instrument.version.versionLabel = run & "-published";
			var imported = variables.c.instrumentImportService.importConfig(cfg, admin);
			variables.c.instrumentPublishService.publish(imported.versionId, admin);
			var before = variables.c.definitionRepository.findVersionById(imported.versionId);

			var exported = variables.c.instrumentAdminService.exportDocument(imported.versionId);
			assertExactTextEquals("PUBLISHED", exported.version.status);
			assertExactTextEquals("DRAFT", exported.document.instrument.version.status);
			exported.document.instrument.version.versionLabel = run & "-from-export";
			var draft = variables.c.instrumentAdminService.importDocument(exported.document, admin);

			assertTrue(draft.created, "a new DRAFT");
			assertExactTextEquals("DRAFT", draft.status);
			assertExactTextEquals(imported.definitionsChecksum, draft.definitionsChecksum, "exactly the published definitions");
			var after = variables.c.definitionRepository.findVersionById(imported.versionId);
			assertExactTextEquals("PUBLISHED", after.status);
			assertExactTextEquals(before.checksum, after.checksum, "the published version did not move");
			assertRowVersionEquals(before.rowVersion, after.rowVersion, "not even its row version");
		} finally {
			cleanup.removeInstrumentsCoded(code);
			cleanup.removeUsers(run & "-");
		}
	}

	// ---- helpers ---------------------------------------------------------------------------------

	private struct function rowWhere(required array rows, required string key, required string value) {
		for (var row in arguments.rows) {
			if (structKeyExists(row, arguments.key) && !isNull(row[arguments.key]) && compare(row[arguments.key], arguments.value) == 0) return row;
		}
		fail("no row with " & arguments.key & " = " & arguments.value);
	}

	private string function canonical(required any value) {
		return variables.c.canonicalJson.serialize(arguments.value);
	}
}
