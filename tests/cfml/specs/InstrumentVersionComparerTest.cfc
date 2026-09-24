/**
 * InstrumentVersionComparer at its own boundary (Phase 6, ADM-06): no database.
 *
 * WHAT IS PROVED HERE. Two compiled snapshots are compared row by row on the logical keys every
 * version shares, and the result is exact:
 *   - identical snapshots are reported identical, with nothing listed;
 *   - one prompt change is reported as exactly one changed item, carrying the exact before and
 *     after text -- the acceptance criterion's "compare view shows the exact prompt change";
 *   - added and removed rows, a response option's score and label, a rule's condition, an item's
 *     reportability and its review status are each reported as themselves;
 *   - a structured value whose key order differs is NOT a change (canonical comparison), and a
 *     string "3" is not the number 3 (type-exact comparison);
 *   - document-level facts outside the definitions -- the version label, the instrument name --
 *     are reported as metadata, separately from keyed rows.
 */
component extends="icfwalktests.BaseSpec" output="false" {

	public void function beforeEach() {
		variables.comparer = variables.c.instrumentVersionComparer;
		var normalized = variables.c.configNormalizer.fromConfig(repoJson("config/instrument-config.json"));
		variables.base = variables.c.snapshotCompiler.compile(normalized).snapshot;
	}

	public void function testIdenticalSnapshotsAreReportedIdentical() {
		var r = variables.comparer.diff(variables.base, duplicate(variables.base));
		assertTrue(r.identical);
		assertEquals(0, arrayLen(r.changes));
		assertEquals(0, arrayLen(r.metadata));
	}

	/** ADM-06: the exact prompt change, and only it. */
	public void function testOnePromptChangeIsReportedExactly() {
		var next = duplicate(variables.base);
		var item = next.definitions.items[10];
		var before = item.prompt;
		item.prompt = "The one prompt that changed";
		var r = variables.comparer.diff(variables.base, next);
		assertFalse(r.identical);
		assertEquals(1, arrayLen(r.changes), "exactly one row changed");
		var change = r.changes[1];
		assertExactTextEquals("items", change.collection);
		assertExactTextEquals(item.itemKey, change.key);
		assertExactTextEquals("changed", change.change);
		assertEquals(1, arrayLen(change.fields), "and exactly one field of it");
		assertExactTextEquals("prompt", change.fields[1].field);
		assertExactTextEquals(before, change.fields[1].from, "with the exact text it had");
		assertExactTextEquals("The one prompt that changed", change.fields[1].to, "and the exact text it has now");
		assertEquals(1, r.summary.changed);
		assertEquals(0, r.summary.added);
		assertEquals(0, r.summary.removed);
	}

	public void function testAddedAndRemovedRowsAreReported() {
		var next = duplicate(variables.base);
		var removed = next.definitions.items[1];
		arrayDeleteAt(next.definitions.items, 1);
		var added = duplicate(next.definitions.items[1]);
		added.itemKey = "zz_added_item";
		arrayAppend(next.definitions.items, added);
		var r = variables.comparer.diff(variables.base, next);
		var kinds = {};
		for (var c in r.changes) kinds[c.key] = c.change;
		assertExactTextEquals("removed", kinds[removed.itemKey]);
		assertExactTextEquals("added", kinds["zz_added_item"]);
		assertEquals(1, r.summary.added);
		assertEquals(1, r.summary.removed);
	}

	/** Response options, scores, rules, reportability and review state are all just fields. */
	public void function testOptionsRulesReportabilityAndReviewStateAreCompared() {
		var next = duplicate(variables.base);
		var option = next.definitions.responseOptions[3];
		option.label = "Relabelled";
		option.numericScore = isNull(option.numericScore) ? 9 : option.numericScore + 1;
		next.definitions.rules[1].comparisonValue = "changed-comparison";
		var item = next.definitions.items[20];
		item.reportable = !item.reportable;
		item.reviewStatus = "Approved wording";
		var r = variables.comparer.diff(variables.base, next);
		var byKey = {};
		for (var c in r.changes) byKey[c.collection & ":" & c.key] = c;
		var optionChange = byKey["responseOptions:" & option.setKey & "/" & option.optionKey];
		assertEquals(2, arrayLen(optionChange.fields), "label and score");
		assertTrue(structKeyExists(byKey, "rules:" & next.definitions.rules[1].ruleKey), "the rule change is reported");
		var itemChange = byKey["items:" & item.itemKey];
		var names = [];
		for (var f in itemChange.fields) arrayAppend(names, f.field);
		arraySort(names, "text");
		assertExactJsonEquals(["reportable", "reviewStatus"], names);
	}

	/** Key order inside a structured value is not a change; a type change is. */
	public void function testStructuredValuesAreComparedCanonicallyAndTypeExactly() {
		var first = duplicate(variables.base);
		var forward = structNew("ordered");
		forward["alpha"] = 1;
		forward["beta"] = { "x": 1, "y": "two" };
		first.definitions.items[1].settings = forward;
		var second = duplicate(variables.base);
		var backward = structNew("ordered");
		backward["beta"] = { "y": "two", "x": 1 };
		backward["alpha"] = 1;
		second.definitions.items[1].settings = backward;
		assertTrue(variables.comparer.diff(first, second).identical, "the same settings in another key order are the same settings");

		var typed = duplicate(variables.base);
		var o = typed.definitions.responseOptions[1];
		o.numericScore = 3;
		var baseline = duplicate(typed);
		o.numericScore = "3";
		var r = variables.comparer.diff(baseline, typed);
		assertEquals(1, arrayLen(r.changes), "a number replaced by the string of that number is a change");
	}

	/** Document-level facts are metadata, not keyed rows. */
	public void function testVersionAndInstrumentFactsAreReportedAsMetadata() {
		var next = duplicate(variables.base);
		next.version.versionLabel = "a different label";
		next.instrument.name = "A different instrument name";
		var r = variables.comparer.diff(variables.base, next);
		assertEquals(0, arrayLen(r.changes), "no keyed row changed");
		var fields = [];
		for (var m in r.metadata) arrayAppend(fields, m.field);
		arraySort(fields, "text");
		assertExactJsonEquals(["instrument.name", "version.versionLabel"], fields);
	}
}
