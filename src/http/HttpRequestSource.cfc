/**
 * The current HTTP request, as the router consumes it (P6A-01).
 *
 * Everything but the body is METADATA and costs nothing to ask for: method, path, headers, query
 * string, remote address. The body is asked for separately, through readBody(), and only after the
 * router has authenticated the caller, checked CSRF and compared any declared Content-Length with
 * the route's limit -- so an unauthenticated or oversized request's body is never acquired, let
 * alone parsed. headers() uses getHttpRequestData(false), which does not touch the body.
 *
 * THE BODY IS READ AS BYTES, BOUNDED. readBody(maxBytes) reads the servlet container's own input
 * stream, at most maxBytes + 1 bytes, and stops: a chunked request (no trustworthy Content-Length)
 * cannot make the application read more than one byte past the route's limit, and the count is of
 * the bytes on the wire -- UTF-8 bytes of a JSON body -- never of characters (CFML len() on text
 * counts UTF-16 code units, which is how multibyte text used to slip under the limit).
 *
 * The CONTAINER's stream, not the engine's. Lucee wraps the servlet request, and the wrapper's
 * getInputStream() first copies the entire body into memory (HTTPServletRequestWrap.storeEL), which
 * would read an unbounded chunked body to its end before this code could count a byte of it. So the
 * request is unwrapped first -- Lucee's getOriginalRequest(), then any standard ServletRequestWrapper
 * chain, which is how Adobe ColdFusion and Tomcat wrap it -- and the innermost stream is read.
 *
 * If the engine has already consumed the stream (a servlet container or engine that buffers the
 * body itself), the stream yields nothing; the body is then taken from getHttpRequestData(true) and
 * measured by re-encoding it to UTF-8 bytes, before anything parses it. In that case what bounds the
 * engine's own buffering is the connector's limit (docs/LOCAL_SETUP.md, "Request size limits").
 *
 * The router talks to this component through the application container, so a spec can hand the
 * router a FakeRequestSource instead (tests/cfml/support) and observe every body read.
 */
component output="false" {

	variables.CHUNK = 65536;

	public HttpRequestSource function init(required any requestContext) {
		variables.requestContext = arguments.requestContext;
		variables.Array = createObject("java", "java.lang.reflect.Array");
		variables.ByteType = createObject("java", "java.lang.Byte").TYPE;
		return this;
	}

	public string function method() { return uCase(cgi.request_method); }

	public string function path() { return variables.requestContext.pathInfo(); }

	/** Header names lower-cased. Never reads the body. */
	public struct function headers() {
		var raw = getHttpRequestData(false).headers;
		var out = {};
		for (var name in structKeyArray(raw)) out[lCase(name)] = raw[name];
		return out;
	}

	public struct function query() { return duplicate(url); }

	public string function remoteAddress() { return cgi.remote_addr; }

	/**
	 * At most maxBytes + 1 bytes of the body.
	 *
	 * @return { exceeded: true, byteCount } when the body is longer than maxBytes (reading stopped
	 *         there, and nothing read is returned), else { exceeded: false, byteCount, bytes }.
	 */
	public struct function readBody(required numeric maxBytes) {
		var limit = arguments.maxBytes;
		var input = containerRequest().getInputStream();
		var out = createObject("java", "java.io.ByteArrayOutputStream").init();
		var chunk = variables.Array.newInstance(variables.ByteType, javaCast("int", variables.CHUNK));
		var total = 0;
		while (true) {
			var n = input.read(chunk, javaCast("int", 0), javaCast("int", variables.CHUNK));
			if (n < 0) break;
			total += n;
			if (total > limit) return { "exceeded": true, "byteCount": total };
			out.write(chunk, javaCast("int", 0), javaCast("int", n));
		}
		if (total == 0 && bodyExpected()) return engineBody(limit);
		return { "exceeded": false, "byteCount": total, "bytes": out.toByteArray() };
	}

	// ---- internals -------------------------------------------------------------------------------

	/** The servlet container's request underneath the engine's wrappers. */
	private any function containerRequest() {
		var r = getPageContext().getRequest();
		for (var depth = 1; depth <= 8; depth++) {
			var inner = javaCast("null", "");
			if (instanceOf(r, "lucee.runtime.net.http.HTTPServletRequestWrap")) {
				inner = r.getOriginalRequest();
			} else if (instanceOf(r, "javax.servlet.ServletRequestWrapper") || instanceOf(r, "jakarta.servlet.ServletRequestWrapper")) {
				inner = r.getRequest();
			}
			if (isNull(inner)) break;
			r = inner;
		}
		return r;
	}

	/** isInstanceOf, false (never an error) for a class this engine does not have. */
	private boolean function instanceOf(required any object, required string className) {
		try {
			return isInstanceOf(arguments.object, arguments.className);
		} catch (any e) {
			return false;
		}
	}

	/** A request that says it carries a body: a non-zero Content-Length, or a transfer coding. */
	private boolean function bodyExpected() {
		var h = headers();
		if (structKeyExists(h, "transfer-encoding") && len(trim(h["transfer-encoding"]))) return true;
		var declared = structKeyExists(h, "content-length") && isSimpleValue(h["content-length"]) ? trim(h["content-length"]) : "";
		return reFind("^[0-9]+$", declared) && reFind("[1-9]", declared);
	}

	/** The body the engine already buffered, measured in UTF-8 bytes. */
	private struct function engineBody(required numeric limit) {
		var content = getHttpRequestData(true).content;
		var bytes = "";
		if (isNull(content)) return { "exceeded": false, "byteCount": 0, "bytes": charsetDecode("", "utf-8") };
		if (isBinary(content)) bytes = content;
		else bytes = javaCast("string", content).getBytes("UTF-8");
		var count = variables.Array.getLength(bytes);
		if (count > arguments.limit) return { "exceeded": true, "byteCount": count };
		return { "exceeded": false, "byteCount": count, "bytes": bytes };
	}
}
