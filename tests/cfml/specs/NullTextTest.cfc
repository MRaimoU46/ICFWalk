/**
 * Phase 8, defect P8-08: the text "null" is text, at every core boundary.
 *
 * Adobe ColdFusion 2023's isNull() is true for a string whose value is "null" in any letter case --
 * a literal, a value parsed from JSON, one read from a struct or passed as an argument. Every
 * `isNull(value)` guard in the application therefore took such text for an absent value: the
 * database binders sent SQL NULL (a person named Null could not be provisioned, a note "null"
 * vanished), canonical JSON wrote `null` in place of the string, and the type helpers called it
 * no value at all. Lucee answers false. A real null is detected on both engines by structKeyExists
 * (false for a null-valued key, a null or omitted argument, and a null local) and by
 * arrayIsDefined, which is what the application now uses.
 *
 * These cases hold on either engine; tests/node/null-text.test.mjs proves the same end to end.
 */
component extends="icfwalktests.BaseSpec" output="false" {

	variables.SPELLINGS = ["null", "NULL", "Null", "nUlL"];

	public void function testTheDatabaseBindersBindTheTextNotNull() {
		for (var text in variables.SPELLINGS) {
			for (var binder in ["nvarchar", "ntext"]) {
				var param = invoke(variables.c.db, binder, [text]);
				assertFalse(structKeyExists(param, "null") && param["null"], binder & "(" & serializeJSON(text) & ") binds SQL NULL");
				assertExactTextEquals(text, param.value, binder & " keeps the text");
			}
			var q = variables.c.db.run("SELECT :v AS v, CASE WHEN :w IS NULL THEN 1 ELSE 0 END AS was_null", { "v": variables.c.db.nvarchar(text), "w": variables.c.db.ntext(text) });
			assertExactTextEquals(text, q.v[1], "the database receives " & serializeJSON(text));
			assertEquals(0, q.was_null[1], "and not NULL");
		}
	}

	public void function testCanonicalJsonWritesTheStringNotNull() {
		var json = variables.c.canonicalJson;
		for (var text in variables.SPELLINGS) {
			assertExactTextEquals('"' & text & '"', json.serialize(text));
			assertExactTextEquals('{"k":"' & text & '"}', json.serialize({ "k": text }));
			assertExactTextEquals('["' & text & '"]', json.serialize([text]));
		}
		// And a real null is still null.
		assertExactTextEquals('{"k":null}', json.serialize({ "k": javaCast("null", "") }));
	}

	public void function testTheTypeHelpersCallItAString() {
		var types = new icfwalk.core.JsonTypes();
		for (var text in variables.SPELLINGS) {
			assertTrue(types.isJsonString(text), serializeJSON(text) & " is a JSON string");
			assertExactTextEquals("a string", types.describe(text));
			var parsed = deserializeJSON('{"k":"' & text & '"}');
			assertTrue(types.isJsonString(parsed.k), "parsed " & serializeJSON(text) & " is a JSON string");
		}
	}

	public void function testTheHtmlEncoderKeepsIt() {
		var html = new icfwalk.core.HtmlEncoder();
		for (var text in variables.SPELLINGS) assertExactTextEquals(text, html.encode(text));
	}
}
