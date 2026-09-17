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
}
