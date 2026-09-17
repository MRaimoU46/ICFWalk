/**
 * Base class for CFML specs: assertion helpers and lifecycle hooks. Access the application
 * container through variables.c (for example variables.c.db, variables.c.instrumentImportService).
 */
component output="false" {

	public any function init(required struct container) {
		variables.c = arguments.container;
		return this;
	}

	/** Return a non-empty reason to skip the whole spec (for example, no database schema). */
	public string function skipReason() { return ""; }
	public void function beforeAll() {}
	public void function beforeEach() {}
	public void function afterAll() {}

	public boolean function schemaPresent() {
		try {
			var q = variables.c.db.run("SELECT CASE WHEN OBJECT_ID(N'[icf].[instrument]', N'U') IS NULL THEN 0 ELSE 1 END AS has_schema");
			return q.has_schema[1] == 1;
		} catch (any e) {
			return false;
		}
	}

	public string function repoFile(required string relativePath) {
		return fileRead(variables.c.repoRoot & arguments.relativePath, "utf-8");
	}

	public any function repoJson(required string relativePath) {
		return deserializeJSON(repoFile(arguments.relativePath));
	}

	// ---- assertions -------------------------------------------------------------------------

	public void function fail(required string message) {
		throw(type = "ICFWalk.Test.AssertionFailed", message = arguments.message);
	}

	public void function assertTrue(required any condition, string message = "Expected condition to be true.") {
		if (!(isBoolean(arguments.condition) && arguments.condition)) fail(arguments.message);
	}

	public void function assertFalse(required any condition, string message = "Expected condition to be false.") {
		if (isBoolean(arguments.condition) && arguments.condition) fail(arguments.message);
	}

	public void function assertEquals(required any expected, required any actual, string message = "") {
		var e = isSimpleValue(arguments.expected) ? toString(arguments.expected) : serializeJSON(arguments.expected);
		var a = isSimpleValue(arguments.actual) ? toString(arguments.actual) : serializeJSON(arguments.actual);
		if (e != a) {
			fail((len(arguments.message) ? arguments.message & " " : "") & "Expected [" & left(e, 300) & "] but got [" & left(a, 300) & "].");
		}
	}

	public void function assertNotEquals(required any expected, required any actual, string message = "") {
		var e = isSimpleValue(arguments.expected) ? toString(arguments.expected) : serializeJSON(arguments.expected);
		var a = isSimpleValue(arguments.actual) ? toString(arguments.actual) : serializeJSON(arguments.actual);
		if (e == a) fail((len(arguments.message) ? arguments.message & " " : "") & "Expected values to differ but both were [" & left(e, 300) & "].");
	}

	public void function assertContains(required string needle, required string haystack, string message = "") {
		if (!find(arguments.needle, arguments.haystack)) fail((len(arguments.message) ? arguments.message & " " : "") & "Expected to find [" & arguments.needle & "] in [" & left(arguments.haystack, 300) & "].");
	}

	/**
	 * Runs fn and asserts it throws an exception whose type starts with typePrefix (and, when
	 * given, whose errorcode equals code). Returns the caught exception for further assertions.
	 */
	public any function assertThrows(required any fn, required string typePrefix, string code = "") {
		try {
			arguments.fn();
		} catch (any e) {
			if (left(e.type, len(arguments.typePrefix)) != arguments.typePrefix) {
				fail("Expected exception type starting with [" & arguments.typePrefix & "] but got [" & e.type & "]: " & e.message);
			}
			if (len(arguments.code) && (!structKeyExists(e, "errorcode") || e.errorcode != arguments.code)) {
				fail("Expected errorcode [" & arguments.code & "] but got [" & (structKeyExists(e, "errorcode") ? e.errorcode : "") & "]: " & e.message);
			}
			return e;
		}
		fail("Expected an exception of type [" & arguments.typePrefix & "] but nothing was thrown.");
	}
}
