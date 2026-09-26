/**
 * Server-side validation of a submitted walk working state against the walk's pinned instrument
 * version. Nothing from the browser is trusted: every dimension code, item key, option code, and
 * value code must exist in the pinned render model (and therefore in the version's definition
 * rows), and every value must fit the declared data/item type. Unknown keys, foreign option codes
 * (SAVE-07), display items, and mistyped values are rejected with a specific code; all issues are
 * collected and returned in details.issues.
 *
 * JSON primitive types are checked, never coerced: a field declared as text must arrive as a JSON
 * string, a number as a JSON number, a boolean as a JSON boolean. CFML would happily read the JSON
 * number 4 as the string "4" and match a stored option code, so every check goes through the
 * underlying Java type (jsonString/jsonNumber/jsonBoolean) rather than isSimpleValue.
 *
 * Response state is derived data: the server owns it. A payload that carries a "state" field for a
 * response is rejected with CLIENT_STATE_NOT_ACCEPTED rather than quietly ignored, so a client can
 * never believe it set one.
 *
 * Output is a clean state in the working-state shape (docs/DATA_CONTRACT.md) with resolved GUIDs
 * attached out of band (resolved.dimensions[code].valueId, resolved.responses[itemKey].optionId).
 */
component output="false" {

	variables.MAX_DIMENSION_TEXT = 1000;
	variables.MAX_RESPONSE_TEXT = 20000;
	variables.OTHER_CODE = "other";
	variables.EMAIL_KEYS = ["includedPartKeys", "drafted", "to", "subject", "body"];

	public WalkPayloadValidator function init(required any errors, required any canonicalJson) {
		variables.errors = arguments.errors;
		variables.json = arguments.canonicalJson;
		variables.cache = {};
		return this;
	}

	/**
	 * Model facts needed for validation and persistence: items by key, placements by dimension
	 * code (in authored order), and each item's section. Cached by cacheKey (version id + checksum)
	 * when given; the model itself is never mutated because it is served to browsers as is.
	 */
	public struct function modelIndex(required struct model, string cacheKey = "") {
		if (len(arguments.cacheKey) && structKeyExists(variables.cache, arguments.cacheKey)) return variables.cache[arguments.cacheKey];
		var idx = { "items": {}, "itemOrder": [], "placements": {}, "placementOrder": [], "sectionOfItem": {} };
		walkSection(arguments.model.root, idx);
		if (len(arguments.cacheKey)) variables.cache[arguments.cacheKey] = idx;
		return idx;
	}

	/**
	 * Validates { dimensions, responses } and returns { state, resolved }. Throws ICFWalk.Validation
	 * with the first issue's code and every issue in details.issues.
	 */
	public struct function validate(required struct model, required struct definitionIndex, required any payload) {
		var issues = [];
		var idx = modelIndex(arguments.model, indexKey(arguments.definitionIndex));
		var state = { "dimensions": {}, "responses": {} };
		var resolved = { "dimensions": {}, "responses": {} };
		if (!isStruct(arguments.payload)) {
			issue(issues, "INVALID_STATE", "state", "The walk state must be a JSON object.");
			raise(issues);
		}
		var dims = structKeyExists(arguments.payload, "dimensions") ? arguments.payload.dimensions : {};
		var responses = structKeyExists(arguments.payload, "responses") ? arguments.payload.responses : {};
		if (!isStruct(dims)) { issue(issues, "INVALID_STATE", "dimensions", "dimensions must be an object keyed by dimension code."); dims = {}; }
		if (!isStruct(responses)) { issue(issues, "INVALID_STATE", "responses", "responses must be an object keyed by item key."); responses = {}; }

		for (var code in structKeyArray(dims)) {
			if (!structKeyExists(idx.placements, code) || !structKeyExists(arguments.model.dimensions, code) || !structKeyExists(arguments.definitionIndex.dimensions, code)) {
				issue(issues, "UNKNOWN_DIMENSION", "dimensions." & safeKey(code), "Dimension is not part of this walk's instrument version.");
				continue;
			}
			var placement = idx.placements[code];
			var dim = arguments.model.dimensions[code];
			var raw = dims[code];
			if (!structKeyExists(local, "raw")) continue;
			if (!isStruct(raw)) { issue(issues, "INVALID_DIMENSION_VALUE", "dimensions." & code, "Dimension value must be an object."); continue; }
			var clean = {};
			var res = {};
			var ok = true;
			for (var k in structKeyArray(raw)) {
				var v = raw[k];
				if (!structKeyExists(local, "v") || (jsonString(v) && !len(v))) continue;
				if (!isSimpleValue(v) || isInstanceOf(v, "java.util.Date")) { issue(issues, "INVALID_DIMENSION_VALUE", "dimensions." & code & "." & safeKey(k), "Value must be a string, number, or boolean."); ok = false; continue; }
				switch (k) {
					case "selectedValueCode":
						if (dim.dataType != "LIST") { issue(issues, "INVALID_DIMENSION_VALUE", "dimensions." & code & ".selectedValueCode", "Dimension does not accept a list value."); ok = false; break; }
						if (!jsonString(v)) { issue(issues, "INVALID_DIMENSION_VALUE", "dimensions." & code & ".selectedValueCode", "Value code must be a JSON string."); ok = false; break; }
						var dimId = arguments.definitionIndex.dimensions[code];
						var valueId = findValueId(dim, arguments.definitionIndex.values[dimId], toString(v));
						if (!len(valueId)) { issue(issues, "INVALID_DIMENSION_VALUE", "dimensions." & code & ".selectedValueCode", "Value code is not defined for this dimension."); ok = false; break; }
						clean["selectedValueCode"] = toString(v);
						res["valueId"] = valueId;
						break;
					case "otherText":
						if (dim.dataType != "LIST" || !dim.allowOther) { issue(issues, "INVALID_DIMENSION_VALUE", "dimensions." & code & ".otherText", "Dimension does not accept free text."); ok = false; break; }
						if (!jsonString(v)) { issue(issues, "INVALID_DIMENSION_VALUE", "dimensions." & code & ".otherText", "Text must be a JSON string."); ok = false; break; }
						if (len(toString(v)) > variables.MAX_DIMENSION_TEXT) { issue(issues, "VALUE_TOO_LONG", "dimensions." & code & ".otherText", "Text exceeds " & variables.MAX_DIMENSION_TEXT & " characters."); ok = false; break; }
						clean["otherText"] = toString(v);
						break;
					case "textValue":
						if (dim.dataType != "TEXT") { issue(issues, "INVALID_DIMENSION_VALUE", "dimensions." & code & ".textValue", "Dimension does not accept text."); ok = false; break; }
						if (!jsonString(v)) { issue(issues, "INVALID_DIMENSION_VALUE", "dimensions." & code & ".textValue", "Text must be a JSON string."); ok = false; break; }
						if (len(toString(v)) > variables.MAX_DIMENSION_TEXT) { issue(issues, "VALUE_TOO_LONG", "dimensions." & code & ".textValue", "Text exceeds " & variables.MAX_DIMENSION_TEXT & " characters."); ok = false; break; }
						clean["textValue"] = toString(v);
						break;
					case "dateValue":
						if (dim.dataType != "DATE") { issue(issues, "INVALID_DIMENSION_VALUE", "dimensions." & code & ".dateValue", "Dimension does not accept a date."); ok = false; break; }
						if (!jsonString(v)) { issue(issues, "INVALID_DATE", "dimensions." & code & ".dateValue", "Date must be a JSON string in YYYY-MM-DD form."); ok = false; break; }
						var iso = normalizeIsoDate(v);
						if (!len(iso)) { issue(issues, "INVALID_DATE", "dimensions." & code & ".dateValue", "Date must be a valid calendar date in YYYY-MM-DD form."); ok = false; break; }
						clean["dateValue"] = iso;
						break;
					case "numberValue":
						if (dim.dataType != "NUMBER") { issue(issues, "INVALID_DIMENSION_VALUE", "dimensions." & code & ".numberValue", "Dimension does not accept a number."); ok = false; break; }
						if (!jsonNumber(v)) { issue(issues, "INVALID_DIMENSION_VALUE", "dimensions." & code & ".numberValue", "Value must be a JSON number."); ok = false; break; }
						clean["numberValue"] = val(v);
						break;
					case "booleanValue":
						if (dim.dataType != "BOOLEAN") { issue(issues, "INVALID_DIMENSION_VALUE", "dimensions." & code & ".booleanValue", "Dimension does not accept a boolean."); ok = false; break; }
						if (!jsonBoolean(v)) { issue(issues, "INVALID_DIMENSION_VALUE", "dimensions." & code & ".booleanValue", "Value must be the JSON literal true or false."); ok = false; break; }
						clean["booleanValue"] = v ? true : false;
						break;
					default:
						issue(issues, "INVALID_DIMENSION_VALUE", "dimensions." & code & "." & safeKey(k), "Unknown value field.");
						ok = false;
				}
			}
			if (!ok) continue;
			// Documented "Other" mapping: free text is stored only as the qualifier of the selected Other
			// value (selected_value_id = Other, text_value = the text). The browser keeps stale otherText
			// in memory after switching to a listed value, so it is dropped here rather than rejected.
			if (structKeyExists(clean, "otherText") && (!structKeyExists(clean, "selectedValueCode") || lCase(clean.selectedValueCode) != variables.OTHER_CODE)) {
				structDelete(clean, "otherText");
			}
			if (!structIsEmpty(clean)) { state.dimensions[code] = clean; resolved.dimensions[code] = res; }
		}

		for (var key in structKeyArray(responses)) {
			if (!structKeyExists(idx.items, key) || !structKeyExists(arguments.definitionIndex.items, key)) {
				issue(issues, "UNKNOWN_ITEM", "responses." & safeKey(key), "Item is not part of this walk's instrument version.");
				continue;
			}
			var item = idx.items[key];
			var raw = responses[key];
			if (!structKeyExists(local, "raw")) continue;
			if (!isStruct(raw)) { issue(issues, "INVALID_RESPONSE_VALUE", "responses." & key, "Response must be an object."); continue; }
			if (item.layout == "display-heading" || item.layout == "display-guidance") {
				if (!structIsEmpty(raw)) issue(issues, "INVALID_RESPONSE_VALUE", "responses." & key, "Display items do not accept responses.");
				continue;
			}
			var hasSet = structKeyExists(item, "responseSet") && isStruct(item.responseSet);
			var clean = {};
			var res = {};
			var ok = true;
			for (var k in structKeyArray(raw)) {
				var v = raw[k];
				if (compare(k, "state") == 0) {
					// Response state is derived server-side from the pinned instrument; a client may
					// never assert it (docs/DATA_CONTRACT.md "Response states").
					issue(issues, "CLIENT_STATE_NOT_ACCEPTED", "responses." & key & ".state", "Response state is derived by the server and is not accepted from a client.");
					ok = false;
					continue;
				}
				if (!structKeyExists(local, "v") || (jsonString(v) && !len(v))) continue;
				if (!jsonString(v)) { issue(issues, "INVALID_RESPONSE_VALUE", "responses." & key & "." & safeKey(k), "Value must be a JSON string."); ok = false; continue; }
				switch (k) {
					case "storedCode":
						if (!hasSet) { issue(issues, "INVALID_RESPONSE_VALUE", "responses." & key & ".storedCode", "Item does not use a response set."); ok = false; break; }
						var setId = arguments.definitionIndex.items[key].responseSetId;
						var optionId = findOptionId(item.responseSet, structKeyExists(arguments.definitionIndex.options, setId) ? arguments.definitionIndex.options[setId] : {}, toString(v));
						if (!len(optionId)) { issue(issues, "INVALID_OPTION", "responses." & key & ".storedCode", "Option is not part of this item's response set."); ok = false; break; }
						clean["storedCode"] = toString(v);
						res["optionId"] = optionId;
						break;
					case "textValue":
						if (hasSet) { issue(issues, "INVALID_RESPONSE_VALUE", "responses." & key & ".textValue", "Choice items do not accept text."); ok = false; break; }
						if (len(toString(v)) > variables.MAX_RESPONSE_TEXT) { issue(issues, "VALUE_TOO_LONG", "responses." & key & ".textValue", "Text exceeds " & variables.MAX_RESPONSE_TEXT & " characters."); ok = false; break; }
						if (item.itemType == "EMAIL_DRAFT_JSON") {
							var canonical = validateEmailDraft(toString(v));
							if (!len(canonical)) { issue(issues, "INVALID_EMAIL_DRAFT", "responses." & key & ".textValue", "Email draft state does not match the application schema."); ok = false; break; }
							clean["textValue"] = canonical;
						} else {
							clean["textValue"] = toString(v);
						}
						break;
					default:
						issue(issues, "INVALID_RESPONSE_VALUE", "responses." & key & "." & safeKey(k), "Unknown value field.");
						ok = false;
				}
			}
			if (!ok) continue;
			if (!structIsEmpty(clean)) { state.responses[key] = clean; resolved.responses[key] = res; }
		}

		if (arrayLen(issues)) raise(issues);
		return { "state": state, "resolved": resolved };
	}

	/** Canonical JSON of a valid email-draft document, or "" when invalid. */
	public string function validateEmailDraft(required string text) {
		if (!isJSON(arguments.text)) return "";
		var doc = deserializeJSON(arguments.text);
		if (!isStruct(doc)) return "";
		for (var k in structKeyArray(doc)) if (!arrayContainsNoCase(variables.EMAIL_KEYS, k)) return "";
		var out = { "includedPartKeys": [], "drafted": false, "to": "", "subject": "", "body": "" };
		if (structKeyExists(doc, "includedPartKeys")) {
			if (!isArray(doc.includedPartKeys)) return "";
			for (var p in doc.includedPartKeys) { if (!isSimpleValue(p)) return ""; arrayAppend(out.includedPartKeys, toString(p)); }
		}
		if (structKeyExists(doc, "drafted")) { if (!isBoolean(doc.drafted)) return ""; out.drafted = doc.drafted ? true : false; }
		for (var k in ["to", "subject", "body"]) {
			if (structKeyExists(doc, k)) { if (!isSimpleValue(doc[k])) return ""; out[k] = toString(doc[k]); }
		}
		return variables.json.serialize(out);
	}

	// ---- internals ---------------------------------------------------------------------------

	private void function walkSection(required struct node, required struct idx) {
		for (var p in arguments.node.placements) { arguments.idx.placements[p.dimensionCode] = p; arrayAppend(arguments.idx.placementOrder, p.dimensionCode); }
		for (var it in arguments.node.items) { arguments.idx.items[it.itemKey] = it; arrayAppend(arguments.idx.itemOrder, it.itemKey); arguments.idx.sectionOfItem[it.itemKey] = arguments.node.sectionKey; }
		for (var child in arguments.node.children) walkSection(child, arguments.idx);
	}

	private string function findValueId(required struct dim, required struct valueIds, required string code) {
		for (var v in arguments.dim.values) {
			if (compare(v.valueCode, arguments.code) == 0 && structKeyExists(arguments.valueIds, v.valueCode)) return arguments.valueIds[v.valueCode];
		}
		return "";
	}

	private string function findOptionId(required struct set, required struct optionIds, required string code) {
		for (var o in arguments.set.options) {
			if (compare(o.storedCode, arguments.code) == 0 && structKeyExists(arguments.optionIds, o.storedCode)) return arguments.optionIds[o.storedCode];
		}
		return "";
	}

	private string function normalizeIsoDate(required string value) {
		var v = trim(arguments.value);
		if (!reFind("^[0-9]{4}-[0-9]{2}-[0-9]{2}$", v)) return "";
		var y = val(listGetAt(v, 1, "-"));
		var m = val(listGetAt(v, 2, "-"));
		var d = val(listGetAt(v, 3, "-"));
		if (y < 1900 || y > 2200 || m < 1 || m > 12 || d < 1 || d > daysInMonth(createDate(y, m, 1))) return "";
		return v;
	}

	public string function indexKey(required struct definitionIndex) {
		return (structKeyExists(arguments.definitionIndex, "versionId") ? arguments.definitionIndex.versionId : "") & ":" & (structKeyExists(arguments.definitionIndex, "checksum") ? arguments.definitionIndex.checksum : "");
	}

	/** JSON primitive type tests against the underlying Java type (no CFML coercion). */
	private boolean function jsonString(required any value) { return isInstanceOf(arguments.value, "java.lang.String"); }
	private boolean function jsonNumber(required any value) { return isInstanceOf(arguments.value, "java.lang.Number"); }
	private boolean function jsonBoolean(required any value) { return isInstanceOf(arguments.value, "java.lang.Boolean"); }

	private string function safeKey(required string key) {
		return left(reReplace(arguments.key, "[^A-Za-z0-9_.-]", "?", "all"), 60);
	}

	private void function issue(required array issues, required string code, required string path, required string message) {
		arrayAppend(arguments.issues, { "code": arguments.code, "path": arguments.path, "message": arguments.message });
	}

	private void function raise(required array issues) {
		variables.errors.validation("Walk state failed validation: " & arguments.issues[1].message, arguments.issues[1].code, { "issues": arguments.issues });
	}
}
