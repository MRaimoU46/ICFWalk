/**
 * A ReportRepository that delegates everything to the real one and fires a callback at one named
 * seam, the way support/InterceptingWalkRepository does for walks. It lets a spec put a real,
 * committed concurrent SAVE at an exact point *inside* a report computation -- after the
 * population's row versions were captured and some aggregates were read, before the rest are --
 * and observe what the report does about it. There is no test-only seam in production code:
 * ReportService reads walks through its repository and nothing else.
 *
 * arm(seam, fn) fires fn before the next call to `seam` and then disarms, unless fn re-arms it
 * (armEvery keeps it armed for every call). fired(seam) is how many times it ran.
 */
component output="false" {

	public InterceptingReportRepository function init(required any delegate) {
		variables.inner = arguments.delegate;
		variables.hooks = {};
		variables.persistent = {};
		// Not "fired"/"calls": a component's variables scope also holds its functions, so a struct
		// by either name would replace the method of the same name for every internal call.
		variables.firedCount = {};
		variables.callCount = {};
		return this;
	}

	public void function arm(required string seam, required any fn) {
		variables.hooks[arguments.seam] = arguments.fn;
		variables.persistent[arguments.seam] = false;
		variables.firedCount[arguments.seam] = 0;
	}

	public void function armEvery(required string seam, required any fn) {
		arm(arguments.seam, arguments.fn);
		variables.persistent[arguments.seam] = true;
	}

	public numeric function fired(required string seam) {
		return structKeyExists(variables.firedCount, arguments.seam) ? variables.firedCount[arguments.seam] : 0;
	}

	/** How many times the report called a seam, armed or not (for "it retried" assertions). */
	public numeric function calls(required string seam) {
		return structKeyExists(variables.callCount, arguments.seam) ? variables.callCount[arguments.seam] : 0;
	}

	private void function trigger(required string seam) {
		variables.callCount[arguments.seam] = calls(arguments.seam) + 1;
		if (!structKeyExists(variables.hooks, arguments.seam)) return;
		var fn = variables.hooks[arguments.seam];
		if (!variables.persistent[arguments.seam]) structDelete(variables.hooks, arguments.seam);
		variables.firedCount[arguments.seam] = fired(arguments.seam) + 1;
		fn();
	}

	// ---- hooked seams ------------------------------------------------------------------------------

	public numeric function selectCandidates(required string versionId, required array statuses, any observedFrom = "", any observedBefore = "") {
		trigger("selectCandidates");
		return variables.inner.selectCandidates(arguments.versionId, arguments.statuses, arguments.observedFrom, arguments.observedBefore);
	}

	/**
	 * Fires between the dimension aggregates and the item aggregates: by the time this runs the
	 * report has captured every row version and read every walk's dimension values, and has not
	 * read a single response. A save committed here is the torn read itself.
	 */
	public array function itemCounts(required array itemIds) {
		trigger("itemCounts");
		return variables.inner.itemCounts(arguments.itemIds);
	}

	/** The release freeze's counterpart of itemCounts: after the dimension aggregates, before any response. */
	public array function unitItemCounts(required array itemIds) {
		trigger("unitItemCounts");
		return variables.inner.unitItemCounts(arguments.itemIds);
	}

	public numeric function verifyPopulation() {
		trigger("verifyPopulation");
		return variables.inner.verifyPopulation();
	}

	// ---- pass-through ------------------------------------------------------------------------------

	public array function listFrozenVersions(required string instrumentCode) { return variables.inner.listFrozenVersions(arguments.instrumentCode); }
	public void function beginPopulation() { variables.inner.beginPopulation(); }
	public void function endPopulation() { variables.inner.endPopulation(); }
	public void function loadScope(required array orgUnitIds) { variables.inner.loadScope(arguments.orgUnitIds); }
	public numeric function populationSize() { return variables.inner.populationSize(); }
	public void function restrictToDimensionValue(required string dimensionId, required string valueId, required struct visibility) { variables.inner.restrictToDimensionValue(arguments.dimensionId, arguments.valueId, arguments.visibility); }
	public void function restrictToOption(required string itemId, required string optionId) { variables.inner.restrictToOption(arguments.itemId, arguments.optionId); }
	public array function unitStatusCounts() { return variables.inner.unitStatusCounts(); }
	public array function dimensionCounts(required string dimensionId, required struct visibility) { return variables.inner.dimensionCounts(arguments.dimensionId, arguments.visibility); }
	public string function visibilitySql(required struct visibility, required string alias, required struct params) { return variables.inner.visibilitySql(arguments.visibility, arguments.alias, arguments.params); }
	public array function unitDimensionCounts(required string dimensionId, required struct visibility) { return variables.inner.unitDimensionCounts(arguments.dimensionId, arguments.visibility); }
	public array function versionsWithCompletedWalks(required date observedFrom, required date observedBefore) { return variables.inner.versionsWithCompletedWalks(arguments.observedFrom, arguments.observedBefore); }
	public void function lockReleases() { variables.inner.lockReleases(); }
	public boolean function overlapsRelease(required string fromDay, required string toDay) { return variables.inner.overlapsRelease(arguments.fromDay, arguments.toDay); }
	public void function insertRelease(required string releaseId, required string fromDay, required string toDay, required numeric minimumWalks, required string releasedBy) { variables.inner.insertRelease(arguments.releaseId, arguments.fromDay, arguments.toDay, arguments.minimumWalks, arguments.releasedBy); }
	public void function insertBlock(required string releaseId, required string versionId, required string orgUnitId, required numeric walks) { variables.inner.insertBlock(arguments.releaseId, arguments.versionId, arguments.orgUnitId, arguments.walks); }
	public void function insertCells(required string releaseId, required string versionId, required string orgUnitId, required array cells) { variables.inner.insertCells(arguments.releaseId, arguments.versionId, arguments.orgUnitId, arguments.cells); }
	public array function listReleases() { return variables.inner.listReleases(); }
	public struct function findRelease(required string releaseId) { return variables.inner.findRelease(arguments.releaseId); }
	public array function releaseBlockIndex() { return variables.inner.releaseBlockIndex(); }
	public array function releaseBlocks(required string releaseId, required string versionId) { return variables.inner.releaseBlocks(arguments.releaseId, arguments.versionId); }
	public array function releaseCells(required string releaseId, required string versionId, required array orgUnitIds) { return variables.inner.releaseCells(arguments.releaseId, arguments.versionId, arguments.orgUnitIds); }
}
