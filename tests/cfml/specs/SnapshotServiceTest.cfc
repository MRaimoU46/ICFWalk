/**
 * SnapshotService: current-version resolution (PUBLISHED first, documented DRAFT fallback outside
 * production), parsing, caching by checksum, and fail-closed errors.
 */
component extends="icfwalktests.BaseSpec" output="false" {

	public string function skipReason() {
		return schemaPresent() ? "" : "icf schema is not present.";
	}

	public void function beforeAll() {
		variables.golden = repoJson("tests/golden/instrument-snapshot.golden.json");
		// Guarantee the seeded DRAFT exists (idempotent).
		variables.c.instrumentImportService.importFromFile(variables.c.config.instrumentConfigPath);
		variables.service = variables.c.snapshotService;
	}

	public void function testCurrentVersionFallsBackToTheSeededDraftOutsideProduction() {
		assertTrue(variables.c.config.allowUnpublishedInstrument, "Development allows the DRAFT fallback.");
		var v = variables.service.currentVersion();
		assertFalse(structIsEmpty(v), "A renderable version exists.");
		assertExactTextEquals("2026-09-17 aligned prototype", v.versionLabel);
		assertExactTextEquals("DRAFT", v.status);
		assertTrue(v.isFallbackDraft);
		assertExactTextEquals(variables.golden.checksum, v.checksum);
		var current = variables.service.currentRenderModel();
		assertExactTextEquals("icfwalk-render-model/1", current.model.format);
		assertExactTextEquals(v.versionId, current.version.versionId);
	}

	public void function testProductionSemanticsRequireAPublishedVersion() {
		var cfg = duplicate(variables.c.config);
		cfg.allowUnpublishedInstrument = false;
		var strict = new icfwalk.instrument.SnapshotService(cfg, variables.c.db, variables.c.definitionRepository, variables.c.renderModelBuilder, variables.c.errors, variables.c.logger, variables.c.canonicalJson);
		var published = variables.c.db.scalar("SELECT COUNT(*) AS n FROM [icf].[instrument_version] WHERE status = N'PUBLISHED'");
		if (published > 0) return; // Phase 6 publishes; then this rule is covered by the published path.
		assertTrue(structIsEmpty(strict.currentVersion()), "No DRAFT fallback when disallowed.");
		assertThrows(function() { strict.currentRenderModel(); }, "ICFWalk.NotFound", "INSTRUMENT_NOT_AVAILABLE");
	}

	public void function testSnapshotIsParsedOnceAndCachedByChecksum() {
		var v = variables.service.currentVersion();
		variables.service.clearCache();
		var a = variables.service.snapshotFor(v.versionId);
		var b = variables.service.snapshotFor(v.versionId);
		assertExactTextEquals("icfwalk-instrument-snapshot/1", a.snapshotFormat);
		assertEquals(23, arrayLen(a.definitions.sections));
		assertTrue(a.equals(b), "Same parsed instance is served while the checksum is unchanged.");
		var model = variables.service.renderModelFor(v.versionId);
		assertEquals(144, model.counts.items);
		// The stored snapshot equals the reference compilation byte for byte.
		var row = variables.c.definitionRepository.findVersionById(v.versionId);
		assertExactTextEquals(variables.golden.checksum, variables.c.canonicalJson.sha256(row.snapshotJson));
	}

	public void function testInvalidAndUnknownVersionsFailClosed() {
		assertThrows(function() { variables.service.snapshotFor("not-a-guid"); }, "ICFWalk.Validation", "INVALID_VERSION_ID");
		assertThrows(function() { variables.service.snapshotFor("00000000-0000-0000-0000-000000000000"); }, "ICFWalk.NotFound", "INSTRUMENT_VERSION_NOT_FOUND");
	}
}
