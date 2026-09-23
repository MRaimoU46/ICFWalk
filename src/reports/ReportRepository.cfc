/**
 * Data access for aggregate reporting (Phase 7). Every statement is parameterized through
 * core/Db; nothing is concatenated from input except placeholders this component generates itself.
 *
 * WHAT THIS COMPONENT MAY READ, AND WHAT IT MAY NOT. It reads walk headers (id, org unit, status,
 * version, observation instant, row version), the *identity* of selected dimension values, and
 * the *state and selected option* of item responses. It never selects a narrative or identifying
 * column: no walk_response.text_value, no walk_dimension_value.text_value (the Observer name, the
 * lesson standard, "Other" text), no teacher_identifier, teacher_display_name, teacher_email,
 * classroom_label, owner_user_id, void_reason, and nothing from app_user. That is enforced
 * structurally, not by review: tests/node/reports.test.mjs scans this file and fails if any of
 * those names appears in it. What leaves this component is counts keyed by identifiers.
 *
 * RELEASES. It also writes and reads the frozen report releases of migration 007 (see "Releases"
 * below): counts per (release, version, org unit) block, keyed by instrument codes. They carry no
 * walk id and are never updated or deleted here.
 *
 * THE POPULATION. A report is computed over a population of walks materialized once, in a
 * session-local temporary table, and every aggregate joins that one table. The caller runs the
 * whole sequence inside one Db.transact so every statement uses the same connection (the temporary
 * tables are per-connection); the transaction is READ COMMITTED and takes no lock a writer waits
 * on, so a report never blocks autosave.
 *
 * COHERENCE. Each walk's row version is captured when the population is selected -- from the walk
 * row alone, before any child row is read -- and verified again after every aggregate has been
 * read (verifyPopulation). Every mutation path (create, save, complete, void) updates the walk row
 * in the same transaction as its child writes, so any mutation that committed between those two
 * reads moved that walk's row version. A report whose verification finds a moved walk has read at
 * least one walk across two committed states, and the caller discards it and runs again.
 *
 * Statement order matters to that argument and is fixed by ReportService: selectCandidates first
 * (walk rows only), then the population filters and every aggregate (child rows), then
 * verifyPopulation.
 */
