/**
 * A DefinitionRepository that delegates everything to the real one and fires a one-shot callback
 * immediately after one named seam returns.
 *
 * WHY THIS EXISTS. Racing two publishes with Promise.all and seeing one win is a stress test, not
 * a proof: it shows that on this run, with this timing, the outcome was acceptable. It cannot show
 * that the intended interleaving was ever reached, so it passes just as happily against code whose
 * lock does nothing and whose two callers simply never overlapped.
 *
 * A barrier proves it. The seams below are the exact statements that take the version's row lock:
 *
 *   findVersionByIdForUpdate   the first thing InstrumentPublishService does inside its transaction
 *   findVersion(lock = true)   the first thing InstrumentImportService does inside its transaction
 *
 * Arming a callback after one of them puts the spec *inside* transaction A at the moment A holds
 * the lock and has done nothing else. The callback starts transaction B on its own thread and
 * joins it with a bounded wait: B cannot finish, because it is queued on the row A is holding, and
 * that is the observable signal that B really reached the competing boundary. When the callback
 * returns, A carries on and commits -- releasing the lock explicitly rather than by timing -- and
 * the spec then joins B again to see the one serial outcome the design permits.
 *
 * armAfter(seam, fn) arms the callback for the next call to that seam and disarms it as it fires,
 * so a delegated call the callback itself makes cannot re-enter it. fired(seam) reports whether it
 * ran, so a spec proves the interleaving happened rather than assuming it.
 *
 * NO PRODUCTION HOOK. This is a decorator, constructed by a spec and handed to a service the spec
 * also constructs. Nothing in src/ references it, no route reaches it, and the container never
 * holds it -- so there is no configuration, in production or anywhere else, in which a client can
 * activate a lock hook. Every method other than the two seams is a plain pass-through via
 * onMissingMethod, so the decorated repository behaves exactly like the real one.
 */
component output="false" {

	public InterceptingDefinitionRepository function init(required any delegate) {
		variables.inner = arguments.delegate;
		variables.hooks = {};
		variables.fired = {};
		return this;
	}

	/** Arms fn to run once, immediately after the next call to `seam` returns. */
	public void function armAfter(required string seam, required any fn) {
		variables.hooks[arguments.seam] = arguments.fn;
		variables.fired[arguments.seam] = false;
	}

	public boolean function fired(required string seam) {
		return structKeyExists(variables.fired, arguments.seam) && variables.fired[arguments.seam];
	}

	private void function trigger(required string seam) {
		if (!structKeyExists(variables.hooks, arguments.seam)) return;
		var fn = variables.hooks[arguments.seam];
		structDelete(variables.hooks, arguments.seam);
		variables.fired[arguments.seam] = true;
		fn();
	}

	// ---- the two lock seams ----------------------------------------------------------------------

	/** Publishing's first statement: the version row under UPDLOCK/ROWLOCK. */
	public struct function findVersionByIdForUpdate(required string versionId) {
		var result = variables.inner.findVersionByIdForUpdate(arguments.versionId);
		trigger("findVersionByIdForUpdate");
		return result;
	}

	/** Importing's first statement, when it locks: the version row under UPDLOCK/HOLDLOCK. */
	public struct function findVersion(required string instrumentId, required string versionLabel, boolean lockForUpdate = false) {
		var result = variables.inner.findVersion(arguments.instrumentId, arguments.versionLabel, arguments.lockForUpdate);
		if (arguments.lockForUpdate) trigger("findVersion");
		return result;
	}

	/**
	 * `mapper` is declared rather than forwarded because InstrumentImportService reads it once in
	 * its constructor, before any call could reach onMissingMethod.
	 */
	public any function mapper() {
		return variables.inner.mapper();
	}

	// ---- everything else -------------------------------------------------------------------------

	public any function onMissingMethod(required string missingMethodName, required struct missingMethodArguments) {
		return invoke(variables.inner, arguments.missingMethodName, arguments.missingMethodArguments);
	}
}
