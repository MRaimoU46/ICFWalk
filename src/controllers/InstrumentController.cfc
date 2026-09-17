/**
 * Instrument rendering contract for signed-in users: the current instrument version's render
 * model plus the runtime policies the browser engine must honor. Read-only; no walk data.
 * Route policy: anyPermission (walk, report, or instrument capability). Report-only users may
 * read the instrument definitions (they need them for report filters) but never walk details.
 */
component output="false" {

	public InstrumentController function init(required struct container) {
		variables.c = arguments.container;
		return this;
	}

	public struct function current(required struct req) {
		var current = variables.c.snapshotService.currentRenderModel();
		var v = current.version;
		return { "status": 200, "body": {
			"version": {
				"versionId": v.versionId,
				"versionLabel": v.versionLabel,
				"status": v.status,
				"checksum": v.checksum,
				"publishedAt": (isSimpleValue(v.publishedAt) && isDate(v.publishedAt)) ? variables.c.canonicalJson.formatDate(v.publishedAt) : javaCast("null", ""),
				"isFallbackDraft": v.isFallbackDraft ? true : false
			},
			"policies": {
				// docs/OPEN_DECISIONS.md: hidden Period values are retained as HIDDEN by default.
				"hiddenDimensionPolicy": variables.c.config.hiddenPeriodPolicy
			},
			"model": current.model,
			"correlationId": variables.c.requestContext.correlationId()
		} };
	}
}
