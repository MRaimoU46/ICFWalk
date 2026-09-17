/**
 * Identity endpoints: who am I (identity, permissions, scope, CSRF token) and sign-out.
 */
component output="false" {

	public AuthController function init(required struct container) {
		variables.c = arguments.container;
		return this;
	}

	public struct function me(required struct req) {
		var p = arguments.req.principal;
		var assignments = [];
		for (var a in p.assignments) {
			arrayAppend(assignments, {
				"roleCode": a.roleCode, "scopeType": a.scopeType, "orgUnitId": a.orgUnitId, "orgUnitCode": a.orgUnitCode,
				"orgUnitName": a.orgUnitName, "includeDescendants": a.includeDescendants,
				"effectiveStart": variables.c.canonicalJson.formatDate(a.effectiveStart),
				"effectiveEnd": isDate(a.effectiveEnd) ? variables.c.canonicalJson.formatDate(a.effectiveEnd) : javaCast("null", ""),
				"coveredOrgUnitCount": arrayLen(a.coveredOrgUnitIds)
			});
		}
		return { "status": 200, "body": {
			"user": { "userId": p.userId, "displayName": p.displayName, "email": p.email },
			"identityProvider": variables.c.authenticationService.providerName(),
			"permissions": p.permissions,
			"orgUnits": p.orgUnitNames,
			"assignments": assignments,
			"csrfToken": variables.c.sessionService.csrfToken(),
			"correlationId": variables.c.requestContext.correlationId()
		} };
	}

	public struct function csrfToken(required struct req) {
		return { "status": 200, "body": { "csrfToken": variables.c.sessionService.csrfToken() } };
	}

	public struct function signOut(required struct req) {
		variables.c.authenticationService.signOut();
		return { "status": 200, "body": { "signedOut": true } };
	}
}
