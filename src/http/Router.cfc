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
 *
 * THE BODY COMES LAST (P6A-01). A request is handled in this order, and each step runs only if the
 * one before it passed:
 *
 *   1. route match, and the request's METADATA (method, path, headers, query, remote address) --
 *      no body byte is read;
 *   2. the policy's pre-body checks: the maintenance guard's token check; or authentication, the
 *      CSRF token for a mutating method, and the permission unless the policy reads a body member
 *      (`orgUnitBody`);
 *   3. the body, under the route's byte limit (`maxBodyBytes`, else the server maximum): a
 *      declared Content-Length over it is refused 413 without reading; otherwise the container's
 *      stream is read in requests of at most min(65,536, limit - total + 1) bytes, so at most one
 *      byte past the limit is taken from it, and a longer body is refused 413 -- counted in bytes,
 *      never characters (HttpRequestSource; an engine-buffered body is measured, not bounded);
 *   4. JSON parsing of a body that passed all of that (JsonBodyParser);
 *   5. the permission of an `orgUnitBody` policy, which needs the parsed member;
 *   6. the controller.
 *
 * It used to read and parse the body inside step 1, so an anonymous or CSRF-invalid caller's body
 * was acquired and deserialized in full, a malformed body answered 400 before anyone asked who sent
 * it, and the import's size limit -- checked in its controller -- came after the parse.
 */
