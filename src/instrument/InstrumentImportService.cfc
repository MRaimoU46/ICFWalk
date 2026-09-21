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
 */
component output="false" {

	public InstrumentImportService function init(
		required struct config, required any db, required any errors, required any logger,
		required any definitionRepository, required any auditRepository, required any configNormalizer,
		required any configValidator, required any snapshotCompiler, required any requestContext
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

	public struct function importConfig(required any config, string actorUserId = "") {
		var started = getTickCount();
		var validation = variables.validator.validate(arguments.config);
		if (!validation.valid) {
			variables.logger.warn("instrument.import.rejected", { "errorCount": arrayLen(validation.errors), "firstCode": validation.errors[1].code });
			variables.errors.importValidation("Instrument configuration failed validation with " & arrayLen(validation.errors) & " error(s). First: " & validation.errors[1].message, validation.errors);
		}

		var normalized = variables.normalizer.fromConfig(arguments.config);
		var compiled = variables.compiler.compile(normalized);
		var actor = arguments.actorUserId;
		var self = this;
		// Filled by a refusing branch inside the transaction; written after the rollback below.
		var refusal = {};

		var outcome = "";
		try {
		outcome = variables.db.transact(function() {
			var instrument = variables.repo.findInstrumentByCode(normalized.instrument.code);
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
			if (structIsEmpty(existing)) {
				versionId = variables.repo.createDraftVersion(instrumentId, normalized.version.versionLabel, actor);
				created = true;
			} else {
				if (existing.status != "DRAFT") {
					self.markRefusal(refusal, existing.versionId, normalized.version.versionLabel, existing.status, "IMPORT", "VERSION_NOT_DRAFT", actor);
					variables.errors.importPublishedVersion(normalized.version.versionLabel, existing.status);
				}
				var walkCount = variables.repo.countWalksForVersion(existing.versionId);
				if (walkCount > 0) {
					variables.errors.importVersionInUse(normalized.version.versionLabel, walkCount);
				}
				versionId = existing.versionId;
			}

			if (!structIsEmpty(instrument)) {
				variables.repo.updateInstrument(instrumentId, normalized.instrument.name, normalized.instrument.description, normalized.instrument.active);
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

			variables.audit.record("INSTRUMENT_VERSION", versionId, created ? "INSTRUMENT_VERSION_CREATED" : "INSTRUMENT_VERSION_REIMPORTED", actor, {
				"versionLabel": normalized.version.versionLabel,
				"instrumentCode": normalized.instrument.code,
				"checksum": compiled.checksum,
				"definitionsChecksum": compiled.definitionsChecksum,
				"counts": compiled.counts,
				"warningCount": arrayLen(warnings),
				"placeholderCount": arrayLen(placeholders)
			});

			return {
				"instrumentId": instrumentId,
				"versionId": versionId,
				"versionLabel": normalized.version.versionLabel,
				"instrumentCode": normalized.instrument.code,
				"status": "DRAFT",
				"created": created,
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
		variables.logger.info("instrument.import.completed", { "versionId": outcome.versionId, "created": outcome.created, "checksum": outcome.checksum, "counts": outcome.counts, "warningCount": arrayLen(outcome.warnings), "elapsedMs": outcome.elapsedMs });
		return outcome;
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
				if (walkCount > 0) variables.errors.importVersionInUse(label, walkCount);
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
				: variables.repo.createDimensionIdentity(dimRow);
			var existingValues = variables.repo.loadDimensionValues(dimensionIds[dim.code]);
			var valueIds = {};
			for (var v in vals) {
				var valueRow = variables.mapper.dimensionValueRow(v);
				valueIds[v.valueCode] = structKeyExists(existingValues, v.valueCode)
					? existingValues[v.valueCode].id
					: variables.repo.createDimensionValueIdentity(dimensionIds[dim.code], valueRow);
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
