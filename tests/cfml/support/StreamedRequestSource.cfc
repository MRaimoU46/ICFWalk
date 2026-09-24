/**
 * The PRODUCTION HttpRequestSource, reading a body stream the spec supplies (P6A-R01).
 *
 * WHY IT EXISTS. FakeRequestSource states the reader's contract; it cannot show that the production
 * reader keeps it. This does: it extends icfwalk.http.HttpRequestSource and replaces only
 *
 *   containerRequest()   where the stream comes from. In production it unwraps the engine's servlet
 *                        request to the container's; here the "request" is this object, and its
 *                        getInputStream() is the stream the spec built;
 *   method, path, headers, query, remoteAddress   the request metadata, so a spec can state them.
 *
 * readBody() -- the bounded read loop, the size of every read it asks for, the byte count, the
 * decision to fall back to the engine's buffered body -- is inherited unchanged, so what a spec
 * measures through this is exactly what the production reader does with a stream.
 *
 * TEST-ONLY. Lives under tests/cfml, which only the CFML test runner maps; nothing in src/
 * references it, the application container never holds it, and no route reaches it.
 */
component extends="icfwalk.http.HttpRequestSource" output="false" {

	public StreamedRequestSource function init(required any requestContext, required any stream, string method = "POST", string path = "/api/admin/instrument/import", struct headers = {}) {
		super.init(arguments.requestContext);
		variables.bodyStream = arguments.stream;
		variables.fakeMethod = uCase(arguments.method);
		variables.fakePath = arguments.path;
		variables.fakeHeaders = {};
		for (var k in structKeyArray(arguments.headers)) variables.fakeHeaders[lCase(k)] = arguments.headers[k];
		return this;
	}

	public string function method() { return variables.fakeMethod; }
	public string function path() { return variables.fakePath; }
	public struct function headers() { return duplicate(variables.fakeHeaders); }
	public struct function query() { return {}; }
	public string function remoteAddress() { return "127.0.0.1"; }

	/** The one environmental seam: the container request is this object. */
	private any function containerRequest() { return this; }

	/** ...whose input stream is the spec's. */
	public any function getInputStream() { return variables.bodyStream; }
}
