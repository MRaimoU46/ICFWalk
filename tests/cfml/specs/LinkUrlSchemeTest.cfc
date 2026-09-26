/**
 * Phase 8, defect P8-06: an item's reference link may only be an http or https address.
 *
 * `linkUrl` comes from an imported instrument document (JSON, or the Excel workbook converted to
 * one) and the walk editor renders it as a link on the item for every walker. Nothing checked its
 * scheme, so a document could carry `javascript:...`, `data:text/html,...` or any other scheme, and
 * the import stored it and the editor linked it. The page's Content-Security-Policy stops a
 * `javascript:` link from running in a browser that enforces it; that is the second defense, not
 * the first.
 *
 * The rule lives in the shared DefinitionValidator, so an import refuses such a document and a
 * publication refuses a draft that holds one (imported before the rule existed). The browser side,
 * which also refuses to link anything but http(s), is tests/node/browser-xss-sweep.test.mjs.
 *
 * No database: the validators are pure.
 */
component extends="icfwalktests.BaseSpec" output="false" {

	variables.REFUSED = [
		"javascript:alert(1)",
		"JavaScript:alert(1)",
		" javascript:alert(1)",
		"java" & chr(9) & "script:alert(1)",
		"data:text/html,<script>alert(1)</script>",
		"vbscript:msgbox(1)",
		"file:///etc/passwd",
		"//evil.example/reference",
		"/relative/reference",
		"https://",
		"https://example.test/a b",
		"https://example.test/" & chr(10) & "x",
		"https://example.test/""onmouseover=""alert(1)"
	];

	variables.ACCEPTED = [
		"https://drive.google.com/file/d/1tV3OclL/view",
		"http://example.test/reference",
		"HTTPS://EXAMPLE.TEST/Reference?x=1&y=2##part"
	];

	public void function beforeEach() {
		variables.config = repoJson("config/instrument-config.json");
		variables.linked = 0;
		for (var i = 1; i <= arrayLen(variables.config.items); i++) {
			var item = variables.config.items[i];
			if (structKeyExists(item, "linkUrl") && !isNull(item.linkUrl) && len(item.linkUrl)) variables.linked = i;
		}
	}

	public void function testTheSuppliedInstrumentHasALinkAndItIsAccepted() {
		assertTrue(variables.linked > 0, "the supplied instrument carries a linked item");
		var r = variables.c.configValidator.validate(variables.config);
		assertTrue(r.valid, "Expected no errors: " & (arrayLen(r.errors) ? r.errors[1].message : ""));
	}

	public void function testAnImportRefusesEveryLinkThatIsNotHttpOrHttps() {
		for (var candidate in variables.REFUSED) {
			var doc = duplicate(variables.config);
			doc.items[variables.linked].linkUrl = candidate;
			var r = variables.c.configValidator.validate(doc);
			assertFalse(r.valid, "an import accepted linkUrl " & serializeJSON(candidate));
			assertTrue(hasError(r, "INVALID_LINK_URL", doc.items[variables.linked].itemKey), "INVALID_LINK_URL naming the item for " & serializeJSON(candidate) & ": " & serializeJSON(r.errors));
		}
	}

	public void function testAnImportAcceptsHttpAndHttpsLinks() {
		for (var candidate in variables.ACCEPTED) {
			var doc = duplicate(variables.config);
			doc.items[variables.linked].linkUrl = candidate;
			var r = variables.c.configValidator.validate(doc);
			assertTrue(r.valid, "an import refused linkUrl " & serializeJSON(candidate) & ": " & (arrayLen(r.errors) ? r.errors[1].message : ""));
		}
	}

	public void function testAnEmptyLinkIsNoLink() {
		var doc = duplicate(variables.config);
		doc.items[variables.linked].linkUrl = "";
		assertTrue(variables.c.configValidator.validate(doc).valid, "an empty linkUrl is no link, not an invalid one");
	}

	/** The same rule refuses publication of a draft that already holds such a link. */
	public void function testPublicationRefusesADraftHoldingSuchALink() {
		var doc = duplicate(variables.config);
		doc.items[variables.linked].linkUrl = "javascript:alert(1)";
		var definitions = variables.c.configNormalizer.fromConfig(doc).definitions;
		var r = variables.c.definitionValidator.validate(definitions);
		assertFalse(r.valid, "the shared rule set accepted a javascript: link");
		assertTrue(hasError(r, "INVALID_LINK_URL", doc.items[variables.linked].itemKey));
	}

	private boolean function hasError(required struct r, required string code, required string needle) {
		for (var e in arguments.r.errors) {
			if (compare(e.code, arguments.code) == 0 && (!len(arguments.needle) || find(arguments.needle, e.message))) return true;
		}
		return false;
	}
}
