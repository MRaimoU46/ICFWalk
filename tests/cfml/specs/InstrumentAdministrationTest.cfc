/**
 * Instrument administration (Phase 6: ADM-01, ADM-02, ADM-06, ADM-07, ADM-08, and discard),
 * against the real services and the real database.
 *
 * WHAT IS PROVED HERE.
 *   ADM-01  An administrator's uploaded document imports into a DRAFT and the result is the
 *           validation summary: counts, the seventeen placeholder warnings, and the placeholders.
 *   ADM-02  A DRAFT's preview is the render model walks would render -- the same model, built by
 *           the same builder from the same verified snapshot -- not a separate rendering.
 *   ADM-06  A new DRAFT cloned from a PUBLISHED version starts with exactly the source's
 *           definitions, leaves the source byte-identical (snapshot, checksum, row version), takes
 *           one prompt edit, and the comparison of the two versions reports exactly that prompt,
 *           from its exact old text to its exact new text. The refusals around it -- a label that is
 *           taken, stale edits, edits to a frozen version, edits that would make the instrument
 *           invalid, a malformed request -- change nothing and leave the durable trace every
 *           refused write leaves. An edit set that changes nothing writes nothing.
 *   ADM-07  Retiring a PUBLISHED version that historical walks use: the version leaves the
 *           current-version predicate, a new walk is pinned to the successor and never to it, the
 *           existing walk still renders from it, and its snapshot, checksum, publisher and
 *           publication time are exactly as frozen. Retiring a DRAFT or a RETIRED version is
 *           refused, and retiring the only in-service version is refused unless confirmed.
 *   ADM-08  The placeholder review queue lists exactly the seventeen items with their source
 *           location and review status, searchable, and it shrinks when one is resolved by edit.
 *
 * Every fixture version lives under this spec's own instrument code, so nothing here publishes,
 * retires or edits the ICFWalk instrument other specs and the runtime read.
 */
