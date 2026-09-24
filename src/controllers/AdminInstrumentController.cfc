/**
 * Instrument administration for signed-in MASTER_INSTRUMENT_ADMIN users (permission
 * instrument.manage). Phase 2 exposed version listing; Phase 6 adds import, preview, clone,
 * wording edits, compare, the placeholder queue, publish, retire and discard, all on the same
 * authorization basis: the route requires instrument.manage (and the CSRF token for every POST),
 * and the actor for a write is the authenticated principal -- never a value from the body.
 *
 * Every refusal is raised by a service and mapped to its status by Errors.statusFor.
 */
component output="false" {

	public AdminInstrumentController function init(required struct container) {
		variables.c = arguments.container;
		variables.types = new icfwalk.core.JsonTypes();
		return this;
	}

	// An uploaded instrument document is ~300 KB; this leaves ample room for growth while refusing
	// a body no administrator would send. Checked against the raw byte count, before anything else.
	variables.MAX_IMPORT_BYTES = 5000000;

	/**
	 * GET /api/admin/instrument/versions. Every version of every instrument (by instrument, newest first), with the
	 * one each instrument would serve now marked `isCurrent`.
	 */
	public struct function listVersions(required struct req) {
		return { "status": 200, "body": { "versions": variables.c.instrumentAdminService.listVersions() } };
	}

	/**
	 * POST /api/admin/instrument/import (ADM-01). Body `{ "document": <instrument configuration> }`.
	 * The same import the maintenance route performs, attributed to the signed-in administrator:
	 * full validation, a validation summary with counts, warnings and the placeholder list, and
	 * 201 when a DRAFT was created or 200 when an existing DRAFT was re-imported.
	 */
	public struct function importDocument(required struct req) {
		if (arguments.req.rawBodyLength > variables.MAX_IMPORT_BYTES) {
			variables.c.errors.payloadTooLarge("The instrument document may be at most " & variables.MAX_IMPORT_BYTES & " bytes.", "DOCUMENT_TOO_LARGE", { "limitBytes": variables.MAX_IMPORT_BYTES });
		}
		onlyMembers(arguments.req.body, ["document"], "IMPORT_BODY_INVALID");
		var result = variables.c.instrumentAdminService.importDocument(
			structKeyExists(arguments.req.body, "document") ? arguments.req.body.document : javaCast("null", ""),
			arguments.req.principal.userId
		);
		return { "status": result.created ? 201 : 200, "body": result };
	}

	/** GET /api/admin/instrument/versions/{versionId}/preview (ADM-02). Read-only. */
	public struct function previewVersion(required struct req) {
		return { "status": 200, "body": variables.c.instrumentAdminService.preview(arguments.req.params[1]) };
	}

	/** GET /api/admin/instrument/versions/{versionId}/wording?q= (ADM-06, ADM-08). Read-only. */
	public struct function wording(required struct req) {
		return { "status": 200, "body": variables.c.instrumentAdminService.wording(arguments.req.params[1], queryValue(arguments.req, "q")) };
	}

	/** GET /api/admin/instrument/versions/{versionId}/placeholders?q= (ADM-08). Read-only. */
	public struct function placeholders(required struct req) {
		return { "status": 200, "body": variables.c.instrumentAdminService.placeholders(arguments.req.params[1], queryValue(arguments.req, "q")) };
	}

	/** GET /api/admin/instrument/compare?from=&to= (ADM-06). Read-only. */
	public struct function compareVersions(required struct req) {
		return {
			"status": 200,
			"body": variables.c.instrumentAdminService.compareVersions(queryValue(arguments.req, "from"), queryValue(arguments.req, "to"))
		};
	}

	/**
	 * POST /api/admin/instrument/versions/{versionId}/clone (ADM-06).
	 * Body `{ "versionLabel": "...", "revisionNotes": "..." }` (notes optional). 201 with the new DRAFT.
	 */
	public struct function cloneVersion(required struct req) {
		var result = variables.c.instrumentAdminService.cloneVersion(arguments.req.params[1], arguments.req.body, arguments.req.principal.userId);
		return { "status": 201, "body": result };
	}

	/**
	 * POST /api/admin/instrument/versions/{versionId}/edits (ADM-06, ADM-08).
	 * Body `{ "expectedChecksum": "<64 hex>", "edits": [ { target, key, field, value } ] }`.
	 */
	public struct function editDraft(required struct req) {
		return { "status": 200, "body": variables.c.instrumentAdminService.editDraft(arguments.req.params[1], arguments.req.body, arguments.req.principal.userId) };
	}

	/**
	 * POST /api/admin/instrument/versions/{versionId}/discard. Takes no body, like publish: the
	 * version is in the path and the actor is the session.
	 */
	public struct function discardVersion(required struct req) {
		refuseAnyBody(arguments.req, "DISCARD_BODY_NOT_ALLOWED", "This endpoint takes no request body: the version is named in the path and the actor is the signed-in user.");
		return { "status": 200, "body": variables.c.instrumentAdminService.discard(arguments.req.params[1], arguments.req.principal.userId) };
	}

	/**
	 * POST /api/admin/instrument/versions/{versionId}/retire (ADM-07). No body, or
	 * `{ "allowNoCurrentVersion": true }` to confirm that retiring the instrument's only in-service
	 * version should stop new walks. Nothing else is accepted.
	 */
	public struct function retireVersion(required struct req) {
		var allowNone = false;
		if (arguments.req.hasBody || structCount(arguments.req.body)) {
			onlyMembers(arguments.req.body, ["allowNoCurrentVersion"], "RETIRE_BODY_INVALID");
			if (!structKeyExists(arguments.req.body, "allowNoCurrentVersion") || !variables.types.isJsonBoolean(arguments.req.body.allowNoCurrentVersion)) {
				variables.c.errors.validation("allowNoCurrentVersion must be true or false.", "RETIRE_BODY_INVALID");
			}
			allowNone = arguments.req.body.allowNoCurrentVersion ? true : false;
		}
		return {
			"status": 200,
			"body": variables.c.instrumentPublishService.retire(arguments.req.params[1], arguments.req.principal.userId, allowNone)
		};
	}

	/**
	 * POST /api/admin/instrument/versions/{versionId}/publish (ADM-04).
	 *
	 * The route's permission check (instrument.manage) and the central CSRF check have already run.
	 *
	 * THE PUBLISHER COMES FROM THE SESSION, NEVER FROM THE REQUEST. The only two inputs are the
	 * version id in the path and the authenticated principal; the body selects nothing. A body that
	 * carries anything at all is refused rather than ignored, so a client that believes it can name
	 * an actor, a publisher, a checksum or a snapshot is told it cannot, instead of being quietly
	 * misled into thinking it worked.
	 *
	 * "No body" means no body bytes, not "a body that happens to parse to nothing". This used to
	 * test structCount(req.body), which cannot tell a request with no body from one carrying a
	 * literal `{}` -- both parse to an empty struct -- so `{}` was accepted while the documentation
	 * said the endpoint takes no body. req.hasBody is the raw fact from the wire, so the
	 * implemented contract and the documented one are the same contract: `{}`, whitespace, `null`
	 * and a populated object are all bodies, and all are refused.
	 *
	 * Every refusal is raised by the service and mapped to its status by Errors.statusFor.
	 */
	public struct function publishVersion(required struct req) {
		refuseAnyBody(arguments.req, "PUBLISH_BODY_NOT_ALLOWED", "This endpoint takes no request body: the version is named in the path and the publisher is the signed-in user.");
		return {
			"status": 200,
			"body": variables.c.instrumentPublishService.publish(arguments.req.params[1], arguments.req.principal.userId)
		};
	}
	// ---- helpers ---------------------------------------------------------------------------------

	/** "No body" means no body bytes, exactly as the publish route has always meant it. */
	private void function refuseAnyBody(required struct req, required string code, required string message) {
		if (arguments.req.hasBody || structCount(arguments.req.body)) variables.c.errors.validation(arguments.message, arguments.code);
	}

	private void function onlyMembers(required struct body, required array allowed, required string code) {
		for (var key in structKeyArray(arguments.body)) {
			if (!arrayFindNoCase(arguments.allowed, key)) {
				variables.c.errors.validation("'" & key & "' is not accepted by this endpoint.", arguments.code);
			}
		}
	}

	private string function queryValue(required struct req, required string name) {
		// URL-scope keys come back in the engine's case, so the parameter is found case-insensitively.
		for (var key in structKeyArray(arguments.req.query)) {
			if (compareNoCase(key, arguments.name) == 0 && isSimpleValue(arguments.req.query[key])) return trim(arguments.req.query[key]);
		}
		return "";
	}
}
