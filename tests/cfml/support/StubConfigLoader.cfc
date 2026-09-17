/**
 * ConfigLoader whose environment lookups come from a supplied struct, so configuration rules
 * can be tested without touching real environment variables or files.
 */
component extends="icfwalk.config.ConfigLoader" output="false" {

	public StubConfigLoader function initWithValues(required string repoRoot, required struct values) {
		super.init(arguments.repoRoot);
		variables.stubValues = arguments.values;
		return this;
	}

	public string function value(required string name, string defaultValue = "") {
		if (structKeyExists(variables.stubValues, arguments.name) && len(variables.stubValues[arguments.name])) return variables.stubValues[arguments.name];
		return arguments.defaultValue;
	}
}
