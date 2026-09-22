/**
 * A published version's dimensions and values are its own (migration 006).
 *
 * WHAT WENT WRONG BEFORE. icf.dimension_definition and icf.dimension_value were global, one row per
 * code, and the importer updated them in place. loadNormalizedDefinitions read a version's
 * dimensions and values straight out of those shared rows. So importing V2 with a renamed
 * dimension, a relabelled or reordered value, a deactivated value or a dropped one silently
 * rewrote what V1's definitions said -- after V1 had been published, frozen, and reported on. V1's
 * stored snapshot did not move, so nothing looked wrong until something compared the snapshot with
 * the tables and found drift in a version nobody had touched.
 *
 * THE INVARIANT THIS PROVES. After V1 is published, importing or editing V2 can never change
 * loadNormalizedDefinitions(V1), V1's checksum materialization, V1's comparison metadata, or the
 * meaning of data already reported under V1.
 *
 * AND THE THING THAT MUST STILL WORK. Cross-version reporting identity. A walk conducted under V1
 * stores a dimension value id; a report grouping V1 and V2 walks by that value's code must still
 * see one value. So the global rows are kept, as identity and nothing else: the same value_id and
 * value_code are shared by both versions, while what each version calls it, where it puts it and
 * whether it offers it at all live on rows only that version owns.
 *
 * The fixture uses its own instrument code, so publishing here never becomes the ICFWalk
 * instrument's current version for anything else in the suite.
 */
