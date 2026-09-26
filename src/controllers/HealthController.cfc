/**
 * Liveness/readiness endpoint. Reports whether the database answers; never reports configuration
 * values or secrets. Returns 503 when the database is unavailable so load balancers can react.
 */
component output="false" {

	// A datasource that truncates long text (Adobe ColdFusion without "Enable long text retrieval
	// (CLOB)" returns the first 32,000 characters of an nvarchar(max) value) cannot read an instrument
	// snapshot, a mutation replay record or a revision snapshot whole (P8-04). The check reads a value
	// longer than any the application stores back from SQL Server; once it has passed it is repeated
	// every LONG_TEXT_RECHECK_MS, not on every probe of a busy load balancer.
	variables.LONG_TEXT_PROBE_CHARS = 300000;
	variables.LONG_TEXT_RECHECK_MS = 600000;

	public HealthController function init(required struct config, required any db, required any requestContext) {
		variables.config = arguments.config;
		variables.db = arguments.db;
		variables.requestContext = arguments.requestContext;
		variables.longTextVerifiedAt = 0;
		return this;
	}

	public struct function get(required struct req) {
		var database = "ok";
		var schema = "unknown";
		var longText = "unknown";
		try {
			var q = variables.db.run("SELECT CASE WHEN OBJECT_ID(N'[icf].[instrument]', N'U') IS NULL THEN 0 ELSE 1 END AS has_schema");
			schema = q.has_schema[1] == 1 ? "present" : "missing";
			longText = longTextCheck();
		} catch (any e) {
			database = "unavailable";
		}
		var healthy = database == "ok" && longText != "truncated";
		var body = {
			"application": "ICFWalk",
			"status": healthy ? "ok" : "degraded",
			"checks": { "database": database, "schema": schema, "longText": longText },
			"correlationId": variables.requestContext.correlationId()
		};
		if (!variables.config.isProduction) {
			body["environment"] = variables.config.environment;
			body["engine"] = engineDescription();
		}
		return { "status": healthy ? 200 : 503, "body": body };
	}

	/** "ok" when SQL Server's long text reaches the application whole, else "truncated". */
	private string function longTextCheck() {
		if (variables.longTextVerifiedAt > 0 && getTickCount() - variables.longTextVerifiedAt < variables.LONG_TEXT_RECHECK_MS) return "ok";
		var q = variables.db.run("SELECT REPLICATE(CAST(N'x' AS nvarchar(max)), :n) AS probe", { "n": { "value": variables.LONG_TEXT_PROBE_CHARS, "cfsqltype": "cf_sql_integer" } });
		if (len(q.probe[1]) != variables.LONG_TEXT_PROBE_CHARS) {
			variables.longTextVerifiedAt = 0;
			return "truncated";
		}
		variables.longTextVerifiedAt = getTickCount();
		return "ok";
	}

	public string function engineDescription() {
		if (structKeyExists(server, "lucee") && structKeyExists(server.lucee, "version")) return "Lucee " & server.lucee.version;
		return server.coldfusion.productname & " " & server.coldfusion.productversion;
	}
}
