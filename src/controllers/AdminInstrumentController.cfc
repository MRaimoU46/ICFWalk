/**
 * Instrument administration for signed-in MASTER_INSTRUMENT_ADMIN users (permission
 * instrument.manage). Phase 2 exposes version listing; Phase 6 adds DRAFT editing, validation,
 * preview, publish, retire, and compare on the same authorization basis.
 */
component output="false" {

	public AdminInstrumentController function init(required struct container) {
		variables.c = arguments.container;
		return this;
	}

	public struct function listVersions(required struct req) {
		return { "status": 200, "body": { "versions": variables.c.definitionRepository.listVersions() } };
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
		if (arguments.req.hasBody || structCount(arguments.req.body)) {
			variables.c.errors.validation(
				"This endpoint takes no request body: the version is named in the path and the publisher is the signed-in user.",
				"PUBLISH_BODY_NOT_ALLOWED"
			);
		}
		return {
			"status": 200,
			"body": variables.c.instrumentPublishService.publish(arguments.req.params[1], arguments.req.principal.userId)
		};
	}
}
