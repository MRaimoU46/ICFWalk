/**
 * In-application wording edits to a DRAFT (Phase 6, ADM-06 and the ADM-08 placeholder review).
 *
 * WHAT IT IS. A pure function over a normalized instrument document -- the same shape
 * ConfigNormalizer produces and SnapshotCompiler compiles. It validates a list of edit operations,
 * applies them to a copy, and returns the edited document. It touches no database and knows
 * nothing about versions, locks or audit; InstrumentImportService takes the result through the
 * one validated write path every DRAFT change goes through (the shared semantic rule set, the real
 * renderer, the version lock, the round-trip checksum proof, the refusal audit).
 *
 * WHAT IT EDITS, AND WHY ONLY THAT. Wording and content-review state, keyed by the stable logical
 * keys every version shares:
 *
 *   section         title, instructions, reviewStatus
 *   item            prompt, helpText, placeholder, reviewStatus, revisionNotes
 *   responseOption  label, definition            (key "setKey/optionKey")
 *   version         reviewStatus, revisionNotes  (the version's own review metadata; no key)
 *
 * Structure -- adding, removing or reordering content, changing a rule, a response set, a score or
 * a dimension -- is authored in the instrument document and imported, exactly as before. The
 * in-app editor exists for the change the acceptance criteria name (alter a prompt in a new DRAFT)
 * and for resolving the seventeen placeholder prompts (docs/OPEN_DECISIONS.md: "make replacement a
 * new DRAFT version edit"). Widening it to structure would duplicate the document import as a
 * second, weaker authoring path; that is recorded as a decision rather than left implicit.
 *
 * CONTENT REVIEW STAYS CONSISTENT. contentReview.unresolvedPlaceholders is a document-level summary
 * of the items marked with the placeholder review status, and import warns when the two disagree.
 * When an applied edit changes an item's prompt or review status, that summary is rebuilt from the
 * items: surviving entries keep their original order, entries for items no longer marked are
 * dropped, newly marked items are appended by key. It is never touched otherwise, so an edit that
 * changes nothing about placeholders cannot move the snapshot bytes.
 *
 * A malformed request is a 400 (DRAFT_EDIT_INVALID, with every issue and its path). A well-formed
 * edit that produces an invalid instrument is not this component's decision: the shared rule set
 * refuses it downstream as a 422, exactly as it would refuse the same content imported.
 */
