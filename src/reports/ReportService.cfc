/**
 * Aggregate reporting (Phase 7): filterable, organizationally scoped aggregates of walk responses.
 *
 * WHO. Every entry point requires report.view (docs/ENDPOINTS.md; the route policy checks it
 * first, and this service checks it again so a direct call cannot skip it). The population is
 * always drawn from the org units the caller's report.view assignments cover right now -- effective
 * dates, active units and include_descendants all resolved by AuthorizationService -- intersected
 * with any unit the request names. A named unit outside that scope is refused as not found and
 * audited (AuthorizationService.requirePermission), so a report cannot be used to learn that a
 * unit, or its walks, exist. Instrument administrators hold no report.view and are refused.
 *
 * WHAT. Counts and scores keyed by identifiers, never an individual walk:
 *   - population: walks by status, and walks per contributing org unit;
 *   - dimensions: for each reportable, non-sensitive controlled-list dimension, walks per value,
 *     with ANSWERED / UNANSWERED / HIDDEN kept distinct. A value the instrument currently hides
 *     (Period outside grades 6-12, retained under RETAIN_HIDDEN) counts as HIDDEN, never as its
 *     value: visibility is decided by the instrument's own VisibilityEngine, not re-implemented;
 *   - items: for each reportable single-choice item, ANSWERED / UNANSWERED / HIDDEN /
 *     NOT_APPLICABLE counts, the option distribution of ANSWERED responses, and -- for scored
 *     response sets -- the item mean SUM(score) / COUNT(answered scored responses);
 *   - sections: the pooled mean of every scored response under the section, so a component whose
 *     walks answered different numbers of items is weighted by responses, never by walk averages.
 * Unanswered, hidden and not-applicable responses never enter a numerator or a denominator, and
 * nothing is ever coerced to zero (docs/DATA_CONTRACT.md, "Aggregate calculations").
 *
 * WHAT NEVER. No walk id, owner, observer, teacher field, classroom label, note, email draft, free
 * text or "Other" text: ReportRepository does not select those columns at all, and free-text
 * dimensions and non-choice items are not reportable here whatever their authoring flags say.
 * Report-only users therefore have nothing to drill into.
 *
 * ONE VERSION PER REPORT. Every walk is pinned to one immutable instrument version, and a report
 * aggregates walks of exactly one version, defaulting to the current one. Two versions may score
 * or word an item differently, so pooling them would average unlike things.
 *
 * COHERENCE. See ReportRepository: the population's row versions are captured before any child row
 * is read and verified after every aggregate is read. A report that saw any walk move is discarded
 * and recomputed, at most MAX_ATTEMPTS times; after that the caller receives 409
 * REPORT_POPULATION_CHANGED rather than a report that describes no committed state. No lock is
 * held that a writer waits on.
 *
 * PRIVACY SUPPRESSION. ICFWALK_REPORT_SUPPRESSION_THRESHOLD is an undecided policy
 * (docs/OPEN_DECISIONS.md) and defaults to 0, which applies none. When a deployment sets it to N:
 * a population of fewer than N walks is withheld entirely, and each org-unit and dimension-value
 * group of fewer than N walks is withheld individually. See docs/DATA_CONTRACT.md for what this
 * does not attempt.
 */
