/**
 * The production body reader never consumes more than one byte past the limit (P6A-R01).
 *
 * THE DEFECT. HttpRequestSource.readBody asked the input stream for a fixed 65,536 bytes on every
 * read and compared the running total with the limit only afterwards. A read that began just under
 * the limit could therefore consume up to 65,536 bytes past it before the reader noticed: with the
 * import's 5,000,000-byte limit and a body that had fully arrived, 5,046,272 bytes were consumed.
 * The documentation said "at most one byte past", and FakeRequestSource -- the only reader
 * RouterBodyOrderTest drove -- behaved that way, so nothing measured the real loop.
 *
 * THE CORRECTION. Every read asks for min(65,536, limit - total + 1) bytes. An InputStream returns at
 * most what it is asked for, so the reader consumes at most limit + 1 bytes from the stream, and it
 * consumes exactly limit + 1 whenever the body is longer.
 *
 * WHAT IS PROVED HERE, ON THE PRODUCTION LOOP. StreamedRequestSource is the production
 * HttpRequestSource with only the stream's origin and the request metadata replaced; readBody is
 * inherited unchanged. RecordingInputStream holds the body in a real java.io.ByteArrayInputStream,
 * so consumed() is exact, and records every read the loop asks for. Each case asserts the bytes
 * consumed from the stream, the count the reader reports, and that no single read asked for more
 * than min(65,536, limit - total + 1). The cases cover both production limits (5,000,000 and
 * 20,000,000), limits either side of the 65,536-byte read size, bodies one byte and many reads past
 * the limit, streams that deliver a few bytes at a time as a network does, multibyte text, a body
 * within the limit read whole and byte for byte, and the same reader driven through Router.handle.
 *
 * What this does not measure: bytes the servlet container itself receives from the network into its
 * own buffers ahead of the application's reads, and a body an engine had already buffered before the
 * reader ran (then HttpRequestSource measures the engine's copy; the connector's limit bounds it).
 */
