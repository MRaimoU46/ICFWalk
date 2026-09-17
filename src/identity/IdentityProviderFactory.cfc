/**
 * Builds the configured identity adapter (ICFWALK_SSO_MODE). Unknown modes fail at startup; the
 * development stub is only constructible when the configuration allows it.
 */
component output="false" {

	public IdentityProviderFactory function init(required struct config, required any logger) {
		variables.config = arguments.config;
		variables.logger = arguments.logger;
		return this;
	}

	public any function build() {
		switch (variables.config.ssoMode) {
			case "header":
				return new icfwalk.identity.HeaderIdentityProvider(variables.config, variables.logger);
			case "development":
				if (!variables.config.devIdentityEnabled || variables.config.isProduction) {
					throw(type = "ICFWalk.Configuration", message = "ICFWALK_SSO_MODE=development requires ICFWALK_DEV_IDENTITY_ENABLED=true outside production.", errorcode = "DEV_IDENTITY_NOT_PERMITTED");
				}
				variables.logger.warn("identity.development_stub_active", { "environment": variables.config.environment });
				return new icfwalk.identity.DevelopmentIdentityProvider(variables.config, variables.logger);
		}
		throw(type = "ICFWalk.Configuration", message = "Unsupported ICFWALK_SSO_MODE '" & variables.config.ssoMode & "'. Supported: header, development.", errorcode = "SSO_MODE_UNSUPPORTED");
	}
}
