/**
 * Serializes controller results and exceptions as JSON. Application errors (ICFWalk.*) expose
 * their code, message, and structured details; unexpected errors expose only a correlation id
 * outside development so that stack traces, SQL, and configuration never leak to clients.
 */
component output="false" {

	public Responder function init(required struct config, required any logger, required any canonicalJson, required any requestContext) {
		variables.config = arguments.config;
		variables.logger = arguments.logger;
		variables.json = arguments.canonicalJson;
		variables.requestContext = arguments.requestContext;
		variables.errors = new icfwalk.core.Errors();
		return this;
	}

	public void function send(required struct result) {
		var status = structKeyExists(arguments.result, "status") ? arguments.result.status : 200;
		var body = structKeyExists(arguments.result, "body") ? arguments.result.body : {};
		if (structKeyExists(arguments.result, "headers")) {
			for (var name in structKeyArray(arguments.result.headers)) {
				cfheader(name = name, value = arguments.result.headers[name]);
			}
		}
		if (structKeyExists(arguments.result, "text")) {
			cfheader(statusCode = status);
			cfcontent(type = structKeyExists(arguments.result, "contentType") ? arguments.result.contentType : "text/plain; charset=utf-8", reset = true);
			writeOutput(arguments.result.text);
			return;
		}
		writeJson(status, body);
	}

	public void function sendError(required numeric status, required string code, required string message, any details) {
		var payload = { "error": { "code": arguments.code, "message": arguments.message, "correlationId": variables.requestContext.correlationId() } };
		if (!isNull(arguments.details) && (isStruct(arguments.details) || isArray(arguments.details))) {
			payload.error["details"] = arguments.details;
		}
		writeJson(arguments.status, payload);
	}

	public void function sendException(required any exception) {
		var type = structKeyExists(arguments.exception, "type") ? arguments.exception.type : "unknown";
		var status = variables.errors.statusFor(type);
		var isAppError = variables.errors.isApplicationError(type);
		var code = (isAppError && structKeyExists(arguments.exception, "errorcode") && len(arguments.exception.errorcode)) ? arguments.exception.errorcode : "INTERNAL_ERROR";
		var message = isAppError ? arguments.exception.message : "An unexpected error occurred.";
		var logFields = {
			"type": type,
			"code": code,
			"status": status,
			"path": variables.requestContext.pathInfo(),
			"exceptionMessage": structKeyExists(arguments.exception, "message") ? arguments.exception.message : ""
		};
		if (!isAppError && structKeyExists(arguments.exception, "tagContext") && isArray(arguments.exception.tagContext) && arrayLen(arguments.exception.tagContext)) {
			var top = arguments.exception.tagContext[1];
			logFields["at"] = (structKeyExists(top, "template") ? top.template : "") & ":" & (structKeyExists(top, "line") ? top.line : "");
		}
		if (status >= 500) variables.logger.error("request.failed", logFields);
		else variables.logger.warn("request.rejected", logFields);

		var details = isAppError ? variables.errors.detailsOf(arguments.exception) : {};
		if (!isAppError && variables.config.environment == "development") {
			details = { "exceptionType": type, "exceptionMessage": structKeyExists(arguments.exception, "message") ? arguments.exception.message : "" };
			if (structKeyExists(arguments.exception, "detail")) details["exceptionDetail"] = arguments.exception.detail;
		}
		sendError(status, code, message, details);
	}

	private void function writeJson(required numeric status, required any body) {
		cfheader(statusCode = arguments.status);
		cfheader(name = "Cache-Control", value = "no-store");
		cfheader(name = "X-Content-Type-Options", value = "nosniff");
		cfcontent(type = "application/json; charset=utf-8", reset = true);
		writeOutput(variables.json.serialize(arguments.body));
	}
}
