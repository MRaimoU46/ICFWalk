/**
 * Instrument administration (Phase 6): the operations the administration view performs, other
 * than publishing (InstrumentPublishService) and the shared-row metadata operation
 * (InstrumentMetadataService, still unrouted).
 *
 *   listVersions     every version, marked with the one each instrument would serve now
 *   preview          the render model of any version, DRAFT included (ADM-02)
 *   importDocument   an authoring document uploaded by an administrator (ADM-01)
 *   cloneVersion     a new DRAFT whose content is an existing version's snapshot (ADM-06)
 *   editDraft        wording and review-state edits to a DRAFT (ADM-06, ADM-08)
 *   wording          the editable surface of a version, searched (ADM-06, ADM-08)
 *   compareVersions  two versions, row by row on their logical keys (ADM-06)
 *   placeholders     the items still carrying placeholder source content, searched (ADM-08)
 *   discard          a DRAFT no walk references
 *
 * AUTHORIZATION is the route's: every administration route requires `instrument.manage`, the
 * global permission only MASTER_INSTRUMENT_ADMIN carries, and every state-changing one also
 * requires the session's CSRF token. The actor recorded for a write is the authenticated
 * principal's user id, passed by the controller; nothing in a request body names it.
 *
 * WRITES GO THROUGH ONE PATH. A clone and an edit both produce a normalized instrument document
 * and hand it to InstrumentImportService.writeNormalizedDraft -- the same validation, renderer
 * preflight, version lock, round-trip proof and refusal audit an import gets. This service never
 * writes a definition row itself.
 *
 * READS ARE OF SNAPSHOTS. Preview, compare, wording and placeholders read a version's compiled
 * snapshot through SnapshotService, which verifies the stored checksum before it parses anything,
 * so an administrator never reviews content the runtime would refuse to serve.
 */
