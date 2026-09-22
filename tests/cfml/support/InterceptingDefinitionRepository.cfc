/**
 * A DefinitionRepository that delegates everything to the real one and fires one-shot callbacks
 * immediately before and immediately after a named seam.
 *
 * WHY THIS EXISTS. Racing two publishes with Promise.all and seeing one win is a stress test, not
 * a proof: it shows that on this run, with this timing, the outcome was acceptable. It cannot show
 * that the intended interleaving was ever reached, so it passes just as happily against code whose
 * lock does nothing and whose two callers simply never overlapped.
 *
 * A two-sided barrier proves it, and it needs both halves:
 *
 *   armAfter(seam, fn)   puts the spec INSIDE transaction A at the moment A holds the production
 *                        lock and has done nothing else. A announces A_LOCKED from there.
 *   armBefore(seam, fn)  puts the spec on B's thread immediately BEFORE the database call that
 *                        will contend for that same lock. B announces B_AT_COMPETING_BOUNDARY from
 *                        there, and then makes the call and blocks.
 *
 * The spec waits for B's announcement -- an observation -- and only then lets A finish. The
 * earlier form of these specs had no `armBefore`, so it inferred B's arrival from B not having
 * completed within a timeout, which a scheduler delay produces just as readily.
 *
 * THE SEAMS are the exact statements that take the row lock a competitor will queue on:
 *
 *   findVersionByIdForUpdate    the first thing InstrumentPublishService does inside its transaction
 *   findVersion(lock = true)    the first thing InstrumentImportService does inside its transaction
 *   lockInstrumentByCode        the shared-metadata operation's locked read of icf.instrument
 *   lockInstrumentById          import's locked re-read of icf.instrument, after the version lock
 *   createDimensionIdentity     the DRAFT-qualified mint of a global dimension identity
 *   createDimensionValueIdentity  the same, for a global dimension-value identity
 *   findInstrumentByCode        the pre-correction UNLOCKED read the metadata service used to start
 *                               from. Armed alongside lockInstrumentByCode so the metadata barrier
 *                               specs fail on behaviour -- a lost update -- against the code that
 *                               had no locked read at all, rather than merely on a missing method.
 *
 * NO PRODUCTION HOOK. This is a decorator, constructed by a spec and handed to a service the spec
 * also constructs. Nothing in src/ references it, no route reaches it, and the container never
 * holds it -- so there is no configuration, in production or anywhere else, in which a client can
 * activate a lock hook. Every method other than the declared seams is a plain pass-through via
 * onMissingMethod, so the decorated repository behaves exactly like the real one.
 */
component output="false" {

	public InterceptingDefinitionRepository function init(required any delegate) {
		variables.inner = arguments.delegate;
		variables.before = {};
		variables.after = {};
		variables.fired = {};
		return this;
	}

	/** Arms fn to run once, immediately BEFORE the next call to `seam` is delegated. */
	public void function armBefore(required string seam, required any fn) {
		variables.before[arguments.seam] = arguments.fn;
	}

	/** Arms fn to run once, immediately AFTER the next call to `seam` returns. */
	public void function armAfter(required string seam, required any fn) {
		variables.after[arguments.seam] = arguments.fn;
	}

	public boolean function fired(required string seam) {
		return structKeyExists(variables.fired, arguments.seam) && variables.fired[arguments.seam];
	}

	/** True when any of the named seams fired. Used where one logical boundary has two candidates. */
	public boolean function firedAny(required array seams) {
		for (var seam in arguments.seams) if (fired(seam)) return true;
		return false;
	}

	public array function firedSeams() {
		var out = [];
		for (var seam in structKeyArray(variables.fired)) if (variables.fired[seam]) arrayAppend(out, seam);
		arraySort(out, "textnocase");
		return out;
	}

	private void function trigger(required string phase, required string seam) {
		var hooks = arguments.phase == "before" ? variables.before : variables.after;
		if (!structKeyExists(hooks, arguments.seam)) return;
		var fn = hooks[arguments.seam];
		// Disarmed as it fires, so a delegated call the callback itself makes cannot re-enter it.
		structDelete(hooks, arguments.seam);
		variables.fired[arguments.seam] = true;
		fn();
	}

	// ---- the lock seams --------------------------------------------------------------------------

	/** Publishing's first statement: the version row under UPDLOCK/ROWLOCK. */
	public struct function findVersionByIdForUpdate(required string versionId) {
		trigger("before", "findVersionByIdForUpdate");
		var result = variables.inner.findVersionByIdForUpdate(arguments.versionId);
		trigger("after", "findVersionByIdForUpdate");
		return result;
	}

	/** Importing's first statement, when it locks: the version row under UPDLOCK/HOLDLOCK. */
	public struct function findVersion(required string instrumentId, required string versionLabel, boolean lockForUpdate = false) {
		if (arguments.lockForUpdate) trigger("before", "findVersion");
		var result = variables.inner.findVersion(arguments.instrumentId, arguments.versionLabel, arguments.lockForUpdate);
		if (arguments.lockForUpdate) trigger("after", "findVersion");
		return result;
	}

	/** The shared-metadata operation's locked read of icf.instrument. */
	public struct function lockInstrumentByCode(required string code) {
		trigger("before", "lockInstrumentByCode");
		var result = variables.inner.lockInstrumentByCode(arguments.code);
		trigger("after", "lockInstrumentByCode");
		return result;
	}

	/** Import's locked re-read of icf.instrument, taken after the version lock is already held. */
	public struct function lockInstrumentById(required string instrumentId) {
		trigger("before", "lockInstrumentById");
		var result = variables.inner.lockInstrumentById(arguments.instrumentId);
		trigger("after", "lockInstrumentById");
		return result;
	}

	/**
	 * The unlocked read the metadata service used to derive its replacement row from, before this
	 * correction. Armed alongside lockInstrumentByCode so a barrier spec written against the
	 * corrected contract still drives the uncorrected code to the same interleaving, and fails
	 * there on the lost update rather than on an absent method.
	 */
	public struct function findInstrumentByCode(required string code) {
		trigger("before", "findInstrumentByCode");
		var result = variables.inner.findInstrumentByCode(arguments.code);
		trigger("after", "findInstrumentByCode");
		return result;
	}

	/** The shared-row write. In the uncorrected code this is where the row lock was first taken. */
	public numeric function updateInstrumentMetadata(
		required string instrumentId, required string name, any description,
		required boolean active, required string authorizedByUserId
	) {
		trigger("before", "updateInstrumentMetadata");
		var result = variables.inner.updateInstrumentMetadata(
			arguments.instrumentId, arguments.name,
			isNull(arguments.description) ? javaCast("null", "") : arguments.description,
			arguments.active, arguments.authorizedByUserId
		);
		trigger("after", "updateInstrumentMetadata");
		return result;
	}

	/** Minting a global dimension identity on a DRAFT's authority. */
	public string function createDimensionIdentity(required string versionId, required struct row) {
		trigger("before", "createDimensionIdentity");
		var result = variables.inner.createDimensionIdentity(arguments.versionId, arguments.row);
		trigger("after", "createDimensionIdentity");
		return result;
	}

	/** Minting a global dimension-value identity on a DRAFT's authority. */
	public string function createDimensionValueIdentity(required string versionId, required string dimensionId, required struct row) {
		trigger("before", "createDimensionValueIdentity");
		var result = variables.inner.createDimensionValueIdentity(arguments.versionId, arguments.dimensionId, arguments.row);
		trigger("after", "createDimensionValueIdentity");
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
