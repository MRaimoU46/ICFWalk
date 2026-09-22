/**
 * An ordinary DRAFT import cannot change what an already published version is, or whether the
 * runtime can still find it.
 *
 * THE DEFECT THIS EXISTS FOR. icf.instrument is shared by every version. The importer wrote it on
 * every re-import, straight from the document, with no authorization beyond "an import happened":
 *
 *     if (!structIsEmpty(instrument)) {
 *         variables.repo.updateInstrument(instrumentId, name, description, active);
 *     }
 *
 * SnapshotService.currentVersion() selects with `i.active = 1`. So importing a V2 DRAFT whose
 * document said "active": false made an already PUBLISHED V1 vanish from the runtime: no version
 * row changed, no checksum moved, no audit named anyone, and the frozen version was simply gone
 * for every walker. The immutability inventory had explicitly declared updateInstrument out of
 * scope, so nothing caught it.
 *
 * WHAT IS PROVED HERE.
 *   - Importing V2 with active = false cannot remove published V1 from the runtime.
 *   - Importing V2 cannot rename or re-describe what V1 is, in the tables or in what the runtime
 *     serves for V1.
 *   - Shared metadata that disagrees with the stored row is not silently dropped either: the
 *     import is refused atomically, with a stable code, and the refusal is audited.
 *   - The change can still be made -- deliberately, by a named user, through the one operation
 *     that owns it -- and that operation audits itself.
 *
 * The fixture instrument is its own, so a frozen fixture is never a candidate for the real
 * ICFWalk instrument's current version.
 */
