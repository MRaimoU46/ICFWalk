/**
 * Evaluates instrument rules (evaluateVisibility: CFML reserves the name "evaluate") against a walk's working state and derives visibility, response
 * states, and filtered option lists. This is the server-side twin of app/assets/js/rules.js;
 * both are proven equivalent by tests/fixtures/visibility-vectors.json.
 *
 * Working state (the same shape the Phase 4 autosave payload uses, docs/DATA_CONTRACT.md):
 *   { "dimensions": { code: { selectedValueCode?, otherText?, textValue?, dateValue? } },
 *     "responses":  { itemKey: { storedCode?, textValue? } } }
 *
 * Codes are compared exactly with compare() (never ==, which coerces "yes"/"1" and "1"/"1.0" to
 * equal values in CFML), matching the strict equality of the JavaScript twin (Phase 4 fix).
 *
 * Semantics (all derived from the render model, nothing keyed to a specific section or item):
 *   - A target (section, item, dimension placement) with SHOW rules is visible when any active
 *     rule evaluates true; a target without rules is visible (a placement without rules follows
 *     visibleByDefault). Children of a hidden section are hidden.
 *   - Conditions: DIMENSION sources compare the selected value's label or code (or the typed
 *     text/date value); ITEM sources compare the stored option code. Operators EQUALS, NOT_EQUALS,
 *     IN, NOT_IN; logic AND / OR.
 *   - Response state: HIDDEN when the item is hidden by a section or a dimension-driven rule;
 *     NOT_APPLICABLE when hidden by a rule sourced from a sibling item (the skippable-component
 *     applicability answer); otherwise ANSWERED when a valid option code or non-empty text is
 *     present, else UNANSWERED. Unanswered is never zero.
 *   - Option filters (placement settings.optionFilter, e.g. schoolTypeToGradeBand) restrict a
 *     dimension's values to those sharing the source dimension's selected value group; when the
 *     source is unselected or ungrouped ("Other"), every value is allowed.
 *
 * normalize() applies the state changes the prototype performs in the browser: a filtered
 * selection that is no longer allowed is cleared; responses in NOT_APPLICABLE state are cleared
 * (ratings clear when a component is marked not applicable; notes are never rated and so remain);
 * values hidden by dimension rules are retained (HIDDEN) unless the hidden-value policy is CLEAR.
 */