component output="false" {

	variables.MUTATING = ["POST", "PUT", "PATCH", "DELETE"];
	variables.SHELL_PERMISSIONS = ["walk.create", "walk.read", "walk.edit_owned", "report.view", "instrument.manage"];
	variables.WALK_LIST_PERMISSIONS = ["walk.create", "walk.read", "walk.edit_owned"];
	variables.WALK_READ_PERMISSIONS = ["walk.read", "walk.edit_owned"];
	variables.WALK_EDIT_PERMISSIONS = ["walk.edit_owned"];

	// The server maximum: the most any request body may be, on any route that does not declare a
	// smaller limit of its own. It matches Adobe ColdFusion's default "Maximum size of post data"
	// (20 MB) and sits far above any real walk save; production also sets the same ceiling at the
	// connector (docs/LOCAL_SETUP.md, "Request size limits").
	variables.MAX_REQUEST_BODY_BYTES = 20000000;
	// An uploaded instrument document is ~300 KB; this leaves ample room for growth while refusing a
	// body no administrator would send (the import route's limit, ADM-01).
	variables.MAX_IMPORT_BYTES = 5000000;

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
		add("POST", "^/api/admin/instrument/import$", "adminInstrumentController", "importDocument", { "permission": "instrument.manage" }, {
			"maxBodyBytes": variables.MAX_IMPORT_BYTES,
			"tooLargeCode": "DOCUMENT_TOO_LARGE",
			"tooLargeMessage": "The instrument document may be at most " & variables.MAX_IMPORT_BYTES & " bytes."
		});
		add("GET", "^/api/admin/instrument/compare$", "adminInstrumentController", "compareVersions", { "permission": "instrument.manage" });
		add("GET", "^/api/admin/instrument/versions/([^/]+)/preview$", "adminInstrumentController", "previewVersion", { "permission": "instrument.manage" });
		add("GET", "^/api/admin/instrument/versions/([^/]+)/wording$", "adminInstrumentController", "wording", { "permission": "instrument.manage" });
		add("GET", "^/api/admin/instrument/versions/([^/]+)/document$", "adminInstrumentController", "exportDocument", { "permission": "instrument.manage" });
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
		// Releases (RPT-03 correction): the one report write, so it carries CSRF like every POST.
		// ReportService admits only someone who can open every walk in every school.
		add("POST", "^/api/reports/releases$", "reportController", "createRelease", { "permission": "report.view" });

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

	/**
	 * `options.maxBodyBytes` sets the route's own body limit (else the server maximum), with
	 * `tooLargeCode` / `tooLargeMessage` for its 413. It is route METADATA: the router enforces it
	 * before the body is read or parsed, so no controller can run ahead of it.
	 */
	public void function add(required string method, required string pattern, required string controller, required string action, required any policy, struct options = {}) {
		if (!isSimpleValue(arguments.policy) && !isStruct(arguments.policy)) {
			throw(type = "ICFWalk.Configuration", message = "Route policy must be a string or struct.", errorcode = "ROUTE_POLICY_INVALID");
		}
		if (isSimpleValue(arguments.policy) && arguments.policy != "public" && arguments.policy != "maintenance") {
			throw(type = "ICFWalk.Configuration", message = "Unknown route policy '" & arguments.policy & "'.", errorcode = "ROUTE_POLICY_INVALID");
		}
		var limit = structKeyExists(arguments.options, "maxBodyBytes") ? arguments.options.maxBodyBytes : variables.MAX_REQUEST_BODY_BYTES;
		if (!isNumeric(limit) || limit < 0 || limit > variables.MAX_REQUEST_BODY_BYTES) {
			throw(type = "ICFWalk.Configuration", message = "A route's maxBodyBytes must be between 0 and the server maximum.", errorcode = "ROUTE_POLICY_INVALID");
		}
		arrayAppend(variables.routes, {
			"method": uCase(arguments.method), "pattern": arguments.pattern, "controller": arguments.controller, "action": arguments.action, "policy": arguments.policy,
			"maxBodyBytes": limit,
			"tooLargeCode": structKeyExists(arguments.options, "tooLargeCode") ? arguments.options.tooLargeCode : "PAYLOAD_TOO_LARGE",
			"tooLargeMessage": structKeyExists(arguments.options, "tooLargeMessage") ? arguments.options.tooLargeMessage : "The request body may be at most " & limit & " bytes."
		});
	}

	public array function routes() {
		var out = [];
		for (var r in variables.routes) arrayAppend(out, { "method": r.method, "pattern": r.pattern, "policy": r.policy, "maxBodyBytes": r.maxBodyBytes });
		return out;
	}

	public void function dispatch() {
		var responder = variables.c.responder;
		try {
			var outcome = handle(variables.c.httpRequestSource);
			if (structKeyExists(outcome, "unrouted")) {
				responder.sendError(outcome.status, outcome.code, outcome.message);
				return;
			}
			responder.send(outcome);
		} catch (any e) {
			responder.sendException(e);
		}
	}

	/**
	 * One request, in the order the header describes, from `source` (HttpRequestSource for a real
	 * request; a spec's FakeRequestSource otherwise). Returns the controller's result, or
	 * { unrouted, status, code, message } when no route matched; refusals are thrown.
	 */
	public struct function handle(required any source) {
		var method = arguments.source.method();
		var path = arguments.source.path();
		var methodMismatch = false;
		for (var route in variables.routes) {
			var m = reFind(route.pattern, path, 1, true);
			if (m.len[1] == 0) continue;
			if (route.method != method) { methodMismatch = true; continue; }
			var req = requestMetadata(arguments.source, method, path, m);
			authorizeBeforeBody(route, req);
			acquireBody(route, req, arguments.source);
			authorizeAfterBody(route, req);
			var controller = variables.c[route.controller];
			return invoke(controller, route.action, { "req": req });
		}
		if (methodMismatch) return { "unrouted": true, "status": 405, "code": "METHOD_NOT_ALLOWED", "message": "Method not allowed." };
		return { "unrouted": true, "status": 404, "code": "NOT_FOUND", "message": "Not found." };
	}

	/**
	 * Step 2. Maintenance routes: the guard's token check (the controller still runs its own full
	 * guard, which audits the invocation). Every other non-public route: authentication, then CSRF
	 * for a mutating method, then the declared permission -- unless the policy reads a body member,
	 * in which case that one check waits for step 5.
	 */
	private void function authorizeBeforeBody(required struct route, required struct req) {
		var policy = arguments.route.policy;
		if (isSimpleValue(policy)) {
			if (policy == "public") return;
			if (policy == "maintenance") {
				variables.c.maintenanceGuard.precheck(arguments.req, arguments.route.action);
				return;
			}
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
		if (needsBody(policy)) return;
		requirePolicyPermission(policy, arguments.req);
	}

	/** Step 5: the permission of a policy that is decided on a body member. */
	private void function authorizeAfterBody(required struct route, required struct req) {
		if (isStruct(arguments.route.policy) && needsBody(arguments.route.policy)) requirePolicyPermission(arguments.route.policy, arguments.req);
	}

	private boolean function needsBody(required any policy) {
		return isStruct(arguments.policy) && structKeyExists(arguments.policy, "orgUnitBody");
	}

	private void function requirePolicyPermission(required struct policy, required struct req) {
		var principal = arguments.req.principal;
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

	/** Step 1: everything about the request except its body. */
	private struct function requestMetadata(required any source, required string method, required string path, required struct match) {
		var req = {
			"path": arguments.path,
			"method": arguments.method,
			"params": [],
			"query": arguments.source.query(),
			"headers": arguments.source.headers(),
			"remoteAddress": arguments.source.remoteAddress(),
			"body": {},
			// Whether the client sent a body AT ALL, independent of what it parsed to. A route
			// documented as taking no request body cannot tell that from `body` alone: no body and
			// a literal `{}` both parse to an empty struct. This is the raw fact -- were there any
			// body bytes on the wire -- set in step 3 from the bytes actually read, whitespace
			// included, and it is what such a route checks.
			"hasBody": false,
			// The body's length in BYTES as read (step 3).
			"rawBodyLength": 0,
			"principal": {}
		};
		var n = arrayLen(arguments.match.len);
		for (var i = 2; i <= n; i++) {
			if (arguments.match.len[i] > 0) arrayAppend(req.params, mid(arguments.path, arguments.match.pos[i], arguments.match.len[i]));
			else arrayAppend(req.params, "");
		}
		return req;
	}

	/**
	 * Steps 3 and 4. The declared length is trusted only as a plain decimal Content-Length on a
	 * request without a transfer coding (HTTP: Transfer-Encoding overrides Content-Length); a
	 * declared length over the limit is refused without reading anything. Whatever the declaration,
	 * the source takes at most one byte past the limit from the container's stream (each read asks
	 * for min(65,536, limit - total + 1) bytes: P6A-R01), and the count of bytes actually read is
	 * compared again -- so a chunked or mis-declared body cannot slip past. Only a body within the
	 * limit is decoded (UTF-8) and, if it is not blank, parsed.
	 */
	private void function acquireBody(required struct route, required struct req, required any source) {
		var limit = arguments.route.maxBodyBytes;
		if (declaredLength(arguments.req.headers) > limit) tooLarge(arguments.route);
		var read = arguments.source.readBody(limit);
		if (read.exceeded || read.byteCount > limit) tooLarge(arguments.route);
		arguments.req.rawBodyLength = read.byteCount;
		arguments.req.hasBody = read.byteCount > 0;
		if (read.byteCount == 0) return;
		var text = charsetEncode(read.bytes, "utf-8");
		if (len(trim(text))) arguments.req.body = variables.c.jsonBodyParser.parse(text);
	}

	/** The Content-Length a request declares, or -1 when it declares none that can be trusted. */
	private numeric function declaredLength(required struct headers) {
		if (structKeyExists(arguments.headers, "transfer-encoding")) return -1;
		if (!structKeyExists(arguments.headers, "content-length") || !isSimpleValue(arguments.headers["content-length"])) return -1;
		var raw = trim(arguments.headers["content-length"]);
		if (!reFind("^[0-9]+$", raw)) return -1;
		// Longer than any limit can be, and longer than a number can safely hold: over every limit.
		if (len(raw) > 15) return variables.MAX_REQUEST_BODY_BYTES + 1;
		return val(raw);
	}

	private void function tooLarge(required struct route) {
		variables.c.errors.payloadTooLarge(arguments.route.tooLargeMessage, arguments.route.tooLargeCode, { "limitBytes": arguments.route.maxBodyBytes });
	}
}
