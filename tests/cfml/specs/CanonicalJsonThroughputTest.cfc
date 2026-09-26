/**
 * Phase 8, defect P8-14: the canonical JSON writer serializes a My Walks sized response in
 * milliseconds, not in a large fraction of a second.
 *
 * Every API response, every stored JSON document and every snapshot checksum goes through
 * CanonicalJson. It escaped each string one UTF-16 code unit at a time and sorted each struct's
 * keys with a CFML closure, so its cost was CFML interpretation per character. On the Phase 8
 * synthetic district a walker's My Walks (81 walks, 72 KB) spent about 400 ms of each request in
 * serialization on Adobe ColdFusion 2023 and 110 to 290 ms on Lucee, against 2 to 6 ms for the
 * engine's own serializer, and under 25 concurrent people that request's median reached 5 seconds.
 *
 * The output is fixed by the shared vectors (CanonicalJsonTest, tests/node/canonical-json.test.mjs)
 * and by every snapshot checksum; this spec is about time only. The ceiling is several times what
 * the corrected writer needs on either engine and a fraction of what the uncorrected one took.
 */
component extends="icfwalktests.BaseSpec" output="false" {

	variables.CEILING_MS = 250;

	public void function testAMyWalksSizedResponseSerializesQuickly() {
		var walks = [];
		for (var i = 1; i <= 200; i++) {
			arrayAppend(walks, {
				"id": createUUID(), "orgUnitId": createUUID(), "orgUnitName": "Abbott Middle School", "orgUnitCode": "abbott_middle_school",
				"lockedDimensions": ["school"], "versionId": createUUID(), "versionLabel": "2026-09-17 aligned prototype", "status": "COMPLETED",
				"ownerUserId": createUUID(), "ownerDisplayName": "Synthetic Walker " & i, "isOwner": true, "canEdit": true,
				"observedAt": "2026-02-10T00:00:00.000Z", "createdAt": "2026-02-10T14:03:11.250Z", "updatedAt": "2026-02-11T09:45:00.000Z",
				"completedAt": "2026-02-11T09:45:00.000Z", "rowVersion": "000000000000" & (1000 + i),
				"state": {
					"dimensions": {
						"school": { "selectedValueCode": "abbott_middle_school" }, "grade": { "selectedValueCode": "7" },
						"date": { "dateValue": "2026-02-10" }, "content": { "selectedValueCode": "math" },
						"observer": { "textValue": "Observer " & i & ", with a ""quoted"" note" }
					},
					"responses": {}
				}
			});
		}
		var json = variables.c.canonicalJson;
		var document = { "walks": walks };
		json.serialize(document);
		var best = 0;
		for (var run = 1; run <= 3; run++) {
			var t0 = getTickCount();
			var text = json.serialize(document);
			var ms = getTickCount() - t0;
			best = run == 1 ? ms : min(best, ms);
		}
		assertTrue(len(text) > 150000, "the document is My Walks sized (" & len(text) & " bytes)");
		assertTrue(best < variables.CEILING_MS, "serializing " & len(text) & " bytes took " & best & " ms at best of three (ceiling " & variables.CEILING_MS & " ms)");
	}
}
