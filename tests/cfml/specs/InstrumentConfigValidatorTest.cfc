component extends="icfwalktests.BaseSpec" output="false" {

	public void function beforeEach() {
		variables.config = repoJson("config/instrument-config.json");
	}

	public void function testSuppliedConfigurationIsValidWithSeventeenPlaceholderWarnings() {
		var r = variables.c.configValidator.validate(variables.config);
		assertTrue(r.valid, "Expected no errors: " & (arrayLen(r.errors) ? r.errors[1].message : ""));
		assertEquals(0, arrayLen(r.errors));
		assertEquals(17, arrayLen(r.placeholders));
		var placeholderWarnings = 0;
		for (var w in r.warnings) if (w.code == "PLACEHOLDER_CONTENT") placeholderWarnings++;
		assertEquals(17, placeholderWarnings);
		assertEquals(17, arrayLen(r.warnings), "Only placeholder warnings are expected for the supplied document.");
	}

	public void function testMissingResponseSetIsReportedWithSpecificReference() {
		removeResponseSet("rs_scale_comp_s1_q1");
		var r = variables.c.configValidator.validate(variables.config);
		assertFalse(r.valid);
		assertTrue(hasError(r, "MISSING_REFERENCE", "rs_scale_comp_s1_q1"), "Expected MISSING_REFERENCE naming rs_scale_comp_s1_q1.");
	}

	public void function testCorruptConditionsJsonIsReported() {
		variables.config.rules[1].conditionsJson = "{not valid json";
		var r = variables.c.configValidator.validate(variables.config);
		assertFalse(r.valid);
		assertTrue(hasError(r, "INVALID_JSON", variables.config.rules[1].ruleKey));
	}

	public void function testDuplicateItemKeyIsReported() {
		variables.config.items[2].itemKey = variables.config.items[1].itemKey;
		var r = variables.c.configValidator.validate(variables.config);
		assertTrue(hasError(r, "DUPLICATE_KEY", variables.config.items[1].itemKey));
	}

	public void function testBadParentSectionIsReported() {
		variables.config.sections[3].parentSectionId = "sec_does_not_exist";
		var r = variables.c.configValidator.validate(variables.config);
		assertTrue(hasError(r, "MISSING_REFERENCE", "sec_does_not_exist"));
	}

	public void function testDuplicateOptionOrderIsReported() {
		var first = variables.config.responseOptions[1];
		for (var op in variables.config.responseOptions) {
			if (op.responseSetId == first.responseSetId && op.optionId != first.optionId) { op.displayOrder = first.displayOrder; break; }
		}
		var r = variables.c.configValidator.validate(variables.config);
		assertTrue(hasError(r, "DUPLICATE_ORDER", ""));
	}

	public void function testUnsupportedRuleEffectIsReported() {
		variables.config.rules[1].effect = "HIDE";
		var r = variables.c.configValidator.validate(variables.config);
		assertTrue(hasError(r, "UNSUPPORTED_EFFECT", variables.config.rules[1].ruleKey));
	}

	public void function testConditionMismatchIsReported() {
		variables.config.rules[1].operator = "NOT_IN";
		var r = variables.c.configValidator.validate(variables.config);
		assertTrue(hasError(r, "CONDITION_MISMATCH", variables.config.rules[1].ruleKey));
	}

	public void function testRetiredSipContentIsRejected() {
		variables.config.sections[2].title = "School Improvement (SIP) Goals";
		var r = variables.c.configValidator.validate(variables.config);
		assertTrue(hasError(r, "RETIRED_CONTENT_PRESENT", ""));
	}

	public void function testNonDraftStatusIsRejected() {
		variables.config.instrument.version.status = "PUBLISHED";
		var r = variables.c.configValidator.validate(variables.config);
		assertTrue(hasError(r, "VERSION_STATUS_NOT_DRAFT", ""));
	}

	public void function testChoiceItemWithoutResponseSetIsRejected() {
		for (var it in variables.config.items) {
			if (it.itemType == "SINGLE_CHOICE") { it.responseSetId = javaCast("null", ""); break; }
		}
		var r = variables.c.configValidator.validate(variables.config);
		assertTrue(hasError(r, "ITEM_RESPONSE_SET_REQUIRED", ""));
	}

	public void function testStructuralFailureStopsEarlyWithoutCrashing() {
		var r = variables.c.configValidator.validate({ "instrument": {} });
		assertFalse(r.valid);
		assertTrue(hasError(r, "STRUCTURE", ""));
		var r2 = variables.c.configValidator.validate("not an object");
		assertFalse(r2.valid);
	}

	// ---- helpers ----------------------------------------------------------------------------

	private void function removeResponseSet(required string id) {
		var kept = [];
		for (var rs in variables.config.responseSets) if (rs.responseSetId != arguments.id) arrayAppend(kept, rs);
		variables.config.responseSets = kept;
		var keptOptions = [];
		for (var op in variables.config.responseOptions) if (op.responseSetId != arguments.id) arrayAppend(keptOptions, op);
		variables.config.responseOptions = keptOptions;
	}

	private boolean function hasError(required struct r, required string code, required string needle) {
		for (var e in arguments.r.errors) {
			if (e.code == arguments.code && (!len(arguments.needle) || find(arguments.needle, e.message))) return true;
		}
		return false;
	}
}
