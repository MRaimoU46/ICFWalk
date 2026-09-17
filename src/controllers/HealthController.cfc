/**
 * Liveness/readiness endpoint. Reports whether the database answers; never reports configuration
 * values or secrets. Returns 503 when the database is unavailable so load balancers can react.
 */
component output="false" {

	public HealthController function init(required struct config, required any db, required any requestContext) {
		variables.config = arguments.config;
		variables.db = arguments.db;
		variables.requestContext = arguments.requestContext;
		return this;
	}

	public struct function get(required struct req) {
		var database = "ok";
		var schema = "unknown";
		try {
			var q = variables.db.run("SELECT CASE WHEN OBJECT_ID(N'[icf].[instrument]', N'U') IS NULL THEN 0 ELSE 1 END AS has_schema");
			schema = q.has_schema[1] == 1 ? "present" : "missing";
		} catch (any e) {
			database = "unavailable";
		}
		var body = {
			"application": "ICFWalk",
			"status": database == "ok" ? "ok" : "degraded",
			"checks": { "database": database, "schema": schema },
			"correlationId": variables.requestContext.correlationId()
		};
		if (!variables.config.isProduction) {
			body["environment"] = variables.config.environment;
			body["engine"] = engineDescription();
		}
		return { "status": database == "ok" ? 200 : 503, "body": body };
	}

	public string function engineDescription() {
		if (structKeyExists(server, "lucee") && structKeyExists(server.lucee, "version")) return "Lucee " & server.lucee.version;
		return server.coldfusion.productname & " " & server.coldfusion.productversion;
	}
}
