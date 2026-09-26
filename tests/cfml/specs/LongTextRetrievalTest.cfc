/**
 * Phase 8, defect P8-04: long text must come back whole.
 *
 * Adobe ColdFusion returns only the first 32,000 characters of an nvarchar(max) value unless the
 * datasource has "Enable long text retrieval (CLOB)" on (disable_clob = false). The compiled instrument
 * snapshot is about 218,000 characters, so under the default setting every snapshot read failed its
 * checksum and nothing could render or save; mutation replay records and revision snapshots can pass
 * 32,000 characters too. Lucee returns long text whole.
 *
 * The first case is the datasource itself. The others are the health check that makes a truncating
 * datasource visible: it answers 503 with `longText: "truncated"` instead of 200.
 */
component extends="icfwalktests.BaseSpec" output="false" {

	public string function skipReason() {
		return schemaPresent() ? "" : "database schema not applied";
	}

	public void function testTheDatasourceReturnsLongTextWhole() {
		var q = variables.c.db.run("SELECT REPLICATE(CAST(N'x' AS nvarchar(max)), 300000) + N'!' AS v");
		assertEquals(300001, len(q.v[1]), "a 300,001-character value is read back whole");
		assertExactTextEquals("!", right(q.v[1], 1), "including its last character");
	}

	public void function testTheHealthCheckReportsWholeLongText() {
		var health = new icfwalk.controllers.HealthController(variables.c.config, variables.c.db, variables.c.requestContext);
		var r = health.get({});
		assertEquals(200, r.status);
		assertExactTextEquals("ok", r.body.checks.longText);
		assertExactTextEquals("ok", r.body.status);
	}

	public void function testTheHealthCheckRefusesADatasourceThatTruncatesLongText() {
		var truncating = createObject("component", "icfwalktests.support.TruncatingDb").init(variables.c.db, 32000);
		var health = new icfwalk.controllers.HealthController(variables.c.config, truncating, variables.c.requestContext);
		var r = health.get({});
		assertEquals(503, r.status, "a load balancer takes the node out");
		assertExactTextEquals("truncated", r.body.checks.longText);
		assertExactTextEquals("degraded", r.body.status);
		assertExactTextEquals("ok", r.body.checks.database, "the database itself answers");
	}
}
