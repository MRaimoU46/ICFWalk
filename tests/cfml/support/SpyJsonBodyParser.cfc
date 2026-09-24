/**
 * The real JsonBodyParser, counting every call (P6A-01 specs). A spec hands this to a Router it
 * constructs, so "the body was never deserialized" is an observed count of zero, not an inference.
 *
 * TEST-ONLY. Lives under tests/cfml; nothing in src/ references it.
 */
component output="false" {

	public SpyJsonBodyParser function init(required any delegate) {
		variables.inner = arguments.delegate;
		variables.calls = 0;
		return this;
	}

	public struct function parse(required string text) {
		variables.calls++;
		return variables.inner.parse(arguments.text);
	}

	public numeric function calls() { return variables.calls; }
}
