/**
 * Protects operator-only maintenance endpoints (schema seeding, test runner). These do not use
 * the user session, so every call must present the maintenance token header, the feature must be
 * explicitly enabled, and the caller must be on the loopback interface unless remote access is
 * explicitly allowed. Denials respond 404 so the endpoints are indistinguishable from absent
 * routes; each attempt is logged and each successful invocation is audited.
 */
component output="false" {

	public MaintenanceGuard function init(required struct config, required any logger, required any errors, required any auditRepository, required any requestContext) {
		variables.config = arguments.config;
		variables.logger = arguments.logger;
		variables.errors = arguments.errors;
		variables.audit = arguments.auditRepository;
		variables.requestContext = arguments.requestContext;
		variables.MessageDigest = createObject("java", "java.security.MessageDigest");
		return this;
	}

	public void function require(required struct req, required string task) {
		var remote = arguments.req.remoteAddress;
		if (!variables.config.maintenanceEnabled) {
			deny("maintenance.disabled", arguments.task, remote);
		}
		if (!variables.config.maintenanceAllowRemote && !isLoopback(remote)) {
			deny("maintenance.remote_denied", arguments.task, remote);
		}
		var supplied = structKeyExists(arguments.req.headers, "x-icfwalk-maintenance-token") ? trim(arguments.req.headers["x-icfwalk-maintenance-token"]) : "";
		if (!len(supplied) || !constantTimeEquals(supplied, variables.config.maintenanceToken)) {
			deny("maintenance.token_invalid", arguments.task, remote);
		}
		variables.logger.info("maintenance.invoked", { "task": arguments.task, "remoteAddress": remote });
		variables.audit.record("MAINTENANCE", "", "MAINTENANCE_TASK_INVOKED", "", { "task": arguments.task, "remoteAddress": remote });
	}

	public boolean function isLoopback(required string address) {
		var a = trim(arguments.address);
		return a == "127.0.0.1" || a == "::1" || a == "0:0:0:0:0:0:0:1" || left(a, 4) == "127.";
	}

	public boolean function constantTimeEquals(required string a, required string b) {
		var ab = javaCast("string", arguments.a).getBytes("UTF-8");
		var bb = javaCast("string", arguments.b).getBytes("UTF-8");
		return variables.MessageDigest.isEqual(ab, bb);
	}

	private void function deny(required string reason, required string task, required string remote) {
		variables.logger.warn("maintenance.denied", { "reason": arguments.reason, "task": arguments.task, "remoteAddress": arguments.remote });
		variables.errors.notFound();
	}
}
