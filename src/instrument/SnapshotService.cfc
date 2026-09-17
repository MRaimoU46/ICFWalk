/**
 * Resolves and caches the compiled instrument snapshot the runtime renders from.
 *
 * The rendering contract for walks is the compiled snapshot stored on icf.instrument_version
 * (docs/DATA_CONTRACT.md). The "current" version is the newest PUBLISHED version (published_at
 * descending). Publishing arrives in Phase 6; until a version is published, deployments outside
 * production may render the newest DRAFT that carries a snapshot when
 * ICFWALK_ALLOW_UNPUBLISHED_INSTRUMENT=true (the default outside production, refused in
 * production). Responses mark such a version with isFallbackDraft=true so the UI can say so.
 *
 * Snapshots are parsed once per (versionId, checksum) and cached in this singleton; a published
 * version is immutable, and a DRAFT re-import changes its checksum, which invalidates the entry.
 */
component output="false" {

	public SnapshotService function init(required struct config, required any db, required any definitionRepository, required any renderModelBuilder, required any errors, required any logger) {
		variables.config = arguments.config;
		variables.db = arguments.db;
		variables.definitions = arguments.definitionRepository;
		variables.builder = arguments.renderModelBuilder;
		variables.errors = arguments.errors;
		variables.logger = arguments.logger;
		variables.cache = {};
		return this;
	}

	/**
	 * Returns { versionId, versionLabel, status, checksum, publishedAt, isFallbackDraft } for the
	 * version walks are created against, or an empty struct when nothing renderable exists.
	 */
	public struct function currentVersion() {
		var q = variables.db.run(
			"SELECT TOP 1 v.version_id, v.version_label, v.status, v.checksum_sha256, v.published_at
			 FROM [icf].[instrument_version] v
			 JOIN [icf].[instrument] i ON i.instrument_id = v.instrument_id
			 WHERE v.status = N'PUBLISHED' AND v.compiled_snapshot_json IS NOT NULL AND i.active = 1
			 ORDER BY v.published_at DESC, v.created_at DESC"
		);
		if (q.recordCount) return rowToVersion(q, false);
		if (!variables.config.allowUnpublishedInstrument) return {};
		q = variables.db.run(
			"SELECT TOP 1 v.version_id, v.version_label, v.status, v.checksum_sha256, v.published_at
			 FROM [icf].[instrument_version] v
			 JOIN [icf].[instrument] i ON i.instrument_id = v.instrument_id
			 WHERE v.status = N'DRAFT' AND v.compiled_snapshot_json IS NOT NULL AND i.active = 1
			 ORDER BY v.updated_at DESC, v.created_at DESC"
		);
		if (!q.recordCount) return {};
		return rowToVersion(q, true);
	}

	/** Parsed snapshot document for a version id (cached by checksum). */
	public struct function snapshotFor(required string versionId) {
		return loadEntry(arguments.versionId).snapshot;
	}

	/** Render model (RenderModelBuilder output) for a version id (cached by checksum). */
	public struct function renderModelFor(required string versionId) {
		return loadEntry(arguments.versionId).model;
	}

	/**
	 * Current version plus its render model, shaped for GET /api/instrument/current. Throws
	 * ICFWalk.NotFound (INSTRUMENT_NOT_AVAILABLE) when no renderable version exists.
	 */
	public struct function currentRenderModel() {
		var v = currentVersion();
		if (structIsEmpty(v)) {
			variables.errors.notFound("No instrument version is available for walks yet. Seed and publish an instrument version.", "INSTRUMENT_NOT_AVAILABLE");
		}
		var entry = loadEntry(v.versionId);
		return { "version": v, "model": entry.model };
	}

	public void function clearCache() { variables.cache = {}; }

	// ---- internals ---------------------------------------------------------------------------

	private struct function loadEntry(required string versionId) {
		if (!variables.db.isGuid(arguments.versionId)) variables.errors.validation("Invalid instrument version identifier.", "INVALID_VERSION_ID");
		var id = uCase(arguments.versionId);
		var row = variables.definitions.findVersionById(id);
		if (structIsEmpty(row)) variables.errors.notFound("Instrument version not found.", "INSTRUMENT_VERSION_NOT_FOUND");
		if (isNull(row.snapshotJson) || !len(row.snapshotJson)) variables.errors.notFound("Instrument version has no compiled snapshot.", "INSTRUMENT_SNAPSHOT_MISSING");
		var checksum = isNull(row.checksum) ? "" : row.checksum;
		if (structKeyExists(variables.cache, id) && variables.cache[id].checksum == checksum) return variables.cache[id];
		var snapshot = deserializeJSON(row.snapshotJson);
		if (!isStruct(snapshot) || !structKeyExists(snapshot, "definitions")) variables.errors.configuration("Stored snapshot for version " & id & " is not a valid instrument snapshot.", "INSTRUMENT_SNAPSHOT_INVALID");
		var entry = { "checksum": checksum, "snapshot": snapshot, "model": variables.builder.build(snapshot) };
		variables.cache[id] = entry;
		variables.logger.info("instrument.snapshot.loaded", { "versionId": id, "checksum": checksum, "status": row.status });
		return entry;
	}

	private struct function rowToVersion(required query q, required boolean fallback) {
		return {
			"versionId": uCase(arguments.q.version_id[1]),
			"versionLabel": arguments.q.version_label[1],
			"status": arguments.q.status[1],
			"checksum": isNull(arguments.q.checksum_sha256[1]) ? "" : arguments.q.checksum_sha256[1],
			"publishedAt": isDate(arguments.q.published_at[1]) ? arguments.q.published_at[1] : "",
			"isFallbackDraft": arguments.fallback
		};
	}
}