component output="false" {

	variables.MAX_EDITS = 200;
	// target -> field -> { required, max }. `required` means the value may not be null or blank.
	variables.FIELDS = {
		"section": {
			"title": { "required": true, "max": 300 },
			"instructions": { "required": false, "max": 4000 },
			"reviewStatus": { "required": true, "max": 100 }
		},
		"item": {
			"prompt": { "required": true, "max": 4000 },
			"helpText": { "required": false, "max": 4000 },
			"placeholder": { "required": false, "max": 500 },
			"reviewStatus": { "required": true, "max": 100 },
			"revisionNotes": { "required": false, "max": 2000 }
		},
		"responseOption": {
			"label": { "required": true, "max": 500 },
			"definition": { "required": false, "max": 4000 }
		},
		"version": {
			"reviewStatus": { "required": false, "max": 200 },
			"revisionNotes": { "required": false, "max": 2000 }
		}
	};
	// Edits to these item fields are what can change the placeholder summary.
	variables.REVIEW_SENSITIVE = ["prompt", "reviewStatus"];
	variables.COLLECTION_OF = { "section": "sections", "item": "items", "responseOption": "responseOptions" };

	public DraftEditor function init(required string placeholderReviewStatus) {
		variables.PLACEHOLDER_REVIEW_STATUS = arguments.placeholderReviewStatus;
		variables.types = new icfwalk.core.JsonTypes();
		return this;
	}

	/** The editable surface, for callers that list or search it. */
	public struct function editableFields() {
		return duplicate(variables.FIELDS);
	}

	public numeric function maxEdits() { return variables.MAX_EDITS; }

	/**
	 * The normalized document an existing compiled snapshot was compiled from. SnapshotCompiler
	 * writes exactly the normalized document plus `snapshotFormat` and `counts`, so removing those
	 * two members inverts it -- compiling the result reproduces the stored bytes, which is what makes
	 * a clone or an edit a change to the version's real content rather than to a reconstruction.
	 */
	public struct function normalizedFromSnapshot(required struct snapshot) {
		var n = {};
		for (var key in ["schemaVersion", "source", "instrument", "version", "definitions", "behavior", "contentReview"]) {
			if (structKeyExists(arguments.snapshot, key) && !isNull(arguments.snapshot[key])) {
				n[key] = duplicate(arguments.snapshot[key]);
			} else {
				n[key] = javaCast("null", "");
			}
		}
		return n;
	}

	/**
	 * Validates `edits` completely, then applies them to a copy of `normalized`.
	 *
	 * @return { normalized, applied: [ { target, key, field, from, to } ], changed: boolean }
	 */
	public struct function apply(required struct normalized, required any edits) {
		var issues = validateShape(arguments.edits);
		if (arrayLen(issues)) refuse(issues);

		var doc = duplicate(arguments.normalized);
		var index = indexOf(doc);
		var applied = [];
		var reviewTouched = false;
		for (var i = 1; i <= arrayLen(arguments.edits); i++) {
			var edit = arguments.edits[i];
			var path = "$.edits[" & (i - 1) & "]";
			var entity = resolve(index, doc, edit.target, keyOf(edit));
			if (isNull(entity)) {
				arrayAppend(issues, issue("EDIT_TARGET_NOT_FOUND", "No " & edit.target & " with key '" & keyOf(edit) & "' exists in this version.", path & ".key"));
				continue;
			}
			var spec = variables.FIELDS[edit.target][edit.field];
			var value = normalizedValue(edit, spec);
			var before = structKeyExists(entity, edit.field) && !isNull(entity[edit.field]) ? entity[edit.field] : javaCast("null", "");
			if (isNull(value)) {
				entity[edit.field] = javaCast("null", "");
			} else {
				entity[edit.field] = value;
			}
			var changed = !sameText(isNull(before) ? javaCast("null", "") : before, isNull(value) ? javaCast("null", "") : value);
			if (changed) {
				arrayAppend(applied, {
					"target": edit.target, "key": keyOf(edit), "field": edit.field,
					"from": isNull(before) ? javaCast("null", "") : before,
					"to": isNull(value) ? javaCast("null", "") : value
				});
				if (edit.target == "item" && arrayContains(variables.REVIEW_SENSITIVE, edit.field)) reviewTouched = true;
			}
		}
		if (arrayLen(issues)) refuse(issues);
		if (reviewTouched) refreshPlaceholderSummary(doc);
		return { "normalized": doc, "applied": applied, "changed": arrayLen(applied) > 0 };
	}

	/**
	 * Every editable entity whose key or current wording contains `query` (case-insensitive), with
	 * the current value of each editable field. An empty query matches nothing: the editor is
	 * search-driven, and listing every field of 144 items is not a useful answer.
	 */
	public array function search(required struct normalized, required string query, numeric limit = 50) {
		var q = lCase(trim(arguments.query));
		var out = [];
		if (!len(q)) return out;
		var d = arguments.normalized.definitions;
		var sectionTitles = {};
		for (var s in d.sections) sectionTitles[s.sectionKey] = textOf(s, "title");
		for (var s in d.sections) {
			if (matches(q, [s.sectionKey, textOf(s, "title"), textOf(s, "instructions")])) {
				arrayAppend(out, entry("section", s.sectionKey, textOf(s, "title"), "", s));
			}
		}
		for (var it in d.items) {
			if (matches(q, [it.itemKey, textOf(it, "prompt"), textOf(it, "helpText"), textOf(it, "sourceLocation"), textOf(it, "reviewStatus")])) {
				var sectionKey = isNull(it.sectionKey) ? "" : it.sectionKey;
				var context = structKeyExists(sectionTitles, sectionKey) ? sectionTitles[sectionKey] : "";
				arrayAppend(out, entry("item", it.itemKey, textOf(it, "prompt"), context, it));
			}
		}
		for (var op in d.responseOptions) {
			if (matches(q, [op.setKey & "/" & op.optionKey, textOf(op, "label"), textOf(op, "definition")])) {
				arrayAppend(out, entry("responseOption", op.setKey & "/" & op.optionKey, textOf(op, "label"), op.setKey, op));
			}
		}
		return arrayLen(out) > arguments.limit ? arraySlice(out, 1, arguments.limit) : out;
	}

	/** The editable fields of one entity, for a caller that already knows its key. */
	public struct function describe(required struct normalized, required string target, string key = "") {
		if (!structKeyExists(variables.FIELDS, arguments.target)) refuse([issue("EDIT_TARGET_INVALID", "Unknown edit target '" & arguments.target & "'.", "$.target")]);
		var entity = resolve(indexOf(arguments.normalized), arguments.normalized, arguments.target, arguments.key);
		if (isNull(entity)) refuse([issue("EDIT_TARGET_NOT_FOUND", "No " & arguments.target & " with key '" & arguments.key & "' exists in this version.", "$.key")]);
		return entry(arguments.target, arguments.key, "", "", entity);
	}

	// ---- validation ------------------------------------------------------------------------------

	private array function validateShape(required any edits) {
		var issues = [];
		if (isNull(arguments.edits) || !isArray(arguments.edits)) {
			arrayAppend(issues, issue("DRAFT_EDIT_INVALID", "edits must be an array of edit operations.", "$.edits"));
			return issues;
		}
		if (!arrayLen(arguments.edits)) {
			arrayAppend(issues, issue("DRAFT_EDIT_EMPTY", "At least one edit is required.", "$.edits"));
			return issues;
		}
		if (arrayLen(arguments.edits) > variables.MAX_EDITS) {
			arrayAppend(issues, issue("DRAFT_EDIT_TOO_MANY", "At most " & variables.MAX_EDITS & " edits may be applied at once.", "$.edits"));
			return issues;
		}
		var seen = {};
		for (var i = 1; i <= arrayLen(arguments.edits); i++) {
			var path = "$.edits[" & (i - 1) & "]";
			var edit = arguments.edits[i];
			if (isNull(edit) || !isStruct(edit)) {
				arrayAppend(issues, issue("DRAFT_EDIT_INVALID", "Each edit must be an object.", path));
				continue;
			}
			for (var member in structKeyArray(edit)) {
				if (!arrayContains(["target", "key", "field", "value"], member)) {
					arrayAppend(issues, issue("DRAFT_EDIT_UNKNOWN_MEMBER", "'" & member & "' is not part of an edit.", path & "." & member));
				}
			}
			if (!structKeyExists(edit, "target") || !variables.types.isJsonString(edit.target) || !structKeyExists(variables.FIELDS, edit.target)) {
				arrayAppend(issues, issue("EDIT_TARGET_INVALID", "target must be one of " & arrayToList(structKeyArray(variables.FIELDS), ", ") & ".", path & ".target"));
				continue;
			}
			if (edit.target != "version" && (!structKeyExists(edit, "key") || !variables.types.isJsonString(edit.key) || !len(trim(edit.key)))) {
				arrayAppend(issues, issue("EDIT_KEY_REQUIRED", "key is required for a " & edit.target & " edit.", path & ".key"));
				continue;
			}
			if (!structKeyExists(edit, "field") || !variables.types.isJsonString(edit.field) || !structKeyExists(variables.FIELDS[edit.target], edit.field)) {
				arrayAppend(issues, issue("EDIT_FIELD_NOT_EDITABLE", "field must be one of " & arrayToList(structKeyArray(variables.FIELDS[edit.target]), ", ") & " for a " & edit.target & ".", path & ".field"));
				continue;
			}
			var spec = variables.FIELDS[edit.target][edit.field];
			var present = structKeyExists(edit, "value") && !isNull(edit.value);
			if (present && !variables.types.isJsonString(edit.value)) {
				arrayAppend(issues, issue("EDIT_VALUE_INVALID", "value must be a string" & (spec.required ? "" : " or null") & ".", path & ".value"));
				continue;
			}
			var text = present ? trim(edit.value) : "";
			if (spec.required && !len(text)) {
				arrayAppend(issues, issue("EDIT_VALUE_REQUIRED", edit.field & " may not be blank.", path & ".value"));
				continue;
			}
			if (len(text) > spec.max) {
				arrayAppend(issues, issue("EDIT_VALUE_TOO_LONG", edit.field & " may be at most " & spec.max & " characters.", path & ".value"));
				continue;
			}
			var identity = edit.target & "|" & keyOf(edit) & "|" & edit.field;
			if (structKeyExists(seen, identity)) {
				arrayAppend(issues, issue("EDIT_DUPLICATE", "The same field is edited twice in one request.", path));
				continue;
			}
			seen[identity] = true;
		}
		return issues;
	}

	private void function refuse(required array issues) {
		throw(
			type = "ICFWalk.Validation",
			message = "The DRAFT edit request is invalid: " & arguments.issues[1].message,
			errorcode = "DRAFT_EDIT_INVALID",
			extendedinfo = serializeJSON({ "issues": arguments.issues })
		);
	}

	// ---- application -----------------------------------------------------------------------------

	private struct function indexOf(required struct doc) {
		var d = arguments.doc.definitions;
		var index = { "section": {}, "item": {}, "responseOption": {} };
		for (var i = 1; i <= arrayLen(d.sections); i++) index.section[d.sections[i].sectionKey] = i;
		for (var i = 1; i <= arrayLen(d.items); i++) index.item[d.items[i].itemKey] = i;
		for (var i = 1; i <= arrayLen(d.responseOptions); i++) index.responseOption[d.responseOptions[i].setKey & "/" & d.responseOptions[i].optionKey] = i;
		return index;
	}

	/**
	 * The entity struct itself (by reference into `doc`), or null when the key does not resolve.
	 *
	 * Keys are matched EXACTLY. A CFML struct lookup is case-insensitive, so the index finds the
	 * candidate and compare() then refuses a key that differs from it only in case: a logical key
	 * is an identifier, and "PREK_K_Q1" is not an edit to prek_k_q1.
	 */
	private any function resolve(required struct index, required struct doc, required string target, string key = "") {
		if (arguments.target == "version") {
			if (!structKeyExists(arguments.doc, "version") || isNull(arguments.doc.version) || !isStruct(arguments.doc.version)) return javaCast("null", "");
			return arguments.doc.version;
		}
		var slots = arguments.index[arguments.target];
		if (!structKeyExists(slots, arguments.key)) return javaCast("null", "");
		var entity = arguments.doc.definitions[variables.COLLECTION_OF[arguments.target]][slots[arguments.key]];
		var actualKey = arguments.target == "section" ? entity.sectionKey
			: arguments.target == "item" ? entity.itemKey
			: entity.setKey & "/" & entity.optionKey;
		return compare(actualKey, arguments.key) == 0 ? entity : javaCast("null", "");
	}

	private any function normalizedValue(required struct edit, required struct spec) {
		if (!structKeyExists(arguments.edit, "value") || isNull(arguments.edit.value)) return javaCast("null", "");
		var text = trim(arguments.edit.value);
		if (!len(text) && !arguments.spec.required) return javaCast("null", "");
		return text;
	}

	/**
	 * Rebuilds contentReview.unresolvedPlaceholders from the items, keeping the order of surviving
	 * entries. Only called when an applied edit changed an item's prompt or review status, and only
	 * when the document carries the summary at all -- it is never invented.
	 */
	private void function refreshPlaceholderSummary(required struct doc) {
		if (isNull(arguments.doc.contentReview) || !isStruct(arguments.doc.contentReview)) return;
		var review = arguments.doc.contentReview;
		if (!structKeyExists(review, "unresolvedPlaceholders") || isNull(review.unresolvedPlaceholders) || !isArray(review.unresolvedPlaceholders)) return;
		var marked = {};
		var order = [];
		for (var it in arguments.doc.definitions.items) {
			if (!isNull(it.reviewStatus) && compare(it.reviewStatus, variables.PLACEHOLDER_REVIEW_STATUS) == 0) {
				marked[it.itemKey] = it;
				arrayAppend(order, it.itemKey);
			}
		}
		var rebuilt = [];
		var kept = {};
		for (var existing in review.unresolvedPlaceholders) {
			if (!isStruct(existing) || !structKeyExists(existing, "itemKey") || !structKeyExists(marked, existing.itemKey)) continue;
			arrayAppend(rebuilt, summaryEntry(marked[existing.itemKey]));
			kept[existing.itemKey] = true;
		}
		arraySort(order, "text");
		for (var key in order) if (!structKeyExists(kept, key)) arrayAppend(rebuilt, summaryEntry(marked[key]));
		review["unresolvedPlaceholders"] = rebuilt;
	}

	private struct function summaryEntry(required struct item) {
		return {
			"itemKey": arguments.item.itemKey,
			"prompt": arguments.item.prompt,
			"sourceLocation": isNull(arguments.item.sourceLocation) ? javaCast("null", "") : arguments.item.sourceLocation
		};
	}

	// ---- helpers ---------------------------------------------------------------------------------

	private string function keyOf(required struct edit) {
		return structKeyExists(arguments.edit, "key") && !isNull(arguments.edit.key) && isSimpleValue(arguments.edit.key) ? trim(arguments.edit.key) : "";
	}

	private boolean function sameText(any a, any b) {
		if (isNull(arguments.a) && isNull(arguments.b)) return true;
		if (isNull(arguments.a) || isNull(arguments.b)) return false;
		return compare(toString(arguments.a), toString(arguments.b)) == 0;
	}

	private string function textOf(required struct src, required string field) {
		return structKeyExists(arguments.src, arguments.field) && !isNull(arguments.src[arguments.field]) && isSimpleValue(arguments.src[arguments.field])
			? toString(arguments.src[arguments.field]) : "";
	}

	private boolean function matches(required string q, required array haystack) {
		for (var text in arguments.haystack) if (findNoCase(arguments.q, text)) return true;
		return false;
	}

	private struct function entry(required string target, required string key, required string label, required string context, required struct src) {
		var fields = {};
		for (var f in structKeyArray(variables.FIELDS[arguments.target])) {
			fields[f] = structKeyExists(arguments.src, f) && !isNull(arguments.src[f]) ? arguments.src[f] : javaCast("null", "");
		}
		return { "target": arguments.target, "key": arguments.key, "label": arguments.label, "context": arguments.context, "fields": fields };
	}

	private struct function issue(required string code, required string message, required string path) {
		return { "code": arguments.code, "message": arguments.message, "path": arguments.path };
	}
}
