/**
 * Centralized server-side authorization.
 *
 * A principal is built per request from the user's currently effective role assignments
 * (icf.user_role_scope joined to icf.app_role, effective-dated, active units only). Each
 * assignment covers its org unit and, when include_descendants = 1, every active descendant. The
 * five role flags from the supplied schema become permissions:
 *
 *   walk.create         can_create_walk             org-scoped
 *   walk.read           can_open_walk_details       org-scoped (individual walk details)
 *   walk.edit_owned     can_edit_owned_walks        org-scoped AND walk.owner_user_id = user
 *   report.view         can_view_aggregate_reports  org-scoped (aggregate only)
 *   instrument.manage   can_manage_instruments      global (scope_type GLOBAL); never grants walks/reports
 *
 * Denials are fail-closed: ICFWalk.Forbidden (403) when the user has no capability at all, and
 * ICFWalk.NotFound (404) when the capability exists but not for the requested unit or record, so
 * record existence outside the caller's scope is never disclosed. Every denial is audited as
 * ACCESS_DENIED with the permission, org unit, and record id only.
 */
component output="false" {

	variables.PERMISSIONS = ["walk.create", "walk.read", "walk.edit_owned", "report.view", "instrument.manage"];
	variables.FLAG_FOR = { "walk.create": "canCreateWalk", "walk.read": "canOpenWalkDetails", "walk.edit_owned": "canEditOwnedWalks", "report.view": "canViewAggregateReports", "instrument.manage": "canManageInstruments" };

	public AuthorizationService function init(required any db, required any orgUnitRepository, required any roleScopeRepository, required any auditRepository, required any logger, required any errors) {
		variables.db = arguments.db;
		variables.orgUnits = arguments.orgUnitRepository;
		variables.roleScopes = arguments.roleScopeRepository;
		variables.audit = arguments.auditRepository;
		variables.logger = arguments.logger;
		variables.errors = arguments.errors;
		return this;
	}

	public array function permissions() { return variables.PERMISSIONS; }

	/**
	 * Builds the principal: assignments with resolved covered units and a permission map of
	 * permission -> struct of covered org unit ids (instrument.manage -> boolean).
	 */
	public struct function principalFor(required struct user) {
		var tree = variables.orgUnits.loadActiveTree();
		var assignments = variables.roleScopes.effectiveAssignments(arguments.user.userId);
		var scoped = {};
		for (var p in variables.PERMISSIONS) scoped[p] = {};
		var manage = false;
		for (var a in assignments) {
			var covered = a.includeDescendants ? variables.orgUnits.descendantIds(a.orgUnitId, tree) : (structKeyExists(tree, a.orgUnitId) ? [a.orgUnitId] : []);
			a["coveredOrgUnitIds"] = covered;
			for (var p in variables.PERMISSIONS) {
				if (!a.flags[variables.FLAG_FOR[p]]) continue;
				if (p == "instrument.manage") { manage = true; continue; }
				for (var id in covered) scoped[p][id] = true;
			}
		}
		var permissions = {};
		for (var p in variables.PERMISSIONS) {
			if (p == "instrument.manage") permissions[p] = manage;
			else permissions[p] = structKeyArray(scoped[p]);
		}
		return {
			"userId": arguments.user.userId,
			"subject": arguments.user.subject,
			"displayName": arguments.user.displayName,
			"email": arguments.user.email,
			"assignments": assignments,
			"permissions": permissions,
			"orgUnitNames": namesFor(tree, permissions)
		};
	}

	/** True when the principal holds the permission anywhere (for global) or for the given unit. */
	public boolean function can(required struct principal, required string permission, string orgUnitId = "") {
		assertKnownPermission(arguments.permission);
		if (arguments.permission == "instrument.manage") return arguments.principal.permissions["instrument.manage"] ? true : false;
		var units = arguments.principal.permissions[arguments.permission];
		if (!len(arguments.orgUnitId)) return arrayLen(units) > 0;
		return arrayContains(units, uCase(arguments.orgUnitId));
	}

	public boolean function hasAnyCapability(required struct principal, required string permission) {
		return can(arguments.principal, arguments.permission);
	}

	/**
	 * Throws unless the principal holds the permission for the unit (or globally). A malformed org
	 * unit id is a validation error; an unknown or out-of-scope unit is NotFound; a missing capability
	 * is Forbidden.
	 */
	public void function requirePermission(required struct principal, required string permission, string orgUnitId = "", string recordType = "", string recordId = "") {
		assertKnownPermission(arguments.permission);
		if (arguments.permission == "instrument.manage") {
			if (!can(arguments.principal, "instrument.manage")) deny(arguments.principal, arguments.permission, "", arguments.recordType, arguments.recordId, "forbidden");
			return;
		}
		if (!hasAnyCapability(arguments.principal, arguments.permission)) {
			deny(arguments.principal, arguments.permission, arguments.orgUnitId, arguments.recordType, arguments.recordId, "forbidden");
		}
		if (!len(arguments.orgUnitId)) return;
		if (!variables.db.isGuid(arguments.orgUnitId)) {
			variables.errors.validation("Invalid organizational unit identifier.", "INVALID_ORG_UNIT");
		}
		if (!can(arguments.principal, arguments.permission, arguments.orgUnitId)) {
			deny(arguments.principal, arguments.permission, arguments.orgUnitId, arguments.recordType, arguments.recordId, "not_found");
		}
	}

	/** Org unit ids the principal may use for the permission (for list filtering). Empty = none. */
	public array function visibleOrgUnitIds(required struct principal, required string permission) {
		assertKnownPermission(arguments.permission);
		if (arguments.permission == "instrument.manage") return [];
		return duplicate(arguments.principal.permissions[arguments.permission]);
	}

	/**
	 * Record-level walk authorization shared by every walk endpoint (Phase 4 onward).
	 * action: "read" (open details), "edit" (owner-only edits), "void".
	 * The walk's org unit and owner are re-resolved from the database; client-supplied ids are
	 * never trusted for scope.
	 */
	public struct function authorizeWalk(required struct principal, required string walkId, required string action) {
		if (!variables.db.isGuid(arguments.walkId)) variables.errors.validation("Invalid walk identifier.", "INVALID_WALK_ID");
		var permission = arguments.action == "read" ? "walk.read" : "walk.edit_owned";
		if (arguments.action != "read" && arguments.action != "edit" && arguments.action != "void") {
			throw(type = "ICFWalk.Validation", message = "Unknown walk action.", errorcode = "INVALID_WALK_ACTION");
		}
		var q = variables.db.run("SELECT walk_id, org_unit_id, owner_user_id, status, version_id FROM [icf].[walk] WHERE walk_id = :id", { "id": variables.db.guid(arguments.walkId) });
		var isOwner = q.recordCount && uCase(q.owner_user_id[1]) == arguments.principal.userId;
		var readable = q.recordCount && (can(arguments.principal, "walk.read", uCase(q.org_unit_id[1])) || (isOwner && can(arguments.principal, "walk.edit_owned", uCase(q.org_unit_id[1]))));
		if (arguments.action == "read") {
			if (!hasAnyCapability(arguments.principal, "walk.read") && !hasAnyCapability(arguments.principal, "walk.edit_owned")) {
				deny(arguments.principal, permission, "", "WALK", arguments.walkId, "forbidden");
			}
			if (!readable) deny(arguments.principal, permission, "", "WALK", arguments.walkId, "not_found");
		} else {
			if (!hasAnyCapability(arguments.principal, "walk.edit_owned")) deny(arguments.principal, permission, "", "WALK", arguments.walkId, "forbidden");
			if (!readable) deny(arguments.principal, permission, "", "WALK", arguments.walkId, "not_found");
			if (!isOwner || !can(arguments.principal, "walk.edit_owned", uCase(q.org_unit_id[1]))) {
				deny(arguments.principal, permission, uCase(q.org_unit_id[1]), "WALK", arguments.walkId, "forbidden");
			}
		}
		return { "walkId": uCase(q.walk_id[1]), "orgUnitId": uCase(q.org_unit_id[1]), "ownerUserId": uCase(q.owner_user_id[1]), "status": q.status[1], "versionId": uCase(q.version_id[1]), "isOwner": isOwner ? true : false };
	}

	/**
	 * Client-supplied org unit id must be a well-formed GUID naming an active unit within the
	 * principal's scope for the permission; returns the canonical id.
	 */
	public string function resolveScopedOrgUnit(required struct principal, required string permission, required string orgUnitId) {
		requirePermission(arguments.principal, arguments.permission, arguments.orgUnitId);
		var unit = variables.orgUnits.findById(arguments.orgUnitId);
		if (structIsEmpty(unit) || !unit.active) deny(arguments.principal, arguments.permission, arguments.orgUnitId, "ORG_UNIT", arguments.orgUnitId, "not_found");
		return unit.id;
	}

	// ---- internals ---------------------------------------------------------------------------

	private void function assertKnownPermission(required string permission) {
		if (!arrayContains(variables.PERMISSIONS, arguments.permission)) {
			throw(type = "ICFWalk.Configuration", message = "Unknown permission '" & arguments.permission & "'.", errorcode = "UNKNOWN_PERMISSION");
		}
	}

	private void function deny(required struct principal, required string permission, required string orgUnitId, required string recordType, required string recordId, required string kind) {
		var details = { "permission": arguments.permission, "kind": arguments.kind };
		if (len(arguments.orgUnitId)) details["orgUnitId"] = uCase(arguments.orgUnitId);
		if (len(arguments.recordType)) details["recordType"] = arguments.recordType;
		if (len(arguments.recordId) && variables.db.isGuid(arguments.recordId)) details["recordId"] = uCase(arguments.recordId);
		variables.logger.warn("authorization.denied", details);
		variables.audit.record(len(arguments.recordType) ? arguments.recordType : "ORG_UNIT", (len(arguments.recordId) && variables.db.isGuid(arguments.recordId)) ? arguments.recordId : (len(arguments.orgUnitId) && variables.db.isGuid(arguments.orgUnitId) ? arguments.orgUnitId : ""), "ACCESS_DENIED", arguments.principal.userId, details);
		if (arguments.kind == "not_found") variables.errors.notFound();
		variables.errors.forbidden("You do not have permission to perform this action.", "FORBIDDEN");
	}

	private struct function namesFor(required struct tree, required struct permissions) {
		var names = {};
		for (var p in structKeyArray(arguments.permissions)) {
			if (!isArray(arguments.permissions[p])) continue;
			for (var id in arguments.permissions[p]) {
				if (structKeyExists(arguments.tree, id)) names[id] = { "code": arguments.tree[id].code, "name": arguments.tree[id].name, "type": arguments.tree[id].type };
			}
		}
		return names;
	}
}
