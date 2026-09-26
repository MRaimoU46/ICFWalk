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
		// Performance (P8-14): a string with nothing to escape is written in one append, and struct
		// keys are sorted by Java rather than by a CFML comparator; the bytes are unchanged. The
		// pattern finds what writeString escapes: a quote, a backslash, a control character or a
		// lone surrogate (Java matches by code point, so a valid surrogate pair is not found here and
		// is copied whole, exactly as the character loop copies it).
		variables.NEEDS_ESCAPE = createObject("java", "java.util.regex.Pattern").compile("[""\\\x00-\x1F\uD800-\uDFFF]");
		variables.Collections = createObject("java", "java.util.Collections");
		return this;
	}

	public string function serialize(any value) {
		// The output is collected as parts and joined once: on Adobe ColdFusion each call to a Java
		// StringBuilder's overloaded append costs several microseconds of method resolution, a
		// hundred times arrayAppend's (P8-14). The parts live in a struct, which both engines pass by
		// reference, so the writer below appends to one array whatever passArrayByReference says.
		var buf = { "parts": [] };
		if (!structKeyExists(arguments, "value")) {
			arrayAppend(buf.parts, "null");
		} else {
			write(buf, arguments.value);
		}
		return arrayToList(buf.parts, "");
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

	private void function write(required struct buf, required any value) {
		if (!structKeyExists(arguments, "value")) {
			arrayAppend(arguments.buf.parts, "null");
			return;
		}
		var v = arguments.value;
		if (isStruct(v)) {
			writeStruct(arguments.buf, v);
			return;
		}
		if (isArray(v)) {
			arrayAppend(arguments.buf.parts, "[");
			var n = arrayLen(v);
			for (var i = 1; i <= n; i++) {
				if (i > 1) arrayAppend(arguments.buf.parts, ",");
				if (!arrayIsDefined(v, i)) arrayAppend(arguments.buf.parts, "null");
				else write(arguments.buf, v[i]);
			}
			arrayAppend(arguments.buf.parts, "]");
			return;
		}
		if (isInstanceOf(v, "java.lang.Boolean")) {
			arrayAppend(arguments.buf.parts, v ? "true" : "false");
			return;
		}
		if (isInstanceOf(v, "java.lang.Number")) {
			arrayAppend(arguments.buf.parts, formatNumber(v));
			return;
		}
		if (isInstanceOf(v, "java.util.Date")) {
			writeString(arguments.buf, formatDate(v));
			return;
		}
		if (isInstanceOf(v, "java.lang.String")) {
			writeString(arguments.buf, v);
			return;
		}
		if (isQuery(v)) {
			writeQuery(arguments.buf, v);
			return;
		}
		if (isSimpleValue(v)) {
			// CFML simple values whose Java type is not one of the above (rare engine wrappers).
			if (isBoolean(v) && !isNumeric(v)) { arrayAppend(arguments.buf.parts, v ? "true" : "false"); return; }
			if (isNumeric(v) && isValid("numeric", v) && !isInstanceOf(v, "java.lang.String")) { arrayAppend(arguments.buf.parts, formatNumber(v)); return; }
			writeString(arguments.buf, toString(v));
			return;
		}
		throw(type = "ICFWalk.Validation", message = "Canonical JSON cannot encode value of type " & v.getClass().getName(), errorcode = "CANONICAL_JSON_TYPE");
	}

	private void function writeStruct(required struct buf, required struct value) {
		// String.compareTo is UTF-16 code unit order, the order the rules require.
		var keys = createObject("java", "java.util.ArrayList").init(structKeyArray(arguments.value));
		variables.Collections.sort(keys);
		arrayAppend(arguments.buf.parts, "{");
		var n = keys.size();
		for (var i = 0; i < n; i++) {
			var key = keys.get(i);
			if (i > 0) arrayAppend(arguments.buf.parts, ",");
			writeString(arguments.buf, key);
			arrayAppend(arguments.buf.parts, ":");
			if (!structKeyExists(arguments.value, key)) arrayAppend(arguments.buf.parts, "null");
			else write(arguments.buf, arguments.value[key]);
		}
		arrayAppend(arguments.buf.parts, "}");
	}

	private void function writeQuery(required struct buf, required query value) {
		var rows = [];
		var columns = listToArray(arguments.value.columnList);
		for (var r = 1; r <= arguments.value.recordCount; r++) {
			var row = {};
			for (var col in columns) {
				row[col] = arguments.value[col][r];
			}
			arrayAppend(rows, row);
		}
		write(arguments.buf, rows);
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

	private void function writeString(required struct buf, required string value) {
		var s = javaCast("string", arguments.value);
		if (!variables.NEEDS_ESCAPE.matcher(s).find()) {
			arrayAppend(arguments.buf.parts, '"' & s & '"');
			return;
		}
		// Something to escape: one UTF-16 code unit at a time, as JavaScript does.
		var sb = createObject("java", "java.lang.StringBuilder").init();
		var n = s.length();
		sb.append('"');
		var i = 0;
		// Work with UTF-16 code units to mirror JavaScript semantics exactly.
		while (i < n) {
			var ch = s.charAt(i);
			var c = javaCast("int", ch);
			if (c == 34) sb.append('\"');
			else if (c == 92) sb.append("\\");
			else if (c == 8) sb.append("\b");
			else if (c == 12) sb.append("\f");
			else if (c == 10) sb.append("\n");
			else if (c == 13) sb.append("\r");
			else if (c == 9) sb.append("\t");
			else if (c < 32) sb.append("\u" & right("000" & lCase(formatBaseN(c, 16)), 4));
			else if (c >= 55296 && c <= 56319) {
				// High surrogate: valid only when followed by a low surrogate.
				var nextUnit = (i + 1 < n) ? javaCast("int", s.charAt(i + 1)) : 0;
				if (nextUnit >= 56320 && nextUnit <= 57343) {
					sb.append(ch);
					sb.append(s.charAt(i + 1));
					i++;
				} else {
					sb.append("\u" & lCase(formatBaseN(c, 16)));
				}
			}
			else if (c >= 56320 && c <= 57343) sb.append("\u" & lCase(formatBaseN(c, 16)));
			else sb.append(ch);
			i++;
		}
		sb.append('"');
		arrayAppend(arguments.buf.parts, sb.toString());
	}
}
