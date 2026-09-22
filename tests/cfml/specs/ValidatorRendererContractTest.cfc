/**
 * The contract that makes "publishable" and "renderable" the same statement.
 *
 * WHAT WENT WRONG BEFORE. DefinitionValidator and RenderModelBuilder each had their own idea of
 * what a valid instrument was, and the validator's was wider. A version could satisfy every
 * semantic rule, hash to its stored checksum, agree with the definitions SQL Server held, publish
 * -- and then make the runtime throw, or, worse, render with content silently missing. Checksums
 * and drift checks cannot see that: the rows and the snapshot agree perfectly on content the
 * renderer will not build.
 *
 * SO THIS SPEC PAIRS THEM. Every case below takes the real instrument, breaks exactly one thing
 * that the renderer cannot survive, and asserts BOTH halves of the contract:
 *
 *   1. the renderer really does reject it, or really does drop content it was given (proved here,
 *      not assumed, so a case cannot quietly stop being a case), and
 *   2. DefinitionValidator refuses it, with a stable code, before publication can reach step 1.
 *
 * The second assertion is the one that was failing. Both are kept because a rule that outlives the
 * renderer behaviour it exists for is a rule nobody can explain later.
 *
 * "Silently omitted" is the harder half and is measured, not eyeballed: countRendered walks the
 * built model and counts the active sections, items and placements that actually reached it. A
 * renderer that builds without throwing but drops a subtree fails the count.
 *
 * No database: both components are pure functions of normalized definitions.
 */
