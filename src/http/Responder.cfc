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
		variables.html = new icfwalk.core.HtmlEncoder();
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
		if (structKeyExists(arguments, "details") && (isStruct(arguments.details) || isArray(arguments.details))) {
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
		if (wantsHtml()) {
			sendHtmlError(status, code, message);
			return;
		}
		sendError(status, code, message, details);
	}

	/**
	 * Page routes (anything outside /api) answer browsers with a small HTML error page instead of
	 * JSON. Every dynamic value is HTML-encoded; no exception details are included.
	 */
	public void function sendHtmlError(required numeric status, required string code, required string message) {
		cfheader(statusCode = arguments.status);
		cfheader(name = "Cache-Control", value = "no-store");
		cfheader(name = "X-Content-Type-Options", value = "nosniff");
		cfheader(name = "Content-Security-Policy", value = "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'");
		cfcontent(type = "text/html; charset=utf-8", reset = true);
		var title = arguments.status == 401 ? "Sign-in required" : (arguments.status == 403 ? "Access denied" : (arguments.status == 404 ? "Not found" : "Something went wrong"));
		writeOutput('<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>ICFWalk ' & chr(183) & ' ' & variables.html.encode(title) & '</title>'
			& '<style>body{font-family:"Work Sans",-apple-system,"Segoe UI",Helvetica,Arial,sans-serif;background:##EDF3F9;color:##142433;margin:0;padding:40px 20px}main{max-width:560px;margin:0 auto;background:##fff;border:1px solid ##D7E1EA;border-radius:10px;padding:24px}h1{color:##003466;font-size:20px;margin:0 0 8px}p{font-size:14px;line-height:1.5;margin:0 0 8px}code{font-size:12px;color:##4E5D6C}</style></head>'
			& '<body><main role="main"><h1>' & variables.html.encode(title) & '</h1><p>' & variables.html.encode(arguments.message) & '</p><p><code>' & variables.html.encode(arguments.code) & ' ' & chr(183) & ' ' & variables.html.encode(variables.requestContext.correlationId()) & '</code></p></main></body></html>');
	}

	private boolean function wantsHtml() {
		var path = variables.requestContext.pathInfo();
		if (left(path, 5) == "/api/") return false;
		var accept = "";
		try {
			var headers = getHttpRequestData(false).headers;
			for (var name in structKeyArray(headers)) if (lCase(name) == "accept") accept = headers[name];
		} catch (any e) { accept = ""; }
		if (!structKeyExists(local, "accept") || !isSimpleValue(accept)) accept = "";
		return findNoCase("text/html", accept) > 0;
	}

	private void function writeJson(required numeric status, required any body) {
		cfheader(statusCode = arguments.status);
		cfheader(name = "Cache-Control", value = "no-store");
		cfheader(name = "X-Content-Type-Options", value = "nosniff");
		cfcontent(type = "application/json; charset=utf-8", reset = true);
		writeOutput(variables.json.serialize(arguments.body));
	}
}
