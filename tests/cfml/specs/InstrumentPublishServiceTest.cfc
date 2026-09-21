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
 *   - a version that is not a DRAFT is refused, whether the caller comes through the route or
 *     calls the service directly, and the refusal is audited rather than silent
 *     (testPublishingAPublishedVersionIsRefusedAndAudited, testAssertDraftForWriteRefusesAPublishedVersion);
 *   - a DRAFT whose definitions have drifted from its snapshot is refused and left untouched, with
 *     nothing partially applied (testDefinitionsDriftIsRefusedAndNothingChanges).
 *
 * Fixtures are synthetic version labels removed in afterAll; no seeded version is published.
 */
component extends="icfwalktests.BaseSpec" output="false" {

	public string function skipReason() {
		return schemaPresent() ? "" : "icf schema is not present in datasource '" & variables.c.db.datasourceName() & "'.";
	}

	public void function beforeAll() {
		variables.run = "pub-" & lCase(left(replace(createUUID(), "-", "", "all"), 8));
		variables.importSvc = variables.c.instrumentImportService;
		variables.svc = variables.c.instrumentPublishService;
		variables.repo = variables.c.definitionRepository;
		variables.db = variables.c.db;
	}

	public void function afterAll() {
		var q = variables.db.run(
			"SELECT version_id FROM [icf].[instrument_version] WHERE version_label LIKE :prefix",
			{ "prefix": { "value": variables.run & "%", "cfsqltype": "cf_sql_nvarchar" } }
		);
		for (var r = 1; r <= q.recordCount; r++) variables.repo.deleteVersionCascadeUnchecked(uCase(q.version_id[r]));
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

		var result = variables.svc.publish(imported.versionId, "");

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
			"SELECT status, published_at, effective_start, checksum_sha256, compiled_snapshot_json FROM [icf].[instrument_version] WHERE version_id = :id",
			{ "id": variables.db.guid(imported.versionId) }
		);
		assertEquals("PUBLISHED", row.status[1]);
		assertTrue(isDate(row.published_at[1]), "published_at is set");
		assertTrue(isDate(row.effective_start[1]), "effective_start is set");
		assertEquals(64, len(trim(row.checksum_sha256[1])));
		assertTrue(len(row.compiled_snapshot_json[1]) > 0, "the snapshot is still stored");

		assertEquals(1, auditCount(imported.versionId, "INSTRUMENT_VERSION_PUBLISHED"), "the publish is audited once");
	}

	/**
	 * The published version is the one the renderer will now select. Proving it here keeps the
	 * publish path honest about the thing publishing exists to do.
	 */
	public void function testAPublishedVersionBecomesSelectableAsCurrent() {
		var imported = draft("adm04b");
		variables.svc.publish(imported.versionId, "");
		var selectable = variables.db.scalar(
			"SELECT COUNT(*) AS n FROM [icf].[instrument_version]
			  WHERE version_id = :id AND status = N'PUBLISHED' AND compiled_snapshot_json IS NOT NULL AND effective_start IS NOT NULL",
			{ "id": variables.db.guid(imported.versionId) }
		);
		assertEquals(1, selectable, "the published version satisfies the current-version selection predicate");
	}

	// ---- ADM-05: a frozen version never moves again ----------------------------------------------

	/**
	 * Publishing twice is refused on the second attempt, and refused loudly: the status is read
	 * under the row lock, the attempt is audited, and the stored row is untouched.
	 */
	public void function testPublishingAPublishedVersionIsRefusedAndAudited() {
		var imported = draft("adm05");
		variables.svc.publish(imported.versionId, "");
		var frozen = variables.repo.findVersionById(imported.versionId);

		var svc = variables.svc;
		var id = imported.versionId;
		var e = assertThrows(function() { svc.publish(id, ""); }, "ICFWalk.Publish", "INSTRUMENT_VERSION_NOT_DRAFT");
		assertContains("PUBLISHED", e.message, "the refusal names the status that blocked it");

		var after = variables.repo.findVersionById(imported.versionId);
		assertEquals(frozen.snapshotJson, after.snapshotJson, "the published snapshot is unchanged");
		assertEquals(frozen.checksum, after.checksum);
		assertEquals(frozen.rowVersion, after.rowVersion, "the row did not move at all");
		assertEquals(1, auditCount(imported.versionId, "INSTRUMENT_VERSION_PUBLISHED"), "still exactly one publish");
		assertEquals(1, auditCount(imported.versionId, "INSTRUMENT_VERSION_PUBLISH_REFUSED"), "and the refusal is on the record");
	}

	/**
	 * ADM-05's "or direct service call": the guard is callable, so it holds for code that never
	 * touches a route. A DRAFT passes it; a published version is refused and audited.
	 */
	public void function testAssertDraftForWriteRefusesAPublishedVersion() {
		var imported = draft("adm05b");
		var svc = variables.svc;
		var id = imported.versionId;

		// A DRAFT is writable: the guard returns without throwing.
		svc.assertDraftForWrite(id, "", "TEST_WRITE");

		variables.svc.publish(id, "");

		assertThrows(function() { svc.assertDraftForWrite(id, "", "TEST_WRITE"); }, "ICFWalk.Publish", "INSTRUMENT_VERSION_NOT_DRAFT");
		assertEquals(1, auditCount(id, "INSTRUMENT_VERSION_WRITE_REFUSED"), "the refused write attempt is audited");
	}

	/**
	 * The existing import guard and the new publish guard agree: a published version is not
	 * re-importable either. This is DB-06 restated from the publish side, so the two paths cannot
	 * drift apart into one that refuses and one that does not.
	 */
	public void function testAPublishedVersionCannotBeReimported() {
		var imported = draft("adm05c");
		variables.svc.publish(imported.versionId, "");
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
		var changed = variables.db.run(
			"UPDATE TOP (1) [icf].[item_definition] SET prompt = N'DRIFTED PROMPT (publish must refuse)' WHERE version_id = :id",
			{ "id": variables.db.guid(imported.versionId) }
		);

		var svc = variables.svc;
		var id = imported.versionId;
		var e = assertThrows(function() { svc.publish(id, ""); }, "ICFWalk.Publish", "INSTRUMENT_VERSION_NOT_PUBLISHABLE");
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
		assertThrows(function() { svc.publish(missing, ""); }, "ICFWalk.NotFound", "INSTRUMENT_VERSION_NOT_FOUND");
	}

	/** A malformed version id is refused as input, before any database work. */
	public void function testPublishingRefusesAMalformedVersionId() {
		var svc = variables.svc;
		assertThrows(function() { svc.publish("not-a-guid", ""); }, "ICFWalk.Validation", "INVALID_VERSION_ID");
	}

	// ---- helpers ---------------------------------------------------------------------------------

	private string function label(required string suffix) {
		return variables.run & "-" & arguments.suffix;
	}

	private struct function config(required string versionLabel) {
		var cfg = repoJson("config/instrument-config.json");
		cfg.instrument.version.versionLabel = arguments.versionLabel;
		return cfg;
	}

	/** An imported DRAFT of the real instrument under a synthetic label. */
	private struct function draft(required string suffix) {
		return variables.importSvc.importConfig(config(label(arguments.suffix)));
	}

	private numeric function auditCount(required string versionId, required string eventType) {
		return variables.db.scalar(
			"SELECT COUNT(*) AS n FROM [icf].[audit_event] WHERE entity_id = :id AND event_type = :t",
			{ "id": variables.db.guid(arguments.versionId), "t": variables.db.nvarchar(arguments.eventType) }
		);
	}
}
