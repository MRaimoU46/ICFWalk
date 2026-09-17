/**
 * Operator maintenance tasks: import/seed the instrument configuration, list versions, discard a
 * DRAFT, and run the CFML test suite. All actions pass the MaintenanceGuard first. Production
 * administration of instrument versions by signed-in administrators arrives in Phase 6; this
 * controller exists so a clean install can be seeded and verified without a user session.
 */
component output="false" {

	public MaintenanceController function init(required struct container) {
		variables.c = arguments.container;
		return this;
	}

	public struct function importInstrument(required struct req) {
		variables.c.maintenanceGuard.require(arguments.req, "instrument.import");
		var path = variables.c.config.instrumentConfigPath;
		if (structKeyExists(arguments.req.body, "configFile") && len(trim(arguments.req.body.configFile))) {
			path = variables.c.instrumentImportService.resolveConfigFile(arguments.req.body.configFile);
		}
		var result = variables.c.instrumentImportService.importFromFile(path);
		return { "status": result.created ? 201 : 200, "body": result };
	}

	public struct function listVersions(required struct req) {
		variables.c.maintenanceGuard.require(arguments.req, "instrument.versions");
		return { "status": 200, "body": { "versions": variables.c.definitionRepository.listVersions() } };
	}

	public struct function discardDraft(required struct req) {
		variables.c.maintenanceGuard.require(arguments.req, "instrument.discardDraft");
		if (!structKeyExists(arguments.req.body, "versionLabel") || !len(trim(arguments.req.body.versionLabel))) {
			variables.c.errors.validation("versionLabel is required.", "VERSION_LABEL_REQUIRED");
		}
		var result = variables.c.instrumentImportService.discardDraft(arguments.req.body.versionLabel);
		return { "status": 200, "body": result };
	}

	public struct function runTests(required struct req) {
		variables.c.maintenanceGuard.require(arguments.req, "tests.run");
		if (!variables.c.config.testsEnabled) {
			variables.c.errors.notFound();
		}
		var filter = structKeyExists(arguments.req.query, "filter") ? arguments.req.query.filter : "";
		var runner = createObject("component", "icfwalktests.TestRunner").init(variables.c);
		var results = runner.run(filter);
		return { "status": 200, "body": results };
	}
}
