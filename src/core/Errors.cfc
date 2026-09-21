/**
 * Application error model. Every failure the application raises deliberately has a stable
 * exception type (ICFWalk.*), a machine-readable errorcode, an operator-safe message, and an
 * optional details document (JSON in extendedInfo) that never contains narrative walk content,
 * secrets, or tokens. The Responder maps types to HTTP statuses.
 *
 * Types:
 *   ICFWalk.Validation           400  Request or document failed validation (details lists issues)
 *   ICFWalk.Unauthenticated      401  No verified identity (Phase 2)
 *   ICFWalk.Forbidden            403  Identity lacks the role/scope (Phase 2)
 *   ICFWalk.NotFound             404  Resource does not exist or is outside the caller's scope
 *   ICFWalk.Conflict             409  Optimistic-concurrency or state conflict
 *   ICFWalk.Import.Validation    422  Instrument configuration is invalid
 *   ICFWalk.Import.PublishedVersion 409  Import targeted a PUBLISHED/RETIRED version
 *   ICFWalk.Publish.NotDraft        409  Publish or edit targeted a version that is not a DRAFT
 *   ICFWalk.Publish.Validation      422  A DRAFT was not publishable; nothing was changed
 *   ICFWalk.Import.VersionInUse  409  A DRAFT already referenced by walks cannot be rewritten
 *   ICFWalk.Configuration        500  Deployment configuration is invalid
 */
component output="false" {

	public void function validation(required string message, string code = "VALIDATION_FAILED", any details = "") {
		raise("ICFWalk.Validation", arguments.message, arguments.code, arguments.details);
	}

	public void function unauthenticated(string message = "Authentication required.", string code = "UNAUTHENTICATED") {
		raise("ICFWalk.Unauthenticated", arguments.message, arguments.code);
	}

	public void function forbidden(string message = "Access denied.", string code = "FORBIDDEN") {
		raise("ICFWalk.Forbidden", arguments.message, arguments.code);
	}

	public void function notFound(string message = "Not found.", string code = "NOT_FOUND") {
		raise("ICFWalk.NotFound", arguments.message, arguments.code);
	}

	public void function conflict(required string message, string code = "CONFLICT", any details = "") {
		raise("ICFWalk.Conflict", arguments.message, arguments.code, arguments.details);
	}

	public void function importValidation(required string message, required array issues) {
		raise("ICFWalk.Import.Validation", arguments.message, "INSTRUMENT_CONFIG_INVALID", { "issues": arguments.issues });
	}

	public void function importPublishedVersion(required string versionLabel, required string status) {
		raise(
			"ICFWalk.Import.PublishedVersion",
			"Instrument version '" & arguments.versionLabel & "' is " & arguments.status & " and cannot be imported over. Create a new DRAFT version instead.",
			"INSTRUMENT_VERSION_IMMUTABLE",
			{ "versionLabel": arguments.versionLabel, "status": arguments.status }
		);
	}

	public void function importVersionInUse(required string versionLabel, required numeric walkCount) {
		raise(
			"ICFWalk.Import.VersionInUse",
			"Instrument version '" & arguments.versionLabel & "' is referenced by existing walks and cannot be rewritten.",
			"INSTRUMENT_VERSION_IN_USE",
			{ "versionLabel": arguments.versionLabel, "walkCount": arguments.walkCount }
		);
	}

	/**
	 * Publishing (Phase 6). A version that is not a DRAFT is already frozen: publishing it again,
	 * or editing it, is refused rather than silently ignored.
	 */
	public void function publishNotDraft(required string versionLabel, required string status) {
		raise(
			"ICFWalk.Publish.NotDraft",
			"Instrument version '" & arguments.versionLabel & "' is " & arguments.status & " and cannot be published. Only a DRAFT can be published.",
			"INSTRUMENT_VERSION_NOT_DRAFT",
			{ "versionLabel": arguments.versionLabel, "status": arguments.status }
		);
	}

	public void function publishValidation(required string message, required array issues) {
		raise("ICFWalk.Publish.Validation", arguments.message, "INSTRUMENT_VERSION_NOT_PUBLISHABLE", { "issues": arguments.issues });
	}

	public void function configuration(required string message, string code = "CONFIGURATION_INVALID") {
		raise("ICFWalk.Configuration", arguments.message, arguments.code);
	}

	public void function raise(required string type, required string message, required string code, any details = "") {
		var info = "";
		if (isStruct(arguments.details) || isArray(arguments.details)) {
			info = serializeJSON(arguments.details);
		} else if (isSimpleValue(arguments.details) && len(arguments.details)) {
			info = arguments.details;
		}
		throw(type = arguments.type, message = arguments.message, errorcode = arguments.code, extendedinfo = info);
	}

	/**
	 * Maps an exception type to an HTTP status. Unknown types are treated as server errors.
	 */
	public numeric function statusFor(required string type) {
		switch (arguments.type) {
			case "ICFWalk.Validation": return 400;
			case "ICFWalk.Unauthenticated": return 401;
			case "ICFWalk.Forbidden": return 403;
			case "ICFWalk.NotFound": return 404;
			case "ICFWalk.Conflict": return 409;
			case "ICFWalk.Import.PublishedVersion": return 409;
			case "ICFWalk.Import.VersionInUse": return 409;
			case "ICFWalk.Import.Validation": return 422;
			case "ICFWalk.Publish.NotDraft": return 409;
			case "ICFWalk.Publish.Validation": return 422;
			case "ICFWalk.Configuration": return 500;
		}
		return 500;
	}

	public boolean function isApplicationError(required string type) {
		return left(arguments.type, 8) == "ICFWalk.";
	}

	/**
	 * Parses the details document stored in extendedInfo back into a struct/array, or returns
	 * an empty struct when absent or unparseable.
	 */
	public any function detailsOf(required any exception) {
		if (!structKeyExists(arguments.exception, "extendedInfo")) return {};
		var info = arguments.exception.extendedInfo;
		if (!isSimpleValue(info) || !len(trim(info))) return {};
		if (isJSON(info)) return deserializeJSON(info);
		return { "detail": info };
	}
}
