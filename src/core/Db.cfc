/**
 * Thin data-access helper. Every statement runs through queryExecute with typed, parameterized
 * values (cfqueryparam semantics); no SQL is ever concatenated from input. Helpers build the
 * parameter structs so callers state the intended SQL type explicitly.
 */
component output="false" {

	public Db function init(required string datasource) {
		variables.datasource = arguments.datasource;
		variables.UUID = createObject("java", "java.util.UUID");
		return this;
	}

	public string function datasourceName() {
		return variables.datasource;
	}

	public query function run(required string sql, struct params = {}) {
		var q = queryExecute(arguments.sql, arguments.params, { "datasource": variables.datasource });
		// A statement with no result set (an INSERT, UPDATE or DELETE without OUTPUT) returns nothing
		// on Adobe ColdFusion and an empty query on Lucee; callers get the empty query on both (P8-02).
		if (!structKeyExists(local, "q")) return queryNew("");
		return q;
	}

	public numeric function scalar(required string sql, struct params = {}, numeric defaultValue = 0) {
		var q = run(arguments.sql, arguments.params);
		if (!q.recordCount) return arguments.defaultValue;
		var v = q[listFirst(q.columnList)][1];
		if (!structKeyExists(local, "v") || !isNumeric(v)) return arguments.defaultValue;
		return v;
	}

	/**
	 * Runs fn inside one transaction. Any exception rolls the transaction back and is rethrown.
	 * Nested calls join the outer transaction (CFML semantics).
	 */
	public any function transact(required any fn) {
		var result = "";
		transaction {
			try {
				result = arguments.fn();
				transactionCommit();
			} catch (any e) {
				transactionRollback();
				rethrow;
			}
		}
		return result;
	}

	public string function newGuid() {
		return uCase(variables.UUID.randomUUID().toString());
	}

	public boolean function isGuid(any value) {
		if (!structKeyExists(arguments, "value") || !isSimpleValue(arguments.value)) return false;
		return reFind("^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$", trim(arguments.value)) > 0;
	}

	// ---- typed parameter builders -------------------------------------------------------

	public struct function guid(any value) {
		if (!structKeyExists(arguments, "value") || !len(trim(arguments.value))) return { "value": "", "cfsqltype": "cf_sql_varchar", "null": true };
		if (!isGuid(arguments.value)) throw(type = "ICFWalk.Validation", message = "Value is not a GUID.", errorcode = "INVALID_GUID");
		return { "value": uCase(trim(arguments.value)), "cfsqltype": "cf_sql_varchar" };
	}

	public struct function nvarchar(any value, numeric maxLength = 0) {
		if (!structKeyExists(arguments, "value")) return { "value": "", "cfsqltype": "cf_sql_nvarchar", "null": true };
		var s = toString(arguments.value);
		if (arguments.maxLength > 0 && len(s) > arguments.maxLength) {
			throw(type = "ICFWalk.Validation", message = "Value exceeds " & arguments.maxLength & " characters.", errorcode = "VALUE_TOO_LONG");
		}
		return { "value": s, "cfsqltype": "cf_sql_nvarchar" };
	}

	public struct function ntext(any value) {
		if (!structKeyExists(arguments, "value")) return { "value": "", "cfsqltype": "cf_sql_longnvarchar", "null": true };
		return { "value": toString(arguments.value), "cfsqltype": "cf_sql_longnvarchar" };
	}

	public struct function integer(any value) {
		if (!structKeyExists(arguments, "value") || (isSimpleValue(arguments.value) && !len(trim(arguments.value)))) return { "value": "", "cfsqltype": "cf_sql_integer", "null": true };
		return { "value": javaCast("int", arguments.value), "cfsqltype": "cf_sql_integer" };
	}

	public struct function bigint(any value) {
		if (!structKeyExists(arguments, "value")) return { "value": "", "cfsqltype": "cf_sql_bigint", "null": true };
		return { "value": javaCast("long", arguments.value), "cfsqltype": "cf_sql_bigint" };
	}

	public struct function bit(any value) {
		if (!structKeyExists(arguments, "value")) return { "value": "", "cfsqltype": "cf_sql_bit", "null": true };
		return { "value": (arguments.value ? true : false), "cfsqltype": "cf_sql_bit" };
	}

	public struct function decimal(any value, numeric scale = 4) {
		if (!structKeyExists(arguments, "value") || (isSimpleValue(arguments.value) && !len(trim(arguments.value)))) return { "value": "", "cfsqltype": "cf_sql_decimal", "scale": arguments.scale, "null": true };
		return { "value": arguments.value, "cfsqltype": "cf_sql_decimal", "scale": arguments.scale };
	}

	public struct function timestamp(any value) {
		if (!structKeyExists(arguments, "value") || (isSimpleValue(arguments.value) && !len(trim(arguments.value)))) return { "value": "", "cfsqltype": "cf_sql_timestamp", "null": true };
		return { "value": arguments.value, "cfsqltype": "cf_sql_timestamp" };
	}
}