component extends="icfwalktests.BaseSpec" output="false" {

	public string function skipReason() {
		return schemaPresent() ? "" : "icf schema is not present in datasource '" & variables.c.db.datasourceName() & "'.";
	}

	public void function beforeAll() {
		variables.run = "shared-" & lCase(left(replace(createUUID(), "-", "", "all"), 8));
		variables.instrumentCode = "SHRFIX" & uCase(left(replace(createUUID(), "-", "", "all"), 8));
		variables.db = variables.c.db;
		variables.repo = variables.c.definitionRepository;
		variables.importSvc = variables.c.instrumentImportService;
		variables.publishSvc = variables.c.instrumentPublishService;
		variables.metadataSvc = variables.c.instrumentMetadataService;
		variables.fixtures = new icfwalktests.support.FixtureCleanup(variables.c);
		variables.publisher = variables.fixtures.ensureUser(variables.run & "-publisher", "Shared boundary fixture publisher");
		// The shared-row operation is authorized by the central model now, so the actor for it has
		// to be a principal who really holds instrument.manage -- not merely a user who exists.
		variables.orgUnit = variables.fixtures.ensureOrgUnit(variables.run & "-district", "DISTRICT");
		variables.fixtures.grantRole(variables.publisher, "MASTER_INSTRUMENT_ADMIN", variables.orgUnit, true);
		variables.admin = variables.fixtures.principalFor(variables.publisher);

		// V1: imported and published, exactly as a real deployment would have it.
		variables.v1 = variables.importSvc.importConfig(config(label("v1")));
		variables.publishSvc.publish(variables.v1.versionId, variables.publisher);
	}

	public void function afterAll() {
		variables.fixtures.removeInstrumentsCoded(variables.instrumentCode);
		variables.fixtures.removeUsers(variables.run & "-");
		variables.c.orgUnitRepository.deleteUnreferenced(variables.orgUnit);
	}

	// ---- the runtime defect ----------------------------------------------------------------------

	/**
	 * The headline case. V2 declares the instrument inactive; V1 is published and in service.
	 * Whatever happens to the import, V1 must still be the instrument's current version.
	 */
	public void function testImportingV2WithAnInactiveInstrumentCannotHidePublishedV1() {
		assertEquals(variables.v1.versionId, currentVersionId(), "precondition: published V1 is the current version");
		var beforeActive = instrumentRow().active;

		var cfg = config(label("v2-inactive"));
		cfg.instrument["active"] = false;
		var importSvc = variables.importSvc;
		var refused = false;
		try {
			importSvc.importConfig(cfg, variables.publisher);
		} catch (any e) {
			refused = true;
		}

		assertEquals(beforeActive, instrumentRow().active, "the shared instrument row's active flag did not move");
		assertEquals(variables.v1.versionId, currentVersionId(), "published V1 is still the current version the runtime serves");
		assertTrue(refused, "and the conflicting document was refused rather than partly applied");
	}

	/**
	 * Name and description are VERSION metadata, and are version-scoped rather than refused.
	 *
	 * V2 may describe the instrument differently from V1 -- that is a normal authoring change, and
	 * each version's wording is frozen into its own snapshot, which is what the runtime shows for
	 * a walk pinned to that version. What V2 must not do is reach the shared row and thereby
	 * restate what V1 says. So the import is accepted, V2's snapshot carries the new name, V1's
	 * snapshot still carries the old one, and the shared row is untouched by either.
	 */
	public void function testImportingV2RenamesOnlyItsOwnVersionAndNotTheSharedRow() {
		var before = instrumentRow();
		var v1Name = variables.c.snapshotService.renderModelFor(variables.v1.versionId).instrument.name;
		var newName = "Renamed by V2 only";

		var cfg = config(label("v2-renamed"));
		cfg.instrument["name"] = newName;
		var v2 = variables.importSvc.importConfig(cfg, variables.publisher);

		var after = instrumentRow();
		assertEquals(before.name, after.name, "the shared row's name is unchanged: an import does not own it");
		assertEquals(before.description, after.description, "and neither is its description");
		assertEquals(before.active, after.active, "and neither is its active flag");

		variables.c.snapshotService.clearCache();
		assertEquals(newName, variables.c.snapshotService.renderModelFor(v2.versionId).instrument.name, "V2 shows its own name");
		assertEquals(v1Name, variables.c.snapshotService.renderModelFor(variables.v1.versionId).instrument.name, "and V1 still shows the name it was published with");
		assertEquals(variables.v1.versionId, currentVersionId(), "and V1 is still the current version");
	}

	/**
	 * And V1's own runtime metadata is untouched: what the runtime serves for V1 comes from V1's
	 * frozen snapshot, which a later import cannot reach at all.
	 */
	public void function testImportingV2CannotAlterWhatTheRuntimeServesForV1() {
		var beforeModel = variables.c.snapshotService.renderModelFor(variables.v1.versionId);
		var beforeRow = variables.repo.findVersionById(variables.v1.versionId);

		// A V2 that agrees about shared metadata and is therefore accepted.
		var v2 = variables.importSvc.importConfig(config(label("v2-clean")));
		assertNotEquals(variables.v1.versionId, v2.versionId, "V2 really is a separate version");

		variables.c.snapshotService.clearCache();
		var afterModel = variables.c.snapshotService.renderModelFor(variables.v1.versionId);
		var afterRow = variables.repo.findVersionById(variables.v1.versionId);

		assertEquals(beforeRow.snapshotJson, afterRow.snapshotJson, "V1's frozen snapshot bytes are unchanged");
		assertEquals(beforeRow.checksum, afterRow.checksum, "and its checksum");
		assertEquals(beforeRow.rowVersion, afterRow.rowVersion, "and its row version");
		assertEquals(
			variables.c.canonicalJson.serialize(beforeModel.instrument),
			variables.c.canonicalJson.serialize(afterModel.instrument),
			"and the instrument identity the runtime serves for V1"
		);
		assertEquals(
			variables.c.canonicalJson.serialize(beforeModel.root),
			variables.c.canonicalJson.serialize(afterModel.root),
			"and V1's whole render model"
		);
		assertEquals(variables.v1.versionId, currentVersionId(), "and V1 is still current: importing a DRAFT does not promote it");
	}

	/** A refused shared-metadata conflict rolls back completely and is audited exactly once. */
	public void function testARefusedSharedMetadataConflictChangesNothingAndIsAudited() {
		// A DRAFT that exists already, so the refusal has a version to be recorded against.
		var draft = variables.importSvc.importConfig(config(label("v2-conflict")));
		var beforeRow = variables.repo.findVersionById(draft.versionId);
		var beforeInstrument = instrumentRow();
		var beforeRefusals = auditCount(draft.versionId, "INSTRUMENT_VERSION_WRITE_REFUSED");

		var cfg = config(label("v2-conflict"));
		cfg.instrument["active"] = false;
		cfg.items[1].prompt = "A prompt that must never be stored";
		var importSvc = variables.importSvc;
		assertThrows(function() { importSvc.importConfig(cfg, variables.publisher); }, "ICFWalk.Import.Validation", "INSTRUMENT_CONFIG_INVALID");

		var afterRow = variables.repo.findVersionById(draft.versionId);
		assertEquals(beforeRow.rowVersion, afterRow.rowVersion, "the DRAFT's row version did not move");
		assertEquals(beforeRow.checksum, afterRow.checksum, "and its checksum");
		assertEquals(beforeInstrument.name, instrumentRow().name, "and the shared row is untouched");
		assertEquals(beforeInstrument.active, instrumentRow().active, "including its active flag");
		assertEquals(0, variables.db.scalar(
			"SELECT COUNT(*) AS n FROM [icf].[item_definition] WHERE version_id = :id AND prompt = N'A prompt that must never be stored'",
			{ "id": variables.db.guid(draft.versionId) }
		), "and nothing from the refused document was written");
		assertEquals(beforeRefusals + 1, auditCount(draft.versionId, "INSTRUMENT_VERSION_WRITE_REFUSED"), "exactly one refusal audit survived the rollback");

		var q = variables.db.run(
			"SELECT TOP (1) details_json FROM [icf].[audit_event] WHERE entity_id = :id AND event_type = N'INSTRUMENT_VERSION_WRITE_REFUSED' ORDER BY event_id DESC",
			{ "id": variables.db.guid(draft.versionId) }
		);
		var details = deserializeJSON(q.details_json[1]);
		assertEquals("SHARED_METADATA_CONFLICT", details.reason, "the refusal carries a stable reason code");
		assertEquals("IMPORT", details.operation);
		assertFalse(find("prompt", q.details_json[1]) > 0, "and no narrative content");
	}

	// ---- the operation that does own the row -----------------------------------------------------

	/**
	 * The change is still possible -- deliberately, by a named user, through the one operation
	 * that owns the row -- and it says who did it.
	 */
	public void function testTheAuthorizedOperationCanChangeSharedMetadataAndAuditsIt() {
		var instrumentId = variables.repo.findInstrumentByCode(variables.instrumentCode).instrumentId;
		var before = auditCount(instrumentId, "INSTRUMENT_METADATA_UPDATED");

		var result = variables.metadataSvc.updateMetadata(variables.instrumentCode, { "name": "Renamed deliberately" }, variables.admin);
		assertEquals("Renamed deliberately", result.name);
		assertEquals("Renamed deliberately", instrumentRow().name, "the shared row really changed");
		assertTrue(arrayContains(result.changedFields, "name"), "and the result names what changed");
		assertEquals(before + 1, auditCount(instrumentId, "INSTRUMENT_METADATA_UPDATED"), "exactly one audit event");

		var q = variables.db.run(
			"SELECT TOP (1) actor_user_id, details_json FROM [icf].[audit_event] WHERE entity_id = :id AND event_type = N'INSTRUMENT_METADATA_UPDATED' ORDER BY event_id DESC",
			{ "id": variables.db.guid(instrumentId) }
		);
		assertEquals(variables.publisher, uCase(q.actor_user_id[1]), "naming the user who authorized it");
		var details = deserializeJSON(q.details_json[1]);
		assertEquals("Renamed deliberately", details.name);
		assertTrue(structKeyExists(details, "previousName"), "and what it was before");

		// Put it back so the later cases see the document's own name.
		variables.metadataSvc.updateMetadata(variables.instrumentCode, { "name": before_name() }, variables.admin);
		assertEquals(before_name(), instrumentRow().name, "restored");
	}

	/**
	 * That operation refuses a caller who is not the current principal, and changes nothing.
	 *
	 * It used to take an actor id and check only that icf.app_user had such a row, which is an
	 * integrity check and not a permission check -- so a bare id was enough to authorize a change
	 * to the shared row. There is no actor argument any more: an id, an empty string and an empty
	 * struct are all refused before anything is read or written, and permission itself is proved
	 * against the real role model in InstrumentMetadataServiceTest.
	 */
	public void function testTheAuthorizedOperationRefusesACallerThatIsNotAPrincipal() {
		var before = instrumentRow();
		var svc = variables.metadataSvc;
		var code = variables.instrumentCode;
		var stranger = variables.db.newGuid();
		var knownUserId = variables.publisher;
		assertThrows(function() { svc.updateMetadata(code, { "active": false }, stranger); }, "ICFWalk.Validation", "INSTRUMENT_METADATA_PRINCIPAL_REQUIRED");
		assertThrows(function() { svc.updateMetadata(code, { "active": false }, ""); }, "ICFWalk.Validation", "INSTRUMENT_METADATA_PRINCIPAL_REQUIRED");
		// Even the id of the user who DOES hold instrument.manage is not an authorization: the
		// principal is what carries the permission, and an id is not a principal.
		assertThrows(function() { svc.updateMetadata(code, { "active": false }, knownUserId); }, "ICFWalk.Validation", "INSTRUMENT_METADATA_PRINCIPAL_REQUIRED");

		var after = instrumentRow();
		assertEquals(before.name, after.name, "a refused metadata change writes nothing");
		assertEquals(before.active, after.active);
		assertEquals(variables.v1.versionId, currentVersionId(), "and published V1 is still current");
	}

	/** It is not reachable over HTTP: this pass closes the boundary and adds no UI for it. */
	public void function testTheAuthorizedOperationHasNoRoute() {
		var routes = fileRead(expandPath("/icfwalk/http/Router.cfc"), "utf-8");
		assertFalse(findNoCase("instrumentMetadataService", routes) > 0, "no route reaches the instrument metadata operation");
		var controllers = directoryList(expandPath("/icfwalk/controllers"), false, "path", "*.cfc");
		for (var file in controllers) {
			assertFalse(findNoCase("instrumentMetadataService", fileRead(file, "utf-8")) > 0, listLast(replace(file, "\", "/", "all"), "/") & " must not reach the instrument metadata operation");
		}
	}

	// ---- helpers ---------------------------------------------------------------------------------

	private string function before_name() {
		return repoJson("config/instrument-config.json").instrument.name;
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

	private struct function instrumentRow() {
		var q = variables.db.run(
			"SELECT name, description, active FROM [icf].[instrument] WHERE code = :code",
			{ "code": variables.db.nvarchar(variables.instrumentCode, 60) }
		);
		return { "name": q.name[1], "description": isNull(q.description[1]) ? "" : q.description[1], "active": q.active[1] ? true : false };
	}

	/**
	 * The version the runtime would serve for this fixture instrument, by the same predicate
	 * SnapshotService.currentVersion() uses (including the shared row's active flag, which is the
	 * whole point).
	 */
	private string function currentVersionId() {
		var q = variables.db.run(
			"SELECT TOP 1 v.version_id
			   FROM [icf].[instrument_version] v
			   JOIN [icf].[instrument] i ON i.instrument_id = v.instrument_id
			  WHERE i.code = :code AND i.active = 1
			    AND v.status = N'PUBLISHED' AND v.compiled_snapshot_json IS NOT NULL
			    AND v.effective_start IS NOT NULL AND v.effective_start <= SYSUTCDATETIME()
			    AND (v.effective_end IS NULL OR v.effective_end > SYSUTCDATETIME())
			  ORDER BY v.effective_start DESC, v.published_at DESC, v.created_at DESC",
			{ "code": variables.db.nvarchar(variables.instrumentCode, 60) }
		);
		return q.recordCount ? uCase(q.version_id[1]) : "";
	}

	private numeric function auditCount(required string entityId, required string eventType) {
		return variables.db.scalar(
			"SELECT COUNT(*) AS n FROM [icf].[audit_event] WHERE entity_id = :id AND event_type = :t",
			{ "id": variables.db.guid(arguments.entityId), "t": variables.db.nvarchar(arguments.eventType) }
		);
	}
}
