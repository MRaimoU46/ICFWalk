/**
 * Validates an authoring document (config/instrument-config.json shape) before it touches the
 * database. Reports every problem it can find as { code, message, path } so content owners get
 * a complete list, then the importer refuses the document when any error exists.
 *
 * Errors block import. Warnings (placeholder content, review mismatches) are returned with the
 * import result and, per docs/OPEN_DECISIONS.md, only block publication when configured.
 *
 * ONE SEMANTIC RULE SET, AND THIS IS NOT IT.
 *
 * This component used to run a full second copy of the instrument's semantics -- its own item-type
 * list, its own rule and dimension and placement checks, its own retired-content guard -- and then
 * ALSO delegate to DefinitionValidator. Import was therefore judged by two rule sets and publish by
 * one. Two rule sets over the same subject do not stay equal: they drift, and every place they
 * disagree is a document that imports and then cannot be published, or worse.
 *
 * So what is left here is only what cannot be asked of anything but an inbound document:
 *
 *   - that it parses, and has the arrays and objects the normalizer needs (checkStructure);
 *   - that it declares DRAFT, and names an instrument and a version (checkInstrument);
 *   - that its *authoring ids* are unique -- sectionId, itemId, responseSetId, optionId, ruleId,
 *     dimensionId, dimensionValueId, instrumentDimensionId (checkAuthoringIds). These exist only in
 *     the document; normalization resolves them away into keys, and a persisted version has none;
 *   - that every authoring id it references resolves to a declared one (checkReferences), reported
 *     against the id the author actually wrote rather than the key it would have become;
 *   - that conditionsJson is parseable text (checkConditionsParseable). In the document this is a
 *     JSON *string*; by the time anything else sees it, it is a parsed document;
 *   - which items the content review left unresolved (collectPlaceholders), which is a property of
 *     the source workbook and not of the instrument.
 *
 * Everything else -- references between keys, allowed types, hierarchy, response-set requirements,
 * option ordering, rule semantics, dimension and value rules, placements, the runtime renderability
 * contract, retired content -- belongs to DefinitionValidator, over the normalized definitions.
 * checkDefinitions below normalizes this document once and hands it to exactly the component
 * InstrumentPublishService runs against the locked version's snapshot and stored rows. An import
 * that passes and a publish that passes are therefore the same predicate, evaluated over the same
 * shape, and neither can drift into accepting what the other refuses.
 */
