/**
 * Imports config/instrument-config.json (or any document with the same shape) into a DRAFT
 * instrument version following docs/DATA_CONTRACT.md "Logical-ID import rules":
 *
 *   1. Validate the document completely (structure, unique keys, references, enumerations,
 *      orders, JSON documents, retired-content guardrail). Any error refuses the import before
 *      the database is touched.
 *   2. In one transaction: resolve the instrument by code (create if missing); resolve the
 *      version by (instrument, label) with an update lock; refuse PUBLISHED/RETIRED versions and
 *      DRAFTs already referenced by walks; create the DRAFT when absent.
 *   3. Upsert every definition by its unique key, reusing existing GUIDs (idempotent), inserting
 *      sections in two passes so parents resolve, parking display orders so reorders never
 *      collide with unique sibling-order indexes, and deleting version-scoped rows that are no
 *      longer in the document. Dimension and dimension-value *identities* (id and code) are created
 *      once globally and never updated; what this version calls them, where it puts them, and which
 *      values it offers are written to its own icf.instrument_dimension and
 *      icf.instrument_dimension_value rows, so importing this DRAFT cannot change what an already
 *      published version says (migration 006).
 *   4. Read the persisted definitions back, recompile them, and abort (rolling back) unless the
 *      definitions checksum equals the checksum compiled from the input. This is also the backstop
 *      for the repository's status-qualified DML: a write that silently matched no rows leaves the
 *      round trip short, and the whole transaction is refused rather than half-committed.
 *   5. Store the canonical snapshot and its SHA-256 on the version and write an audit event.
 *
 * A refused write leaves a durable trace. Every refusal below happens inside the transaction, so an
 * audit record written there would roll back with it and the attempt would leave no evidence at
 * all. The refusing branch records what it decided, the transaction rolls back, and exactly one
 * INSTRUMENT_VERSION_WRITE_REFUSED event is written afterwards -- the same shape publish() uses.
 *
 * That applies to every refusing branch, which it did not before: the DRAFT-in-use branches of
 * import and of discardDraft threw INSTRUMENT_VERSION_IN_USE without marking the refusal first, so
 * the catch had nothing to persist and an attempt to rewrite a DRAFT that walks already reference
 * left no record at all. Both now mark before they throw.
 */
