/**
 * Re-importing over a DRAFT is decided by the server, under the version lock (P6A-02).
 *
 * THE DEFECT. The administration import received only `{ document }`. When the document's label
 * named an existing DRAFT the server re-imported over it, whatever it held: the only protection was
 * a question the page asked, and the page decided whether to ask by comparing the workbook with the
 * version list it had loaded earlier. A list loaded before someone else's edit showed the old
 * checksum, so the page asked nothing and the newer DRAFT was overwritten; a label someone else
 * created after the list loaded was not in it at all, so that DRAFT was taken over too.
 *
 * THE CONTRACT NOW (docs/ENDPOINTS.md):
 *
 *   create-only  `{ document }`. A label that names an existing DRAFT is refused 409
 *                DRAFT_REPLACEMENT_REQUIRED, with that DRAFT's id and current checksum, and nothing
 *                is written.
 *   replace      `{ document, replace: { versionId, expectedChecksum } }`. The DRAFT under the
 *                document's label must be that exact id with that exact checksum, compared under
 *                the same lock the write holds. Any other id, another checksum, no row at all, or a
 *                version that is no longer a DRAFT is refused atomically (409 DRAFT_CHANGED, or the
 *                existing immutable-version refusal), with nothing written and one durable refusal.
 *                A successful replacement is audited against the exact prior id and checksum.
 *
 * WHAT IS PROVED HERE. Two cases are forced through the two-sided barrier (A_LOCKED /
 * B_AT_COMPETING_BOUNDARY on the version lock, InterceptingDefinitionRepository.findVersion): an
 * upload queued behind the creation of its label, and a replacement queued behind an edit made after
 * it was confirmed. In both, the holder is released only after the competitor has announced its
 * arrival AND SQL Server reports it blocked behind the holder's session; nothing is inferred from
 * elapsed time. The export case forces a committed edit between the export's read and its use.
 */
