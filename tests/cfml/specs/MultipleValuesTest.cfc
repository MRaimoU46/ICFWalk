/**
 * Instrument revision 2026-10-14, step 2: visit fields a walk can hold several values of (the
 * prototype's checkboxes for Grade level, Content / Subject Area, Program and Visit timing), on the
 * CFML side with no database: the authoring rules for a placement's settings.multiple, the render
 * model, the visibility engine (tests/fixtures/visibility-vectors-multiple.json is the parity contract
 * with app/assets/js/rules.js), the save validator, and the summary.
 *
 * Storage, reports and releases against SQL Server, and the editor, are
 * tests/node/browser-multiple.test.mjs.
 */
component extends="icfwalktests.BaseSpec" output="false" {

	public void function beforeAll() {
		var normalized = variables.c.configNormalizer.fromConfig(repoJson("config/instrument-config-2026-10-14.json"));
		variables.definitions = normalized.definitions;
		variables.model = variables.c.renderModelBuilder.build(variables.c.snapshotCompiler.compile(normalized).snapshot);
		variables.engine = variables.c.visibilityEngine;
		variables.vectors = repoJson("tests/fixtures/visibility-vectors-multiple.json");
		variables.index = fakeIndex(variables.model);
	}

	// ---- the instrument -----------------------------------------------------------------------

	/** Exactly the four checkbox fields take several values, in the model and on their placements. */
	public void function testTheFourCheckboxFieldsTakeSeveralValues() {
		for (var code in ["grade", "content", "classType", "visitTiming"]) assertTrue(variables.model.dimensions[code].multiple, code);
		for (var code in ["date", "observer", "school", "topic"]) assertFalse(variables.model.dimensions[code].multiple, code);
		assertFalse(structKeyExists(variables.model.dimensions, "period"), "Period is not in this version (owner, 2026-10-24)");
		var visit = findSection(variables.model.root, "visit_information");
		assertEquals(7, arrayLen(visit.placements), "the visit fields");
		for (var p in visit.placements) {
			assertEquals(variables.model.dimensions[p.dimensionCode].multiple, p.multiple, "placement " & p.dimensionCode);
		}
		// The 2026-09-17 version has no such field.
		var earlier = variables.c.renderModelBuilder.build(variables.c.snapshotCompiler.compile(variables.c.configNormalizer.fromConfig(repoJson("config/instrument-config.json"))).snapshot);
		for (var code in structKeyArray(earlier.dimensions)) assertFalse(earlier.dimensions[code].multiple, "2026-09-17 " & code);
	}

	/** The authoring rules: a boolean, on a list, with codes a release can combine and store. */
	public void function testTheValidatorRefusesWhatSeveralValuesCannotBe() {
		var ok = variables.c.definitionValidator.validate(duplicate(variables.definitions));
		assertTrue(ok.valid, "the 2026-10-14 definitions are valid: " & (arrayLen(ok.errors) ? serializeJSON(ok.errors[1]) : ""));

		var d = duplicate(variables.definitions);
		placementOf(d, "grade").settings["multiple"] = "true";
		assertTrue(hasError(variables.c.definitionValidator.validate(d), "MULTIPLE_SETTING_INVALID"), "a string is not true");

		d = duplicate(variables.definitions);
		placementOf(d, "topic").settings["multiple"] = true;
		assertTrue(hasError(variables.c.definitionValidator.validate(d), "MULTIPLE_NOT_A_LIST"), "typed text has no values to select");

		d = duplicate(variables.definitions);
		valueOf(d, "grade", "7").valueCode = "7+8";
		assertTrue(hasError(variables.c.definitionValidator.validate(d), "MULTIPLE_VALUE_CODE_INVALID"), "a '+' would make a combination ambiguous");

		d = duplicate(variables.definitions);
		var n = 0;
		for (var v in d.dimensionValues) {
			if (compare(v.dimensionCode, "content") != 0) continue;
			n++;
			v.valueCode = "a_content_value_code_long_enough_to_matter_" & n;
		}
		assertTrue(hasError(variables.c.definitionValidator.validate(d), "MULTIPLE_CODES_TOO_LONG"), "every code joined must fit a release cell");

		d = duplicate(variables.definitions);
		placementOf(d, "school").settings["multiple"] = true;
		assertTrue(hasError(variables.c.definitionValidator.validate(d), "OPTION_FILTER_SOURCE_MULTIPLE"), "the grade filter reads one school");

		d = duplicate(variables.definitions);
		placementOf(d, "grade").settings["multiple"] = false;
		assertTrue(variables.c.definitionValidator.validate(d).valid, "false is a valid setting: one value");
	}

	// ---- the engine ---------------------------------------------------------------------------

	/** Parity with the JavaScript engine on every shared vector. */
	public void function testMatchesTheSharedMultipleVectorsExactly() {
		assertExactTextEquals("icfwalk-visibility-vectors/1", variables.vectors.format);
		assertTrue(arrayLen(variables.vectors.vectors) >= 10);
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
			assertExactTextEquals(canon(v.expected), canon(actual), "Vector '" & v.name & "'.");
		}
	}

	/** EQUALS and IN hold when any value matches; NOT_EQUALS and NOT_IN when none does. */
	public void function testOperatorsReadEveryValue() {
		var m = duplicate(variables.model);
		var rule = {};
		for (var r in m.rules) if (compare(r.ruleKey, "show_content_area") == 0) rule = r;
		assertFalse(structIsEmpty(rule), "the content-area rule");
		rule.conditions.conditions[1].operator = "NOT_IN";
		rule.conditions.conditions[1].comparisonValue = ["math", "ELA"];
		assertFalse(cardShown(m, ["math", "visual_arts"]), "NOT_IN: math is among the values");
		assertTrue(cardShown(m, ["visual_arts", "pe"]), "NOT_IN: none of them is listed");
		assertTrue(cardShown(m, []), "NOT_IN: no value is listed");
		rule.conditions.conditions[1].operator = "NOT_EQUALS";
		rule.conditions.conditions[1].comparisonValue = "Math";
		assertFalse(cardShown(m, ["ela", "math"]), "NOT_EQUALS: Math is among the values (by label)");
		assertTrue(cardShown(m, ["ela", "pe"]));
		rule.conditions.conditions[1].operator = "EQUALS";
		assertTrue(cardShown(m, ["ela", "math"]), "EQUALS: Math is among the values");
		assertFalse(cardShown(m, ["ela", "pe"]));
	}

	/** A school change keeps the grades it allows (DIMENSION_VALUES_REMOVED) and Other's text with Other. */
	public void function testNarrowingKeepsWhatTheSchoolAllows() {
		var n = variables.engine.normalize(variables.model, {
			"dimensions": { "school": { "selectedValueCode": "abbott_middle_school" }, "grade": { "selectedValueCodes": ["5", "6", "7"] } }, "responses": {}
		});
		assertExactJsonEquals(["6", "7"], n.state.dimensions.grade.selectedValueCodes);
		assertEquals(1, arrayLen(n.changes));
		assertExactTextEquals("DIMENSION_VALUES_REMOVED", n.changes[1].kind);
		assertExactTextEquals("grade", n.changes[1].key);
		n = variables.engine.normalize(variables.model, {
			"dimensions": { "school": { "selectedValueCode": "bartlett_elementary_school" }, "grade": { "selectedValueCodes": ["7", "8"] } }, "responses": {}
		});
		assertTrue(structIsEmpty(n.state.dimensions.grade), "nothing left: the field is cleared");
		assertExactTextEquals("DIMENSION_CLEARED", n.changes[1].kind);
	}

	// ---- the save validator -------------------------------------------------------------------

	/** Several values arrive as selectedValueCodes, are checked one by one, and are put in order. */
	public void function testTheSaveValidatorChecksAndOrdersSeveralValues() {
		var v = variables.c.walkPayloadValidator.validate(variables.model, variables.index, {
			"dimensions": {
				"grade": { "selectedValueCodes": ["8", "7"] },
				"content": { "selectedValueCodes": ["other", "ela"], "otherText": "Robotics" },
				"classType": { "selectedValueCodes": ["dhh"], "otherText": "dropped: Other is not selected" },
				"visitTiming": { "selectedValueCodes": [] },
				"school": { "selectedValueCode": "abbott_middle_school" }
			},
			"responses": {}
		});
		assertExactJsonEquals(["7", "8"], v.state.dimensions.grade.selectedValueCodes, "the version's order");
		assertExactJsonEquals([variables.index.values[variables.index.dimensions.grade]["7"], variables.index.values[variables.index.dimensions.grade]["8"]], v.resolved.dimensions.grade.valueIds);
		assertExactJsonEquals(["ela", "other"], v.state.dimensions.content.selectedValueCodes);
		assertExactTextEquals("Robotics", v.state.dimensions.content.otherText);
		assertFalse(structKeyExists(v.state.dimensions.classType, "otherText"), "Other's text goes only with Other");
		assertFalse(structKeyExists(v.state.dimensions, "visitTiming"), "an empty list is no value");
		assertExactTextEquals("abbott_middle_school", v.state.dimensions.school.selectedValueCode, "a field that takes one value keeps its shape");

		assertRefused({ "grade": { "selectedValueCodes": ["7", "7"] } }, "dimensions.grade.selectedValueCodes[1]", "listed twice");
		assertRefused({ "grade": { "selectedValueCodes": ["7", "13"] } }, "dimensions.grade.selectedValueCodes[1]", "not a value");
		assertRefused({ "grade": { "selectedValueCodes": ["7", 8] } }, "dimensions.grade.selectedValueCodes[1]", "a number");
		assertRefused({ "grade": { "selectedValueCodes": "7" } }, "dimensions.grade.selectedValueCodes", "not an array");
		assertRefused({ "grade": { "selectedValueCode": "7" } }, "dimensions.grade.selectedValueCode", "one value for a field that takes several");
		assertRefused({ "school": { "selectedValueCodes": ["abbott_middle_school"] } }, "dimensions.school.selectedValueCodes", "several values for a field that takes one");
	}

	// ---- the summary --------------------------------------------------------------------------

	/** Several values print as the prototype's metaDisplay does, and name the file and the email. */
	public void function testTheSummaryListsSeveralValues() {
		var st = {
			"dimensions": {
				"date": { "dateValue": "2026-10-15" },
				"grade": { "selectedValueCodes": ["7", "8"] },
				"content": { "selectedValueCodes": ["ela", "other"], "otherText": "Robotics" },
				"classType": { "selectedValueCodes": ["dhh", "esl"] },
				"visitTiming": { "selectedValueCodes": ["beginning_of_lesson", "middle_of_the_lesson"] }
			},
			"responses": {}
		};
		var ev = variables.engine.evaluateVisibility(variables.model, st);
		var formatter = variables.c.walkSummaryFormatter;
		var lines = listToArray(formatter.summaryText(variables.model, st, ev), chr(10), true);
		for (var expected in ["Grade level: 7, 8", "Content / Subject Area: ELA, Robotics", "Program: DHH, ESL", "Visit occurred at the: Beginning of Lesson, Middle of the Lesson"]) {
			assertTrue(arrayFind(lines, expected) > 0, "summary line " & expected);
		}
		assertExactTextEquals("ICFWalk_7_8_ELA_Robotics_2026-10-15.txt", formatter.fileName(variables.model, st, ev, "walk-id"));
		var draft = formatter.emailDraft(variables.model, st, ev, []);
		assertTrue(find(" 7, 8 ELA, Robotics", draft.subject) > 0, "subject: " & draft.subject);
		assertTrue(find(" in 7, 8 ELA, Robotics on 2026-10-15.", draft.body) > 0, "body names the grades and contents");
	}

	// ---- helpers ------------------------------------------------------------------------------

	private string function canon(required any value) { return variables.c.canonicalJson.serialize(arguments.value); }

	private boolean function cardShown(required struct m, required array contents) {
		var st = { "dimensions": {}, "responses": {} };
		if (arrayLen(arguments.contents)) st.dimensions["content"] = { "selectedValueCodes": arguments.contents };
		return variables.engine.evaluateVisibility(arguments.m, st).sections["content_area_look_fors"];
	}

	private void function assertRefused(required struct dims, required string path, required string why) {
		var refused = false;
		try {
			variables.c.walkPayloadValidator.validate(variables.model, variables.index, { "dimensions": arguments.dims, "responses": {} });
		} catch (any e) {
			refused = true;
			assertExactTextEquals("ICFWalk.Validation", e.type, arguments.why);
			var paths = [];
			for (var i in deserializeJSON(e.extendedInfo).issues) arrayAppend(paths, i.path);
			assertTrue(arrayFind(paths, arguments.path) > 0, arguments.why & ": " & serializeJSON(paths));
		}
		assertTrue(refused, arguments.why & ": refused");
	}

	/** The definition index the save path reads from SQL Server, made from the model: codes to ids. */
	private struct function fakeIndex(required struct m) {
		var idx = { "versionId": "MULTIPLE-VALUES-SPEC", "checksum": "spec", "items": {}, "options": {}, "dimensions": {}, "values": {}, "multiple": {} };
		for (var code in structKeyArray(arguments.m.dimensions)) {
			var dimensionId = "D-" & uCase(code);
			idx.dimensions[code] = dimensionId;
			idx.values[dimensionId] = {};
			for (var v in arguments.m.dimensions[code].values) idx.values[dimensionId][v.valueCode] = "V-" & uCase(code) & "-" & uCase(v.valueCode);
			if (arguments.m.dimensions[code].multiple) idx.multiple[code] = true;
		}
		return idx;
	}

	private struct function placementOf(required struct d, required string code) {
		for (var p in arguments.d.instrumentDimensions) if (compare(p.dimensionCode, arguments.code) == 0) return p;
		fail("no placement " & arguments.code);
	}

	private struct function valueOf(required struct d, required string code, required string valueCode) {
		for (var v in arguments.d.dimensionValues) if (compare(v.dimensionCode, arguments.code) == 0 && compare(v.valueCode, arguments.valueCode) == 0) return v;
		fail("no value " & arguments.code & " " & arguments.valueCode);
	}

	private boolean function hasError(required struct r, required string code) {
		for (var e in arguments.r.errors) if (compare(e.code, arguments.code) == 0) return true;
		return false;
	}

	private struct function findSection(required struct node, required string key) {
		if (arguments.node.sectionKey == arguments.key) return arguments.node;
		for (var child in arguments.node.children) {
			var hit = findSection(child, arguments.key);
			if (!structIsEmpty(hit)) return hit;
		}
		return {};
	}
}