component output="false" {

	public InstrumentImportService function init(
		required struct config, required any db, required any errors, required any logger,
		required any definitionRepository, required any auditRepository, required any configNormalizer,
		required any configValidator, required any snapshotCompiler, required any requestContext,
		required any renderContractValidator
	) {
		variables.config = arguments.config;
		variables.db = arguments.db;
		variables.errors = arguments.errors;
		variables.logger = arguments.logger;
		variables.repo = arguments.definitionRepository;
		variables.audit = arguments.auditRepository;
		variables.normalizer = arguments.configNormalizer;
		variables.validator = arguments.configValidator;
		variables.compiler = arguments.snapshotCompiler;
		variables.requestContext = arguments.requestContext;
		variables.renderContract = arguments.renderContractValidator;
		variables.mapper = arguments.definitionRepository.mapper();
		return this;
	}

	/**
	 * Resolves a file name relative to the configured instrument configuration directory. Only
	 * plain file names inside that directory are accepted (no path traversal).
	 */
	public string function resolveConfigFile(required string fileName) {
		var name = trim(arguments.fileName);
		if (!reFind("^[A-Za-z0-9._-]+\.json$", name) || find("..", name)) {
			variables.errors.validation("configFile must be a .json file name inside the instrument configuration directory.", "INVALID_CONFIG_FILE");
		}
		var path = variables.config.instrumentConfigDirectory & name;
		if (!fileExists(path)) variables.errors.notFound("Configuration file not found: " & name, "CONFIG_FILE_NOT_FOUND");
		return path;
	}

	/**
	 * Imports a configuration file. `identity` may carry `instrumentCode` and/or `versionLabel` to
	 * import the same document under a different identity; nothing else about the document can be
	 * overridden, and the full validation runs on the result either way.
	 */
	public struct function importFromFile(required string path, string actorUserId = "", struct identity = {}) {
		if (!fileExists(arguments.path)) {
			variables.errors.notFound("Configuration file not found.", "CONFIG_FILE_NOT_FOUND");
		}
		var text = fileRead(arguments.path, "utf-8");
		if (!isJSON(text)) {
			variables.errors.importValidation("Configuration file is not valid JSON.", [{ "code": "INVALID_JSON", "message": "The document could not be parsed as JSON.", "path": "$" }]);
		}
		var document = deserializeJSON(text);
		if (structKeyExists(arguments.identity, "instrumentCode") && isStruct(document) && structKeyExists(document, "instrument") && isStruct(document.instrument)) {
			document.instrument["code"] = arguments.identity.instrumentCode;
		}
		if (structKeyExists(arguments.identity, "versionLabel") && isStruct(document) && structKeyExists(document, "instrument") && isStruct(document.instrument)
			&& structKeyExists(document.instrument, "version") && isStruct(document.instrument.version)) {
			document.instrument.version["versionLabel"] = arguments.identity.versionLabel;
		}
		var result = importConfig(document, arguments.actorUserId);
		result["sourcePath"] = listLast(replace(arguments.path, "\", "/", "all"), "/");
		return result;
	}

	/**
	 * `options` selects how an existing DRAFT under the document's label is treated (P6A-02):
	 *
	 *   (none)            the maintenance import: an existing DRAFT is re-imported. The operator seed
	 *                     path relies on that and keeps it deliberately; it is behind the maintenance
	 *                     guard, and no signed-in administrator can reach it.
	 *   createOnly        the administration import without a replacement: an existing DRAFT is
	 *                     refused 409 DRAFT_REPLACEMENT_REQUIRED and nothing is written.
	 *   replaceVersionId  the administration import naming the DRAFT it replaces, with
	 *   + expectedChecksum   the checksum the administrator agreed to replace; both are compared
	 *                     under the version lock the write holds (writeNormalizedDraft).
	 */
	public struct function importConfig(required any config, string actorUserId = "", struct options = {}) {
		var validation = variables.validator.validate(arguments.config);
		if (!validation.valid) {
			variables.logger.warn("instrument.import.rejected", { "errorCount": arrayLen(validation.errors), "firstCode": validation.errors[1].code });
			variables.errors.importValidation("Instrument configuration failed validation with " & arrayLen(validation.errors) & " error(s). First: " & validation.errors[1].message, validation.errors);
		}
		var normalized = variables.normalizer.fromConfig(arguments.config);
		// The authoring-document validation above already ran the shared semantic rule set over
		// exactly this normalized form (InstrumentConfigValidator.checkDefinitions).
		var opts = { "operation": "IMPORT", "warnings": validation.warnings, "definitionsValidated": true };
		for (var key in ["createOnly", "replaceVersionId", "expectedChecksum"]) {
			if (structKeyExists(arguments.options, key)) opts[key] = arguments.options[key];
		}
		return writeNormalizedDraft(normalized, arguments.actorUserId, opts);
	}

	/**
	 * THE ONE WRITE PATH FOR A DRAFT'S CONTENT (Phase 6).
	 *
	 * An import, a clone of an existing version (ADM-06) and a wording edit to a DRAFT (ADM-06,
	 * ADM-08) all end here, with a normalized instrument document, so none of them can be judged
	 * by a different predicate or written through a weaker transaction than the others:
	 *
	 *   1. the shared semantic rule set (DefinitionValidator), unless the caller already ran it
	 *      over this exact document -- an import has, inside InstrumentConfigValidator;
	 *   2. compilation, and the REAL renderer building the compiled snapshot;
	 *   3. one transaction: the version row under its lock, the lifecycle refusals, the shared
	 *      metadata conflict decided on the locked current instrument row, the definition writes,
	 *      the round-trip checksum proof, the snapshot, and the audit event;
	 *   4. every refusal decided inside that transaction audited durably after the rollback.
	 *
	 * options (all optional):
	 *   operation            IMPORT | CLONE | EDIT; recorded on refusal audits (default IMPORT)
	 *   warnings             inbound-document warnings to return with the result
	 *   definitionsValidated true when step 1 has already run over this document
	 *   mustCreate           CLONE: refuse (409 VERSION_LABEL_EXISTS) if the label is taken
	 *   createOnly           IMPORT without a replacement: an existing DRAFT under the label is
	 *                        refused (409 DRAFT_REPLACEMENT_REQUIRED), decided under the version lock
	 *   replaceVersionId     IMPORT replacing a DRAFT: the label must hold exactly this version, or
	 *                        the import is refused (409 DRAFT_CHANGED); it never creates a version
	 *   targetVersionId      EDIT: the version the caller read; a different or vanished row is refused
	 *   expectedChecksum     EDIT and replacing IMPORT: the snapshot checksum the caller's change was
	 *                        made against; compared under the version lock (409 DRAFT_CHANGED)
	 *   skipWhenUnchanged    EDIT: when the compiled snapshot equals the stored one, write nothing,
	 *                        audit nothing, and report changed = false
	 *   successEvent         the audit event for a successful write (default CREATED / REIMPORTED)
	 *   auditDetails         extra lifecycle facts for that event (identifiers and counts only)
	 */
	public struct function writeNormalizedDraft(required struct normalizedDraft, string actorUserId = "", struct options = {}) {
		var started = getTickCount();
		var opts = {
			"operation": "IMPORT", "warnings": [], "definitionsValidated": false, "mustCreate": false,
			"createOnly": false, "replaceVersionId": "",
			"targetVersionId": "", "expectedChecksum": "", "skipWhenUnchanged": false,
			"successEvent": "", "auditDetails": {}
		};
		structAppend(opts, arguments.options, true);
		var replaceId = uCase(trim(opts.replaceVersionId));
		var normalized = arguments.normalizedDraft;
		var validation = { "warnings": opts.warnings };

		if (!opts.definitionsValidated) {
			var semantic = variables.validator.definitionValidator().validate(normalized.definitions, { "path": "$.definitions" });
			if (!semantic.valid) {
				variables.logger.warn("instrument.draft.rejected", { "operation": opts.operation, "errorCount": arrayLen(semantic.errors), "firstCode": semantic.errors[1].code });
				variables.errors.importValidation("The instrument failed validation with " & arrayLen(semantic.errors) & " error(s). First: " & semantic.errors[1].message, semantic.errors);
			}
		}

		var compiled = variables.compiler.compile(normalized);

		// The renderer really does build what this document compiles to. The shared semantic rules
		// above already cover every way RenderModelBuilder can fail, but they are a description of
		// the renderer maintained by hand, and a description drifts. Running the real builder here
		// means a DRAFT that imports is a DRAFT that publishes: publication runs the same preflight
		// on the same snapshot, and cannot discover something this did not.
		var renderIssues = variables.renderContract.validate(compiled.snapshot, { "path": "$" });
		if (!renderIssues.valid) {
			variables.logger.warn("instrument.import.not_renderable", { "errorCount": arrayLen(renderIssues.errors), "firstCode": renderIssues.errors[1].code });
			variables.errors.importValidation("Instrument configuration compiles to a snapshot the runtime cannot render: " & renderIssues.errors[1].message, renderIssues.errors);
		}

		var actor = arguments.actorUserId;
		var self = this;
		// Filled by a refusing branch inside the transaction; written after the rollback below.
		var refusal = {};

		var outcome = "";
		try {
		outcome = variables.db.transact(function() {
			var instrument = variables.repo.findInstrumentByCode(normalized.instrument.code);
			if (structIsEmpty(instrument) && len(replaceId)) {
				// A replacement names a DRAFT of an instrument that does not exist: there is nothing
				// under this label to replace, and a replacement never creates.
				self.markRefusal(refusal, replaceId, normalized.version.versionLabel, "ABSENT", opts.operation, "REPLACED_VERSION_MISSING", actor);
				variables.errors.conflict(self.replacementChangedMessage(normalized.version.versionLabel), "DRAFT_CHANGED", { "versionId": replaceId, "versionLabel": normalized.version.versionLabel });
			}
			var instrumentId = structIsEmpty(instrument)
				? variables.repo.createInstrument(normalized.instrument.code, normalized.instrument.name, normalized.instrument.description, normalized.instrument.active)
				: instrument.instrumentId;

			// ONE LOCK ORDER: icf.instrument_version first, icf.instrument afterwards. Publishing
			// takes the version row under UPDLOCK and only then reads the instrument row for the
			// snapshot's identity check, so an import that took an exclusive lock on the instrument
			// *before* locking the version would invert the order, and a publish racing an import
			// would deadlock instead of queueing. The instrument update therefore happens after
			// this lock, not before it.
			var existing = variables.repo.findVersion(instrumentId, normalized.version.versionLabel, true);
			var created = false;
			var versionId = "";
			var priorChecksum = "";
			var operation = opts.operation;
			if (structIsEmpty(existing)) {
				if (len(opts.targetVersionId)) {
					// An edit names a DRAFT that no longer exists (it was discarded after it was
					// read). Refuse rather than silently creating a new version under its label.
					variables.errors.notFound("The DRAFT being edited no longer exists.", "INSTRUMENT_VERSION_NOT_FOUND");
				}
				if (len(replaceId)) {
					// The DRAFT the administrator agreed to replace is gone (discarded, or never under
					// this label). Decided under the range lock HOLDLOCK took on the free label, so no
					// DRAFT can appear here before this transaction ends -- and a replacement never
					// creates one.
					self.markRefusal(refusal, replaceId, normalized.version.versionLabel, "ABSENT", operation, "REPLACED_VERSION_MISSING", actor);
					variables.errors.conflict(self.replacementChangedMessage(normalized.version.versionLabel), "DRAFT_CHANGED", { "versionId": replaceId, "versionLabel": normalized.version.versionLabel });
				}
				versionId = variables.repo.createDraftVersion(instrumentId, normalized.version.versionLabel, actor);
				created = true;
			} else {
				if (opts.mustCreate) {
					// A clone creates a NEW version. Taking over an existing label would re-import
					// whatever DRAFT carries it, or be refused as immutable, neither of which is
					// what the caller asked for.
					self.markRefusal(refusal, existing.versionId, normalized.version.versionLabel, existing.status, operation, "VERSION_LABEL_EXISTS", actor);
					variables.errors.conflict(
						"A version labelled '" & normalized.version.versionLabel & "' already exists for this instrument. Choose a new label.",
						"VERSION_LABEL_EXISTS", { "versionLabel": normalized.version.versionLabel, "versionId": existing.versionId }
					);
				}
				if (len(opts.targetVersionId) && compare(existing.versionId, uCase(trim(opts.targetVersionId))) != 0) {
					self.markRefusal(refusal, existing.versionId, normalized.version.versionLabel, existing.status, operation, "VERSION_MISMATCH", actor);
					variables.errors.conflict("The edited document names a different version than the one being edited.", "VERSION_MISMATCH");
				}
				var lockedChecksum = isNull(existing.checksum) ? "" : lCase(trim(existing.checksum));
				if (len(replaceId) && compare(existing.versionId, replaceId) != 0) {
					// The label now holds a different version than the one the administrator agreed
					// to replace (that one was discarded and the label re-made). Refused: replacing
					// this one was never agreed to.
					self.markRefusal(refusal, replaceId, normalized.version.versionLabel, existing.status, operation, "REPLACED_VERSION_MISMATCH", actor);
					variables.errors.conflict(self.replacementChangedMessage(normalized.version.versionLabel), "DRAFT_CHANGED", {
						"versionId": replaceId, "versionLabel": normalized.version.versionLabel,
						"currentVersionId": existing.versionId, "currentChecksum": lockedChecksum
					});
				}
				if (existing.status != "DRAFT") {
					self.markRefusal(refusal, existing.versionId, normalized.version.versionLabel, existing.status, operation, "VERSION_NOT_DRAFT", actor);
					variables.errors.importPublishedVersion(normalized.version.versionLabel, existing.status);
				}
				if (opts.createOnly) {
					// Create-only never takes over an existing DRAFT, however it came to hold the
					// label -- including one created after the caller last looked. Decided here, on
					// the locked row, so there is no window in which the answer can go stale.
					self.markRefusal(refusal, existing.versionId, normalized.version.versionLabel, existing.status, operation, "REPLACEMENT_REQUIRED", actor);
					variables.errors.conflict(
						"A DRAFT labelled '" & normalized.version.versionLabel & "' already exists for this instrument. Replacing it has to be asked for explicitly, naming that DRAFT and the checksum you agreed to replace; or choose a new label.",
						"DRAFT_REPLACEMENT_REQUIRED", { "versionId": existing.versionId, "versionLabel": normalized.version.versionLabel, "currentChecksum": lockedChecksum }
					);
				}
				var walkCount = variables.repo.countWalksForVersion(existing.versionId);
				if (walkCount > 0) {
					// A DRAFT that walks already reference is refused like any other refused write,
					// and leaves the same durable trace. This branch used to throw without marking
					// the refusal, so the catch below had nothing to persist and the attempt
					// vanished with the rollback -- the one defect the post-rollback audit pattern
					// exists to prevent.
					self.markRefusal(refusal, existing.versionId, normalized.version.versionLabel, existing.status, operation, "VERSION_IN_USE", actor);
					variables.errors.importVersionInUse(normalized.version.versionLabel, walkCount);
				}
				var storedChecksum = lockedChecksum;
				if (len(opts.expectedChecksum) && compare(storedChecksum, lCase(trim(opts.expectedChecksum))) != 0) {
					// Optimistic concurrency for DRAFT edits and replacing imports, decided under the
					// version lock: the change was made against (or agreed for) a snapshot that is no
					// longer the DRAFT's content. Applying it would silently discard whatever changed it.
					self.markRefusal(refusal, existing.versionId, normalized.version.versionLabel, existing.status, operation, "DRAFT_CHANGED", actor);
					variables.errors.conflict(
						len(replaceId) ? self.replacementChangedMessage(normalized.version.versionLabel) : "This DRAFT changed after it was read. Reload it and make the edit again.",
						"DRAFT_CHANGED", { "versionId": existing.versionId, "currentChecksum": storedChecksum }
					);
				}
				priorChecksum = storedChecksum;
				if (opts.skipWhenUnchanged && compare(storedChecksum, compiled.checksum) == 0) {
					// Nothing to write: the edited document compiles to exactly the stored snapshot.
					// No row is touched and nothing is audited, so updated_at and row_version do not
					// move for a change that did not happen.
					return self.unchangedResult(existing.versionId, instrumentId, normalized, compiled);
				}
				versionId = existing.versionId;
			}

			// SHARED INSTRUMENT METADATA IS NOT IMPORT-OWNED.
			//
			// This used to be an unconditional updateInstrument() straight from the document. The
			// shared row carries `active`, which is part of SnapshotService.currentVersion()'s
			// selection predicate, so importing a V2 DRAFT that said active = false removed an
			// already PUBLISHED V1 from the runtime -- no version row changed, no audit named the
			// actor, and the frozen version was simply gone.
			//
			// The row is written exactly once, at the instrument's birth above. Afterwards the
			// document's name and description are *version* metadata: they are compiled into this
			// version's snapshot, which is what the runtime shows for this version, so they are
			// stored at the right scope rather than ignored. `active` has no version-scoped effect
			// to be stored at -- it decides which published version the runtime serves at all --
			// so a document that disagrees about it is refused atomically here rather than
			// silently dropped.
			//
			// THE CONFLICT IS DECIDED ON THE LOCKED CURRENT ROW, NOT ON THE EARLIER LOOKUP. The
			// read at the top of this transaction resolves the instrument id; it is an ordinary
			// unlocked read and an authorized metadata change can commit after it. Deciding the
			// conflict from that object meant an administrator's deactivation, committed in the
			// gap, was invisible here: the document said "active" and the stale object agreed, so
			// the import was accepted against a row that no longer said so. The row is therefore
			// re-read under UPDLOCK/HOLDLOCK now -- AFTER the version lock above, preserving the
			// declared version-then-instrument order, so this can never deadlock with a publish --
			// and the locked row is what the decision, and the rest of this transaction, sees.
			if (!structIsEmpty(instrument)) {
				var current = variables.repo.lockInstrumentById(instrumentId);
				if (structIsEmpty(current)) {
					// The instrument existed a moment ago and does not now. Refuse rather than
					// re-create it: an import does not own the shared row's existence either.
					self.markRefusal(refusal, versionId, normalized.version.versionLabel, "DRAFT", operation, "SHARED_METADATA_CONFLICT", actor);
					variables.errors.notFound("No instrument with code '" & normalized.instrument.code & "' exists.", "INSTRUMENT_NOT_FOUND");
				}
				var conflicts = sharedMetadataConflicts(current, normalized.instrument);
				if (arrayLen(conflicts)) {
					self.markRefusal(refusal, versionId, normalized.version.versionLabel, "DRAFT", operation, "SHARED_METADATA_CONFLICT", actor);
					variables.errors.importValidation(
						"The document's instrument metadata differs from the shared icf.instrument row, which an import does not own. Change it through the authorized instrument-level operation, or align the document.",
						conflicts
					);
				}
			}

			var writeWarnings = writeDefinitions(versionId, normalized.definitions, created);

			// Round-trip proof: what SQL Server now holds must compile to the same definitions.
			var persisted = variables.repo.loadNormalizedDefinitions(versionId);
			var persistedChecksum = variables.compiler.definitionsChecksum(persisted);
			if (persistedChecksum != compiled.definitionsChecksum) {
				variables.logger.error("instrument.import.roundtrip_mismatch", { "versionId": versionId, "expected": compiled.definitionsChecksum, "actual": persistedChecksum });
				throw(type = "ICFWalk.Import.Validation", message = "Persisted definitions do not match the imported document; the import was rolled back.", errorcode = "IMPORT_ROUNDTRIP_MISMATCH");
			}

			variables.repo.storeSnapshot(versionId, compiled.canonicalJson, compiled.checksum);

			var warnings = duplicate(validation.warnings);
			for (var w in writeWarnings) arrayAppend(warnings, w);
			var placeholders = variables.compiler.placeholders(normalized.definitions);

			var auditDetails = {
				"versionLabel": normalized.version.versionLabel,
				"instrumentCode": normalized.instrument.code,
				"checksum": compiled.checksum,
				"definitionsChecksum": compiled.definitionsChecksum,
				"counts": compiled.counts,
				"warningCount": arrayLen(warnings),
				"placeholderCount": arrayLen(placeholders)
			};
			if (len(replaceId)) {
				// A replacement is audited against exactly what it replaced: the same version id, and
				// the checksum that id held under the lock -- which equals the one agreed to.
				auditDetails["replacedVersionId"] = versionId;
				auditDetails["previousChecksum"] = priorChecksum;
			}
			structAppend(auditDetails, opts.auditDetails, true);
			var successEvent = len(opts.successEvent) ? opts.successEvent : (created ? "INSTRUMENT_VERSION_CREATED" : "INSTRUMENT_VERSION_REIMPORTED");
			variables.audit.record("INSTRUMENT_VERSION", versionId, successEvent, actor, auditDetails);

			return {
				"instrumentId": instrumentId,
				"versionId": versionId,
				"versionLabel": normalized.version.versionLabel,
				"instrumentCode": normalized.instrument.code,
				"status": "DRAFT",
				"created": created,
				"changed": true,
				"checksum": compiled.checksum,
				"definitionsChecksum": compiled.definitionsChecksum,
				"snapshotFormat": variables.compiler.snapshotFormat(),
				"counts": compiled.counts,
				"warnings": warnings,
				"placeholders": placeholders
			};
		});
		} catch (any e) {
			// The transaction is rolled back by now, so this audit is the first write of a new one
			// and survives. Only refusals this service decided on are recorded; anything else
			// (a deadlock, a constraint, a driver fault) propagates unannotated.
			writeRefusalAudit(refusal);
			rethrow;
		}

		outcome["elapsedMs"] = getTickCount() - started;
		variables.logger.info("instrument.draft.written", { "operation": opts.operation, "versionId": outcome.versionId, "created": outcome.created, "changed": outcome.changed, "checksum": outcome.checksum, "counts": outcome.counts, "warningCount": arrayLen(outcome.warnings), "elapsedMs": outcome.elapsedMs });
		return outcome;
	}

	/** Public only because the transaction closure above reaches it through `self`. */
	public string function replacementChangedMessage(required string versionLabel) {
		return "The DRAFT labelled '" & arguments.versionLabel & "' is not the one you chose to replace, or it changed after you chose to replace it. Nothing was imported; reload the version list and decide again.";
	}

	/**
	 * The result of an edit that changed nothing. Public only because the transaction closure above
	 * reaches it through `self`.
	 */
	public struct function unchangedResult(required string versionId, required string instrumentId, required struct normalized, required struct compiled) {
		return {
			"instrumentId": arguments.instrumentId,
			"versionId": arguments.versionId,
			"versionLabel": arguments.normalized.version.versionLabel,
			"instrumentCode": arguments.normalized.instrument.code,
			"status": "DRAFT",
			"created": false,
			"changed": false,
			"checksum": arguments.compiled.checksum,
			"definitionsChecksum": arguments.compiled.definitionsChecksum,
			"snapshotFormat": variables.compiler.snapshotFormat(),
			"counts": arguments.compiled.counts,
			"warnings": [],
			"placeholders": variables.compiler.placeholders(arguments.normalized.definitions)
		};
	}

	/**
	 * Records a refusal that was decided OUTSIDE a transaction -- a precondition an administration
	 * operation checked before it began any write -- in exactly the shape the post-rollback path
	 * uses, so every refused write of a given kind leaves the same single durable event whether it
	 * was caught before the lock or under it.
	 */
	public void function recordRefusal(
		required string versionId, required string versionLabel, required string status,
		required string operation, required string reason, string actorUserId = ""
	) {
		var refusal = {};
		markRefusal(refusal, arguments.versionId, arguments.versionLabel, arguments.status, arguments.operation, arguments.reason, arguments.actorUserId);
		writeRefusalAudit(refusal);
	}

	/**
	 * Discards exactly the DRAFT `versionId` names (the administration route, P6A-03).
	 *
	 * ONE IDENTITY, ONE TRANSACTION. This used to read the row without a lock, turn it into
	 * (instrument code, label) and hand that to the label-addressed discardDraft below, which then
	 * deleted whatever row owned the label -- so if the named version was discarded and a new DRAFT
	 * created under its label in between, a request naming the first deleted the second. Nothing
	 * here resolves a label now:
	 *
	 *   1. the transaction locks the exact row the path names (UPDLOCK, the lock publish, import and
	 *      retire take on the same row, in the same version-first order);
	 *   2. the instrument, label, status and checksum are read from THAT locked row;
	 *   3. this id must be a DRAFT, and no walk may reference this id;
	 *   4. this id -- and only this id -- is deleted, and exactly one version row must go;
	 *   5. the audit event and the response name this id.
	 *
	 * Refusals keep their codes and leave the same single durable trace as every refused write.
	 * The maintenance route's label-addressed discardDraft is a separate operation and is untouched.
	 */
	public struct function discardDraftById(required string versionId, string actorUserId = "") {
		if (!variables.db.isGuid(arguments.versionId)) variables.errors.validation("versionId must be a GUID.", "INVALID_VERSION_ID");
		var id = uCase(trim(arguments.versionId));
		var actor = arguments.actorUserId;
		var self = this;
		var refusal = {};
		try {
			return variables.db.transact(function() {
				var row = variables.repo.findVersionByIdForUpdate(id);
				if (structIsEmpty(row)) variables.errors.notFound("Instrument version not found.", "INSTRUMENT_VERSION_NOT_FOUND");
				if (row.status != "DRAFT") {
					self.markRefusal(refusal, row.versionId, row.versionLabel, row.status, "DISCARD_DRAFT", "VERSION_NOT_DRAFT", actor);
					variables.errors.importPublishedVersion(row.versionLabel, row.status);
				}
				var walkCount = variables.repo.countWalksForVersion(row.versionId);
				if (walkCount > 0) {
					self.markRefusal(refusal, row.versionId, row.versionLabel, row.status, "DISCARD_DRAFT", "VERSION_IN_USE", actor);
					variables.errors.importVersionInUse(row.versionLabel, walkCount);
				}
				var deleted = variables.repo.deleteDraftVersionCascade(row.versionId);
				if (deleted != 1) {
					// The locked DRAFT did not go. Nothing is committed and nothing is claimed.
					variables.logger.error("instrument.discard.unexpected_delete_count", { "versionId": row.versionId, "deleted": deleted });
					throw(type = "ICFWalk.Conflict", message = "The DRAFT could not be discarded; nothing was changed.", errorcode = "DISCARD_NOT_APPLIED");
				}
				var checksum = isNull(row.checksum) ? "" : lCase(trim(row.checksum));
				variables.audit.record("INSTRUMENT_VERSION", row.versionId, "INSTRUMENT_VERSION_DISCARDED", actor, {
					"versionLabel": row.versionLabel, "instrumentCode": row.instrumentCode, "checksum": checksum
				});
				return { "versionId": row.versionId, "versionLabel": row.versionLabel, "instrumentCode": row.instrumentCode, "discarded": true };
			});
		} catch (any e) {
			writeRefusalAudit(refusal);
			rethrow;
		}
	}

	/**
	 * Deletes a DRAFT version of this instrument that no walk references. Published and retired
	 * versions are never deleted.
	 *
	 * The lookup is scoped by instrument identity as well as by label: version labels are unique
	 * only within an instrument, so a label lookup alone could select -- and delete -- another
	 * instrument's version that happens to carry the same label. An optional instrumentCode names
	 * a different instrument explicitly; it defaults to the configured ICFWalk instrument.
	 */
	public struct function discardDraft(required string versionLabel, string actorUserId = "", string instrumentCode = "") {
		var label = arguments.versionLabel;
		var actor = arguments.actorUserId;
		var code = len(trim(arguments.instrumentCode)) ? trim(arguments.instrumentCode) : variables.config.instrumentCode;
		var self = this;
		var refusal = {};
		try {
			return variables.db.transact(function() {
				var instrument = variables.repo.findInstrumentByCode(code);
				if (structIsEmpty(instrument)) variables.errors.notFound("No instrument with code '" & code & "' exists.", "INSTRUMENT_NOT_FOUND");
				var q = variables.db.run(
					"SELECT v.version_id, v.status FROM [icf].[instrument_version] v WITH (UPDLOCK, HOLDLOCK) WHERE v.instrument_id = :instrumentId AND v.version_label = :label",
					{ "instrumentId": variables.db.guid(instrument.instrumentId), "label": variables.db.nvarchar(label, 100) }
				);
				if (!q.recordCount) variables.errors.notFound("No version of instrument '" & code & "' with that label exists.", "VERSION_NOT_FOUND");
				var versionId = uCase(q.version_id[1]);
				if (q.status[1] != "DRAFT") {
					self.markRefusal(refusal, versionId, label, q.status[1], "DISCARD_DRAFT", "VERSION_NOT_DRAFT", actor);
					variables.errors.importPublishedVersion(label, q.status[1]);
				}
				var walkCount = variables.repo.countWalksForVersion(versionId);
				if (walkCount > 0) {
					// Same as the import branch above: marked before the throw, so the refusal
					// survives the rollback that is about to happen.
					self.markRefusal(refusal, versionId, label, q.status[1], "DISCARD_DRAFT", "VERSION_IN_USE", actor);
					variables.errors.importVersionInUse(label, walkCount);
				}
				variables.repo.deleteDraftVersionCascade(versionId);
				variables.audit.record("INSTRUMENT_VERSION", versionId, "INSTRUMENT_VERSION_DISCARDED", actor, { "versionLabel": label, "instrumentCode": code });
				return { "versionId": versionId, "versionLabel": label, "instrumentCode": code, "discarded": true };
			});
		} catch (any e) {
			writeRefusalAudit(refusal);
			rethrow;
		}
	}

	/**
	 * Records what a refusing branch decided, without writing anything yet. `into` is mutated in
	 * place rather than reassigned, because this is called from inside a transaction closure and an
	 * assignment there would not reach the caller's variable.
	 *
	 * Details carry lifecycle facts only -- version, label, prior status, operation, reason code,
	 * actor -- and never definitions, snapshot text, narrative content, secrets or tokens.
	 *
	 * Public only because the closures above reach it through `self`.
	 */
	public void function markRefusal(
		required struct into, required string versionId, required string versionLabel,
		required string status, required string operation, required string reason, string actorUserId = ""
	) {
		arguments.into["versionId"] = arguments.versionId;
		arguments.into["actorUserId"] = arguments.actorUserId;
		arguments.into["details"] = {
			"versionLabel": arguments.versionLabel,
			"status": arguments.status,
			"operation": arguments.operation,
			"reason": arguments.reason
		};
	}

	/**
	 * Which shared instrument facts the document disagrees with the stored row about -- and,
	 * deliberately, which ones are not shared facts at all.
	 *
	 * The document's instrument block carries code, name, description and active. Three of them
	 * are already stored at the right lifecycle scope and are therefore not ignored here:
	 *
	 *   code         the identity the row was found by. It cannot differ.
	 *   name         compiled into THIS version's snapshot, which is what RenderModelBuilder
	 *   description  returns as `instrument` and what the runtime shows for this version. Two
	 *                versions may legitimately describe the instrument differently, and each walk
	 *                sees its own version's wording. Nothing in the walk runtime reads
	 *                icf.instrument.name or .description; they are operational labels for the
	 *                instrument as a whole and belong to the instrument-level operation.
	 *
	 * That leaves `active`, which is the one the document cannot be allowed to state, because it
	 * is not version-scoped in effect: SnapshotService.currentVersion() filters on
	 * icf.instrument.active, so a DRAFT import declaring the instrument inactive would take an
	 * already PUBLISHED version out of service. It is refused rather than applied, and refused
	 * rather than quietly dropped, so an author who wrote it is told the decision is not theirs to
	 * make here.
	 */
	private array function sharedMetadataConflicts(required struct stored, required struct document) {
		var issues = [];
		if (flag(arguments.stored.active) != flag(arguments.document.active)) {
			arrayAppend(issues, {
				"code": "SHARED_METADATA_CONFLICT",
				"message": "The document says the instrument is " & (flag(arguments.document.active) ? "active" : "inactive")
					& " but the shared icf.instrument row says it is " & (flag(arguments.stored.active) ? "active" : "inactive")
					& ". Whether an instrument is in service decides which published version the runtime serves, so it is an"
					& " instrument-level decision and not an import's. Align the document, or change it through the authorized"
					& " instrument-level operation.",
				"path": "$.instrument.active"
			});
		}
		return issues;
	}

	private boolean function flag(any value) {
		if (isNull(arguments.value)) return false;
		if (isBoolean(arguments.value)) return arguments.value ? true : false;
		if (isSimpleValue(arguments.value)) {
			var t = lCase(trim(toString(arguments.value)));
			return t == "true" || t == "yes" || t == "1";
		}
		return false;
	}

	/** Writes the single refusal event, after the rollback, if a branch above decided on one. */
	private void function writeRefusalAudit(required struct refusal) {
		if (structIsEmpty(arguments.refusal)) return;
		variables.audit.record("INSTRUMENT_VERSION", arguments.refusal.versionId, "INSTRUMENT_VERSION_WRITE_REFUSED", arguments.refusal.actorUserId, arguments.refusal.details);
		variables.logger.warn("instrument.write.refused", {
			"versionId": arguments.refusal.versionId,
			"status": arguments.refusal.details.status,
			"operation": arguments.refusal.details.operation,
			"reason": arguments.refusal.details.reason
		});
	}

	// ---------------------------------------------------------------------------------------
	// Definition writes
	// ---------------------------------------------------------------------------------------

	private array function writeDefinitions(required string versionId, required struct d, required boolean isNewVersion) {
		var warnings = [];
		var existing = arguments.isNewVersion
			? { "sections": {}, "responseSets": {}, "options": {}, "rules": {}, "items": {}, "placements": {} }
			: variables.repo.loadVersionChildren(arguments.versionId);
		if (!arguments.isNewVersion) variables.repo.parkVersionOrders(arguments.versionId);
		var offset = variables.repo.parkOffset();

		// 1. Sections, pass one: content only, parked orders, no parents.
		var sectionIds = {};
		var seq = 0;
		for (var s in arguments.d.sections) {
			var row = variables.mapper.sectionRow(s);
			seq++;
			if (structKeyExists(existing.sections, s.sectionKey)) {
				sectionIds[s.sectionKey] = existing.sections[s.sectionKey].id;
				variables.repo.updateSectionContent(arguments.versionId, sectionIds[s.sectionKey], row);
			} else {
				sectionIds[s.sectionKey] = variables.repo.insertSection(arguments.versionId, row, offset * 2 + seq);
			}
		}

		// 2. Response sets and options.
		var setIds = {};
		var optionsBySet = {};
		for (var op in arguments.d.responseOptions) {
			if (!structKeyExists(optionsBySet, op.setKey)) optionsBySet[op.setKey] = [];
			arrayAppend(optionsBySet[op.setKey], op);
		}
		var keptOptions = {};
		for (var rs in arguments.d.responseSets) {
			var opts = structKeyExists(optionsBySet, rs.setKey) ? optionsBySet[rs.setKey] : [];
			var existingSetId = structKeyExists(existing.responseSets, rs.setKey) ? existing.responseSets[rs.setKey].id : "";
			setIds[rs.setKey] = variables.repo.upsertResponseSet(arguments.versionId, existingSetId, variables.mapper.responseSetRow(rs, opts));
			for (var op in opts) {
				var optKey = rs.setKey & "|" & op.optionKey;
				var existingOptId = structKeyExists(existing.options, optKey) ? existing.options[optKey].id : "";
				variables.repo.upsertOption(arguments.versionId, setIds[rs.setKey], existingOptId, variables.mapper.optionRow(op));
				keptOptions[optKey] = true;
			}
		}
		for (var optKey in structKeyArray(existing.options)) {
			if (!structKeyExists(keptOptions, optKey)) variables.repo.deleteOption(arguments.versionId, existing.options[optKey].id);
		}

		// 3. Dimension and dimension-value IDENTITY only (migration 006). The global rows carry the
		//    stable id and code that reporting and icf.walk_dimension_value depend on across
		//    versions; they are created the first time a code is seen and never updated again.
		//    What this version calls a dimension, and which values it offers, are written with the
		//    placement in step 6 -- to rows only this version owns.
		var dimensionIds = {};
		var dimensionRows = {};
		var valueIdsByDim = {};
		var existingDims = variables.repo.loadDimensions();
		var valuesByDim = {};
		for (var v in arguments.d.dimensionValues) {
			if (!structKeyExists(valuesByDim, v.dimensionCode)) valuesByDim[v.dimensionCode] = [];
			arrayAppend(valuesByDim[v.dimensionCode], v);
		}
		for (var dim in arguments.d.dimensions) {
			var vals = structKeyExists(valuesByDim, dim.code) ? valuesByDim[dim.code] : [];
			var dimRow = variables.mapper.dimensionRow(dim, vals);
			dimensionRows[dim.code] = dimRow;
			dimensionIds[dim.code] = structKeyExists(existingDims, dim.code)
				? existingDims[dim.code].id
				: variables.repo.createDimensionIdentity(arguments.versionId, dimRow);
			var existingValues = variables.repo.loadDimensionValues(dimensionIds[dim.code]);
			var valueIds = {};
			for (var v in vals) {
				var valueRow = variables.mapper.dimensionValueRow(v);
				valueIds[v.valueCode] = structKeyExists(existingValues, v.valueCode)
					? existingValues[v.valueCode].id
					: variables.repo.createDimensionValueIdentity(arguments.versionId, dimensionIds[dim.code], valueRow);
			}
			valueIdsByDim[dim.code] = valueIds;
		}

		// 4. Rules (target keys already resolved by the normalizer).
		var keptRules = {};
		for (var rule in arguments.d.rules) {
			var existingRuleId = structKeyExists(existing.rules, rule.ruleKey) ? existing.rules[rule.ruleKey].id : "";
			variables.repo.upsertRule(arguments.versionId, existingRuleId, variables.mapper.ruleRow(rule));
			keptRules[rule.ruleKey] = true;
		}

		// 5. Items.
		var keptItems = {};
		for (var it in arguments.d.items) {
			var existingItemId = structKeyExists(existing.items, it.itemKey) ? existing.items[it.itemKey].id : "";
			var setId = (!isNull(it.responseSetKey) && structKeyExists(setIds, it.responseSetKey)) ? setIds[it.responseSetKey] : "";
			variables.repo.upsertItem(arguments.versionId, existingItemId, variables.mapper.itemRow(it), sectionIds[it.sectionKey], setId);
			keptItems[it.itemKey] = true;
		}
		for (var itemKey in structKeyArray(existing.items)) {
			if (!structKeyExists(keptItems, itemKey)) variables.repo.deleteItem(arguments.versionId, existing.items[itemKey].id);
		}

		// 6. Placements (instrument_dimension), which reference rules and sections. The document
		//    authors placement order per section, while the supplied schema's
		//    UX_instrument_dimension_order is unique per version; the column receives a derived
		//    version-wide order and the authored order lives in settings_json and the snapshot.
		var columnOrders = placementColumnOrders(arguments.d);
		var keptPlacements = {};
		for (var p in arguments.d.instrumentDimensions) {
			var sectionId = (!isNull(p.sectionKey) && structKeyExists(sectionIds, p.sectionKey)) ? sectionIds[p.sectionKey] : "";
			var row = variables.mapper.placementRow(p);
			row["displayOrder"] = columnOrders[p.dimensionCode];
			// The version's own view of the dimension travels with its placement row, so a later
			// DRAFT that renames or deactivates the dimension writes to its own row, not this one.
			var dimRow = dimensionRows[p.dimensionCode];
			row["dimensionLabel"] = dimRow.label;
			row["dimensionDataType"] = dimRow.dataType;
			row["dimensionReportable"] = dimRow.reportable;
			row["dimensionSensitive"] = dimRow.sensitive;
			row["dimensionActive"] = dimRow.active;
			row["dimensionSettingsJson"] = dimRow.settingsJson;
			variables.repo.upsertPlacement(arguments.versionId, dimensionIds[p.dimensionCode], structKeyExists(existing.placements, p.dimensionCode), row, sectionId);

			// ...and so do the values it offers, in the order it offers them.
			var vals = structKeyExists(valuesByDim, p.dimensionCode) ? valuesByDim[p.dimensionCode] : [];
			var valueIds = structKeyExists(valueIdsByDim, p.dimensionCode) ? valueIdsByDim[p.dimensionCode] : {};
			var valueRows = [];
			for (var v in vals) {
				var valueRow = variables.mapper.dimensionValueRow(v);
				valueRow["valueId"] = valueIds[v.valueCode];
				arrayAppend(valueRows, valueRow);
			}
			variables.repo.replaceVersionDimensionValues(arguments.versionId, dimensionIds[p.dimensionCode], valueRows);
			keptPlacements[p.dimensionCode] = true;
		}
		for (var code in structKeyArray(existing.placements)) {
			if (!structKeyExists(keptPlacements, code)) variables.repo.deletePlacement(arguments.versionId, existing.placements[code].dimensionId);
		}
		for (var ruleKey in structKeyArray(existing.rules)) {
			if (!structKeyExists(keptRules, ruleKey)) variables.repo.deleteRule(arguments.versionId, existing.rules[ruleKey].id);
		}

		// 7. Sections, pass two: parents and final orders; then stale sections and sets.
		for (var s in arguments.d.sections) {
			var parentId = (!isNull(s.parentSectionKey) && structKeyExists(sectionIds, s.parentSectionKey)) ? sectionIds[s.parentSectionKey] : "";
			variables.repo.placeSection(arguments.versionId, sectionIds[s.sectionKey], parentId, s.displayOrder);
		}
		var staleSections = [];
		for (var sectionKey in structKeyArray(existing.sections)) {
			if (!structKeyExists(sectionIds, sectionKey)) arrayAppend(staleSections, existing.sections[sectionKey].id);
		}
		if (arrayLen(staleSections)) variables.repo.deleteSections(arguments.versionId, staleSections);
		for (var setKey in structKeyArray(existing.responseSets)) {
			if (!structKeyExists(setIds, setKey)) variables.repo.deleteResponseSet(arguments.versionId, existing.responseSets[setKey].id);
		}
		return warnings;
	}

	/**
	 * Derives a version-unique display_order for each placement: sections in document order
	 * (depth-first by displayOrder), then the authored placement order, then dimension code.
	 * Returns dimensionCode -> 10, 20, 30...
	 */
	private struct function placementColumnOrders(required struct d) {
		var byParent = {};
		for (var s in arguments.d.sections) {
			var parent = isNull(s.parentSectionKey) ? "" : s.parentSectionKey;
			if (!structKeyExists(byParent, parent)) byParent[parent] = [];
			arrayAppend(byParent[parent], s);
		}
		for (var parent in structKeyArray(byParent)) {
			arraySort(byParent[parent], function(a, b) {
				if (a.displayOrder != b.displayOrder) return a.displayOrder < b.displayOrder ? -1 : 1;
				return sgn(javaCast("string", a.sectionKey).compareTo(javaCast("string", b.sectionKey)));
			});
		}
		var rank = {};
		var counter = 0;
		var stack = structKeyExists(byParent, "") ? duplicate(byParent[""]) : [];
		// Iterative depth-first traversal preserving sibling order.
		var queue = [];
		for (var i = arrayLen(stack); i >= 1; i--) arrayAppend(queue, stack[i]);
		while (arrayLen(queue)) {
			var current = queue[arrayLen(queue)];
			arrayDeleteAt(queue, arrayLen(queue));
			counter++;
			rank[current.sectionKey] = counter;
			if (structKeyExists(byParent, current.sectionKey)) {
				var children = byParent[current.sectionKey];
				for (var j = arrayLen(children); j >= 1; j--) arrayAppend(queue, children[j]);
			}
		}
		var placements = duplicate(arguments.d.instrumentDimensions);
		arraySort(placements, function(a, b) {
			var ra = (!isNull(a.sectionKey) && structKeyExists(rank, a.sectionKey)) ? rank[a.sectionKey] : 0;
			var rb = (!isNull(b.sectionKey) && structKeyExists(rank, b.sectionKey)) ? rank[b.sectionKey] : 0;
			if (ra != rb) return ra < rb ? -1 : 1;
			if (a.displayOrder != b.displayOrder) return a.displayOrder < b.displayOrder ? -1 : 1;
			return sgn(javaCast("string", a.dimensionCode).compareTo(javaCast("string", b.dimensionCode)));
		});
		var orders = {};
		var n = 0;
		for (var p in placements) {
			n += 10;
			orders[p.dimensionCode] = n;
		}
		return orders;
	}
}
