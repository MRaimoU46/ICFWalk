/**
 * Publishing an instrument version (Phase 6, ADM-04/05, with the ADM-03 refusal path).
 *
 * WHAT PUBLISHING IS. A DRAFT is editable and may be re-imported freely. Publishing freezes it:
 * the definitions stop being writable, the canonical snapshot and its SHA-256 become the version's
 * permanent identity, and walks pin themselves to it. Nothing downstream re-derives the instrument
 * from the definition tables, so the snapshot frozen here is what every future walk, render and
 * summary will describe.
 *
 * WHAT PUBLISHING PROVES. Self-consistency is not validity. An earlier version of this service
 * proved only that the stored snapshot hashed to its stored checksum and that its definitions
 * matched the definitions SQL Server held -- which a DRAFT carrying the same invalid content in
 * both places satisfies perfectly, and then publishes. So, under the version row's own lock:
 *
 *   1. The version still has a compiled snapshot, it parses, and its SHA-256 is the checksum stored
 *      beside it. A DRAFT whose snapshot and checksum disagree is refused rather than frozen in
 *      that state forever.
 *   2. The snapshot envelope is the one the compiler writes and the runtime reads: declared format,
 *      a definitions object, an instrument and a version, and a counts block that agrees with the
 *      definitions beside it. Its instrument code and version label must be the identity of the row
 *      it is stored on -- a snapshot that names another version is not this version's snapshot,
 *      however well it hashes.
 *   3. The definitions inside the snapshot are semantically valid: DefinitionValidator, the same
 *      component the import path runs over every document it accepts.
 *   4. The definitions SQL Server holds are semantically valid, by the same component. The two are
 *      validated separately and on purpose: agreeing with each other is exactly what a corrupted
 *      DRAFT does.
 *   5. Those two sets still equal each other, compared by the canonical definitions checksum the
 *      import used. This is the drift check: freezing a snapshot that no longer describes its own
 *      definitions is the one unrecoverable mistake here.
 *
 * WHAT PUBLISHING DOES NOT DO. It does not recompile. The compiled snapshot carries metadata that
 * exists only in the imported document -- schemaVersion, source, behavior, contentReview -- and is
 * not reconstructible from the definition tables, so re-deriving it here from a partial source
 * would be a guess dressed as a check. On success the stored bytes and checksum are exactly what
 * the import compiled.
 *
 * THE INVARIANT. A version is DRAFT, or it is PUBLISHED with a named publisher and a snapshot and
 * checksum that provably match the valid definitions it was compiled from. There is no third state,
 * and no window in which a version is PUBLISHED but incompletely so:
 *
 *   - The version row is taken under UPDLOCK/ROWLOCK first, so a concurrent publish or import of
 *     the same version queues behind this one rather than interleaving with it. Same lock, same
 *     order, as every definition write (DefinitionRepository.requireDraftVersion).
 *   - Only a DRAFT may be published; PUBLISHED and RETIRED are refused (ADM-05) on a status read
 *     under that lock, never on an earlier unlocked read.
 *   - The publisher is required, is a real app_user, and comes from the authenticated principal.
 *     There is no default and no path that publishes with nobody named.
 *   - Status, publisher, publication time, effective start, snapshot and checksum are written by
 *     one statement (DefinitionRepository.markPublished); the database's own
 *     CK_instrument_version_publish_values and CK_instrument_version_publisher_required reject any
 *     non-DRAFT row missing one of them, so a half-published row cannot be stored even by a future
 *     caller that tried.
 *   - Every refusal below happens inside the transaction, so none of them leaves partial state.
 *     Their audit records are written after the rollback, because a record written inside the
 *     transaction would be rolled back with it and the refusal would leave no trace at all.
 */
