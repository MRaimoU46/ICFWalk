/**
 * Builds the render model from a compiled instrument snapshot (icfwalk-instrument-snapshot/1).
 *
 * The renderer (app/assets/js/renderer.js), the Phase 6 administration preview, and the server
 * side visibility engine all work from this model rather than from the flat snapshot, so the
 * interpretation of the configuration lives in exactly one place. Nothing here names a section,
 * item, response option, or prompt: everything is derived from the snapshot's keys, orders,
 * settings, response sets, rules, dimensions, and placements.
 *
 * Model (canonical JSON):
 *   root            section tree: children ordered by displayOrder, each with placements, items,
 *                   and children; every node carries the derived presentation facts listed below
 *   rules           active rules (conditions block only; authoring metadata is not needed)
 *   dimensions      dimension code -> definition with ordered values
 *   optionFilters   declarative option filters derived from placement settings.optionFilter
 *   placeholders    items whose reviewStatus is "Placeholder in source" (content review)
 *
 * Presentation facts derived per section:
 *   presentation    "root" | "card" (top level with placements or conditional visibility)
 *                   | "accordion" (other top-level sections) | "component" (nested section with
 *                   settings.partNumber) | "block" (other nested sections)
 *   headingVisible  block sections show their title only when they carry look-fors or a color;
 *                   a plain block keeps its heading for assistive technology only
 *   hasLookFors     the section has DISPLAY_HEADING / DISPLAY_GUIDANCE items
 *   canBeSkipped / defaultApplicable   from settings
 *   applicabilityItemKey / ratedItemKeys   the item whose value drives SHOW rules on sibling items
 *   conditional / ruleKeys   SHOW rules targeting the section
 *
 * Presentation facts derived per item:
 *   layout          "display-heading" | "display-guidance" | "question" (choice with definitions)
 *                   | "choice-row" (choice without definitions, e.g. yes/no) | "applicability"
 *                   | "notes" (LONG_TEXT in a notes-enabled section) | "text" (other LONG_TEXT)
 *                   | "email-draft"
 *   questionNumber  1-based number among a section's questions: scored questions when the
 *                   section has any, otherwise every question (matches the prototype numbering)
 *   isPlaceholder   reviewStatus "Placeholder in source"
 *   defaultStoredCode   settings.defaultStoredCode (new-walk default, e.g. applicability "no")
 */
