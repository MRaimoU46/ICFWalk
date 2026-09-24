/**
 * The router decides who may send a body, and how large it may be, before it reads or parses one
 * (P6A-01).
 *
 * THE DEFECT. Router.dispatch() built the request by reading the whole body and deserializing it
 * first, then authenticated, then checked CSRF, and only the import controller -- after all of
 * that -- compared a length with its 5,000,000-byte limit. So an anonymous caller's body was read
 * and parsed in full; a malformed body answered 400 INVALID_JSON_BODY before anyone asked who sent
 * it; an authorized malformed body over the limit answered 400 instead of 413; and the chunked
 * fallback measured characters with len(), so multibyte text under the limit in characters but
 * over it in bytes was accepted.
 *
 * THE CORRECTION, AND WHAT IS PROVED HERE. Router.handle() matches the route and builds the
 * request from its metadata only; authenticates, checks CSRF and (unless the policy needs a body
 * member) the permission; then, and only then, acquires the body under the route's byte limit --
 * refusing a declared Content-Length over it without reading at all, and reading at most one byte
 * past it otherwise -- and only a body within the limit is parsed. Each case below runs the real
 * Router over a FakeRequestSource that records every body read and a SpyJsonBodyParser that counts
 * every parse, so "not read" and "not parsed" are observed counts, not inferences from a status.
 *
 * FakeRequestSource states the reader's contract (at most limit + 1 bytes); it does not prove the
 * production reader keeps it. RequestBodyReadBoundTest does (P6A-R01): it runs HttpRequestSource's own
 * readBody loop over a real stream and measures exactly how many bytes it takes.
 *
 * The HTTP twins in tests/node/admin-instrument.test.mjs prove the same order on the running
 * server, by sending a body that never finishes: only a server that decides first can answer it.
 */
