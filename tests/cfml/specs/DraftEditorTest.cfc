/**
 * DraftEditor at its own boundary: the wording and review-state edits an administrator makes to a
 * DRAFT (Phase 6, ADM-06 and ADM-08), with no database involved.
 *
 * WHAT IS PROVED HERE.
 *   - The normalized document an edit starts from is the exact inverse of compilation: compiling
 *     it again reproduces the stored snapshot's checksum byte for byte. Without that, a "one prompt"
 *     edit would silently rewrite everything the reconstruction got wrong.
 *   - One edit changes exactly one field of exactly one row, and reports what it was and what it
 *     became. Everything else in the document is unchanged, compared as canonical JSON.
 *   - A malformed request is refused completely, before anything is applied, with a stable code at
 *     a stable path for every problem: not an array, empty, too many, unknown members, unknown
 *     target, missing key, a field that is not editable, a value of the wrong type, a blank required
 *     value, an over-long value, a repeated field, a key that does not resolve -- and a key that
 *     differs from a real one only in case, because logical keys are identifiers.
 *   - An edit that sets a field to the value it already has changes nothing and says so.
 *   - Resolving a placeholder keeps contentReview.unresolvedPlaceholders consistent with the items,
 *     keeping the order of what survives; an edit unrelated to placeholders leaves that summary
 *     untouched, so it cannot move the snapshot bytes.
 */
