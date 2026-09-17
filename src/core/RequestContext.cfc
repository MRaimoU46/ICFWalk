/**
 * Per-request correlation. Accepts a caller-supplied X-Correlation-Id when it is a safe token,
 * otherwise generates one; the id is echoed on the response and attached to every log line and
 * audit event written during the request.
 */
component output="false" {

	variables.SAFE_ID_PATTERN = "^[A-Za-z0-9._-]{8,64}$";

	public RequestContext function init(required any logger) {
		variables.logger = arguments.logger;
		return this;
	}

	public void function begin() {
		var headers = getHttpRequestData(false).headers;
		var supplied = "";
		for (var name in structKeyArray(headers)) {
			if (lCase(name) == "x-correlation-id") { supplied = trim(headers[name]); break; }
		}
		var id = (len(supplied) && reFind(variables.SAFE_ID_PATTERN, supplied)) ? supplied : newId();
		request["icf"] = {
			"correlationId": id,
			"startedAt": getTickCount(),
			"method": cgi.request_method,
			"path": pathInfo()
		};
		cfheader(name = "X-Correlation-Id", value = id);
	}

	public string function correlationId() {
		if (structKeyExists(request, "icf") && structKeyExists(request.icf, "correlationId")) return request.icf.correlationId;
		return newId();
	}

	public string function newId() {
		return lCase(createObject("java", "java.util.UUID").randomUUID().toString());
	}

	public string function pathInfo() {
		var p = cgi.path_info;
		if (!len(p) && len(cgi.script_name)) {
			// Some web-server integrations fold the extra path into script_name.
			var idx = findNoCase("index.cfm", cgi.script_name);
			if (idx) p = mid(cgi.script_name, idx + 9, len(cgi.script_name));
		}
		if (!len(p)) p = "/";
		return p;
	}

	public numeric function elapsedMs() {
		if (structKeyExists(request, "icf")) return getTickCount() - request.icf.startedAt;
		return 0;
	}
}