component extends="icfwalktests.BaseSpec" output="false" {

	public string function skipReason() {
		return schemaPresent() ? "" : "icf schema is not present in datasource '" & variables.c.db.datasourceName() & "'.";
	}

	public void function beforeAll() {
		variables.run = "drc-" & lCase(left(replace(createUUID(), "-", "", "all"), 8));
		variables.code = "DRC" & uCase(left(replace(createUUID(), "-", "", "all"), 9));
		variables.db = variables.c.db;
		variables.repo = variables.c.definitionRepository;
		variables.admin = variables.c.instrumentAdminService;
		variables.importer = variables.c.instrumentImportService;
		variables.cleanup = new icfwalktests.support.FixtureCleanup(variables.c);
		variables.adminA = variables.cleanup.ensureUser(variables.run & "-admin-a", "Replacement administrator A");
		variables.adminB = variables.cleanup.ensureUser(variables.run & "-admin-b", "Replacement administrator B");
		// The instrument exists before any race, so only the version row is contended.
		variables.importer.importConfig(configFor(variables.run & "-base"), variables.adminA);
	}

	public void function afterAll() {
		variables.cleanup.removeInstrumentsCoded(variables.code);
		variables.cleanup.removeUsers(variables.run & "-");
	}

	// ---- 1. a stale page cannot overwrite a newer DRAFT ---------------------------------------------

	/**
	 * A and B both read the DRAFT at C1. B commits C2. A, still holding C1, uploads: the page asks
	 * nothing (its list says C1, like the workbook), so only the server can refuse -- and it does,
	 * because A's replacement names C1.
	 */
	public void function testAReplacementNamingAnOlderChecksumCannotOverwriteTheNewerDraft() {
		var draft = variables.importer.importConfig(configFor(label("stale")), variables.adminA);
		var target = aScoredItem(draft.versionId);
		var edited = variables.admin.editDraft(draft.versionId, {
			"expectedChecksum": draft.checksum,
			"edits": [{ "target": "item", "key": target.itemKey, "field": "prompt", "value": "B's wording, committed second" }]
		}, variables.adminB);
		var before = variables.repo.findVersionById(draft.versionId);
		var refusals = auditCount(draft.versionId, "INSTRUMENT_VERSION_WRITE_REFUSED");

		var admin = variables.admin;
		var doc = configFor(label("stale"));
		doc.instrument.version.revisionNotes = "A's upload, made against C1";
		var token = { "versionId": draft.versionId, "expectedChecksum": draft.checksum };
		var actor = variables.adminA;
		var e = assertThrows(function() { admin.importDocument(doc, actor, token); }, "ICFWalk.Conflict", "DRAFT_CHANGED");
		var details = variables.c.errors.detailsOf(e);
		assertExactTextEquals(draft.versionId, details.versionId);
		assertExactTextEquals(edited.checksum, details.currentChecksum, "the refusal names the state it found");

		assertUnchanged(before, draft.versionId, "B's DRAFT");
		assertExactTextEquals("B's wording, committed second", itemPrompt(draft.versionId, target.itemKey));
		assertEquals(0, auditCount(draft.versionId, "INSTRUMENT_VERSION_REIMPORTED"), "no success was audited");
		assertEquals(refusals + 1, auditCount(draft.versionId, "INSTRUMENT_VERSION_WRITE_REFUSED"), "one durable refusal");
		assertExactTextEquals("DRAFT_CHANGED", lastAudit(draft.versionId, "INSTRUMENT_VERSION_WRITE_REFUSED").reason);
	}

	// ---- 2. a label created after the page looked is never silently taken over ----------------------

	/**
	 * The creator holds the version lock on a label that is still free; the uploader, whose page saw
	 * the label free, sends a create-only import for it and queues on that lock. Released, the
	 * creator commits, and the uploader is refused rather than re-importing over the new DRAFT.
	 */
	public void function testACreateOnlyImportQueuedBehindTheCreationOfItsLabelIsRefused() {
		var theLabel = label("late");
		var creatorDoc = configFor(theLabel);
		creatorDoc.instrument.version.revisionNotes = "The creator's DRAFT";
		var uploaderDoc = configFor(theLabel);
		uploaderDoc.instrument.version.revisionNotes = "The uploader's document";

		var barrier = createObject("component", "icfwalktests.support.ConcurrencyBarrier").init();
		var holderRepo = createObject("component", "icfwalktests.support.InterceptingDefinitionRepository").init(variables.repo);
		var competitorRepo = createObject("component", "icfwalktests.support.InterceptingDefinitionRepository").init(variables.repo);
		var holder = importServiceWith(holderRepo);
		var uploader = adminServiceWith(competitorRepo, importServiceWith(competitorRepo));
		competitorRepo.armBefore("findVersion", function() { barrier.signalOnce("B_AT_COMPETING_BOUNDARY"); });

		var threadName = "uploadLate" & lCase(left(replace(createUUID(), "-", "", "all"), 10));
		var actor = variables.adminA;
		var observed = {};
		holderRepo.armAfter("findVersion", function() {
			// The creator holds the lock on the (still free) label and has written nothing.
			barrier.signal("A_LOCKED");
			thread name="#threadName#" svc=uploader doc=uploaderDoc who=actor barrier=barrier {
				try {
					thread.result = attributes.svc.importDocument(attributes.doc, attributes.who);
					thread.outcome = "imported";
				} catch (any e) {
					thread.outcome = structKeyExists(e, "errorcode") && len(e.errorcode) && e.errorcode != "0" ? e.errorcode : e.type;
					thread.details = structKeyExists(e, "extendedInfo") ? e.extendedInfo : "";
					thread.detail = left(e.message, 300);
				}
				attributes.barrier.signal("B_DONE");
			}
			observed = holdUntilQueued(barrier, threadName);
		});

		var created = holder.importConfig(creatorDoc, variables.adminB);
		threadJoin(threadName, 60000);
		var u = cfthread[threadName];

		assertTrue(created.created, "the creator created the DRAFT");
		assertExactTextEquals("COMPLETED", u.status);
		assertExactTextEquals("DRAFT_REPLACEMENT_REQUIRED", u.outcome, "the uploader was refused, not silently re-imported" & (structKeyExists(u, "detail") ? " (" & u.detail & ")" : ""));
		var details = deserializeJSON(u.details);
		assertExactTextEquals(created.versionId, details.versionId, "the refusal names the DRAFT that now holds the label");
		assertExactTextEquals(created.checksum, details.currentChecksum, "and its current checksum");

		var row = variables.repo.findVersionById(created.versionId);
		assertExactTextEquals(created.checksum, lCase(trim(row.checksum)), "the creator's DRAFT is exactly what the creator wrote");
		assertExactTextEquals(created.checksum, variables.c.canonicalJson.sha256(row.snapshotJson));
		assertExactTextEquals(created.definitionsChecksum, persistedDefinitionsChecksum(created.versionId));
		assertEquals(1, auditCount(created.versionId, "INSTRUMENT_VERSION_CREATED"));
		assertEquals(0, auditCount(created.versionId, "INSTRUMENT_VERSION_REIMPORTED"), "no re-import was audited");
		assertExactTextEquals("REPLACEMENT_REQUIRED", lastAudit(created.versionId, "INSTRUMENT_VERSION_WRITE_REFUSED").reason);

		assertQueuedBehindHolder(barrier, observed);
	}

	// ---- 3. a change after confirmation still refuses the replacement -------------------------------

	/**
	 * A confirmed replacing the DRAFT at C1. Before A's write, B's edit takes the version lock; A's
	 * replacement queues on it. B commits C2; A must be refused and B's content must stand exactly.
	 */
	public void function testAReplacementQueuedBehindAnEditMadeAfterItWasConfirmedIsRefused() {
		var draft = variables.importer.importConfig(configFor(label("confirmed")), variables.adminA);
		var target = aScoredItem(draft.versionId);
		var replacement = configFor(label("confirmed"));
		replacement.instrument.version.revisionNotes = "A's confirmed replacement";
		var token = { "versionId": draft.versionId, "expectedChecksum": draft.checksum };

		var barrier = createObject("component", "icfwalktests.support.ConcurrencyBarrier").init();
		var holderRepo = createObject("component", "icfwalktests.support.InterceptingDefinitionRepository").init(variables.repo);
		var competitorRepo = createObject("component", "icfwalktests.support.InterceptingDefinitionRepository").init(variables.repo);
		var editor = adminServiceWith(holderRepo, importServiceWith(holderRepo));
		var replacer = adminServiceWith(competitorRepo, importServiceWith(competitorRepo));
		competitorRepo.armBefore("findVersion", function() { barrier.signalOnce("B_AT_COMPETING_BOUNDARY"); });

		var threadName = "replaceAfterEdit" & lCase(left(replace(createUUID(), "-", "", "all"), 10));
		var actor = variables.adminA;
		var observed = {};
		holderRepo.armAfter("findVersion", function() {
			// B's edit holds the version lock and has written nothing yet.
			barrier.signal("A_LOCKED");
			thread name="#threadName#" svc=replacer doc=replacement who=actor token=token barrier=barrier {
				try {
					thread.result = attributes.svc.importDocument(attributes.doc, attributes.who, attributes.token);
					thread.outcome = "imported";
				} catch (any e) {
					thread.outcome = structKeyExists(e, "errorcode") && len(e.errorcode) && e.errorcode != "0" ? e.errorcode : e.type;
					thread.details = structKeyExists(e, "extendedInfo") ? e.extendedInfo : "";
					thread.detail = left(e.message, 300);
				}
				attributes.barrier.signal("B_DONE");
			}
			observed = holdUntilQueued(barrier, threadName);
		});

		var edited = editor.editDraft(draft.versionId, {
			"expectedChecksum": draft.checksum,
			"edits": [{ "target": "item", "key": target.itemKey, "field": "prompt", "value": "B's edit, committed while A's replacement waited" }]
		}, variables.adminB);
		threadJoin(threadName, 60000);
		var a = cfthread[threadName];

		assertExactTextEquals("COMPLETED", a.status);
		assertExactTextEquals("DRAFT_CHANGED", a.outcome, "the confirmed replacement was refused" & (structKeyExists(a, "detail") ? " (" & a.detail & ")" : ""));
		assertExactTextEquals(edited.checksum, deserializeJSON(a.details).currentChecksum);

		var row = variables.repo.findVersionById(draft.versionId);
		assertExactTextEquals(edited.checksum, lCase(trim(row.checksum)), "B's content stands");
		assertExactTextEquals(edited.checksum, variables.c.canonicalJson.sha256(row.snapshotJson), "byte for byte");
		assertExactTextEquals(edited.definitionsChecksum, persistedDefinitionsChecksum(draft.versionId), "and in every definition row");
		assertExactTextEquals("B's edit, committed while A's replacement waited", itemPrompt(draft.versionId, target.itemKey));
		assertEquals(0, auditCount(draft.versionId, "INSTRUMENT_VERSION_REIMPORTED"), "no replacement was audited");
		assertExactTextEquals("DRAFT_CHANGED", lastAudit(draft.versionId, "INSTRUMENT_VERSION_WRITE_REFUSED").reason);

		assertQueuedBehindHolder(barrier, observed);
	}

	// ---- 4. a correct replacement succeeds once, audited against what it replaced -------------------

	public void function testACorrectReplacementSucceedsOnceAndIsAuditedAgainstTheExactPriorVersion() {
		var draft = variables.importer.importConfig(configFor(label("replace")), variables.adminA);
		var replacement = configFor(label("replace"));
		replacement.instrument.version.revisionNotes = "The replacement";
		var token = { "versionId": draft.versionId, "expectedChecksum": draft.checksum };

		var r = variables.admin.importDocument(replacement, variables.adminB, token);
		assertFalse(r.created, "the DRAFT was replaced, not created");
		assertTrue(r.changed);
		assertExactTextEquals(draft.versionId, r.versionId, "the same version id");
		assertExactTextNotEquals(draft.checksum, r.checksum, "with the new content");
		assertExactTextEquals(r.checksum, lCase(trim(variables.repo.findVersionById(draft.versionId).checksum)));

		assertEquals(1, auditCount(draft.versionId, "INSTRUMENT_VERSION_REIMPORTED"));
		var audit = lastAudit(draft.versionId, "INSTRUMENT_VERSION_REIMPORTED");
		assertExactTextEquals(draft.versionId, audit.replacedVersionId, "the audit names the exact version replaced");
		assertExactTextEquals(draft.checksum, audit.previousChecksum, "and the exact checksum it had");
		assertExactTextEquals(r.checksum, audit.checksum, "and what it became");
		assertExactTextEquals(variables.adminB, uCase(lastActor(draft.versionId, "INSTRUMENT_VERSION_REIMPORTED")));
		var text = serializeJSON(audit);
		assertFalse(findNoCase("The replacement", text) > 0, "no instrument content in the audit");
		assertFalse(findNoCase("prompt", text) > 0, "no narrative field in the audit");

		// The same token again: it named C1, and the DRAFT is no longer C1.
		var before = variables.repo.findVersionById(draft.versionId);
		var admin = variables.admin;
		var actor = variables.adminB;
		assertThrows(function() { admin.importDocument(replacement, actor, token); }, "ICFWalk.Conflict", "DRAFT_CHANGED");
		assertUnchanged(before, draft.versionId, "the replaced DRAFT");
		assertEquals(1, auditCount(draft.versionId, "INSTRUMENT_VERSION_REIMPORTED"), "it succeeded exactly once");
	}

	/**
	 * Every other way a replacement can name something that is not there is refused, atomically:
	 * a wrong id, a label with no DRAFT at all (a replacement never creates), a version that has
	 * since been published, and a malformed token. A create-only import of a free label still
	 * creates.
	 */
	public void function testAReplacementThatNamesAnythingElseIsRefusedAndWritesNothing() {
		var admin = variables.admin;
		var actor = variables.adminA;
		var draft = variables.importer.importConfig(configFor(label("other")), variables.adminA);
		var before = variables.repo.findVersionById(draft.versionId);
		var doc = configFor(label("other"));

		var wrongId = { "versionId": variables.db.newGuid(), "expectedChecksum": draft.checksum };
		var e = assertThrows(function() { admin.importDocument(doc, actor, wrongId); }, "ICFWalk.Conflict", "DRAFT_CHANGED");
		assertExactTextEquals(draft.versionId, variables.c.errors.detailsOf(e).currentVersionId, "the refusal names the version the label actually holds");
		assertUnchanged(before, draft.versionId, "the DRAFT");

		var free = configFor(label("free"));
		var nothing = { "versionId": draft.versionId, "expectedChecksum": draft.checksum };
		assertThrows(function() { admin.importDocument(free, actor, nothing); }, "ICFWalk.Conflict", "DRAFT_CHANGED");
		assertEquals(0, labelCount(label("free")), "a replacement never creates a version");

		var pub = variables.importer.importConfig(configFor(label("published")), variables.adminA);
		variables.c.instrumentPublishService.publish(pub.versionId, variables.adminA);
		var frozenBefore = variables.repo.findVersionById(pub.versionId);
		var pubDoc = configFor(label("published"));
		var pubToken = { "versionId": pub.versionId, "expectedChecksum": pub.checksum };
		assertThrows(function() { admin.importDocument(pubDoc, actor, pubToken); }, "ICFWalk.Import.PublishedVersion", "INSTRUMENT_VERSION_IMMUTABLE");
		assertUnchanged(frozenBefore, pub.versionId, "the published version");
		assertThrows(function() { admin.importDocument(pubDoc, actor); }, "ICFWalk.Import.PublishedVersion", "INSTRUMENT_VERSION_IMMUTABLE");

		for (var bad in [
			"not an object",
			{ "versionId": draft.versionId },
			{ "expectedChecksum": draft.checksum },
			{ "versionId": "nope", "expectedChecksum": draft.checksum },
			{ "versionId": draft.versionId, "expectedChecksum": "abc" },
			{ "versionId": draft.versionId, "expectedChecksum": draft.checksum, "status": "DRAFT" }
		]) {
			var t = bad;
			assertThrows(function() { admin.importDocument(doc, actor, t); }, "ICFWalk.Validation", "REPLACE_INVALID");
		}
		assertUnchanged(before, draft.versionId, "the DRAFT, after every malformed token");

		var createdFree = admin.importDocument(configFor(label("free")), actor);
		assertTrue(createdFree.created, "a create-only import of a free label creates it");
	}

	// ---- 5. an export pairs its metadata with the document of the same state ----------------------

	/**
	 * The export used to read the version row for its metadata and then read the snapshot again for
	 * the document. An edit committed between the two paired C1's checksum with C2's content -- a
	 * workbook claiming to be C1 that was not. The spec forces exactly that commit and requires the
	 * document to be the state the metadata names.
	 */
	public void function testAnExportNeverPairsOneStatesMetadataWithAnotherStatesDocument() {
		var draft = variables.importer.importConfig(configFor(label("export")), variables.adminA);
		var target = aScoredItem(draft.versionId);
		var barrier = createObject("component", "icfwalktests.support.ConcurrencyBarrier").init();
		var readRepo = createObject("component", "icfwalktests.support.InterceptingDefinitionRepository").init(variables.repo);
		var readSnapshots = createObject("component", "icfwalk.instrument.SnapshotService").init(
			variables.c.config, variables.c.db, readRepo, variables.c.renderModelBuilder, variables.c.errors, variables.c.logger, variables.c.canonicalJson
		);
		var exporter = adminServiceWith(readRepo, variables.importer, readSnapshots);
		var editor = variables.admin;
		var threadName = "editDuringExport" & lCase(left(replace(createUUID(), "-", "", "all"), 10));
		var edit = { "expectedChecksum": draft.checksum, "edits": [{ "target": "item", "key": target.itemKey, "field": "prompt", "value": "Committed during the export" }] };
		var actor = variables.adminB;
		var committed = false;
		readRepo.armAfter("findVersionById", function() {
			// The export has read the version row and nothing else.
			barrier.signal("A_READ");
			thread name="#threadName#" svc=editor vid=draft.versionId body=edit who=actor barrier=barrier {
				thread.result = attributes.svc.editDraft(attributes.vid, attributes.body, attributes.who);
				attributes.barrier.signal("B_COMMITTED");
			}
			committed = barrier.await("B_COMMITTED", 60000);
		});

		var exported = exporter.exportDocument(draft.versionId);
		threadJoin(threadName, 60000);

		assertTrue(committed, "the edit really committed inside the export's window");
		assertTrue(barrier.signalledInOrder("A_READ", "B_COMMITTED"), "after the export's read");
		var newer = cfthread[threadName].result.checksum;
		assertExactTextNotEquals(draft.checksum, newer, "the edit changed the DRAFT");

		var recompiled = variables.c.snapshotCompiler.compile(variables.c.configNormalizer.fromConfig(exported.document));
		assertExactTextEquals(exported.version.checksum, recompiled.checksum, "the document is exactly the state the metadata names");
		assertExactTextEquals(draft.checksum, exported.version.checksum, "the state the export read");
		assertExactTextEquals(target.prompt, promptIn(exported.document, target.itemKey), "with that state's wording");
	}

	// ---- barrier support -------------------------------------------------------------------------

	/**
	 * Runs inside the holder's transaction, on its connection. Returns once the competitor has
	 * announced its arrival and SQL Server reports it blocked behind this session -- or once it has
	 * finished without ever being held back, which is what code without the lock produces. The
	 * ceiling turns a hang into a failure; it is never the evidence.
	 */
	private struct function holdUntilQueued(required any barrier, required string threadName) {
		var out = { "reached": arguments.barrier.await("B_AT_COMPETING_BOUNDARY", 60000), "blocked": false, "doneWhileHeld": false };
		var deadline = getTickCount() + 60000;
		while (out.reached && getTickCount() < deadline) {
			var waiting = variables.db.run("SELECT COUNT(*) AS n FROM sys.dm_exec_requests WHERE blocking_session_id = @@SPID");
			if (waiting.n[1] > 0) { out.blocked = true; break; }
			if (arguments.barrier.await("B_DONE", 100)) break;
		}
		out["doneWhileHeld"] = arguments.barrier.observed("B_DONE");
		return out;
	}

	private void function assertQueuedBehindHolder(required any barrier, required struct observed) {
		assertTrue(arguments.barrier.observed("A_LOCKED"), "the holder really held the version lock");
		assertTrue(arguments.observed.reached, "the competitor announced that it had reached the version lock");
		assertTrue(arguments.barrier.signalledInOrder("A_LOCKED", "B_AT_COMPETING_BOUNDARY"), "in that order");
		assertTrue(arguments.observed.blocked, "SQL Server reported the competitor blocked behind the holder's session");
		assertFalse(arguments.observed.doneWhileHeld, "the competitor did not finish while the holder held the lock");
	}

	// ---- helpers ---------------------------------------------------------------------------------

	private any function importServiceWith(required any repository) {
		return createObject("component", "icfwalk.instrument.InstrumentImportService").init(
			variables.c.config, variables.c.db, variables.c.errors, variables.c.logger, arguments.repository,
			variables.c.auditRepository, variables.c.configNormalizer, variables.c.configValidator,
			variables.c.snapshotCompiler, variables.c.requestContext, variables.c.renderContractValidator
		);
	}

	private any function adminServiceWith(required any repository, required any importService, any snapshots) {
		return createObject("component", "icfwalk.instrument.InstrumentAdminService").init(
			variables.c.config, variables.c.db, variables.c.errors, variables.c.logger, arguments.repository,
			isNull(arguments.snapshots) ? variables.c.snapshotService : arguments.snapshots,
			arguments.importService, variables.c.draftEditor, variables.c.instrumentVersionComparer,
			variables.c.snapshotCompiler, variables.c.instrumentDocumentExporter
		);
	}

	private string function label(required string suffix) { return variables.run & "-" & arguments.suffix; }

	private struct function configFor(required string versionLabel) {
		var cfg = repoJson("config/instrument-config.json");
		cfg.instrument.code = variables.code;
		cfg.instrument.version.versionLabel = arguments.versionLabel;
		return cfg;
	}

	/** Nothing about the version moved: status, checksum, snapshot bytes, row version. */
	private void function assertUnchanged(required struct before, required string versionId, required string what) {
		var after = variables.repo.findVersionById(arguments.versionId);
		assertFalse(structIsEmpty(after), arguments.what & " still exists");
		assertExactTextEquals(arguments.before.status, after.status, arguments.what & ": status");
		assertExactTextEquals(arguments.before.checksum, after.checksum, arguments.what & ": checksum");
		assertExactTextEquals(arguments.before.snapshotJson, after.snapshotJson, arguments.what & ": snapshot bytes");
		assertRowVersionEquals(arguments.before.rowVersion, after.rowVersion, arguments.what & ": row version");
	}

	private string function persistedDefinitionsChecksum(required string versionId) {
		return variables.c.snapshotCompiler.definitionsChecksum(variables.repo.loadNormalizedDefinitions(arguments.versionId));
	}

	private struct function aScoredItem(required string versionId) {
		var snapshot = deserializeJSON(variables.repo.findVersionById(arguments.versionId).snapshotJson);
		for (var it in snapshot.definitions.items) {
			if (compare(it.itemType, "SINGLE_CHOICE") == 0 && compare(it.reviewStatus, "Source baseline") == 0) return it;
		}
		fail("no scored item");
	}

	private string function itemPrompt(required string versionId, required string itemKey) {
		var q = variables.db.run(
			"SELECT prompt FROM [icf].[item_definition] WHERE version_id = :v AND item_key = :k",
			{ "v": variables.db.guid(arguments.versionId), "k": variables.db.nvarchar(arguments.itemKey, 100) }
		);
		return q.recordCount ? q.prompt[1] : "";
	}

	private string function promptIn(required struct document, required string itemKey) {
		for (var it in arguments.document.items) if (compare(it.itemKey, arguments.itemKey) == 0) return it.prompt;
		fail("no item " & arguments.itemKey & " in the exported document");
	}

	private numeric function labelCount(required string versionLabel) {
		return variables.db.scalar(
			"SELECT COUNT(*) AS n FROM [icf].[instrument_version] WHERE version_label = :l",
			{ "l": variables.db.nvarchar(arguments.versionLabel, 100) }
		);
	}

	private numeric function auditCount(required string entityId, required string eventType) {
		return variables.db.scalar(
			"SELECT COUNT(*) AS n FROM [icf].[audit_event] WHERE entity_id = :id AND event_type = :t",
			{ "id": variables.db.guid(arguments.entityId), "t": variables.db.nvarchar(arguments.eventType) }
		);
	}

	private struct function lastAudit(required string entityId, required string eventType) {
		var q = variables.db.run(
			"SELECT TOP (1) details_json FROM [icf].[audit_event] WHERE entity_id = :id AND event_type = :t ORDER BY event_id DESC",
			{ "id": variables.db.guid(arguments.entityId), "t": variables.db.nvarchar(arguments.eventType) }
		);
		if (!q.recordCount) fail("no " & arguments.eventType & " event for " & arguments.entityId);
		return deserializeJSON(q.details_json[1]);
	}

	private string function lastActor(required string entityId, required string eventType) {
		var q = variables.db.run(
			"SELECT TOP (1) actor_user_id FROM [icf].[audit_event] WHERE entity_id = :id AND event_type = :t ORDER BY event_id DESC",
			{ "id": variables.db.guid(arguments.entityId), "t": variables.db.nvarchar(arguments.eventType) }
		);
		return q.recordCount ? q.actor_user_id[1] : "";
	}
}
