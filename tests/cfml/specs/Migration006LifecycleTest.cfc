/**
 * Re-applying migration 006 after a later version introduces a new dimension value must not change
 * an already published version -- in the tables, in what the runtime renders, or in what a walk is
 * allowed to record.
 *
 * THE DEFECT. The first form of 006 backfilled icf.instrument_dimension_value with "every global
 * value of every placed dimension that this version does not already have a row for". As a
 * description of the one-time schema transition that is correct: before the transition a version
 * offered, by construction, all of its dimension's global values.
 *
 * As a condition re-evaluated on every apply it is a data-corruption bug. Once V2 imports a new
 * value under a shared dimension, that value exists globally and published V1 has no row for it,
 * so a re-apply *infers* that V1 must have meant to offer it and inserts it. V1's normalized
 * definitions and the walk values it accepts change; its snapshot bytes, its checksum and its
 * row_version do not. The corruption is therefore invisible to every check the application has:
 * the drift check compares the snapshot with the tables only when someone publishes, and
 * WalkRepository.definitionIndex() caches by the version checksum, which did not move -- so a
 * running application keeps serving the pre-corruption index and a restarted one silently serves
 * a different instrument.
 *
 * WHY THIS SPEC AND NOT A SQL-ONLY TEST. The schema-level cases (clean apply, apply over the
 * Phase 5 schema with data, immediate re-application, adoption of a database carrying the earlier
 * form, and the ambiguous-state precondition) live in tests/node/db-scripts.test.mjs, which can
 * make throwaway databases. This case cannot be proved there: it needs the real importer, the real
 * publisher, and the two real caches -- and the whole point is what a *cached* reader sees. So it
 * runs here, in-process, against the live application database, in the order the audit specified:
 *
 *   1. (the database is at 006, having been taken there from the Phase 5 schema)
 *   2. import V1 and publish it
 *   3. prime the walk definition cache and the snapshot cache for V1
 *   4. import V2 with a new value under a shared dimension, belonging only to V2
 *   5. re-apply migration 006 through the normal repository mechanism
 *   6. prove V1's version-scoped dimension rows, normalized definitions, snapshot bytes, checksum,
 *      row version, allowed walk values and runtime render model are all unchanged
 *   7. prove it from the already-primed cache AND from a fresh uncached load
 */