component extends="icfwalktests.BaseSpec" output="false" {

	variables.LIMIT = 5000000;
	variables.IMPORT = "/api/admin/instrument/import";
	variables.CSRF = repeatString("c", 64);
	variables.MALFORMED = "{""document"": this is not json ";

	// ---- refused before the body -----------------------------------------------------------------

	public void function testAnUnauthenticatedLargeMalformedImportIsRefusedWithoutReadingOrParsing() {
		for (var headers in [
			{ "content-length": "50000000", "content-type": "application/json" },
			{ "transfer-encoding": "chunked", "content-type": "application/json" }
		]) {
			var h = harness({ "anonymous": true });
			var src = source("POST", variables.IMPORT, headers, variables.MALFORMED & repeatString("x", variables.LIMIT));
			assertThrows(function() { h.router.handle(src); }, "ICFWalk.Unauthenticated", "UNAUTHENTICATED");
			assertEquals(0, src.readCount(), "the body was never read");
			assertEquals(0, h.parser.calls(), "the body was never deserialized");
			assertEquals(0, arrayLen(h.doubles.calls().controller), "no controller ran");
		}
	}

	public void function testACsrfInvalidLargeMalformedImportIsRefusedWithoutReadingOrParsing() {
		for (var token in ["", repeatString("f", 64)]) {
			var h = harness({});
			var headers = { "content-length": "50000000", "content-type": "application/json" };
			if (len(token)) headers["x-icfwalk-csrf-token"] = token;
			var src = source("POST", variables.IMPORT, headers, variables.MALFORMED & repeatString("x", variables.LIMIT));
			assertThrows(function() { h.router.handle(src); }, "ICFWalk.Forbidden", "CSRF_TOKEN_INVALID");
			assertEquals(1, h.doubles.calls().authenticate, "authentication ran first");
			assertEquals(0, src.readCount(), "the body was never read");
			assertEquals(0, h.parser.calls(), "the body was never deserialized");
		}
	}

	public void function testAUserWithoutThePermissionIsRefusedWithoutReadingOrParsing() {
		var h = harness({ "deny": true });
		var src = source("POST", variables.IMPORT, authorized({ "content-length": "50000000" }), variables.MALFORMED);
		assertThrows(function() { h.router.handle(src); }, "ICFWalk.Forbidden", "FORBIDDEN");
		assertEquals(0, src.readCount(), "the body was never read");
		assertEquals(0, h.parser.calls(), "the body was never deserialized");
	}

	// ---- refused at the limit, before parsing ------------------------------------------------------

	public void function testAnAuthorizedMalformedImportOverTheLimitIs413NotInvalidJson() {
		// Declared: refused from the header, without reading a byte.
		var body = variables.MALFORMED & repeatString("x", variables.LIMIT);
		var h = harness({});
		var declared = source("POST", variables.IMPORT, authorized({ "content-length": toString(variables.LIMIT + 1) }), body);
		var e = assertThrows(function() { h.router.handle(declared); }, "ICFWalk.PayloadTooLarge", "DOCUMENT_TOO_LARGE");
		assertEquals(variables.LIMIT, variables.c.errors.detailsOf(e).limitBytes);
		assertEquals(0, declared.readCount(), "a declared length over the limit is refused without reading the body");
		assertEquals(0, h.parser.calls());

		// Undeclared (chunked): read to one byte past the limit, then refused unparsed.
		var chunked = source("POST", variables.IMPORT, authorized({ "transfer-encoding": "chunked" }), body);
		assertThrows(function() { h.router.handle(chunked); }, "ICFWalk.PayloadTooLarge", "DOCUMENT_TOO_LARGE");
		assertEquals(1, chunked.readCount());
		assertEquals(variables.LIMIT, chunked.readLimits()[1], "read under the route's own limit");
		assertEquals(0, h.parser.calls(), "an oversized malformed body is never handed to the parser");
		assertEquals(0, arrayLen(h.doubles.calls().controller));
	}

	public void function testAnAuthorizedValidImportOverTheLimitIs413WithoutDeserialization() {
		var valid = serializeJSON({ "document": { "padding": repeatString("a", variables.LIMIT) } });
		for (var headers in [authorized({ "transfer-encoding": "chunked" }), authorized({})]) {
			var h = harness({});
			var src = source("POST", variables.IMPORT, headers, valid);
			assertThrows(function() { h.router.handle(src); }, "ICFWalk.PayloadTooLarge", "DOCUMENT_TOO_LARGE");
			assertEquals(0, h.parser.calls(), "valid JSON over the limit is never deserialized");
			assertEquals(0, arrayLen(h.doubles.calls().controller));
		}
	}

	public void function testMultibyteTextIsMeasuredInUtf8BytesAndCannotSlipUnderTheLimit() {
		// 1,700,000 euro signs: 1.7 million characters, 5.1 million UTF-8 bytes.
		var euro = chr(8364);
		var body = "{""document"":{""padding"":""" & repeatString(euro, 1700000) & """}}";
		assertTrue(len(body) < variables.LIMIT, "precondition: under the limit in characters");
		var h = harness({});
		var src = source("POST", variables.IMPORT, authorized({ "transfer-encoding": "chunked" }), body);
		assertThrows(function() { h.router.handle(src); }, "ICFWalk.PayloadTooLarge", "DOCUMENT_TOO_LARGE");
		assertEquals(0, h.parser.calls(), "refused on its byte count, before parsing");
	}

	// ---- everything else is unchanged ------------------------------------------------------------

	public void function testAnAuthorizedImportWithinTheLimitIsParsedOnceAndReachesTheController() {
		var h = harness({});
		var src = source("POST", variables.IMPORT, authorized({}), "{""document"":{""a"":1}}");
		var result = h.router.handle(src);
		assertExactTextEquals("importDocument", result.body.reached);
		assertEquals(1, src.readCount());
		assertEquals(1, h.parser.calls());
		var reached = h.doubles.calls().controller[1];
		assertEquals(1, reached.body.document.a);
		assertTrue(reached.hasBody);
		assertEquals(20, reached.rawBodyLength, "the body's length in bytes");
		// Exactly at the limit is within it.
		var atLimit = "{""document"":{""padding"":""" & repeatString("a", variables.LIMIT - 27) & """}}";
		var exact = source("POST", variables.IMPORT, authorized({ "content-length": toString(variables.LIMIT) }), atLimit);
		h.router.handle(exact);
		assertEquals(2, h.parser.calls(), "a body of exactly the limit is parsed");
	}

	public void function testAMalformedBodyWithinTheLimitIsStillInvalidJsonForAnAuthorizedCaller() {
		var h = harness({});
		var src = source("POST", variables.IMPORT, authorized({}), variables.MALFORMED);
		assertThrows(function() { h.router.handle(src); }, "ICFWalk.Validation", "INVALID_JSON_BODY");
		assertEquals(1, h.parser.calls());
		var nullBody = source("POST", variables.IMPORT, authorized({}), "null");
		assertThrows(function() { h.router.handle(nullBody); }, "ICFWalk.Validation", "INVALID_JSON_BODY");
	}

	/** Whitespace is a body (the no-body routes refuse it), and it parses to nothing. */
	public void function testWhitespaceIsABodyThatParsesToNothing() {
		var h = harness({});
		var src = source("POST", "/api/admin/instrument/versions/" & createUUID() & "/publish", authorized({}), "   ");
		h.router.handle(src);
		var reached = h.doubles.calls().controller[1];
		assertTrue(reached.hasBody, "three bytes of whitespace are a body");
		assertEquals(3, reached.rawBodyLength);
		assertEquals(0, structCount(reached.body));
		assertEquals(0, h.parser.calls(), "and nothing was parsed");
	}

	/**
	 * A policy that needs a body member (POST /api/walks names its org unit in the body) still
	 * authenticates and checks CSRF first; its permission check then sees the parsed member.
	 */
	public void function testABodyDependentPermissionStillAuthenticatesFirstAndThenSeesTheBody() {
		var anonymous = harness({ "anonymous": true });
		var refused = source("POST", "/api/walks", { "content-type": "application/json" }, variables.MALFORMED);
		assertThrows(function() { anonymous.router.handle(refused); }, "ICFWalk.Unauthenticated", "UNAUTHENTICATED");
		assertEquals(0, refused.readCount());
		assertEquals(0, anonymous.parser.calls());

		var h = harness({});
		var src = source("POST", "/api/walks", authorized({}), "{""orgUnitId"":""ORG-1"",""clientMutationId"":""m""}");
		h.router.handle(src);
		var checks = h.doubles.calls().permission;
		assertEquals(1, arrayLen(checks));
		assertExactTextEquals("walk.create", checks[1].permission);
		assertExactTextEquals("ORG-1", checks[1].orgUnitId, "the permission was decided on the parsed body member");
	}

	public void function testAMaintenanceRouteWithoutItsTokenIsHiddenWithoutReadingOrParsing() {
		var h = harness({});
		var src = source("POST", "/api/maintenance/instrument/import", { "content-length": "50000000" }, variables.MALFORMED);
		assertThrows(function() { h.router.handle(src); }, "ICFWalk.NotFound", "NOT_FOUND");
		assertEquals(0, src.readCount());
		assertEquals(0, h.parser.calls());
	}

	/** A route with no limit of its own is held to the server maximum, which is larger. */
	public void function testEveryOtherRouteIsBoundedByTheServerMaximum() {
		var h = harness({});
		var src = source("PUT", "/api/walks/" & createUUID(), authorized({ "content-length": "5000001" }), "{}");
		h.router.handle(src);
		assertEquals(1, src.readCount(), "a walk save larger than the import limit is still read");
		assertTrue(src.readLimits()[1] > variables.LIMIT, "under the server maximum, not the import limit");
		var huge = source("PUT", "/api/walks/" & createUUID(), authorized({ "content-length": toString(src.readLimits()[1] + 1) }), "{}");
		assertThrows(function() { h.router.handle(huge); }, "ICFWalk.PayloadTooLarge", "PAYLOAD_TOO_LARGE");
		assertEquals(0, huge.readCount());
	}

	// ---- helpers ---------------------------------------------------------------------------------

	/** A real Router over a container whose identity, CSRF, permission and controllers are doubles. */
	private struct function harness(required struct opts) {
		var doubles = createObject("component", "icfwalktests.support.RouterTestDoubles").init(
			variables.c.errors,
			structKeyExists(arguments.opts, "anonymous") && arguments.opts.anonymous,
			variables.CSRF,
			structKeyExists(arguments.opts, "deny") && arguments.opts.deny
		);
		var parser = createObject("component", "icfwalktests.support.SpyJsonBodyParser").init(variables.c.jsonBodyParser);
		var container = structCopy(variables.c);
		container["authenticationService"] = doubles;
		container["sessionService"] = doubles;
		container["authorizationService"] = doubles;
		container["jsonBodyParser"] = parser;
		for (var name in ["adminInstrumentController", "walkController"]) container[name] = doubles;
		return { "router": createObject("component", "icfwalk.http.Router").init(container), "doubles": doubles, "parser": parser };
	}

	private any function source(required string method, required string path, struct headers = {}, string body = "") {
		return createObject("component", "icfwalktests.support.FakeRequestSource").init(arguments.method, arguments.path, arguments.headers, arguments.body);
	}

	private struct function authorized(required struct headers) {
		var h = duplicate(arguments.headers);
		h["x-icfwalk-csrf-token"] = variables.CSRF;
		if (!structKeyExists(h, "content-type")) h["content-type"] = "application/json";
		return h;
	}
}