component output="false" {

	public InstrumentConfigValidator function init(required any errors, required any configNormalizer, required any definitionValidator) {
		variables.errors = arguments.errors;
		// The shared JSON type helper: a declared status has to BE a string, not merely read as one.
		variables.types = new icfwalk.core.JsonTypes();
		variables.normalizer = arguments.configNormalizer;
		variables.definitionValidator = arguments.definitionValidator;
		// The one definition of "unresolved placeholder", shared with the compiler and the renderer.
		variables.PLACEHOLDER_REVIEW_STATUS = arguments.definitionValidator.placeholderReviewStatus();
		variables.COLLECTIONS = arguments.definitionValidator.collections();
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
		var ids = collectAuthoringIds(r, cfg);
		checkReferences(r, cfg, ids);
		checkConditionsParseable(r, cfg);
		collectPlaceholders(r, cfg);
		checkDefinitions(r, cfg);
		r.valid = arrayLen(r.errors) == 0;
		return r;
	}

	/**
	 * Runs the shared definition rules on the normalized form of this document, so that what import
	 * accepts is exactly what publish will accept later. Normalization is only reached once the
	 * structural checks above have passed, so every array exists and holds objects; a document that
	 * still defeats it is reported rather than allowed through on an exception.
	 */
	private void function checkDefinitions(required struct r, required struct cfg) {
		var definitions = "";
		try {
			definitions = variables.normalizer.fromConfig(arguments.cfg).definitions;
		} catch (any e) {
			err(arguments.r, "DEFINITIONS_NOT_VALIDATABLE", "The document could not be normalized for definition validation: " & e.message, "$");
			return;
		}
		var result = variables.definitionValidator.validate(definitions, { "path": "$.definitions" });
		for (var issue in result.errors) arrayAppend(arguments.r.errors, issue);
	}

	// ---------------------------------------------------------------------------------------

	private void function checkStructure(required struct r, required struct cfg) {
		for (var key in variables.COLLECTIONS) {
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

	/**
	 * The instrument and version identity the document declares. Only an import can be refused for
	 * declaring the wrong status: a persisted version's status is a lifecycle fact, not a claim in
	 * a document, and is checked under the version's row lock instead.
	 *
	 * THE DECLARATION IS REQUIRED. This used to refuse a non-DRAFT status only when the member was
	 * present, so a document that simply omitted it was imported -- silence read as consent, on the
	 * one field that says which of three lifecycle states the author believes they are writing.
	 * docs/DATA_CONTRACT.md says an inbound document declares DRAFT, so it must, and three distinct
	 * failures are reported distinctly at the same stable path:
	 *
	 *   VERSION_STATUS_REQUIRED   absent, or present and null
	 *   VERSION_STATUS_INVALID    present but not a JSON string (a number, a boolean, an array...)
	 *   VERSION_STATUS_NOT_DRAFT  a string that is not exactly DRAFT
	 *
	 * The comparison is CASE-SENSITIVE, because the contract's enumeration is: SQL Server's
	 * CK_instrument_version_status constrains the column to the three upper-case literals, and
	 * CFML's own `!=` is case-insensitive, so `draft` used to be accepted as a DRAFT declaration
	 * and then stored as something the schema never named. compare() is the only equality here that
	 * matches the contract being enforced.
	 */
	private void function checkInstrument(required struct r, required struct cfg) {
		var inst = arguments.cfg.instrument;
		requireText(arguments.r, inst, "code", "$.instrument.code", 60);
		requireText(arguments.r, inst, "name", "$.instrument.name", 200);
		requireText(arguments.r, inst.version, "versionLabel", "$.instrument.version.versionLabel", 100);
		checkDeclaredStatus(arguments.r, inst.version);
	}

	private void function checkDeclaredStatus(required struct r, required struct version) {
		var path = "$.instrument.version.status";
		if (!structKeyExists(arguments.version, "status") || isNull(arguments.version.status)) {
			err(arguments.r, "VERSION_STATUS_REQUIRED", "The document must declare instrument.version.status, and it must be 'DRAFT'.", path);
			return;
		}
		var declared = arguments.version.status;
		if (!variables.types.isJsonString(declared)) {
			err(arguments.r, "VERSION_STATUS_INVALID", "instrument.version.status is " & variables.types.describe(declared) & "; it must be the string 'DRAFT'.", path);
			return;
		}
		if (compare(declared, "DRAFT") != 0) {
			err(arguments.r, "VERSION_STATUS_NOT_DRAFT", "Only DRAFT versions can be imported; the document declares status '" & declared & "'.", path);
		}
	}

	/**
	 * Authoring ids: unique within the document, and collected so references can be resolved
	 * against them. Logical *keys* are not checked here -- they survive normalization, so
	 * DefinitionValidator owns their uniqueness, and duplicating the rule here is what this
	 * refactoring removed. The key sets are still collected, silently, because a rule's source is
	 * written as a key even in the authoring document and checkReferences has to resolve it.
	 */
	private struct function collectAuthoringIds(required struct r, required struct cfg) {
		var cfg = arguments.cfg;
		var ids = {};
		ids["sectionIds"] = uniqueSet(arguments.r, cfg.sections, ["sectionId"], "sections", "sectionId");
		ids["itemIds"] = uniqueSet(arguments.r, cfg.items, ["itemId"], "items", "itemId");
		ids["setIds"] = uniqueSet(arguments.r, cfg.responseSets, ["responseSetId"], "responseSets", "responseSetId");
		ids["optionIds"] = uniqueSet(arguments.r, cfg.responseOptions, ["optionId"], "responseOptions", "optionId");
		ids["ruleIds"] = uniqueSet(arguments.r, cfg.rules, ["ruleId"], "rules", "ruleId");
		ids["dimensionIds"] = uniqueSet(arguments.r, cfg.dimensions, ["dimensionId"], "dimensions", "dimensionId");
		ids["valueIds"] = uniqueSet(arguments.r, cfg.dimensionValues, ["dimensionValueId"], "dimensionValues", "dimensionValueId");
		ids["placementIds"] = uniqueSet(arguments.r, cfg.instrumentDimensions, ["instrumentDimensionId"], "instrumentDimensions", "instrumentDimensionId");
		ids["itemKeys"] = keySet(cfg.items, "itemKey");
		ids["ruleKeys"] = keySet(cfg.rules, "ruleKey");
		ids["dimensionCodes"] = keySet(cfg.dimensions, "code");
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
		for (var rule in cfg.rules) {
			var targetType = keyOf(rule, "targetType");
			var targetSet = "";
			if (targetType == "SECTION") targetSet = "sectionIds";
			else if (targetType == "ITEM") targetSet = "itemIds";
			else if (targetType == "DIMENSION") targetSet = "dimensionIds";
			if (len(targetSet) && (!has(rule, "targetId") || !structKeyExists(arguments.ids[targetSet], rule.targetId))) {
				err(arguments.r, "MISSING_REFERENCE", "Rule '" & keyOf(rule, "ruleKey") & "' targets missing " & targetType & " '" & keyOf(rule, "targetId") & "'.", "$.rules[" & i & "].targetId");
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

	/**
	 * conditionsJson is a JSON *string* in the authoring document and a parsed document everywhere
	 * else, so "does it parse" is the one question about it that only an import can ask. What the
	 * parsed document must then contain -- logic, at least one condition, resolvable sources,
	 * operators, and agreement with the rule's flat columns -- is DefinitionValidator's, over the
	 * normalized rule.
	 */
	private void function checkConditionsParseable(required struct r, required struct cfg) {
		var i = 0;
		for (var rule in arguments.cfg.rules) {
			var text = has(rule, "conditionsJson") ? rule.conditionsJson : "";
			if (!isSimpleValue(text) || !len(trim(text)) || !isJSON(text)) {
				err(arguments.r, "INVALID_JSON", "Rule '" & keyOf(rule, "ruleKey") & "' has a conditionsJson document that is not valid JSON.", "$.rules[" & i & "].conditionsJson");
			}
			i++;
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

	/** Collects a logical-key lookup without reporting on it; DefinitionValidator owns those rules. */
	private struct function keySet(required array rows, required string key) {
		var out = {};
		for (var row in arguments.rows) {
			if (has(row, arguments.key) && isSimpleValue(row[arguments.key]) && len(trim(toString(row[arguments.key])))) {
				out[toString(row[arguments.key])] = true;
			}
		}
		return out;
	}

	private struct function uniqueSet(required struct r, required array rows, required array keys, required string collection, required string label) {
		var seen = {};
		var seenLower = {};
		var i = 0;
		for (var row in arguments.rows) {
			var parts = [];
			var blank = false;
			for (var k in arguments.keys) {
				if (!has(row, k) || !isSimpleValue(row[k]) || !len(trim(toString(row[k])))) blank = true;
				arrayAppend(parts, (has(row, k) && isSimpleValue(row[k])) ? toString(row[k]) : "");
			}
			var composite = arrayToList(parts, "|");
			if (blank) {
				err(arguments.r, "BLANK_KEY", arguments.collection & " entry has a blank " & arguments.label & ".", "$." & arguments.collection & "[" & i & "]");
			} else if (structKeyExists(seen, composite)) {
				err(arguments.r, "DUPLICATE_KEY", arguments.collection & " contains duplicate " & arguments.label & " '" & composite & "'.", "$." & arguments.collection & "[" & i & "]");
			} else {
				seen[composite] = true;
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
