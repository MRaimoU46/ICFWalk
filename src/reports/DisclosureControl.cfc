/**
 * Cell suppression for released (protected) aggregate reports: the owner-approved RPT-03 rule
 * (docs/OPEN_DECISIONS.md, "Aggregate privacy-suppression threshold"), applied to one breakdown of
 * one block at a time. Pure: no database, no state, no configuration. ReportService supplies the
 * minimum k from the release being read.
 *
 * A BREAKDOWN is every category a block's walks can fall into for one item or one dimension, in a
 * fixed order, with the walks in each. The categories are mutually exclusive and exhaustive, so
 * the counts add up to the block's walks, which are published. What a reader can know about a
 * breakdown is therefore its published cells, that total, and this algorithm.
 *
 * THE RULE, for a breakdown with cells c[1..m] and minimum k:
 *
 *   1. Primary suppression. Every cell of 1..k-1 is withheld. Zero is published: "no walk"
 *      identifies no walk.
 *   2. Complementary suppression. While the withheld set S could still be solved -- fewer than two
 *      cells, a total below k, or a total equal to its number of cells (every withheld cell would
 *      have to be exactly 1, because withheld cells in a partial breakdown are never zero) -- the
 *      smallest remaining non-zero cell is withheld too (ties broken by category order).
 *   3. If S comes to cover every non-zero cell, the whole breakdown is withheld, zeros included: a
 *      breakdown whose only published cells would be its zeros says exactly which categories hold
 *      the withheld walks, which is the information step 1 exists to protect.
 *   4. Audit. Subtraction is not the only attack: a reader who knows steps 1-3 also knows that a
 *      withheld cell is either a primary (1..k-1) or the one complementary cell, and that the
 *      complementary cell was the smallest candidate. Those bounds can pin a cell that subtraction
 *      alone cannot -- (3, 2, 2) with k = 3 publishes as (3, W, W), and the only way to reach that
 *      pattern is (3, 2, 2). So before a partial breakdown is published, `possibleValues` computes,
 *      for every withheld cell, every value that cell could hold in ANY breakdown this algorithm
 *      would publish the same way. If any withheld cell has only one possible value, the whole
 *      breakdown is withheld instead.
 *
 * So a published breakdown is either complete (no cell of 1..k-1 existed), or partial with every
 * withheld cell having at least two values consistent with everything published -- for a reader
 * who knows this algorithm, not only for one who subtracts -- or withheld entirely.
 * ReportDisclosureTest proves that exhaustively for every breakdown of up to six categories and
 * small totals, comparing `possibleValues` with a brute-force inversion of the algorithm, rather
 * than asserting it.
 *
 * LINKED BREAKDOWNS. The rule above protects a breakdown whose cells are tied to nothing else that
 * is published. The instrument's own rules tie some together: Period is shown only for some Grades,
 * so Period's HIDDEN count is a sum of Grade cells; a conditional section's items are HIDDEN exactly
 * for some Class Types; a component's ratings are NOT_APPLICABLE exactly when its "applicable"
 * question was answered No. Publishing one of those alongside a partly withheld other can solve
 * the withheld cells. ReportService therefore groups breakdowns linked by any rule and applies
 * `anyPrimary` to the group: if any breakdown in it has a cell of 1..k-1, the whole group is
 * withheld in that block; otherwise the whole group is complete and nothing needs protecting.
 */
