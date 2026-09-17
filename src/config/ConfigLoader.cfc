/**
 * Environment-driven configuration. Values come from real environment variables first, then
 * from an optional .env file (ICFWALK_ENV_FILE or <repo>/.env). No value is hard coded that
 * differs per deployment, and no secret is ever logged or echoed.
 *
 * Safety rules enforced here:
 *   - ICFWALK_ENVIRONMENT defaults to "production" so an unconfigured deployment fails closed.
 *   - The development identity stub (Phase 2) cannot be enabled in production; the application
 *     refuses to start with a configuration error (acceptance test AUTH-02).
 *   - Maintenance endpoints require an explicit enable flag and a token of at least 32
 *     characters, and are loopback-only unless explicitly allowed remotely.
 *   - The CFML test runner is never enabled in production.
 */
component output="false" {

	variables.VALID_ENVIRONMENTS = ["development", "test", "staging", "production"];
	variables.VALID_LOG_LEVELS = ["DEBUG", "INFO", "WARN", "ERROR"];

	public ConfigLoader function init(required string repoRoot) {
		variables.repoRoot = arguments.repoRoot;
		variables.system = createObject("java", "java.lang.System");
		variables.envFileValues = {};
		variables.envFileLoaded = false;
		return this;
	}

	public struct function load() {
		var cfg = {};
		var errors = [];

		cfg["repoRoot"] = variables.repoRoot;
		cfg["environment"] = lCase(value("ICFWALK_ENVIRONMENT", "production"));
		if (!arrayContains(variables.VALID_ENVIRONMENTS, cfg.environment)) {
			arrayAppend(errors, "ICFWALK_ENVIRONMENT must be one of " & arrayToList(variables.VALID_ENVIRONMENTS, ", ") & ".");
		}
		cfg["isProduction"] = cfg.environment == "production";
		cfg["datasource"] = value("ICFWALK_DATASOURCE", "icfwalk");
		cfg["logLevel"] = uCase(value("ICFWALK_LOG_LEVEL", "INFO"));
		if (!arrayContains(variables.VALID_LOG_LEVELS, cfg.logLevel)) {
			arrayAppend(errors, "ICFWALK_LOG_LEVEL must be one of " & arrayToList(variables.VALID_LOG_LEVELS, ", ") & ".");
		}
		cfg["logName"] = value("ICFWALK_LOG_NAME", "icfwalk");

		cfg["instrumentConfigPath"] = value("ICFWALK_INSTRUMENT_CONFIG_PATH", variables.repoRoot & "config/instrument-config.json");
		cfg["instrumentConfigDirectory"] = getDirectoryFromPath(cfg.instrumentConfigPath);

		cfg["maintenanceEnabled"] = boolValue("ICFWALK_MAINTENANCE_ENABLED", false);
		cfg["maintenanceAllowRemote"] = boolValue("ICFWALK_MAINTENANCE_ALLOW_REMOTE", false);
		cfg["maintenanceToken"] = value("ICFWALK_MAINTENANCE_TOKEN", "");
		if (cfg.maintenanceEnabled && len(cfg.maintenanceToken) < 32) {
			arrayAppend(errors, "ICFWALK_MAINTENANCE_TOKEN must be at least 32 characters when maintenance endpoints are enabled.");
		}

		cfg["testsEnabled"] = boolValue("ICFWALK_TESTS_ENABLED", false) && !cfg.isProduction;

		// Phase 2 seam: the development identity stub. Validated now so that production can
		// never start with it enabled, even before the stub exists.
		cfg["devIdentityEnabled"] = boolValue("ICFWALK_DEV_IDENTITY_ENABLED", false);
		if (cfg.devIdentityEnabled && cfg.isProduction) {
			arrayAppend(errors, "ICFWALK_DEV_IDENTITY_ENABLED cannot be true in the production environment.");
		}
		if (cfg.devIdentityEnabled && cfg.environment != "development" && cfg.environment != "test") {
			arrayAppend(errors, "ICFWALK_DEV_IDENTITY_ENABLED is only permitted in the development or test environment.");
		}

		// Identity / SSO seam (Phase 2). The provider itself is not specified; the adapter contract is.
		cfg["ssoMode"] = lCase(value("ICFWALK_SSO_MODE", "header"));
		cfg["ssoSubjectHeader"] = value("ICFWALK_SSO_SUBJECT_HEADER", "X-Auth-Subject");
		cfg["ssoNameHeader"] = value("ICFWALK_SSO_NAME_HEADER", "X-Auth-Name");
		cfg["ssoEmailHeader"] = value("ICFWALK_SSO_EMAIL_HEADER", "X-Auth-Email");
		cfg["ssoSecretHeader"] = value("ICFWALK_SSO_SECRET_HEADER", "X-Auth-Proxy-Secret");
		cfg["ssoSharedSecret"] = value("ICFWALK_SSO_SHARED_SECRET", "");
		cfg["ssoTrustedProxies"] = value("ICFWALK_SSO_TRUSTED_PROXIES", "");
		cfg["autoProvisionUsers"] = boolValue("ICFWALK_AUTO_PROVISION_USERS", true);
		if (cfg.ssoMode != "header" && cfg.ssoMode != "development") {
			arrayAppend(errors, "ICFWALK_SSO_MODE must be 'header' or 'development'.");
		}
		if (cfg.ssoMode == "development" && !cfg.devIdentityEnabled) {
			arrayAppend(errors, "ICFWALK_SSO_MODE=development requires ICFWALK_DEV_IDENTITY_ENABLED=true (never permitted in production).");
		}
		if (cfg.ssoMode == "header" && cfg.isProduction && !len(trim(cfg.ssoTrustedProxies))) {
			arrayAppend(errors, "ICFWALK_SSO_TRUSTED_PROXIES must list the SSO gateway/proxy addresses in production.");
		}
		if (len(cfg.ssoSharedSecret) && len(cfg.ssoSharedSecret) < 32) {
			arrayAppend(errors, "ICFWALK_SSO_SHARED_SECRET must be at least 32 characters when set.");
		}

		// Sessions and cookies.
		var timeoutMinutes = value("ICFWALK_SESSION_TIMEOUT_MINUTES", "60");
		cfg["sessionTimeoutMinutes"] = isNumeric(timeoutMinutes) && timeoutMinutes >= 5 && timeoutMinutes <= 720 ? int(timeoutMinutes) : 0;
		if (cfg.sessionTimeoutMinutes == 0) arrayAppend(errors, "ICFWALK_SESSION_TIMEOUT_MINUTES must be between 5 and 720.");
		cfg["cookieSecure"] = boolValue("ICFWALK_COOKIE_SECURE", true);
		if (!cfg.cookieSecure && cfg.isProduction) arrayAppend(errors, "ICFWALK_COOKIE_SECURE cannot be false in production.");

		// Open-decision seams (docs/OPEN_DECISIONS.md). Defaults are the documented safe defaults.
		cfg["placeholderWarningsBlockPublish"] = boolValue("ICFWALK_PLACEHOLDER_WARNINGS_BLOCK_PUBLISH", false);
		cfg["hiddenPeriodPolicy"] = value("ICFWALK_HIDDEN_PERIOD_POLICY", "RETAIN_HIDDEN");
		if (cfg.hiddenPeriodPolicy != "RETAIN_HIDDEN" && cfg.hiddenPeriodPolicy != "CLEAR") {
			arrayAppend(errors, "ICFWALK_HIDDEN_PERIOD_POLICY must be RETAIN_HIDDEN or CLEAR.");
		}
		var suppression = value("ICFWALK_REPORT_SUPPRESSION_THRESHOLD", "");
		cfg["reportSuppressionThreshold"] = len(suppression) && isNumeric(suppression) ? int(suppression) : 0;
		cfg["outboundEmailEnabled"] = false; // Not configurable: no automatic outbound mail without separate authorization.

		// Phase 3 rendering seam: until Phase 6 publishes a version, non-production deployments may
		// render the newest DRAFT snapshot. Production always requires a PUBLISHED version.
		cfg["allowUnpublishedInstrument"] = boolValue("ICFWALK_ALLOW_UNPUBLISHED_INSTRUMENT", !cfg.isProduction);
		if (cfg.allowUnpublishedInstrument && cfg.isProduction) {
			arrayAppend(errors, "ICFWALK_ALLOW_UNPUBLISHED_INSTRUMENT cannot be true in the production environment.");
		}

		if (arrayLen(errors)) {
			throw(
				type = "ICFWalk.Configuration",
				message = "Invalid ICFWalk configuration: " & arrayToList(errors, " "),
				errorcode = "CONFIGURATION_INVALID"
			);
		}
		return cfg;
	}

	/**
	 * Returns a redacted copy suitable for diagnostics. Secrets are never included.
	 */
	public struct function describe(required struct cfg) {
		return {
			"environment": arguments.cfg.environment,
			"datasource": arguments.cfg.datasource,
			"logLevel": arguments.cfg.logLevel,
			"maintenanceEnabled": arguments.cfg.maintenanceEnabled,
			"maintenanceAllowRemote": arguments.cfg.maintenanceAllowRemote,
			"testsEnabled": arguments.cfg.testsEnabled,
			"devIdentityEnabled": arguments.cfg.devIdentityEnabled,
			"ssoMode": arguments.cfg.ssoMode,
			"ssoTrustedProxiesConfigured": len(trim(arguments.cfg.ssoTrustedProxies)) > 0,
			"ssoSharedSecretConfigured": len(arguments.cfg.ssoSharedSecret) > 0,
			"autoProvisionUsers": arguments.cfg.autoProvisionUsers,
			"sessionTimeoutMinutes": arguments.cfg.sessionTimeoutMinutes,
			"cookieSecure": arguments.cfg.cookieSecure,
			"placeholderWarningsBlockPublish": arguments.cfg.placeholderWarningsBlockPublish,
			"hiddenPeriodPolicy": arguments.cfg.hiddenPeriodPolicy,
			"reportSuppressionThreshold": arguments.cfg.reportSuppressionThreshold,
			"allowUnpublishedInstrument": arguments.cfg.allowUnpublishedInstrument
		};
	}

	// ---------------------------------------------------------------------------------------
	// Lookup helpers
	// ---------------------------------------------------------------------------------------

	public string function value(required string name, string defaultValue = "") {
		var v = variables.system.getenv(arguments.name);
		if (!isNull(v) && len(v)) return v;
		loadEnvFile();
		if (structKeyExists(variables.envFileValues, arguments.name) && len(variables.envFileValues[arguments.name])) {
			return variables.envFileValues[arguments.name];
		}
		return arguments.defaultValue;
	}

	public boolean function boolValue(required string name, boolean defaultValue = false) {
		var v = lCase(trim(value(arguments.name, "")));
		if (!len(v)) return arguments.defaultValue;
		return v == "true" || v == "1" || v == "yes" || v == "on";
	}

	private void function loadEnvFile() {
		if (variables.envFileLoaded) return;
		variables.envFileLoaded = true;
		var path = variables.system.getenv("ICFWALK_ENV_FILE");
		if (isNull(path) || !len(path)) path = variables.repoRoot & ".env";
		if (!fileExists(path)) return;
		variables.envFileValues = parseEnvText(fileRead(path, "utf-8"));
	}

	/**
	 * Parses KEY=VALUE lines. Supports comments (#), optional "export " prefix, and single or
	 * double quoted values. Later duplicates win.
	 */
	public struct function parseEnvText(required string text) {
		var out = {};
		var lines = listToArray(replace(arguments.text, chr(13), "", "all"), chr(10));
		for (var line in lines) {
			line = trim(line);
			if (!len(line) || left(line, 1) == "##") continue;
			if (left(line, 7) == "export ") line = trim(mid(line, 8, len(line)));
			var eq = find("=", line);
			if (eq <= 1) continue;
			var key = trim(left(line, eq - 1));
			var raw = trim(mid(line, eq + 1, len(line)));
			if (len(raw) >= 2 && ((left(raw, 1) == '"' && right(raw, 1) == '"') || (left(raw, 1) == "'" && right(raw, 1) == "'"))) {
				raw = mid(raw, 2, len(raw) - 2);
			}
			out[key] = raw;
		}
		return out;
	}
}
