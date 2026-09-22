/**
 * Who may change the shared icf.instrument row, and what a change may say.
 *
 * THE DEFECT THIS EXISTS FOR. The operation required a GUID actor and the repository checked
 * `userExists`. That is an integrity check -- it stops the audit trail naming somebody the database
 * has never heard of -- and it was being relied on as the authorization control. Any row in
 * icf.app_user could therefore be supplied as the alleged authorizer by any internal caller, and
 * the successful case in the existing suite used a user who had never been granted
 * `instrument.manage` at all. The absence of an HTTP route is not authorization either: a service
 * boundary that is only safe because nothing calls it is not a boundary.
 *
 * WHAT IS PROVED HERE.
 *   - The operation takes the current principal, not a caller-supplied actor id, and asks the
 *     central AuthorizationService for global `instrument.manage` before anything is written.
 *   - A known, active user without that permission is denied and changes nothing.
 *   - A user with a real, currently effective role assignment that grants it succeeds.
 *   - The row's authorizing user and the audit's actor are the authorized principal, and no
 *     argument can name a different actor.
 *   - The patch is validated strictly before any mutation: only name, description and active;
 *     unknown members refused; name a non-blank string within the column; description a string
 *     within the column or absent; active an actual boolean and never a coerced string or number;
 *     at least one supported change required.
 *   - A patch that produces no material difference is a NO-OP: nothing is written, no audit event
 *     is recorded, and the row version does not move (docs/OPEN_DECISIONS.md).
 *   - The component is still unreachable from src/http and src/controllers.
 *
 * The concurrency properties of the same operation -- that the locked read, merge, update and
 * audit are one transaction -- are proved in SharedMetadataConcurrencyBarrierTest.
 */
