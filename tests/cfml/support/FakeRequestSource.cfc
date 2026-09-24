/**
 * A request for Router.handle() that never touches the engine's request (P6A-01 specs).
 *
 * It answers the same questions HttpRequestSource does -- method, path, headers, query, remote
 * address -- from values the spec gives it, and it RECORDS every attempt to read the body, so a
 * spec can prove the body was never acquired rather than infer it from a status code.
 *
 * readBody(maxBytes) keeps HttpRequestSource's contract exactly: it reads at most maxBytes + 1 bytes
 * and stops, reporting `exceeded` when there was more; byteCount is the UTF-8 byte length of what
 * it read, counted on the bytes (java.lang.reflect.Array), never with len() on text. That the
 * production reader keeps the same bound is measured separately, on its own loop, by
 * RequestBodyReadBoundTest (P6A-R01) -- this double only states it.
 *
 * TEST-ONLY. Lives under tests/cfml; nothing in src/ references it.
 */
component output="false" {

	public FakeRequestSource function init(required string method, required string path, struct headers = {}, string body = "", struct query = {}) {
		variables.m = uCase(arguments.method);
		variables.p = arguments.path;
		variables.h = {};
		for (var k in structKeyArray(arguments.headers)) variables.h[lCase(k)] = arguments.headers[k];
		variables.bodyText = arguments.body;
		variables.q = arguments.query;
		variables.reads = [];
		return this;
	}

	public string function method() { return variables.m; }
	public string function path() { return variables.p; }
	public struct function headers() { return duplicate(variables.h); }
	public struct function query() { return duplicate(variables.q); }
	public string function remoteAddress() { return "127.0.0.1"; }

	public struct function readBody(required numeric maxBytes) {
		arrayAppend(variables.reads, arguments.maxBytes);
		var bytes = charsetDecode(variables.bodyText, "utf-8");
		var count = createObject("java", "java.lang.reflect.Array").getLength(bytes);
		if (count > arguments.maxBytes) return { "exceeded": true, "byteCount": arguments.maxBytes + 1 };
		return { "exceeded": false, "byteCount": count, "bytes": bytes };
	}

	/** How many times the body was asked for, and with which limits. */
	public numeric function readCount() { return arrayLen(variables.reads); }
	public array function readLimits() { return duplicate(variables.reads); }
}
