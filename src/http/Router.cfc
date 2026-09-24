/**
 * Maps HTTP method + path to controller actions and enforces the route's authorization policy
 * before the controller runs. Every route declares a policy explicitly; there is no default that
 * grants access:
 *
 *   "public"                        no identity required (health only)
 *   "maintenance"                   operator token guard (MaintenanceGuard, no session)
 *   { "authenticated": true }       a signed-in user (any or no roles)
 *   { "permission": "x", ... }      a signed-in user holding permission x globally, or for the org
 *                                   unit named by "orgUnitParam" (path capture index) / "orgUnitBody"
 *                                   (JSON body key). Record-level checks happen in controllers via
 *                                   AuthorizationService.authorizeWalk.
 *   { "anyPermission": [..] }       a signed-in user holding at least one of the permissions
 *                                   anywhere (used for shared, non-record resources such as the
 *                                   instrument definitions and the HTML shell).
 *
 * State-changing requests (POST/PUT/PATCH/DELETE) on session-authenticated routes must carry the
 * session's CSRF token in X-ICFWalk-CSRF-Token. Controllers receive a request struct (path params,
 * query, parsed JSON body, headers, principal) and return { status, body }.
 */
component output="false" {

	variables.MUTATING = ["POST", "PUT", "PATCH", "DELETE"];
	variables.SHELL_PERMISSIONS = ["walk.create", "walk.read", "walk.edit_owned", "report.view", "instrument.manage"];
	variables.WALK_LIST_PERMISSIONS = ["walk.create", "walk.read", "walk.edit_owned"];
	variables.WALK_READ_PERMISSIONS = ["walk.read", "walk.edit_owned"];
	variables.WALK_EDIT_PERMISSIONS = ["walk.edit_owned"];

	public Router function init(required struct container) {
		variables.c = arguments.container;
		variables.routes = [];
		add("GET", "^/api/health$", "healthController", "get", "public");

		// HTML shell and instrument engine (Phase 3). The shell is the single page for My Walks and
		// the walk editor; it needs a signed-in user with a walk, report, or instrument capability.
		add("GET", "^/$", "shellController", "index", { "anyPermission": variables.SHELL_PERMISSIONS });
		add("GET", "^/api/instrument/current$", "instrumentController", "current", { "anyPermission": variables.SHELL_PERMISSIONS });

		add("GET", "^/api/me$", "authController", "me", { "authenticated": true });
		add("GET", "^/api/auth/csrf-token$", "authController", "csrfToken", { "authenticated": true });
		add("POST", "^/api/auth/sign-out$", "authController", "signOut", { "authenticated": true });

		add("GET", "^/api/admin/instrument/versions$", "adminInstrumentController", "listVersions", { "permission": "instrument.manage" });
		// Publishing (Phase 6). State-changing, so it carries the same CSRF and permission posture
		// as every other POST; the service refuses anything that is not a DRAFT.
		add("POST", "^/api/admin/instrument/versions/([^/]+)/publish$", "adminInstrumentController", "publishVersion", { "permission": "instrument.manage" });
		// The rest of instrument administration (Phase 6). Every route requires instrument.manage;
		// every POST also requires the CSRF token (enforcePolicy). Reads are GETs and change nothing.
		add("POST", "^/api/admin/instrument/import$", "adminInstrumentController", "importDocument", { "permission": "instrument.manage" });
		add("GET", "^/api/admin/instrument/compare$", "adminInstrumentController", "compareVersions", { "permission": "instrument.manage" });
		add("GET", "^/api/admin/instrument/versions/([^/]+)/preview$", "adminInstrumentController", "previewVersion", { "permission": "instrument.manage" });
		add("GET", "^/api/admin/instrument/versions/([^/]+)/wording$", "adminInstrumentController", "wording", { "permission": "instrument.manage" });
		add("GET", "^/api/admin/instrument/versions/([^/]+)/placeholders$", "adminInstrumentController", "placeholders", { "permission": "instrument.manage" });
		add("POST", "^/api/admin/instrument/versions/([^/]+)/clone$", "adminInstrumentController", "cloneVersion", { "permission": "instrument.manage" });
		add("POST", "^/api/admin/instrument/versions/([^/]+)/edits$", "adminInstrumentController", "editDraft", { "permission": "instrument.manage" });
		add("POST", "^/api/admin/instrument/versions/([^/]+)/discard$", "adminInstrumentController", "discardVersion", { "permission": "instrument.manage" });
		add("POST", "^/api/admin/instrument/versions/([^/]+)/retire$", "adminInstrumentController", "retireVersion", { "permission": "instrument.manage" });

		// Walk persistence (Phase 4). Report-only and instrument-admin roles hold none of these
		// capabilities and are refused before any controller runs; record-level scope/owner checks
		// happen in WalkService through AuthorizationService.authorizeWalk.
		add("GET", "^/api/walks$", "walkController", "list", { "anyPermission": variables.WALK_LIST_PERMISSIONS });
		add("POST", "^/api/walks$", "walkController", "create", { "permission": "walk.create", "orgUnitBody": "orgUnitId" });
		add("GET", "^/api/walks/([^/]+)$", "walkController", "open", { "anyPermission": variables.WALK_READ_PERMISSIONS });
		add("GET", "^/api/walks/([^/]+)/instrument$", "walkController", "instrument", { "anyPermission": variables.WALK_READ_PERMISSIONS });
		// Summary export (Phase 5): read-only, so the same read policy as opening a walk and no CSRF.
		// The bare-id route is "$" anchored, so this path is unambiguous.
		add("GET", "^/api/walks/([^/]+)/summary$", "walkController", "summary", { "anyPermission": variables.WALK_READ_PERMISSIONS });
		add("PUT", "^/api/walks/([^/]+)$", "walkController", "save", { "anyPermission": variables.WALK_EDIT_PERMISSIONS });
		add("POST", "^/api/walks/([^/]+)/complete$", "walkController", "complete", { "anyPermission": variables.WALK_EDIT_PERMISSIONS });
		add("POST", "^/api/walks/([^/]+)/void$", "walkController", "void", { "anyPermission": variables.WALK_EDIT_PERMISSIONS });
		add("DELETE", "^/api/walks/([^/]+)$", "walkController", "remove", { "anyPermission": variables.WALK_EDIT_PERMISSIONS });

		// Aggregate reporting (Phase 7). Read-only, so no CSRF; report.view anywhere admits the
		// request and ReportService draws the population from the caller's covered units only. The
		// ".csv" route is "$" anchored and listed first so neither pattern can shadow the other.
		add("GET", "^/api/reports/options$", "reportController", "options", { "permission": "report.view" });
		add("GET", "^/api/reports/aggregate\.csv$", "reportController", "exportCsv", { "permission": "report.view" });
		add("GET", "^/api/reports/aggregate$", "reportController", "aggregate", { "permission": "report.view" });

		add("POST", "^/api/maintenance/instrument/import$", "maintenanceController", "importInstrument", "maintenance");
		add("GET", "^/api/maintenance/instrument/versions$", "maintenanceController", "listVersions", "maintenance");
		add("POST", "^/api/maintenance/instrument/discard-draft$", "maintenanceController", "discardDraft", "maintenance");
		add("POST", "^/api/maintenance/org-units/import$", "maintenanceController", "importOrgUnits", "maintenance");
		add("POST", "^/api/maintenance/org-units/align-school-dimension$", "maintenanceController", "alignSchoolDimension", "maintenance");
		add("POST", "^/api/maintenance/identity/provision-user$", "maintenanceController", "provisionUser", "maintenance");
		add("POST", "^/api/maintenance/identity/assign-role$", "maintenanceController", "assignRole", "maintenance");
		add("POST", "^/api/maintenance/identity/cleanup-fixtures$", "maintenanceController", "cleanupFixtures", "maintenance");
		add("POST", "^/api/maintenance/tests/run$", "maintenanceController", "runTests", "maintenance");
		add("GET", "^/api/maintenance/tests/run$", "maintenanceController", "runTests", "maintenance");
		return this;
	}

	public void function add(required string method, required string pattern, required string controller, required string action, required any policy) {
		if (!isSimpleValue(arguments.policy) && !isStruct(arguments.policy)) {
			throw(type = "ICFWalk.Configuration", message = "Route policy must be a string or struct.", errorcode = "ROUTE_POLICY_INVALID");
		}
		if (isSimpleValue(arguments.policy) && arguments.policy != "public" && arguments.policy != "maintenance") {
			throw(type = "ICFWalk.Configuration", message = "Unknown route policy '" & arguments.policy & "'.", errorcode = "ROUTE_POLICY_INVALID");
		}
		arrayAppend(variables.routes, { "method": uCase(arguments.method), "pattern": arguments.pattern, "controller": arguments.controller, "action": arguments.action, "policy": arguments.policy });
	}

	public array function routes() {
		var out = [];
		for (var r in variables.routes) arrayAppend(out, { "method": r.method, "pattern": r.pattern, "policy": r.policy });
		return out;
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
				enforcePolicy(route, req);
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

	/**
	 * Applies the route policy. Maintenance routes keep their guard inside the controller (token
	 * header, no session); every other non-public route authenticates first, then checks CSRF for
	 * mutating methods, then the declared permission.
	 */
	private void function enforcePolicy(required struct route, required struct req) {
		var policy = arguments.route.policy;
		if (isSimpleValue(policy)) {
			if (policy == "public" || policy == "maintenance") return;
			variables.c.errors.forbidden();
		}
		var principal = variables.c.authenticationService.authenticate(arguments.req);
		arguments.req["principal"] = principal;
		if (arrayContains(variables.MUTATING, arguments.req.method)) {
			var supplied = structKeyExists(arguments.req.headers, "x-icfwalk-csrf-token") ? trim(arguments.req.headers["x-icfwalk-csrf-token"]) : "";
			if (!variables.c.sessionService.csrfTokenValid(supplied)) {
				variables.c.logger.warn("csrf.rejected", { "path": arguments.req.path, "userId": principal.userId });
				variables.c.errors.forbidden("Missing or invalid CSRF token.", "CSRF_TOKEN_INVALID");
			}
		}
		if (structKeyExists(policy, "anyPermission")) {
			var granted = false;
			for (var perm in policy.anyPermission) if (variables.c.authorizationService.hasAnyCapability(principal, perm)) granted = true;
			if (!granted) {
				variables.c.logger.warn("authorization.denied", { "permission": arrayToList(policy.anyPermission), "kind": "forbidden", "path": arguments.req.path });
				variables.c.auditRepository.record("ROUTE", "", "ACCESS_DENIED", principal.userId, { "permissions": policy.anyPermission, "kind": "forbidden", "path": arguments.req.path });
				variables.c.errors.forbidden("You do not have permission to perform this action.", "FORBIDDEN");
			}
		} else if (structKeyExists(policy, "permission")) {
			var orgUnitId = "";
			if (structKeyExists(policy, "orgUnitParam") && arrayLen(arguments.req.params) >= policy.orgUnitParam) orgUnitId = arguments.req.params[policy.orgUnitParam];
			if (structKeyExists(policy, "orgUnitBody") && structKeyExists(arguments.req.body, policy.orgUnitBody) && isSimpleValue(arguments.req.body[policy.orgUnitBody])) orgUnitId = arguments.req.body[policy.orgUnitBody];
			variables.c.authorizationService.requirePermission(principal, policy.permission, orgUnitId);
		} else if (!structKeyExists(policy, "authenticated") || !policy.authenticated) {
			variables.c.errors.forbidden();
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
			"body": {},
			// Whether the client sent a body AT ALL, independent of what it parsed to. A route
			// documented as taking no request body cannot tell that from `body` alone: no body and
			// a literal `{}` both parse to an empty struct, so structCount() accepted `{}` from a
			// client that believed it was sending something. This is the raw fact -- were there any
			// body bytes on the wire -- and it is what such a route checks.
			"hasBody": false,
			"rawBodyLength": 0,
			"principal": {}
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
		// DID THE CLIENT SEND A BODY? Asked of the wire, not of the parse.
		//
		// The engine does not hand back whitespace-only content -- getHttpRequestData() gives an
		// empty string for it -- so `content` alone cannot answer this, and a route documented as
		// taking no body would accept "   " while refusing "{}". Content-Length is the raw fact and
		// is checked first; `content` covers a chunked request, which carries no Content-Length.
		// Content-Length: 0 is not a body: the client sent no bytes.
		var declaredLength = structKeyExists(req.headers, "content-length") && isNumeric(req.headers["content-length"])
			? int(req.headers["content-length"]) : 0;
		var actualLength = (!isNull(content) && isSimpleValue(content)) ? len(content) : 0;
		req.rawBodyLength = max(declaredLength, actualLength);
		req.hasBody = req.rawBodyLength > 0;
		if (!isNull(content) && len(trim(content))) {
			if (!isJSON(content)) {
				variables.c.errors.validation("Request body must be a JSON document.", "INVALID_JSON_BODY");
			}
			// A body of literal `null` parses to CFML null, and reading that variable back is an
			// error rather than a value -- so this used to escape as a 500 instead of the 400 the
			// contract promises. isNull() is the only safe way to ask.
			var parsed = deserializeJSON(content);
			if (isNull(parsed) || !isStruct(parsed)) {
				variables.c.errors.validation("Request body must be a JSON object.", "INVALID_JSON_BODY");
			}
			req.body = parsed;
		}
		return req;
	}
}
