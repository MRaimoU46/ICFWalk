component extends="icfwalktests.BaseSpec" output="false" {

	public void function beforeAll() {
		variables.golden = repoJson("tests/golden/instrument-snapshot.golden.json");
		variables.config = repoJson("config/instrument-config.json");
	}

	public void function testCompiledSnapshotMatchesReferenceGolden() {
		// Parity with scripts/lib/snapshot.mjs: identical canonical bytes and checksums.
		var normalized = variables.c.configNormalizer.fromConfig(variables.config);
		var compiled = variables.c.snapshotCompiler.compile(normalized);
		assertExactTextEquals(variables.golden.checksum, compiled.checksum, "Snapshot checksum.");
		assertExactTextEquals(variables.golden.definitionsChecksum, compiled.definitionsChecksum, "Definitions checksum.");
		var bytes = javaCast("string", compiled.canonicalJson).getBytes("UTF-8");
		assertEquals(variables.golden.canonicalBytes, arrayLen(bytes), "Canonical byte length.");
		for (var key in structKeyArray(variables.golden.counts)) {
			assertEquals(variables.golden.counts[key], compiled.counts[key], "Count '" & key & "'.");
		}
	}

	public void function testSnapshotContainsNoDatabaseIdentifiersAndCarriesBehavior() {
		var normalized = variables.c.configNormalizer.fromConfig(variables.config);
		var compiled = variables.c.snapshotCompiler.compile(normalized);
		assertExactTextEquals("icfwalk-instrument-snapshot/1", compiled.snapshot.snapshotFormat);
		assertTrue(structKeyExists(compiled.snapshot, "behavior") && isStruct(compiled.snapshot.behavior), "Behavior block present.");
		assertExactTextEquals("Part 3 " & chr(183) & " Conditions for Learning", sectionTitle(compiled.snapshot.definitions.sections, "part3"));
		assertEquals(17, arrayLen(variables.c.snapshotCompiler.placeholders(normalized.definitions)));
		assertFalse(reFind("[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}", compiled.canonicalJson) > 0, "Snapshot must not embed SQL GUIDs.");
	}

	public void function testRuleTargetsResolveToKeysNotLogicalIds() {
		var normalized = variables.c.configNormalizer.fromConfig(variables.config);
		for (var r in normalized.definitions.rules) {
			if (r.ruleKey == "show_prek_k") { assertExactTextEquals("prek_k_classroom", r.targetKey); assertExactTextEquals("SECTION", r.targetType); }
			if (r.ruleKey == "show_period_for_grades_6_12") { assertExactTextEquals("period", r.targetKey); assertExactTextEquals("DIMENSION", r.targetType); }
			if (r.ruleKey == "show_comp_s3_q1") { assertExactTextEquals("comp_s3_q1", r.targetKey); assertExactTextEquals("ITEM", r.targetType); assertExactTextEquals("comp_s3_applicable", r.sourceKey); }
		}
	}

	private string function sectionTitle(required array sections, required string key) {
		for (var s in arguments.sections) if (s.sectionKey == arguments.key) return s.title;
		return "";
	}
}