component output="false" {

	variables.FORMAT = "icfwalk-aggregate-report/1";
	variables.MAX_ATTEMPTS = 3;
	variables.MAX_VISIBILITY_TUPLES = 512;
	variables.PARAM_MAX_LENGTH = 100;
	variables.REPORT_PARAMS = ["versionId", "orgUnitId", "from", "to", "section", "item", "optionItem", "option", "includeDrafts"];
	variables.OPTIONS_PARAMS = ["versionId"];
	variables.DIMENSION_PREFIX = "dim_";
	variables.STATES = ["ANSWERED", "UNANSWERED", "HIDDEN", "NOT_APPLICABLE"];

	public ReportService function init(
		required struct config, required any db, required any errors, required any logger, required any auditRepository,
		required any canonicalJson, required any authorizationService, required any snapshotService, required any visibilityEngine,
		required any walkRepository, required any orgUnitRepository, required any reportRepository
	) {
		variables.config = arguments.config;
		variables.db = arguments.db;
		variables.errors = arguments.errors;
		variables.logger = arguments.logger;
		variables.audit = arguments.auditRepository;
		variables.json = arguments.canonicalJson;
		variables.authz = arguments.authorizationService;
		variables.snapshots = arguments.snapshotService;
		variables.engine = arguments.visibilityEngine;
		variables.walks = arguments.walkRepository;
		variables.orgUnits = arguments.orgUnitRepository;
		variables.reports = arguments.reportRepository;
		variables.catalogCache = {};
		variables.BigDecimal = createObject("java", "java.math.BigDecimal");
		variables.HALF_UP = createObject("java", "java.math.RoundingMode").HALF_UP;
		return this;
	}

	public numeric function suppressionThreshold() {
		var t = variables.config.reportSuppressionThreshold;
		return (isNumeric(t) && t > 0) ? int(t) : 0;
	}

	// ---- options --------------------------------------------------------------------------------

	/**
	 * What the caller may filter by: the reportable versions, the org units the caller's report
	 * scope covers, and -- for the selected version -- the reportable dimensions with their values,
	 * the sections and the reportable items with their options. Instrument content and scope only;
	 * no walk data.
	 */
	public struct function options(required struct principal, required struct query) {
		variables.authz.requirePermission(arguments.principal, "report.view");
		var params = readParams(arguments.query, variables.OPTIONS_PARAMS, false);
		var version = resolveVersion(structKeyExists(params.named, "versionId") ? params.named.versionId : "");
		var catalog = catalogFor(version.versionId);
		var tree = variables.orgUnits.loadActiveTree();
		var units = [];
		for (var id in variables.authz.visibleOrgUnitIds(arguments.principal, "report.view")) {
			if (!structKeyExists(tree, id)) continue;
			var u = tree[id];
			arrayAppend(units, { "orgUnitId": u.id, "code": u.code, "name": u.name, "type": u.type, "parentOrgUnitId": len(u.parentId) ? u.parentId : javaCast("null", "") });
		}
		arraySort(units, function(a, b) {
			var byType = compare(typeRank(a.type), typeRank(b.type));
			return byType != 0 ? byType : compareNoCase(a.name, b.name);
		});
		var dims = [];
		for (var d in catalog.dimensions) {
			var values = [];
			for (var v in d.values) arrayAppend(values, { "code": v.code, "label": v.label });
			arrayAppend(dims, { "code": d.code, "label": d.label, "values": values });
		}
		var sections = [];
		for (var s in catalog.sections) arrayAppend(sections, { "sectionKey": s.sectionKey, "title": s.title, "parentSectionKey": len(s.parentSectionKey) ? s.parentSectionKey : javaCast("null", ""), "depth": s.depth });
		var items = [];
		for (var it in catalog.items) arrayAppend(items, itemHeader(it));
		return {
			"format": variables.FORMAT,
			"version": version,
			"versions": reportableVersions(),
			"orgUnits": units,
			"dimensions": dims,
			"sections": sections,
			"items": items,
			"statuses": { "default": ["COMPLETED"], "withDrafts": ["COMPLETED", "DRAFT"] },
			"suppression": { "threshold": suppressionThreshold() }
		};
	}

	// ---- the report -------------------------------------------------------------------------------

	public struct function aggregate(required struct principal, required struct query) {
		var started = getTickCount();
		var f = parseFilters(arguments.principal, arguments.query);
		var raw = compute(f);
		var report = assemble(f, raw);
		variables.logger.info("report.generated", {
			"versionId": f.version.versionId, "walks": report.population.suppressed ? -1 : report.population.walks,
			"items": arrayLen(report.items), "attempts": raw.attempts, "filters": filterCount(f), "ms": getTickCount() - started
		});
		return report;
	}

	/**
	 * The same report as a CSV download (RFC 4180, UTF-8 with a byte order mark so spreadsheet
	 * applications read the en dashes in the instrument's own wording, CRLF line ends). Every text
	 * cell that a spreadsheet would evaluate as a formula is neutralized. The export is audited with
	 * identifiers and counts only.
	 */
	public struct function exportCsv(required struct principal, required struct query) {
		var report = aggregate(arguments.principal, arguments.query);
		var lines = [];
		arrayAppend(lines, csvRow(["record_type", "group", "key", "label", "count", "answered", "unanswered", "hidden", "not_applicable", "unrecorded", "scored_responses", "score_sum", "mean", "suppressed"]));
		var meta = [
			["format", variables.FORMAT], ["version_label", report.version.versionLabel], ["version_status", report.version.status],
			["generated_at", report.generatedAt], ["statuses", arrayToList(report.filters.statuses, " ")],
			["suppression_threshold", toString(report.suppression.threshold)]
		];
		for (var key in ["orgUnitId", "from", "to", "section", "item", "optionItem", "option"]) {
			if (!isNull(report.filters[key])) arrayAppend(meta, ["filter_" & key, report.filters[key]]);
		}
		var dimensionCodes = structKeyArray(report.filters.dimensions);
		arraySort(dimensionCodes, "textnocase");
		for (var code in dimensionCodes) arrayAppend(meta, ["filter_dim_" & code, report.filters.dimensions[code]]);
		for (var m in meta) arrayAppend(lines, csvRow(["META", "", m[1], m[2], "", "", "", "", "", "", "", "", "", ""]));
		var pop = report.population;
		arrayAppend(lines, csvRow(["POPULATION", "", "walks", "", pop.suppressed ? "" : num(pop.walks), "", "", "", "", "", "", "", "", flag(pop.suppressed)]));
		for (var status in ["COMPLETED", "DRAFT"]) {
			if (!pop.suppressed && structKeyExists(pop.byStatus, status)) arrayAppend(lines, csvRow(["POPULATION", "status", status, "", num(pop.byStatus[status]), "", "", "", "", "", "", "", "", "0"]));
		}
		for (var u in report.orgUnits) arrayAppend(lines, csvRow(["ORG_UNIT", u.type, u.code, u.name, u.suppressed ? "" : num(u.walks), "", "", "", "", "", "", "", "", flag(u.suppressed)]));
		for (var d in report.dimensions) {
			arrayAppend(lines, csvRow(["DIMENSION", d.code, "", d.label, "", num(d.states.ANSWERED), num(d.states.UNANSWERED), num(d.states.HIDDEN), "", "", "", "", "", "0"]));
			for (var v in d.values) arrayAppend(lines, csvRow(["DIMENSION_VALUE", d.code, v.code, v.label, v.suppressed ? "" : num(v.walks), "", "", "", "", "", "", "", "", flag(v.suppressed)]));
		}
		for (var s in report.sections) {
			var sectionScored = scoredCells(s);
			arrayAppend(lines, csvRow(["SECTION", s.sectionKey, "", s.title, "", "", "", "", "", "", sectionScored[1], sectionScored[2], sectionScored[3], "0"]));
		}
		for (var it in report.items) {
			var itemScored = scoredCells(it);
			arrayAppend(lines, csvRow(["ITEM", it.sectionKey, it.itemKey, it.prompt, "", num(it.states.ANSWERED), num(it.states.UNANSWERED), num(it.states.HIDDEN), num(it.states.NOT_APPLICABLE), num(it.states.UNRECORDED), itemScored[1], itemScored[2], itemScored[3], "0"]));
			for (var o in it.options) arrayAppend(lines, csvRow(["OPTION", it.itemKey, o.code, o.label, num(o.count), "", "", "", "", "", "", "", "", "0"]));
		}
		var text = chr(65279) & arrayToList(lines, chr(13) & chr(10)) & chr(13) & chr(10);
		var bytes = arrayLen(charsetDecode(text, "utf-8"));
		var fileName = "ICFWalk_report_" & safeName(report.version.versionLabel) & "_" & dateFormat(dateConvert("local2utc", now()), "yyyymmdd") & ".csv";
		var details = {
			"versionId": report.version.versionId, "walks": pop.suppressed ? -1 : pop.walks, "suppressed": pop.suppressed ? true : false,
			"rows": arrayLen(lines) - 1, "bytes": bytes, "filters": report.filterCount, "attempts": report.attempts
		};
		if (!isNull(report.filters.orgUnitId)) details["orgUnitId"] = report.filters.orgUnitId;
		variables.audit.record("REPORT", "", "REPORT_EXPORTED", arguments.principal.userId, details);
		variables.logger.info("report.exported", details);
		return { "text": text, "fileName": fileName, "bytes": bytes, "rows": arrayLen(lines) - 1 };
	}

	// ---- filters ----------------------------------------------------------------------------------

	/**
	 * Normalizes and validates the request against the caller's scope and the selected version.
	 * Unknown parameters are refused rather than ignored, so a misspelt filter can never silently
	 * widen a report to a population the caller did not ask for.
	 */
	public struct function parseFilters(required struct principal, required struct query) {
		variables.authz.requirePermission(arguments.principal, "report.view");
		var params = readParams(arguments.query, variables.REPORT_PARAMS, true);
		var named = params.named;
		var version = resolveVersion(structKeyExists(named, "versionId") ? named.versionId : "");
		var catalog = catalogFor(version.versionId);
		var f = {
			"version": version, "catalog": catalog, "orgUnitId": "", "unitIds": [], "from": "", "to": "",
			"observedFrom": "", "observedBefore": "", "dimensions": {}, "dimensionFilters": [],
			"section": "", "item": "", "optionItem": "", "option": "", "optionFilter": {},
			"includeDrafts": false, "statuses": ["COMPLETED"]
		};

		// Scope: the caller's covered units, narrowed (never widened) by a named unit.
		var covered = variables.authz.visibleOrgUnitIds(arguments.principal, "report.view");
		if (structKeyExists(named, "orgUnitId")) {
			if (!variables.db.isGuid(named.orgUnitId)) filterRefused("INVALID_ORG_UNIT", "orgUnitId", "orgUnitId is not a valid identifier.");
			variables.authz.requirePermission(arguments.principal, "report.view", named.orgUnitId, "ORG_UNIT", named.orgUnitId);
			f.orgUnitId = uCase(trim(named.orgUnitId));
			var tree = variables.orgUnits.loadActiveTree();
			var coveredSet = {};
			for (var id in covered) coveredSet[uCase(id)] = true;
			for (var id in variables.orgUnits.descendantIds(f.orgUnitId, tree)) {
				if (structKeyExists(coveredSet, uCase(id))) arrayAppend(f.unitIds, uCase(id));
			}
		} else {
			for (var id in covered) arrayAppend(f.unitIds, uCase(id));
		}

		// Observation window (inclusive calendar dates).
		if (structKeyExists(named, "from")) { f.observedFrom = parseDate(named.from, "from"); f.from = named.from; }
		if (structKeyExists(named, "to")) { f.observedBefore = dateAdd("d", 1, parseDate(named.to, "to")); f.to = named.to; }
		if (isDate(f.observedFrom) && isDate(f.observedBefore) && dateCompare(f.observedFrom, f.observedBefore) >= 0) {
			variables.errors.validation("The report's start date must not be after its end date.", "REPORT_DATE_RANGE_INVALID", { "issues": [{ "parameter": "from", "code": "REPORT_DATE_RANGE_INVALID" }] });
		}

		// Controlled-list dimensions.
		for (var raw in structKeyArray(params.dimensions)) {
			var d = findDimension(catalog, raw);
			if (structIsEmpty(d)) filterRefused("REPORT_FILTER_UNKNOWN", variables.DIMENSION_PREFIX & raw, "Unknown or non-reportable dimension.");
			var code = params.dimensions[raw];
			var value = findValue(d, code);
			if (structIsEmpty(value)) filterRefused("REPORT_FILTER_VALUE_INVALID", variables.DIMENSION_PREFIX & raw, "The value is not one of this version's values for the dimension.");
			f.dimensions[d.code] = value.code;
			arrayAppend(f.dimensionFilters, { "dimension": d, "value": value });
		}

		// Section and item restrict which items are reported; they do not change the population.
		if (structKeyExists(named, "section")) {
			if (!structKeyExists(catalog.sectionIndex, named.section)) filterRefused("REPORT_FILTER_VALUE_INVALID", "section", "Unknown section.");
			f.section = named.section;
		}
		if (structKeyExists(named, "item")) {
			if (!structKeyExists(catalog.itemIndex, named.item)) filterRefused("REPORT_FILTER_VALUE_INVALID", "item", "Unknown or non-reportable item.");
			if (len(f.section) && !arrayContains(catalog.sectionIndex[f.section].subtreeItemKeys, named.item)) {
				filterRefused("REPORT_FILTER_VALUE_INVALID", "item", "The item is not in the selected section.");
			}
			f.item = named.item;
		}

		// Response option: restricts the population to walks that answered one item with one option.
		var hasOptionItem = structKeyExists(named, "optionItem");
		var hasOption = structKeyExists(named, "option");
		if (hasOptionItem != hasOption) filterRefused("REPORT_FILTER_INCOMPLETE", hasOptionItem ? "option" : "optionItem", "optionItem and option are used together.");
		if (hasOptionItem) {
			if (!structKeyExists(catalog.itemIndex, named.optionItem)) filterRefused("REPORT_FILTER_VALUE_INVALID", "optionItem", "Unknown or non-reportable item.");
			var target = catalog.itemIndex[named.optionItem];
			var opt = {};
			for (var o in target.options) if (compare(o.code, named.option) == 0) opt = o;
			if (structIsEmpty(opt)) filterRefused("REPORT_FILTER_VALUE_INVALID", "option", "The option is not one of the item's options.");
			f.optionItem = target.itemKey;
			f.option = opt.code;
			f.optionFilter = { "itemId": target.itemId, "optionId": opt.optionId };
		}

		if (structKeyExists(named, "includeDrafts")) {
			if (compare(named.includeDrafts, "true") == 0) f.includeDrafts = true;
			else if (compare(named.includeDrafts, "false") != 0) filterRefused("REPORT_FILTER_VALUE_INVALID", "includeDrafts", "includeDrafts is true or false.");
		}
		f.statuses = f.includeDrafts ? ["COMPLETED", "DRAFT"] : ["COMPLETED"];
		return f;
	}

	// ---- computation ------------------------------------------------------------------------------

	private struct function compute(required struct f) {
		var f = arguments.f;
		var reports = variables.reports;
		var catalog = f.catalog;
		var itemIds = [];
		for (var it in reportedItems(f)) arrayAppend(itemIds, it.itemId);
		for (var attempt = 1; attempt <= variables.MAX_ATTEMPTS; attempt++) {
			var outcome = variables.db.transact(function() {
				reports.beginPopulation();
				var result = { "units": [], "dimensions": {}, "items": [], "moved": 0 };
				for (var d in catalog.dimensions) result.dimensions[d.code] = [];
				if (arrayLen(f.unitIds)) {
					reports.loadScope(f.unitIds);
					// S1: walk rows only, row versions captured.
					reports.selectCandidates(f.version.versionId, f.statuses, f.observedFrom, f.observedBefore);
					// S2: population filters and every aggregate read child rows.
					for (var df in f.dimensionFilters) reports.restrictToDimensionValue(df.dimension.dimensionId, df.value.valueId, df.dimension.visibility);
					if (!structIsEmpty(f.optionFilter)) reports.restrictToOption(f.optionFilter.itemId, f.optionFilter.optionId);
					result.units = reports.unitStatusCounts();
					for (var d in catalog.dimensions) result.dimensions[d.code] = reports.dimensionCounts(d.dimensionId, d.visibility);
					result.items = reports.itemCounts(itemIds);
					// S3: every walk still at the row version S1 captured, or the report is discarded.
					result.moved = reports.verifyPopulation();
				}
				reports.endPopulation();
				return result;
			});
			if (outcome.moved == 0) {
				outcome["attempts"] = attempt;
				return outcome;
			}
			variables.logger.warn("report.population.changed", { "versionId": f.version.versionId, "attempt": attempt, "moved": outcome.moved });
		}
		variables.errors.conflict(
			"Walks in this report changed while it was being prepared. Run the report again.",
			"REPORT_POPULATION_CHANGED", { "attempts": variables.MAX_ATTEMPTS }
		);
	}

	private struct function assemble(required struct f, required struct raw) {
		var f = arguments.f;
		var catalog = f.catalog;
		var threshold = suppressionThreshold();
		var total = 0;
		var byStatus = {};
		var byUnit = {};
		for (var row in arguments.raw.units) {
			total += row.walks;
			byStatus[row.status] = (structKeyExists(byStatus, row.status) ? byStatus[row.status] : 0) + row.walks;
			byUnit[row.orgUnitId] = (structKeyExists(byUnit, row.orgUnitId) ? byUnit[row.orgUnitId] : 0) + row.walks;
		}
		var suppressed = isSuppressed(total, threshold);
		var report = {
			"format": variables.FORMAT,
			"generatedAt": variables.json.formatDate(now()),
			"version": f.version,
			"filters": filterEcho(f),
			"filterCount": filterCount(f),
			"scope": { "orgUnitCount": arrayLen(f.unitIds) },
			"suppression": { "threshold": threshold, "applied": suppressed },
			"population": { "walks": suppressed ? javaCast("null", "") : total, "byStatus": suppressed ? {} : byStatus, "suppressed": suppressed },
			"orgUnits": [], "dimensions": [], "sections": [], "items": [],
			"attempts": arguments.raw.attempts
		};
		if (suppressed) return report;

		var tree = variables.orgUnits.loadActiveTree();
		for (var unitId in structKeyArray(byUnit)) {
			var n = byUnit[unitId];
			var u = structKeyExists(tree, unitId) ? tree[unitId] : { "code": "", "name": "", "type": "" };
			var small = isSuppressed(n, threshold);
			arrayAppend(report.orgUnits, { "orgUnitId": unitId, "code": u.code, "name": u.name, "type": u.type, "walks": small ? javaCast("null", "") : n, "suppressed": small });
		}
		arraySort(report.orgUnits, function(a, b) {
			var byType = compare(typeRank(a.type), typeRank(b.type));
			return byType != 0 ? byType : compareNoCase(a.name, b.name);
		});

		for (var d in catalog.dimensions) arrayAppend(report.dimensions, dimensionDto(d, arguments.raw.dimensions[d.code], threshold));

		// Items: state counts, the ANSWERED distribution, and item-level scores.
		var counts = {};
		for (var row in arguments.raw.items) {
			if (!structKeyExists(counts, row.itemId)) counts[row.itemId] = { "states": {}, "options": {} };
			var c = counts[row.itemId];
			c.states[row.state] = (structKeyExists(c.states, row.state) ? c.states[row.state] : 0) + row.responses;
			if (row.state == "ANSWERED" && len(row.optionId)) c.options[row.optionId] = (structKeyExists(c.options, row.optionId) ? c.options[row.optionId] : 0) + row.responses;
		}
		var itemDtos = {};
		for (var it in reportedItems(f)) {
			var dto = itemDto(it, structKeyExists(counts, it.itemId) ? counts[it.itemId] : { "states": {}, "options": {} }, total);
			itemDtos[it.itemKey] = dto;
			arrayAppend(report.items, dto);
		}
		// Sections: pooled over every reported scored response beneath them.
		for (var s in catalog.sections) {
			var keys = [];
			for (var k in s.subtreeItemKeys) if (structKeyExists(itemDtos, k)) arrayAppend(keys, k);
			if (!arrayLen(keys)) continue;
			var own = [];
			for (var k in s.itemKeys) if (structKeyExists(itemDtos, k)) arrayAppend(own, k);
			var responses = 0;
			var sum = variables.BigDecimal.ZERO;
			var anyScored = false;
			for (var k in keys) {
				if (isNull(itemDtos[k].scored)) continue;
				anyScored = true;
				responses += itemDtos[k].scored.responses;
				sum = sum.add(itemDtos[k].scoreSumExact);
			}
			arrayAppend(report.sections, {
				"sectionKey": s.sectionKey, "title": s.title, "parentSectionKey": len(s.parentSectionKey) ? s.parentSectionKey : javaCast("null", ""),
				"depth": s.depth, "itemKeys": own, "scored": anyScored ? scoredDto(responses, sum) : javaCast("null", "")
			});
		}
		for (var dto in report.items) structDelete(dto, "scoreSumExact");
		return report;
	}

	private struct function dimensionDto(required struct d, required array rows, required numeric threshold) {
		var states = { "ANSWERED": 0, "UNANSWERED": 0, "HIDDEN": 0 };
		var byValue = {};
		for (var row in arguments.rows) {
			if (!row.visible) { states.HIDDEN += row.walks; continue; }
			if (len(row.valueId) && structKeyExists(arguments.d.valueById, row.valueId)) {
				states.ANSWERED += row.walks;
				byValue[row.valueId] = (structKeyExists(byValue, row.valueId) ? byValue[row.valueId] : 0) + row.walks;
			} else {
				states.UNANSWERED += row.walks;
			}
		}
		var values = [];
		for (var v in arguments.d.values) {
			var n = structKeyExists(byValue, v.valueId) ? byValue[v.valueId] : 0;
			var small = isSuppressed(n, arguments.threshold);
			arrayAppend(values, { "code": v.code, "label": v.label, "walks": small ? javaCast("null", "") : n, "suppressed": small });
		}
		return { "code": arguments.d.code, "label": arguments.d.label, "states": states, "values": values };
	}

	private struct function itemDto(required struct it, required struct counts, required numeric total) {
		var states = {};
		var recorded = 0;
		for (var s in variables.STATES) {
			states[s] = structKeyExists(arguments.counts.states, s) ? arguments.counts.states[s] : 0;
			recorded += states[s];
		}
		states["UNRECORDED"] = max(0, arguments.total - recorded);
		var options = [];
		var responses = 0;
		var sum = variables.BigDecimal.ZERO;
		for (var o in arguments.it.options) {
			var n = structKeyExists(arguments.counts.options, o.optionId) ? arguments.counts.options[o.optionId] : 0;
			arrayAppend(options, { "code": o.code, "label": o.label, "numericScore": o.scored ? o.numericScore : javaCast("null", ""), "isNa": o.isNa, "count": n });
			if (arguments.it.scored && o.scored && n > 0) {
				responses += n;
				sum = sum.add(variables.BigDecimal.init(toString(o.numericScore)).multiply(variables.BigDecimal.valueOf(javaCast("long", n))));
			}
		}
		var dto = itemHeader(arguments.it);
		dto["states"] = states;
		dto["options"] = options;
		dto["scored"] = arguments.it.scored ? scoredDto(responses, sum) : javaCast("null", "");
		dto["scoreSumExact"] = sum;
		return dto;
	}

	private struct function itemHeader(required struct it) {
		var options = [];
		for (var o in arguments.it.options) arrayAppend(options, { "code": o.code, "label": o.label, "numericScore": o.scored ? o.numericScore : javaCast("null", ""), "isNa": o.isNa });
		return {
			"itemKey": arguments.it.itemKey, "sectionKey": arguments.it.sectionKey, "prompt": arguments.it.prompt,
			"questionNumber": isNull(arguments.it.questionNumber) ? javaCast("null", "") : arguments.it.questionNumber,
			"layout": arguments.it.layout, "isPlaceholder": arguments.it.isPlaceholder, "scoreEnabled": arguments.it.scored, "options": options
		};
	}

	/** { responses, sum, mean }: mean = sum / responses to four places, null when nothing was scored. */
	private struct function scoredDto(required numeric responses, required any sum) {
		var mean = javaCast("null", "");
		if (arguments.responses > 0) {
			mean = val(arguments.sum.divide(variables.BigDecimal.valueOf(javaCast("long", arguments.responses)), javaCast("int", 4), variables.HALF_UP).toPlainString());
		}
		return { "responses": arguments.responses, "sum": val(arguments.sum.toPlainString()), "mean": isNull(mean) ? javaCast("null", "") : mean };
	}

	private array function reportedItems(required struct f) {
		var out = [];
		for (var it in arguments.f.catalog.items) {
			if (len(arguments.f.item) && compare(it.itemKey, arguments.f.item) != 0) continue;
			if (len(arguments.f.section) && !arrayContains(arguments.f.catalog.sectionIndex[arguments.f.section].subtreeItemKeys, it.itemKey)) continue;
			arrayAppend(out, it);
		}
		return out;
	}

	// ---- catalog: what a version makes reportable -------------------------------------------------

	/**
	 * The reportable surface of one version, derived from its immutable render model and resolved
	 * to its SQL identifiers. Cached per (version, checksum): a published version never changes,
	 * and a DRAFT re-import changes the checksum.
	 *
	 *   items       active SINGLE_CHOICE items flagged reportable, with a response set. Notes, text,
	 *               display items and the email draft are never reportable, whatever their flags.
	 *   dimensions  active placements of reportable, non-sensitive LIST dimensions, except the School
	 *               dimension (the org unit is the school, and the authority for scope). Free-text,
	 *               date and number dimensions (Observer, Lesson Standard, tags, Date) are never
	 *               reported. Each carries the visibility condition the engine implies for it.
	 */
	public struct function catalogFor(required string versionId) {
		var index = variables.walks.definitionIndex(arguments.versionId);
		var cacheKey = uCase(arguments.versionId);
		if (structKeyExists(variables.catalogCache, cacheKey) && compare(variables.catalogCache[cacheKey].checksum, index.checksum) == 0) return variables.catalogCache[cacheKey];
		var model = variables.snapshots.renderModelFor(arguments.versionId);
		var catalog = { "checksum": index.checksum, "sections": [], "sectionIndex": {}, "items": [], "itemIndex": {}, "dimensions": [] };
		collect(model.root, "", 0, [], catalog, model, index);
		// A section is listed only when something reportable lies beneath it.
		var kept = [];
		for (var s in catalog.sections) if (arrayLen(s.subtreeItemKeys)) arrayAppend(kept, s);
		catalog.sections = kept;
		variables.catalogCache[cacheKey] = catalog;
		return catalog;
	}

	private void function collect(required struct node, required string parentKey, required numeric depth, required array ancestry, required struct catalog, required struct model, required struct index) {
		var n = arguments.node;
		var path = duplicate(arguments.ancestry);
		arrayAppend(path, n.sectionKey);
		var section = { "sectionKey": n.sectionKey, "title": n.title, "parentSectionKey": arguments.parentKey, "depth": arguments.depth, "itemKeys": [], "subtreeItemKeys": [] };
		arrayAppend(arguments.catalog.sections, section);
		arguments.catalog.sectionIndex[n.sectionKey] = section;
		for (var p in n.placements) {
			var dim = dimensionEntry(p, path, arguments.model, arguments.index);
			if (!structIsEmpty(dim)) arrayAppend(arguments.catalog.dimensions, dim);
		}
		for (var it in n.items) {
			var entry = itemEntry(it, n.sectionKey, arguments.index);
			if (structIsEmpty(entry)) continue;
			arrayAppend(arguments.catalog.items, entry);
			arguments.catalog.itemIndex[entry.itemKey] = entry;
			arrayAppend(section.itemKeys, entry.itemKey);
			for (var key in path) arrayAppend(arguments.catalog.sectionIndex[key].subtreeItemKeys, entry.itemKey);
		}
		for (var child in n.children) collect(child, n.sectionKey, arguments.depth + 1, path, arguments.catalog, arguments.model, arguments.index);
	}

	private struct function itemEntry(required struct it, required string sectionKey, required struct index) {
		var i = arguments.it;
		if (compare(i.itemType, "SINGLE_CHOICE") != 0 || !i.reportable) return {};
		if (!structKeyExists(i, "responseSet") || isNull(i.responseSet) || !isStruct(i.responseSet)) return {};
		if (!structKeyExists(arguments.index.items, i.itemKey)) return {};
		var def = arguments.index.items[i.itemKey];
		var byCode = structKeyExists(arguments.index.options, def.responseSetId) ? arguments.index.options[def.responseSetId] : {};
		var options = [];
		var anyScore = false;
		for (var o in i.responseSet.options) {
			if (!structKeyExists(byCode, o.storedCode)) continue;
			var scored = !isNull(o.numericScore) && isNumeric(o.numericScore) && !o.isNa;
			if (scored) anyScore = true;
			arrayAppend(options, { "code": o.storedCode, "label": o.label, "optionId": byCode[o.storedCode], "numericScore": scored ? o.numericScore : javaCast("null", ""), "isNa": o.isNa ? true : false, "scored": scored });
		}
		return {
			"itemKey": i.itemKey, "itemId": def.itemId, "sectionKey": arguments.sectionKey, "prompt": i.prompt,
			"questionNumber": isNull(i.questionNumber) ? javaCast("null", "") : i.questionNumber, "layout": i.layout,
			"isPlaceholder": i.isPlaceholder ? true : false,
			"scored": (i.responseSet.scoreEnabled ? true : false) && anyScore, "options": options
		};
	}

	private struct function dimensionEntry(required struct placement, required array ancestry, required struct model, required struct index) {
		var code = arguments.placement.dimensionCode;
		if (!structKeyExists(arguments.model.dimensions, code)) return {};
		var dim = arguments.model.dimensions[code];
		if (compare(dim.dataType, "LIST") != 0 || !dim.reportable || dim.sensitive) return {};
		if (compareNoCase(code, variables.config.schoolDimensionCode) == 0) return {};
		if (!structKeyExists(arguments.index.dimensions, code)) return {};
		var dimensionId = arguments.index.dimensions[code];
		var valueIds = arguments.index.values[dimensionId];
		var values = [];
		var valueById = {};
		for (var v in dim.values) {
			if (!structKeyExists(valueIds, v.valueCode)) continue;
			arrayAppend(values, { "code": v.valueCode, "label": v.label, "valueId": valueIds[v.valueCode] });
			valueById[valueIds[v.valueCode]] = v.valueCode;
		}
		var visibility = visibilityFor(code, arguments.ancestry, arguments.model, arguments.index);
		if (structIsEmpty(visibility)) return {};
		return { "code": code, "label": dim.label, "dimensionId": dimensionId, "values": values, "valueById": valueById, "visibility": visibility };
	}

	/**
	 * When is this dimension visible? Asked of the instrument's own engine rather than re-derived.
	 *
	 * The rules that can hide a placement are the SHOW rules on the dimension itself and on every
	 * section above it. When every condition in them reads a controlled-list dimension, visibility
	 * is a function of those source dimensions' selected values alone, so every combination of
	 * those values (each value of the version, plus "none") is evaluated through
	 * VisibilityEngine.evaluateVisibility and the combinations that show the dimension become the
	 * condition the SQL applies. When a condition reads anything else -- an item response, free
	 * text -- visibility cannot be decided from the tables without per-walk evaluation, and the
	 * dimension is left out of the report rather than counted wrong.
	 */
	private struct function visibilityFor(required string code, required array ancestry, required struct model, required struct index) {
		var sources = [];
		for (var r in arguments.model.rules) {
			var relevant = (compare(r.targetType, "DIMENSION") == 0 && compare(r.targetKey, arguments.code) == 0)
				|| (compare(r.targetType, "SECTION") == 0 && arrayContains(arguments.ancestry, r.targetKey));
			if (!relevant) continue;
			var conds = structKeyExists(r.conditions, "conditions") ? r.conditions.conditions : [];
			for (var c in conds) {
				if (compare(c.sourceType, "DIMENSION") != 0) return {};
				if (!arrayContains(sources, c.sourceKey)) arrayAppend(sources, c.sourceKey);
			}
		}
		if (!arrayLen(sources)) {
			var ev = variables.engine.evaluateVisibility(arguments.model, { "dimensions": {}, "responses": {} });
			return { "mode": (structKeyExists(ev.dimensions, arguments.code) && ev.dimensions[arguments.code]) ? "ALWAYS" : "NEVER" };
		}
		var axes = [];
		var sourceIds = [];
		var product = 1;
		for (var src in sources) {
			if (!structKeyExists(arguments.model.dimensions, src) || compare(arguments.model.dimensions[src].dataType, "LIST") != 0) return {};
			if (!structKeyExists(arguments.index.dimensions, src)) return {};
			var srcId = arguments.index.dimensions[src];
			var axis = [""];
			for (var v in arguments.model.dimensions[src].values) if (structKeyExists(arguments.index.values[srcId], v.valueCode)) arrayAppend(axis, v.valueCode);
			arrayAppend(axes, axis);
			arrayAppend(sourceIds, srcId);
			product *= arrayLen(axis);
			if (product > variables.MAX_VISIBILITY_TUPLES) return {};
		}
		var tuples = [];
		var combo = [];
		for (var i = 1; i <= arrayLen(axes); i++) arrayAppend(combo, 1);
		while (true) {
			var st = { "dimensions": {}, "responses": {} };
			var tuple = [];
			for (var a = 1; a <= arrayLen(axes); a++) {
				var valueCode = axes[a][combo[a]];
				if (len(valueCode)) st.dimensions[sources[a]] = { "selectedValueCode": valueCode };
				arrayAppend(tuple, len(valueCode) ? arguments.index.values[sourceIds[a]][valueCode] : "");
			}
			var ev = variables.engine.evaluateVisibility(arguments.model, st);
			if (structKeyExists(ev.dimensions, arguments.code) && ev.dimensions[arguments.code]) arrayAppend(tuples, tuple);
			// Next combination (odometer order).
			var pos = arrayLen(axes);
			while (pos >= 1) {
				if (combo[pos] < arrayLen(axes[pos])) { combo[pos]++; break; }
				combo[pos] = 1;
				pos--;
			}
			if (pos < 1) break;
		}
		return { "mode": "TUPLES", "sources": sourceIds, "tuples": tuples };
	}

	// ---- versions ---------------------------------------------------------------------------------

	/**
	 * PUBLISHED and RETIRED versions of the configured instrument, plus the current version (which
	 * outside production may be the DRAFT preview walks were created against). Newest first.
	 */
	public array function reportableVersions() {
		var current = variables.snapshots.currentVersion();
		var out = [];
		var seen = {};
		if (!structIsEmpty(current)) {
			arrayAppend(out, { "versionId": current.versionId, "versionLabel": current.versionLabel, "status": current.status, "isCurrent": true });
			seen[current.versionId] = true;
		}
		for (var v in variables.reports.listFrozenVersions(variables.config.instrumentCode)) {
			if (structKeyExists(seen, v.versionId)) continue;
			v["isCurrent"] = false;
			arrayAppend(out, v);
			seen[v.versionId] = true;
		}
		return out;
	}

	private struct function resolveVersion(required string versionId) {
		var versions = reportableVersions();
		if (!len(arguments.versionId)) {
			for (var v in versions) if (v.isCurrent) return { "versionId": v.versionId, "versionLabel": v.versionLabel, "status": v.status };
			// Nothing is in service (Phase 6: the only version was retired with confirmation), but its
			// walks are still reportable. The default is then the newest frozen version, which is
			// first in the list, rather than a refusal that would leave the Reports view unable to open.
			if (arrayLen(versions)) return { "versionId": versions[1].versionId, "versionLabel": versions[1].versionLabel, "status": versions[1].status };
			variables.errors.notFound("No instrument version is available to report on yet.", "REPORT_VERSION_NOT_AVAILABLE");
		}
		if (!variables.db.isGuid(arguments.versionId)) filterRefused("INVALID_VERSION_ID", "versionId", "versionId is not a valid identifier.");
		for (var v in versions) {
			if (compare(v.versionId, uCase(trim(arguments.versionId))) == 0) return { "versionId": v.versionId, "versionLabel": v.versionLabel, "status": v.status };
		}
		variables.errors.notFound("Instrument version not found.", "REPORT_VERSION_NOT_FOUND");
	}

	// ---- request parameters -----------------------------------------------------------------------

	/**
	 * Splits the query into named parameters and dimension filters. Parameter names are matched
	 * case-insensitively (the URL scope does not preserve case on every engine); values are exact.
	 * An empty value is an absent filter. Anything unrecognized, structured, or too long is refused.
	 */
	private struct function readParams(required struct query, required array allowed, required boolean allowDimensions) {
		var out = { "named": {}, "dimensions": {} };
		for (var key in structKeyArray(arguments.query)) {
			var value = arguments.query[key];
			var shown = left(key, 60);
			if (isNull(value) || !isSimpleValue(value)) filterRefused("REPORT_FILTER_VALUE_INVALID", shown, "Filter values are plain text.");
			value = trim(toString(value));
			if (len(value) > variables.PARAM_MAX_LENGTH) filterRefused("REPORT_FILTER_VALUE_INVALID", shown, "Filter value is too long.");
			var canonical = "";
			for (var name in arguments.allowed) if (compareNoCase(name, key) == 0) canonical = name;
			if (len(canonical)) {
				if (len(value)) out.named[canonical] = value;
				continue;
			}
			if (arguments.allowDimensions && len(key) > len(variables.DIMENSION_PREFIX) && compareNoCase(left(key, len(variables.DIMENSION_PREFIX)), variables.DIMENSION_PREFIX) == 0) {
				if (len(value)) out.dimensions[mid(key, len(variables.DIMENSION_PREFIX) + 1, len(key))] = value;
				continue;
			}
			filterRefused("REPORT_FILTER_UNKNOWN", shown, "Unknown report parameter.");
		}
		return out;
	}

	private date function parseDate(required string text, required string parameter) {
		if (!reFind("^\d{4}-\d{2}-\d{2}$", arguments.text)) filterRefused("REPORT_FILTER_VALUE_INVALID", arguments.parameter, "Dates are YYYY-MM-DD.");
		var y = val(left(arguments.text, 4));
		var m = val(mid(arguments.text, 6, 2));
		var d = val(right(arguments.text, 2));
		if (m < 1 || m > 12 || d < 1 || d > daysInMonth(createDate(y, m, 1)) || y < 1900 || y > 9999) {
			filterRefused("REPORT_FILTER_VALUE_INVALID", arguments.parameter, "Not a calendar date.");
		}
		return createDate(y, m, d);
	}

	private struct function findDimension(required struct catalog, required string rawCode) {
		for (var d in arguments.catalog.dimensions) if (compareNoCase(d.code, arguments.rawCode) == 0) return d;
		return {};
	}

	private struct function findValue(required struct dimension, required string code) {
		for (var v in arguments.dimension.values) if (compare(v.code, arguments.code) == 0) return v;
		return {};
	}

	private void function filterRefused(required string code, required string parameter, required string message) {
		variables.errors.validation(arguments.message, arguments.code, { "issues": [{ "parameter": arguments.parameter, "code": arguments.code }] });
	}

	private struct function filterEcho(required struct f) {
		return {
			"versionId": arguments.f.version.versionId,
			"orgUnitId": orNull(arguments.f.orgUnitId),
			"from": orNull(arguments.f.from),
			"to": orNull(arguments.f.to),
			"dimensions": arguments.f.dimensions,
			"section": orNull(arguments.f.section),
			"item": orNull(arguments.f.item),
			"optionItem": orNull(arguments.f.optionItem),
			"option": orNull(arguments.f.option),
			"includeDrafts": arguments.f.includeDrafts ? true : false,
			"statuses": arguments.f.statuses
		};
	}

	/** The value, or JSON null when it is empty (a local assigned null does not exist in CFML). */
	private any function orNull(required string value) {
		if (!len(arguments.value)) return javaCast("null", "");
		return arguments.value;
	}

	private numeric function filterCount(required struct f) {
		var n = structCount(arguments.f.dimensions);
		for (var k in ["orgUnitId", "from", "to", "section", "item", "optionItem"]) if (len(arguments.f[k])) n++;
		if (arguments.f.includeDrafts) n++;
		return n;
	}

	// ---- small helpers ----------------------------------------------------------------------------

	private boolean function isSuppressed(required numeric n, required numeric threshold) {
		return arguments.threshold > 0 && arguments.n > 0 && arguments.n < arguments.threshold;
	}

	private string function typeRank(required string type) {
		switch (uCase(arguments.type)) {
			case "DISTRICT": return "1";
			case "SCHOOL": return "2";
		}
		return "3";
	}

	private string function num(any value) {
		if (isNull(arguments.value)) return "";
		return variables.json.serialize(arguments.value);
	}

	private string function flag(required boolean value) { return arguments.value ? "1" : "0"; }

	/** [responses, sum, mean] cells of a section or item row; empty when it is not scored. */
	private array function scoredCells(required struct row) {
		if (isNull(arguments.row.scored)) return ["", "", ""];
		var mean = isNull(arguments.row.scored.mean) ? "" : num(arguments.row.scored.mean);
		return [num(arguments.row.scored.responses), num(arguments.row.scored.sum), mean];
	}

	/** One RFC 4180 row. Text that a spreadsheet would evaluate is prefixed with an apostrophe. */
	private string function csvRow(required array cells) {
		var out = [];
		for (var cell in arguments.cells) {
			var s = isNull(cell) ? "" : toString(cell);
			if (len(s) && reFind("^[=+\-@\t\r]", s) && !reFind("^-?\d+(\.\d+)?$", s)) s = "'" & s;
			if (reFind('[",\r\n]', s)) s = '"' & replace(s, '"', '""', "all") & '"';
			arrayAppend(out, s);
		}
		return arrayToList(out, ",");
	}

	private string function safeName(required string text) {
		var s = reReplace(arguments.text, "[^A-Za-z0-9_-]+", "_", "all");
		s = reReplace(s, "^_+|_+$", "", "all");
		return len(s) ? left(s, 60) : "version";
	}
}
