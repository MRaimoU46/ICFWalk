/**
 * Data access for instrument configuration tables (icf.instrument, instrument_version,
 * section_definition, response_set, response_option, rule_definition, dimension_definition,
 * dimension_value, instrument_dimension, instrument_dimension_value, item_definition). All
 * statements are parameterized.
 *
 * THE DRAFT-ONLY WRITE BOUNDARY (ADM-05). Every method below that writes definition content for a
 * version does two things before and during the write, and neither is optional:
 *
 *   1. requireDraftVersion() takes the owning instrument_version row under UPDLOCK/ROWLOCK and
 *      refuses anything that is not a DRAFT. It runs inside the caller's transaction, so the status
 *      it read cannot go stale before the write, and it is called by the repository method itself --
 *      a caller cannot forget it, because there is no path to the DML that does not pass through it.
 *      Methods that are handed only a child id (an option id, a section id) resolve the owner from
 *      the child in the same statement rather than trusting what they were told.
 *   2. The DML is status-qualified: every UPDATE, DELETE and INSERT carries the owning version's
 *      `status = N'DRAFT'` in its own predicate. This is the structural half. If the lock above were
 *      ever bypassed, skipped or defeated, the statement still matches no rows, so a PUBLISHED or
 *      RETIRED version cannot be overwritten or deleted by any statement in this file.
 *
 * A refused write therefore changes nothing: no row, no row_version, no timestamp. A refused write
 * that somehow reached the DML writes nothing either, and the importer's round-trip checksum proof
 * (InstrumentImportService step 4) fails the whole transaction rather than committing a partial one.
 *
 * There is no unchecked deletion path. deleteDraftVersionCascade refuses a non-DRAFT version like
 * every other mutator; test fixtures that must remove a published fixture version use the test-only
 * harness in tests/cfml/support/FixtureCleanup.cfc, which no application code can reach.
 *
 * VERSION-SCOPED DIMENSIONS (migration 006). icf.dimension_definition and icf.dimension_value hold
 * reporting identity only -- dimension_id, code, value_id, value_code -- created once when a code is
 * first seen and never updated again, so a walk's stored value_id keeps meaning the same thing
 * across versions. Everything a version authors about a dimension (label, data type, reportability,
 * sensitivity, settings, activity) lives on its own icf.instrument_dimension row, and the values it
 * offers (membership, label, order, effective window, activity) live in icf.instrument_dimension_value.
 * loadNormalizedDefinitions reads the version-scoped rows, so importing or editing V2 cannot change
 * what V1's definitions say.
 */