component extends="icfwalktests.BaseSpec" output="false" {

	public string function skipReason() {
		return schemaPresent() ? "" : "icf schema is not present in datasource '" & variables.c.db.datasourceName() & "'.";
	}

	public void function beforeAll() {
		variables.run = "meta-" & lCase(left(replace(createUUID(), "-", "", "all"), 8));
		variables.instrumentCode = "METFIX" & uCase(left(replace(createUUID(), "-", "", "all"), 8));
		variables.db = variables.c.db;
		variables.repo = variables.c.definitionRepository;
		variables.svc = variables.c.instrumentMetadataService;
		variables.fixtures = new icfwalktests.support.FixtureCleanup(variables.c);
		variables.orgUnit = variables.fixtures.ensureOrgUnit(variables.run & "-district", "DISTRICT");

		// An administrator: a real, currently effective MASTER_INSTRUMENT_ADMIN assignment, which is
		// the only role in the supplied schema whose can_manage_instruments flag is set.
		variables.adminId = variables.fixtures.ensureUser(variables.run & "-admin", "Metadata administrator");
		variables.fixtures.grantRole(variables.adminId, "MASTER_INSTRUMENT_ADMIN", variables.orgUnit, true);
		variables.admin = variables.fixtures.principalFor(variables.adminId);

		// A known, active, perfectly ordinary user with a real role that does NOT grant
		// instrument.manage. This is the user the previous suite used as its successful actor.
		variables.walkerId = variables.fixtures.ensureUser(variables.run & "-walker", "Metadata non-administrator");
		variables.fixtures.grantRole(variables.walkerId, "DISTRICT_WALK_REPORT", variables.orgUnit, true);
		variables.walker = variables.fixtures.principalFor(variables.walkerId);

		// A known, active user with no role assignment at all.
		variables.bystanderId = variables.fixtures.ensureUser(variables.run & "-bystander", "Metadata bystander");
		variables.bystander = variables.fixtures.principalFor(variables.bystanderId);

		variables.importSvc = variables.c.instrumentImportService;
		variables.importSvc.importConfig(config(label("v1")));
	}

	public void function afterAll() {
		variables.fixtures.removeInstrumentsCoded(variables.instrumentCode);
		variables.fixtures.removeUsers(variables.run & "-");
		variables.c.orgUnitRepository.deleteUnreferenced(variables.orgUnit);
	}

	public void function beforeEach() {
		variables.svc.updateMetadata(variables.instrumentCode, { "name": "Metadata baseline", "description": "baseline", "active": true }, variables.admin);
		// Audit assertions below count only what the case itself writes, so a case never depends on
		// how many events the cases before it happened to leave behind.
		variables.baselineEventId = variables.db.scalar("SELECT ISNULL(MAX(event_id), 0) AS n FROM [icf].[audit_event]");
	}

	// ---- authorization ---------------------------------------------------------------------------

	/** The permission is real: a user the deployment knows, but has not made an administrator. */
	public void function testAKnownUserWithoutInstrumentManageIsDeniedAndChangesNothing() {
		assertFalse(variables.c.authorizationService.can(variables.walker, "instrument.manage"), "precondition: the walker does not hold instrument.manage");
		assertTrue(variables.c.authorizationService.can(variables.walker, "walk.create", variables.orgUnit), "precondition: but is a real, active user with real permissions");

		var before = instrumentRow();
		var svc = variables.svc;
		var code = variables.instrumentCode;
		var walker = variables.walker;
		assertThrows(function() { svc.updateMetadata(code, { "name": "Renamed by a walker" }, walker); }, "ICFWalk.Forbidden", "FORBIDDEN");

		var after = instrumentRow();
		assertEquals(before.name, after.name, "a denied metadata change writes nothing");
		assertEquals(before.active, after.active);
		assertEquals(before.rowVersion, after.rowVersion, "and does not move the row version");
		assertEquals(0, auditCount("INSTRUMENT_METADATA_UPDATED"), "and records no success event");
	}

	/** And a user with no role assignment at all. */
	public void function testAKnownUserWithNoRoleAtAllIsDeniedAndChangesNothing() {
		var before = instrumentRow();
		var svc = variables.svc;
		var code = variables.instrumentCode;
		var bystander = variables.bystander;
		assertThrows(function() { svc.updateMetadata(code, { "active": false }, bystander); }, "ICFWalk.Forbidden", "FORBIDDEN");
		assertEquals(before.rowVersion, instrumentRow().rowVersion, "nothing moved");
		assertEquals(0, auditCount("INSTRUMENT_METADATA_UPDATED"));
	}

	/** A user whose effective role assignment really grants instrument.manage succeeds. */
	public void function testAUserWithAnEffectiveInstrumentManageAssignmentSucceeds() {
		assertTrue(variables.c.authorizationService.can(variables.admin, "instrument.manage"), "precondition: the administrator holds instrument.manage");

		var result = variables.svc.updateMetadata(variables.instrumentCode, { "name": "Renamed by an administrator" }, variables.admin);

		assertEquals("Renamed by an administrator", result.name);
		assertEquals("Renamed by an administrator", instrumentRow().name, "the shared row really changed");
		assertTrue(arrayContains(result.changedFields, "name"), "and the result names what changed");
		assertEquals(1, auditCount("INSTRUMENT_METADATA_UPDATED"), "exactly one audit event");
	}

	/**
	 * The actor is the authorized principal, and there is no argument that names a different one.
	 * The audit and the row both say so, and neither can be steered from the call site.
	 */
	public void function testTheAuditActorIsTheAuthorizedPrincipalAndCannotBeOverridden() {
		var result = variables.svc.updateMetadata(variables.instrumentCode, { "description": "Set by the administrator" }, variables.admin);
		assertEquals(variables.adminId, result.updatedByUserId, "the result names the authorized principal");

		var q = variables.db.run(
			"SELECT TOP (1) actor_user_id, details_json FROM [icf].[audit_event]
			  WHERE entity_id = :id AND event_type = N'INSTRUMENT_METADATA_UPDATED' ORDER BY event_id DESC",
			{ "id": variables.db.guid(instrumentId()) }
		);
		assertEquals(variables.adminId, uCase(q.actor_user_id[1]), "and so does the audit event");

		// There is no actor argument, and a caller that supplies one anyway cannot change the actor.
		invoke(variables.svc, "updateMetadata", {
			"instrumentCode": variables.instrumentCode,
			"changes": { "name": "Renamed again" },
			"principal": variables.admin,
			"actorUserId": variables.walkerId
		});
		var after = variables.db.run(
			"SELECT TOP (1) actor_user_id FROM [icf].[audit_event]
			  WHERE entity_id = :id AND event_type = N'INSTRUMENT_METADATA_UPDATED' ORDER BY event_id DESC",
			{ "id": variables.db.guid(instrumentId()) }
		);
		assertEquals(variables.adminId, uCase(after.actor_user_id[1]), "a supplied actor id is not honoured: the principal is the only actor");
	}

	/** The principal has to be one: a bare user id, or anything that is not a principal, is refused. */
	public void function testTheOperationRequiresAPrincipalRatherThanAnActorId() {
		var before = instrumentRow();
		var svc = variables.svc;
		var code = variables.instrumentCode;
		var adminId = variables.adminId;
		assertThrows(function() { svc.updateMetadata(code, { "active": false }, adminId); }, "ICFWalk.Validation", "INSTRUMENT_METADATA_PRINCIPAL_REQUIRED");
		assertThrows(function() { svc.updateMetadata(code, { "active": false }, {}); }, "ICFWalk.Validation", "INSTRUMENT_METADATA_PRINCIPAL_REQUIRED");
		assertEquals(before.rowVersion, instrumentRow().rowVersion, "and nothing was written");
	}

	// ---- the patch -------------------------------------------------------------------------------

	/** Only name, description and active. An unknown member is refused, not ignored. */
	public void function testAnUnknownPatchMemberIsRefusedWithoutAWrite() {
		expectInvalidPatch({ "name": "Fine", "retired": true }, "INSTRUMENT_METADATA_UNKNOWN_FIELD");
		expectInvalidPatch({ "instrumentId": uCase(createUUID()) }, "INSTRUMENT_METADATA_UNKNOWN_FIELD");
		expectInvalidPatch({ "code": "SOMETHINGELSE" }, "INSTRUMENT_METADATA_UNKNOWN_FIELD");
	}

	/** An empty patch names no supported change and is refused. */
	public void function testAnEmptyPatchIsRefusedWithoutAWrite() {
		expectInvalidPatch({}, "INSTRUMENT_METADATA_NO_CHANGES");
	}

	/** A name must be a non-blank string that fits icf.instrument.name. */
	public void function testAnInvalidNameIsRefusedWithoutAWrite() {
		expectInvalidPatch({ "name": "" }, "INSTRUMENT_METADATA_INVALID");
		expectInvalidPatch({ "name": "   " }, "INSTRUMENT_METADATA_INVALID");
		expectInvalidPatch({ "name": repeatString("x", 201) }, "INSTRUMENT_METADATA_INVALID");
		expectInvalidPatch({ "name": true }, "INSTRUMENT_METADATA_INVALID");
		expectInvalidPatch({ "name": 42 }, "INSTRUMENT_METADATA_INVALID");
		expectInvalidPatch({ "name": ["a"] }, "INSTRUMENT_METADATA_INVALID");
		expectInvalidPatch({ "name": { "value": "a" } }, "INSTRUMENT_METADATA_INVALID");
	}

	/** A description must be a string that fits icf.instrument.description. */
	public void function testAnInvalidDescriptionIsRefusedWithoutAWrite() {
		expectInvalidPatch({ "description": repeatString("y", 1001) }, "INSTRUMENT_METADATA_INVALID");
		expectInvalidPatch({ "description": 7 }, "INSTRUMENT_METADATA_INVALID");
		expectInvalidPatch({ "description": false }, "INSTRUMENT_METADATA_INVALID");
		expectInvalidPatch({ "description": [] }, "INSTRUMENT_METADATA_INVALID");
	}

	/**
	 * `active` must be an actual boolean.
	 *
	 * This is the case CFML makes easy to get wrong: isBoolean("144") is true, isBoolean(0) is
	 * true, and a "coerce anything unrecognised to false" helper turns a malformed request into a
	 * silent deactivation -- which removes a published version from the runtime for every walker.
	 */
	public void function testAMalformedActiveIsRefusedRatherThanCoerced() {
		for (var bad in ["false", "true", "no", "yes", "0", "1", "maybe", ""]) {
			expectInvalidPatch({ "active": bad }, "INSTRUMENT_METADATA_INVALID");
		}
		expectInvalidPatch({ "active": 0 }, "INSTRUMENT_METADATA_INVALID");
		expectInvalidPatch({ "active": 1 }, "INSTRUMENT_METADATA_INVALID");
		expectInvalidPatch({ "active": [] }, "INSTRUMENT_METADATA_INVALID");
		expectInvalidPatch({ "active": {} }, "INSTRUMENT_METADATA_INVALID");

		// And a real boolean still works, in both directions.
		variables.svc.updateMetadata(variables.instrumentCode, { "active": false }, variables.admin);
		assertFalse(instrumentRow().active, "an actual boolean false deactivates");
		variables.svc.updateMetadata(variables.instrumentCode, { "active": true }, variables.admin);
		assertTrue(instrumentRow().active, "and an actual boolean true reactivates");
	}

	/**
	 * A patch with no material difference is a NO-OP.
	 *
	 * The documented decision (docs/OPEN_DECISIONS.md): the row is not written, no audit event is
	 * recorded, and the row version does not move -- so `updated_at` does not drift and the audit
	 * trail does not fill with events that changed nothing. The result says so explicitly.
	 */
	public void function testAPatchWithNoMaterialDifferenceIsAnAuditFreeNoOp() {
		var before = instrumentRow();
		var result = variables.svc.updateMetadata(
			variables.instrumentCode,
			{ "name": before.name, "description": before.description, "active": before.active },
			variables.admin
		);

		assertEquals(0, arrayLen(result.changedFields), "nothing changed");
		assertTrue(result.noOp, "and the result says the operation was a no-op");
		assertEquals(before.name, result.name, "while still reporting the committed row");
		assertEquals(before.active, result.active);
		var after = instrumentRow();
		assertEquals(before.rowVersion, after.rowVersion, "the row was not written at all");
		assertEquals(0, auditCount("INSTRUMENT_METADATA_UPDATED"), "and no audit event was recorded");
	}

	/** A patch that changes one field of several still writes, and names only what moved. */
	public void function testAPartialPatchKeepsTheStoredValueOfWhatItOmits() {
		var before = instrumentRow();
		var result = variables.svc.updateMetadata(variables.instrumentCode, { "active": false }, variables.admin);

		assertEquals(["active"], result.changedFields, "only active moved");
		assertFalse(result.noOp);
		var after = instrumentRow();
		assertEquals(before.name, after.name, "the omitted name kept its stored value");
		assertEquals(before.description, after.description, "and so did the omitted description");
		assertFalse(after.active);
	}

	/** A missing instrument is refused, and nothing is audited as a success. */
	public void function testAMissingInstrumentIsRefusedWithoutAuditingSuccess() {
		var svc = variables.svc;
		var admin = variables.admin;
		var absent = "NOSUCH" & uCase(left(replace(createUUID(), "-", "", "all"), 8));
		assertThrows(function() { svc.updateMetadata(absent, { "active": false }, admin); }, "ICFWalk.NotFound", "INSTRUMENT_NOT_FOUND");
		assertEquals(0, variables.db.scalar(
			"SELECT COUNT(*) AS n FROM [icf].[audit_event] WHERE event_type = N'INSTRUMENT_METADATA_UPDATED' AND details_json LIKE :like",
			{ "like": { "value": "%" & absent & "%", "cfsqltype": "cf_sql_nvarchar" } }
		), "no success event was written for an instrument that does not exist");
	}

	/** Narrative content never reaches the audit details, even when the description changes. */
	public void function testTheAuditNamesChangedFieldsWithoutCopyingNarrativeContent() {
		var secret = "A description that must never appear in an audit event " & createUUID();
		variables.svc.updateMetadata(variables.instrumentCode, { "description": secret }, variables.admin);

		var q = variables.db.run(
			"SELECT TOP (1) details_json FROM [icf].[audit_event]
			  WHERE entity_id = :id AND event_type = N'INSTRUMENT_METADATA_UPDATED' ORDER BY event_id DESC",
			{ "id": variables.db.guid(instrumentId()) }
		);
		assertFalse(find(secret, q.details_json[1]) > 0, "the description text is not copied into the audit event");
		var details = deserializeJSON(q.details_json[1]);
		assertTrue(arrayContains(details.changedFields, "description"), "but the event says the description changed");
		assertTrue(structKeyExists(details, "descriptionChanged") && details.descriptionChanged, "as a lifecycle fact rather than as content");
	}

	/** Still no route: this pass closes the write boundary and adds no administration UI for it. */
	public void function testTheOperationRemainsUnreachableFromHttpAndControllers() {
		var routes = fileRead(expandPath("/icfwalk/http/Router.cfc"), "utf-8");
		assertFalse(findNoCase("instrumentMetadataService", routes) > 0, "no route reaches the instrument metadata operation");
		assertFalse(findNoCase("updateMetadata", routes) > 0, "and nothing in the router names the operation");
		for (var dir in ["/icfwalk/http", "/icfwalk/controllers"]) {
			for (var file in directoryList(expandPath(dir), true, "path", "*.cfc")) {
				var text = fileRead(file, "utf-8");
				var name = listLast(replace(file, "\", "/", "all"), "/");
				assertFalse(findNoCase("instrumentMetadataService", text) > 0, name & " must not reach the instrument metadata operation");
				assertFalse(findNoCase("updateMetadata", text) > 0, name & " must not call the instrument metadata operation");
			}
		}
	}

	// ---- helpers ---------------------------------------------------------------------------------

	/** Asserts the patch is refused with `code`, before any write, and that nothing moved. */
	private void function expectInvalidPatch(required struct changes, required string code) {
		var before = instrumentRow();
		var audits = auditCount("INSTRUMENT_METADATA_UPDATED");
		var svc = variables.svc;
		var instrumentCode = variables.instrumentCode;
		var admin = variables.admin;
		var patch = arguments.changes;
		assertThrows(function() { svc.updateMetadata(instrumentCode, patch, admin); }, "ICFWalk.Validation", arguments.code);
		var after = instrumentRow();
		assertEquals(before.rowVersion, after.rowVersion, "a refused patch " & serializeJSON(arguments.changes) & " must not write the row");
		assertEquals(before.name, after.name);
		assertEquals(before.active, after.active);
		assertEquals(audits, auditCount("INSTRUMENT_METADATA_UPDATED"), "and must not audit a change that did not happen");
	}

	private string function label(required string suffix) {
		return variables.run & "-" & arguments.suffix;
	}

	private struct function config(required string versionLabel) {
		var cfg = repoJson("config/instrument-config.json");
		cfg.instrument.code = variables.instrumentCode;
		cfg.instrument.version.versionLabel = arguments.versionLabel;
		return cfg;
	}

	private string function instrumentId() {
		return variables.repo.findInstrumentByCode(variables.instrumentCode).instrumentId;
	}

	private struct function instrumentRow() {
		var q = variables.db.run(
			"SELECT name, description, active, row_version FROM [icf].[instrument] WHERE code = :code",
			{ "code": variables.db.nvarchar(variables.instrumentCode, 60) }
		);
		return {
			"name": q.name[1],
			"description": isNull(q.description[1]) ? "" : q.description[1],
			"active": q.active[1] ? true : false,
			"rowVersion": binaryEncode(q.row_version[1], "hex")
		};
	}

	/** Metadata audit events written since this case's baseline was established. */
	private numeric function auditCount(required string eventType) {
		return variables.db.scalar(
			"SELECT COUNT(*) AS n FROM [icf].[audit_event] a
			  WHERE a.entity_id = :id AND a.event_type = :t AND a.event_id > :since",
			{ "id": variables.db.guid(instrumentId()), "t": variables.db.nvarchar(arguments.eventType), "since": variables.db.bigint(variables.baselineEventId) }
		);
	}
}