component extends="icfwalktests.BaseSpec" output="false" {

	public string function skipReason() {
		return schemaPresent() ? "" : "icf schema is not present in datasource '" & variables.c.db.datasourceName() & "'.";
	}

	public void function beforeAll() {
		variables.run = "adm-" & lCase(left(replace(createUUID(), "-", "", "all"), 8));
		variables.instrumentCode = "ADMFIX" & uCase(left(replace(createUUID(), "-", "", "all"), 8));
		variables.db = variables.c.db;
		variables.repo = variables.c.definitionRepository;
		variables.admin = variables.c.instrumentAdminService;
		variables.publishSvc = variables.c.instrumentPublishService;
		variables.snapshots = variables.c.snapshotService;
		variables.cleanup = new icfwalktests.support.FixtureCleanup(variables.c);
		variables.adminId = variables.cleanup.ensureUser(variables.run & "-admin", "Administration fixture administrator");

		// A walker and a school, for the ADM-07 walks. Walks are created through a WalkService bound
		// to THIS spec's instrument, so the ICFWalk instrument's current version is never involved.
		variables.fx = createObject("component", "icfwalktests.support.Fixtures").init(variables.c, variables.run);
		variables.district = variables.fx.orgUnit("d", "DISTRICT");
		variables.school = variables.fx.orgUnit("s", "SCHOOL", variables.district);
		variables.walker = variables.fx.user("walker");
		variables.fx.assign(variables.walker.userId, "SCHOOL_WALK_REPORT", variables.school, false);

		// V1, imported and published: the version the clone and retirement cases start from.
		variables.v1 = variables.c.instrumentImportService.importConfig(config(label("v1")), variables.adminId);
		variables.publishSvc.publish(variables.v1.versionId, variables.adminId);
	}

	public void function afterAll() {
		variables.fx.remove();
		variables.cleanup.removeInstrumentsCoded(variables.instrumentCode);
		variables.cleanup.removeUsers(variables.run & "-");
	}

	// ---- ADM-01 ----------------------------------------------------------------------------------

	/** The administrator's import returns the validation summary the acceptance criterion names. */
	public void function testImportOfTheSuppliedDocumentReturnsTheValidationSummary() {
		var result = variables.admin.importDocument(config(label("adm01")), variables.adminId);
		assertTrue(result.created, "a new DRAFT was created");
		assertExactTextEquals("DRAFT", result.status);
		assertEquals(23, result.counts.sections);
		assertEquals(144, result.counts.items);
		assertEquals(29, result.counts.responseSets);
		assertEquals(138, result.counts.responseOptions);
		assertEquals(12, result.counts.rules);
		assertEquals(10, result.counts.dimensions);
		assertEquals(95, result.counts.dimensionValues);
		assertEquals(17, arrayLen(result.placeholders), "seventeen placeholders");
		var placeholderWarnings = 0;
		for (var w in result.warnings) if (findNoCase("PLACEHOLDER", w.code)) placeholderWarnings++;
		assertEquals(17, placeholderWarnings, "and seventeen placeholder warnings in the summary");
		var q = variables.db.run(
			"SELECT created_by_user_id FROM [icf].[instrument_version] WHERE version_id = :id",
			{ "id": variables.db.guid(result.versionId) }
		);
		assertExactTextEquals(variables.adminId, uCase(q.created_by_user_id[1]), "attributed to the administrator who imported it");
	}

	/** Something that is not a document is refused before anything is read or written. */
	public void function testAnImportWithoutADocumentIsRefused() {
		var admin = variables.admin;
		var actor = variables.adminId;
		assertThrows(function() { admin.importDocument("not a document", actor); }, "ICFWalk.Validation", "DOCUMENT_REQUIRED");
		assertThrows(function() { admin.importDocument([], actor); }, "ICFWalk.Validation", "DOCUMENT_REQUIRED");
	}

	// ---- ADM-02 ----------------------------------------------------------------------------------

	/** Preview is the render model walks render, for a DRAFT as for a PUBLISHED version. */
	public void function testPreviewIsTheRenderModelWalksRender() {
		var draft = variables.c.instrumentImportService.importConfig(config(label("adm02")), variables.adminId);
		var preview = variables.admin.preview(draft.versionId);
		assertExactTextEquals("DRAFT", preview.version.status);
		assertExactTextEquals(draft.checksum, preview.version.checksum);
		assertExactTextEquals(
			canonical(variables.snapshots.renderModelFor(draft.versionId)),
			canonical(preview.model),
			"the preview model is the walk render model, built by the same builder from the same snapshot"
		);
		assertExactTextEquals(variables.c.config.hiddenPeriodPolicy, preview.policies.hiddenDimensionPolicy, "with the same runtime policies");
		var published = variables.admin.preview(variables.v1.versionId);
		assertExactTextEquals("PUBLISHED", published.version.status);

		var admin = variables.admin;
		var absent = variables.db.newGuid();
		assertThrows(function() { admin.preview(absent); }, "ICFWalk.NotFound", "INSTRUMENT_VERSION_NOT_FOUND");
		assertThrows(function() { admin.preview("not-a-guid"); }, "ICFWalk.Validation", "INVALID_VERSION_ID");
	}

	// ---- ADM-06 ----------------------------------------------------------------------------------

	/**
	 * The acceptance case end to end: a new DRAFT from a published version, one prompt altered, the
	 * prior version unchanged, and the comparison showing the exact prompt change.
	 */
	public void function testCloneEditAndCompareShowTheExactPromptChange() {
		var before = variables.repo.findVersionById(variables.v1.versionId);
		var v1Definitions = definitionsChecksumOf(variables.v1.versionId);

		var clone = variables.admin.cloneVersion(variables.v1.versionId, { "versionLabel": label("adm06"), "revisionNotes": "Prompt review" }, variables.adminId);
		assertTrue(clone.created);
		assertExactTextEquals("DRAFT", clone.status);
		assertExactTextEquals(variables.v1.versionId, clone.sourceVersionId);
		assertExactTextEquals(v1Definitions, clone.definitionsChecksum, "the clone starts with exactly the source's definitions");
		assertEquals(1, auditCount(clone.versionId, "INSTRUMENT_VERSION_CLONED"), "one clone event");
		var clonedEvent = lastAudit(clone.versionId, "INSTRUMENT_VERSION_CLONED");
		assertExactTextEquals(variables.v1.versionId, clonedEvent.sourceVersionId, "naming its source");

		var target = aScoredItem(clone.versionId);
		var edited = variables.admin.editDraft(clone.versionId, {
			"expectedChecksum": clone.checksum,
			"edits": [{ "target": "item", "key": target.itemKey, "field": "prompt", "value": "An altered prompt for ADM-06" }]
		}, variables.adminId);
		assertTrue(edited.changed);
		assertExactTextNotEquals(clone.checksum, edited.checksum, "the DRAFT's snapshot moved");
		assertEquals(1, auditCount(clone.versionId, "INSTRUMENT_VERSION_EDITED"), "one edit event");
		assertExactTextEquals("An altered prompt for ADM-06", itemPrompt(clone.versionId, target.itemKey), "the definition row carries the new prompt");

		// The prior version is unchanged, byte for byte.
		var after = variables.repo.findVersionById(variables.v1.versionId);
		assertExactTextEquals(before.snapshotJson, after.snapshotJson, "V1's snapshot bytes are unchanged");
		assertExactTextEquals(before.checksum, after.checksum, "and its checksum");
		assertRowVersionEquals(before.rowVersion, after.rowVersion, "and its row version");
		assertExactTextEquals(target.prompt, itemPrompt(variables.v1.versionId, target.itemKey), "and its prompt");

		// The comparison shows exactly that change.
		var diff = variables.admin.compareVersions(variables.v1.versionId, clone.versionId);
		assertEquals(1, arrayLen(diff.changes), "one definition changed between the two versions");
		assertExactTextEquals("items", diff.changes[1].collection);
		assertExactTextEquals(target.itemKey, diff.changes[1].key);
		assertEquals(1, arrayLen(diff.changes[1].fields));
		assertExactTextEquals("prompt", diff.changes[1].fields[1].field);
		assertExactTextEquals(target.prompt, diff.changes[1].fields[1].from, "from the exact old wording");
		assertExactTextEquals("An altered prompt for ADM-06", diff.changes[1].fields[1].to, "to the exact new wording");
		var metadataFields = [];
		for (var m in diff.metadata) arrayAppend(metadataFields, m.field);
		assertTrue(arrayContains(metadataFields, "version.versionLabel"), "the label difference is reported as version metadata");
	}

	/** Cloning onto a label that is taken is refused, audited, and creates nothing. */
	public void function testACloneOntoAnExistingLabelIsRefusedAndAudited() {
		var existing = variables.c.instrumentImportService.importConfig(config(label("taken")), variables.adminId);
		var versionsBefore = versionCount();
		var refusalsBefore = auditCount(existing.versionId, "INSTRUMENT_VERSION_WRITE_REFUSED");
		var admin = variables.admin;
		var source = variables.v1.versionId;
		var body = { "versionLabel": label("taken") };
		var actor = variables.adminId;
		assertThrows(function() { admin.cloneVersion(source, body, actor); }, "ICFWalk.Conflict", "VERSION_LABEL_EXISTS");
		assertEquals(versionsBefore, versionCount(), "no version was created");
		assertEquals(refusalsBefore + 1, auditCount(existing.versionId, "INSTRUMENT_VERSION_WRITE_REFUSED"), "exactly one durable refusal");
		var refusal = lastAudit(existing.versionId, "INSTRUMENT_VERSION_WRITE_REFUSED");
		assertExactTextEquals("CLONE", refusal.operation);
		assertExactTextEquals("VERSION_LABEL_EXISTS", refusal.reason);
	}

	/** A clone request says what it means or is refused. */
	public void function testAMalformedCloneRequestIsRefused() {
		var admin = variables.admin;
		var source = variables.v1.versionId;
		var actor = variables.adminId;
		assertThrows(function() { admin.cloneVersion(source, {}, actor); }, "ICFWalk.Validation", "VERSION_LABEL_INVALID");
		assertThrows(function() { admin.cloneVersion(source, { "versionLabel": "   " }, actor); }, "ICFWalk.Validation", "VERSION_LABEL_INVALID");
		assertThrows(function() { admin.cloneVersion(source, { "versionLabel": repeatString("x", 101) }, actor); }, "ICFWalk.Validation", "VERSION_LABEL_INVALID");
		assertThrows(function() { admin.cloneVersion(source, { "versionLabel": 7 }, actor); }, "ICFWalk.Validation", "VERSION_LABEL_INVALID");
		assertThrows(function() { admin.cloneVersion(source, { "versionLabel": "ok", "status": "PUBLISHED" }, actor); }, "ICFWalk.Validation", "CLONE_BODY_INVALID");
		var absent = variables.db.newGuid();
		assertThrows(function() { admin.cloneVersion(absent, { "versionLabel": "ok" }, actor); }, "ICFWalk.NotFound", "INSTRUMENT_VERSION_NOT_FOUND");
	}

	/** Edits made against content that has since changed are refused, audited, and change nothing. */
	public void function testStaleEditsAreRefusedAndChangeNothing() {
		var draft = variables.c.instrumentImportService.importConfig(config(label("stale")), variables.adminId);
		var target = aScoredItem(draft.versionId);
		var first = variables.admin.editDraft(draft.versionId, {
			"expectedChecksum": draft.checksum,
			"edits": [{ "target": "item", "key": target.itemKey, "field": "prompt", "value": "First administrator's wording" }]
		}, variables.adminId);
		var before = variables.repo.findVersionById(draft.versionId);
		var refusalsBefore = auditCount(draft.versionId, "INSTRUMENT_VERSION_WRITE_REFUSED");
		var admin = variables.admin;
		var id = draft.versionId;
		var stale = { "expectedChecksum": draft.checksum, "edits": [{ "target": "item", "key": target.itemKey, "field": "prompt", "value": "Second administrator's wording" }] };
		var actor = variables.adminId;
		var e = assertThrows(function() { admin.editDraft(id, stale, actor); }, "ICFWalk.Conflict", "DRAFT_CHANGED");
		assertExactTextEquals(first.checksum, variables.c.errors.detailsOf(e).currentChecksum, "the refusal names the current checksum to reload against");
		var after = variables.repo.findVersionById(draft.versionId);
		assertRowVersionEquals(before.rowVersion, after.rowVersion, "nothing moved");
		assertExactTextEquals("First administrator's wording", itemPrompt(draft.versionId, target.itemKey), "the first edit stands");
		assertEquals(refusalsBefore + 1, auditCount(draft.versionId, "INSTRUMENT_VERSION_WRITE_REFUSED"), "one durable refusal");
		assertExactTextEquals("DRAFT_CHANGED", lastAudit(draft.versionId, "INSTRUMENT_VERSION_WRITE_REFUSED").reason);
	}

	/** A frozen version cannot be edited, however the request is formed. */
	public void function testAPublishedVersionCannotBeEdited() {
		var before = variables.repo.findVersionById(variables.v1.versionId);
		var target = aScoredItem(variables.v1.versionId);
		var admin = variables.admin;
		var id = variables.v1.versionId;
		var body = { "expectedChecksum": lCase(trim(before.checksum)), "edits": [{ "target": "item", "key": target.itemKey, "field": "prompt", "value": "Not allowed" }] };
		var actor = variables.adminId;
		assertThrows(function() { admin.editDraft(id, body, actor); }, "ICFWalk.Import.PublishedVersion", "INSTRUMENT_VERSION_IMMUTABLE");
		var after = variables.repo.findVersionById(variables.v1.versionId);
		assertRowVersionEquals(before.rowVersion, after.rowVersion, "the published version did not move");
		assertExactTextEquals(before.snapshotJson, after.snapshotJson);
		assertExactTextEquals("VERSION_NOT_DRAFT", lastAudit(variables.v1.versionId, "INSTRUMENT_VERSION_WRITE_REFUSED").reason, "and the attempt is on the record");
	}

	/** An edit that would make the instrument invalid is refused by the shared rule set. */
	public void function testAnEditThatBreaksTheInstrumentIsRefusedByTheSharedRules() {
		var draft = variables.c.instrumentImportService.importConfig(config(label("invalid")), variables.adminId);
		var before = variables.repo.findVersionById(draft.versionId);
		var target = aScoredItem(draft.versionId);
		var admin = variables.admin;
		var id = draft.versionId;
		var body = { "expectedChecksum": draft.checksum, "edits": [{ "target": "item", "key": target.itemKey, "field": "prompt", "value": "School Improvement (SIP) Goals" }] };
		var actor = variables.adminId;
		var e = assertThrows(function() { admin.editDraft(id, body, actor); }, "ICFWalk.Import.Validation", "INSTRUMENT_CONFIG_INVALID");
		var codes = [];
		for (var issue in variables.c.errors.detailsOf(e).issues) arrayAppend(codes, issue.code);
		assertTrue(arrayContains(codes, "RETIRED_CONTENT_PRESENT"), "refused by the retired-content rule an import would apply: " & arrayToList(codes));
		assertRowVersionEquals(before.rowVersion, variables.repo.findVersionById(draft.versionId).rowVersion, "nothing moved");
	}

	/** An edit set that changes nothing writes nothing and audits nothing. */
	public void function testAnEditThatChangesNothingWritesNothing() {
		var draft = variables.c.instrumentImportService.importConfig(config(label("noop")), variables.adminId);
		var before = variables.repo.findVersionById(draft.versionId);
		var target = aScoredItem(draft.versionId);
		var result = variables.admin.editDraft(draft.versionId, {
			"expectedChecksum": draft.checksum,
			"edits": [{ "target": "item", "key": target.itemKey, "field": "prompt", "value": target.prompt }]
		}, variables.adminId);
		assertFalse(result.changed);
		assertExactTextEquals(draft.checksum, result.checksum);
		assertRowVersionEquals(before.rowVersion, variables.repo.findVersionById(draft.versionId).rowVersion, "the row was not written");
		assertEquals(0, auditCount(draft.versionId, "INSTRUMENT_VERSION_EDITED"), "and nothing was audited");
	}

	/** A malformed edit request is a 400 and never reaches the write. */
	public void function testAMalformedEditRequestIsRefused() {
		var draft = variables.c.instrumentImportService.importConfig(config(label("malformed")), variables.adminId);
		var admin = variables.admin;
		var id = draft.versionId;
		var actor = variables.adminId;
		var good = draft.checksum;
		assertThrows(function() { admin.editDraft(id, { "edits": [] }, actor); }, "ICFWalk.Validation", "EXPECTED_CHECKSUM_REQUIRED");
		assertThrows(function() { admin.editDraft(id, { "expectedChecksum": "abc", "edits": [] }, actor); }, "ICFWalk.Validation", "EXPECTED_CHECKSUM_REQUIRED");
		assertThrows(function() { admin.editDraft(id, { "expectedChecksum": good, "edits": [] }, actor); }, "ICFWalk.Validation", "DRAFT_EDIT_INVALID");
		assertThrows(function() { admin.editDraft(id, { "expectedChecksum": good, "edits": [{ "target": "item", "key": "x", "field": "itemType", "value": "x" }] }, actor); }, "ICFWalk.Validation", "DRAFT_EDIT_INVALID");
		assertThrows(function() { admin.editDraft(id, { "expectedChecksum": good, "edits": [], "status": "PUBLISHED" }, actor); }, "ICFWalk.Validation", "EDIT_BODY_INVALID");
	}

	// ---- ADM-08 ----------------------------------------------------------------------------------

	/** Exactly the seventeen placeholder items, with source location and review status, searchable. */
	public void function testThePlaceholderQueueListsExactlySeventeenWithSourceAndStatus() {
		var draft = variables.c.instrumentImportService.importConfig(config(label("adm08")), variables.adminId);
		var queue = variables.admin.placeholders(draft.versionId);
		assertEquals(17, queue.total);
		assertEquals(17, queue.matched);
		assertEquals(17, arrayLen(queue.items));
		assertTrue(queue.editable, "a DRAFT's queue can be worked from");
		for (var p in queue.items) {
			assertTrue(len(p.sourceLocation) > 0, p.itemKey & " carries its source location");
			assertExactTextEquals("Placeholder in source", p.reviewStatus, p.itemKey & " carries its review status");
			assertTrue(len(p.sectionTitle) > 0, p.itemKey & " names its section");
		}
		var prek = variables.admin.placeholders(draft.versionId, "PREK_K_ITEMS");
		assertEquals(3, prek.matched, "search by source location");
		assertEquals(17, prek.total, "while the total still shows every unresolved placeholder");
		assertEquals(17, variables.admin.placeholders(draft.versionId, "place holder").matched, "search by wording");
		assertEquals(0, variables.admin.placeholders(draft.versionId, "nothing matches this").matched);

		// Resolving one by edit takes it out of the queue.
		var first = queue.items[1];
		variables.admin.editDraft(draft.versionId, {
			"expectedChecksum": draft.checksum,
			"edits": [
				{ "target": "item", "key": first.itemKey, "field": "prompt", "value": "Approved wording for this question" },
				{ "target": "item", "key": first.itemKey, "field": "reviewStatus", "value": "Approved wording" }
			]
		}, variables.adminId);
		var after = variables.admin.placeholders(draft.versionId);
		assertEquals(16, after.total, "the resolved item left the queue");
	}

	// ---- discard ---------------------------------------------------------------------------------

	public void function testADraftCanBeDiscardedButAPublishedVersionCannot() {
		var draft = variables.c.instrumentImportService.importConfig(config(label("discard")), variables.adminId);
		var result = variables.admin.discard(draft.versionId, variables.adminId);
		assertTrue(result.discarded);
		assertTrue(structIsEmpty(variables.repo.findVersionById(draft.versionId)), "the DRAFT is gone");

		var admin = variables.admin;
		var published = variables.v1.versionId;
		var actor = variables.adminId;
		var before = variables.repo.findVersionById(published);
		assertThrows(function() { admin.discard(published, actor); }, "ICFWalk.Import.PublishedVersion", "INSTRUMENT_VERSION_IMMUTABLE");
		assertRowVersionEquals(before.rowVersion, variables.repo.findVersionById(published).rowVersion, "the published version is untouched");
	}

	// ---- ADM-07 ----------------------------------------------------------------------------------

	/**
	 * Retire a published version historical walks use: no new walk uses it, the existing walk still
	 * renders from it, and what was frozen stays frozen.
	 */
	public void function testRetiringAVersionInUseStopsNewWalksButNotHistoricalOnes() {
		// V2 from V1, published, so V1 has a successor; a historical walk pinned to V1.
		var v1 = variables.c.instrumentImportService.importConfig(config(label("r-v1")), variables.adminId);
		variables.publishSvc.publish(v1.versionId, variables.adminId);
		var walks = walkService();
		var historical = walks.create(principal(), { "orgUnitId": variables.school, "clientMutationId": variables.db.newGuid() });
		assertExactTextEquals(v1.versionId, historical.versionId, "precondition: the historical walk is pinned to V1");
		var modelBefore = canonical(variables.snapshots.renderModelFor(v1.versionId));

		var v2 = variables.admin.cloneVersion(v1.versionId, { "versionLabel": label("r-v2") }, variables.adminId);
		variables.publishSvc.publish(v2.versionId, variables.adminId);
		var frozen = variables.repo.findVersionById(v1.versionId);

		var retired = variables.publishSvc.retire(v1.versionId, variables.adminId);
		assertExactTextEquals("RETIRED", retired.status);
		assertEquals(1, retired.walkCount, "the retirement knows a walk uses the version");
		assertExactTextEquals(v2.versionId, retired.successorVersionId, "and which version takes over");

		var row = variables.repo.findVersionById(v1.versionId);
		assertExactTextEquals("RETIRED", row.status);
		assertExactTextEquals(frozen.snapshotJson, row.snapshotJson, "the frozen snapshot is unchanged");
		assertExactTextEquals(frozen.checksum, row.checksum, "and its checksum");
		assertExactTextEquals(frozen.publishedByUserId, row.publishedByUserId, "and its publisher");
		assertExactTextEquals(toString(frozen.publishedAt), toString(row.publishedAt), "and when it was published");
		var q = variables.db.run("SELECT effective_end FROM [icf].[instrument_version] WHERE version_id = :id", { "id": variables.db.guid(v1.versionId) });
		assertTrue(isDate(q.effective_end[1]), "effective_end records when it went out of service");
		assertEquals(1, auditCount(v1.versionId, "INSTRUMENT_VERSION_RETIRED"), "one retirement event");

		// No new walk uses it.
		var fresh = walks.create(principal(), { "orgUnitId": variables.school, "clientMutationId": variables.db.newGuid() });
		assertExactTextEquals(v2.versionId, fresh.versionId, "a new walk is pinned to the successor");
		assertFalse(structKeyExists(variables.repo.currentVersionIds(), v1.versionId), "the retired version is not current");

		// The historical walk still opens and renders from the version it was conducted under.
		var reopened = walks.open(principal(), historical.id);
		assertExactTextEquals(v1.versionId, reopened.versionId, "the historical walk is still pinned to V1");
		variables.snapshots.clearCache();
		assertExactTextEquals(modelBefore, canonical(variables.snapshots.renderModelFor(v1.versionId)), "and renders from exactly the snapshot it always did");
	}

	/** Only a PUBLISHED version can be retired, and every refusal is audited and moves nothing. */
	public void function testOnlyAPublishedVersionCanBeRetired() {
		var draft = variables.c.instrumentImportService.importConfig(config(label("r-draft")), variables.adminId);
		var svc = variables.publishSvc;
		var actor = variables.adminId;
		var draftId = draft.versionId;
		var before = variables.repo.findVersionById(draftId);
		assertThrows(function() { svc.retire(draftId, actor); }, "ICFWalk.Retire.NotPublished", "INSTRUMENT_VERSION_NOT_PUBLISHED");
		assertRowVersionEquals(before.rowVersion, variables.repo.findVersionById(draftId).rowVersion, "the DRAFT did not move");
		assertExactTextEquals("NOT_PUBLISHED", lastAudit(draftId, "INSTRUMENT_VERSION_RETIRE_REFUSED").reason);

		var once = variables.c.instrumentImportService.importConfig(config(label("r-once")), variables.adminId);
		svc.publish(once.versionId, actor);
		var onceId = once.versionId;
		svc.retire(onceId, actor, true);
		var retiredRow = variables.repo.findVersionById(onceId);
		assertThrows(function() { svc.retire(onceId, actor, true); }, "ICFWalk.Retire.NotPublished", "INSTRUMENT_VERSION_NOT_PUBLISHED");
		assertRowVersionEquals(retiredRow.rowVersion, variables.repo.findVersionById(onceId).rowVersion, "a second retirement moves nothing");
		assertEquals(1, auditCount(onceId, "INSTRUMENT_VERSION_RETIRED"), "and records no second success");
		assertEquals(1, auditCount(onceId, "INSTRUMENT_VERSION_RETIRE_REFUSED"), "but does record the attempt");
	}

	/**
	 * Retiring the only in-service version stops every new walk, so it is refused unless the
	 * administrator confirms it; confirmed, it happens and says so.
	 */
	public void function testRetiringTheOnlyInServiceVersionRequiresConfirmation() {
		var code = variables.instrumentCode & "L";
		var only = variables.c.instrumentImportService.importConfig(configFor(code, label("only")), variables.adminId);
		variables.publishSvc.publish(only.versionId, variables.adminId);
		var before = variables.repo.findVersionById(only.versionId);
		var svc = variables.publishSvc;
		var id = only.versionId;
		var actor = variables.adminId;
		assertThrows(function() { svc.retire(id, actor); }, "ICFWalk.Conflict", "RETIRE_LEAVES_NO_CURRENT_VERSION");
		var unchanged = variables.repo.findVersionById(only.versionId);
		assertExactTextEquals("PUBLISHED", unchanged.status);
		assertRowVersionEquals(before.rowVersion, unchanged.rowVersion, "nothing moved");
		assertExactTextEquals("LEAVES_NO_CURRENT_VERSION", lastAudit(only.versionId, "INSTRUMENT_VERSION_RETIRE_REFUSED").reason);

		var confirmed = svc.retire(id, actor, true);
		assertExactTextEquals("RETIRED", confirmed.status);
		assertTrue(confirmed.leftNoCurrentVersion, "the result says new walks have stopped");
		var walks = walkService(code);
		var p = principal();
		var unit = variables.school;
		assertThrows(function() { walks.create(p, { "orgUnitId": unit, "clientMutationId": variables.db.newGuid() }); }, "ICFWalk.NotFound", "INSTRUMENT_NOT_AVAILABLE");
	}

	/**
	 * Reports outlive the version they report on. Once the only in-service version is retired
	 * (confirmed), nothing is current, but its walks are still reportable: the report options must
	 * still open, defaulting to the newest frozen version, instead of refusing with "no version".
	 */
	public void function testReportsStillOpenWhenNoVersionIsInService() {
		var code = variables.instrumentCode & "R";
		var only = variables.c.instrumentImportService.importConfig(configFor(code, label("report-only")), variables.adminId);
		variables.publishSvc.publish(only.versionId, variables.adminId);
		var walks = walkService(code);
		var created = walks.create(principal(), { "orgUnitId": variables.school, "clientMutationId": variables.db.newGuid() });
		variables.publishSvc.retire(only.versionId, variables.adminId, true);

		var reports = reportService(code);
		var options = reports.options(principal(), {});
		assertExactTextEquals(uCase(only.versionId), options.version.versionId, "the retired version is the default");
		assertExactTextEquals("RETIRED", options.version.status);
		assertEquals(1, arrayLen(options.versions));
		assertFalse(options.versions[1].isCurrent, "and it is not presented as in service");
		var report = reports.aggregate(principal(), { "includeDrafts": "true" });
		assertExactTextEquals(uCase(only.versionId), report.version.versionId);
		assertEquals(1, report.population.walks, "the walk on the retired version is still counted");
		variables.fx.deleteWalk(created.id);
	}

	// ---- helpers ---------------------------------------------------------------------------------

	/** A ReportService whose runtime instrument is `code`, with no DRAFT fallback. */
	private any function reportService(required string code) {
		var cfg = duplicate(variables.c.config);
		cfg.instrumentCode = arguments.code;
		cfg.allowUnpublishedInstrument = false;
		var snap = createObject("component", "icfwalk.instrument.SnapshotService").init(
			cfg, variables.c.db, variables.c.definitionRepository, variables.c.renderModelBuilder, variables.c.errors, variables.c.logger, variables.c.canonicalJson
		);
		return createObject("component", "icfwalk.reports.ReportService").init(
			cfg, variables.c.db, variables.c.errors, variables.c.logger, variables.c.auditRepository, variables.c.canonicalJson,
			variables.c.authorizationService, snap, variables.c.visibilityEngine, variables.c.walkRepository,
			variables.c.orgUnitRepository, variables.c.reportRepository
		);
	}

	/**
	 * A WalkService whose current version is THIS spec's instrument, with no DRAFT fallback, so
	 * "which version does a new walk use" is answered for the fixture and never for ICFWalk.
	 */
	private any function walkService(string code = variables.instrumentCode) {
		var cfg = duplicate(variables.c.config);
		cfg.instrumentCode = arguments.code;
		cfg.allowUnpublishedInstrument = false;
		var snap = createObject("component", "icfwalk.instrument.SnapshotService").init(
			cfg, variables.c.db, variables.c.definitionRepository, variables.c.renderModelBuilder, variables.c.errors, variables.c.logger, variables.c.canonicalJson
		);
		return createObject("component", "icfwalk.walks.WalkService").init(
			cfg, variables.c.db, variables.c.errors, variables.c.logger, variables.c.auditRepository,
			variables.c.canonicalJson, variables.c.authorizationService, snap,
			variables.c.visibilityEngine, variables.c.walkRepository, variables.c.walkPayloadValidator, variables.c.orgUnitRepository,
			variables.c.walkSummaryFormatter
		);
	}

	private struct function principal() { return variables.fx.principal(variables.walker.userId); }

	private string function label(required string suffix) {
		return variables.run & "-" & arguments.suffix;
	}

	private struct function config(required string versionLabel) {
		return configFor(variables.instrumentCode, arguments.versionLabel);
	}

	private struct function configFor(required string code, required string versionLabel) {
		var cfg = repoJson("config/instrument-config.json");
		cfg.instrument.code = arguments.code;
		cfg.instrument.version.versionLabel = arguments.versionLabel;
		return cfg;
	}

	private string function canonical(required any value) {
		return variables.c.canonicalJson.serialize(arguments.value);
	}

	private string function definitionsChecksumOf(required string versionId) {
		return variables.c.snapshotCompiler.definitionsChecksum(deserializeJSON(variables.repo.findVersionById(arguments.versionId).snapshotJson).definitions);
	}

	/** A scored, non-placeholder question from the version's snapshot. */
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

	private numeric function versionCount() {
		return variables.db.scalar(
			"SELECT COUNT(*) AS n FROM [icf].[instrument_version] v JOIN [icf].[instrument] i ON i.instrument_id = v.instrument_id WHERE i.code = :code",
			{ "code": variables.db.nvarchar(variables.instrumentCode, 60) }
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
}
