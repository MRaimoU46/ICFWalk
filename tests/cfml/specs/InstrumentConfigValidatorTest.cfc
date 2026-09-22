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
		for (var w in r.warnings) if (compare(w.code, "PLACEHOLDER_CONTENT") == 0) placeholderWarnings++;
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

	/**
	 * An inbound document must DECLARE that it is a DRAFT.
	 *
	 * THE DEFECT THIS EXISTS FOR. checkInstrument() rejected a non-DRAFT status only when
	 * `instrument.version.status` was present. A document that simply omitted it passed -- while
	 * the component header and docs/DATA_CONTRACT.md both say an inbound document declares DRAFT,
	 * and every other reader treats the declaration as required. So "silence" was accepted as
	 * "DRAFT", which is the one reading a contract with three lifecycle states must not take.
	 *
	 * The status is now required, must be a JSON string, and must equal DRAFT exactly. The contract
	 * is case-sensitive: icf.instrument_version.status is constrained to the three upper-case
	 * literals, so `draft` is not the same declaration as `DRAFT` and is not treated as one.
	 */
	public void function testNonDraftStatusIsRejected() {
		variables.config.instrument.version.status = "PUBLISHED";
		var r = variables.c.configValidator.validate(variables.config);
		assertTrue(hasError(r, "VERSION_STATUS_NOT_DRAFT", ""));
		assertTrue(hasPath(r, "$.instrument.version.status"), "reported at $.instrument.version.status");

		variables.config.instrument.version.status = "RETIRED";
		assertTrue(hasError(variables.c.configValidator.validate(variables.config), "VERSION_STATUS_NOT_DRAFT", ""));
	}

	/** An omitted status is refused: silence is not a DRAFT declaration. */
	public void function testAMissingStatusIsRejected() {
		structDelete(variables.config.instrument.version, "status");
		var r = variables.c.configValidator.validate(variables.config);
		assertFalse(r.valid, "a document that declares no status is not importable");
		assertTrue(hasError(r, "VERSION_STATUS_REQUIRED", ""), "with a stable code: " & errorSummary(r));
		assertTrue(hasPath(r, "$.instrument.version.status"), "at $.instrument.version.status");
	}

	/** A null status is an absent declaration. */
	public void function testANullStatusIsRejected() {
		variables.config.instrument.version.status = javaCast("null", "");
		var r = variables.c.configValidator.validate(variables.config);
		assertFalse(r.valid);
		assertTrue(hasError(r, "VERSION_STATUS_REQUIRED", ""), "with a stable code: " & errorSummary(r));
	}

	/** A status that is not a JSON string is a type error, not a value error. */
	public void function testANonStringStatusIsRejected() {
		for (var bad in [1, 0, true, false, ["DRAFT"], { "value": "DRAFT" }]) {
			variables.config.instrument.version.status = bad;
			var r = variables.c.configValidator.validate(variables.config);
			assertFalse(r.valid, "a non-string status must be refused");
			assertTrue(hasError(r, "VERSION_STATUS_INVALID", ""), "as a type error: " & errorSummary(r));
			assertTrue(hasPath(r, "$.instrument.version.status"), "at $.instrument.version.status");
		}
	}

	/** A blank status declares nothing. */
	public void function testABlankStatusIsRejected() {
		for (var bad in ["", "   "]) {
			variables.config.instrument.version.status = bad;
			var r = variables.c.configValidator.validate(variables.config);
			assertFalse(r.valid, "a blank status must be refused");
			assertTrue(hasPath(r, "$.instrument.version.status"), "at $.instrument.version.status: " & errorSummary(r));
		}
	}

	/** The contract is case-sensitive, so a lower-case declaration is not a DRAFT declaration. */
	public void function testALowerCaseStatusIsRejected() {
		for (var bad in ["draft", "Draft", "dRaFt"]) {
			variables.config.instrument.version.status = bad;
			var r = variables.c.configValidator.validate(variables.config);
			assertFalse(r.valid, "'" & bad & "' is not the DRAFT the data contract names");
			assertTrue(hasError(r, "VERSION_STATUS_NOT_DRAFT", ""), "reported as the wrong value: " & errorSummary(r));
		}
	}

	/** And the declaration the supplied document actually makes is accepted. */
	public void function testAnExactDraftStatusIsAccepted() {
		variables.config.instrument.version.status = "DRAFT";
		var r = variables.c.configValidator.validate(variables.config);
		assertTrue(r.valid, "a document declaring DRAFT is valid: " & errorSummary(r));
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

	private boolean function hasPath(required struct r, required string path) {
		for (var e in arguments.r.errors) if (structKeyExists(e, "path") && compare(e.path, arguments.path) == 0) return true;
		return false;
	}

	private string function errorSummary(required struct r) {
		var codes = [];
		for (var e in arguments.r.errors) arrayAppend(codes, e.code & "@" & (structKeyExists(e, "path") ? e.path : ""));
		return arrayToList(codes, ", ");
	}

	private boolean function hasError(required struct r, required string code, required string needle) {
		for (var e in arguments.r.errors) {
			if (compare(e.code, arguments.code) == 0 && (!len(arguments.needle) || find(arguments.needle, e.message))) return true;
		}
		return false;
	}
}
