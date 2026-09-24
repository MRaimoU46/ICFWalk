/**
 * Turns a version's normalized content back into the authoring document an administrator imports
 * (the config/instrument-config.json shape) -- the exact inverse of ConfigNormalizer.fromConfig.
 *
 * WHY IT IS EXACT. A compiled snapshot keeps every row's `authoringId` (the sectionId, itemId,
 * responseSetId ... the document named it by), and every reference between rows as a logical key.
 * So each row gets its own id back, and each key reference is resolved to the id of the row that
 * owns that key. ConfigNormalizer maps those ids straight back to the same keys, so
 * fromConfig(toDocument(n)).definitions compiles to n's definitions checksum. That is asserted by
 * InstrumentDocumentExporterTest for the supplied instrument, not assumed.
 *
 * What the document carries that the snapshot does not is supplied, never guessed:
 *   - every row's `versionId` is the version's own authoring id (import ignores it; the document
 *     shape has it);
 *   - the version declares `status: "DRAFT"` with no effective window, because importing it can
 *     only ever create or replace a DRAFT, and the importer refuses any other declaration;
 *   - a rule's `conditionsJson` is its parsed `conditions` serialized canonically. The text can
 *     differ from what was first written (key order, spacing); the document it parses to cannot.
 *   - `generatedAt` and the top-level `counts` are not written: import ignores both.
 * A row that somehow has no authoring id gets `<prefix><key>` so the document still imports; no
 * stored version has one, because every version began as an import.
 *
 * ROW ORDER IS FOR PEOPLE. Normalized collections are sorted by key, which is the order a checksum
 * needs and nobody reads in. The document lists sections in tree order, questions by section and
 * display order, options by set and display order, and so on -- the order the walk shows them.
 * Import re-sorts everything, so the order changes nothing about the version it produces.
 *
 * Pure: no database, no request. InstrumentAdminService supplies the normalized document from a
 * checksum-verified snapshot.
 */
