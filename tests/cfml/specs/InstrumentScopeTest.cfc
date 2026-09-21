/**
 * Phase 0-4 correction regressions for instrument scoping and runtime snapshot integrity.
 *
 * Before the correction, "the current instrument version" was the newest PUBLISHED version of any
 * active instrument, with no effective window, and a DRAFT discard resolved a version by label
 * alone. So a second instrument could supply the runtime contract or lose a draft to another
 * instrument's discard, and a version scheduled for a future term or already expired could be
 * selected. The stored snapshot was also parsed and cached without ever being checked against its
 * recorded checksum.
 *
 * Every fixture here is a synthetic instrument or a synthetic version row; the seeded ICFWalk
 * version is never modified, and everything is removed in afterAll.
 */
component extends="icfwalktests.BaseSpec" output="false" {

	public string function skipReason() {
		if (!schemaPresent()) return "icf schema is not present.";
		if (structIsEmpty(variables.c.snapshotService.currentVersion())) return "no renderable instrument version is seeded.";
		return "";
	}

	public void function beforeAll() {
		variables.db = variables.c.db;
		variables.snapshots = variables.c.snapshotService;
		variables.repo = variables.c.definitionRepository;
		variables.tag = uCase(left(replace(createUUID(), "-", "", "all"), 8));
		variables.seeded = variables.snapshots.currentVersion();
		var row = variables.repo.findVersionById(variables.seeded.versionId);
		variables.snapshotJson = row.snapshotJson;
		variables.checksum = row.checksum;
		variables.instrumentIds = [];
		variables.versionIds = [];
		variables.fixtures = new icfwalktests.support.FixtureCleanup(variables.c);
		// A published row must name a publisher (CK_instrument_version_publisher_required,
		// migration 006), so these fixtures carry a real user rather than nobody.
		variables.publisher = variables.fixtures.ensureUser("scope-" & lCase(variables.tag) & "-publisher", "Instrument scope fixture publisher");
		variables.foreignA = instrument("OTHER-A-" & variables.tag);
		variables.foreignB = instrument("OTHER-B-" & variables.tag);
	}

	public void function afterAll() {
		for (var id in variables.versionIds) variables.db.run("DELETE FROM [icf].[instrument_version] WHERE version_id = :id", { "id": variables.db.guid(id) });
		for (var id in variables.instrumentIds) variables.db.run("DELETE FROM [icf].[instrument] WHERE instrument_id = :id", { "id": variables.db.guid(id) });
		variables.fixtures.removeUsers("scope-" & lCase(variables.tag) & "-");
		variables.snapshots.clearCache();
	}

	// ---- fixture helpers -------------------------------------------------------------------------

	private string function instrument(required string code) {
		var id = variables.db.newGuid();
		variables.db.run(
			"INSERT INTO [icf].[instrument] (instrument_id, code, name, description, active) VALUES (:id, :code, :name, NULL, 1)",
			{ "id": variables.db.guid(id), "code": variables.db.nvarchar(arguments.code, 60), "name": variables.db.nvarchar("Fixture " & arguments.code, 200) }
		);
		arrayAppend(variables.instrumentIds, id);
		return id;
	}

	/**
	 * A version row carrying the seeded snapshot (so it is renderable and checksum-clean) with the
	 * status and effective window this spec needs. offsets are in minutes from now; "" leaves NULL.
	 */
	private string function version(required string instrumentId, required string label, required string status, any startOffset, any endOffset, string snapshotJson = "", string checksum = "") {
		var id = variables.db.newGuid();
		var params = {
			"id": variables.db.guid(id), "instrumentId": variables.db.guid(arguments.instrumentId),
			"label": variables.db.nvarchar(arguments.label, 100), "status": variables.db.nvarchar(arguments.status, 20),
			"snapshot": variables.db.ntext(len(arguments.snapshotJson) ? arguments.snapshotJson : variables.snapshotJson),
			"checksum": variables.db.nvarchar(len(arguments.checksum) ? arguments.checksum : variables.checksum, 64),
			"publisher": variables.db.guid(arguments.status == "DRAFT" ? "" : variables.publisher)
		};
		var startSql = isNull(arguments.startOffset) ? "NULL" : "DATEADD(minute, " & int(arguments.startOffset) & ", SYSUTCDATETIME())";
		var endSql = isNull(arguments.endOffset) ? "NULL" : "DATEADD(minute, " & int(arguments.endOffset) & ", SYSUTCDATETIME())";
		var publishedSql = arguments.status == "PUBLISHED" ? "SYSUTCDATETIME()" : "NULL";
		variables.db.run(
			"INSERT INTO [icf].[instrument_version] (version_id, instrument_id, version_label, status, effective_start, effective_end, published_at, compiled_snapshot_json, checksum_sha256, published_by_user_id)
			 VALUES (:id, :instrumentId, :label, :status, " & startSql & ", " & endSql & ", " & publishedSql & ", :snapshot, :checksum, :publisher)",
			params
		);
		arrayAppend(variables.versionIds, id);
		return id;
	}

	private void function dropVersion(required string versionId) {
		variables.db.run("DELETE FROM [icf].[instrument_version] WHERE version_id = :id", { "id": variables.db.guid(arguments.versionId) });
	}

	// ---- current-version selection ----------------------------------------------------------------

	/** A second instrument's published version never becomes the ICFWalk runtime contract. */
	public void function testASecondInstrumentNeverSuppliesTheCurrentVersion() {
		var foreign = version(variables.foreignA, "foreign current " & variables.tag, "PUBLISHED", -60, javaCast("null", ""));
		var current = variables.snapshots.currentVersion();
		assertNotEquals(foreign, current.versionId, "the other instrument's published version is not selected");
		assertEquals(variables.seeded.versionId, current.versionId);
		dropVersion(foreign);
	}

	/** Only a version in effect right now is selected: not a future one, not an expired one. */
	public void function testFutureAndExpiredIcfwalkVersionsAreNotSelected() {
		var icfwalk = variables.repo.findInstrumentByCode(variables.c.config.instrumentCode);
		assertFalse(structIsEmpty(icfwalk), "the ICFWalk instrument exists");
		var future = version(icfwalk.instrumentId, "future " & variables.tag, "PUBLISHED", 60 * 24, javaCast("null", ""));
		var expired = version(icfwalk.instrumentId, "expired " & variables.tag, "PUBLISHED", -60 * 48, -60 * 24);
		var selected = variables.snapshots.currentVersion();
		assertNotEquals(future, selected.versionId, "a version that starts in the future is not selected");
		assertNotEquals(expired, selected.versionId, "a version whose window has closed is not selected");
		assertEquals(variables.seeded.versionId, selected.versionId, "the seeded DRAFT still answers outside production");

		// One that is in effect now does win, and is preferred over the DRAFT fallback.
		var inEffect = version(icfwalk.instrumentId, "in effect " & variables.tag, "PUBLISHED", -5, 60 * 24);
		var now = variables.snapshots.currentVersion();
		assertEquals(inEffect, now.versionId);
		assertEquals("PUBLISHED", now.status);
		assertFalse(now.isFallbackDraft);

		dropVersion(future);
		dropVersion(expired);
		dropVersion(inEffect);
		assertEquals(variables.seeded.versionId, variables.snapshots.currentVersion().versionId, "fixtures removed");
	}

	// ---- draft discard ------------------------------------------------------------------------------

	/** A draft discard is scoped by instrument identity, not by version label alone. */
	public void function testDiscardDraftCannotReachAnotherInstrumentsSameLabelDraft() {
		var label = "shared label " & variables.tag;
		var draftA = version(variables.foreignA, label, "DRAFT", javaCast("null", ""), javaCast("null", ""));
		var draftB = version(variables.foreignB, label, "DRAFT", javaCast("null", ""), javaCast("null", ""));
		var importer = variables.c.instrumentImportService;
		// Discarding the label under the ICFWalk instrument must not reach either foreign draft.
		assertThrows(function() { importer.discardDraft(label); }, "ICFWalk.NotFound", "VERSION_NOT_FOUND");
		assertEquals(1, variables.db.scalar("SELECT COUNT(*) AS n FROM [icf].[instrument_version] WHERE version_id = :id", { "id": variables.db.guid(draftA) }));
		assertEquals(1, variables.db.scalar("SELECT COUNT(*) AS n FROM [icf].[instrument_version] WHERE version_id = :id", { "id": variables.db.guid(draftB) }));
		// Naming instrument A removes exactly A's draft; B's identically labelled draft survives.
		var result = importer.discardDraft(label, "", "OTHER-A-" & variables.tag);
		assertEquals(draftA, result.versionId);
		assertEquals(0, variables.db.scalar("SELECT COUNT(*) AS n FROM [icf].[instrument_version] WHERE version_id = :id", { "id": variables.db.guid(draftA) }));
		assertEquals(1, variables.db.scalar("SELECT COUNT(*) AS n FROM [icf].[instrument_version] WHERE version_id = :id", { "id": variables.db.guid(draftB) }), "the other instrument's draft is untouched");
		dropVersion(draftB);
	}

	// ---- runtime snapshot integrity -----------------------------------------------------------------

	/** A stored snapshot that does not match its checksum is refused, not rendered and not cached. */
	public void function testACorruptedSnapshotFailsClosedOnAnUncachedLoad() {
		// The stored JSON is altered while the recorded digest stays as it was.
		var corruptedJson = reReplace(variables.snapshotJson, "^\{", "{""tamperedByTest"":true,", "one");
		assertNotEquals(variables.snapshotJson, corruptedJson, "the fixture actually changed the stored bytes");
		var corrupted = version(variables.foreignA, "corrupted " & variables.tag, "DRAFT", javaCast("null", ""), javaCast("null", ""), corruptedJson, variables.checksum);
		var snapshots = variables.snapshots;
		snapshots.clearCache();
		var e = assertThrows(function() { snapshots.renderModelFor(corrupted); }, "ICFWalk.Configuration", "INSTRUMENT_SNAPSHOT_CHECKSUM_MISMATCH");
		assertThrows(function() { snapshots.snapshotFor(corrupted); }, "ICFWalk.Configuration", "INSTRUMENT_SNAPSHOT_CHECKSUM_MISMATCH");

		// A snapshot with no recorded digest at all is refused for the same reason.
		var unchecked = version(variables.foreignA, "unchecked " & variables.tag, "DRAFT", javaCast("null", ""), javaCast("null", ""), variables.snapshotJson, "");
		variables.db.run("UPDATE [icf].[instrument_version] SET checksum_sha256 = NULL WHERE version_id = :id", { "id": variables.db.guid(unchecked) });
		assertThrows(function() { snapshots.renderModelFor(unchecked); }, "ICFWalk.Configuration", "INSTRUMENT_SNAPSHOT_CHECKSUM_MISSING");

		// The intact copy of the same bytes still loads, so the check is on the content, not the row.
		var intact = version(variables.foreignA, "intact " & variables.tag, "DRAFT", javaCast("null", ""), javaCast("null", ""), variables.snapshotJson, variables.checksum);
		assertEquals("icfwalk-render-model/1", snapshots.renderModelFor(intact).format);

		dropVersion(corrupted);
		dropVersion(unchecked);
		dropVersion(intact);
		snapshots.clearCache();
	}
}