component extends="icfwalktests.BaseSpec" output="false" {

	public string function skipReason() {
		return schemaPresent() ? "" : "icf schema is not present in datasource '" & variables.c.db.datasourceName() & "'.";
	}

	public void function beforeAll() {
		variables.run = "dim-" & lCase(left(replace(createUUID(), "-", "", "all"), 8));
		variables.instrumentCode = "DIMISO" & uCase(left(replace(createUUID(), "-", "", "all"), 8));
		variables.db = variables.c.db;
		variables.repo = variables.c.definitionRepository;
		variables.importSvc = variables.c.instrumentImportService;
		variables.publishSvc = variables.c.instrumentPublishService;
		variables.compiler = variables.c.snapshotCompiler;
		variables.fixtures = new icfwalktests.support.FixtureCleanup(variables.c);
		variables.publisher = variables.fixtures.ensureUser(variables.run & "-publisher", "Dimension isolation publisher");

		// V1: the real instrument, published and frozen.
		variables.v1 = variables.importSvc.importConfig(config("v1"));
		variables.publishSvc.publish(variables.v1.versionId, variables.publisher);
		variables.v1Before = materialization(variables.v1.versionId);

		// The dimension V2 will rewrite: a LIST dimension with several values, none of whose value
		// codes any rule compares against (so V2 stays a valid document while its semantics change).
		variables.target = pickRewritableDimension();

		// V2: same instrument, new label, with that dimension's semantics changed in every way the
		// old shared-row model would have leaked back into V1.
		variables.v2 = variables.importSvc.importConfig(rewrittenConfig("v2"));
	}

	public void function afterAll() {
		variables.fixtures.removeInstrumentsCoded(variables.instrumentCode);
		variables.fixtures.removeUsers(variables.run & "-");
	}

	// ---- the invariant ---------------------------------------------------------------------------

	/** V1's stored snapshot and checksum are exactly what publication froze. */
	public void function testPublishedSnapshotIsByteForByteUnchangedAfterTheNextImport() {
		var after = materialization(variables.v1.versionId);
		assertExactTextEquals(variables.v1Before.snapshotJson, after.snapshotJson, "V1's stored snapshot is byte-for-byte unchanged");
		assertExactTextEquals(variables.v1Before.checksum, after.checksum, "V1's checksum is unchanged");
		assertExactTextEquals("PUBLISHED", after.status);
		assertRowVersionEquals(variables.v1Before.rowVersion, after.rowVersion, "V1's version row did not move");
	}

	/**
	 * The thing the old model actually broke: what SQL Server says V1's definitions are. If this
	 * ever regresses, V1's snapshot and V1's tables disagree and V1 becomes unverifiable.
	 */
	public void function testNormalizedDefinitionsForV1AreUnchangedAfterTheNextImport() {
		var after = materialization(variables.v1.versionId);
		assertExactTextEquals(variables.v1Before.definitionsChecksum, after.definitionsChecksum, "loadNormalizedDefinitions(V1) is unchanged");
		assertExactTextEquals(
			after.definitionsChecksum,
			variables.compiler.definitionsChecksum(deserializeJSON(after.snapshotJson).definitions),
			"V1's tables and V1's snapshot still describe each other"
		);
	}

	/** Field by field, so a regression says which property leaked rather than only that one did. */
	public void function testV1KeepsItsOwnDimensionAndValueSemantics() {
		var v1 = dimensionView(variables.v1.versionId, variables.target.code);
		assertExactTextEquals(variables.target.originalLabel, v1.label, "V1 still calls the dimension what it called it");
		assertEquals(variables.target.originalActive, v1.active, "V1's dimension activity is unchanged");

		for (var code in structKeyArray(variables.target.originalValues)) {
			var expected = variables.target.originalValues[code];
			assertTrue(structKeyExists(v1.values, code), "V1 still offers value '" & code & "'");
			assertExactTextEquals(expected.label, v1.values[code].label, "V1's label for '" & code & "'");
			assertEquals(expected.displayOrder, v1.values[code].displayOrder, "V1's order for '" & code & "'");
			assertEquals(expected.active, v1.values[code].active, "V1's activity for '" & code & "'");
		}
		assertEquals(structCount(variables.target.originalValues), structCount(v1.values), "V1 offers exactly the values it always did");
		assertFalse(structKeyExists(v1.values, variables.target.addedValueCode), "and not the value V2 added");
	}

	/** V2 really did change all of that, so the test above is not passing by doing nothing. */
	public void function testV2SeesItsOwnChangedSemantics() {
		var v2 = dimensionView(variables.v2.versionId, variables.target.code);
		assertExactTextEquals(variables.target.originalLabel & " (renamed in V2)", v2.label, "V2 renamed the dimension");
		assertExactTextNotEquals(
			variables.target.originalValues[variables.target.relabelledValueCode].label,
			v2.values[variables.target.relabelledValueCode].label,
			"V2 relabelled a value"
		);
		assertNotEquals(
			variables.target.originalValues[variables.target.reorderedValueCode].displayOrder,
			v2.values[variables.target.reorderedValueCode].displayOrder,
			"V2 reordered the values"
		);
		assertFalse(v2.values[variables.target.deactivatedValueCode].active, "V2 deactivated a value");
		assertFalse(structKeyExists(v2.values, variables.target.droppedValueCode), "V2 dropped a value");
		assertTrue(structKeyExists(v2.values, variables.target.addedValueCode), "V2 added a value");
	}

	/**
	 * Cross-version reporting identity survives the split. The shared value codes resolve to the
	 * same value_id in both versions, which is what icf.walk_dimension_value stores and what any
	 * report grouping V1 and V2 walks together depends on.
	 */
	public void function testReportingIdentityIsSharedAcrossVersions() {
		var v1Ids = valueIdsByCode(variables.v1.versionId, variables.target.code);
		var v2Ids = valueIdsByCode(variables.v2.versionId, variables.target.code);
		var shared = 0;
		for (var code in structKeyArray(v1Ids)) {
			if (!structKeyExists(v2Ids, code)) continue;
			assertExactTextEquals(v1Ids[code], v2Ids[code], "value '" & code & "' is the same reporting identity in both versions");
			shared++;
		}
		assertTrue(shared >= 2, "the two versions share their value identities (" & shared & " shared)");

		// The dropped value's identity row is still there: V1 walks still point at something real.
		assertEquals(1, variables.db.scalar(
			"SELECT COUNT(*) AS n FROM [icf].[dimension_value] WHERE value_id = :id",
			{ "id": variables.db.guid(v1Ids[variables.target.droppedValueCode]) }
		), "the value V2 dropped keeps its global identity for V1's walks");
	}

	/**
	 * What a walk pinned to V1 is allowed to carry is decided by V1's rows, not by the latest
	 * import. A value V2 deactivated or dropped is still a valid V1 answer; the value V2 added is
	 * not a valid V1 answer.
	 */
	public void function testTheWalkIndexOfAPinnedVersionIsUnaffectedByTheNextImport() {
		var walkRepo = variables.c.walkRepository;
		walkRepo.clearCache();
		var v1Index = walkRepo.definitionIndex(variables.v1.versionId);
		var v2Index = walkRepo.definitionIndex(variables.v2.versionId);
		var dimensionId = v1Index.dimensions[variables.target.code];

		assertTrue(structKeyExists(v1Index.values[dimensionId], variables.target.deactivatedValueCode), "V1 still accepts the value V2 deactivated");
		assertTrue(structKeyExists(v1Index.values[dimensionId], variables.target.droppedValueCode), "V1 still accepts the value V2 dropped");
		assertFalse(structKeyExists(v1Index.values[dimensionId], variables.target.addedValueCode), "V1 does not accept the value only V2 offers");

		assertFalse(structKeyExists(v2Index.values[v2Index.dimensions[variables.target.code]], variables.target.deactivatedValueCode), "V2 does not accept the value it deactivated");
		assertTrue(structKeyExists(v2Index.values[v2Index.dimensions[variables.target.code]], variables.target.addedValueCode), "V2 accepts the value it added");
	}

	/**
	 * The defect in its purest form. The old importer wrote a later version's label, order and
	 * activity straight into the shared `icf.dimension_definition` / `icf.dimension_value` rows, and
	 * `loadNormalizedDefinitions` read them back for *every* version placing that dimension -- so a
	 * published version's definitions changed because somebody edited a DRAFT.
	 *
	 * This makes exactly those writes, directly, and then asks V1 what its definitions are. The
	 * global rows are identity now: nothing reads their label, order or activity, so V1 does not
	 * move. If anything ever starts reading them again, this fails immediately and says so.
	 */
	public void function testWritingTheGlobalIdentityRowsDoesNotChangeAPublishedVersion() {
		var before = materialization(variables.v1.versionId);
		var v1Before = dimensionView(variables.v1.versionId, variables.target.code);

		variables.db.run(
			"UPDATE [icf].[dimension_definition] SET label = N'Rewritten globally', active = 0 WHERE code = :code",
			{ "code": variables.db.nvarchar(variables.target.code, 100) }
		);
		variables.db.run(
			"UPDATE dv SET dv.label = N'Rewritten globally', dv.active = 0, dv.display_order = dv.display_order + 5000
			   FROM [icf].[dimension_value] dv JOIN [icf].[dimension_definition] d ON d.dimension_id = dv.dimension_id
			  WHERE d.code = :code",
			{ "code": variables.db.nvarchar(variables.target.code, 100) }
		);

		var after = materialization(variables.v1.versionId);
		assertExactTextEquals(before.definitionsChecksum, after.definitionsChecksum, "rewriting the shared rows does not change V1's definitions");
		assertExactTextEquals(before.snapshotJson, after.snapshotJson, "nor its stored snapshot");

		var v1After = dimensionView(variables.v1.versionId, variables.target.code);
		assertExactTextEquals(v1Before.label, v1After.label, "V1 still calls the dimension what it called it");
		assertEquals(v1Before.active, v1After.active);
		for (var code in structKeyArray(v1Before.values)) {
			assertExactTextEquals(v1Before.values[code].label, v1After.values[code].label, "V1's label for '" & code & "'");
			assertEquals(v1Before.values[code].displayOrder, v1After.values[code].displayOrder, "V1's order for '" & code & "'");
			assertEquals(v1Before.values[code].active, v1After.values[code].active, "V1's activity for '" & code & "'");
		}

		// And the walk path agrees: a value this rewrite deactivated globally is still a valid V1
		// answer, because V1's own row says it is.
		variables.c.walkRepository.clearCache();
		var index = variables.c.walkRepository.definitionIndex(variables.v1.versionId);
		assertTrue(structKeyExists(index.dimensions, variables.target.code), "V1 still offers the dimension a global row just deactivated");
		var dimensionId = index.dimensions[variables.target.code];
		assertEquals(structCount(v1Before.values), structCount(index.values[dimensionId]), "and every value V1 offered is still acceptable");
	}

	/**
	 * The consequence for publication: V1 can still be verified. Re-running publish's own checks
	 * over the frozen version finds no drift and no validation error, which is what would have
	 * broken first under the shared-row model.
	 */
	public void function testV1StillPassesTheChecksPublicationMadeAboutIt() {
		var row = variables.repo.findVersionById(variables.v1.versionId);
		assertExactTextEquals(row.checksum, variables.c.canonicalJson.sha256(row.snapshotJson), "V1's checksum still hashes V1's snapshot");
		var snapshot = deserializeJSON(row.snapshotJson);
		var validator = variables.c.definitionValidator;
		assertTrue(validator.validateEnvelope(snapshot, { "versionLabel": row.versionLabel, "instrumentCode": row.instrumentCode }).valid, "V1's envelope is still valid");
		var persisted = variables.repo.loadNormalizedDefinitions(variables.v1.versionId);
		var issues = validator.validate(persisted);
		assertTrue(issues.valid, "V1's persisted definitions are still valid: " & (arrayLen(issues.errors) ? serializeJSON(issues.errors[1]) : ""));
		assertExactTextEquals(
			variables.compiler.definitionsChecksum(snapshot.definitions),
			variables.compiler.definitionsChecksum(persisted),
			"and they still match V1's snapshot"
		);
	}

	// ---- helpers ---------------------------------------------------------------------------------

	private string function label(required string suffix) {
		return variables.run & "-" & arguments.suffix;
	}

	private struct function config(required string suffix) {
		var cfg = repoJson("config/instrument-config.json");
		cfg.instrument.code = variables.instrumentCode;
		cfg.instrument.version.versionLabel = label(arguments.suffix);
		return cfg;
	}

	/**
	 * A LIST dimension with at least four values, none of whose value codes any rule compares
	 * against, so rewriting its values leaves the document valid. Records what V1 said about it.
	 */
	private struct function pickRewritableDimension() {
		var cfg = repoJson("config/instrument-config.json");
		var referenced = {};
		for (var rule in cfg.rules) {
			if (!structKeyExists(rule, "conditionsJson") || !isSimpleValue(rule.conditionsJson) || !isJSON(rule.conditionsJson)) continue;
			var doc = deserializeJSON(rule.conditionsJson);
			if (!isStruct(doc) || !structKeyExists(doc, "conditions") || !isArray(doc.conditions)) continue;
			for (var cond in doc.conditions) {
				if (!isStruct(cond) || !structKeyExists(cond, "comparisonValue")) continue;
				if (isArray(cond.comparisonValue)) { for (var v in cond.comparisonValue) referenced[toString(v)] = true; }
				else if (isSimpleValue(cond.comparisonValue)) referenced[toString(cond.comparisonValue)] = true;
			}
		}
		var v1 = dimensionViewAll(variables.v1.versionId);
		var chosen = "";
		for (var code in structKeyArray(v1)) {
			var view = v1[code];
			if (view.dataType != "LIST" || structCount(view.values) < 4) continue;
			var clean = true;
			for (var valueCode in structKeyArray(view.values)) if (structKeyExists(referenced, valueCode)) clean = false;
			if (!clean) continue;
			if (!len(chosen) || compare(code, chosen) < 0) chosen = code;
		}
		if (!len(chosen)) fail("No LIST dimension with four unreferenced values exists in the instrument; this spec needs one.");

		var view = v1[chosen];
		var codes = structKeyArray(view.values);
		arraySort(codes, "text");
		return {
			"code": chosen,
			"originalLabel": view.label,
			"originalActive": view.active,
			"originalValues": view.values,
			"relabelledValueCode": codes[1],
			"reorderedValueCode": codes[2],
			"deactivatedValueCode": codes[3],
			"droppedValueCode": codes[4],
			"addedValueCode": "added_in_v2_" & variables.run
		};
	}

	/** The V2 document: the same instrument, with the target dimension rewritten every which way. */
	private struct function rewrittenConfig(required string suffix) {
		var cfg = config(arguments.suffix);
		var t = variables.target;
		var dimensionAuthoringId = "";
		for (var d in cfg.dimensions) {
			if (d.code != t.code) continue;
			dimensionAuthoringId = d.dimensionId;
			d.label = t.originalLabel & " (renamed in V2)";
			break;
		}
		var kept = [];
		var order = 0;
		var values = [];
		for (var v in cfg.dimensionValues) if (v.dimensionId == dimensionAuthoringId) arrayAppend(values, v);
		for (var v in cfg.dimensionValues) {
			if (v.dimensionId != dimensionAuthoringId) { arrayAppend(kept, v); continue; }
			if (v.valueCode == t.droppedValueCode) continue;
			if (v.valueCode == t.relabelledValueCode) v.label = v.label & " (relabelled in V2)";
			if (v.valueCode == t.deactivatedValueCode) v.active = false;
			arrayAppend(kept, v);
		}
		// Reverse the surviving values' order, so every one of them moves.
		var mine = [];
		for (var v in kept) if (v.dimensionId == dimensionAuthoringId) arrayAppend(mine, v);
		var n = arrayLen(mine);
		for (var i = 1; i <= n; i++) mine[i].displayOrder = (n - i + 1) * 10;
		arrayAppend(kept, {
			"dimensionValueId": "dv_" & t.addedValueCode,
			"dimensionId": dimensionAuthoringId,
			"valueCode": t.addedValueCode,
			"label": "Added in V2",
			"displayOrder": (n + 1) * 10,
			"active": true
		});
		cfg.dimensionValues = kept;
		return cfg;
	}

	/** What the database says one version's dimensions are, by code. */
	private struct function dimensionViewAll(required string versionId) {
		var d = variables.repo.loadNormalizedDefinitions(arguments.versionId);
		var out = {};
		for (var dim in d.dimensions) {
			out[dim.code] = { "label": dim.label, "dataType": dim.dataType, "active": dim.active, "values": {} };
		}
		for (var v in d.dimensionValues) {
			if (!structKeyExists(out, v.dimensionCode)) continue;
			out[v.dimensionCode].values[v.valueCode] = { "label": v.label, "displayOrder": v.displayOrder, "active": v.active };
		}
		return out;
	}

	private struct function dimensionView(required string versionId, required string code) {
		var all = dimensionViewAll(arguments.versionId);
		if (!structKeyExists(all, arguments.code)) fail("Version " & arguments.versionId & " has no dimension '" & arguments.code & "'.");
		return all[arguments.code];
	}

	private struct function valueIdsByCode(required string versionId, required string dimensionCode) {
		var q = variables.db.run(
			"SELECT dv.value_code, iv.value_id
			   FROM [icf].[instrument_dimension_value] iv
			   JOIN [icf].[dimension_value] dv ON dv.value_id = iv.value_id
			   JOIN [icf].[dimension_definition] d ON d.dimension_id = iv.dimension_id
			  WHERE iv.version_id = :id AND d.code = :code",
			{ "id": variables.db.guid(arguments.versionId), "code": variables.db.nvarchar(arguments.dimensionCode, 100) }
		);
		var out = {};
		for (var r = 1; r <= q.recordCount; r++) out[q.value_code[r]] = uCase(q.value_id[r]);
		return out;
	}

	private struct function materialization(required string versionId) {
		var row = variables.repo.findVersionById(arguments.versionId);
		return {
			"status": row.status,
			"snapshotJson": row.snapshotJson,
			"checksum": row.checksum,
			"rowVersion": row.rowVersion,
			"definitionsChecksum": variables.compiler.definitionsChecksum(variables.repo.loadNormalizedDefinitions(arguments.versionId))
		};
	}
}