component output="false" {

	public VisibilityEngine function init() {
		return this;
	}

	/** New-walk state: defaults from item settings.defaultStoredCode (e.g. applicability = "no"). */
	public struct function blankState(required struct model) {
		var state = { "dimensions": {}, "responses": {} };
		var idx = index(arguments.model);
		for (var key in structKeyArray(idx.items)) {
			var it = idx.items[key];
			if (!isNull(it.defaultStoredCode) && len(it.defaultStoredCode)) state.responses[it.itemKey] = { "storedCode": it.defaultStoredCode };
		}
		return state;
	}

	public struct function evaluateVisibility(required struct model, required struct state) {
		var idx = index(arguments.model);
		var st = coerceState(arguments.state);
		var rulesByTarget = idx.rulesByTarget;
		var out = { "sections": {}, "items": {}, "dimensions": {}, "dimensionOptions": {}, "responseStates": {}, "dimensionStates": {} };
		var ruleResults = {};
		for (var r in arguments.model.rules) ruleResults[r.ruleKey] = evaluateRule(r, st, idx);

		// Sections (parents before children: idx.sectionOrder is a pre-order walk).
		for (var key in idx.sectionOrder) {
			var s = idx.sections[key];
			var parentVisible = isNull(s.parentSectionKey) ? true : out.sections[s.parentSectionKey];
			out.sections[key] = parentVisible && targetVisible(rulesByTarget, "SECTION", key, ruleResults, true);
		}
		// Option filters.
		for (var f in arguments.model.optionFilters) {
			out.dimensionOptions[f.dimensionCode] = allowedValueCodes(arguments.model, f, st);
		}
		// Placements.
		for (var key in idx.sectionOrder) {
			for (var p in idx.sections[key].placements) {
				var visible = out.sections[key] && targetVisible(rulesByTarget, "DIMENSION", p.dimensionCode, ruleResults, p.visibleByDefault);
				out.dimensions[p.dimensionCode] = visible;
				out.dimensionStates[p.dimensionCode] = !visible ? "HIDDEN" : (dimensionAnswered(arguments.model, p, st) ? "ANSWERED" : "UNANSWERED");
			}
		}
		// Items.
		for (var key in idx.sectionOrder) {
			for (var it in idx.sections[key].items) {
				var sectionVisible = out.sections[key];
				var ownVisible = targetVisible(rulesByTarget, "ITEM", it.itemKey, ruleResults, true);
				var visible = sectionVisible && ownVisible;
				out.items[it.itemKey] = visible;
				if (it.layout == "display-heading" || it.layout == "display-guidance") continue;
				if (visible) {
					out.responseStates[it.itemKey] = itemAnswered(it, st) ? "ANSWERED" : "UNANSWERED";
				} else if (sectionVisible && hiddenByItemRule(rulesByTarget, it.itemKey)) {
					out.responseStates[it.itemKey] = "NOT_APPLICABLE";
				} else {
					out.responseStates[it.itemKey] = "HIDDEN";
				}
			}
		}
		return out;
	}

	/**
	 * Returns { state, changes[] } where state is a copy with the derived clearing applied.
	 * policies.hiddenDimensionPolicy: RETAIN_HIDDEN (default) or CLEAR.
	 */
	public struct function normalize(required struct model, required struct state, struct policies = {}) {
		var st = duplicate(coerceState(arguments.state));
		var changes = [];
		var policy = structKeyExists(arguments.policies, "hiddenDimensionPolicy") ? arguments.policies.hiddenDimensionPolicy : "RETAIN_HIDDEN";
		// Pass 1: option filters (a school change can invalidate the grade, which drives other rules).
		var ev = evaluateVisibility(arguments.model, st);
		for (var code in structKeyArray(ev.dimensionOptions)) {
			if (!structKeyExists(st.dimensions, code)) continue;
			var sel = valueOf(st.dimensions[code], "selectedValueCode");
			if (len(sel) && !arrayContains(ev.dimensionOptions[code], sel)) {
				st.dimensions[code] = {};
				arrayAppend(changes, { "kind": "DIMENSION_CLEARED", "key": code, "reason": "OPTION_FILTER" });
			}
		}
		// Pass 2: re-evaluate, then clear NOT_APPLICABLE responses and (by policy) hidden dimensions.
		ev = evaluateVisibility(arguments.model, st);
		for (var key in structKeyArray(ev.responseStates)) {
			if (ev.responseStates[key] == "NOT_APPLICABLE" && structKeyExists(st.responses, key) && hasValue(st.responses[key])) {
				st.responses[key] = {};
				arrayAppend(changes, { "kind": "RESPONSE_CLEARED", "key": key, "reason": "NOT_APPLICABLE" });
			}
		}
		if (policy == "CLEAR") {
			for (var code in structKeyArray(ev.dimensions)) {
				if (!ev.dimensions[code] && structKeyExists(st.dimensions, code) && hasValue(st.dimensions[code])) {
					st.dimensions[code] = {};
					arrayAppend(changes, { "kind": "DIMENSION_CLEARED", "key": code, "reason": "HIDDEN_CLEAR" });
				}
			}
		}
		arraySort(changes, function(a, b) { return compare(a.kind & ":" & a.key, b.kind & ":" & b.key); });
		return { "state": st, "changes": changes };
	}

	// ---- rule evaluation ---------------------------------------------------------------------

	private boolean function evaluateRule(required struct rule, required struct st, required struct idx) {
		var conds = arguments.rule.conditions;
		var logic = structKeyExists(conds, "logic") ? uCase(conds.logic) : "AND";
		var list = structKeyExists(conds, "conditions") ? conds.conditions : [];
		if (!arrayLen(list)) return true;
		var anyTrue = false;
		var allTrue = true;
		for (var c in list) {
			var r = evaluateCondition(c, arguments.st, arguments.idx);
			if (r) anyTrue = true; else allTrue = false;
		}
		return logic == "OR" ? anyTrue : allTrue;
	}

	private boolean function evaluateCondition(required struct c, required struct st, required struct idx) {
		var candidates = [];
		if (arguments.c.sourceType == "DIMENSION") {
			candidates = dimensionCandidates(arguments.idx.model, arguments.c.sourceKey, arguments.st);
		} else if (arguments.c.sourceType == "ITEM") {
			if (structKeyExists(arguments.st.responses, arguments.c.sourceKey)) {
				var code = valueOf(arguments.st.responses[arguments.c.sourceKey], "storedCode");
				if (len(code)) arrayAppend(candidates, code);
			}
		} else {
			throw(type = "ICFWalk.Configuration", message = "Unsupported rule source type '" & arguments.c.sourceType & "'.", errorcode = "RULE_SOURCE_UNSUPPORTED");
		}
		var op = uCase(arguments.c.operator);
		var expected = arguments.c.comparisonValue;
		var hit = false;
		if (op == "EQUALS" || op == "NOT_EQUALS") {
			var e = isSimpleValue(expected) ? toString(expected) : "";
			for (var v in candidates) if (compare(v, e) == 0) hit = true;
			return op == "EQUALS" ? hit : !hit;
		}
		if (op == "IN" || op == "NOT_IN") {
			var list = expected;
			if (isSimpleValue(list)) list = isJSON(list) ? deserializeJSON(list) : [toString(list)];
			if (!isArray(list)) list = [];
			for (var v in candidates) for (var e in list) if (isSimpleValue(e) && compare(v, toString(e)) == 0) hit = true;
			return op == "IN" ? hit : !hit;
		}
		throw(type = "ICFWalk.Configuration", message = "Unsupported rule operator '" & arguments.c.operator & "'.", errorcode = "RULE_OPERATOR_UNSUPPORTED");
	}

	/** Strings a dimension value can be compared as: the selected value's code and label, or typed text. */
	private array function dimensionCandidates(required struct model, required string code, required struct st) {
		var out = [];
		if (!structKeyExists(arguments.st.dimensions, arguments.code)) return out;
		var v = arguments.st.dimensions[arguments.code];
		var sel = valueOf(v, "selectedValueCode");
		if (len(sel)) {
			arrayAppend(out, sel);
			if (structKeyExists(arguments.model.dimensions, arguments.code)) {
				for (var dv in arguments.model.dimensions[arguments.code].values) if (compare(dv.valueCode, sel) == 0) arrayAppend(out, dv.label);
			}
			return out;
		}
		var text = valueOf(v, "textValue");
		if (len(text)) arrayAppend(out, text);
		var d = valueOf(v, "dateValue");
		if (len(d)) arrayAppend(out, d);
		return out;
	}

	private boolean function targetVisible(required struct rulesByTarget, required string type, required string key, required struct results, required boolean defaultVisible) {
		var tk = arguments.type & ":" & arguments.key;
		if (!structKeyExists(arguments.rulesByTarget, tk)) return arguments.defaultVisible;
		for (var r in arguments.rulesByTarget[tk]) if (arguments.results[r.ruleKey]) return true;
		return false;
	}

	private boolean function hiddenByItemRule(required struct rulesByTarget, required string itemKey) {
		var tk = "ITEM:" & arguments.itemKey;
		if (!structKeyExists(arguments.rulesByTarget, tk)) return false;
		for (var r in arguments.rulesByTarget[tk]) {
			for (var c in r.conditions.conditions) if (c.sourceType == "ITEM") return true;
		}
		return false;
	}

	private array function allowedValueCodes(required struct model, required struct filter, required struct st) {
		var dim = arguments.model.dimensions[arguments.filter.dimensionCode];
		var all = [];
		for (var v in dim.values) arrayAppend(all, v.valueCode);
		var srcCode = arguments.filter.sourceDimensionCode;
		if (!structKeyExists(arguments.st.dimensions, srcCode)) return all;
		var sel = valueOf(arguments.st.dimensions[srcCode], "selectedValueCode");
		if (!len(sel) || !structKeyExists(arguments.model.dimensions, srcCode)) return all;
		var group = "";
		var found = false;
		for (var sv in arguments.model.dimensions[srcCode].values) {
			if (compare(sv.valueCode, sel) == 0) { found = true; group = isNull(sv[arguments.filter.matchField]) ? "" : toString(sv[arguments.filter.matchField]); }
		}
		if (!found || !len(group)) return all;
		var out = [];
		for (var v in dim.values) {
			if (!isNull(v[arguments.filter.matchField]) && compare(toString(v[arguments.filter.matchField]), group) == 0) arrayAppend(out, v.valueCode);
		}
		return out;
	}

	// ---- answered checks ---------------------------------------------------------------------

	private boolean function itemAnswered(required struct it, required struct st) {
		if (!structKeyExists(arguments.st.responses, arguments.it.itemKey)) return false;
		var r = arguments.st.responses[arguments.it.itemKey];
		if (structKeyExists(arguments.it, "responseSet") && !isNull(arguments.it.responseSet) && isStruct(arguments.it.responseSet)) {
			var code = valueOf(r, "storedCode");
			if (!len(code)) return false;
			for (var o in arguments.it.responseSet.options) if (compare(o.storedCode, code) == 0) return true;
			return false;
		}
		return len(trim(valueOf(r, "textValue"))) > 0;
	}

	private boolean function dimensionAnswered(required struct model, required struct p, required struct st) {
		if (!structKeyExists(arguments.st.dimensions, arguments.p.dimensionCode)) return false;
		var v = arguments.st.dimensions[arguments.p.dimensionCode];
		var sel = valueOf(v, "selectedValueCode");
		if (len(sel)) {
			if (!structKeyExists(arguments.model.dimensions, arguments.p.dimensionCode)) return false;
			for (var dv in arguments.model.dimensions[arguments.p.dimensionCode].values) if (compare(dv.valueCode, sel) == 0) return true;
			return false;
		}
		return len(trim(valueOf(v, "textValue"))) > 0 || len(trim(valueOf(v, "dateValue"))) > 0;
	}

	private boolean function hasValue(required struct v) {
		for (var k in ["selectedValueCode", "otherText", "textValue", "dateValue", "storedCode"]) if (len(valueOf(arguments.v, k))) return true;
		return false;
	}

	private string function valueOf(required any v, required string key) {
		if (!isStruct(arguments.v) || !structKeyExists(arguments.v, arguments.key) || isNull(arguments.v[arguments.key]) || !isSimpleValue(arguments.v[arguments.key])) return "";
		return toString(arguments.v[arguments.key]);
	}

	private struct function coerceState(required any state) {
		var st = { "dimensions": {}, "responses": {} };
		if (isStruct(arguments.state)) {
			if (structKeyExists(arguments.state, "dimensions") && isStruct(arguments.state.dimensions)) st.dimensions = arguments.state.dimensions;
			if (structKeyExists(arguments.state, "responses") && isStruct(arguments.state.responses)) st.responses = arguments.state.responses;
		}
		return st;
	}

	// ---- model index --------------------------------------------------------------------------
	// Built per call (a pre-order walk of ~25 sections) and never stored on the model: the model is
	// the shared, cached object that /api/instrument/current and the walk endpoints serialize, and
	// an index holding a back-reference to it would make that serialization circular (Phase 4 fix).

	private struct function index(required struct model) {
		var idx = { "model": arguments.model, "sections": {}, "sectionOrder": [], "items": {}, "rulesByTarget": {} };
		walk(arguments.model.root, idx);
		for (var r in arguments.model.rules) {
			var tk = r.targetType & ":" & r.targetKey;
			if (!structKeyExists(idx.rulesByTarget, tk)) idx.rulesByTarget[tk] = [];
			arrayAppend(idx.rulesByTarget[tk], r);
		}
		return idx;
	}

	private void function walk(required struct node, required struct idx) {
		arguments.idx.sections[arguments.node.sectionKey] = arguments.node;
		arrayAppend(arguments.idx.sectionOrder, arguments.node.sectionKey);
		for (var it in arguments.node.items) arguments.idx.items[it.itemKey] = it;
		for (var child in arguments.node.children) walk(child, arguments.idx);
	}
}
