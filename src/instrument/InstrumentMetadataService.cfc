/**
 * The one operation that changes shared instrument metadata: the name, the description, and
 * whether the instrument is in service at all.
 *
 * WHY THIS EXISTS. icf.instrument is shared by every version of the instrument, and one of its
 * columns -- active -- is part of the predicate SnapshotService.currentVersion() selects with. So
 * writing that row is not an edit to a draft, it is an operational decision about a live system:
 * setting active = false takes an already PUBLISHED version out of service for every walker.
 *
 * The importer used to do it, unconditionally, from whatever the document said, on every
 * re-import. That made "import a V2 draft" a way to remove a published V1 from the runtime with
 * no audit naming who did it and no version row changing to show it had happened. Import no longer
 * touches the row (InstrumentImportService refuses a document that disagrees with it instead), and
 * this is where the change is made deliberately.
 *
 * WHO MAY DO IT. The caller passes the CURRENT PRINCIPAL, and this asks the central
 * AuthorizationService for global `instrument.manage` before any database mutation. It used to
 * take an actor id and rely on DefinitionRepository.userExists(), which is an integrity check --
 * every row in icf.app_user satisfies it -- and was being read as a permission check, so any
 * existing user could be supplied as the alleged authorizer by any internal caller. There is now
 * no actor argument at all: the audit actor is the authorized principal's userId and cannot be
 * named, substituted or overridden from the call site. The absence of an HTTP route is not part of
 * the security model and never was; it is a scope decision, stated below.
 *
 * THE ROW IS LOCKED BEFORE IT IS READ. The operation derives a COMPLETE replacement row -- a patch
 * that changes one field keeps the stored value of every field it omits -- so where those omitted
 * values come from is the whole correctness question. They used to come from an ordinary unlocked
 * findInstrumentByCode(), with the row lock taken later, inside the update. Two concurrent partial
 * patches therefore both restated what they had read before the other ran:
 *
 *     both read { name: N0, active: true }
 *     A sets active = false and commits
 *     B, which changes only the name, wakes from the lock and writes { name: N1, active: true }
 *     the deliberate deactivation is gone, and A's audit records a `before` image
 *     that was never the row A actually replaced
 *
 * Now the locked read, the merge, the update and the audit are one transaction: the row is taken
 * under UPDLOCK/HOLDLOCK and read in the same statement, `before` and `after` are built from that
 * locked row, the update runs while the lock is still held, and the success audit is written
 * before the commit. A request that queues behind another sees what that other one committed.
 *
 * THE REST OF THE CONTRACT.
 *   - `changes` is validated strictly before anything is written: only name, description and
 *     active; unknown members refused rather than ignored; name a non-blank JSON string inside
 *     icf.instrument.name; description a JSON string inside icf.instrument.description, or absent;
 *     active an ACTUAL boolean, never a coerced string or number; at least one supported member.
 *   - A patch that produces no material difference is a NO-OP (docs/OPEN_DECISIONS.md): the row is
 *     not written, no audit event is recorded, updated_at and row_version do not move, and the
 *     result says `noOp`. An administrative action that changed nothing is not a change.
 *   - It writes exactly one INSTRUMENT_METADATA_UPDATED audit event on a real change, carrying the
 *     before and after of the lifecycle facts it changed. Narrative content is never copied into
 *     an audit event: the description is reported as `descriptionChanged`, never as its text.
 *   - A refusal writes nothing and changes nothing: every check runs before the update, inside the
 *     transaction, so a rollback leaves the row exactly as it was.
 *   - A missing instrument is refused without writing or auditing success.
 *   - It never touches a version. Publishing, importing and discarding are unaffected by it, and
 *     it cannot make a frozen version's definitions say anything different.
 *
 * LOCK ORDER. This takes icf.instrument and requests no version lock, so it cannot invert the
 * version-then-instrument order import and publish take and cannot deadlock with either. The
 * guarantee is the database transaction and its row locks, never an application-process lock: the
 * production deployment can run more than one process or node, where a process lock proves nothing.
 *
 * NO ROUTE. This correction closes the write boundary; it does not add the administration UI for
 * the operation. Nothing in src/http or src/controllers reaches this component, deliberately -- and
 * that is a statement about scope, not about security. The authorization check above is the control.
 */
