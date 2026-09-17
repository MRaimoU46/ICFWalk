/**
 * Per-request authentication: asks the configured identity adapter for the asserted identity,
 * provisions or loads the icf.app_user row, establishes/refreshes the server session, and returns
 * the authorization principal. Every failure is fail-closed (ICFWalk.Unauthenticated) and carries no
 * protected data. Audit events: USER_PROVISIONED, USER_SIGNED_IN, USER_SIGNED_OUT.
 */
component output="false" {

	public AuthenticationService function init(required struct config, required any logger, required any identityProvider, required any userRepository, required any sessionService, required any authorizationService, required any auditRepository, required any errors) {
		variables.config = arguments.config;
		variables.logger = arguments.logger;
		variables.provider = arguments.identityProvider;
		variables.users = arguments.userRepository;
		variables.sessions = arguments.sessionService;
		variables.authz = arguments.authorizationService;
		variables.audit = arguments.auditRepository;
		variables.errors = arguments.errors;
		return this;
	}

	public string function providerName() { return variables.provider.name(); }

	/**
	 * Returns the principal for the request or throws ICFWalk.Unauthenticated.
	 */
	public struct function authenticate(required struct req) {
		var identity = variables.provider.resolve(arguments.req);
		var current = variables.sessions.current();
		var user = {};

		if (identity.authenticated) {
			user = variables.users.findBySubject(identity.subject);
			if (structIsEmpty(user)) {
				if (!variables.config.autoProvisionUsers) {
					variables.logger.warn("auth.unknown_subject", { "provider": variables.provider.name() });
					variables.errors.unauthenticated("No application account exists for this identity.", "USER_NOT_PROVISIONED");
				}
				user = variables.users.provision(identity.subject, identity.displayName, identity.email);
				variables.audit.record("USER", user.userId, "USER_PROVISIONED", user.userId, { "provider": variables.provider.name() });
			}
			if (!user.active) {
				variables.logger.warn("auth.user_inactive", { "userId": user.userId });
				variables.errors.unauthenticated("This account is inactive.", "USER_INACTIVE");
			}
			if (structIsEmpty(current) || !structKeyExists(current, "userId") || current.userId != user.userId) {
				variables.sessions.establish(user);
				variables.users.recordSignIn(user.userId, identity.displayName, identity.email);
				variables.audit.record("USER", user.userId, "USER_SIGNED_IN", user.userId, { "provider": variables.provider.name() });
				variables.logger.info("auth.signed_in", { "userId": user.userId, "provider": variables.provider.name() });
			}
		} else if (!variables.provider.perRequest() && !structIsEmpty(current) && structKeyExists(current, "userId")) {
			// Session-establishing adapters (future OIDC/SAML) keep the identity in the session.
			user = variables.users.findById(current.userId);
			if (structIsEmpty(user) || !user.active) {
				variables.sessions.clear();
				variables.errors.unauthenticated();
			}
		} else {
			if (!structIsEmpty(current)) variables.sessions.clear();
			variables.logger.debug("auth.anonymous", { "reason": identity.reason, "provider": variables.provider.name() });
			variables.errors.unauthenticated();
		}

		var principal = variables.authz.principalFor(user);
		request.icf["actorUserId"] = user.userId;
		request.icf["principal"] = principal;
		return principal;
	}

	public void function signOut() {
		var current = variables.sessions.current();
		if (!structIsEmpty(current) && structKeyExists(current, "userId")) {
			variables.audit.record("USER", current.userId, "USER_SIGNED_OUT", current.userId, {});
		}
		variables.sessions.clear();
	}
}
