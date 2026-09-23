/**
 * Aggregate report endpoints (Phase 7). The route policy requires report.view before anything
 * here runs; ReportService re-checks it and resolves the caller's organizational scope itself.
 * The report routes are reads: no CSRF token, nothing written except the export's audit event.
 * Creating a release (RPT-03 correction) is the one write, and it carries the Router's CSRF check
 * like every other POST.
 *
 * Only the query string is read. Nothing else in the request -- no header, no body, no identity
 * field -- can name a scope, a version or a population.
 */
component output="false" {

	public ReportController function init(required struct container) {
		variables.c = arguments.container;
		return this;
	}

	public struct function options(required struct req) {
		var out = variables.c.reportService.options(arguments.req.principal, arguments.req.query);
		out["correlationId"] = variables.c.requestContext.correlationId();
		return { "status": 200, "body": out };
	}

	public struct function aggregate(required struct req) {
		var out = variables.c.reportService.aggregate(arguments.req.principal, arguments.req.query);
		out["correlationId"] = variables.c.requestContext.correlationId();
		return { "status": 200, "body": out };
	}

	/**
	 * POST /api/reports/releases: freeze one closed period for report-only users. The body names
	 * the period and nothing else; who releases it is the signed-in principal, never the body.
	 * ReportService decides who may and refuses everything else.
	 */
	public struct function createRelease(required struct req) {
		var out = variables.c.reportService.createRelease(arguments.req.principal, arguments.req.body);
		out["correlationId"] = variables.c.requestContext.correlationId();
		return { "status": 201, "body": out };
	}

	/**
	 * The same report as a CSV attachment. The file name is built from [A-Za-z0-9_-] only, so the
	 * Content-Disposition value can carry no quote, separator or traversal sequence. no-store and
	 * nosniff are set explicitly because the Responder's text path sets only status and type.
	 */
	public struct function exportCsv(required struct req) {
		var out = variables.c.reportService.exportCsv(arguments.req.principal, arguments.req.query);
		return {
			"status": 200,
			"text": out.text,
			"contentType": "text/csv; charset=utf-8",
			"headers": {
				"Content-Disposition": 'attachment; filename="' & out.fileName & '"',
				"Cache-Control": "no-store",
				"X-Content-Type-Options": "nosniff"
			}
		};
	}
}