component extends="icfwalktests.BaseSpec" output="false" {

	public void function beforeEach() {
		variables.validator = variables.c.definitionValidator;
		variables.builder = variables.c.renderModelBuilder;
		variables.compiler = variables.c.snapshotCompiler;
		variables.definitions = variables.c.configNormalizer.fromConfig(repoJson("config/instrument-config.json")).definitions;
	}

	// ---- the positive half: what the validator accepts, the renderer builds ----------------------

	/**
	 * The supplied instrument is accepted by the shared validator AND builds a complete render
	 * model: every active section, item and placement it declares is present in the model. Without
	 * this, every negative case below could be satisfied by a validator that refuses everything.
	 */
	public void function testTheSuppliedInstrumentIsAcceptedAndBuildsCompletely() {
		var r = variables.validator.validate(variables.definitions);
		assertTrue(r.valid, "Expected the supplied instrument to be valid: " & errorSummary(r));

		var model = variables.builder.build(snapshot());
		var rendered = countRendered(model);
		var declared = countActive(variables.definitions);
		assertEquals(declared.sections, rendered.sections, "every active section reaches the render model");
		assertEquals(declared.items, rendered.items, "every active item reaches the render model");
		assertEquals(declared.placements, rendered.placements, "every active placement reaches the render model");
	}

	/**
	 * A reduced but representative instrument -- one root, a nested section, a choice item with an
	 * active set, a display item, a placement with the supported option filter, a SHOW rule -- is
	 * also accepted and also builds completely. The full document is one shape; this proves the
	 * contract is not tuned to it.
	 */
	public void function testARepresentativeMinimalInstrumentIsAcceptedAndBuildsCompletely() {
		var d = minimal();
		var r = variables.validator.validate(d);
		assertTrue(r.valid, "Expected the minimal instrument to be valid: " & errorSummary(r));

		var model = variables.builder.build(snapshot(d));
		var rendered = countRendered(model);
		var declared = countActive(d);
		assertEquals(declared.sections, rendered.sections, "every active section reaches the render model");
		assertEquals(declared.items, rendered.items, "every active item reaches the render model");
		assertEquals(declared.placements, rendered.placements, "every active placement reaches the render model");
	}

	// ---- exactly one active root -----------------------------------------------------------------

	/** No active root: the renderer throws SNAPSHOT_NO_ROOT, so the validator must refuse first. */
	public void function testNoActiveRootSectionIsRefused() {
		var d = variables.definitions;
		rootOf(d).active = false;
		assertRendererRejects(d, "the renderer cannot build an instrument with no active root");
		assertRefused(d, "SECTION_ROOT_MISSING");
	}

	/**
	 * Two active roots: the renderer does NOT throw. It keeps whichever root it happens to see
	 * last and silently drops the other one and everything under it, which is the quietest way an
	 * instrument can lose content.
	 */
	public void function testTwoActiveRootSectionsAreRefused() {
		var d = variables.definitions;
		var second = firstChildOf(d);
		second.parentSectionKey = javaCast("null", "");
		assertRendererDropsContent(d, "a second root makes the renderer drop a subtree");
		assertRefused(d, "SECTION_ROOT_AMBIGUOUS");
	}

	// ---- no active content orphaned from that root -----------------------------------------------

	/** An active section under a deactivated parent never reaches the tree walk. */
	public void function testActiveSectionUnderAnInactiveParentIsRefused() {
		var d = variables.definitions;
		var parent = firstParentWithChild(d);
		parent.active = false;
		assertRendererDropsContent(d, "a subtree under an inactive parent is dropped");
		assertRefused(d, "SECTION_ORPHANED_FROM_ROOT");
	}

	/** An active item in a deactivated section is dropped with it. */
	public void function testActiveItemInAnInactiveSectionIsRefused() {
		var d = variables.definitions;
		var section = sectionWithItems(d);
		section.active = false;
		assertRendererDropsContent(d, "items of an inactive section are dropped");
		assertRefused(d, "ITEM_ORPHANED_FROM_ROOT");
	}

	/** A detached active subtree (its parent is not in the document) is unreachable. */
	public void function testActiveSectionDetachedFromTheRootIsRefused() {
		var d = variables.definitions;
		var s = firstChildOf(d);
		s.parentSectionKey = "no-such-section";
		assertRendererDropsContent(d, "a detached subtree never reaches the tree walk");
		assertRefused(d, "MISSING_REFERENCE");
	}

	// ---- every accepted item type is implemented by the runtime ----------------------------------

	/**
	 * MULTI_CHOICE reached the item-type allow-list but no branch of the renderer's layout switch,
	 * and nothing below the renderer stores more than one selected option per item. It is refused
	 * at both ends rather than half-supported.
	 */
	public void function testMultiChoiceIsRefusedBecauseTheRuntimeDoesNotImplementIt() {
		var d = variables.definitions;
		choiceItem(d).itemType = "MULTI_CHOICE";
		assertRendererRejects(d, "the renderer has no MULTI_CHOICE layout");
		assertRefused(d, "INVALID_ENUM");
	}

	/** SHORT_TEXT, likewise: allowed by the old list, implemented by nothing. */
	public void function testShortTextIsRefusedBecauseTheRuntimeDoesNotImplementIt() {
		var d = variables.definitions;
		var it = textItem(d);
		it.itemType = "SHORT_TEXT";
		assertRendererRejects(d, "the renderer has no SHORT_TEXT layout");
		assertRefused(d, "INVALID_ENUM");
	}

	/** And the same is true through the import document, so neither end can accept them. */
	public void function testRetiredItemTypesAreRefusedAtImportToo() {
		var cfg = repoJson("config/instrument-config.json");
		for (var it in cfg.items) {
			if (it.itemType == "SINGLE_CHOICE") { it.itemType = "MULTI_CHOICE"; break; }
		}
		var r = variables.c.configValidator.validate(cfg);
		assertFalse(r.valid, "an import document naming MULTI_CHOICE is refused");
		assertTrue(hasError(r, "INVALID_ENUM"), summary(r.errors));
	}

	// ---- option filters --------------------------------------------------------------------------

	/** An option filter the renderer does not implement is a runtime throw, so it is refused. */
	public void function testUnknownOptionFilterIsRefused() {
		var d = variables.definitions;
		var p = d.instrumentDimensions[1];
		p.settings = { "optionFilter": "notARealFilter" };
		assertRendererRejects(d, "the renderer throws on an unknown option filter");
		assertRefused(d, "UNSUPPORTED_OPTION_FILTER");
	}

	/** The filter the instrument does use is supported, and is not refused by the new rule. */
	public void function testTheSupportedOptionFilterIsAccepted() {
		var r = variables.validator.validate(variables.definitions);
		assertTrue(r.valid, errorSummary(r));
		var found = false;
		for (var p in variables.definitions.instrumentDimensions) {
			if (isStruct(p.settings) && structKeyExists(p.settings, "optionFilter") && len(p.settings.optionFilter)) found = true;
		}
		assertTrue(found, "the instrument really does use an option filter, so the rule above is exercised");
	}

	// ---- an active item may reference only an active response set --------------------------------

	/** The renderer indexes active sets only, so an active item pointing at an inactive one throws. */
	public void function testActiveItemReferencingAnInactiveResponseSetIsRefused() {
		var d = variables.definitions;
		var it = choiceItem(d);
		setOf(d, it.responseSetKey).active = false;
		assertRendererRejects(d, "the renderer throws on an item whose response set was filtered out");
		assertRefused(d, "RESPONSE_SET_INACTIVE");
	}

	/** A choice item whose set survives but has no active option renders an unanswerable question. */
	public void function testActiveChoiceItemWhoseSetHasNoActiveOptionIsRefused() {
		var d = variables.definitions;
		var it = choiceItem(d);
		var n = 0;
		for (var op in d.responseOptions) {
			if (op.setKey == it.responseSetKey) { op.active = false; n++; }
		}
		assertTrue(n > 0, "the fixture really did deactivate some options");
		var model = variables.builder.build(snapshot(d));
		assertEquals(0, arrayLen(renderedItem(model, it.itemKey).responseSet.options), "the renderer offers no options at all");
		assertRefused(d, "RESPONSE_SET_NO_ACTIVE_OPTIONS");
	}

	// ---- placements ------------------------------------------------------------------------------

	/** A placement of a deactivated dimension throws: the renderer indexes active dimensions only. */
	public void function testActivePlacementOfAnInactiveDimensionIsRefused() {
		var d = variables.definitions;
		dimensionOf(d, d.instrumentDimensions[1].dimensionCode).active = false;
		assertRendererRejects(d, "the renderer throws on a placement of a filtered-out dimension");
		assertRefused(d, "DIMENSION_INACTIVE");
	}

	/** A LIST placement with no value left active is an empty, unanswerable control. */
	public void function testActiveListPlacementWithNoActiveValuesIsRefused() {
		var d = variables.definitions;
		var code = listDimensionCode(d);
		for (var v in d.dimensionValues) if (v.dimensionCode == code) v.active = false;
		var model = variables.builder.build(snapshot(d));
		assertEquals(0, arrayLen(model.dimensions[code].values), "the renderer offers no values at all");
		assertRefused(d, "DIMENSION_NO_ACTIVE_VALUES");
	}

	// ---- active references stay closed after inactive content is filtered ------------------------

	/** An active rule whose target has been deactivated is a reference the render model cannot use. */
	public void function testActiveRuleTargetingInactiveContentIsRefused() {
		var d = variables.definitions;
		var rule = ruleTargeting(d, "SECTION");
		sectionOf(d, rule.targetKey).active = false;
		assertRefused(d, "SECTION_ORPHANED_FROM_ROOT", "RULE_TARGET_INACTIVE");
	}

	/** And so is an active rule whose source item has been deactivated. */
	public void function testActiveRuleSourcedFromInactiveContentIsRefused() {
		var d = variables.definitions;
		var rule = ruleSourcedFrom(d, "ITEM");
		itemOf(d, rule.sourceKey).active = false;
		assertRefused(d, "ITEM_ORPHANED_FROM_ROOT", "RULE_SOURCE_INACTIVE");
	}

	// ---- helpers ---------------------------------------------------------------------------------

	/** The validator must refuse `d`, reporting at least one of the codes given. */
	private void function assertRefused(required struct d, required string code, string alternative = "") {
		var r = variables.validator.validate(arguments.d);
		assertFalse(r.valid, "the shared validator must refuse this state; it reported nothing");
		var ok = hasError(r, arguments.code) || (len(arguments.alternative) && hasError(r, arguments.alternative));
		assertTrue(ok, "expected " & arguments.code & (len(arguments.alternative) ? " or " & arguments.alternative : "") & "; got " & errorSummary(r));
	}

	/** The renderer really does throw on this state (so the rule above is not guarding nothing). */
	private void function assertRendererRejects(required struct d, required string why) {
		var threw = false;
		try {
			variables.builder.build(snapshot(arguments.d));
		} catch (any e) {
			threw = true;
		}
		assertTrue(threw, arguments.why);
	}

	/** The renderer builds, but the model no longer carries everything the definitions declared. */
	private void function assertRendererDropsContent(required struct d, required string why) {
		var model = "";
		try {
			model = variables.builder.build(snapshot(arguments.d));
		} catch (any e) {
			// Throwing is a stronger failure than dropping; the contract is broken either way.
			return;
		}
		var rendered = countRendered(model);
		var declared = countActive(arguments.d);
		var dropped = (declared.sections > rendered.sections) || (declared.items > rendered.items) || (declared.placements > rendered.placements);
		assertTrue(dropped, arguments.why & " (declared " & declared.sections & "/" & declared.items & "/" & declared.placements
			& " rendered " & rendered.sections & "/" & rendered.items & "/" & rendered.placements & ")");
	}

	private struct function snapshot(struct d = variables.definitions) {
		return {
			"snapshotFormat": variables.validator.snapshotFormat(),
			"instrument": { "code": "ICFWALK", "name": "ICFWalk" },
			"version": { "versionLabel": "contract" },
			"definitions": arguments.d,
			"counts": variables.compiler.countDefinitions(arguments.d)
		};
	}

	private struct function countActive(required struct d) {
		var out = { "sections": 0, "items": 0, "placements": 0 };
		for (var s in arguments.d.sections) if (s.active) out.sections++;
		for (var i in arguments.d.items) if (i.active) out.items++;
		for (var p in arguments.d.instrumentDimensions) if (p.active) out.placements++;
		return out;
	}

	private struct function countRendered(required struct model) {
		var out = { "sections": 0, "items": 0, "placements": 0 };
		walk(arguments.model.root, out);
		return out;
	}

	private void function walk(required struct node, required struct out) {
		arguments.out.sections++;
		arguments.out.items += arrayLen(arguments.node.items);
		arguments.out.placements += arrayLen(arguments.node.placements);
		for (var child in arguments.node.children) walk(child, arguments.out);
	}

	private struct function renderedItem(required struct model, required string itemKey) {
		var found = findItem(arguments.model.root, arguments.itemKey);
		if (!isStruct(found)) fail("item '" & arguments.itemKey & "' is not in the render model at all");
		return found;
	}

	private any function findItem(required struct node, required string itemKey) {
		for (var it in arguments.node.items) if (it.itemKey == arguments.itemKey) return it;
		for (var child in arguments.node.children) {
			var hit = findItem(child, arguments.itemKey);
			if (isStruct(hit)) return hit;
		}
		return "";
	}

	// ---- fixture selection (by shape, never by name) ---------------------------------------------

	private struct function rootOf(required struct d) {
		for (var s in arguments.d.sections) if (s.active && isNull(s.parentSectionKey)) return s;
		fail("no active root section in the fixture");
	}

	private struct function firstChildOf(required struct d) {
		var root = rootOf(arguments.d);
		for (var s in arguments.d.sections) {
			if (s.active && !isNull(s.parentSectionKey) && s.parentSectionKey == root.sectionKey) return s;
		}
		fail("the root has no active child in the fixture");
	}

	/** A section that has at least one active child section, so deactivating it orphans a subtree. */
	private struct function firstParentWithChild(required struct d) {
		var root = rootOf(arguments.d);
		for (var candidate in arguments.d.sections) {
			if (!candidate.active || isNull(candidate.parentSectionKey)) continue;
			for (var s in arguments.d.sections) {
				if (s.active && !isNull(s.parentSectionKey) && s.parentSectionKey == candidate.sectionKey) return candidate;
			}
		}
		fail("no active section with an active child in the fixture");
	}

	private struct function sectionWithItems(required struct d) {
		for (var s in arguments.d.sections) {
			if (!s.active || isNull(s.parentSectionKey)) continue;
			for (var it in arguments.d.items) if (it.active && it.sectionKey == s.sectionKey) return s;
		}
		fail("no active non-root section with active items in the fixture");
	}

	private struct function choiceItem(required struct d) {
		for (var it in arguments.d.items) {
			if (it.active && it.itemType == "SINGLE_CHOICE" && !isNull(it.responseSetKey) && len(it.responseSetKey)) return it;
		}
		fail("no active choice item in the fixture");
	}

	private struct function textItem(required struct d) {
		for (var it in arguments.d.items) if (it.active && it.itemType == "LONG_TEXT") return it;
		fail("no active LONG_TEXT item in the fixture");
	}

	private struct function setOf(required struct d, required string setKey) {
		for (var rs in arguments.d.responseSets) if (rs.setKey == arguments.setKey) return rs;
		fail("response set '" & arguments.setKey & "' is not in the fixture");
	}

	private struct function sectionOf(required struct d, required string sectionKey) {
		for (var s in arguments.d.sections) if (s.sectionKey == arguments.sectionKey) return s;
		fail("section '" & arguments.sectionKey & "' is not in the fixture");
	}

	private struct function itemOf(required struct d, required string itemKey) {
		for (var it in arguments.d.items) if (it.itemKey == arguments.itemKey) return it;
		fail("item '" & arguments.itemKey & "' is not in the fixture");
	}

	private struct function dimensionOf(required struct d, required string code) {
		for (var dim in arguments.d.dimensions) if (dim.code == arguments.code) return dim;
		fail("dimension '" & arguments.code & "' is not in the fixture");
	}

	/** A placed dimension of dataType LIST that currently has active values. */
	private string function listDimensionCode(required struct d) {
		for (var p in arguments.d.instrumentDimensions) {
			if (!p.active) continue;
			var dim = dimensionOf(arguments.d, p.dimensionCode);
			if (!dim.active || dim.dataType != "LIST") continue;
			for (var v in arguments.d.dimensionValues) if (v.dimensionCode == dim.code && v.active) return dim.code;
		}
		fail("no active LIST placement with active values in the fixture");
	}

	private struct function ruleTargeting(required struct d, required string targetType) {
		for (var r in arguments.d.rules) if (r.active && r.targetType == arguments.targetType) return r;
		fail("no active rule targeting a " & arguments.targetType & " in the fixture");
	}

	private struct function ruleSourcedFrom(required struct d, required string sourceType) {
		for (var r in arguments.d.rules) if (r.active && r.sourceType == arguments.sourceType) return r;
		fail("no active rule sourced from an " & arguments.sourceType & " in the fixture");
	}

	/** A small instrument written here rather than derived, so the contract is not fixture-shaped. */
	private struct function minimal() {
		var conditions = { "logic": "AND", "conditions": [{ "sourceType": "ITEM", "sourceKey": "gate", "operator": "EQUALS", "comparisonValue": "yes" }] };
		return {
			"sections": [
				row({ "sectionKey": "root", "title": "Root", "displayOrder": 0 }),
				row({ "sectionKey": "part", "parentSectionKey": "root", "title": "Part", "displayOrder": 10 })
			],
			"items": [
				row({ "itemKey": "gate", "sectionKey": "part", "itemType": "SINGLE_CHOICE", "prompt": "Gate?", "responseSetKey": "yesno", "displayOrder": 10 }),
				row({ "itemKey": "rated", "sectionKey": "part", "itemType": "SINGLE_CHOICE", "prompt": "Rated?", "responseSetKey": "yesno", "displayOrder": 20 }),
				row({ "itemKey": "guide", "sectionKey": "part", "itemType": "DISPLAY_GUIDANCE", "prompt": "Guidance", "displayOrder": 30 }),
				row({ "itemKey": "notes", "sectionKey": "part", "itemType": "LONG_TEXT", "prompt": "Notes", "displayOrder": 40 })
			],
			"responseSets": [row({ "setKey": "yesno", "name": "Yes / No", "selectionMode": "SINGLE", "scoreEnabled": false, "allowNa": false })],
			"responseOptions": [
				row({ "setKey": "yesno", "optionKey": "yes", "storedCode": "yes", "label": "Yes", "displayOrder": 10 }),
				row({ "setKey": "yesno", "optionKey": "no", "storedCode": "no", "label": "No", "displayOrder": 20 })
			],
			"rules": [row({
				"ruleKey": "show_rated", "targetType": "ITEM", "targetKey": "rated", "effect": "SHOW",
				"sourceType": "ITEM", "sourceKey": "gate", "operator": "EQUALS", "comparisonValue": "yes",
				"conditionLogic": "AND", "conditions": conditions
			})],
			"dimensions": [
				row({ "code": "school", "label": "School", "dataType": "LIST", "valueMode": "SINGLE", "allowOther": false, "reportable": true, "sensitive": false }),
				row({ "code": "band", "label": "Band", "dataType": "LIST", "valueMode": "SINGLE", "allowOther": false, "reportable": true, "sensitive": false })
			],
			"dimensionValues": [
				row({ "dimensionCode": "school", "valueCode": "s1", "label": "School One", "displayOrder": 10, "valueGroup": "ELEM" }),
				row({ "dimensionCode": "band", "valueCode": "b1", "label": "Band One", "displayOrder": 10, "valueGroup": "ELEM" })
			],
			"instrumentDimensions": [
				row({ "dimensionCode": "school", "sectionKey": "root", "displayOrder": 10, "required": true, "visibleByDefault": true }),
				row({ "dimensionCode": "band", "sectionKey": "root", "displayOrder": 20, "required": false, "visibleByDefault": true, "settings": { "optionFilter": "schoolTypeToGradeBand" } })
			]
		};
	}

	/** Fills the fields every normalized row carries, so a fixture states only what it is about. */
	private struct function row(required struct given) {
		var base = {
			"authoringId": javaCast("null", ""), "active": true, "settings": {},
			"sourceLocation": javaCast("null", ""), "reviewStatus": javaCast("null", ""), "revisionNotes": javaCast("null", ""),
			"displayOrder": 0, "required": false, "reportable": false, "sensitive": false, "allowOther": false,
			"notesEnabled": false, "optionalSection": false, "requiredSection": false, "visibleByDefault": true,
			"scoreEnabled": false, "allowNa": false, "isNa": false, "numericScore": javaCast("null", ""),
			"instructions": javaCast("null", ""), "colorHex": javaCast("null", ""), "helpText": javaCast("null", ""),
			"placeholder": javaCast("null", ""), "linkUrl": javaCast("null", ""), "definition": javaCast("null", ""),
			"reportingKey": javaCast("null", ""), "contentFamily": javaCast("null", ""), "labelOverride": javaCast("null", ""),
			"ruleKey": javaCast("null", ""), "valueGroup": javaCast("null", ""), "gradeBand": javaCast("null", ""),
			"effectiveStart": javaCast("null", ""), "effectiveEnd": javaCast("null", ""), "valueMode": "SINGLE",
			"effectValue": javaCast("null", ""), "parentSectionKey": javaCast("null", ""),
			"responseSetKey": javaCast("null", ""), "sectionKey": javaCast("null", "")
		};
		for (var k in arguments.given) base[k] = arguments.given[k];
		return base;
	}

	private boolean function hasError(required struct r, required string code) {
		for (var e in arguments.r.errors) if (compare(e.code, arguments.code) == 0) return true;
		return false;
	}

	private string function errorSummary(required struct r) {
		return summary(arguments.r.errors);
	}

	private string function summary(required array errors) {
		var codes = [];
		for (var e in arguments.errors) arrayAppend(codes, e.code & "@" & e.path);
		return arrayToList(codes, ", ");
	}
}
