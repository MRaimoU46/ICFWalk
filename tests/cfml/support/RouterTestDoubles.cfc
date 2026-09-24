/**
 * Stand-ins for the services Router.handle() consults, so a spec can put a request in any
 * authentication, CSRF and permission state without a browser, a session or the identity stub
 * (P6A-01 specs). Each double records what it was asked, and refusals are raised through the real
 * Errors component so their types and codes are the production ones.
 *
 *   authenticationService   authenticate(req): anonymous -> 401 UNAUTHENTICATED, else a principal
 *   sessionService          csrfTokenValid(supplied): equal to the configured token
 *   authorizationService    requirePermission / hasAnyCapability: granted unless `deny`
 *   controller              any action: records the request it was given and answers 200
 *
 * TEST-ONLY. Lives under tests/cfml; nothing in src/ references it.
 */
component output="false" {

	public RouterTestDoubles function init(required any errors, boolean anonymous = false, string csrfToken = "", boolean deny = false) {
		variables.errors = arguments.errors;
		variables.anonymous = arguments.anonymous;
		variables.csrf = arguments.csrfToken;
		variables.deny = arguments.deny;
		variables.log = { "authenticate": 0, "csrf": 0, "permission": [], "controller": [] };
		return this;
	}

	// ---- authenticationService --------------------------------------------------------------------
	public struct function authenticate(required struct req) {
		variables.log.authenticate++;
		if (variables.anonymous) variables.errors.unauthenticated();
		return { "userId": "00000000-0000-0000-0000-00000000A001", "roles": [], "permissions": {} };
	}

	// ---- sessionService ---------------------------------------------------------------------------
	public boolean function csrfTokenValid(required string supplied) {
		variables.log.csrf++;
		return len(variables.csrf) && compare(arguments.supplied, variables.csrf) == 0;
	}

	// ---- authorizationService ---------------------------------------------------------------------
	public void function requirePermission(required struct principal, required string permission, string orgUnitId = "") {
		arrayAppend(variables.log.permission, { "permission": arguments.permission, "orgUnitId": arguments.orgUnitId });
		if (variables.deny) variables.errors.forbidden("You do not have permission to perform this action.", "FORBIDDEN");
	}

	public boolean function hasAnyCapability(required struct principal, required string permission) {
		arrayAppend(variables.log.permission, { "permission": arguments.permission, "orgUnitId": "" });
		return !variables.deny;
	}

	// ---- controller -------------------------------------------------------------------------------
	public any function onMissingMethod(required string missingMethodName, required struct missingMethodArguments) {
		var req = structKeyExists(arguments.missingMethodArguments, "req") ? arguments.missingMethodArguments.req : arguments.missingMethodArguments[1];
		arrayAppend(variables.log.controller, { "action": arguments.missingMethodName, "body": duplicate(req.body), "hasBody": req.hasBody, "rawBodyLength": req.rawBodyLength });
		return { "status": 200, "body": { "reached": arguments.missingMethodName } };
	}

	public struct function calls() { return duplicate(variables.log); }
}
