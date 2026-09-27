/**
 * Finding A8-01 (Phase 8 independent audit): the readiness contract of GET /api/health.
 *
 * docs/OPERATIONS.md names /index.cfm/api/health as the load balancer's readiness probe. A node is
 * ready, HTTP 200 with status "ok", only when all three checks pass: the database answers
 * (checks.database "ok"), the ICFWalk schema is there (checks.schema "present") and long text comes
 * back whole (checks.longText "ok"). Every other combination is HTTP 503 with status "degraded".
 *
 * Before the correction the check ignored the schema: a reachable database without it (a new database
 * before migration 001, or a datasource pointed at the wrong database) answered 200 "ok", so a load
 * balancer would have sent walkers to a node that fails every request.
 *
 * Every case builds its own HealthController, because the long text check keeps its result per
 * instance, and asserts the HTTP status first, then the body's status, all three checks and the
 * correlation id. The doubles are in tests/cfml/support: SchemaAbsentDb (the database answers, and SQL
 * Server reports no [icf].[instrument]) and TruncatingDb (P8-04: long text cut to 32,000 characters).
 * An unreachable database is a Db on a datasource that does not exist, so what the check catches is
 * the engine's own database error.
 */
component extends="icfwalktests.BaseSpec" output="false" {

	// Every double but the unreachable one delegates to the real database, which must hold the schema
	// for the "present" cases to mean anything.
	public string function skipReason() {
		return schemaPresent() ? "" : "database schema not applied";
	}

	// ---- the regression ---------------------------------------------------------------------------

	public void function testAReachableDatabaseWithoutTheSchemaIsNotReady() {
		var absent = createObject("component", "icfwalktests.support.SchemaAbsentDb").init(variables.c.db);
		var r = healthOf(absent);
		assertEquals(1, absent.schemaProbes(), "the schema probe reached SQL Server, naming a table that does not exist");
		assertReadiness(r, 503, "degraded", "ok", "missing", "ok");
	}

	public void function testProductionAnswersTheSameWithoutTheSchemaAndNamesNothing() {
		var absent = createObject("component", "icfwalktests.support.SchemaAbsentDb").init(variables.c.db);
		var r = healthOf(absent, true);
		assertReadiness(r, 503, "degraded", "ok", "missing", "ok");
		assertExactTextEquals("application,checks,correlationId,status", keysOf(r.body), "production names no environment and no engine");
		assertExactTextEquals("database,longText,schema", keysOf(r.body.checks));
	}

	// ---- the rest of the contract -------------------------------------------------------------------

	public void function testTheDatabaseWithItsSchemaAndWholeLongTextIsReady() {
		assertReadiness(healthOf(variables.c.db), 200, "ok", "ok", "present", "ok");
	}

	public void function testTruncatedLongTextIsNotReadyEvenWithTheSchema() {
		var truncating = createObject("component", "icfwalktests.support.TruncatingDb").init(variables.c.db, 32000);
		assertReadiness(healthOf(truncating), 503, "degraded", "ok", "present", "truncated");
	}

	public void function testAnUnreachableDatabaseIsNotReady() {
		var unreachable = new icfwalk.core.Db("icfwalk_a8_01_no_such_datasource");
		assertReadiness(healthOf(unreachable), 503, "degraded", "unavailable", "unknown", "unknown");
	}

	public void function testWithoutTheSchemaAndWithTruncatedLongTextItIsNotReady() {
		var truncating = createObject("component", "icfwalktests.support.TruncatingDb").init(variables.c.db, 32000);
		var absent = createObject("component", "icfwalktests.support.SchemaAbsentDb").init(truncating);
		assertReadiness(healthOf(absent), 503, "degraded", "ok", "missing", "truncated");
	}

	// ---- support --------------------------------------------------------------------------------------

	private struct function healthOf(required any db, boolean production = false) {
		var cfg = duplicate(variables.c.config);
		if (arguments.production) {
			cfg["isProduction"] = true;
			cfg["environment"] = "production";
		}
		return new icfwalk.controllers.HealthController(cfg, arguments.db, variables.c.requestContext).get({});
	}

	private void function assertReadiness(required struct r, required numeric httpStatus, required string overall, required string database, required string schema, required string longText) {
		var seen = variables.c.canonicalJson.serialize(arguments.r.body);
		assertEquals(arguments.httpStatus, arguments.r.status, "HTTP status for " & seen);
		assertExactTextEquals(arguments.overall, arguments.r.body.status, "status");
		assertExactTextEquals(arguments.database, arguments.r.body.checks.database, "checks.database");
		assertExactTextEquals(arguments.schema, arguments.r.body.checks.schema, "checks.schema");
		assertExactTextEquals(arguments.longText, arguments.r.body.checks.longText, "checks.longText");
		assertExactTextEquals(variables.c.requestContext.correlationId(), arguments.r.body.correlationId, "the request's correlation id");
	}

	private string function keysOf(required struct s) {
		var keys = structKeyArray(arguments.s);
		arraySort(keys, "textnocase");
		return arrayToList(keys);
	}
}