component output="false" {

	variables.PARK_OFFSET = 1000000;

	public DefinitionRepository function init(required any db, required any canonicalJson, required any errors) {
		variables.db = arguments.db;
		variables.json = arguments.canonicalJson;
		variables.errors = arguments.errors;
		variables.mapper = new icfwalk.instrument.DefinitionMapper(arguments.canonicalJson);
		return this;
	}

	public any function mapper() { return variables.mapper; }

	// ---- the DRAFT-only write boundary --------------------------------------------------------

	/**
	 * Resolves and locks the owning version, then refuses anything that is not a DRAFT.
	 *
	 * Call inside the transaction that will do the writing: the UPDLOCK is what makes the answer
	 * still true at the moment of the write, and it is taken on instrument_version first, which is
	 * the same row, in the same order, that publish() and import() each take before touching
	 * anything else. One lock order, so a publish racing an edit queues instead of interleaving.
	 *
	 * @return { versionId, versionLabel, status, instrumentId }
	 */
	public struct function requireDraftVersion(required string versionId) {
		var version = lockVersion(arguments.versionId);
		if (structIsEmpty(version)) {
			variables.errors.notFound("Instrument version not found.", "INSTRUMENT_VERSION_NOT_FOUND");
		}
		if (version.status != "DRAFT") {
			variables.errors.publishNotDraft(version.versionLabel, version.status);
		}
		return version;
	}

	/** The locked identity read requireDraftVersion and publish() both start from. */
	public struct function lockVersion(required string versionId) {
		var q = variables.db.run(
			"SELECT v.version_id, v.instrument_id, v.version_label, v.status
			 FROM [icf].[instrument_version] v WITH (UPDLOCK, ROWLOCK) WHERE v.version_id = :id",
			{ "id": variables.db.guid(arguments.versionId) }
		);
		if (!q.recordCount) return {};
		return { "versionId": uCase(q.version_id[1]), "instrumentId": uCase(q.instrument_id[1]), "versionLabel": q.version_label[1], "status": q.status[1] };
	}

	/**
	 * Resolves the version that owns a child row and refuses unless the caller named the same one.
	 * A method handed only a child id gets the owner from the database, not from its arguments, so
	 * a wrong or absent versionId cannot widen what it may write.
	 */
	private struct function requireDraftOwnerOf(required string table, required string idColumn, required string childId, required string versionId) {
		var owner = "";
		if (arguments.table == "response_option") {
			owner = variables.db.run(
				"SELECT s.version_id FROM [icf].[response_option] o JOIN [icf].[response_set] s ON s.response_set_id = o.response_set_id WHERE o.option_id = :childId",
				{ "childId": variables.db.guid(arguments.childId) }
			);
		} else {
			owner = variables.db.run(
				"SELECT version_id FROM [icf].[" & arguments.table & "] WHERE [" & arguments.idColumn & "] = :childId",
				{ "childId": variables.db.guid(arguments.childId) }
			);
		}
		if (!owner.recordCount) {
			variables.errors.notFound("Instrument definition row not found.", "INSTRUMENT_DEFINITION_NOT_FOUND");
		}
		var ownerVersionId = uCase(owner.version_id[1]);
		if (ownerVersionId != uCase(trim(arguments.versionId))) {
			variables.errors.validation("The definition row belongs to a different instrument version.", "INSTRUMENT_DEFINITION_VERSION_MISMATCH");
		}
		return requireDraftVersion(ownerVersionId);
	}

	// ---- instrument and version -------------------------------------------------------------

	public array function listVersions() {
		var q = variables.db.run(
			"SELECT v.version_id, i.code AS instrument_code, v.version_label, v.status, v.effective_start, v.effective_end,
			        v.checksum_sha256, v.created_at, v.published_at, v.updated_at, v.published_by_user_id,
			        (SELECT COUNT(*) FROM [icf].[walk] w WHERE w.version_id = v.version_id) AS walk_count
			 FROM [icf].[instrument_version] v
			 JOIN [icf].[instrument] i ON i.instrument_id = v.instrument_id
			 ORDER BY i.code, v.created_at DESC"
		);
		var out = [];
		for (var r = 1; r <= q.recordCount; r++) {
			var row = {};
			row["versionId"] = uCase(q.version_id[r]);
			row["instrumentCode"] = q.instrument_code[r];
			row["versionLabel"] = q.version_label[r];
			row["status"] = q.status[r];
			row["checksum"] = len(q.checksum_sha256[r]) ? q.checksum_sha256[r] : javaCast("null", "");
			row["effectiveStart"] = isDate(q.effective_start[r]) ? variables.json.formatDate(q.effective_start[r]) : javaCast("null", "");
			row["publishedAt"] = isDate(q.published_at[r]) ? variables.json.formatDate(q.published_at[r]) : javaCast("null", "");
			row["publishedByUserId"] = len(q.published_by_user_id[r]) ? uCase(q.published_by_user_id[r]) : javaCast("null", "");
			row["createdAt"] = variables.json.formatDate(q.created_at[r]);
			row["updatedAt"] = variables.json.formatDate(q.updated_at[r]);
			row["walkCount"] = q.walk_count[r];
			arrayAppend(out, row);
		}
		return out;
	}

	/**
	 * An ordinary, UNLOCKED read of the shared row. Safe for resolving an id or reporting; never
	 * safe as the source of values a later write will restate. Use lockInstrumentByCode or
	 * lockInstrumentById for that.
	 */
	public struct function findInstrumentByCode(required string code) {
		var q = variables.db.run("SELECT instrument_id, code, name, description, active FROM [icf].[instrument] WHERE code = :code", { "code": variables.db.nvarchar(arguments.code, 60) });
		if (!q.recordCount) return {};
		return { "instrumentId": uCase(q.instrument_id[1]), "code": q.code[1], "name": q.name[1], "description": q.description[1], "active": q.active[1] };
	}

	/**
	 * The shared instrument row, taken under UPDLOCK with transaction-duration protection, and read
	 * in the same statement that takes the lock.
	 *
	 * WHY BOTH HINTS. UPDLOCK alone is released at the end of the statement unless the transaction
	 * holds it; HOLDLOCK (SERIALIZABLE) keeps it until the transaction ends. Together they mean
	 * "nobody else may take this row to update it until I commit", which is what makes the values
	 * read here still true at the moment they are written back.
	 *
	 * WHY IT EXISTS AT ALL. InstrumentMetadataService derives a COMPLETE replacement row: a patch
	 * that changes one field keeps the stored value of every field it omits. Deriving those omitted
	 * values from an unlocked read and writing them after taking a lock is a lost update -- two
	 * partial patches both restate what they read, and whichever commits second silently undoes the
	 * other. icf.instrument.active is part of SnapshotService.currentVersion()'s predicate, so the
	 * change that gets undone can be "take this published version out of service".
	 *
	 * CALL INSIDE THE TRANSACTION THAT WILL WRITE. Outside one the lock is released immediately and
	 * proves nothing.
	 *
	 * LOCK ORDER. This takes only icf.instrument. Import takes icf.instrument_version first and
	 * then this row; publish takes icf.instrument_version and never holds this one. There is no
	 * path that takes icf.instrument before icf.instrument_version, so these queue rather than
	 * deadlock.
	 */
	public struct function lockInstrumentByCode(required string code) {
		return instrumentRow(
			"SELECT instrument_id, code, name, description, active FROM [icf].[instrument] WITH (UPDLOCK, HOLDLOCK, ROWLOCK) WHERE code = :key",
			variables.db.nvarchar(arguments.code, 60)
		);
	}

	/** The same locked read, by id, for a caller that has already resolved the instrument. */
	public struct function lockInstrumentById(required string instrumentId) {
		return instrumentRow(
			"SELECT instrument_id, code, name, description, active FROM [icf].[instrument] WITH (UPDLOCK, HOLDLOCK, ROWLOCK) WHERE instrument_id = :key",
			variables.db.guid(arguments.instrumentId)
		);
	}

	private struct function instrumentRow(required string sql, required struct key) {
		var q = variables.db.run(arguments.sql, { "key": arguments.key });
		if (!q.recordCount) return {};
		return {
			"instrumentId": uCase(q.instrument_id[1]),
			"code": q.code[1],
			"name": q.name[1],
			"description": isNull(q.description[1]) ? javaCast("null", "") : q.description[1],
			"active": (isBoolean(q.active[1]) && q.active[1]) ? true : false
		};
	}

	/**
	 * Creates an instrument that does not exist yet. INSERT ONLY, and the only write in this file
	 * that does not take a version lock -- because at this moment the instrument has no versions at
	 * all, so there is nothing frozen to protect. UQ/PK on `code` makes a second call for the same
	 * code fail rather than overwrite, so this method cannot reach an existing instrument even if
	 * a caller tried.
	 *
	 * The document defines the shared row exactly once, here, at the instrument's birth. After
	 * that, shared metadata is never import-owned: see updateInstrumentMetadata below and the
	 * conflict refusal in InstrumentImportService.
	 */
	public string function createInstrument(required string code, required string name, any description, boolean active = true) {
		var id = variables.db.newGuid();
		variables.db.run(
			"INSERT INTO [icf].[instrument] (instrument_id, code, name, description, active) VALUES (:id, :code, :name, :description, :active)",
			{ "id": variables.db.guid(id), "code": variables.db.nvarchar(arguments.code, 60), "name": variables.db.nvarchar(arguments.name, 200), "description": variables.db.nvarchar(isNull(arguments.description) ? javaCast("null", "") : arguments.description, 1000), "active": variables.db.bit(arguments.active) }
		);
		return id;
	}

	/**
	 * Changes the shared instrument row: its name, description, and whether it is in service.
	 *
	 * WHY THIS IS NOT updateInstrument, AND WHY IMPORT NO LONGER CALLS IT. The importer used to
	 * write this row on every re-import, straight from the document, with no authorization beyond
	 * "an import happened". icf.instrument.active is part of SnapshotService.currentVersion()'s
	 * selection predicate, so importing a V2 DRAFT whose document said active = false made an
	 * already PUBLISHED V1 vanish from the runtime -- a frozen version made unavailable by an edit
	 * to an unfrozen one, with no audit naming who did it and no version row changed to show it.
	 *
	 * Instrument-level facts are now changed only here. AUTHORIZATION IS NOT DONE HERE: the
	 * userExists() call below is an INTEGRITY check -- icf.audit_event.actor_user_id is a foreign
	 * key to icf.app_user, so an id this deployment has never heard of would make the audit trail
	 * name nobody -- and it is not, and must never be described as, a permission check. Any row in
	 * icf.app_user satisfies it. Whether the caller may change shared instrument metadata is
	 * decided by AuthorizationService (global `instrument.manage`) in InstrumentMetadataService,
	 * before this is reached.
	 *
	 * THE ROW MUST ALREADY BE LOCKED. This performs the UPDATE only. The caller takes the row under
	 * lockInstrumentByCode/lockInstrumentById first and derives `name`, `description` and `active`
	 * from THAT read, inside the same transaction, because a partial patch restates the fields it
	 * omits and a lock taken after the read those values came from protects nothing. The statement
	 * is re-asserted against the instrument id it was given, so a caller that skipped the lock
	 * still cannot write a row that does not exist -- but it can lose an update, which is why the
	 * lock is the caller's contract and is documented as such.
	 *
	 * There is deliberately no route: this pass closes the boundary and does not add
	 * administration UI for it.
	 */
	public numeric function updateInstrumentMetadata(
		required string instrumentId, required string name, any description,
		required boolean active, required string authorizedByUserId
	) {
		// Integrity, not authorization: the audit actor must be a row icf.app_user really has.
		if (!variables.db.isGuid(arguments.authorizedByUserId) || !userExists(arguments.authorizedByUserId)) {
			variables.errors.validation("The audit actor for a shared instrument metadata change must be a known application user.", "INSTRUMENT_METADATA_ACTOR_REQUIRED");
		}
		var present = variables.db.run(
			"SELECT instrument_id FROM [icf].[instrument] WITH (UPDLOCK, HOLDLOCK, ROWLOCK) WHERE instrument_id = :id",
			{ "id": variables.db.guid(arguments.instrumentId) }
		);
		if (!present.recordCount) {
			variables.errors.notFound("Instrument not found.", "INSTRUMENT_NOT_FOUND");
		}
		variables.db.run(
			"UPDATE [icf].[instrument] SET name = :name, description = :description, active = :active, updated_at = SYSUTCDATETIME() WHERE instrument_id = :id",
			{ "id": variables.db.guid(arguments.instrumentId), "name": variables.db.nvarchar(arguments.name, 200), "description": variables.db.nvarchar(isNull(arguments.description) ? javaCast("null", "") : arguments.description, 1000), "active": variables.db.bit(arguments.active) }
		);
		return variables.db.scalar(
			"SELECT COUNT(*) AS n FROM [icf].[instrument] WHERE instrument_id = :id AND name = :name AND active = :active",
			{ "id": variables.db.guid(arguments.instrumentId), "name": variables.db.nvarchar(arguments.name, 200), "active": variables.db.bit(arguments.active) }
		);
	}

	public struct function findVersion(required string instrumentId, required string versionLabel, boolean lockForUpdate = false) {
		var hint = arguments.lockForUpdate ? " WITH (UPDLOCK, HOLDLOCK)" : "";
		var q = variables.db.run(
			"SELECT version_id, status, checksum_sha256, updated_at FROM [icf].[instrument_version]" & hint & " WHERE instrument_id = :instrumentId AND version_label = :label",
			{ "instrumentId": variables.db.guid(arguments.instrumentId), "label": variables.db.nvarchar(arguments.versionLabel, 100) }
		);
		if (!q.recordCount) return {};
		return { "versionId": uCase(q.version_id[1]), "status": q.status[1], "checksum": q.checksum_sha256[1], "updatedAt": q.updated_at[1] };
	}

	public struct function findVersionById(required string versionId) {
		return versionRow(
			"SELECT v.version_id, v.instrument_id, i.code AS instrument_code, v.version_label, v.status, v.checksum_sha256,
			        v.compiled_snapshot_json, v.published_by_user_id, v.published_at, v.effective_start, v.updated_at, v.row_version
			 FROM [icf].[instrument_version] v JOIN [icf].[instrument] i ON i.instrument_id = v.instrument_id
			 WHERE v.version_id = :id",
			arguments.versionId
		);
	}

	/**
	 * findVersionById under the same row lock every mutation path takes, so a publish and a
	 * concurrent import or publish of the same version queue on the walk of one row rather than
	 * racing. Call inside a transaction; outside one the lock is released immediately and proves
	 * nothing.
	 */
	public struct function findVersionByIdForUpdate(required string versionId) {
		return versionRow(
			"SELECT v.version_id, v.instrument_id, i.code AS instrument_code, v.version_label, v.status, v.checksum_sha256,
			        v.compiled_snapshot_json, v.published_by_user_id, v.published_at, v.effective_start, v.updated_at, v.row_version
			 FROM [icf].[instrument_version] v WITH (UPDLOCK, ROWLOCK) JOIN [icf].[instrument] i ON i.instrument_id = v.instrument_id
			 WHERE v.version_id = :id",
			arguments.versionId
		);
	}

	private struct function versionRow(required string sql, required string versionId) {
		var q = variables.db.run(arguments.sql, { "id": variables.db.guid(arguments.versionId) });
		if (!q.recordCount) return {};
		return {
			"versionId": uCase(q.version_id[1]),
			"instrumentId": uCase(q.instrument_id[1]),
			"instrumentCode": q.instrument_code[1],
			"versionLabel": q.version_label[1],
			"status": q.status[1],
			"checksum": q.checksum_sha256[1],
			"snapshotJson": q.compiled_snapshot_json[1],
			"publishedByUserId": len(q.published_by_user_id[1]) ? uCase(q.published_by_user_id[1]) : "",
			"publishedAt": q.published_at[1],
			"effectiveStart": q.effective_start[1],
			"updatedAt": q.updated_at[1],
			"rowVersion": binaryEncode(q.row_version[1], "hex")
		};
	}

	/**
	 * True when the id names an existing application user.
	 *
	 * INTEGRITY, NOT AUTHORIZATION. This answers "does icf.app_user have this row", which is what
	 * icf.audit_event.actor_user_id's foreign key requires and what stops an audit event naming
	 * somebody the deployment has never heard of. It says nothing whatever about what that user may
	 * do: every user in the table satisfies it. Permission is decided by AuthorizationService, from
	 * the principal's effective role assignments, before any caller reaches this file.
	 */
	public boolean function userExists(required string userId) {
		if (!variables.db.isGuid(arguments.userId)) return false;
		return variables.db.scalar("SELECT COUNT(*) AS n FROM [icf].[app_user] WHERE user_id = :id", { "id": variables.db.guid(arguments.userId) }) == 1;
	}

	/**
	 * The publish write, as one statement. Status, publisher, publication time, effective start,
	 * snapshot and checksum move together or not at all: CK_instrument_version_publish_values
	 * rejects any non-DRAFT row missing one of them and CK_instrument_version_publisher_required
	 * (migration 006) rejects one with no publisher, so a partial publish cannot be stored even if
	 * a future caller tried. The WHERE clause re-asserts DRAFT, so two publishers racing on the
	 * same version cannot both succeed; the loser updates nothing and is told so by the row count.
	 *
	 * publishedByUserId is required and must be a real app_user: there is no default, and no path
	 * that publishes with nobody named.
	 */
	public numeric function markPublished(required string versionId, required string canonicalJson, required string checksum, required string publishedByUserId) {
		if (!variables.db.isGuid(arguments.publishedByUserId)) {
			variables.errors.validation("A publisher is required to publish an instrument version.", "PUBLISHER_REQUIRED");
		}
		requireDraftVersion(arguments.versionId);
		variables.db.run(
			"UPDATE [icf].[instrument_version]
			    SET status = N'PUBLISHED',
			        compiled_snapshot_json = :snapshot,
			        checksum_sha256 = :checksum,
			        published_by_user_id = :publishedBy,
			        published_at = SYSUTCDATETIME(),
			        effective_start = COALESCE(effective_start, SYSUTCDATETIME()),
			        updated_at = SYSUTCDATETIME()
			  WHERE version_id = :id AND status = N'DRAFT'",
			{
				"id": variables.db.guid(arguments.versionId),
				"snapshot": variables.db.ntext(arguments.canonicalJson),
				"checksum": { "value": arguments.checksum, "cfsqltype": "cf_sql_char" },
				"publishedBy": variables.db.guid(arguments.publishedByUserId)
			}
		);
		// Read back inside the same transaction rather than trusting a driver-reported row count.
		// The publisher is part of the predicate: a row that became PUBLISHED under somebody else
		// is not this call's success.
		return variables.db.scalar(
			"SELECT COUNT(*) AS n FROM [icf].[instrument_version]
			  WHERE version_id = :id AND status = N'PUBLISHED' AND published_by_user_id = :publishedBy",
			{ "id": variables.db.guid(arguments.versionId), "publishedBy": variables.db.guid(arguments.publishedByUserId) }
		);
	}

	/**
	 * Serializes retirements of one instrument (Phase 6, ADM-07), for the rest of the caller's
	 * transaction.
	 *
	 * Retirement refuses to leave an instrument with no version in service unless confirmed, and
	 * decides that from the OTHER versions' rows, which it reads without locking them. Two
	 * retirements of the two in-service versions, each holding only its own version row, could
	 * therefore each see the other still in service and both commit: nothing in service, nobody
	 * confirmed it (RetireConcurrencyBarrierTest.testTwoRetirementsCannotTogetherLeaveNothingInService).
	 *
	 * This takes an exclusive, transaction-owned application lock named for the instrument. Only
	 * retirement takes it, after its version row lock, so it adds no edge to the lock order the
	 * other operations share (version row, then instrument row): a second retirement of the same
	 * instrument queues here and decides after the first has committed. The lock is released by the
	 * commit or rollback; there is nothing to release by hand.
	 */
	public void function lockRetirement(required string instrumentId) {
		var granted = variables.db.scalar(
			"SET NOCOUNT ON;
			 DECLARE @result int;
			 EXEC @result = sp_getapplock @Resource = :resource, @LockMode = 'Exclusive', @LockOwner = 'Transaction', @LockTimeout = 30000;
			 SELECT @result AS granted;",
			{ "resource": variables.db.nvarchar("icfwalk:retire:" & uCase(arguments.instrumentId), 255) },
			-999
		);
		// 0 granted at once, 1 granted after waiting; anything negative is a timeout, a deadlock
		// or a call outside a transaction, and retirement must not proceed unserialized.
		if (granted < 0) {
			variables.errors.conflict("Another retirement of this instrument is still in progress. Try again.", "RETIRE_IN_PROGRESS", { "applockResult": granted });
		}
	}

	/**
	 * Retirement (Phase 6, ADM-07): PUBLISHED -> RETIRED, as one status-qualified statement.
	 *
	 * The row keeps everything publication froze -- snapshot, checksum, publisher, published_at,
	 * effective_start -- because walks already pinned to the version keep rendering from exactly
	 * that snapshot. Two things change: the status, which takes the version out of
	 * SnapshotService.currentVersion()'s predicate so no new walk can be created against it, and
	 * effective_end, which records when it stopped being in service. effective_end must be after
	 * effective_start (CK_instrument_version_dates), so a version retired in the same millisecond it
	 * took effect ends one millisecond later rather than failing the constraint.
	 *
	 * The WHERE clause re-asserts PUBLISHED, so a DRAFT cannot be retired (it is discarded instead)
	 * and a second retirement matches nothing. Only PUBLISHED may become RETIRED; the caller locks
	 * the row first (findVersionByIdForUpdate) and decides under that lock, and this statement is
	 * the structural half that holds even if a caller did not. Returns 1 when this call retired the
	 * version, read back rather than trusted from a driver row count.
	 *
	 * Attribution is the INSTRUMENT_VERSION_RETIRED audit event the caller writes in the same
	 * transaction; the schema carries no retired-by column and this adds none
	 * (docs/OPEN_DECISIONS.md).
	 */
	public numeric function markRetired(required string versionId) {
		var params = { "id": variables.db.guid(arguments.versionId) };
		var before = variables.db.run(
			"SELECT status FROM [icf].[instrument_version] WITH (UPDLOCK, ROWLOCK) WHERE version_id = :id",
			params
		);
		if (!before.recordCount) variables.errors.notFound("Instrument version not found.", "INSTRUMENT_VERSION_NOT_FOUND");
		if (before.status[1] != "PUBLISHED") return 0;
		variables.db.run(
			"UPDATE [icf].[instrument_version]
			    SET status = N'RETIRED',
			        effective_end = CASE WHEN SYSUTCDATETIME() > effective_start THEN SYSUTCDATETIME()
			                             ELSE DATEADD(millisecond, 1, effective_start) END,
			        updated_at = SYSUTCDATETIME()
			  WHERE version_id = :id AND status = N'PUBLISHED'",
			params
		);
		return variables.db.scalar(
			"SELECT COUNT(*) AS n FROM [icf].[instrument_version] WHERE version_id = :id AND status = N'RETIRED' AND effective_end IS NOT NULL",
			params
		);
	}

	/**
	 * The version the runtime would serve for this instrument if `excludingVersionId` were not
	 * there, by the same predicate SnapshotService.currentVersion() uses (PUBLISHED, a snapshot,
	 * in effect now, newest first). Empty when there is none. Retirement uses it to tell an
	 * administrator that retiring this version leaves nothing for new walks.
	 */
	public struct function findCurrentVersionExcluding(required string instrumentId, required string excludingVersionId) {
		var q = variables.db.run(
			"SELECT TOP 1 v.version_id, v.version_label
			   FROM [icf].[instrument_version] v
			  WHERE v.instrument_id = :instrumentId AND v.version_id <> :excluding
			    AND v.status = N'PUBLISHED' AND v.compiled_snapshot_json IS NOT NULL
			    AND v.effective_start IS NOT NULL AND v.effective_start <= SYSUTCDATETIME()
			    AND (v.effective_end IS NULL OR v.effective_end > SYSUTCDATETIME())
			  ORDER BY v.effective_start DESC, v.published_at DESC, v.created_at DESC",
			{ "instrumentId": variables.db.guid(arguments.instrumentId), "excluding": variables.db.guid(arguments.excludingVersionId) }
		);
		if (!q.recordCount) return {};
		return { "versionId": uCase(q.version_id[1]), "versionLabel": q.version_label[1] };
	}

	/**
	 * For each instrument, the version the runtime would serve now -- the same predicate as
	 * SnapshotService.currentVersion(), including the shared row's `active` -- as a set of version
	 * ids. Read-only; the administration list marks these as current.
	 */
	public struct function currentVersionIds() {
		var q = variables.db.run(
			"SELECT ranked.version_id FROM (
			    SELECT v.version_id,
			           ROW_NUMBER() OVER (PARTITION BY v.instrument_id ORDER BY v.effective_start DESC, v.published_at DESC, v.created_at DESC) AS rn
			      FROM [icf].[instrument_version] v
			      JOIN [icf].[instrument] i ON i.instrument_id = v.instrument_id
			     WHERE i.active = 1 AND v.status = N'PUBLISHED' AND v.compiled_snapshot_json IS NOT NULL
			       AND v.effective_start IS NOT NULL AND v.effective_start <= SYSUTCDATETIME()
			       AND (v.effective_end IS NULL OR v.effective_end > SYSUTCDATETIME())
			 ) ranked WHERE ranked.rn = 1"
		);
		var out = {};
		for (var r = 1; r <= q.recordCount; r++) out[uCase(q.version_id[r])] = true;
		return out;
	}

	public string function createDraftVersion(required string instrumentId, required string versionLabel, string createdByUserId = "") {
		var id = variables.db.newGuid();
		variables.db.run(
			"INSERT INTO [icf].[instrument_version] (version_id, instrument_id, version_label, status, created_by_user_id)
			 VALUES (:id, :instrumentId, :label, N'DRAFT', :createdBy)",
			{ "id": variables.db.guid(id), "instrumentId": variables.db.guid(arguments.instrumentId), "label": variables.db.nvarchar(arguments.versionLabel, 100), "createdBy": variables.db.guid(arguments.createdByUserId) }
		);
		return id;
	}

	public numeric function countWalksForVersion(required string versionId) {
		return variables.db.scalar("SELECT COUNT(*) AS n FROM [icf].[walk] WHERE version_id = :id", { "id": variables.db.guid(arguments.versionId) });
	}

	/**
	 * Replaces a DRAFT's compiled snapshot. This is the one write that can destroy a published
	 * version's identity in a single statement, so it is both guarded and status-qualified, and it
	 * verifies afterwards that the DRAFT it wrote is the DRAFT it was asked to write.
	 */
	public void function storeSnapshot(required string versionId, required string canonicalJson, required string checksum) {
		requireDraftVersion(arguments.versionId);
		variables.db.run(
			"UPDATE [icf].[instrument_version] SET compiled_snapshot_json = :snapshot, checksum_sha256 = :checksum, updated_at = SYSUTCDATETIME()
			  WHERE version_id = :id AND status = N'DRAFT'",
			{ "id": variables.db.guid(arguments.versionId), "snapshot": variables.db.ntext(arguments.canonicalJson), "checksum": { "value": arguments.checksum, "cfsqltype": "cf_sql_char" } }
		);
		var stored = variables.db.scalar(
			"SELECT COUNT(*) AS n FROM [icf].[instrument_version] WHERE version_id = :id AND status = N'DRAFT' AND checksum_sha256 = :checksum",
			{ "id": variables.db.guid(arguments.versionId), "checksum": { "value": arguments.checksum, "cfsqltype": "cf_sql_char" } }
		);
		if (stored != 1) {
			throw(type = "ICFWalk.Import.Validation", message = "The compiled snapshot was not stored; the transaction was rolled back.", errorcode = "INSTRUMENT_SNAPSHOT_NOT_STORED");
		}
	}

	// ---- existing children (keyed by unique keys) ---------------------------------------------

	public struct function loadVersionChildren(required string versionId) {
		var p = { "id": variables.db.guid(arguments.versionId) };
		var out = { "sections": {}, "responseSets": {}, "options": {}, "rules": {}, "items": {}, "placements": {} };
		var q = variables.db.run("SELECT section_id, section_key, parent_section_id FROM [icf].[section_definition] WHERE version_id = :id", p);
		for (var r = 1; r <= q.recordCount; r++) out.sections[q.section_key[r]] = { "id": uCase(q.section_id[r]) };
		q = variables.db.run("SELECT response_set_id, response_set_key FROM [icf].[response_set] WHERE version_id = :id", p);
		for (var r = 1; r <= q.recordCount; r++) out.responseSets[q.response_set_key[r]] = { "id": uCase(q.response_set_id[r]) };
		q = variables.db.run(
			"SELECT o.option_id, o.option_key, s.response_set_key FROM [icf].[response_option] o JOIN [icf].[response_set] s ON s.response_set_id = o.response_set_id WHERE s.version_id = :id", p);
		for (var r = 1; r <= q.recordCount; r++) out.options[q.response_set_key[r] & "|" & q.option_key[r]] = { "id": uCase(q.option_id[r]) };
		q = variables.db.run("SELECT rule_id, rule_key FROM [icf].[rule_definition] WHERE version_id = :id", p);
		for (var r = 1; r <= q.recordCount; r++) out.rules[q.rule_key[r]] = { "id": uCase(q.rule_id[r]) };
		q = variables.db.run("SELECT item_id, item_key FROM [icf].[item_definition] WHERE version_id = :id", p);
		for (var r = 1; r <= q.recordCount; r++) out.items[q.item_key[r]] = { "id": uCase(q.item_id[r]) };
		q = variables.db.run("SELECT p.dimension_id, d.code FROM [icf].[instrument_dimension] p JOIN [icf].[dimension_definition] d ON d.dimension_id = p.dimension_id WHERE p.version_id = :id", p);
		for (var r = 1; r <= q.recordCount; r++) out.placements[q.code[r]] = { "dimensionId": uCase(q.dimension_id[r]) };
		return out;
	}

	public struct function loadDimensions() {
		var q = variables.db.run("SELECT dimension_id, code FROM [icf].[dimension_definition]");
		var out = {};
		for (var r = 1; r <= q.recordCount; r++) out[q.code[r]] = { "id": uCase(q.dimension_id[r]) };
		return out;
	}

	/** The stable value identities a dimension has, by code. Identity only; no authored semantics. */
	public struct function loadDimensionValues(required string dimensionId) {
		var q = variables.db.run("SELECT value_id, value_code FROM [icf].[dimension_value] WHERE dimension_id = :id", { "id": variables.db.guid(arguments.dimensionId) });
		var out = {};
		for (var r = 1; r <= q.recordCount; r++) out[q.value_code[r]] = { "id": uCase(q.value_id[r]) };
		return out;
	}

	/**
	 * Moves every display order of the version's children out of the final range so that
	 * reordered imports never collide with the unique sibling-order indexes mid-update.
	 */
	public void function parkVersionOrders(required string versionId) {
		requireDraftVersion(arguments.versionId);
		var p = { "id": variables.db.guid(arguments.versionId), "offset": variables.db.integer(variables.PARK_OFFSET) };
		variables.db.run(
			"UPDATE s SET s.display_order = s.display_order + :offset
			   FROM [icf].[section_definition] s JOIN [icf].[instrument_version] v ON v.version_id = s.version_id
			  WHERE s.version_id = :id AND s.display_order < :offset AND v.status = N'DRAFT'", p);
		variables.db.run(
			"UPDATE o SET o.display_order = o.display_order + :offset
			   FROM [icf].[response_option] o
			   JOIN [icf].[response_set] s ON s.response_set_id = o.response_set_id
			   JOIN [icf].[instrument_version] v ON v.version_id = s.version_id
			  WHERE s.version_id = :id AND o.display_order < :offset AND v.status = N'DRAFT'", p);
		variables.db.run(
			"UPDATE i SET i.display_order = i.display_order + :offset
			   FROM [icf].[item_definition] i JOIN [icf].[instrument_version] v ON v.version_id = i.version_id
			  WHERE i.version_id = :id AND i.display_order < :offset AND v.status = N'DRAFT'", p);
		variables.db.run(
			"UPDATE p SET p.display_order = p.display_order + :offset
			   FROM [icf].[instrument_dimension] p JOIN [icf].[instrument_version] v ON v.version_id = p.version_id
			  WHERE p.version_id = :id AND p.display_order < :offset AND v.status = N'DRAFT'", p);
	}

	public numeric function parkOffset() { return variables.PARK_OFFSET; }

	// ---- sections ---------------------------------------------------------------------------

	public string function insertSection(required string versionId, required struct row, required numeric parkedOrder) {
		requireDraftVersion(arguments.versionId);
		var id = variables.db.newGuid();
		variables.db.run(
			"INSERT INTO [icf].[section_definition] (section_id, version_id, parent_section_id, section_key, display_order, title, instructions, notes_enabled, settings_json, active)
			 SELECT :id, :versionId, NULL, :key, :order, :title, :instructions, :notes, :settings, :active
			   FROM [icf].[instrument_version] v WHERE v.version_id = :versionId AND v.status = N'DRAFT'",
			{
				"id": variables.db.guid(id), "versionId": variables.db.guid(arguments.versionId),
				"key": variables.db.nvarchar(arguments.row.sectionKey, 100), "order": variables.db.integer(arguments.parkedOrder),
				"title": variables.db.nvarchar(arguments.row.title, 300), "instructions": variables.db.ntext(nullable(arguments.row, "instructions")),
				"notes": variables.db.bit(arguments.row.notesEnabled), "settings": variables.db.ntext(arguments.row.settingsJson), "active": variables.db.bit(arguments.row.active)
			}
		);
		return id;
	}

	public void function updateSectionContent(required string versionId, required string sectionId, required struct row) {
		requireDraftOwnerOf("section_definition", "section_id", arguments.sectionId, arguments.versionId);
		variables.db.run(
			"UPDATE s SET s.title = :title, s.instructions = :instructions, s.notes_enabled = :notes, s.settings_json = :settings, s.active = :active, s.updated_at = SYSUTCDATETIME()
			   FROM [icf].[section_definition] s JOIN [icf].[instrument_version] v ON v.version_id = s.version_id
			  WHERE s.section_id = :id AND s.version_id = :versionId AND v.status = N'DRAFT'",
			{
				"id": variables.db.guid(arguments.sectionId), "versionId": variables.db.guid(arguments.versionId),
				"title": variables.db.nvarchar(arguments.row.title, 300),
				"instructions": variables.db.ntext(nullable(arguments.row, "instructions")), "notes": variables.db.bit(arguments.row.notesEnabled),
				"settings": variables.db.ntext(arguments.row.settingsJson), "active": variables.db.bit(arguments.row.active)
			}
		);
	}

	public void function placeSection(required string versionId, required string sectionId, string parentSectionId = "", required numeric displayOrder) {
		requireDraftOwnerOf("section_definition", "section_id", arguments.sectionId, arguments.versionId);
		variables.db.run(
			"UPDATE s SET s.parent_section_id = :parent, s.display_order = :order, s.updated_at = SYSUTCDATETIME()
			   FROM [icf].[section_definition] s JOIN [icf].[instrument_version] v ON v.version_id = s.version_id
			  WHERE s.section_id = :id AND s.version_id = :versionId AND v.status = N'DRAFT'",
			{ "id": variables.db.guid(arguments.sectionId), "versionId": variables.db.guid(arguments.versionId), "parent": variables.db.guid(arguments.parentSectionId), "order": variables.db.integer(arguments.displayOrder) }
		);
	}

	/**
	 * Deletes the given sections, children before parents. Returns the number deleted.
	 */
	public numeric function deleteSections(required string versionId, required array sectionIds) {
		if (!arrayLen(arguments.sectionIds)) return 0;
		requireDraftVersion(arguments.versionId);
		var remaining = duplicate(arguments.sectionIds);
		var deleted = 0;
		var progress = true;
		while (arrayLen(remaining) && progress) {
			progress = false;
			var next = [];
			for (var id in remaining) {
				var children = variables.db.scalar("SELECT COUNT(*) AS n FROM [icf].[section_definition] WHERE parent_section_id = :id", { "id": variables.db.guid(id) });
				if (children > 0) { arrayAppend(next, id); continue; }
				variables.db.run(
					"DELETE s FROM [icf].[section_definition] s JOIN [icf].[instrument_version] v ON v.version_id = s.version_id
					  WHERE s.section_id = :id AND s.version_id = :versionId AND v.status = N'DRAFT'",
					{ "id": variables.db.guid(id), "versionId": variables.db.guid(arguments.versionId) }
				);
				deleted++;
				progress = true;
			}
			remaining = next;
		}
		if (arrayLen(remaining)) {
			throw(type = "ICFWalk.Import.Validation", message = "Stale sections could not be removed because other sections still depend on them.", errorcode = "STALE_SECTION_IN_USE");
		}
		return deleted;
	}

	// ---- response sets and options ---------------------------------------------------------

	public string function upsertResponseSet(required string versionId, string existingId = "", required struct row) {
		if (len(arguments.existingId)) {
			requireDraftOwnerOf("response_set", "response_set_id", arguments.existingId, arguments.versionId);
			variables.db.run(
				"UPDATE s SET s.name = :name, s.selection_mode = :mode, s.settings_json = :settings, s.active = :active, s.updated_at = SYSUTCDATETIME()
				   FROM [icf].[response_set] s JOIN [icf].[instrument_version] v ON v.version_id = s.version_id
				  WHERE s.response_set_id = :id AND s.version_id = :versionId AND v.status = N'DRAFT'",
				{ "id": variables.db.guid(arguments.existingId), "versionId": variables.db.guid(arguments.versionId), "name": variables.db.nvarchar(arguments.row.name, 200), "mode": variables.db.nvarchar(arguments.row.selectionMode, 20), "settings": variables.db.ntext(arguments.row.settingsJson), "active": variables.db.bit(arguments.row.active) }
			);
			return arguments.existingId;
		}
		requireDraftVersion(arguments.versionId);
		var id = variables.db.newGuid();
		variables.db.run(
			"INSERT INTO [icf].[response_set] (response_set_id, version_id, response_set_key, name, selection_mode, settings_json, active)
			 SELECT :id, :versionId, :key, :name, :mode, :settings, :active
			   FROM [icf].[instrument_version] v WHERE v.version_id = :versionId AND v.status = N'DRAFT'",
			{ "id": variables.db.guid(id), "versionId": variables.db.guid(arguments.versionId), "key": variables.db.nvarchar(arguments.row.setKey, 100), "name": variables.db.nvarchar(arguments.row.name, 200), "mode": variables.db.nvarchar(arguments.row.selectionMode, 20), "settings": variables.db.ntext(arguments.row.settingsJson), "active": variables.db.bit(arguments.row.active) }
		);
		return id;
	}

	public void function deleteResponseSet(required string versionId, required string responseSetId) {
		requireDraftOwnerOf("response_set", "response_set_id", arguments.responseSetId, arguments.versionId);
		variables.db.run(
			"DELETE s FROM [icf].[response_set] s JOIN [icf].[instrument_version] v ON v.version_id = s.version_id
			  WHERE s.response_set_id = :id AND s.version_id = :versionId AND v.status = N'DRAFT'",
			{ "id": variables.db.guid(arguments.responseSetId), "versionId": variables.db.guid(arguments.versionId) }
		);
	}

	public string function upsertOption(required string versionId, required string responseSetId, string existingId = "", required struct row) {
		var params = {
			"versionId": variables.db.guid(arguments.versionId),
			"setId": variables.db.guid(arguments.responseSetId), "key": variables.db.nvarchar(arguments.row.optionKey, 100),
			"code": variables.db.nvarchar(arguments.row.storedCode, 100), "label": variables.db.nvarchar(arguments.row.label, 500),
			"definition": variables.db.ntext(nullable(arguments.row, "definition")), "score": variables.db.decimal(nullable(arguments.row, "numericScore")),
			"isNa": variables.db.bit(arguments.row.isNa), "order": variables.db.integer(arguments.row.displayOrder), "active": variables.db.bit(arguments.row.active)
		};
		if (len(arguments.existingId)) {
			requireDraftOwnerOf("response_option", "option_id", arguments.existingId, arguments.versionId);
			params["id"] = variables.db.guid(arguments.existingId);
			variables.db.run(
				"UPDATE o SET o.stored_code = :code, o.label = :label, o.definition = :definition, o.numeric_score = :score, o.is_na = :isNa, o.display_order = :order, o.active = :active, o.updated_at = SYSUTCDATETIME()
				   FROM [icf].[response_option] o
				   JOIN [icf].[response_set] s ON s.response_set_id = o.response_set_id
				   JOIN [icf].[instrument_version] v ON v.version_id = s.version_id
				  WHERE o.option_id = :id AND s.version_id = :versionId AND v.status = N'DRAFT'",
				params
			);
			return arguments.existingId;
		}
		requireDraftOwnerOf("response_set", "response_set_id", arguments.responseSetId, arguments.versionId);
		var id = variables.db.newGuid();
		params["id"] = variables.db.guid(id);
		variables.db.run(
			"INSERT INTO [icf].[response_option] (option_id, response_set_id, option_key, stored_code, label, definition, numeric_score, is_na, display_order, active)
			 SELECT :id, :setId, :key, :code, :label, :definition, :score, :isNa, :order, :active
			   FROM [icf].[response_set] s JOIN [icf].[instrument_version] v ON v.version_id = s.version_id
			  WHERE s.response_set_id = :setId AND s.version_id = :versionId AND v.status = N'DRAFT'",
			params
		);
		return id;
	}

	public void function deleteOption(required string versionId, required string optionId) {
		requireDraftOwnerOf("response_option", "option_id", arguments.optionId, arguments.versionId);
		variables.db.run(
			"DELETE o FROM [icf].[response_option] o
			   JOIN [icf].[response_set] s ON s.response_set_id = o.response_set_id
			   JOIN [icf].[instrument_version] v ON v.version_id = s.version_id
			  WHERE o.option_id = :id AND s.version_id = :versionId AND v.status = N'DRAFT'",
			{ "id": variables.db.guid(arguments.optionId), "versionId": variables.db.guid(arguments.versionId) }
		);
	}

	// ---- dimensions: stable identity (global) ------------------------------------------------

	/**
	 * Creates the stable identity row for a dimension code that has never been seen. The label and
	 * flags recorded here are the first version's, kept only so the NOT NULL columns have a value;
	 * nothing reads them after this and nothing ever updates them. What a version means by the
	 * dimension lives on its own icf.instrument_dimension row.
	 *
	 * ATOMICALLY DRAFT-QUALIFIED, AND THAT IS THE WHOLE POINT.
	 *
	 * The row written here is GLOBAL: icf.walk_dimension_value points at a dimension value forever
	 * and reporting groups across versions by these codes. There is no version column to guard, so
	 * the only thing that can authorize minting one is the DRAFT it is minted on behalf of.
	 *
	 * This used to call requireDraftVersion() and then issue an unconditional INSERT. Inside the
	 * import's transaction that is sound, because the transaction holds the version's UPDLOCK from
	 * the check through the insert. But this is a PUBLIC repository method and it is called
	 * directly, outside any transaction. There the UPDLOCK lives only for the length of the SELECT,
	 * so a publish could take the row and freeze the version in the gap, and the INSERT then ran
	 * anyway -- permanent global identity minted on the authority of a version that was no longer a
	 * DRAFT. A lock released before the write it protects is not a write boundary.
	 *
	 * So the authority decision lives INSIDE the minting statement. The source of the INSERT is the
	 * owning instrument_version row, read under UPDLOCK/ROWLOCK and predicated on
	 * `status = N'DRAFT'`; one statement is atomic, so there is no gap for any caller to lose,
	 * whether or not they own a transaction, and the same lock is taken in the same order as every
	 * other write in this file. Inside an import's transaction it simply joins the lock the
	 * transaction already holds.
	 *
	 * OUTPUT INSERTED returns the row the database reports inserting. When the predicate matches
	 * nothing, nothing is inserted and nothing comes back, and the caller gets a typed non-DRAFT
	 * refusal instead of a GUID for a row that does not exist. (OUTPUT without INTO is SQL Server
	 * 2005+; the table has no triggers and is not the referencing side of a cascading foreign key,
	 * so the restrictions on it do not apply.)
	 */
	public string function createDimensionIdentity(required string versionId, required struct row) {
		var id = variables.db.newGuid();
		var inserted = variables.db.run(
			"INSERT INTO [icf].[dimension_definition] (dimension_id, code, label, data_type, reportable, sensitive, settings_json, active)
			 OUTPUT INSERTED.[dimension_id] AS created_id
			 SELECT :id, :code, :label, :dataType, :reportable, :sensitive, :settings, :active
			   FROM [icf].[instrument_version] v WITH (UPDLOCK, ROWLOCK)
			  WHERE v.version_id = :versionId AND v.status = N'DRAFT'",
			{
				"id": variables.db.guid(id), "versionId": variables.db.guid(arguments.versionId),
				"code": variables.db.nvarchar(arguments.row.code, 100), "label": variables.db.nvarchar(arguments.row.label, 200),
				"dataType": variables.db.nvarchar(arguments.row.dataType, 20), "reportable": variables.db.bit(arguments.row.reportable),
				"sensitive": variables.db.bit(arguments.row.sensitive), "settings": variables.db.ntext(arguments.row.settingsJson), "active": variables.db.bit(arguments.row.active)
			}
		);
		if (!inserted.recordCount) refuseIdentityMint(arguments.versionId);
		return uCase(inserted.created_id[1]);
	}

	/**
	 * Creates the stable identity row for a (dimension, value code) pair that has never been seen.
	 * icf.walk_dimension_value.selected_value_id points at this row forever, so the code it carries
	 * is never rewritten. display_order here only satisfies UX_dimension_value_order; the order a
	 * version presents the value in lives in icf.instrument_dimension_value.
	 *
	 * Same boundary, same single statement, for the same reason as createDimensionIdentity above:
	 * the owning version is read under UPDLOCK/ROWLOCK and `status = N'DRAFT'` inside the INSERT
	 * that mints the row, and the identity returned is the one the database reports inserting. The
	 * next display order is a correlated subquery rather than the statement's source, so the source
	 * stays the one version row and exactly zero or one value is ever minted.
	 */
	public string function createDimensionValueIdentity(required string versionId, required string dimensionId, required struct row) {
		var id = variables.db.newGuid();
		var inserted = variables.db.run(
			"INSERT INTO [icf].[dimension_value] (value_id, dimension_id, value_code, label, display_order, active)
			 OUTPUT INSERTED.[value_id] AS created_id
			 SELECT :id, :dimensionId, :code, :label,
			        ISNULL((SELECT MAX(x.display_order) FROM [icf].[dimension_value] x WHERE x.dimension_id = :dimensionId), 0) + 1,
			        :active
			   FROM [icf].[instrument_version] v WITH (UPDLOCK, ROWLOCK)
			  WHERE v.version_id = :versionId AND v.status = N'DRAFT'",
			{
				"id": variables.db.guid(id), "versionId": variables.db.guid(arguments.versionId),
				"dimensionId": variables.db.guid(arguments.dimensionId),
				"code": variables.db.nvarchar(arguments.row.valueCode, 100), "label": variables.db.nvarchar(arguments.row.label, 300),
				"active": variables.db.bit(arguments.row.active)
			}
		);
		if (!inserted.recordCount) refuseIdentityMint(arguments.versionId);
		return uCase(inserted.created_id[1]);
	}

	/**
	 * Nothing was minted, so the statement's own DRAFT predicate matched no row. Reports why, with
	 * the same typed errors every other refusal in this file raises.
	 *
	 * This read is deliberately unlocked: the write has provably not happened, and this is only
	 * deciding which refusal to name. It never returns.
	 */
	private void function refuseIdentityMint(required string versionId) {
		var q = variables.db.run(
			"SELECT version_label, status FROM [icf].[instrument_version] WHERE version_id = :id",
			{ "id": variables.db.guid(arguments.versionId) }
		);
		if (!q.recordCount) {
			variables.errors.notFound("Instrument version not found.", "INSTRUMENT_VERSION_NOT_FOUND");
		}
		variables.errors.publishNotDraft(q.version_label[1], q.status[1]);
		// Unreachable: publishNotDraft always throws. Asserted so a future change to it cannot turn
		// a refusal into a silent success that returns a GUID for a row that was never inserted.
		throw(type = "ICFWalk.Validation", message = "Global identity was not minted and no reason could be established.", errorcode = "INSTRUMENT_IDENTITY_NOT_MINTED");
	}

	// ---- dimensions: what one version authors (version-scoped) -------------------------------

	/**
	 * Writes the placement and the version's own view of the dimension in one row. `row` carries
	 * both the placement fields and the dimension fields (label, dataType, reportable, sensitive,
	 * settingsJson, dimensionActive) this version authors.
	 */
	public void function upsertPlacement(required string versionId, required string dimensionId, required boolean exists, required struct row, string sectionId = "") {
		requireDraftVersion(arguments.versionId);
		var params = {
			"versionId": variables.db.guid(arguments.versionId), "dimensionId": variables.db.guid(arguments.dimensionId), "sectionId": variables.db.guid(arguments.sectionId),
			"order": variables.db.integer(arguments.row.displayOrder), "required": variables.db.bit(arguments.row.required), "ruleKey": variables.db.nvarchar(nullable(arguments.row, "ruleKey"), 100),
			"labelOverride": variables.db.nvarchar(nullable(arguments.row, "labelOverride"), 200), "settings": variables.db.ntext(arguments.row.settingsJson),
			"dimensionLabel": variables.db.nvarchar(arguments.row.dimensionLabel, 200), "dimensionDataType": variables.db.nvarchar(arguments.row.dimensionDataType, 20),
			"dimensionReportable": variables.db.bit(arguments.row.dimensionReportable), "dimensionSensitive": variables.db.bit(arguments.row.dimensionSensitive),
			"dimensionActive": variables.db.bit(arguments.row.dimensionActive), "dimensionSettings": variables.db.ntext(arguments.row.dimensionSettingsJson)
		};
		if (arguments.exists) {
			variables.db.run(
				"UPDATE p SET p.section_id = :sectionId, p.display_order = :order, p.required = :required, p.rule_key = :ruleKey,
				              p.label_override = :labelOverride, p.settings_json = :settings,
				              p.dimension_label = :dimensionLabel, p.dimension_data_type = :dimensionDataType,
				              p.dimension_reportable = :dimensionReportable, p.dimension_sensitive = :dimensionSensitive,
				              p.dimension_active = :dimensionActive, p.dimension_settings_json = :dimensionSettings,
				              p.updated_at = SYSUTCDATETIME()
				   FROM [icf].[instrument_dimension] p JOIN [icf].[instrument_version] v ON v.version_id = p.version_id
				  WHERE p.version_id = :versionId AND p.dimension_id = :dimensionId AND v.status = N'DRAFT'",
				params
			);
			return;
		}
		variables.db.run(
			"INSERT INTO [icf].[instrument_dimension] (version_id, dimension_id, section_id, display_order, required, rule_key, label_override, settings_json,
			                                            dimension_label, dimension_data_type, dimension_reportable, dimension_sensitive, dimension_active, dimension_settings_json)
			 SELECT :versionId, :dimensionId, :sectionId, :order, :required, :ruleKey, :labelOverride, :settings,
			        :dimensionLabel, :dimensionDataType, :dimensionReportable, :dimensionSensitive, :dimensionActive, :dimensionSettings
			   FROM [icf].[instrument_version] v WHERE v.version_id = :versionId AND v.status = N'DRAFT'",
			params
		);
	}

	/**
	 * Replaces the values this version offers for one dimension. Delete-then-insert inside the
	 * transaction, so a reorder never has to dodge UX_instrument_dimension_value_order, and a value
	 * dropped from the document is simply not in this version -- while its identity row, and every
	 * walk that already selected it under an earlier version, are untouched.
	 */
	public void function replaceVersionDimensionValues(required string versionId, required string dimensionId, required array rows) {
		requireDraftVersion(arguments.versionId);
		variables.db.run(
			"DELETE iv FROM [icf].[instrument_dimension_value] iv JOIN [icf].[instrument_version] v ON v.version_id = iv.version_id
			  WHERE iv.version_id = :versionId AND iv.dimension_id = :dimensionId AND v.status = N'DRAFT'",
			{ "versionId": variables.db.guid(arguments.versionId), "dimensionId": variables.db.guid(arguments.dimensionId) }
		);
		for (var row in arguments.rows) {
			variables.db.run(
				"INSERT INTO [icf].[instrument_dimension_value] (version_id, dimension_id, value_id, label, display_order, effective_start, effective_end, active)
				 SELECT :versionId, :dimensionId, :valueId, :label, :order, :start, :end, :active
				   FROM [icf].[instrument_version] v WHERE v.version_id = :versionId AND v.status = N'DRAFT'",
				{
					"versionId": variables.db.guid(arguments.versionId), "dimensionId": variables.db.guid(arguments.dimensionId),
					"valueId": variables.db.guid(row.valueId), "label": variables.db.nvarchar(row.label, 300), "order": variables.db.integer(row.displayOrder),
					"start": variables.db.timestamp(instantOrNull(nullable(row, "effectiveStart"))), "end": variables.db.timestamp(instantOrNull(nullable(row, "effectiveEnd"))),
					"active": variables.db.bit(row.active)
				}
			);
		}
	}

	public void function deletePlacement(required string versionId, required string dimensionId) {
		requireDraftVersion(arguments.versionId);
		var p = { "versionId": variables.db.guid(arguments.versionId), "dimensionId": variables.db.guid(arguments.dimensionId) };
		variables.db.run(
			"DELETE iv FROM [icf].[instrument_dimension_value] iv JOIN [icf].[instrument_version] v ON v.version_id = iv.version_id
			  WHERE iv.version_id = :versionId AND iv.dimension_id = :dimensionId AND v.status = N'DRAFT'", p);
		variables.db.run(
			"DELETE p FROM [icf].[instrument_dimension] p JOIN [icf].[instrument_version] v ON v.version_id = p.version_id
			  WHERE p.version_id = :versionId AND p.dimension_id = :dimensionId AND v.status = N'DRAFT'", p);
	}

	// ---- rules ------------------------------------------------------------------------------

	public string function upsertRule(required string versionId, string existingId = "", required struct row) {
		var params = {
			"versionId": variables.db.guid(arguments.versionId), "key": variables.db.nvarchar(arguments.row.ruleKey, 100), "targetType": variables.db.nvarchar(arguments.row.targetType, 20),
			"targetKey": variables.db.nvarchar(arguments.row.targetKey, 100), "effect": variables.db.nvarchar(arguments.row.effect, 20), "conditions": variables.db.ntext(arguments.row.conditionsJson), "active": variables.db.bit(arguments.row.active)
		};
		if (len(arguments.existingId)) {
			requireDraftOwnerOf("rule_definition", "rule_id", arguments.existingId, arguments.versionId);
			params["id"] = variables.db.guid(arguments.existingId);
			variables.db.run(
				"UPDATE r SET r.target_type = :targetType, r.target_key = :targetKey, r.effect = :effect, r.conditions_json = :conditions, r.active = :active, r.updated_at = SYSUTCDATETIME()
				   FROM [icf].[rule_definition] r JOIN [icf].[instrument_version] v ON v.version_id = r.version_id
				  WHERE r.rule_id = :id AND r.version_id = :versionId AND v.status = N'DRAFT'",
				params
			);
			return arguments.existingId;
		}
		requireDraftVersion(arguments.versionId);
		var id = variables.db.newGuid();
		params["id"] = variables.db.guid(id);
		variables.db.run(
			"INSERT INTO [icf].[rule_definition] (rule_id, version_id, rule_key, target_type, target_key, effect, conditions_json, active)
			 SELECT :id, :versionId, :key, :targetType, :targetKey, :effect, :conditions, :active
			   FROM [icf].[instrument_version] v WHERE v.version_id = :versionId AND v.status = N'DRAFT'",
			params
		);
		return id;
	}

	public void function deleteRule(required string versionId, required string ruleId) {
		requireDraftOwnerOf("rule_definition", "rule_id", arguments.ruleId, arguments.versionId);
		variables.db.run(
			"DELETE r FROM [icf].[rule_definition] r JOIN [icf].[instrument_version] v ON v.version_id = r.version_id
			  WHERE r.rule_id = :id AND r.version_id = :versionId AND v.status = N'DRAFT'",
			{ "id": variables.db.guid(arguments.ruleId), "versionId": variables.db.guid(arguments.versionId) }
		);
	}

	// ---- items ------------------------------------------------------------------------------

	public string function upsertItem(required string versionId, string existingId = "", required struct row, required string sectionId, string responseSetId = "") {
		var params = {
			"versionId": variables.db.guid(arguments.versionId), "sectionId": variables.db.guid(arguments.sectionId), "setId": variables.db.guid(arguments.responseSetId),
			"key": variables.db.nvarchar(arguments.row.itemKey, 100), "reportingKey": variables.db.nvarchar(nullable(arguments.row, "reportingKey"), 100),
			"type": variables.db.nvarchar(arguments.row.itemType, 40), "prompt": variables.db.ntext(arguments.row.prompt), "help": variables.db.ntext(nullable(arguments.row, "helpText")),
			"order": variables.db.integer(arguments.row.displayOrder), "required": variables.db.bit(arguments.row.required), "settings": variables.db.ntext(arguments.row.settingsJson), "active": variables.db.bit(arguments.row.active)
		};
		if (len(arguments.existingId)) {
			requireDraftOwnerOf("item_definition", "item_id", arguments.existingId, arguments.versionId);
			params["id"] = variables.db.guid(arguments.existingId);
			variables.db.run(
				"UPDATE i SET i.section_id = :sectionId, i.response_set_id = :setId, i.reporting_key = :reportingKey, i.item_type = :type, i.prompt = :prompt,
				              i.help_text = :help, i.display_order = :order, i.required = :required, i.settings_json = :settings, i.active = :active, i.updated_at = SYSUTCDATETIME()
				   FROM [icf].[item_definition] i JOIN [icf].[instrument_version] v ON v.version_id = i.version_id
				  WHERE i.item_id = :id AND i.version_id = :versionId AND v.status = N'DRAFT'",
				params
			);
			return arguments.existingId;
		}
		requireDraftVersion(arguments.versionId);
		var id = variables.db.newGuid();
		params["id"] = variables.db.guid(id);
		variables.db.run(
			"INSERT INTO [icf].[item_definition] (item_id, version_id, section_id, response_set_id, item_key, reporting_key, item_type, prompt, help_text, display_order, required, settings_json, active)
			 SELECT :id, :versionId, :sectionId, :setId, :key, :reportingKey, :type, :prompt, :help, :order, :required, :settings, :active
			   FROM [icf].[instrument_version] v WHERE v.version_id = :versionId AND v.status = N'DRAFT'",
			params
		);
		return id;
	}

	public void function deleteItem(required string versionId, required string itemId) {
		requireDraftOwnerOf("item_definition", "item_id", arguments.itemId, arguments.versionId);
		variables.db.run(
			"DELETE i FROM [icf].[item_definition] i JOIN [icf].[instrument_version] v ON v.version_id = i.version_id
			  WHERE i.item_id = :id AND i.version_id = :versionId AND v.status = N'DRAFT'",
			{ "id": variables.db.guid(arguments.itemId), "versionId": variables.db.guid(arguments.versionId) }
		);
	}

	// ---- read back as normalized definitions ------------------------------------------------

	public struct function loadNormalizedDefinitions(required string versionId) {
		var p = { "id": variables.db.guid(arguments.versionId) };
		var m = variables.mapper;
		var normalizer = new icfwalk.instrument.ConfigNormalizer();

		var sq = variables.db.run("SELECT section_id, parent_section_id, section_key, display_order, title, instructions, notes_enabled, settings_json, active FROM [icf].[section_definition] WHERE version_id = :id", p);
		var sectionKeyById = {};
		for (var r = 1; r <= sq.recordCount; r++) sectionKeyById[uCase(sq.section_id[r])] = sq.section_key[r];
		var sections = [];
		for (var r = 1; r <= sq.recordCount; r++) {
			var parentKey = len(sq.parent_section_id[r]) && structKeyExists(sectionKeyById, uCase(sq.parent_section_id[r])) ? sectionKeyById[uCase(sq.parent_section_id[r])] : "";
			arrayAppend(sections, m.sectionFromRow(rowStruct(sq, r), parentKey));
		}
		normalizer.sortBy(sections, ["sectionKey"]);

		var rq = variables.db.run("SELECT response_set_id, response_set_key, name, selection_mode, settings_json, active FROM [icf].[response_set] WHERE version_id = :id", p);
		var setKeyById = {};
		var setSettingsById = {};
		var responseSets = [];
		for (var r = 1; r <= rq.recordCount; r++) {
			setKeyById[uCase(rq.response_set_id[r])] = rq.response_set_key[r];
			setSettingsById[uCase(rq.response_set_id[r])] = m.settingsOf(rq.settings_json[r]);
			arrayAppend(responseSets, m.responseSetFromRow(rowStruct(rq, r)));
		}
		normalizer.sortBy(responseSets, ["setKey"]);

		var oq = variables.db.run(
			"SELECT o.option_id, o.response_set_id, o.option_key, o.stored_code, o.label, o.definition, o.numeric_score, o.is_na, o.display_order, o.active
			 FROM [icf].[response_option] o JOIN [icf].[response_set] s ON s.response_set_id = o.response_set_id WHERE s.version_id = :id", p);
		var responseOptions = [];
		for (var r = 1; r <= oq.recordCount; r++) {
			var sid = uCase(oq.response_set_id[r]);
			arrayAppend(responseOptions, m.optionFromRow(rowStruct(oq, r), setKeyById[sid], setSettingsById[sid]));
		}
		normalizer.sortBy(responseOptions, ["setKey", "optionKey"]);

		var ruq = variables.db.run("SELECT rule_id, rule_key, target_type, target_key, effect, conditions_json, active FROM [icf].[rule_definition] WHERE version_id = :id", p);
		var rules = [];
		for (var r = 1; r <= ruq.recordCount; r++) arrayAppend(rules, m.ruleFromRow(rowStruct(ruq, r)));
		normalizer.sortBy(rules, ["ruleKey"]);

		// Dimensions and values as *this version* authored them (migration 006). The global rows
		// supply the stable code only; nothing a later version imports can reach these columns.
		var dq = variables.db.run(
			"SELECT p.dimension_id, d.code, p.dimension_label AS label, p.dimension_data_type AS data_type,
			        p.dimension_reportable AS reportable, p.dimension_sensitive AS sensitive,
			        p.dimension_settings_json AS settings_json, p.dimension_active AS active
			 FROM [icf].[instrument_dimension] p JOIN [icf].[dimension_definition] d ON d.dimension_id = p.dimension_id
			 WHERE p.version_id = :id", p);
		var dimensions = [];
		var dimensionValues = [];
		var dimCodeById = {};
		for (var r = 1; r <= dq.recordCount; r++) {
			var did = uCase(dq.dimension_id[r]);
			dimCodeById[did] = dq.code[r];
			arrayAppend(dimensions, m.dimensionFromRow(rowStruct(dq, r)));
			var dimSettings = m.settingsOf(dq.settings_json[r]);
			var vq = variables.db.run(
				"SELECT iv.value_id, dv.value_code, iv.label, iv.display_order, iv.effective_start, iv.effective_end, iv.active
				 FROM [icf].[instrument_dimension_value] iv JOIN [icf].[dimension_value] dv ON dv.value_id = iv.value_id
				 WHERE iv.version_id = :id AND iv.dimension_id = :dimensionId",
				{ "id": variables.db.guid(arguments.versionId), "dimensionId": variables.db.guid(did) }
			);
			for (var vr = 1; vr <= vq.recordCount; vr++) arrayAppend(dimensionValues, m.dimensionValueFromRow(rowStruct(vq, vr), dq.code[r], dimSettings));
		}
		normalizer.sortBy(dimensions, ["code"]);
		normalizer.sortBy(dimensionValues, ["dimensionCode", "valueCode"]);

		var pq = variables.db.run("SELECT dimension_id, section_id, display_order, required, rule_key, label_override, settings_json FROM [icf].[instrument_dimension] WHERE version_id = :id", p);
		var placements = [];
		for (var r = 1; r <= pq.recordCount; r++) {
			var sectionKey = len(pq.section_id[r]) && structKeyExists(sectionKeyById, uCase(pq.section_id[r])) ? sectionKeyById[uCase(pq.section_id[r])] : "";
			arrayAppend(placements, m.placementFromRow(rowStruct(pq, r), dimCodeById[uCase(pq.dimension_id[r])], sectionKey));
		}
		normalizer.sortBy(placements, ["dimensionCode"]);

		var iq = variables.db.run("SELECT item_id, section_id, response_set_id, item_key, reporting_key, item_type, prompt, help_text, display_order, required, settings_json, active FROM [icf].[item_definition] WHERE version_id = :id", p);
		var items = [];
		for (var r = 1; r <= iq.recordCount; r++) {
			var sk = structKeyExists(sectionKeyById, uCase(iq.section_id[r])) ? sectionKeyById[uCase(iq.section_id[r])] : "";
			var rk = len(iq.response_set_id[r]) && structKeyExists(setKeyById, uCase(iq.response_set_id[r])) ? setKeyById[uCase(iq.response_set_id[r])] : "";
			arrayAppend(items, m.itemFromRow(rowStruct(iq, r), sk, rk));
		}
		normalizer.sortBy(items, ["itemKey"]);

		return {
			"sections": sections, "items": items, "responseSets": responseSets, "responseOptions": responseOptions,
			"rules": rules, "dimensions": dimensions, "dimensionValues": dimensionValues, "instrumentDimensions": placements
		};
	}

	public struct function countChildren(required string versionId) {
		var p = { "id": variables.db.guid(arguments.versionId) };
		return {
			"sections": variables.db.scalar("SELECT COUNT(*) AS n FROM [icf].[section_definition] WHERE version_id = :id", p),
			"items": variables.db.scalar("SELECT COUNT(*) AS n FROM [icf].[item_definition] WHERE version_id = :id", p),
			"responseSets": variables.db.scalar("SELECT COUNT(*) AS n FROM [icf].[response_set] WHERE version_id = :id", p),
			"responseOptions": variables.db.scalar("SELECT COUNT(*) AS n FROM [icf].[response_option] o JOIN [icf].[response_set] s ON s.response_set_id = o.response_set_id WHERE s.version_id = :id", p),
			"rules": variables.db.scalar("SELECT COUNT(*) AS n FROM [icf].[rule_definition] WHERE version_id = :id", p),
			"instrumentDimensions": variables.db.scalar("SELECT COUNT(*) AS n FROM [icf].[instrument_dimension] WHERE version_id = :id", p),
			"dimensions": variables.db.scalar("SELECT COUNT(*) AS n FROM [icf].[instrument_dimension] WHERE version_id = :id", p),
			"dimensionValues": variables.db.scalar("SELECT COUNT(*) AS n FROM [icf].[instrument_dimension_value] WHERE version_id = :id", p)
		};
	}

	/**
	 * Removes a DRAFT version and every definition it owns. Refused for PUBLISHED and RETIRED like
	 * every other mutator here: the guard throws, and each statement is status-qualified besides,
	 * so there is no production path that deletes frozen content.
	 */
	public void function deleteDraftVersionCascade(required string versionId) {
		requireDraftVersion(arguments.versionId);
		var p = { "id": variables.db.guid(arguments.versionId) };
		variables.db.run("DELETE iv FROM [icf].[instrument_dimension_value] iv JOIN [icf].[instrument_version] v ON v.version_id = iv.version_id WHERE iv.version_id = :id AND v.status = N'DRAFT'", p);
		variables.db.run("DELETE p FROM [icf].[instrument_dimension] p JOIN [icf].[instrument_version] v ON v.version_id = p.version_id WHERE p.version_id = :id AND v.status = N'DRAFT'", p);
		variables.db.run("DELETE i FROM [icf].[item_definition] i JOIN [icf].[instrument_version] v ON v.version_id = i.version_id WHERE i.version_id = :id AND v.status = N'DRAFT'", p);
		variables.db.run("DELETE r FROM [icf].[rule_definition] r JOIN [icf].[instrument_version] v ON v.version_id = r.version_id WHERE r.version_id = :id AND v.status = N'DRAFT'", p);
		variables.db.run("DELETE o FROM [icf].[response_option] o JOIN [icf].[response_set] s ON s.response_set_id = o.response_set_id JOIN [icf].[instrument_version] v ON v.version_id = s.version_id WHERE s.version_id = :id AND v.status = N'DRAFT'", p);
		variables.db.run("DELETE s FROM [icf].[response_set] s JOIN [icf].[instrument_version] v ON v.version_id = s.version_id WHERE s.version_id = :id AND v.status = N'DRAFT'", p);
		var sq = variables.db.run("SELECT section_id FROM [icf].[section_definition] WHERE version_id = :id", p);
		var ids = [];
		for (var r = 1; r <= sq.recordCount; r++) arrayAppend(ids, uCase(sq.section_id[r]));
		deleteSections(arguments.versionId, ids);
		variables.db.run("DELETE FROM [icf].[instrument_version] WHERE version_id = :id AND status = N'DRAFT'", p);
	}

	// ---- helpers ----------------------------------------------------------------------------

	private struct function rowStruct(required query q, required numeric r) {
		var s = {};
		for (var col in listToArray(arguments.q.columnList)) {
			s[lCase(col)] = arguments.q[col][arguments.r];
		}
		return s;
	}

	private any function nullable(required struct row, required string key) {
		if (structKeyExists(arguments.row, arguments.key) && !isNull(arguments.row[arguments.key])) return arguments.row[arguments.key];
		return javaCast("null", "");
	}

	private any function instantOrNull(any value) {
		if (isNull(arguments.value) || !isSimpleValue(arguments.value) || !len(trim(arguments.value))) return javaCast("null", "");
		return variables.json.parseInstant(arguments.value);
	}
}
