/**
 * Import and publish judge instrument semantics with the same rule set, and it is provably the
 * same one.
 *
 * WHAT WENT WRONG BEFORE. InstrumentConfigValidator ran a complete second copy of the semantics --
 * its own item-type list, its own rule, dimension and placement checks, its own retired-content
 * guard -- and then also delegated to DefinitionValidator. Import was therefore judged by two rule
 * sets and publish by one. Two rule sets over one subject drift, and every disagreement is either
 * a document that imports and then cannot be published, or one that publishes carrying something
 * import would have refused.
 *
 * HOW THIS PROVES THEY ARE ONE. Each case below breaks the same fact twice, in the two shapes the
 * two paths actually see:
 *
 *   - in an authoring document, handed to InstrumentConfigValidator (the import predicate);
 *   - in the same document's normalized definitions, handed to DefinitionValidator (the predicate
 *     publish runs, under the version's row lock, against its snapshot and its stored rows).
 *
 * Both must report the same issue code at the same path. The path is the load-bearing half: a code
 * can coincide between two independent implementations, but "$.definitions.items[3].itemType"
 * appearing from both sides only happens when one component produced it. Import reports issues
 * rooted at "$.definitions" because that is where checkDefinitions mounts them, which is exactly
 * the root publish uses for the snapshot's definitions.
 *
 * AND THAT INBOUND RULES STAY INBOUND. The last cases prove the other half of the boundary: the
 * things only a document can be wrong about -- unparseable conditionsJson, a duplicate authoring
 * id, a declared status that is not DRAFT -- are refused by import and are *not* rules the shared
 * validator carries, because a persisted version has no authoring ids, no conditionsJson text, and
 * a status that is a lifecycle fact rather than a claim.
 *
 * No database: both validators are pure.
 */
