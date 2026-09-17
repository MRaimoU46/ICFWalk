/**
 * Production SSO seam: the district's SSO gateway or reverse proxy authenticates the user and
 * asserts the identity in request headers. Nothing about the identity provider itself (ADFS,
 * Entra ID, Shibboleth, ...) is assumed here; only the header contract, which is environment-driven:
 *
 *   ICFWALK_SSO_SUBJECT_HEADER   header carrying the stable subject id (required)
 *   ICFWALK_SSO_NAME_HEADER      header carrying the display name (optional)
 *   ICFWALK_SSO_EMAIL_HEADER     header carrying the email (optional)
 *   ICFWALK_SSO_TRUSTED_PROXIES  comma-separated IPv4 addresses or CIDR blocks allowed to assert
 *                                identity; requests from any other address are unauthenticated
 *   ICFWALK_SSO_SHARED_SECRET    optional secret the proxy must send in ICFWALK_SSO_SECRET_HEADER
 *
 * Fail-closed rules: no trusted proxy list means nobody is trusted; a request from an untrusted
 * address that carries identity headers is logged as a spoofing attempt and treated as anonymous;
 * a wrong or missing shared secret is treated as anonymous.
 */
component implements="icfwalk.identity.IdentityProvider" output="false" {

	public HeaderIdentityProvider function init(required struct config, required any logger) {
		variables.config = arguments.config;
		variables.logger = arguments.logger;
		variables.subjectHeader = lCase(arguments.config.ssoSubjectHeader);
		variables.nameHeader = lCase(arguments.config.ssoNameHeader);
		variables.emailHeader = lCase(arguments.config.ssoEmailHeader);
		variables.secretHeader = lCase(arguments.config.ssoSecretHeader);
		variables.sharedSecret = arguments.config.ssoSharedSecret;
		variables.trustedProxies = parseProxies(arguments.config.ssoTrustedProxies);
		variables.MessageDigest = createObject("java", "java.security.MessageDigest");
		return this;
	}

	public string function name() { return "header"; }
	public boolean function perRequest() { return true; }

	public struct function resolve(required struct req) {
		var headers = arguments.req.headers;
		var subject = headerValue(headers, variables.subjectHeader);
		if (!isTrustedProxy(arguments.req.remoteAddress)) {
			if (len(subject)) {
				variables.logger.warn("identity.header.untrusted_source", { "remoteAddress": arguments.req.remoteAddress });
			}
			return anonymous("untrusted_source");
		}
		if (len(variables.sharedSecret)) {
			var supplied = headerValue(headers, variables.secretHeader);
			if (!len(supplied) || !constantTimeEquals(supplied, variables.sharedSecret)) {
				variables.logger.warn("identity.header.secret_invalid", { "remoteAddress": arguments.req.remoteAddress });
				return anonymous("secret_invalid");
			}
		}
		if (!len(subject)) return anonymous("no_subject");
		if (len(subject) > 255 || javaCast("string", subject).matches("(?s).*\p{Cntrl}.*")) {
			variables.logger.warn("identity.header.subject_invalid", { "remoteAddress": arguments.req.remoteAddress });
			return anonymous("subject_invalid");
		}
		var displayName = len(variables.nameHeader) ? headerValue(headers, variables.nameHeader) : "";
		var email = len(variables.emailHeader) ? headerValue(headers, variables.emailHeader) : "";
		return {
			"authenticated": true,
			"subject": subject,
			"displayName": len(displayName) ? left(displayName, 200) : subject,
			"email": len(email) && isValid("email", email) ? left(email, 320) : "",
			"claims": {},
			"reason": ""
		};
	}

	// ---- helpers ------------------------------------------------------------------------------

	public boolean function isTrustedProxy(required string address) {
		var addr = trim(arguments.address);
		if (!arrayLen(variables.trustedProxies)) return false;
		for (var entry in variables.trustedProxies) {
			if (entry.cidr) {
				if (ipv4InCidr(addr, entry.network, entry.bits)) return true;
			} else if (entry.address == addr) {
				return true;
			}
		}
		return false;
	}

	private array function parseProxies(required string list) {
		var out = [];
		for (var raw in listToArray(arguments.list, ",")) {
			var item = trim(raw);
			if (!len(item)) continue;
			if (find("/", item)) {
				var network = listFirst(item, "/");
				var bits = val(listLast(item, "/"));
				if (isIpv4(network) && bits >= 0 && bits <= 32) arrayAppend(out, { "cidr": true, "network": network, "bits": bits });
			} else {
				arrayAppend(out, { "cidr": false, "address": item });
			}
		}
		return out;
	}

	private boolean function isIpv4(required string value) {
		return reFind("^([0-9]{1,3}\.){3}[0-9]{1,3}$", arguments.value) > 0;
	}

	private numeric function ipv4ToLong(required string value) {
		var parts = listToArray(arguments.value, ".");
		var n = 0;
		for (var p in parts) n = n * 256 + val(p);
		return n;
	}

	private boolean function ipv4InCidr(required string address, required string network, required numeric bits) {
		if (!isIpv4(arguments.address)) return false;
		if (arguments.bits == 0) return true;
		var size = 2 ^ (32 - arguments.bits);
		var a = int(ipv4ToLong(arguments.address) / size);
		var n = int(ipv4ToLong(arguments.network) / size);
		return a == n;
	}

	private string function headerValue(required struct headers, required string name) {
		if (!len(arguments.name) || !structKeyExists(arguments.headers, arguments.name)) return "";
		return trim(toString(arguments.headers[arguments.name]));
	}

	private boolean function constantTimeEquals(required string a, required string b) {
		return variables.MessageDigest.isEqual(javaCast("string", arguments.a).getBytes("UTF-8"), javaCast("string", arguments.b).getBytes("UTF-8"));
	}

	private struct function anonymous(required string reason) {
		return { "authenticated": false, "subject": "", "displayName": "", "email": "", "claims": {}, "reason": arguments.reason };
	}
}
