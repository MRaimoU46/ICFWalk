/**
 * Phase 5 summary formatting (SUM-01..06) and the parity contract with app/assets/js/summary.js.
 *
 * tests/fixtures/summary-vectors.json is the arbiter: the JavaScript twin produced every
 * expectation in it and scripts/prototype-summary-oracle.mjs reviewed each one against
 * source/current-prototype.html, so the comparisons here are what stop the two implementations
 * drifting. Every assertion uses compare() rather than ==, because a coerced comparison would let
 * "3.0" pass for "3" and "yes" for "1" and hide exactly the divergence these vectors exist to catch.
 *
 * The model comes from the seeded snapshot through SnapshotService, which is the same path
 * WalkService.summary takes, so a vector that passes here describes the served contract and not a
 * local compilation.
 */
component extends="icfwalktests.BaseSpec" output="false" {

	public string function skipReason() {
		if (!schemaPresent()) return "icf schema is not present.";
		if (structIsEmpty(variables.c.snapshotService.currentVersion())) return "no renderable instrument version is seeded.";
		return "";
	}

	public void function beforeAll() {
		variables.fmt = variables.c.walkSummaryFormatter;
		variables.engine = variables.c.visibilityEngine;
		variables.current = variables.c.snapshotService.currentVersion();
		variables.model = variables.c.snapshotService.renderModelFor(variables.current.versionId);
		variables.vectors = repoJson("tests/fixtures/summary-vectors.json");
	}

	// ---- helpers ------------------------------------------------------------------------------

	private struct function evaluationFor(required struct state) {
		return variables.engine.evaluateVisibility(variables.model, arguments.state);
	}

	private struct function state(struct dimensions = {}, struct responses = {}) {
		return { "dimensions": arguments.dimensions, "responses": arguments.responses };
	}

	/** Byte comparison with a readable first-difference report; == would coerce and hide drift. */
	private void function assertSame(required string expected, required string actual, string label = "") {
		if (compare(arguments.expected, arguments.actual) == 0) return;
		var n = min(len(arguments.expected), len(arguments.actual));
		var at = n + 1;
		for (var i = 1; i <= n; i++) {
			if (compare(mid(arguments.expected, i, 1), mid(arguments.actual, i, 1)) != 0) { at = i; break; }
		}
		fail(
			(len(arguments.label) ? arguments.label & " " : "") & "Output differs at character " & at
			& ". Expected [" & mid(arguments.expected, max(1, at - 40), 90) & "] but got ["
			& mid(arguments.actual, max(1, at - 40), 90) & "]."
		);
	}

	private any function sectionByKey(required string key) {
		var found = [];
		var walk = function(node) {
			if (arrayLen(found)) return;
			if (compare(arguments.node.sectionKey, key) == 0) { arrayAppend(found, arguments.node); return; }
			for (var child in arguments.node.children) walk(child);
		};
		walk(variables.model.root);
		if (!arrayLen(found)) fail("The instrument has no section '" & arguments.key & "'.");
		return found[1];
	}

	// ---- the parity contract -------------------------------------------------------------------

	public void function testMatchesTheSharedSummaryVectorsExactly() {
		assertEquals("icfwalk-summary-vectors/1", variables.vectors.format);
		assertEquals("icfwalk-summary/1", variables.vectors.contract);
		assertTrue(arrayLen(variables.vectors.vectors) >= 10, "The shared vectors must cover every SUM case.");
		for (var v in variables.vectors.vectors) {
			var ev = evaluationFor(v.state);
			assertSame(v.expected.summaryText, variables.fmt.summaryText(variables.model, v.state, ev), "Vector '" & v.name & "' summaryText.");
			assertSame(v.expected.fileName, variables.fmt.fileName(variables.model, v.state, ev, v.walkId), "Vector '" & v.name & "' fileName.");
			for (var keys in structKeyArray(v.expected.emails)) {
				var included = len(keys) ? listToArray(keys, ",") : [];
				var draft = variables.fmt.emailDraft(variables.model, v.state, ev, included);
				assertSame(v.expected.emails[keys].subject, draft.subject, "Vector '" & v.name & "' email[" & keys & "].subject.");
				assertSame(v.expected.emails[keys].body, draft.body, "Vector '" & v.name & "' email[" & keys & "].body.");
			}
		}
	}

	/**
	 * The one-decimal average must round the same double JavaScript's toFixed(1) rounds. 2.25 is
	 * exactly representable and goes up; 3.05 is stored just below and goes down. An engine that
	 * rounded the exact rational instead would return "3.1" here and fail.
	 */
	public void function testAverageTextMatchesTheSharedRoundingVectors() {
		assertTrue(arrayLen(variables.vectors.averages) >= 10, "The rounding vectors must cover the tie cases.");
		for (var c in variables.vectors.averages) {
			assertSame(c.expected, variables.fmt.averageText(c.sum, c.count), "averageText(" & c.sum & ", " & c.count & ").");
		}
		assertSame("2.3", variables.fmt.averageText(9, 4), "2.25 is an exact binary tie and rounds away from zero.");
		assertSame("3.0", variables.fmt.averageText(61, 20), "3.05 is stored just below the tie and rounds down.");
		assertSame("4.5", variables.fmt.averageText(89, 20), "4.45 is stored just above the tie and rounds up.");
		assertSame("n/a", variables.fmt.averageText(0, 0), "Nothing answered has no average.");
	}

	public void function testFileLabelSanitizationMatchesTheSharedVectors() {
		assertTrue(arrayLen(variables.vectors.fileLabels) >= 8);
		for (var c in variables.vectors.fileLabels) {
			assertSame(c.expected, variables.fmt.sanitizeFileLabel(c.label), "sanitizeFileLabel(" & c.label & ").");
		}
	}

	// ---- behaviors the vectors depend on ---------------------------------------------------------

	/** SUM-02 / COND-15: blanks never count as zero, and nothing answered has no average. */
	public void function testComponentAverageUsesAnsweredScoresOnly() {
		var section = sectionByKey("s1");
		var both = state({}, { "comp_s1_q1": { "storedCode": "4" }, "comp_s1_q2": { "storedCode": "2" } });
		assertSame("3.0", variables.fmt.componentAverage(section, both, evaluationFor(both)));

		// One answered, one blank: the blank is excluded rather than averaged in as a zero.
		var one = state({}, { "comp_s1_q1": { "storedCode": "4" } });
		assertSame("4.0", variables.fmt.componentAverage(section, one, evaluationFor(one)));

		var none = state();
		assertSame("n/a", variables.fmt.componentAverage(section, none, evaluationFor(none)));

		// A foreign option code is not an answer, so it cannot contribute a score either.
		var foreign = state({}, { "comp_s1_q1": { "storedCode": "9" }, "comp_s1_q2": { "storedCode": "3" } });
		assertSame("3.0", variables.fmt.componentAverage(section, foreign, evaluationFor(foreign)));

		// SUM-03: a skipped component reports no average at all and prints the not-part line instead.
		var skipped = state({}, { "comp_s3_applicable": { "storedCode": "no" }, "comp_s3_notes": { "textValue": "kept" } });
		var text = variables.fmt.summaryText(variables.model, skipped, evaluationFor(skipped));
		assertContains("2.3 WORKSHOP MODEL OF INSTRUCTION  (not part of this lesson at the time of the visit)", text);
		assertContains("Notes: kept", text);
		assertTrue(find("2.3 WORKSHOP MODEL OF INSTRUCTION  (avg:", text) == 0, "A skipped component must print no average.");
	}

	/** SUM-04 and the hidden-Period decision: a retained hidden value never reaches the export. */
	public void function testHiddenSectionsAndHiddenPeriodAreExcluded() {
		var hidden = state(
			{ "grade": { "selectedValueCode": "3" }, "period": { "selectedValueCode": "fourth" }, "classType": { "selectedValueCode": "general_education" } },
			{ "dual_language_q1": { "storedCode": "yes" }, "dual_language_notes": { "textValue": "bridge time" } }
		);
		var ev = evaluationFor(hidden);
		// The values are still there: this is exclusion at the export, not deletion of the walk.
		assertEquals("HIDDEN", ev.dimensionStates["period"]);
		assertEquals("HIDDEN", ev.responseStates["dual_language_q1"]);
		var text = variables.fmt.summaryText(variables.model, hidden, ev);
		assertTrue(find("Period:", text) == 0, "A hidden Period must not be exported.");
		assertTrue(find("Fourth", text) == 0, "A hidden Period's value must not be exported.");
		assertTrue(find("DUAL LANGUAGE", text) == 0, "A hidden section must not be exported.");
		assertTrue(find("bridge time", text) == 0, "A hidden section's notes must not be exported.");
		assertTrue(find("Grade level: 3", text) > 0, "A visible dimension is still exported.");

		// The same values reach the export again as soon as the instrument shows them.
		var shown = state(
			{ "grade": { "selectedValueCode": "7" }, "period": { "selectedValueCode": "fourth" }, "classType": { "selectedValueCode": "dual_language" } },
			{ "dual_language_q1": { "storedCode": "yes" }, "dual_language_notes": { "textValue": "bridge time" } }
		);
		var shownText = variables.fmt.summaryText(variables.model, shown, evaluationFor(shown));
		assertContains("Period: Fourth", shownText);
		assertContains("DUAL LANGUAGE CLASSROOM", shownText);
		assertContains("Notes: bridge time", shownText);
	}

	/** SUM-05: nothing outside [A-Za-z0-9_-] can reach a Content-Disposition header or a path. */
	public void function testFileNameSanitization() {
		var punctuated = state({
			"school": { "selectedValueCode": "other", "otherText": "Unlisted/Site?" },
			"grade": { "selectedValueCode": "9" },
			"content": { "selectedValueCode": "other", "otherText": "Art & Design" },
			"date": { "dateValue": "2026-09-17" }
		});
		assertSame("ICFWalk_9_Art_Design_2026-09-17.txt", variables.fmt.fileName(variables.model, punctuated, evaluationFor(punctuated), "W1"));

		// An attempt to steer the file name through free text cannot escape the label.
		var traversal = state({
			"grade": { "selectedValueCode": "9" },
			"content": { "selectedValueCode": "other", "otherText": "../../etc/passwd" }
		});
		var name = variables.fmt.fileName(variables.model, traversal, evaluationFor(traversal), "W1");
		assertSame("ICFWalk_9__etc_passwd.txt", name);
		assertTrue(find("..", name) == 0, "No traversal sequence survives.");
		assertTrue(find("/", name) == 0, "No path separator survives.");
		assertTrue(reFind("^ICFWalk_[A-Za-z0-9_-]+\.txt$", name) > 0, "Only safe characters survive.");

		var quoted = state({ "grade": { "selectedValueCode": "9" }, "content": { "selectedValueCode": "other", "otherText": 'x" ; rm -rf /' } });
		var quotedName = variables.fmt.fileName(variables.model, quoted, evaluationFor(quoted), "W1");
		assertTrue(find('"', quotedName) == 0, "A quote can never reach the header value.");

		// Nothing named falls back to the walk id, which is sanitized on the same rule.
		var blank = state();
		assertSame("ICFWalk_ABC-123.txt", variables.fmt.fileName(variables.model, blank, evaluationFor(blank), "ABC-123"));

		// A hidden dimension cannot name the file either.
		var hiddenPeriod = state({ "grade": { "selectedValueCode": "3" }, "period": { "selectedValueCode": "fourth" } });
		assertSame("ICFWalk_3.txt", variables.fmt.fileName(variables.model, hiddenPeriod, evaluationFor(hiddenPeriod), "W1"));
	}

	/**
	 * The label is sanitized, but the pattern's own literals are instrument configuration. A pattern
	 * that could put a quote, a path separator, or a traversal sequence into a Content-Disposition
	 * header is refused loudly rather than emitted.
	 */
	public void function testAnUnsafeFileNamePatternIsRefused() {
		var s = state({ "grade": { "selectedValueCode": "9" } });
		var ev = evaluationFor(s);
		var fmt = variables.fmt;
		for (var bad in ['ICF"Walk_<grade>.txt', "../<grade>.txt", "dir/<grade>.txt", "ICFWalk_<grade>.t;xt", "..<grade>.txt"]) {
			var pattern = bad;
			var broken = duplicate(variables.model);
			broken.behavior.export.fileNamePattern = pattern;
			assertThrows(function() { fmt.fileName(broken, s, ev, "W1"); }, "ICFWalk.Configuration", "EXPORT_FILENAME_UNSAFE");
		}
		// A pattern made only of safe characters is accepted, and the real one still works.
		var safe = duplicate(variables.model);
		safe.behavior.export.fileNamePattern = "walk-<grade>.text";
		assertSame("walk-9.text", variables.fmt.fileName(safe, s, ev, "W1"));
		assertSame("ICFWalk_9.txt", variables.fmt.fileName(variables.model, s, ev, "W1"));
	}

	/** SUM-06: the settings order wins over the tick order, and only checked parts appear. */
	public void function testEmailDraftPartsAndTemplates() {
		var s = state(
			{ "grade": { "selectedValueCode": "9" }, "content": { "selectedValueCode": "ela" }, "observer": { "textValue": "Jane Doe" }, "date": { "dateValue": "2026-09-17" } },
			{
				"part1_adopted_notes": { "textValue": "adopted note" },
				"comp_s1_notes": { "textValue": "s1 note" },
				"comp_s3_applicable": { "storedCode": "no" },
				"conditions_notes": { "textValue": "b note" },
				"summary_strengths": { "textValue": "strength" }
			}
		);
		var ev = evaluationFor(s);

		var inOrder = variables.fmt.emailDraft(variables.model, s, ev, ["part1", "comp_s1", "belonging", "summary"]);
		var shuffled = variables.fmt.emailDraft(variables.model, s, ev, ["summary", "belonging", "comp_s1", "part1"]);
		assertSame(inOrder.subject, shuffled.subject, "The tick order must not change the subject.");
		assertSame(inOrder.body, shuffled.body, "The tick order must not change the body.");

		assertContains("Part 1 " & chr(8212) & " Target / Taxonomy / Pacing:", inOrder.body);
		assertContains("Adopted Curriculum notes: adopted note", inOrder.body);
		assertContains("2.1 " & chr(8212) & " Daily Engagement with Complex Texts:", inOrder.body);
		assertContains("Notes: s1 note", inOrder.body);
		assertContains("Part 3 " & chr(8212) & " Conditions for Learning:", inOrder.body);
		assertContains("Part 4: Walk Summary:", inOrder.body);
		assertContains("Strengths: strength", inOrder.body);
		assertContains("Jane Doe", inOrder.body);
		assertTrue(find("2.3 ", inOrder.body) == 0, "An unchecked part must not appear.");
		assertTrue(find("Growth areas:", inOrder.body) == 0, "An empty Part 4 field must not appear in the email.");

		// A component that is not part of the lesson says so and offers no "no notes" line.
		var skipped = variables.fmt.emailDraft(variables.model, s, ev, ["comp_s3"]);
		assertContains(chr(8226) & " Not part of this lesson at the time of the visit.", skipped.body);
		assertTrue(find("(No notes recorded for this component.)", skipped.body) == 0);

		// Nothing checked: the prompt to check something, and no part list in the subject.
		var none = variables.fmt.emailDraft(variables.model, s, ev, []);
		assertContains("(No sections were selected " & chr(8212) & " check at least one part above, then update the draft.)", none.body);
		assertTrue(find("(", none.subject) == 0, "An empty selection adds no part list to the subject.");
		assertContains("Quick note from today" & chr(8217) & "s walk-through " & chr(8212) & " 9 ELA", none.subject);

		// No observer: the placeholder the person replaces, never a blank signature.
		var noObserver = duplicate(s);
		structDelete(noObserver.dimensions, "observer");
		var unsigned = variables.fmt.emailDraft(variables.model, noObserver, evaluationFor(noObserver), ["summary"]);
		assertContains("[Your name]", unsigned.body);

		// A part with no notes at all says so rather than printing an empty heading.
		var empty = state({}, { "comp_s3_applicable": { "storedCode": "no" } });
		var emptyDraft = variables.fmt.emailDraft(variables.model, empty, evaluationFor(empty), ["part1", "belonging", "summary"]);
		assertContains("(No notes recorded for this part.)", emptyDraft.body);
		assertContains("(No summary notes recorded yet.)", emptyDraft.body);
	}

	/** A selectable part the instrument cannot resolve is a configuration fault, never a silent skip. */
	public void function testUnresolvablePartFailsLoudly() {
		var s = state();
		var ev = evaluationFor(s);
		var model = variables.model;
		var fmt = variables.fmt;
		assertThrows(function() {
			fmt.resolvePartSection(model, { "key": "ghost", "kind": "component", "partNum": "9.9", "compId": "nope" });
		}, "ICFWalk.Configuration", "EMAIL_PART_UNRESOLVED");
		assertThrows(function() {
			fmt.emailDraft(model, s, ev, []);
			fmt.resolvePartSection(model, { "key": "ghost", "kind": "unknown-kind", "partNum": "Part 9" });
		}, "ICFWalk.Configuration", "EMAIL_PART_UNRESOLVED");
	}

	/** Brief 14.1: the conditional cards print in prototype order, Content-Area before ESL. */
	public void function testConditionalCardsFollowThePrototypeExportOrder() {
		var s = state(
			{ "content": { "selectedValueCode": "music" }, "classType": { "selectedValueCode": "esl" }, "grade": { "selectedValueCode": "10" } },
			{ "content_area_q1": { "storedCode": "yes" }, "esl_q1": { "storedCode": "yes" } }
		);
		var text = variables.fmt.summaryText(variables.model, s, evaluationFor(s));
		var contentAt = find("CONTENT-AREA LOOK-FORS", text);
		var eslAt = find("ESL CLASSROOM", text);
		assertTrue(contentAt > 0 && eslAt > 0, "Both conditional cards are visible for this state.");
		assertTrue(contentAt < eslAt, "The content-sourced card prints before the class-type card that follows it.");
	}

	/** SEC-02: stored markup is text in the export, never markup, and is never dropped or escaped. */
	public void function testStoredMarkupIsExportedVerbatimAsText() {
		var payload = 'Line 1 <b>bold</b> & "quotes" <script>alert(1)</script>';
		var s = state({ "observer": { "textValue": payload } }, { "conditions_notes": { "textValue": payload } });
		var text = variables.fmt.summaryText(variables.model, s, evaluationFor(s));
		assertContains("Observer(s): " & payload, text);
		assertContains("Notes: " & payload, text);
		assertTrue(find("&amp;", text) == 0, "The export is text/plain: nothing is HTML-escaped into it.");
		assertTrue(find("&lt;", text) == 0, "The export is text/plain: nothing is HTML-escaped into it.");
	}

	/** 14.14 / 14.15: LF line ends, no trailing newline, no BOM, and a stable opening. */
	public void function testTextShapeIsStable() {
		var s = state();
		var text = variables.fmt.summaryText(variables.model, s, evaluationFor(s));
		assertSame("ICFWALK SUMMARY" & chr(10) & "================", left(text, 32));
		assertTrue(compare(right(text, 1), chr(10)) != 0, "There is no trailing newline.");
		assertTrue(find(chr(13), text) == 0, "There is no carriage return.");
		assertTrue(compare(left(text, 1), chr(65279)) != 0, "There is no byte-order mark.");
	}
}
