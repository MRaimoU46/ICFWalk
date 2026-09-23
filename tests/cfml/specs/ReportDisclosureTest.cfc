/**
 * RPT-03 correction: the cell-suppression rule of released reports (reports/DisclosureControl),
 * proved rather than sampled, and the instrument links that make some breakdowns a group.
 *
 * The central property: for every breakdown the algorithm could be given -- every way of spreading
 * T walks over m categories, for small m and T -- no published cell is 1..k-1, and every withheld
 * cell has at least two values consistent with everything published. "Consistent" is computed by
 * brute force: the published pattern is inverted by running the real algorithm over every
 * breakdown with the same total, so the reader modelled here knows the algorithm, its tie-breaks
 * and its audit, not only how to subtract. DisclosureControl.possibleValues is also checked against
 * that inversion, cell for cell, for every partial breakdown.
 */
component extends="icfwalktests.BaseSpec" output="false" {

	public void function beforeAll() {
		variables.dc = createObject("component", "icfwalk.reports.DisclosureControl").init();
	}

	// ---- the rule, exhaustively -------------------------------------------------------------------

	public void function testEveryWithheldCellHasAtLeastTwoConsistentValuesFork3() {
		provePropertyFor(3, 6, [0, 12, 12, 12, 10, 9, 8]);
	}

	public void function testEveryWithheldCellHasAtLeastTwoConsistentValuesFork4() {
		provePropertyFor(4, 5, [0, 12, 12, 12, 10, 9]);
	}

	/**
	 * For minimum k, every breakdown of 1..maxM categories and k..maxT[m] walks. Asserts the three
	 * properties and that all three outcomes (complete, partial, withheld) actually occur, so the
	 * proof is not vacuously true of an algorithm that withholds everything.
	 */
	private void function provePropertyFor(required numeric k, required numeric maxM, required array maxT) {
		var modes = { "COMPLETE": 0, "PARTIAL": 0, "WITHHELD": 0 };
		var checked = 0;
		for (var m = 1; m <= arguments.maxM; m++) {
			for (var t = arguments.k; t <= arguments.maxT[m + 1]; t++) {
				var groups = {};
				for (var v in compositions(t, m)) {
					checked++;
					var out = dc.suppress(v, arguments.k);
					modes[out.mode]++;
					var sig = [];
					for (var i = 1; i <= m; i++) {
						if (!out.withheld[i] && v[i] >= 1 && v[i] < arguments.k) fail("k=" & arguments.k & " " & serializeJSON(v) & " publishes the small cell " & v[i]);
						arrayAppend(sig, out.withheld[i] ? "W" : v[i]);
					}
					var key = arrayToList(sig);
					if (!structKeyExists(groups, key)) groups[key] = { "vectors": [], "mode": out.mode, "withheld": out.withheld };
					arrayAppend(groups[key].vectors, v);
				}
				for (var key in structKeyArray(groups)) {
					var g = groups[key];
					var possible = g.mode == "PARTIAL" ? dc.possibleValues(g.vectors[1], g.withheld, arguments.k) : {};
					for (var i = 1; i <= m; i++) {
						if (!g.withheld[i]) continue;
						var seen = {};
						for (var v in g.vectors) seen[toString(v[i])] = true;
						if (structCount(seen) < 2) {
							fail("k=" & arguments.k & " pattern [" & key & "] (T=" & t & ") pins withheld cell " & i & " to " & structKeyList(seen) & ", from " & serializeJSON(g.vectors));
						}
						if (g.mode == "PARTIAL") {
							var a = structKeyArray(possible[toString(i)]);
							var b = structKeyArray(seen);
							arraySort(a, "numeric");
							arraySort(b, "numeric");
							assertExactJsonEquals(b, a, "possibleValues matches the brute-force inversion of [" & key & "] at cell " & i);
						}
					}
				}
			}
		}
		assertTrue(modes.COMPLETE > 0 && modes.PARTIAL > 0 && modes.WITHHELD > 0, "all three outcomes occur: " & serializeJSON(modes));
		assertTrue(checked > 1000, "a real search, not a handful: " & checked);
	}

	private array function compositions(required numeric total, required numeric parts) {
		if (arguments.parts == 1) return [[arguments.total]];
		var out = [];
		for (var first = 0; first <= arguments.total; first++) {
			for (var rest in compositions(arguments.total - first, arguments.parts - 1)) {
				var v = [first];
				for (var x in rest) arrayAppend(v, x);
				arrayAppend(out, v);
			}
		}
		return out;
	}

	// ---- the rule, by example --------------------------------------------------------------------

	/**
	 * The counterexample that shaped step 4: (3, 2, 2) would publish as (3, W, W), and the only
	 * breakdown this algorithm publishes that way is (3, 2, 2) itself -- both "withheld" cells are
	 * pinned to 2 by a reader who knows the rule. The audit withholds the whole breakdown instead.
	 */
	public void function testAPartialPatternThatWouldPinItsCellsIsWithheldWhole() {
		var out = dc.suppress([3, 2, 2], 3);
		assertExactTextEquals("WITHHELD", out.mode);
		assertExactJsonEquals([true, true, true], out.withheld);
		var pinned = dc.possibleValues([3, 2, 2], [false, true, true], 3);
		assertEquals(1, structCount(pinned["2"]), "without the audit cell 2 would have one possible value");
	}

	public void function testKnownBreakdowns() {
		var cases = [
			// cells, k, mode, withheld
			[[10, 0, 5], 3, "COMPLETE", [false, false, false], "no cell of 1..k-1: nothing to protect"],
			[[1, 0, 0, 0], 3, "WITHHELD", [true, true, true, true], "one walk: the whole breakdown, zeros too"],
			[[2, 1], 3, "WITHHELD", [true, true], "every non-zero cell would be withheld, so everything is"],
			[[1, 1, 1], 3, "WITHHELD", [true, true, true], "three singletons are withheld whole"],
			[[6, 3, 0, 1], 3, "PARTIAL", [false, true, false, true], "a small cell and its complement; the zero and the large cell stay"],
			[[5, 1, 4], 3, "PARTIAL", [false, true, true], "the complement is the smallest other non-zero cell"]
		];
		for (var c in cases) {
			var out = dc.suppress(c[1], c[2]);
			assertExactTextEquals(c[3], out.mode, c[5] & " " & serializeJSON(c[1]));
			assertExactJsonEquals(c[4], out.withheld, c[5] & " " & serializeJSON(c[1]));
		}
	}

	/** A partial breakdown never withholds a single cell: subtracting from the total would give it back. */
	public void function testAPartialBreakdownNeverWithholdsExactlyOneCell() {
		for (var c in [[6, 3, 0, 1], [5, 1, 4], [9, 2, 0, 3], [20, 1, 1, 7]]) {
			var out = dc.suppress(c, 3);
			if (out.mode != "PARTIAL") continue;
			var n = 0;
			var sum = 0;
			for (var i = 1; i <= arrayLen(c); i++) if (out.withheld[i]) { n++; sum += c[i]; }
			assertTrue(n >= 2, serializeJSON(c) & " withholds " & n & " cell(s)");
			assertTrue(sum >= 3, serializeJSON(c) & " withholds a total of " & sum & ", below the minimum");
		}
	}

	public void function testTheMinimumCannotGoBelowTheApprovedFloor() {
		assertThrows(function() { dc.suppress([5, 1], 2); }, "ICFWalk.Configuration", "DISCLOSURE_MINIMUM_INVALID");
		assertThrows(function() { dc.suppress([5, -1], 3); }, "ICFWalk.Configuration", "DISCLOSURE_CELL_INVALID");
	}

	public void function testTheGroupRuleIsAllOrNothing() {
		assertTrue(dc.anyPrimary([9, 0, 2], 3));
		assertFalse(dc.anyPrimary([9, 0, 3], 3));
		assertExactJsonEquals([true, true, true], dc.withholdAll(3).withheld);
		assertExactJsonEquals([false, false], dc.publishAll(2).withheld);
	}

	// ---- linked breakdowns in the instrument ------------------------------------------------------

	/**
	 * The current instrument's rules tie Period and the PreK-K section to Grade, the classroom-type
	 * sections to Class Type, the Music / Art / PE section to Content, and each skippable
	 * component's ratings to its "applicable" question. Those breakdowns are released as groups; a
	 * core rating tied to nothing is protected on its own.
	 */
	public void function testInstrumentRulesLinkBreakdownsIntoGroups() {
		if (!schemaPresent() || structIsEmpty(variables.c.snapshotService.currentVersion())) fail("needs the seeded instrument version");
		var catalog = variables.c.reportService.catalogFor(variables.c.snapshotService.currentVersion().versionId);
		var g = catalog.linkGroups;
		var same = function(a, b) { return structKeyExists(g, a) && structKeyExists(g, b) && compare(g[a], g[b]) == 0; };
		assertTrue(same("DIMENSION:grade", "DIMENSION:period"), "Period follows Grade");
		assertTrue(same("ITEM:comp_s3_q1", "ITEM:comp_s3_q2"), "a skippable component's ratings share its applicability answer");
		assertTrue(same("ITEM:comp_s3_q1", "ITEM:comp_s3_applicable") || !structKeyExists(catalog.itemIndex, "comp_s3_applicable"), "and are linked to it when it is reported");
		var dualLanguage = [];
		for (var it in catalog.items) if (left(it.itemKey, len("dual_language_")) == "dual_language_") arrayAppend(dualLanguage, "ITEM:" & it.itemKey);
		assertTrue(arrayLen(dualLanguage) > 0, "the dual-language section has reportable items");
		for (var key in dualLanguage) assertTrue(same(key, "DIMENSION:classType"), key & " is linked to Class Type");
		assertFalse(same("DIMENSION:grade", "DIMENSION:classType"), "separate rules make separate groups");
		assertFalse(structKeyExists(g, "ITEM:comp_s1_q1"), "a rating no rule touches is protected on its own");
		assertFalse(structKeyExists(g, "DIMENSION:visitTiming"), "so is a dimension no rule touches");
	}
}
