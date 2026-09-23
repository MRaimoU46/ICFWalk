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
}