component extends="icfwalktests.BaseSpec" output="false" {

	public void function beforeEach() {
		variables.configValidator = variables.c.configValidator;
		variables.definitionValidator = variables.c.definitionValidator;
		variables.normalizer = variables.c.configNormalizer;
	}

	// ---- the same semantic defect, reported identically from both sides -------------------------

	/** An item type the runtime does not implement. */
	public void function testUnsupportedItemTypeIsReportedIdenticallyByBothPaths() {
		assertEquivalent(function(cfg) {
			firstOfType(cfg, "SINGLE_CHOICE").itemType = "MULTI_CHOICE";
		}, "INVALID_ENUM");
	}

	/** A rule effect the runtime does not implement. */
	public void function testUnsupportedRuleEffectIsReportedIdenticallyByBothPaths() {
		assertEquivalent(function(cfg) {
			cfg.rules[1].effect = "HIDE";
		}, "UNSUPPORTED_EFFECT");
	}

	/** A choice item with no response set. */
	public void function testChoiceItemWithoutAResponseSetIsReportedIdenticallyByBothPaths() {
		assertEquivalent(function(cfg) {
			structDelete(firstOfType(cfg, "SINGLE_CHOICE"), "responseSetId");
		}, "ITEM_RESPONSE_SET_REQUIRED");
	}

	/** A dimension whose data type is not one the contract defines. */
	public void function testInvalidDimensionDataTypeIsReportedIdenticallyByBothPaths() {
		assertEquivalent(function(cfg) {
			cfg.dimensions[1].dataType = "COLOUR";
		}, "INVALID_ENUM");
	}

	/** A blank required value. */
	public void function testBlankSectionTitleIsReportedIdenticallyByBothPaths() {
		assertEquivalent(function(cfg) {
			cfg.sections[2].title = "   ";
		}, "BLANK_VALUE");
	}

	/** An order outside the range the contract allows. */
	public void function testInvalidDisplayOrderIsReportedIdenticallyByBothPaths() {
		assertEquivalent(function(cfg) {
			cfg.items[1].displayOrder = -5;
		}, "INVALID_ORDER");
	}

	/** Retired hierarchy wording that must never reach active content. */
	public void function testRetiredContentIsReportedIdenticallyByBothPaths() {
		assertEquivalent(function(cfg) {
			cfg.sections[2].title = "School Improvement (SIP) overview";
		}, "RETIRED_CONTENT_PRESENT");
	}

	/** The runtime renderability contract, reported the same way from both sides. */
	public void function testInactiveRootIsReportedIdenticallyByBothPaths() {
		assertEquivalent(function(cfg) {
			for (var s in cfg.sections) {
				if (!structKeyExists(s, "parentSectionId") || isNull(s.parentSectionId) || !len(toString(s.parentSectionId))) s.active = false;
			}
		}, "SECTION_ROOT_MISSING");
	}

	/** An option filter the renderer does not implement. */
	public void function testUnknownOptionFilterIsReportedIdenticallyByBothPaths() {
		assertEquivalent(function(cfg) {
			if (!structKeyExists(cfg.instrumentDimensions[1], "settings") || !isStruct(cfg.instrumentDimensions[1].settings)) {
				cfg.instrumentDimensions[1]["settings"] = {};
			}
			cfg.instrumentDimensions[1].settings["optionFilter"] = "notARealFilter";
		}, "UNSUPPORTED_OPTION_FILTER");
	}

	/** An active item pointing at a response set the version has deactivated. */
	public void function testInactiveResponseSetIsReportedIdenticallyByBothPaths() {
		assertEquivalent(function(cfg) {
			var it = firstOfType(cfg, "SINGLE_CHOICE");
			for (var rs in cfg.responseSets) if (rs.responseSetId == it.responseSetId) rs.active = false;
		}, "RESPONSE_SET_INACTIVE");
	}

	// ---- inbound-only rules stay inbound ---------------------------------------------------------

	/**
	 * conditionsJson is a JSON *string* in a document and a parsed document everywhere else, so
	 * "it does not parse" is a question only import can ask. Import refuses it; the shared
	 * validator is never given the string and so has no rule about it.
	 */
	public void function testUnparseableConditionsJsonIsImportOnly() {
		// The normalized rule ends up with no conditions document at all, which the shared
		// validator does report -- as CONDITIONS_SHAPE, its own rule about the parsed form. What it
		// cannot report, and what only import can, is that the *text* was not JSON.
		assertImportOnly(function(cfg) {
			cfg.rules[1].conditionsJson = "{not json";
		}, "INVALID_JSON", false);
	}

	/**
	 * Authoring ids exist only in the document; normalization resolves them into keys and a
	 * persisted version has none. A duplicate one is import's to refuse and nobody else's.
	 */
	public void function testDuplicateAuthoringIdIsImportOnly() {
		// Two sections claiming one authoring id. The shared validator addresses sections by key,
		// and the keys are still distinct, so it never reports the duplicate. It does report the
		// consequence -- items whose sectionId no longer resolves normalize to a blank sectionKey --
		// which is a different rule about a different fact.
		assertImportOnly(function(cfg) {
			cfg.sections[3].sectionId = cfg.sections[2].sectionId;
		}, "DUPLICATE_KEY", false);
	}

	/**
	 * A document may only declare DRAFT. A persisted version's status is a lifecycle fact read
	 * under its row lock, not a claim in a payload, so this rule cannot exist on the shared side.
	 */
	public void function testNonDraftDeclarationIsImportOnly() {
		assertImportOnly(function(cfg) {
			cfg.instrument.version.status = "PUBLISHED";
		}, "VERSION_STATUS_NOT_DRAFT");
	}

	/**
	 * A reference to an authoring id that was never declared.
	 *
	 * Both sides report MISSING_REFERENCE here, and that is correct -- a dangling reference is a
	 * dangling reference. What is inbound-only is the *diagnosis*: import can say which id the
	 * author actually wrote and where they wrote it, because the document still has authoring ids.
	 * By the time the shared validator sees it, normalization has resolved the id into a blank key
	 * and the original spelling is gone. This pins that division rather than pretending the code
	 * belongs to one side.
	 */
	public void function testUnresolvableAuthoringReferenceIsDiagnosedOnlyByImport() {
		var cfg = repoJson("config/instrument-config.json");
		cfg.items[1].sectionId = "sec_does_not_exist";

		var importResult = variables.configValidator.validate(cfg);
		assertFalse(importResult.valid, "import must refuse this document");
		var namedByImport = false;
		for (var e in importResult.errors) {
			if (e.code == "MISSING_REFERENCE" && findNoCase("sec_does_not_exist", e.message) && findNoCase(".sectionId", e.path)) namedByImport = true;
		}
		assertTrue(namedByImport, "import names the authoring id the author wrote, at its sectionId path: " & summary(importResult.errors));

		var definitions = variables.normalizer.fromConfig(cfg).definitions;
		var publishResult = variables.definitionValidator.validate(definitions, { "path": "$.definitions" });
		assertFalse(publishResult.valid, "the shared validator also sees a dangling reference");
		for (var e in publishResult.errors) {
			assertFalse(findNoCase("sec_does_not_exist", e.message) > 0, "but it cannot name an authoring id, because normalization resolved it away");
		}
	}

	// ---- helpers ---------------------------------------------------------------------------------

	/**
	 * Breaks the same fact in the document and asserts that the import predicate and the shared
	 * predicate report the same code at the same path.
	 */
	private void function assertEquivalent(required any corrupt, required string code) {
		var cfg = repoJson("config/instrument-config.json");
		arguments.corrupt(cfg);

		var importResult = variables.configValidator.validate(cfg);
		assertFalse(importResult.valid, "import must refuse this document");
		var importPaths = pathsFor(importResult.errors, arguments.code);
		assertTrue(arrayLen(importPaths) > 0, "import must report " & arguments.code & "; it reported " & summary(importResult.errors));

		var definitions = variables.normalizer.fromConfig(cfg).definitions;
		var publishResult = variables.definitionValidator.validate(definitions, { "path": "$.definitions" });
		assertFalse(publishResult.valid, "the shared validator must refuse the same normalized state");
		var publishPaths = pathsFor(publishResult.errors, arguments.code);
		assertTrue(arrayLen(publishPaths) > 0, "the shared validator must report " & arguments.code & "; it reported " & summary(publishResult.errors));

		arraySort(importPaths, "text");
		arraySort(publishPaths, "text");
		assertEquals(
			arrayToList(publishPaths, " | "),
			arrayToList(importPaths, " | "),
			"import and publish must report " & arguments.code & " at the same path(s)"
		);
	}

	/**
	 * The document is refused by import with `code`, and the shared validator does not carry that
	 * rule. `sharedMustAccept` is false where the normalized form is broken for some *other*
	 * reason as a side effect (an unresolvable authoring reference normalizes to a blank key, which
	 * the shared validator reports as its own kind of problem); there the assertion is only that
	 * the shared validator does not report this code.
	 */
	private void function assertImportOnly(required any corrupt, required string code, boolean sharedMustAccept = true) {
		var cfg = repoJson("config/instrument-config.json");
		arguments.corrupt(cfg);

		var importResult = variables.configValidator.validate(cfg);
		assertFalse(importResult.valid, "import must refuse this document");
		assertTrue(arrayLen(pathsFor(importResult.errors, arguments.code)) > 0, "import must report " & arguments.code & "; it reported " & summary(importResult.errors));

		var definitions = "";
		try {
			definitions = variables.normalizer.fromConfig(cfg).definitions;
		} catch (any e) {
			// A document that cannot even normalize is inbound-only by construction.
			return;
		}
		var publishResult = variables.definitionValidator.validate(definitions, { "path": "$.definitions" });
		assertEquals(0, arrayLen(pathsFor(publishResult.errors, arguments.code)), "the shared validator must not carry this inbound-only rule");
		if (arguments.sharedMustAccept) {
			assertTrue(publishResult.valid, "and the normalized form is otherwise valid: " & summary(publishResult.errors));
		}
	}

	private struct function firstOfType(required struct cfg, required string itemType) {
		for (var it in arguments.cfg.items) if (it.itemType == arguments.itemType) return it;
		fail("no " & arguments.itemType & " item in the supplied configuration");
	}

	private array function pathsFor(required array errors, required string code) {
		var out = [];
		for (var e in arguments.errors) if (e.code == arguments.code) arrayAppend(out, e.path);
		return out;
	}

	private string function summary(required array errors) {
		var codes = [];
		for (var e in arguments.errors) arrayAppend(codes, e.code & "@" & e.path);
		return arrayToList(codes, ", ");
	}
}
