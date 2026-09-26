/**
 * Canonical JSON (icfwalk-canonical-json/1): deterministic serialization used for compiled
 * instrument snapshots, checksums, stored JSON documents, log lines, and API responses.
 *
 * Rules (must stay byte-identical to scripts/lib/snapshot.mjs):
 *   - Struct keys are sorted by UTF-16 code unit order; no whitespace.
 *   - Arrays keep their order.
 *   - Strings are escaped like JSON.stringify: \" \\ \b \f \n \r \t, other control characters
 *     and lone surrogates as lowercase \uXXXX; non-ASCII is emitted unescaped.
 *   - Numbers: integers as plain digits, decimals as the shortest round-trip plain decimal.
 *   - Booleans are true/false; null is null. Dates are ISO-8601 UTC strings with milliseconds.
 *
 * Type detection uses the underlying Java class so that numeric-looking strings stay strings
 * (this is why values must come from deserializeJSON or explicit typed assignments, never from
 * string concatenation when a number is intended).
 */
component output="false" {

	public CanonicalJson function init() {
		variables.BigDecimal = createObject("java", "java.math.BigDecimal");
		variables.formatter = createObject("java", "java.time.format.DateTimeFormatter")
			.ofPattern("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'")
			.withZone(createObject("java", "java.time.ZoneOffset").UTC);
		variables.Instant = createObject("java", "java.time.Instant");
		return this;
	}

	public string function serialize(any value) {
		var sb = createObject("java", "java.lang.StringBuilder").init();
		if (isNull(arguments.value)) {
			sb.append("null");
		} else {
			write(sb, arguments.value);
		}
		return sb.toString();
	}

	public string function sha256(required string text) {
		return lCase(hash(arguments.text, "SHA-256", "UTF-8"));
	}

	public string function formatDate(required any value) {
		var millis = arguments.value.getTime();
		return variables.formatter.format(variables.Instant.ofEpochMilli(javaCast("long", millis)));
	}

	/**
	 * Parses an ISO-8601 instant (for example 2026-09-17T00:00:00Z) into a date, or throws
	 * ICFWalk.Validation when the text is not a valid instant.
	 */
	public date function parseInstant(required string text) {
		try {
			var instant = variables.Instant.parse(javaCast("string", trim(arguments.text)));
			return createObject("java", "java.util.Date").init(javaCast("long", instant.toEpochMilli()));
		} catch (any e) {
			throw(type = "ICFWalk.Validation", message = "Invalid ISO-8601 instant: " & arguments.text, errorcode = "INVALID_INSTANT");
		}
	}

	private void function write(required any sb, required any value) {
		if (isNull(arguments.value)) {
			arguments.sb.append("null");
			return;
		}
		var v = arguments.value;
		if (isStruct(v)) {
			writeStruct(arguments.sb, v);
			return;
		}
		if (isArray(v)) {
			arguments.sb.append("[");
			var n = arrayLen(v);
			for (var i = 1; i <= n; i++) {
				if (i > 1) arguments.sb.append(",");
				if (!arrayIsDefined(v, i)) arguments.sb.append("null");
				else write(arguments.sb, v[i]);
			}
			arguments.sb.append("]");
			return;
		}
		if (isInstanceOf(v, "java.lang.Boolean")) {
			arguments.sb.append(v ? "true" : "false");
			return;
		}
		if (isInstanceOf(v, "java.lang.Number")) {
			arguments.sb.append(formatNumber(v));
			return;
		}
		if (isInstanceOf(v, "java.util.Date")) {
			writeString(arguments.sb, formatDate(v));
			return;
		}
		if (isInstanceOf(v, "java.lang.String")) {
			writeString(arguments.sb, v);
			return;
		}
		if (isQuery(v)) {
			writeQuery(arguments.sb, v);
			return;
		}
		if (isSimpleValue(v)) {
			// CFML simple values whose Java type is not one of the above (rare engine wrappers).
			if (isBoolean(v) && !isNumeric(v)) { arguments.sb.append(v ? "true" : "false"); return; }
			if (isNumeric(v) && isValid("numeric", v) && !isInstanceOf(v, "java.lang.String")) { arguments.sb.append(formatNumber(v)); return; }
			writeString(arguments.sb, toString(v));
			return;
		}
		throw(type = "ICFWalk.Validation", message = "Canonical JSON cannot encode value of type " & v.getClass().getName(), errorcode = "CANONICAL_JSON_TYPE");
	}

	private void function writeStruct(required any sb, required struct value) {
		var keys = structKeyArray(arguments.value);
		arraySort(keys, function(a, b) {
			return sgn(javaCast("string", a).compareTo(javaCast("string", b)));
		});
		arguments.sb.append("{");
		var n = arrayLen(keys);
		for (var i = 1; i <= n; i++) {
			if (i > 1) arguments.sb.append(",");
			writeString(arguments.sb, keys[i]);
			arguments.sb.append(":");
			if (isNull(arguments.value[keys[i]])) arguments.sb.append("null");
			else write(arguments.sb, arguments.value[keys[i]]);
		}
		arguments.sb.append("}");
	}

	private void function writeQuery(required any sb, required query value) {
		var rows = [];
		var columns = listToArray(arguments.value.columnList);
		for (var r = 1; r <= arguments.value.recordCount; r++) {
			var row = {};
			for (var col in columns) {
				row[col] = arguments.value[col][r];
			}
			arrayAppend(rows, row);
		}
		write(arguments.sb, rows);
	}

	private string function formatNumber(required any value) {
		var text = javaCast("string", arguments.value.toString());
		if (text == "NaN" || findNoCase("Infinity", text)) {
			throw(type = "ICFWalk.Validation", message = "Canonical JSON cannot encode NaN or Infinity.", errorcode = "CANONICAL_JSON_NUMBER");
		}
		var bd = variables.BigDecimal.init(text);
		if (bd.signum() == 0) return "0";
		return bd.stripTrailingZeros().toPlainString();
	}

	private void function writeString(required any sb, required string value) {
		var s = javaCast("string", arguments.value);
		var n = s.length();
		arguments.sb.append('"');
		var i = 0;
		// Work with UTF-16 code units to mirror JavaScript semantics exactly.
		while (i < n) {
			var ch = s.charAt(i);
			var c = javaCast("int", ch);
			if (c == 34) arguments.sb.append('\"');
			else if (c == 92) arguments.sb.append("\\");
			else if (c == 8) arguments.sb.append("\b");
			else if (c == 12) arguments.sb.append("\f");
			else if (c == 10) arguments.sb.append("\n");
			else if (c == 13) arguments.sb.append("\r");
			else if (c == 9) arguments.sb.append("\t");
			else if (c < 32) arguments.sb.append("\u" & right("000" & lCase(formatBaseN(c, 16)), 4));
			else if (c >= 55296 && c <= 56319) {
				// High surrogate: valid only when followed by a low surrogate.
				var nextUnit = (i + 1 < n) ? javaCast("int", s.charAt(i + 1)) : 0;
				if (nextUnit >= 56320 && nextUnit <= 57343) {
					arguments.sb.append(ch);
					arguments.sb.append(s.charAt(i + 1));
					i++;
				} else {
					arguments.sb.append("\u" & lCase(formatBaseN(c, 16)));
				}
			}
			else if (c >= 56320 && c <= 57343) arguments.sb.append("\u" & lCase(formatBaseN(c, 16)));
			else arguments.sb.append(ch);
			i++;
		}
		arguments.sb.append('"');
	}
}