component output="false" {

	public DisclosureControl function init() {
		return this;
	}

	/** True when any cell is a primary cell (1..k-1). */
	public boolean function anyPrimary(required array cells, required numeric k) {
		for (var c in arguments.cells) if (c >= 1 && c < arguments.k) return true;
		return false;
	}

	/**
	 * Applies the rule to one breakdown.
	 *
	 *   cells  non-negative whole numbers, in the breakdown's fixed category order
	 *   k      the minimum, at least 3
	 *
	 * Returns { mode, withheld } where mode is "COMPLETE", "PARTIAL" or "WITHHELD" and withheld[i]
	 * says whether cells[i] is withheld. A withheld cell's value must never leave the server.
	 */
	public struct function suppress(required array cells, required numeric k) {
		var n = arrayLen(arguments.cells);
		var withheld = [];
		var nonZero = 0;
		for (var i = 1; i <= n; i++) {
			var c = arguments.cells[i];
			if (!isNumeric(c) || c < 0 || c != int(c)) throw(type = "ICFWalk.Configuration", message = "A breakdown cell is not a non-negative whole number.", errorcode = "DISCLOSURE_CELL_INVALID");
			arrayAppend(withheld, c >= 1 && c < arguments.k);
			if (c > 0) nonZero++;
		}
		if (arguments.k < 3) throw(type = "ICFWalk.Configuration", message = "The disclosure minimum is below the approved floor of 3.", errorcode = "DISCLOSURE_MINIMUM_INVALID");
		var size = 0;
		var total = 0;
		for (var i = 1; i <= n; i++) {
			if (withheld[i]) { size++; total += arguments.cells[i]; }
		}
		if (size == 0) return { "mode": "COMPLETE", "withheld": withheld };
		while (true) {
			if (size == nonZero) return { "mode": "WITHHELD", "withheld": allTrue(n) };
			if (!solvable(size, total, arguments.k)) {
				var possible = possibleValues(arguments.cells, withheld, arguments.k);
				for (var key in structKeyArray(possible)) {
					if (structCount(possible[key]) < 2) return { "mode": "WITHHELD", "withheld": allTrue(n) };
				}
				return { "mode": "PARTIAL", "withheld": withheld };
			}
			var pick = 0;
			for (var i = 1; i <= n; i++) {
				if (withheld[i] || arguments.cells[i] == 0) continue;
				if (pick == 0 || arguments.cells[i] < arguments.cells[pick]) pick = i;
			}
			withheld[pick] = true;
			size++;
			total += arguments.cells[pick];
		}
	}

	/** Withholds every cell: the group rule for linked breakdowns. */
	public struct function withholdAll(required numeric n) {
		return { "mode": "WITHHELD", "withheld": allTrue(arguments.n) };
	}

	/** Publishes every cell: a breakdown, or a linked group, with no cell of 1..k-1. */
	public struct function publishAll(required numeric n) {
		var out = [];
		for (var i = 1; i <= arguments.n; i++) arrayAppend(out, false);
		return { "mode": "COMPLETE", "withheld": out };
	}

	/**
	 * For a partial pattern, every value each withheld cell could hold in some breakdown that this
	 * algorithm (steps 1-3) publishes the same way: same published cells, same withheld positions,
	 * same total. Returns { "<position>": { "<value>": true } }.
	 *
	 * Exact, not sampled. In any breakdown that yields the pattern, the withheld cells are the
	 * primaries P plus at most one complementary cell j (once one cell of k or more joins a set that
	 * already holds a primary, the set is no longer solvable, so the loop stops), and the published
	 * cells are all 0 or at least k. So there are two shapes to enumerate:
	 *
	 *   no complementary   every withheld cell is 1..k-1, and the withheld set is itself unsolvable
	 *                      (otherwise the algorithm would not have stopped there);
	 *   complementary j    the others are 1..k-1 and, alone, still solvable (otherwise the algorithm
	 *                      would have stopped without j); j is at least k and was the smallest
	 *                      non-zero candidate: below every published non-zero cell ahead of it in
	 *                      category order, and no greater than every one after it.
	 *
	 * ReportDisclosureTest checks this against a brute-force inversion of `suppress`.
	 */
	public struct function possibleValues(required array cells, required array withheld, required numeric k) {
		var n = arrayLen(arguments.cells);
		var positions = [];
		var sigma = 0;
		var out = {};
		for (var i = 1; i <= n; i++) {
			if (!arguments.withheld[i]) continue;
			arrayAppend(positions, i);
			sigma += arguments.cells[i];
			out[toString(i)] = {};
		}
		var size = arrayLen(positions);
		var top = arguments.k - 1;
		if (!solvable(size, sigma, arguments.k)) {
			for (var i in positions) {
				for (var a = 1; a <= top; a++) if (fits(size - 1, sigma - a, top)) out[toString(i)][toString(a)] = true;
			}
		}
		for (var j in positions) {
			var bound = -1;
			for (var i = 1; i <= n; i++) {
				if (arguments.withheld[i] || arguments.cells[i] == 0) continue;
				var limit = i < j ? arguments.cells[i] - 1 : arguments.cells[i];
				if (bound < 0 || limit < bound) bound = limit;
			}
			var p = size - 1;
			if (p < 1) continue;
			for (var s = p; s <= p * top; s++) {
				var xj = sigma - s;
				if (xj < arguments.k || (bound >= 0 && xj > bound)) continue;
				if (!solvable(p, s, arguments.k)) continue;
				out[toString(j)][toString(xj)] = true;
				for (var i in positions) {
					if (i == j) continue;
					for (var a = 1; a <= top; a++) if (fits(p - 1, s - a, top)) out[toString(i)][toString(a)] = true;
				}
			}
		}
		return out;
	}

	/**
	 * Whether a withheld set of `size` non-zero cells totalling `total` could be solved by a reader:
	 * fewer than two cells, a total below k, or every cell forced to 1. The algorithm keeps
	 * withholding while this is true.
	 */
	private boolean function solvable(required numeric size, required numeric total, required numeric k) {
		return arguments.size < 2 || arguments.total < arguments.k || arguments.total == arguments.size;
	}

	/** Whether `count` cells of 1..top can add up to `sum`. */
	private boolean function fits(required numeric count, required numeric sum, required numeric top) {
		if (arguments.count == 0) return arguments.sum == 0;
		return arguments.sum >= arguments.count && arguments.sum <= arguments.count * arguments.top;
	}

	private array function allTrue(required numeric n) {
		var out = [];
		for (var i = 1; i <= arguments.n; i++) arrayAppend(out, true);
		return out;
	}
}
