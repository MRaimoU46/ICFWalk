/**
 * Two-way mapping between normalized definitions (the snapshot contract, keyed by logical keys)
 * and icf.* table rows. Fields the supplied schema has no column for are carried in the
 * settings_json column of the owning row, or, for tables without one (response_option,
 * dimension_value, rule_definition), in the parent's settings_json / the conditions document:
 *
 *   section_definition.settings_json    authoringId, colorHex, optionalSection, requiredSection,
 *                                       settings, sourceLocation, reviewStatus, revisionNotes
 *   response_set.settings_json          authoringId, allowNa, scoreEnabled, authoring fields,
 *                                       optionMetadata[optionKey] = {authoringId, authoring fields}
 *   rule_definition.conditions_json     {logic, conditions, authoring:{...}} (canonical document
 *                                       plus the authoring block; runtime reads logic/conditions)
 *   dimension_definition.settings_json  authoringId, valueMode, allowOther, settings, authoring,
 *                                       valueMetadata[valueCode] = {authoringId, valueGroup,
 *                                       gradeBand, authoring fields}
 *   instrument_dimension.settings_json  authoringId, visibleByDefault, placeholder, active,
 *                                       settings, authoring fields
 *   item_definition.settings_json       authoringId, contentFamily, placeholder, linkUrl,
 *                                       reportable, settings, authoring fields
 *
 * Keeping both directions here lets the importer prove, after every write, that reading the
 * rows back reproduces the imported document exactly (definitions checksum equality).
 */
