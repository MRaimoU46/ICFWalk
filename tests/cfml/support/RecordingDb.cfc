/**
 * A Db that records every statement run through it -- its SQL and the query it returned -- and
 * otherwise behaves exactly as the real one (everything is delegated). Tests only: a spec builds a
 * repository on it to see what a method actually reads from SQL Server, not just what it returns.
 */
component output="false" {

	public RecordingDb function init(required any delegate) {
		variables.inner = arguments.delegate;
		variables.log = [];
		return this;
	}

	public query function run(required string sql, struct params = {}) {
		var q = variables.inner.run(arguments.sql, arguments.params);
		arrayAppend(variables.log, { "sql": arguments.sql, "result": q });
		return q;
	}

	/** Every recorded statement whose SQL contains `fragment`, oldest first. */
	public array function statementsContaining(required string fragment) {
		var out = [];
		for (var entry in variables.log) if (findNoCase(arguments.fragment, entry.sql)) arrayAppend(out, entry);
		return out;
	}

	public void function clear() {
		variables.log = [];
	}

	public any function onMissingMethod(required string missingMethodName, required struct missingMethodArguments) {
		return invoke(variables.inner, arguments.missingMethodName, arguments.missingMethodArguments);
	}
}
