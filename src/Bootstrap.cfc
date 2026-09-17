/**
 * Builds the application container: configuration, cross-cutting services, repositories,
 * services, and controllers. Everything is a singleton stored in application.icf. Keeping
 * construction here makes the dependency graph explicit and testable without a framework.
 */
component output="false" {

	public Bootstrap function init(required string repoRoot, required string appRoot) {
		variables.repoRoot = arguments.repoRoot;
		variables.appRoot = arguments.appRoot;
		return this;
	}

	public struct function build() {
		var c = {};
		c["repoRoot"] = variables.repoRoot;
		c["appRoot"] = variables.appRoot;
		c["startedAt"] = now();
		c["config"] = new icfwalk.config.ConfigLoader(variables.repoRoot).load();
		c["errors"] = new icfwalk.core.Errors();
		c["canonicalJson"] = new icfwalk.core.CanonicalJson();
		c["logger"] = new icfwalk.core.Logger(c.config, c.canonicalJson);
		c["requestContext"] = new icfwalk.core.RequestContext(c.logger);
		c["db"] = new icfwalk.core.Db(c.config.datasource);
		c["auditRepository"] = new icfwalk.audit.AuditRepository(c.db, c.canonicalJson, c.requestContext);
		c["definitionRepository"] = new icfwalk.instrument.DefinitionRepository(c.db, c.canonicalJson);
		c["configNormalizer"] = new icfwalk.instrument.ConfigNormalizer();
		c["configValidator"] = new icfwalk.instrument.InstrumentConfigValidator(c.errors);
		c["snapshotCompiler"] = new icfwalk.instrument.SnapshotCompiler(c.canonicalJson);
		c["instrumentImportService"] = new icfwalk.instrument.InstrumentImportService(
			c.config, c.db, c.errors, c.logger, c.definitionRepository, c.auditRepository,
			c.configNormalizer, c.configValidator, c.snapshotCompiler, c.requestContext
		);
		c["responder"] = new icfwalk.http.Responder(c.config, c.logger, c.canonicalJson, c.requestContext);
		c["maintenanceGuard"] = new icfwalk.http.MaintenanceGuard(c.config, c.logger, c.errors, c.auditRepository, c.requestContext);
		c["healthController"] = new icfwalk.controllers.HealthController(c.config, c.db, c.requestContext);
		c["maintenanceController"] = new icfwalk.controllers.MaintenanceController(c);
		c["router"] = new icfwalk.http.Router(c);
		c.logger.info("application.started", {
			"environment": c.config.environment,
			"engine": c.healthController.engineDescription(),
			"maintenanceEnabled": c.config.maintenanceEnabled,
			"testsEnabled": c.config.testsEnabled
		});
		return c;
	}
}
