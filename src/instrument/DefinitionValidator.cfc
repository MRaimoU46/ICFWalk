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
	/** The snapshot's counts block: every definition collection, plus the derived placeholder count. */
	variables.SNAPSHOT_COUNT_KEYS = ["sections", "items", "responseSets", "responseOptions", "rules", "dimensions", "dimensionValues", "instrumentDimensions", "placeholders"];
	/**
	 * Item types the runtime implements end to end. Every entry here has a layout branch in
	 * RenderModelBuilder, a control in app/assets/js/renderer.js, and a storage shape in
	 * icf.walk_response.
	 *
	 * MULTI_CHOICE and SHORT_TEXT used to be on this list and are deliberately not. Neither has a
	 * renderer layout, and MULTI_CHOICE additionally has nowhere to go: icf.walk_response stores one
	 * selected option per item, so "multi" could not be persisted even if it were drawn. Accepting a
	 * type the runtime cannot render is exactly the gap this list now closes -- a version carrying
	 * one is refused at import and at publication rather than frozen and then thrown on. Adding
	 * either back means implementing it everywhere first, and this list is the single place that
	 * records the decision.
	 */
	variables.ITEM_TYPES = ["SINGLE_CHOICE", "LONG_TEXT", "DISPLAY_HEADING", "DISPLAY_GUIDANCE", "EMAIL_DRAFT_JSON"];
	variables.CHOICE_TYPES = ["SINGLE_CHOICE"];
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
	variables.PLACEHOLDER_REVIEW_STATUS = "Placeholder in source";
	/**
	 * Declarative option filters the renderer implements, by name. A placement naming anything else
	 * makes RenderModelBuilder throw, so the name is validated here against the same table the
	 * builder reads.
	 */
	variables.OPTION_FILTERS = {
		"schoolTypeToGradeBand": { "sourceDimensionCode": "school", "matchField": "valueGroup" }
	};

	public DefinitionValidator function init() {
		return this;
	}

	public string function snapshotFormat() { return variables.SNAPSHOT_FORMAT; }

	// ---- the shared vocabulary -----------------------------------------------------------------
	// One authoritative copy of every list the import path, the publish path, the compiler and the
	// renderer all have to agree on. They are handed out as copies: a caller that mutated one would
	// be redefining the contract for everybody.

	public array function itemTypes() { return duplicate(variables.ITEM_TYPES); }
	public array function choiceTypes() { return duplicate(variables.CHOICE_TYPES); }
	public array function selectionModes() { return duplicate(variables.SELECTION_MODES); }
	public array function targetTypes() { return duplicate(variables.TARGET_TYPES); }
	public array function effects() { return duplicate(variables.EFFECTS); }
	public array function supportedEffects() { return duplicate(variables.SUPPORTED_EFFECTS); }
	public array function sourceTypes() { return duplicate(variables.SOURCE_TYPES); }
	public array function operators() { return duplicate(variables.OPERATORS); }
	public array function dataTypes() { return duplicate(variables.DATA_TYPES); }
	public array function logics() { return duplicate(variables.LOGICS); }
	public array function collections() { return duplicate(variables.COLLECTIONS); }
	public array function snapshotCountKeys() { return duplicate(variables.SNAPSHOT_COUNT_KEYS); }
	public array function retiredText() { return duplicate(variables.RETIRED_TEXT); }
	public struct function optionFilters() { return duplicate(variables.OPTION_FILTERS); }
	public numeric function maxOrder() { return variables.MAX_ORDER; }
	public string function placeholderReviewStatus() { return variables.PLACEHOLDER_REVIEW_STATUS; }

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
		checkRuntimeContract(r, d, keys);
		checkRetiredContent(r, d);
		r.valid = arrayLen(r.errors) == 0;
		return r;
	}

	/**
	 * The rules that exist because the *runtime* has them, not because the schema does.
	 *
	 * Everything above validates the definitions as a document: keys are unique, references
	 * resolve, enumerations are known. All of that can hold while RenderModelBuilder still refuses
	 * the version -- or, worse, builds it with content missing. The renderer filters by `active`
	 * before it does anything else, walks the section tree from a single root, and indexes response
	 * sets and dimensions from the active rows only. A reference that was closed over *all* rows
	 * can therefore be dangling over the *active* ones, and a subtree that is perfectly well formed
	 * can hang off nothing the walk reaches.
	 *
	 * So this is the same closure question asked again, after the filter the runtime applies:
	 * exactly one active root, every active thing reachable from it, and every reference an active
	 * row makes resolving to something that is also active and usable. Each rule below corresponds
	 * to a specific way RenderModelBuilder throws or silently drops content; together they are what
	 * makes "this version publishes" and "this version renders" the same statement.
	 */
	private void function checkRuntimeContract(required struct r, required struct d, required struct keys) {
		var activeSections = {};
		var roots = [];
		for (var s in arguments.d.sections) {
			var key = keyOf(s, "sectionKey");
			if (!truthy(s, "active") || !len(key)) continue;
			activeSections[key] = s;
			if (!len(keyOf(s, "parentSectionKey"))) arrayAppend(roots, key);
		}

		if (!arrayLen(roots)) {
			err(arguments.r, "SECTION_ROOT_MISSING", "No active section is the root: the runtime builds the instrument from exactly one active section that has no parent.", path(arguments.r, "sections"));
		} else if (arrayLen(roots) > 1) {
			arraySort(roots, "textnocase");
			err(arguments.r, "SECTION_ROOT_AMBIGUOUS", "More than one active section has no parent (" & arrayToList(roots, ", ") & "); the runtime builds from one root and would silently drop the others.", path(arguments.r, "sections"));
		}

		// Reachability from the one root, over active sections only -- the walk the renderer does.
		var reachable = {};
		if (arrayLen(roots) == 1) {
			var childrenOf = {};
			for (var key in structKeyArray(activeSections)) {
				var parentKey = keyOf(activeSections[key], "parentSectionKey");
				if (!len(parentKey)) continue;
				if (!structKeyExists(childrenOf, parentKey)) childrenOf[parentKey] = [];
				arrayAppend(childrenOf[parentKey], key);
			}
			var queue = [roots[1]];
			while (arrayLen(queue)) {
				var current = queue[arrayLen(queue)];
				arrayDeleteAt(queue, arrayLen(queue));
				if (structKeyExists(reachable, current)) continue;
				reachable[current] = true;
				if (structKeyExists(childrenOf, current)) {
					for (var child in childrenOf[current]) arrayAppend(queue, child);
				}
			}
		}

		var i = 0;
		for (var s in arguments.d.sections) {
			var p = path(arguments.r, "sections") & "[" & i & "]";
			i++;
			var key = keyOf(s, "sectionKey");
			if (!truthy(s, "active") || !len(key)) continue;
			var parentKey = keyOf(s, "parentSectionKey");
			if (!len(parentKey)) continue;
			if (!structKeyExists(activeSections, parentKey)) {
				// A parent that is missing entirely is already reported as MISSING_REFERENCE; this is
				// the case the reference check cannot see, where the parent exists but is inactive.
				if (structKeyExists(arguments.keys.sectionKeys, parentKey)) {
					err(arguments.r, "SECTION_ORPHANED_FROM_ROOT", "Active section '" & key & "' hangs off inactive section '" & parentKey & "', so the runtime never reaches it.", p & ".parentSectionKey");
				}
			} else if (arrayLen(roots) == 1 && !structKeyExists(reachable, key)) {
				err(arguments.r, "SECTION_ORPHANED_FROM_ROOT", "Active section '" & key & "' is not reachable from the root section, so the runtime never renders it.", p & ".parentSectionKey");
			}
		}

		// Response sets and their options, as the renderer indexes them: active rows only.
		var activeSets = {};
		for (var rs in arguments.d.responseSets) {
			if (truthy(rs, "active") && len(keyOf(rs, "setKey"))) activeSets[keyOf(rs, "setKey")] = rs;
		}
		var activeOptionCount = {};
		for (var op in arguments.d.responseOptions) {
			if (!truthy(op, "active")) continue;
			var setKey = keyOf(op, "setKey");
			if (!len(setKey)) continue;
			activeOptionCount[setKey] = (structKeyExists(activeOptionCount, setKey) ? activeOptionCount[setKey] : 0) + 1;
		}

		i = 0;
		for (var it in arguments.d.items) {
			var p = path(arguments.r, "items") & "[" & i & "]";
			i++;
			if (!truthy(it, "active")) continue;
			var sectionKey = keyOf(it, "sectionKey");
			if (len(sectionKey) && structKeyExists(arguments.keys.sectionKeys, sectionKey)) {
				if (!structKeyExists(activeSections, sectionKey)) {
					err(arguments.r, "ITEM_ORPHANED_FROM_ROOT", "Active item '" & keyOf(it, "itemKey") & "' sits in inactive section '" & sectionKey & "', so the runtime never renders it.", p & ".sectionKey");
				} else if (arrayLen(roots) == 1 && !structKeyExists(reachable, sectionKey)) {
					err(arguments.r, "ITEM_ORPHANED_FROM_ROOT", "Active item '" & keyOf(it, "itemKey") & "' sits in section '" & sectionKey & "', which is not reachable from the root.", p & ".sectionKey");
				}
			}
			var setKey = keyOf(it, "responseSetKey");
			if (!len(setKey) || !structKeyExists(arguments.keys.setKeys, setKey)) continue;
			if (!structKeyExists(activeSets, setKey)) {
				err(arguments.r, "RESPONSE_SET_INACTIVE", "Active item '" & keyOf(it, "itemKey") & "' references inactive response set '" & setKey & "'; the runtime indexes active sets only and cannot render it.", p & ".responseSetKey");
			} else if (arrayContains(variables.CHOICE_TYPES, keyOf(it, "itemType")) && !structKeyExists(activeOptionCount, setKey)) {
				err(arguments.r, "RESPONSE_SET_NO_ACTIVE_OPTIONS", "Active choice item '" & keyOf(it, "itemKey") & "' uses response set '" & setKey & "', which has no active option, so it would render with nothing to choose.", p & ".responseSetKey");
			}
		}

		// Dimensions and the values a version offers, again as the renderer indexes them.
		var activeDimensions = {};
		for (var dim in arguments.d.dimensions) {
			if (truthy(dim, "active") && len(keyOf(dim, "code"))) activeDimensions[keyOf(dim, "code")] = dim;
		}
		var activeValueCount = {};
		for (var v in arguments.d.dimensionValues) {
			if (!truthy(v, "active")) continue;
			var dimensionCode = keyOf(v, "dimensionCode");
			if (!len(dimensionCode)) continue;
			activeValueCount[dimensionCode] = (structKeyExists(activeValueCount, dimensionCode) ? activeValueCount[dimensionCode] : 0) + 1;
		}

		i = 0;
		for (var pl in arguments.d.instrumentDimensions) {
			var pa = path(arguments.r, "instrumentDimensions") & "[" & i & "]";
			i++;
			if (!truthy(pl, "active")) continue;
			var dimensionCode = keyOf(pl, "dimensionCode");
			var sectionKey = keyOf(pl, "sectionKey");
			if (!len(sectionKey)) {
				err(arguments.r, "PLACEMENT_SECTION_REQUIRED", "Active placement of dimension '" & dimensionCode & "' names no section; the runtime renders placements inside a section and has nowhere to put it.", pa & ".sectionKey");
			} else if (structKeyExists(arguments.keys.sectionKeys, sectionKey)) {
				if (!structKeyExists(activeSections, sectionKey)) {
					err(arguments.r, "PLACEMENT_ORPHANED_FROM_ROOT", "Active placement of dimension '" & dimensionCode & "' sits in inactive section '" & sectionKey & "', so the runtime never renders it.", pa & ".sectionKey");
				} else if (arrayLen(roots) == 1 && !structKeyExists(reachable, sectionKey)) {
					err(arguments.r, "PLACEMENT_ORPHANED_FROM_ROOT", "Active placement of dimension '" & dimensionCode & "' sits in section '" & sectionKey & "', which is not reachable from the root.", pa & ".sectionKey");
				}
			}
			if (len(dimensionCode) && structKeyExists(arguments.keys.dimensionCodes, dimensionCode)) {
				if (!structKeyExists(activeDimensions, dimensionCode)) {
					err(arguments.r, "DIMENSION_INACTIVE", "Active placement references inactive dimension '" & dimensionCode & "'; the runtime indexes active dimensions only and cannot render it.", pa & ".dimensionCode");
				} else if (keyOf(activeDimensions[dimensionCode], "dataType") == "LIST" && !structKeyExists(activeValueCount, dimensionCode)) {
					err(arguments.r, "DIMENSION_NO_ACTIVE_VALUES", "Active placement of list dimension '" & dimensionCode & "' offers no active value, so it would render with nothing to choose.", pa & ".dimensionCode");
				}
			}
			checkOptionFilter(arguments.r, pl, pa, activeDimensions);
		}

		// Rules the runtime keeps (active ones) must point at content the runtime also keeps.
		i = 0;
		for (var rule in arguments.d.rules) {
			var p = path(arguments.r, "rules") & "[" & i & "]";
			i++;
			if (!truthy(rule, "active")) continue;
			var targetType = keyOf(rule, "targetType");
			var targetKey = keyOf(rule, "targetKey");
			if (len(targetKey)) {
				if (targetType == "SECTION" && structKeyExists(arguments.keys.sectionKeys, targetKey) && !structKeyExists(activeSections, targetKey)) {
					err(arguments.r, "RULE_TARGET_INACTIVE", "Active rule '" & keyOf(rule, "ruleKey") & "' targets inactive section '" & targetKey & "', which the runtime has already filtered out.", p & ".targetKey");
				} else if (targetType == "ITEM" && structKeyExists(arguments.keys.itemKeys, targetKey) && !activeItemExists(arguments.d, targetKey)) {
					err(arguments.r, "RULE_TARGET_INACTIVE", "Active rule '" & keyOf(rule, "ruleKey") & "' targets inactive item '" & targetKey & "', which the runtime has already filtered out.", p & ".targetKey");
				} else if (targetType == "DIMENSION" && structKeyExists(arguments.keys.dimensionCodes, targetKey) && !structKeyExists(activeDimensions, targetKey)) {
					err(arguments.r, "RULE_TARGET_INACTIVE", "Active rule '" & keyOf(rule, "ruleKey") & "' targets inactive dimension '" & targetKey & "', which the runtime has already filtered out.", p & ".targetKey");
				}
			}
			checkActiveSource(arguments.r, arguments.d, keyOf(rule, "sourceType"), keyOf(rule, "sourceKey"), keyOf(rule, "ruleKey"), p & ".sourceKey", arguments.keys, activeDimensions);
			if (has(rule, "conditions") && isStruct(rule.conditions) && has(rule.conditions, "conditions") && isArray(rule.conditions.conditions)) {
				for (var cond in rule.conditions.conditions) {
					if (!isStruct(cond)) continue;
					checkActiveSource(arguments.r, arguments.d, keyOf(cond, "sourceType"), keyOf(cond, "sourceKey"), keyOf(rule, "ruleKey"), p & ".conditions", arguments.keys, activeDimensions);
				}
			}
		}
	}

	/** A placement's option filter must be one the renderer implements, or it throws at build time. */
	private void function checkOptionFilter(required struct r, required any placement, required string pa, required struct activeDimensions) {
		if (!structKeyExists(arguments.placement, "settings") || isNull(arguments.placement.settings) || !isStruct(arguments.placement.settings)) return;
		var settings = arguments.placement.settings;
		if (!has(settings, "optionFilter") || !isSimpleValue(settings.optionFilter) || !len(trim(toString(settings.optionFilter)))) return;
		var name = toString(settings.optionFilter);
		if (!structKeyExists(variables.OPTION_FILTERS, name)) {
			err(arguments.r, "UNSUPPORTED_OPTION_FILTER", "Placement of dimension '" & keyOf(arguments.placement, "dimensionCode") & "' asks for option filter '" & name & "', which the runtime does not implement.", arguments.pa & ".settings.optionFilter");
			return;
		}
		// A filter that names a dimension this version does not offer silently filters nothing.
		var sourceCode = variables.OPTION_FILTERS[name].sourceDimensionCode;
		if (!structKeyExists(arguments.activeDimensions, sourceCode)) {
			err(arguments.r, "OPTION_FILTER_SOURCE_MISSING", "Option filter '" & name & "' reads dimension '" & sourceCode & "', which this version does not offer as an active dimension.", arguments.pa & ".settings.optionFilter");
		}
	}

	/** A rule's source must still exist once the runtime has filtered out inactive content. */
	private void function checkActiveSource(
		required struct r, required struct d, required string sourceType, required string sourceKey,
		required string ruleKey, required string p, required struct keys, required struct activeDimensions
	) {
		if (!len(arguments.sourceKey)) return;
		if (arguments.sourceType == "ITEM") {
			if (!structKeyExists(arguments.keys.itemKeys, arguments.sourceKey)) return;
			if (!activeItemExists(arguments.d, arguments.sourceKey)) {
				err(arguments.r, "RULE_SOURCE_INACTIVE", "Active rule '" & arguments.ruleKey & "' reads inactive item '" & arguments.sourceKey & "', which the runtime has already filtered out.", arguments.p);
			}
			return;
		}
		if (arguments.sourceType == "DIMENSION") {
			if (!structKeyExists(arguments.keys.dimensionCodes, arguments.sourceKey)) return;
			if (!structKeyExists(arguments.activeDimensions, arguments.sourceKey)) {
				err(arguments.r, "RULE_SOURCE_INACTIVE", "Active rule '" & arguments.ruleKey & "' reads inactive dimension '" & arguments.sourceKey & "', which the runtime has already filtered out.", arguments.p);
			}
		}
	}

	private boolean function activeItemExists(required struct d, required string itemKey) {
		for (var it in arguments.d.items) {
			if (keyOf(it, "itemKey") == arguments.itemKey && truthy(it, "active")) return true;
		}
		return false;
	}

	/** A row's boolean flag, read the same way whether it came from JSON or from SQL Server. */
	private boolean function truthy(required any row, required string key) {
		if (!has(arguments.row, arguments.key)) return false;
		var v = arguments.row[arguments.key];
		if (isBoolean(v)) return v ? true : false;
		if (isSimpleValue(v)) {
			var t = lCase(trim(toString(v)));
			return t == "true" || t == "yes" || t == "1";
		}
		return false;
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
		checkCounts(r, s, root);
		r.valid = arrayLen(r.errors) == 0;
		return r;
	}

	/**
	 * The counts block, in full and exactly.
	 *
	 * counts is what every reader trusts instead of walking the arrays, so it is part of the
	 * envelope and not a convenience. The compiler writes all nine members; accepting a snapshot
	 * that is missing the block, missing a member, or carrying a member that is not a whole
	 * non-negative number would mean publication froze a snapshot whose own summary of itself
	 * cannot be relied on. Extra members are refused for the same reason: the contract names nine,
	 * and a tenth is something a reader would either ignore or, worse, believe.
	 *
	 * placeholders is derived rather than counted from a collection: it is the number of items the
	 * content review left unresolved, and PLACEHOLDER_REVIEW_STATUS here is the one definition of
	 * what that means.
	 */
	private void function checkCounts(required struct r, required struct s, required string root) {
		var s = arguments.s;
		if (!has(s, "counts")) {
			err(arguments.r, "SNAPSHOT_COUNTS_MISSING", "The stored snapshot has no counts object; the snapshot envelope requires one with all " & arrayLen(variables.SNAPSHOT_COUNT_KEYS) & " members.", arguments.root & ".counts");
			return;
		}
		if (!isStruct(s.counts)) {
			err(arguments.r, "SNAPSHOT_SHAPE", "The stored snapshot's counts is not an object.", arguments.root & ".counts");
			return;
		}
		// Counts can only be compared with the definitions when there are definitions to compare
		// with; a snapshot with no definitions object is already reported above.
		var comparable = has(s, "definitions") && isStruct(s.definitions);
		var expected = comparable ? derivedCounts(s.definitions) : {};

		for (var name in variables.SNAPSHOT_COUNT_KEYS) {
			var p = arguments.root & ".counts." & name;
			if (!has(s.counts, name)) {
				err(arguments.r, "SNAPSHOT_COUNTS_MISSING", "The stored snapshot's counts has no '" & name & "' member.", p);
				continue;
			}
			var value = s.counts[name];
			if (!isSimpleValue(value) || !isNumeric(value)) {
				err(arguments.r, "SNAPSHOT_COUNTS_INVALID", "The stored snapshot's counts." & name & " is not a number.", p);
				continue;
			}
			if (int(value) != value || value < 0) {
				err(arguments.r, "SNAPSHOT_COUNTS_INVALID", "The stored snapshot's counts." & name & " is " & toString(value) & "; a count must be a whole number of zero or more.", p);
				continue;
			}
			if (comparable && structKeyExists(expected, name) && value != expected[name]) {
				err(arguments.r, "SNAPSHOT_COUNTS_MISMATCH", "The stored snapshot's counts." & name & " is " & toString(value) & " but it carries " & expected[name] & ".", p);
			}
		}

		for (var name in structKeyArray(s.counts)) {
			if (!arrayContains(variables.SNAPSHOT_COUNT_KEYS, name)) {
				err(arguments.r, "SNAPSHOT_COUNTS_UNEXPECTED", "The stored snapshot's counts carries '" & name & "', which is not part of the snapshot envelope.", arguments.root & ".counts." & name);
			}
		}
	}

	/**
	 * The counts the definitions themselves imply. SnapshotCompiler.countDefinitions writes exactly
	 * these; this is the reader's independent derivation of the same numbers, which is what makes
	 * comparing them worth anything.
	 */
	public struct function derivedCounts(required struct definitions) {
		var d = arguments.definitions;
		var out = {};
		for (var name in variables.COLLECTIONS) {
			out[name] = (structKeyExists(d, name) && !isNull(d[name]) && isArray(d[name])) ? arrayLen(d[name]) : 0;
		}
		out["placeholders"] = placeholderCount(d);
		return out;
	}

	/** Items the content review left unresolved: the one definition of "placeholder". */
	public numeric function placeholderCount(required struct definitions) {
		if (!structKeyExists(arguments.definitions, "items") || isNull(arguments.definitions.items) || !isArray(arguments.definitions.items)) return 0;
		var n = 0;
		for (var item in arguments.definitions.items) {
			if (has(item, "reviewStatus") && isSimpleValue(item.reviewStatus) && toString(item.reviewStatus) == variables.PLACEHOLDER_REVIEW_STATUS) n++;
		}
		return n;
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
