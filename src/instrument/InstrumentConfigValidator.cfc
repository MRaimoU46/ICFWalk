/**
 * Validates an authoring document (config/instrument-config.json shape) before it touches the
 * database. Reports every problem it can find as { code, message, path } so content owners get
 * a complete list, then the importer refuses the document when any error exists.
 *
 * Errors block import. Warnings (placeholder content, review mismatches) are returned with the
 * import result and, per docs/OPEN_DECISIONS.md, only block publication when configured.
 */
component output="false" {

	variables.ITEM_TYPES = ["SINGLE_CHOICE", "MULTI_CHOICE", "LONG_TEXT", "SHORT_TEXT", "DISPLAY_HEADING", "DISPLAY_GUIDANCE", "EMAIL_DRAFT_JSON"];
	variables.CHOICE_TYPES = ["SINGLE_CHOICE", "MULTI_CHOICE"];
	variables.SELECTION_MODES = ["SINGLE", "MULTI"];
	variables.TARGET_TYPES = ["SECTION", "ITEM", "DIMENSION"];
	variables.EFFECTS = ["SHOW", "HIDE", "REQUIRE", "OPTIONAL"];
	variables.SUPPORTED_EFFECTS = ["SHOW"];
	variables.SOURCE_TYPES = ["ITEM", "DIMENSION"];
	variables.OPERATORS = ["EQUALS", "NOT_EQUALS", "IN", "NOT_IN"];
	variables.DATA_TYPES = ["LIST", "TEXT", "NUMBER", "DATE", "BOOLEAN"];
	variables.LOGICS = ["AND", "OR"];
	variables.MAX_ORDER = 999999;
	variables.PLACEHOLDER_REVIEW_STATUS = "Placeholder in source";
	variables.RETIRED_TEXT = ["school improvement (sip)", "sip grade"];

	public InstrumentConfigValidator function init(required any errors) {
		variables.errors = arguments.errors;
		return this;
	}

	/**
	 * @return { valid: boolean, errors: [], warnings: [], placeholders: [] }
	 */
	public struct function validate(required any config) {
		var r = { "valid": true, "errors": [], "warnings": [], "placeholders": [] };
		if (!isStruct(arguments.config)) {
			err(r, "STRUCTURE", "Configuration must be a JSON object.", "$");
			r.valid = false;
			return r;
		}
		var cfg = arguments.config;
		checkStructure(r, cfg);
		if (arrayLen(r.errors)) { r.valid = false; return r; }

		checkInstrument(r, cfg);
		var ids = checkUniqueness(r, cfg);
		checkReferences(r, cfg, ids);
		checkSections(r, cfg);
		checkResponseSets(r, cfg);
		checkItems(r, cfg, ids);
		checkRules(r, cfg, ids);
		checkDimensions(r, cfg);
		checkPlacements(r, cfg);
		checkRetiredContent(r, cfg);
		collectPlaceholders(r, cfg);
		r.valid = arrayLen(r.errors) == 0;
		return r;
	}

	// ---------------------------------------------------------------------------------------

	private void function checkStructure(required struct r, required struct cfg) {
		for (var key in ["sections", "items", "responseSets", "responseOptions", "rules", "dimensions", "dimensionValues", "instrumentDimensions"]) {
			if (!structKeyExists(arguments.cfg, key) || isNull(arguments.cfg[key]) || !isArray(arguments.cfg[key])) {
				err(arguments.r, "STRUCTURE", "Missing or invalid array '" & key & "'.", "$." & key);
			} else {
				var i = 0;
				for (var row in arguments.cfg[key]) {
					i++;
					if (!isStruct(row)) err(arguments.r, "STRUCTURE", "Entry is not an object.", "$." & key & "[" & (i - 1) & "]");
				}
			}
		}
		if (!has(arguments.cfg, "instrument") || !isStruct(arguments.cfg.instrument)) {
			err(arguments.r, "STRUCTURE", "Missing 'instrument' object.", "$.instrument");
		} else if (!has(arguments.cfg.instrument, "version") || !isStruct(arguments.cfg.instrument.version)) {
			err(arguments.r, "STRUCTURE", "Missing 'instrument.version' object.", "$.instrument.version");
		}
	}

	private void function checkInstrument(required struct r, required struct cfg) {
		var inst = arguments.cfg.instrument;
		requireText(arguments.r, inst, "code", "$.instrument.code", 60);
		requireText(arguments.r, inst, "name", "$.instrument.name", 200);
		requireText(arguments.r, inst.version, "versionLabel", "$.instrument.version.versionLabel", 100);
		if (has(inst.version, "status") && inst.version.status != "DRAFT") {
			err(arguments.r, "VERSION_STATUS_NOT_DRAFT", "Only DRAFT versions can be imported; the document declares status '" & inst.version.status & "'.", "$.instrument.version.status");
		}
	}

	private struct function checkUniqueness(required struct r, required struct cfg) {
		var cfg = arguments.cfg;
		var ids = {};
		ids["sectionIds"] = uniqueSet(arguments.r, cfg.sections, ["sectionId"], "sections", "sectionId");
		ids["sectionKeys"] = uniqueSet(arguments.r, cfg.sections, ["sectionKey"], "sections", "sectionKey");
		ids["itemIds"] = uniqueSet(arguments.r, cfg.items, ["itemId"], "items", "itemId");
		ids["itemKeys"] = uniqueSet(arguments.r, cfg.items, ["itemKey"], "items", "itemKey");
		ids["setIds"] = uniqueSet(arguments.r, cfg.responseSets, ["responseSetId"], "responseSets", "responseSetId");
		ids["setKeys"] = uniqueSet(arguments.r, cfg.responseSets, ["setKey"], "responseSets", "setKey");
		ids["optionIds"] = uniqueSet(arguments.r, cfg.responseOptions, ["optionId"], "responseOptions", "optionId");
		uniqueSet(arguments.r, cfg.responseOptions, ["responseSetId", "optionKey"], "responseOptions", "responseSetId|optionKey");
		uniqueSet(arguments.r, cfg.responseOptions, ["responseSetId", "storedCode"], "responseOptions", "responseSetId|storedCode");
		ids["ruleIds"] = uniqueSet(arguments.r, cfg.rules, ["ruleId"], "rules", "ruleId");
		ids["ruleKeys"] = uniqueSet(arguments.r, cfg.rules, ["ruleKey"], "rules", "ruleKey");
		ids["dimensionIds"] = uniqueSet(arguments.r, cfg.dimensions, ["dimensionId"], "dimensions", "dimensionId");
		ids["dimensionCodes"] = uniqueSet(arguments.r, cfg.dimensions, ["code"], "dimensions", "code");
		ids["valueIds"] = uniqueSet(arguments.r, cfg.dimensionValues, ["dimensionValueId"], "dimensionValues", "dimensionValueId");
		uniqueSet(arguments.r, cfg.dimensionValues, ["dimensionId", "valueCode"], "dimensionValues", "dimensionId|valueCode");
		ids["placementIds"] = uniqueSet(arguments.r, cfg.instrumentDimensions, ["instrumentDimensionId"], "instrumentDimensions", "instrumentDimensionId");
		uniqueSet(arguments.r, cfg.instrumentDimensions, ["dimensionId"], "instrumentDimensions", "dimensionId");
		return ids;
	}

	private void function checkReferences(required struct r, required struct cfg, required struct ids) {
		var cfg = arguments.cfg;
		var i = 0;
		for (var s in cfg.sections) {
			if (has(s, "parentSectionId") && !structKeyExists(arguments.ids.sectionIds, s.parentSectionId)) {
				err(arguments.r, "MISSING_REFERENCE", "Section '" & keyOf(s, "sectionKey") & "' references missing parent section '" & s.parentSectionId & "'.", "$.sections[" & i & "].parentSectionId");
			}
			i++;
		}
		i = 0;
		for (var it in cfg.items) {
			if (!has(it, "sectionId") || !structKeyExists(arguments.ids.sectionIds, it.sectionId)) {
				err(arguments.r, "MISSING_REFERENCE", "Item '" & keyOf(it, "itemKey") & "' references missing section '" & keyOf(it, "sectionId") & "'.", "$.items[" & i & "].sectionId");
			}
			if (has(it, "responseSetId") && !structKeyExists(arguments.ids.setIds, it.responseSetId)) {
				err(arguments.r, "MISSING_REFERENCE", "Item '" & keyOf(it, "itemKey") & "' references missing response set '" & it.responseSetId & "'.", "$.items[" & i & "].responseSetId");
			}
			i++;
		}
		i = 0;
		for (var op in cfg.responseOptions) {
			if (!has(op, "responseSetId") || !structKeyExists(arguments.ids.setIds, op.responseSetId)) {
				err(arguments.r, "MISSING_REFERENCE", "Response option '" & keyOf(op, "optionId") & "' references missing response set '" & keyOf(op, "responseSetId") & "'.", "$.responseOptions[" & i & "].responseSetId");
			}
			i++;
		}
		i = 0;
		for (var v in cfg.dimensionValues) {
			if (!has(v, "dimensionId") || !structKeyExists(arguments.ids.dimensionIds, v.dimensionId)) {
				err(arguments.r, "MISSING_REFERENCE", "Dimension value '" & keyOf(v, "dimensionValueId") & "' references missing dimension '" & keyOf(v, "dimensionId") & "'.", "$.dimensionValues[" & i & "].dimensionId");
			}
			i++;
		}
		i = 0;
		for (var p in cfg.instrumentDimensions) {
			if (!has(p, "dimensionId") || !structKeyExists(arguments.ids.dimensionIds, p.dimensionId)) {
				err(arguments.r, "MISSING_REFERENCE", "Placement '" & keyOf(p, "instrumentDimensionId") & "' references missing dimension '" & keyOf(p, "dimensionId") & "'.", "$.instrumentDimensions[" & i & "].dimensionId");
			}
			if (has(p, "sectionId") && !structKeyExists(arguments.ids.sectionIds, p.sectionId)) {
				err(arguments.r, "MISSING_REFERENCE", "Placement '" & keyOf(p, "instrumentDimensionId") & "' references missing section '" & p.sectionId & "'.", "$.instrumentDimensions[" & i & "].sectionId");
			}
			if (has(p, "ruleKey") && !structKeyExists(arguments.ids.ruleKeys, p.ruleKey)) {
				err(arguments.r, "MISSING_REFERENCE", "Placement '" & keyOf(p, "instrumentDimensionId") & "' references missing rule '" & p.ruleKey & "'.", "$.instrumentDimensions[" & i & "].ruleKey");
			}
			i++;
		}
	}

	private void function checkSections(required struct r, required struct cfg) {
		var i = 0;
		var siblingOrders = {};
		for (var s in arguments.cfg.sections) {
			var path = "$.sections[" & i & "]";
			requireText(arguments.r, s, "sectionKey", path & ".sectionKey", 100);
			requireText(arguments.r, s, "title", path & ".title", 300);
			checkOrder(arguments.r, s, path);
			checkSettings(arguments.r, s, path);
			var parentKey = has(s, "parentSectionId") ? toString(s.parentSectionId) : "";
			var orderKey = parentKey & "|" & (has(s, "displayOrder") ? toString(s.displayOrder) : "");
			if (structKeyExists(siblingOrders, orderKey)) {
				err(arguments.r, "DUPLICATE_ORDER", "Section '" & keyOf(s, "sectionKey") & "' repeats display order " & keyOf(s, "displayOrder") & " under the same parent.", path & ".displayOrder");
			}
			siblingOrders[orderKey] = true;
			i++;
		}
	}

	private void function checkResponseSets(required struct r, required struct cfg) {
		var cfg = arguments.cfg;
		var optionsBySet = {};
		var i = 0;
		var orders = {};
		for (var op in cfg.responseOptions) {
			var path = "$.responseOptions[" & i & "]";
			requireText(arguments.r, op, "optionKey", path & ".optionKey", 100);
			requireText(arguments.r, op, "storedCode", path & ".storedCode", 100);
			requireText(arguments.r, op, "label", path & ".label", 500);
			checkOrder(arguments.r, op, path);
			if (has(op, "numericScore") && !isNumeric(op.numericScore)) {
				err(arguments.r, "INVALID_SCORE", "Option '" & keyOf(op, "optionKey") & "' has a non-numeric score.", path & ".numericScore");
			}
			var setId = has(op, "responseSetId") ? toString(op.responseSetId) : "";
			if (!structKeyExists(optionsBySet, setId)) optionsBySet[setId] = [];
			arrayAppend(optionsBySet[setId], op);
			var orderKey = setId & "|" & keyOf(op, "displayOrder");
			if (structKeyExists(orders, orderKey)) {
				err(arguments.r, "DUPLICATE_ORDER", "Option '" & keyOf(op, "optionKey") & "' repeats display order " & keyOf(op, "displayOrder") & " within its response set.", path & ".displayOrder");
			}
			orders[orderKey] = true;
			i++;
		}
		var usedSets = {};
		for (var it in cfg.items) {
			if (has(it, "responseSetId")) usedSets[toString(it.responseSetId)] = true;
		}
		i = 0;
		for (var rs in cfg.responseSets) {
			var path = "$.responseSets[" & i & "]";
			requireText(arguments.r, rs, "setKey", path & ".setKey", 100);
			requireText(arguments.r, rs, "name", path & ".name", 200);
			if (!has(rs, "selectionMode") || !arrayContains(variables.SELECTION_MODES, rs.selectionMode)) {
				err(arguments.r, "INVALID_ENUM", "Response set '" & keyOf(rs, "setKey") & "' has an invalid selectionMode.", path & ".selectionMode");
			}
			var setId = keyOf(rs, "responseSetId");
			var opts = structKeyExists(optionsBySet, setId) ? optionsBySet[setId] : [];
			if (structKeyExists(usedSets, setId) && !arrayLen(opts)) {
				err(arguments.r, "RESPONSE_SET_EMPTY", "Response set '" & keyOf(rs, "setKey") & "' is used by an item but has no options.", path);
			}
			if (has(rs, "scoreEnabled") && isBoolean(rs.scoreEnabled) && rs.scoreEnabled) {
				for (var op in opts) {
					var isNa = has(op, "isNa") && isBoolean(op.isNa) && op.isNa;
					if (!isNa && (!has(op, "numericScore") || !isNumeric(op.numericScore))) {
						err(arguments.r, "SCORE_MISSING", "Scored response set '" & keyOf(rs, "setKey") & "' has option '" & keyOf(op, "optionKey") & "' without a numeric score.", path);
					}
				}
			}
			i++;
		}
	}

	private void function checkItems(required struct r, required struct cfg, required struct ids) {
		var i = 0;
		var orders = {};
		for (var it in arguments.cfg.items) {
			var path = "$.items[" & i & "]";
			requireText(arguments.r, it, "itemKey", path & ".itemKey", 100);
			requireText(arguments.r, it, "prompt", path & ".prompt", 0);
			requireText(arguments.r, it, "itemType", path & ".itemType", 40);
			if (has(it, "reportingKey") && len(toString(it.reportingKey)) > 100) {
				err(arguments.r, "VALUE_TOO_LONG", "Item '" & keyOf(it, "itemKey") & "' reportingKey exceeds 100 characters.", path & ".reportingKey");
			}
			checkOrder(arguments.r, it, path);
			checkSettings(arguments.r, it, path);
			var type = keyOf(it, "itemType");
			if (len(type) && !arrayContains(variables.ITEM_TYPES, type)) {
				err(arguments.r, "INVALID_ENUM", "Item '" & keyOf(it, "itemKey") & "' has unsupported itemType '" & type & "'.", path & ".itemType");
			}
			var isChoice = arrayContains(variables.CHOICE_TYPES, type);
			if (isChoice && !has(it, "responseSetId")) {
				err(arguments.r, "ITEM_RESPONSE_SET_REQUIRED", "Choice item '" & keyOf(it, "itemKey") & "' must reference a response set.", path & ".responseSetId");
			}
			if (!isChoice && has(it, "responseSetId")) {
				err(arguments.r, "ITEM_RESPONSE_SET_NOT_ALLOWED", "Item '" & keyOf(it, "itemKey") & "' of type " & type & " must not reference a response set.", path & ".responseSetId");
			}
			if (has(it, "required") && isBoolean(it.required) && it.required && !has(it, "responseSetId")) {
				err(arguments.r, "REQUIRED_ITEM_NO_RESPONSE_SET", "Required item '" & keyOf(it, "itemKey") & "' has no response set.", path & ".required");
			}
			var orderKey = keyOf(it, "sectionId") & "|" & keyOf(it, "displayOrder");
			if (structKeyExists(orders, orderKey)) {
				err(arguments.r, "DUPLICATE_ORDER", "Item '" & keyOf(it, "itemKey") & "' repeats display order " & keyOf(it, "displayOrder") & " within its section.", path & ".displayOrder");
			}
			orders[orderKey] = true;
			i++;
		}
	}

	private void function checkRules(required struct r, required struct cfg, required struct ids) {
		var i = 0;
		for (var rule in arguments.cfg.rules) {
			var path = "$.rules[" & i & "]";
			requireText(arguments.r, rule, "ruleKey", path & ".ruleKey", 100);
			var targetType = keyOf(rule, "targetType");
			if (!arrayContains(variables.TARGET_TYPES, targetType)) {
				err(arguments.r, "INVALID_ENUM", "Rule '" & keyOf(rule, "ruleKey") & "' has invalid targetType '" & targetType & "'.", path & ".targetType");
			} else {
				var targetOk = false;
				if (targetType == "SECTION") targetOk = has(rule, "targetId") && structKeyExists(arguments.ids.sectionIds, rule.targetId);
				else if (targetType == "ITEM") targetOk = has(rule, "targetId") && structKeyExists(arguments.ids.itemIds, rule.targetId);
				else targetOk = has(rule, "targetId") && structKeyExists(arguments.ids.dimensionIds, rule.targetId);
				if (!targetOk) {
					err(arguments.r, "MISSING_REFERENCE", "Rule '" & keyOf(rule, "ruleKey") & "' targets missing " & targetType & " '" & keyOf(rule, "targetId") & "'.", path & ".targetId");
				}
			}
			var effect = keyOf(rule, "effect");
			if (!arrayContains(variables.EFFECTS, effect)) {
				err(arguments.r, "INVALID_ENUM", "Rule '" & keyOf(rule, "ruleKey") & "' has invalid effect '" & effect & "'.", path & ".effect");
			} else if (!arrayContains(variables.SUPPORTED_EFFECTS, effect)) {
				err(arguments.r, "UNSUPPORTED_EFFECT", "Rule '" & keyOf(rule, "ruleKey") & "' uses effect '" & effect & "'; the current runtime supports SHOW only.", path & ".effect");
			}
			var sourceType = keyOf(rule, "sourceType");
			if (!arrayContains(variables.SOURCE_TYPES, sourceType)) {
				err(arguments.r, "INVALID_ENUM", "Rule '" & keyOf(rule, "ruleKey") & "' has invalid sourceType '" & sourceType & "'.", path & ".sourceType");
			} else if (!sourceExists(sourceType, keyOf(rule, "sourceId"), arguments.ids)) {
				err(arguments.r, "MISSING_REFERENCE", "Rule '" & keyOf(rule, "ruleKey") & "' has missing source " & sourceType & " '" & keyOf(rule, "sourceId") & "'.", path & ".sourceId");
			}
			if (!arrayContains(variables.OPERATORS, keyOf(rule, "operator"))) {
				err(arguments.r, "INVALID_ENUM", "Rule '" & keyOf(rule, "ruleKey") & "' has invalid operator '" & keyOf(rule, "operator") & "'.", path & ".operator");
			}
			if (has(rule, "conditionLogic") && !arrayContains(variables.LOGICS, rule.conditionLogic)) {
				err(arguments.r, "INVALID_ENUM", "Rule '" & keyOf(rule, "ruleKey") & "' has invalid conditionLogic.", path & ".conditionLogic");
			}
			checkConditions(arguments.r, rule, path, arguments.ids);
			i++;
		}
	}

	private void function checkConditions(required struct r, required struct rule, required string path, required struct ids) {
		var rule = arguments.rule;
		var text = has(rule, "conditionsJson") ? rule.conditionsJson : "";
		if (!isSimpleValue(text) || !len(trim(text)) || !isJSON(text)) {
			err(arguments.r, "INVALID_JSON", "Rule '" & keyOf(rule, "ruleKey") & "' has a conditionsJson document that is not valid JSON.", arguments.path & ".conditionsJson");
			return;
		}
		var doc = deserializeJSON(text);
		if (!isStruct(doc) || !has(doc, "logic") || !has(doc, "conditions") || !isArray(doc.conditions)) {
			err(arguments.r, "CONDITIONS_SHAPE", "Rule '" & keyOf(rule, "ruleKey") & "' conditionsJson must be an object with 'logic' and a 'conditions' array.", arguments.path & ".conditionsJson");
			return;
		}
		if (!arrayContains(variables.LOGICS, doc.logic)) {
			err(arguments.r, "CONDITIONS_SHAPE", "Rule '" & keyOf(rule, "ruleKey") & "' conditions logic must be AND or OR.", arguments.path & ".conditionsJson");
		}
		if (!arrayLen(doc.conditions)) {
			err(arguments.r, "CONDITIONS_SHAPE", "Rule '" & keyOf(rule, "ruleKey") & "' must have at least one condition.", arguments.path & ".conditionsJson");
			return;
		}
		var ci = 0;
		for (var cond in doc.conditions) {
			ci++;
			if (!isStruct(cond) || !has(cond, "sourceType") || !has(cond, "sourceKey") || !has(cond, "operator") || !structKeyExists(cond, "comparisonValue")) {
				err(arguments.r, "CONDITIONS_SHAPE", "Rule '" & keyOf(rule, "ruleKey") & "' condition " & ci & " must define sourceType, sourceKey, operator, and comparisonValue.", arguments.path & ".conditionsJson");
				continue;
			}
			if (!arrayContains(variables.SOURCE_TYPES, cond.sourceType) || !sourceExists(cond.sourceType, cond.sourceKey, arguments.ids)) {
				err(arguments.r, "MISSING_REFERENCE", "Rule '" & keyOf(rule, "ruleKey") & "' condition " & ci & " references missing source '" & keyOf(cond, "sourceType") & ":" & keyOf(cond, "sourceKey") & "'.", arguments.path & ".conditionsJson");
			}
			if (!arrayContains(variables.OPERATORS, cond.operator)) {
				err(arguments.r, "INVALID_ENUM", "Rule '" & keyOf(rule, "ruleKey") & "' condition " & ci & " has invalid operator '" & cond.operator & "'.", arguments.path & ".conditionsJson");
			}
			if ((cond.operator == "IN" || cond.operator == "NOT_IN") && !isArray(cond.comparisonValue)) {
				err(arguments.r, "CONDITIONS_SHAPE", "Rule '" & keyOf(rule, "ruleKey") & "' condition " & ci & " uses " & cond.operator & " and needs an array comparisonValue.", arguments.path & ".conditionsJson");
			}
		}
		// The flat authoring columns must agree with the single-condition document.
		if (arrayLen(doc.conditions) == 1 && isStruct(doc.conditions[1])) {
			var c1 = doc.conditions[1];
			var mismatch = false;
			if (has(rule, "conditionLogic") && rule.conditionLogic != doc.logic) mismatch = true;
			if (has(rule, "sourceType") && has(c1, "sourceType") && rule.sourceType != c1.sourceType) mismatch = true;
			if (has(rule, "sourceId") && has(c1, "sourceKey") && rule.sourceId != c1.sourceKey) mismatch = true;
			if (has(rule, "operator") && has(c1, "operator") && rule.operator != c1.operator) mismatch = true;
			if (has(rule, "comparisonValue") && structKeyExists(c1, "comparisonValue") && !isNull(c1.comparisonValue)) {
				var flat = toString(rule.comparisonValue);
				var docValue = isSimpleValue(c1.comparisonValue) ? toString(c1.comparisonValue) : serializeJSON(c1.comparisonValue);
				if (isArray(c1.comparisonValue)) {
					if (!isJSON(flat) || !isArray(deserializeJSON(flat)) || arrayToList(deserializeJSON(flat), chr(31)) != arrayToList(c1.comparisonValue, chr(31))) mismatch = true;
				} else if (flat != docValue) {
					mismatch = true;
				}
			}
			if (mismatch) {
				err(arguments.r, "CONDITION_MISMATCH", "Rule '" & keyOf(rule, "ruleKey") & "' flat condition fields disagree with conditionsJson.", arguments.path);
			}
		}
	}

	private boolean function sourceExists(required string sourceType, required string sourceKey, required struct ids) {
		if (arguments.sourceType == "ITEM") return structKeyExists(arguments.ids.itemKeys, arguments.sourceKey);
		if (arguments.sourceType == "DIMENSION") return structKeyExists(arguments.ids.dimensionCodes, arguments.sourceKey);
		return false;
	}

	private void function checkDimensions(required struct r, required struct cfg) {
		var i = 0;
		for (var d in arguments.cfg.dimensions) {
			var path = "$.dimensions[" & i & "]";
			requireText(arguments.r, d, "code", path & ".code", 100);
			requireText(arguments.r, d, "label", path & ".label", 200);
			if (!arrayContains(variables.DATA_TYPES, keyOf(d, "dataType"))) {
				err(arguments.r, "INVALID_ENUM", "Dimension '" & keyOf(d, "code") & "' has invalid dataType '" & keyOf(d, "dataType") & "'.", path & ".dataType");
			}
			checkSettings(arguments.r, d, path);
			i++;
		}
		i = 0;
		var orders = {};
		for (var v in arguments.cfg.dimensionValues) {
			var path = "$.dimensionValues[" & i & "]";
			requireText(arguments.r, v, "valueCode", path & ".valueCode", 100);
			requireText(arguments.r, v, "label", path & ".label", 300);
			checkOrder(arguments.r, v, path);
			var orderKey = keyOf(v, "dimensionId") & "|" & keyOf(v, "displayOrder");
			if (structKeyExists(orders, orderKey)) {
				err(arguments.r, "DUPLICATE_ORDER", "Dimension value '" & keyOf(v, "valueCode") & "' repeats display order " & keyOf(v, "displayOrder") & " within its dimension.", path & ".displayOrder");
			}
			orders[orderKey] = true;
			for (var dateKey in ["effectiveStart", "effectiveEnd"]) {
				if (has(v, dateKey) && !isValidInstant(v[dateKey])) {
					err(arguments.r, "INVALID_INSTANT", "Dimension value '" & keyOf(v, "valueCode") & "' has an invalid " & dateKey & " (expected ISO-8601 UTC instant).", path & "." & dateKey);
				}
			}
			i++;
		}
	}

	private void function checkPlacements(required struct r, required struct cfg) {
		var i = 0;
		var orders = {};
		for (var p in arguments.cfg.instrumentDimensions) {
			var path = "$.instrumentDimensions[" & i & "]";
			checkOrder(arguments.r, p, path);
			checkSettings(arguments.r, p, path);
			if (has(p, "labelOverride") && len(toString(p.labelOverride)) > 200) {
				err(arguments.r, "VALUE_TOO_LONG", "Placement '" & keyOf(p, "instrumentDimensionId") & "' labelOverride exceeds 200 characters.", path & ".labelOverride");
			}
			// Placement order is authored per section (the JSON contract); the importer derives the
			// version-unique column value required by UX_instrument_dimension_order.
			var orderKey = keyOf(p, "sectionId") & "|" & keyOf(p, "displayOrder");
			if (structKeyExists(orders, orderKey)) {
				err(arguments.r, "DUPLICATE_ORDER", "Placement '" & keyOf(p, "instrumentDimensionId") & "' repeats display order " & keyOf(p, "displayOrder") & " within its section.", path & ".displayOrder");
			}
			orders[orderKey] = true;
			i++;
		}
	}

	private void function checkRetiredContent(required struct r, required struct cfg) {
		var text = lCase(serializeJSON({ "sections": arguments.cfg.sections, "items": arguments.cfg.items }));
		for (var needle in variables.RETIRED_TEXT) {
			if (find(needle, text)) {
				err(arguments.r, "RETIRED_CONTENT_PRESENT", "Retired School Improvement Plan hierarchy text ('" & needle & "') appears in active sections or items.", "$");
			}
		}
	}

	private void function collectPlaceholders(required struct r, required struct cfg) {
		var expected = {};
		for (var it in arguments.cfg.items) {
			if (has(it, "reviewStatus") && it.reviewStatus == variables.PLACEHOLDER_REVIEW_STATUS) {
				var entry = {
					"itemKey": keyOf(it, "itemKey"),
					"sectionId": keyOf(it, "sectionId"),
					"sourceLocation": keyOf(it, "sourceLocation"),
					"reviewStatus": it.reviewStatus
				};
				arrayAppend(arguments.r.placeholders, entry);
				expected[keyOf(it, "itemKey")] = true;
				warn(arguments.r, "PLACEHOLDER_CONTENT", "Item '" & keyOf(it, "itemKey") & "' is placeholder content awaiting approved wording (" & keyOf(it, "sourceLocation") & ").", "$.items[" & keyOf(it, "itemKey") & "]");
			}
		}
		if (has(arguments.cfg, "contentReview") && isStruct(arguments.cfg.contentReview) && has(arguments.cfg.contentReview, "unresolvedPlaceholders") && isArray(arguments.cfg.contentReview.unresolvedPlaceholders)) {
			var declared = {};
			for (var ph in arguments.cfg.contentReview.unresolvedPlaceholders) {
				if (isStruct(ph) && has(ph, "itemKey")) declared[ph.itemKey] = true;
			}
			var same = structCount(declared) == structCount(expected);
			if (same) {
				for (var k in structKeyArray(expected)) { if (!structKeyExists(declared, k)) { same = false; break; } }
			}
			if (!same) {
				warn(arguments.r, "CONTENT_REVIEW_MISMATCH", "contentReview.unresolvedPlaceholders does not match the items marked '" & variables.PLACEHOLDER_REVIEW_STATUS & "'.", "$.contentReview.unresolvedPlaceholders");
			}
		}
	}

	// ---- primitives -----------------------------------------------------------------------

	private struct function uniqueSet(required struct r, required array rows, required array keys, required string collection, required string label) {
		var seen = {};
		var seenLower = {};
		var i = 0;
		for (var row in arguments.rows) {
			var parts = [];
			var blank = false;
			for (var k in arguments.keys) {
				if (!has(row, k) || !len(trim(toString(row[k])))) blank = true;
				arrayAppend(parts, has(row, k) ? toString(row[k]) : "");
			}
			var composite = arrayToList(parts, "|");
			if (blank) {
				err(arguments.r, "BLANK_KEY", arguments.collection & " entry has a blank " & arguments.label & ".", "$." & arguments.collection & "[" & i & "]");
			} else if (structKeyExists(seen, composite)) {
				err(arguments.r, "DUPLICATE_KEY", arguments.collection & " contains duplicate " & arguments.label & " '" & composite & "'.", "$." & arguments.collection & "[" & i & "]");
			} else if (structKeyExists(seenLower, lCase(composite))) {
				err(arguments.r, "KEY_CASE_COLLISION", arguments.collection & " contains keys that differ only by letter case: '" & composite & "'.", "$." & arguments.collection & "[" & i & "]");
			} else {
				seen[composite] = true;
				seenLower[lCase(composite)] = true;
			}
			i++;
		}
		return seen;
	}

	private void function requireText(required struct r, required any row, required string key, required string path, required numeric maxLength) {
		if (!has(arguments.row, arguments.key) || !isSimpleValue(arguments.row[arguments.key]) || !len(trim(toString(arguments.row[arguments.key])))) {
			err(arguments.r, "BLANK_VALUE", "'" & arguments.key & "' is required.", arguments.path);
			return;
		}
		if (arguments.maxLength > 0 && len(toString(arguments.row[arguments.key])) > arguments.maxLength) {
			err(arguments.r, "VALUE_TOO_LONG", "'" & arguments.key & "' exceeds " & arguments.maxLength & " characters.", arguments.path);
		}
	}

	private void function checkOrder(required struct r, required any row, required string path) {
		if (!has(arguments.row, "displayOrder") || !isNumeric(arguments.row.displayOrder) || int(arguments.row.displayOrder) != arguments.row.displayOrder || arguments.row.displayOrder < 0 || arguments.row.displayOrder > variables.MAX_ORDER) {
			err(arguments.r, "INVALID_ORDER", "displayOrder must be an integer between 0 and " & variables.MAX_ORDER & ".", arguments.path & ".displayOrder");
		}
	}

	private void function checkSettings(required struct r, required any row, required string path) {
		if (structKeyExists(arguments.row, "settings") && !isNull(arguments.row.settings) && !isStruct(arguments.row.settings)) {
			err(arguments.r, "SETTINGS_NOT_OBJECT", "settings must be a JSON object.", arguments.path & ".settings");
		}
	}

	private boolean function isValidInstant(required any value) {
		if (!isSimpleValue(arguments.value)) return false;
		try {
			createObject("java", "java.time.Instant").parse(javaCast("string", trim(arguments.value)));
			return true;
		} catch (any e) {
			return false;
		}
	}

	private boolean function has(required any src, required string key) {
		return isStruct(arguments.src) && structKeyExists(arguments.src, arguments.key) && !isNull(arguments.src[arguments.key]);
	}

	private string function keyOf(required any row, required string key) {
		if (has(arguments.row, arguments.key) && isSimpleValue(arguments.row[arguments.key])) return toString(arguments.row[arguments.key]);
		return "";
	}

	private void function err(required struct r, required string code, required string message, required string path) {
		arrayAppend(arguments.r.errors, { "code": arguments.code, "message": arguments.message, "path": arguments.path });
	}

	private void function warn(required struct r, required string code, required string message, required string path) {
		arrayAppend(arguments.r.warnings, { "code": arguments.code, "message": arguments.message, "path": arguments.path });
	}
}
