/**
 * Shared summary formatting (Phase 5). Twin of app/assets/js/summary.js;
 * tests/fixtures/summary-vectors.json proves both produce byte-identical output.
 *
 * Every function here is a pure, side-effect-free function of the render model
 * (icfwalk-render-model/1), the working state ({ dimensions, responses }) and the engine
 * evaluation (VisibilityEngine.evaluateVisibility). Nothing touches the database, the request
 * scope, or the log, and no section, item, dimension, or option is named: every string comes from
 * the model (titles, prompts, option labels, placement labels, partNumber, selectableParts,
 * behavior.export) or from presentation() below, which is the same device as LIST_CARD in app.js
 * (BUILD_STATUS Phase 3 decision 5).
 *
 * Output contract (both twins, byte-identical):
 *   summaryText(model, state, evaluation)                     -> string, chr(10) joined, no trailing newline
 *   fileName(model, state, evaluation, walkId)                -> "ICFWalk_<label>.txt"
 *   emailDraft(model, state, evaluation, includedPartKeys)    -> { subject, body }
 *   componentAverage(section, state, evaluation)              -> "3.5" | "n/a"
 *   averageText(sum, count)                                   -> "3.5" | "n/a"
 *   sanitizeFileLabel(label)                                  -> safe filename label
 *
 * Every code comparison uses compare() (Phase 4 decision 10): "yes"/"1" and "1"/"1.0" are not the
 * same option code, and a coerced comparison would export an answer nobody gave.
 *
 * The characters that must survive byte-exactly are built with chr() rather than written as source
 * literals, so the exported bytes never depend on how a CFML engine decodes this file. Upper-casing
 * goes through Locale.ROOT for the same reason: a server whose default locale is Turkish would
 * otherwise upper-case "i" to a dotted capital and break the golden vectors.
 *
 * Resolved source conflicts are recorded in docs/PHASE_5_IMPLEMENTATION_BRIEF.md section 14 and
 * summarized in BUILD_STATUS.md (Phase 5 decisions).
 */