component output="false" {

	public DefinitionMapper function init(required any canonicalJson) {
		variables.json = arguments.canonicalJson;
		return this;
	}

	// ---- normalized -> row ------------------------------------------------------------------

	public struct function sectionRow(required struct s) {
		var settings = {};
		settings["authoringId"] = pick(s, "authoringId");
		settings["colorHex"] = pick(s, "colorHex");
		settings["optionalSection"] = bool(s, "optionalSection");
		settings["requiredSection"] = bool(s, "requiredSection");
		settings["settings"] = structVal(s, "settings");
		authoringInto(settings, s);
		return {
			"sectionKey": s.sectionKey,
			"parentSectionKey": pick(s, "parentSectionKey"),
			"displayOrder": s.displayOrder,
			"title": s.title,
			"instructions": pick(s, "instructions"),
			"notesEnabled": bool(s, "notesEnabled"),
			"active": bool(s, "active"),
			"settingsJson": variables.json.serialize(settings)
		};
	}

	public struct function responseSetRow(required struct rs, required array options) {
		var settings = {};
		settings["authoringId"] = pick(rs, "authoringId");
		settings["allowNa"] = bool(rs, "allowNa");
		settings["scoreEnabled"] = bool(rs, "scoreEnabled");
		authoringInto(settings, rs);
		var meta = {};
		for (var op in arguments.options) {
			var m = {};
			m["authoringId"] = pick(op, "authoringId");
			authoringInto(m, op);
			meta[op.optionKey] = m;
		}
		settings["optionMetadata"] = meta;
		return {
			"setKey": rs.setKey,
			"name": rs.name,
			"selectionMode": rs.selectionMode,
			"active": bool(rs, "active"),
			"settingsJson": variables.json.serialize(settings)
		};
	}

	public struct function optionRow(required struct op) {
		return {
			"optionKey": op.optionKey,
			"storedCode": op.storedCode,
			"label": op.label,
			"definition": pick(op, "definition"),
			"numericScore": pick(op, "numericScore"),
			"isNa": bool(op, "isNa"),
			"displayOrder": op.displayOrder,
			"active": bool(op, "active")
		};
	}

	public struct function ruleRow(required struct r) {
		var doc = {};
		var conditions = structVal(r, "conditions");
		for (var k in structKeyArray(conditions)) {
			if (isNull(conditions[k])) doc[k] = javaCast("null", ""); else doc[k] = conditions[k];
		}
		var authoring = {};
		authoring["authoringId"] = pick(r, "authoringId");
		authoring["effectValue"] = pick(r, "effectValue");
		authoring["sourceType"] = pick(r, "sourceType");
		authoring["sourceKey"] = pick(r, "sourceKey");
		authoring["operator"] = pick(r, "operator");
		authoring["comparisonValue"] = pick(r, "comparisonValue");
		authoring["conditionLogic"] = pick(r, "conditionLogic");
		authoringInto(authoring, r);
		doc["authoring"] = authoring;
		return {
			"ruleKey": r.ruleKey,
			"targetType": r.targetType,
			"targetKey": r.targetKey,
			"effect": r.effect,
			"conditionsJson": variables.json.serialize(doc),
			"active": bool(r, "active")
		};
	}

	public struct function dimensionRow(required struct d, required array values) {
		var settings = {};
		settings["authoringId"] = pick(d, "authoringId");
		settings["valueMode"] = pick(d, "valueMode");
		settings["allowOther"] = bool(d, "allowOther");
		settings["settings"] = structVal(d, "settings");
		authoringInto(settings, d);
		var meta = {};
		for (var v in arguments.values) {
			var m = {};
			m["authoringId"] = pick(v, "authoringId");
			m["valueGroup"] = pick(v, "valueGroup");
			m["gradeBand"] = pick(v, "gradeBand");
			authoringInto(m, v);
			meta[v.valueCode] = m;
		}
		settings["valueMetadata"] = meta;
		return {
			"code": d.code,
			"label": d.label,
			"dataType": d.dataType,
			"reportable": bool(d, "reportable"),
			"sensitive": bool(d, "sensitive"),
			"active": bool(d, "active"),
			"settingsJson": variables.json.serialize(settings)
		};
	}

	public struct function dimensionValueRow(required struct v) {
		return {
			"valueCode": v.valueCode,
			"label": v.label,
			"displayOrder": v.displayOrder,
			"effectiveStart": pick(v, "effectiveStart"),
			"effectiveEnd": pick(v, "effectiveEnd"),
			"active": bool(v, "active")
		};
	}

	public struct function placementRow(required struct p) {
		var settings = {};
		settings["authoringId"] = pick(p, "authoringId");
		settings["visibleByDefault"] = bool(p, "visibleByDefault");
		settings["placeholder"] = pick(p, "placeholder");
		settings["active"] = bool(p, "active");
		settings["settings"] = structVal(p, "settings");
		// Authored (per-section) order. The display_order column holds a version-unique value
		// derived by the importer because UX_instrument_dimension_order is unique per version.
		settings["displayOrder"] = p.displayOrder;
		authoringInto(settings, p);
		return {
			"dimensionCode": p.dimensionCode,
			"sectionKey": pick(p, "sectionKey"),
			"displayOrder": p.displayOrder,
			"required": bool(p, "required"),
			"ruleKey": pick(p, "ruleKey"),
			"labelOverride": pick(p, "labelOverride"),
			"settingsJson": variables.json.serialize(settings)
		};
	}

	public struct function itemRow(required struct it) {
		var settings = {};
		settings["authoringId"] = pick(it, "authoringId");
		settings["contentFamily"] = pick(it, "contentFamily");
		settings["placeholder"] = pick(it, "placeholder");
		settings["linkUrl"] = pick(it, "linkUrl");
		settings["reportable"] = bool(it, "reportable");
		settings["settings"] = structVal(it, "settings");
		authoringInto(settings, it);
		return {
			"itemKey": it.itemKey,
			"sectionKey": it.sectionKey,
			"responseSetKey": pick(it, "responseSetKey"),
			"reportingKey": pick(it, "reportingKey"),
			"itemType": it.itemType,
			"prompt": it.prompt,
			"helpText": pick(it, "helpText"),
			"displayOrder": it.displayOrder,
			"required": bool(it, "required"),
			"active": bool(it, "active"),
			"settingsJson": variables.json.serialize(settings)
		};
	}

	// ---- row -> normalized ------------------------------------------------------------------
	// Query values arrive with SQL NULL as "" (CFML query semantics); text() maps "" back to null.

	public struct function sectionFromRow(required struct row, required string parentSectionKey) {
		var st = settingsOf(row.settings_json);
		var o = {};
		setVal(o, "authoringId", st, "authoringId");
		o["sectionKey"] = row.section_key;
		text(o, "parentSectionKey", arguments.parentSectionKey);
		o["displayOrder"] = num(row.display_order);
		o["title"] = row.title;
		text(o, "instructions", row.instructions);
		setVal(o, "colorHex", st, "colorHex");
		o["notesEnabled"] = toBool(row.notes_enabled);
		o["optionalSection"] = toBool(structVal(st, "optionalSection", false));
		o["requiredSection"] = toBool(structVal(st, "requiredSection", false));
		o["active"] = toBool(row.active);
		o["settings"] = structVal(st, "settings");
		authoringFrom(o, st);
		return o;
	}

	public struct function responseSetFromRow(required struct row) {
		var st = settingsOf(row.settings_json);
		var o = {};
		setVal(o, "authoringId", st, "authoringId");
		o["setKey"] = row.response_set_key;
		o["name"] = row.name;
		o["selectionMode"] = row.selection_mode;
		o["allowNa"] = toBool(structVal(st, "allowNa", false));
		o["scoreEnabled"] = toBool(structVal(st, "scoreEnabled", false));
		o["active"] = toBool(row.active);
		authoringFrom(o, st);
		return o;
	}

	public struct function optionFromRow(required struct row, required string setKey, required struct setSettings) {
		var meta = structVal(arguments.setSettings, "optionMetadata");
		var m = structKeyExists(meta, row.option_key) && isStruct(meta[row.option_key]) ? meta[row.option_key] : {};
		var o = {};
		setVal(o, "authoringId", m, "authoringId");
		o["setKey"] = arguments.setKey;
		o["optionKey"] = row.option_key;
		o["storedCode"] = row.stored_code;
		o["label"] = row.label;
		text(o, "definition", row.definition);
		number(o, "numericScore", row.numeric_score);
		o["isNa"] = toBool(row.is_na);
		o["displayOrder"] = num(row.display_order);
		o["active"] = toBool(row.active);
		authoringFrom(o, m);
		return o;
	}

	public struct function ruleFromRow(required struct row) {
		var doc = settingsOf(row.conditions_json);
		var authoring = structVal(doc, "authoring");
		var conditions = {};
		for (var k in structKeyArray(doc)) {
			if (k == "authoring") continue;
			if (isNull(doc[k])) conditions[k] = javaCast("null", ""); else conditions[k] = doc[k];
		}
		var o = {};
		setVal(o, "authoringId", authoring, "authoringId");
		o["ruleKey"] = row.rule_key;
		o["targetType"] = row.target_type;
		o["targetKey"] = row.target_key;
		o["effect"] = row.effect;
		setVal(o, "effectValue", authoring, "effectValue");
		setVal(o, "sourceType", authoring, "sourceType");
		setVal(o, "sourceKey", authoring, "sourceKey");
		setVal(o, "operator", authoring, "operator");
		setVal(o, "comparisonValue", authoring, "comparisonValue");
		setVal(o, "conditionLogic", authoring, "conditionLogic");
		o["conditions"] = conditions;
		o["active"] = toBool(row.active);
		authoringFrom(o, authoring);
		return o;
	}

	public struct function dimensionFromRow(required struct row) {
		var st = settingsOf(row.settings_json);
		var o = {};
		setVal(o, "authoringId", st, "authoringId");
		o["code"] = row.code;
		o["label"] = row.label;
		o["dataType"] = row.data_type;
		setVal(o, "valueMode", st, "valueMode");
		o["reportable"] = toBool(row.reportable);
		o["sensitive"] = toBool(row.sensitive);
		o["allowOther"] = toBool(structVal(st, "allowOther", false));
		o["active"] = toBool(row.active);
		o["settings"] = structVal(st, "settings");
		authoringFrom(o, st);
		return o;
	}

	public struct function dimensionValueFromRow(required struct row, required string dimensionCode, required struct dimensionSettings) {
		var meta = structVal(arguments.dimensionSettings, "valueMetadata");
		var m = structKeyExists(meta, row.value_code) && isStruct(meta[row.value_code]) ? meta[row.value_code] : {};
		var o = {};
		setVal(o, "authoringId", m, "authoringId");
		o["dimensionCode"] = arguments.dimensionCode;
		o["valueCode"] = row.value_code;
		o["label"] = row.label;
		o["displayOrder"] = num(row.display_order);
		setVal(o, "valueGroup", m, "valueGroup");
		setVal(o, "gradeBand", m, "gradeBand");
		o["active"] = toBool(row.active);
		instant(o, "effectiveStart", row.effective_start);
		instant(o, "effectiveEnd", row.effective_end);
		authoringFrom(o, m);
		return o;
	}

	public struct function placementFromRow(required struct row, required string dimensionCode, required string sectionKey) {
		var st = settingsOf(row.settings_json);
		var o = {};
		setVal(o, "authoringId", st, "authoringId");
		o["dimensionCode"] = arguments.dimensionCode;
		text(o, "sectionKey", arguments.sectionKey);
		o["displayOrder"] = num(structVal(st, "displayOrder", row.display_order));
		o["required"] = toBool(row.required);
		o["visibleByDefault"] = toBool(structVal(st, "visibleByDefault", false));
		text(o, "ruleKey", row.rule_key);
		text(o, "labelOverride", row.label_override);
		setVal(o, "placeholder", st, "placeholder");
		o["active"] = toBool(structVal(st, "active", true));
		o["settings"] = structVal(st, "settings");
		authoringFrom(o, st);
		return o;
	}

	public struct function itemFromRow(required struct row, required string sectionKey, required string responseSetKey) {
		var st = settingsOf(row.settings_json);
		var o = {};
		setVal(o, "authoringId", st, "authoringId");
		o["itemKey"] = row.item_key;
		o["sectionKey"] = arguments.sectionKey;
		text(o, "responseSetKey", arguments.responseSetKey);
		text(o, "reportingKey", row.reporting_key);
		setVal(o, "contentFamily", st, "contentFamily");
		o["itemType"] = row.item_type;
		o["prompt"] = row.prompt;
		text(o, "helpText", row.help_text);
		setVal(o, "placeholder", st, "placeholder");
		setVal(o, "linkUrl", st, "linkUrl");
		o["displayOrder"] = num(row.display_order);
		o["required"] = toBool(row.required);
		o["reportable"] = toBool(structVal(st, "reportable", false));
		o["active"] = toBool(row.active);
		o["settings"] = structVal(st, "settings");
		authoringFrom(o, st);
		return o;
	}

	// ---- helpers ------------------------------------------------------------------------

	public struct function settingsOf(required any text) {
		if (isNull(arguments.text) || !isSimpleValue(arguments.text) || !len(trim(arguments.text)) || !isJSON(arguments.text)) return {};
		var parsed = deserializeJSON(arguments.text);
		return isStruct(parsed) ? parsed : {};
	}

	private any function pick(required struct s, required string key) {
		if (structKeyExists(arguments.s, arguments.key) && !isNull(arguments.s[arguments.key])) return arguments.s[arguments.key];
		return javaCast("null", "");
	}

	private boolean function bool(required struct s, required string key) {
		return structKeyExists(arguments.s, arguments.key) && !isNull(arguments.s[arguments.key]) && isBoolean(arguments.s[arguments.key]) && arguments.s[arguments.key];
	}

	private any function structVal(required struct s, required string key, any defaultValue) {
		if (structKeyExists(arguments.s, arguments.key) && !isNull(arguments.s[arguments.key])) {
			if (isStruct(arguments.s[arguments.key]) || structKeyExists(arguments, "defaultValue")) return arguments.s[arguments.key];
		}
		if (structKeyExists(arguments, "defaultValue")) return arguments.defaultValue;
		return {};
	}

	private void function authoringInto(required struct target, required struct src) {
		arguments.target["sourceLocation"] = pick(arguments.src, "sourceLocation");
		arguments.target["reviewStatus"] = pick(arguments.src, "reviewStatus");
		arguments.target["revisionNotes"] = pick(arguments.src, "revisionNotes");
	}

	private void function authoringFrom(required struct target, required struct st) {
		setVal(arguments.target, "sourceLocation", arguments.st, "sourceLocation");
		setVal(arguments.target, "reviewStatus", arguments.st, "reviewStatus");
		setVal(arguments.target, "revisionNotes", arguments.st, "revisionNotes");
	}

	private void function setVal(required struct out, required string key, required struct src, required string srcKey) {
		if (structKeyExists(arguments.src, arguments.srcKey) && !isNull(arguments.src[arguments.srcKey])) arguments.out[arguments.key] = arguments.src[arguments.srcKey];
		else arguments.out[arguments.key] = javaCast("null", "");
	}

	private void function text(required struct out, required string key, required any value) {
		if (isNull(arguments.value) || !isSimpleValue(arguments.value) || !len(toString(arguments.value))) arguments.out[arguments.key] = javaCast("null", "");
		else arguments.out[arguments.key] = toString(arguments.value);
	}

	private void function number(required struct out, required string key, required any value) {
		if (isNull(arguments.value) || (isSimpleValue(arguments.value) && !len(toString(arguments.value))) || !isNumeric(arguments.value)) arguments.out[arguments.key] = javaCast("null", "");
		else arguments.out[arguments.key] = createObject("java", "java.math.BigDecimal").init(javaCast("string", toString(arguments.value)));
	}

	private void function instant(required struct out, required string key, required any value) {
		if (isNull(arguments.value) || (isSimpleValue(arguments.value) && !isDate(arguments.value))) arguments.out[arguments.key] = javaCast("null", "");
		else arguments.out[arguments.key] = variables.json.formatDate(arguments.value);
	}

	private numeric function num(required any value) {
		return javaCast("int", arguments.value);
	}

	private boolean function toBool(required any value) {
		return (isBoolean(arguments.value) && arguments.value) ? true : false;
	}
}
