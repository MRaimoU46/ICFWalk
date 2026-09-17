/**
 * Visibility engine: rule evaluation, grade filtering, response states, and normalization.
 * The shared vectors (tests/fixtures/visibility-vectors.json) are the parity contract with
 * app/assets/js/rules.js; the explicit cases below pin the acceptance behaviors (COND-01..13).
 */
component extends="icfwalktests.BaseSpec" output="false" {

	public void function beforeAll() {
		var normalized = variables.c.configNormalizer.fromConfig(repoJson("config/instrument-config.json"));
		var compiled = variables.c.snapshotCompiler.compile(normalized);
		variables.model = variables.c.renderModelBuilder.build(compiled.snapshot);
		variables.engine = variables.c.visibilityEngine;
		variables.vectors = repoJson("tests/fixtures/visibility-vectors.json");
	}

	private string function canon(required any value) { return variables.c.canonicalJson.serialize(arguments.value); }

	private struct function state(struct dimensions = {}, struct responses = {}) {
		return { "dimensions": arguments.dimensions, "responses": arguments.responses };
	}

	public void function testMatchesTheSharedVectorsExactly() {
		assertEquals("icfwalk-visibility-vectors/1", variables.vectors.format);
		assertTrue(arrayLen(variables.vectors.vectors) >= 25);
		for (var v in variables.vectors.vectors) {
			var ev = variables.engine.evaluateVisibility(variables.model, v.state);
			var hiddenItems = [];
			for (var key in structKeyArray(ev.items)) if (!ev.items[key]) arrayAppend(hiddenItems, key);
			arraySort(hiddenItems, "text");
			var actual = {
				"sections": ev.sections, "dimensions": ev.dimensions, "dimensionOptions": ev.dimensionOptions,
				"responseStates": ev.responseStates, "dimensionStates": ev.dimensionStates, "hiddenItems": hiddenItems,
				"normalizedRetain": variables.engine.normalize(variables.model, v.state, { "hiddenDimensionPolicy": "RETAIN_HIDDEN" }),
				"normalizedClear": variables.engine.normalize(variables.model, v.state, { "hiddenDimensionPolicy": "CLEAR" })
			};
			assertEquals(canon(v.expected), canon(actual), "Vector '" & v.name & "'.");
		}
	}

	public void function testBlankStateAppliesConfiguredDefaults() {
		var blank = variables.engine.blankState(variables.model);
		assertEquals("no", blank.responses["comp_s3_applicable"].storedCode);
		assertEquals("no", blank.responses["comp_s4_applicable"].storedCode);
		assertEquals(2, structCount(blank.responses), "Only items with a configured default are pre-filled.");
		assertEquals(0, structCount(blank.dimensions));
		var ev = variables.engine.evaluateVisibility(variables.model, blank);
		assertEquals("NOT_APPLICABLE", ev.responseStates["comp_s3_q1"]);
		assertEquals("NOT_APPLICABLE", ev.responseStates["comp_s4_q2"]);
		assertEquals("UNANSWERED", ev.responseStates["comp_s1_q1"]);
		assertFalse(ev.items["comp_s3_q1"], "COND-11: rating rows hidden for a new walk.");
		assertFalse(ev.dimensions["period"], "Period hidden without a grade.");
		assertFalse(ev.sections["prek_k_classroom"]);
	}

	public void function testGradeFilteringFollowsSchoolGroup() {
		var e = variables.engine.evaluateVisibility(variables.model, state({ "school": { "selectedValueCode": "bartlett_elementary_school" } }));
		assertEquals(["prek", "k", "1", "2", "3", "4", "5"], e.dimensionOptions["grade"], "COND-01");
		e = variables.engine.evaluateVisibility(variables.model, state({ "school": { "selectedValueCode": "abbott_middle_school" } }));
		assertEquals(["6", "7", "8"], e.dimensionOptions["grade"], "COND-02");
		for (var code in ["elgin_high_school", "dream_academy", "central_school"]) {
			e = variables.engine.evaluateVisibility(variables.model, state({ "school": { "selectedValueCode": code } }));
			assertEquals(["9", "10", "11", "12"], e.dimensionOptions["grade"], "COND-03 " & code);
		}
		e = variables.engine.evaluateVisibility(variables.model, state({ "school": { "selectedValueCode": "other", "otherText": "Somewhere" } }));
		assertEquals(14, arrayLen(e.dimensionOptions["grade"]), "COND-04");
		e = variables.engine.evaluateVisibility(variables.model, state());
		assertEquals(14, arrayLen(e.dimensionOptions["grade"]), "No school: full list.");
	}

	public void function testInvalidGradeIsClearedAndDependentVisibilityRecalculates() {
		var st = state({ "school": { "selectedValueCode": "bartlett_elementary_school" }, "grade": { "selectedValueCode": "5" } });
		var before = variables.engine.evaluateVisibility(variables.model, st);
		assertTrue(before.dimensionStates["grade"] == "ANSWERED");
		st.dimensions["school"] = { "selectedValueCode": "abbott_middle_school" };
		var n = variables.engine.normalize(variables.model, st);
		assertEquals(1, arrayLen(n.changes));
		assertEquals("DIMENSION_CLEARED", n.changes[1].kind);
		assertEquals("grade", n.changes[1].key);
		assertEquals("OPTION_FILTER", n.changes[1].reason);
		assertEquals("UNANSWERED", variables.engine.evaluateVisibility(variables.model, n.state).dimensionStates["grade"], "COND-05");
		// PreK selection then a high school: PreK-K section disappears with the cleared grade.
		st = state({ "school": { "selectedValueCode": "bartlett_elementary_school" }, "grade": { "selectedValueCode": "prek" } });
		assertTrue(variables.engine.evaluateVisibility(variables.model, st).sections["prek_k_classroom"]);
		st.dimensions["school"] = { "selectedValueCode": "elgin_high_school" };
		n = variables.engine.normalize(variables.model, st);
		assertFalse(variables.engine.evaluateVisibility(variables.model, n.state).sections["prek_k_classroom"], "COND-05 dependent visibility.");
	}

	public void function testPeriodVisibilityAndHiddenRetentionPolicy() {
		for (var g in ["6", "7", "8", "9", "10", "11", "12"]) {
			assertTrue(variables.engine.evaluateVisibility(variables.model, state({ "grade": { "selectedValueCode": g } })).dimensions["period"], "COND-06 grade " & g);
		}
		for (var g in ["prek", "k", "1", "2", "3", "4", "5"]) {
			assertFalse(variables.engine.evaluateVisibility(variables.model, state({ "grade": { "selectedValueCode": g } })).dimensions["period"], "COND-06 grade " & g);
		}
		var st = state({ "grade": { "selectedValueCode": "3" }, "period": { "selectedValueCode": "third" } });
		var retained = variables.engine.normalize(variables.model, st);
		assertEquals(0, arrayLen(retained.changes), "RETAIN_HIDDEN keeps the period value.");
		assertEquals("HIDDEN", variables.engine.evaluateVisibility(variables.model, retained.state).dimensionStates["period"]);
		var cleared = variables.engine.normalize(variables.model, st, { "hiddenDimensionPolicy": "CLEAR" });
		assertEquals(1, arrayLen(cleared.changes));
		assertEquals("HIDDEN_CLEAR", cleared.changes[1].reason);
		assertEquals(0, structCount(cleared.state.dimensions["period"]));
	}

	public void function testConditionalClassroomSectionsFollowGradeClassTypeAndContent() {
		var conditional = ["prek_k_classroom", "dual_language_classroom", "mac_prep_classroom", "ignite_classroom", "avid_classroom", "esl_classroom", "content_area_look_fors"];
		var expectOnly = function(required struct st, required array visibleKeys, required string label) {
			var e = variables.engine.evaluateVisibility(variables.model, st);
			for (var key in conditional) assertEquals(arrayContains(visibleKeys, key) ? true : false, e.sections[key], label & " " & key);
		};
		expectOnly(state({ "grade": { "selectedValueCode": "prek" } }), ["prek_k_classroom"], "COND-07 PreK");
		expectOnly(state({ "grade": { "selectedValueCode": "k" } }), ["prek_k_classroom"], "COND-07 K");
		expectOnly(state({ "grade": { "selectedValueCode": "1" } }), [], "COND-07 grade 1");
		expectOnly(state({ "classType": { "selectedValueCode": "dual_language" } }), ["dual_language_classroom"], "COND-08");
		expectOnly(state({ "classType": { "selectedValueCode": "mac" } }), ["mac_prep_classroom"], "COND-08");
		expectOnly(state({ "classType": { "selectedValueCode": "prep" } }), ["mac_prep_classroom"], "COND-08");
		expectOnly(state({ "classType": { "selectedValueCode": "ignite" } }), ["ignite_classroom"], "COND-08");
		expectOnly(state({ "classType": { "selectedValueCode": "avid" } }), ["avid_classroom"], "COND-08");
		expectOnly(state({ "classType": { "selectedValueCode": "esl" } }), ["esl_classroom"], "COND-08");
		expectOnly(state({ "classType": { "selectedValueCode": "general_education" } }), [], "COND-08");
		for (var c in ["art", "music", "cte"]) expectOnly(state({ "content": { "selectedValueCode": c } }), ["content_area_look_fors"], "COND-09 " & c);
		expectOnly(state({ "content": { "selectedValueCode": "ela" } }), [], "COND-09 ela");
		// The "Other" free text never satisfies a rule.
		expectOnly(state({ "classType": { "selectedValueCode": "other", "otherText": "AVID" } }), [], "Other text is not a match");
	}

	public void function testHiddenConditionalAnswersAreRetainedAndReappear() {
		var st = state({ "grade": { "selectedValueCode": "prek" } }, { "prek_k_q2": { "storedCode": "yes" }, "prek_k_notes": { "textValue": "n" } });
		assertEquals("ANSWERED", variables.engine.evaluateVisibility(variables.model, st).responseStates["prek_k_q2"]);
		st.dimensions["grade"] = { "selectedValueCode": "2" };
		var n = variables.engine.normalize(variables.model, st);
		assertEquals(0, arrayLen(n.changes), "COND-10: hidden answers are not cleared.");
		assertEquals("HIDDEN", variables.engine.evaluateVisibility(variables.model, n.state).responseStates["prek_k_q2"]);
		assertEquals("HIDDEN", variables.engine.evaluateVisibility(variables.model, n.state).responseStates["prek_k_notes"]);
		n.state.dimensions["grade"] = { "selectedValueCode": "k" };
		assertEquals("ANSWERED", variables.engine.evaluateVisibility(variables.model, n.state).responseStates["prek_k_q2"], "COND-10: value reappears.");
	}

	public void function testSkippableComponentClearsRatingsKeepsNotesAndReturnsUnanswered() {
		var st = state({}, { "comp_s3_applicable": { "storedCode": "yes" }, "comp_s3_q1": { "storedCode": "4" }, "comp_s3_q2": { "storedCode": "5" }, "comp_s3_notes": { "textValue": "keep me" } });
		var e = variables.engine.evaluateVisibility(variables.model, st);
		assertTrue(e.items["comp_s3_q1"] && e.items["comp_s3_q2"]);
		assertEquals("ANSWERED", e.responseStates["comp_s3_q1"]);
		st.responses["comp_s3_applicable"] = { "storedCode": "no" };
		var n = variables.engine.normalize(variables.model, st);
		assertEquals(2, arrayLen(n.changes), "COND-12: both ratings cleared.");
		assertEquals("RESPONSE_CLEARED", n.changes[1].kind);
		assertEquals("NOT_APPLICABLE", n.changes[1].reason);
		assertEquals("keep me", n.state.responses["comp_s3_notes"].textValue, "COND-12: notes retained.");
		e = variables.engine.evaluateVisibility(variables.model, n.state);
		assertFalse(e.items["comp_s3_q1"]);
		assertEquals("NOT_APPLICABLE", e.responseStates["comp_s3_q1"]);
		assertEquals("ANSWERED", e.responseStates["comp_s3_notes"]);
		n.state.responses["comp_s3_applicable"] = { "storedCode": "yes" };
		e = variables.engine.evaluateVisibility(variables.model, n.state);
		assertEquals("UNANSWERED", e.responseStates["comp_s3_q1"], "COND-13: cleared ratings do not reappear.");
		assertEquals("UNANSWERED", e.responseStates["comp_s3_q2"]);
		assertEquals("ANSWERED", e.responseStates["comp_s3_notes"]);
		// A non-skippable component is never NOT_APPLICABLE.
		assertEquals("UNANSWERED", e.responseStates["comp_s1_q1"]);
	}

	public void function testAnsweredRequiresAValidOptionAndUnansweredIsNeverNumeric() {
		var e = variables.engine.evaluateVisibility(variables.model, state({}, { "comp_s1_q1": { "storedCode": "0" }, "comp_s1_q2": { "storedCode": "3" }, "p1q1": { "storedCode": "Partial" } }));
		assertEquals("UNANSWERED", e.responseStates["comp_s1_q1"], "COND-15: a code outside the set is not an answer.");
		assertEquals("ANSWERED", e.responseStates["comp_s1_q2"]);
		assertEquals("ANSWERED", e.responseStates["p1q1"]);
		assertEquals("UNANSWERED", e.responseStates["conditions_b1"]);
		assertFalse(structKeyExists(e.responseStates, "part2_s1_student_1"), "Display items carry no response state.");
	}

	public void function testUnsupportedOperatorsAreRefused() {
		var model = duplicate(variables.model);
		structDelete(model, "__index");
		model.rules[1].conditions.conditions[1].operator = "MATCHES";
		assertThrows(function() { variables.engine.evaluateVisibility(model, state()); }, "ICFWalk.Configuration", "RULE_OPERATOR_UNSUPPORTED");
	}
}
