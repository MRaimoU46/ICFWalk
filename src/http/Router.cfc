/**
 * Maps HTTP method + path to controller actions. Routes are explicit; anything unmatched is a
 * JSON 404. Controllers receive a request struct (path params, query, parsed JSON body, headers)
 * and return { status, body } which the Responder serializes.
 *
 * Phase 1 routes are health and maintenance only. Phase 2 adds identity and wraps every walk,
 * report, and administration route in server-side authorization.
 */
component output="false" {

	public Router function init(required struct container) {
		variables.c = arguments.container;
		variables.routes = [];
		add("GET", "^/api/health$", "healthController", "get");
		add("POST", "^/api/maintenance/instrument/import$", "maintenanceController", "importInstrument");
		add("GET", "^/api/maintenance/instrument/versions$", "maintenanceController", "listVersions");
		add("POST", "^/api/maintenance/instrument/discard-draft$", "maintenanceController", "discardDraft");
		add("POST", "^/api/maintenance/tests/run$", "maintenanceController", "runTests");
		add("GET", "^/api/maintenance/tests/run$", "maintenanceController", "runTests");
		return this;
	}

	public void function add(required string method, required string pattern, required string controller, required string action) {
		arrayAppend(variables.routes, { "method": uCase(arguments.method), "pattern": arguments.pattern, "controller": arguments.controller, "action": arguments.action });
	}

	public void function dispatch() {
		var responder = variables.c.responder;
		var method = uCase(cgi.request_method);
		var path = variables.c.requestContext.pathInfo();
		try {
			var matched = false;
			var methodMismatch = false;
			for (var route in variables.routes) {
				var m = reFind(route.pattern, path, 1, true);
				if (m.len[1] == 0) continue;
				if (route.method != method) { methodMismatch = true; continue; }
				matched = true;
				var req = buildRequest(path, m);
				var controller = variables.c[route.controller];
				var result = invoke(controller, route.action, { "req": req });
				responder.send(result);
				return;
			}
			if (methodMismatch) {
				responder.sendError(405, "METHOD_NOT_ALLOWED", "Method not allowed.");
			} else {
				responder.sendError(404, "NOT_FOUND", "Not found.");
			}
		} catch (any e) {
			responder.sendException(e);
		}
	}

	private struct function buildRequest(required string path, required struct match) {
		var data = getHttpRequestData(true);
		var req = {
			"path": arguments.path,
			"method": uCase(cgi.request_method),
			"params": [],
			"query": duplicate(url),
			"headers": {},
			"remoteAddress": cgi.remote_addr,
			"body": {}
		};
		for (var name in structKeyArray(data.headers)) {
			req.headers[lCase(name)] = data.headers[name];
		}
		var n = arrayLen(arguments.match.len);
		for (var i = 2; i <= n; i++) {
			if (arguments.match.len[i] > 0) arrayAppend(req.params, mid(arguments.path, arguments.match.pos[i], arguments.match.len[i]));
			else arrayAppend(req.params, "");
		}
		var content = data.content;
		if (!isNull(content) && !isSimpleValue(content)) content = toString(content, "utf-8");
		if (!isNull(content) && len(trim(content))) {
			if (!isJSON(content)) {
				variables.c.errors.validation("Request body must be a JSON document.", "INVALID_JSON_BODY");
			}
			var parsed = deserializeJSON(content);
			if (!isStruct(parsed)) {
				variables.c.errors.validation("Request body must be a JSON object.", "INVALID_JSON_BODY");
			}
			req.body = parsed;
		}
		return req;
	}
}
