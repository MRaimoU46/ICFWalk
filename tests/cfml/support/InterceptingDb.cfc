/**
 * A Db that delegates everything to the real one and fires a one-shot callback at exactly one
 * boundary: the instant a committed transaction hands control back to its caller.
 *
 * That boundary is the seam this suite needs. A mutation that materializes its response DTO after
 * its transaction has committed does so with no lock held, so another session can commit in
 * between and the response then describes THAT state instead of the one the mutation produced. The
 * callback is the other session: it runs on this thread, after the commit and before
 * WalkService.save()/complete() resumes, which forces the interleaving deterministically -- no
 * sleeps, no thread timing, no luck. A response built inside the transaction is already complete
 * when the callback runs and cannot be affected by it; a response built afterwards sees the
 * callback's commit, which is precisely the defect.
 *
 * armAfterCommit(fn) arms the callback for the next committed top-level transaction and disarms it
 * as it fires, so anything the callback itself does cannot re-enter it. firedAfterCommit() reports
 * whether it ran, so a spec can prove the interference really happened rather than assuming it.
 *
 * Every other method is a plain pass-through, and every signature mirrors Db exactly, so the
 * decorated object is substitutable. This lives in tests/ only: no production code has a test hook.
 */
component output="false" {

	public InterceptingDb function init(required any delegate) {
		variables.inner = arguments.delegate;
		variables.afterCommit = "";
		variables.armed = false;
		variables.fired = false;
		variables.depth = 0;
		return this;
	}

	/** Arms fn to run once, immediately after the next committed top-level transaction. */
	public void function armAfterCommit(required any fn) {
		variables.afterCommit = arguments.fn;
		variables.armed = true;
		variables.fired = false;
	}

	public boolean function firedAfterCommit() {
		return variables.fired;
	}

	/**
	 * A rolled-back transaction rethrows before the callback, so the barrier marks a real commit.
	 * Only the outermost transaction is a commit boundary: CFML joins nested ones to the outer.
	 */
	public any function transact(required any fn) {
		variables.depth++;
		var result = "";
		try {
			result = variables.inner.transact(arguments.fn);
		} catch (any e) {
			variables.depth--;
			rethrow;
		}
		variables.depth--;
		if (variables.depth == 0 && variables.armed) {
			var callback = variables.afterCommit;
			variables.armed = false;
			variables.afterCommit = "";
			variables.fired = true;
			callback();
		}
		return result;
	}

	// ---- pass-through ----------------------------------------------------------------------------

	public string function datasourceName() { return variables.inner.datasourceName(); }
	public query function run(required string sql, struct params = {}) { return variables.inner.run(argumentCollection = arguments); }
	public numeric function scalar(required string sql, struct params = {}, numeric defaultValue = 0) { return variables.inner.scalar(argumentCollection = arguments); }
	public string function newGuid() { return variables.inner.newGuid(); }
	public boolean function isGuid(any value) { return variables.inner.isGuid(argumentCollection = arguments); }
	public struct function guid(any value) { return variables.inner.guid(argumentCollection = arguments); }
	public struct function nvarchar(any value, numeric maxLength = 0) { return variables.inner.nvarchar(argumentCollection = arguments); }
	public struct function ntext(any value) { return variables.inner.ntext(argumentCollection = arguments); }
	public struct function integer(any value) { return variables.inner.integer(argumentCollection = arguments); }
	public struct function bigint(any value) { return variables.inner.bigint(argumentCollection = arguments); }
	public struct function bit(any value) { return variables.inner.bit(argumentCollection = arguments); }
	public struct function decimal(any value, numeric scale = 4) { return variables.inner.decimal(argumentCollection = arguments); }
	public struct function timestamp(any value) { return variables.inner.timestamp(argumentCollection = arguments); }
}
