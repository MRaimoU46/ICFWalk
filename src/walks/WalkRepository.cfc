/**
 * Data access for the walk aggregate (icf.walk, walk_dimension_value, walk_response,
 * walk_revision, walk_mutation). Every statement is parameterized through core/Db. Row versions
 * are exchanged with clients as the SQL Server hex literal of the rowversion column
 * ("0x" + 16 hex digits) and compared in SQL with CONVERT(binary(8), :rv, 1), so no comparison
 * ever happens on the client's word alone.
 *
 * Key-to-GUID resolution for a pinned instrument version (item keys, option codes, dimension
 * codes, value codes) is loaded once per (version, checksum) and cached: published versions are
 * immutable and a DRAFT re-import changes the checksum.
 */
component output="false" {

	variables.ROW_VERSION_PATTERN = "^0x[0-9A-Fa-f]{16}$";
	variables.LIST_LIMIT = 500;

	public WalkRepository function init(required any db, required any canonicalJson, required any definitionRepository) {
		variables.db = arguments.db;
		variables.json = arguments.canonicalJson;
		variables.definitions = arguments.definitionRepository;
		variables.indexCache = {};
		return this;
	}

	public boolean function isRowVersion(any value) {
		return !isNull(arguments.value) && isSimpleValue(arguments.value) && reFind(variables.ROW_VERSION_PATTERN, trim(arguments.value)) > 0;
	}

	// ---- walk rows ---------------------------------------------------------------------------

	/** Walk header row (empty struct when absent). lock=true takes an update lock for the transaction. */
	public struct function findWalk(required string walkId, boolean lock = false) {
		var hint = arguments.lock ? " WITH (UPDLOCK, ROWLOCK)" : "";
		var q = variables.db.run(
			"SELECT w.walk_id, w.version_id, w.org_unit_id, w.owner_user_id, w.status, w.observed_at, w.created_at, w.updated_at,
			        w.completed_at, w.voided_at, w.void_reason, CONVERT(varchar(18), CAST(w.row_version AS binary(8)), 1) AS row_version_hex,
			        o.name AS org_unit_name, o.org_unit_code, o.org_unit_type, u.display_name AS owner_display_name, v.version_label
			 FROM [icf].[walk] w" & hint & "
			 JOIN [icf].[org_unit] o ON o.org_unit_id = w.org_unit_id
			 JOIN [icf].[app_user] u ON u.user_id = w.owner_user_id
			 JOIN [icf].[instrument_version] v ON v.version_id = w.version_id
			 WHERE w.walk_id = :id",
			{ "id": variables.db.guid(arguments.walkId) }
		);
		if (!q.recordCount) return {};
		return rowToWalk(q, 1);
	}

	public string function insertWalk(required string versionId, required string orgUnitId, required string ownerUserId, any observedAt) {
		var id = variables.db.newGuid();
		var params = {
			"id": variables.db.guid(id), "version": variables.db.guid(arguments.versionId), "org": variables.db.guid(arguments.orgUnitId),
			"owner": variables.db.guid(arguments.ownerUserId)
		};
		if (!isNull(arguments.observedAt) && isDate(arguments.observedAt)) {
			params["observed"] = variables.db.timestamp(arguments.observedAt);
			variables.db.run("INSERT INTO [icf].[walk] (walk_id, version_id, org_unit_id, owner_user_id, status, observed_at) VALUES (:id, :version, :org, :owner, N'DRAFT', :observed)", params);
		} else {
			variables.db.run("INSERT INTO [icf].[walk] (walk_id, version_id, org_unit_id, owner_user_id, status) VALUES (:id, :version, :org, :owner, N'DRAFT')", params);
		}
		return id;
	}

	/**
	 * Bumps updated_at (and the rowversion) and records the observation timestamp.
	 * observedAt: a date sets observed_at; the empty string falls observed_at back to the walk's
	 * immutable creation instant (the Visit Date dimension is absent or was cleared).
	 */
	public void function touchWalk(required string walkId, any observedAt) {
		if (!isNull(arguments.observedAt) && isDate(arguments.observedAt)) {
			variables.db.run("UPDATE [icf].[walk] SET updated_at = SYSUTCDATETIME(), observed_at = :observed WHERE walk_id = :id",
				{ "id": variables.db.guid(arguments.walkId), "observed": variables.db.timestamp(arguments.observedAt) });
		} else {
			variables.db.run("UPDATE [icf].[walk] SET updated_at = SYSUTCDATETIME(), observed_at = created_at WHERE walk_id = :id", { "id": variables.db.guid(arguments.walkId) });
		}
	}

	public void function markCompleted(required string walkId) {
		variables.db.run("UPDATE [icf].[walk] SET status = N'COMPLETED', completed_at = SYSUTCDATETIME(), updated_at = SYSUTCDATETIME() WHERE walk_id = :id AND status = N'DRAFT'",
			{ "id": variables.db.guid(arguments.walkId) });
	}

	public void function markVoided(required string walkId, required string reason) {
		variables.db.run("UPDATE [icf].[walk] SET status = N'VOIDED', voided_at = SYSUTCDATETIME(), void_reason = :reason, updated_at = SYSUTCDATETIME() WHERE walk_id = :id AND status <> N'VOIDED'",
			{ "id": variables.db.guid(arguments.walkId), "reason": variables.db.nvarchar(arguments.reason, 1000) });
	}

	/**
	 * Walk headers visible to a user: own non-voided walks in units where the user holds
	 * walk.edit_owned or walk.read, plus (scope "all") every non-voided walk in walk.read units.
	 * Newest updated first, at most LIST_LIMIT rows. Dimension values are attached per walk.
	 */
	public array function listWalks(required string userId, required array readUnitIds, required array editUnitIds, string scope = "mine") {
		var own = inClause(mergeIds(arguments.readUnitIds, arguments.editUnitIds), "o");
		var where = "w.status <> N'VOIDED' AND ((w.owner_user_id = :me AND " & own.sql & ")";
		var params = own.params;
		params["me"] = variables.db.guid(arguments.userId);
		if (arguments.scope == "all") {
			var all = inClause(arguments.readUnitIds, "r");
			where &= " OR (" & all.sql & ")";
			structAppend(params, all.params);
		}
		where &= ")";
		var q = variables.db.run(
			"SELECT TOP " & variables.LIST_LIMIT & " w.walk_id, w.version_id, w.org_unit_id, w.owner_user_id, w.status, w.observed_at, w.created_at, w.updated_at,
			        w.completed_at, w.voided_at, w.void_reason, CONVERT(varchar(18), CAST(w.row_version AS binary(8)), 1) AS row_version_hex,
			        o.name AS org_unit_name, o.org_unit_code, o.org_unit_type, u.display_name AS owner_display_name, v.version_label
			 FROM [icf].[walk] w
			 JOIN [icf].[org_unit] o ON o.org_unit_id = w.org_unit_id
			 JOIN [icf].[app_user] u ON u.user_id = w.owner_user_id
			 JOIN [icf].[instrument_version] v ON v.version_id = w.version_id
			 WHERE " & where & "
			 ORDER BY w.updated_at DESC, w.created_at DESC",
			params
		);
		var walks = [];
		var byId = {};
		for (var r = 1; r <= q.recordCount; r++) {
			var w = rowToWalk(q, r);
			w["dimensions"] = {};
			arrayAppend(walks, w);
			byId[w.walkId] = w;
		}
		if (arrayLen(walks)) {
			var dq = variables.db.run(
				"SELECT x.walk_id, d.code, d.data_type, dv.value_code, x.text_value, x.number_value, x.date_value, x.boolean_value
				 FROM [icf].[walk_dimension_value] x
				 JOIN [icf].[dimension_definition] d ON d.dimension_id = x.dimension_id
				 LEFT JOIN [icf].[dimension_value] dv ON dv.value_id = x.selected_value_id
				 WHERE x.walk_id IN (SELECT w.walk_id FROM [icf].[walk] w WHERE " & where & ")",
				params
			);
			for (var r = 1; r <= dq.recordCount; r++) {
				var wid = uCase(dq.walk_id[r]);
				if (structKeyExists(byId, wid)) byId[wid].dimensions[dq.code[r]] = dimensionRowToValue(dq, r);
			}
		}
		return walks;
	}

	// ---- dimension values ---------------------------------------------------------------------

	/** Persisted dimension values keyed by dimension code, in the working-state value shape. */
	public struct function loadDimensionValues(required string walkId) {
		var q = variables.db.run(
			"SELECT d.code, d.data_type, dv.value_code, x.text_value, x.number_value, x.date_value, x.boolean_value
			 FROM [icf].[walk_dimension_value] x
			 JOIN [icf].[dimension_definition] d ON d.dimension_id = x.dimension_id
			 LEFT JOIN [icf].[dimension_value] dv ON dv.value_id = x.selected_value_id
			 WHERE x.walk_id = :id",
			{ "id": variables.db.guid(arguments.walkId) }
		);
		var out = {};
		for (var r = 1; r <= q.recordCount; r++) out[q.code[r]] = dimensionRowToValue(q, r);
		return out;
	}

	/**
	 * Writes one typed dimension value (exactly one typed column, plus text_value as the "Other"
	 * qualifier of a selected list value). value keys: selectedValueId, textValue, numberValue,
	 * dateValue, booleanValue.
	 */
	public void function upsertDimensionValue(required string walkId, required string versionId, required string dimensionId, required struct value, required boolean exists) {
		var params = {
			"walk": variables.db.guid(arguments.walkId), "version": variables.db.guid(arguments.versionId), "dim": variables.db.guid(arguments.dimensionId),
			"selected": variables.db.guid(structKeyExists(arguments.value, "selectedValueId") ? arguments.value.selectedValueId : ""),
			"text": variables.db.nvarchar(structKeyExists(arguments.value, "textValue") ? arguments.value.textValue : javaCast("null", ""), 1000),
			"number": variables.db.decimal(structKeyExists(arguments.value, "numberValue") ? arguments.value.numberValue : javaCast("null", "")),
			"date": dateParam(structKeyExists(arguments.value, "dateValue") ? arguments.value.dateValue : ""),
			"bool": variables.db.bit(structKeyExists(arguments.value, "booleanValue") ? arguments.value.booleanValue : javaCast("null", ""))
		};
		if (arguments.exists) {
			variables.db.run("UPDATE [icf].[walk_dimension_value] SET selected_value_id = :selected, text_value = :text, number_value = :number, date_value = :date, boolean_value = :bool, updated_at = SYSUTCDATETIME() WHERE walk_id = :walk AND dimension_id = :dim", params);
		} else {
			variables.db.run("INSERT INTO [icf].[walk_dimension_value] (walk_id, version_id, dimension_id, selected_value_id, text_value, number_value, date_value, boolean_value) VALUES (:walk, :version, :dim, :selected, :text, :number, :date, :bool)", params);
		}
	}

	public void function deleteDimensionValue(required string walkId, required string dimensionId) {
		variables.db.run("DELETE FROM [icf].[walk_dimension_value] WHERE walk_id = :walk AND dimension_id = :dim", { "walk": variables.db.guid(arguments.walkId), "dim": variables.db.guid(arguments.dimensionId) });
	}

	// ---- responses ----------------------------------------------------------------------------

	/** Persisted responses keyed by item key: { responseId, state, storedCode?, textValue?, optionId? }. */
	public struct function loadResponses(required string walkId) {
		var q = variables.db.run(
			"SELECT r.response_id, i.item_key, r.response_state, r.selected_option_id, o.stored_code, r.text_value
			 FROM [icf].[walk_response] r
			 JOIN [icf].[item_definition] i ON i.item_id = r.item_id
			 LEFT JOIN [icf].[response_option] o ON o.option_id = r.selected_option_id
			 WHERE r.walk_id = :id",
			{ "id": variables.db.guid(arguments.walkId) }
		);
		var out = {};
		for (var r = 1; r <= q.recordCount; r++) {
			var entry = { "responseId": uCase(q.response_id[r]), "state": q.response_state[r], "optionId": "" };
			if (len(q.selected_option_id[r])) { entry.optionId = uCase(q.selected_option_id[r]); entry["storedCode"] = q.stored_code[r]; }
			if (!isNull(q.text_value[r]) && len(q.text_value[r])) entry["textValue"] = q.text_value[r];
			out[q.item_key[r]] = entry;
		}
		return out;
	}

	public void function upsertResponse(required string walkId, required string versionId, required string itemId, required string state, string optionId = "", any textValue, required boolean exists) {
		var params = {
			"walk": variables.db.guid(arguments.walkId), "version": variables.db.guid(arguments.versionId), "item": variables.db.guid(arguments.itemId),
			"state": variables.db.nvarchar(arguments.state, 30), "option": variables.db.guid(arguments.optionId),
			"text": variables.db.ntext(isNull(arguments.textValue) || (isSimpleValue(arguments.textValue) && !len(arguments.textValue)) ? javaCast("null", "") : arguments.textValue)
		};
		if (arguments.exists) {
			variables.db.run("UPDATE [icf].[walk_response] SET response_state = :state, selected_option_id = :option, text_value = :text, number_value = NULL, date_value = NULL, boolean_value = NULL, updated_at = SYSUTCDATETIME() WHERE walk_id = :walk AND item_id = :item", params);
		} else {
			variables.db.run("INSERT INTO [icf].[walk_response] (walk_id, version_id, item_id, response_state, selected_option_id, text_value) VALUES (:walk, :version, :item, :state, :option, :text)", params);
		}
	}

	public struct function responseCounts(required string walkId) {
		var q = variables.db.run("SELECT response_state, COUNT(*) AS n FROM [icf].[walk_response] WHERE walk_id = :id GROUP BY response_state", { "id": variables.db.guid(arguments.walkId) });
		var out = { "total": 0 };
		for (var r = 1; r <= q.recordCount; r++) { out[q.response_state[r]] = q.n[r]; out.total += q.n[r]; }
		return out;
	}

	// ---- revisions and mutations ---------------------------------------------------------------

	public numeric function insertRevision(required string walkId, required string actorUserId, required string reason, required string priorSnapshotJson) {
		var next = variables.db.scalar("SELECT ISNULL(MAX(revision_number), 0) + 1 AS n FROM [icf].[walk_revision] WHERE walk_id = :id", { "id": variables.db.guid(arguments.walkId) }, 1);
		variables.db.run(
			"INSERT INTO [icf].[walk_revision] (walk_id, revision_number, actor_user_id, reason, prior_snapshot_json) VALUES (:walk, :n, :actor, :reason, :snapshot)",
			{ "walk": variables.db.guid(arguments.walkId), "n": variables.db.integer(next), "actor": variables.db.guid(arguments.actorUserId), "reason": variables.db.nvarchar(arguments.reason, 1000), "snapshot": variables.db.ntext(arguments.priorSnapshotJson) }
		);
		return next;
	}

	public numeric function countRevisions(required string walkId) {
		return variables.db.scalar("SELECT COUNT(*) AS n FROM [icf].[walk_revision] WHERE walk_id = :id", { "id": variables.db.guid(arguments.walkId) });
	}

	public array function listRevisions(required string walkId) {
		var q = variables.db.run("SELECT revision_id, revision_number, actor_user_id, reason, created_at FROM [icf].[walk_revision] WHERE walk_id = :id ORDER BY revision_number", { "id": variables.db.guid(arguments.walkId) });
		var out = [];
		for (var r = 1; r <= q.recordCount; r++) {
			arrayAppend(out, { "revisionId": uCase(q.revision_id[r]), "revisionNumber": q.revision_number[r], "actorUserId": uCase(q.actor_user_id[r]), "reason": q.reason[r], "createdAt": variables.json.formatDate(q.created_at[r]) });
		}
		return out;
	}

	/**
	 * Recorded mutation, or an empty struct. fingerprint is "" for rows written before migration
	 * 004; the service treats an absent fingerprint as "not bound to content" rather than as a
	 * match for any content.
	 */
	public struct function findMutation(required string mutationId) {
		var q = variables.db.run("SELECT mutation_id, walk_id, actor_user_id, action, request_fingerprint, result_json, created_at FROM [icf].[walk_mutation] WHERE mutation_id = :id", { "id": variables.db.guid(arguments.mutationId) });
		if (!q.recordCount) return {};
		return {
			"mutationId": uCase(q.mutation_id[1]), "walkId": uCase(q.walk_id[1]), "actorUserId": uCase(q.actor_user_id[1]), "action": q.action[1],
			"fingerprint": isNull(q.request_fingerprint[1]) ? "" : lCase(trim(q.request_fingerprint[1])),
			"result": isJSON(q.result_json[1]) ? deserializeJSON(q.result_json[1]) : {}, "createdAt": variables.json.formatDate(q.created_at[1])
		};
	}

	public void function insertMutation(required string mutationId, required string walkId, required string actorUserId, required string action, required struct result, string requestFingerprint = "") {
		variables.db.run(
			"INSERT INTO [icf].[walk_mutation] (mutation_id, walk_id, actor_user_id, action, request_fingerprint, result_json) VALUES (:id, :walk, :actor, :action, :fingerprint, :result)",
			{
				"id": variables.db.guid(arguments.mutationId), "walk": variables.db.guid(arguments.walkId), "actor": variables.db.guid(arguments.actorUserId),
				"action": variables.db.nvarchar(arguments.action, 20),
				"fingerprint": variables.db.nvarchar(len(arguments.requestFingerprint) ? lCase(arguments.requestFingerprint) : javaCast("null", ""), 64),
				"result": variables.db.ntext(variables.json.serialize(arguments.result))
			}
		);
	}

	// ---- definition index (keys -> GUIDs for a pinned version) ---------------------------------

	/**
	 * { items: { itemKey: { itemId, responseSetId } }, options: { responseSetId: { storedCode: optionId } },
	 *   dimensions: { code: dimensionId }, values: { dimensionId: { valueCode: valueId } }, checksum }
	 */
	public struct function definitionIndex(required string versionId) {
		var id = uCase(arguments.versionId);
		var row = variables.definitions.findVersionById(id);
		if (structIsEmpty(row)) throw(type = "ICFWalk.NotFound", message = "Instrument version not found.", errorcode = "INSTRUMENT_VERSION_NOT_FOUND");
		var checksum = isNull(row.checksum) ? "" : row.checksum;
		if (structKeyExists(variables.indexCache, id) && variables.indexCache[id].checksum == checksum) return variables.indexCache[id];
		var p = { "id": variables.db.guid(id) };
		var idx = { "versionId": id, "checksum": checksum, "items": {}, "options": {}, "dimensions": {}, "values": {} };
		var iq = variables.db.run("SELECT item_id, item_key, response_set_id FROM [icf].[item_definition] WHERE version_id = :id AND active = 1", p);
		for (var r = 1; r <= iq.recordCount; r++) idx.items[iq.item_key[r]] = { "itemId": uCase(iq.item_id[r]), "responseSetId": len(iq.response_set_id[r]) ? uCase(iq.response_set_id[r]) : "" };
		var oq = variables.db.run("SELECT o.option_id, o.response_set_id, o.stored_code FROM [icf].[response_option] o JOIN [icf].[response_set] s ON s.response_set_id = o.response_set_id WHERE s.version_id = :id AND o.active = 1 AND s.active = 1", p);
		for (var r = 1; r <= oq.recordCount; r++) {
			var sid = uCase(oq.response_set_id[r]);
			if (!structKeyExists(idx.options, sid)) idx.options[sid] = {};
			idx.options[sid][oq.stored_code[r]] = uCase(oq.option_id[r]);
		}
		var dq = variables.db.run("SELECT d.dimension_id, d.code FROM [icf].[dimension_definition] d JOIN [icf].[instrument_dimension] p ON p.dimension_id = d.dimension_id WHERE p.version_id = :id AND d.active = 1", p);
		for (var r = 1; r <= dq.recordCount; r++) {
			var did = uCase(dq.dimension_id[r]);
			idx.dimensions[dq.code[r]] = did;
			idx.values[did] = {};
			var vq = variables.db.run("SELECT value_id, value_code FROM [icf].[dimension_value] WHERE dimension_id = :id AND active = 1", { "id": variables.db.guid(did) });
			for (var vr = 1; vr <= vq.recordCount; vr++) idx.values[did][vq.value_code[vr]] = uCase(vq.value_id[vr]);
		}
		variables.indexCache[id] = idx;
		return idx;
	}

	public void function clearCache() { variables.indexCache = {}; }

	// ---- internals ---------------------------------------------------------------------------

	private struct function rowToWalk(required query q, required numeric r) {
		return {
			"walkId": uCase(arguments.q.walk_id[arguments.r]),
			"versionId": uCase(arguments.q.version_id[arguments.r]),
			"versionLabel": arguments.q.version_label[arguments.r],
			"orgUnitId": uCase(arguments.q.org_unit_id[arguments.r]),
			"orgUnitName": arguments.q.org_unit_name[arguments.r],
			"orgUnitCode": arguments.q.org_unit_code[arguments.r],
			"orgUnitType": arguments.q.org_unit_type[arguments.r],
			"ownerUserId": uCase(arguments.q.owner_user_id[arguments.r]),
			"ownerDisplayName": arguments.q.owner_display_name[arguments.r],
			"status": arguments.q.status[arguments.r],
			"observedAt": arguments.q.observed_at[arguments.r],
			"createdAt": arguments.q.created_at[arguments.r],
			"updatedAt": arguments.q.updated_at[arguments.r],
			"completedAt": isDate(arguments.q.completed_at[arguments.r]) ? arguments.q.completed_at[arguments.r] : "",
			"voidedAt": isDate(arguments.q.voided_at[arguments.r]) ? arguments.q.voided_at[arguments.r] : "",
			"voidReason": isNull(arguments.q.void_reason[arguments.r]) ? "" : arguments.q.void_reason[arguments.r],
			"rowVersion": arguments.q.row_version_hex[arguments.r]
		};
	}

	private struct function dimensionRowToValue(required query q, required numeric r) {
		var v = {};
		if (!isNull(arguments.q.value_code[arguments.r]) && len(arguments.q.value_code[arguments.r])) {
			v["selectedValueCode"] = arguments.q.value_code[arguments.r];
			if (!isNull(arguments.q.text_value[arguments.r]) && len(arguments.q.text_value[arguments.r])) v["otherText"] = arguments.q.text_value[arguments.r];
			return v;
		}
		if (!isNull(arguments.q.text_value[arguments.r]) && len(arguments.q.text_value[arguments.r])) v["textValue"] = arguments.q.text_value[arguments.r];
		if (!isNull(arguments.q.date_value[arguments.r]) && isDate(arguments.q.date_value[arguments.r])) v["dateValue"] = dateFormat(arguments.q.date_value[arguments.r], "yyyy-mm-dd");
		if (!isNull(arguments.q.number_value[arguments.r]) && isNumeric(arguments.q.number_value[arguments.r])) v["numberValue"] = arguments.q.number_value[arguments.r];
		if (!isNull(arguments.q.boolean_value[arguments.r]) && isBoolean(arguments.q.boolean_value[arguments.r]) && len(toString(arguments.q.boolean_value[arguments.r]))) v["booleanValue"] = arguments.q.boolean_value[arguments.r] ? true : false;
		return v;
	}

	private struct function dateParam(required string value) {
		if (!len(trim(arguments.value))) return { "value": "", "cfsqltype": "cf_sql_date", "null": true };
		return { "value": createDate(val(listGetAt(arguments.value, 1, "-")), val(listGetAt(arguments.value, 2, "-")), val(listGetAt(arguments.value, 3, "-"))), "cfsqltype": "cf_sql_date" };
	}

	private array function mergeIds(required array a, required array b) {
		var seen = {};
		var out = [];
		for (var id in arguments.a) { if (!structKeyExists(seen, uCase(id))) { seen[uCase(id)] = true; arrayAppend(out, uCase(id)); } }
		for (var id in arguments.b) { if (!structKeyExists(seen, uCase(id))) { seen[uCase(id)] = true; arrayAppend(out, uCase(id)); } }
		return out;
	}

	private struct function inClause(required array ids, required string prefix) {
		if (!arrayLen(arguments.ids)) return { "sql": "1 = 0", "params": {} };
		var names = [];
		var params = {};
		for (var i = 1; i <= arrayLen(arguments.ids); i++) {
			arrayAppend(names, ":" & arguments.prefix & i);
			params[arguments.prefix & i] = variables.db.guid(arguments.ids[i]);
		}
		return { "sql": "w.org_unit_id IN (" & arrayToList(names, ", ") & ")", "params": params };
	}
}
