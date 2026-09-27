/**
 * A Db for a reachable SQL Server database that holds no ICFWalk schema (finding A8-01). The health
 * check asks SQL Server whether [icf].[instrument] exists; through this double the question names a
 * table that exists in no database, so SQL Server itself answers that it is absent, exactly as it does
 * for a new database before migration 001 or a datasource pointed at the wrong database. Every other
 * statement, the long text probe included, reaches the real Db unchanged.
 *
 * schemaProbes() counts the statements it redirected, so a spec can prove that the absence it reports
 * came from SQL Server and not from a fixture that never ran. Tests only.
 */
component output="false" {

	variables.PRESENT = "N'[icf].[instrument]'";
	variables.ABSENT = "N'[icf].[instrument_absent_for_a8_01]'";

	public SchemaAbsentDb function init(required any delegate) {
		variables.inner = arguments.delegate;
		variables.redirected = 0;
		return this;
	}

	public query function run(required string sql, struct params = {}) {
		var statement = arguments.sql;
		if (find(variables.PRESENT, statement)) {
			statement = replace(statement, variables.PRESENT, variables.ABSENT, "all");
			variables.redirected++;
		}
		return variables.inner.run(statement, arguments.params);
	}

	public numeric function schemaProbes() {
		return variables.redirected;
	}

	public any function onMissingMethod(required string missingMethodName, required struct missingMethodArguments) {
		return invoke(variables.inner, arguments.missingMethodName, arguments.missingMethodArguments);
	}
}
