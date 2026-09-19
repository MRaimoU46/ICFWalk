/**
 * Operator maintenance tasks: import/seed the instrument configuration, list versions, discard a
 * DRAFT, and run the CFML test suite. All actions pass the MaintenanceGuard first. Production
 * administration of instrument versions by signed-in administrators arrives in Phase 6; this
 * controller exists so a clean install can be seeded and verified without a user session.
 */
component output="false" {

	public MaintenanceController function init(required struct container) {
		variables.c = arguments.container;
		return this;
	}

	public struct function importInstrument(required struct req) {
		variables.c.maintenanceGuard.require(arguments.req, "instrument.import");
		var path = variables.c.config.instrumentConfigPath;
		if (structKeyExists(arguments.req.body, "configFile") && len(trim(arguments.req.body.configFile))) {
			path = variables.c.instrumentImportService.resolveConfigFile(arguments.req.body.configFile);
		}
		var result = variables.c.instrumentImportService.importFromFile(path);
		return { "status": result.created ? 201 : 200, "body": result };
	}

	public struct function listVersions(required struct req) {
		variables.c.maintenanceGuard.require(arguments.req, "instrument.versions");
		return { "status": 200, "body": { "versions": variables.c.definitionRepository.listVersions() } };
	}

	public struct function discardDraft(required struct req) {
		variables.c.maintenanceGuard.require(arguments.req, "instrument.discardDraft");
		if (!structKeyExists(arguments.req.body, "versionLabel") || !len(trim(arguments.req.body.versionLabel))) {
			variables.c.errors.validation("versionLabel is required.", "VERSION_LABEL_REQUIRED");
		}
		var instrumentCode = structKeyExists(arguments.req.body, "instrumentCode") && isSimpleValue(arguments.req.body.instrumentCode) ? trim(arguments.req.body.instrumentCode) : "";
		var result = variables.c.instrumentImportService.discardDraft(arguments.req.body.versionLabel, "", instrumentCode);
		return { "status": 200, "body": result };
	}

	/**
	 * Idempotent org-unit import from { "orgUnits": [...] } or { "file": "org-units.example.json" }
	 * (a .json file name inside the instrument configuration directory). Parents are resolved by
	 * code in two passes so document order does not matter.
	 *
	 * A SCHOOL unit may declare `schoolValueCode`: the instrument School dimension value that names
	 * it. That declaration is the identity relationship walks rely on (icf.org_unit_dimension_map,
	 * migration 005) and is validated against the School dimension of the current renderable
	 * instrument version before it is stored. A value already mapped to another unit is refused. A
	 * SCHOOL unit without one stays unmapped and its walks carry no School value; the alignment
	 * endpoint below derives the mapping for deployments whose codes already match.
	 */
	public struct function importOrgUnits(required struct req) {
		variables.c.maintenanceGuard.require(arguments.req, "orgUnits.import");
		var units = [];
		if (structKeyExists(arguments.req.body, "orgUnits") && isArray(arguments.req.body.orgUnits)) {
			units = arguments.req.body.orgUnits;
		} else if (structKeyExists(arguments.req.body, "file") && isSimpleValue(arguments.req.body.file)) {
			var path = variables.c.instrumentImportService.resolveConfigFile(arguments.req.body.file);
			var doc = deserializeJSON(fileRead(path, "utf-8"));
			if (!isStruct(doc) || !structKeyExists(doc, "orgUnits") || !isArray(doc.orgUnits)) variables.c.errors.validation("The file must contain an orgUnits array.", "ORG_UNITS_INVALID");
			units = doc.orgUnits;
		} else {
			variables.c.errors.validation("Provide orgUnits[] or file.", "ORG_UNITS_REQUIRED");
		}
		var repo = variables.c.orgUnitRepository;
		var errors = variables.c.errors;
		var audit = variables.c.auditRepository;
		var result = variables.c.db.transact(function() {
			var ids = {};
			var created = 0;
			var updated = 0;
			var mapped = 0;
			for (var u in units) {
				if (!isStruct(u) || !structKeyExists(u, "code") || !len(trim(u.code)) || !structKeyExists(u, "name") || !len(trim(u.name)) || !structKeyExists(u, "type") || !len(trim(u.type))) {
					errors.validation("Each org unit needs code, type, and name.", "ORG_UNIT_INVALID");
				}
				if (!reFind("^[A-Za-z0-9._-]{1,50}$", u.code)) errors.validation("Org unit code '" & u.code & "' is invalid.", "ORG_UNIT_CODE_INVALID");
				var before = repo.findByCode(u.code);
				var active = structKeyExists(u, "active") && isBoolean(u.active) ? u.active : true;
				ids[u.code] = repo.upsert(u.code, uCase(u.type), u.name, "", active);
				if (structIsEmpty(before)) created++; else updated++;
				if (structKeyExists(u, "schoolValueCode") && !isNull(u.schoolValueCode) && isSimpleValue(u.schoolValueCode) && len(trim(u.schoolValueCode))) {
					if (uCase(u.type) != "SCHOOL") errors.validation("Only a SCHOOL org unit can declare schoolValueCode ('" & u.code & "').", "ORG_UNIT_SCHOOL_VALUE_NOT_SCHOOL");
					mapSchoolValue(ids[u.code], trim(u.schoolValueCode), "EXPLICIT");
					mapped++;
				}
			}
			for (var u in units) {
				var parentCode = structKeyExists(u, "parentCode") && !isNull(u.parentCode) && len(trim(u.parentCode)) ? u.parentCode : "";
				if (!len(parentCode)) continue;
				if (!structKeyExists(ids, parentCode)) {
					var parent = repo.findByCode(parentCode);
					if (structIsEmpty(parent)) errors.validation("Org unit '" & u.code & "' references unknown parent '" & parentCode & "'.", "ORG_UNIT_PARENT_MISSING");
					ids[parentCode] = parent.id;
				}
				var active = structKeyExists(u, "active") && isBoolean(u.active) ? u.active : true;
				repo.upsert(u.code, uCase(u.type), u.name, ids[parentCode], active);
			}
			audit.record("ORG_UNIT", "", "ORG_UNITS_IMPORTED", "", { "count": arrayLen(units), "created": created, "updated": updated, "schoolValuesMapped": mapped });
			return { "imported": arrayLen(units), "created": created, "updated": updated, "schoolValuesMapped": mapped };
		});
		return { "status": 200, "body": result };
	}

	/**
	 * Derives the School dimension mapping for active SCHOOL org units whose `org_unit_code` is
	 * exactly a School dimension value code of the current renderable instrument version, and
	 * reports every unit it could not map.
	 *
	 * This is the one place an org-unit code is compared with a dimension value code, it happens
	 * only when an operator asks for it, and what it produces is a stored, validated mapping row
	 * (source CODE_ALIGNED). The walk path never compares codes: it reads the row. An EXPLICIT row
	 * is never overwritten, and a value another unit already holds is reported, not moved.
	 *
	 * { "dryRun": true } reports what would be written without writing anything. Idempotent.
	 */
	public struct function alignSchoolDimension(required struct req) {
		variables.c.maintenanceGuard.require(arguments.req, "orgUnits.alignSchoolDimension");
		var dryRun = structKeyExists(arguments.req.body, "dryRun") && isBoolean(arguments.req.body.dryRun) && arguments.req.body.dryRun;
		var dimensionCode = variables.c.config.schoolDimensionCode;
		if (!len(dimensionCode)) variables.c.errors.validation("No School dimension code is configured (ICFWALK_SCHOOL_DIMENSION_CODE).", "SCHOOL_DIMENSION_NOT_CONFIGURED");
		var current = variables.c.snapshotService.currentVersion();
		if (structIsEmpty(current)) variables.c.errors.notFound("No renderable instrument version is available.", "INSTRUMENT_NOT_AVAILABLE");
		var model = variables.c.snapshotService.renderModelFor(current.versionId);
		if (!structKeyExists(model.dimensions, dimensionCode)) variables.c.errors.validation("The instrument has no '" & dimensionCode & "' dimension.", "SCHOOL_DIMENSION_NOT_DEFINED");
		var valueCodes = {};
		for (var v in model.dimensions[dimensionCode].values) valueCodes[v.valueCode] = true;
		var repo = variables.c.orgUnitRepository;
		var existing = repo.loadDimensionMappings(dimensionCode);
		var report = { "versionId": current.versionId, "dimensionCode": dimensionCode, "dryRun": dryRun, "mapped": [], "alreadyMapped": [], "unmapped": [] };
		for (var unit in repo.activeSchoolUnits()) {
			var already = structKeyExists(existing, unit.id) ? existing[unit.id] : {};
			if (!structIsEmpty(already)) {
				arrayAppend(report.alreadyMapped, { "orgUnitCode": unit.code, "valueCode": already.valueCode, "source": already.source });
				continue;
			}
			// An exact code match against this version's School values, nothing else. Display names
			// are never consulted.
			if (!structKeyExists(valueCodes, unit.code)) {
				arrayAppend(report.unmapped, { "orgUnitCode": unit.code, "reason": "NO_MATCHING_VALUE_CODE" });
				continue;
			}
			var claimed = repo.findUnitByDimensionValue(dimensionCode, unit.code);
			if (!structIsEmpty(claimed) && claimed.orgUnitId != unit.id) {
				arrayAppend(report.unmapped, { "orgUnitCode": unit.code, "reason": "VALUE_MAPPED_TO_ANOTHER_UNIT" });
				continue;
			}
			if (!dryRun) repo.upsertDimensionMapping(unit.id, dimensionCode, unit.code, "CODE_ALIGNED");
			arrayAppend(report.mapped, { "orgUnitCode": unit.code, "valueCode": unit.code, "source": "CODE_ALIGNED" });
		}
		if (!dryRun && arrayLen(report.mapped)) {
			variables.c.auditRepository.record("ORG_UNIT", "", "ORG_UNIT_SCHOOL_DIMENSION_ALIGNED", "", { "dimensionCode": dimensionCode, "versionId": current.versionId, "mapped": arrayLen(report.mapped), "unmapped": arrayLen(report.unmapped) });
		}
		return { "status": 200, "body": report };
	}

	/**
	 * Stores one declared SCHOOL org unit -> School dimension value mapping after checking that the
	 * value exists in the School dimension of the current renderable instrument version. Without a
	 * renderable version there is nothing to validate against, so the declaration is refused rather
	 * than stored unvalidated.
	 */
	private void function mapSchoolValue(required string orgUnitId, required string valueCode, required string source) {
		var dimensionCode = variables.c.config.schoolDimensionCode;
		if (!len(dimensionCode)) variables.c.errors.validation("No School dimension code is configured (ICFWALK_SCHOOL_DIMENSION_CODE).", "SCHOOL_DIMENSION_NOT_CONFIGURED");
		var current = variables.c.snapshotService.currentVersion();
		if (structIsEmpty(current)) variables.c.errors.validation("No renderable instrument version is available to validate schoolValueCode against.", "INSTRUMENT_NOT_AVAILABLE");
		var model = variables.c.snapshotService.renderModelFor(current.versionId);
		if (!structKeyExists(model.dimensions, dimensionCode)) variables.c.errors.validation("The instrument has no '" & dimensionCode & "' dimension.", "SCHOOL_DIMENSION_NOT_DEFINED");
		var found = false;
		for (var v in model.dimensions[dimensionCode].values) {
			if (compare(v.valueCode, arguments.valueCode) == 0) { found = true; break; }
		}
		if (!found) variables.c.errors.validation("schoolValueCode '" & arguments.valueCode & "' is not a School dimension value of the current instrument version.", "ORG_UNIT_SCHOOL_VALUE_UNKNOWN");
		variables.c.orgUnitRepository.upsertDimensionMapping(arguments.orgUnitId, dimensionCode, arguments.valueCode, arguments.source);
	}

	/** Creates (or returns) the application account for an identity subject. */
	public struct function provisionUser(required struct req) {
		variables.c.maintenanceGuard.require(arguments.req, "identity.provisionUser");
		var b = arguments.req.body;
		if (!structKeyExists(b, "subject") || !len(trim(b.subject))) variables.c.errors.validation("subject is required.", "SUBJECT_REQUIRED");
		var existing = variables.c.userRepository.findBySubject(trim(b.subject));
		if (!structIsEmpty(existing)) return { "status": 200, "body": { "userId": existing.userId, "subject": existing.subject, "created": false } };
		var name = structKeyExists(b, "displayName") && len(trim(b.displayName)) ? trim(b.displayName) : trim(b.subject);
		var email = structKeyExists(b, "email") && isSimpleValue(b.email) ? trim(b.email) : "";
		var user = variables.c.userRepository.provision(trim(b.subject), name, email);
		variables.c.auditRepository.record("USER", user.userId, "USER_PROVISIONED", "", { "source": "maintenance" });
		return { "status": 201, "body": { "userId": user.userId, "subject": user.subject, "created": true } };
	}

	/**
	 * Assigns a role to a user for an org unit:
	 * { subject, roleCode, orgUnitCode, includeDescendants?, effectiveStart?, effectiveEnd? }
	 */
	public struct function assignRole(required struct req) {
		variables.c.maintenanceGuard.require(arguments.req, "identity.assignRole");
		var b = arguments.req.body;
		for (var key in ["subject", "roleCode", "orgUnitCode"]) {
			if (!structKeyExists(b, key) || !isSimpleValue(b[key]) || !len(trim(b[key]))) variables.c.errors.validation(key & " is required.", uCase(key) & "_REQUIRED");
		}
		var user = variables.c.userRepository.findBySubject(trim(b.subject));
		if (structIsEmpty(user)) variables.c.errors.notFound("No user with that subject.", "USER_NOT_FOUND");
		var role = variables.c.roleScopeRepository.findRoleByCode(trim(b.roleCode));
		if (structIsEmpty(role) || !role.active) variables.c.errors.notFound("No active role with that code.", "ROLE_NOT_FOUND");
		var unit = variables.c.orgUnitRepository.findByCode(trim(b.orgUnitCode));
		if (structIsEmpty(unit)) variables.c.errors.notFound("No org unit with that code.", "ORG_UNIT_NOT_FOUND");
		var includeDescendants = structKeyExists(b, "includeDescendants") && isBoolean(b.includeDescendants) && b.includeDescendants;
		// Empty string means "not supplied" (start defaults to now, end to open-ended).
		var start = structKeyExists(b, "effectiveStart") && isSimpleValue(b.effectiveStart) && len(b.effectiveStart) ? variables.c.canonicalJson.parseInstant(b.effectiveStart) : "";
		var end = structKeyExists(b, "effectiveEnd") && isSimpleValue(b.effectiveEnd) && len(b.effectiveEnd) ? variables.c.canonicalJson.parseInstant(b.effectiveEnd) : "";
		var id = variables.c.roleScopeRepository.assign(user.userId, role.roleId, unit.id, includeDescendants, start, end, "");
		variables.c.auditRepository.record("USER", user.userId, "ROLE_ASSIGNED", "", { "assignmentId": id, "roleCode": role.roleCode, "orgUnitId": unit.id, "includeDescendants": includeDescendants, "source": "maintenance" });
		return { "status": 201, "body": { "assignmentId": id, "userId": user.userId, "roleCode": role.roleCode, "orgUnitId": unit.id, "includeDescendants": includeDescendants } };
	}

	/**
	 * Test-only cleanup of HTTP fixture data (users, assignments, walks, org units) whose subject or
	 * code starts with the given tag. Available only where the test runner is enabled (never in
	 * production).
	 */
	public struct function cleanupFixtures(required struct req) {
		variables.c.maintenanceGuard.require(arguments.req, "identity.cleanupFixtures");
		if (!variables.c.config.testsEnabled) variables.c.errors.notFound();
		var b = arguments.req.body;
		if (!structKeyExists(b, "tag") || !reFind("^[A-Za-z0-9-]{6,60}$", b.tag)) variables.c.errors.validation("tag is required.", "TAG_REQUIRED");
		var db = variables.c.db;
		var like = { "value": b.tag & "-%", "cfsqltype": "cf_sql_nvarchar" };
		var removed = db.transact(function() {
			var owned = "SELECT w.walk_id FROM [icf].[walk] w JOIN [icf].[app_user] u ON u.user_id = w.owner_user_id WHERE u.identity_subject LIKE :like";
			db.run("DELETE FROM [icf].[walk_mutation] WHERE walk_id IN (" & owned & ")", { "like": like });
			db.run("DELETE FROM [icf].[walk_revision] WHERE walk_id IN (" & owned & ")", { "like": like });
			db.run("DELETE s FROM [icf].[walk_response_selection] s JOIN [icf].[walk_response] r ON r.response_id = s.response_id WHERE r.walk_id IN (" & owned & ")", { "like": like });
			db.run("DELETE FROM [icf].[walk_response] WHERE walk_id IN (" & owned & ")", { "like": like });
			db.run("DELETE FROM [icf].[walk_dimension_value] WHERE walk_id IN (" & owned & ")", { "like": like });
			db.run("DELETE FROM [icf].[audit_event] WHERE entity_type = N'WALK' AND entity_id IN (" & owned & ")", { "like": like });
			db.run("DELETE FROM [icf].[walk] WHERE walk_id IN (" & owned & ")", { "like": like });
			db.run("DELETE s FROM [icf].[user_role_scope] s JOIN [icf].[app_user] u ON u.user_id = s.user_id WHERE u.identity_subject LIKE :like", { "like": like });
			db.run("DELETE a FROM [icf].[audit_event] a JOIN [icf].[app_user] u ON u.user_id = a.actor_user_id OR u.user_id = a.entity_id WHERE u.identity_subject LIKE :like", { "like": like });
			var users = db.run("DELETE FROM [icf].[app_user] WHERE identity_subject LIKE :like", { "like": like });
			db.run("DELETE a FROM [icf].[audit_event] a JOIN [icf].[org_unit] o ON o.org_unit_id = a.entity_id WHERE o.org_unit_code LIKE :like", { "like": like });
			db.run("DELETE m FROM [icf].[org_unit_dimension_map] m JOIN [icf].[org_unit] o ON o.org_unit_id = m.org_unit_id WHERE o.org_unit_code LIKE :like", { "like": like });
			db.run("DELETE FROM [icf].[org_unit] WHERE org_unit_code LIKE :like AND parent_org_unit_id IS NOT NULL", { "like": like });
			db.run("DELETE FROM [icf].[org_unit] WHERE org_unit_code LIKE :like", { "like": like });
			return true;
		});
		return { "status": 200, "body": { "cleaned": true, "tag": b.tag } };
	}

	public struct function runTests(required struct req) {
		variables.c.maintenanceGuard.require(arguments.req, "tests.run");
		if (!variables.c.config.testsEnabled) {
			variables.c.errors.notFound();
		}
		var filter = structKeyExists(arguments.req.query, "filter") ? arguments.req.query.filter : "";
		var runner = createObject("component", "icfwalktests.TestRunner").init(variables.c);
		var results = runner.run(filter);
		return { "status": 200, "body": results };
	}
}
