/**
 * The authoritative semantic rules for a set of normalized instrument definitions, and for the
 * snapshot envelope that carries them.
 *
 * WHY THIS COMPONENT EXISTS. Normalized definitions are the one representation both sides of the
 * instrument lifecycle actually hold: the importer produces them from the authoring document, the
 * compiler serializes them into the stored snapshot, and DefinitionRepository.loadNormalizedDefinitions
 * reads them back out of SQL Server. Validating them here, once, is what makes "a DRAFT that
 * imported is publishable" and "a version that publishes is renderable" the same statement.
 *
 * Before this existed, publishing proved only self-consistency -- snapshot hashes to its checksum,
 * snapshot definitions equal the SQL definitions. Self-consistency is not validity: the same invalid
 * content can sit in both places and agree perfectly, and a publish that only compares them freezes
 * it. The rules below are the ones InstrumentConfigValidator applies to an authoring document,
 * restated over the representation that survives the import, so publish can apply them to the
 * locked persisted version without pretending it is a new import.
 *
 * WHAT IS *NOT* HERE. Rules that only mean something for an inbound document -- that it declares
 * DRAFT, that its authoring ids are unique and resolvable, that conditionsJson parses as a string --
 * stay in InstrumentConfigValidator. They cannot be checked against a persisted version, because
 * the persisted version has no authoring ids and no conditionsJson text; it has keys and a parsed
 * conditions document. Keeping them apart is what stops publish validation from either skipping
 * real rules or inventing ones the stored form cannot satisfy.
 *
 * Errors are { code, message, path } with the same codes the import path already returns, so a
 * refusal reads the same wherever it came from. Paths are rooted at the caller's `path` option
 * ("$.definitions" by default) because the same definitions are validated in three places: inside
 * an import document, inside a stored snapshot, and as read back from SQL Server.
 */
