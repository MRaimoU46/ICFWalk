/**
 * The shared semantic rule set, at its own boundary.
 *
 * WHY THIS SPEC EXISTS SEPARATELY. InstrumentPublishServiceTest proves that publication refuses a
 * checksum-matching invalid version, but it can only build the invalid states SQL Server will
 * actually store. Several rules in the contract guard against states the schema already makes
 * impossible -- duplicate logical keys (unique constraints on every key), a parent section that is
 * not a section of this version (a self-referencing foreign key plus
 * FK_section_parent_same_version and CK_section_not_self_parent). Those rules still have to hold,
 * because the snapshot side of publication is a JSON document that no constraint touches, and
 * because the import path runs the same rules over a document that has not reached the database at
 * all.
 *
 * So this spec exercises DefinitionValidator directly, on normalized definitions built from the
 * real instrument and then broken one rule at a time. It is the boundary test for exactly the
 * defects a database constraint refuses to persist, and the unit-level proof for the ones it does.
 *
 * No database, no fixtures: the validator is pure.
 */
component extends="icfwalktests.BaseSpec" output="false" {

	public void function beforeEach() {
		variables.validator = variables.c.definitionValidator;
		variables.definitions = variables.c.configNormalizer.fromConfig(repoJson("config/instrument-config.json")).definitions;
	}

	/** The supplied instrument is valid, and the validator says so with no errors at all. */
	public void function testTheSuppliedInstrumentIsValid() {
		var r = variables.validator.validate(variables.definitions);
		assertTrue(r.valid, "Expected no errors: " & (arrayLen(r.errors) ? serializeJSON(r.errors[1]) : ""));
		assertEquals(0, arrayLen(r.errors));
	}

	/** A definitions object that is not an object at all fails without throwing. */
	public void function testNonObjectDefinitionsAreReported() {
		assertFalse(variables.validator.validate("not an object").valid);
		assertTrue(hasError(variables.validator.validate([]), "DEFINITIONS_SHAPE"));
	}

	/** A missing collection is reported, and the rest of the run does not crash on it. */
	public void function testMissingCollectionIsReported() {
		structDelete(variables.definitions, "rules");
		var r = variables.validator.validate(variables.definitions);
		assertFalse(r.valid);
		assertTrue(hasError(r, "DEFINITIONS_SHAPE"));
	}

	/** An instrument version with nothing in it is not a valid instrument. */
	public void function testEmptyDefinitionsAreReported() {
		variables.definitions.sections = [];
		variables.definitions.items = [];
		var r = variables.validator.validate(variables.definitions);
		assertFalse(r.valid);
		assertTrue(hasError(r, "DEFINITIONS_EMPTY"));
	}

	// ---- the rules SQL Server prevents from ever being persisted ------------------------------

	/** Two sections with one key. UQ_section_version_key stops this in the database. */
	public void function testDuplicateSectionKeyIsReported() {
		variables.definitions.sections[2].sectionKey = variables.definitions.sections[1].sectionKey;
		var r = variables.validator.validate(variables.definitions);
		assertTrue(hasError(r, "DUPLICATE_KEY"), errorSummary(r));
	}

	/** Two items with one key. UQ_item_version_key stops this in the database. */
	public void function testDuplicateItemKeyIsReported() {
		variables.definitions.items[2].itemKey = variables.definitions.items[1].itemKey;
		assertTrue(hasError(variables.validator.validate(variables.definitions), "DUPLICATE_KEY"));
	}

	/** Keys that differ only by letter case are one key to every key-addressed reader. */
	public void function testKeyCaseCollisionIsReported() {
		variables.definitions.items[2].itemKey = uCase(variables.definitions.items[1].itemKey) & "X";
		variables.definitions.items[3].itemKey = lCase(variables.definitions.items[2].itemKey);
		assertTrue(hasError(variables.validator.validate(variables.definitions), "KEY_CASE_COLLISION"));
	}

	/** Two options of one set sharing a stored code. UQ_response_option_set_code stops this. */
	public void function testDuplicateOptionCodeIsReported() {
		var setKey = variables.definitions.responseOptions[1].setKey;
		for (var op in variables.definitions.responseOptions) {
			if (op.setKey == setKey && op.optionKey != variables.definitions.responseOptions[1].optionKey) {
				op.storedCode = variables.definitions.responseOptions[1].storedCode;
				break;
			}
		}
		assertTrue(hasError(variables.validator.validate(variables.definitions), "DUPLICATE_KEY"));
	}

	/** Two rules with one key. UQ_rule_version_key stops this. */
	public void function testDuplicateRuleKeyIsReported() {
		variables.definitions.rules[2].ruleKey = variables.definitions.rules[1].ruleKey;
		assertTrue(hasError(variables.validator.validate(variables.definitions), "DUPLICATE_KEY"));
	}

	/** Two dimensions with one code. UQ_dimension_definition_code stops this. */
	public void function testDuplicateDimensionCodeIsReported() {
		variables.definitions.dimensions[2].code = variables.definitions.dimensions[1].code;
		assertTrue(hasError(variables.validator.validate(variables.definitions), "DUPLICATE_KEY"));
	}

	/**
	 * A section whose parent is not a section of this version. The self-referencing foreign key and
	 * FK_section_parent_same_version stop this in the database; the snapshot side has no such
	 * protection, which is why the rule is here.
	 */
	public void function testBadSectionParentIsReported() {
		variables.definitions.sections[3].parentSectionKey = "sec_does_not_exist";
		assertTrue(hasError(variables.validator.validate(variables.definitions), "MISSING_REFERENCE"));
	}

	/** A section that is its own parent. CK_section_not_self_parent stops this in the database. */
	public void function testSelfParentedSectionIsReported() {
		variables.definitions.sections[3].parentSectionKey = variables.definitions.sections[3].sectionKey;
		assertTrue(hasError(variables.validator.validate(variables.definitions), "SECTION_HIERARCHY_INVALID"));
	}

	/** A parent chain that loops: no root reaches it, so nothing renders it. */
	public void function testSectionCycleIsReported() {
		variables.definitions.sections[1].parentSectionKey = variables.definitions.sections[2].sectionKey;
		variables.definitions.sections[2].parentSectionKey = variables.definitions.sections[1].sectionKey;
		assertTrue(hasError(variables.validator.validate(variables.definitions), "SECTION_HIERARCHY_INVALID"));
	}

	// ---- item, response set and option rules --------------------------------------------------

	public void function testItemWithMissingSectionIsReported() {
		variables.definitions.items[1].sectionKey = "sec_gone";
		assertTrue(hasError(variables.validator.validate(variables.definitions), "MISSING_REFERENCE"));
	}

	public void function testChoiceItemWithoutResponseSetIsReported() {
		for (var it in variables.definitions.items) {
			if (it.itemType == "SINGLE_CHOICE") { it.responseSetKey = javaCast("null", ""); break; }
		}
		assertTrue(hasError(variables.validator.validate(variables.definitions), "ITEM_RESPONSE_SET_REQUIRED"));
	}

	public void function testNonChoiceItemWithAResponseSetIsReported() {
		for (var it in variables.definitions.items) {
			if (it.itemType == "LONG_TEXT") { it.responseSetKey = variables.definitions.responseSets[1].setKey; break; }
		}
		assertTrue(hasError(variables.validator.validate(variables.definitions), "ITEM_RESPONSE_SET_NOT_ALLOWED"));
	}

	public void function testUnsupportedItemTypeIsReported() {
		variables.definitions.items[1].itemType = "TELEPATHY";
		assertTrue(hasError(variables.validator.validate(variables.definitions), "INVALID_ENUM"));
	}

	public void function testResponseSetUsedByAnItemButEmptyIsReported() {
		var setKey = "";
		for (var it in variables.definitions.items) {
			if (!isNull(it.responseSetKey) && len(it.responseSetKey)) { setKey = it.responseSetKey; break; }
		}
		var kept = [];
		for (var op in variables.definitions.responseOptions) if (op.setKey != setKey) arrayAppend(kept, op);
		variables.definitions.responseOptions = kept;
		assertTrue(hasError(variables.validator.validate(variables.definitions), "RESPONSE_SET_EMPTY"));
	}

	public void function testInvalidSelectionModeIsReported() {
		variables.definitions.responseSets[1].selectionMode = "PICK_ANY";
		assertTrue(hasError(variables.validator.validate(variables.definitions), "INVALID_ENUM"));
	}

	public void function testOptionOrderOutOfRangeIsReported() {
		variables.definitions.responseOptions[1].displayOrder = 1000000;
		assertTrue(hasError(variables.validator.validate(variables.definitions), "INVALID_ORDER"));
	}

	public void function testDuplicateOptionOrderIsReported() {
		var first = variables.definitions.responseOptions[1];
		for (var op in variables.definitions.responseOptions) {
			if (op.setKey == first.setKey && op.optionKey != first.optionKey) { op.displayOrder = first.displayOrder; break; }
		}
		assertTrue(hasError(variables.validator.validate(variables.definitions), "DUPLICATE_ORDER"));
	}

	public void function testBlankOptionLabelIsReported() {
		variables.definitions.responseOptions[1].label = "  ";
		assertTrue(hasError(variables.validator.validate(variables.definitions), "BLANK_VALUE"));
	}

	// ---- rule semantics -------------------------------------------------------------------------

	public void function testUnsupportedRuleEffectIsReported() {
		variables.definitions.rules[1].effect = "HIDE";
		assertTrue(hasError(variables.validator.validate(variables.definitions), "UNSUPPORTED_EFFECT"));
	}

	public void function testInvalidRuleEffectIsReported() {
		variables.definitions.rules[1].effect = "EXPLODE";
		assertTrue(hasError(variables.validator.validate(variables.definitions), "INVALID_ENUM"));
	}

	public void function testRuleWithMissingTargetIsReported() {
		variables.definitions.rules[1].targetKey = "nothing_here";
		assertTrue(hasError(variables.validator.validate(variables.definitions), "MISSING_REFERENCE"));
	}

	public void function testRuleWithMissingSourceIsReported() {
		variables.definitions.rules[1].sourceKey = "nothing_here";
		variables.definitions.rules[1].conditions.conditions[1].sourceKey = "nothing_here";
		assertTrue(hasError(variables.validator.validate(variables.definitions), "MISSING_REFERENCE"));
	}

	public void function testInvalidRuleOperatorIsReported() {
		variables.definitions.rules[1].operator = "SORT_OF";
		assertTrue(hasError(variables.validator.validate(variables.definitions), "INVALID_ENUM"));
	}

	public void function testConditionsDocumentShapeIsReported() {
		variables.definitions.rules[1].conditions = { "logic": "MAYBE", "conditions": [] };
		assertTrue(hasError(variables.validator.validate(variables.definitions), "CONDITIONS_SHAPE"));
	}

	public void function testMissingConditionsDocumentIsReported() {
		variables.definitions.rules[1].conditions = javaCast("null", "");
		assertTrue(hasError(variables.validator.validate(variables.definitions), "CONDITIONS_SHAPE"));
	}

	public void function testInConditionWithoutAnArrayIsReported() {
		var rule = variables.definitions.rules[1];
		rule.operator = "IN";
		rule.conditions.conditions[1].operator = "IN";
		rule.conditions.conditions[1].comparisonValue = "not-an-array";
		rule.comparisonValue = "not-an-array";
		assertTrue(hasError(variables.validator.validate(variables.definitions), "CONDITIONS_SHAPE"));
	}

	public void function testFlatFieldsDisagreeingWithTheDocumentAreReported() {
		variables.definitions.rules[1].operator = "NOT_EQUALS";
		assertTrue(hasError(variables.validator.validate(variables.definitions), "CONDITION_MISMATCH"));
	}

	// ---- dimensions, values and placements ---------------------------------------------------

	public void function testInvalidDimensionDataTypeIsReported() {
		variables.definitions.dimensions[1].dataType = "COLOUR";
		assertTrue(hasError(variables.validator.validate(variables.definitions), "INVALID_ENUM"));
	}

	public void function testDimensionValueWithMissingDimensionIsReported() {
		variables.definitions.dimensionValues[1].dimensionCode = "no_such_dimension";
		assertTrue(hasError(variables.validator.validate(variables.definitions), "MISSING_REFERENCE"));
	}

	public void function testDuplicateDimensionValueOrderIsReported() {
		var first = variables.definitions.dimensionValues[1];
		for (var v in variables.definitions.dimensionValues) {
			if (v.dimensionCode == first.dimensionCode && v.valueCode != first.valueCode) { v.displayOrder = first.displayOrder; break; }
		}
		assertTrue(hasError(variables.validator.validate(variables.definitions), "DUPLICATE_ORDER"));
	}

	public void function testInvalidEffectiveInstantIsReported() {
		variables.definitions.dimensionValues[1].effectiveStart = "yesterday";
		assertTrue(hasError(variables.validator.validate(variables.definitions), "INVALID_INSTANT"));
	}

	public void function testPlacementWithMissingDimensionIsReported() {
		variables.definitions.instrumentDimensions[1].dimensionCode = "no_such_dimension";
		assertTrue(hasError(variables.validator.validate(variables.definitions), "MISSING_REFERENCE"));
	}

	public void function testPlacementWithMissingRuleIsReported() {
		variables.definitions.instrumentDimensions[1].ruleKey = "no_such_rule";
		assertTrue(hasError(variables.validator.validate(variables.definitions), "MISSING_REFERENCE"));
	}

	public void function testPlacementWithMissingSectionIsReported() {
		variables.definitions.instrumentDimensions[1].sectionKey = "no_such_section";
		assertTrue(hasError(variables.validator.validate(variables.definitions), "MISSING_REFERENCE"));
	}

	public void function testRetiredSipContentIsReported() {
		variables.definitions.sections[2].title = "School Improvement (SIP) Goals";
		assertTrue(hasError(variables.validator.validate(variables.definitions), "RETIRED_CONTENT_PRESENT"));
	}

	/** Reported paths are rooted at the caller's path, so publish can say which copy failed. */
	public void function testErrorPathsAreRootedAtTheCallersPath() {
		variables.definitions.items[1].itemType = "TELEPATHY";
		var r = variables.validator.validate(variables.definitions, { "path": "$.persistedDefinitions" });
		var found = false;
		for (var e in r.errors) if (left(e.path, len("$.persistedDefinitions.items")) == "$.persistedDefinitions.items") found = true;
		assertTrue(found, "expected a path under $.persistedDefinitions.items: " & errorSummary(r));
	}

	// ---- the snapshot envelope -----------------------------------------------------------------

	public void function testAValidEnvelopeIsAccepted() {
		var r = variables.validator.validateEnvelope(envelope(), { "versionLabel": "v1", "instrumentCode": "ICFWALK" });
		assertTrue(r.valid, "Expected no envelope errors: " & (arrayLen(r.errors) ? serializeJSON(r.errors[1]) : ""));
	}

	public void function testUnknownSnapshotFormatIsReported() {
		var e = envelope();
		e["snapshotFormat"] = "icfwalk-instrument-snapshot/99";
		assertTrue(hasError(variables.validator.validateEnvelope(e), "SNAPSHOT_FORMAT_UNSUPPORTED"));
	}

	public void function testEnvelopeWithoutDefinitionsIsReported() {
		var e = envelope();
		structDelete(e, "definitions");
		assertTrue(hasError(variables.validator.validateEnvelope(e), "SNAPSHOT_SHAPE"));
	}

	public void function testEnvelopeIdentityMismatchIsReported() {
		var r = variables.validator.validateEnvelope(envelope(), { "versionLabel": "a different label", "instrumentCode": "ICFWALK" });
		assertTrue(hasError(r, "SNAPSHOT_IDENTITY_MISMATCH"));
		var r2 = variables.validator.validateEnvelope(envelope(), { "versionLabel": "v1", "instrumentCode": "SOMETHING_ELSE" });
		assertTrue(hasError(r2, "SNAPSHOT_IDENTITY_MISMATCH"));
	}

	public void function testEnvelopeCountsMismatchIsReported() {
		var e = envelope();
		e.counts["items"] = e.counts.items + 3;
		assertTrue(hasError(variables.validator.validateEnvelope(e), "SNAPSHOT_COUNTS_MISMATCH"));
	}

	// ---- helpers --------------------------------------------------------------------------------

	private struct function envelope() {
		return {
			"snapshotFormat": variables.validator.snapshotFormat(),
			"instrument": { "code": "ICFWALK", "name": "ICFWalk" },
			"version": { "versionLabel": "v1" },
			"definitions": variables.definitions,
			"counts": variables.c.snapshotCompiler.countDefinitions(variables.definitions)
		};
	}

	private boolean function hasError(required struct r, required string code) {
		for (var e in arguments.r.errors) if (e.code == arguments.code) return true;
		return false;
	}

	private string function errorSummary(required struct r) {
		var codes = [];
		for (var e in arguments.r.errors) arrayAppend(codes, e.code & "@" & e.path);
		return arrayToList(codes, ", ");
	}
}
