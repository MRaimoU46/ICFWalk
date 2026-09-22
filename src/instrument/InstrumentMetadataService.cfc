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
 * THE CONTRACT.
 *   - A named actor is required, must be a real app_user, and is checked before anything is
 *     written. There is no default and no unattributed path.
 *   - The instrument row is taken under its own UPDLOCK inside the transaction, so two of these
 *     operations serialize rather than interleave.
 *   - It writes exactly one INSTRUMENT_METADATA_UPDATED audit event on success, carrying the
 *     before and after of each field it changed -- lifecycle facts only, never definitions,
 *     snapshot text, narrative content, secrets or tokens.
 *   - A refusal writes nothing and changes nothing: every check runs before the update, inside the
 *     transaction, so a rollback leaves the row exactly as it was.
 *   - It never touches a version. Publishing, importing and discarding are unaffected by it, and
 *     it cannot make a frozen version's definitions say anything different.
 *
 * NO ROUTE. This correction closes the write boundary; it does not add the administration UI for
 * the operation. Nothing in src/http or src/controllers reaches this component, deliberately.
 */
component output="false" {

	public InstrumentMetadataService function init(
		required any db, required any errors, required any logger,
		required any definitionRepository, required any auditRepository
	) {
		variables.db = arguments.db;
		variables.errors = arguments.errors;
		variables.logger = arguments.logger;
		variables.repo = arguments.definitionRepository;
		variables.audit = arguments.auditRepository;
		return this;
	}

	/**
	 * Changes the shared row for one instrument, on behalf of one named user.
	 *
	 * `changes` may carry name, description and active; anything it omits keeps its stored value,
	 * so a caller changing one fact does not have to restate the others and cannot blank them by
	 * accident.
	 */
	public struct function updateMetadata(required string instrumentCode, required struct changes, required string actorUserId) {
		if (!len(trim(arguments.actorUserId))) {
			variables.errors.validation("Changing shared instrument metadata requires a named user.", "INSTRUMENT_METADATA_ACTOR_REQUIRED");
		}
		if (!variables.db.isGuid(arguments.actorUserId)) {
			variables.errors.validation("The authorizing user must be a valid user id.", "INSTRUMENT_METADATA_ACTOR_REQUIRED");
		}
		var code = trim(arguments.instrumentCode);
		var changes = arguments.changes;
		var actor = uCase(trim(arguments.actorUserId));
		var repo = variables.repo;
		var errors = variables.errors;
		var self = this;

		var outcome = variables.db.transact(function() {
			var instrument = repo.findInstrumentByCode(code);
			if (structIsEmpty(instrument)) {
				errors.notFound("No instrument with code '" & code & "' exists.", "INSTRUMENT_NOT_FOUND");
			}
			var before = {
				"name": self.textOf(instrument.name),
				"description": self.textOf(instrument.description),
				"active": self.flagOf(instrument.active)
			};
			var after = {
				"name": structKeyExists(changes, "name") ? self.textOf(changes.name) : before.name,
				"description": structKeyExists(changes, "description") ? self.textOf(changes.description) : before.description,
				"active": structKeyExists(changes, "active") ? self.flagOf(changes.active) : before.active
			};
			if (!len(after.name)) {
				errors.validation("An instrument must have a name.", "INSTRUMENT_METADATA_INVALID");
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

			var changed = [];
			for (var field in ["name", "description", "active"]) {
				if (toString(before[field]) != toString(after[field])) arrayAppend(changed, field);
			}
			variables.audit.record("INSTRUMENT", instrument.instrumentId, "INSTRUMENT_METADATA_UPDATED", actor, {
				"instrumentCode": code,
				"changedFields": changed,
				"previousName": before.name,
				"name": after.name,
				"previousActive": before.active,
				"active": after.active
			});

			return {
				"instrumentId": instrument.instrumentId,
				"instrumentCode": code,
				"name": after.name,
				"description": len(after.description) ? after.description : javaCast("null", ""),
				"active": after.active,
				"changedFields": changed,
				"updatedByUserId": actor
			};
		});

		variables.logger.info("instrument.metadata.updated", {
			"instrumentCode": code, "changedFields": outcome.changedFields, "active": outcome.active
		});
		return outcome;
	}

	/** Public only because the transaction closure above reaches them through `self`. */
	public string function textOf(any value) {
		if (isNull(arguments.value) || !isSimpleValue(arguments.value)) return "";
		return trim(toString(arguments.value));
	}

	public boolean function flagOf(any value) {
		if (isNull(arguments.value)) return false;
		if (isBoolean(arguments.value)) return arguments.value ? true : false;
		if (isSimpleValue(arguments.value)) {
			var t = lCase(trim(toString(arguments.value)));
			return t == "true" || t == "yes" || t == "1";
		}
		return false;
	}
}
