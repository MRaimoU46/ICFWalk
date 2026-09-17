/**
 * Walk persistence and lifecycle (Phase 4): create, list, open, autosave, complete, void.
 *
 * Every entry point takes the request principal and re-authorizes through the centralized
 * AuthorizationService (route policy first, then authorizeWalk record checks); org unit, owner,
 * version, and status are always re-read from the database, never taken from the request.
 *
 * Save semantics (docs/DATA_CONTRACT.md "Concurrency and transactions"):
 *   1. The submitted state is validated against the walk's pinned instrument version
 *      (WalkPayloadValidator): unknown items/dimensions, foreign option or value codes, mistyped
 *      values are rejected (400) and audited as WALK_SAVE_REJECTED.
 *   2. Inside one transaction the walk row is locked, its row_version compared with the client's
 *      (409 STALE_ROW_VERSION, audited WALK_SAVE_CONFLICT, nothing written), the server engine
 *      re-normalizes the state (grade filter clearing, NOT_APPLICABLE clearing of skippable
 *      components, hidden-dimension policy), evaluates HIDDEN / NOT_APPLICABLE / ANSWERED /
 *      UNANSWERED states, and writes only the rows that changed. Notes are never cleared by the
 *      engine. The walk's updated_at/rowversion are bumped after the child writes.
 *   3. The client mutation id is recorded with the committed result (icf.walk_mutation); a retry
 *      with the same id replays that outcome (no duplicate rows, no second revision).
 *
 * Revisions (application policy): DRAFT autosaves append no revision; completion appends one
 * (reason COMPLETE, the pre-completion snapshot); an owner's edit of a COMPLETED walk appends one
 * (reason POST_COMPLETION_EDIT) and must leave the walk complete. Audit events: WALK_CREATED,
 * WALK_COMPLETED, WALK_COMPLETION_REJECTED, WALK_VOIDED, WALK_SAVE_CONFLICT, WALK_SAVE_REJECTED,
 * WALK_MUTATION_REPLAYED, WALK_POST_COMPLETION_EDIT, WALK_DELETE_REFUSED. Audit details carry
 * identifiers, counts, and codes only; never narrative values.
 */
