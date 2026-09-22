component extends="icfwalktests.BaseSpec" output="false" {

	public void function testRedactsSensitiveKeysAndTruncatesLongText() {
		var entry = variables.c.logger.buildEntry("INFO", "unit.test", {
			"checksum": "abc",
			"password": "p@ss",
			"text_value": "narrative content",
			"nested": { "notes": "private", "count": 3, "authorization": "Bearer x" },
			"teacher_email": "someone@example.org",
			"long": repeatString("z", 500)
		});
		assertExactTextEquals("abc", entry.fields.checksum);
		assertExactTextEquals("[redacted]", entry.fields.password);
		assertExactTextEquals("[redacted]", entry.fields.text_value);
		assertExactTextEquals("[redacted]", entry.fields.nested.notes);
		assertExactTextEquals("[redacted]", entry.fields.nested.authorization);
		assertExactTextEquals("[redacted]", entry.fields.teacher_email);
		assertEquals(3, entry.fields.nested.count);
		assertTrue(len(entry.fields.long) < 260, "Long strings must be truncated.");
		assertContains("[truncated]", entry.fields.long);
		assertExactTextEquals("unit.test", entry.event);
		assertExactTextEquals("INFO", entry.level);
	}

	public void function testEntrySerializesAsSingleJsonLine() {
		var entry = variables.c.logger.buildEntry("WARN", "unit.line", { "a": 1 });
		var line = variables.c.canonicalJson.serialize(entry);
		assertTrue(isJSON(line));
		assertFalse(find(chr(10), line) > 0);
	}

	public void function testLevelThresholds() {
		assertTrue(variables.c.logger.isEnabled("ERROR"));
		assertTrue(variables.c.logger.isEnabled("WARN"));
	}
}
