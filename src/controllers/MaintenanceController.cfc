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

	/**
	 * Imports the instrument configuration as a DRAFT.
	 *
	 * `instrumentCode` and `versionLabel` let an operator import the same document as a separate
	 * instrument or under a separate label. This is what makes the publish path verifiable
	 * end-to-end without publishing (and thereby freezing) the seeded DRAFT every other check reads:
	 * a verification run imports its own instrument, publishes that, and leaves the seed alone.
	 * Both are plain identity overrides -- they rename nothing and reach no other document field --
	 * and the route is behind the maintenance guard, so no session can reach it at all.
	 */
	public struct function importInstrument(required struct req) {
		variables.c.maintenanceGuard.require(arguments.req, "instrument.import");
		var path = variables.c.config.instrumentConfigPath;
		if (structKeyExists(arguments.req.body, "configFile") && len(trim(arguments.req.body.configFile))) {
			path = variables.c.instrumentImportService.resolveConfigFile(arguments.req.body.configFile);
		}
		var overrides = {};
		if (structKeyExists(arguments.req.body, "instrumentCode")) {
			overrides["instrumentCode"] = requireIdentityOverride(arguments.req.body.instrumentCode, "instrumentCode", 60);
		}
		if (structKeyExists(arguments.req.body, "versionLabel")) {
			overrides["versionLabel"] = requireIdentityOverride(arguments.req.body.versionLabel, "versionLabel", 100);
		}
		var result = variables.c.instrumentImportService.importFromFile(path, "", overrides);
		return { "status": result.created ? 201 : 200, "body": result };
	}

	private string function requireIdentityOverride(required any value, required string name, required numeric maxLength) {
		if (!isSimpleValue(arguments.value) || !len(trim(arguments.value)) || len(trim(arguments.value)) > arguments.maxLength) {
			variables.c.errors.validation(arguments.name & " must be 1 to " & arguments.maxLength & " characters.", uCase(arguments.name) & "_INVALID");
		}
		return trim(arguments.value);
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
	 * instrument version before it is stored. A value already mapped to another unit is refused, and
	 * so is one that names no school at all -- the dimension's free-text "other" option is a value
	 * the instrument defines but not an identity anything can have. A SCHOOL unit without a mapping
	 * stays unmapped and its walks carry no School value; the alignment endpoint below reports the
	 * mapping a deployment whose codes already match could confirm.
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
	 * Reports the School dimension mapping an operator could derive for active SCHOOL org units
	 * whose `org_unit_code` is exactly a School dimension value code of the current renderable
	 * instrument version, and writes only the pairs that operator explicitly confirms.
	 *
	 * Code equality is a coincidence, not a decision. It is worth surfacing -- a deployment whose
	 * codes already are the instrument's value codes should not have to retype every school -- but
	 * it is not evidence that a code names the school it matches, so on its own it persists nothing.
	 * The call therefore reports `candidates[]` and stops. To store them the operator sends them
	 * back in `confirm[]` as explicit (orgUnitCode, valueCode) pairs, and each pair is re-derived
	 * and re-validated before it is written: a pair that is no longer a candidate, that names a
	 * different value than the one derived, or that the instrument no longer defines is refused and
	 * reported rather than written.
	 *
	 * What is stored is the instrument's own spelling of the value code, not the org unit's: the
	 * walk path compares the stored code with the pinned version's values exactly (case-sensitively),
	 * so a unit code that matches in every way but case must still store the instrument's form or
	 * the mapping it just wrote would never match again.
	 *
	 * A value that identifies nothing is never a candidate. The School dimension's free-text option
	 * ("other") matches a unit coded "other" by pure string equality, but it names no school, so it
	 * is reported as `NON_IDENTIFYING_VALUE_CODE` and that unit stays unmapped -- which the walk path
	 * already handles by failing closed.
	 *
	 * An EXPLICIT row is never overwritten, and a value another unit already holds is reported, not
	 * moved. { "dryRun": true } is the report with any confirmations ignored. Idempotent.
	 *
	 * Body: { "dryRun"?: true, "confirm"?: [ { "orgUnitCode": "...", "valueCode": "..." } ] }
	 */
	public struct function alignSchoolDimension(required struct req) {
		variables.c.maintenanceGuard.require(arguments.req, "orgUnits.alignSchoolDimension");
		var dryRun = structKeyExists(arguments.req.body, "dryRun") && isBoolean(arguments.req.body.dryRun) && arguments.req.body.dryRun;
		var confirmed = confirmationsOf(arguments.req.body);
		var dimensionCode = variables.c.config.schoolDimensionCode;
		if (!len(dimensionCode)) variables.c.errors.validation("No School dimension code is configured (ICFWALK_SCHOOL_DIMENSION_CODE).", "SCHOOL_DIMENSION_NOT_CONFIGURED");
		var current = variables.c.snapshotService.currentVersion();
		if (structIsEmpty(current)) variables.c.errors.notFound("No renderable instrument version is available.", "INSTRUMENT_NOT_AVAILABLE");
		var model = variables.c.snapshotService.renderModelFor(current.versionId);
		if (!structKeyExists(model.dimensions, dimensionCode)) variables.c.errors.validation("The instrument has no '" & dimensionCode & "' dimension.", "SCHOOL_DIMENSION_NOT_DEFINED");
		// Keyed by the instrument's own code, so a lookup answers with the canonical spelling.
		var canonicalByCode = {};
		for (var v in model.dimensions[dimensionCode].values) canonicalByCode[v.valueCode] = v.valueCode;
		var repo = variables.c.orgUnitRepository;
		var existing = repo.loadDimensionMappings(dimensionCode);
		var report = {
			"versionId": current.versionId, "dimensionCode": dimensionCode, "dryRun": dryRun,
			"confirmationsReceived": structCount(confirmed),
			"candidates": [], "mapped": [], "alreadyMapped": [], "unmapped": [], "refused": []
		};
		for (var unit in repo.activeSchoolUnits()) {
			var already = structKeyExists(existing, unit.id) ? existing[unit.id] : {};
			if (!structIsEmpty(already)) {
				arrayAppend(report.alreadyMapped, { "orgUnitCode": unit.code, "valueCode": already.valueCode, "source": already.source });
				continue;
			}
			// An exact code match against this version's School values, nothing else. Display names
			// are never consulted.
			if (!structKeyExists(canonicalByCode, unit.code)) {
				arrayAppend(report.unmapped, { "orgUnitCode": unit.code, "reason": "NO_MATCHING_VALUE_CODE" });
				continue;
			}
			var canonical = canonicalByCode[unit.code];
			if (!repo.isIdentifyingValueCode(canonical)) {
				arrayAppend(report.unmapped, { "orgUnitCode": unit.code, "reason": "NON_IDENTIFYING_VALUE_CODE" });
				continue;
			}
			var claimed = repo.findUnitByDimensionValue(dimensionCode, canonical);
			if (!structIsEmpty(claimed) && claimed.orgUnitId != unit.id) {
				arrayAppend(report.unmapped, { "orgUnitCode": unit.code, "reason": "VALUE_MAPPED_TO_ANOTHER_UNIT" });
				continue;
			}
			arrayAppend(report.candidates, { "orgUnitCode": unit.code, "valueCode": canonical, "source": "CODE_ALIGNED" });
			if (dryRun || !structKeyExists(confirmed, unit.code)) continue;
			if (compare(confirmed[unit.code], canonical) != 0) {
				// The operator confirmed a different pairing than the one derived here. Writing either
				// would be writing something nobody asked for.
				arrayAppend(report.refused, { "orgUnitCode": unit.code, "valueCode": confirmed[unit.code], "reason": "CONFIRMATION_DOES_NOT_MATCH_CANDIDATE" });
				continue;
			}
			repo.upsertDimensionMapping(unit.id, dimensionCode, canonical, "CODE_ALIGNED");
			arrayAppend(report.mapped, { "orgUnitCode": unit.code, "valueCode": canonical, "source": "CODE_ALIGNED" });
		}
		// A confirmation naming a unit that is not a candidate is never silently dropped.
		var candidateCodes = {};
		for (var c in report.candidates) candidateCodes[c.orgUnitCode] = true;
		for (var code in confirmed) {
			if (structKeyExists(candidateCodes, code)) continue;
			arrayAppend(report.refused, { "orgUnitCode": code, "valueCode": confirmed[code], "reason": "NOT_A_CANDIDATE" });
		}
		if (arrayLen(report.mapped)) {
			variables.c.auditRepository.record("ORG_UNIT", "", "ORG_UNIT_SCHOOL_DIMENSION_ALIGNED", "", { "dimensionCode": dimensionCode, "versionId": current.versionId, "mapped": arrayLen(report.mapped), "candidates": arrayLen(report.candidates), "refused": arrayLen(report.refused), "unmapped": arrayLen(report.unmapped) });
		}
		return { "status": 200, "body": report };
	}

	/**
	 * The confirmed (orgUnitCode -> valueCode) pairs from an alignment request, as a struct keyed by
	 * org unit code. Every entry must name both, so a confirmation can never be read as "map this
	 * unit to whatever you derive".
	 */
	private struct function confirmationsOf(required struct body) {
		if (!structKeyExists(arguments.body, "confirm")) return {};
		if (!isArray(arguments.body.confirm)) variables.c.errors.validation("confirm must be an array of { orgUnitCode, valueCode } pairs.", "ALIGN_CONFIRM_INVALID");
		var out = {};
		for (var pair in arguments.body.confirm) {
			if (!isStruct(pair) || !structKeyExists(pair, "orgUnitCode") || !isSimpleValue(pair.orgUnitCode) || !len(trim(pair.orgUnitCode))
				|| !structKeyExists(pair, "valueCode") || !isSimpleValue(pair.valueCode) || !len(trim(pair.valueCode))) {
				variables.c.errors.validation("Each confirm entry needs orgUnitCode and valueCode.", "ALIGN_CONFIRM_INVALID");
			}
			out[trim(pair.orgUnitCode)] = trim(pair.valueCode);
		}
		return out;
	}

	/**
	 * Stores one declared SCHOOL org unit -> School dimension value mapping after checking that the
	 * value exists in the School dimension of the current renderable instrument version. Without a
	 * renderable version there is nothing to validate against, so the declaration is refused rather
	 * than stored unvalidated.
	 *
	 * A value the instrument defines is not automatically an identity. The free-text escape hatch
	 * ("other") names no school, so declaring it is refused here with the reason the operator needs
	 * (400 ORG_UNIT_SCHOOL_VALUE_NOT_IDENTIFYING) rather than left to the repository's blanket
	 * guard. What is stored is the instrument's own spelling of the code, never the caller's.
	 */
	private void function mapSchoolValue(required string orgUnitId, required string valueCode, required string source) {
		var dimensionCode = variables.c.config.schoolDimensionCode;
		if (!len(dimensionCode)) variables.c.errors.validation("No School dimension code is configured (ICFWALK_SCHOOL_DIMENSION_CODE).", "SCHOOL_DIMENSION_NOT_CONFIGURED");
		var current = variables.c.snapshotService.currentVersion();
		if (structIsEmpty(current)) variables.c.errors.validation("No renderable instrument version is available to validate schoolValueCode against.", "INSTRUMENT_NOT_AVAILABLE");
		var model = variables.c.snapshotService.renderModelFor(current.versionId);
		if (!structKeyExists(model.dimensions, dimensionCode)) variables.c.errors.validation("The instrument has no '" & dimensionCode & "' dimension.", "SCHOOL_DIMENSION_NOT_DEFINED");
		var canonical = "";
		for (var v in model.dimensions[dimensionCode].values) {
			if (compare(v.valueCode, arguments.valueCode) == 0) { canonical = v.valueCode; break; }
		}
		if (!len(canonical)) variables.c.errors.validation("schoolValueCode '" & arguments.valueCode & "' is not a School dimension value of the current instrument version.", "ORG_UNIT_SCHOOL_VALUE_UNKNOWN");
		if (!variables.c.orgUnitRepository.isIdentifyingValueCode(canonical)) {
			variables.c.errors.validation(
				"schoolValueCode '" & canonical & "' is the School dimension's free-text option, not a school. It names no school and cannot be a school's identity.",
				"ORG_UNIT_SCHOOL_VALUE_NOT_IDENTIFYING"
			);
		}
		variables.c.orgUnitRepository.upsertDimensionMapping(arguments.orgUnitId, dimensionCode, canonical, arguments.source);
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
			// Report releases a fixture user created (migration 007), before the walks, which a
			// release's membership references. The database refuses every deletion of a release row
			// (50068), so this verification-only route disables those guards inside its own
			// transaction, deletes in the order the keys and the membership guard allow (cells, blocks,
			// the walks they counted, the release), and enables the guards again before it commits.
			// That needs ALTER on the tables, which a development login has and the production runtime
			// login must not (database/README.md); the route is also disabled wherever the test runner
			// is. The application itself never deletes a release.
			var released = "SELECT r.release_id FROM [icf].[report_release] r JOIN [icf].[app_user] u ON u.user_id = r.released_by_user_id WHERE u.identity_subject LIKE :like";
			db.run(releaseDeleteGuards("DISABLE"));
			db.run("DELETE FROM [icf].[report_release_cell] WHERE release_id IN (" & released & ")", { "like": like });
			db.run("DELETE FROM [icf].[report_release_block] WHERE release_id IN (" & released & ")", { "like": like });
			db.run("DELETE FROM [icf].[report_release_walk] WHERE release_id IN (" & released & ")", { "like": like });
			db.run("DELETE FROM [icf].[report_release] WHERE release_id IN (" & released & ")", { "like": like });
			db.run(releaseDeleteGuards("ENABLE"));
			var owned = "SELECT w.walk_id FROM [icf].[walk] w JOIN [icf].[app_user] u ON u.user_id = w.owner_user_id WHERE u.identity_subject LIKE :like";
			db.run("DELETE FROM [icf].[walk_mutation] WHERE walk_id IN (" & owned & ")", { "like": like });
			db.run("DELETE FROM [icf].[walk_revision] WHERE walk_id IN (" & owned & ")", { "like": like });
			db.run("DELETE s FROM [icf].[walk_response_selection] s JOIN [icf].[walk_response] r ON r.response_id = s.response_id WHERE r.walk_id IN (" & owned & ")", { "like": like });
			db.run("DELETE FROM [icf].[walk_response] WHERE walk_id IN (" & owned & ")", { "like": like });
			db.run("DELETE FROM [icf].[walk_dimension_value] WHERE walk_id IN (" & owned & ")", { "like": like });
			db.run("DELETE FROM [icf].[audit_event] WHERE entity_type = N'WALK' AND entity_id IN (" & owned & ")", { "like": like });
			db.run("DELETE FROM [icf].[walk] WHERE walk_id IN (" & owned & ")", { "like": like });
			// Instrument versions of fixture instruments, whatever status they reached -- before the
			// fixture users, because a published version names its publisher
			// (FK_instrument_version_publisher) and a DRAFT names its creator. This route exists
			// only where the test runner is enabled, which ConfigLoader forces off in production, so
			// it is a verification harness and not a production deletion path: no application code,
			// and no signed-in user, can reach it. It is deliberately scoped to instruments whose
			// own code carries the run tag -- never the seeded ICFWalk instrument.
			var scoped = "SELECT v.version_id FROM [icf].[instrument_version] v JOIN [icf].[instrument] i ON i.instrument_id = v.instrument_id WHERE i.code LIKE :like";
			db.run("DELETE FROM [icf].[instrument_dimension_value] WHERE version_id IN (" & scoped & ")", { "like": like });
			db.run("DELETE FROM [icf].[instrument_dimension] WHERE version_id IN (" & scoped & ")", { "like": like });
			db.run("DELETE FROM [icf].[item_definition] WHERE version_id IN (" & scoped & ")", { "like": like });
			db.run("DELETE FROM [icf].[rule_definition] WHERE version_id IN (" & scoped & ")", { "like": like });
			db.run("DELETE o FROM [icf].[response_option] o JOIN [icf].[response_set] s ON s.response_set_id = o.response_set_id WHERE s.version_id IN (" & scoped & ")", { "like": like });
			db.run("DELETE FROM [icf].[response_set] WHERE version_id IN (" & scoped & ")", { "like": like });
			// Children before parents, without assuming a depth.
			for (var pass = 1; pass <= 12; pass++) {
				db.run(
					"DELETE FROM [icf].[section_definition]
					  WHERE version_id IN (" & scoped & ")
					    AND section_id NOT IN (SELECT parent_section_id FROM [icf].[section_definition] WHERE parent_section_id IS NOT NULL)",
					{ "like": like }
				);
			}
			db.run("DELETE FROM [icf].[audit_event] WHERE entity_type = N'INSTRUMENT_VERSION' AND entity_id IN (" & scoped & ")", { "like": like });
			db.run("DELETE FROM [icf].[instrument_version] WHERE version_id IN (" & scoped & ")", { "like": like });
			db.run("DELETE FROM [icf].[instrument] WHERE code LIKE :like", { "like": like });
			// A fixture user may also have created or published a version of another instrument
			// (the seeded one, for example). Those versions are not this cleanup's to remove, so the
			// reference is released rather than the row deleted.
			db.run("UPDATE [icf].[instrument_version] SET created_by_user_id = NULL WHERE created_by_user_id IN (SELECT user_id FROM [icf].[app_user] WHERE identity_subject LIKE :like)", { "like": like });
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
		// `part` of `of` runs one deterministic slice of the specs, so a growing suite does not have
		// to finish inside one HTTP client's response-header timeout. See TestRunner.run.
		var part = structKeyExists(arguments.req.query, "part") && isNumeric(arguments.req.query.part) ? int(arguments.req.query.part) : 0;
		var of = structKeyExists(arguments.req.query, "of") && isNumeric(arguments.req.query.of) ? int(arguments.req.query.of) : 0;
		if (of > 0 && (part < 1 || part > of)) {
			variables.c.errors.validation("part must be between 1 and of.", "INVALID_TEST_PARTITION");
		}
		var runner = createObject("component", "icfwalktests.TestRunner").init(variables.c);
		var results = runner.run(filter, part, of);
		return { "status": 200, "body": results };
	}

	/** DISABLE or ENABLE the triggers that refuse deletion of release rows (migration 007, 50068). */
	private string function releaseDeleteGuards(required string action) {
		var out = [];
		for (var pair in [["report_release", "TR_report_release_no_delete"], ["report_release_block", "TR_report_release_block_no_delete"],
			["report_release_cell", "TR_report_release_cell_no_delete"], ["report_release_walk", "TR_report_release_walk_no_delete"]]) {
			arrayAppend(out, "IF OBJECT_ID(N'[icf].[" & pair[2] & "]', N'TR') IS NOT NULL " & arguments.action & " TRIGGER [icf].[" & pair[2] & "] ON [icf].[" & pair[1] & "];");
		}
		return arrayToList(out, chr(10));
	}
}
