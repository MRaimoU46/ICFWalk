/**
 * Publishing an instrument version (Phase 6, ADM-04/05, with the ADM-03 refusal path).
 *
 * WHAT PUBLISHING IS. A DRAFT is editable and may be re-imported freely. Publishing freezes it:
 * the definitions stop being writable, the canonical snapshot and its SHA-256 become the version's
 * permanent identity, and walks pin themselves to it. Nothing downstream re-derives the instrument
 * from the definition tables, so the snapshot frozen here is what every future walk, render and
 * summary will describe.
 *
 * WHAT THIS SERVICE CAN AND CANNOT PROVE. The compiled snapshot carries metadata that exists only
 * in the imported document -- schemaVersion, source, version, behavior, contentReview -- and is not
 * reconstructible from the definition tables. So publishing does not recompile the whole snapshot;
 * the import already did that, under its own round-trip proof, and re-deriving it here from a
 * partial source would be a guess dressed as a check. What publishing can prove, and does:
 *
 *   1. The version still has a compiled snapshot at all, and that snapshot is parseable JSON whose
 *      SHA-256 is the checksum stored beside it. A DRAFT whose snapshot and checksum disagree is
 *      refused rather than frozen in that state forever.
 *   2. The definitions inside that snapshot still equal the definitions SQL Server holds, compared
 *      by the same canonical checksum the import used. This is the drift check that matters: it is
 *      the only thing that can have changed since the import, and freezing a snapshot that no
 *      longer describes its own definitions is the one unrecoverable mistake here.
 *
 * Structural validation of the document (duplicate keys, bad parents, missing sets, option order,
 * malformed rule JSON -- ADM-03) is enforced by InstrumentConfigValidator at import, which is the
 * only writer of these tables. Publishing refuses anything that has drifted since, and audits it.
 *
 * THE INVARIANT. A version is DRAFT, or it is PUBLISHED with a snapshot and checksum that provably
 * match the definitions it was compiled from. There is no third state, and no window in which a
 * version is PUBLISHED but incompletely so:
 *
 *   - The version row is taken under UPDLOCK/ROWLOCK first, so a concurrent publish or import of
 *     the same version queues behind this one rather than interleaving with it. Same lock
 *     discipline every walk mutation path uses (WalkRepository.findWalk(id, true)).
 *   - Only a DRAFT may be published; PUBLISHED and RETIRED are refused (ADM-05) on a status read
 *     under that lock, never on an earlier unlocked read.
 *   - Status, publisher, publication time, effective start, snapshot and checksum are written by
 *     one statement (DefinitionRepository.markPublished), and the database's own
 *     CK_instrument_version_publish_values constraint rejects any non-DRAFT row missing one of
 *     them, so a half-published row cannot be stored even by a future caller that tried.
 *   - Every refusal below happens inside the transaction, so none of them leaves partial state.
 *     Their audit records are written after the rollback, because a record written inside the
 *     transaction would be rolled back with it and the refusal would leave no trace at all.
 */
