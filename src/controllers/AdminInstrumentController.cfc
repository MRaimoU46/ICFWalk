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
	 * The route's permission check (instrument.manage) has already run; the publishing user is
	 * recorded as the publisher. Every refusal is raised by the service and mapped to its status by
	 * Errors.statusFor, so this action has no failure branch of its own.
	 */
	public struct function publishVersion(required struct req) {
		return {
			"status": 200,
			"body": variables.c.instrumentPublishService.publish(arguments.req.params[1], arguments.req.principal.userId)
		};
	}
}
