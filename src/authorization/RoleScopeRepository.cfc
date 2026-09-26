/**
 * icf.app_role and icf.user_role_scope access. Effective-dated filtering happens in SQL using the
 * database clock (SYSUTCDATETIME) so application and database agree on "now".
 */
component output="false" {

	public RoleScopeRepository function init(required any db) {
		variables.db = arguments.db;
		return this;
	}

	public struct function findRoleByCode(required string roleCode) {
		var q = variables.db.run("SELECT role_id, role_code, scope_type, active FROM [icf].[app_role] WHERE role_code = :code", { "code": variables.db.nvarchar(arguments.roleCode, 60) });
		if (!q.recordCount) return {};
		return { "roleId": uCase(q.role_id[1]), "roleCode": q.role_code[1], "scopeType": q.scope_type[1], "active": (isBoolean(q.active[1]) && q.active[1]) ? true : false };
	}

	/**
	 * Currently effective assignments for a user: role active, org unit active, effective_start in
	 * the past, effective_end null or in the future.
	 */
	public array function effectiveAssignments(required string userId) {
		var q = variables.db.run(
			"SELECT s.user_role_scope_id, s.org_unit_id, s.include_descendants, s.effective_start, s.effective_end,
			        r.role_code, r.scope_type, r.can_create_walk, r.can_open_walk_details, r.can_edit_owned_walks,
			        r.can_view_aggregate_reports, r.can_manage_instruments, o.org_unit_code, o.name AS org_unit_name
			 FROM [icf].[user_role_scope] s
			 JOIN [icf].[app_role] r ON r.role_id = s.role_id
			 JOIN [icf].[org_unit] o ON o.org_unit_id = s.org_unit_id
			 WHERE s.user_id = :userId
			   AND r.active = 1
			   AND o.active = 1
			   AND s.effective_start <= SYSUTCDATETIME()
			   AND (s.effective_end IS NULL OR s.effective_end > SYSUTCDATETIME())",
			{ "userId": variables.db.guid(arguments.userId) }
		);
		var out = [];
		for (var r = 1; r <= q.recordCount; r++) {
			arrayAppend(out, {
				"assignmentId": uCase(q.user_role_scope_id[r]),
				"roleCode": q.role_code[r],
				"scopeType": q.scope_type[r],
				"orgUnitId": uCase(q.org_unit_id[r]),
				"orgUnitCode": q.org_unit_code[r],
				"orgUnitName": q.org_unit_name[r],
				"includeDescendants": flag(q.include_descendants[r]),
				"effectiveStart": q.effective_start[r],
				"effectiveEnd": isDate(q.effective_end[r]) ? q.effective_end[r] : "",
				"flags": {
					"canCreateWalk": flag(q.can_create_walk[r]),
					"canOpenWalkDetails": flag(q.can_open_walk_details[r]),
					"canEditOwnedWalks": flag(q.can_edit_owned_walks[r]),
					"canViewAggregateReports": flag(q.can_view_aggregate_reports[r]),
					"canManageInstruments": flag(q.can_manage_instruments[r])
				}
			});
		}
		return out;
	}

	public string function assign(required string userId, required string roleId, required string orgUnitId, boolean includeDescendants = false, any effectiveStart, any effectiveEnd, string createdByUserId = "") {
		var id = variables.db.newGuid();
		var startParam = (!structKeyExists(arguments, "effectiveStart") || (isSimpleValue(arguments.effectiveStart) && !len(arguments.effectiveStart)))
			? { "value": "", "cfsqltype": "cf_sql_timestamp", "null": true }
			: variables.db.timestamp(arguments.effectiveStart);
		var startIsNull = structKeyExists(startParam, "null") && startParam.null;
		// An assignment created "now" is effective from one second before creation: datetime2(3) rounds
		// SYSUTCDATETIME() to the millisecond, which could otherwise place effective_start a fraction
		// of a millisecond in the future and make the new assignment ineffective for that instant.
		var startClause = startIsNull ? "DATEADD(second, -1, SYSUTCDATETIME())" : ":start";
		var params = {
			"id": variables.db.guid(id), "userId": variables.db.guid(arguments.userId), "roleId": variables.db.guid(arguments.roleId),
			"orgUnitId": variables.db.guid(arguments.orgUnitId), "desc": variables.db.bit(arguments.includeDescendants),
			"end": (!structKeyExists(arguments, "effectiveEnd") || (isSimpleValue(arguments.effectiveEnd) && !len(arguments.effectiveEnd)))
				? { "value": "", "cfsqltype": "cf_sql_timestamp", "null": true }
				: variables.db.timestamp(arguments.effectiveEnd),
			"createdBy": variables.db.guid(arguments.createdByUserId)
		};
		if (!startIsNull) params["start"] = startParam;
		variables.db.run(
			"INSERT INTO [icf].[user_role_scope] (user_role_scope_id, user_id, role_id, org_unit_id, effective_start, effective_end, include_descendants, created_by_user_id)
			 VALUES (:id, :userId, :roleId, :orgUnitId, " & startClause & ", :end, :desc, :createdBy)",
			params
		);
		return id;
	}

	public void function endAssignment(required string assignmentId) {
		// Ends at the last completed millisecond so the assignment is already ineffective for the
		// current instant; CK_user_role_scope_dates requires effective_end > effective_start, so an
		// assignment created in the same millisecond ends one millisecond after its start instead.
		variables.db.run(
			"UPDATE [icf].[user_role_scope]
			 SET effective_end = CASE WHEN DATEADD(millisecond, -1, SYSUTCDATETIME()) > effective_start
			                          THEN DATEADD(millisecond, -1, SYSUTCDATETIME())
			                          ELSE DATEADD(millisecond, 1, effective_start) END
			 WHERE user_role_scope_id = :id AND (effective_end IS NULL OR effective_end > SYSUTCDATETIME())",
			{ "id": variables.db.guid(arguments.assignmentId) });
	}

	public void function deleteAssignmentsForUser(required string userId) {
		variables.db.run("DELETE FROM [icf].[user_role_scope] WHERE user_id = :id", { "id": variables.db.guid(arguments.userId) });
	}

	private boolean function flag(required any value) {
		return (isBoolean(arguments.value) && arguments.value) ? true : false;
	}
}