component extends="icfwalktests.BaseSpec" output="false" {

	public void function beforeEach() {
		variables.editor = variables.c.draftEditor;
		variables.compiler = variables.c.snapshotCompiler;
		variables.document = variables.c.configNormalizer.fromConfig(repoJson("config/instrument-config.json"));
		variables.compiled = variables.compiler.compile(variables.document);
	}

	/** Compiling the reconstructed document reproduces the stored snapshot exactly. */
	public void function testTheNormalizedDocumentIsTheExactInverseOfCompilation() {
		var stored = deserializeJSON(variables.compiled.canonicalJson);
		var again = variables.compiler.compile(variables.editor.normalizedFromSnapshot(stored));
		assertExactTextEquals(variables.compiled.checksum, again.checksum, "the snapshot a clone or an edit starts from is the stored one, not an approximation");
		assertExactTextEquals(variables.compiled.canonicalJson, again.canonicalJson);
	}

	/** One prompt edit changes that prompt and nothing else in the document. */
	public void function testOnePromptEditChangesExactlyThatPrompt() {
		var target = firstItem();
		var result = variables.editor.apply(variables.document, [
			{ "target": "item", "key": target.itemKey, "field": "prompt", "value": "A reworded prompt for review" }
		]);
		assertTrue(result.changed);
		assertEquals(1, arrayLen(result.applied));
		assertExactTextEquals(target.itemKey, result.applied[1].key);
		assertExactTextEquals(target.prompt, result.applied[1].from, "the edit reports what the prompt was");
		assertExactTextEquals("A reworded prompt for review", result.applied[1].to, "and what it became");

		var edited = itemIn(result.normalized, target.itemKey);
		assertExactTextEquals("A reworded prompt for review", edited.prompt);
		// Everything else is untouched: restore the one field and the documents are identical.
		edited.prompt = target.prompt;
		// Canonical form, because CFML struct key order is not part of a document's meaning.
		assertExactTextEquals(canonical(variables.document), canonical(result.normalized), "no other field of any row moved");
		assertExactTextEquals(target.prompt, itemIn(variables.document, target.itemKey).prompt, "and the input document was not mutated");
	}

	/** Sections, response options and the version's own review metadata are editable too. */
	public void function testSectionOptionAndVersionFieldsAreEditable() {
		var section = variables.document.definitions.sections[2];
		var option = variables.document.definitions.responseOptions[1];
		var result = variables.editor.apply(variables.document, [
			{ "target": "section", "key": section.sectionKey, "field": "title", "value": "A new section title" },
			{ "target": "responseOption", "key": option.setKey & "/" & option.optionKey, "field": "definition", "value": "A clearer definition" },
			{ "target": "version", "field": "revisionNotes", "value": "Wording review, round one" }
		]);
		assertEquals(3, arrayLen(result.applied));
		assertExactTextEquals("A new section title", sectionIn(result.normalized, section.sectionKey).title);
		assertExactTextEquals("Wording review, round one", result.normalized.version.revisionNotes);
		var edited = "";
		for (var o in result.normalized.definitions.responseOptions) if (compare(o.setKey, option.setKey) == 0 && compare(o.optionKey, option.optionKey) == 0) edited = o;
		assertExactTextEquals("A clearer definition", edited.definition);
	}

	/** Setting a field to its current value changes nothing, and the result says so. */
	public void function testAnEditToTheSameValueIsNotAChange() {
		var target = firstItem();
		var result = variables.editor.apply(variables.document, [
			{ "target": "item", "key": target.itemKey, "field": "prompt", "value": target.prompt }
		]);
		assertFalse(result.changed, "no field moved");
		assertEquals(0, arrayLen(result.applied));
		assertExactTextEquals(variables.compiled.checksum, variables.compiler.compile(result.normalized).checksum, "and the compiled snapshot is byte-identical");
	}

	/** A nullable field is cleared by null or by blank text; a required one cannot be. */
	public void function testNullableFieldsClearAndRequiredFieldsRefuseBlank() {
		var target = firstItem();
		var cleared = variables.editor.apply(variables.document, [
			{ "target": "item", "key": target.itemKey, "field": "helpText", "value": "Temporary help" }
		]);
		var again = variables.editor.apply(cleared.normalized, [
			{ "target": "item", "key": target.itemKey, "field": "helpText", "value": "   " }
		]);
		var clearedItem = itemIn(again.normalized, target.itemKey);
		// In CFML a member holding null does not exist, which is exactly the assertion.
		assertFalse(structKeyExists(clearedItem, "helpText"), "blank text clears a nullable field to null");
		expectRefusal([{ "target": "item", "key": target.itemKey, "field": "prompt", "value": "   " }], "EDIT_VALUE_REQUIRED", "$.edits[0].value");
		expectRefusal([{ "target": "item", "key": target.itemKey, "field": "prompt" }], "EDIT_VALUE_REQUIRED", "$.edits[0].value");
	}

	/** Every malformed request is refused with a stable code at a stable path, and nothing applies. */
	public void function testMalformedRequestsAreRefusedWithStableCodes() {
		var key = firstItem().itemKey;
		expectRefusal("not an array", "DRAFT_EDIT_INVALID", "$.edits");
		expectRefusal([], "DRAFT_EDIT_EMPTY", "$.edits");
		var many = [];
		for (var i = 1; i <= 201; i++) arrayAppend(many, { "target": "item", "key": key, "field": "prompt", "value": "x" & i });
		expectRefusal(many, "DRAFT_EDIT_TOO_MANY", "$.edits");
		expectRefusal(["a string"], "DRAFT_EDIT_INVALID", "$.edits[0]");
		expectRefusal([{ "target": "item", "key": key, "field": "prompt", "value": "x", "extra": 1 }], "DRAFT_EDIT_UNKNOWN_MEMBER", "$.edits[0].extra");
		expectRefusal([{ "target": "rule", "key": key, "field": "prompt", "value": "x" }], "EDIT_TARGET_INVALID", "$.edits[0].target");
		expectRefusal([{ "target": "item", "field": "prompt", "value": "x" }], "EDIT_KEY_REQUIRED", "$.edits[0].key");
		expectRefusal([{ "target": "item", "key": key, "field": "itemType", "value": "SHORT_TEXT" }], "EDIT_FIELD_NOT_EDITABLE", "$.edits[0].field");
		expectRefusal([{ "target": "item", "key": key, "field": "reportable", "value": "false" }], "EDIT_FIELD_NOT_EDITABLE", "$.edits[0].field");
		expectRefusal([{ "target": "item", "key": key, "field": "prompt", "value": 42 }], "EDIT_VALUE_INVALID", "$.edits[0].value");
		expectRefusal([{ "target": "item", "key": key, "field": "prompt", "value": true }], "EDIT_VALUE_INVALID", "$.edits[0].value");
		expectRefusal([{ "target": "item", "key": key, "field": "prompt", "value": repeatString("p", 4001) }], "EDIT_VALUE_TOO_LONG", "$.edits[0].value");
		expectRefusal([
			{ "target": "item", "key": key, "field": "prompt", "value": "one" },
			{ "target": "item", "key": key, "field": "prompt", "value": "two" }
		], "EDIT_DUPLICATE", "$.edits[1]");
		expectRefusal([{ "target": "item", "key": "no_such_item", "field": "prompt", "value": "x" }], "EDIT_TARGET_NOT_FOUND", "$.edits[0].key");
	}

	/** A key that differs from a real key only in case is not that key. */
	public void function testKeysAreMatchedExactlyNotCaseInsensitively() {
		var key = firstItem().itemKey;
		assertTrue(compare(uCase(key), key) != 0, "precondition: the key has lower-case letters");
		expectRefusal([{ "target": "item", "key": uCase(key), "field": "prompt", "value": "x" }], "EDIT_TARGET_NOT_FOUND", "$.edits[0].key");
	}

	/** Resolving a placeholder keeps the content-review summary consistent, in its original order. */
	public void function testResolvingAPlaceholderUpdatesTheContentReviewSummaryInOrder() {
		var summary = variables.document.contentReview.unresolvedPlaceholders;
		assertEquals(17, arrayLen(summary), "precondition: the supplied document lists seventeen");
		var resolvedKey = summary[2].itemKey;
		var reworded = summary[5].itemKey;
		var result = variables.editor.apply(variables.document, [
			{ "target": "item", "key": resolvedKey, "field": "prompt", "value": "Approved question wording" },
			{ "target": "item", "key": resolvedKey, "field": "reviewStatus", "value": "Approved wording" },
			{ "target": "item", "key": reworded, "field": "prompt", "value": "Still a placeholder, reworded" }
		]);
		var after = result.normalized.contentReview.unresolvedPlaceholders;
		assertEquals(16, arrayLen(after), "the resolved item left the summary");
		var keys = [];
		for (var e in after) arrayAppend(keys, e.itemKey);
		var expected = [];
		for (var e in summary) if (compare(e.itemKey, resolvedKey) != 0) arrayAppend(expected, e.itemKey);
		assertExactJsonEquals(expected, keys, "every surviving entry kept its place");
		for (var e in after) {
			if (compare(e.itemKey, reworded) == 0) assertExactTextEquals("Still a placeholder, reworded", e.prompt, "the summary carries the item's current wording");
		}
		assertEquals(16, arrayLen(variables.compiler.placeholders(result.normalized.definitions)), "and it agrees with the items themselves");
	}

	/** An edit that has nothing to do with placeholders leaves the summary exactly as it was. */
	public void function testAnUnrelatedEditLeavesTheContentReviewSummaryAlone() {
		var section = variables.document.definitions.sections[3];
		var result = variables.editor.apply(variables.document, [
			{ "target": "section", "key": section.sectionKey, "field": "instructions", "value": "New instructions" }
		]);
		assertExactTextEquals(canonical(variables.document.contentReview), canonical(result.normalized.contentReview));
	}

	/** Marking a new item as a placeholder appends it to the summary. */
	public void function testMarkingAnItemAsAPlaceholderAppendsItToTheSummary() {
		var target = "";
		for (var it in variables.document.definitions.items) {
			if (compare(it.reviewStatus, "Source baseline") == 0) { target = it; break; }
		}
		var result = variables.editor.apply(variables.document, [
			{ "target": "item", "key": target.itemKey, "field": "reviewStatus", "value": variables.compiler.placeholderReviewStatus() }
		]);
		var after = result.normalized.contentReview.unresolvedPlaceholders;
		assertEquals(18, arrayLen(after));
		assertExactTextEquals(target.itemKey, after[18].itemKey, "a newly marked item is appended after the existing entries");
	}

	/** Search finds rows by key and by wording, and an empty query finds nothing. */
	public void function testSearchFindsEditableRowsByKeyAndWording() {
		assertEquals(0, arrayLen(variables.editor.search(variables.document, "")), "the editor is search-driven");
		var byText = variables.editor.search(variables.document, "place holder");
		var itemHits = 0;
		for (var r in byText) if (compare(r.target, "item") == 0) itemHits++;
		assertEquals(17, itemHits, "every placeholder prompt is found by its wording");
		var one = variables.editor.search(variables.document, firstItem().itemKey);
		assertTrue(arrayLen(one) >= 1);
		assertTrue(structKeyExists(one[1].fields, "prompt") && structKeyExists(one[1].fields, "reviewStatus"), "a result carries every editable field's current value");
	}

	// ---- helpers ---------------------------------------------------------------------------------

	private string function canonical(required any value) {
		return variables.c.canonicalJson.serialize(arguments.value);
	}

	/**
	 * A scored question that is NOT a placeholder, so an edit to it has no reason to touch the
	 * content-review summary; the placeholder cases below exercise that path on purpose.
	 */
	private struct function firstItem() {
		for (var it in variables.document.definitions.items) {
			if (compare(it.itemType, "SINGLE_CHOICE") == 0 && compare(it.reviewStatus, variables.compiler.placeholderReviewStatus()) != 0) return it;
		}
		fail("no non-placeholder SINGLE_CHOICE item in the supplied document");
	}

	private struct function itemIn(required struct doc, required string key) {
		for (var it in arguments.doc.definitions.items) if (compare(it.itemKey, arguments.key) == 0) return it;
		fail("no item " & arguments.key);
	}

	private struct function sectionIn(required struct doc, required string key) {
		for (var s in arguments.doc.definitions.sections) if (compare(s.sectionKey, arguments.key) == 0) return s;
		fail("no section " & arguments.key);
	}

	private void function expectRefusal(required any edits, required string code, required string path) {
		var editor = variables.editor;
		var doc = variables.document;
		var list = arguments.edits;
		var e = assertThrows(function() { editor.apply(doc, list); }, "ICFWalk.Validation", "DRAFT_EDIT_INVALID");
		var issues = deserializeJSON(e.extendedInfo).issues;
		var found = false;
		for (var issue in issues) {
			if (compare(issue.code, arguments.code) == 0 && compare(issue.path, arguments.path) == 0) found = true;
		}
		assertTrue(found, "expected " & arguments.code & " at " & arguments.path & " but got " & left(serializeJSON(issues), 400));
	}
}
