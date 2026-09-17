/**
 * Development identity stub. The caller names the identity in request headers:
 *   X-ICFWalk-Dev-Subject   required, the identity subject (for example "dev-district-walker")
 *   X-ICFWalk-Dev-Name      optional display name
 *   X-ICFWalk-Dev-Email     optional email
 *
 * It exists only when ICFWALK_DEV_IDENTITY_ENABLED=true in the development or test environment;
 * ConfigLoader refuses that setting in production and IdentityProviderFactory refuses to build this
 * adapter unless the loaded configuration allows it, so it cannot be enabled by accident.
 */
component implements="icfwalk.identity.IdentityProvider" output="false" {

	public DevelopmentIdentityProvider function init(required struct config, required any logger) {
		if (!arguments.config.devIdentityEnabled || arguments.config.isProduction) {
			throw(type = "ICFWalk.Configuration", message = "The development identity stub is not permitted by the current configuration.", errorcode = "DEV_IDENTITY_NOT_PERMITTED");
		}
		variables.logger = arguments.logger;
		return this;
	}

	public string function name() { return "development"; }
	public boolean function perRequest() { return true; }

	public struct function resolve(required struct req) {
		var headers = arguments.req.headers;
		var subject = structKeyExists(headers, "x-icfwalk-dev-subject") ? trim(headers["x-icfwalk-dev-subject"]) : "";
		if (!len(subject)) return { "authenticated": false, "subject": "", "displayName": "", "email": "", "claims": {}, "reason": "no_dev_subject" };
		if (!reFind("^[A-Za-z0-9._@-]{1,255}$", subject)) return { "authenticated": false, "subject": "", "displayName": "", "email": "", "claims": {}, "reason": "dev_subject_invalid" };
		var name = structKeyExists(headers, "x-icfwalk-dev-name") ? trim(headers["x-icfwalk-dev-name"]) : "";
		var email = structKeyExists(headers, "x-icfwalk-dev-email") ? trim(headers["x-icfwalk-dev-email"]) : "";
		return {
			"authenticated": true,
			"subject": subject,
			"displayName": len(name) ? left(name, 200) : subject,
			"email": len(email) && isValid("email", email) ? left(email, 320) : "",
			"claims": { "stub": true },
			"reason": ""
		};
	}
}