component output="false" {

	public InstrumentPublishService function init(
		required struct config, required any db, required any errors, required any logger,
		required any definitionRepository, required any auditRepository, required any canonicalJson,
		required any snapshotCompiler
	) {
		variables.config = arguments.config;
		variables.db = arguments.db;
		variables.errors = arguments.errors;
		variables.logger = arguments.logger;
		variables.repo = arguments.definitionRepository;
		variables.audit = arguments.auditRepository;
		variables.json = arguments.canonicalJson;
		variables.compiler = arguments.snapshotCompiler;
		return this;
	}

	/**
	 * Publishes one DRAFT version. Returns the published version's identity and counts.
	 * Throws rather than returning a failure: every refusal leaves the database untouched.
	 */
	public struct function publish(required string versionId, string actorUserId = "") {
		if (!variables.db.isGuid(arguments.versionId)) {
			variables.errors.validation("versionId must be a GUID.", "INVALID_VERSION_ID");
		}
		var started = getTickCount();
		var actor = arguments.actorUserId;
		var wanted = arguments.versionId;
		var self = this;
		// Every refusal below rolls its transaction back, and an audit record written inside that
		// transaction would roll back with it -- leaving the refusal invisible, which is the one
		// thing ADM-05 asks for. So a refusing branch records what happened here and raises; the
		// audit is written after the rollback, in the catch below.
		var refusal = {};

		var outcome = "";
		try {
			outcome = variables.db.transact(function() {
			var version = variables.repo.findVersionByIdForUpdate(wanted);
			if (structIsEmpty(version)) {
				variables.errors.notFound("Instrument version not found.", "INSTRUMENT_VERSION_NOT_FOUND");
			}

			// ADM-05: a version that is not a DRAFT is frozen. Refused under the lock and audited,
			// so an attempt to republish it is visible rather than merely ineffective.
			if (version.status != "DRAFT") {
				self.markRefusal(refusal, version, "NOT_DRAFT", {});
				variables.errors.publishNotDraft(version.versionLabel, version.status);
			}

			var snapshotJson = isNull(version.snapshotJson) ? "" : version.snapshotJson;
			if (!len(trim(snapshotJson))) {
				self.markRefusal(refusal, version, "NO_SNAPSHOT", {});
				variables.errors.publishValidation(
					"Instrument version '" & version.versionLabel & "' has no compiled snapshot. Import the DRAFT before publishing.",
					[{ "code": "NO_SNAPSHOT", "message": "compiled_snapshot_json is empty for this version.", "path": "$" }]
				);
			}
			if (!isJSON(snapshotJson)) {
				self.markRefusal(refusal, version, "SNAPSHOT_NOT_JSON", {});
				variables.errors.publishValidation(
					"Instrument version '" & version.versionLabel & "' has a compiled snapshot that is not valid JSON.",
					[{ "code": "SNAPSHOT_NOT_JSON", "message": "compiled_snapshot_json could not be parsed.", "path": "$" }]
				);
			}

			// 1. The stored checksum must be the checksum of the stored snapshot.
			var storedChecksum = isNull(version.checksum) ? "" : trim(version.checksum);
			var actualChecksum = variables.json.sha256(snapshotJson);
			if (!len(storedChecksum) || storedChecksum != actualChecksum) {
				self.markRefusal(refusal, version, "CHECKSUM_MISMATCH", { "storedChecksum": storedChecksum, "actualChecksum": actualChecksum });
				variables.errors.publishValidation(
					"Instrument version '" & version.versionLabel & "' has a checksum that does not match its stored snapshot. Re-import the DRAFT before publishing.",
					[{ "code": "CHECKSUM_MISMATCH", "message": "checksum_sha256 is not the SHA-256 of compiled_snapshot_json.", "path": "$" }]
				);
			}

			// 2. The snapshot's definitions must still equal the definitions SQL Server holds.
			var snapshot = deserializeJSON(snapshotJson);
			if (!isStruct(snapshot) || !structKeyExists(snapshot, "definitions")) {
				self.markRefusal(refusal, version, "SNAPSHOT_SHAPE", {});
				variables.errors.publishValidation(
					"Instrument version '" & version.versionLabel & "' has a compiled snapshot with no definitions.",
					[{ "code": "SNAPSHOT_SHAPE", "message": "The stored snapshot has no definitions member.", "path": "$.definitions" }]
				);
			}
			var persisted = variables.repo.loadNormalizedDefinitions(version.versionId);
			var persistedChecksum = variables.compiler.definitionsChecksum(persisted);
			var snapshotChecksum = variables.compiler.definitionsChecksum(snapshot.definitions);
			if (persistedChecksum != snapshotChecksum) {
				variables.logger.error("instrument.publish.definitions_drift", {
					"versionId": version.versionId, "snapshot": snapshotChecksum, "persisted": persistedChecksum
				});
				self.markRefusal(refusal, version, "DEFINITIONS_DRIFT", { "snapshotChecksum": snapshotChecksum, "persistedChecksum": persistedChecksum });
				variables.errors.publishValidation(
					"Instrument version '" & version.versionLabel & "' has definitions that no longer match its compiled snapshot. Re-import the DRAFT before publishing.",
					[{ "code": "DEFINITIONS_DRIFT", "message": "The definitions in the stored snapshot and the definitions in the database compile to different checksums.", "path": "$.definitions" }]
				);
			}

			// Open-decision seam (docs/OPEN_DECISIONS.md): unresolved source placeholders warn by
			// default and block publication only where the deployment says they should.
			var placeholders = variables.compiler.placeholders(persisted);
			if (variables.config.placeholderWarningsBlockPublish && arrayLen(placeholders)) {
				self.markRefusal(refusal, version, "PLACEHOLDERS", { "placeholderCount": arrayLen(placeholders) });
				variables.errors.publishValidation(
					"Instrument version '" & version.versionLabel & "' still has " & arrayLen(placeholders) & " unresolved placeholder(s) and this deployment blocks publication until they are resolved.",
					[{ "code": "UNRESOLVED_PLACEHOLDERS", "message": arrayLen(placeholders) & " placeholder prompt(s) are unresolved.", "path": "$.contentReview" }]
				);
			}

			// The snapshot is frozen exactly as the import compiled it: byte for byte, same
			// checksum. Publishing changes the version's status, not its content.
			var published = variables.repo.markPublished(version.versionId, snapshotJson, storedChecksum, actor);
			if (published != 1) {
				// Unreachable while the lock above is held; asserted rather than assumed, because a
				// silent no-op here would leave a DRAFT that every caller believes is published.
				throw(
					type = "ICFWalk.Publish.Validation",
					message = "Instrument version '" & version.versionLabel & "' was not published; the transaction was rolled back.",
					errorcode = "INSTRUMENT_VERSION_PUBLISH_FAILED"
				);
			}

			var counts = variables.compiler.countDefinitions(persisted);
			variables.audit.record("INSTRUMENT_VERSION", version.versionId, "INSTRUMENT_VERSION_PUBLISHED", actor, {
				"versionLabel": version.versionLabel,
				"checksum": storedChecksum,
				"definitionsChecksum": persistedChecksum,
				"counts": counts,
				"placeholderCount": arrayLen(placeholders)
			});

			return {
				"versionId": version.versionId,
				"versionLabel": version.versionLabel,
				"instrumentId": version.instrumentId,
				"status": "PUBLISHED",
				"checksum": storedChecksum,
				"definitionsChecksum": persistedChecksum,
				"counts": counts,
				"placeholderCount": arrayLen(placeholders)
			};
			});
		} catch (any e) {
			// The transaction is rolled back by now, so this audit is the first write of a new one
			// and survives. Only refusals this service decided on are recorded here; anything else
			// (a deadlock, a constraint, a driver fault) propagates unannotated.
			if (!structIsEmpty(refusal)) {
				variables.audit.record("INSTRUMENT_VERSION", refusal.versionId, "INSTRUMENT_VERSION_PUBLISH_REFUSED", actor, refusal.details);
			}
			rethrow;
		}

		outcome["elapsedMs"] = getTickCount() - started;
		variables.logger.info("instrument.publish.completed", {
			"versionId": outcome.versionId, "versionLabel": outcome.versionLabel, "checksum": outcome.checksum
		});
		return outcome;
	}

	/**
	 * ADM-05, stated as a callable guard so it holds for a direct service call and not only for the
	 * routes that happen to check. Any code about to write definitions for a version asks this
	 * first; a version that is not a DRAFT is refused and the attempt is audited.
	 *
	 * Call inside the transaction that will do the writing: the status is read under the same row
	 * lock the write will take, so the answer cannot go stale between the check and the write.
	 *
	 * One consequence, stated rather than glossed: the audit record below is written in whatever
	 * transaction the caller has open, so a caller that rolls back rolls the record back with it.
	 * The refusal itself is never affected -- the write is refused either way -- but a caller that
	 * needs a durable record of the attempt must write it after its rollback, the way publish()
	 * above does.
	 */
	public void function assertDraftForWrite(required string versionId, string actorUserId = "", string operation = "DEFINITION_WRITE") {
		if (!variables.db.isGuid(arguments.versionId)) {
			variables.errors.validation("versionId must be a GUID.", "INVALID_VERSION_ID");
		}
		var version = variables.repo.findVersionByIdForUpdate(arguments.versionId);
		if (structIsEmpty(version)) {
			variables.errors.notFound("Instrument version not found.", "INSTRUMENT_VERSION_NOT_FOUND");
		}
		if (version.status == "DRAFT") return;
		variables.audit.record("INSTRUMENT_VERSION", version.versionId, "INSTRUMENT_VERSION_WRITE_REFUSED", arguments.actorUserId, {
			"versionLabel": version.versionLabel, "status": version.status, "operation": arguments.operation
		});
		variables.logger.warn("instrument.write.refused", {
			"versionId": version.versionId, "status": version.status, "operation": arguments.operation
		});
		variables.errors.publishNotDraft(version.versionLabel, version.status);
	}

	/**
	 * Records what a refusing branch decided, without writing anything yet. `into` is mutated in
	 * place rather than reassigned, because this is called from inside the transaction closure and
	 * an assignment there would not reach the caller's variable.
	 *
	 * Public only because the closure above reaches it through `self`.
	 */
	public void function markRefusal(required struct into, required struct version, required string reason, struct detail = {}) {
		var payload = { "versionLabel": arguments.version.versionLabel, "status": arguments.version.status, "reason": arguments.reason };
		for (var k in arguments.detail) payload[k] = arguments.detail[k];
		arguments.into["versionId"] = arguments.version.versionId;
		arguments.into["reason"] = arguments.reason;
		arguments.into["details"] = payload;
	}
}