component output="false" {

	public WalkSummaryFormatter function init() {
		variables.MIDDLE_DOT = chr(183);          // U+00B7, separates a part number from its title
		variables.EM_DASH = chr(8212);            // U+2014
		variables.BULLET = chr(8226);             // U+2022
		variables.RIGHT_SINGLE_QUOTE = chr(8217); // U+2019
		variables.NL = chr(10);

		variables.TITLE_SEPARATOR = " " & variables.MIDDLE_DOT & " ";
		variables.HEADING_SEPARATOR = " " & variables.EM_DASH & " ";

		variables.SUMMARY_TITLE = "ICFWALK SUMMARY";
		variables.SUMMARY_RULE = "================";
		variables.UNANSWERED = "not answered";
		variables.NONE_NOTED = "(none noted)";
		variables.NOT_PART_SUFFIX = "  (not part of this lesson at the time of the visit)";
		variables.AVG_PREFIX = "  (avg: ";
		variables.AVG_SUFFIX = ")";
		variables.NOTES_PREFIX = "Notes: ";
		variables.NO_AVERAGE = "n/a";
		variables.VALUE_GAP = "  ";

		// The only presentation literals besides the prototype's template sentences. Dimension codes
		// are addressing, not instrument content -- the same justification as LIST_CARD in app.js.
		variables.PART4_LABELS = { "summary_strengths": "Strengths", "summary_growth": "Growth areas" };
		variables.EMAIL_TITLE_DIMENSIONS = ["grade", "content"];
		variables.EMAIL_DATE_DIMENSION = "date";
		variables.EMAIL_OBSERVER_DIMENSION = "observer";

		// Brief 14.1. behavior.export.preservePrototypeSectionOrder delegates the conditional-card
		// order to the prototype, whose order differs from the snapshot's displayOrder in exactly one
		// place. The rule is keyed on the SHOW rule's source dimension and never on a section key:
		// conditional cards sourced from HOIST_SOURCE print immediately before the LAST conditional
		// card sourced from HOIST_ANCHOR. Today that places Content-Area before ESL. When content
		// owners renumber displayOrder (the OPEN item), the rule becomes a no-op.
		variables.HOIST_SOURCE = "content";
		variables.HOIST_ANCHOR = "classType";

		// Prototype template sentences, transcribed verbatim (brief sections 5 and 8).
		variables.EMAIL = {
			"opening": "I enjoyed my time stopping by your classroom today. I wanted to share a quick feedback note from what I observed during the visit",
			"inPrefix": " in ",
			"onPrefix": " on ",
			"nothingSelected": "(No sections were selected " & variables.EM_DASH & " check at least one part above, then update the draft.)",
			"closing": "Stop by whenever you can, as I would love to talk through this with you " & variables.EM_DASH & " thanks again for what you do in your classroom for our students.",
			"signaturePlaceholder": "[Your name]",
			"subject": "Quick note from today" & variables.RIGHT_SINGLE_QUOTE & "s walk-through",
			"notApplicableBullet": variables.BULLET & " Not part of this lesson at the time of the visit.",
			"noPartNotes": "(No notes recorded for this part.)",
			"noComponentNotes": "(No notes recorded for this component.)",
			"noSummaryNotes": "(No summary notes recorded yet.)",
			"nestedNotesInfix": " notes: "
		};

		variables.LOCALE_ROOT = createObject("java", "java.util.Locale").ROOT;
		variables.BigDecimal = createObject("java", "java.math.BigDecimal");
		variables.MathContext = createObject("java", "java.math.MathContext");
		variables.RoundingMode = createObject("java", "java.math.RoundingMode");
		variables.HALF_UP = variables.RoundingMode.valueOf("HALF_UP");
		return this;
	}

	/** The presentation map, exposed so tests and documentation read the same values the code uses. */
	public struct function presentation() {
		return {
			"part4Labels": duplicate(variables.PART4_LABELS),
			"emailTitleDimensions": duplicate(variables.EMAIL_TITLE_DIMENSIONS),
			"emailDateDimension": variables.EMAIL_DATE_DIMENSION,
			"emailObserverDimension": variables.EMAIL_OBSERVER_DIMENSION,
			"exportOrderHoist": { "source": variables.HOIST_SOURCE, "beforeLastSourcedBy": variables.HOIST_ANCHOR }
		};
	}

	// ---- null-safe model access -----------------------------------------------------------------

	/** Render-model fields are emitted as nulls rather than absent keys; read them defensively. */
	private any function nv(required struct holder, required string key, any fallback = "") {
		if (!structKeyExists(arguments.holder, arguments.key)) return arguments.fallback;
		if (!structKeyExists(arguments.holder, arguments.key)) return arguments.fallback;
		return arguments.holder[arguments.key];
	}

	private array function childrenOf(required struct section) { return nv(arguments.section, "children", []); }
	private array function itemsOf(required struct section) { return nv(arguments.section, "items", []); }
	private array function placementsOf(required struct section) { return nv(arguments.section, "placements", []); }

	/** Items the export prints as "- <prompt>  [<value>]". Applicability and display rows never print. */
	private array function choiceItems(required struct section) {
		var out = [];
		for (var it in itemsOf(arguments.section)) {
			var layout = toString(nv(it, "layout", ""));
			if (compare(layout, "question") == 0 || compare(layout, "choice-row") == 0) arrayAppend(out, it);
		}
		return out;
	}

	/** Scored question items -- the ones a component average is taken over. */
	private array function ratedItems(required struct section) {
		var out = [];
		for (var it in itemsOf(arguments.section)) {
			if (compare(toString(nv(it, "layout", "")), "question") != 0) continue;
			var set = nv(it, "responseSet", "");
			if (!isStruct(set)) continue;
			if (!isBoolean(nv(set, "scoreEnabled", false)) || !nv(set, "scoreEnabled", false)) continue;
			arrayAppend(out, it);
		}
		return out;
	}

	private any function notesItemOf(required struct section) {
		for (var it in itemsOf(arguments.section)) if (compare(toString(nv(it, "layout", "")), "notes") == 0) return it;
		return "";
	}

	/** Part 4's free-text items that carry an export label. */
	private array function labelledTextItems(required struct section) {
		var out = [];
		for (var it in itemsOf(arguments.section)) {
			if (compare(toString(nv(it, "layout", "")), "text") != 0) continue;
			if (!structKeyExists(variables.PART4_LABELS, it.itemKey)) continue;
			arrayAppend(out, it);
		}
		return out;
	}

	private boolean function isAnswered(required struct evaluation, required string key) {
		if (!structKeyExists(arguments.evaluation.responseStates, arguments.key)) return false;
		return compare(arguments.evaluation.responseStates[arguments.key], "ANSWERED") == 0;
	}

	private string function textOf(required struct state, required string itemKey) {
		if (!structKeyExists(arguments.state.responses, arguments.itemKey)) return "";
		return toString(nv(arguments.state.responses[arguments.itemKey], "textValue", ""));
	}

	/** Answered note text for a section, or "" when the section has no note or it is empty. */
	private string function notesTextOf(required struct section, required struct state, required struct evaluation) {
		var it = notesItemOf(arguments.section);
		if (!isStruct(it)) return "";
		if (!isAnswered(arguments.evaluation, it.itemKey)) return "";
		return textOf(arguments.state, it.itemKey);
	}

	/**
	 * A dimension's display text: the selected option's label, the typed Other text, or the typed
	 * value -- but only while the engine reports it ANSWERED (brief 14.2), so a value the pinned
	 * instrument currently hides is never exported, named in a file, or quoted in an email.
	 */
	private string function dimensionText(required struct model, required struct state, required struct evaluation, required string code) {
		if (!structKeyExists(arguments.evaluation.dimensionStates, arguments.code)) return "";
		if (compare(arguments.evaluation.dimensionStates[arguments.code], "ANSWERED") != 0) return "";
		if (!structKeyExists(arguments.state.dimensions, arguments.code)) return "";
		var v = arguments.state.dimensions[arguments.code];
		if (!isStruct(v)) return "";
		var selected = toString(nv(v, "selectedValueCode", ""));
		if (len(selected)) {
			if (!structKeyExists(arguments.model.dimensions, arguments.code)) return "";
			for (var value in arguments.model.dimensions[arguments.code].values) {
				if (compare(value.valueCode, selected) != 0) continue;
				var otherText = toString(nv(v, "otherText", ""));
				// Convention: on an allowOther dimension, the value coded "other" reveals free text.
				if (compareNoCase(toString(value.valueCode), "other") == 0 && len(otherText)) return otherText;
				return toString(value.label);
			}
			return "";
		}
		var typed = toString(nv(v, "textValue", ""));
		if (len(typed)) return typed;
		return toString(nv(v, "dateValue", ""));
	}

	/** Locale-independent upper case, matching JavaScript's String.prototype.toUpperCase(). */
	private string function upper(required string text) {
		return javaCast("string", arguments.text).toUpperCase(variables.LOCALE_ROOT);
	}

	/** "Part 1 / Target / Taxonomy / Pacing" -> "PART 1 - TARGET / TAXONOMY / PACING" (brief section 5). */
	private string function headingOf(required struct section) {
		return upper(replace(toString(arguments.section.title), variables.TITLE_SEPARATOR, variables.HEADING_SEPARATOR, "all"));
	}

	/** "Part 3 (dot) Conditions for Learning" -> "Conditions for Learning". */
	private string function titleAfterSeparator(required struct section) {
		var title = toString(arguments.section.title);
		var at = find(variables.TITLE_SEPARATOR, title);
		if (at == 0) return title;
		return mid(title, at + len(variables.TITLE_SEPARATOR), len(title));
	}

	/** Brief 14.4: a label ending in a colon is not doubled when ": " is appended. */
	private string function placementLabel(required struct placement) {
		var label = toString(arguments.placement.label);
		if (len(label) && compare(right(label, 1), ":") == 0) return left(label, len(label) - 1);
		return label;
	}

	private void function eachSection(required struct node, required any visitor) {
		arguments.visitor(arguments.node);
		for (var child in childrenOf(arguments.node)) eachSection(child, arguments.visitor);
	}

	/** The dimension a section's SHOW rule reads, or "" when it has none. */
	private string function ruleSourceDimension(required struct model, required struct section) {
		for (var ruleKey in nv(arguments.section, "ruleKeys", [])) {
			for (var rule in arguments.model.rules) {
				if (compare(rule.ruleKey, ruleKey) != 0) continue;
				var conditions = nv(rule, "conditions", {});
				if (!isStruct(conditions)) continue;
				for (var condition in nv(conditions, "conditions", [])) {
					if (compare(toString(nv(condition, "sourceType", "")), "DIMENSION") == 0) return toString(condition.sourceKey);
				}
			}
		}
		return "";
	}

	// ---- values and lines -------------------------------------------------------------------------

	private numeric function maxScoreOf(required struct responseSet) {
		var max = 0;
		for (var option in arguments.responseSet.options) {
			var score = nv(option, "numericScore", "");
			if (!isNumeric(score)) continue;
			if (score > max) max = score;
		}
		return max;
	}

	private any function selectedOption(required struct item, required struct state) {
		if (!structKeyExists(arguments.state.responses, arguments.item.itemKey)) return "";
		var stored = toString(nv(arguments.state.responses[arguments.item.itemKey], "storedCode", ""));
		if (!len(stored)) return "";
		for (var option in arguments.item.responseSet.options) if (compare(option.storedCode, stored) == 0) return option;
		return "";
	}

	/** Brief 14.5: scored choices print <code>/<max>; every other choice prints its option label. */
	private string function choiceValue(required struct item, required struct state, required struct evaluation) {
		if (!isAnswered(arguments.evaluation, arguments.item.itemKey)) return variables.UNANSWERED;
		var option = selectedOption(arguments.item, arguments.state);
		if (!isStruct(option)) return variables.UNANSWERED;
		var set = arguments.item.responseSet;
		if (isBoolean(nv(set, "scoreEnabled", false)) && nv(set, "scoreEnabled", false)) {
			return toString(option.storedCode) & "/" & toString(maxScoreOf(set));
		}
		return toString(option.label);
	}

	/**
	 * Brief 14.8: a non-scored choice item sitting among scored siblings prints its prompt with a
	 * trailing colon (the prototype's "- Pacing:  [ON pace]"). Stated as a data rule, not a key.
	 */
	private boolean function isLabelledChoice(required struct item, required struct section) {
		var set = nv(arguments.item, "responseSet", "");
		if (isStruct(set) && isBoolean(nv(set, "scoreEnabled", false)) && nv(set, "scoreEnabled", false)) return false;
		return arrayLen(ratedItems(arguments.section)) > 0;
	}

	private string function choiceLine(required struct item, required struct section, required struct state, required struct evaluation) {
		var suffix = isLabelledChoice(arguments.item, arguments.section) ? ":" : "";
		return "- " & toString(arguments.item.prompt) & suffix & variables.VALUE_GAP & "[" & choiceValue(arguments.item, arguments.state, arguments.evaluation) & "]";
	}

	/** A choice row prints unless the engine hides it or reports it not applicable. */
	private boolean function choicePrints(required struct item, required struct evaluation) {
		var key = arguments.item.itemKey;
		if (structKeyExists(arguments.evaluation.items, key) && !arguments.evaluation.items[key]) return false;
		if (structKeyExists(arguments.evaluation.responseStates, key) && compare(arguments.evaluation.responseStates[key], "NOT_APPLICABLE") == 0) return false;
		return true;
	}

	private void function pushPlacementLines(required array lines, required struct model, required struct section, required struct state, required struct evaluation) {
		for (var placement in placementsOf(arguments.section)) {
			var text = dimensionText(arguments.model, arguments.state, arguments.evaluation, placement.dimensionCode);
			if (!len(text)) continue;
			arrayAppend(arguments.lines, placementLabel(placement) & ": " & text);
		}
	}

	private void function pushChoiceLines(required array lines, required struct section, required struct state, required struct evaluation) {
		for (var item in choiceItems(arguments.section)) {
			if (!choicePrints(item, arguments.evaluation)) continue;
			arrayAppend(arguments.lines, choiceLine(item, arguments.section, arguments.state, arguments.evaluation));
		}
	}

	private void function pushNotesLine(required array lines, required struct section, required struct state, required struct evaluation) {
		var text = notesTextOf(arguments.section, arguments.state, arguments.evaluation);
		if (len(text)) arrayAppend(arguments.lines, variables.NOTES_PREFIX & text);
	}

	// ---- averages -----------------------------------------------------------------------------------

	/**
	 * One decimal place with JavaScript's Number.prototype.toFixed(1) semantics.
	 *
	 * toFixed rounds the IEEE-754 double half away from zero on its *exact* binary value, which is
	 * why 3.05 (stored as 3.04999999999999982...) formats as "3.0" while 2.25 (exactly representable)
	 * formats as "2.3". Reproducing that needs the same double, so the quotient is taken to 40
	 * significant decimal digits and narrowed to the nearest double rather than trusting the CFML
	 * engine's own division to stay in double space (Adobe ColdFusion may widen arithmetic). The
	 * exact binary value of that double is then rounded HALF_UP at one decimal. The shared vectors
	 * pin the agreement; WalkSummaryFormatterTest fails loudly if an engine ever diverges.
	 *
	 * Scores are non-negative, so HALF_UP (away from zero) and toFixed's "pick the larger n" agree.
	 */
	public string function averageText(required numeric sum, required numeric count) {
		if (arguments.count == 0) return variables.NO_AVERAGE;
		var quotient = variables.BigDecimal.init(javaCast("string", toString(arguments.sum)))
			.divide(variables.BigDecimal.init(javaCast("string", toString(arguments.count))), variables.MathContext.init(javaCast("int", 40)));
		var asDouble = variables.BigDecimal.init(javaCast("double", quotient.doubleValue()));
		return asDouble.setScale(javaCast("int", 1), variables.HALF_UP).toPlainString();
	}

	/**
	 * COND-15 / SUM-02: the mean of the numeric scores of answered rated items only. A blank rating is
	 * never counted as zero, and a component with nothing answered has no average.
	 */
	public string function componentAverage(required struct section, required struct state, required struct evaluation) {
		var sum = 0;
		var count = 0;
		for (var item in ratedItems(arguments.section)) {
			if (!isAnswered(arguments.evaluation, item.itemKey)) continue;
			var option = selectedOption(item, arguments.state);
			if (!isStruct(option)) continue;
			var score = nv(option, "numericScore", "");
			if (!isNumeric(score)) continue;
			sum += score;
			count++;
		}
		return averageText(sum, count);
	}

	/** Rated question items and how many are answered; all NOT_APPLICABLE means "not part of it". */
	private struct function ratingSummary(required struct section, required struct evaluation) {
		var rated = ratedItems(arguments.section);
		var answered = 0;
		var notApplicable = arrayLen(rated) > 0;
		for (var item in rated) {
			if (isAnswered(arguments.evaluation, item.itemKey)) answered++;
			var state = structKeyExists(arguments.evaluation.responseStates, item.itemKey) ? arguments.evaluation.responseStates[item.itemKey] : "";
			if (compare(state, "NOT_APPLICABLE") != 0) notApplicable = false;
		}
		return { "total": arrayLen(rated), "answered": answered, "notApplicable": notApplicable };
	}

	// ---- summary text -------------------------------------------------------------------------------

	/**
	 * Top-level sections in export order: snapshot order, with the one documented reordering of the
	 * conditional classroom cards applied (brief 14.1, HOIST_SOURCE / HOIST_ANCHOR above).
	 */
	public array function exportSections(required struct model) {
		var top = childrenOf(arguments.model.root);
		var hoisted = [];
		var rest = [];
		for (var section in top) {
			var isHoisted = nv(section, "conditional", false) && compare(ruleSourceDimension(arguments.model, section), variables.HOIST_SOURCE) == 0;
			if (isHoisted) arrayAppend(hoisted, section);
			else arrayAppend(rest, section);
		}
		if (!arrayLen(hoisted)) return top;
		var anchorAt = 0;
		for (var i = 1; i <= arrayLen(rest); i++) {
			if (!nv(rest[i], "conditional", false)) continue;
			if (compare(ruleSourceDimension(arguments.model, rest[i]), variables.HOIST_ANCHOR) == 0) anchorAt = i;
		}
		if (anchorAt == 0) return top;
		var out = [];
		for (var i = 1; i <= arrayLen(rest); i++) {
			if (i == anchorAt) for (var h in hoisted) arrayAppend(out, h);
			arrayAppend(out, rest[i]);
		}
		return out;
	}

	/**
	 * The walk's identifying block: a top-level section that carries placements and no responses at
	 * all. It prints its placement lines directly under the title rule, with no heading and no blank
	 * line, exactly as the prototype prints META_FIELDS.
	 */
	private boolean function isIdentityBlock(required struct section) {
		if (nv(arguments.section, "conditional", false)) return false;
		return arrayLen(itemsOf(arguments.section)) == 0 && arrayLen(childrenOf(arguments.section)) == 0;
	}

	private boolean function sectionVisible(required struct evaluation, required struct section) {
		var key = arguments.section.sectionKey;
		if (!structKeyExists(arguments.evaluation.sections, key)) return true;
		return arguments.evaluation.sections[key] ? true : false;
	}

	private void function emitTopSection(required array lines, required struct model, required struct section, required struct state, required struct evaluation) {
		if (!sectionVisible(arguments.evaluation, arguments.section)) return;
		if (isIdentityBlock(arguments.section)) {
			pushPlacementLines(arguments.lines, arguments.model, arguments.section, arguments.state, arguments.evaluation);
			return;
		}
		arrayAppend(arguments.lines, "");
		arrayAppend(arguments.lines, headingOf(arguments.section));
		pushPlacementLines(arguments.lines, arguments.model, arguments.section, arguments.state, arguments.evaluation);
		pushChoiceLines(arguments.lines, arguments.section, arguments.state, arguments.evaluation);
		for (var item in labelledTextItems(arguments.section)) {
			var text = isAnswered(arguments.evaluation, item.itemKey) ? textOf(arguments.state, item.itemKey) : "";
			arrayAppend(arguments.lines, variables.PART4_LABELS[item.itemKey] & ": " & (len(text) ? text : variables.NONE_NOTED));
		}
		pushNotesLine(arguments.lines, arguments.section, arguments.state, arguments.evaluation);
		for (var child in childrenOf(arguments.section)) emitChildSection(arguments.lines, arguments.model, child, arguments.state, arguments.evaluation);
	}

	private void function emitChildSection(required array lines, required struct model, required struct section, required struct state, required struct evaluation) {
		if (!sectionVisible(arguments.evaluation, arguments.section)) return;
		if (compare(toString(nv(arguments.section, "presentation", "")), "component") == 0) {
			emitComponent(arguments.lines, arguments.section, arguments.state, arguments.evaluation);
			return;
		}
		// A block the renderer shows without a heading of its own prints straight under the part heading.
		if (nv(arguments.section, "headingVisible", true)) {
			arrayAppend(arguments.lines, "");
			arrayAppend(arguments.lines, headingOf(arguments.section));
		}
		pushPlacementLines(arguments.lines, arguments.model, arguments.section, arguments.state, arguments.evaluation);
		pushChoiceLines(arguments.lines, arguments.section, arguments.state, arguments.evaluation);
		pushNotesLine(arguments.lines, arguments.section, arguments.state, arguments.evaluation);
		for (var child in childrenOf(arguments.section)) emitChildSection(arguments.lines, arguments.model, child, arguments.state, arguments.evaluation);
	}

	private void function emitComponent(required array lines, required struct section, required struct state, required struct evaluation) {
		arrayAppend(arguments.lines, "");
		var heading = toString(arguments.section.partNumber) & " " & headingOf(arguments.section);
		// SUM-03: a component whose rated rows are all NOT_APPLICABLE is labelled, has no average and
		// no rating lines, and may still carry its retained notes.
		if (ratingSummary(arguments.section, arguments.evaluation).notApplicable) {
			arrayAppend(arguments.lines, heading & variables.NOT_PART_SUFFIX);
			pushNotesLine(arguments.lines, arguments.section, arguments.state, arguments.evaluation);
			return;
		}
		arrayAppend(arguments.lines, heading & variables.AVG_PREFIX & componentAverage(arguments.section, arguments.state, arguments.evaluation) & variables.AVG_SUFFIX);
		pushChoiceLines(arguments.lines, arguments.section, arguments.state, arguments.evaluation);
		pushNotesLine(arguments.lines, arguments.section, arguments.state, arguments.evaluation);
	}

	/** The whole text export. Lines join with LF; there is no trailing newline and no BOM (14.14/15). */
	public string function summaryText(required struct model, required struct state, required struct evaluation) {
		var lines = [variables.SUMMARY_TITLE, variables.SUMMARY_RULE];
		for (var section in exportSections(arguments.model)) emitTopSection(lines, arguments.model, section, arguments.state, arguments.evaluation);
		return arrayToList(lines, variables.NL);
	}

	// ---- file name ----------------------------------------------------------------------------------

	/**
	 * SUM-05. Runs of characters outside [A-Za-z0-9_-] collapse to a single underscore and case is
	 * kept, exactly as the prototype does. Nothing else survives, so "..", "/", "\", and quotes can
	 * never reach a Content-Disposition header or a path.
	 */
	public string function sanitizeFileLabel(required string label) {
		return reReplace(arguments.label, "[^A-Za-z0-9_-]+", "_", "all");
	}

	/**
	 * Parses behavior.export.fileNamePattern ("ICFWalk_<grade>_<content>_<date>.txt") into the literal
	 * prefix and suffix, the dimension codes it names, and the separator between them. The pattern is
	 * the contract for the exported file name, so the codes are read from it rather than restated here.
	 */
	public struct function fileNameSpec(required struct model) {
		var behavior = nv(arguments.model, "behavior", {});
		var exportSettings = isStruct(behavior) ? nv(behavior, "export", {}) : {};
		var pattern = isStruct(exportSettings) ? toString(nv(exportSettings, "fileNamePattern", "")) : "";
		var codes = [];
		var starts = [];
		var ends = [];
		var at = 1;
		while (at <= len(pattern)) {
			var m = reFind("<([^<>]+)>", pattern, at, true);
			if (m.len[1] == 0) break;
			arrayAppend(codes, mid(pattern, m.pos[2], m.len[2]));
			arrayAppend(starts, m.pos[1]);
			arrayAppend(ends, m.pos[1] + m.len[1]);
			at = m.pos[1] + m.len[1];
		}
		if (!arrayLen(codes)) {
			throw(type = "ICFWalk.Configuration", message = "behavior.export.fileNamePattern names no dimension: " & pattern, errorcode = "EXPORT_FILENAME_PATTERN_INVALID");
		}
		var separator = "";
		for (var i = 2; i <= arrayLen(codes); i++) {
			var gap = mid(pattern, ends[i - 1], starts[i] - ends[i - 1]);
			if (i == 2) separator = gap;
			else if (compare(gap, separator) != 0) {
				throw(type = "ICFWalk.Configuration", message = "behavior.export.fileNamePattern mixes separators: " & pattern, errorcode = "EXPORT_FILENAME_PATTERN_INVALID");
			}
		}
		return {
			"prefix": left(pattern, starts[1] - 1),
			"suffix": mid(pattern, ends[arrayLen(codes)], len(pattern)),
			"separator": separator,
			"dimensionCodes": codes
		};
	}

	/**
	 * "ICFWalk_<label>.txt"; a walk with nothing named falls back to its id (both are sanitized).
	 *
	 * The label is sanitized, but the pattern's own literals are instrument configuration, so the
	 * assembled name is checked before it is handed to a caller that will put it in a
	 * Content-Disposition header. A pattern that could smuggle a quote, a path separator, or a
	 * traversal sequence into that header is a configuration fault and is refused loudly rather than
	 * quietly mangled -- the same treatment fileNameSpec already gives a pattern it cannot read.
	 */
	public string function fileName(required struct model, required struct state, required struct evaluation, string walkId = "") {
		var spec = fileNameSpec(arguments.model);
		var parts = [];
		for (var code in spec.dimensionCodes) {
			var text = dimensionText(arguments.model, arguments.state, arguments.evaluation, code);
			if (len(text)) arrayAppend(parts, text);
		}
		var label = arrayLen(parts) ? arrayToList(parts, spec.separator) : arguments.walkId;
		var name = spec.prefix & sanitizeFileLabel(label) & spec.suffix;
		if (reFind("^[A-Za-z0-9_.-]+$", name) == 0 || find("..", name) > 0) {
			throw(
				type = "ICFWalk.Configuration",
				message = "behavior.export.fileNamePattern yields an unsafe file name: " & name,
				errorcode = "EXPORT_FILENAME_UNSAFE"
			);
		}
		return name;
	}

	// ---- email draft ---------------------------------------------------------------------------------

	/** The Part 4 composer item: the one item the model lays out as an email draft. */
	public struct function emailItem(required struct model) {
		var found = [];
		eachSection(arguments.model.root, function(section) {
			for (var item in itemsOf(arguments.section)) {
				if (compare(toString(nv(item, "layout", "")), "email-draft") == 0 && !arrayLen(found)) arrayAppend(found, item);
			}
		});
		if (!arrayLen(found)) {
			throw(type = "ICFWalk.Configuration", message = "The render model has no email-draft item.", errorcode = "EMAIL_DRAFT_ITEM_MISSING");
		}
		return found[1];
	}

	/** The selectable parts the composer offers, in the order the item's settings declare them. */
	public array function selectableParts(required struct model) {
		var settings = nv(emailItem(arguments.model), "settings", {});
		if (!isStruct(settings)) return [];
		var parts = nv(settings, "selectableParts", []);
		return isArray(parts) ? parts : [];
	}

	/**
	 * Resolves a selectable part to the section it summarizes, by data and never by key. A component
	 * is the section carrying its partNumber (falling back to its compId); every other kind is the
	 * top-level part section whose title opens with the part number. Failing loudly beats quietly
	 * dropping a part the person asked for.
	 */
	public struct function resolvePartSection(required struct model, required struct part) {
		var partNum = toString(arguments.part.partNum);
		var found = [];
		if (compare(toString(arguments.part.kind), "component") == 0) {
			eachSection(arguments.model.root, function(section) {
				if (arrayLen(found)) return;
				var number = nv(arguments.section, "partNumber", "");
				if (!len(toString(number)) && isStruct(nv(arguments.section, "settings", {}))) number = nv(nv(arguments.section, "settings", {}), "partNumber", "");
				if (len(toString(number)) && compare(toString(number), partNum) == 0) arrayAppend(found, arguments.section);
			});
			var compId = toString(nv(arguments.part, "compId", ""));
			if (!arrayLen(found) && len(compId)) {
				eachSection(arguments.model.root, function(section) {
					if (!arrayLen(found) && compare(arguments.section.sectionKey, compId) == 0) arrayAppend(found, arguments.section);
				});
			}
		} else {
			for (var section in childrenOf(arguments.model.root)) {
				if (arrayLen(found)) break;
				if (compare(left(toString(section.title), len(partNum)), partNum) == 0) arrayAppend(found, section);
			}
		}
		if (!arrayLen(found)) {
			throw(
				type = "ICFWalk.Configuration",
				message = "Selectable part '" & toString(arguments.part.key) & "' does not resolve to a section in this instrument version.",
				errorcode = "EMAIL_PART_UNRESOLVED"
			);
		}
		return found[1];
	}

	private array function componentPartLines(required struct model, required struct part, required struct state, required struct evaluation) {
		var section = resolvePartSection(arguments.model, arguments.part);
		var lines = [toString(arguments.part.partNum) & variables.HEADING_SEPARATOR & toString(arguments.part.compTitle) & ":"];
		var notApplicable = ratingSummary(section, arguments.evaluation).notApplicable;
		if (notApplicable) arrayAppend(lines, variables.EMAIL.notApplicableBullet);
		var notes = notesTextOf(section, arguments.state, arguments.evaluation);
		if (len(notes)) arrayAppend(lines, variables.NOTES_PREFIX & notes);
		else if (!notApplicable) arrayAppend(lines, variables.EMAIL.noComponentNotes);
		return lines;
	}

	private array function part1PartLines(required struct model, required struct part, required struct state, required struct evaluation) {
		var section = resolvePartSection(arguments.model, arguments.part);
		var lines = [toString(arguments.part.partNum) & variables.HEADING_SEPARATOR & titleAfterSeparator(section) & ":"];
		var any = false;
		for (var child in childrenOf(section)) {
			var notes = notesTextOf(child, arguments.state, arguments.evaluation);
			if (!len(notes)) continue;
			arrayAppend(lines, toString(child.title) & variables.EMAIL.nestedNotesInfix & notes);
			any = true;
		}
		if (!any) arrayAppend(lines, variables.EMAIL.noPartNotes);
		return lines;
	}

	private array function notesPartLines(required struct model, required struct part, required struct state, required struct evaluation) {
		var section = resolvePartSection(arguments.model, arguments.part);
		var lines = [toString(arguments.part.partNum) & variables.HEADING_SEPARATOR & titleAfterSeparator(section) & ":"];
		var notes = notesTextOf(section, arguments.state, arguments.evaluation);
		arrayAppend(lines, len(notes) ? variables.NOTES_PREFIX & notes : variables.EMAIL.noPartNotes);
		return lines;
	}

	private array function summaryPartLines(required struct model, required struct part, required struct state, required struct evaluation) {
		var section = resolvePartSection(arguments.model, arguments.part);
		var lines = [toString(arguments.part.label) & ":"];
		var any = false;
		for (var item in labelledTextItems(section)) {
			if (!isAnswered(arguments.evaluation, item.itemKey)) continue;
			var text = textOf(arguments.state, item.itemKey);
			if (!len(text)) continue;
			arrayAppend(lines, variables.PART4_LABELS[item.itemKey] & ": " & text);
			any = true;
		}
		if (!any) arrayAppend(lines, variables.EMAIL.noSummaryNotes);
		return lines;
	}

	private array function partLines(required struct model, required struct part, required struct state, required struct evaluation) {
		var kind = toString(arguments.part.kind);
		if (compare(kind, "component") == 0) return componentPartLines(arguments.model, arguments.part, arguments.state, arguments.evaluation);
		if (compare(kind, "part1merged") == 0) return part1PartLines(arguments.model, arguments.part, arguments.state, arguments.evaluation);
		if (compare(kind, "belonging") == 0) return notesPartLines(arguments.model, arguments.part, arguments.state, arguments.evaluation);
		if (compare(kind, "summary") == 0) return summaryPartLines(arguments.model, arguments.part, arguments.state, arguments.evaluation);
		throw(type = "ICFWalk.Configuration", message = "Unsupported selectable part kind '" & kind & "'.", errorcode = "EMAIL_PART_KIND_UNSUPPORTED");
	}

	/**
	 * SUM-06. The draft the composer puts in the editable box. Parts appear in the order the item's
	 * settings declare them however the checkboxes were ticked, and only the checked ones appear.
	 * Nothing here sends anything: the result is text for a person to review, edit, copy, or hand to
	 * their own mail client.
	 */
	public struct function emailDraft(required struct model, required struct state, required struct evaluation, array includedPartKeys = []) {
		var included = {};
		for (var key in arguments.includedPartKeys) if (isSimpleValue(key)) included[toString(key)] = true;
		var chosen = [];
		for (var part in selectableParts(arguments.model)) if (structKeyExists(included, toString(part.key))) arrayAppend(chosen, part);

		var titleParts = [];
		for (var code in variables.EMAIL_TITLE_DIMENSIONS) {
			var text = dimensionText(arguments.model, arguments.state, arguments.evaluation, code);
			if (len(text)) arrayAppend(titleParts, text);
		}
		var title = arrayToList(titleParts, " ");
		var visitDate = dimensionText(arguments.model, arguments.state, arguments.evaluation, variables.EMAIL_DATE_DIMENSION);
		var observer = dimensionText(arguments.model, arguments.state, arguments.evaluation, variables.EMAIL_OBSERVER_DIMENSION);

		var body = variables.EMAIL.opening
			& (len(title) ? variables.EMAIL.inPrefix & title : "")
			& (len(visitDate) ? variables.EMAIL.onPrefix & visitDate : "")
			& "." & variables.NL;
		for (var part in chosen) {
			body &= variables.NL & arrayToList(partLines(arguments.model, part, arguments.state, arguments.evaluation), variables.NL) & variables.NL;
		}
		if (!arrayLen(chosen)) body &= variables.NL & variables.EMAIL.nothingSelected & variables.NL;
		body &= variables.NL & variables.EMAIL.closing & variables.NL & variables.NL;
		body &= len(observer) ? observer : variables.EMAIL.signaturePlaceholder;

		var labels = [];
		for (var part in chosen) arrayAppend(labels, toString(part.label));
		var subject = variables.EMAIL.subject
			& (len(title) ? variables.HEADING_SEPARATOR & title : "")
			& (arrayLen(labels) ? " (" & arrayToList(labels, ", ") & ")" : "");

		return { "subject": subject, "body": body };
	}
}
