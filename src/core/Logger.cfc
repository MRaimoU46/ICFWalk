/**
 * Structured, redacting logger. Each entry is one canonical JSON line written through writeLog
 * (ColdFusion log directory, file name from ICFWALK_LOG_NAME). Field names that could carry
 * narrative content, personal data, or secrets are redacted by name, and long string values are
 * truncated so that free text never reaches the log even under an unexpected field name.
 */
component output="false" {

	variables.LEVELS = { "DEBUG": 10, "INFO": 20, "WARN": 30, "ERROR": 40 };
	variables.REDACT_PATTERN = "(?i)(password|secret|token|authorization|cookie|session|text_value|textvalue|body|subject|notes|narrative|email|teacher|prompt|definition|label)";
	variables.MAX_STRING = 200;

	public Logger function init(required struct config, required any canonicalJson) {
		variables.config = arguments.config;
		variables.json = arguments.canonicalJson;
		variables.threshold = variables.LEVELS[arguments.config.logLevel];
		variables.logName = arguments.config.logName;
		return this;
	}

	public void function debug(required string event, struct fields = {}) { write("DEBUG", arguments.event, arguments.fields); }
	public void function info(required string event, struct fields = {}) { write("INFO", arguments.event, arguments.fields); }
	public void function warn(required string event, struct fields = {}) { write("WARN", arguments.event, arguments.fields); }
	public void function error(required string event, struct fields = {}) { write("ERROR", arguments.event, arguments.fields); }

	public boolean function isEnabled(required string level) {
		return variables.LEVELS[uCase(arguments.level)] >= variables.threshold;
	}

	/**
	 * Builds the log entry (exposed for tests so redaction can be verified without writing).
	 */
	public struct function buildEntry(required string level, required string event, struct fields = {}) {
		var entry = {};
		entry["ts"] = formatInstant(now());
		entry["level"] = uCase(arguments.level);
		entry["event"] = arguments.event;
		if (structKeyExists(request, "icf") && structKeyExists(request.icf, "correlationId")) {
			entry["correlationId"] = request.icf.correlationId;
		}
		if (structKeyExists(request, "icf") && structKeyExists(request.icf, "actorUserId") && len(request.icf.actorUserId)) {
			entry["actorUserId"] = request.icf.actorUserId;
		}
		entry["fields"] = redact(arguments.fields, 0);
		return entry;
	}

	public any function redact(required any value, numeric depth = 0) {
		if (arguments.depth > 6) return "[truncated-depth]";
		if (isNull(arguments.value)) return javaCast("null", "");
		if (isStruct(arguments.value)) {
			var out = {};
			for (var key in structKeyArray(arguments.value)) {
				if (reFind(variables.REDACT_PATTERN, key)) {
					out[key] = "[redacted]";
				} else if (isNull(arguments.value[key])) {
					out[key] = javaCast("null", "");
				} else {
					out[key] = redact(arguments.value[key], arguments.depth + 1);
				}
			}
			return out;
		}
		if (isArray(arguments.value)) {
			var arr = [];
			var n = arrayLen(arguments.value);
			for (var i = 1; i <= n; i++) {
				if (i > 50) { arrayAppend(arr, "[truncated-array]"); break; }
				if (isNull(arguments.value[i])) arrayAppend(arr, javaCast("null", ""));
				else arrayAppend(arr, redact(arguments.value[i], arguments.depth + 1));
			}
			return arr;
		}
		if (isInstanceOf(arguments.value, "java.lang.String")) {
			var s = arguments.value;
			if (len(s) > variables.MAX_STRING) return left(s, variables.MAX_STRING) & "...[truncated]";
			return s;
		}
		if (isSimpleValue(arguments.value)) return arguments.value; // numbers, booleans, dates
		return "[object]";
	}

	private void function write(required string level, required string event, required struct fields) {
		if (variables.LEVELS[arguments.level] < variables.threshold) return;
		var entry = buildEntry(arguments.level, arguments.event, arguments.fields);
		var cfType = "information";
		if (arguments.level == "WARN") cfType = "warning";
		if (arguments.level == "ERROR") cfType = "error";
		writeLog(file = variables.logName, type = cfType, text = variables.json.serialize(entry));
	}

	private string function formatInstant(required date value) {
		return variables.json.formatDate(arguments.value);
	}
}