component output="false" {

	variables.MAX_QUERY = 200;

	public InstrumentAdminService function init(
		required struct config, required any db, required any errors, required any logger,
		required any definitionRepository, required any snapshotService, required any importService,
		required any draftEditor, required any comparer, required any snapshotCompiler, required any documentExporter
	) {
		variables.config = arguments.config;
		variables.db = arguments.db;
		variables.errors = arguments.errors;
		variables.logger = arguments.logger;
		variables.repo = arguments.definitionRepository;
		variables.snapshots = arguments.snapshotService;
		variables.importer = arguments.importService;
		variables.editor = arguments.draftEditor;
		variables.comparer = arguments.comparer;
		variables.compiler = arguments.snapshotCompiler;
		variables.exporter = arguments.documentExporter;
		variables.types = new icfwalk.core.JsonTypes();
		return this;
	}

	// ---- versions --------------------------------------------------------------------------------

	public array function listVersions() {
		var current = variables.repo.currentVersionIds();
		var rows = variables.repo.listVersions();
		for (var row in rows) {
			row["isCurrent"] = structKeyExists(current, row.versionId);
			row["isRuntimeInstrument"] = compare(row.instrumentCode, variables.config.instrumentCode) == 0;
		}
		return rows;
	}

	/** The render model of any version, so an administrator sees exactly what walks would render. */
	public struct function preview(required string versionId) {
		var row = requireVersion(arguments.versionId);
		return {
			"version": versionSummary(row),
			"model": variables.snapshots.renderModelFor(row.versionId),
			"policies": { "hiddenDimensionPolicy": variables.config.hiddenPeriodPolicy }
		};
	}

	// ---- writes ----------------------------------------------------------------------------------

	/**
	 * Any version, of any status, as the authoring document an import takes: the starting point of
	 * the Excel round-trip and of a JSON download. Read from the checksum-verified snapshot and
	 * inverted by InstrumentDocumentExporter, so importing it (under a new label) produces a DRAFT
	 * with exactly this version's definitions. Read-only.
	 */
	public struct function exportDocument(required string versionId) {
		if (!variables.db.isGuid(arguments.versionId)) variables.errors.validation("versionId must be a GUID.", "INVALID_VERSION_ID");
		// ONE READ OF THE ROW (P6A-02). The metadata returned with the document -- above all its
		// checksum, which a workbook carries back as the state it was downloaded from -- and the
		// snapshot the document is built from come from the same read, verified against each other.
		// This used to read the row for the metadata and then read the snapshot again, so an edit
		// committed between the two paired one state's checksum with another state's content.
		var loaded = variables.snapshots.loadVersion(arguments.versionId);
		var normalized = variables.editor.normalizedFromSnapshot(loaded.snapshot);
		return { "version": versionSummary(loaded.row), "document": variables.exporter.toDocument(normalized) };
	}

	/**
	 * An uploaded authoring document (ADM-01). `document` is deliberately not `required`: an absent
	 * member arrives as null, and a required argument given null is an engine error (500) rather
	 * than this refusal (400).
	 *
	 * CREATE-ONLY UNLESS A REPLACEMENT IS NAMED (P6A-02). Without `replace`, a label that already
	 * names a DRAFT is refused (409 DRAFT_REPLACEMENT_REQUIRED) rather than re-imported -- including
	 * a DRAFT that appeared after the administrator's page last looked. With
	 * `replace = { versionId, expectedChecksum }`, the DRAFT under the document's label must be that
	 * exact version with that exact checksum, compared under the version lock the write holds; any
	 * other state is refused (409 DRAFT_CHANGED) and nothing is written. The page's confirmation is
	 * how an administrator chooses; this is what makes the choice hold.
	 */
	public struct function importDocument(any document, required string actorUserId, any replace) {
		if (!structKeyExists(arguments, "document") || !isStruct(arguments.document)) {
			variables.errors.validation("document must be the instrument configuration JSON object.", "DOCUMENT_REQUIRED");
		}
		var options = { "createOnly": true };
		if (structKeyExists(arguments, "replace")) {
			var token = replacementToken(arguments.replace);
			options = { "replaceVersionId": token.versionId, "expectedChecksum": token.expectedChecksum };
		}
		return variables.importer.importConfig(arguments.document, arguments.actorUserId, options);
	}

	/** `{ versionId: <GUID>, expectedChecksum: <64 hex> }` and nothing else, or 400 REPLACE_INVALID. */
	private struct function replacementToken(required any replace) {
		var shape = "replace must be { ""versionId"": the DRAFT's id, ""expectedChecksum"": the 64-hex-digit checksum you agreed to replace }.";
		if (!isStruct(arguments.replace)) variables.errors.validation(shape, "REPLACE_INVALID");
		for (var key in structKeyArray(arguments.replace)) {
			if (!arrayFindNoCase(["versionId", "expectedChecksum"], key)) variables.errors.validation("'" & key & "' is not accepted in replace. " & shape, "REPLACE_INVALID");
		}
		var id = structKeyExists(arguments.replace, "versionId") ? arguments.replace.versionId : javaCast("null", "");
		var checksum = structKeyExists(arguments.replace, "expectedChecksum") ? arguments.replace.expectedChecksum : javaCast("null", "");
		if (!structKeyExists(local, "id") || !variables.types.isJsonString(id) || !variables.db.isGuid(id)) variables.errors.validation(shape, "REPLACE_INVALID");
		if (!structKeyExists(local, "checksum") || !variables.types.isJsonString(checksum) || !reFind("^[0-9a-fA-F]{64}$", checksum)) variables.errors.validation(shape, "REPLACE_INVALID");
		return { "versionId": uCase(trim(id)), "expectedChecksum": lCase(checksum) };
	}

	/**
	 * A new DRAFT whose content is `sourceVersionId`'s compiled snapshot under a new label.
	 *
	 * The snapshot is the version -- for a PUBLISHED version it is what walks render -- and it
	 * carries everything the document did (behavior, content review, source reference), so the new
	 * DRAFT's definitions compile to exactly the source's definitions checksum. Only the version
	 * label changes, and optionally the version's revision notes. The source is read, never
	 * written: it may be a DRAFT, a PUBLISHED or a RETIRED version, and it is unchanged afterwards.
	 */
	public struct function cloneVersion(required string sourceVersionId, required struct body, required string actorUserId) {
		allowOnly(arguments.body, ["versionLabel", "revisionNotes"], "CLONE_BODY_INVALID");
		var label = requiredText(arguments.body, "versionLabel", 100, "VERSION_LABEL_INVALID");
		var notes = optionalText(arguments.body, "revisionNotes", 2000, "REVISION_NOTES_INVALID");
		var source = requireVersion(arguments.sourceVersionId);
		var normalized = variables.editor.normalizedFromSnapshot(variables.snapshots.snapshotFor(source.versionId));
		normalized.version["versionLabel"] = label;
		if (structKeyExists(local, "notes")) normalized.version["revisionNotes"] = notes;
		var result = variables.importer.writeNormalizedDraft(normalized, arguments.actorUserId, {
			"operation": "CLONE",
			"mustCreate": true,
			"successEvent": "INSTRUMENT_VERSION_CLONED",
			"auditDetails": { "sourceVersionId": source.versionId, "sourceVersionLabel": source.versionLabel, "sourceStatus": source.status, "sourceChecksum": source.checksum }
		});
		result["sourceVersionId"] = source.versionId;
		result["sourceVersionLabel"] = source.versionLabel;
		return result;
	}

	/**
	 * Applies wording edits to a DRAFT, against the snapshot checksum the caller read.
	 *
	 * The checksum is the optimistic-concurrency token: it identifies the DRAFT's content exactly.
	 * It is compared once here, before any work, and again under the version lock inside the write,
	 * so an edit made against content that has since changed is refused (409 DRAFT_CHANGED) rather
	 * than silently discarding the other change. An edit set that changes nothing writes nothing.
	 */
	public struct function editDraft(required string versionId, required struct body, required string actorUserId) {
		allowOnly(arguments.body, ["expectedChecksum", "edits"], "EDIT_BODY_INVALID");
		if (!structKeyExists(arguments.body, "expectedChecksum") || !variables.types.isJsonString(arguments.body.expectedChecksum)
			|| !reFind("^[0-9a-fA-F]{64}$", arguments.body.expectedChecksum)) {
			variables.errors.validation("expectedChecksum must be the 64-hex-digit checksum of the DRAFT the edits were made against.", "EXPECTED_CHECKSUM_REQUIRED");
		}
		var expected = lCase(arguments.body.expectedChecksum);
		var row = requireVersion(arguments.versionId);
		// Checked here AND again under the version lock inside the write. This first check is what
		// guarantees the edits below are applied to the content the caller actually read: if the
		// DRAFT changed and then changed back before the lock, the second check alone would accept
		// edits made against the intermediate content. Refused here, it is audited exactly as the
		// under-lock refusal is. A PUBLISHED or RETIRED version is left to the write path, which
		// refuses and audits it under the lock like any other attempt to write a frozen version.
		if (compare(lCase(trim(row.checksum)), expected) != 0) {
			variables.importer.recordRefusal(row.versionId, row.versionLabel, row.status, "EDIT", "DRAFT_CHANGED", arguments.actorUserId);
			variables.errors.conflict("This DRAFT changed after it was read. Reload it and make the edit again.", "DRAFT_CHANGED", { "versionId": row.versionId, "currentChecksum": lCase(trim(row.checksum)) });
		}
		var normalized = variables.editor.normalizedFromSnapshot(variables.snapshots.snapshotFor(row.versionId));
		var edited = variables.editor.apply(normalized, structKeyExists(arguments.body, "edits") ? arguments.body.edits : javaCast("null", ""));
		var result = variables.importer.writeNormalizedDraft(edited.normalized, arguments.actorUserId, {
			"operation": "EDIT",
			"targetVersionId": row.versionId,
			"expectedChecksum": expected,
			"skipWhenUnchanged": true,
			"successEvent": "INSTRUMENT_VERSION_EDITED",
			"auditDetails": { "editCount": arrayLen(edited.applied), "editedFields": editedFieldNames(edited.applied), "previousChecksum": expected }
		});
		result["applied"] = edited.applied;
		return result;
	}

	public struct function discard(required string versionId, required string actorUserId) {
		return variables.importer.discardDraftById(arguments.versionId, arguments.actorUserId);
	}

	// ---- reads -----------------------------------------------------------------------------------

	/** The editable surface of a version: fields, searched by key or wording. */
	public struct function wording(required string versionId, string query = "") {
		var row = requireVersion(arguments.versionId);
		var q = boundedQuery(arguments.query);
		var normalized = variables.editor.normalizedFromSnapshot(variables.snapshots.snapshotFor(row.versionId));
		var matches = variables.editor.search(normalized, q, 50);
		return {
			"version": versionSummary(row),
			"editable": row.status == "DRAFT",
			"query": q,
			"results": matches,
			"versionFields": variables.editor.describe(normalized, "version").fields,
			"fields": variables.editor.editableFields(),
			"maxEdits": variables.editor.maxEdits()
		};
	}

	/**
	 * Two versions compared on their compiled snapshots. `fromVersionId` is the baseline and
	 * `toVersionId` the candidate; the result lists what the candidate adds, removes and changes.
	 */
	public struct function compareVersions(required string fromVersionId, required string toVersionId) {
		var fromRow = requireVersion(arguments.fromVersionId);
		var toRow = requireVersion(arguments.toVersionId);
		var result = variables.comparer.diff(variables.snapshots.snapshotFor(fromRow.versionId), variables.snapshots.snapshotFor(toRow.versionId));
		result["from"] = versionSummary(fromRow);
		result["to"] = versionSummary(toRow);
		return result;
	}

	/**
	 * The review queue for placeholder source content (ADM-08): every item whose review status is
	 * the placeholder status, with where it came from in the source and what its status is, in
	 * instrument order. `query` narrows by item key, prompt, section, source location or notes.
	 * `total` is always the full count, so the number of unresolved placeholders is visible even
	 * while a search is applied.
	 */
	public struct function placeholders(required string versionId, string query = "") {
		var row = requireVersion(arguments.versionId);
		var q = boundedQuery(arguments.query);
		var snapshot = variables.snapshots.snapshotFor(row.versionId);
		var model = variables.snapshots.renderModelFor(row.versionId);
		var status = variables.compiler.placeholderReviewStatus();
		var sections = {};
		for (var s in snapshot.definitions.sections) sections[s.sectionKey] = s;
		var numbers = questionNumbers(model);
		var all = [];
		for (var it in snapshot.definitions.items) {
			if (!structKeyExists(it, "reviewStatus") || compare(it.reviewStatus, status) != 0) continue;
			var section = structKeyExists(it, "sectionKey") && structKeyExists(sections, it.sectionKey) ? sections[it.sectionKey] : {};
			arrayAppend(all, {
				"itemKey": it.itemKey,
				"prompt": it.prompt,
				"sectionKey": !structKeyExists(it, "sectionKey") ? javaCast("null", "") : it.sectionKey,
				"sectionTitle": structKeyExists(section, "title") ? section.title : javaCast("null", ""),
				"questionNumber": structKeyExists(numbers, it.itemKey) ? numbers[it.itemKey] : javaCast("null", ""),
				"sourceLocation": !structKeyExists(it, "sourceLocation") ? javaCast("null", "") : it.sourceLocation,
				"reviewStatus": it.reviewStatus,
				"revisionNotes": !structKeyExists(it, "revisionNotes") ? javaCast("null", "") : it.revisionNotes,
				"active": !structKeyExists(it, "active") ? true : it.active,
				"order": structKeyExists(numbers, "__order_" & it.itemKey) ? numbers["__order_" & it.itemKey] : 999999
			});
		}
		arraySort(all, function(a, b) {
			if (a.order != b.order) return a.order < b.order ? -1 : 1;
			return compare(a.itemKey, b.itemKey);
		});
		var matched = [];
		for (var p in all) {
			structDelete(p, "order");
			if (!len(q) || matchesAny(q, searchableText(p, ["itemKey", "prompt", "sectionKey", "sectionTitle", "sourceLocation", "reviewStatus", "revisionNotes"]))) arrayAppend(matched, p);
		}
		return {
			"version": versionSummary(row),
			"editable": row.status == "DRAFT",
			"reviewStatus": status,
			"query": q,
			"total": arrayLen(all),
			"matched": arrayLen(matched),
			"items": matched
		};
	}

	// ---- internals -------------------------------------------------------------------------------

	private struct function requireVersion(required string versionId) {
		if (!variables.db.isGuid(arguments.versionId)) variables.errors.validation("versionId must be a GUID.", "INVALID_VERSION_ID");
		var row = variables.repo.findVersionById(arguments.versionId);
		if (structIsEmpty(row)) variables.errors.notFound("Instrument version not found.", "INSTRUMENT_VERSION_NOT_FOUND");
		if (!structKeyExists(row, "snapshotJson") || !len(row.snapshotJson)) variables.errors.notFound("Instrument version has no compiled snapshot.", "INSTRUMENT_SNAPSHOT_MISSING");
		return row;
	}

	private struct function versionSummary(required struct row) {
		return {
			"versionId": arguments.row.versionId,
			"versionLabel": arguments.row.versionLabel,
			"instrumentCode": arguments.row.instrumentCode,
			"status": arguments.row.status,
			"checksum": !structKeyExists(arguments.row, "checksum") ? javaCast("null", "") : lCase(trim(arguments.row.checksum))
		};
	}

	/** Item key -> question number, plus "__order_<key>" -> position in render order. */
	private struct function questionNumbers(required struct model) {
		var out = {};
		var position = 0;
		var walk = function(node) {
			if (structKeyExists(node, "items") && isArray(node.items)) {
				for (var item in node.items) {
					position++;
					out["__order_" & item.itemKey] = position;
					if (structKeyExists(item, "questionNumber")) out[item.itemKey] = item.questionNumber;
				}
			}
			if (structKeyExists(node, "children") && isArray(node.children)) for (var child in node.children) walk(child);
		};
		walk(arguments.model.root);
		return out;
	}

	private void function allowOnly(required struct body, required array allowed, required string code) {
		for (var key in structKeyArray(arguments.body)) {
			if (!arrayFindNoCase(arguments.allowed, key)) {
				variables.errors.validation("'" & key & "' is not accepted here. Allowed: " & arrayToList(arguments.allowed, ", ") & ".", arguments.code);
			}
		}
	}

	private string function requiredText(required struct body, required string key, required numeric max, required string code) {
		if (!structKeyExists(arguments.body, arguments.key) || !variables.types.isJsonString(arguments.body[arguments.key]) || !len(trim(arguments.body[arguments.key]))) {
			variables.errors.validation(arguments.key & " is required.", arguments.code);
		}
		var text = trim(arguments.body[arguments.key]);
		if (len(text) > arguments.max) variables.errors.validation(arguments.key & " may be at most " & arguments.max & " characters.", arguments.code);
		return text;
	}

	private any function optionalText(required struct body, required string key, required numeric max, required string code) {
		if (!structKeyExists(arguments.body, arguments.key)) return javaCast("null", "");
		if (!variables.types.isJsonString(arguments.body[arguments.key])) variables.errors.validation(arguments.key & " must be a string.", arguments.code);
		var text = trim(arguments.body[arguments.key]);
		if (len(text) > arguments.max) variables.errors.validation(arguments.key & " may be at most " & arguments.max & " characters.", arguments.code);
		return len(text) ? text : javaCast("null", "");
	}

	private string function boundedQuery(any query) {
		if (!structKeyExists(arguments, "query") || !isSimpleValue(arguments.query)) return "";
		var q = trim(arguments.query);
		if (len(q) > variables.MAX_QUERY) variables.errors.validation("The search text may be at most " & variables.MAX_QUERY & " characters.", "QUERY_TOO_LONG");
		return q;
	}

	/** The named members' text, with absent (null) members skipped -- in CFML a null member does not exist. */
	private array function searchableText(required struct row, required array names) {
		var out = [];
		for (var name in arguments.names) {
			if (structKeyExists(arguments.row, name) && isSimpleValue(arguments.row[name])) arrayAppend(out, toString(arguments.row[name]));
		}
		return out;
	}

	private boolean function matchesAny(required string q, required array haystack) {
		for (var text in arguments.haystack) {
			if (structKeyExists(local, "text") && isSimpleValue(text) && findNoCase(arguments.q, text)) return true;
		}
		return false;
	}

	private array function editedFieldNames(required array applied) {
		var out = [];
		for (var a in arguments.applied) {
			var name = a.target & "." & a.field;
			if (!arrayContains(out, name)) arrayAppend(out, name);
		}
		return out;
	}
}
