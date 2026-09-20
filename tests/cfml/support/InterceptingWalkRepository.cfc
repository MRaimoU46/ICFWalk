/**
 * A WalkRepository that delegates everything to the real one and fires a one-shot callback at one
 * named seam. It exists so a spec can force a real concurrent writer into an exact point of a
 * WalkService operation and observe what the operation does about it, without any test-only seam in
 * production code: the repository is the only thing WalkService reads the walk aggregate through.
 *
 * armed(seam, fn) arms the callback for the next call to that seam and disarms it again as it
 * fires, so a delegated call the callback itself makes cannot recurse. fired(seam) reports whether
 * it ran.
 *
 * Seams are repository method names. Only the ones a spec needs are hooked; every other method is a
 * plain pass-through so the decorated repository behaves exactly like the real one.
 */
component output="false" {

	public InterceptingWalkRepository function init(required any delegate) {
		variables.inner = arguments.delegate;
		variables.hooks = {};
		variables.fired = {};
		return this;
	}

	/** Arms fn to run once, before the next call to `seam`. */
	public void function arm(required string seam, required any fn) {
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

	// ---- hooked seams --------------------------------------------------------------------------

	public struct function loadDimensionValues(required string walkId) {
		trigger("loadDimensionValues");
		return variables.inner.loadDimensionValues(arguments.walkId);
	}

	public struct function findWalk(required string walkId, boolean lock = false) {
		trigger(arguments.lock ? "findWalkLocked" : "findWalk");
		return variables.inner.findWalk(arguments.walkId, arguments.lock);
	}

	/**
	 * Reached only while a response DTO is being materialized (WalkService.loadDto). A save or a
	 * completion performs no other revision count, so this seam is an unambiguous "the write is
	 * done and its response is being built" -- the exact point a concurrent writer must not be able
	 * to commit at.
	 */
	public numeric function countRevisions(required string walkId) {
		trigger("countRevisions");
		return variables.inner.countRevisions(arguments.walkId);
	}

	// ---- pass-through --------------------------------------------------------------------------
	//
	// Every signature mirrors WalkRepository exactly so the decorated object is substitutable.

	public boolean function isRowVersion(any value) { return variables.inner.isRowVersion(argumentCollection = arguments); }
	public string function insertWalk(required string versionId, required string orgUnitId, required string ownerUserId, any observedAt) { return variables.inner.insertWalk(argumentCollection = arguments); }
	public void function touchWalk(required string walkId, any observedAt) { variables.inner.touchWalk(argumentCollection = arguments); }
	public void function markCompleted(required string walkId) { variables.inner.markCompleted(argumentCollection = arguments); }
	public void function markVoided(required string walkId, required string reason) { variables.inner.markVoided(argumentCollection = arguments); }
	public array function listWalks(required string userId, required array readUnitIds, required array editUnitIds, string scope = "mine") { return variables.inner.listWalks(argumentCollection = arguments); }
	public void function upsertDimensionValue(required string walkId, required string versionId, required string dimensionId, required struct value, required boolean exists) { variables.inner.upsertDimensionValue(argumentCollection = arguments); }
	public void function deleteDimensionValue(required string walkId, required string dimensionId) { variables.inner.deleteDimensionValue(argumentCollection = arguments); }
	public struct function loadResponses(required string walkId) { return variables.inner.loadResponses(argumentCollection = arguments); }
	public void function upsertResponse(required string walkId, required string versionId, required string itemId, required string state, string optionId = "", any textValue, required boolean exists) { variables.inner.upsertResponse(argumentCollection = arguments); }
	public struct function responseCounts(required string walkId) { return variables.inner.responseCounts(argumentCollection = arguments); }
	public numeric function insertRevision(required string walkId, required string actorUserId, required string reason, required string priorSnapshotJson) { return variables.inner.insertRevision(argumentCollection = arguments); }
	public array function listRevisions(required string walkId) { return variables.inner.listRevisions(argumentCollection = arguments); }
	public struct function findMutation(required string mutationId) { return variables.inner.findMutation(argumentCollection = arguments); }
	public void function insertMutation(required string mutationId, required string walkId, required string actorUserId, required string action, required struct result, string requestFingerprint = "") { variables.inner.insertMutation(argumentCollection = arguments); }
	public struct function definitionIndex(required string versionId) { return variables.inner.definitionIndex(argumentCollection = arguments); }
	public void function clearCache() { variables.inner.clearCache(); }
}
