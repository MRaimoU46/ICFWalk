/**
 * Proves the render model is derived from the canonical instrument configuration rather than from
 * hard-coded content: structure, ordering, layouts, numbering, placements, derived applicability,
 * definitions, and placeholder flags all come from config/instrument-config.json compiled through
 * the same path the importer uses (golden checksum).
 */
component extends="icfwalktests.BaseSpec" output="false" {

	public void function beforeAll() {
		variables.config = repoJson("config/instrument-config.json");
		var normalized = variables.c.configNormalizer.fromConfig(variables.config);
		variables.compiled = variables.c.snapshotCompiler.compile(normalized);
		variables.model = variables.c.renderModelBuilder.build(variables.compiled.snapshot);
		variables.index = {};
		variables.itemIndex = {};
		indexTree(variables.model.root);
	}

	private void function indexTree(required struct node) {
		variables.index[arguments.node.sectionKey] = arguments.node;
		for (var it in arguments.node.items) variables.itemIndex[it.itemKey] = it;
		for (var child in arguments.node.children) indexTree(child);
	}

	private array function keys(required array nodes, required string key) {
		var out = [];
		for (var n in arguments.nodes) arrayAppend(out, n[arguments.key]);
		return out;
	}

	public void function testTreeFollowsAuthoredParentsAndDisplayOrder() {
		assertEquals("icfwalk-render-model/1", variables.model.format);
		assertEquals("root", variables.model.root.presentation);
		var top = keys(variables.model.root.children, "sectionKey");
		// Every top-level section from the configuration, ordered by displayOrder (10..400).
		var expected = [];
		var sections = duplicate(variables.compiled.snapshot.definitions.sections);
		arraySort(sections, function(a, b) { return a.displayOrder < b.displayOrder ? -1 : (a.displayOrder > b.displayOrder ? 1 : compare(a.sectionKey, b.sectionKey)); });
		for (var s in sections) if (!isNull(s.parentSectionKey) && s.parentSectionKey == "root") arrayAppend(expected, s.sectionKey);
		assertEquals(expected, top, "Top-level order.");
		assertEquals(23, structCount(variables.index), "All 23 sections are in the tree.");
		assertEquals(144, structCount(variables.itemIndex), "All 144 items are placed.");
		var part2 = variables.index["part2"];
		assertEquals(7, arrayLen(part2.children));
		assertEquals(["2.1", "2.2", "2.3", "2.4", "2.5", "2.6", "2.7"], keys(part2.children, "partNumber"));
		assertEquals(["target_taxonomy", "part1_adopted", "part1_targettask"], keys(variables.index["part1"].children, "sectionKey"));
	}

	public void function testPresentationIsDerivedFromStructureNotNames() {
		// Top-level: placements or conditional visibility -> card; otherwise accordion.
		assertEquals("card", variables.index["visit_information"].presentation);
		for (var key in ["prek_k_classroom", "dual_language_classroom", "mac_prep_classroom", "ignite_classroom", "avid_classroom", "esl_classroom", "content_area_look_fors"]) {
			assertEquals("card", variables.index[key].presentation, key);
			assertTrue(variables.index[key].conditional, key & " is conditional.");
			assertEquals(1, arrayLen(variables.index[key].ruleKeys), key & " has one SHOW rule.");
		}
		for (var key in ["part1", "part2", "part3", "part4"]) {
			assertEquals("accordion", variables.index[key].presentation, key);
			assertFalse(variables.index[key].conditional, key);
		}
		assertTrue(variables.index["part1"].requiredSection, "Part 1 carries the REQUIRED badge flag.");
		// Nested: numbered components vs plain blocks.
		for (var i = 1; i <= 7; i++) assertEquals("component", variables.index["s" & i].presentation);
		assertEquals("block", variables.index["target_taxonomy"].presentation);
		assertFalse(variables.index["target_taxonomy"].headingVisible, "Plain block keeps its heading for assistive tech only.");
		assertEquals("block", variables.index["part1_adopted"].presentation);
		assertTrue(variables.index["part1_adopted"].headingVisible);
		assertTrue(variables.index["part1_adopted"].hasLookFors);
		assertEquals("##2CA6C9", variables.index["part1_adopted"].colorHex);
		assertEquals("##C4267A", variables.index["s3"].colorHex);
	}

	public void function testPlacementsCarryDimensionMetadataInAuthoredOrder() {
		var visit = variables.index["visit_information"].placements;
		assertEquals(["date", "observer", "school", "grade", "content", "period", "classType", "visitTiming"], keys(visit, "dimensionCode"));
		assertEquals(["DATE", "TEXT", "LIST", "LIST", "LIST", "LIST", "LIST", "LIST"], keys(visit, "dataType"));
		var period = visit[6];
		assertFalse(period.visibleByDefault);
		assertTrue(period.conditional);
		assertTrue(arrayContains(period.ruleKeys, "show_period_for_grades_6_12"));
		assertEquals("Visit occurred at the:", visit[8].label);
		assertEquals("Select...", visit[3].placeholder);
		assertTrue(visit[3].allowOther);
		assertFalse(visit[4].allowOther);
		assertEquals("schoolTypeToGradeBand", visit[4].optionFilter);
		var taxonomy = variables.index["target_taxonomy"].placements;
		assertEquals(["topic", "tag"], keys(taxonomy, "dimensionCode"));
		assertEquals("Standard being taught...", taxonomy[1].placeholder);
		assertEquals(1, arrayLen(variables.model.optionFilters));
		assertEquals("grade", variables.model.optionFilters[1].dimensionCode);
		assertEquals("school", variables.model.optionFilters[1].sourceDimensionCode);
		assertEquals("valueGroup", variables.model.optionFilters[1].matchField);
		// Dimension values keep authored order and group metadata.
		var grades = variables.model.dimensions["grade"].values;
		assertEquals(["prek", "k", "1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12"], keys(grades, "valueCode"));
		assertEquals("elementary", grades[1].valueGroup);
		assertEquals("middle", grades[8].valueGroup);
		assertEquals("high", grades[14].valueGroup);
		assertEquals(51, arrayLen(variables.model.dimensions["school"].values));
		assertEquals("high", schoolGroup("dream_academy"));
		assertEquals("high", schoolGroup("central_school"));
		assertEquals("", schoolGroup("other"), "Other has no school group.");
	}

	private string function schoolGroup(required string code) {
		for (var v in variables.model.dimensions["school"].values) {
			if (v.valueCode == arguments.code) return (structKeyExists(v, "valueGroup") && !isNull(v.valueGroup)) ? v.valueGroup : "";
		}
		return "";
	}

	public void function testLayoutsAndNumberingComeFromResponseSetsAndOrder() {
		assertEquals("display-heading", variables.itemIndex["part2_s1_student_heading"].layout);
		assertEquals("display-guidance", variables.itemIndex["part2_s1_student_1"].layout);
		assertEquals("question", variables.itemIndex["comp_s1_q1"].layout);
		assertEquals("choice-row", variables.itemIndex["prek_k_q1"].layout, "Yes/No sets without definitions render as rows.");
		assertEquals("applicability", variables.itemIndex["comp_s3_applicable"].layout);
		assertEquals("notes", variables.itemIndex["comp_s1_notes"].layout);
		assertEquals("text", variables.itemIndex["summary_strengths"].layout, "LONG_TEXT outside a notes-enabled section is a field.");
		assertEquals("email-draft", variables.itemIndex["email_workflow"].layout);
		// Numbering: scored questions are numbered; pacing (unscored, with definitions) is not.
		assertEquals(1, variables.itemIndex["part1_adopted_ac1"].questionNumber);
		assertEquals(2, variables.itemIndex["part1_adopted_ac2"].questionNumber);
		assertTrue(isNull(variables.itemIndex["part1_adopted_pacing"].questionNumber), "Pacing is not numbered.");
		assertEquals("question", variables.itemIndex["part1_adopted_pacing"].layout);
		// Sections without scored questions number every question (Part 1 taxonomy 1..3).
		assertEquals(1, variables.itemIndex["p1q1"].questionNumber);
		assertEquals(3, variables.itemIndex["p1q3"].questionNumber);
		assertEquals(6, variables.itemIndex["conditions_b6"].questionNumber);
		// Item order inside a section follows displayOrder.
		assertEquals(["part2_s3_student_heading", "part2_s3_student_1", "part2_s3_student_2", "part2_s3_student_3", "part2_s3_teacher_heading", "part2_s3_teacher_1", "part2_s3_teacher_2", "part2_s3_teacher_3", "comp_s3_applicable", "comp_s3_q1", "comp_s3_q2", "comp_s3_notes"], keys(variables.index["s3"].items, "itemKey"));
	}

	public void function testSkippableComponentsDeriveApplicabilityFromRules() {
		for (var key in ["s3", "s4"]) {
			var s = variables.index[key];
			assertTrue(s.canBeSkipped, key);
			assertFalse(s.defaultApplicable, key & " defaults to not applicable.");
			assertEquals("comp_" & key & "_applicable", s.applicabilityItemKey);
			assertEquals(["comp_" & key & "_q1", "comp_" & key & "_q2"], s.ratedItemKeys);
			assertEquals("no", variables.itemIndex["comp_" & key & "_applicable"].defaultStoredCode);
			assertTrue(variables.itemIndex["comp_" & key & "_q1"].conditional);
		}
		for (var key in ["s1", "s2", "s5", "s6", "s7"]) {
			assertFalse(variables.index[key].canBeSkipped, key);
			assertTrue(isNull(variables.index[key].applicabilityItemKey), key & " has no applicability item.");
			assertEquals(0, arrayLen(variables.index[key].ratedItemKeys));
		}
	}

	public void function testResponseOptionsAndDefinitionsMatchTheConfigurationExactly() {
		// COND-14 at the data level: labels 1-5 and per-question definitions equal the JSON source.
		var optionsBySet = {};
		for (var o in variables.config.responseOptions) {
			if (!structKeyExists(optionsBySet, o.responseSetId)) optionsBySet[o.responseSetId] = [];
			arrayAppend(optionsBySet[o.responseSetId], o);
		}
		var setIdByKey = {};
		for (var rs in variables.config.responseSets) setIdByKey[rs.setKey] = rs.responseSetId;
		var checked = 0;
		for (var key in structKeyArray(variables.itemIndex)) {
			var it = variables.itemIndex[key];
			if (it.itemType != "SINGLE_CHOICE") continue;
			assertTrue(!isNull(it.responseSet) && isStruct(it.responseSet), key & " has a response set.");
			var source = optionsBySet[setIdByKey[it.responseSet.setKey]];
			arraySort(source, function(a, b) { return a.displayOrder < b.displayOrder ? -1 : (a.displayOrder > b.displayOrder ? 1 : 0); });
			assertEquals(arrayLen(source), arrayLen(it.responseSet.options), key & " option count.");
			for (var i = 1; i <= arrayLen(source); i++) {
				assertEquals(source[i].label, it.responseSet.options[i].label, key & " option label.");
				assertEquals(source[i].storedCode, it.responseSet.options[i].storedCode, key & " option code.");
				var srcDef = structKeyExists(source[i], "definition") && !isNull(source[i].definition) ? source[i].definition : "";
				var modelDef = isNull(it.responseSet.options[i].definition) ? "" : it.responseSet.options[i].definition;
				assertEquals(srcDef, modelDef, key & " option definition.");
				checked++;
			}
		}
		assertTrue(checked >= 138, "Every option was compared (" & checked & ").");
		assertEquals(["1", "2", "3", "4", "5"], keys(variables.itemIndex["comp_s1_q1"].responseSet.options, "label"));
		assertTrue(variables.itemIndex["comp_s1_q1"].responseSet.scoreEnabled);
		assertEquals(5, variables.itemIndex["comp_s1_q1"].responseSet.options[5].numericScore);
		assertTrue(variables.itemIndex["comp_s1_q1"].responseSet.hasDefinitions);
		assertFalse(variables.itemIndex["prek_k_q1"].responseSet.hasDefinitions);
	}

	public void function testPromptsAndPlaceholdersComeFromTheConfiguration() {
		var promptsByKey = {};
		for (var it in variables.config.items) promptsByKey[it.itemKey] = it.prompt;
		for (var key in structKeyArray(variables.itemIndex)) assertEquals(promptsByKey[key], variables.itemIndex[key].prompt, key & " prompt.");
		assertEquals(17, arrayLen(variables.model.placeholders));
		var flagged = 0;
		for (var key in structKeyArray(variables.itemIndex)) if (variables.itemIndex[key].isPlaceholder) flagged++;
		assertEquals(17, flagged, "Exactly the 17 placeholder items are flagged.");
		assertEquals("Placeholder in source", variables.itemIndex["avid_q2"].reviewStatus);
		assertFalse(variables.itemIndex["esl_q1"].isPlaceholder);
		// Link and help text ride on the item.
		assertEquals("https://drive.google.com/file/d/1tV3OclLfOszteUyshWNRWLP32bv2h0LL/view?usp=sharing", variables.itemIndex["dual_language_q2"].linkUrl);
		assertEquals("High Impact Reference — Oracy", variables.itemIndex["dual_language_q2"].helpText);
		assertContains("left blank", variables.itemIndex["comp_s3_applicable"].helpText);
		assertEquals("Notes for this component...", variables.itemIndex["comp_s1_notes"].placeholder);
		assertEquals("Evidence / look-fors noted", variables.itemIndex["part1_adopted_notes"].prompt);
	}

	public void function testRulesArePassedThroughAndUnsupportedEffectsAreRefused() {
		assertEquals(12, arrayLen(variables.model.rules));
		for (var r in variables.model.rules) assertEquals("SHOW", r.effect);
		var snapshot = duplicate(variables.compiled.snapshot);
		snapshot.definitions.rules[1].effect = "HIDE";
		assertThrows(function() { variables.c.renderModelBuilder.build(snapshot); }, "ICFWalk.Configuration", "SNAPSHOT_UNSUPPORTED_RULE_EFFECT");
		var snapshot2 = duplicate(variables.compiled.snapshot);
		snapshot2.definitions.instrumentDimensions[1].settings = { "optionFilter": "unknownFilter" };
		assertThrows(function() { variables.c.renderModelBuilder.build(snapshot2); }, "ICFWalk.Configuration", "UNSUPPORTED_OPTION_FILTER");
	}

	public void function testModelSerializesToCanonicalJsonWithoutGuids() {
		var json = variables.c.canonicalJson.serialize(variables.model);
		assertTrue(isJSON(json));
		assertFalse(reFind("[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}", json) > 0, "No SQL GUIDs in the render model.");
		assertContains('"partNumber":"2.3"', json);
	}
}
