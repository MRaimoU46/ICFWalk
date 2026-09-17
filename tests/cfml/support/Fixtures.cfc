/**
 * Synthetic identity/authorization fixtures for specs. Everything is prefixed with a per-run tag
 * so parallel or repeated runs never collide, and remove() deletes it all (walks, assignments,
 * users, org units) in dependency order. No real staff or student data.
 */
component output="false" {

	public Fixtures function init(required struct container, required string tag) {
		variables.c = arguments.container;
		variables.tag = arguments.tag;
		variables.orgUnitIds = [];
		variables.userIds = [];
		variables.walkIds = [];
		return this;
	}

	public string function tag() { return variables.tag; }

	public string function orgUnit(required string code, required string type, string parentId = "", boolean active = true) {
		var id = variables.c.orgUnitRepository.upsert(variables.tag & "-" & arguments.code, arguments.type, "Fixture " & arguments.code, arguments.parentId, arguments.active);
		arrayAppend(variables.orgUnitIds, id);
		return id;
	}

	public struct function user(required string name, boolean active = true) {
		var subject = variables.tag & "-" & arguments.name;
		var u = variables.c.userRepository.provision(subject, "Fixture " & arguments.name, "");
		if (!arguments.active) variables.c.userRepository.setActive(u.userId, false);
		arrayAppend(variables.userIds, u.userId);
		return variables.c.userRepository.findById(u.userId);
	}

	public string function assign(required string userId, required string roleCode, required string orgUnitId, boolean includeDescendants = false, any effectiveStart, any effectiveEnd) {
		var role = variables.c.roleScopeRepository.findRoleByCode(arguments.roleCode);
		return variables.c.roleScopeRepository.assign(arguments.userId, role.roleId, arguments.orgUnitId, arguments.includeDescendants, isNull(arguments.effectiveStart) ? "" : arguments.effectiveStart, isNull(arguments.effectiveEnd) ? "" : arguments.effectiveEnd, "");
	}

	/** Inserts a bare walk row pinned to the seeded version (no responses). */
	public string function walk(required string orgUnitId, required string ownerUserId, string status = "DRAFT") {
		var db = variables.c.db;
		var v = db.run("SELECT TOP 1 version_id FROM [icf].[instrument_version] ORDER BY created_at DESC");
		var id = db.newGuid();
		db.run("INSERT INTO [icf].[walk] (walk_id, version_id, org_unit_id, owner_user_id, status) VALUES (:id, :version, :org, :owner, :status)",
			{ "id": db.guid(id), "version": db.guid(uCase(v.version_id[1])), "org": db.guid(arguments.orgUnitId), "owner": db.guid(arguments.ownerUserId), "status": db.nvarchar(arguments.status, 20) });
		arrayAppend(variables.walkIds, id);
		return id;
	}

	public struct function principal(required string userId) {
		return variables.c.authorizationService.principalFor(variables.c.userRepository.findById(arguments.userId));
	}

	/** Deletes a walk and its child rows (responses, dimension values, revisions, mutations, audit). */
	public void function deleteWalk(required string walkId) {
		var db = variables.c.db;
		var p = { "id": db.guid(arguments.walkId) };
		db.run("DELETE FROM [icf].[walk_mutation] WHERE walk_id = :id", p);
		db.run("DELETE FROM [icf].[walk_revision] WHERE walk_id = :id", p);
		db.run("DELETE s FROM [icf].[walk_response_selection] s JOIN [icf].[walk_response] r ON r.response_id = s.response_id WHERE r.walk_id = :id", p);
		db.run("DELETE FROM [icf].[walk_response] WHERE walk_id = :id", p);
		db.run("DELETE FROM [icf].[walk_dimension_value] WHERE walk_id = :id", p);
		db.run("DELETE FROM [icf].[audit_event] WHERE entity_type = N'WALK' AND entity_id = :id", p);
		db.run("DELETE FROM [icf].[walk] WHERE walk_id = :id", p);
	}

	public void function remove() {
		var db = variables.c.db;
		for (var id in variables.walkIds) deleteWalk(id);
		for (var id in variables.userIds) {
			var owned = db.run("SELECT walk_id FROM [icf].[walk] WHERE owner_user_id = :id", { "id": db.guid(id) });
			for (var r = 1; r <= owned.recordCount; r++) deleteWalk(owned.walk_id[r]);
			variables.c.roleScopeRepository.deleteAssignmentsForUser(id);
			db.run("DELETE FROM [icf].[audit_event] WHERE actor_user_id = :id OR entity_id = :id", { "id": db.guid(id) });
			db.run("DELETE FROM [icf].[app_user] WHERE user_id = :id", { "id": db.guid(id) });
		}
		// Children before parents.
		for (var i = arrayLen(variables.orgUnitIds); i >= 1; i--) {
			db.run("DELETE FROM [icf].[audit_event] WHERE entity_id = :id", { "id": db.guid(variables.orgUnitIds[i]) });
			variables.c.orgUnitRepository.deleteUnreferenced(variables.orgUnitIds[i]);
		}
	}
}