component output="false" {

	variables.DEFAULT_VOID_REASON = "Deleted by owner from My Walks";

	public WalkService function init(
		required struct config, required any db, required any errors, required any logger, required any auditRepository,
		required any canonicalJson, required any authorizationService, required any snapshotService, required any visibilityEngine,
		required any walkRepository, required any payloadValidator
	) {
		variables.config = arguments.config;
		variables.db = arguments.db;
		variables.errors = arguments.errors;
		variables.logger = arguments.logger;
		variables.audit = arguments.auditRepository;
		variables.json = arguments.canonicalJson;
		variables.authz = arguments.authorizationService;
		variables.snapshots = arguments.snapshotService;
		variables.engine = arguments.visibilityEngine;
		variables.walks = arguments.walkRepository;
		variables.validator = arguments.payloadValidator;
		return this;
	}

	public struct function policies() {
		return { "hiddenDimensionPolicy": variables.config.hiddenPeriodPolicy };
	}

	// ---- list / open ---------------------------------------------------------------------------

	/** scope "mine" (default): own walks; "all": plus every walk readable in scope. */
	public array function list(required struct principal, string scope = "mine") {
		var readUnits = variables.authz.visibleOrgUnitIds(arguments.principal, "walk.read");
		var editUnits = variables.authz.visibleOrgUnitIds(arguments.principal, "walk.edit_owned");
		var rows = variables.walks.listWalks(arguments.principal.userId, readUnits, editUnits, arguments.scope == "all" ? "all" : "mine");
		var out = [];
		for (var w in rows) {
			var dto = headerDto(w, arguments.principal);
			dto["state"] = { "dimensions": w.dimensions, "responses": {} };
			arrayAppend(out, dto);
		}
		return out;
	}

	public struct function open(required struct principal, required string walkId) {
		var access = variables.authz.authorizeWalk(arguments.principal, arguments.walkId, "read");
		return loadDto(access.walkId, arguments.principal, false);
	}

	/** Render model of the walk's pinned version (WALK-11: historical walks render from their own snapshot). */
	public struct function instrumentFor(required struct principal, required string walkId) {
		var access = variables.authz.authorizeWalk(arguments.principal, arguments.walkId, "read");
		var row = variables.walks.findWalk(access.walkId);
		var model = variables.snapshots.renderModelFor(row.versionId);
		return {
			"version": { "versionId": row.versionId, "versionLabel": row.versionLabel },
			"policies": policies(),
			"model": model
		};
	}

	// ---- create --------------------------------------------------------------------------------

	/**
	 * body: { orgUnitId, clientMutationId?, versionId?, dimensions?, responses? }. The route policy
	 * already required walk.create for orgUnitId; the unit is re-resolved here. New walks pin the
	 * current instrument version; a client that renders another version is told to reload.
	 */
	public struct function create(required struct principal, required struct body) {
		var b = arguments.body;
		if (!structKeyExists(b, "orgUnitId") || !isSimpleValue(b.orgUnitId) || !len(trim(b.orgUnitId))) variables.errors.validation("orgUnitId is required.", "ORG_UNIT_REQUIRED");
		var orgUnitId = variables.authz.resolveScopedOrgUnit(arguments.principal, "walk.create", trim(b.orgUnitId));
		var mutationId = mutationIdOf(b, false);
		var current = variables.snapshots.currentVersion();
		if (structIsEmpty(current)) variables.errors.notFound("No instrument version is available for walks yet.", "INSTRUMENT_NOT_AVAILABLE");
		if (structKeyExists(b, "versionId") && isSimpleValue(b.versionId) && len(trim(b.versionId)) && uCase(trim(b.versionId)) != current.versionId) {
			variables.errors.conflict("The instrument version has changed; reload before starting a walk.", "INSTRUMENT_VERSION_CHANGED", { "currentVersionId": current.versionId });
		}
		if (len(mutationId)) {
			var recorded = variables.walks.findMutation(mutationId);
			if (!structIsEmpty(recorded)) return replay(recorded, arguments.principal, "CREATE", "");
		}
		var model = variables.snapshots.renderModelFor(current.versionId);
		var index = variables.walks.definitionIndex(current.versionId);
		var submitted = (structKeyExists(b, "dimensions") || structKeyExists(b, "responses")) ? b : variables.engine.blankState(model);
		var validated = validateOrAudit(model, index, submitted, arguments.principal, "");
		var normalized = variables.engine.normalize(model, validated.state, policies());
		var evaluation = variables.engine.evaluateVisibility(model, normalized.state);
		var me = arguments.principal.userId;
		var walks = variables.walks;
		var self = this;
		var walkId = "";
		try {
			walkId = variables.db.transact(function() {
				var id = walks.insertWalk(current.versionId, orgUnitId, me, observedAtOf(normalized.state));
				persistState(id, current.versionId, model, index, normalized.state, validated.resolved, evaluation, {}, {});
				walks.touchWalk(id, observedAtOf(normalized.state));
				var after = walks.findWalk(id);
				if (len(mutationId)) walks.insertMutation(mutationId, id, me, "CREATE", { "walkId": id, "rowVersion": after.rowVersion, "savedAt": variables.json.formatDate(after.updatedAt), "status": after.status, "changes": normalized.changes });
				variables.audit.record("WALK", id, "WALK_CREATED", me, { "orgUnitId": orgUnitId, "versionId": current.versionId, "clientMutationId": mutationId, "responseRows": structCount(evaluation.responseStates) });
				return id;
			});
		} catch (any e) {
			// A concurrent retry with the same mutation id won the insert: replay its outcome.
			if (len(mutationId)) {
				var recorded = variables.walks.findMutation(mutationId);
				if (!structIsEmpty(recorded)) return replay(recorded, arguments.principal, "CREATE", "");
			}
			rethrow;
		}
		variables.logger.info("walk.created", { "walkId": walkId, "orgUnitId": orgUnitId, "versionId": current.versionId });
		var dto = loadDto(walkId, arguments.principal, true);
		dto["changes"] = normalized.changes;
		dto["replayed"] = false;
		dto["clientMutationId"] = mutationId;
		return dto;
	}

	// ---- save (autosave) -----------------------------------------------------------------------

	/**
	 * body: { rowVersion (required), clientMutationId (required), walkId?, versionId?, dimensions, responses }.
	 */
	public struct function save(required struct principal, required string walkId, required struct body) {
		var access = variables.authz.authorizeWalk(arguments.principal, arguments.walkId, "edit");
		var b = arguments.body;
		var id = access.walkId;
		if (structKeyExists(b, "walkId") && isSimpleValue(b.walkId) && len(trim(b.walkId)) && uCase(trim(b.walkId)) != id) variables.errors.validation("walkId does not match the request path.", "WALK_ID_MISMATCH");
		if (structKeyExists(b, "versionId") && isSimpleValue(b.versionId) && len(trim(b.versionId)) && uCase(trim(b.versionId)) != access.versionId) {
			auditRejected(id, arguments.principal, "VERSION_MISMATCH", "versionId");
			variables.errors.validation("versionId does not match the walk's pinned instrument version.", "VERSION_MISMATCH");
		}
		var rowVersion = rowVersionOf(b, true);
		var mutationId = mutationIdOf(b, true);
		var model = variables.snapshots.renderModelFor(access.versionId);
		var index = variables.walks.definitionIndex(access.versionId);
		var validated = validateOrAudit(model, index, b, arguments.principal, id);
		var normalized = variables.engine.normalize(model, validated.state, policies());
		var evaluation = variables.engine.evaluateVisibility(model, normalized.state);
		var me = arguments.principal.userId;
		var walks = variables.walks;
		var errors = variables.errors;
		var audit = variables.audit;
		var json = variables.json;
		var self = this;
		var outcome = variables.db.transact(function() {
			var row = walks.findWalk(id, true);
			if (structIsEmpty(row)) errors.notFound();
			var recorded = walks.findMutation(mutationId);
			if (!structIsEmpty(recorded)) return { "replay": recorded };
			if (row.status == "VOIDED") errors.conflict("This walk has been voided and can no longer be edited.", "WALK_VOIDED", { "walkId": id });
			if (compare(row.rowVersion, rowVersion) != 0) {
				return { "conflict": { "walkId": id, "serverRowVersion": row.rowVersion, "serverUpdatedAt": json.formatDate(row.updatedAt) } };
			}
			var priorDims = walks.loadDimensionValues(id);
			var priorResponses = walks.loadResponses(id);
			var revisionNumber = 0;
			if (row.status == "COMPLETED") {
				var issues = completionIssues(model, evaluation);
				if (arrayLen(issues)) return { "incomplete": issues };
				revisionNumber = walks.insertRevision(id, me, "POST_COMPLETION_EDIT", snapshotJson(row, priorDims, priorResponses));
			}
			var written = persistState(id, row.versionId, model, index, normalized.state, validated.resolved, evaluation, priorDims, priorResponses);
			walks.touchWalk(id, observedAtOf(normalized.state));
			var after = walks.findWalk(id);
			var result = { "walkId": id, "rowVersion": after.rowVersion, "savedAt": json.formatDate(after.updatedAt), "status": after.status, "changes": normalized.changes, "written": written };
			walks.insertMutation(mutationId, id, me, "SAVE", result);
			if (revisionNumber > 0) audit.record("WALK", id, "WALK_POST_COMPLETION_EDIT", me, { "revisionNumber": revisionNumber, "clientMutationId": mutationId, "written": written });
			return { "result": result };
		});
		if (structKeyExists(outcome, "replay")) return replay(outcome.replay, arguments.principal, "SAVE", id);
		if (structKeyExists(outcome, "conflict")) {
			variables.audit.record("WALK", id, "WALK_SAVE_CONFLICT", me, { "clientMutationId": mutationId, "clientRowVersion": rowVersion, "serverRowVersion": outcome.conflict.serverRowVersion });
			variables.logger.warn("walk.save.conflict", { "walkId": id, "clientRowVersion": rowVersion, "serverRowVersion": outcome.conflict.serverRowVersion });
			variables.errors.conflict("This walk was changed elsewhere since you opened it. Reload the latest version to continue.", "STALE_ROW_VERSION", outcome.conflict);
		}
		if (structKeyExists(outcome, "incomplete")) {
			variables.audit.record("WALK", id, "WALK_COMPLETION_REJECTED", me, { "issueCount": arrayLen(outcome.incomplete), "during": "POST_COMPLETION_EDIT" });
			variables.errors.validation("A completed walk must keep every required response.", "WALK_COMPLETION_INVALID", { "errors": outcome.incomplete });
		}
		var dto = loadDto(id, arguments.principal, true);
		dto["changes"] = normalized.changes;
		dto["replayed"] = false;
		dto["clientMutationId"] = mutationId;
		dto["savedAt"] = outcome.result.savedAt;
		return dto;
	}

	// ---- complete ------------------------------------------------------------------------------

	public struct function complete(required struct principal, required string walkId, required struct body) {
		var access = variables.authz.authorizeWalk(arguments.principal, arguments.walkId, "edit");
		var id = access.walkId;
		var rowVersion = rowVersionOf(arguments.body, true);
		var mutationId = mutationIdOf(arguments.body, true);
		var model = variables.snapshots.renderModelFor(access.versionId);
		var me = arguments.principal.userId;
		var walks = variables.walks;
		var errors = variables.errors;
		var engine = variables.engine;
		var json = variables.json;
		var self = this;
		var outcome = variables.db.transact(function() {
			var row = walks.findWalk(id, true);
			if (structIsEmpty(row)) errors.notFound();
			var recorded = walks.findMutation(mutationId);
			if (!structIsEmpty(recorded)) return { "replay": recorded };
			if (row.status == "VOIDED") errors.conflict("This walk has been voided.", "WALK_VOIDED", { "walkId": id });
			if (row.status == "COMPLETED") errors.conflict("This walk is already completed.", "WALK_ALREADY_COMPLETED", { "walkId": id, "completedAt": json.formatDate(row.completedAt) });
			if (compare(row.rowVersion, rowVersion) != 0) return { "conflict": { "walkId": id, "serverRowVersion": row.rowVersion, "serverUpdatedAt": json.formatDate(row.updatedAt) } };
			var dims = walks.loadDimensionValues(id);
			var responses = walks.loadResponses(id);
			var state = stateOf(dims, responses);
			var evaluation = engine.evaluateVisibility(model, state);
			var issues = completionIssues(model, evaluation);
			if (arrayLen(issues)) return { "incomplete": issues };
			var revisionNumber = walks.insertRevision(id, me, "COMPLETE", snapshotJson(row, dims, responses));
			walks.markCompleted(id);
			var after = walks.findWalk(id);
			var result = { "walkId": id, "rowVersion": after.rowVersion, "savedAt": json.formatDate(after.updatedAt), "status": after.status, "completedAt": json.formatDate(after.completedAt), "revisionNumber": revisionNumber };
			walks.insertMutation(mutationId, id, me, "COMPLETE", result);
			variables.audit.record("WALK", id, "WALK_COMPLETED", me, { "revisionNumber": revisionNumber, "clientMutationId": mutationId, "answered": countState(evaluation, "ANSWERED"), "hidden": countState(evaluation, "HIDDEN"), "notApplicable": countState(evaluation, "NOT_APPLICABLE") });
			return { "result": result };
		});
		if (structKeyExists(outcome, "replay")) return replay(outcome.replay, arguments.principal, "COMPLETE", id);
		if (structKeyExists(outcome, "conflict")) {
			variables.audit.record("WALK", id, "WALK_SAVE_CONFLICT", me, { "clientMutationId": mutationId, "clientRowVersion": rowVersion, "serverRowVersion": outcome.conflict.serverRowVersion, "during": "COMPLETE" });
			variables.errors.conflict("This walk was changed elsewhere since you opened it. Reload the latest version to continue.", "STALE_ROW_VERSION", outcome.conflict);
		}
		if (structKeyExists(outcome, "incomplete")) {
			variables.audit.record("WALK", id, "WALK_COMPLETION_REJECTED", me, { "issueCount": arrayLen(outcome.incomplete), "clientMutationId": mutationId });
			variables.errors.validation("The walk cannot be completed until every required response is answered.", "WALK_INCOMPLETE", { "errors": outcome.incomplete });
		}
		variables.logger.info("walk.completed", { "walkId": id });
		var dto = loadDto(id, arguments.principal, true);
		dto["replayed"] = false;
		dto["clientMutationId"] = mutationId;
		return dto;
	}

	// ---- void / delete -------------------------------------------------------------------------

	/** body: { reason?, rowVersion?, clientMutationId? }. A COMPLETED walk requires a reason. */
	public struct function void(required struct principal, required string walkId, required struct body) {
		var access = variables.authz.authorizeWalk(arguments.principal, arguments.walkId, "void");
		var id = access.walkId;
		var b = arguments.body;
		var rowVersion = rowVersionOf(b, false);
		var mutationId = mutationIdOf(b, false);
		var reason = structKeyExists(b, "reason") && isSimpleValue(b.reason) ? trim(b.reason) : "";
		if (len(reason) > 1000) variables.errors.validation("Reason exceeds 1000 characters.", "VALUE_TOO_LONG");
		var me = arguments.principal.userId;
		var walks = variables.walks;
		var errors = variables.errors;
		var json = variables.json;
		var self = this;
		var outcome = variables.db.transact(function() {
			var row = walks.findWalk(id, true);
			if (structIsEmpty(row)) errors.notFound();
			if (len(mutationId)) {
				var recorded = walks.findMutation(mutationId);
				if (!structIsEmpty(recorded)) return { "replay": recorded };
			}
			if (row.status == "VOIDED") errors.conflict("This walk is already voided.", "WALK_ALREADY_VOIDED", { "walkId": id });
			if (len(rowVersion) && compare(row.rowVersion, rowVersion) != 0) return { "conflict": { "walkId": id, "serverRowVersion": row.rowVersion, "serverUpdatedAt": json.formatDate(row.updatedAt) } };
			if (row.status == "COMPLETED" && !len(reason)) errors.validation("A reason is required to void a completed walk.", "VOID_REASON_REQUIRED");
			var finalReason = len(reason) ? reason : variables.DEFAULT_VOID_REASON;
			walks.markVoided(id, finalReason);
			var after = walks.findWalk(id);
			var result = { "walkId": id, "rowVersion": after.rowVersion, "savedAt": json.formatDate(after.updatedAt), "status": after.status, "voidedAt": json.formatDate(after.voidedAt) };
			if (len(mutationId)) walks.insertMutation(mutationId, id, me, "VOID", result);
			variables.audit.record("WALK", id, "WALK_VOIDED", me, { "priorStatus": row.status, "reasonProvided": len(reason) > 0, "clientMutationId": mutationId });
			return { "result": result };
		});
		if (structKeyExists(outcome, "replay")) return replay(outcome.replay, arguments.principal, "VOID", id);
		if (structKeyExists(outcome, "conflict")) {
			variables.errors.conflict("This walk was changed elsewhere since you opened it. Reload the latest version to continue.", "STALE_ROW_VERSION", outcome.conflict);
		}
		variables.logger.info("walk.voided", { "walkId": id, "priorStatus": access.status });
		var dto = loadDto(id, arguments.principal, true);
		dto["replayed"] = false;
		dto["clientMutationId"] = mutationId;
		return dto;
	}

	/** WALK-08: physical deletion is never available; completed/audited history is retained. */
	public void function refuseDelete(required struct principal, required string walkId) {
		var access = variables.authz.authorizeWalk(arguments.principal, arguments.walkId, "void");
		variables.audit.record("WALK", access.walkId, "WALK_DELETE_REFUSED", arguments.principal.userId, { "status": access.status });
		variables.errors.conflict("Walks are never physically deleted. Void the walk with a reason instead (POST /api/walks/{id}/void).", "WALK_DELETE_REFUSED", { "walkId": access.walkId, "status": access.status });
	}

	// ---- completion validation -----------------------------------------------------------------

	/** Required, currently visible items and placements without an answer. */
	public array function completionIssues(required struct model, required struct evaluation, string cacheKey = "") {
		var idx = variables.validator.modelIndex(arguments.model, arguments.cacheKey);
		var issues = [];
		for (var code in idx.placementOrder) {
			var p = idx.placements[code];
			if (!p.required) continue;
			if (structKeyExists(arguments.evaluation.dimensionStates, code) && arguments.evaluation.dimensionStates[code] == "UNANSWERED") {
				arrayAppend(issues, { "kind": "DIMENSION", "key": code, "label": p.label, "message": p.label & " is required." });
			}
		}
		for (var key in idx.itemOrder) {
			var it = idx.items[key];
			if (!it.required) continue;
			if (structKeyExists(arguments.evaluation.responseStates, key) && arguments.evaluation.responseStates[key] == "UNANSWERED") {
				var number = isNull(it.questionNumber) ? "" : toString(it.questionNumber);
				arrayAppend(issues, { "kind": "ITEM", "key": key, "sectionKey": idx.sectionOfItem[key], "questionNumber": number, "message": "A response is required" & (len(number) ? " for question " & number : "") & "." });
			}
		}
		return issues;
	}

	// ---- internals ---------------------------------------------------------------------------

	private struct function validateOrAudit(required struct model, required struct index, required any payload, required struct principal, required string walkId) {
		try {
			return variables.validator.validate(arguments.model, arguments.index, arguments.payload);
		} catch (ICFWalk.Validation e) {
			var details = variables.errors.detailsOf(e);
			var paths = [];
			if (isStruct(details) && structKeyExists(details, "issues")) for (var i in details.issues) arrayAppend(paths, i.path);
			auditRejected(arguments.walkId, arguments.principal, e.errorcode, arrayToList(paths, " "));
			rethrow;
		}
	}

	private void function auditRejected(required string walkId, required struct principal, required string code, required string paths) {
		variables.logger.warn("walk.save.rejected", { "walkId": arguments.walkId, "code": arguments.code, "paths": arguments.paths });
		variables.audit.record("WALK", arguments.walkId, "WALK_SAVE_REJECTED", arguments.principal.userId, { "code": arguments.code, "paths": left(arguments.paths, 500) });
	}

	/**
	 * Writes the differences between the persisted rows and the normalized state. Returns counts.
	 * Dimension rows exist only for dimensions with a value; response rows exist for every
	 * response-capable item of the version (state UNANSWERED when empty) so states are countable.
	 */
	private struct function persistState(required string walkId, required string versionId, required struct model, required struct index, required struct state, required struct resolved, required struct evaluation, required struct priorDims, required struct priorResponses) {
		var idx = variables.validator.modelIndex(arguments.model, variables.validator.indexKey(arguments.index));
		var written = { "dimensions": 0, "responses": 0 };
		for (var code in idx.placementOrder) {
			var dimensionId = arguments.index.dimensions[code];
			var has = structKeyExists(arguments.state.dimensions, code) && !structIsEmpty(arguments.state.dimensions[code]);
			var prior = structKeyExists(arguments.priorDims, code) ? arguments.priorDims[code] : {};
			if (!has) {
				if (!structIsEmpty(prior)) { variables.walks.deleteDimensionValue(arguments.walkId, dimensionId); written.dimensions++; }
				continue;
			}
			var v = arguments.state.dimensions[code];
			if (compare(variables.json.serialize(v), variables.json.serialize(prior)) == 0) continue;
			var typed = {};
			if (structKeyExists(v, "selectedValueCode")) {
				typed["selectedValueId"] = structKeyExists(arguments.resolved.dimensions, code) && structKeyExists(arguments.resolved.dimensions[code], "valueId") ? arguments.resolved.dimensions[code].valueId : arguments.index.values[dimensionId][v.selectedValueCode];
				if (structKeyExists(v, "otherText")) typed["textValue"] = v.otherText;
			} else if (structKeyExists(v, "textValue")) {
				typed["textValue"] = v.textValue;
			} else if (structKeyExists(v, "dateValue")) {
				typed["dateValue"] = v.dateValue;
			} else if (structKeyExists(v, "numberValue")) {
				typed["numberValue"] = v.numberValue;
			} else if (structKeyExists(v, "booleanValue")) {
				typed["booleanValue"] = v.booleanValue;
			}
			variables.walks.upsertDimensionValue(arguments.walkId, arguments.versionId, dimensionId, typed, !structIsEmpty(prior));
			written.dimensions++;
		}
		for (var key in idx.itemOrder) {
			if (!structKeyExists(arguments.evaluation.responseStates, key)) continue; // display items
			var item = idx.items[key];
			var def = arguments.index.items[key];
			var st = arguments.evaluation.responseStates[key];
			var value = structKeyExists(arguments.state.responses, key) ? arguments.state.responses[key] : {};
			var optionId = "";
			var text = "";
			if (structKeyExists(value, "storedCode") && len(value.storedCode)) {
				optionId = structKeyExists(arguments.resolved.responses, key) && structKeyExists(arguments.resolved.responses[key], "optionId") ? arguments.resolved.responses[key].optionId : "";
				if (!len(optionId) && len(def.responseSetId) && structKeyExists(arguments.index.options, def.responseSetId) && structKeyExists(arguments.index.options[def.responseSetId], value.storedCode)) optionId = arguments.index.options[def.responseSetId][value.storedCode];
			}
			if (structKeyExists(value, "textValue")) text = value.textValue;
			var prior = structKeyExists(arguments.priorResponses, key) ? arguments.priorResponses[key] : {};
			var exists = !structIsEmpty(prior);
			var priorText = exists && structKeyExists(prior, "textValue") ? prior.textValue : "";
			if (exists && prior.state == st && compare(prior.optionId, optionId) == 0 && compare(priorText, text) == 0) continue;
			variables.walks.upsertResponse(arguments.walkId, arguments.versionId, def.itemId, st, optionId, text, exists);
			written.responses++;
		}
		return written;
	}

	/** Working state from persisted rows (responses carry only their values, states are derived). */
	private struct function stateOf(required struct dims, required struct responses) {
		var state = { "dimensions": duplicate(arguments.dims), "responses": {} };
		for (var key in structKeyArray(arguments.responses)) {
			var r = arguments.responses[key];
			var v = {};
			if (structKeyExists(r, "storedCode") && len(r.storedCode)) v["storedCode"] = r.storedCode;
			if (structKeyExists(r, "textValue") && len(r.textValue)) v["textValue"] = r.textValue;
			if (!structIsEmpty(v)) state.responses[key] = v;
		}
		return state;
	}

	private string function snapshotJson(required struct row, required struct dims, required struct responses) {
		var persisted = {};
		for (var key in structKeyArray(arguments.responses)) {
			var r = arguments.responses[key];
			var v = { "state": r.state };
			if (structKeyExists(r, "storedCode") && len(r.storedCode)) v["storedCode"] = r.storedCode;
			if (structKeyExists(r, "textValue") && len(r.textValue)) v["textValue"] = r.textValue;
			persisted[key] = v;
		}
		return variables.json.serialize({
			"walkId": arguments.row.walkId, "versionId": arguments.row.versionId, "status": arguments.row.status, "rowVersion": arguments.row.rowVersion,
			"updatedAt": variables.json.formatDate(arguments.row.updatedAt), "dimensions": arguments.dims, "responses": persisted
		});
	}

	private struct function replay(required struct recorded, required struct principal, required string action, required string walkId) {
		if (arguments.recorded.actorUserId != arguments.principal.userId || arguments.recorded.action != arguments.action || (len(arguments.walkId) && arguments.recorded.walkId != arguments.walkId)) {
			variables.audit.record("WALK", arguments.recorded.walkId, "WALK_MUTATION_ID_REUSED", arguments.principal.userId, { "clientMutationId": arguments.recorded.mutationId, "recordedAction": arguments.recorded.action });
			variables.errors.conflict("The client mutation id was already used for a different request.", "MUTATION_ID_REUSED", { "clientMutationId": arguments.recorded.mutationId });
		}
		variables.audit.record("WALK", arguments.recorded.walkId, "WALK_MUTATION_REPLAYED", arguments.principal.userId, { "clientMutationId": arguments.recorded.mutationId, "action": arguments.action });
		var dto = loadDto(arguments.recorded.walkId, arguments.principal, true);
		dto["replayed"] = true;
		dto["clientMutationId"] = arguments.recorded.mutationId;
		dto["mutation"] = arguments.recorded.result;
		if (structKeyExists(arguments.recorded.result, "changes")) dto["changes"] = arguments.recorded.result.changes;
		if (structKeyExists(arguments.recorded.result, "savedAt")) dto["savedAt"] = arguments.recorded.result.savedAt;
		return dto;
	}

	private struct function loadDto(required string walkId, required struct principal, required boolean skipAuthorization) {
		var row = variables.walks.findWalk(arguments.walkId);
		if (structIsEmpty(row)) variables.errors.notFound();
		var dims = variables.walks.loadDimensionValues(arguments.walkId);
		var responses = variables.walks.loadResponses(arguments.walkId);
		var model = variables.snapshots.renderModelFor(row.versionId);
		var state = stateOf(dims, responses);
		var evaluation = variables.engine.evaluateVisibility(model, state);
		var persistedStates = {};
		for (var key in structKeyArray(responses)) persistedStates[key] = responses[key].state;
		var dto = headerDto(row, arguments.principal);
		dto["state"] = state;
		dto["states"] = { "responseStates": evaluation.responseStates, "dimensionStates": evaluation.dimensionStates, "persistedResponseStates": persistedStates };
		dto["revisionCount"] = variables.walks.countRevisions(arguments.walkId);
		return dto;
	}

	private struct function headerDto(required struct row, required struct principal) {
		var isOwner = arguments.row.ownerUserId == arguments.principal.userId;
		var canEdit = isOwner && variables.authz.can(arguments.principal, "walk.edit_owned", arguments.row.orgUnitId) && arguments.row.status != "VOIDED";
		return {
			"id": arguments.row.walkId,
			"orgUnitId": arguments.row.orgUnitId,
			"orgUnitName": arguments.row.orgUnitName,
			"orgUnitCode": arguments.row.orgUnitCode,
			"versionId": arguments.row.versionId,
			"versionLabel": arguments.row.versionLabel,
			"status": arguments.row.status,
			"ownerUserId": arguments.row.ownerUserId,
			"ownerDisplayName": arguments.row.ownerDisplayName,
			"isOwner": isOwner,
			"canEdit": canEdit,
			"observedAt": variables.json.formatDate(arguments.row.observedAt),
			"createdAt": variables.json.formatDate(arguments.row.createdAt),
			"updatedAt": variables.json.formatDate(arguments.row.updatedAt),
			"completedAt": isDate(arguments.row.completedAt) ? variables.json.formatDate(arguments.row.completedAt) : javaCast("null", ""),
			"voidedAt": isDate(arguments.row.voidedAt) ? variables.json.formatDate(arguments.row.voidedAt) : javaCast("null", ""),
			"rowVersion": arguments.row.rowVersion
		};
	}

	private string function mutationIdOf(required struct body, required boolean required) {
		if (!structKeyExists(arguments.body, "clientMutationId") || isNull(arguments.body.clientMutationId) || !isSimpleValue(arguments.body.clientMutationId) || !len(trim(arguments.body.clientMutationId))) {
			if (arguments.required) variables.errors.validation("clientMutationId is required.", "CLIENT_MUTATION_ID_REQUIRED");
			return "";
		}
		if (!variables.db.isGuid(arguments.body.clientMutationId)) variables.errors.validation("clientMutationId must be a GUID.", "CLIENT_MUTATION_ID_INVALID");
		return uCase(trim(arguments.body.clientMutationId));
	}

	private string function rowVersionOf(required struct body, required boolean required) {
		if (!structKeyExists(arguments.body, "rowVersion") || isNull(arguments.body.rowVersion) || !isSimpleValue(arguments.body.rowVersion) || !len(trim(arguments.body.rowVersion))) {
			if (arguments.required) variables.errors.validation("rowVersion is required.", "ROW_VERSION_REQUIRED");
			return "";
		}
		if (!variables.walks.isRowVersion(arguments.body.rowVersion)) variables.errors.validation("rowVersion is not a valid row version token.", "ROW_VERSION_INVALID");
		return "0x" & uCase(mid(trim(arguments.body.rowVersion), 3, 16));
	}

	/** observed_at follows the first DATE dimension with a value (the visit date), else stays as is ("" = unchanged). */
	private any function observedAtOf(required struct state) {
		for (var code in structKeyArray(arguments.state.dimensions)) {
			var v = arguments.state.dimensions[code];
			if (isStruct(v) && structKeyExists(v, "dateValue") && reFind("^[0-9]{4}-[0-9]{2}-[0-9]{2}$", v.dateValue)) {
				return createDateTime(val(listGetAt(v.dateValue, 1, "-")), val(listGetAt(v.dateValue, 2, "-")), val(listGetAt(v.dateValue, 3, "-")), 0, 0, 0);
			}
		}
		return "";
	}

	private numeric function countState(required struct evaluation, required string state) {
		var n = 0;
		for (var key in structKeyArray(arguments.evaluation.responseStates)) if (arguments.evaluation.responseStates[key] == arguments.state) n++;
		return n;
	}
}
