component extends="icfwalktests.BaseSpec" output="false" {

	public void function testSharedVectorsProduceIdenticalCanonicalText() {
		var vectors = repoJson("tests/fixtures/canonical-json-vectors.json").vectors;
		assertTrue(arrayLen(vectors) >= 6, "Expected the shared vector set to be present.");
		for (var v in vectors) {
			var parsed = deserializeJSON(v.input);
			var actual = variables.c.canonicalJson.serialize(parsed);
			assertEquals(v.expected, actual, "Vector '" & v.name & "'.");
			assertEquals(v.sha256, variables.c.canonicalJson.sha256(actual), "Vector '" & v.name & "' checksum.");
		}
	}

	public void function testNullValuedKeysAreRetainedFromJson() {
		// Adobe ColdFusion and Lucee must both keep a JSON null as a present key with a null value.
		var parsed = deserializeJSON('{"a":null,"b":1}');
		assertEquals('{"a":null,"b":1}', variables.c.canonicalJson.serialize(parsed));
	}

	public void function testExplicitNullAssignmentSerializesAsNull() {
		var s = {};
		s["x"] = javaCast("null", "");
		s["y"] = "text";
		assertEquals('{"x":null,"y":"text"}', variables.c.canonicalJson.serialize(s));
	}

	public void function testBracketKeysPreserveCase() {
		var s = {};
		s["itemKey"] = "k";
		s["displayOrder"] = 10;
		assertEquals('{"displayOrder":10,"itemKey":"k"}', variables.c.canonicalJson.serialize(s));
	}

	public void function testDateFormatting() {
		var d = variables.c.canonicalJson.parseInstant("2026-09-17T00:00:00Z");
		assertEquals("2026-09-17T00:00:00.000Z", variables.c.canonicalJson.formatDate(d));
		assertEquals("2026-09-17T13:45:30.123Z", variables.c.canonicalJson.formatDate(variables.c.canonicalJson.parseInstant("2026-09-17T13:45:30.123Z")));
		assertThrows(function() { variables.c.canonicalJson.parseInstant("not a date"); }, "ICFWalk.Validation", "INVALID_INSTANT");
	}

	public void function testDecimalsFromDatabaseStyleValuesFormatPlainly() {
		var s = {};
		s["score"] = createObject("java", "java.math.BigDecimal").init("1.0000");
		s["half"] = createObject("java", "java.math.BigDecimal").init("2.5000");
		assertEquals('{"half":2.5,"score":1}', variables.c.canonicalJson.serialize(s));
	}
}
