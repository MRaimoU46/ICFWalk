/**
 * Walk persistence and lifecycle (Phase 4): create, list, open, autosave, complete, void.
 *
 * Every entry point takes the request principal and re-authorizes through the centralized
 * AuthorizationService (route policy first, then authorizeWalk record checks); org unit, owner,
 * version, and status are always re-read from the database, never taken from the request. A
 * mutation replay re-authorizes the recorded walk before anything about it is disclosed, so an
 * old mutation id can never return a walk the current principal may no longer read.
 *
 * Mutation envelope (docs/ENDPOINTS.md): create, save, complete, and void all require a
 * clientMutationId; save, complete, and void also require the walk's rowVersion (create has no
 * prior row to compare). A malformed or missing token is a 400 before any write. Each recorded
 * mutation is bound to its actor, action, target, and a SHA-256 fingerprint of its canonical
 * semantic request (migration 004); the same id with a different semantic request is refused with
 * 409 MUTATION_ID_REUSED rather than replayed.
 *
 * Save semantics (docs/DATA_CONTRACT.md "Concurrency and transactions"):
 *   1. The submitted state is validated against the walk's pinned instrument version
 *      (WalkPayloadValidator): a whole-state save must carry both root objects, unknown
 *      items/dimensions, foreign option or value codes, and mistyped values are rejected (400)
 *      and audited as WALK_SAVE_REJECTED.
 *   2. Inside one transaction the walk row is locked, its row_version compared with the client's
 *      (409 STALE_ROW_VERSION, audited WALK_SAVE_CONFLICT, nothing written), the persisted state
 *      is loaded, and the server merges it with the submission: values the pinned instrument
 *      currently hides are taken from the database, never from the browser, so an omitted hidden
 *      value is retained and a crafted client cannot change one. The engine then re-normalizes
 *      (grade filter clearing, NOT_APPLICABLE clearing of skippable components, hidden-dimension
 *      policy), evaluates HIDDEN / NOT_APPLICABLE / ANSWERED / UNANSWERED states, and writes only
 *      the rows that changed. Notes are never cleared by the engine. The walk's
 *      updated_at/rowversion are bumped after the child writes; a save that changes nothing on a
 *      COMPLETED walk writes nothing at all (no revision, no new row version).
 *   3. The client mutation id is recorded with the committed result (icf.walk_mutation); a retry
 *      with the same id replays that outcome (no duplicate rows, no second revision). The replay
 *      itself runs under the same walk mutation lock, so its coherence check and the aggregate it
 *      returns are one consistent snapshot (see replay).
 *   4. The response DTO is materialized inside that same transaction, under the same lock, and
 *      returned through the transaction outcome (see mutationDto). A successful SAVE or COMPLETE
 *      therefore answers with the exact serialized state its own mutation produced -- row version,
 *      header, dimensions, responses, evaluation states, and revision count all one snapshot --
 *      and never with a state some other session committed a moment later.
 *
 * A walk conducted at a SCHOOL org unit carries the School dimension value naming that unit: the
 * authorized active unit is authoritative and the server fills and locks the value (see
 * enforceSchoolScope).
 *
 * Revisions (application policy): DRAFT autosaves append no revision; completion appends one
 * (reason COMPLETE, the pre-completion snapshot); an owner's material edit of a COMPLETED walk
 * appends one (reason POST_COMPLETION_EDIT) and must leave the walk complete. Audit events:
 * WALK_CREATED, WALK_COMPLETED, WALK_COMPLETION_REJECTED, WALK_VOIDED, WALK_SAVE_CONFLICT,
 * WALK_SAVE_REJECTED, WALK_MUTATION_REPLAYED, WALK_MUTATION_ID_REUSED, WALK_MUTATION_SUPERSEDED,
 * WALK_MUTATION_LEGACY_UNVERIFIABLE, WALK_POST_COMPLETION_EDIT, WALK_SCHOOL_SCOPE_REJECTED,
 * WALK_SCHOOL_SCOPE_UNMAPPED, WALK_DELETE_REFUSED. Audit details carry identifiers, counts, and
 * codes only; never narrative values.
 */