component extends="icfwalktests.BaseSpec" output="false" {

	variables.CHUNK = 65536;
	variables.IMPORT_LIMIT = 5000000;
	variables.SERVER_MAX = 20000000;
	variables.CSRF = repeatString("c", 64);

	// ---- the reader alone ------------------------------------------------------------------------

	/** The worst case: the whole body is available, so only the size asked for limits each read. */
	public void function testTheReaderConsumesExactlyOneBytePastTheLimitWhenTheWholeBodyHasArrived() {
		for (var limit in [0, 1, 2, 65535, 65536, 65537, 131071, 131072, 131073, variables.IMPORT_LIMIT]) {
			for (var extra in [1, 2, 65535, 65536, 65537, 200000]) {
				var r = readThrough(limit, zeros(limit + extra));
				assertStoppedOneBytePast(r, limit, "limit " & limit & ", body " & (limit + extra));
			}
		}
	}

	/** The server maximum, which every route without a limit of its own is read under. */
	public void function testTheServerMaximumIsBoundTheSameWay() {
		var r = readThrough(variables.SERVER_MAX, zeros(variables.SERVER_MAX + 70000));
		assertStoppedOneBytePast(r, variables.SERVER_MAX, "the server maximum");
	}

	/** A network stream returns only what has arrived; the bound holds read by read. */
	public void function testShortReadsLikeANetworkStreamStopAtTheSameByte() {
		for (var c in [[1, 0], [1, 5], [1, 300], [7, 65536], [1000, 65536], [1000, 100000], [65535, 131072], [4096, variables.IMPORT_LIMIT]]) {
			var perRead = c[1];
			var limit = c[2];
			var r = readThrough(limit, zeros(limit + 70000), perRead);
			assertStoppedOneBytePast(r, limit, "limit " & limit & ", at most " & perRead & " bytes delivered per read");
		}
	}

	/** Within the limit the whole body is read, byte for byte, and nothing past its end is asked for. */
	public void function testABodyWithinTheLimitIsReadWholeAndExactly() {
		var limit = 70000;
		for (var size in [1, 2, 65535, 65536, 65537, limit - 1, limit]) {
			var body = patterned(size);
			var r = readThrough(limit, body, 0, { "content-length": toString(size) });
			var label = "limit " & limit & ", body " & size;
			assertFalse(r.result.exceeded, label & ": within the limit");
			assertEquals(size, r.result.byteCount, label & ": counted exactly");
			assertEquals(size, r.stream.consumed(), label & ": consumed exactly");
			assertExactTextEquals(digest(body), digest(r.result.bytes), label & ": the bytes returned are the body's, in order");
			assertEveryReadWithinTheBound(r.stream.reads(), limit, label);
		}
	}

	/** Bytes, not characters: 1,700,001 euro signs are 5,100,003 bytes, cut at the limit's next byte. */
	public void function testMultibyteTextIsBoundedInBytes() {
		var bytes = charsetDecode(repeatString(chr(8364), 1700001), "utf-8");
		var r = readThrough(variables.IMPORT_LIMIT, bytes);
		assertEquals(5100003, r.stream.size(), "precondition: 5,100,003 UTF-8 bytes");
		assertStoppedOneBytePast(r, variables.IMPORT_LIMIT, "euro signs");
	}

	// ---- the same reader, through the router -------------------------------------------------------

	/** An authorized chunked import over the limit: 413 after exactly limit + 1 bytes, never parsed. */
	public void function testTheRouterRefusesAnOversizedChunkedImportAfterReadingExactlyOneBytePast() {
		var h = harness(false);
		var body = charsetDecode("{""document"": this is not json " & repeatString("x", variables.IMPORT_LIMIT + 200000), "utf-8");
		var stream = new icfwalktests.support.RecordingInputStream(body);
		var source = streamed(stream, authorized({ "transfer-encoding": "chunked" }));
		assertThrows(function() { h.router.handle(source); }, "ICFWalk.PayloadTooLarge", "DOCUMENT_TOO_LARGE");
		assertEquals(variables.IMPORT_LIMIT + 1, stream.consumed(), "the router's read consumed exactly one byte past the import limit");
		assertEveryReadWithinTheBound(stream.reads(), variables.IMPORT_LIMIT, "through the router");
		assertEquals(0, h.parser.calls(), "and nothing was parsed");
		assertEquals(0, arrayLen(h.doubles.calls().controller), "and no controller ran");
	}

	/** Refused before the body: not one byte is taken from the stream. */
	public void function testTheRouterTakesNothingFromTheStreamBeforeAuthenticationCsrfOrADeclaredOversizedLength() {
		var body = charsetDecode(repeatString("x", 300000), "utf-8");

		var anonymous = harness(true);
		var s1 = new icfwalktests.support.RecordingInputStream(body);
		var src1 = streamed(s1, { "transfer-encoding": "chunked" });
		assertThrows(function() { anonymous.router.handle(src1); }, "ICFWalk.Unauthenticated", "UNAUTHENTICATED");
		assertEquals(0, s1.consumed(), "unauthenticated: nothing read");

		var h = harness(false);
		var s2 = new icfwalktests.support.RecordingInputStream(body);
		var src2 = streamed(s2, { "transfer-encoding": "chunked", "x-icfwalk-csrf-token": repeatString("f", 64) });
		assertThrows(function() { h.router.handle(src2); }, "ICFWalk.Forbidden", "CSRF_TOKEN_INVALID");
		assertEquals(0, s2.consumed(), "CSRF-invalid: nothing read");

		var s3 = new icfwalktests.support.RecordingInputStream(body);
		var src3 = streamed(s3, authorized({ "content-length": toString(variables.IMPORT_LIMIT + 1) }));
		assertThrows(function() { h.router.handle(src3); }, "ICFWalk.PayloadTooLarge", "DOCUMENT_TOO_LARGE");
		assertEquals(0, s3.consumed(), "a declared length over the limit: nothing read");
		assertEquals(0, arrayLen(s1.reads()) + arrayLen(s2.reads()) + arrayLen(s3.reads()), "no read was even asked for");
		assertEquals(0, anonymous.parser.calls() + h.parser.calls());
	}

	/** Within the limit the router reads the body to its end and parses it once. */
	public void function testTheRouterReadsABodyWithinTheLimitToItsEndAndParsesItOnce() {
		var h = harness(false);
		var text = "{""document"":{""padding"":""" & repeatString("a", 150000) & """}}";
		var body = charsetDecode(text, "utf-8");
		var stream = new icfwalktests.support.RecordingInputStream(body, 1000);
		var result = h.router.handle(streamed(stream, authorized({ "transfer-encoding": "chunked" })));
		assertExactTextEquals("importDocument", result.body.reached);
		assertEquals(stream.size(), stream.consumed(), "the whole body was read");
		assertEquals(1, h.parser.calls(), "and parsed once");
		assertEquals(stream.size(), h.doubles.calls().controller[1].rawBodyLength, "its length is the bytes read");
		assertEveryReadWithinTheBound(stream.reads(), variables.IMPORT_LIMIT, "within the limit, through the router");
	}

	// ---- helpers ---------------------------------------------------------------------------------

	private struct function readThrough(required numeric limit, required any bytes, numeric perRead = 0, struct headers) {
		var h = structKeyExists(arguments, "headers") ? arguments.headers : { "transfer-encoding": "chunked" };
		var stream = new icfwalktests.support.RecordingInputStream(arguments.bytes, arguments.perRead);
		var source = streamed(stream, h);
		return { "result": source.readBody(arguments.limit), "stream": stream };
	}

	private any function streamed(required any stream, required struct headers) {
		return new icfwalktests.support.StreamedRequestSource(variables.c.requestContext, arguments.stream, "POST", "/api/admin/instrument/import", arguments.headers);
	}

	/** Refused as over the limit, having counted and consumed exactly limit + 1 bytes, read by bounded read. */
	private void function assertStoppedOneBytePast(required struct r, required numeric limit, required string label) {
		assertTrue(arguments.r.result.exceeded, arguments.label & ": refused as over the limit");
		assertEquals(arguments.limit + 1, arguments.r.result.byteCount, arguments.label & ": the reader counted exactly one byte past the limit");
		assertEquals(arguments.limit + 1, arguments.r.stream.consumed(), arguments.label & ": consumed from the stream exactly one byte past the limit, and not one more");
		assertEveryReadWithinTheBound(arguments.r.stream.reads(), arguments.limit, arguments.label);
	}

	/** No read asked for more than min(65,536, limit - total + 1) bytes, and every read asked for at least one. */
	private void function assertEveryReadWithinTheBound(required array reads, required numeric limit, required string label) {
		assertTrue(arrayLen(arguments.reads) > 0, arguments.label & ": the stream was read");
		for (var i = 1; i <= arrayLen(arguments.reads); i++) {
			var rd = arguments.reads[i];
			var bound = min(variables.CHUNK, arguments.limit - rd.before + 1);
			if (rd.requested > bound || rd.requested < 1) {
				fail(arguments.label & ": read " & i & " asked for " & rd.requested & " bytes with " & rd.before & " already read; the bound is " & bound & " (min(65536, limit - total + 1)).");
			}
		}
	}

	private any function zeros(required numeric n) {
		return createObject("java", "java.lang.reflect.Array").newInstance(createObject("java", "java.lang.Byte").TYPE, javaCast("int", arguments.n));
	}

	/** n ASCII bytes of a repeating pattern, so an out-of-order or short copy shows. */
	private any function patterned(required numeric n) {
		return charsetDecode(left(repeatString("0123456789abcdefghijklmnopqrstuvwxyz", ceiling(arguments.n / 36) + 1), arguments.n), "us-ascii");
	}

	private string function digest(required any bytes) {
		return hash(binaryEncode(arguments.bytes, "base64"), "SHA-256");
	}

	/** A real Router over a container whose identity, CSRF, permission and controllers are doubles. */
	private struct function harness(required boolean anonymous) {
		var doubles = createObject("component", "icfwalktests.support.RouterTestDoubles").init(variables.c.errors, arguments.anonymous, variables.CSRF, false);
		var parser = createObject("component", "icfwalktests.support.SpyJsonBodyParser").init(variables.c.jsonBodyParser);
		var container = structCopy(variables.c);
		container["authenticationService"] = doubles;
		container["sessionService"] = doubles;
		container["authorizationService"] = doubles;
		container["jsonBodyParser"] = parser;
		container["adminInstrumentController"] = doubles;
		return { "router": createObject("component", "icfwalk.http.Router").init(container), "doubles": doubles, "parser": parser };
	}

	private struct function authorized(required struct headers) {
		var h = duplicate(arguments.headers);
		h["x-icfwalk-csrf-token"] = variables.CSRF;
		h["content-type"] = "application/json";
		return h;
	}
}
