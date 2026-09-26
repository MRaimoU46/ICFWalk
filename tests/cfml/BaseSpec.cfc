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

	/**
	 * Everything a caught exception says, on either engine. For a database error Lucee's message is
	 * SQL Server's own text, while Adobe ColdFusion's message is "Error Executing Database Query." and
	 * SQL Server's text is in detail (P8-07). A spec that recognises a refusal by the database's words
	 * reads them here.
	 */
	public string function errorText(required any exception) {
		var text = "";
		try { text &= arguments.exception.message; } catch (any ignored) {}
		try { if (len(arguments.exception.detail)) text &= " " & arguments.exception.detail; } catch (any ignored) {}
		return text;
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

	// ---- exact comparisons ----------------------------------------------------------------------
	//
	// assertEquals and assertNotEquals (below) stringify both values and compare them with CFML's
	// != and ==. Those operators ignore case, compare two numeric-looking strings as numbers and
	// two boolean-looking strings as booleans, so they cannot tell "ICFWalk" from "Icfwalk", "4"
	// from "04", or the row version 000000000000E988 from 000000000000E989 (both read as zero in
	// exponent notation). Every value whose contract is exact -- text, identifiers, codes,
	// statuses, checksums, canonical JSON, stored codes, opaque tokens and row versions -- is
	// compared by these helpers instead, with compare(), which is case-sensitive and never
	// reinterprets text. Nothing is trimmed, re-cased, padded or stripped of a prefix: two values
	// are equal only when they are the same characters.

	/** Exact, case-sensitive text equality of two simple values. */
	public void function assertExactTextEquals(any expected, any actual, string message = "") {
		if (!structKeyExists(arguments, "expected") || !structKeyExists(arguments, "actual")) failOnNull("assertExactTextEquals", !structKeyExists(arguments, "expected") ? "expected" : "actual", arguments.message);
		var e = exactText("assertExactTextEquals", "expected", arguments.expected, arguments.message);
		var a = exactText("assertExactTextEquals", "actual", arguments.actual, arguments.message);
		if (compare(e, a) != 0) {
			fail(lead(arguments.message) & "Expected exactly " & shown(e, a) & " but got " & shown(a, e) & difference(e, a) & ".");
		}
	}

	/** The two simple values are not the same text, compared exactly and case-sensitively. */
	public void function assertExactTextNotEquals(any unexpected, any actual, string message = "") {
		if (!structKeyExists(arguments, "unexpected") || !structKeyExists(arguments, "actual")) failOnNull("assertExactTextNotEquals", !structKeyExists(arguments, "unexpected") ? "unexpected" : "actual", arguments.message);
		var u = exactText("assertExactTextNotEquals", "unexpected", arguments.unexpected, arguments.message);
		var a = exactText("assertExactTextNotEquals", "actual", arguments.actual, arguments.message);
		if (compare(u, a) == 0) {
			fail(lead(arguments.message) & "Expected a value other than " & shown(u, a) & " but got exactly that: " & shown(a, u) & ".");
		}
	}

	/**
	 * Row versions are opaque tokens: the same row version is the same characters. Hex such as
	 * 000000000000E988 is never read as a number, a 0x prefix is never added or removed, and case
	 * and padding are never normalized. An empty token is refused rather than compared, so a row
	 * version that was never read cannot make "unchanged" true.
	 */
	public void function assertRowVersionEquals(any expected, any actual, string message = "") {
		if (!structKeyExists(arguments, "expected") || !structKeyExists(arguments, "actual")) failOnNull("assertRowVersionEquals", !structKeyExists(arguments, "expected") ? "expected" : "actual", arguments.message);
		var e = rowVersionToken("assertRowVersionEquals", "expected", arguments.expected, arguments.message);
		var a = rowVersionToken("assertRowVersionEquals", "actual", arguments.actual, arguments.message);
		if (compare(e, a) != 0) {
			fail(lead(arguments.message) & "Expected row version " & shown(e, a) & " but got " & shown(a, e) & difference(e, a) & ".");
		}
	}

	/** The row version moved: `after` is not exactly the token `before` was. */
	public void function assertRowVersionChanged(any before, any after, string message = "") {
		if (!structKeyExists(arguments, "before") || !structKeyExists(arguments, "after")) failOnNull("assertRowVersionChanged", !structKeyExists(arguments, "before") ? "before" : "after", arguments.message);
		var b = rowVersionToken("assertRowVersionChanged", "before", arguments.before, arguments.message);
		var a = rowVersionToken("assertRowVersionChanged", "after", arguments.after, arguments.message);
		if (compare(b, a) == 0) {
			fail(lead(arguments.message) & "Expected the row version to change from " & shown(b, a) & " but it is still exactly " & shown(a, b) & ".");
		}
	}

	/**
	 * Structures (arrays, structs) and typed JSON values: equal only when their canonical JSON --
	 * the application's own wire form (core/CanonicalJson: keys sorted, strings exact, a number in
	 * its shortest decimal form) -- is identical, character for character. Unlike assertEquals, codes
	 * and keys inside the structure keep their case, and a string never equals the number it spells.
	 *
	 * It used to compare the engine's serializeJSON text, which is not one text across engines: Adobe
	 * ColdFusion writes a whole-number double as 10.0 where Lucee writes 10, and can write a numeric
	 * string as a number. The client never sees either form; it sees canonical JSON (P8-07).
	 */
	public void function assertExactJsonEquals(any expected, any actual, string message = "") {
		if (!structKeyExists(arguments, "expected") || !structKeyExists(arguments, "actual")) failOnNull("assertExactJsonEquals", !structKeyExists(arguments, "expected") ? "expected" : "actual", arguments.message);
		var e = variables.c.canonicalJson.serialize(arguments.expected);
		var a = variables.c.canonicalJson.serialize(arguments.actual);
		if (compare(e, a) != 0) {
			fail(lead(arguments.message) & "Expected JSON " & shown(e, a) & " but got " & shown(a, e) & difference(e, a) & ".");
		}
	}

	// ---- general (coercive) comparisons ----------------------------------------------------------

	/**
	 * General equality for numeric and boolean contracts (counts, lengths, statuses as numbers,
	 * flags). Both values are stringified and compared with CFML's !=, which is what makes 3 equal
	 * 3.0 -- and also what makes "ICFWalk" equal "Icfwalk" and 000000000000E988 equal
	 * 000000000000E989. It is therefore not an exact comparison and is not used for text,
	 * identifiers, codes, checksums, tokens, structures or row versions (see the exact helpers
	 * above). A value shaped like a row-version token is refused outright.
	 */
	public void function assertEquals(required any expected, required any actual, string message = "") {
		refuseRowVersionToken("assertEquals", arguments.expected, arguments.actual);
		var e = isSimpleValue(arguments.expected) ? toString(arguments.expected) : serializeJSON(arguments.expected);
		var a = isSimpleValue(arguments.actual) ? toString(arguments.actual) : serializeJSON(arguments.actual);
		if (e != a) {
			fail((len(arguments.message) ? arguments.message & " " : "") & "Expected [" & left(e, 300) & "] but got [" & left(a, 300) & "].");
		}
	}

	/** The coercive counterpart of assertEquals, with the same limits; see there. */
	public void function assertNotEquals(required any expected, required any actual, string message = "") {
		refuseRowVersionToken("assertNotEquals", arguments.expected, arguments.actual);
		var e = isSimpleValue(arguments.expected) ? toString(arguments.expected) : serializeJSON(arguments.expected);
		var a = isSimpleValue(arguments.actual) ? toString(arguments.actual) : serializeJSON(arguments.actual);
		if (e == a) fail((len(arguments.message) ? arguments.message & " " : "") & "Expected values to differ but [" & left(e, 300) & "] and [" & left(a, 300) & "] compare equal under CFML ==.");
	}

	public void function assertContains(required string needle, required string haystack, string message = "") {
		if (!find(arguments.needle, arguments.haystack)) fail((len(arguments.message) ? arguments.message & " " : "") & "Expected to find [" & arguments.needle & "] in [" & left(arguments.haystack, 300) & "].");
	}

	/**
	 * Runs fn and asserts it throws an exception whose type starts with typePrefix (and, when
	 * given, whose errorcode is exactly code). Returns the caught exception for further assertions.
	 *
	 * The type prefix is matched case-insensitively on purpose: that is how CFML itself resolves
	 * exception types (`catch (ICFWalk.Validation e)`, and the switch in Errors.statusFor that maps
	 * a type to its HTTP status), so it is the contract production relies on. The errorcode is
	 * compared exactly, because it is what a client receives as error.code.
	 */
	public any function assertThrows(required any fn, required string typePrefix, string code = "") {
		try {
			arguments.fn();
		} catch (any e) {
			if (compareNoCase(left(e.type, len(arguments.typePrefix)), arguments.typePrefix) != 0) {
				fail("Expected exception type starting with [" & arguments.typePrefix & "] but got [" & e.type & "]: " & e.message);
			}
			if (len(arguments.code) && (!structKeyExists(e, "errorcode") || compare(e.errorcode, arguments.code) != 0)) {
				fail("Expected errorcode [" & arguments.code & "] but got [" & (structKeyExists(e, "errorcode") ? e.errorcode : "") & "]: " & e.message);
			}
			return e;
		}
		fail("Expected an exception of type [" & arguments.typePrefix & "] but nothing was thrown.");
	}

	// ---- support for the exact comparisons -------------------------------------------------------

	private string function lead(required string message) {
		return len(arguments.message) ? arguments.message & " " : "";
	}

	private void function failOnNull(required string helper, required string role, required string message) {
		fail(lead(arguments.message) & arguments.helper & " was given a null " & arguments.role & " value, and null is not comparable.");
	}

	/** The value's text, exactly as it is; a structure is refused rather than stringified. */
	private string function exactText(required string helper, required string role, required any value, required string message) {
		if (!isSimpleValue(arguments.value)) {
			var kind = isArray(arguments.value) ? "an array" : (isStruct(arguments.value) ? "a struct" : (isQuery(arguments.value) ? "a query" : "a complex value"));
			fail(lead(arguments.message) & arguments.helper & " compares simple values, but the " & arguments.role & " value is " & kind & "; compare structures with assertExactJsonEquals.");
		}
		return toString(arguments.value);
	}

	private string function rowVersionToken(required string helper, required string role, required any value, required string message) {
		var token = exactText(arguments.helper, arguments.role, arguments.value, arguments.message);
		if (!len(token)) {
			fail(lead(arguments.message) & arguments.helper & " was given an empty " & arguments.role & " row version; a row version that was never read cannot be compared.");
		}
		return token;
	}

	/** 1-based index of the first differing character, one past the shorter text when one is a prefix of the other, 0 when identical. */
	private numeric function firstDifferenceAt(required string a, required string b) {
		var n = min(len(arguments.a), len(arguments.b));
		for (var i = 1; i <= n; i++) {
			if (compare(mid(arguments.a, i, 1), mid(arguments.b, i, 1)) != 0) return i;
		}
		return len(arguments.a) == len(arguments.b) ? 0 : n + 1;
	}

	/** [value] and its length; a long value is shown as the window around its first difference from `other`. */
	private string function shown(required string value, required string other) {
		var n = len(arguments.value);
		if (n <= 300) return "[" & arguments.value & "] (" & n & " chars)";
		var from = max(1, firstDifferenceAt(arguments.value, arguments.other) - 60);
		return "[" & (from > 1 ? "..." : "") & mid(arguments.value, from, 180) & (from + 180 <= n ? "..." : "") & "] (" & n & " chars)";
	}

	private string function difference(required string expected, required string actual) {
		var at = firstDifferenceAt(arguments.expected, arguments.actual);
		if (at == 0) return "";
		if (at > min(len(arguments.expected), len(arguments.actual))) {
			return "; one is a prefix of the other (" & len(arguments.expected) & " and " & len(arguments.actual) & " chars)";
		}
		return "; the first difference is at character " & at & " ([" & mid(arguments.expected, at, 1) & "] expected, [" & mid(arguments.actual, at, 1) & "] found)";
	}

	/**
	 * Keeps row versions off the coercive path. Text that is exactly 16 hexadecimal digits,
	 * optionally 0x-prefixed, is how this application writes a row version (binaryEncode(..., "hex")
	 * for instrument rows, CONVERT(varchar(18), ..., 1) for walks), and CFML's == reads the
	 * unprefixed form as a number whenever it is digits around a single E.
	 */
	private void function refuseRowVersionToken(required string helper, required any expected, required any actual) {
		for (var v in [arguments.expected, arguments.actual]) {
			if (isSimpleValue(v) && reFind("^(0[xX])?[0-9A-Fa-f]{16}$", toString(v))) {
				fail(arguments.helper & " was given [" & toString(v) & "], which has the shape of a row-version token. CFML's == can read it as a number and ignores case, so row versions are compared with assertRowVersionEquals or assertRowVersionChanged, and other exact text with assertExactTextEquals.");
			}
		}
	}
}