component output="false" {

	// Exactly what a patch may name. Anything else is refused rather than ignored, so a caller that
	// believes it can change something else is told, instead of being quietly misled.
	variables.SUPPORTED = ["name", "description", "active"];
	variables.MAX_NAME = 200;          // icf.instrument.name        nvarchar(200)
	variables.MAX_DESCRIPTION = 1000;  // icf.instrument.description nvarchar(1000)

	public InstrumentMetadataService function init(
		required any db, required any errors, required any logger,
		required any definitionRepository, required any auditRepository, required any authorizationService
	) {
		variables.db = arguments.db;
		variables.errors = arguments.errors;
		variables.logger = arguments.logger;
		variables.repo = arguments.definitionRepository;
		variables.audit = arguments.auditRepository;
		variables.authorization = arguments.authorizationService;
		variables.types = new icfwalk.core.JsonTypes();
		return this;
	}

	/**
	 * Changes the shared row for one instrument, on behalf of the signed-in principal.
	 *
	 * `changes` may carry name, description and active; anything it omits keeps the value the
	 * LOCKED row holds, so a caller changing one fact does not have to restate the others and
	 * cannot blank them by accident -- or lose somebody else's change by restating a stale one.
	 *
	 * @principal the current principal, as AuthorizationService.principalFor builds it. There is no
	 *            actor argument: the audit actor is this principal's userId.
	 */
	public struct function updateMetadata(required string instrumentCode, required struct changes, required any principal) {
		var actor = requireManagePermission(arguments.principal);
		var patch = validatePatch(arguments.changes);
		var code = trim(arguments.instrumentCode);
		var repo = variables.repo;
		var errors = variables.errors;
		var audit = variables.audit;
		var self = this;

		var outcome = variables.db.transact(function() {
			// THE LOCKED READ. Everything below is derived from this row, and the lock is held
			// until this transaction ends, so what is read here is what is replaced.
			var instrument = repo.lockInstrumentByCode(code);
			if (structIsEmpty(instrument)) {
				errors.notFound("No instrument with code '" & code & "' exists.", "INSTRUMENT_NOT_FOUND");
			}

			var before = {
				"name": self.textOf(instrument.name),
				"description": self.textOf(isNull(instrument.description) ? javaCast("null", "") : instrument.description),
				"active": instrument.active ? true : false
			};
			var after = {
				"name": structKeyExists(patch, "name") ? patch.name : before.name,
				"description": structKeyExists(patch, "description") ? patch.description : before.description,
				"active": structKeyExists(patch, "active") ? patch.active : before.active
			};

			var changed = [];
			for (var field in variables.SUPPORTED) {
				if (toString(before[field]) != toString(after[field])) arrayAppend(changed, field);
			}

			// A patch that produces no material difference is a no-op: no write, no audit, no row
			// version movement. The read above already told us so, under the lock, so this is a
			// decision about the committed row and not a guess.
			if (!arrayLen(changed)) {
				return self.result(instrument.instrumentId, code, after, changed, actor, true);
			}

			var written = repo.updateInstrumentMetadata(
				instrument.instrumentId, after.name,
				len(after.description) ? after.description : javaCast("null", ""),
				after.active, actor
			);
			if (written != 1) {
				// Unreachable while the row lock above is held; asserted rather than assumed,
				// because a silent no-op would leave an audit claiming a change that did not happen.
				throw(type = "ICFWalk.Validation", message = "Instrument metadata was not updated; the transaction was rolled back.", errorcode = "INSTRUMENT_METADATA_NOT_UPDATED");
			}

			// Written in the same transaction as the update it describes, from the same locked row,
			// so the `before` image is the row that was really replaced and the `after` image is
			// what was really committed. Lifecycle facts only: the description is reported as
			// changed, never as its text.
			audit.record("INSTRUMENT", instrument.instrumentId, "INSTRUMENT_METADATA_UPDATED", actor, {
				"instrumentCode": code,
				"changedFields": changed,
				"previousName": before.name,
				"name": after.name,
				"previousActive": before.active,
				"active": after.active,
				"descriptionChanged": arrayContains(changed, "description")
			});

			return self.result(instrument.instrumentId, code, after, changed, actor, false);
		});

		variables.logger.info(outcome.noOp ? "instrument.metadata.unchanged" : "instrument.metadata.updated", {
			"instrumentCode": code, "changedFields": outcome.changedFields, "active": outcome.active
		});
		return outcome;
	}

	// ---- authorization ---------------------------------------------------------------------------

	/**
	 * The central authorization model, and nothing else. `instrument.manage` is global in
	 * AuthorizationService, so no org unit is named; a principal without it is denied (and the
	 * denial is audited there) before this service touches the database.
	 *
	 * Returns the actor for the write and the audit: the principal's own userId, which is the only
	 * actor this operation ever records.
	 */
	private string function requireManagePermission(required any principal) {
		if (isNull(arguments.principal) || !isStruct(arguments.principal)
			|| !structKeyExists(arguments.principal, "userId") || !structKeyExists(arguments.principal, "permissions")) {
			variables.errors.validation(
				"Changing shared instrument metadata requires the current principal, not a caller-supplied actor id.",
				"INSTRUMENT_METADATA_PRINCIPAL_REQUIRED"
			);
		}
		var actor = uCase(trim(toString(arguments.principal.userId)));
		if (!variables.db.isGuid(actor)) {
			variables.errors.validation("The principal does not carry a valid user id.", "INSTRUMENT_METADATA_PRINCIPAL_REQUIRED");
		}
		variables.authorization.requirePermission(arguments.principal, "instrument.manage", "", "INSTRUMENT", "");
		return actor;
	}

	// ---- the patch -------------------------------------------------------------------------------

	/**
	 * Validates `changes` completely, before anything is read or written, and returns the coerced
	 * values the merge will use. Every refusal here happens before the transaction opens, so a
	 * refused patch cannot have taken a lock, let alone written a row.
	 *
	 * The type rules are deliberately strict. CFML's isBoolean() says yes to "144", to "no" and to
	 * 0, so a "coerce anything unrecognised to false" helper turns a malformed request into a
	 * silent deactivation -- which removes a published version from the runtime for every walker.
	 * core/JsonTypes answers the type question from the value's Java class instead.
	 */
	private struct function validatePatch(required struct changes) {
		for (var key in structKeyArray(arguments.changes)) {
			if (!arrayContains(variables.SUPPORTED, key)) {
				variables.errors.validation(
					"'" & key & "' is not a shared instrument metadata field. Only " & arrayToList(variables.SUPPORTED, ", ") & " may be changed.",
					"INSTRUMENT_METADATA_UNKNOWN_FIELD"
				);
			}
		}

		var patch = {};
		if (structKeyExists(arguments.changes, "name")) {
			var name = arguments.changes.name;
			if (!variables.types.isJsonString(name)) {
				variables.errors.validation("An instrument name must be a string; this patch supplies " & variables.types.describe(name) & ".", "INSTRUMENT_METADATA_INVALID");
			}
			var trimmedName = trim(name);
			if (!len(trimmedName)) {
				variables.errors.validation("An instrument must have a name.", "INSTRUMENT_METADATA_INVALID");
			}
			if (len(trimmedName) > variables.MAX_NAME) {
				variables.errors.validation("An instrument name may be at most " & variables.MAX_NAME & " characters.", "INSTRUMENT_METADATA_INVALID");
			}
			patch["name"] = trimmedName;
		}

		if (structKeyExists(arguments.changes, "description")) {
			var description = isNull(arguments.changes.description) ? "" : arguments.changes.description;
			if (!isNull(arguments.changes.description) && !variables.types.isJsonString(arguments.changes.description)) {
				variables.errors.validation("An instrument description must be a string or null; this patch supplies " & variables.types.describe(arguments.changes.description) & ".", "INSTRUMENT_METADATA_INVALID");
			}
			var trimmedDescription = trim(description);
			if (len(trimmedDescription) > variables.MAX_DESCRIPTION) {
				variables.errors.validation("An instrument description may be at most " & variables.MAX_DESCRIPTION & " characters.", "INSTRUMENT_METADATA_INVALID");
			}
			// A blank description clears the column, which is what NULL means here.
			patch["description"] = trimmedDescription;
		}

		if (structKeyExists(arguments.changes, "active")) {
			if (!variables.types.isJsonBoolean(arguments.changes.active)) {
				variables.errors.validation(
					"Whether an instrument is in service must be a boolean; this patch supplies " & variables.types.describe(arguments.changes.active)
						& ". It is not coerced, because taking a published version out of service is not something a malformed value may do by accident.",
					"INSTRUMENT_METADATA_INVALID"
				);
			}
			patch["active"] = arguments.changes.active ? true : false;
		}

		if (structIsEmpty(patch)) {
			variables.errors.validation(
				"A shared instrument metadata change must name at least one of " & arrayToList(variables.SUPPORTED, ", ") & ".",
				"INSTRUMENT_METADATA_NO_CHANGES"
			);
		}
		return patch;
	}

	// ---- shared with the transaction closure ------------------------------------------------------

	/** Public only because the transaction closure above reaches them through `self`. */
	public struct function result(
		required string instrumentId, required string instrumentCode, required struct after,
		required array changedFields, required string actor, required boolean noOp
	) {
		return {
			"instrumentId": arguments.instrumentId,
			"instrumentCode": arguments.instrumentCode,
			"name": arguments.after.name,
			"description": len(arguments.after.description) ? arguments.after.description : javaCast("null", ""),
			"active": arguments.after.active,
			"changedFields": arguments.changedFields,
			"noOp": arguments.noOp,
			"updatedByUserId": arguments.actor
		};
	}

	public string function textOf(any value) {
		if (isNull(arguments.value) || !isSimpleValue(arguments.value)) return "";
		return trim(toString(arguments.value));
	}
}