component output="false" {

	variables.FORMAT = "icfwalk-render-model/1";

	/**
	 * The renderer reads the placeholder status and the option-filter table from DefinitionValidator
	 * rather than keeping its own copies. They are the same facts the validator refuses a version
	 * for getting wrong, and two copies of a shared fact is how the validator and the renderer
	 * drifted apart in the first place: the validator accepted option filters and item types this
	 * builder had never heard of.
	 */
	public RenderModelBuilder function init(required any definitionValidator) {
		variables.definitionValidator = arguments.definitionValidator;
		variables.PLACEHOLDER_STATUS = arguments.definitionValidator.placeholderReviewStatus();
		variables.OPTION_FILTERS = arguments.definitionValidator.optionFilters();
		return this;
	}

	public string function format() { return variables.FORMAT; }

	public struct function build(required struct snapshot) {
		var d = arguments.snapshot.definitions;
		var sets = indexResponseSets(d);
		var dimensions = indexDimensions(d);
		var rules = activeRules(d);
		var rulesByTarget = {};
		for (var r in rules) {
			var tk = r.targetType & ":" & r.targetKey;
			if (!structKeyExists(rulesByTarget, tk)) rulesByTarget[tk] = [];
			arrayAppend(rulesByTarget[tk], r);
		}
		var itemsBySection = {};
		for (var it in d.items) {
			if (!it.active) continue;
			if (!structKeyExists(itemsBySection, it.sectionKey)) itemsBySection[it.sectionKey] = [];
			arrayAppend(itemsBySection[it.sectionKey], it);
		}
		var placementsBySection = {};
		var optionFilters = [];
		for (var p in d.instrumentDimensions) {
			if (!p.active) continue;
			if (!structKeyExists(placementsBySection, p.sectionKey)) placementsBySection[p.sectionKey] = [];
			arrayAppend(placementsBySection[p.sectionKey], p);
			if (isStruct(p.settings) && structKeyExists(p.settings, "optionFilter") && isSimpleValue(p.settings.optionFilter) && len(p.settings.optionFilter)) {
				var name = p.settings.optionFilter;
				if (!structKeyExists(variables.OPTION_FILTERS, name)) {
					throw(type = "ICFWalk.Configuration", message = "Unsupported option filter '" & name & "' on dimension '" & p.dimensionCode & "'.", errorcode = "UNSUPPORTED_OPTION_FILTER");
				}
				arrayAppend(optionFilters, { "dimensionCode": p.dimensionCode, "filter": name, "sourceDimensionCode": variables.OPTION_FILTERS[name].sourceDimensionCode, "matchField": variables.OPTION_FILTERS[name].matchField });
			}
		}
		var sectionsByParent = {};
		var rootKey = "";
		for (var s in d.sections) {
			if (!s.active) continue;
			if (!structKeyExists(s, "parentSectionKey")) { rootKey = s.sectionKey; continue; }
			if (!structKeyExists(sectionsByParent, s.parentSectionKey)) sectionsByParent[s.parentSectionKey] = [];
			arrayAppend(sectionsByParent[s.parentSectionKey], s);
		}
		if (!len(rootKey)) throw(type = "ICFWalk.Configuration", message = "Snapshot has no root section.", errorcode = "SNAPSHOT_NO_ROOT");
		var rootDef = "";
		for (var s in d.sections) if (s.sectionKey == rootKey) rootDef = s;
		var ctx = { "sets": sets, "dimensions": dimensions, "rulesByTarget": rulesByTarget, "itemsBySection": itemsBySection, "placementsBySection": placementsBySection, "sectionsByParent": sectionsByParent };
		var root = buildSection(rootDef, 0, ctx);

		var placeholders = [];
		for (var it in d.items) {
			if (it.active && structKeyExists(it, "reviewStatus") && it.reviewStatus == variables.PLACEHOLDER_STATUS) {
				arrayAppend(placeholders, { "itemKey": it.itemKey, "sectionKey": it.sectionKey, "prompt": it.prompt, "sourceLocation": !structKeyExists(it, "sourceLocation") ? javaCast("null", "") : it.sourceLocation, "reviewStatus": it.reviewStatus });
			}
		}
		var ruleDocs = [];
		for (var r in rules) {
			arrayAppend(ruleDocs, { "ruleKey": r.ruleKey, "effect": r.effect, "targetType": r.targetType, "targetKey": r.targetKey, "conditions": r.conditions });
		}
		return {
			"format": variables.FORMAT,
			"snapshotFormat": arguments.snapshot.snapshotFormat,
			"instrument": arguments.snapshot.instrument,
			"version": arguments.snapshot.version,
			"behavior": structKeyExists(arguments.snapshot, "behavior") ? arguments.snapshot.behavior : {},
			"root": root,
			"rules": ruleDocs,
			"dimensions": dimensions,
			"optionFilters": optionFilters,
			"placeholders": placeholders,
			"counts": structKeyExists(arguments.snapshot, "counts") ? arguments.snapshot.counts : {}
		};
	}

	// ---- sections --------------------------------------------------------------------------------

	private struct function buildSection(required struct def, required numeric depth, required struct ctx) {
		var s = arguments.def;
		var settings = isStruct(s.settings) ? s.settings : {};
		var node = {
			"sectionKey": s.sectionKey,
			"title": s.title,
			"instructions": nullable(s, "instructions"),
			"colorHex": nullable(s, "colorHex"),
			"notesEnabled": s.notesEnabled ? true : false,
			"optionalSection": s.optionalSection ? true : false,
			"requiredSection": s.requiredSection ? true : false,
			"displayOrder": s.displayOrder,
			"parentSectionKey": nullable(s, "parentSectionKey"),
			"depth": arguments.depth,
			"settings": settings,
			"partNumber": structKeyExists(settings, "partNumber") && isSimpleValue(settings.partNumber) ? toString(settings.partNumber) : javaCast("null", ""),
			"canBeSkipped": structKeyExists(settings, "canBeSkipped") && isBoolean(settings.canBeSkipped) && settings.canBeSkipped,
			"defaultApplicable": structKeyExists(settings, "defaultApplicable") && isBoolean(settings.defaultApplicable) ? (settings.defaultApplicable ? true : false) : javaCast("null", ""),
			"applicabilityItemKey": javaCast("null", ""),
			"ratedItemKeys": [],
			"conditional": false,
			"ruleKeys": []
		};
		var sectionRules = rulesFor(arguments.ctx.rulesByTarget, "SECTION", s.sectionKey);
		node.conditional = arrayLen(sectionRules) > 0;
		for (var r in sectionRules) arrayAppend(node.ruleKeys, r.ruleKey);

		// Placements (dimension inputs) in authored per-section order.
		var placements = [];
		if (structKeyExists(arguments.ctx.placementsBySection, s.sectionKey)) {
			for (var p in arguments.ctx.placementsBySection[s.sectionKey]) arrayAppend(placements, buildPlacement(p, arguments.ctx));
			sortByOrder(placements, "dimensionCode");
		}
		node["placements"] = placements;

		// Items in display order with derived layouts.
		var items = [];
		var itemKeys = {};
		if (structKeyExists(arguments.ctx.itemsBySection, s.sectionKey)) {
			for (var it in arguments.ctx.itemsBySection[s.sectionKey]) itemKeys[it.itemKey] = true;
			// The applicability item is the ITEM-typed rule source for SHOW rules on sibling items.
			var applicability = "";
			var rated = [];
			for (var it in arguments.ctx.itemsBySection[s.sectionKey]) {
				for (var r in rulesFor(arguments.ctx.rulesByTarget, "ITEM", it.itemKey)) {
					for (var cnd in r.conditions.conditions) {
						if (cnd.sourceType == "ITEM" && structKeyExists(itemKeys, cnd.sourceKey) && cnd.sourceKey != it.itemKey) {
							if (!len(applicability)) applicability = cnd.sourceKey;
							if (applicability == cnd.sourceKey && !arrayContains(rated, it.itemKey)) arrayAppend(rated, it.itemKey);
						}
					}
				}
			}
			if (len(applicability)) node.applicabilityItemKey = applicability;
			for (var it in arguments.ctx.itemsBySection[s.sectionKey]) {
				arrayAppend(items, buildItem(it, node, applicability, arguments.ctx));
			}
			sortByOrder(items, "itemKey");
			for (var k in rated) arrayAppend(node.ratedItemKeys, k);
			sortRatedByOrder(node, items);
			assignQuestionNumbers(items);
		}
		node["items"] = items;
		node["hasLookFors"] = false;
		for (var it in items) if (it.layout == "display-heading" || it.layout == "display-guidance") node.hasLookFors = true;

		// Children.
		var children = [];
		if (structKeyExists(arguments.ctx.sectionsByParent, s.sectionKey)) {
			var defs = arguments.ctx.sectionsByParent[s.sectionKey];
			arraySort(defs, function(a, b) {
				if (a.displayOrder != b.displayOrder) return a.displayOrder < b.displayOrder ? -1 : 1;
				return compare(a.sectionKey, b.sectionKey);
			});
			for (var child in defs) arrayAppend(children, buildSection(child, arguments.depth + 1, arguments.ctx));
		}
		node["children"] = children;

		// Presentation.
		if (arguments.depth == 0) node["presentation"] = "root";
		else if (arguments.depth == 1) node["presentation"] = (arrayLen(placements) || node.conditional) ? "card" : "accordion";
		else node["presentation"] = !structKeyExists(node, "partNumber") ? "block" : "component";
		node["headingVisible"] = node.presentation != "block" || node.hasLookFors || structKeyExists(node, "colorHex");
		return node;
	}

	private struct function buildPlacement(required struct p, required struct ctx) {
		if (!structKeyExists(arguments.ctx.dimensions, arguments.p.dimensionCode)) {
			throw(type = "ICFWalk.Configuration", message = "Placement references unknown dimension '" & arguments.p.dimensionCode & "'.", errorcode = "SNAPSHOT_UNKNOWN_DIMENSION");
		}
		var dim = arguments.ctx.dimensions[arguments.p.dimensionCode];
		var dimRules = rulesFor(arguments.ctx.rulesByTarget, "DIMENSION", arguments.p.dimensionCode);
		var ruleKeys = [];
		for (var r in dimRules) arrayAppend(ruleKeys, r.ruleKey);
		if (structKeyExists(arguments.p, "ruleKey") && len(arguments.p.ruleKey) && !arrayContains(ruleKeys, arguments.p.ruleKey)) arrayAppend(ruleKeys, arguments.p.ruleKey);
		var settings = isStruct(arguments.p.settings) ? arguments.p.settings : {};
		return {
			"dimensionCode": arguments.p.dimensionCode,
			"label": (structKeyExists(arguments.p, "labelOverride") && len(arguments.p.labelOverride)) ? arguments.p.labelOverride : dim.label,
			"placeholder": nullable(arguments.p, "placeholder"),
			"required": arguments.p.required ? true : false,
			"visibleByDefault": arguments.p.visibleByDefault ? true : false,
			"displayOrder": arguments.p.displayOrder,
			"conditional": arrayLen(ruleKeys) > 0 || !arguments.p.visibleByDefault,
			"ruleKeys": ruleKeys,
			"optionFilter": structKeyExists(settings, "optionFilter") && isSimpleValue(settings.optionFilter) ? settings.optionFilter : javaCast("null", ""),
			"settings": settings,
			"dataType": dim.dataType,
			"valueMode": dim.valueMode,
			"allowOther": dim.allowOther ? true : false
		};
	}

	private struct function buildItem(required struct it, required struct section, required string applicabilityKey, required struct ctx) {
		var item = arguments.it;
		var settings = isStruct(item.settings) ? item.settings : {};
		var set = {};
		var hasSet = false;
		if (structKeyExists(item, "responseSetKey") && len(item.responseSetKey)) {
			if (!structKeyExists(arguments.ctx.sets, item.responseSetKey)) {
				throw(type = "ICFWalk.Configuration", message = "Item '" & item.itemKey & "' references unknown response set '" & item.responseSetKey & "'.", errorcode = "SNAPSHOT_UNKNOWN_RESPONSE_SET");
			}
			set = arguments.ctx.sets[item.responseSetKey];
			hasSet = true;
		}
		var itemRules = rulesFor(arguments.ctx.rulesByTarget, "ITEM", item.itemKey);
		var ruleKeys = [];
		for (var r in itemRules) arrayAppend(ruleKeys, r.ruleKey);
		var layout = "";
		switch (item.itemType) {
			case "DISPLAY_HEADING": layout = "display-heading"; break;
			case "DISPLAY_GUIDANCE": layout = "display-guidance"; break;
			case "LONG_TEXT": layout = arguments.section.notesEnabled ? "notes" : "text"; break;
			case "EMAIL_DRAFT_JSON": layout = "email-draft"; break;
			case "SINGLE_CHOICE":
				if (!hasSet) throw(type = "ICFWalk.Configuration", message = "Choice item '" & item.itemKey & "' has no response set.", errorcode = "SNAPSHOT_ITEM_NO_RESPONSE_SET");
				if (item.itemKey == arguments.applicabilityKey) layout = "applicability";
				else layout = set.hasDefinitions ? "question" : "choice-row";
				break;
			default:
				throw(type = "ICFWalk.Configuration", message = "Unsupported item type '" & item.itemType & "' on item '" & item.itemKey & "'.", errorcode = "SNAPSHOT_UNSUPPORTED_ITEM_TYPE");
		}
		return {
			"itemKey": item.itemKey,
			"itemType": item.itemType,
			"prompt": item.prompt,
			"helpText": nullable(item, "helpText"),
			"linkUrl": nullable(item, "linkUrl"),
			"placeholder": nullable(item, "placeholder"),
			"required": item.required ? true : false,
			"reportable": item.reportable ? true : false,
			"displayOrder": item.displayOrder,
			"reviewStatus": nullable(item, "reviewStatus"),
			"isPlaceholder": structKeyExists(item, "reviewStatus") && item.reviewStatus == variables.PLACEHOLDER_STATUS,
			"contentFamily": nullable(item, "contentFamily"),
			"settings": settings,
			"responseSet": hasSet ? set : javaCast("null", ""),
			"layout": layout,
			"questionNumber": javaCast("null", ""),
			"conditional": arrayLen(ruleKeys) > 0,
			"ruleKeys": ruleKeys,
			"defaultStoredCode": structKeyExists(settings, "defaultStoredCode") && isSimpleValue(settings.defaultStoredCode) ? toString(settings.defaultStoredCode) : javaCast("null", "")
		};
	}

	private void function assignQuestionNumbers(required array items) {
		var anyScored = false;
		for (var it in arguments.items) {
			if (it.layout == "question" && hasResponseSet(it) && it.responseSet.scoreEnabled) anyScored = true;
		}
		var n = 0;
		for (var it in arguments.items) {
			if (it.layout != "question") continue;
			if (anyScored && !it.responseSet.scoreEnabled) continue;
			n++;
			it.questionNumber = n;
		}
	}

	private boolean function hasResponseSet(required struct it) {
		return structKeyExists(arguments.it, "responseSet") && isStruct(arguments.it.responseSet);
	}

	private void function sortRatedByOrder(required struct node, required array items) {
		var ordered = [];
		for (var it in arguments.items) if (arrayContains(arguments.node.ratedItemKeys, it.itemKey)) arrayAppend(ordered, it.itemKey);
		arguments.node.ratedItemKeys = ordered;
	}

	// ---- indexes ----------------------------------------------------------------------------------

	private struct function indexResponseSets(required struct d) {
		var optionsBySet = {};
		for (var o in arguments.d.responseOptions) {
			if (!o.active) continue;
			if (!structKeyExists(optionsBySet, o.setKey)) optionsBySet[o.setKey] = [];
			arrayAppend(optionsBySet[o.setKey], {
				"optionKey": o.optionKey, "storedCode": o.storedCode, "label": o.label, "displayOrder": o.displayOrder,
				"numericScore": nullable(o, "numericScore"), "isNa": o.isNa ? true : false, "definition": nullable(o, "definition")
			});
		}
		var out = {};
		for (var rs in arguments.d.responseSets) {
			if (!rs.active) continue;
			var options = structKeyExists(optionsBySet, rs.setKey) ? optionsBySet[rs.setKey] : [];
			sortByOrder(options, "optionKey");
			var hasDefinitions = false;
			for (var o in options) if (structKeyExists(o, "definition") && len(o.definition)) hasDefinitions = true;
			out[rs.setKey] = {
				"setKey": rs.setKey, "name": rs.name, "selectionMode": rs.selectionMode,
				"scoreEnabled": rs.scoreEnabled ? true : false, "allowNa": rs.allowNa ? true : false,
				"hasDefinitions": hasDefinitions, "options": options
			};
		}
		return out;
	}

	private struct function indexDimensions(required struct d) {
		var valuesByDim = {};
		for (var v in arguments.d.dimensionValues) {
			if (!v.active) continue;
			if (!structKeyExists(valuesByDim, v.dimensionCode)) valuesByDim[v.dimensionCode] = [];
			arrayAppend(valuesByDim[v.dimensionCode], {
				"valueCode": v.valueCode, "label": v.label, "displayOrder": v.displayOrder,
				"valueGroup": nullable(v, "valueGroup"), "gradeBand": nullable(v, "gradeBand")
			});
		}
		var out = {};
		for (var dim in arguments.d.dimensions) {
			if (!dim.active) continue;
			var values = structKeyExists(valuesByDim, dim.code) ? valuesByDim[dim.code] : [];
			sortByOrder(values, "valueCode");
			out[dim.code] = {
				"code": dim.code, "label": dim.label, "dataType": dim.dataType, "valueMode": dim.valueMode,
				"allowOther": dim.allowOther ? true : false, "reportable": dim.reportable ? true : false,
				"sensitive": dim.sensitive ? true : false, "settings": isStruct(dim.settings) ? dim.settings : {}, "values": values
			};
		}
		return out;
	}

	private array function activeRules(required struct d) {
		var out = [];
		for (var r in arguments.d.rules) {
			if (!r.active) continue;
			if (r.effect != "SHOW") throw(type = "ICFWalk.Configuration", message = "Unsupported rule effect '" & r.effect & "' on rule '" & r.ruleKey & "'.", errorcode = "SNAPSHOT_UNSUPPORTED_RULE_EFFECT");
			arrayAppend(out, r);
		}
		return out;
	}

	private array function rulesFor(required struct rulesByTarget, required string targetType, required string key) {
		var tk = arguments.targetType & ":" & arguments.key;
		return structKeyExists(arguments.rulesByTarget, tk) ? arguments.rulesByTarget[tk] : [];
	}

	private void function sortByOrder(required array arr, required string tieKey) {
		var tie = arguments.tieKey;
		arraySort(arguments.arr, function(a, b) {
			if (a.displayOrder != b.displayOrder) return a.displayOrder < b.displayOrder ? -1 : 1;
			return compare(a[tie], b[tie]);
		});
	}

	private any function nullable(required struct row, required string key) {
		if (!structKeyExists(arguments.row, arguments.key)) return javaCast("null", "");
		return arguments.row[arguments.key];
	}
}