component extends="icfwalktests.BaseSpec" output="false" {

	public string function skipReason() {
		return schemaPresent() ? "" : "icf schema is not present in datasource '" & variables.c.db.datasourceName() & "'.";
	}

	public void function beforeAll() {
		variables.run = "mig6-" & lCase(left(replace(createUUID(), "-", "", "all"), 8));
		variables.instrumentCode = "MIG6FIX" & uCase(left(replace(createUUID(), "-", "", "all"), 8));
		variables.db = variables.c.db;
		variables.repo = variables.c.definitionRepository;
		variables.importSvc = variables.c.instrumentImportService;
		variables.publishSvc = variables.c.instrumentPublishService;
		variables.walkRepo = variables.c.walkRepository;
		variables.snapshots = variables.c.snapshotService;
		variables.fixtures = new icfwalktests.support.FixtureCleanup(variables.c);
		variables.publisher = variables.fixtures.ensureUser(variables.run & "-publisher", "Migration 006 fixture publisher");
		variables.migrationSql = repoFile("database/006_version_scoped_dimensions.sql");
	}

	public void function afterAll() {
		variables.fixtures.removeInstrumentsCoded(variables.instrumentCode);
		variables.fixtures.removeUsers(variables.run & "-");
		// The caches are process-wide; leave them clean for whatever runs next.
		variables.snapshots.clearCache();
		variables.walkRepo.clearCache();
	}

	/** The migration file really is the one-time form, and says so in its recorded state. */
	public void function testTheMigrationRecordsItsTransitionStateDurably() {
		assertTrue(
			variables.db.scalar("SELECT COUNT(*) AS n FROM sys.tables WHERE schema_id = SCHEMA_ID('icf') AND name = 'schema_migration_state'") == 1,
			"006 keeps a durable record of one-time steps"
		);
		var q = variables.db.run(
			"SELECT state FROM [icf].[schema_migration_state] WHERE migration = N'006_version_scoped_dimensions' AND step = N'legacy_membership_backfill'"
		);
		assertEquals(1, q.recordCount, "the legacy membership backfill is recorded as settled");
		assertTrue(
			q.state[1] == "COMPLETED" || q.state[1] == "ADOPTED_PRE_STATE",
			"and in a state that means 'never infer membership again', not '" & q.state[1] & "'"
		);
	}

	/**
	 * The whole sequence, in order. One test rather than several because the steps are a single
	 * ordered scenario: a later step means nothing without the earlier ones having happened.
	 */
	public void function testReapplying006AfterV2AddsANewValueLeavesPublishedV1Untouched() {
		// 2. V1 is imported and published.
		var v1 = variables.importSvc.importConfig(config(label("v1")));
		variables.publishSvc.publish(v1.versionId, variables.publisher);
		var versionId = v1.versionId;

		// 3. Prime both caches for V1, the way a running application would have them.
		var primedIndex = variables.walkRepo.definitionIndex(versionId);
		var primedModel = variables.snapshots.renderModelFor(versionId);
		var primedSnapshot = variables.snapshots.snapshotFor(versionId);
		assertTrue(structCount(primedIndex.values) > 0, "precondition: the primed index really carries dimension values");

		var before = stateOf(versionId);
		var sharedDimension = aSharedListDimension(versionId);
		var newValueCode = "mig6_v2_only_" & lCase(left(replace(createUUID(), "-", "", "all"), 8));

		// 4. V2 arrives with a brand-new value under a dimension V1 also places. Imported through
		//    the real importer, so the value's global identity row is created exactly as it would
		//    be in production -- which is what makes it visible to a re-applied backfill.
		var v2Config = config(label("v2"));
		addValueToDimension(v2Config, sharedDimension.code, newValueCode);
		var v2 = variables.importSvc.importConfig(v2Config);
		assertNotEquals(versionId, v2.versionId, "V2 is its own version");

		assertEquals(1, variables.db.scalar(
			"SELECT COUNT(*) AS n FROM [icf].[dimension_value] dv JOIN [icf].[dimension_definition] d ON d.dimension_id = dv.dimension_id
			  WHERE d.code = :code AND dv.value_code = :value",
			{ "code": variables.db.nvarchar(sharedDimension.code, 100), "value": variables.db.nvarchar(newValueCode, 100) }
		), "the new value now exists as global reporting identity");
		assertEquals(0, v1MembershipFor(versionId, sharedDimension.dimensionId, newValueCode), "and V1 does not offer it");
		assertEquals(1, v1MembershipFor(v2.versionId, sharedDimension.dimensionId, newValueCode), "while V2 does");

		// 5. Re-apply migration 006 exactly as the repository's own mechanism would.
		var result = variables.db.run(variables.migrationSql);
		assertTrue(result.recordCount > 0, "the migration ran and reported");
		assertEquals(0, result.legacy_membership_backfill_ran_now[1], "and it did NOT run the legacy membership backfill again");

		// 6. Nothing about V1 moved.
		var after = stateOf(versionId);
		assertEquals(before.membershipDigest, after.membershipDigest, "V1's version-scoped dimension rows are unchanged");
		assertEquals(before.membershipCount, after.membershipCount, "including how many there are");
		assertEquals(0, v1MembershipFor(versionId, sharedDimension.dimensionId, newValueCode), "V1 still does not offer V2's new value");
		assertEquals(before.definitionsChecksum, after.definitionsChecksum, "V1's normalized definitions are unchanged");
		assertEquals(before.snapshotJson, after.snapshotJson, "V1's snapshot bytes are unchanged");
		assertEquals(before.checksum, after.checksum, "V1's checksum is unchanged");
		assertEquals(before.rowVersion, after.rowVersion, "V1's row version is unchanged");
		assertEquals("PUBLISHED", after.status, "and it is still published");

		// 7a. The already-primed caches still describe V1 exactly as they did.
		var cachedIndex = variables.walkRepo.definitionIndex(versionId);
		var cachedModel = variables.snapshots.renderModelFor(versionId);
		assertEquals(digestOf(primedIndex), digestOf(cachedIndex), "the primed walk definition index is unchanged");
		assertEquals(digestOf(primedModel), digestOf(cachedModel), "the primed render model is unchanged");
		assertFalse(
			structKeyExists(cachedIndex.values[sharedDimension.dimensionId], newValueCode),
			"and the cached index still refuses V2's value for a V1 walk"
		);

		// 7b. ...and so does a fresh load with every cache dropped, which is the reading a
		//     restarted application would get. Before the correction this is where the two
		//     diverged: the cache kept the old answer because the checksum had not moved, and the
		//     fresh load returned an instrument that had silently gained a value.
		variables.walkRepo.clearCache();
		variables.snapshots.clearCache();
		var freshIndex = variables.walkRepo.definitionIndex(versionId);
		var freshModel = variables.snapshots.renderModelFor(versionId);
		var freshSnapshot = variables.snapshots.snapshotFor(versionId);
		assertEquals(digestOf(primedIndex), digestOf(freshIndex), "a fresh uncached index is identical to the primed one");
		assertEquals(digestOf(primedModel), digestOf(freshModel), "a fresh uncached render model is identical to the primed one");
		assertEquals(digestOf(primedSnapshot), digestOf(freshSnapshot), "and so is the parsed snapshot");
		assertFalse(
			structKeyExists(freshIndex.values[sharedDimension.dimensionId], newValueCode),
			"the allowed walk values for V1 are the same uncached as cached"
		);

		// And the walk values V1 accepts are exactly the ones it offered before V2 existed.
		assertEquals(before.allowedValues, allowedWalkValues(versionId), "V1's allowed walk values are unchanged");
	}

	/** V2 keeps its own new value: the correction restricts inference, it does not break imports. */
	public void function testV2KeepsItsOwnNewValueAfterTheReapplication() {
		var v2 = variables.db.run(
			"SELECT TOP (1) v.version_id FROM [icf].[instrument_version] v JOIN [icf].[instrument] i ON i.instrument_id = v.instrument_id
			  WHERE i.code = :code AND v.version_label = :label",
			{ "code": variables.db.nvarchar(variables.instrumentCode, 60), "label": variables.db.nvarchar(label("v2"), 100) }
		);
		if (!v2.recordCount) return; // The ordered scenario above has not run in this pass.
		var versionId = uCase(v2.version_id[1]);
		var q = variables.db.run(
			"SELECT COUNT(*) AS n FROM [icf].[instrument_dimension_value] iv JOIN [icf].[dimension_value] dv ON dv.value_id = iv.value_id
			  WHERE iv.version_id = :id AND dv.value_code LIKE 'mig6_v2_only_%'",
			{ "id": variables.db.guid(versionId) }
		);
		assertEquals(1, q.n[1], "V2 still offers the value it introduced");
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

	/** A LIST dimension this version places and offers values for. */
	private struct function aSharedListDimension(required string versionId) {
		var q = variables.db.run(
			"SELECT TOP (1) p.dimension_id, d.code FROM [icf].[instrument_dimension] p
			   JOIN [icf].[dimension_definition] d ON d.dimension_id = p.dimension_id
			  WHERE p.version_id = :id AND p.dimension_data_type = N'LIST' AND p.dimension_active = 1
			    AND EXISTS (SELECT 1 FROM [icf].[instrument_dimension_value] iv WHERE iv.version_id = p.version_id AND iv.dimension_id = p.dimension_id)
			  ORDER BY d.code",
			{ "id": variables.db.guid(arguments.versionId) }
		);
		if (!q.recordCount) fail("the fixture instrument places no list dimension with values");
		return { "dimensionId": uCase(q.dimension_id[1]), "code": q.code[1] };
	}

	/** Adds one new value to a dimension in an authoring document, after its existing values. */
	private void function addValueToDimension(required struct cfg, required string dimensionCode, required string valueCode) {
		var dimensionId = "";
		for (var d in arguments.cfg.dimensions) if (d.code == arguments.dimensionCode) dimensionId = d.dimensionId;
		if (!len(dimensionId)) fail("dimension '" & arguments.dimensionCode & "' is not in the document");
		var maxOrder = 0;
		for (var v in arguments.cfg.dimensionValues) {
			if (v.dimensionId == dimensionId && isNumeric(v.displayOrder) && v.displayOrder > maxOrder) maxOrder = v.displayOrder;
		}
		arrayAppend(arguments.cfg.dimensionValues, {
			"dimensionValueId": "dv_" & arguments.valueCode,
			"dimensionId": dimensionId,
			"valueCode": arguments.valueCode,
			"label": "Value introduced by V2",
			"displayOrder": maxOrder + 10,
			"active": true
		});
	}

	private numeric function v1MembershipFor(required string versionId, required string dimensionId, required string valueCode) {
		return variables.db.scalar(
			"SELECT COUNT(*) AS n FROM [icf].[instrument_dimension_value] iv JOIN [icf].[dimension_value] dv ON dv.value_id = iv.value_id
			  WHERE iv.version_id = :id AND iv.dimension_id = :dimensionId AND dv.value_code = :value",
			{ "id": variables.db.guid(arguments.versionId), "dimensionId": variables.db.guid(arguments.dimensionId), "value": variables.db.nvarchar(arguments.valueCode, 100) }
		);
	}

	/** Everything about a version that a re-applied migration must not be able to move. */
	private struct function stateOf(required string versionId) {
		var row = variables.repo.findVersionById(arguments.versionId);
		return {
			"status": row.status,
			"snapshotJson": isNull(row.snapshotJson) ? "" : row.snapshotJson,
			"checksum": isNull(row.checksum) ? "" : row.checksum,
			"rowVersion": row.rowVersion,
			"definitionsChecksum": variables.c.snapshotCompiler.definitionsChecksum(variables.repo.loadNormalizedDefinitions(arguments.versionId)),
			"membershipCount": variables.db.scalar("SELECT COUNT(*) AS n FROM [icf].[instrument_dimension_value] WHERE version_id = :id", { "id": variables.db.guid(arguments.versionId) }),
			"membershipDigest": membershipDigest(arguments.versionId),
			"allowedValues": allowedWalkValues(arguments.versionId)
		};
	}

	private string function membershipDigest(required string versionId) {
		var q = variables.db.run(
			"SELECT dv.value_code, iv.dimension_id, iv.label, iv.display_order, iv.active
			   FROM [icf].[instrument_dimension_value] iv JOIN [icf].[dimension_value] dv ON dv.value_id = iv.value_id
			  WHERE iv.version_id = :id ORDER BY iv.dimension_id, dv.value_code",
			{ "id": variables.db.guid(arguments.versionId) }
		);
		return digestOf(q);
	}

	/** The value codes a walk pinned to this version may record, by dimension. */
	private string function allowedWalkValues(required string versionId) {
		var q = variables.db.run(
			"SELECT d.code AS dimension_code, dv.value_code
			   FROM [icf].[instrument_dimension_value] iv
			   JOIN [icf].[dimension_value] dv ON dv.value_id = iv.value_id
			   JOIN [icf].[dimension_definition] d ON d.dimension_id = iv.dimension_id
			  WHERE iv.version_id = :id AND iv.active = 1 ORDER BY d.code, dv.value_code",
			{ "id": variables.db.guid(arguments.versionId) }
		);
		return digestOf(q);
	}

	private string function digestOf(required any value) {
		return variables.c.canonicalJson.sha256(variables.c.canonicalJson.serialize(arguments.value));
	}
}
