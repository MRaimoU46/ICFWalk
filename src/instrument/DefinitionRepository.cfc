/**
 * Data access for instrument configuration tables (icf.instrument, instrument_version,
 * section_definition, response_set, response_option, rule_definition, dimension_definition,
 * dimension_value, instrument_dimension, item_definition). All statements are parameterized.
 *
 * Immutability of PUBLISHED/RETIRED versions is enforced by InstrumentImportService before any
 * write; the only method that ignores status is deleteVersionCascadeUnchecked, which exists for
 * test fixture cleanup and is not reachable through any HTTP route.
 */
component output="false" {

	variables.PARK_OFFSET = 1000000;

	public DefinitionRepository function init(required any db, required any canonicalJson) {
		variables.db = arguments.db;
		variables.json = arguments.canonicalJson;
		variables.mapper = new icfwalk.instrument.DefinitionMapper(arguments.canonicalJson);
		return this;
	}

	public any function mapper() { return variables.mapper; }

	// ---- instrument and version -------------------------------------------------------------

	public array function listVersions() {
		var q = variables.db.run(
			"SELECT v.version_id, i.code AS instrument_code, v.version_label, v.status, v.effective_start, v.effective_end,
			        v.checksum_sha256, v.created_at, v.published_at, v.updated_at,
			        (SELECT COUNT(*) FROM [icf].[walk] w WHERE w.version_id = v.version_id) AS walk_count
			 FROM [icf].[instrument_version] v
			 JOIN [icf].[instrument] i ON i.instrument_id = v.instrument_id
			 ORDER BY i.code, v.created_at DESC"
		);
		var out = [];
		for (var r = 1; r <= q.recordCount; r++) {
			var row = {};
			row["versionId"] = uCase(q.version_id[r]);
			row["instrumentCode"] = q.instrument_code[r];
			row["versionLabel"] = q.version_label[r];
			row["status"] = q.status[r];
			row["checksum"] = len(q.checksum_sha256[r]) ? q.checksum_sha256[r] : javaCast("null", "");
			row["effectiveStart"] = isDate(q.effective_start[r]) ? variables.json.formatDate(q.effective_start[r]) : javaCast("null", "");
			row["publishedAt"] = isDate(q.published_at[r]) ? variables.json.formatDate(q.published_at[r]) : javaCast("null", "");
			row["createdAt"] = variables.json.formatDate(q.created_at[r]);
			row["updatedAt"] = variables.json.formatDate(q.updated_at[r]);
			row["walkCount"] = q.walk_count[r];
			arrayAppend(out, row);
		}
		return out;
	}

	public struct function findInstrumentByCode(required string code) {
		var q = variables.db.run("SELECT instrument_id, code, name, description, active FROM [icf].[instrument] WHERE code = :code", { "code": variables.db.nvarchar(arguments.code, 60) });
		if (!q.recordCount) return {};
		return { "instrumentId": uCase(q.instrument_id[1]), "code": q.code[1], "name": q.name[1], "description": q.description[1], "active": q.active[1] };
	}

	public string function createInstrument(required string code, required string name, any description, boolean active = true) {
		var id = variables.db.newGuid();
		variables.db.run(
			"INSERT INTO [icf].[instrument] (instrument_id, code, name, description, active) VALUES (:id, :code, :name, :description, :active)",
			{ "id": variables.db.guid(id), "code": variables.db.nvarchar(arguments.code, 60), "name": variables.db.nvarchar(arguments.name, 200), "description": variables.db.nvarchar(isNull(arguments.description) ? javaCast("null", "") : arguments.description, 1000), "active": variables.db.bit(arguments.active) }
		);
		return id;
	}

	public void function updateInstrument(required string instrumentId, required string name, any description, boolean active = true) {
		variables.db.run(
			"UPDATE [icf].[instrument] SET name = :name, description = :description, active = :active, updated_at = SYSUTCDATETIME() WHERE instrument_id = :id",
			{ "id": variables.db.guid(arguments.instrumentId), "name": variables.db.nvarchar(arguments.name, 200), "description": variables.db.nvarchar(isNull(arguments.description) ? javaCast("null", "") : arguments.description, 1000), "active": variables.db.bit(arguments.active) }
		);
	}

	public struct function findVersion(required string instrumentId, required string versionLabel, boolean lockForUpdate = false) {
		var hint = arguments.lockForUpdate ? " WITH (UPDLOCK, HOLDLOCK)" : "";
		var q = variables.db.run(
			"SELECT version_id, status, checksum_sha256, updated_at FROM [icf].[instrument_version]" & hint & " WHERE instrument_id = :instrumentId AND version_label = :label",
			{ "instrumentId": variables.db.guid(arguments.instrumentId), "label": variables.db.nvarchar(arguments.versionLabel, 100) }
		);
		if (!q.recordCount) return {};
		return { "versionId": uCase(q.version_id[1]), "status": q.status[1], "checksum": q.checksum_sha256[1], "updatedAt": q.updated_at[1] };
	}

	public struct function findVersionById(required string versionId) {
		var q = variables.db.run(
			"SELECT v.version_id, v.instrument_id, v.version_label, v.status, v.checksum_sha256, v.compiled_snapshot_json, v.updated_at, v.row_version
			 FROM [icf].[instrument_version] v WHERE v.version_id = :id",
			{ "id": variables.db.guid(arguments.versionId) }
		);
		if (!q.recordCount) return {};
		return {
			"versionId": uCase(q.version_id[1]),
			"instrumentId": uCase(q.instrument_id[1]),
			"versionLabel": q.version_label[1],
			"status": q.status[1],
			"checksum": q.checksum_sha256[1],
			"snapshotJson": q.compiled_snapshot_json[1],
			"updatedAt": q.updated_at[1],
			"rowVersion": binaryEncode(q.row_version[1], "hex")
		};
	}

	/**
	 * findVersionById under the same row lock every mutation path takes, so a publish and a
	 * concurrent import or publish of the same version queue on the walk of one row rather than
	 * racing. Call inside a transaction; outside one the lock is released immediately and proves
	 * nothing.
	 */
	public struct function findVersionByIdForUpdate(required string versionId) {
		var q = variables.db.run(
			"SELECT v.version_id, v.instrument_id, v.version_label, v.status, v.checksum_sha256, v.compiled_snapshot_json, v.updated_at, v.row_version
			 FROM [icf].[instrument_version] v WITH (UPDLOCK, ROWLOCK) WHERE v.version_id = :id",
			{ "id": variables.db.guid(arguments.versionId) }
		);
		if (!q.recordCount) return {};
		return {
			"versionId": uCase(q.version_id[1]),
			"instrumentId": uCase(q.instrument_id[1]),
			"versionLabel": q.version_label[1],
			"status": q.status[1],
			"checksum": q.checksum_sha256[1],
			"snapshotJson": q.compiled_snapshot_json[1],
			"updatedAt": q.updated_at[1],
			"rowVersion": binaryEncode(q.row_version[1], "hex")
		};
	}

	/**
	 * The publish write, as one statement. Status, publisher, publication time, effective start,
	 * snapshot and checksum move together or not at all: CK_instrument_version_publish_values
	 * rejects any non-DRAFT row missing one of them, so a partial publish cannot be stored even
	 * if a future caller tried. The WHERE clause re-asserts DRAFT, so two publishers racing on the
	 * same version cannot both succeed; the loser updates nothing and is told so by the row count.
	 */
	public numeric function markPublished(required string versionId, required string canonicalJson, required string checksum, string publishedByUserId = "") {
		variables.db.run(
			"UPDATE [icf].[instrument_version]
			    SET status = N'PUBLISHED',
			        compiled_snapshot_json = :snapshot,
			        checksum_sha256 = :checksum,
			        published_by_user_id = :publishedBy,
			        published_at = SYSUTCDATETIME(),
			        effective_start = COALESCE(effective_start, SYSUTCDATETIME()),
			        updated_at = SYSUTCDATETIME()
			  WHERE version_id = :id AND status = N'DRAFT'",
			{
				"id": variables.db.guid(arguments.versionId),
				"snapshot": variables.db.ntext(arguments.canonicalJson),
				"checksum": { "value": arguments.checksum, "cfsqltype": "cf_sql_char" },
				"publishedBy": variables.db.guid(arguments.publishedByUserId)
			}
		);
		// Read back inside the same transaction rather than trusting a driver-reported row count.
		return variables.db.scalar(
			"SELECT COUNT(*) AS n FROM [icf].[instrument_version] WHERE version_id = :id AND status = N'PUBLISHED'",
			{ "id": variables.db.guid(arguments.versionId) }
		);
	}

	public string function createDraftVersion(required string instrumentId, required string versionLabel, string createdByUserId = "") {
		var id = variables.db.newGuid();
		variables.db.run(
			"INSERT INTO [icf].[instrument_version] (version_id, instrument_id, version_label, status, created_by_user_id)
			 VALUES (:id, :instrumentId, :label, N'DRAFT', :createdBy)",
			{ "id": variables.db.guid(id), "instrumentId": variables.db.guid(arguments.instrumentId), "label": variables.db.nvarchar(arguments.versionLabel, 100), "createdBy": variables.db.guid(arguments.createdByUserId) }
		);
		return id;
	}

	public numeric function countWalksForVersion(required string versionId) {
		return variables.db.scalar("SELECT COUNT(*) AS n FROM [icf].[walk] WHERE version_id = :id", { "id": variables.db.guid(arguments.versionId) });
	}

	public void function storeSnapshot(required string versionId, required string canonicalJson, required string checksum) {
		variables.db.run(
			"UPDATE [icf].[instrument_version] SET compiled_snapshot_json = :snapshot, checksum_sha256 = :checksum, updated_at = SYSUTCDATETIME() WHERE version_id = :id",
			{ "id": variables.db.guid(arguments.versionId), "snapshot": variables.db.ntext(arguments.canonicalJson), "checksum": { "value": arguments.checksum, "cfsqltype": "cf_sql_char" } }
		);
	}

	// ---- existing children (keyed by unique keys) ---------------------------------------------

	public struct function loadVersionChildren(required string versionId) {
		var p = { "id": variables.db.guid(arguments.versionId) };
		var out = { "sections": {}, "responseSets": {}, "options": {}, "rules": {}, "items": {}, "placements": {} };
		var q = variables.db.run("SELECT section_id, section_key, parent_section_id FROM [icf].[section_definition] WHERE version_id = :id", p);
		for (var r = 1; r <= q.recordCount; r++) out.sections[q.section_key[r]] = { "id": uCase(q.section_id[r]) };
		q = variables.db.run("SELECT response_set_id, response_set_key FROM [icf].[response_set] WHERE version_id = :id", p);
		for (var r = 1; r <= q.recordCount; r++) out.responseSets[q.response_set_key[r]] = { "id": uCase(q.response_set_id[r]) };
		q = variables.db.run(
			"SELECT o.option_id, o.option_key, s.response_set_key FROM [icf].[response_option] o JOIN [icf].[response_set] s ON s.response_set_id = o.response_set_id WHERE s.version_id = :id", p);
		for (var r = 1; r <= q.recordCount; r++) out.options[q.response_set_key[r] & "|" & q.option_key[r]] = { "id": uCase(q.option_id[r]) };
		q = variables.db.run("SELECT rule_id, rule_key FROM [icf].[rule_definition] WHERE version_id = :id", p);
		for (var r = 1; r <= q.recordCount; r++) out.rules[q.rule_key[r]] = { "id": uCase(q.rule_id[r]) };
		q = variables.db.run("SELECT item_id, item_key FROM [icf].[item_definition] WHERE version_id = :id", p);
		for (var r = 1; r <= q.recordCount; r++) out.items[q.item_key[r]] = { "id": uCase(q.item_id[r]) };
		q = variables.db.run("SELECT p.dimension_id, d.code FROM [icf].[instrument_dimension] p JOIN [icf].[dimension_definition] d ON d.dimension_id = p.dimension_id WHERE p.version_id = :id", p);
		for (var r = 1; r <= q.recordCount; r++) out.placements[q.code[r]] = { "dimensionId": uCase(q.dimension_id[r]) };
		return out;
	}

	public struct function loadDimensions() {
		var q = variables.db.run("SELECT dimension_id, code FROM [icf].[dimension_definition]");
		var out = {};
		for (var r = 1; r <= q.recordCount; r++) out[q.code[r]] = { "id": uCase(q.dimension_id[r]) };
		return out;
	}

	public struct function loadDimensionValues(required string dimensionId) {
		var q = variables.db.run("SELECT value_id, value_code, display_order FROM [icf].[dimension_value] WHERE dimension_id = :id", { "id": variables.db.guid(arguments.dimensionId) });
		var out = {};
		for (var r = 1; r <= q.recordCount; r++) out[q.value_code[r]] = { "id": uCase(q.value_id[r]), "displayOrder": q.display_order[r] };
		return out;
	}

	/**
	 * Moves every display order of the version's children out of the final range so that
	 * reordered imports never collide with the unique sibling-order indexes mid-update.
	 */
	public void function parkVersionOrders(required string versionId) {
		var p = { "id": variables.db.guid(arguments.versionId), "offset": variables.db.integer(variables.PARK_OFFSET) };
		variables.db.run("UPDATE [icf].[section_definition] SET display_order = display_order + :offset WHERE version_id = :id AND display_order < :offset", p);
		variables.db.run("UPDATE o SET o.display_order = o.display_order + :offset FROM [icf].[response_option] o JOIN [icf].[response_set] s ON s.response_set_id = o.response_set_id WHERE s.version_id = :id AND o.display_order < :offset", p);
		variables.db.run("UPDATE [icf].[item_definition] SET display_order = display_order + :offset WHERE version_id = :id AND display_order < :offset", p);
		variables.db.run("UPDATE [icf].[instrument_dimension] SET display_order = display_order + :offset WHERE version_id = :id AND display_order < :offset", p);
	}

	public void function parkDimensionValueOrders(required string dimensionId) {
		variables.db.run("UPDATE [icf].[dimension_value] SET display_order = display_order + :offset WHERE dimension_id = :id AND display_order < :offset",
			{ "id": variables.db.guid(arguments.dimensionId), "offset": variables.db.integer(variables.PARK_OFFSET) });
	}

	public numeric function parkOffset() { return variables.PARK_OFFSET; }

	// ---- sections ---------------------------------------------------------------------------

	public string function insertSection(required string versionId, required struct row, required numeric parkedOrder) {
		var id = variables.db.newGuid();
		variables.db.run(
			"INSERT INTO [icf].[section_definition] (section_id, version_id, parent_section_id, section_key, display_order, title, instructions, notes_enabled, settings_json, active)
			 VALUES (:id, :versionId, NULL, :key, :order, :title, :instructions, :notes, :settings, :active)",
			{
				"id": variables.db.guid(id), "versionId": variables.db.guid(arguments.versionId),
				"key": variables.db.nvarchar(arguments.row.sectionKey, 100), "order": variables.db.integer(arguments.parkedOrder),
				"title": variables.db.nvarchar(arguments.row.title, 300), "instructions": variables.db.ntext(nullable(arguments.row, "instructions")),
				"notes": variables.db.bit(arguments.row.notesEnabled), "settings": variables.db.ntext(arguments.row.settingsJson), "active": variables.db.bit(arguments.row.active)
			}
		);
		return id;
	}

	public void function updateSectionContent(required string sectionId, required struct row) {
		variables.db.run(
			"UPDATE [icf].[section_definition] SET title = :title, instructions = :instructions, notes_enabled = :notes, settings_json = :settings, active = :active, updated_at = SYSUTCDATETIME()
			 WHERE section_id = :id",
			{
				"id": variables.db.guid(arguments.sectionId), "title": variables.db.nvarchar(arguments.row.title, 300),
				"instructions": variables.db.ntext(nullable(arguments.row, "instructions")), "notes": variables.db.bit(arguments.row.notesEnabled),
				"settings": variables.db.ntext(arguments.row.settingsJson), "active": variables.db.bit(arguments.row.active)
			}
		);
	}

	public void function placeSection(required string sectionId, string parentSectionId = "", required numeric displayOrder) {
		variables.db.run(
			"UPDATE [icf].[section_definition] SET parent_section_id = :parent, display_order = :order, updated_at = SYSUTCDATETIME() WHERE section_id = :id",
			{ "id": variables.db.guid(arguments.sectionId), "parent": variables.db.guid(arguments.parentSectionId), "order": variables.db.integer(arguments.displayOrder) }
		);
	}

	/**
	 * Deletes the given sections, children before parents. Returns the number deleted.
	 */
	public numeric function deleteSections(required array sectionIds) {
		var remaining = duplicate(arguments.sectionIds);
		var deleted = 0;
		var progress = true;
		while (arrayLen(remaining) && progress) {
			progress = false;
			var next = [];
			for (var id in remaining) {
				var children = variables.db.scalar("SELECT COUNT(*) AS n FROM [icf].[section_definition] WHERE parent_section_id = :id", { "id": variables.db.guid(id) });
				if (children > 0) { arrayAppend(next, id); continue; }
				variables.db.run("DELETE FROM [icf].[section_definition] WHERE section_id = :id", { "id": variables.db.guid(id) });
				deleted++;
				progress = true;
			}
			remaining = next;
		}
		if (arrayLen(remaining)) {
			throw(type = "ICFWalk.Import.Validation", message = "Stale sections could not be removed because other sections still depend on them.", errorcode = "STALE_SECTION_IN_USE");
		}
		return deleted;
	}

	// ---- response sets and options ---------------------------------------------------------

	public string function upsertResponseSet(required string versionId, string existingId = "", required struct row) {
		if (len(arguments.existingId)) {
			variables.db.run(
				"UPDATE [icf].[response_set] SET name = :name, selection_mode = :mode, settings_json = :settings, active = :active, updated_at = SYSUTCDATETIME() WHERE response_set_id = :id",
				{ "id": variables.db.guid(arguments.existingId), "name": variables.db.nvarchar(arguments.row.name, 200), "mode": variables.db.nvarchar(arguments.row.selectionMode, 20), "settings": variables.db.ntext(arguments.row.settingsJson), "active": variables.db.bit(arguments.row.active) }
			);
			return arguments.existingId;
		}
		var id = variables.db.newGuid();
		variables.db.run(
			"INSERT INTO [icf].[response_set] (response_set_id, version_id, response_set_key, name, selection_mode, settings_json, active) VALUES (:id, :versionId, :key, :name, :mode, :settings, :active)",
			{ "id": variables.db.guid(id), "versionId": variables.db.guid(arguments.versionId), "key": variables.db.nvarchar(arguments.row.setKey, 100), "name": variables.db.nvarchar(arguments.row.name, 200), "mode": variables.db.nvarchar(arguments.row.selectionMode, 20), "settings": variables.db.ntext(arguments.row.settingsJson), "active": variables.db.bit(arguments.row.active) }
		);
		return id;
	}

	public void function deleteResponseSet(required string responseSetId) {
		variables.db.run("DELETE FROM [icf].[response_set] WHERE response_set_id = :id", { "id": variables.db.guid(arguments.responseSetId) });
	}

	public string function upsertOption(required string responseSetId, string existingId = "", required struct row) {
		var params = {
			"setId": variables.db.guid(arguments.responseSetId), "key": variables.db.nvarchar(arguments.row.optionKey, 100),
			"code": variables.db.nvarchar(arguments.row.storedCode, 100), "label": variables.db.nvarchar(arguments.row.label, 500),
			"definition": variables.db.ntext(nullable(arguments.row, "definition")), "score": variables.db.decimal(nullable(arguments.row, "numericScore")),
			"isNa": variables.db.bit(arguments.row.isNa), "order": variables.db.integer(arguments.row.displayOrder), "active": variables.db.bit(arguments.row.active)
		};
		if (len(arguments.existingId)) {
			params["id"] = variables.db.guid(arguments.existingId);
			variables.db.run(
				"UPDATE [icf].[response_option] SET stored_code = :code, label = :label, definition = :definition, numeric_score = :score, is_na = :isNa, display_order = :order, active = :active, updated_at = SYSUTCDATETIME() WHERE option_id = :id",
				params
			);
			return arguments.existingId;
		}
		var id = variables.db.newGuid();
		params["id"] = variables.db.guid(id);
		variables.db.run(
			"INSERT INTO [icf].[response_option] (option_id, response_set_id, option_key, stored_code, label, definition, numeric_score, is_na, display_order, active)
			 VALUES (:id, :setId, :key, :code, :label, :definition, :score, :isNa, :order, :active)",
			params
		);
		return id;
	}

	public void function deleteOption(required string optionId) {
		variables.db.run("DELETE FROM [icf].[response_option] WHERE option_id = :id", { "id": variables.db.guid(arguments.optionId) });
	}

	// ---- dimensions (global) ---------------------------------------------------------------

	public string function upsertDimension(string existingId = "", required struct row) {
		var params = {
			"code": variables.db.nvarchar(arguments.row.code, 100), "label": variables.db.nvarchar(arguments.row.label, 200), "dataType": variables.db.nvarchar(arguments.row.dataType, 20),
			"reportable": variables.db.bit(arguments.row.reportable), "sensitive": variables.db.bit(arguments.row.sensitive), "settings": variables.db.ntext(arguments.row.settingsJson), "active": variables.db.bit(arguments.row.active)
		};
		if (len(arguments.existingId)) {
			params["id"] = variables.db.guid(arguments.existingId);
			variables.db.run("UPDATE [icf].[dimension_definition] SET label = :label, data_type = :dataType, reportable = :reportable, sensitive = :sensitive, settings_json = :settings, active = :active, updated_at = SYSUTCDATETIME() WHERE dimension_id = :id", params);
			return arguments.existingId;
		}
		var id = variables.db.newGuid();
		params["id"] = variables.db.guid(id);
		variables.db.run("INSERT INTO [icf].[dimension_definition] (dimension_id, code, label, data_type, reportable, sensitive, settings_json, active) VALUES (:id, :code, :label, :dataType, :reportable, :sensitive, :settings, :active)", params);
		return id;
	}

	public string function upsertDimensionValue(required string dimensionId, string existingId = "", required struct row) {
		var params = {
			"dimensionId": variables.db.guid(arguments.dimensionId), "code": variables.db.nvarchar(arguments.row.valueCode, 100), "label": variables.db.nvarchar(arguments.row.label, 300),
			"order": variables.db.integer(arguments.row.displayOrder), "start": variables.db.timestamp(instantOrNull(nullable(arguments.row, "effectiveStart"))),
			"end": variables.db.timestamp(instantOrNull(nullable(arguments.row, "effectiveEnd"))), "active": variables.db.bit(arguments.row.active)
		};
		if (len(arguments.existingId)) {
			params["id"] = variables.db.guid(arguments.existingId);
			variables.db.run("UPDATE [icf].[dimension_value] SET label = :label, display_order = :order, effective_start = :start, effective_end = :end, active = :active, updated_at = SYSUTCDATETIME() WHERE value_id = :id", params);
			return arguments.existingId;
		}
		var id = variables.db.newGuid();
		params["id"] = variables.db.guid(id);
		variables.db.run("INSERT INTO [icf].[dimension_value] (value_id, dimension_id, value_code, label, display_order, effective_start, effective_end, active) VALUES (:id, :dimensionId, :code, :label, :order, :start, :end, :active)", params);
		return id;
	}

	public void function setDimensionValueOrder(required string valueId, required numeric displayOrder) {
		variables.db.run("UPDATE [icf].[dimension_value] SET display_order = :order WHERE value_id = :id", { "id": variables.db.guid(arguments.valueId), "order": variables.db.integer(arguments.displayOrder) });
	}

	public numeric function maxDimensionValueOrder(required string dimensionId) {
		return variables.db.scalar("SELECT ISNULL(MAX(display_order), 0) AS n FROM [icf].[dimension_value] WHERE dimension_id = :id AND display_order < :offset",
			{ "id": variables.db.guid(arguments.dimensionId), "offset": variables.db.integer(variables.PARK_OFFSET) });
	}

	// ---- rules ------------------------------------------------------------------------------

	public string function upsertRule(required string versionId, string existingId = "", required struct row) {
		var params = {
			"versionId": variables.db.guid(arguments.versionId), "key": variables.db.nvarchar(arguments.row.ruleKey, 100), "targetType": variables.db.nvarchar(arguments.row.targetType, 20),
			"targetKey": variables.db.nvarchar(arguments.row.targetKey, 100), "effect": variables.db.nvarchar(arguments.row.effect, 20), "conditions": variables.db.ntext(arguments.row.conditionsJson), "active": variables.db.bit(arguments.row.active)
		};
		if (len(arguments.existingId)) {
			params["id"] = variables.db.guid(arguments.existingId);
			variables.db.run("UPDATE [icf].[rule_definition] SET target_type = :targetType, target_key = :targetKey, effect = :effect, conditions_json = :conditions, active = :active, updated_at = SYSUTCDATETIME() WHERE rule_id = :id", params);
			return arguments.existingId;
		}
		var id = variables.db.newGuid();
		params["id"] = variables.db.guid(id);
		variables.db.run("INSERT INTO [icf].[rule_definition] (rule_id, version_id, rule_key, target_type, target_key, effect, conditions_json, active) VALUES (:id, :versionId, :key, :targetType, :targetKey, :effect, :conditions, :active)", params);
		return id;
	}

	public void function deleteRule(required string ruleId) {
		variables.db.run("DELETE FROM [icf].[rule_definition] WHERE rule_id = :id", { "id": variables.db.guid(arguments.ruleId) });
	}

	// ---- items ------------------------------------------------------------------------------

	public string function upsertItem(required string versionId, string existingId = "", required struct row, required string sectionId, string responseSetId = "") {
		var params = {
			"versionId": variables.db.guid(arguments.versionId), "sectionId": variables.db.guid(arguments.sectionId), "setId": variables.db.guid(arguments.responseSetId),
			"key": variables.db.nvarchar(arguments.row.itemKey, 100), "reportingKey": variables.db.nvarchar(nullable(arguments.row, "reportingKey"), 100),
			"type": variables.db.nvarchar(arguments.row.itemType, 40), "prompt": variables.db.ntext(arguments.row.prompt), "help": variables.db.ntext(nullable(arguments.row, "helpText")),
			"order": variables.db.integer(arguments.row.displayOrder), "required": variables.db.bit(arguments.row.required), "settings": variables.db.ntext(arguments.row.settingsJson), "active": variables.db.bit(arguments.row.active)
		};
		if (len(arguments.existingId)) {
			params["id"] = variables.db.guid(arguments.existingId);
			variables.db.run(
				"UPDATE [icf].[item_definition] SET section_id = :sectionId, response_set_id = :setId, reporting_key = :reportingKey, item_type = :type, prompt = :prompt, help_text = :help, display_order = :order, required = :required, settings_json = :settings, active = :active, updated_at = SYSUTCDATETIME() WHERE item_id = :id",
				params
			);
			return arguments.existingId;
		}
		var id = variables.db.newGuid();
		params["id"] = variables.db.guid(id);
		variables.db.run(
			"INSERT INTO [icf].[item_definition] (item_id, version_id, section_id, response_set_id, item_key, reporting_key, item_type, prompt, help_text, display_order, required, settings_json, active)
			 VALUES (:id, :versionId, :sectionId, :setId, :key, :reportingKey, :type, :prompt, :help, :order, :required, :settings, :active)",
			params
		);
		return id;
	}

	public void function deleteItem(required string itemId) {
		variables.db.run("DELETE FROM [icf].[item_definition] WHERE item_id = :id", { "id": variables.db.guid(arguments.itemId) });
	}

	// ---- placements (instrument_dimension) --------------------------------------------------

	public void function upsertPlacement(required string versionId, required string dimensionId, required boolean exists, required struct row, string sectionId = "") {
		var params = {
			"versionId": variables.db.guid(arguments.versionId), "dimensionId": variables.db.guid(arguments.dimensionId), "sectionId": variables.db.guid(arguments.sectionId),
			"order": variables.db.integer(arguments.row.displayOrder), "required": variables.db.bit(arguments.row.required), "ruleKey": variables.db.nvarchar(nullable(arguments.row, "ruleKey"), 100),
			"labelOverride": variables.db.nvarchar(nullable(arguments.row, "labelOverride"), 200), "settings": variables.db.ntext(arguments.row.settingsJson)
		};
		if (arguments.exists) {
			variables.db.run(
				"UPDATE [icf].[instrument_dimension] SET section_id = :sectionId, display_order = :order, required = :required, rule_key = :ruleKey, label_override = :labelOverride, settings_json = :settings, updated_at = SYSUTCDATETIME()
				 WHERE version_id = :versionId AND dimension_id = :dimensionId",
				params
			);
			return;
		}
		variables.db.run(
			"INSERT INTO [icf].[instrument_dimension] (version_id, dimension_id, section_id, display_order, required, rule_key, label_override, settings_json)
			 VALUES (:versionId, :dimensionId, :sectionId, :order, :required, :ruleKey, :labelOverride, :settings)",
			params
		);
	}

	public void function deletePlacement(required string versionId, required string dimensionId) {
		variables.db.run("DELETE FROM [icf].[instrument_dimension] WHERE version_id = :versionId AND dimension_id = :dimensionId",
			{ "versionId": variables.db.guid(arguments.versionId), "dimensionId": variables.db.guid(arguments.dimensionId) });
	}

	// ---- read back as normalized definitions ------------------------------------------------

	public struct function loadNormalizedDefinitions(required string versionId) {
		var p = { "id": variables.db.guid(arguments.versionId) };
		var m = variables.mapper;
		var normalizer = new icfwalk.instrument.ConfigNormalizer();

		var sq = variables.db.run("SELECT section_id, parent_section_id, section_key, display_order, title, instructions, notes_enabled, settings_json, active FROM [icf].[section_definition] WHERE version_id = :id", p);
		var sectionKeyById = {};
		for (var r = 1; r <= sq.recordCount; r++) sectionKeyById[uCase(sq.section_id[r])] = sq.section_key[r];
		var sections = [];
		for (var r = 1; r <= sq.recordCount; r++) {
			var parentKey = len(sq.parent_section_id[r]) && structKeyExists(sectionKeyById, uCase(sq.parent_section_id[r])) ? sectionKeyById[uCase(sq.parent_section_id[r])] : "";
			arrayAppend(sections, m.sectionFromRow(rowStruct(sq, r), parentKey));
		}
		normalizer.sortBy(sections, ["sectionKey"]);

		var rq = variables.db.run("SELECT response_set_id, response_set_key, name, selection_mode, settings_json, active FROM [icf].[response_set] WHERE version_id = :id", p);
		var setKeyById = {};
		var setSettingsById = {};
		var responseSets = [];
		for (var r = 1; r <= rq.recordCount; r++) {
			setKeyById[uCase(rq.response_set_id[r])] = rq.response_set_key[r];
			setSettingsById[uCase(rq.response_set_id[r])] = m.settingsOf(rq.settings_json[r]);
			arrayAppend(responseSets, m.responseSetFromRow(rowStruct(rq, r)));
		}
		normalizer.sortBy(responseSets, ["setKey"]);

		var oq = variables.db.run(
			"SELECT o.option_id, o.response_set_id, o.option_key, o.stored_code, o.label, o.definition, o.numeric_score, o.is_na, o.display_order, o.active
			 FROM [icf].[response_option] o JOIN [icf].[response_set] s ON s.response_set_id = o.response_set_id WHERE s.version_id = :id", p);
		var responseOptions = [];
		for (var r = 1; r <= oq.recordCount; r++) {
			var sid = uCase(oq.response_set_id[r]);
			arrayAppend(responseOptions, m.optionFromRow(rowStruct(oq, r), setKeyById[sid], setSettingsById[sid]));
		}
		normalizer.sortBy(responseOptions, ["setKey", "optionKey"]);

		var ruq = variables.db.run("SELECT rule_id, rule_key, target_type, target_key, effect, conditions_json, active FROM [icf].[rule_definition] WHERE version_id = :id", p);
		var rules = [];
		for (var r = 1; r <= ruq.recordCount; r++) arrayAppend(rules, m.ruleFromRow(rowStruct(ruq, r)));
		normalizer.sortBy(rules, ["ruleKey"]);

		// Dimensions placed on this version (global rows), and their values.
		var dq = variables.db.run(
			"SELECT d.dimension_id, d.code, d.label, d.data_type, d.reportable, d.sensitive, d.settings_json, d.active
			 FROM [icf].[dimension_definition] d JOIN [icf].[instrument_dimension] p ON p.dimension_id = d.dimension_id WHERE p.version_id = :id", p);
		var dimensions = [];
		var dimensionValues = [];
		var dimCodeById = {};
		for (var r = 1; r <= dq.recordCount; r++) {
			var did = uCase(dq.dimension_id[r]);
			dimCodeById[did] = dq.code[r];
			arrayAppend(dimensions, m.dimensionFromRow(rowStruct(dq, r)));
			var dimSettings = m.settingsOf(dq.settings_json[r]);
			var vq = variables.db.run("SELECT value_id, value_code, label, display_order, effective_start, effective_end, active FROM [icf].[dimension_value] WHERE dimension_id = :id", { "id": variables.db.guid(did) });
			for (var vr = 1; vr <= vq.recordCount; vr++) arrayAppend(dimensionValues, m.dimensionValueFromRow(rowStruct(vq, vr), dq.code[r], dimSettings));
		}
		normalizer.sortBy(dimensions, ["code"]);
		normalizer.sortBy(dimensionValues, ["dimensionCode", "valueCode"]);

		var pq = variables.db.run("SELECT dimension_id, section_id, display_order, required, rule_key, label_override, settings_json FROM [icf].[instrument_dimension] WHERE version_id = :id", p);
		var placements = [];
		for (var r = 1; r <= pq.recordCount; r++) {
			var sectionKey = len(pq.section_id[r]) && structKeyExists(sectionKeyById, uCase(pq.section_id[r])) ? sectionKeyById[uCase(pq.section_id[r])] : "";
			arrayAppend(placements, m.placementFromRow(rowStruct(pq, r), dimCodeById[uCase(pq.dimension_id[r])], sectionKey));
		}
		normalizer.sortBy(placements, ["dimensionCode"]);

		var iq = variables.db.run("SELECT item_id, section_id, response_set_id, item_key, reporting_key, item_type, prompt, help_text, display_order, required, settings_json, active FROM [icf].[item_definition] WHERE version_id = :id", p);
		var items = [];
		for (var r = 1; r <= iq.recordCount; r++) {
			var sk = structKeyExists(sectionKeyById, uCase(iq.section_id[r])) ? sectionKeyById[uCase(iq.section_id[r])] : "";
			var rk = len(iq.response_set_id[r]) && structKeyExists(setKeyById, uCase(iq.response_set_id[r])) ? setKeyById[uCase(iq.response_set_id[r])] : "";
			arrayAppend(items, m.itemFromRow(rowStruct(iq, r), sk, rk));
		}
		normalizer.sortBy(items, ["itemKey"]);

		return {
			"sections": sections, "items": items, "responseSets": responseSets, "responseOptions": responseOptions,
			"rules": rules, "dimensions": dimensions, "dimensionValues": dimensionValues, "instrumentDimensions": placements
		};
	}

	public struct function countChildren(required string versionId) {
		var p = { "id": variables.db.guid(arguments.versionId) };
		return {
			"sections": variables.db.scalar("SELECT COUNT(*) AS n FROM [icf].[section_definition] WHERE version_id = :id", p),
			"items": variables.db.scalar("SELECT COUNT(*) AS n FROM [icf].[item_definition] WHERE version_id = :id", p),
			"responseSets": variables.db.scalar("SELECT COUNT(*) AS n FROM [icf].[response_set] WHERE version_id = :id", p),
			"responseOptions": variables.db.scalar("SELECT COUNT(*) AS n FROM [icf].[response_option] o JOIN [icf].[response_set] s ON s.response_set_id = o.response_set_id WHERE s.version_id = :id", p),
			"rules": variables.db.scalar("SELECT COUNT(*) AS n FROM [icf].[rule_definition] WHERE version_id = :id", p),
			"instrumentDimensions": variables.db.scalar("SELECT COUNT(*) AS n FROM [icf].[instrument_dimension] WHERE version_id = :id", p),
			"dimensions": variables.db.scalar("SELECT COUNT(*) AS n FROM [icf].[dimension_definition]"),
			"dimensionValues": variables.db.scalar("SELECT COUNT(*) AS n FROM [icf].[dimension_value]")
		};
	}

	/**
	 * Removes a version and every child definition regardless of status. Used for DRAFT discard
	 * (after the service verifies status and walk count) and for test fixture cleanup only.
	 */
	public void function deleteVersionCascadeUnchecked(required string versionId) {
		var p = { "id": variables.db.guid(arguments.versionId) };
		variables.db.run("DELETE FROM [icf].[instrument_dimension] WHERE version_id = :id", p);
		variables.db.run("DELETE FROM [icf].[item_definition] WHERE version_id = :id", p);
		variables.db.run("DELETE FROM [icf].[rule_definition] WHERE version_id = :id", p);
		variables.db.run("DELETE o FROM [icf].[response_option] o JOIN [icf].[response_set] s ON s.response_set_id = o.response_set_id WHERE s.version_id = :id", p);
		variables.db.run("DELETE FROM [icf].[response_set] WHERE version_id = :id", p);
		var sq = variables.db.run("SELECT section_id FROM [icf].[section_definition] WHERE version_id = :id", p);
		var ids = [];
		for (var r = 1; r <= sq.recordCount; r++) arrayAppend(ids, uCase(sq.section_id[r]));
		deleteSections(ids);
		variables.db.run("DELETE FROM [icf].[instrument_version] WHERE version_id = :id", p);
	}

	// ---- helpers ----------------------------------------------------------------------------

	private struct function rowStruct(required query q, required numeric r) {
		var s = {};
		for (var col in listToArray(arguments.q.columnList)) {
			s[lCase(col)] = arguments.q[col][arguments.r];
		}
		return s;
	}

	private any function nullable(required struct row, required string key) {
		if (structKeyExists(arguments.row, arguments.key) && !isNull(arguments.row[arguments.key])) return arguments.row[arguments.key];
		return javaCast("null", "");
	}

	private any function instantOrNull(any value) {
		if (isNull(arguments.value) || !isSimpleValue(arguments.value) || !len(trim(arguments.value))) return javaCast("null", "");
		return variables.json.parseInstant(arguments.value);
	}
}
