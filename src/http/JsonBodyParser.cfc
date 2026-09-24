/**
 * Turns a request body that has already been authorized and measured into a JSON object (P6A-01).
 *
 * The router calls this LAST: after authentication, CSRF, the permission check (unless the route's
 * policy reads a body member) and the route's byte limit. Nothing that reaches it can be larger than
 * the route allows, and nothing an unauthenticated or CSRF-invalid caller sent ever does.
 *
 * It is a component of its own, held in the application container, so a spec can wrap it in a spy
 * (tests/cfml/support/SpyJsonBodyParser.cfc) and prove how many times a body was deserialized.
 */
component output="false" {

	public JsonBodyParser function init(required any errors) {
		variables.errors = arguments.errors;
		return this;
	}

	public struct function parse(required string text) {
		if (!isJSON(arguments.text)) {
			variables.errors.validation("Request body must be a JSON document.", "INVALID_JSON_BODY");
		}
		// A body of literal `null` parses to CFML null, and reading that variable back is an error
		// rather than a value -- so it is asked with isNull(), and refused like any non-object.
		var parsed = deserializeJSON(arguments.text);
		if (isNull(parsed) || !isStruct(parsed)) {
			variables.errors.validation("Request body must be a JSON object.", "INVALID_JSON_BODY");
		}
		return parsed;
	}
}
