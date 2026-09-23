/**
 * A Logger that records every entry exactly as the real Logger would write it -- built by the real
 * Logger's buildEntry, so the same redaction and truncation apply -- and then writes it through the
 * real Logger as well. Specs use it to assert what a code path puts in the log (SEC-05, RPT-06)
 * without reading the engine's log files.
 */
component output="false" {

	public CapturingLogger function init(required any delegate, required any canonicalJson) {
		variables.inner = arguments.delegate;
		variables.json = arguments.canonicalJson;
		variables.entries = [];
		return this;
	}

	public void function debug(required string event, struct fields = {}) { capture("DEBUG", arguments.event, arguments.fields); variables.inner.debug(arguments.event, arguments.fields); }
	public void function info(required string event, struct fields = {}) { capture("INFO", arguments.event, arguments.fields); variables.inner.info(arguments.event, arguments.fields); }
	public void function warn(required string event, struct fields = {}) { capture("WARN", arguments.event, arguments.fields); variables.inner.warn(arguments.event, arguments.fields); }
	public void function error(required string event, struct fields = {}) { capture("ERROR", arguments.event, arguments.fields); variables.inner.error(arguments.event, arguments.fields); }
	public boolean function isEnabled(required string level) { return variables.inner.isEnabled(arguments.level); }
	public struct function buildEntry(required string level, required string event, struct fields = {}) { return variables.inner.buildEntry(arguments.level, arguments.event, arguments.fields); }

	/** The captured lines, each the canonical JSON the real Logger writes. */
	public array function lines() {
		var out = [];
		for (var e in variables.entries) arrayAppend(out, variables.json.serialize(e));
		return out;
	}

	public array function events() {
		var out = [];
		for (var e in variables.entries) arrayAppend(out, e.event);
		return out;
	}

	private void function capture(required string level, required string event, required struct fields) {
		arrayAppend(variables.entries, variables.inner.buildEntry(arguments.level, arguments.event, arguments.fields));
	}
}
