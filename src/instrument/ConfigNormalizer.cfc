/**
 * Converts the authoring JSON (config/instrument-config.json, logical IDs) into the normalized,
 * key-based contract consumed by the snapshot compiler and the importer. Mirrors
 * scripts/lib/snapshot.mjs normalizeConfig exactly: every field is explicit (missing values
 * become null), booleans are coerced, and arrays are sorted by their unique keys.
 *
 * Unknown references are mapped to null rather than raising so that the validator can report
 * them with precise paths; the validator always runs before an import proceeds.
 */
component output="false" {

	public ConfigNormalizer function init() {
		return this;
	}

	public struct function fromConfig(required struct config) {
		var cfg = arguments.config;
		var sectionKeyById = indexBy(cfg.sections, "sectionId", "sectionKey");
		var itemKeyById = indexBy(cfg.items, "itemId", "itemKey");
		var setKeyById = indexBy(cfg.responseSets, "responseSetId", "setKey");
		var dimensionCodeById = indexBy(cfg.dimensions, "dimensionId", "code");

		var sections = [];
		for (var s in cfg.sections) {
			var o = {};
			put(o, "authoringId", s, "sectionId");
			put(o, "sectionKey", s, "sectionKey");
			o["parentSectionKey"] = lookup(sectionKeyById, s, "parentSectionId");
			put(o, "displayOrder", s, "displayOrder");
			put(o, "title", s, "title");
			put(o, "instructions", s, "instructions");
			put(o, "colorHex", s, "colorHex");
			putBool(o, "notesEnabled", s, "notesEnabled");
			putBool(o, "optionalSection", s, "optionalSection");
			putBool(o, "requiredSection", s, "requiredSection");
			putBool(o, "active", s, "active");
			putSettings(o, "settings", s, "settings");
			putAuthoring(o, s);
			arrayAppend(sections, o);
		}
		sortBy(sections, ["sectionKey"]);

		var items = [];
		for (var it in cfg.items) {
			var o = {};
			put(o, "authoringId", it, "itemId");
			put(o, "itemKey", it, "itemKey");
			o["sectionKey"] = lookup(sectionKeyById, it, "sectionId");
			o["responseSetKey"] = lookup(setKeyById, it, "responseSetId");
			put(o, "reportingKey", it, "reportingKey");
			put(o, "contentFamily", it, "contentFamily");
			put(o, "itemType", it, "itemType");
			put(o, "prompt", it, "prompt");
			put(o, "helpText", it, "helpText");
			put(o, "placeholder", it, "placeholder");
			put(o, "linkUrl", it, "linkUrl");
			put(o, "displayOrder", it, "displayOrder");
			putBool(o, "required", it, "required");
			putBool(o, "reportable", it, "reportable");
			putBool(o, "active", it, "active");
			putSettings(o, "settings", it, "settings");
			putAuthoring(o, it);
			arrayAppend(items, o);
		}
		sortBy(items, ["itemKey"]);

		var responseSets = [];
		for (var rs in cfg.responseSets) {
			var o = {};
			put(o, "authoringId", rs, "responseSetId");
			put(o, "setKey", rs, "setKey");
			put(o, "name", rs, "name");
			put(o, "selectionMode", rs, "selectionMode");
			putBool(o, "allowNa", rs, "allowNa");
			putBool(o, "scoreEnabled", rs, "scoreEnabled");
			putBool(o, "active", rs, "active");
			putAuthoring(o, rs);
			arrayAppend(responseSets, o);
		}
		sortBy(responseSets, ["setKey"]);

		var responseOptions = [];
		for (var op in cfg.responseOptions) {
			var o = {};
			put(o, "authoringId", op, "optionId");
			o["setKey"] = lookup(setKeyById, op, "responseSetId");
			put(o, "optionKey", op, "optionKey");
			put(o, "storedCode", op, "storedCode");
			put(o, "label", op, "label");
			put(o, "definition", op, "definition");
			put(o, "numericScore", op, "numericScore");
			putBool(o, "isNa", op, "isNa");
			put(o, "displayOrder", op, "displayOrder");
			putBool(o, "active", op, "active");
			putAuthoring(o, op);
			arrayAppend(responseOptions, o);
		}
		sortBy(responseOptions, ["setKey", "optionKey"]);

		var rules = [];
		for (var r in cfg.rules) {
			var o = {};
			put(o, "authoringId", r, "ruleId");
			put(o, "ruleKey", r, "ruleKey");
			put(o, "targetType", r, "targetType");
			var targetType = has(r, "targetType") ? r.targetType : "";
			if (targetType == "SECTION") o["targetKey"] = lookup(sectionKeyById, r, "targetId");
			else if (targetType == "ITEM") o["targetKey"] = lookup(itemKeyById, r, "targetId");
			else if (targetType == "DIMENSION") o["targetKey"] = lookup(dimensionCodeById, r, "targetId");
			else o["targetKey"] = javaCast("null", "");
			put(o, "effect", r, "effect");
			put(o, "effectValue", r, "effectValue");
			put(o, "sourceType", r, "sourceType");
			put(o, "sourceKey", r, "sourceId");
			put(o, "operator", r, "operator");
			put(o, "comparisonValue", r, "comparisonValue");
			put(o, "conditionLogic", r, "conditionLogic");
			if (has(r, "conditionsJson") && isSimpleValue(r.conditionsJson) && isJSON(r.conditionsJson)) {
				o["conditions"] = deserializeJSON(r.conditionsJson);
			} else {
				o["conditions"] = javaCast("null", "");
			}
			putBool(o, "active", r, "active");
			putAuthoring(o, r);
			arrayAppend(rules, o);
		}
		sortBy(rules, ["ruleKey"]);

		var dimensions = [];
		for (var d in cfg.dimensions) {
			var o = {};
			put(o, "authoringId", d, "dimensionId");
			put(o, "code", d, "code");
			put(o, "label", d, "label");
			put(o, "dataType", d, "dataType");
			put(o, "valueMode", d, "valueMode");
			putBool(o, "reportable", d, "reportable");
			putBool(o, "sensitive", d, "sensitive");
			putBool(o, "allowOther", d, "allowOther");
			putBool(o, "active", d, "active");
			putSettings(o, "settings", d, "settings");
			putAuthoring(o, d);
			arrayAppend(dimensions, o);
		}
		sortBy(dimensions, ["code"]);

		var dimensionValues = [];
		for (var v in cfg.dimensionValues) {
			var o = {};
			put(o, "authoringId", v, "dimensionValueId");
			o["dimensionCode"] = lookup(dimensionCodeById, v, "dimensionId");
			put(o, "valueCode", v, "valueCode");
			put(o, "label", v, "label");
			put(o, "displayOrder", v, "displayOrder");
			put(o, "valueGroup", v, "valueGroup");
			put(o, "gradeBand", v, "gradeBand");
			putBool(o, "active", v, "active");
			put(o, "effectiveStart", v, "effectiveStart");
			put(o, "effectiveEnd", v, "effectiveEnd");
			putAuthoring(o, v);
			arrayAppend(dimensionValues, o);
		}
		sortBy(dimensionValues, ["dimensionCode", "valueCode"]);

		var instrumentDimensions = [];
		for (var p in cfg.instrumentDimensions) {
			var o = {};
			put(o, "authoringId", p, "instrumentDimensionId");
			o["dimensionCode"] = lookup(dimensionCodeById, p, "dimensionId");
			o["sectionKey"] = lookup(sectionKeyById, p, "sectionId");
			put(o, "displayOrder", p, "displayOrder");
			putBool(o, "required", p, "required");
			putBool(o, "visibleByDefault", p, "visibleByDefault");
			put(o, "ruleKey", p, "ruleKey");
			put(o, "labelOverride", p, "labelOverride");
			put(o, "placeholder", p, "placeholder");
			putBool(o, "active", p, "active");
			putSettings(o, "settings", p, "settings");
			putAuthoring(o, p);
			arrayAppend(instrumentDimensions, o);
		}
		sortBy(instrumentDimensions, ["dimensionCode"]);

		var inst = cfg.instrument;
		var ver = has(inst, "version") && isStruct(inst.version) ? inst.version : {};
		var source = has(cfg, "source") && isStruct(cfg.source) ? cfg.source : {};

		var normalized = {};
		put(normalized, "schemaVersion", cfg, "schemaVersion");
		var src = {};
		put(src, "file", source, "file");
		put(src, "sha256", source, "sha256");
		put(src, "authority", source, "authority");
		normalized["source"] = src;
		var instrument = {};
		put(instrument, "authoringId", inst, "instrumentId");
		put(instrument, "code", inst, "code");
		put(instrument, "name", inst, "name");
		put(instrument, "description", inst, "description");
		putBool(instrument, "active", inst, "active");
		normalized["instrument"] = instrument;
		var version = {};
		put(version, "authoringId", ver, "versionId");
		put(version, "versionLabel", ver, "versionLabel");
		put(version, "extractedOn", ver, "extractedOn");
		put(version, "sourceFile", ver, "sourceFile");
		put(version, "sourceSha256", ver, "sourceSha256");
		put(version, "reviewStatus", ver, "reviewStatus");
		put(version, "revisionNotes", ver, "revisionNotes");
		normalized["version"] = version;
		normalized["definitions"] = {
			"sections": sections,
			"items": items,
			"responseSets": responseSets,
			"responseOptions": responseOptions,
			"rules": rules,
			"dimensions": dimensions,
			"dimensionValues": dimensionValues,
			"instrumentDimensions": instrumentDimensions
		};
		put(normalized, "behavior", cfg, "behavior");
		put(normalized, "contentReview", cfg, "contentReview");
		return normalized;
	}

	// ---- helpers ------------------------------------------------------------------------

	public boolean function has(required any src, required string key) {
		return isStruct(arguments.src) && structKeyExists(arguments.src, arguments.key) && !isNull(arguments.src[arguments.key]);
	}

	private struct function indexBy(required array rows, required string idKey, required string valueKey) {
		var map = {};
		for (var row in arguments.rows) {
			if (has(row, arguments.idKey) && has(row, arguments.valueKey)) map[toString(row[arguments.idKey])] = row[arguments.valueKey];
		}
		return map;
	}

	private any function lookup(required struct map, required struct src, required string key) {
		if (!has(arguments.src, arguments.key)) return javaCast("null", "");
		var id = toString(arguments.src[arguments.key]);
		if (!structKeyExists(arguments.map, id)) return javaCast("null", "");
		return arguments.map[id];
	}

	private void function put(required struct out, required string key, required any src, required string srcKey) {
		if (has(arguments.src, arguments.srcKey)) arguments.out[arguments.key] = arguments.src[arguments.srcKey];
		else arguments.out[arguments.key] = javaCast("null", "");
	}

	private void function putBool(required struct out, required string key, required any src, required string srcKey) {
		if (has(arguments.src, arguments.srcKey) && isBoolean(arguments.src[arguments.srcKey]) && arguments.src[arguments.srcKey]) arguments.out[arguments.key] = true;
		else arguments.out[arguments.key] = false;
	}

	private void function putSettings(required struct out, required string key, required any src, required string srcKey) {
		if (has(arguments.src, arguments.srcKey) && isStruct(arguments.src[arguments.srcKey])) arguments.out[arguments.key] = arguments.src[arguments.srcKey];
		else arguments.out[arguments.key] = {};
	}

	private void function putAuthoring(required struct out, required any src) {
		put(arguments.out, "sourceLocation", arguments.src, "sourceLocation");
		put(arguments.out, "reviewStatus", arguments.src, "reviewStatus");
		put(arguments.out, "revisionNotes", arguments.src, "revisionNotes");
	}

	/**
	 * Sorts an array of structs by one or more string keys using UTF-16 code unit comparison
	 * (nulls sort first), matching the JavaScript reference.
	 */
	public void function sortBy(required array rows, required array keys) {
		var keyList = arguments.keys;
		arraySort(arguments.rows, function(a, b) {
			for (var k in keyList) {
				var left = (structKeyExists(a, k) && !isNull(a[k])) ? javaCast("string", toString(a[k])) : javaCast("string", "");
				var right = (structKeyExists(b, k) && !isNull(b[k])) ? javaCast("string", toString(b[k])) : javaCast("string", "");
				var cmp = left.compareTo(right);
				if (cmp != 0) return sgn(cmp);
			}
			return 0;
		});
	}
}
