/**
 * Identity adapters, provisioning, sessions, and configuration guards (AUTH-01/AUTH-02 seams).
 */
component extends="icfwalktests.BaseSpec" output="false" {

	public string function skipReason() {
		return schemaPresent() ? "" : "icf schema is not present.";
	}

	public void function beforeAll() {
		variables.fx = createObject("component", "icfwalktests.support.Fixtures").init(variables.c, "ident-" & lCase(left(replace(createUUID(), "-", "", "all"), 8)));
	}

	public void function afterAll() {
		variables.fx.remove();
	}

	private struct function headerConfig(struct overrides = {}) {
		var cfg = duplicate(variables.c.config);
		cfg["ssoMode"] = "header";
		cfg["ssoSubjectHeader"] = "X-Auth-Subject";
		cfg["ssoNameHeader"] = "X-Auth-Name";
		cfg["ssoEmailHeader"] = "X-Auth-Email";
		cfg["ssoSecretHeader"] = "X-Auth-Proxy-Secret";
		cfg["ssoSharedSecret"] = "";
		cfg["ssoTrustedProxies"] = "10.0.0.5, 192.168.10.0/24";
		for (var k in structKeyArray(arguments.overrides)) cfg[k] = arguments.overrides[k];
		return cfg;
	}

	private struct function req(struct headers = {}, string remote = "10.0.0.5") {
		return { "headers": arguments.headers, "remoteAddress": arguments.remote, "method": "GET", "path": "/api/me", "body": {}, "params": [], "query": {} };
	}

	// ---- header (SSO gateway) adapter -------------------------------------------------------------

	public void function testHeaderProviderTrustsOnlyListedProxies() {
		var provider = new icfwalk.identity.HeaderIdentityProvider(headerConfig(), variables.c.logger);
		var ok = provider.resolve(req({ "x-auth-subject": "sso|abc123", "x-auth-name": "Fixture Person", "x-auth-email": "fixture@example.org" }, "10.0.0.5"));
		assertTrue(ok.authenticated);
		assertEquals("sso|abc123", ok.subject);
		assertEquals("Fixture Person", ok.displayName);
		assertEquals("fixture@example.org", ok.email);
		var cidr = provider.resolve(req({ "x-auth-subject": "sso|abc123" }, "192.168.10.77"));
		assertTrue(cidr.authenticated, "CIDR block member trusted.");
		var spoof = provider.resolve(req({ "x-auth-subject": "sso|attacker" }, "203.0.113.9"));
		assertFalse(spoof.authenticated);
		assertEquals("untrusted_source", spoof.reason);
		var outsideCidr = provider.resolve(req({ "x-auth-subject": "sso|abc123" }, "192.168.11.1"));
		assertFalse(outsideCidr.authenticated);
	}

	public void function testHeaderProviderWithNoProxyListTrustsNobody() {
		var provider = new icfwalk.identity.HeaderIdentityProvider(headerConfig({ "ssoTrustedProxies": "" }), variables.c.logger);
		assertFalse(provider.resolve(req({ "x-auth-subject": "sso|abc123" }, "127.0.0.1")).authenticated);
	}

	public void function testHeaderProviderRequiresSharedSecretWhenConfigured() {
		var secret = repeatString("s", 40);
		var provider = new icfwalk.identity.HeaderIdentityProvider(headerConfig({ "ssoSharedSecret": secret }), variables.c.logger);
		assertFalse(provider.resolve(req({ "x-auth-subject": "sso|abc123" })).authenticated);
		assertFalse(provider.resolve(req({ "x-auth-subject": "sso|abc123", "x-auth-proxy-secret": "wrong" })).authenticated);
		assertTrue(provider.resolve(req({ "x-auth-subject": "sso|abc123", "x-auth-proxy-secret": secret })).authenticated);
	}

	public void function testHeaderProviderRejectsMissingOrMalformedSubjects() {
		var provider = new icfwalk.identity.HeaderIdentityProvider(headerConfig(), variables.c.logger);
		assertFalse(provider.resolve(req({})).authenticated);
		assertFalse(provider.resolve(req({ "x-auth-subject": "bad" & chr(10) & "subject" })).authenticated);
		assertFalse(provider.resolve(req({ "x-auth-subject": repeatString("x", 300) })).authenticated);
		var noEmail = provider.resolve(req({ "x-auth-subject": "sso|1", "x-auth-email": "not-an-email" }));
		assertTrue(noEmail.authenticated);
		assertEquals("", noEmail.email);
	}

	// ---- development stub and factory guards ---------------------------------------------------

	public void function testDevelopmentStubCannotBeConstructedWhenNotPermitted() {
		var cfg = duplicate(variables.c.config);
		cfg["devIdentityEnabled"] = false;
		var logger = variables.c.logger;
		assertThrows(function() { new icfwalk.identity.DevelopmentIdentityProvider(cfg, logger); }, "ICFWalk.Configuration", "DEV_IDENTITY_NOT_PERMITTED");
		var prod = duplicate(variables.c.config);
		prod["devIdentityEnabled"] = true;
		prod["isProduction"] = true;
		assertThrows(function() { new icfwalk.identity.DevelopmentIdentityProvider(prod, logger); }, "ICFWalk.Configuration", "DEV_IDENTITY_NOT_PERMITTED");
		var factoryCfg = duplicate(variables.c.config);
		factoryCfg["ssoMode"] = "development";
		factoryCfg["devIdentityEnabled"] = false;
		assertThrows(function() { new icfwalk.identity.IdentityProviderFactory(factoryCfg, logger).build(); }, "ICFWalk.Configuration", "DEV_IDENTITY_NOT_PERMITTED");
		var unknown = duplicate(variables.c.config);
		unknown["ssoMode"] = "saml";
		assertThrows(function() { new icfwalk.identity.IdentityProviderFactory(unknown, logger).build(); }, "ICFWalk.Configuration", "SSO_MODE_UNSUPPORTED");
	}

	public void function testDevelopmentStubReadsOnlyItsOwnHeaders() {
		var cfg = duplicate(variables.c.config);
		cfg["devIdentityEnabled"] = true;
		cfg["isProduction"] = false;
		var provider = new icfwalk.identity.DevelopmentIdentityProvider(cfg, variables.c.logger);
		assertFalse(provider.resolve(req({ "x-auth-subject": "sso|abc" })).authenticated, "SSO headers are ignored by the stub.");
		var ok = provider.resolve(req({ "x-icfwalk-dev-subject": "dev-user-1", "x-icfwalk-dev-name": "Dev User" }));
		assertTrue(ok.authenticated);
		assertEquals("dev-user-1", ok.subject);
		assertFalse(provider.resolve(req({ "x-icfwalk-dev-subject": "bad subject with spaces" })).authenticated);
	}

	public void function testConfigLoaderRejectsUnsafeIdentitySettings() {
		var loader = function(values) { return createObject("component", "icfwalktests.support.StubConfigLoader").initWithValues(variables.c.repoRoot, values); };
		assertThrows(function() { loader({ "ICFWALK_SSO_MODE": "development" }).load(); }, "ICFWalk.Configuration");
		assertThrows(function() { loader({ "ICFWALK_ENVIRONMENT": "production", "ICFWALK_SSO_MODE": "development", "ICFWALK_DEV_IDENTITY_ENABLED": "true" }).load(); }, "ICFWalk.Configuration");
		assertThrows(function() { loader({ "ICFWALK_ENVIRONMENT": "production", "ICFWALK_SSO_MODE": "header" }).load(); }, "ICFWalk.Configuration");
		assertThrows(function() { loader({ "ICFWALK_ENVIRONMENT": "production", "ICFWALK_SSO_TRUSTED_PROXIES": "10.0.0.1", "ICFWALK_COOKIE_SECURE": "false" }).load(); }, "ICFWalk.Configuration");
		assertThrows(function() { loader({ "ICFWALK_SSO_MODE": "oidc" }).load(); }, "ICFWalk.Configuration");
		var ok = loader({ "ICFWALK_ENVIRONMENT": "production", "ICFWALK_SSO_TRUSTED_PROXIES": "10.0.0.1", "ICFWALK_SSO_SHARED_SECRET": repeatString("k", 40) }).load();
		assertEquals("header", ok.ssoMode);
		assertTrue(ok.cookieSecure);
		assertEquals(60, ok.sessionTimeoutMinutes);
	}

	// ---- provisioning ----------------------------------------------------------------------------

	public void function testProvisioningIsKeyedBySubjectAndTolerantOfEmailCollisions() {
		var users = variables.c.userRepository;
		var a = variables.fx.user("prov-a");
		assertTrue(len(a.userId) == 36);
		assertEquals(variables.fx.tag() & "-prov-a", a.subject);
		assertTrue(a.active);
		var again = users.findBySubject(a.subject);
		assertEquals(a.userId, again.userId, "Lookup by subject returns the same account.");
		users.recordSignIn(a.userId, "Renamed Fixture", "shared@example.org");
		var b = users.provision(variables.fx.tag() & "-prov-b", "Fixture B", "shared@example.org");
		assertEquals("", b.email, "Colliding email is not stored twice.");
		variables.c.db.run("DELETE FROM [icf].[app_user] WHERE user_id = :id", { "id": variables.c.db.guid(b.userId) });
		assertEquals("Renamed Fixture", users.findById(a.userId).displayName);
	}

	public void function testInactiveUserIsRejectedByAuthentication() {
		var u = variables.fx.user("inactive", false);
		var cfg = duplicate(variables.c.config);
		cfg["devIdentityEnabled"] = true;
		cfg["isProduction"] = false;
		var provider = new icfwalk.identity.DevelopmentIdentityProvider(cfg, variables.c.logger);
		var svc = new icfwalk.identity.AuthenticationService(cfg, variables.c.logger, provider, variables.c.userRepository, variables.c.sessionService, variables.c.authorizationService, variables.c.auditRepository, variables.c.errors);
		var subject = u.subject;
		assertThrows(function() { svc.authenticate(req({ "x-icfwalk-dev-subject": subject })); }, "ICFWalk.Unauthenticated", "USER_INACTIVE");
		assertThrows(function() { svc.authenticate(req({})); }, "ICFWalk.Unauthenticated");
	}

	public void function testAuthenticationProvisionsAndBuildsPrincipal() {
		var cfg = duplicate(variables.c.config);
		cfg["devIdentityEnabled"] = true;
		cfg["isProduction"] = false;
		cfg["autoProvisionUsers"] = true;
		var provider = new icfwalk.identity.DevelopmentIdentityProvider(cfg, variables.c.logger);
		var svc = new icfwalk.identity.AuthenticationService(cfg, variables.c.logger, provider, variables.c.userRepository, variables.c.sessionService, variables.c.authorizationService, variables.c.auditRepository, variables.c.errors);
		var subject = variables.fx.tag() & "-jit";
		var principal = svc.authenticate(req({ "x-icfwalk-dev-subject": subject, "x-icfwalk-dev-name": "JIT User" }));
		assertEquals(subject, principal.subject);
		assertEquals(0, arrayLen(principal.assignments), "A newly provisioned user has no roles.");
		assertFalse(principal.permissions["instrument.manage"]);
		var user = variables.c.userRepository.findBySubject(subject);
		assertTrue(isDate(user.lastSignInAt));
		assertEquals(1, variables.c.db.scalar("SELECT COUNT(*) AS n FROM [icf].[audit_event] WHERE entity_id = :id AND event_type = N'USER_PROVISIONED'", { "id": variables.c.db.guid(user.userId) }));
		assertTrue(variables.c.db.scalar("SELECT COUNT(*) AS n FROM [icf].[audit_event] WHERE entity_id = :id AND event_type = N'USER_SIGNED_IN'", { "id": variables.c.db.guid(user.userId) }) >= 1);
		assertTrue(len(variables.c.sessionService.csrfToken()) == 64, "Session CSRF token established at sign-in.");
		assertTrue(variables.c.sessionService.csrfTokenValid(variables.c.sessionService.csrfToken()));
		assertFalse(variables.c.sessionService.csrfTokenValid("0000"));
		// Cleanup of the JIT user (created outside the fixture registry).
		variables.c.db.run("DELETE FROM [icf].[audit_event] WHERE entity_id = :id OR actor_user_id = :id", { "id": variables.c.db.guid(user.userId) });
		variables.c.db.run("DELETE FROM [icf].[app_user] WHERE user_id = :id", { "id": variables.c.db.guid(user.userId) });
		var strict = duplicate(cfg);
		strict["autoProvisionUsers"] = false;
		var strictSvc = new icfwalk.identity.AuthenticationService(strict, variables.c.logger, provider, variables.c.userRepository, variables.c.sessionService, variables.c.authorizationService, variables.c.auditRepository, variables.c.errors);
		assertThrows(function() { strictSvc.authenticate(req({ "x-icfwalk-dev-subject": subject & "-unknown" })); }, "ICFWalk.Unauthenticated", "USER_NOT_PROVISIONED");
	}
}
