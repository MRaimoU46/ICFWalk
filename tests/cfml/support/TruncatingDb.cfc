/**
 * A Db whose run() answers as a datasource without long text retrieval does: every string value
 * longer than `limit` characters comes back cut to its first `limit` characters. Adobe ColdFusion's
 * default datasource settings do exactly that to an nvarchar(max) value past 32,000 characters
 * (defect P8-04). Everything else passes through to the real Db. Tests only.
 */
component output="false" {

	public TruncatingDb function init(required any delegate, numeric limit = 32000) {
		variables.inner = arguments.delegate;
		variables.limit = arguments.limit;
		return this;
	}

	public query function run(required string sql, struct params = {}) {
		var q = variables.inner.run(arguments.sql, arguments.params);
		for (var column in listToArray(q.columnList)) {
			for (var r = 1; r <= q.recordCount; r++) {
				var v = q[column][r];
				if (isSimpleValue(v) && len(v) > variables.limit) querySetCell(q, column, left(v, variables.limit), r);
			}
		}
		return q;
	}

	public any function onMissingMethod(required string missingMethodName, required struct missingMethodArguments) {
		return invoke(variables.inner, arguments.missingMethodName, arguments.missingMethodArguments);
	}
}
