/**
 * Phase 8, defect P8-09: a CFML boolean is a boolean on both engines.
 *
 * core/JsonTypes decides a value's JSON type by its Java class, so that "true", "yes", 1 and 0 are
 * never taken for booleans. It recognised java.lang.Boolean only -- what deserializeJSON produces on
 * both engines, and what a CFML literal is on Lucee. On Adobe ColdFusion 2023 a literal `true` or
 * `false`, and the result of a comparison, is coldfusion.runtime.CFBoolean, so every CFML caller
 * passing a real boolean (InstrumentMetadataService's `active`, through its specs) was refused as
 * "an unsupported value" there.
 */
component extends="icfwalktests.BaseSpec" output="false" {

	public void function testLiteralsAndComparisonsAreBooleans() {
		var types = new icfwalk.core.JsonTypes();
		var compared = (1 == 1);
		for (var value in [true, false, compared, !compared]) {
			assertTrue(types.isJsonBoolean(value), types.classOf(value) & " is a boolean");
			assertExactTextEquals("a boolean", types.describe(value));
		}
		var parsed = deserializeJSON('{"t":true,"f":false}');
		assertTrue(types.isJsonBoolean(parsed.t) && types.isJsonBoolean(parsed.f), "and so is a JSON boolean");
	}

	public void function testNothingElseIsTakenForABoolean() {
		var types = new icfwalk.core.JsonTypes();
		for (var value in ["true", "false", "yes", "no", 1, 0, "1", "0", "on"]) {
			assertFalse(types.isJsonBoolean(value), serializeJSON(value) & " (" & types.classOf(value) & ") is not a boolean");
		}
		assertFalse(types.isJsonBoolean(javaCast("null", "")));
		assertFalse(types.isJsonBoolean({}));
	}
}
