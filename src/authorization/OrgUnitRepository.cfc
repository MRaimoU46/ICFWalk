/**
 * icf.org_unit access: the active organizational tree (district → schools), descendant resolution,
 * and idempotent upsert by org_unit_code for bootstrap/maintenance.
 */
component output="false" {

	/*
	 * Not every value a controlled list defines identifies anything. A dimension that allows free
	 * text carries a value coded "other" whose whole purpose is to mean "none of these, see the
	 * typed text" (the convention WalkPayloadValidator reads to reveal that field). It names no
	 * school, so it can never be a school's identity: mapping a unit to it would label that unit's
	 * walks "Other", and because the mapping is unique on (dimension, value) the first unit to
	 * claim it would lock every other unit out of a value that identifies none of them.
	 *
	 * A SCHOOL unit with no identifying value stays unmapped, which the walk path already handles
	 * by failing closed. That is strictly better than an identity that identifies nothing.
	 */
	variables.NON_IDENTIFYING_VALUE_CODES = ["other"];

	/** False for a controlled-list value that names no particular thing, such as "other". */
	public boolean function isIdentifyingValueCode(required string valueCode) {
		return !arrayFindNoCase(variables.NON_IDENTIFYING_VALUE_CODES, trim(arguments.valueCode));
	}

	public OrgUnitRepository function init(required any db) {
		variables.db = arguments.db;
		return this;
	}

	/** Active org units keyed by upper-case GUID: { id, code, type, name, parentId }. */
	public struct function loadActiveTree() {
		var q = variables.db.run("SELECT org_unit_id, parent_org_unit_id, org_unit_code, org_unit_type, name FROM [icf].[org_unit] WHERE active = 1");
		var out = {};
		for (var r = 1; r <= q.recordCount; r++) {
			var id = uCase(q.org_unit_id[r]);
			out[id] = { "id": id, "code": q.org_unit_code[r], "type": q.org_unit_type[r], "name": q.name[r], "parentId": len(q.parent_org_unit_id[r]) ? uCase(q.parent_org_unit_id[r]) : "" };
		}
		return out;
	}

	/** The unit itself plus every active descendant (in-memory walk of the active tree). */
	public array function descendantIds(required string orgUnitId, required struct tree) {
		var root = uCase(arguments.orgUnitId);
		var out = [];
		if (!structKeyExists(arguments.tree, root)) return out;
		var childrenOf = {};
		for (var id in structKeyArray(arguments.tree)) {
			var parent = arguments.tree[id].parentId;
			if (!len(parent)) continue;
			if (!structKeyExists(childrenOf, parent)) childrenOf[parent] = [];
			arrayAppend(childrenOf[parent], id);
		}
		var queue = [root];
		var seen = {};
		while (arrayLen(queue)) {
			var current = queue[1];
			arrayDeleteAt(queue, 1);
			if (structKeyExists(seen, current)) continue;
			seen[current] = true;
			arrayAppend(out, current);
			if (structKeyExists(childrenOf, current)) {
				for (var child in childrenOf[current]) arrayAppend(queue, child);
			}
		}
		return out;
	}

	public struct function findByCode(required string code) {
		var q = variables.db.run("SELECT org_unit_id, parent_org_unit_id, org_unit_code, org_unit_type, name, active FROM [icf].[org_unit] WHERE org_unit_code = :code", { "code": variables.db.nvarchar(arguments.code, 50) });
		if (!q.recordCount) return {};
		return { "id": uCase(q.org_unit_id[1]), "code": q.org_unit_code[1], "type": q.org_unit_type[1], "name": q.name[1], "parentId": len(q.parent_org_unit_id[1]) ? uCase(q.parent_org_unit_id[1]) : "", "active": (isBoolean(q.active[1]) && q.active[1]) ? true : false };
	}

	public struct function findById(required string orgUnitId) {
		var q = variables.db.run("SELECT org_unit_id, parent_org_unit_id, org_unit_code, org_unit_type, name, active FROM [icf].[org_unit] WHERE org_unit_id = :id", { "id": variables.db.guid(arguments.orgUnitId) });
		if (!q.recordCount) return {};
		return { "id": uCase(q.org_unit_id[1]), "code": q.org_unit_code[1], "type": q.org_unit_type[1], "name": q.name[1], "parentId": len(q.parent_org_unit_id[1]) ? uCase(q.parent_org_unit_id[1]) : "", "active": (isBoolean(q.active[1]) && q.active[1]) ? true : false };
	}

	/**
	 * Inserts or updates one org unit by code. parentId may be empty for a root unit.
	 */
	public string function upsert(required string code, required string type, required string name, string parentId = "", boolean active = true) {
		var existing = findByCode(arguments.code);
		if (!structIsEmpty(existing)) {
			if (len(arguments.parentId) && uCase(arguments.parentId) == existing.id) {
				throw(type = "ICFWalk.Validation", message = "An org unit cannot be its own parent.", errorcode = "ORG_UNIT_SELF_PARENT");
			}
			variables.db.run(
				"UPDATE [icf].[org_unit] SET parent_org_unit_id = :parent, org_unit_type = :type, name = :name, active = :active, updated_at = SYSUTCDATETIME() WHERE org_unit_id = :id",
				{ "id": variables.db.guid(existing.id), "parent": variables.db.guid(arguments.parentId), "type": variables.db.nvarchar(arguments.type, 30), "name": variables.db.nvarchar(arguments.name, 200), "active": variables.db.bit(arguments.active) }
			);
			return existing.id;
		}
		var id = variables.db.newGuid();
		variables.db.run(
			"INSERT INTO [icf].[org_unit] (org_unit_id, parent_org_unit_id, org_unit_code, org_unit_type, name, active) VALUES (:id, :parent, :code, :type, :name, :active)",
			{ "id": variables.db.guid(id), "parent": variables.db.guid(arguments.parentId), "code": variables.db.nvarchar(arguments.code, 50), "type": variables.db.nvarchar(arguments.type, 30), "name": variables.db.nvarchar(arguments.name, 200), "active": variables.db.bit(arguments.active) }
		);
		return id;
	}

	// ---- org unit -> instrument dimension value mapping (migration 005) ------------------------

	/*
	 * The identity relationship between a SCHOOL org unit and the instrument's School dimension
	 * value is an explicit stored row, never a comparison of an org_unit_code with a value code.
	 * icf.org_unit_dimension_map is unique on (dimension_code, value_code), so one School value
	 * belongs to at most one org unit, and on (org_unit_id, dimension_code), so one unit carries at
	 * most one School value. A unit with no row is unmapped and the walk path fails closed.
	 */

	/** { valueCode, source } for one (unit, dimension), or {} when the unit is unmapped. */
	public struct function findDimensionMapping(required string orgUnitId, required string dimensionCode) {
		var q = variables.db.run(
			"SELECT value_code, source FROM [icf].[org_unit_dimension_map] WHERE org_unit_id = :id AND dimension_code = :code",
			{ "id": variables.db.guid(arguments.orgUnitId), "code": variables.db.nvarchar(arguments.dimensionCode, 100) }
		);
		if (!q.recordCount) return {};
		return { "valueCode": q.value_code[1], "source": q.source[1] };
	}

	/** The mapped org unit for one dimension value, or {} when no unit claims it. */
	public struct function findUnitByDimensionValue(required string dimensionCode, required string valueCode) {
		var q = variables.db.run(
			"SELECT m.org_unit_id, m.source FROM [icf].[org_unit_dimension_map] m WHERE m.dimension_code = :code AND m.value_code = :value",
			{ "code": variables.db.nvarchar(arguments.dimensionCode, 100), "value": variables.db.nvarchar(arguments.valueCode, 100) }
		);
		if (!q.recordCount) return {};
		return { "orgUnitId": uCase(q.org_unit_id[1]), "source": q.source[1] };
	}

	/** Every mapping for one dimension, keyed by upper-case org unit id. */
	public struct function loadDimensionMappings(required string dimensionCode) {
		var q = variables.db.run(
			"SELECT org_unit_id, value_code, source FROM [icf].[org_unit_dimension_map] WHERE dimension_code = :code",
			{ "code": variables.db.nvarchar(arguments.dimensionCode, 100) }
		);
		var out = {};
		for (var r = 1; r <= q.recordCount; r++) out[uCase(q.org_unit_id[r])] = { "valueCode": q.value_code[r], "source": q.source[r] };
		return out;
	}

	/**
	 * Writes one mapping. The caller validates the value against the instrument first; this method
	 * enforces the facts that must hold however the mapping was declared. A value already mapped to
	 * another unit is refused rather than moved, so an import can never silently relabel a school,
	 * and a non-identifying value is refused outright, so no caller can store one by any route.
	 */
	public void function upsertDimensionMapping(required string orgUnitId, required string dimensionCode, required string valueCode, required string source) {
		if (!isIdentifyingValueCode(arguments.valueCode)) {
			throw(
				type = "ICFWalk.Validation",
				message = "Dimension value '" & arguments.valueCode & "' does not identify a particular org unit and cannot be stored as one's identity mapping.",
				errorcode = "ORG_UNIT_DIMENSION_VALUE_NOT_IDENTIFYING"
			);
		}
		var claimed = findUnitByDimensionValue(arguments.dimensionCode, arguments.valueCode);
		if (!structIsEmpty(claimed) && claimed.orgUnitId != uCase(arguments.orgUnitId)) {
			throw(
				type = "ICFWalk.Validation",
				message = "Dimension value '" & arguments.valueCode & "' is already mapped to another org unit.",
				errorcode = "ORG_UNIT_DIMENSION_VALUE_TAKEN"
			);
		}
		var params = {
			"id": variables.db.guid(arguments.orgUnitId),
			"code": variables.db.nvarchar(arguments.dimensionCode, 100),
			"value": variables.db.nvarchar(arguments.valueCode, 100),
			"source": variables.db.nvarchar(arguments.source, 30)
		};
		var existing = findDimensionMapping(arguments.orgUnitId, arguments.dimensionCode);
		if (structIsEmpty(existing)) {
			variables.db.run("INSERT INTO [icf].[org_unit_dimension_map] (org_unit_id, dimension_code, value_code, source) VALUES (:id, :code, :value, :source)", params);
			return;
		}
		variables.db.run(
			"UPDATE [icf].[org_unit_dimension_map] SET value_code = :value, source = :source, updated_at = SYSUTCDATETIME() WHERE org_unit_id = :id AND dimension_code = :code",
			params
		);
	}

	public void function deleteDimensionMappings(required string orgUnitId) {
		variables.db.run("DELETE FROM [icf].[org_unit_dimension_map] WHERE org_unit_id = :id", { "id": variables.db.guid(arguments.orgUnitId) });
	}

	/** Active SCHOOL units, for the alignment pass and for operator reporting. */
	public array function activeSchoolUnits() {
		var q = variables.db.run("SELECT org_unit_id, org_unit_code, name FROM [icf].[org_unit] WHERE active = 1 AND org_unit_type = N'SCHOOL' ORDER BY org_unit_code");
		var out = [];
		for (var r = 1; r <= q.recordCount; r++) arrayAppend(out, { "id": uCase(q.org_unit_id[r]), "code": q.org_unit_code[r], "name": q.name[r] });
		return out;
	}

	/** Test/maintenance helper: removes an org unit that nothing references. */
	public void function deleteUnreferenced(required string orgUnitId) {
		deleteDimensionMappings(arguments.orgUnitId);
		variables.db.run("DELETE FROM [icf].[org_unit] WHERE org_unit_id = :id", { "id": variables.db.guid(arguments.orgUnitId) });
	}
}
