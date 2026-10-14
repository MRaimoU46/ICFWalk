/**
 * The 2026-10-14 instrument revision (docs/INSTRUMENT_REVISION_2026-10-14.md) on the CFML side,
 * with no database: config/instrument-config-2026-10-14.json is accepted by the authoring validator,
 * compiles to exactly the bytes scripts/lib/snapshot.mjs compiles (the golden checksums in
 * tests/golden/instrument-snapshot-2026-10-14.golden.json), builds a render model that carries the
 * level names, the third Academic Teaming question and the new Part 1 order, and runs through the
 * visibility engine and the summary formatter the way the prototype does.
 *
 * The import, publication, a saved walk and its summary against SQL Server, and the editor, are
 * tests/node/browser-revision.test.mjs.
 */
component extends="icfwalktests.BaseSpec" output="false" {

	public void function beforeAll() {
		variables.golden = repoJson("tests/golden/instrument-snapshot-2026-10-14.golden.json");
		variables.doc = repoJson("config/instrument-config-2026-10-14.json");
		variables.normalized = variables.c.configNormalizer.fromConfig(variables.doc);
		variables.compiled = variables.c.snapshotCompiler.compile(variables.normalized);
		variables.model = variables.c.renderModelBuilder.build(variables.compiled.snapshot);
		variables.engine = variables.c.visibilityEngine;
	}

	/** Parity with the reference compiler: identical canonical bytes and checksums. */
	public void function testRevisionCompilesToTheReferenceGolden() {
		assertExactTextEquals(variables.golden.checksum, variables.compiled.checksum, "Snapshot checksum.");
		assertExactTextEquals(variables.golden.definitionsChecksum, variables.compiled.definitionsChecksum, "Definitions checksum.");
		var bytes = javaCast("string", variables.compiled.canonicalJson).getBytes("UTF-8");
		assertEquals(variables.golden.canonicalBytes, arrayLen(bytes), "Canonical byte length.");
		for (var key in structKeyArray(variables.golden.counts)) {
			assertEquals(variables.golden.counts[key], variables.compiled.counts[key], "Count '" & key & "'.");
		}
	}

	/** The authoring validator accepts the document; its only warnings are the 17 placeholders. */
	public void function testRevisionPassesTheAuthoringValidator() {
		var result = variables.c.configValidator.validate(variables.doc);
		assertTrue(result.valid, "valid: " & serializeJSON(result.errors));
		assertEquals(0, arrayLen(result.errors));
		assertEquals(17, arrayLen(result.placeholders));
		for (var w in result.warnings) assertExactTextEquals("PLACEHOLDER_CONTENT", w.code, "warning " & w.path);
	}

	/** The real renderer builds it completely, with the level names it carries. */
	public void function testRenderModelCarriesTheRevision() {
		var contract = variables.c.renderContractValidator.validate(variables.compiled.snapshot);
		assertTrue(contract.valid, "renderable: " & serializeJSON(contract.errors));
		assertEquals(0, arrayLen(contract.errors));
		var names = variables.model.behavior.ratings.levelNames;
		assertExactTextEquals("Not evident", names["1"]);
		assertExactTextEquals("Inconsistent", names["2"]);
		assertExactTextEquals("Evident", names["3"]);
		assertExactTextEquals("Evident and student-owned", names["4"]);
		assertEquals(4, structCount(names));

		var part1 = findSection(variables.model.root, "part1");
		var order = [];
		for (var child in part1.children) arrayAppend(order, child.sectionKey);
		assertExactJsonEquals(["target_taxonomy", "part1_targettask", "part1_adopted"], order, "Target/Task Alignment before Adopted Curriculum");

		var s4 = findSection(variables.model.root, "s4");
		assertExactJsonEquals(["comp_s4_q1", "comp_s4_q2", "comp_s4_q3"], s4.ratedItemKeys);
		for (var it in s4.items) {
			if (it.layout != "question") continue;
			var codes = [];
			for (var o in it.responseSet.options) arrayAppend(codes, o.storedCode);
			assertExactJsonEquals(["1", "2", "3", "4"], codes, it.itemKey & " levels");
		}
		assertExactTextEquals("Program", variables.model.dimensions["classType"].label);
		assertEquals(17, arrayLen(variables.model.dimensions["classType"].values));
		assertExactTextEquals("Content / Subject Area", variables.model.dimensions["content"].label);
		assertFalse(structKeyExists(variables.model.dimensions, "tag"), "no tag field in this version");
	}

	/** The content-area card follows Performing Arts, Visual Arts and CTE; Art and Music are gone. */
	public void function testContentAreaCardFollowsTheNewTriggers() {
		for (var trigger in ["performing_arts", "visual_arts", "cte"]) {
			var shown = variables.engine.evaluateVisibility(variables.model, revisionState({ "content": { "selectedValueCode": trigger } }));
			assertTrue(shown.sections["content_area_look_fors"], trigger & " shows the card");
		}
		for (var other in ["math", "ela", "other"]) {
			var hidden = variables.engine.evaluateVisibility(variables.model, revisionState({ "content": { "selectedValueCode": other } }));
			assertFalse(hidden.sections["content_area_look_fors"], other & " does not");
		}
		var dhh = variables.engine.evaluateVisibility(variables.model, revisionState({ "classType": { "selectedValueCode": "dhh" } }));
		assertFalse(dhh.sections["dual_language_classroom"], "a new program opens no conditional card");
		var dl = variables.engine.evaluateVisibility(variables.model, revisionState({ "classType": { "selectedValueCode": "dual_language" } }));
		assertTrue(dl.sections["dual_language_classroom"]);
	}

	/** Academic Teaming's third question shows, and is cleared, with the component, like the first two. */
	public void function testThirdTeamingQuestionFollowsApplicability() {
		var blank = variables.engine.blankState(variables.model);
		var ev = variables.engine.evaluateVisibility(variables.model, blank);
		assertFalse(ev.items["comp_s4_q3"], "hidden for a new walk");
		assertExactTextEquals("NOT_APPLICABLE", ev.responseStates["comp_s4_q3"]);
		var applies = revisionState({}, { "comp_s4_applicable": { "storedCode": "yes" }, "comp_s4_q3": { "storedCode": "3" } });
		ev = variables.engine.evaluateVisibility(variables.model, applies);
		assertTrue(ev.items["comp_s4_q3"]);
		assertExactTextEquals("ANSWERED", ev.responseStates["comp_s4_q3"]);
		// Switching the component to No clears the third rating exactly as COND-12 clears the others.
		applies.responses["comp_s4_applicable"] = { "storedCode": "no" };
		var n = variables.engine.normalize(variables.model, applies);
		assertEquals(1, arrayLen(n.changes), "one rating cleared");
		assertExactTextEquals("RESPONSE_CLEARED", n.changes[1].kind);
		assertExactTextEquals("comp_s4_q3", n.changes[1].key);
		assertExactTextEquals("NOT_APPLICABLE", n.changes[1].reason);
		ev = variables.engine.evaluateVisibility(variables.model, n.state);
		assertFalse(ev.items["comp_s4_q3"]);
		assertExactTextEquals("NOT_APPLICABLE", ev.responseStates["comp_s4_q3"]);
		n.state.responses["comp_s4_applicable"] = { "storedCode": "yes" };
		ev = variables.engine.evaluateVisibility(variables.model, n.state);
		assertExactTextEquals("UNANSWERED", ev.responseStates["comp_s4_q3"], "a cleared rating does not reappear");
	}

	/** The export prints n/4, the three-question average, and Target/Task Alignment first. */
	public void function testSummaryReadsOnTheFourPointScale() {
		var st = revisionState(
			{ "grade": { "selectedValueCode": "7" }, "content": { "selectedValueCode": "visual_arts" }, "classType": { "selectedValueCode": "dhh" } },
			{
				"part1_targettask_tt1": { "storedCode": "4" },
				"part1_adopted_pacing": { "storedCode": "notevident" },
				"comp_s4_applicable": { "storedCode": "yes" },
				"comp_s4_q1": { "storedCode": "4" }, "comp_s4_q2": { "storedCode": "3" }, "comp_s4_q3": { "storedCode": "3" }
			}
		);
		var ev = variables.engine.evaluateVisibility(variables.model, st);
		var text = variables.c.walkSummaryFormatter.summaryText(variables.model, st, ev);
		var lines = listToArray(text, chr(10), true);
		assertTrue(arrayFind(lines, "Program: DHH") > 0, "Program line");
		assertTrue(arrayFind(lines, "Content / Subject Area: Visual Arts") > 0, "Content line");
		assertTrue(arrayFind(lines, "- Pacing:  [Pacing NOT evident]") > 0, "pacing line");
		assertTrue(arrayFind(lines, "2.4 ACADEMIC TEAMING  (avg: 3.3)") > 0, "three-question average");
		var target = arrayFind(lines, "TARGET/TASK ALIGNMENT");
		var adopted = arrayFind(lines, "ADOPTED CURRICULUM");
		assertTrue(target > 0 && target < adopted, "Target/Task Alignment prints first");
		assertTrue(find("[4/4]", text) > 0, "scored on 4");
		assertFalse(find("/5]", text) > 0, "nothing out of 5");
	}

	// ---- helpers ------------------------------------------------------------------------------

	private struct function revisionState(struct dimensions = {}, struct responses = {}) {
		return { "dimensions": arguments.dimensions, "responses": arguments.responses };
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