component output="false" {

	public InstrumentPublishService function init(
		required struct config, required any db, required any errors, required any logger,
		required any definitionRepository, required any auditRepository, required any canonicalJson,
		required any snapshotCompiler, required any definitionValidator
	) {
		variables.config = arguments.config;
		variables.db = arguments.db;
		variables.errors = arguments.errors;
		variables.logger = arguments.logger;
		variables.repo = arguments.definitionRepository;
		variables.audit = arguments.auditRepository;
		variables.json = arguments.canonicalJson;
		variables.compiler = arguments.snapshotCompiler;
		variables.definitionValidator = arguments.definitionValidator;
		return this;
	}

	/**
	 * Publishes one DRAFT version on behalf of one authenticated user. Returns the published
	 * version's identity and counts. Throws rather than returning a failure: every refusal leaves
	 * the database untouched.
	 *
	 * actorUserId is the publisher and is required. Callers pass the authenticated principal's user
	 * id; nothing from a request body ever reaches it.
	 */
	public struct function publish(required string versionId, required string actorUserId) {
		if (!variables.db.isGuid(arguments.versionId)) {
			variables.errors.validation("versionId must be a GUID.", "INVALID_VERSION_ID");
		}
		if (!len(trim(arguments.actorUserId))) {
			variables.errors.validation("A publisher is required to publish an instrument version.", "PUBLISHER_REQUIRED");
		}
		if (!variables.db.isGuid(arguments.actorUserId)) {
			variables.errors.validation("The publisher must be a valid user id.", "PUBLISHER_INVALID");
		}
		var started = getTickCount();
		var actor = uCase(trim(arguments.actorUserId));
		var wanted = arguments.versionId;
		var self = this;
		var validator = variables.definitionValidator;
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

				// The publisher must be a user this deployment knows. Checked under the lock, before
				// anything is written, so an unknown actor never reaches the publish statement.
				if (!variables.repo.userExists(actor)) {
					self.markRefusal(refusal, version, "PUBLISHER_UNKNOWN", { "attemptedPublisherUserId": actor });
					variables.errors.validation("The publishing user does not exist.", "PUBLISHER_UNKNOWN");
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

				// 2. The envelope the compiler writes and the runtime reads, including the identity
				//    it claims against the identity of the row it is stored on.
				var snapshot = deserializeJSON(snapshotJson);
				var envelope = validator.validateEnvelope(snapshot, {
					"path": "$", "versionLabel": version.versionLabel, "instrumentCode": version.instrumentCode
				});
				if (!envelope.valid) {
					self.markRefusal(refusal, version, "SNAPSHOT_ENVELOPE_INVALID", { "errorCount": arrayLen(envelope.errors), "firstCode": envelope.errors[1].code });
					variables.errors.publishValidation(
						"Instrument version '" & version.versionLabel & "' has a stored snapshot that is not a valid instrument snapshot: " & envelope.errors[1].message,
						envelope.errors
					);
				}

				// 3. The definitions carried in the snapshot are semantically valid.
				var snapshotIssues = validator.validate(snapshot.definitions, { "path": "$.definitions" });
				if (!snapshotIssues.valid) {
					self.markRefusal(refusal, version, "SNAPSHOT_DEFINITIONS_INVALID", { "errorCount": arrayLen(snapshotIssues.errors), "firstCode": snapshotIssues.errors[1].code });
					variables.errors.publishValidation(
						"Instrument version '" & version.versionLabel & "' has a stored snapshot whose definitions failed validation with " & arrayLen(snapshotIssues.errors) & " error(s). First: " & snapshotIssues.errors[1].message,
						snapshotIssues.errors
					);
				}

				// 4. The definitions SQL Server holds are semantically valid, checked in their own
				//    right. A DRAFT whose rows and snapshot agree on the same invalid content passes
				//    every comparison and fails here, which is the whole point of checking both.
				var persisted = variables.repo.loadNormalizedDefinitions(version.versionId);
				var persistedIssues = validator.validate(persisted, { "path": "$.persistedDefinitions" });
				if (!persistedIssues.valid) {
					self.markRefusal(refusal, version, "PERSISTED_DEFINITIONS_INVALID", { "errorCount": arrayLen(persistedIssues.errors), "firstCode": persistedIssues.errors[1].code });
					variables.errors.publishValidation(
						"Instrument version '" & version.versionLabel & "' has stored definitions that failed validation with " & arrayLen(persistedIssues.errors) & " error(s). First: " & persistedIssues.errors[1].message,
						persistedIssues.errors
					);
				}

				// 5. ...and the two still describe each other.
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

				// The publisher recorded on the row is the actor this call was made for, and is the
				// actor the success audit below names. Read back rather than assumed, so the audit
				// trail and the row can never disagree about who published.
				var frozen = variables.repo.findVersionById(version.versionId);
				if (frozen.publishedByUserId != actor) {
					throw(
						type = "ICFWalk.Publish.Validation",
						message = "Instrument version '" & version.versionLabel & "' was published by a different user; the transaction was rolled back.",
						errorcode = "INSTRUMENT_VERSION_PUBLISHER_MISMATCH"
					);
				}

				var counts = variables.compiler.countDefinitions(persisted);
				variables.audit.record("INSTRUMENT_VERSION", version.versionId, "INSTRUMENT_VERSION_PUBLISHED", actor, {
					"versionLabel": version.versionLabel,
					"checksum": storedChecksum,
					"definitionsChecksum": persistedChecksum,
					"publishedByUserId": frozen.publishedByUserId,
					"counts": counts,
					"placeholderCount": arrayLen(placeholders)
				});

				return {
					"versionId": version.versionId,
					"versionLabel": version.versionLabel,
					"instrumentId": version.instrumentId,
					"instrumentCode": version.instrumentCode,
					"status": "PUBLISHED",
					"checksum": storedChecksum,
					"definitionsChecksum": persistedChecksum,
					"publishedByUserId": frozen.publishedByUserId,
					"counts": counts,
					"placeholderCount": arrayLen(placeholders)
				};
			});
		} catch (any e) {
			// The transaction is rolled back by now, so this audit is the first write of a new one
			// and survives. Only refusals this service decided on are recorded here; anything else
			// (a deadlock, a constraint, a driver fault) propagates unannotated.
			if (!structIsEmpty(refusal)) {
				// icf.audit_event.actor_user_id is a foreign key to icf.app_user, so an actor who
				// does not exist is recorded as an unattributed event naming the id it claimed in
				// the details -- not dropped, and not allowed to fail the refusal it is recording.
				var auditActor = variables.repo.userExists(actor) ? actor : "";
				variables.audit.record("INSTRUMENT_VERSION", refusal.versionId, "INSTRUMENT_VERSION_PUBLISH_REFUSED", auditActor, refusal.details);
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
	 * ADM-05, stated as a callable guard for code that wants the answer before it starts work.
	 *
	 * This is a convenience, not the mechanism. The DRAFT-only write boundary is enforced inside
	 * DefinitionRepository: every mutator there locks the owning version and refuses a non-DRAFT
	 * before any write, and every statement is status-qualified besides, so a caller that never
	 * calls this still cannot touch a frozen version. Asking first only produces a clearer error
	 * earlier.
	 *
	 * Call inside the transaction that will do the writing: the status is read under the same row
	 * lock the write will take, so the answer cannot go stale between the check and the write.
	 *
	 * One consequence, stated rather than glossed: a refusal raised here happens inside whatever
	 * transaction the caller has open, so a durable record of the attempt must be written after
	 * that transaction rolls back -- the way publish() above and InstrumentImportService do.
	 */
	public void function assertDraftForWrite(required string versionId, string actorUserId = "", string operation = "DEFINITION_WRITE") {
		if (!variables.db.isGuid(arguments.versionId)) {
			variables.errors.validation("versionId must be a GUID.", "INVALID_VERSION_ID");
		}
		var version = variables.repo.lockVersion(arguments.versionId);
		if (structIsEmpty(version)) {
			variables.errors.notFound("Instrument version not found.", "INSTRUMENT_VERSION_NOT_FOUND");
		}
		if (version.status == "DRAFT") return;
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
	 * Details carry lifecycle facts only -- label, status, reason, checksums, counts. Never
	 * definitions, snapshot text, narrative content, secrets or tokens.
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
