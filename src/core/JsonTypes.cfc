/**
 * What a value's JSON type actually IS, rather than what CFML is willing to treat it as.
 *
 * WHY THIS EXISTS. CFML's built-in predicates answer a coercion question, not a type question, and
 * the two disagree in ways that matter wherever a document's declared type is part of a contract:
 *
 *   isNumeric("144")   -> true    a JSON string that happens to spell a number
 *   isBoolean("144")   -> true    so does a "boolean"
 *   isBoolean(0)       -> true    and so does a number
 *   isBoolean("no")    -> true
 *
 * docs/DATA_CONTRACT.md defines the snapshot's counts block as JSON NUMBERS and the shared
 * instrument's `active` as a JSON BOOLEAN. Under the predicates above a stored snapshot whose
 * counts were `{"items": "144"}` passed publication, and a metadata patch of `{"active": "maybe"}`
 * was coerced to `false` -- which takes a published version out of service for every walker. The
 * value's Java class is the only thing that answers the question actually being asked, because
 * deserializeJSON produces java.lang.String for a JSON string, a java.lang.Number subclass for a
 * JSON number and java.lang.Boolean for a JSON boolean, on both engines.
 *
 * ONE HELPER, NOT A SECOND CONTRACT. This decides types only. It defines no envelope, no count
 * key list and no serialization: DefinitionValidator still owns the snapshot envelope and
 * CanonicalJson still owns canonical bytes. Components construct it themselves rather than taking
 * it as a dependency, so no constructor signature changes to adopt it.
 */
component output="false" {

	variables.NUMBER_CLASSES = [
		"java.lang.Integer", "java.lang.Long", "java.lang.Short", "java.lang.Byte",
		"java.lang.Double", "java.lang.Float", "java.math.BigDecimal", "java.math.BigInteger"
	];
	// The widest whole number the schema's int columns and the runtime's counters both hold.
	variables.MAX_COUNT = 2147483647;

	public JsonTypes function init() {
		return this;
	}

	/** True only for a JSON string (java.lang.String), never for a number or boolean. */
	public boolean function isJsonString(any value) {
		if (isNull(arguments.value)) return false;
		if (!isSimpleValue(arguments.value)) return false;
		return classOf(arguments.value) == "java.lang.String";
	}

	/** True only for a JSON number, never for a numeric-looking string and never for a boolean. */
	public boolean function isJsonNumber(any value) {
		if (isNull(arguments.value)) return false;
		if (!isSimpleValue(arguments.value)) return false;
		return arrayContains(variables.NUMBER_CLASSES, classOf(arguments.value));
	}

	/** True only for a JSON boolean, never for "true", "yes", 1 or 0. */
	public boolean function isJsonBoolean(any value) {
		if (isNull(arguments.value)) return false;
		if (!isSimpleValue(arguments.value)) return false;
		return classOf(arguments.value) == "java.lang.Boolean";
	}

	/**
	 * True when the value is a JSON number that is a whole number, finite, not negative, and inside
	 * the supported integer range. This is the counts-block rule, stated once.
	 */
	public boolean function isCount(any value) {
		if (!isJsonNumber(arguments.value)) return false;
		// NaN fails its own equality test; the infinities fail the range test below.
		if (arguments.value != arguments.value) return false;
		if (arguments.value < 0 || arguments.value > variables.MAX_COUNT) return false;
		return int(arguments.value) == arguments.value;
	}

	public numeric function maxCount() { return variables.MAX_COUNT; }

	/** The value's Java class name, or "" when the engine will not give one. */
	public string function classOf(any value) {
		if (isNull(arguments.value)) return "";
		try {
			return arguments.value.getClass().getName();
		} catch (any e) {
			return "";
		}
	}

	/** A short, safe description of a value's type, for an error message. */
	public string function describe(any value) {
		if (isNull(arguments.value)) return "null";
		if (isArray(arguments.value)) return "an array";
		if (isStruct(arguments.value)) return "an object";
		if (isJsonBoolean(arguments.value)) return "a boolean";
		if (isJsonNumber(arguments.value)) return "a number";
		if (isJsonString(arguments.value)) return "a string";
		return "an unsupported value";
	}
}
