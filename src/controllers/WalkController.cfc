/**
 * Walk endpoints (Phase 4). Route policies in Router.cfc require a walk capability; record-level
 * authorization (scope, owner, status) happens in WalkService through AuthorizationService.
 * Bodies are the autosave payload of docs/DATA_CONTRACT.md; responses carry the committed
 * rowVersion, the normalized state, derived states, and the client mutation id.
 */
component output="false" {

	public WalkController function init(required struct container) {
		variables.c = arguments.container;
		return this;
	}

	public struct function list(required struct req) {
		var scope = structKeyExists(arguments.req.query, "scope") && arguments.req.query.scope == "all" ? "all" : "mine";
		return { "status": 200, "body": { "walks": variables.c.walkService.list(arguments.req.principal, scope), "scope": scope, "correlationId": variables.c.requestContext.correlationId() } };
	}

	public struct function create(required struct req) {
		var walk = variables.c.walkService.create(arguments.req.principal, arguments.req.body);
		return { "status": walk.replayed ? 200 : 201, "body": { "walk": walk, "correlationId": variables.c.requestContext.correlationId() } };
	}

	public struct function open(required struct req) {
		return { "status": 200, "body": { "walk": variables.c.walkService.open(arguments.req.principal, arguments.req.params[1]), "correlationId": variables.c.requestContext.correlationId() } };
	}

	public struct function instrument(required struct req) {
		var out = variables.c.walkService.instrumentFor(arguments.req.principal, arguments.req.params[1]);
		out["correlationId"] = variables.c.requestContext.correlationId();
		return { "status": 200, "body": out };
	}

	/**
	 * Text export (Phase 5). The body is the summary exactly as the formatter produced it: UTF-8,
	 * LF line ends, no trailing newline, no BOM. The file name is sanitized down to [A-Za-z0-9_-]
	 * by the formatter (SUM-05), so the Content-Disposition value can carry no quote, path
	 * separator, or traversal sequence however a walk was filled in. Cache-Control and nosniff are
	 * passed explicitly because the Responder's text path sets only the status and content type.
	 */
	public struct function summary(required struct req) {
		var out = variables.c.walkService.summary(arguments.req.principal, arguments.req.params[1]);
		return {
			"status": 200,
			"text": out.text,
			"contentType": "text/plain; charset=utf-8",
			"headers": {
				"Content-Disposition": 'attachment; filename="' & out.fileName & '"',
				"Cache-Control": "no-store",
				"X-Content-Type-Options": "nosniff"
			}
		};
	}

	public struct function save(required struct req) {
		var walk = variables.c.walkService.save(arguments.req.principal, arguments.req.params[1], arguments.req.body);
		return { "status": 200, "body": { "walk": walk, "correlationId": variables.c.requestContext.correlationId() } };
	}

	public struct function complete(required struct req) {
		var walk = variables.c.walkService.complete(arguments.req.principal, arguments.req.params[1], arguments.req.body);
		return { "status": 200, "body": { "walk": walk, "correlationId": variables.c.requestContext.correlationId() } };
	}

	public struct function void(required struct req) {
		var walk = variables.c.walkService.void(arguments.req.principal, arguments.req.params[1], arguments.req.body);
		return { "status": 200, "body": { "walk": walk, "correlationId": variables.c.requestContext.correlationId() } };
	}

	/** DELETE is refused for every walk (WALK-08); the service raises 409 WALK_DELETE_REFUSED. */
	public struct function remove(required struct req) {
		variables.c.walkService.refuseDelete(arguments.req.principal, arguments.req.params[1]);
		return { "status": 409, "body": {} };
	}
}
