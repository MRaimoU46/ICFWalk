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
 *      longer in the document. Global dimensions/values are upserted and never deleted.
 *   4. Read the persisted definitions back, recompile them, and abort (rolling back) unless the
 *      definitions checksum equals the checksum compiled from the input.
 *   5. Store the canonical snapshot and its SHA-256 on the version and write an audit event.
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

	public struct function importFromFile(required string path, string actorUserId = "") {
		if (!fileExists(arguments.path)) {
			variables.errors.notFound("Configuration file not found.", "CONFIG_FILE_NOT_FOUND");
		}
		var text = fileRead(arguments.path, "utf-8");
		if (!isJSON(text)) {
			variables.errors.importValidation("Configuration file is not valid JSON.", [{ "code": "INVALID_JSON", "message": "The document could not be parsed as JSON.", "path": "$" }]);
		}
		var result = importConfig(deserializeJSON(text), arguments.actorUserId);
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

		var outcome = variables.db.transact(function() {
			var instrument = variables.repo.findInstrumentByCode(normalized.instrument.code);
			var instrumentId = "";
			if (structIsEmpty(instrument)) {
				instrumentId = variables.repo.createInstrument(normalized.instrument.code, normalized.instrument.name, normalized.instrument.description, normalized.instrument.active);
			} else {
				instrumentId = instrument.instrumentId;
				variables.repo.updateInstrument(instrumentId, normalized.instrument.name, normalized.instrument.description, normalized.instrument.active);
			}

			var existing = variables.repo.findVersion(instrumentId, normalized.version.versionLabel, true);
			var created = false;
			var versionId = "";
			if (structIsEmpty(existing)) {
				versionId = variables.repo.createDraftVersion(instrumentId, normalized.version.versionLabel, actor);
				created = true;
			} else {
				if (existing.status != "DRAFT") {
					variables.errors.importPublishedVersion(normalized.version.versionLabel, existing.status);
				}
				var walkCount = variables.repo.countWalksForVersion(existing.versionId);
				if (walkCount > 0) {
					variables.errors.importVersionInUse(normalized.version.versionLabel, walkCount);
				}
				versionId = existing.versionId;
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
		return variables.db.transact(function() {
			var instrument = variables.repo.findInstrumentByCode(code);
			if (structIsEmpty(instrument)) variables.errors.notFound("No instrument with code '" & code & "' exists.", "INSTRUMENT_NOT_FOUND");
			var q = variables.db.run(
				"SELECT v.version_id, v.status FROM [icf].[instrument_version] v WITH (UPDLOCK, HOLDLOCK) WHERE v.instrument_id = :instrumentId AND v.version_label = :label",
				{ "instrumentId": variables.db.guid(instrument.instrumentId), "label": variables.db.nvarchar(label, 100) }
			);
			if (!q.recordCount) variables.errors.notFound("No version of instrument '" & code & "' with that label exists.", "VERSION_NOT_FOUND");
			var versionId = uCase(q.version_id[1]);
			if (q.status[1] != "DRAFT") variables.errors.importPublishedVersion(label, q.status[1]);
			var walkCount = variables.repo.countWalksForVersion(versionId);
			if (walkCount > 0) variables.errors.importVersionInUse(label, walkCount);
			variables.repo.deleteVersionCascadeUnchecked(versionId);
			variables.audit.record("INSTRUMENT_VERSION", versionId, "INSTRUMENT_VERSION_DISCARDED", actor, { "versionLabel": label, "instrumentCode": code });
			return { "versionId": versionId, "versionLabel": label, "instrumentCode": code, "discarded": true };
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
				variables.repo.updateSectionContent(sectionIds[s.sectionKey], row);
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
				variables.repo.upsertOption(setIds[rs.setKey], existingOptId, variables.mapper.optionRow(op));
				keptOptions[optKey] = true;
			}
		}
		for (var optKey in structKeyArray(existing.options)) {
			if (!structKeyExists(keptOptions, optKey)) variables.repo.deleteOption(existing.options[optKey].id);
		}

		// 3. Global dimensions and values (upsert only; never deleted).
		var dimensionIds = {};
		var existingDims = variables.repo.loadDimensions();
		var valuesByDim = {};
		for (var v in arguments.d.dimensionValues) {
			if (!structKeyExists(valuesByDim, v.dimensionCode)) valuesByDim[v.dimensionCode] = [];
			arrayAppend(valuesByDim[v.dimensionCode], v);
		}
		for (var dim in arguments.d.dimensions) {
			var vals = structKeyExists(valuesByDim, dim.code) ? valuesByDim[dim.code] : [];
			var existingDimId = structKeyExists(existingDims, dim.code) ? existingDims[dim.code].id : "";
			dimensionIds[dim.code] = variables.repo.upsertDimension(existingDimId, variables.mapper.dimensionRow(dim, vals));
			var existingValues = len(existingDimId) ? variables.repo.loadDimensionValues(dimensionIds[dim.code]) : {};
			if (structCount(existingValues)) variables.repo.parkDimensionValueOrders(dimensionIds[dim.code]);
			var kept = {};
			var usedOrders = {};
			for (var v in vals) {
				var existingValueId = structKeyExists(existingValues, v.valueCode) ? existingValues[v.valueCode].id : "";
				variables.repo.upsertDimensionValue(dimensionIds[dim.code], existingValueId, variables.mapper.dimensionValueRow(v));
				kept[v.valueCode] = true;
				usedOrders[toString(v.displayOrder)] = true;
			}
			// Values that exist in the database but not in the document keep their identity; restore
			// their order, moving them after the document's values when the order is now taken.
			var nextFree = 0;
			for (var code in structKeyArray(existingValues)) {
				if (structKeyExists(kept, code)) continue;
				var original = existingValues[code].displayOrder;
				var restored = original;
				if (structKeyExists(usedOrders, toString(original))) {
					if (nextFree == 0) nextFree = variables.repo.maxDimensionValueOrder(dimensionIds[dim.code]);
					nextFree += 10;
					restored = nextFree;
				}
				usedOrders[toString(restored)] = true;
				variables.repo.setDimensionValueOrder(existingValues[code].id, restored);
				arrayAppend(warnings, { "code": "DIMENSION_VALUE_NOT_IN_DOCUMENT", "message": "Dimension '" & dim.code & "' value '" & code & "' exists in the database but not in the imported document; it was left in place.", "path": "$.dimensionValues" });
			}
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
			if (!structKeyExists(keptItems, itemKey)) variables.repo.deleteItem(existing.items[itemKey].id);
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
			variables.repo.upsertPlacement(arguments.versionId, dimensionIds[p.dimensionCode], structKeyExists(existing.placements, p.dimensionCode), row, sectionId);
			keptPlacements[p.dimensionCode] = true;
		}
		for (var code in structKeyArray(existing.placements)) {
			if (!structKeyExists(keptPlacements, code)) variables.repo.deletePlacement(arguments.versionId, existing.placements[code].dimensionId);
		}
		for (var ruleKey in structKeyArray(existing.rules)) {
			if (!structKeyExists(keptRules, ruleKey)) variables.repo.deleteRule(existing.rules[ruleKey].id);
		}

		// 7. Sections, pass two: parents and final orders; then stale sections and sets.
		for (var s in arguments.d.sections) {
			var parentId = (!isNull(s.parentSectionKey) && structKeyExists(sectionIds, s.parentSectionKey)) ? sectionIds[s.parentSectionKey] : "";
			variables.repo.placeSection(sectionIds[s.sectionKey], parentId, s.displayOrder);
		}
		var staleSections = [];
		for (var sectionKey in structKeyArray(existing.sections)) {
			if (!structKeyExists(sectionIds, sectionKey)) arrayAppend(staleSections, existing.sections[sectionKey].id);
		}
		if (arrayLen(staleSections)) variables.repo.deleteSections(staleSections);
		for (var setKey in structKeyArray(existing.responseSets)) {
			if (!structKeyExists(setIds, setKey)) variables.repo.deleteResponseSet(existing.responseSets[setKey].id);
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
