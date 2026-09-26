/**
 * Engine-independent HTML output encoding. Adobe ColdFusion ships encodeForHTML (ESAPI) but the
 * Lucee light verification runtime does not, so the few server-rendered HTML fragments (the
 * shell template values and the HTML error page) use this explicit encoder. Encodes the five
 * HTML metacharacters plus '/' so a value is safe in text content and in quoted attributes.
 */
component output="false" {

	public HtmlEncoder function init() { return this; }

	public string function encode(any value) {
		if (!structKeyExists(arguments, "value")) return "";
		var s = toString(arguments.value);
		s = replace(s, "&", "&amp;", "all");
		s = replace(s, "<", "&lt;", "all");
		s = replace(s, ">", "&gt;", "all");
		s = replace(s, '"', "&quot;", "all");
		s = replace(s, "'", "&##39;", "all");
		s = replace(s, "/", "&##47;", "all");
		return s;
	}

	/** Attribute-safe encoding for values placed inside double-quoted attributes (keeps '/'). */
	public string function encodeAttribute(any value) {
		if (!structKeyExists(arguments, "value")) return "";
		var s = toString(arguments.value);
		s = replace(s, "&", "&amp;", "all");
		s = replace(s, "<", "&lt;", "all");
		s = replace(s, ">", "&gt;", "all");
		s = replace(s, '"', "&quot;", "all");
		s = replace(s, "'", "&##39;", "all");
		return s;
	}
}
