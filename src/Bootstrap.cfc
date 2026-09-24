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
		c["definitionRepository"] = new icfwalk.instrument.DefinitionRepository(c.db, c.canonicalJson, c.errors);
		c["configNormalizer"] = new icfwalk.instrument.ConfigNormalizer();
		// The one authoritative semantic rule set over normalized definitions. Import runs it on
		// every document it accepts and publish runs it on the locked version's snapshot and rows,
		// so the two cannot drift into accepting what the other refuses.
		c["definitionValidator"] = new icfwalk.instrument.DefinitionValidator();
		c["configValidator"] = new icfwalk.instrument.InstrumentConfigValidator(c.errors, c.configNormalizer, c.definitionValidator);
		c["snapshotCompiler"] = new icfwalk.instrument.SnapshotCompiler(c.canonicalJson, c.definitionValidator);
		// The runtime renderer, and the preflight that runs it. Both import and publish build the
		// snapshot through the real builder before accepting it, so a version that passes the
		// semantic rules but the renderer cannot build is refused rather than frozen.
		c["renderModelBuilder"] = new icfwalk.instrument.RenderModelBuilder(c.definitionValidator);
		c["renderContractValidator"] = new icfwalk.instrument.RenderContractValidator(c.renderModelBuilder);
		c["instrumentImportService"] = new icfwalk.instrument.InstrumentImportService(
			c.config, c.db, c.errors, c.logger, c.definitionRepository, c.auditRepository,
			c.configNormalizer, c.configValidator, c.snapshotCompiler, c.requestContext,
			c.renderContractValidator
		);
		// Publishing (Phase 6). Freezes a DRAFT into an immutable PUBLISHED version and is the
		// single guard for "a non-DRAFT version is never written to" (ADM-05).
		c["instrumentPublishService"] = new icfwalk.instrument.InstrumentPublishService(
			c.config, c.db, c.errors, c.logger, c.definitionRepository, c.auditRepository,
			c.canonicalJson, c.snapshotCompiler, c.definitionValidator, c.renderContractValidator
		);
		c["responder"] = new icfwalk.http.Responder(c.config, c.logger, c.canonicalJson, c.requestContext);

		// Instrument engine (Phase 3): visibility rules from the compiled snapshot. The render model
		// builder itself is constructed above, because import and publish preflight through it.
		c["visibilityEngine"] = new icfwalk.instrument.VisibilityEngine();
		c["maintenanceGuard"] = new icfwalk.http.MaintenanceGuard(c.config, c.logger, c.errors, c.auditRepository, c.requestContext);

		// Identity, roles, and scope (Phase 2).
		c["userRepository"] = new icfwalk.identity.UserRepository(c.db);
		c["orgUnitRepository"] = new icfwalk.authorization.OrgUnitRepository(c.db);
		c["roleScopeRepository"] = new icfwalk.authorization.RoleScopeRepository(c.db);
		c["authorizationService"] = new icfwalk.authorization.AuthorizationService(c.db, c.orgUnitRepository, c.roleScopeRepository, c.auditRepository, c.logger, c.errors);
		// The only operation that writes the shared icf.instrument row, constructed HERE rather than
		// beside the other instrument services because its authorization dependency is real: it asks
		// AuthorizationService for global instrument.manage before any mutation, so it cannot be
		// built before the authorization model exists. Deliberately not routed -- this pass closes
		// the write boundary and adds no administration UI for it -- and the lack of a route is a
		// scope decision, not the security control.
		c["instrumentMetadataService"] = new icfwalk.instrument.InstrumentMetadataService(
			c.db, c.errors, c.logger, c.definitionRepository, c.auditRepository, c.authorizationService
		);
		c["sessionService"] = new icfwalk.identity.SessionService(c.config);
		c["identityProvider"] = new icfwalk.identity.IdentityProviderFactory(c.config, c.logger).build();
		c["authenticationService"] = new icfwalk.identity.AuthenticationService(c.config, c.logger, c.identityProvider, c.userRepository, c.sessionService, c.authorizationService, c.auditRepository, c.errors);

		c["snapshotService"] = new icfwalk.instrument.SnapshotService(c.config, c.db, c.definitionRepository, c.renderModelBuilder, c.errors, c.logger, c.canonicalJson);

		// Instrument administration (Phase 6): preview, clone, wording edits, compare and the
		// placeholder queue. Clone and edit write through InstrumentImportService's one validated
		// DRAFT write path; every read is of a checksum-verified snapshot through SnapshotService.
		c["draftEditor"] = new icfwalk.instrument.DraftEditor(c.definitionValidator.placeholderReviewStatus());
		c["instrumentVersionComparer"] = new icfwalk.instrument.InstrumentVersionComparer(c.canonicalJson);
		c["instrumentAdminService"] = new icfwalk.instrument.InstrumentAdminService(
			c.config, c.db, c.errors, c.logger, c.definitionRepository, c.snapshotService,
			c.instrumentImportService, c.draftEditor, c.instrumentVersionComparer, c.snapshotCompiler
		);

		// Walk persistence (Phase 4).
		c["walkRepository"] = new icfwalk.walks.WalkRepository(c.db, c.canonicalJson, c.definitionRepository);
		c["walkPayloadValidator"] = new icfwalk.walks.WalkPayloadValidator(c.errors, c.canonicalJson);
		// Summary export and teacher email draft (Phase 5). The formatter is pure: no database, no
		// request scope, no logging, so it is a plain singleton shared by every walk.
		c["walkSummaryFormatter"] = new icfwalk.walks.WalkSummaryFormatter();
		c["walkService"] = new icfwalk.walks.WalkService(
			c.config, c.db, c.errors, c.logger, c.auditRepository, c.canonicalJson, c.authorizationService,
			c.snapshotService, c.visibilityEngine, c.walkRepository, c.walkPayloadValidator, c.orgUnitRepository,
			c.walkSummaryFormatter
		);

		// Aggregate reporting (Phase 7). Reads walks through its own repository, which selects no
		// narrative or identifying column; scope, versions and visibility come from the services
		// above rather than being re-derived.
		c["reportRepository"] = new icfwalk.reports.ReportRepository(c.db);
		c["reportService"] = new icfwalk.reports.ReportService(
			c.config, c.db, c.errors, c.logger, c.auditRepository, c.canonicalJson, c.authorizationService,
			c.snapshotService, c.visibilityEngine, c.walkRepository, c.orgUnitRepository, c.reportRepository
		);

		c["healthController"] = new icfwalk.controllers.HealthController(c.config, c.db, c.requestContext);
		c["shellController"] = new icfwalk.controllers.ShellController(c);
		c["instrumentController"] = new icfwalk.controllers.InstrumentController(c);
		c["authController"] = new icfwalk.controllers.AuthController(c);
		c["walkController"] = new icfwalk.controllers.WalkController(c);
		c["adminInstrumentController"] = new icfwalk.controllers.AdminInstrumentController(c);
		c["reportController"] = new icfwalk.controllers.ReportController(c);
		c["maintenanceController"] = new icfwalk.controllers.MaintenanceController(c);
		c["router"] = new icfwalk.http.Router(c);
		c.logger.info("application.started", {
			"environment": c.config.environment,
			"engine": c.healthController.engineDescription(),
			"identityProvider": c.identityProvider.name(),
			"maintenanceEnabled": c.config.maintenanceEnabled,
			"testsEnabled": c.config.testsEnabled
		});
		return c;
	}
}