component output="false" {

	variables.COLLECTIONS = ["sections", "items", "responseSets", "responseOptions", "rules", "dimensions", "dimensionValues", "instrumentDimensions"];
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
	variables.SNAPSHOT_FORMAT = "icfwalk-instrument-snapshot/1";
	variables.RETIRED_TEXT = ["school improvement (sip)", "sip grade"];

	public DefinitionValidator function init() {
		return this;
	}

	public string function snapshotFormat() { return variables.SNAPSHOT_FORMAT; }

	/**
	 * Validates one set of normalized definitions.
	 *
	 * options.path  root JSON path for reported errors (default "$.definitions")
	 *
	 * @return { valid: boolean, errors: [ { code, message, path } ] }
	 */
	public struct function validate(required any definitions, struct options = {}) {
		var root = structKeyExists(arguments.options, "path") ? arguments.options.path : "$.definitions";
		var r = { "valid": true, "errors": [], "path": root };
		if (!isStruct(arguments.definitions)) {
			err(r, "DEFINITIONS_SHAPE", "definitions must be a JSON object.", root);
			r.valid = false;
			return r;
		}
		var d = arguments.definitions;
		if (!checkCollections(r, d)) { r.valid = false; return r; }

		var keys = collectKeys(r, d);
		checkSections(r, d, keys);
		checkResponseSets(r, d, keys);
		checkItems(r, d, keys);
		checkRules(r, d, keys);
		checkDimensions(r, d, keys);
		checkPlacements(r, d, keys);
		checkRetiredContent(r, d);
		r.valid = arrayLen(r.errors) == 0;
		return r;
	}

	/**
	 * Validates the stored snapshot envelope: the members the compiler writes and the render model
	 * and runtime read back. The definitions inside it are validated separately by validate(), so
	 * a caller can report envelope and content problems under their own paths.
	 *
	 * options.path       root path (default "$")
	 * options.versionLabel / options.instrumentCode
	 *                    when supplied, the identity the snapshot claims must equal the identity of
	 *                    the row it is stored on. A snapshot that names another version is not this
	 *                    version's snapshot, however well it hashes.
	 */
	public struct function validateEnvelope(required any snapshot, struct options = {}) {
		var root = structKeyExists(arguments.options, "path") ? arguments.options.path : "$";
		var r = { "valid": true, "errors": [], "path": root };
		if (!isStruct(arguments.snapshot)) {
			err(r, "SNAPSHOT_SHAPE", "The stored snapshot is not a JSON object.", root);
			r.valid = false;
			return r;
		}
		var s = arguments.snapshot;
		if (!has(s, "snapshotFormat") || !isSimpleValue(s.snapshotFormat) || s.snapshotFormat != variables.SNAPSHOT_FORMAT) {
			err(r, "SNAPSHOT_FORMAT_UNSUPPORTED", "The stored snapshot declares format '" & (has(s, "snapshotFormat") && isSimpleValue(s.snapshotFormat) ? s.snapshotFormat : "") & "'; this runtime reads " & variables.SNAPSHOT_FORMAT & ".", root & ".snapshotFormat");
		}
		if (!has(s, "definitions") || !isStruct(s.definitions)) {
			err(r, "SNAPSHOT_SHAPE", "The stored snapshot has no definitions object.", root & ".definitions");
		}
		if (!has(s, "instrument") || !isStruct(s.instrument)) {
			err(r, "SNAPSHOT_SHAPE", "The stored snapshot has no instrument object.", root & ".instrument");
		} else if (!has(s.instrument, "code") || !isSimpleValue(s.instrument.code) || !len(trim(toString(s.instrument.code)))) {
			err(r, "BLANK_VALUE", "The stored snapshot's instrument has no code.", root & ".instrument.code");
		} else if (structKeyExists(arguments.options, "instrumentCode") && len(trim(arguments.options.instrumentCode)) && toString(s.instrument.code) != arguments.options.instrumentCode) {
			err(r, "SNAPSHOT_IDENTITY_MISMATCH", "The stored snapshot names instrument '" & toString(s.instrument.code) & "' but is stored on a version of instrument '" & arguments.options.instrumentCode & "'.", root & ".instrument.code");
		}
		if (!has(s, "version") || !isStruct(s.version)) {
			err(r, "SNAPSHOT_SHAPE", "The stored snapshot has no version object.", root & ".version");
		} else if (!has(s.version, "versionLabel") || !isSimpleValue(s.version.versionLabel) || !len(trim(toString(s.version.versionLabel)))) {
			err(r, "BLANK_VALUE", "The stored snapshot's version has no versionLabel.", root & ".version.versionLabel");
		} else if (structKeyExists(arguments.options, "versionLabel") && len(trim(arguments.options.versionLabel)) && toString(s.version.versionLabel) != arguments.options.versionLabel) {
			err(r, "SNAPSHOT_IDENTITY_MISMATCH", "The stored snapshot names version '" & toString(s.version.versionLabel) & "' but is stored on version '" & arguments.options.versionLabel & "'.", root & ".version.versionLabel");
		}
		// counts is what every reader trusts instead of walking the arrays; a counts block that
		// disagrees with the definitions beside it is a snapshot that lies about itself.
		if (has(s, "definitions") && isStruct(s.definitions) && has(s, "counts")) {
			if (!isStruct(s.counts)) {
				err(r, "SNAPSHOT_SHAPE", "The stored snapshot's counts is not an object.", root & ".counts");
			} else {
				for (var name in variables.COLLECTIONS) {
					if (!has(s.definitions, name) || !isArray(s.definitions[name])) continue;
					if (!has(s.counts, name)) continue;
					if (!isNumeric(s.counts[name]) || s.counts[name] != arrayLen(s.definitions[name])) {
						err(r, "SNAPSHOT_COUNTS_MISMATCH", "The stored snapshot's counts." & name & " is " & (isSimpleValue(s.counts[name]) ? toString(s.counts[name]) : "not a number") & " but it carries " & arrayLen(s.definitions[name]) & ".", root & ".counts." & name);
					}
				}
			}
		}
		r.valid = arrayLen(r.errors) == 0;
		return r;
	}

	// ---- collections -----------------------------------------------------------------------

	private boolean function checkCollections(required struct r, required struct d) {
		var ok = true;
		for (var name in variables.COLLECTIONS) {
			if (!has(arguments.d, name) || !isArray(arguments.d[name])) {
				err(arguments.r, "DEFINITIONS_SHAPE", "Missing or invalid definitions array '" & name & "'.", path(arguments.r, name));
				ok = false;
				continue;
			}
			var i = 0;
			for (var row in arguments.d[name]) {
				if (!isStruct(row)) {
					err(arguments.r, "DEFINITIONS_SHAPE", "Entry is not an object.", path(arguments.r, name) & "[" & i & "]");
					ok = false;
				}
				i++;
			}
		}
		if (ok && !arrayLen(arguments.d.sections)) {
			err(arguments.r, "DEFINITIONS_EMPTY", "An instrument version must define at least one section.", path(arguments.r, "sections"));
		}
		if (ok && !arrayLen(arguments.d.items)) {
			err(arguments.r, "DEFINITIONS_EMPTY", "An instrument version must define at least one item.", path(arguments.r, "items"));
		}
		return ok;
	}

	private struct function collectKeys(required struct r, required struct d) {
		var k = {};
		k["sectionKeys"] = uniqueSet(arguments.r, arguments.d.sections, ["sectionKey"], "sections", "sectionKey");
		k["itemKeys"] = uniqueSet(arguments.r, arguments.d.items, ["itemKey"], "items", "itemKey");
		k["setKeys"] = uniqueSet(arguments.r, arguments.d.responseSets, ["setKey"], "responseSets", "setKey");
		uniqueSet(arguments.r, arguments.d.responseOptions, ["setKey", "optionKey"], "responseOptions", "setKey|optionKey");
		uniqueSet(arguments.r, arguments.d.responseOptions, ["setKey", "storedCode"], "responseOptions", "setKey|storedCode");
		k["ruleKeys"] = uniqueSet(arguments.r, arguments.d.rules, ["ruleKey"], "rules", "ruleKey");
		k["dimensionCodes"] = uniqueSet(arguments.r, arguments.d.dimensions, ["code"], "dimensions", "code");
		uniqueSet(arguments.r, arguments.d.dimensionValues, ["dimensionCode", "valueCode"], "dimensionValues", "dimensionCode|valueCode");
		uniqueSet(arguments.r, arguments.d.instrumentDimensions, ["dimensionCode"], "instrumentDimensions", "dimensionCode");
		return k;
	}

	// ---- sections --------------------------------------------------------------------------

	private void function checkSections(required struct r, required struct d, required struct keys) {
		var i = 0;
		var siblingOrders = {};
		var parentOf = {};
		for (var s in arguments.d.sections) {
			var p = path(arguments.r, "sections") & "[" & i & "]";
			requireText(arguments.r, s, "sectionKey", p & ".sectionKey", 100);
			requireText(arguments.r, s, "title", p & ".title", 300);
			checkOrder(arguments.r, s, p);
			checkSettings(arguments.r, s, p);
			var parentKey = keyOf(s, "parentSectionKey");
			if (len(parentKey)) {
				if (!structKeyExists(arguments.keys.sectionKeys, parentKey)) {
					err(arguments.r, "MISSING_REFERENCE", "Section '" & keyOf(s, "sectionKey") & "' references missing parent section '" & parentKey & "'.", p & ".parentSectionKey");
				} else if (parentKey == keyOf(s, "sectionKey")) {
					err(arguments.r, "SECTION_HIERARCHY_INVALID", "Section '" & keyOf(s, "sectionKey") & "' is its own parent.", p & ".parentSectionKey");
				}
			}
			if (len(keyOf(s, "sectionKey"))) parentOf[keyOf(s, "sectionKey")] = parentKey;
			var orderKey = parentKey & "|" & keyOf(s, "displayOrder");
			if (structKeyExists(siblingOrders, orderKey)) {
				err(arguments.r, "DUPLICATE_ORDER", "Section '" & keyOf(s, "sectionKey") & "' repeats display order " & keyOf(s, "displayOrder") & " under the same parent.", p & ".displayOrder");
			}
			siblingOrders[orderKey] = true;
			i++;
		}
		checkNoSectionCycles(arguments.r, parentOf);
	}

	/**
	 * A parent chain that loops renders as nothing and reports as nothing: the tree walk simply
	 * never reaches those sections. The authoring document cannot express it (parents are declared
	 * by id and the writer only ever nests), but a persisted version can hold it, so the rule is
	 * checked here rather than assumed.
	 */
	private void function checkNoSectionCycles(required struct r, required struct parentOf) {
		var reported = {};
		for (var startKey in structKeyArray(arguments.parentOf)) {
			var seen = {};
			var current = startKey;
			var guard = 0;
			while (len(current) && structKeyExists(arguments.parentOf, current) && guard <= structCount(arguments.parentOf)) {
				if (structKeyExists(seen, current)) {
					if (!structKeyExists(reported, current)) {
						reported[current] = true;
						err(arguments.r, "SECTION_HIERARCHY_INVALID", "Section '" & current & "' is part of a parent cycle.", path(arguments.r, "sections"));
					}
					break;
				}
				seen[current] = true;
				current = arguments.parentOf[current];
				guard++;
			}
		}
	}

	// ---- response sets and options -----------------------------------------------------------

	private void function checkResponseSets(required struct r, required struct d, required struct keys) {
		var optionsBySet = {};
		var orders = {};
		var i = 0;
		for (var op in arguments.d.responseOptions) {
			var p = path(arguments.r, "responseOptions") & "[" & i & "]";
			requireText(arguments.r, op, "optionKey", p & ".optionKey", 100);
			requireText(arguments.r, op, "storedCode", p & ".storedCode", 100);
			requireText(arguments.r, op, "label", p & ".label", 500);
			checkOrder(arguments.r, op, p);
			if (has(op, "numericScore") && !isNumeric(op.numericScore)) {
				err(arguments.r, "INVALID_SCORE", "Option '" & keyOf(op, "optionKey") & "' has a non-numeric score.", p & ".numericScore");
			}
			var setKey = keyOf(op, "setKey");
			if (!len(setKey) || !structKeyExists(arguments.keys.setKeys, setKey)) {
				err(arguments.r, "MISSING_REFERENCE", "Response option '" & keyOf(op, "optionKey") & "' references missing response set '" & setKey & "'.", p & ".setKey");
			}
			if (!structKeyExists(optionsBySet, setKey)) optionsBySet[setKey] = [];
			arrayAppend(optionsBySet[setKey], op);
			var orderKey = setKey & "|" & keyOf(op, "displayOrder");
			if (structKeyExists(orders, orderKey)) {
				err(arguments.r, "DUPLICATE_ORDER", "Option '" & keyOf(op, "optionKey") & "' repeats display order " & keyOf(op, "displayOrder") & " within its response set.", p & ".displayOrder");
			}
			orders[orderKey] = true;
			i++;
		}

		var usedSets = {};
		for (var it in arguments.d.items) {
			var rsk = keyOf(it, "responseSetKey");
			if (len(rsk)) usedSets[rsk] = true;
		}
		i = 0;
		for (var rs in arguments.d.responseSets) {
			var p = path(arguments.r, "responseSets") & "[" & i & "]";
			requireText(arguments.r, rs, "setKey", p & ".setKey", 100);
			requireText(arguments.r, rs, "name", p & ".name", 200);
			if (!has(rs, "selectionMode") || !isSimpleValue(rs.selectionMode) || !arrayContains(variables.SELECTION_MODES, rs.selectionMode)) {
				err(arguments.r, "INVALID_ENUM", "Response set '" & keyOf(rs, "setKey") & "' has an invalid selectionMode.", p & ".selectionMode");
			}
			var setKey = keyOf(rs, "setKey");
			var opts = structKeyExists(optionsBySet, setKey) ? optionsBySet[setKey] : [];
			if (structKeyExists(usedSets, setKey) && !arrayLen(opts)) {
				err(arguments.r, "RESPONSE_SET_EMPTY", "Response set '" & setKey & "' is used by an item but has no options.", p);
			}
			if (has(rs, "scoreEnabled") && isBoolean(rs.scoreEnabled) && rs.scoreEnabled) {
				for (var op in opts) {
					var isNa = has(op, "isNa") && isBoolean(op.isNa) && op.isNa;
					if (!isNa && (!has(op, "numericScore") || !isNumeric(op.numericScore))) {
						err(arguments.r, "SCORE_MISSING", "Scored response set '" & setKey & "' has option '" & keyOf(op, "optionKey") & "' without a numeric score.", p);
					}
				}
			}
			i++;
		}
	}

	// ---- items -----------------------------------------------------------------------------

	private void function checkItems(required struct r, required struct d, required struct keys) {
		var i = 0;
		var orders = {};
		for (var it in arguments.d.items) {
			var p = path(arguments.r, "items") & "[" & i & "]";
			requireText(arguments.r, it, "itemKey", p & ".itemKey", 100);
			requireText(arguments.r, it, "prompt", p & ".prompt", 0);
			requireText(arguments.r, it, "itemType", p & ".itemType", 40);
			if (has(it, "reportingKey") && isSimpleValue(it.reportingKey) && len(toString(it.reportingKey)) > 100) {
				err(arguments.r, "VALUE_TOO_LONG", "Item '" & keyOf(it, "itemKey") & "' reportingKey exceeds 100 characters.", p & ".reportingKey");
			}
			checkOrder(arguments.r, it, p);
			checkSettings(arguments.r, it, p);
			var sectionKey = keyOf(it, "sectionKey");
			if (!len(sectionKey) || !structKeyExists(arguments.keys.sectionKeys, sectionKey)) {
				err(arguments.r, "MISSING_REFERENCE", "Item '" & keyOf(it, "itemKey") & "' references missing section '" & sectionKey & "'.", p & ".sectionKey");
			}
			var type = keyOf(it, "itemType");
			if (len(type) && !arrayContains(variables.ITEM_TYPES, type)) {
				err(arguments.r, "INVALID_ENUM", "Item '" & keyOf(it, "itemKey") & "' has unsupported itemType '" & type & "'.", p & ".itemType");
			}
			var setKey = keyOf(it, "responseSetKey");
			var hasSet = len(setKey) > 0;
			if (hasSet && !structKeyExists(arguments.keys.setKeys, setKey)) {
				err(arguments.r, "MISSING_REFERENCE", "Item '" & keyOf(it, "itemKey") & "' references missing response set '" & setKey & "'.", p & ".responseSetKey");
			}
			var isChoice = arrayContains(variables.CHOICE_TYPES, type);
			if (isChoice && !hasSet) {
				err(arguments.r, "ITEM_RESPONSE_SET_REQUIRED", "Choice item '" & keyOf(it, "itemKey") & "' must reference a response set.", p & ".responseSetKey");
			}
			if (!isChoice && hasSet) {
				err(arguments.r, "ITEM_RESPONSE_SET_NOT_ALLOWED", "Item '" & keyOf(it, "itemKey") & "' of type " & type & " must not reference a response set.", p & ".responseSetKey");
			}
			if (has(it, "required") && isBoolean(it.required) && it.required && !hasSet) {
				err(arguments.r, "REQUIRED_ITEM_NO_RESPONSE_SET", "Required item '" & keyOf(it, "itemKey") & "' has no response set.", p & ".required");
			}
			var orderKey = sectionKey & "|" & keyOf(it, "displayOrder");
			if (structKeyExists(orders, orderKey)) {
				err(arguments.r, "DUPLICATE_ORDER", "Item '" & keyOf(it, "itemKey") & "' repeats display order " & keyOf(it, "displayOrder") & " within its section.", p & ".displayOrder");
			}
			orders[orderKey] = true;
			i++;
		}
	}

	// ---- rules -----------------------------------------------------------------------------

	private void function checkRules(required struct r, required struct d, required struct keys) {
		var i = 0;
		for (var rule in arguments.d.rules) {
			var p = path(arguments.r, "rules") & "[" & i & "]";
			requireText(arguments.r, rule, "ruleKey", p & ".ruleKey", 100);
			var targetType = keyOf(rule, "targetType");
			if (!arrayContains(variables.TARGET_TYPES, targetType)) {
				err(arguments.r, "INVALID_ENUM", "Rule '" & keyOf(rule, "ruleKey") & "' has invalid targetType '" & targetType & "'.", p & ".targetType");
			} else {
				var targetKey = keyOf(rule, "targetKey");
				var targetOk = false;
				if (len(targetKey)) {
					if (targetType == "SECTION") targetOk = structKeyExists(arguments.keys.sectionKeys, targetKey);
					else if (targetType == "ITEM") targetOk = structKeyExists(arguments.keys.itemKeys, targetKey);
					else targetOk = structKeyExists(arguments.keys.dimensionCodes, targetKey);
				}
				if (!targetOk) {
					err(arguments.r, "MISSING_REFERENCE", "Rule '" & keyOf(rule, "ruleKey") & "' targets missing " & targetType & " '" & targetKey & "'.", p & ".targetKey");
				}
			}
			var effect = keyOf(rule, "effect");
			if (!arrayContains(variables.EFFECTS, effect)) {
				err(arguments.r, "INVALID_ENUM", "Rule '" & keyOf(rule, "ruleKey") & "' has invalid effect '" & effect & "'.", p & ".effect");
			} else if (!arrayContains(variables.SUPPORTED_EFFECTS, effect)) {
				err(arguments.r, "UNSUPPORTED_EFFECT", "Rule '" & keyOf(rule, "ruleKey") & "' uses effect '" & effect & "'; the current runtime supports SHOW only.", p & ".effect");
			}
			var sourceType = keyOf(rule, "sourceType");
			if (!arrayContains(variables.SOURCE_TYPES, sourceType)) {
				err(arguments.r, "INVALID_ENUM", "Rule '" & keyOf(rule, "ruleKey") & "' has invalid sourceType '" & sourceType & "'.", p & ".sourceType");
			} else if (!sourceExists(sourceType, keyOf(rule, "sourceKey"), arguments.keys)) {
				err(arguments.r, "MISSING_REFERENCE", "Rule '" & keyOf(rule, "ruleKey") & "' has missing source " & sourceType & " '" & keyOf(rule, "sourceKey") & "'.", p & ".sourceKey");
			}
			if (!arrayContains(variables.OPERATORS, keyOf(rule, "operator"))) {
				err(arguments.r, "INVALID_ENUM", "Rule '" & keyOf(rule, "ruleKey") & "' has invalid operator '" & keyOf(rule, "operator") & "'.", p & ".operator");
			}
			if (has(rule, "conditionLogic") && isSimpleValue(rule.conditionLogic) && !arrayContains(variables.LOGICS, rule.conditionLogic)) {
				err(arguments.r, "INVALID_ENUM", "Rule '" & keyOf(rule, "ruleKey") & "' has invalid conditionLogic.", p & ".conditionLogic");
			}
			checkConditions(arguments.r, rule, p, arguments.keys);
			i++;
		}
	}

	/**
	 * The conditions document as the runtime reads it: { logic, conditions: [...] }. In an authoring
	 * document this arrives as a JSON string and the import validator proves it parses; by the time
	 * it is normalized (and stored), it is a parsed structure, so this checks the structure itself.
	 */
	private void function checkConditions(required struct r, required struct rule, required string p, required struct keys) {
		var rule = arguments.rule;
		if (!has(rule, "conditions")) {
			err(arguments.r, "CONDITIONS_SHAPE", "Rule '" & keyOf(rule, "ruleKey") & "' has no conditions document.", arguments.p & ".conditions");
			return;
		}
		var doc = rule.conditions;
		if (!isStruct(doc) || !has(doc, "logic") || !has(doc, "conditions") || !isArray(doc.conditions)) {
			err(arguments.r, "CONDITIONS_SHAPE", "Rule '" & keyOf(rule, "ruleKey") & "' conditions must be an object with 'logic' and a 'conditions' array.", arguments.p & ".conditions");
			return;
		}
		if (!isSimpleValue(doc.logic) || !arrayContains(variables.LOGICS, doc.logic)) {
			err(arguments.r, "CONDITIONS_SHAPE", "Rule '" & keyOf(rule, "ruleKey") & "' conditions logic must be AND or OR.", arguments.p & ".conditions");
		}
		if (!arrayLen(doc.conditions)) {
			err(arguments.r, "CONDITIONS_SHAPE", "Rule '" & keyOf(rule, "ruleKey") & "' must have at least one condition.", arguments.p & ".conditions");
			return;
		}
		var ci = 0;
		for (var cond in doc.conditions) {
			ci++;
			if (!isStruct(cond) || !has(cond, "sourceType") || !has(cond, "sourceKey") || !has(cond, "operator") || !structKeyExists(cond, "comparisonValue")) {
				err(arguments.r, "CONDITIONS_SHAPE", "Rule '" & keyOf(rule, "ruleKey") & "' condition " & ci & " must define sourceType, sourceKey, operator, and comparisonValue.", arguments.p & ".conditions");
				continue;
			}
			if (!isSimpleValue(cond.sourceType) || !arrayContains(variables.SOURCE_TYPES, cond.sourceType) || !isSimpleValue(cond.sourceKey) || !sourceExists(cond.sourceType, toString(cond.sourceKey), arguments.keys)) {
				err(arguments.r, "MISSING_REFERENCE", "Rule '" & keyOf(rule, "ruleKey") & "' condition " & ci & " references missing source '" & keyOf(cond, "sourceType") & ":" & keyOf(cond, "sourceKey") & "'.", arguments.p & ".conditions");
			}
			if (!isSimpleValue(cond.operator) || !arrayContains(variables.OPERATORS, cond.operator)) {
				err(arguments.r, "INVALID_ENUM", "Rule '" & keyOf(rule, "ruleKey") & "' condition " & ci & " has invalid operator '" & keyOf(cond, "operator") & "'.", arguments.p & ".conditions");
			} else if ((cond.operator == "IN" || cond.operator == "NOT_IN") && !isArray(cond.comparisonValue)) {
				err(arguments.r, "CONDITIONS_SHAPE", "Rule '" & keyOf(rule, "ruleKey") & "' condition " & ci & " uses " & cond.operator & " and needs an array comparisonValue.", arguments.p & ".conditions");
			}
		}
		// The flat authoring columns must still agree with the single-condition document: the
		// runtime evaluates the document, reporting and compare read the flat fields.
		if (arrayLen(doc.conditions) == 1 && isStruct(doc.conditions[1])) {
			var c1 = doc.conditions[1];
			var mismatch = false;
			if (has(rule, "conditionLogic") && isSimpleValue(rule.conditionLogic) && isSimpleValue(doc.logic) && rule.conditionLogic != doc.logic) mismatch = true;
			if (has(rule, "sourceType") && has(c1, "sourceType") && isSimpleValue(c1.sourceType) && keyOf(rule, "sourceType") != toString(c1.sourceType)) mismatch = true;
			if (has(rule, "sourceKey") && has(c1, "sourceKey") && isSimpleValue(c1.sourceKey) && keyOf(rule, "sourceKey") != toString(c1.sourceKey)) mismatch = true;
			if (has(rule, "operator") && has(c1, "operator") && isSimpleValue(c1.operator) && keyOf(rule, "operator") != toString(c1.operator)) mismatch = true;
			if (has(rule, "comparisonValue") && structKeyExists(c1, "comparisonValue") && !isNull(c1.comparisonValue)) {
				var flat = rule.comparisonValue;
				if (isArray(c1.comparisonValue)) {
					if (!isArray(flat)) {
						var flatText = isSimpleValue(flat) ? toString(flat) : "";
						if (!len(flatText) || !isJSON(flatText) || !isArray(deserializeJSON(flatText)) || arrayToList(deserializeJSON(flatText), chr(31)) != arrayToList(c1.comparisonValue, chr(31))) mismatch = true;
					} else if (arrayToList(flat, chr(31)) != arrayToList(c1.comparisonValue, chr(31))) {
						mismatch = true;
					}
				} else if (isSimpleValue(flat) && isSimpleValue(c1.comparisonValue)) {
					if (toString(flat) != toString(c1.comparisonValue)) mismatch = true;
				} else if (serializeJSON(flat) != serializeJSON(c1.comparisonValue)) {
					mismatch = true;
				}
			}
			if (mismatch) {
				err(arguments.r, "CONDITION_MISMATCH", "Rule '" & keyOf(rule, "ruleKey") & "' flat condition fields disagree with its conditions document.", arguments.p);
			}
		}
	}

	private boolean function sourceExists(required string sourceType, required string sourceKey, required struct keys) {
		if (!len(arguments.sourceKey)) return false;
		if (arguments.sourceType == "ITEM") return structKeyExists(arguments.keys.itemKeys, arguments.sourceKey);
		if (arguments.sourceType == "DIMENSION") return structKeyExists(arguments.keys.dimensionCodes, arguments.sourceKey);
		return false;
	}

	// ---- dimensions and values ---------------------------------------------------------------

	private void function checkDimensions(required struct r, required struct d, required struct keys) {
		var i = 0;
		for (var dim in arguments.d.dimensions) {
			var p = path(arguments.r, "dimensions") & "[" & i & "]";
			requireText(arguments.r, dim, "code", p & ".code", 100);
			requireText(arguments.r, dim, "label", p & ".label", 200);
			if (!arrayContains(variables.DATA_TYPES, keyOf(dim, "dataType"))) {
				err(arguments.r, "INVALID_ENUM", "Dimension '" & keyOf(dim, "code") & "' has invalid dataType '" & keyOf(dim, "dataType") & "'.", p & ".dataType");
			}
			checkSettings(arguments.r, dim, p);
			i++;
		}
		i = 0;
		var orders = {};
		for (var v in arguments.d.dimensionValues) {
			var p = path(arguments.r, "dimensionValues") & "[" & i & "]";
			requireText(arguments.r, v, "valueCode", p & ".valueCode", 100);
			requireText(arguments.r, v, "label", p & ".label", 300);
			checkOrder(arguments.r, v, p);
			var dimensionCode = keyOf(v, "dimensionCode");
			if (!len(dimensionCode) || !structKeyExists(arguments.keys.dimensionCodes, dimensionCode)) {
				err(arguments.r, "MISSING_REFERENCE", "Dimension value '" & keyOf(v, "valueCode") & "' references missing dimension '" & dimensionCode & "'.", p & ".dimensionCode");
			}
			var orderKey = dimensionCode & "|" & keyOf(v, "displayOrder");
			if (structKeyExists(orders, orderKey)) {
				err(arguments.r, "DUPLICATE_ORDER", "Dimension value '" & keyOf(v, "valueCode") & "' repeats display order " & keyOf(v, "displayOrder") & " within its dimension.", p & ".displayOrder");
			}
			orders[orderKey] = true;
			for (var dateKey in ["effectiveStart", "effectiveEnd"]) {
				if (has(v, dateKey) && !isValidInstant(v[dateKey])) {
					err(arguments.r, "INVALID_INSTANT", "Dimension value '" & keyOf(v, "valueCode") & "' has an invalid " & dateKey & " (expected ISO-8601 UTC instant).", p & "." & dateKey);
				}
			}
			i++;
		}
	}

	private void function checkPlacements(required struct r, required struct d, required struct keys) {
		var i = 0;
		var orders = {};
		for (var p in arguments.d.instrumentDimensions) {
			var pa = path(arguments.r, "instrumentDimensions") & "[" & i & "]";
			checkOrder(arguments.r, p, pa);
			checkSettings(arguments.r, p, pa);
			var dimensionCode = keyOf(p, "dimensionCode");
			if (!len(dimensionCode) || !structKeyExists(arguments.keys.dimensionCodes, dimensionCode)) {
				err(arguments.r, "MISSING_REFERENCE", "Placement references missing dimension '" & dimensionCode & "'.", pa & ".dimensionCode");
			}
			var sectionKey = keyOf(p, "sectionKey");
			if (len(sectionKey) && !structKeyExists(arguments.keys.sectionKeys, sectionKey)) {
				err(arguments.r, "MISSING_REFERENCE", "Placement '" & dimensionCode & "' references missing section '" & sectionKey & "'.", pa & ".sectionKey");
			}
			var ruleKey = keyOf(p, "ruleKey");
			if (len(ruleKey) && !structKeyExists(arguments.keys.ruleKeys, ruleKey)) {
				err(arguments.r, "MISSING_REFERENCE", "Placement '" & dimensionCode & "' references missing rule '" & ruleKey & "'.", pa & ".ruleKey");
			}
			if (has(p, "labelOverride") && isSimpleValue(p.labelOverride) && len(toString(p.labelOverride)) > 200) {
				err(arguments.r, "VALUE_TOO_LONG", "Placement '" & dimensionCode & "' labelOverride exceeds 200 characters.", pa & ".labelOverride");
			}
			var orderKey = sectionKey & "|" & keyOf(p, "displayOrder");
			if (structKeyExists(orders, orderKey)) {
				err(arguments.r, "DUPLICATE_ORDER", "Placement '" & dimensionCode & "' repeats display order " & keyOf(p, "displayOrder") & " within its section.", pa & ".displayOrder");
			}
			orders[orderKey] = true;
			i++;
		}
	}

	private void function checkRetiredContent(required struct r, required struct d) {
		var text = lCase(serializeJSON({ "sections": arguments.d.sections, "items": arguments.d.items }));
		for (var needle in variables.RETIRED_TEXT) {
			if (find(needle, text)) {
				err(arguments.r, "RETIRED_CONTENT_PRESENT", "Retired School Improvement Plan hierarchy text ('" & needle & "') appears in active sections or items.", arguments.r.path);
			}
		}
	}

	// ---- primitives --------------------------------------------------------------------------

	private string function path(required struct r, required string collection) {
		return arguments.r.path & "." & arguments.collection;
	}

	/**
	 * Collects one unique-key set and reports collisions.
	 *
	 * Struct keys in CFML are case-insensitive, so `seen` catches a key that repeats in any casing;
	 * the *value* stored under it is the exact spelling first seen, and compare() (which is
	 * case-sensitive) then separates a true duplicate from two keys that differ only by letter
	 * case. Both are refused -- every reader here addresses definitions by key, and two keys that
	 * differ only by case are one key to all of them -- but they are different mistakes and are
	 * reported as such.
	 */
	private struct function uniqueSet(required struct r, required array rows, required array keys, required string collection, required string label) {
		var seen = {};
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
				err(arguments.r, "BLANK_KEY", arguments.collection & " entry has a blank " & arguments.label & ".", path(arguments.r, arguments.collection) & "[" & i & "]");
			} else if (structKeyExists(seen, composite)) {
				if (compare(seen[composite], composite) == 0) {
					err(arguments.r, "DUPLICATE_KEY", arguments.collection & " contains duplicate " & arguments.label & " '" & composite & "'.", path(arguments.r, arguments.collection) & "[" & i & "]");
				} else {
					err(arguments.r, "KEY_CASE_COLLISION", arguments.collection & " contains keys that differ only by letter case: '" & composite & "' and '" & seen[composite] & "'.", path(arguments.r, arguments.collection) & "[" & i & "]");
				}
			} else {
				seen[composite] = composite;
			}
			i++;
		}
		return seen;
	}

	private void function requireText(required struct r, required any row, required string key, required string p, required numeric maxLength) {
		if (!has(arguments.row, arguments.key) || !isSimpleValue(arguments.row[arguments.key]) || !len(trim(toString(arguments.row[arguments.key])))) {
			err(arguments.r, "BLANK_VALUE", "'" & arguments.key & "' is required.", arguments.p);
			return;
		}
		if (arguments.maxLength > 0 && len(toString(arguments.row[arguments.key])) > arguments.maxLength) {
			err(arguments.r, "VALUE_TOO_LONG", "'" & arguments.key & "' exceeds " & arguments.maxLength & " characters.", arguments.p);
		}
	}

	private void function checkOrder(required struct r, required any row, required string p) {
		if (!has(arguments.row, "displayOrder") || !isSimpleValue(arguments.row.displayOrder) || !isNumeric(arguments.row.displayOrder)
			|| int(arguments.row.displayOrder) != arguments.row.displayOrder || arguments.row.displayOrder < 0 || arguments.row.displayOrder > variables.MAX_ORDER) {
			err(arguments.r, "INVALID_ORDER", "displayOrder must be an integer between 0 and " & variables.MAX_ORDER & ".", arguments.p & ".displayOrder");
		}
	}

	private void function checkSettings(required struct r, required any row, required string p) {
		if (structKeyExists(arguments.row, "settings") && !isNull(arguments.row.settings) && !isStruct(arguments.row.settings)) {
			err(arguments.r, "SETTINGS_NOT_OBJECT", "settings must be a JSON object.", arguments.p & ".settings");
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

	private void function err(required struct r, required string code, required string message, required string p) {
		arrayAppend(arguments.r.errors, { "code": arguments.code, "message": arguments.message, "path": arguments.p });
	}
}
