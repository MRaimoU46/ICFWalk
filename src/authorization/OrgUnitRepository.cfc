/**
 * icf.org_unit access: the active organizational tree (district → schools), descendant resolution,
 * and idempotent upsert by org_unit_code for bootstrap/maintenance.
 */
component output="false" {

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

	/** Test/maintenance helper: removes an org unit that nothing references. */
	public void function deleteUnreferenced(required string orgUnitId) {
		variables.db.run("DELETE FROM [icf].[org_unit] WHERE org_unit_id = :id", { "id": variables.db.guid(arguments.orgUnitId) });
	}
}