component output="false" {

	variables.POP = "##icf_report_population";
	variables.UNITS = "##icf_report_units";
	variables.UNIT_BATCH = 500;
	variables.CELL_BATCH = 250;

	public ReportRepository function init(required any db) {
		variables.db = arguments.db;
		return this;
	}

	// ---- versions --------------------------------------------------------------------------------

	/**
	 * Versions of one instrument whose walks can be reported on: PUBLISHED and RETIRED versions
	 * carry a frozen snapshot. A DRAFT is never listed here; the service adds the current version
	 * itself, which outside production may be the DRAFT preview walks were created against.
	 */
	public array function listFrozenVersions(required string instrumentCode) {
		var q = variables.db.run(
			"SELECT v.version_id, v.version_label, v.status, v.published_at, v.effective_start
			   FROM [icf].[instrument_version] v
			   JOIN [icf].[instrument] i ON i.instrument_id = v.instrument_id
			  WHERE i.code = :code
			    AND v.status IN (N'PUBLISHED', N'RETIRED')
			    AND v.compiled_snapshot_json IS NOT NULL
			  ORDER BY v.effective_start DESC, v.published_at DESC, v.created_at DESC",
			{ "code": variables.db.nvarchar(arguments.instrumentCode, 60) }
		);
		var out = [];
		for (var r = 1; r <= q.recordCount; r++) {
			arrayAppend(out, { "versionId": uCase(q.version_id[r]), "versionLabel": q.version_label[r], "status": q.status[r] });
		}
		return out;
	}

	// ---- the population --------------------------------------------------------------------------

	/** Creates (or recreates) the session's population and scope tables. */
	public void function beginPopulation() {
		variables.db.run(
			"IF OBJECT_ID(N'tempdb.." & variables.POP & "') IS NOT NULL DROP TABLE " & variables.POP & ";
			 IF OBJECT_ID(N'tempdb.." & variables.UNITS & "') IS NOT NULL DROP TABLE " & variables.UNITS & ";
			 CREATE TABLE " & variables.UNITS & " (org_unit_id uniqueidentifier NOT NULL PRIMARY KEY);
			 CREATE TABLE " & variables.POP & " (
			     walk_id uniqueidentifier NOT NULL PRIMARY KEY,
			     org_unit_id uniqueidentifier NOT NULL,
			     status nvarchar(20) NOT NULL,
			     rv binary(8) NOT NULL
			 );"
		);
	}

	public void function endPopulation() {
		variables.db.run(
			"IF OBJECT_ID(N'tempdb.." & variables.POP & "') IS NOT NULL DROP TABLE " & variables.POP & ";
			 IF OBJECT_ID(N'tempdb.." & variables.UNITS & "') IS NOT NULL DROP TABLE " & variables.UNITS & ";"
		);
	}

	/** Loads the authorized org units the report may draw walks from. */
	public void function loadScope(required array orgUnitIds) {
		var ids = arguments.orgUnitIds;
		var n = arrayLen(ids);
		var start = 1;
		while (start <= n) {
			var stop = min(n, start + variables.UNIT_BATCH - 1);
			var rows = [];
			var params = {};
			for (var i = start; i <= stop; i++) {
				arrayAppend(rows, "(:u" & i & ")");
				params["u" & i] = variables.db.guid(ids[i]);
			}
			variables.db.run("INSERT INTO " & variables.UNITS & " (org_unit_id) VALUES " & arrayToList(rows, ", "), params);
			start = stop + 1;
		}
	}

	/**
	 * S1. Selects the candidate walks from walk rows alone -- version, scope, status, observation
	 * window -- and captures each one's row version. Reads no child row. Returns the count.
	 * observedFrom and observedBefore are dates or "" (no bound); observedBefore is exclusive.
	 */
	public numeric function selectCandidates(required string versionId, required array statuses, any observedFrom = "", any observedBefore = "") {
		var params = { "version": variables.db.guid(arguments.versionId) };
		var names = [];
		for (var i = 1; i <= arrayLen(arguments.statuses); i++) {
			arrayAppend(names, ":s" & i);
			params["s" & i] = variables.db.nvarchar(arguments.statuses[i], 20);
		}
		var where = "w.version_id = :version AND w.status IN (" & arrayToList(names, ", ") & ")";
		if (isDate(arguments.observedFrom)) {
			where &= " AND w.observed_at >= :observedFrom";
			params["observedFrom"] = variables.db.timestamp(arguments.observedFrom);
		}
		if (isDate(arguments.observedBefore)) {
			where &= " AND w.observed_at < :observedBefore";
			params["observedBefore"] = variables.db.timestamp(arguments.observedBefore);
		}
		variables.db.run(
			"INSERT INTO " & variables.POP & " (walk_id, org_unit_id, status, rv)
			 SELECT w.walk_id, w.org_unit_id, w.status, CAST(w.row_version AS binary(8))
			   FROM [icf].[walk] w
			   JOIN " & variables.UNITS & " u ON u.org_unit_id = w.org_unit_id
			  WHERE " & where,
			params
		);
		return populationSize();
	}

	public numeric function populationSize() {
		return variables.db.scalar("SELECT COUNT(*) AS n FROM " & variables.POP);
	}

	/**
	 * Keeps only walks whose dimension carries the given value AND whose dimension is visible under
	 * the given visibility condition (see visibilitySql). A hidden retained value never matches.
	 */
	public void function restrictToDimensionValue(required string dimensionId, required string valueId, required struct visibility) {
		var params = { "dimension": variables.db.guid(arguments.dimensionId), "value": variables.db.guid(arguments.valueId) };
		var vis = visibilitySql(arguments.visibility, "p", params);
		variables.db.run(
			"DELETE p FROM " & variables.POP & " p
			  WHERE NOT EXISTS (SELECT 1 FROM [icf].[walk_dimension_value] x
			                     WHERE x.walk_id = p.walk_id AND x.dimension_id = :dimension AND x.selected_value_id = :value)
			     OR NOT (" & vis & ")",
			params
		);
	}

	/** Keeps only walks whose response to the item is ANSWERED with the given option. */
	public void function restrictToOption(required string itemId, required string optionId) {
		variables.db.run(
			"DELETE p FROM " & variables.POP & " p
			  WHERE NOT EXISTS (SELECT 1 FROM [icf].[walk_response] r
			                     WHERE r.walk_id = p.walk_id AND r.item_id = :item
			                       AND r.response_state = N'ANSWERED' AND r.selected_option_id = :option)",
			{ "item": variables.db.guid(arguments.itemId), "option": variables.db.guid(arguments.optionId) }
		);
	}

	// ---- aggregates -------------------------------------------------------------------------------

	/** [{ orgUnitId, status, walks }] over the population. */
	public array function unitStatusCounts() {
		var q = variables.db.run("SELECT p.org_unit_id, p.status, COUNT(*) AS n FROM " & variables.POP & " p GROUP BY p.org_unit_id, p.status");
		var out = [];
		for (var r = 1; r <= q.recordCount; r++) arrayAppend(out, { "orgUnitId": uCase(q.org_unit_id[r]), "status": q.status[r], "walks": q.n[r] });
		return out;
	}

	/**
	 * [{ visible, valueId, walks }] for one dimension over the population: every walk appears once,
	 * with whether the dimension is visible for it and which value (if any) it selected. The value
	 * identity is read; its text never is.
	 */
	public array function dimensionCounts(required string dimensionId, required struct visibility) {
		var params = { "dimension": variables.db.guid(arguments.dimensionId) };
		var vis = visibilitySql(arguments.visibility, "p", params);
		var q = variables.db.run(
			"SELECT t.visible, t.selected_value_id, COUNT(*) AS n
			   FROM (SELECT CASE WHEN " & vis & " THEN 1 ELSE 0 END AS visible, x.selected_value_id
			           FROM " & variables.POP & " p
			           LEFT JOIN [icf].[walk_dimension_value] x ON x.walk_id = p.walk_id AND x.dimension_id = :dimension) t
			  GROUP BY t.visible, t.selected_value_id",
			params
		);
		var out = [];
		for (var r = 1; r <= q.recordCount; r++) {
			arrayAppend(out, { "visible": q.visible[r] == 1, "valueId": len(q.selected_value_id[r]) ? uCase(q.selected_value_id[r]) : "", "walks": q.n[r] });
		}
		return out;
	}

	/**
	 * [{ itemId, state, optionId, responses }] for the given items over the population. The
	 * persisted response state is the server engine's own evaluation, written in the same
	 * transaction as the value it describes (Phase 4), so it is read rather than re-derived.
	 */
	public array function itemCounts(required array itemIds) {
		if (!arrayLen(arguments.itemIds)) return [];
		var names = [];
		var params = {};
		for (var i = 1; i <= arrayLen(arguments.itemIds); i++) {
			arrayAppend(names, ":i" & i);
			params["i" & i] = variables.db.guid(arguments.itemIds[i]);
		}
		var q = variables.db.run(
			"SELECT r.item_id, r.response_state, r.selected_option_id, COUNT(*) AS n
			   FROM " & variables.POP & " p
			   JOIN [icf].[walk_response] r ON r.walk_id = p.walk_id
			  WHERE r.item_id IN (" & arrayToList(names, ", ") & ")
			  GROUP BY r.item_id, r.response_state, r.selected_option_id",
			params
		);
		var out = [];
		for (var r = 1; r <= q.recordCount; r++) {
			arrayAppend(out, {
				"itemId": uCase(q.item_id[r]),
				"state": q.response_state[r],
				"optionId": len(q.selected_option_id[r]) ? uCase(q.selected_option_id[r]) : "",
				"responses": q.n[r]
			});
		}
		return out;
	}

	/**
	 * dimensionCounts, per org unit: [{ orgUnitId, visible, valueId, walks }]. Used when a release
	 * is created, because a release stores each block's breakdowns separately (see "Releases").
	 */
	public array function unitDimensionCounts(required string dimensionId, required struct visibility) {
		var params = { "dimension": variables.db.guid(arguments.dimensionId) };
		var vis = visibilitySql(arguments.visibility, "p", params);
		var q = variables.db.run(
			"SELECT t.org_unit_id, t.visible, t.selected_value_id, COUNT(*) AS n
			   FROM (SELECT p.org_unit_id, CASE WHEN " & vis & " THEN 1 ELSE 0 END AS visible, x.selected_value_id
			           FROM " & variables.POP & " p
			           LEFT JOIN [icf].[walk_dimension_value] x ON x.walk_id = p.walk_id AND x.dimension_id = :dimension) t
			  GROUP BY t.org_unit_id, t.visible, t.selected_value_id",
			params
		);
		var out = [];
		for (var r = 1; r <= q.recordCount; r++) {
			arrayAppend(out, { "orgUnitId": uCase(q.org_unit_id[r]), "visible": q.visible[r] == 1, "valueId": len(q.selected_value_id[r]) ? uCase(q.selected_value_id[r]) : "", "walks": q.n[r] });
		}
		return out;
	}

	/** itemCounts, per org unit: [{ orgUnitId, itemId, state, optionId, responses }]. */
	public array function unitItemCounts(required array itemIds) {
		if (!arrayLen(arguments.itemIds)) return [];
		var names = [];
		var params = {};
		for (var i = 1; i <= arrayLen(arguments.itemIds); i++) {
			arrayAppend(names, ":i" & i);
			params["i" & i] = variables.db.guid(arguments.itemIds[i]);
		}
		var q = variables.db.run(
			"SELECT p.org_unit_id, r.item_id, r.response_state, r.selected_option_id, COUNT(*) AS n
			   FROM " & variables.POP & " p
			   JOIN [icf].[walk_response] r ON r.walk_id = p.walk_id
			  WHERE r.item_id IN (" & arrayToList(names, ", ") & ")
			  GROUP BY p.org_unit_id, r.item_id, r.response_state, r.selected_option_id",
			params
		);
		var out = [];
		for (var r = 1; r <= q.recordCount; r++) {
			arrayAppend(out, {
				"orgUnitId": uCase(q.org_unit_id[r]),
				"itemId": uCase(q.item_id[r]),
				"state": q.response_state[r],
				"optionId": len(q.selected_option_id[r]) ? uCase(q.selected_option_id[r]) : "",
				"responses": q.n[r]
			});
		}
		return out;
	}

	/**
	 * S3. The number of population walks whose row changed (or disappeared) since selectCandidates
	 * captured it. Zero means every aggregate read above saw one committed state of every walk.
	 */
	public numeric function verifyPopulation() {
		return variables.db.scalar(
			"SELECT COUNT(*) AS n
			   FROM " & variables.POP & " p
			   LEFT JOIN [icf].[walk] w ON w.walk_id = p.walk_id
			  WHERE w.walk_id IS NULL OR CAST(w.row_version AS binary(8)) <> p.rv"
		);
	}

	// ---- releases ----------------------------------------------------------------------------------
	//
	// A release freezes one closed observation period for report-only users (migration 007). What is
	// stored is counts keyed by instrument codes -- per (version, org unit) block, per breakdown, per
	// category -- never a walk id. Period dates travel as YYYY-MM-DD text and are cast by SQL Server,
	// so no time zone can move a boundary. Nothing here updates or deletes a release.

	/**
	 * The versions that have COMPLETED walks observed in [observedFrom, observedBefore). Reads walk
	 * headers only; the release then selects each version's population the way a report does.
	 */
	public array function versionsWithCompletedWalks(required date observedFrom, required date observedBefore) {
		var q = variables.db.run(
			"SELECT DISTINCT w.version_id FROM [icf].[walk] w
			  WHERE w.status = N'COMPLETED' AND w.observed_at >= :observedFrom AND w.observed_at < :observedBefore",
			{ "observedFrom": variables.db.timestamp(arguments.observedFrom), "observedBefore": variables.db.timestamp(arguments.observedBefore) }
		);
		var out = [];
		for (var r = 1; r <= q.recordCount; r++) arrayAppend(out, uCase(q.version_id[r]));
		return out;
	}

	/**
	 * Serializes release creation: an exclusive application lock held until the caller's
	 * transaction ends, so two overlapping releases cannot both pass the overlap check.
	 * TR_report_release_no_overlap enforces the same rule in the database regardless.
	 */
	public void function lockReleases() {
		// The JDBC driver opens the caller's (implicit) transaction on its first statement that reads a
		// table, and a transaction-owned lock needs that transaction to exist, so read one first.
		var q = variables.db.run(
			"DECLARE @seen int, @result int;
			 SELECT @seen = COUNT(*) FROM [icf].[report_release] WHERE 1 = 0;
			 EXEC @result = sp_getapplock @Resource = N'icfwalk.report_release', @LockMode = N'Exclusive', @LockOwner = N'Transaction', @LockTimeout = 30000;
			 SELECT @result AS result, @@TRANCOUNT AS open_transactions;"
		);
		if (q.open_transactions[1] < 1) throw(type = "ICFWalk.Configuration", message = "Releases must be created inside a transaction.", errorcode = "REPORT_RELEASE_NO_TRANSACTION");
		if (q.result[1] < 0) throw(type = "ICFWalk.Conflict", message = "Another release is being created. Try again.", errorcode = "REPORT_RELEASE_BUSY");
	}

	public boolean function overlapsRelease(required string fromDay, required string toDay) {
		return variables.db.scalar(
			"SELECT COUNT(*) AS n FROM [icf].[report_release]
			  WHERE observed_from <= CAST(:toDay AS date) AND CAST(:fromDay AS date) <= observed_to",
			{ "fromDay": variables.db.nvarchar(arguments.fromDay, 10), "toDay": variables.db.nvarchar(arguments.toDay, 10) }
		) > 0;
	}

	public void function insertRelease(required string releaseId, required string fromDay, required string toDay, required numeric minimumWalks, required string releasedBy) {
		variables.db.run(
			"INSERT INTO [icf].[report_release] (release_id, observed_from, observed_to, minimum_walks, released_by_user_id)
			 VALUES (:id, CAST(:fromDay AS date), CAST(:toDay AS date), :minimum, :releasedBy)",
			{
				"id": variables.db.guid(arguments.releaseId), "fromDay": variables.db.nvarchar(arguments.fromDay, 10),
				"toDay": variables.db.nvarchar(arguments.toDay, 10), "minimum": variables.db.integer(arguments.minimumWalks),
				"releasedBy": variables.db.guid(arguments.releasedBy)
			}
		);
	}

	public void function insertBlock(required string releaseId, required string versionId, required string orgUnitId, required numeric walks) {
		variables.db.run(
			"INSERT INTO [icf].[report_release_block] (release_id, version_id, org_unit_id, walks) VALUES (:release, :version, :unit, :walks)",
			{ "release": variables.db.guid(arguments.releaseId), "version": variables.db.guid(arguments.versionId), "unit": variables.db.guid(arguments.orgUnitId), "walks": variables.db.integer(arguments.walks) }
		);
	}

	/** cells: [{ subjectType, subjectKey, categoryType, categoryCode, responses }], all for one block. */
	public void function insertCells(required string releaseId, required string versionId, required string orgUnitId, required array cells) {
		var n = arrayLen(arguments.cells);
		var start = 1;
		while (start <= n) {
			var stop = min(n, start + variables.CELL_BATCH - 1);
			var rows = [];
			var params = { "release": variables.db.guid(arguments.releaseId), "version": variables.db.guid(arguments.versionId), "unit": variables.db.guid(arguments.orgUnitId) };
			for (var i = start; i <= stop; i++) {
				var c = arguments.cells[i];
				arrayAppend(rows, "(:release, :version, :unit, :st" & i & ", :sk" & i & ", :ct" & i & ", :cc" & i & ", :n" & i & ")");
				params["st" & i] = variables.db.nvarchar(c.subjectType, 12);
				params["sk" & i] = variables.db.nvarchar(c.subjectKey, 100);
				params["ct" & i] = variables.db.nvarchar(c.categoryType, 12);
				params["cc" & i] = variables.db.nvarchar(c.categoryCode, 100);
				params["n" & i] = variables.db.integer(c.responses);
			}
			variables.db.run(
				"INSERT INTO [icf].[report_release_cell] (release_id, version_id, org_unit_id, subject_type, subject_key, category_type, category_code, responses)
				 VALUES " & arrayToList(rows, ", "),
				params
			);
			start = stop + 1;
		}
	}

	/** Every release, latest dates first: [{ releaseId, observedFrom, observedTo, minimumWalks, releasedAt }]. */
	public array function listReleases() {
		var q = variables.db.run(
			"SELECT release_id, CONVERT(char(10), observed_from, 23) AS observed_from, CONVERT(char(10), observed_to, 23) AS observed_to, minimum_walks, released_at
			   FROM [icf].[report_release] ORDER BY observed_from DESC"
		);
		var out = [];
		for (var r = 1; r <= q.recordCount; r++) arrayAppend(out, releaseRow(q, r));
		return out;
	}

	/** One release, or {} when there is none by that id. */
	public struct function findRelease(required string releaseId) {
		var q = variables.db.run(
			"SELECT release_id, CONVERT(char(10), observed_from, 23) AS observed_from, CONVERT(char(10), observed_to, 23) AS observed_to, minimum_walks, released_at
			   FROM [icf].[report_release] WHERE release_id = :id",
			{ "id": variables.db.guid(arguments.releaseId) }
		);
		return q.recordCount ? releaseRow(q, 1) : {};
	}

	/** Every stored block's identity: [{ releaseId, versionId, orgUnitId }]. No counts. */
	public array function releaseBlockIndex() {
		var q = variables.db.run("SELECT release_id, version_id, org_unit_id FROM [icf].[report_release_block]");
		var out = [];
		for (var r = 1; r <= q.recordCount; r++) arrayAppend(out, { "releaseId": uCase(q.release_id[r]), "versionId": uCase(q.version_id[r]), "orgUnitId": uCase(q.org_unit_id[r]) });
		return out;
	}

	/** The blocks one release stored for one version: [{ orgUnitId, walks }]. */
	public array function releaseBlocks(required string releaseId, required string versionId) {
		var q = variables.db.run(
			"SELECT org_unit_id, walks FROM [icf].[report_release_block] WHERE release_id = :release AND version_id = :version",
			{ "release": variables.db.guid(arguments.releaseId), "version": variables.db.guid(arguments.versionId) }
		);
		var out = [];
		for (var r = 1; r <= q.recordCount; r++) arrayAppend(out, { "orgUnitId": uCase(q.org_unit_id[r]), "walks": q.walks[r] });
		return out;
	}

	/** The cells of the named blocks: [{ orgUnitId, subjectType, subjectKey, categoryType, categoryCode, responses }]. */
	public array function releaseCells(required string releaseId, required string versionId, required array orgUnitIds) {
		var out = [];
		var ids = arguments.orgUnitIds;
		var n = arrayLen(ids);
		var start = 1;
		while (start <= n) {
			var stop = min(n, start + variables.UNIT_BATCH - 1);
			var names = [];
			var params = { "release": variables.db.guid(arguments.releaseId), "version": variables.db.guid(arguments.versionId) };
			for (var i = start; i <= stop; i++) {
				arrayAppend(names, ":u" & i);
				params["u" & i] = variables.db.guid(ids[i]);
			}
			var q = variables.db.run(
				"SELECT org_unit_id, subject_type, subject_key, category_type, category_code, responses
				   FROM [icf].[report_release_cell]
				  WHERE release_id = :release AND version_id = :version AND org_unit_id IN (" & arrayToList(names, ", ") & ")",
				params
			);
			for (var r = 1; r <= q.recordCount; r++) {
				arrayAppend(out, {
					"orgUnitId": uCase(q.org_unit_id[r]), "subjectType": q.subject_type[r], "subjectKey": q.subject_key[r],
					"categoryType": q.category_type[r], "categoryCode": q.category_code[r], "responses": q.responses[r]
				});
			}
			start = stop + 1;
		}
		return out;
	}

	private struct function releaseRow(required query q, required numeric r) {
		return {
			"releaseId": uCase(arguments.q.release_id[arguments.r]), "observedFrom": trim(arguments.q.observed_from[arguments.r]),
			"observedTo": trim(arguments.q.observed_to[arguments.r]), "minimumWalks": arguments.q.minimum_walks[arguments.r],
			"releasedAt": arguments.q.released_at[arguments.r]
		};
	}

	// ---- visibility --------------------------------------------------------------------------------

	/**
	 * Renders a visibility condition over population alias `alias`, adding its parameters to
	 * `params`. The condition is computed by ReportService from the instrument's own engine, never
	 * written here:
	 *
	 *   { mode: "ALWAYS" }                          visible for every walk
	 *   { mode: "NEVER" }                           visible for none
	 *   { mode: "TUPLES", sources: [dimensionId],   visible exactly when the walk's selected values of
	 *     tuples: [[valueId | ""]] }                the source dimensions equal one of the tuples
	 *                                               ("" = no value selected)
	 */
	public string function visibilitySql(required struct visibility, required string alias, required struct params) {
		var v = arguments.visibility;
		if (v.mode == "ALWAYS") return "1 = 1";
		if (v.mode == "NEVER" || !arrayLen(v.tuples)) return "1 = 0";
		var seq = structCount(arguments.params);
		if (arrayLen(v.sources) == 1) {
			// One source dimension (the usual case: Period follows Grade): an IN list, plus "no value"
			// when that is one of the visible tuples.
			seq++;
			var single = "vs" & seq;
			arguments.params[single] = variables.db.guid(v.sources[1]);
			var names = [];
			var noneVisible = false;
			for (var tuple in v.tuples) {
				if (!len(tuple[1])) { noneVisible = true; continue; }
				seq++;
				arrayAppend(names, ":vv" & seq);
				arguments.params["vv" & seq] = variables.db.guid(tuple[1]);
			}
			var parts = [];
			if (arrayLen(names)) arrayAppend(parts, "EXISTS (SELECT 1 FROM [icf].[walk_dimension_value] vx WHERE vx.walk_id = " & arguments.alias & ".walk_id AND vx.dimension_id = :" & single & " AND vx.selected_value_id IN (" & arrayToList(names, ", ") & "))");
			if (noneVisible) arrayAppend(parts, "NOT EXISTS (SELECT 1 FROM [icf].[walk_dimension_value] vx WHERE vx.walk_id = " & arguments.alias & ".walk_id AND vx.dimension_id = :" & single & " AND vx.selected_value_id IS NOT NULL)");
			return "(" & arrayToList(parts, " OR ") & ")";
		}
		var ors = [];
		for (var t = 1; t <= arrayLen(v.tuples); t++) {
			var ands = [];
			for (var s = 1; s <= arrayLen(v.sources); s++) {
				seq++;
				var srcName = "vs" & seq;
				arguments.params[srcName] = variables.db.guid(v.sources[s]);
				var valueId = v.tuples[t][s];
				if (len(valueId)) {
					seq++;
					var valName = "vv" & seq;
					arguments.params[valName] = variables.db.guid(valueId);
					arrayAppend(ands, "EXISTS (SELECT 1 FROM [icf].[walk_dimension_value] vx WHERE vx.walk_id = " & arguments.alias & ".walk_id AND vx.dimension_id = :" & srcName & " AND vx.selected_value_id = :" & valName & ")");
				} else {
					arrayAppend(ands, "NOT EXISTS (SELECT 1 FROM [icf].[walk_dimension_value] vx WHERE vx.walk_id = " & arguments.alias & ".walk_id AND vx.dimension_id = :" & srcName & " AND vx.selected_value_id IS NOT NULL)");
				}
			}
			arrayAppend(ors, "(" & arrayToList(ands, " AND ") & ")");
		}
		return "(" & arrayToList(ors, " OR ") & ")";
	}
}
