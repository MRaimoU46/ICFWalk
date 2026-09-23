component extends="icfwalktests.BaseSpec" output="false" {

	private any function loader(required struct values) {
		// Production requires an SSO proxy allowlist (covered separately in IdentityTest); supply one
		// here so the remaining rules can be exercised in isolation.
		var values = duplicate(arguments.values);
		if (!structKeyExists(values, "ICFWALK_SSO_TRUSTED_PROXIES")) values["ICFWALK_SSO_TRUSTED_PROXIES"] = "10.0.0.1";
		return createObject("component", "icfwalktests.support.StubConfigLoader").initWithValues(variables.c.repoRoot, values);
	}

	public void function testDefaultsFailClosedToProduction() {
		var cfg = loader({}).load();
		assertExactTextEquals("production", cfg.environment);
		assertTrue(cfg.isProduction);
		assertFalse(cfg.maintenanceEnabled);
		assertFalse(cfg.testsEnabled);
		assertFalse(cfg.devIdentityEnabled);
		assertFalse(cfg.outboundEmailEnabled);
		assertExactTextEquals("RETAIN_HIDDEN", cfg.hiddenPeriodPolicy);
		assertEquals(0, cfg.reportSuppressionThreshold);
		assertExactTextEquals("header", cfg.ssoMode);
		assertTrue(cfg.cookieSecure);
		assertTrue(cfg.autoProvisionUsers);
	}

	public void function testDevIdentityStubCannotBeEnabledInProduction() {
		var e = assertThrows(function() {
			loader({ "ICFWALK_ENVIRONMENT": "production", "ICFWALK_DEV_IDENTITY_ENABLED": "true" }).load();
		}, "ICFWalk.Configuration", "CONFIGURATION_INVALID");
		assertContains("ICFWALK_DEV_IDENTITY_ENABLED", e.message);
	}

	public void function testDevIdentityStubIsOnlyForDevelopmentOrTest() {
		assertThrows(function() { loader({ "ICFWALK_ENVIRONMENT": "staging", "ICFWALK_DEV_IDENTITY_ENABLED": "true" }).load(); }, "ICFWalk.Configuration");
		var cfg = loader({ "ICFWALK_ENVIRONMENT": "development", "ICFWALK_DEV_IDENTITY_ENABLED": "true" }).load();
		assertTrue(cfg.devIdentityEnabled);
	}

	public void function testUnpublishedInstrumentRenderingIsRefusedInProduction() {
		assertFalse(loader({}).load().allowUnpublishedInstrument, "Production never renders a DRAFT.");
		assertTrue(loader({ "ICFWALK_ENVIRONMENT": "development" }).load().allowUnpublishedInstrument, "Development defaults to the DRAFT fallback.");
		assertFalse(loader({ "ICFWALK_ENVIRONMENT": "development", "ICFWALK_ALLOW_UNPUBLISHED_INSTRUMENT": "false" }).load().allowUnpublishedInstrument);
		var e = assertThrows(function() {
			loader({ "ICFWALK_ENVIRONMENT": "production", "ICFWALK_ALLOW_UNPUBLISHED_INSTRUMENT": "true" }).load();
		}, "ICFWalk.Configuration", "CONFIGURATION_INVALID");
		assertContains("ICFWALK_ALLOW_UNPUBLISHED_INSTRUMENT", e.message);
	}

	public void function testMaintenanceRequiresLongToken() {
		assertThrows(function() { loader({ "ICFWALK_MAINTENANCE_ENABLED": "true", "ICFWALK_MAINTENANCE_TOKEN": "short" }).load(); }, "ICFWalk.Configuration");
		var cfg = loader({ "ICFWALK_MAINTENANCE_ENABLED": "true", "ICFWALK_MAINTENANCE_TOKEN": repeatString("x", 40) }).load();
		assertTrue(cfg.maintenanceEnabled);
	}

	public void function testTestRunnerIsNeverEnabledInProduction() {
		var cfg = loader({ "ICFWALK_ENVIRONMENT": "production", "ICFWALK_TESTS_ENABLED": "true" }).load();
		assertFalse(cfg.testsEnabled);
		var dev = loader({ "ICFWALK_ENVIRONMENT": "development", "ICFWALK_TESTS_ENABLED": "true" }).load();
		assertTrue(dev.testsEnabled);
	}

	public void function testInvalidEnvironmentAndLogLevelAreRejected() {
		assertThrows(function() { loader({ "ICFWALK_ENVIRONMENT": "prod" }).load(); }, "ICFWalk.Configuration");
		assertThrows(function() { loader({ "ICFWALK_LOG_LEVEL": "TRACE" }).load(); }, "ICFWalk.Configuration");
	}

	/**
	 * Phase 7 made the suppression threshold operative, so a malformed value must refuse startup
	 * rather than quietly apply no suppression. Empty and 0 remain the undecided default (none).
	 */
	public void function testReportSuppressionThresholdIsAWholeNumberOrRefused() {
		assertEquals(0, loader({}).load().reportSuppressionThreshold, "unset applies no suppression");
		assertEquals(0, loader({ "ICFWALK_REPORT_SUPPRESSION_THRESHOLD": "0" }).load().reportSuppressionThreshold);
		assertEquals(5, loader({ "ICFWALK_REPORT_SUPPRESSION_THRESHOLD": "5" }).load().reportSuppressionThreshold);
		assertEquals(11, loader({ "ICFWALK_REPORT_SUPPRESSION_THRESHOLD": " 11 " }).load().reportSuppressionThreshold);
		for (var bad in ["5 walks", "-3", "2.5", "five", "1e3", "0x10", "1234567"]) {
			var e = assertThrows(function() {
				loader({ "ICFWALK_REPORT_SUPPRESSION_THRESHOLD": bad }).load();
			}, "ICFWalk.Configuration", "CONFIGURATION_INVALID");
			assertContains("ICFWALK_REPORT_SUPPRESSION_THRESHOLD", e.message, "[" & bad & "] is refused by name");
		}
	}

	public void function testEnvFileParsing() {
		var parsed = loader({}).parseEnvText("## comment" & chr(10) & "A=1" & chr(10) & 'export B="two words"' & chr(10) & "C='single'" & chr(10) & "bad line" & chr(10) & "D=" & chr(10) & "E=x=y");
		assertExactTextEquals("1", parsed.A);
		assertExactTextEquals("two words", parsed.B);
		assertExactTextEquals("single", parsed.C);
		assertExactTextEquals("", parsed.D);
		assertExactTextEquals("x=y", parsed.E);
		assertFalse(structKeyExists(parsed, "bad line"));
	}

	public void function testDescribeOmitsSecrets() {
		var l = loader({ "ICFWALK_MAINTENANCE_ENABLED": "true", "ICFWALK_MAINTENANCE_TOKEN": repeatString("s", 40), "ICFWALK_DB_PASSWORD": "hunter22hunter22" });
		var described = serializeJSON(l.describe(l.load()));
		assertFalse(find("ssssssss", described) > 0, "Token leaked into describe().");
		assertFalse(find("hunter22", described) > 0, "Password leaked into describe().");
	}
}
