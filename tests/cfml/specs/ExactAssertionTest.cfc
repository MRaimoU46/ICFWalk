/**
 * The shared exact-comparison helpers in BaseSpec, exercised directly: the same implementation
 * every migrated spec calls.
 *
 * WHY. BaseSpec.assertEquals / assertNotEquals compare stringified values with CFML's != / ==,
 * which ignore case and compare numeric-looking strings as numbers. On Lucee 6.2.8.20 that made
 * "ICFWalk" equal "Icfwalk" and the row version 000000000000E988 equal 000000000000E989 (each reads
 * as zero in exponent notation), so an "unchanged" assertion could pass although the value moved
 * and a "changed" assertion could fail although it did move. Exact contracts -- text, identifiers,
 * codes, checksums, structures and row versions -- now go through assertExactTextEquals,
 * assertExactTextNotEquals, assertRowVersionEquals, assertRowVersionChanged and
 * assertExactJsonEquals. Each case below proves one direction of one helper, with the two pairs
 * the defect was observed on.
 *
 * The last two cases are the guard against a regression: the coercive helpers refuse a
 * row-version-shaped value at run time, and no spec passes a row-version expression or a quoted
 * text literal to them, or compares a row version with a bare operator.
 */
component extends="icfwalktests.BaseSpec" output="false" {

	variables.CASE_PAIR = ["ICFWalk", "Icfwalk"];
	variables.HEX_PAIR = ["000000000000E988", "000000000000E989"];

	// ---- exact text ------------------------------------------------------------------------------

	public void function testExactTextTellsACaseOnlyDifferenceApart() {
		var e = variables.CASE_PAIR[1];
		var a = variables.CASE_PAIR[2];
		var message = failureOf(function() { assertExactTextEquals(e, a, "metadata name"); });
		assertContains("metadata name", message, "the caller's message leads the failure");
		assertContains("[ICFWalk] (7 chars)", message, "the failure shows the expected value");
		assertContains("[Icfwalk] (7 chars)", message, "the failure shows the actual value");
		assertContains("first difference is at character 2 ([C] expected, [c] found)", message, "and where they differ");
		assertExactTextNotEquals(e, a, "distinct text is reported as distinct");
	}

	public void function testIdenticalTextPassesTheEqualsHelper() {
		assertExactTextEquals("ICFWalk", "ICFWalk");
		assertExactTextEquals("", "", "the empty text equals itself");
		assertExactTextEquals("04", "04", "numeric-looking text equals itself");
	}

	public void function testIdenticalTextFailsTheNotEqualsHelper() {
		var message = failureOf(function() { assertExactTextNotEquals("ICFWalk", "ICFWalk", "renamed"); });
		assertContains("renamed", message);
		assertContains("Expected a value other than [ICFWalk] (7 chars) but got exactly that: [ICFWalk] (7 chars)", message);
	}

	public void function testExactTextNeverReadsTextAsANumberOrABoolean() {
		// Each pair is equal under CFML's == (observed on Lucee 6.2.8.20) and different as text.
		for (var pair in [["4", "04"], ["1E3", "1000"], ["0", "0.0"], ["true", "YES"], ["ICFWALK_DRAFT", "icfwalk_draft"]]) {
			var e = pair[1];
			var a = pair[2];
			var message = failureOf(function() { assertExactTextEquals(e, a); });
			assertContains("[" & e & "]", message, "the failure shows [" & e & "]");
			assertContains("[" & a & "]", message, "the failure shows [" & a & "]");
			assertExactTextNotEquals(e, a, "[" & e & "] and [" & a & "] are different text");
		}
	}

	public void function testExactTextRefusesNullAndStructuresInsteadOfStringifyingThem() {
		assertContains("null expected value", failureOf(function() { assertExactTextEquals(javaCast("null", ""), "x"); }));
		assertContains("null actual value", failureOf(function() { assertExactTextEquals("x", javaCast("null", "")); }));
		assertContains("the expected value is a struct", failureOf(function() { assertExactTextEquals({ "a": 1 }, "x"); }));
		assertContains("the actual value is an array", failureOf(function() { assertExactTextNotEquals("x", ["x"]); }));
	}

	// ---- row versions ----------------------------------------------------------------------------

	public void function testRowVersionsE988AndE989AreDifferentTokens() {
		var before = variables.HEX_PAIR[1];
		var after = variables.HEX_PAIR[2];
		var message = failureOf(function() { assertRowVersionEquals(before, after, "version row_version"); });
		assertContains("version row_version", message);
		assertContains("Expected row version [000000000000E988] (16 chars) but got [000000000000E989] (16 chars)", message);
		assertContains("first difference is at character 16 ([8] expected, [9] found)", message);
		assertRowVersionChanged(before, after, "E988 to E989 is a change");
	}

	public void function testIdenticalRowVersionsPassTheEqualsHelper() {
		assertRowVersionEquals("000000000000E988", "000000000000E988");
		assertRowVersionEquals("0x000000000000E988", "0x000000000000E988", "the walk form, 0x-prefixed");
		assertRowVersionEquals("59784", "59784", "a high-water mark read as decimal text");
	}

	public void function testIdenticalRowVersionsFailTheChangedHelper() {
		var message = failureOf(function() { assertRowVersionChanged("000000000000E988", "000000000000E988", "saved"); });
		assertContains("saved", message);
		assertContains("Expected the row version to change from [000000000000E988] (16 chars) but it is still exactly [000000000000E988] (16 chars)", message);
	}

	public void function testRowVersionsAreNeverNormalized() {
		// Case, the 0x prefix, padding, and two tokens that are both zero in exponent notation.
		for (var pair in [
			["0x000000000000E988", "0x000000000000e988"],
			["0x000000000000E988", "000000000000E988"],
			["000000000000E988", "00000000000E988"],
			["0000000000000000", "000000000000E988"],
			["00000000000012E4", "0000000000120000"]
		]) {
			var e = pair[1];
			var a = pair[2];
			var message = failureOf(function() { assertRowVersionEquals(e, a); });
			assertContains("[" & e & "]", message);
			assertContains("[" & a & "]", message);
			assertRowVersionChanged(e, a, "[" & e & "] and [" & a & "] are different tokens");
		}
	}

	public void function testAnUnreadRowVersionIsRefusedRatherThanCompared() {
		assertContains("empty expected row version", failureOf(function() { assertRowVersionEquals("", ""); }));
		assertContains("empty before row version", failureOf(function() { assertRowVersionChanged("", "000000000000E988"); }));
		assertContains("null after value", failureOf(function() { assertRowVersionChanged("000000000000E988", javaCast("null", "")); }));
		assertContains("the actual value is a struct", failureOf(function() { assertRowVersionEquals("000000000000E988", {}); }));
	}

	// ---- structures ------------------------------------------------------------------------------

	public void function testExactJsonKeepsTheCaseOfCodesAndKeys() {
		assertExactJsonEquals(["DRAFT", "PUBLISHED"], ["DRAFT", "PUBLISHED"]);
		assertExactJsonEquals({ "changedFields": ["name"] }, { "changedFields": ["name"] });
		var message = failureOf(function() { assertExactJsonEquals(["DRAFT"], ["draft"], "statuses"); });
		assertContains("statuses", message);
		assertContains('["DRAFT"]', message);
		assertContains('["draft"]', message);
		assertContains("first difference is at character 3 ([D] expected, [d] found)", message);
		failureOf(function() { assertExactJsonEquals({ "code": "A" }, { "code": "a" }); });
		failureOf(function() { assertExactJsonEquals(["a", "b"], ["b", "a"]); });
	}

	// ---- errorcodes ------------------------------------------------------------------------------

	public void function testAssertThrowsComparesTheErrorcodeExactly() {
		var thrower = function() { throw(type = "ICFWalk.Validation", message = "refused", errorcode = "INSTRUMENT_VERSION_NOT_DRAFT"); };
		var e = assertThrows(thrower, "ICFWalk.Validation", "INSTRUMENT_VERSION_NOT_DRAFT");
		assertExactTextEquals("INSTRUMENT_VERSION_NOT_DRAFT", e.errorcode);
		var message = failureOf(function() { assertThrows(thrower, "ICFWalk.Validation", "instrument_version_not_draft"); });
		assertContains("Expected errorcode [instrument_version_not_draft] but got [INSTRUMENT_VERSION_NOT_DRAFT]", message);
		// The type prefix is matched the way CFML resolves exception types, case-insensitively.
		assertThrows(thrower, "icfwalk.validation", "INSTRUMENT_VERSION_NOT_DRAFT");
		assertContains("Expected exception type starting with [ICFWalk.Conflict]", failureOf(function() { assertThrows(thrower, "ICFWalk.Conflict"); }));
	}

	// ---- the guard -------------------------------------------------------------------------------

	public void function testTheCoerciveHelpersRefuseARowVersionToken() {
		for (var token in ["000000000000E988", "0x000000000000E988", "0x000000000000e988"]) {
			var t = token;
			assertContains("[" & t & "], which has the shape of a row-version token", failureOf(function() { assertEquals(t, t); }));
			assertContains("assertRowVersionEquals or assertRowVersionChanged", failureOf(function() { assertNotEquals(t, "000000000000E989"); }));
		}
		// Their numeric and boolean contract is unchanged.
		assertEquals(144, 144);
		assertEquals(3, 3.0);
		assertNotEquals(144, 145);
		assertEquals(true, true);
	}

	/**
	 * A structural guard over the source of every spec and support component: none passes an
	 * expression naming a row version, or a quoted text literal, to the coercive assertEquals /
	 * assertNotEquals, none compares a row version with ==, !=, EQ or NEQ, and none defines its own
	 * method under a shared assertion's name, which would shadow the implementation proved here.
	 * Comments and string literals are blanked first so that prose and messages cannot trip it.
	 * This spec is the one file excluded, because it feeds the coercive helpers on purpose to prove
	 * they refuse.
	 *
	 * The run-time refusal above covers the values, including aliases such as r0 or token whose
	 * names say nothing; this covers the paths a run does not execute.
	 */
	public void function testNoSpecSendsARowVersionOrALiteralTextThroughTheCoercivePath() {
		var files = [];
		for (var dir in ["specs", "support"]) {
			for (var path in directoryList(variables.c.repoRoot & "tests/cfml/" & dir, false, "path", "*.cfc", "name asc")) {
				if (compare(getFileFromPath(path), "ExactAssertionTest.cfc") != 0) arrayAppend(files, path);
			}
		}
		assertTrue(arrayLen(files) >= 35, "the scan found only " & arrayLen(files) & " source files; it is not reading the suite");
		var findings = [];
		var coerciveCalls = 0;
		for (var path in files) {
			var code = codeOnly(fileRead(path, "utf-8"));
			var name = getFileFromPath(path);
			var at = 1;
			while (true) {
				var m = reFindNoCase("\b(assertEquals|assertNotEquals)\s*\(", code, at, true);
				if (m.pos[1] == 0) break;
				var open = m.pos[1] + m.len[1] - 1;
				var close = closingParen(code, open);
				var args = topLevelArguments(mid(code, open + 1, close - open - 1));
				var where = name & ":" & lineAt(code, m.pos[1]) & " ";
				var helper = mid(code, m.pos[2], m.len[2]);
				coerciveCalls++;
				for (var i = 1; i <= min(2, arrayLen(args)); i++) {
					if (reFindNoCase("row_?version|\brv[0-9]*\b", args[i])) arrayAppend(findings, where & "passes a row version to " & helper);
					if (reFind("^\s*[""']", args[i])) arrayAppend(findings, where & "passes a quoted text literal to " & helper);
				}
				at = open + 1;
			}
			// A spec-local method of the same name would shadow the shared implementation.
			var redefined = reFindNoCase("\bfunction\s+(assert(Exact|RowVersion)[A-Za-z]*|assertEquals|assertNotEquals|assertThrows)\s*\(", code, 1, true);
			if (redefined.pos[1]) {
				arrayAppend(findings, name & ":" & lineAt(code, redefined.pos[1]) & " redefines the shared helper " & mid(code, redefined.pos[2], redefined.len[2]));
			}
			var lines = listToArray(code, chr(10), true);
			for (var i = 1; i <= arrayLen(lines); i++) {
				// A comparison with a number literal (compare(a, b) != 0, len(token) == 18) is not a comparison of two row versions.
				var line = reReplace(lines[i], "(==|!=)\s*-?[0-9]+\b|\b-?[0-9]+\s*(==|!=)", " ", "all");
				if (reFindNoCase("row_?version|\brv[0-9]*\b", line) && reFindNoCase("==|!=|\bneq\b|\beq\b", line)) {
					arrayAppend(findings, name & ":" & i & " compares a row version with a CFML operator");
				}
			}
		}
		assertTrue(coerciveCalls > 100, "the scan found only " & coerciveCalls & " coercive assertion calls; it is not parsing the sources");
		if (arrayLen(findings)) fail(arrayLen(findings) & " coercive comparison(s) of exact values: " & arrayToList(findings, "; "));
	}

	// ---- support ---------------------------------------------------------------------------------

	/** Runs fn, which must fail through BaseSpec.fail, and returns the failure message. */
	private string function failureOf(required any fn) {
		try {
			arguments.fn();
		} catch (ICFWalk.Test.AssertionFailed e) {
			return e.message;
		}
		fail("Expected the assertion to fail, but it passed.");
	}

	/**
	 * The source with every comment and string literal replaced by spaces, newlines kept, so that
	 * positions and line numbers still refer to the original file. A quoted literal is kept as its
	 * opening quote followed by spaces, so a call whose argument starts with one is still visible.
	 */
	private string function codeOnly(required string source) {
		var matcher = createObject("java", "java.util.regex.Pattern").compile("""(?:[^""]|"""")*""|'(?:[^']|'')*'|//[^\n]*|/\*[\s\S]*?\*/").matcher(arguments.source);
		var out = createObject("java", "java.lang.StringBuilder").init();
		var last = 0;
		while (matcher.find()) {
			var start = matcher.start();
			if (start > last) out.append(javaCast("string", mid(arguments.source, last + 1, start - last)));
			var token = matcher.group();
			var blank = reReplace(token, "[^\n]", " ", "all");
			var first = left(token, 1);
			if (compare(first, """") == 0 || compare(first, "'") == 0) blank = first & mid(blank, 2, len(blank));
			out.append(javaCast("string", blank));
			last = matcher.end();
		}
		if (len(arguments.source) > last) out.append(javaCast("string", mid(arguments.source, last + 1, len(arguments.source) - last)));
		return out.toString();
	}

	/** The comma-separated arguments of a call, split only at the top level of (), [] and {}. */
	private array function topLevelArguments(required string argumentText) {
		var out = [];
		var depth = 0;
		var from = 1;
		var n = len(arguments.argumentText);
		for (var i = 1; i <= n; i++) {
			var ch = mid(arguments.argumentText, i, 1);
			if (find(ch, "([{")) depth++;
			else if (find(ch, ")]}")) depth--;
			else if (depth == 0 && compare(ch, ",") == 0) {
				arrayAppend(out, mid(arguments.argumentText, from, i - from));
				from = i + 1;
			}
		}
		arrayAppend(out, mid(arguments.argumentText, from, n - from + 1));
		return out;
	}

	/** Position of the parenthesis that closes the one at `open` (the source is already comment- and string-free). */
	private numeric function closingParen(required string code, required numeric open) {
		var depth = 0;
		var n = len(arguments.code);
		for (var i = arguments.open; i <= n; i++) {
			var ch = mid(arguments.code, i, 1);
			if (compare(ch, "(") == 0) depth++;
			else if (compare(ch, ")") == 0) {
				depth--;
				if (depth == 0) return i;
			}
		}
		fail("unbalanced parentheses after position " & arguments.open);
	}

	private numeric function lineAt(required string code, required numeric position) {
		return listLen(left(arguments.code, arguments.position), chr(10), true);
	}
}