component output="false" {

	public InstrumentDocumentExporter function init(required any canonicalJson) {
		variables.json = arguments.canonicalJson;
		return this;
	}

	/**
	 * @normalized the normalized document (DraftEditor.normalizedFromSnapshot of a stored snapshot)
	 * @return the authoring document, ready to import or to lay out as a workbook
	 */
	public struct function toDocument(required struct normalized) {
		var n = arguments.normalized;
		var defs = n.definitions;
		var instrument = structOr(n, "instrument");
		var version = structOr(n, "version");
		var versionId = idOr(version, "ver_", valueOr(version, "versionLabel", "version"));
		var instrumentId = idOr(instrument, "inst_", valueOr(instrument, "code", "instrument"));

		var sectionIdByKey = idsByKey(defs.sections, "sectionKey", "sec_");
		var itemIdByKey = idsByKey(defs.items, "itemKey", "item_");
		var setIdByKey = idsByKey(defs.responseSets, "setKey", "rs_");
		var dimensionIdByCode = idsByKey(defs.dimensions, "code", "dim_");
		var sectionRank = sectionTreeRanks(defs.sections);

		var sections = [];
		for (var s in sortedSections(defs.sections, sectionRank)) {
			var o = {};
			o["sectionId"] = idOr(s, "sec_", valueOr(s, "sectionKey", ""));
			o["versionId"] = versionId;
			o["parentSectionId"] = refOr(sectionIdByKey, s, "parentSectionKey");
			copyFields(o, s, ["sectionKey", "displayOrder", "title", "instructions", "colorHex", "notesEnabled", "optionalSection", "requiredSection", "active", "settings"]);
			authoring(o, s);
			arrayAppend(sections, o);
		}

		var items = [];
		for (var it in sortedBy(defs.items, function(a, b) {
			var bySection = rankOf(sectionRank, a, "sectionKey") - rankOf(sectionRank, b, "sectionKey");
			if (bySection != 0) return sgn(bySection);
			var byOrder = orderOf(a) - orderOf(b);
			if (byOrder != 0) return sgn(byOrder);
			return textCompare(a, b, "itemKey");
		})) {
			var o = {};
			o["itemId"] = idOr(it, "item_", valueOr(it, "itemKey", ""));
			o["versionId"] = versionId;
			o["sectionId"] = refOr(sectionIdByKey, it, "sectionKey");
			copyFields(o, it, ["itemKey", "reportingKey", "contentFamily", "itemType", "prompt", "helpText", "placeholder", "linkUrl"]);
			o["responseSetId"] = refOr(setIdByKey, it, "responseSetKey");
			copyFields(o, it, ["displayOrder", "required", "reportable", "active", "settings"]);
			authoring(o, it);
			arrayAppend(items, o);
		}

		var responseSets = [];
		for (var rs in sortedBy(defs.responseSets, function(a, b) { return textCompare(a, b, "setKey"); })) {
			var o = {};
			o["responseSetId"] = idOr(rs, "rs_", valueOr(rs, "setKey", ""));
			o["versionId"] = versionId;
			copyFields(o, rs, ["setKey", "name", "selectionMode", "allowNa", "scoreEnabled", "active"]);
			authoring(o, rs);
			arrayAppend(responseSets, o);
		}

		var responseOptions = [];
		for (var op in sortedBy(defs.responseOptions, function(a, b) {
			var bySet = textCompare(a, b, "setKey");
			if (bySet != 0) return bySet;
			var byOrder = orderOf(a) - orderOf(b);
			if (byOrder != 0) return sgn(byOrder);
			return textCompare(a, b, "optionKey");
		})) {
			var o = {};
			o["optionId"] = idOr(op, "opt_", valueOr(op, "setKey", "") & "_" & valueOr(op, "optionKey", ""));
			o["responseSetId"] = refOr(setIdByKey, op, "setKey");
			copyFields(o, op, ["optionKey", "storedCode", "label", "definition", "numericScore", "isNa", "displayOrder", "active"]);
			authoring(o, op);
			arrayAppend(responseOptions, o);
		}

		var rules = [];
		for (var r in sortedBy(defs.rules, function(a, b) { return textCompare(a, b, "ruleKey"); })) {
			var o = {};
			o["ruleId"] = idOr(r, "rule_", valueOr(r, "ruleKey", ""));
			o["versionId"] = versionId;
			copyFields(o, r, ["ruleKey", "targetType"]);
			var targetType = valueOr(r, "targetType", "");
			if (targetType == "SECTION") o["targetId"] = refOr(sectionIdByKey, r, "targetKey");
			else if (targetType == "ITEM") o["targetId"] = refOr(itemIdByKey, r, "targetKey");
			else if (targetType == "DIMENSION") o["targetId"] = refOr(dimensionIdByCode, r, "targetKey");
			else o["targetId"] = valueOrNull(r, "targetKey");
			copyFields(o, r, ["effect", "effectValue", "sourceType"]);
			// The source is written as a key even in the authoring document (ConfigNormalizer copies
			// sourceId to sourceKey unchanged), so it goes back unchanged.
			o["sourceId"] = valueOrNull(r, "sourceKey");
			copyFields(o, r, ["operator", "comparisonValue", "conditionLogic"]);
			o["conditionsJson"] = has(r, "conditions") ? variables.json.serialize(r.conditions) : javaCast("null", "");
			copyFields(o, r, ["active"]);
			authoring(o, r);
			arrayAppend(rules, o);
		}

		var dimensions = [];
		for (var d in sortedBy(defs.dimensions, function(a, b) { return textCompare(a, b, "code"); })) {
			var o = {};
			o["dimensionId"] = idOr(d, "dim_", valueOr(d, "code", ""));
			copyFields(o, d, ["code", "label", "dataType", "valueMode", "reportable", "sensitive", "allowOther", "active", "settings"]);
			authoring(o, d);
			arrayAppend(dimensions, o);
		}

		var dimensionValues = [];
		for (var v in sortedBy(defs.dimensionValues, function(a, b) {
			var byDimension = textCompare(a, b, "dimensionCode");
			if (byDimension != 0) return byDimension;
			var byOrder = orderOf(a) - orderOf(b);
			if (byOrder != 0) return sgn(byOrder);
			return textCompare(a, b, "valueCode");
		})) {
			var o = {};
			o["dimensionValueId"] = idOr(v, "dval_", valueOr(v, "dimensionCode", "") & "_" & valueOr(v, "valueCode", ""));
			o["dimensionId"] = refOr(dimensionIdByCode, v, "dimensionCode");
			copyFields(o, v, ["valueCode", "label", "displayOrder", "valueGroup", "gradeBand", "active", "effectiveStart", "effectiveEnd"]);
			authoring(o, v);
			arrayAppend(dimensionValues, o);
		}

		var instrumentDimensions = [];
		for (var p in sortedBy(defs.instrumentDimensions, function(a, b) {
			var bySection = rankOf(sectionRank, a, "sectionKey") - rankOf(sectionRank, b, "sectionKey");
			if (bySection != 0) return sgn(bySection);
			var byOrder = orderOf(a) - orderOf(b);
			if (byOrder != 0) return sgn(byOrder);
			return textCompare(a, b, "dimensionCode");
		})) {
			var o = {};
			o["instrumentDimensionId"] = idOr(p, "inst_dim_", valueOr(p, "dimensionCode", ""));
			o["versionId"] = versionId;
			o["dimensionId"] = refOr(dimensionIdByCode, p, "dimensionCode");
			o["sectionId"] = refOr(sectionIdByKey, p, "sectionKey");
			copyFields(o, p, ["displayOrder", "required", "visibleByDefault", "ruleKey", "labelOverride", "placeholder", "active", "settings"]);
			authoring(o, p);
			arrayAppend(instrumentDimensions, o);
		}

		var ver = {};
		ver["versionId"] = versionId;
		ver["instrumentId"] = instrumentId;
		ver["versionLabel"] = valueOrNull(version, "versionLabel");
		ver["status"] = "DRAFT";
		ver["effectiveStart"] = javaCast("null", "");
		ver["effectiveEnd"] = javaCast("null", "");
		copyFields(ver, version, ["extractedOn", "sourceFile", "sourceSha256", "reviewStatus", "revisionNotes"]);

		var inst = {};
		inst["instrumentId"] = instrumentId;
		copyFields(inst, instrument, ["code", "name", "description", "active"]);
		inst["version"] = ver;

		var doc = {};
		doc["schemaVersion"] = valueOrNull(n, "schemaVersion");
		doc["source"] = valueOrNull(n, "source");
		doc["instrument"] = inst;
		doc["sections"] = sections;
		doc["items"] = items;
		doc["responseSets"] = responseSets;
		doc["responseOptions"] = responseOptions;
		doc["rules"] = rules;
		doc["dimensions"] = dimensions;
		doc["dimensionValues"] = dimensionValues;
		doc["instrumentDimensions"] = instrumentDimensions;
		doc["behavior"] = valueOrNull(n, "behavior");
		doc["contentReview"] = valueOrNull(n, "contentReview");
		return doc;
	}

	// ---- ordering --------------------------------------------------------------------------------

	/** sectionKey -> position in a depth-first walk of the tree, siblings by display order then key. */
	private struct function sectionTreeRanks(required array sections) {
		var children = {};
		var roots = [];
		for (var s in arguments.sections) {
			if (has(s, "parentSectionKey")) {
				if (!structKeyExists(children, s.parentSectionKey)) children[s.parentSectionKey] = [];
				arrayAppend(children[s.parentSectionKey], s);
			} else {
				arrayAppend(roots, s);
			}
		}
		var state = { "ranks": {}, "next": 0 };
		visitSections(roots, children, state);
		// A section whose parent is missing is invalid, but it still gets a place, after the tree.
		for (var s in arguments.sections) {
			if (!structKeyExists(state.ranks, s.sectionKey)) { state.ranks[s.sectionKey] = state.next; state.next++; }
		}
		return state.ranks;
	}

	private void function visitSections(required array level, required struct children, required struct state) {
		var siblings = sortedBy(arguments.level, function(a, b) {
			var byOrder = orderOf(a) - orderOf(b);
			if (byOrder != 0) return sgn(byOrder);
			return textCompare(a, b, "sectionKey");
		});
		for (var s in siblings) {
			if (structKeyExists(arguments.state.ranks, s.sectionKey)) continue;
			arguments.state.ranks[s.sectionKey] = arguments.state.next;
			arguments.state.next++;
			if (structKeyExists(arguments.children, s.sectionKey)) visitSections(arguments.children[s.sectionKey], arguments.children, arguments.state);
		}
	}

	private array function sortedSections(required array sections, required struct ranks) {
		var r = arguments.ranks;
		return sortedBy(arguments.sections, function(a, b) { return sgn(r[a.sectionKey] - r[b.sectionKey]); });
	}

	private array function sortedBy(required array rows, required any comparator) {
		var sorted = duplicate(arguments.rows);
		arraySort(sorted, arguments.comparator);
		return sorted;
	}

	private numeric function rankOf(required struct ranks, required struct row, required string key) {
		if (!has(arguments.row, arguments.key) || !structKeyExists(arguments.ranks, arguments.row[arguments.key])) return 999999;
		return arguments.ranks[arguments.row[arguments.key]];
	}

	private numeric function orderOf(required struct row) {
		return has(arguments.row, "displayOrder") && isNumeric(arguments.row.displayOrder) ? arguments.row.displayOrder : 999999;
	}

	/** UTF-16 code unit order, nulls first -- the normalizer's own comparison. */
	private numeric function textCompare(required struct a, required struct b, required string key) {
		var left = has(arguments.a, arguments.key) ? javaCast("string", toString(arguments.a[arguments.key])) : javaCast("string", "");
		var right = has(arguments.b, arguments.key) ? javaCast("string", toString(arguments.b[arguments.key])) : javaCast("string", "");
		return sgn(left.compareTo(right));
	}

	// ---- helpers ---------------------------------------------------------------------------------

	private struct function idsByKey(required array rows, required string keyField, required string prefix) {
		var out = {};
		for (var row in arguments.rows) {
			if (has(row, arguments.keyField)) out[row[arguments.keyField]] = idOr(row, arguments.prefix, row[arguments.keyField]);
		}
		return out;
	}

	private string function idOr(required struct row, required string prefix, required string key) {
		return has(arguments.row, "authoringId") ? toString(arguments.row.authoringId) : arguments.prefix & arguments.key;
	}

	/** The id of the row that owns the referenced key, or null when there is no reference. */
	private any function refOr(required struct idsByKey, required struct row, required string keyField) {
		if (!has(arguments.row, arguments.keyField)) return javaCast("null", "");
		var key = arguments.row[arguments.keyField];
		// An unresolvable key is written as itself, so import reports it as a missing reference
		// rather than this export silently dropping it.
		return structKeyExists(arguments.idsByKey, key) ? arguments.idsByKey[key] : key;
	}

	private void function copyFields(required struct out, required struct src, required array keys) {
		for (var key in arguments.keys) arguments.out[key] = valueOrNull(arguments.src, key);
	}

	private void function authoring(required struct out, required struct src) {
		copyFields(arguments.out, arguments.src, ["sourceLocation", "reviewStatus", "revisionNotes"]);
	}

	private struct function structOr(required struct src, required string key) {
		return has(arguments.src, arguments.key) && isStruct(arguments.src[arguments.key]) ? arguments.src[arguments.key] : {};
	}

	private any function valueOrNull(required any src, required string key) {
		if (has(arguments.src, arguments.key)) return arguments.src[arguments.key];
		return javaCast("null", "");
	}

	private string function valueOr(required any src, required string key, required string fallback) {
		return has(arguments.src, arguments.key) && isSimpleValue(arguments.src[arguments.key]) ? toString(arguments.src[arguments.key]) : arguments.fallback;
	}

	private boolean function has(required any src, required string key) {
		return isStruct(arguments.src) && structKeyExists(arguments.src, arguments.key) && !isNull(arguments.src[arguments.key]);
	}
}