component output="false" {

	variables.DEFAULT_VOID_REASON = "Deleted by owner from My Walks";

	public WalkService function init(
		required struct config, required any db, required any errors, required any logger, required any auditRepository,
		required any canonicalJson, required any authorizationService, required any snapshotService, required any visibilityEngine,
		required any walkRepository, required any payloadValidator, required any orgUnitRepository,
		required any summaryFormatter
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
		variables.orgUnits = arguments.orgUnitRepository;
		variables.summaries = arguments.summaryFormatter;
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
		return loadDto(access.walkId, arguments.principal);
	}

	/**
	 * Text summary export (Phase 5, SUM-01..05). Read-only: the same read authorization as open()
	 * (403 for a report-only or instrument-admin role, 404 outside the caller's organizational
	 * scope, 400 for a malformed id), the walk's own pinned instrument version (WALK-11), and the
	 * server engine's evaluation -- so a value the instrument currently hides is excluded from the
	 * text and the file name however it is retained in the database (docs/DATA_CONTRACT.md).
	 *
	 * A voided walk still exports: Phase 4 keeps it readable by id and the text carries no status.
	 *
	 * Nothing about the request chooses what is exported: no version id, org unit, item list, or
	 * file name is accepted from the caller. The audit event and the log line carry identifiers,
	 * the walk's status, and a byte count only -- never the summary text, a note, or any other
	 * narrative value (SEC-05).
	 *
	 * COHERENCE (Phase 5 correction). The export is materialized inside one transaction that takes
	 * the walk mutation lock first -- findWalk(id, true), the same WITH (UPDLOCK, ROWLOCK) row that
	 * SAVE, COMPLETE and VOID all take as their first act -- and holds it across the header,
	 * dimension and response reads, the visibility evaluation, the text, and the file name.
	 *
	 * Unlocked, the reads were three separate statements and a mutation could commit between any
	 * two of them. A save that changes a visibility-driving dimension and a response it governs
	 * commits both together; an export straddling that commit could pair the old dimensions with
	 * the new responses, and then print, under the old dimensions, a retained answer the new ones
	 * hide -- a file describing a state the database never held, violating SUM-01 and SUM-04. This
	 * is the same failure mutationDto() was corrected for, on the read side.
	 *
	 * Because every mutation path begins by taking that one row lock, serializing against it
	 * serializes against all of them: SAVE, COMPLETE and VOID each block on findWalk(id, true)
	 * while this transaction holds it, and this transaction blocks on it while any of them does.
	 * A concurrent SAVE therefore commits strictly before or strictly after an export, never
	 * inside one.
	 *
	 * The lock is released when the transaction returns. The log line and the audit event are
	 * written afterwards, from the already-coherent result: they are metadata only, nothing else
	 * reads them, and keeping them out of the transaction keeps the lock's duration to the reads
	 * that need it.
	 */
	public struct function summary(required struct principal, required string walkId) {
		var access = variables.authz.authorizeWalk(arguments.principal, arguments.walkId, "read");
		var id = access.walkId;
		var walks = variables.walks;
		var errors = variables.errors;
		var materialized = variables.db.transact(function() {
			var row = walks.findWalk(id, true);
			if (structIsEmpty(row)) errors.notFound();
			var dims = walks.loadDimensionValues(id);
			var responses = walks.loadResponses(id);
			var model = variables.snapshots.renderModelFor(row.versionId);
			var state = stateOf(dims, responses);
			var evaluation = variables.engine.evaluateVisibility(model, state);
			var text = variables.summaries.summaryText(model, state, evaluation);
			return {
				"text": text,
				"fileName": variables.summaries.fileName(model, state, evaluation, row.walkId),
				"status": row.status,
				"versionId": row.versionId,
				"bytes": arrayLen(charsetDecode(text, "utf-8"))
			};
		});
		variables.logger.info("walk.summary.exported", { "walkId": id, "versionId": materialized.versionId, "status": materialized.status, "bytes": materialized.bytes });
		variables.audit.record("WALK", id, "WALK_SUMMARY_EXPORTED", arguments.principal.userId, { "status": materialized.status, "versionId": materialized.versionId, "bytes": materialized.bytes });
		return materialized;
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
	 * body: { orgUnitId, clientMutationId, versionId?, dimensions?, responses? }. The route policy
	 * already required walk.create for orgUnitId; the unit is re-resolved here. New walks pin the
	 * current instrument version; a client that renders another version is told to reload.
	 *
	 * The recorded-mutation lookup precedes the current-version check on purpose: a create that
	 * committed against an earlier instrument version must still replay after a newer version is
	 * published, otherwise an ambiguous retry would strand the committed walk.
	 */
	public struct function create(required struct principal, required struct body) {
		var b = arguments.body;
		if (!structKeyExists(b, "orgUnitId") || !isSimpleValue(b.orgUnitId) || !len(trim(b.orgUnitId))) variables.errors.validation("orgUnitId is required.", "ORG_UNIT_REQUIRED");
		var orgUnitId = variables.authz.resolveScopedOrgUnit(arguments.principal, "walk.create", trim(b.orgUnitId));
		var mutationId = mutationIdOf(b, true);
		requireStateContainers(b, true);
		// The org unit is the create target; versionId is deliberately not part of the fingerprint.
		var fingerprint = fingerprintFor("CREATE", orgUnitId, semanticStateOf(b));
		var recorded = variables.walks.findMutation(mutationId);
		if (!structIsEmpty(recorded)) return replay(recorded, arguments.principal, "CREATE", "", fingerprint);
		var current = variables.snapshots.currentVersion();
		if (structIsEmpty(current)) variables.errors.notFound("No instrument version is available for walks yet.", "INSTRUMENT_NOT_AVAILABLE");
		if (structKeyExists(b, "versionId") && isSimpleValue(b.versionId) && len(trim(b.versionId)) && uCase(trim(b.versionId)) != current.versionId) {
			variables.errors.conflict("The instrument version has changed; reload before starting a walk.", "INSTRUMENT_VERSION_CHANGED", { "currentVersionId": current.versionId });
		}
		var model = variables.snapshots.renderModelFor(current.versionId);
		var index = variables.walks.definitionIndex(current.versionId);
		var submitted = (structKeyExists(b, "dimensions") || structKeyExists(b, "responses")) ? b : variables.engine.blankState(model);
		var validated = validateOrAudit(model, index, submitted, arguments.principal, "");
		var scoped = enforceSchoolScope(orgUnitId, model, validated.state, arguments.principal, "");
		var normalized = variables.engine.normalize(model, scoped, policies());
		var evaluation = variables.engine.evaluateVisibility(model, normalized.state);
		var me = arguments.principal.userId;
		var walks = variables.walks;
		var self = this;
		var walkId = "";
		try {
			walkId = variables.db.transact(function() {
				var id = walks.insertWalk(current.versionId, orgUnitId, me, observedAtOf(normalized.state));
				if (!len(id)) {
					// The version this walk was about to be pinned to was retired after it was chosen
					// (ADM-07). Nothing was inserted; the client reloads onto the current version.
					variables.errors.conflict("The instrument version has changed; reload before starting a walk.", "INSTRUMENT_VERSION_CHANGED", { "retiredVersionId": current.versionId });
				}
				var plan = planState(id, current.versionId, model, index, normalized.state, validated.resolved, evaluation, {}, {});
				applyPlan(plan.ops);
				walks.touchWalk(id, observedAtOf(normalized.state));
				var after = walks.findWalk(id);
				walks.insertMutation(mutationId, id, me, "CREATE", { "walkId": id, "rowVersion": after.rowVersion, "savedAt": variables.json.formatDate(after.updatedAt), "status": after.status, "changes": normalized.changes }, fingerprint);
				variables.audit.record("WALK", id, "WALK_CREATED", me, { "orgUnitId": orgUnitId, "versionId": current.versionId, "clientMutationId": mutationId, "responseRows": structCount(evaluation.responseStates) });
				return id;
			});
		} catch (any e) {
			// A concurrent retry with the same mutation id won the insert: replay its outcome.
			var raced = variables.walks.findMutation(mutationId);
			if (!structIsEmpty(raced)) return replay(raced, arguments.principal, "CREATE", "", fingerprint);
			rethrow;
		}
		variables.logger.info("walk.created", { "walkId": walkId, "orgUnitId": orgUnitId, "versionId": current.versionId });
		var dto = loadDto(walkId, arguments.principal);
		dto["changes"] = normalized.changes;
		dto["replayed"] = false;
		dto["clientMutationId"] = mutationId;
		return dto;
	}

	// ---- save (autosave) -----------------------------------------------------------------------

	/**
	 * body: { rowVersion (required), clientMutationId (required), walkId?, versionId?, dimensions, responses }.
	 *
	 * The whole submitted state is validated against the pinned version before the transaction, but
	 * it is merged with the persisted state inside it: the server owns visibility, retention, and
	 * clearing, so the browser never has to echo a hidden value back and can never change one.
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
		requireStateContainers(b, false);
		var fingerprint = fingerprintFor("SAVE", id, semanticStateOf(b));
		var model = variables.snapshots.renderModelFor(access.versionId);
		var index = variables.walks.definitionIndex(access.versionId);
		var validated = validateOrAudit(model, index, b, arguments.principal, id);
		// School/org consistency is enforced before the transaction opens, like validation: the
		// refusal writes nothing, and its audit event is not rolled back with the mutation.
		validated.state = enforceSchoolScope(access.orgUnitId, model, validated.state, arguments.principal, id);
		var me = arguments.principal.userId;
		var actingPrincipal = arguments.principal;
		var walks = variables.walks;
		var errors = variables.errors;
		var audit = variables.audit;
		var json = variables.json;
		var self = this;
		var savePolicies = policies();
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
			// Server-authoritative retention: currently hidden values come from the database.
			var merged = mergeRetainedHidden(model, validated.state, priorDims, priorResponses);
			// Where the server took a value from the database, the GUIDs the validator resolved for
			// the discarded submission must go with it, or the retained code would be written
			// against the submitted option's identifier.
			var resolved = { "dimensions": duplicate(validated.resolved.dimensions), "responses": duplicate(validated.resolved.responses) };
			for (var overriddenCode in merged.overridden.dimensions) structDelete(resolved.dimensions, overriddenCode);
			for (var overriddenKey in merged.overridden.responses) structDelete(resolved.responses, overriddenKey);
			var normalized = variables.engine.normalize(model, merged.state, savePolicies);
			var evaluation = variables.engine.evaluateVisibility(model, normalized.state);
			var observed = observedAtOf(normalized.state);
			var plan = planState(id, row.versionId, model, index, normalized.state, resolved, evaluation, priorDims, priorResponses);
			var material = arrayLen(plan.ops) > 0 || observedAtDiffers(row, observed);
			var revisionNumber = 0;
			if (row.status == "COMPLETED") {
				var issues = completionIssues(model, evaluation);
				if (arrayLen(issues)) return { "incomplete": issues };
				// An identical save to a COMPLETED walk is a no-op: no revision, no new row version.
				if (!material) {
					var unchanged = { "walkId": id, "rowVersion": row.rowVersion, "savedAt": json.formatDate(row.updatedAt), "status": row.status, "changes": normalized.changes, "written": plan.written, "noop": true };
					walks.insertMutation(mutationId, id, me, "SAVE", unchanged, fingerprint);
					// "Nothing changed" is a claim about one specific serialized state, so the DTO that
					// carries it is built here, under the lock, exactly like a material save's.
					return { "result": unchanged, "changes": normalized.changes, "dto": mutationDto(id, actingPrincipal, row, unchanged) };
				}
				revisionNumber = walks.insertRevision(id, me, "POST_COMPLETION_EDIT", snapshotJson(row, priorDims, priorResponses));
			}
			applyPlan(plan.ops);
			walks.touchWalk(id, observed);
			var after = walks.findWalk(id);
			var result = { "walkId": id, "rowVersion": after.rowVersion, "savedAt": json.formatDate(after.updatedAt), "status": after.status, "changes": normalized.changes, "written": plan.written, "retained": arrayLen(merged.retained) };
			walks.insertMutation(mutationId, id, me, "SAVE", result, fingerprint);
			if (revisionNumber > 0) audit.record("WALK", id, "WALK_POST_COMPLETION_EDIT", me, { "revisionNumber": revisionNumber, "clientMutationId": mutationId, "written": plan.written });
			return { "result": result, "changes": normalized.changes, "dto": mutationDto(id, actingPrincipal, after, result) };
		});
		if (structKeyExists(outcome, "replay")) return replay(outcome.replay, arguments.principal, "SAVE", id, fingerprint);
		if (structKeyExists(outcome, "conflict")) {
			variables.audit.record("WALK", id, "WALK_SAVE_CONFLICT", me, { "clientMutationId": mutationId, "clientRowVersion": rowVersion, "serverRowVersion": outcome.conflict.serverRowVersion });
			variables.logger.warn("walk.save.conflict", { "walkId": id, "clientRowVersion": rowVersion, "serverRowVersion": outcome.conflict.serverRowVersion });
			variables.errors.conflict("This walk was changed elsewhere since you opened it. Reload the latest version to continue.", "STALE_ROW_VERSION", outcome.conflict);
		}
		if (structKeyExists(outcome, "incomplete")) {
			variables.audit.record("WALK", id, "WALK_COMPLETION_REJECTED", me, { "issueCount": arrayLen(outcome.incomplete), "during": "POST_COMPLETION_EDIT" });
			variables.errors.validation("A completed walk must keep every required response.", "WALK_COMPLETION_INVALID", { "errors": outcome.incomplete });
		}
		var dto = outcome.dto;
		dto["changes"] = outcome.changes;
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
		var fingerprint = fingerprintFor("COMPLETE", id, {});
		var model = variables.snapshots.renderModelFor(access.versionId);
		var me = arguments.principal.userId;
		var actingPrincipal = arguments.principal;
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
			walks.insertMutation(mutationId, id, me, "COMPLETE", result, fingerprint);
			variables.audit.record("WALK", id, "WALK_COMPLETED", me, { "revisionNumber": revisionNumber, "clientMutationId": mutationId, "answered": countState(evaluation, "ANSWERED"), "hidden": countState(evaluation, "HIDDEN"), "notApplicable": countState(evaluation, "NOT_APPLICABLE") });
			return { "result": result, "dto": mutationDto(id, actingPrincipal, after, result) };
		});
		if (structKeyExists(outcome, "replay")) return replay(outcome.replay, arguments.principal, "COMPLETE", id, fingerprint);
		if (structKeyExists(outcome, "conflict")) {
			variables.audit.record("WALK", id, "WALK_SAVE_CONFLICT", me, { "clientMutationId": mutationId, "clientRowVersion": rowVersion, "serverRowVersion": outcome.conflict.serverRowVersion, "during": "COMPLETE" });
			variables.errors.conflict("This walk was changed elsewhere since you opened it. Reload the latest version to continue.", "STALE_ROW_VERSION", outcome.conflict);
		}
		if (structKeyExists(outcome, "incomplete")) {
			variables.audit.record("WALK", id, "WALK_COMPLETION_REJECTED", me, { "issueCount": arrayLen(outcome.incomplete), "clientMutationId": mutationId });
			variables.errors.validation("The walk cannot be completed until every required response is answered.", "WALK_INCOMPLETE", { "errors": outcome.incomplete });
		}
		variables.logger.info("walk.completed", { "walkId": id });
		var dto = outcome.dto;
		dto["replayed"] = false;
		dto["clientMutationId"] = mutationId;
		return dto;
	}

	// ---- void / delete -------------------------------------------------------------------------

	/**
	 * body: { rowVersion (required), clientMutationId (required), reason? }. A COMPLETED walk
	 * requires a reason. A stale rowVersion is a 409 that changes nothing.
	 */
	public struct function void(required struct principal, required string walkId, required struct body) {
		var access = variables.authz.authorizeWalk(arguments.principal, arguments.walkId, "void");
		var id = access.walkId;
		var b = arguments.body;
		var rowVersion = rowVersionOf(b, true);
		var mutationId = mutationIdOf(b, true);
		if (structKeyExists(b, "reason") && !isNull(b.reason) && !isJsonString(b.reason)) variables.errors.validation("reason must be a string.", "INVALID_VOID_REASON");
		var reason = structKeyExists(b, "reason") && !isNull(b.reason) && isSimpleValue(b.reason) ? trim(b.reason) : "";
		if (len(reason) > 1000) variables.errors.validation("Reason exceeds 1000 characters.", "VALUE_TOO_LONG");
		var fingerprint = fingerprintFor("VOID", id, { "reason": reason });
		var me = arguments.principal.userId;
		var walks = variables.walks;
		var errors = variables.errors;
		var json = variables.json;
		var self = this;
		var outcome = variables.db.transact(function() {
			var row = walks.findWalk(id, true);
			if (structIsEmpty(row)) errors.notFound();
			var recorded = walks.findMutation(mutationId);
			if (!structIsEmpty(recorded)) return { "replay": recorded };
			if (row.status == "VOIDED") errors.conflict("This walk is already voided.", "WALK_ALREADY_VOIDED", { "walkId": id });
			if (compare(row.rowVersion, rowVersion) != 0) return { "conflict": { "walkId": id, "serverRowVersion": row.rowVersion, "serverUpdatedAt": json.formatDate(row.updatedAt) } };
			if (row.status == "COMPLETED" && !len(reason)) errors.validation("A reason is required to void a completed walk.", "VOID_REASON_REQUIRED");
			var finalReason = len(reason) ? reason : variables.DEFAULT_VOID_REASON;
			walks.markVoided(id, finalReason);
			var after = walks.findWalk(id);
			var result = { "walkId": id, "rowVersion": after.rowVersion, "savedAt": json.formatDate(after.updatedAt), "status": after.status, "voidedAt": json.formatDate(after.voidedAt) };
			walks.insertMutation(mutationId, id, me, "VOID", result, fingerprint);
			variables.audit.record("WALK", id, "WALK_VOIDED", me, { "priorStatus": row.status, "reasonProvided": len(reason) > 0, "clientMutationId": mutationId });
			return { "result": result };
		});
		if (structKeyExists(outcome, "replay")) return replay(outcome.replay, arguments.principal, "VOID", id, fingerprint);
		if (structKeyExists(outcome, "conflict")) {
			variables.audit.record("WALK", id, "WALK_SAVE_CONFLICT", me, { "clientMutationId": mutationId, "clientRowVersion": rowVersion, "serverRowVersion": outcome.conflict.serverRowVersion, "during": "VOID" });
			variables.errors.conflict("This walk was changed elsewhere since you opened it. Reload the latest version to continue.", "STALE_ROW_VERSION", outcome.conflict);
		}
		variables.logger.info("walk.voided", { "walkId": id, "priorStatus": access.status });
		var dto = loadDto(id, arguments.principal);
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
	 * Plans the differences between the persisted rows and the normalized state without writing
	 * anything, so a caller can tell an identical (no-op) save from a material one before it
	 * decides to append a revision or bump the row version. Returns { ops[], written }.
	 *
	 * Dimension rows exist only for dimensions with a value; response rows exist for every
	 * response-capable item of the version (state UNANSWERED when empty) so states are countable.
	 */
	private struct function planState(required string walkId, required string versionId, required struct model, required struct index, required struct state, required struct resolved, required struct evaluation, required struct priorDims, required struct priorResponses) {
		var idx = variables.validator.modelIndex(arguments.model, variables.validator.indexKey(arguments.index));
		var ops = [];
		var written = { "dimensions": 0, "responses": 0 };
		for (var code in idx.placementOrder) {
			var dimensionId = arguments.index.dimensions[code];
			var has = structKeyExists(arguments.state.dimensions, code) && !structIsEmpty(arguments.state.dimensions[code]);
			var prior = structKeyExists(arguments.priorDims, code) ? arguments.priorDims[code] : {};
			if (!has) {
				if (!structIsEmpty(prior)) {
					arrayAppend(ops, { "kind": "DELETE_DIMENSION", "walkId": arguments.walkId, "dimensionId": dimensionId });
					written.dimensions++;
				}
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
			arrayAppend(ops, { "kind": "UPSERT_DIMENSION", "walkId": arguments.walkId, "versionId": arguments.versionId, "dimensionId": dimensionId, "value": typed, "exists": !structIsEmpty(prior) });
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
			arrayAppend(ops, { "kind": "UPSERT_RESPONSE", "walkId": arguments.walkId, "versionId": arguments.versionId, "itemId": def.itemId, "state": st, "optionId": optionId, "textValue": text, "exists": exists });
			written.responses++;
		}
		return { "ops": ops, "written": written };
	}

	/** Executes a plan from planState in order. */
	private void function applyPlan(required array ops) {
		for (var op in arguments.ops) {
			if (op.kind == "DELETE_DIMENSION") {
				variables.walks.deleteDimensionValue(op.walkId, op.dimensionId);
			} else if (op.kind == "UPSERT_DIMENSION") {
				variables.walks.upsertDimensionValue(op.walkId, op.versionId, op.dimensionId, op.value, op.exists);
			} else {
				variables.walks.upsertResponse(op.walkId, op.versionId, op.itemId, op.state, op.optionId, op.textValue, op.exists);
			}
		}
	}

	/**
	 * Server-authoritative retention (docs/DATA_CONTRACT.md "Visibility and clearing rules").
	 *
	 * Visibility is derived from the pinned instrument twice: once from the persisted state (what
	 * was hidden when the browser loaded the walk) and once from the submission (what is hidden
	 * now). A key is taken from the database, and the submission for it discarded, when either
	 *
	 *   - it is hidden under the submitted state: the browser has no business sending it, so an
	 *     omission is retained and a crafted value is ignored; or
	 *   - it was hidden in the persisted state and the submission omits it: the condition has just
	 *     returned and the retained value reappears without the browser echoing it back.
	 *
	 * Everything else stays whole-state: a visible key the browser omits is a cleared value, which
	 * is how CLEAR works, and a value the browser sends for a key that has become visible is a
	 * normal edit. NOT_APPLICABLE is deliberately not retained here; the engine clears those
	 * ratings so switching a skippable component back to Yes returns them as UNANSWERED.
	 *
	 * Returns { state, retained[], overridden } where retained names the keys whose submission was
	 * discarded because it differed from the persisted value (audit counts only, never values) and
	 * overridden names every key the server took from the database, so the caller drops the GUIDs
	 * the validator resolved for the discarded submission.
	 */
	private struct function mergeRetainedHidden(required struct model, required struct submitted, required struct priorDims, required struct priorResponses) {
		var st = { "dimensions": duplicate(arguments.submitted.dimensions), "responses": duplicate(arguments.submitted.responses) };
		var priorEv = variables.engine.evaluateVisibility(arguments.model, stateOf(arguments.priorDims, arguments.priorResponses));
		var ev = variables.engine.evaluateVisibility(arguments.model, st);
		var retained = [];
		var overridden = { "dimensions": [], "responses": [] };
		for (var code in structKeyArray(ev.dimensionStates)) {
			var submittedValue = structKeyExists(st.dimensions, code) ? st.dimensions[code] : {};
			var hiddenNow = ev.dimensionStates[code] == "HIDDEN";
			var wasHidden = structKeyExists(priorEv.dimensionStates, code) && priorEv.dimensionStates[code] == "HIDDEN";
			if (!hiddenNow && !(wasHidden && structIsEmpty(submittedValue))) continue;
			var priorValue = structKeyExists(arguments.priorDims, code) ? duplicate(arguments.priorDims[code]) : {};
			if (compare(variables.json.serialize(priorValue), variables.json.serialize(submittedValue)) != 0) arrayAppend(retained, "DIMENSION:" & code);
			if (structIsEmpty(priorValue)) structDelete(st.dimensions, code);
			else st.dimensions[code] = priorValue;
			arrayAppend(overridden.dimensions, code);
		}
		for (var key in structKeyArray(ev.responseStates)) {
			var priorRow = structKeyExists(arguments.priorResponses, key) ? arguments.priorResponses[key] : {};
			var submittedResponse = structKeyExists(st.responses, key) ? st.responses[key] : {};
			var hiddenNow = ev.responseStates[key] == "HIDDEN";
			var wasHidden = !structIsEmpty(priorRow) && priorRow.state == "HIDDEN";
			if (!hiddenNow && !(wasHidden && structIsEmpty(submittedResponse))) continue;
			var priorResponse = {};
			if (structKeyExists(priorRow, "storedCode") && len(priorRow.storedCode)) priorResponse["storedCode"] = priorRow.storedCode;
			if (structKeyExists(priorRow, "textValue") && len(priorRow.textValue)) priorResponse["textValue"] = priorRow.textValue;
			if (compare(variables.json.serialize(priorResponse), variables.json.serialize(submittedResponse)) != 0) arrayAppend(retained, "RESPONSE:" & key);
			if (structIsEmpty(priorResponse)) structDelete(st.responses, key);
			else st.responses[key] = priorResponse;
			arrayAppend(overridden.responses, key);
		}
		return { "state": st, "retained": retained, "overridden": overridden };
	}

	/**
	 * A walk conducted at a SCHOOL org unit must carry the School dimension value that its own
	 * mapping row names. The identity relationship is the explicit, stored, validated mapping in
	 * icf.org_unit_dimension_map (migration 005) -- never a comparison of an org_unit_code with a
	 * dimension value code, which is a coincidence of two independently owned namespaces:
	 *
	 *   - a mapped unit whose mapped value exists in the walk's PINNED instrument: the server fills
	 *     and locks that value and refuses any other School value, including the free-text "other"
	 *     (409 SCHOOL_ORG_MISMATCH). Because the mapping is unique on (dimension, value), the value
	 *     another school is mapped to is never available to this one;
	 *   - an unmapped unit, or one whose mapped value the pinned version does not define: the
	 *     School dimension fails closed. Nothing is filled (nothing trustworthy exists to fill) and
	 *     any submitted School value is refused with 409 SCHOOL_ORG_UNMAPPED, because the server
	 *     cannot establish that the value names this school and must not label the walk with a
	 *     school it cannot verify. Operators declare the mapping through the org-unit import
	 *     (schoolValueCode) or the alignment endpoint; nothing is ever inferred from a display name.
	 *
	 * A district-scoped user creating a walk at an authorized descendant SCHOOL unit is a normal
	 * create: authorization is the org unit's (AuthorizationService.resolveScopedOrgUnit), and the
	 * School dimension follows that unit's mapping.
	 *
	 * Walks at a DISTRICT unit are left alone. The governing specification (docs/PRODUCT_SPEC.md)
	 * defines no district-level walk semantics, so none are invented here.
	 */
	private struct function enforceSchoolScope(required string orgUnitId, required struct model, required struct state, required struct principal, required string walkId) {
		var code = variables.config.schoolDimensionCode;
		if (!len(code) || !structKeyExists(arguments.model.dimensions, code)) return arguments.state;
		var unit = variables.orgUnits.findById(arguments.orgUnitId);
		if (structIsEmpty(unit) || unit.type != "SCHOOL") return arguments.state;
		var st = arguments.state;
		var submitted = structKeyExists(st.dimensions, code) ? st.dimensions[code] : {};
		var selected = structKeyExists(submitted, "selectedValueCode") ? submitted.selectedValueCode : "";
		var expected = mappedSchoolValue(unit, arguments.model, code);
		if (!len(expected)) {
			// Fail closed: without a trustworthy mapping the server can neither fill the School
			// dimension nor accept a value, because it cannot establish that the value names this
			// school rather than another one.
			if (!structIsEmpty(submitted)) schoolScopeUnmapped(arguments.principal, arguments.walkId, unit, code, selected);
			structDelete(st.dimensions, code);
			return st;
		}
		if ((len(selected) && compare(selected, expected) != 0) || (!len(selected) && !structIsEmpty(submitted))) {
			schoolScopeRejected(arguments.principal, arguments.walkId, unit, expected, selected);
		}
		st.dimensions[code] = { "selectedValueCode": expected };
		return st;
	}

	/**
	 * The School dimension value this SCHOOL org unit is mapped to, validated against the walk's
	 * pinned instrument, or "" when the unit is unmapped or its mapped value is not defined by that
	 * version. Only the stored mapping is consulted; codes are never compared.
	 */
	private string function mappedSchoolValue(required struct unit, required struct model, required string dimensionCode) {
		var mapping = variables.orgUnits.findDimensionMapping(arguments.unit.id, arguments.dimensionCode);
		if (structIsEmpty(mapping) || !len(trim(mapping.valueCode))) return "";
		for (var v in arguments.model.dimensions[arguments.dimensionCode].values) {
			if (compare(v.valueCode, mapping.valueCode) == 0) return v.valueCode;
		}
		return "";
	}

	private void function schoolScopeRejected(required struct principal, required string walkId, required struct unit, required string expected, required string selected) {
		variables.logger.warn("walk.school.mismatch", { "walkId": arguments.walkId, "orgUnitId": arguments.unit.id, "expected": arguments.expected, "selected": arguments.selected });
		variables.audit.record("WALK", arguments.walkId, "WALK_SCHOOL_SCOPE_REJECTED", arguments.principal.userId, { "orgUnitId": arguments.unit.id, "expectedSchool": arguments.expected, "submittedSchool": left(arguments.selected, 100) });
		variables.errors.conflict(
			"The School selection must match the school this walk is authorized for.",
			"SCHOOL_ORG_MISMATCH",
			{ "orgUnitId": arguments.unit.id, "orgUnitCode": arguments.unit.code, "expectedSchoolValueCode": arguments.expected }
		);
	}

	/**
	 * A SCHOOL org unit with no validated School mapping. Nothing is written and no School value is
	 * accepted: an operator must declare the mapping (docs/DATA_CONTRACT.md, "School and
	 * organizational scope") before walks at this unit can carry a School value.
	 */
	private void function schoolScopeUnmapped(required struct principal, required string walkId, required struct unit, required string dimensionCode, required string selected) {
		variables.logger.warn("walk.school.unmapped", { "walkId": arguments.walkId, "orgUnitId": arguments.unit.id, "selected": arguments.selected });
		variables.audit.record("WALK", arguments.walkId, "WALK_SCHOOL_SCOPE_UNMAPPED", arguments.principal.userId, { "orgUnitId": arguments.unit.id, "dimensionCode": arguments.dimensionCode, "submittedSchool": left(arguments.selected, 100) });
		variables.errors.conflict(
			"This school is not mapped to a School value for this instrument version, so a School selection cannot be accepted. Ask an administrator to map it.",
			"SCHOOL_ORG_UNMAPPED",
			{ "orgUnitId": arguments.unit.id, "orgUnitCode": arguments.unit.code, "dimensionCode": arguments.dimensionCode }
		);
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

	/**
	 * Replays a committed mutation. The checks run in a fixed order, each one a precondition of the
	 * next, so nothing about the recorded walk is disclosed or returned before it has been earned:
	 *
	 *   1. Authorization. The recorded walk is re-authorized against the current principal and the
	 *      current authorization graph, so a mutation id recorded before access changed (or one
	 *      pointing at a walk the principal never had) answers 404 and discloses nothing -- before
	 *      any comparison whose outcome could differ per walk.
	 *   2. Actor, action, and target walk (when the route names one). A mismatch is the id being
	 *      reused for a different request: 409 MUTATION_ID_REUSED.
	 *   3. Provenance. A row written before migration 004 carries no fingerprint, so nothing about
	 *      it can prove that this request is the request it committed. It is never replayed as a
	 *      success: 409 MUTATION_LEGACY_UNVERIFIABLE (see legacyReplayRefused).
	 *   4. The SHA-256 fingerprint of the canonical semantic request: a different request under the
	 *      same id is 409 MUTATION_ID_REUSED.
	 *   5. Coherence (see supersededReplayRefused). The recorded outcome is only returned while the
	 *      aggregate still stands where that mutation left it. This comparison and the aggregate's
	 *      materialization are one atomic step under the walk mutation lock, so the DTO a replay
	 *      returns always carries the row version the recorded mutation committed -- never a newer
	 *      one a save slipped in between the two.
	 *
	 * Nothing here writes application state; the audit trail is the only side effect.
	 */
	private struct function replay(required struct recorded, required struct principal, required string action, required string walkId, required string fingerprint) {
		var recordAction = arguments.action == "VOID" ? "void" : (arguments.action == "CREATE" ? "read" : "edit");
		variables.authz.authorizeWalk(arguments.principal, arguments.recorded.walkId, recordAction);
		if (arguments.recorded.actorUserId != arguments.principal.userId
			|| arguments.recorded.action != arguments.action
			|| (len(arguments.walkId) && arguments.recorded.walkId != arguments.walkId)) {
			mutationIdReused(arguments.recorded, arguments.principal, arguments.action, false);
		}
		if (!len(arguments.recorded.fingerprint)) legacyReplayRefused(arguments.recorded, arguments.principal, arguments.action);
		if (compare(arguments.recorded.fingerprint, lCase(arguments.fingerprint)) != 0) {
			mutationIdReused(arguments.recorded, arguments.principal, arguments.action, true);
		}
		var recordedRowVersion = recordedRowVersionOf(arguments.recorded);
		var target = arguments.recorded.walkId;
		var actingPrincipal = arguments.principal;
		var walks = variables.walks;
		// Coherence and materialization are one atomic step. Comparing the recorded row version
		// against an unlocked read and then building the DTO from later unlocked reads left a
		// window in which a concurrent save could commit between the two, so a replay that had
		// just been judged coherent returned the NEWER aggregate and the newer row version to a
		// session still holding the state that went with the original mutation -- exactly the
		// stale-state-with-a-live-token pairing the comparison exists to prevent. Both now happen
		// inside one transaction that holds the walk mutation lock (findWalk(..., true)), which is
		// the same lock every normal mutation path takes before it writes, so no save, completion
		// or void can interleave between them.
		var outcome = variables.db.transact(function() {
			var locked = walks.findWalk(target, true);
			if (structIsEmpty(locked)) return { "missing": true };
			if (!len(recordedRowVersion) || compare(recordedRowVersion, locked.rowVersion) != 0) {
				return { "superseded": { "row": locked } };
			}
			var materialized = loadDto(target, actingPrincipal, locked);
			// The aggregate is read under the lock, so this re-read cannot have moved; asserting it
			// anyway makes the invariant the code's, not the lock's: the DTO that leaves here always
			// carries the row version the recorded mutation committed, or nothing leaves at all.
			var after = walks.findWalk(target, true);
			if (structIsEmpty(after)) return { "missing": true };
			if (compare(recordedRowVersion, after.rowVersion) != 0 || compare(recordedRowVersion, materialized.rowVersion) != 0) {
				return { "superseded": { "row": after } };
			}
			return { "dto": materialized };
		});
		if (structKeyExists(outcome, "missing")) variables.errors.notFound();
		if (structKeyExists(outcome, "superseded")) {
			supersededReplayRefused(arguments.recorded, arguments.principal, arguments.action, recordedRowVersion, outcome.superseded.row);
		}
		variables.audit.record("WALK", arguments.recorded.walkId, "WALK_MUTATION_REPLAYED", arguments.principal.userId, { "clientMutationId": arguments.recorded.mutationId, "action": arguments.action, "rowVersion": recordedRowVersion });
		var dto = outcome.dto;
		dto["replayed"] = true;
		dto["clientMutationId"] = arguments.recorded.mutationId;
		dto["mutation"] = arguments.recorded.result;
		if (structKeyExists(arguments.recorded.result, "changes")) dto["changes"] = arguments.recorded.result.changes;
		if (structKeyExists(arguments.recorded.result, "savedAt")) dto["savedAt"] = arguments.recorded.result.savedAt;
		return dto;
	}

	private void function mutationIdReused(required struct recorded, required struct principal, required string action, required boolean contentMismatch) {
		variables.audit.record("WALK", arguments.recorded.walkId, "WALK_MUTATION_ID_REUSED", arguments.principal.userId, { "clientMutationId": arguments.recorded.mutationId, "recordedAction": arguments.recorded.action, "requestedAction": arguments.action, "contentMismatch": arguments.contentMismatch });
		variables.errors.conflict("The client mutation id was already used for a different request.", "MUTATION_ID_REUSED", { "clientMutationId": arguments.recorded.mutationId });
	}

	/**
	 * The row version the recorded mutation committed, as it was stored in the mutation's own
	 * result. Every action records one; a row whose result carries none cannot be shown to be
	 * coherent with anything, so the caller refuses it rather than guessing.
	 */
	private string function recordedRowVersionOf(required struct recorded) {
		if (!isStruct(arguments.recorded.result) || !structKeyExists(arguments.recorded.result, "rowVersion")) return "";
		var stored = arguments.recorded.result.rowVersion;
		if (isNull(stored) || !isSimpleValue(stored) || !variables.walks.isRowVersion(stored)) return "";
		return "0x" & uCase(mid(trim(stored), 3, 16));
	}

	/**
	 * Replay coherence. A replay returns the recorded walk as it stands now, including its current
	 * row version, and the retrying client still holds the local state that went with the ORIGINAL
	 * mutation. If the aggregate has moved on since that mutation committed -- another session
	 * saved, completed, or voided the walk in between -- handing the old request a token minted for
	 * the newer state would pair stale client state with a live concurrency token, and the client's
	 * next save would overwrite the newer work without ever seeing a conflict.
	 *
	 * So the replay is refused instead: 409 MUTATION_REPLAY_SUPERSEDED tells the client its mutation
	 * did commit (nothing is retried, nothing is duplicated) and that the walk has since changed, so
	 * it must reload and reconcile like any other conflict. The details deliberately carry the
	 * RECORDED row version, never the current one: a stale token cannot be used to overwrite
	 * anything, and the current state is fetched by reading the walk.
	 *
	 * The caller reaches this only from inside the locked replay transaction's outcome, so "the
	 * aggregate has moved on" is decided against the same locked row the DTO would have been built
	 * from. There is no window between deciding and answering.
	 */
	private void function supersededReplayRefused(required struct recorded, required struct principal, required string action, required string recordedRowVersion, required struct row) {
		variables.logger.warn("walk.mutation.superseded", { "walkId": arguments.recorded.walkId, "action": arguments.action, "recordedRowVersion": arguments.recordedRowVersion });
		variables.audit.record("WALK", arguments.recorded.walkId, "WALK_MUTATION_SUPERSEDED", arguments.principal.userId, { "clientMutationId": arguments.recorded.mutationId, "action": arguments.action, "recordedRowVersion": arguments.recordedRowVersion });
		variables.errors.conflict(
			"This change was saved, but the walk has been changed again since. Reload the latest version to continue.",
			"MUTATION_REPLAY_SUPERSEDED",
			{ "walkId": arguments.recorded.walkId, "clientMutationId": arguments.recorded.mutationId, "recordedRowVersion": arguments.recordedRowVersion, "recordedAt": arguments.recorded.createdAt, "status": arguments.row.status }
		);
	}

	/**
	 * A mutation row written before migration 004 carries no request fingerprint, so there is no
	 * record of what request it committed. An identical-looking retry and a materially different
	 * request are indistinguishable against it, and replaying either as a success would assert
	 * something the data cannot support. The answer is a deterministic conflict that writes no
	 * application state, and it is reached only after the authorization and actor/action/target
	 * checks above, so it never discloses a walk the caller may not see.
	 */
	private void function legacyReplayRefused(required struct recorded, required struct principal, required string action) {
		variables.logger.warn("walk.mutation.legacy", { "walkId": arguments.recorded.walkId, "action": arguments.action });
		variables.audit.record("WALK", arguments.recorded.walkId, "WALK_MUTATION_LEGACY_UNVERIFIABLE", arguments.principal.userId, { "clientMutationId": arguments.recorded.mutationId, "action": arguments.action, "recordedAt": arguments.recorded.createdAt });
		variables.errors.conflict(
			"This client mutation id was recorded before the request fingerprint existed, so the server cannot confirm it is the same request. Reload the walk and retry with a new mutation id.",
			"MUTATION_LEGACY_UNVERIFIABLE",
			{ "walkId": arguments.recorded.walkId, "clientMutationId": arguments.recorded.mutationId, "recordedAt": arguments.recorded.createdAt }
		);
	}

	/**
	 * The response DTO for a successful, non-replay mutation, materialized inside that mutation's
	 * own transaction while the walk mutation lock (findWalk(..., true)) is still held.
	 *
	 * `row` is the walk header the mutation's recorded result was minted from -- read after the
	 * write, under that lock -- so the row version, header, dimensions, responses, evaluation
	 * states, and revision count the DTO carries all describe one serialized database state: the
	 * state this mutation produced.
	 *
	 * Materializing the response after the transaction had committed instead left a window with no
	 * lock in it. Session A's save could commit M1 and mint R1, session B could then save M2 against
	 * R1 and commit R2, and A's later read would answer with B's aggregate and R2 -- while A's
	 * browser still held the local state it sent as M1, because the client adopts the returned
	 * metadata without replacing its editor state. That pairs stale client state with a live
	 * concurrency token, and A's next whole-state save would overwrite B without ever being told
	 * STALE_ROW_VERSION. Under the lock no other SAVE, COMPLETE or VOID can commit between the
	 * mutation and its response, so the pairing cannot arise.
	 *
	 * The row version is re-asserted against the recorded result rather than assumed, so the
	 * invariant is the code's and not merely the lock's: the DTO that leaves here always carries
	 * the row version this mutation recorded, or the transaction rolls back and nothing leaves.
	 */
	private struct function mutationDto(required string walkId, required struct principal, required struct row, required struct result) {
		var dto = loadDto(arguments.walkId, arguments.principal, arguments.row);
		if (compare(dto.rowVersion, arguments.result.rowVersion) != 0) {
			throw(
				type = "ICFWalk.MutationIncoherent",
				message = "A mutation response was materialized against a different row version than the mutation recorded.",
				errorcode = "MUTATION_RESPONSE_INCOHERENT"
			);
		}
		return dto;
	}

	/**
	 * Loads the walk aggregate for a response. Callers authorize the record before calling this.
	 *
	 * `row` lets a caller that already holds the walk header -- because it read it under the walk
	 * mutation lock -- materialize the aggregate from that exact row instead of reading the header
	 * again, so the DTO's row version is the one the caller compared and not a later one.
	 */
	private struct function loadDto(required string walkId, required struct principal, struct row = {}) {
		var header = structIsEmpty(arguments.row) ? variables.walks.findWalk(arguments.walkId) : arguments.row;
		if (structIsEmpty(header)) variables.errors.notFound();
		var dims = variables.walks.loadDimensionValues(arguments.walkId);
		var responses = variables.walks.loadResponses(arguments.walkId);
		var model = variables.snapshots.renderModelFor(header.versionId);
		var state = stateOf(dims, responses);
		var evaluation = variables.engine.evaluateVisibility(model, state);
		var persistedStates = {};
		for (var key in structKeyArray(responses)) persistedStates[key] = responses[key].state;
		var dto = headerDto(header, arguments.principal);
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
			// Dimensions the server owns for this walk: the browser renders them read-only instead of
			// offering a choice it would refuse (docs/DATA_CONTRACT.md, "School and organizational
			// scope"). A walk at a SCHOOL unit carries that unit's mapped School value or, when the
			// unit is unmapped, none at all -- either way the value is not the client's to set.
			"lockedDimensions": lockedDimensionsFor(arguments.row),
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

	/** The dimension codes the server owns for a walk, in the order the contract documents them. */
	private array function lockedDimensionsFor(required struct row) {
		var code = variables.config.schoolDimensionCode;
		if (!len(code)) return [];
		if (!structKeyExists(arguments.row, "orgUnitType") || arguments.row.orgUnitType != "SCHOOL") return [];
		return [code];
	}

	private string function mutationIdOf(required struct body, required boolean required) {
		var present = structKeyExists(arguments.body, "clientMutationId") && !isNull(arguments.body.clientMutationId);
		if (!present || (isJsonString(arguments.body.clientMutationId) && !len(trim(arguments.body.clientMutationId)))) {
			if (arguments.required) variables.errors.validation("clientMutationId is required.", "CLIENT_MUTATION_ID_REQUIRED");
			return "";
		}
		if (!isJsonString(arguments.body.clientMutationId) || !variables.db.isGuid(arguments.body.clientMutationId)) variables.errors.validation("clientMutationId must be a GUID string.", "CLIENT_MUTATION_ID_INVALID");
		return uCase(trim(arguments.body.clientMutationId));
	}

	private string function rowVersionOf(required struct body, required boolean required) {
		var present = structKeyExists(arguments.body, "rowVersion") && !isNull(arguments.body.rowVersion);
		if (!present || (isJsonString(arguments.body.rowVersion) && !len(trim(arguments.body.rowVersion)))) {
			if (arguments.required) variables.errors.validation("rowVersion is required.", "ROW_VERSION_REQUIRED");
			return "";
		}
		if (!isJsonString(arguments.body.rowVersion) || !variables.walks.isRowVersion(arguments.body.rowVersion)) variables.errors.validation("rowVersion is not a valid row version token.", "ROW_VERSION_INVALID");
		return "0x" & uCase(mid(trim(arguments.body.rowVersion), 3, 16));
	}

	/**
	 * observed_at follows the Visit Date dimension: the first DATE-typed dimension carrying a value.
	 * When no Visit Date is present -- never entered, or entered and then cleared -- the empty string
	 * is returned and the repository falls observed_at back to the walk's immutable creation
	 * instant, so a cleared date never leaves a stale observation timestamp behind.
	 */
	private any function observedAtOf(required struct state) {
		for (var code in structKeyArray(arguments.state.dimensions)) {
			var v = arguments.state.dimensions[code];
			if (isStruct(v) && structKeyExists(v, "dateValue") && reFind("^[0-9]{4}-[0-9]{2}-[0-9]{2}$", v.dateValue)) {
				return createDateTime(val(listGetAt(v.dateValue, 1, "-")), val(listGetAt(v.dateValue, 2, "-")), val(listGetAt(v.dateValue, 3, "-")), 0, 0, 0);
			}
		}
		return "";
	}

	/** True when saving this state would move observed_at away from what the row already stores. */
	private boolean function observedAtDiffers(required struct row, required any observed) {
		var target = (isSimpleValue(arguments.observed) && !len(arguments.observed)) ? arguments.row.createdAt : arguments.observed;
		if (!isDate(arguments.row.observedAt) || !isDate(target)) return true;
		return compare(variables.json.formatDate(arguments.row.observedAt), variables.json.formatDate(target)) != 0;
	}

	/**
	 * SHA-256 over the canonical JSON of a mutation's semantic request: its action, its target, and
	 * the body fields that decide what the mutation means. The concurrency token, the mutation id,
	 * the client clock, and (for a create) the requested instrument version are deliberately left
	 * out: they are not what the request means, and a create retried after a newer version is
	 * published must still match the fingerprint it committed.
	 */
	private string function fingerprintFor(required string action, required string targetKey, required struct semantic) {
		var doc = { "contract": "icfwalk-mutation-fingerprint/1", "action": arguments.action, "target": uCase(arguments.targetKey) };
		for (var k in structKeyArray(arguments.semantic)) doc[k] = arguments.semantic[k];
		return variables.json.sha256(variables.json.serialize(doc));
	}

	/** The whole-state portion of a request body, exactly as submitted (absent keys stay absent). */
	private struct function semanticStateOf(required struct body) {
		var out = {};
		if (structKeyExists(arguments.body, "dimensions") && !isNull(arguments.body.dimensions)) out["dimensions"] = arguments.body.dimensions;
		if (structKeyExists(arguments.body, "responses") && !isNull(arguments.body.responses)) out["responses"] = arguments.body.responses;
		return out;
	}

	/**
	 * A whole-state save must carry both root containers as JSON objects: an absent container is a
	 * truncated payload, not an instruction to leave that half of the walk alone. A create may omit
	 * both (the server starts from the engine's blank state) but never just one.
	 */
	private void function requireStateContainers(required struct body, required boolean allowAbsent) {
		var hasDimensions = structKeyExists(arguments.body, "dimensions") && !isNull(arguments.body.dimensions);
		var hasResponses = structKeyExists(arguments.body, "responses") && !isNull(arguments.body.responses);
		if (arguments.allowAbsent && !hasDimensions && !hasResponses) return;
		if (!hasDimensions) variables.errors.validation("dimensions is required and must be a JSON object.", "STATE_CONTAINER_REQUIRED", { "path": "dimensions" });
		if (!hasResponses) variables.errors.validation("responses is required and must be a JSON object.", "STATE_CONTAINER_REQUIRED", { "path": "responses" });
		if (!isStruct(arguments.body.dimensions)) variables.errors.validation("dimensions must be a JSON object keyed by dimension code.", "STATE_CONTAINER_INVALID", { "path": "dimensions" });
		if (!isStruct(arguments.body.responses)) variables.errors.validation("responses must be a JSON object keyed by item key.", "STATE_CONTAINER_INVALID", { "path": "responses" });
	}

	/** True only for a JSON string; a JSON number or boolean is not silently coerced to text. */
	private boolean function isJsonString(required any value) {
		return isSimpleValue(arguments.value) && isInstanceOf(arguments.value, "java.lang.String");
	}

	private numeric function countState(required struct evaluation, required string state) {
		var n = 0;
		for (var key in structKeyArray(arguments.evaluation.responseStates)) if (arguments.evaluation.responseStates[key] == arguments.state) n++;
		return n;
	}
}
