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
 * LIVE OR RELEASED (RPT-03; the owner-approved rule in docs/OPEN_DECISIONS.md, "Aggregate
 * privacy-suppression threshold"). A report-only user must not be able to infer an individual walk
 * from any report, and a report over live data cannot promise that: two reports whose filters
 * differ by one walk, or one report run before and after a walk is completed, differ by exactly
 * that walk. So there are two kinds of report:
 *
 *   LIVE      today's walks, every filter. Only for a caller who holds walk.read on EVERY unit the
 *             report draws on: that person can already open each of those walks, so an aggregate
 *             can disclose nothing to them that they could not read directly.
 *   RELEASE   a frozen release of one closed period (migration 007; createRelease). Anyone with
 *             report.view may read one, and a caller without walk.read on the whole scope may read
 *             nothing else (REPORT_RELEASE_REQUIRED). It takes the version, a covered unit, a
 *             section and a question -- nothing that narrows who is counted
 *             (REPORT_FILTER_NOT_PERMITTED) -- and counts COMPLETED walks only. Releases never
 *             overlap and never change, so no two can be subtracted and rerunning one returns the
 *             same figures. Blocks -- one per (version, org unit) -- below the minimum were never
 *             stored, and each stored block's breakdowns are protected by DisclosureControl before
 *             they are added up, so a district figure is the sum of figures each school's own
 *             report already publishes: subtracting reports never yields anything new.
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
 * nothing is ever coerced to zero (docs/DATA_CONTRACT.md, "Aggregate calculations"). In a released
 * report a withheld figure is null -- never 0, and never sent next to a flag -- and a figure that
 * is only partly published carries `withheld: true`: it is the published part, a lower bound.
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
 * is read and verified after every aggregate is read. A live report -- or a release being created
 * -- that saw any walk move is discarded and recomputed, at most MAX_ATTEMPTS times; after that the
 * caller receives 409 REPORT_POPULATION_CHANGED rather than figures that describe no committed
 * state. No lock is held that a writer waits on.
 */
component output="false" {

	variables.FORMAT = "icfwalk-aggregate-report/2";
	variables.MAX_ATTEMPTS = 3;
	variables.MAX_VISIBILITY_TUPLES = 512;
	variables.PARAM_MAX_LENGTH = 100;
	variables.REPORT_PARAMS = ["versionId", "orgUnitId", "releaseId", "from", "to", "section", "item", "optionItem", "option", "includeDrafts"];
	// Parameters that change who is counted. A released report takes none of them.
	variables.LIVE_ONLY_PARAMS = ["from", "to", "optionItem", "option", "includeDrafts"];
	variables.OPTIONS_PARAMS = ["versionId"];
	variables.RELEASE_FIELDS = ["observedFrom", "observedTo"];
	variables.DIMENSION_PREFIX = "dim_";
	variables.STATES = ["ANSWERED", "UNANSWERED", "HIDDEN", "NOT_APPLICABLE"];
	// The categories of a released breakdown after an item's options, and after a dimension's values.
	variables.ITEM_STATE_CATEGORIES = ["UNANSWERED", "HIDDEN", "NOT_APPLICABLE", "UNRECORDED"];
	variables.DIMENSION_STATE_CATEGORIES = ["UNANSWERED", "HIDDEN"];
	variables.ITEM_REPORT_STATES = ["ANSWERED", "UNANSWERED", "HIDDEN", "NOT_APPLICABLE", "UNRECORDED"];
	variables.DIMENSION_REPORT_STATES = ["ANSWERED", "UNANSWERED", "HIDDEN"];

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
		variables.disclosure = createObject("component", "icfwalk.reports.DisclosureControl").init();
		variables.catalogCache = {};
		variables.BigDecimal = createObject("java", "java.math.BigDecimal");
		variables.HALF_UP = createObject("java", "java.math.RoundingMode").HALF_UP;
		return this;
	}

	/** The approved minimum (docs/OPEN_DECISIONS.md), as configured; never below 3. */
	public numeric function minimumWalks() {
		var k = variables.config.reportSuppressionThreshold;
		return (isNumeric(k) && k >= 3) ? int(k) : 3;
	}

	// ---- options --------------------------------------------------------------------------------

	/**
	 * What the caller may filter by: the reportable versions, the org units the caller's report
	 * scope covers, and -- for the selected version -- the reportable dimensions with their values,
	 * the sections and the reportable items with their options. Also whether live reports are open
	 * to the caller over their whole scope, which releases exist (with the versions each holds for
	 * the caller's units), and whether the caller may create one. Instrument content, scope and
	 * release metadata only; no walk data.
	 */
	public struct function options(required struct principal, required struct query) {
		variables.authz.requirePermission(arguments.principal, "report.view");
		var params = readParams(arguments.query, variables.OPTIONS_PARAMS, false);
		var version = resolveVersion(structKeyExists(params.named, "versionId") ? params.named.versionId : "");
		var catalog = catalogFor(version.versionId);
		var tree = variables.orgUnits.loadActiveTree();
		var units = [];
		var covered = variables.authz.visibleOrgUnitIds(arguments.principal, "report.view");
		for (var id in covered) {
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
			"disclosure": { "minimumWalks": minimumWalks(), "liveAvailable": !isProtected(arguments.principal, covered) },
			"releases": releasesFor(covered),
			"canRelease": canRelease(arguments.principal)
		};
	}

	// ---- the report -------------------------------------------------------------------------------

	public struct function aggregate(required struct principal, required struct query) {
		var started = getTickCount();
		var f = parseFilters(arguments.principal, arguments.query);
		var report = f.mode == "RELEASE" ? releaseReport(f) : liveReport(f);
		variables.logger.info("report.generated", {
			"versionId": f.version.versionId, "mode": f.mode, "walks": report.population.withheld ? -1 : report.population.walks,
			"items": arrayLen(report.items), "attempts": report.attempts, "filters": filterCount(f), "ms": getTickCount() - started
		});
		return report;
	}

	/**
	 * The same report as a CSV download (RFC 4180, UTF-8 with a byte order mark so spreadsheet
	 * applications read the en dashes in the instrument's own wording, CRLF line ends). One record
	 * per figure, each with its own `withheld` flag: an empty count with withheld = 1 is withheld,
	 * a count with withheld = 1 is only the published part. It is built from the same report the
	 * JSON route returns, so it can never carry a figure that route withholds. Every text cell that
	 * a spreadsheet would evaluate as a formula is neutralized. The export is audited with
	 * identifiers and counts only.
	 */
	public struct function exportCsv(required struct principal, required struct query) {
		var report = aggregate(arguments.principal, arguments.query);
		var lines = [];
		arrayAppend(lines, csvRow(["record_type", "group", "key", "label", "count", "withheld", "scored_responses", "score_sum", "mean"]));
		var meta = [
			["format", variables.FORMAT], ["mode", report.mode], ["version_label", report.version.versionLabel], ["version_status", report.version.status],
			["generated_at", report.generatedAt], ["statuses", arrayToList(report.filters.statuses, " ")],
			["minimum_walks", toString(report.disclosure.minimumWalks)]
		];
		if (!isNull(report.release)) {
			arrayAppend(meta, ["release_id", report.release.releaseId]);
			arrayAppend(meta, ["release_observed_from", report.release.observedFrom]);
			arrayAppend(meta, ["release_observed_to", report.release.observedTo]);
			arrayAppend(meta, ["release_released_at", report.release.releasedAt]);
		}
		for (var key in ["orgUnitId", "from", "to", "section", "item", "optionItem", "option"]) {
			if (!isNull(report.filters[key])) arrayAppend(meta, ["filter_" & key, report.filters[key]]);
		}
		var dimensionCodes = structKeyArray(report.filters.dimensions);
		arraySort(dimensionCodes, "textnocase");
		for (var code in dimensionCodes) arrayAppend(meta, ["filter_dim_" & code, report.filters.dimensions[code]]);
		for (var m in meta) arrayAppend(lines, csvRow(["META", "", m[1], m[2], "", "", "", "", ""]));
		var pop = report.population;
		arrayAppend(lines, csvRow(["POPULATION", "", "walks", "", cell(pop, "walks"), flag(pop.withheld), "", "", ""]));
		for (var status in ["COMPLETED", "DRAFT"]) {
			if (!pop.withheld && structKeyExists(pop.byStatus, status)) arrayAppend(lines, csvRow(["POPULATION", "status", status, "", num(pop.byStatus[status]), "0", "", "", ""]));
		}
		for (var u in report.orgUnits) arrayAppend(lines, csvRow(["ORG_UNIT", u.type, u.code, u.name, cell(u, "walks"), "0", "", "", ""]));
		for (var d in report.dimensions) {
			for (var state in variables.DIMENSION_REPORT_STATES) {
				arrayAppend(lines, csvRow(["DIMENSION_STATE", d.code, state, "", cell(d.states, state), flag(arrayContains(d.withheldStates, state)), "", "", ""]));
			}
			if (d.withheldResponses > 0) arrayAppend(lines, csvRow(["DIMENSION_STATE", d.code, "WITHHELD_RESPONSES", "", num(d.withheldResponses), "1", "", "", ""]));
			for (var v in d.values) arrayAppend(lines, csvRow(["DIMENSION_VALUE", d.code, v.code, v.label, cell(v, "walks"), flag(v.withheld), "", "", ""]));
		}
		for (var s in report.sections) {
			var sectionScored = scoredCells(s);
			arrayAppend(lines, csvRow(["SECTION", s.sectionKey, "", s.title, "", sectionScored[4], sectionScored[1], sectionScored[2], sectionScored[3]]));
		}
		for (var it in report.items) {
			var itemScored = scoredCells(it);
			arrayAppend(lines, csvRow(["ITEM", it.sectionKey, it.itemKey, it.prompt, "", itemScored[4], itemScored[1], itemScored[2], itemScored[3]]));
			for (var state in variables.ITEM_REPORT_STATES) {
				arrayAppend(lines, csvRow(["ITEM_STATE", it.itemKey, state, "", cell(it.states, state), flag(arrayContains(it.withheldStates, state)), "", "", ""]));
			}
			if (it.withheldResponses > 0) arrayAppend(lines, csvRow(["ITEM_STATE", it.itemKey, "WITHHELD_RESPONSES", "", num(it.withheldResponses), "1", "", "", ""]));
			for (var o in it.options) arrayAppend(lines, csvRow(["OPTION", it.itemKey, o.code, o.label, cell(o, "count"), flag(o.withheld), "", "", ""]));
		}
		var text = chr(65279) & arrayToList(lines, chr(13) & chr(10)) & chr(13) & chr(10);
		var bytes = arrayLen(charsetDecode(text, "utf-8"));
		var fileName = "ICFWalk_report_" & safeName(report.version.versionLabel) & "_" & dateFormat(dateConvert("local2utc", now()), "yyyymmdd") & ".csv";
		var details = {
			"versionId": report.version.versionId, "mode": report.mode, "walks": pop.withheld ? -1 : pop.walks, "withheld": pop.withheld ? true : false,
			"rows": arrayLen(lines) - 1, "bytes": bytes, "filters": report.filterCount, "attempts": report.attempts
		};
		if (!isNull(report.filters.orgUnitId)) details["orgUnitId"] = report.filters.orgUnitId;
		if (!isNull(report.release)) details["releaseId"] = report.release.releaseId;
		variables.audit.record("REPORT", "", "REPORT_EXPORTED", arguments.principal.userId, details);
		variables.logger.info("report.exported", details);
		return { "text": text, "fileName": fileName, "bytes": bytes, "rows": arrayLen(lines) - 1 };
	}

	// ---- releases ---------------------------------------------------------------------------------

	/**
	 * Freezes one closed observation period for report-only users (POST /api/reports/releases).
	 *
	 * WHO. Only a caller who holds report.view AND walk.read on every active org unit: a release
	 * covers every walk of the period in every school, and this is someone who can already open
	 * each of them, so creating one discloses nothing to them. Anyone else is refused (403
	 * REPORT_RELEASE_NOT_PERMITTED) and the refusal is audited.
	 *
	 * WHAT. body = { observedFrom, observedTo } (YYYY-MM-DD, inclusive), nothing else. The dates
	 * must have passed (the last before today, UTC) and must not overlap any existing release's dates:
	 * two overlapping releases could be subtracted. Under an exclusive lock, for every reportable
	 * version with COMPLETED walks observed in the period, the walks of every active unit that no
	 * earlier release counted are read as one coherent population (captured row versions, verified,
	 * up to MAX_ATTEMPTS), and each (version, org unit) block with at least the minimum walks is
	 * stored with the count of every non-zero category of every reportable breakdown, beside the
	 * walks it counts (so no later release counts them again, even after a date correction moves
	 * one: P7C-02). A smaller block is not stored at all, and its walks stay unreleased.
	 * Nothing is suppressed at this point: suppression is applied, deterministically, each time the
	 * release is read.
	 */
	public struct function createRelease(required struct principal, required struct body) {
		var principal = arguments.principal;
		variables.authz.requirePermission(principal, "report.view");
		if (!canRelease(principal)) {
			variables.logger.warn("authorization.denied", { "permission": "report.release", "kind": "forbidden" });
			variables.audit.record("REPORT", "", "ACCESS_DENIED", principal.userId, { "permission": "report.release", "kind": "forbidden" });
			variables.errors.forbidden("Only someone who can open every walk in every school may release reporting dates.", "REPORT_RELEASE_NOT_PERMITTED");
		}
		var span = releaseDates(arguments.body);
		var k = minimumWalks();
		var reports = variables.reports;
		var unitIds = structKeyArray(variables.orgUnits.loadActiveTree());
		var reportable = {};
		for (var v in reportableVersions()) reportable[v.versionId] = true;
		var outcome = variables.db.transact(function() {
			reports.lockReleases();
			if (reports.overlapsRelease(span.fromText, span.toText)) {
				variables.errors.conflict("Those dates overlap dates that have already been released. Released dates never overlap.", "REPORT_RELEASE_OVERLAP");
			}
			var releaseId = variables.db.newGuid();
			reports.insertRelease(releaseId, span.fromText, span.toText, k, principal.userId);
			var versions = [];
			var blockCount = 0;
			var attempts = 0;
			for (var versionId in reports.versionsWithCompletedWalks(span.from, span.before)) {
				if (!structKeyExists(reportable, versionId)) continue;
				var frozen = freezeVersion(versionId, span.from, span.before, unitIds, k);
				attempts = max(attempts, frozen.attempts);
				for (var b in frozen.blocks) {
					reports.insertMembers(releaseId, versionId, b.orgUnitId, b.walkIds);
					reports.insertBlock(releaseId, versionId, b.orgUnitId, b.walks);
					reports.insertCells(releaseId, versionId, b.orgUnitId, b.cells);
				}
				blockCount += arrayLen(frozen.blocks);
				arrayAppend(versions, { "versionId": versionId, "blocks": arrayLen(frozen.blocks) });
			}
			return { "release": reports.findRelease(releaseId), "versions": versions, "blocks": blockCount, "attempts": attempts };
		});
		var r = outcome.release;
		var details = {
			"releaseId": r.releaseId, "observedFrom": r.observedFrom, "observedTo": r.observedTo, "minimumWalks": r.minimumWalks,
			"versions": arrayLen(outcome.versions), "blocks": outcome.blocks, "attempts": outcome.attempts
		};
		variables.audit.record("REPORT", r.releaseId, "REPORT_RELEASED", principal.userId, details);
		variables.logger.info("report.released", details);
		return {
			"release": {
				"releaseId": r.releaseId, "observedFrom": r.observedFrom, "observedTo": r.observedTo, "minimumWalks": r.minimumWalks,
				"releasedAt": variables.json.formatDate(r.releasedAt), "versions": outcome.versions, "blocks": outcome.blocks
			}
		};
	}

	/** Whether the principal may create a release: report.view and walk.read on every active unit. */
	public boolean function canRelease(required struct principal) {
		var tree = variables.orgUnits.loadActiveTree();
		if (structIsEmpty(tree)) return false;
		var read = unitSet(variables.authz.visibleOrgUnitIds(arguments.principal, "walk.read"));
		var view = unitSet(variables.authz.visibleOrgUnitIds(arguments.principal, "report.view"));
		for (var id in structKeyArray(tree)) {
			if (!structKeyExists(read, uCase(id)) || !structKeyExists(view, uCase(id))) return false;
		}
		return true;
	}

	/** Reads and checks a release request body: exactly { observedFrom, observedTo }, dates that have passed. */
	private struct function releaseDates(required struct body) {
		for (var key in structKeyArray(arguments.body)) {
			var known = false;
			for (var name in variables.RELEASE_FIELDS) if (compare(name, key) == 0) known = true;
			if (!known) releaseRefused("REPORT_RELEASE_BODY_INVALID", left(key, 60), "A release takes observedFrom and observedTo only.");
		}
		var dates = {};
		for (var name in variables.RELEASE_FIELDS) {
			if (!structKeyExists(arguments.body, name) || isNull(arguments.body[name])) releaseRefused("REPORT_RELEASE_BODY_INVALID", name, "observedFrom and observedTo are both required.");
			var text = arguments.body[name];
			if (!isSimpleValue(text) || !reFind("^\d{4}-\d{2}-\d{2}$", text)) releaseRefused("REPORT_RELEASE_DATES_INVALID", name, "Dates are YYYY-MM-DD.");
			var y = val(left(text, 4));
			var m = val(mid(text, 6, 2));
			var d = val(right(text, 2));
			if (m < 1 || m > 12 || y < 1900 || y > 9999 || d < 1 || d > daysInMonth(createDate(y, m, 1))) releaseRefused("REPORT_RELEASE_DATES_INVALID", name, "Not a calendar date.");
			dates[name] = createDate(y, m, d);
		}
		if (dateCompare(dates.observedFrom, dates.observedTo) > 0) releaseRefused("REPORT_RELEASE_DATES_INVALID", "observedFrom", "The first date must not be after the last.");
		var utc = dateConvert("local2utc", now());
		if (dateCompare(dates.observedTo, createDate(year(utc), month(utc), day(utc))) >= 0) {
			releaseRefused("REPORT_RELEASE_DATES_OPEN", "observedTo", "Only dates that have passed can be released: the last must be before today (UTC).");
		}
		return {
			"fromText": arguments.body.observedFrom, "toText": arguments.body.observedTo,
			"from": dates.observedFrom, "before": dateAdd("d", 1, dates.observedTo)
		};
	}

	private void function releaseRefused(required string code, required string field, required string message) {
		variables.errors.validation(arguments.message, arguments.code, { "issues": [{ "field": arguments.field, "code": arguments.code }] });
	}

	/**
	 * One version's blocks for a release: a coherent population of the version's COMPLETED walks
	 * observed in the period at every active unit, read the way a live report reads it, then split
	 * by org unit. Blocks below k are dropped here and never stored.
	 */
	private struct function freezeVersion(required string versionId, required date observedFrom, required date observedBefore, required array unitIds, required numeric k) {
		var catalog = catalogFor(arguments.versionId);
		var reports = variables.reports;
		var itemIds = [];
		for (var it in catalog.items) arrayAppend(itemIds, it.itemId);
		for (var attempt = 1; attempt <= variables.MAX_ATTEMPTS; attempt++) {
			var population = reports.beginPopulation();
			reports.loadScope(population, arguments.unitIds);
			// S1: walk rows only, row versions captured. A walk an earlier release counted is never
			// a candidate again, wherever a correction has moved its date since (P7C-02).
			reports.selectCandidates(population, arguments.versionId, ["COMPLETED"], arguments.observedFrom, arguments.observedBefore, true);
			// S2: every aggregate reads child rows.
			var units = reports.unitStatusCounts(population);
			var dims = {};
			for (var d in catalog.dimensions) dims[d.code] = reports.unitDimensionCounts(population, d.dimensionId, d.visibility);
			var items = reports.unitItemCounts(population, itemIds);
			// S3: every walk still at the row version S1 captured, or this attempt is discarded.
			var moved = reports.verifyPopulation(population);
			var members = moved == 0 ? reports.populationWalks(population) : [];
			reports.endPopulation(population);
			if (moved == 0) return { "attempts": attempt, "blocks": withMembers(blocksFrom(catalog, units, dims, items, arguments.k), members) };
			variables.logger.warn("report.release.population.changed", { "versionId": arguments.versionId, "attempt": attempt, "moved": moved });
		}
		variables.errors.conflict(
			"Walks observed on those dates changed while the release was being prepared. Release them again.",
			"REPORT_POPULATION_CHANGED", { "attempts": variables.MAX_ATTEMPTS }
		);
	}

	/**
	 * Attaches to each kept block the walks it counts (the release's membership). A block whose
	 * count and walks disagree is a defect, and the database would refuse it too (50065).
	 */
	private array function withMembers(required array blocks, required array members) {
		var byUnit = {};
		for (var m in arguments.members) {
			if (!structKeyExists(byUnit, m.orgUnitId)) byUnit[m.orgUnitId] = [];
			arrayAppend(byUnit[m.orgUnitId], m.walkId);
		}
		for (var b in arguments.blocks) {
			b["walkIds"] = structKeyExists(byUnit, uCase(b.orgUnitId)) ? byUnit[uCase(b.orgUnitId)] : [];
			if (arrayLen(b.walkIds) != b.walks) {
				throw(type = "ICFWalk.Internal", message = "A release block's walks and its count disagree.", errorcode = "REPORT_RELEASE_MEMBERSHIP_MISMATCH");
			}
		}
		return arguments.blocks;
	}

	/**
	 * Turns per-unit aggregate rows into stored blocks: [{ orgUnitId, walks, cells[] }] for every
	 * unit with at least k walks. Cells are keyed by codes (see breakdownOf for the categories).
	 */
	private array function blocksFrom(required struct catalog, required array units, required struct dims, required array items, required numeric k) {
		var walksByUnit = {};
		for (var row in arguments.units) walksByUnit[row.orgUnitId] = (structKeyExists(walksByUnit, row.orgUnitId) ? walksByUnit[row.orgUnitId] : 0) + row.walks;
		var itemById = {};
		for (var it in arguments.catalog.items) itemById[it.itemId] = it;
		var cellsByUnit = {};
		var recorded = {};
		for (var row in arguments.items) {
			if (!structKeyExists(itemById, row.itemId) || !structKeyExists(walksByUnit, row.orgUnitId)) continue;
			var it = itemById[row.itemId];
			var category = { "type": "STATE", "code": row.state };
			if (row.state == "ANSWERED") {
				category = { "type": "STATE", "code": "ANSWERED_UNLISTED" };
				for (var o in it.options) if (compare(o.optionId, row.optionId) == 0) category = { "type": "OPTION", "code": o.code };
			}
			addCell(cellsByUnit, row.orgUnitId, "ITEM", it.itemKey, category.type, category.code, row.responses);
			var rk = row.orgUnitId & "|" & it.itemKey;
			recorded[rk] = (structKeyExists(recorded, rk) ? recorded[rk] : 0) + row.responses;
		}
		for (var unitId in structKeyArray(walksByUnit)) {
			for (var it in arguments.catalog.items) {
				var rk = unitId & "|" & it.itemKey;
				var missing = walksByUnit[unitId] - (structKeyExists(recorded, rk) ? recorded[rk] : 0);
				if (missing > 0) addCell(cellsByUnit, unitId, "ITEM", it.itemKey, "STATE", "UNRECORDED", missing);
			}
		}
		for (var d in arguments.catalog.dimensions) {
			for (var row in arguments.dims[d.code]) {
				if (!structKeyExists(walksByUnit, row.orgUnitId)) continue;
				if (!row.visible) addCell(cellsByUnit, row.orgUnitId, "DIMENSION", d.code, "STATE", "HIDDEN", row.walks);
				else if (len(row.valueId) && structKeyExists(d.valueById, row.valueId)) addCell(cellsByUnit, row.orgUnitId, "DIMENSION", d.code, "VALUE", d.valueById[row.valueId], row.walks);
				else addCell(cellsByUnit, row.orgUnitId, "DIMENSION", d.code, "STATE", "UNANSWERED", row.walks);
			}
		}
		var out = [];
		var unitIds = structKeyArray(walksByUnit);
		arraySort(unitIds, "text");
		for (var unitId in unitIds) {
			if (walksByUnit[unitId] < arguments.k) continue;
			var cells = [];
			if (structKeyExists(cellsByUnit, unitId)) {
				var keys = structKeyArray(cellsByUnit[unitId]);
				arraySort(keys, "text");
				for (var key in keys) arrayAppend(cells, cellsByUnit[unitId][key]);
			}
			arrayAppend(out, { "orgUnitId": unitId, "walks": walksByUnit[unitId], "cells": cells });
		}
		return out;
	}

	private void function addCell(required struct into, required string unitId, required string subjectType, required string subjectKey, required string categoryType, required string categoryCode, required numeric responses) {
		if (!structKeyExists(arguments.into, arguments.unitId)) arguments.into[arguments.unitId] = {};
		var key = arguments.subjectType & "|" & arguments.subjectKey & "|" & arguments.categoryType & "|" & arguments.categoryCode;
		var bucket = arguments.into[arguments.unitId];
		if (!structKeyExists(bucket, key)) {
			bucket[key] = { "subjectType": arguments.subjectType, "subjectKey": arguments.subjectKey, "categoryType": arguments.categoryType, "categoryCode": arguments.categoryCode, "responses": 0 };
		}
		bucket[key].responses += arguments.responses;
	}

	/** Releases for options: every release, with the versions it holds blocks of in the given units. */
	private array function releasesFor(required array unitIds) {
		var scope = unitSet(arguments.unitIds);
		var held = {};
		for (var b in variables.reports.releaseBlockIndex()) {
			if (!structKeyExists(scope, b.orgUnitId)) continue;
			if (!structKeyExists(held, b.releaseId)) held[b.releaseId] = {};
			held[b.releaseId][b.versionId] = true;
		}
		var versions = reportableVersions();
		var out = [];
		for (var r in variables.reports.listReleases()) {
			var ids = [];
			for (var v in versions) if (structKeyExists(held, r.releaseId) && structKeyExists(held[r.releaseId], v.versionId)) arrayAppend(ids, v.versionId);
			arrayAppend(out, releaseDto(r, ids));
		}
		return out;
	}

	private struct function releaseDto(required struct release, array versionIds) {
		var out = {
			"releaseId": arguments.release.releaseId, "observedFrom": arguments.release.observedFrom, "observedTo": arguments.release.observedTo,
			"minimumWalks": arguments.release.minimumWalks, "releasedAt": variables.json.formatDate(arguments.release.releasedAt)
		};
		if (!isNull(arguments.versionIds)) out["versionIds"] = arguments.versionIds;
		return out;
	}

	// ---- filters ----------------------------------------------------------------------------------

	/**
	 * Normalizes and validates the request against the caller's scope and the selected version.
	 * Unknown parameters are refused rather than ignored, so a misspelt filter can never silently
	 * widen a report to a population the caller did not ask for.
	 *
	 * The order is fixed: scope first (an out-of-scope unit is 404 whatever else the request says),
	 * then the kind of report -- a caller without walk.read on every unit in scope is refused live
	 * figures (REPORT_RELEASE_REQUIRED) -- then, for a released report, any parameter that would
	 * narrow who is counted (REPORT_FILTER_NOT_PERMITTED, before its value is even read).
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
			"includeDrafts": false, "statuses": ["COMPLETED"], "mode": "LIVE", "release": {}, "protected": false
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

		// Live or released: live figures only for a caller who can open every walk they would count.
		f.protected = isProtected(arguments.principal, f.unitIds);
		if (structKeyExists(named, "releaseId")) {
			if (!variables.db.isGuid(named.releaseId)) filterRefused("INVALID_RELEASE_ID", "releaseId", "releaseId is not a valid identifier.");
			f.release = variables.reports.findRelease(uCase(trim(named.releaseId)));
			if (structIsEmpty(f.release)) variables.errors.notFound("Report release not found.", "REPORT_RELEASE_NOT_FOUND");
			f.mode = "RELEASE";
		} else if (f.protected) {
			variables.errors.validation(
				"Reports for your scope come from released reporting dates. Choose a release.",
				"REPORT_RELEASE_REQUIRED", { "issues": [{ "parameter": "releaseId", "code": "REPORT_RELEASE_REQUIRED" }] }
			);
		}
		if (f.mode == "RELEASE") {
			var refused = [];
			for (var name in variables.LIVE_ONLY_PARAMS) if (structKeyExists(named, name)) arrayAppend(refused, { "parameter": name, "code": "REPORT_FILTER_NOT_PERMITTED" });
			var dimensionNames = structKeyArray(params.dimensions);
			arraySort(dimensionNames, "textnocase");
			for (var raw in dimensionNames) arrayAppend(refused, { "parameter": left(variables.DIMENSION_PREFIX & raw, 60), "code": "REPORT_FILTER_NOT_PERMITTED" });
			if (arrayLen(refused)) {
				variables.errors.validation("A released report is narrowed by version, school, section and question only.", "REPORT_FILTER_NOT_PERMITTED", { "issues": refused });
			}
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

	/** Whether a report over these units must come from a release: some unit's walks are not readable to the caller. */
	private boolean function isProtected(required struct principal, required array unitIds) {
		var readable = unitSet(variables.authz.visibleOrgUnitIds(arguments.principal, "walk.read"));
		for (var id in arguments.unitIds) if (!structKeyExists(readable, uCase(id))) return true;
		return false;
	}

	private struct function unitSet(required array ids) {
		var out = {};
		for (var id in arguments.ids) out[uCase(id)] = true;
		return out;
	}

	// ---- live computation -------------------------------------------------------------------------

	private struct function compute(required struct f) {
		var f = arguments.f;
		var reports = variables.reports;
		var catalog = f.catalog;
		var itemIds = [];
		for (var it in reportedItems(f)) arrayAppend(itemIds, it.itemId);
		for (var attempt = 1; attempt <= variables.MAX_ATTEMPTS; attempt++) {
			var outcome = variables.db.transact(function() {
				var population = reports.beginPopulation();
				var result = { "units": [], "dimensions": {}, "items": [], "moved": 0 };
				for (var d in catalog.dimensions) result.dimensions[d.code] = [];
				if (arrayLen(f.unitIds)) {
					reports.loadScope(population, f.unitIds);
					// S1: walk rows only, row versions captured.
					reports.selectCandidates(population, f.version.versionId, f.statuses, f.observedFrom, f.observedBefore);
					// S2: population filters and every aggregate read child rows.
					for (var df in f.dimensionFilters) reports.restrictToDimensionValue(population, df.dimension.dimensionId, df.value.valueId, df.dimension.visibility);
					if (!structIsEmpty(f.optionFilter)) reports.restrictToOption(population, f.optionFilter.itemId, f.optionFilter.optionId);
					result.units = reports.unitStatusCounts(population);
					for (var d in catalog.dimensions) result.dimensions[d.code] = reports.dimensionCounts(population, d.dimensionId, d.visibility);
					result.items = reports.itemCounts(population, itemIds);
					// S3: every walk still at the row version S1 captured, or the report is discarded.
					result.moved = reports.verifyPopulation(population);
				}
				reports.endPopulation(population);
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

	/** The report envelope both kinds share; the figures are filled in by the caller. */
	private struct function shell(required struct f, required numeric attempts) {
		return {
			"format": variables.FORMAT,
			"generatedAt": variables.json.formatDate(now()),
			"mode": arguments.f.mode,
			"release": arguments.f.mode == "RELEASE" ? releaseDto(arguments.f.release) : javaCast("null", ""),
			"version": arguments.f.version,
			"filters": filterEcho(arguments.f),
			"filterCount": filterCount(arguments.f),
			"scope": { "orgUnitCount": arrayLen(arguments.f.unitIds) },
			"disclosure": { "minimumWalks": arguments.f.mode == "RELEASE" ? arguments.f.release.minimumWalks : minimumWalks(), "protected": arguments.f.protected ? true : false },
			"population": { "walks": 0, "byStatus": {}, "withheld": false },
			"orgUnits": [], "dimensions": [], "sections": [], "items": [],
			"attempts": arguments.attempts
		};
	}

	/**
	 * A live report: every figure as counted. Reached only by a caller who can open every walk the
	 * report counts (parseFilters), so nothing is withheld.
	 */
	private struct function liveReport(required struct f) {
		var f = arguments.f;
		var raw = compute(f);
		var catalog = f.catalog;
		var report = shell(f, raw.attempts);
		var total = 0;
		var byStatus = {};
		var byUnit = {};
		for (var row in raw.units) {
			total += row.walks;
			byStatus[row.status] = (structKeyExists(byStatus, row.status) ? byStatus[row.status] : 0) + row.walks;
			byUnit[row.orgUnitId] = (structKeyExists(byUnit, row.orgUnitId) ? byUnit[row.orgUnitId] : 0) + row.walks;
		}
		report.population = { "walks": total, "byStatus": byStatus, "withheld": false };
		report.orgUnits = unitDtos(byUnit);

		for (var d in catalog.dimensions) arrayAppend(report.dimensions, liveDimensionDto(d, raw.dimensions[d.code]));

		// Items: state counts, the ANSWERED distribution, and item-level scores.
		var counts = {};
		for (var row in raw.items) {
			if (!structKeyExists(counts, row.itemId)) counts[row.itemId] = { "states": {}, "options": {} };
			var c = counts[row.itemId];
			c.states[row.state] = (structKeyExists(c.states, row.state) ? c.states[row.state] : 0) + row.responses;
			if (row.state == "ANSWERED" && len(row.optionId)) c.options[row.optionId] = (structKeyExists(c.options, row.optionId) ? c.options[row.optionId] : 0) + row.responses;
		}
		var pooled = {};
		for (var it in reportedItems(f)) {
			var dto = liveItemDto(it, structKeyExists(counts, it.itemId) ? counts[it.itemId] : { "states": {}, "options": {} }, total, pooled);
			arrayAppend(report.items, dto);
		}
		report.sections = sectionDtos(f, pooled, 0);
		return report;
	}

	private array function unitDtos(required struct byUnit) {
		var tree = variables.orgUnits.loadActiveTree();
		var out = [];
		for (var unitId in structKeyArray(arguments.byUnit)) {
			var u = structKeyExists(tree, unitId) ? tree[unitId] : { "code": "", "name": "", "type": "" };
			arrayAppend(out, { "orgUnitId": unitId, "code": u.code, "name": u.name, "type": u.type, "walks": arguments.byUnit[unitId] });
		}
		arraySort(out, function(a, b) {
			var byType = compare(typeRank(a.type), typeRank(b.type));
			return byType != 0 ? byType : compareNoCase(a.name, b.name);
		});
		return out;
	}

	private struct function liveDimensionDto(required struct d, required array rows) {
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
			arrayAppend(values, { "code": v.code, "label": v.label, "walks": structKeyExists(byValue, v.valueId) ? byValue[v.valueId] : 0, "withheld": false });
		}
		return { "code": arguments.d.code, "label": arguments.d.label, "states": states, "withheldStates": [], "withheldResponses": 0, "values": values };
	}

	/** One live item. Records its scored responses and exact sum in `pooled` for the sections. */
	private struct function liveItemDto(required struct it, required struct counts, required numeric total, required struct pooled) {
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
			arrayAppend(options, { "code": o.code, "label": o.label, "numericScore": o.scored ? o.numericScore : javaCast("null", ""), "isNa": o.isNa, "count": n, "withheld": false });
			if (arguments.it.scored && o.scored && n > 0) {
				responses += n;
				sum = sum.add(variables.BigDecimal.init(toString(o.numericScore)).multiply(variables.BigDecimal.valueOf(javaCast("long", n))));
			}
		}
		arguments.pooled[arguments.it.itemKey] = { "scored": arguments.it.scored, "responses": responses, "sum": sum, "withheld": false };
		var dto = itemHeader(arguments.it);
		dto["states"] = states;
		dto["withheldStates"] = [];
		dto["withheldResponses"] = 0;
		dto["options"] = options;
		dto["scored"] = arguments.it.scored ? scoredDto(responses, sum, false, 0) : javaCast("null", "");
		return dto;
	}

	/**
	 * Sections pooled over every reported scored response beneath them: `pooled` holds each reported
	 * item's scored responses and exact sum (the published part, in a release). k > 0 withholds a
	 * section mean resting on fewer than k published responses.
	 */
	private array function sectionDtos(required struct f, required struct pooled, required numeric k) {
		var out = [];
		for (var s in arguments.f.catalog.sections) {
			var keys = [];
			for (var key in s.subtreeItemKeys) if (structKeyExists(arguments.pooled, key)) arrayAppend(keys, key);
			if (!arrayLen(keys)) continue;
			var own = [];
			for (var key in s.itemKeys) if (structKeyExists(arguments.pooled, key)) arrayAppend(own, key);
			var responses = 0;
			var sum = variables.BigDecimal.ZERO;
			var anyScored = false;
			var partial = false;
			for (var key in keys) {
				var p = arguments.pooled[key];
				if (!p.scored) continue;
				anyScored = true;
				responses += p.responses;
				sum = sum.add(p.sum);
				if (p.withheld) partial = true;
			}
			arrayAppend(out, {
				"sectionKey": s.sectionKey, "title": s.title, "parentSectionKey": len(s.parentSectionKey) ? s.parentSectionKey : javaCast("null", ""),
				"depth": s.depth, "itemKeys": own, "scored": anyScored ? scoredDto(responses, sum, partial, arguments.k) : javaCast("null", "")
			});
		}
		return out;
	}

	// ---- released reports -------------------------------------------------------------------------

	/**
	 * A report read from a release. For every stored block in the caller's scope, every breakdown of
	 * the version -- all of them, whatever the section or question selected, so a block publishes
	 * the same cells in every report that reads it -- is protected on its own (DisclosureControl
	 * .suppress) or, when instrument rules link it to another breakdown, together with its group.
	 * The published cells are then added up across blocks. A category withheld in some block
	 * carries withheld: true, and its count is the published part (a lower bound) or null when no
	 * block published any of it. Scores and derived totals are computed from published cells only.
	 */
	private struct function releaseReport(required struct f) {
		var f = arguments.f;
		var k = f.release.minimumWalks;
		var catalog = f.catalog;
		var report = shell(f, 1);
		var scope = unitSet(f.unitIds);
		var blocks = [];
		for (var b in variables.reports.releaseBlocks(f.release.releaseId, f.version.versionId)) {
			if (structKeyExists(scope, b.orgUnitId) && b.walks >= k) arrayAppend(blocks, b);
		}
		if (!arrayLen(blocks)) {
			// No block at all, or only blocks that never met the minimum: identical either way.
			report.population = { "walks": javaCast("null", ""), "byStatus": {}, "withheld": true };
			return report;
		}
		var blockIds = [];
		for (var b in blocks) arrayAppend(blockIds, b.orgUnitId);
		var stored = {};
		for (var c in variables.reports.releaseCells(f.release.releaseId, f.version.versionId, blockIds)) {
			if (!structKeyExists(stored, c.orgUnitId)) stored[c.orgUnitId] = {};
			var subject = c.subjectType & ":" & c.subjectKey;
			if (!structKeyExists(stored[c.orgUnitId], subject)) stored[c.orgUnitId][subject] = {};
			stored[c.orgUnitId][subject][c.categoryType & ":" & c.categoryCode] = c.responses;
		}
		var subjects = breakdownsOf(catalog);
		var totals = {};
		var total = 0;
		var byUnit = {};
		for (var b in blocks) {
			total += b.walks;
			byUnit[b.orgUnitId] = b.walks;
			var cells = structKeyExists(stored, b.orgUnitId) ? stored[b.orgUnitId] : {};
			publishBlock(subjects, cells, catalog.linkGroups, k, totals);
		}
		report.population = { "walks": total, "byStatus": { "COMPLETED": total }, "withheld": false };
		report.orgUnits = unitDtos(byUnit);
		for (var d in catalog.dimensions) arrayAppend(report.dimensions, releasedDimensionDto(d, totalsOf(totals, "DIMENSION:" & d.code), total));
		var pooled = {};
		for (var it in reportedItems(f)) arrayAppend(report.items, releasedItemDto(it, totalsOf(totals, "ITEM:" & it.itemKey), total, k, pooled));
		report.sections = sectionDtos(f, pooled, k);
		return report;
	}

	/**
	 * Every breakdown of a version in a fixed order, each with its fixed categories: an item's
	 * options then UNANSWERED, HIDDEN, NOT_APPLICABLE, UNRECORDED; a dimension's values then
	 * UNANSWERED, HIDDEN. Category keys are "OPTION:<code>", "VALUE:<code>", "STATE:<state>".
	 */
	private array function breakdownsOf(required struct catalog) {
		var out = [];
		for (var it in arguments.catalog.items) {
			var categories = [];
			for (var o in it.options) arrayAppend(categories, "OPTION:" & o.code);
			for (var s in variables.ITEM_STATE_CATEGORIES) arrayAppend(categories, "STATE:" & s);
			arrayAppend(out, { "id": "ITEM:" & it.itemKey, "categories": categories });
		}
		for (var d in arguments.catalog.dimensions) {
			var categories = [];
			for (var v in d.values) arrayAppend(categories, "VALUE:" & v.code);
			for (var s in variables.DIMENSION_STATE_CATEGORIES) arrayAppend(categories, "STATE:" & s);
			arrayAppend(out, { "id": "DIMENSION:" & d.code, "categories": categories });
		}
		return out;
	}

	/**
	 * Protects every breakdown of one block and adds what it publishes to `totals`:
	 * totals[subject][category] = { sum (published walks), withheld (withheld in some block) }.
	 * A stored category the version no longer names (a DRAFT re-imported after the release) joins
	 * its breakdown after the fixed ones, so the breakdown still adds up; it is never shown.
	 */
	private void function publishBlock(required array subjects, required struct cells, required struct linkGroups, required numeric k, required struct totals) {
		var prepared = [];
		var primaryGroups = {};
		for (var s in arguments.subjects) {
			var stored = structKeyExists(arguments.cells, s.id) ? arguments.cells[s.id] : {};
			var keys = duplicate(s.categories);
			var extras = [];
			for (var key in structKeyArray(stored)) if (!arrayContains(keys, key)) arrayAppend(extras, key);
			arraySort(extras, "text");
			for (var key in extras) arrayAppend(keys, key);
			var counts = [];
			for (var key in keys) arrayAppend(counts, structKeyExists(stored, key) ? stored[key] : 0);
			arrayAppend(prepared, { "id": s.id, "keys": keys, "counts": counts });
			if (structKeyExists(arguments.linkGroups, s.id) && variables.disclosure.anyPrimary(counts, arguments.k)) primaryGroups[arguments.linkGroups[s.id]] = true;
		}
		for (var p in prepared) {
			var decision = {};
			if (structKeyExists(arguments.linkGroups, p.id)) {
				decision = structKeyExists(primaryGroups, arguments.linkGroups[p.id]) ? variables.disclosure.withholdAll(arrayLen(p.counts)) : variables.disclosure.publishAll(arrayLen(p.counts));
			} else {
				decision = variables.disclosure.suppress(p.counts, arguments.k);
			}
			if (!structKeyExists(arguments.totals, p.id)) arguments.totals[p.id] = {};
			var into = arguments.totals[p.id];
			for (var i = 1; i <= arrayLen(p.keys); i++) {
				var key = p.keys[i];
				if (!structKeyExists(into, key)) into[key] = { "sum": 0, "withheld": false };
				if (decision.withheld[i]) into[key].withheld = true;
				else into[key].sum += p.counts[i];
			}
		}
	}

	private struct function totalsOf(required struct totals, required string subject) {
		return structKeyExists(arguments.totals, arguments.subject) ? arguments.totals[arguments.subject] : {};
	}

	/** A released figure: the published part, null when withheld and nothing of it was published. */
	private any function publishedCount(required struct totals, required string key) {
		if (!structKeyExists(arguments.totals, arguments.key)) return 0;
		var t = arguments.totals[arguments.key];
		if (t.withheld && t.sum == 0) return javaCast("null", "");
		return t.sum;
	}

	private boolean function isWithheld(required struct totals, required string key) {
		return structKeyExists(arguments.totals, arguments.key) && arguments.totals[arguments.key].withheld;
	}

	/** Adds up published parts of the categories whose key starts with `prefix`; withheld if any is. */
	private struct function publishedSum(required struct totals, required string prefix) {
		var sum = 0;
		var withheld = false;
		for (var key in structKeyArray(arguments.totals)) {
			if (left(key, len(arguments.prefix)) != arguments.prefix) continue;
			sum += arguments.totals[key].sum;
			if (arguments.totals[key].withheld) withheld = true;
		}
		return { "count": (withheld && sum == 0) ? javaCast("null", "") : sum, "withheld": withheld };
	}

	private struct function releasedDimensionDto(required struct d, required struct totals, required numeric population) {
		var shown = 0;
		var values = [];
		for (var v in arguments.d.values) {
			var key = "VALUE:" & v.code;
			var count = publishedCount(arguments.totals, key);
			arrayAppend(values, { "code": v.code, "label": v.label, "walks": isNull(count) ? javaCast("null", "") : count, "withheld": isWithheld(arguments.totals, key) });
			if (!isNull(count)) shown += count;
		}
		var answered = publishedSum(arguments.totals, "VALUE:");
		var states = { "ANSWERED": isNull(answered.count) ? javaCast("null", "") : answered.count };
		var withheldStates = answered.withheld ? ["ANSWERED"] : [];
		for (var s in variables.DIMENSION_STATE_CATEGORIES) {
			var count = publishedCount(arguments.totals, "STATE:" & s);
			states[s] = isNull(count) ? javaCast("null", "") : count;
			if (!isNull(count)) shown += count;
			if (isWithheld(arguments.totals, "STATE:" & s)) arrayAppend(withheldStates, s);
		}
		return {
			"code": arguments.d.code, "label": arguments.d.label, "states": states, "withheldStates": withheldStates,
			"withheldResponses": arguments.population - shown, "values": values
		};
	}

	private struct function releasedItemDto(required struct it, required struct totals, required numeric population, required numeric k, required struct pooled) {
		var shown = 0;
		var options = [];
		var responses = 0;
		var sum = variables.BigDecimal.ZERO;
		var scoredWithheld = false;
		for (var o in arguments.it.options) {
			var key = "OPTION:" & o.code;
			var count = publishedCount(arguments.totals, key);
			var withheld = isWithheld(arguments.totals, key);
			arrayAppend(options, { "code": o.code, "label": o.label, "numericScore": o.scored ? o.numericScore : javaCast("null", ""), "isNa": o.isNa, "count": isNull(count) ? javaCast("null", "") : count, "withheld": withheld });
			if (!isNull(count)) shown += count;
			if (arguments.it.scored && o.scored) {
				if (withheld) scoredWithheld = true;
				if (!isNull(count) && count > 0) {
					responses += count;
					sum = sum.add(variables.BigDecimal.init(toString(o.numericScore)).multiply(variables.BigDecimal.valueOf(javaCast("long", count))));
				}
			}
		}
		// ANSWERED is every answered response: the options, plus any answer the version no longer lists.
		var answered = publishedSum(arguments.totals, "OPTION:");
		var unlisted = publishedSum(arguments.totals, "STATE:ANSWERED_UNLISTED");
		var answeredCount = (isNull(answered.count) ? 0 : answered.count) + (isNull(unlisted.count) ? 0 : unlisted.count);
		var answeredWithheld = answered.withheld || unlisted.withheld;
		var states = { "ANSWERED": (answeredWithheld && answeredCount == 0) ? javaCast("null", "") : answeredCount };
		var withheldStates = answeredWithheld ? ["ANSWERED"] : [];
		for (var s in variables.ITEM_STATE_CATEGORIES) {
			var count = publishedCount(arguments.totals, "STATE:" & s);
			states[s] = isNull(count) ? javaCast("null", "") : count;
			if (!isNull(count)) shown += count;
			if (isWithheld(arguments.totals, "STATE:" & s)) arrayAppend(withheldStates, s);
		}
		arguments.pooled[arguments.it.itemKey] = { "scored": arguments.it.scored, "responses": responses, "sum": sum, "withheld": scoredWithheld };
		var dto = itemHeader(arguments.it);
		dto["states"] = states;
		dto["withheldStates"] = withheldStates;
		dto["withheldResponses"] = arguments.population - shown;
		dto["options"] = options;
		dto["scored"] = arguments.it.scored ? scoredDto(responses, sum, scoredWithheld, arguments.k) : javaCast("null", "");
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

	/**
	 * { responses, sum, mean, withheld }: mean = sum / responses to four places, null when nothing
	 * was scored. withheld = true means some rated responses were withheld and these figures are of
	 * the published ones only. With k > 0 (a release), fewer than k published rated responses
	 * withhold the figures themselves: all three are null. None at all is a true "nothing rated"
	 * only when nothing was withheld either.
	 */
	private struct function scoredDto(required numeric responses, required any sum, required boolean withheld, required numeric k) {
		if (arguments.k > 0 && (arguments.responses > 0 ? arguments.responses < arguments.k : arguments.withheld)) {
			return { "responses": javaCast("null", ""), "sum": javaCast("null", ""), "mean": javaCast("null", ""), "withheld": true };
		}
		var mean = javaCast("null", "");
		if (arguments.responses > 0) {
			mean = val(arguments.sum.divide(variables.BigDecimal.valueOf(javaCast("long", arguments.responses)), javaCast("int", 4), variables.HALF_UP).toPlainString());
		}
		return { "responses": arguments.responses, "sum": val(arguments.sum.toPlainString()), "mean": isNull(mean) ? javaCast("null", "") : mean, "withheld": arguments.withheld };
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
	 *   linkGroups  which reportable breakdowns an instrument rule ties together (see linkGroupsOf).
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
		catalog["linkGroups"] = linkGroupsOf(model, catalog);
		variables.catalogCache[cacheKey] = catalog;
		return catalog;
	}

	private void function collect(required struct node, required string parentKey, required numeric depth, required array ancestry, required struct catalog, required struct model, required struct index) {
		var n = arguments.node;
		var path = duplicate(arguments.ancestry);
		arrayAppend(path, n.sectionKey);
		var section = { "sectionKey": n.sectionKey, "title": n.title, "parentSectionKey": arguments.parentKey, "depth": arguments.depth, "itemKeys": [], "subtreeItemKeys": [], "subtreeDimensionCodes": [] };
		arrayAppend(arguments.catalog.sections, section);
		arguments.catalog.sectionIndex[n.sectionKey] = section;
		for (var p in n.placements) {
			var dim = dimensionEntry(p, path, arguments.model, arguments.index);
			if (structIsEmpty(dim)) continue;
			arrayAppend(arguments.catalog.dimensions, dim);
			for (var key in path) arrayAppend(arguments.catalog.sectionIndex[key].subtreeDimensionCodes, dim.code);
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

	/**
	 * Which reportable breakdowns an instrument rule ties together, as { "ITEM:<key>" |
	 * "DIMENSION:<code>": group } for every breakdown in a group of two or more.
	 *
	 * A rule's target and every source its conditions read are linked; a SECTION target links every
	 * reportable item and dimension beneath it. Links are transitive, and a source that is not itself
	 * reported still links the breakdowns it governs (two items hidden by the same unreported answer
	 * have equal HIDDEN counts). Linked breakdowns are protected as a group in a release
	 * (DisclosureControl, "LINKED BREAKDOWNS"): the rule makes one's states a sum of the other's
	 * cells, so they cannot be suppressed independently. Every rule counts, whatever its effect --
	 * over-linking only withholds more.
	 */
	private struct function linkGroupsOf(required struct model, required struct catalog) {
		var parent = {};
		for (var r in arguments.model.rules) {
			var nodes = [];
			var targetType = uCase(r.targetType);
			if (targetType == "SECTION") {
				arrayAppend(nodes, "SECTION:" & r.targetKey);
				if (structKeyExists(arguments.catalog.sectionIndex, r.targetKey)) {
					for (var key in arguments.catalog.sectionIndex[r.targetKey].subtreeItemKeys) arrayAppend(nodes, "ITEM:" & key);
					for (var code in arguments.catalog.sectionIndex[r.targetKey].subtreeDimensionCodes) arrayAppend(nodes, "DIMENSION:" & code);
				}
			} else {
				arrayAppend(nodes, targetType & ":" & r.targetKey);
			}
			var conds = (structKeyExists(r, "conditions") && isStruct(r.conditions) && structKeyExists(r.conditions, "conditions")) ? r.conditions.conditions : [];
			for (var c in conds) arrayAppend(nodes, uCase(c.sourceType) & ":" & c.sourceKey);
			for (var i = 2; i <= arrayLen(nodes); i++) {
				var a = rootOf(parent, nodes[1]);
				var b = rootOf(parent, nodes[i]);
				if (compare(a, b) != 0) parent[b] = a;
			}
		}
		var members = {};
		var subjects = [];
		for (var it in arguments.catalog.items) arrayAppend(subjects, "ITEM:" & it.itemKey);
		for (var d in arguments.catalog.dimensions) arrayAppend(subjects, "DIMENSION:" & d.code);
		for (var subject in subjects) {
			var root = rootOf(parent, subject);
			if (!structKeyExists(members, root)) members[root] = [];
			arrayAppend(members[root], subject);
		}
		var out = {};
		for (var root in structKeyArray(members)) {
			if (arrayLen(members[root]) < 2) continue;
			for (var subject in members[root]) out[subject] = root;
		}
		return out;
	}

	private string function rootOf(required struct parent, required string node) {
		var x = arguments.node;
		while (structKeyExists(arguments.parent, x) && compare(arguments.parent[x], x) != 0) x = arguments.parent[x];
		return x;
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
			"releaseId": arguments.f.mode == "RELEASE" ? arguments.f.release.releaseId : javaCast("null", ""),
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

	/** A figure as a CSV cell: empty when it is null (withheld, or not applicable). */
	private string function cell(required struct holder, required string key) {
		if (!structKeyExists(arguments.holder, arguments.key) || isNull(arguments.holder[arguments.key])) return "";
		return num(arguments.holder[arguments.key]);
	}

	/** [responses, sum, mean, withheld] cells of a section or item row; empty and "0" when it is not scored. */
	private array function scoredCells(required struct row) {
		if (isNull(arguments.row.scored)) return ["", "", "", "0"];
		return [cell(arguments.row.scored, "responses"), cell(arguments.row.scored, "sum"), cell(arguments.row.scored, "mean"), flag(arguments.row.scored.withheld)];
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
