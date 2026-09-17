/**
 * Server session state for the signed-in user. The session stores only the user id, subject,
 * sign-in time, and the CSRF synchronizer token; roles and scope are re-resolved from the database
 * on every request so revocations take effect immediately. The session id is rotated at sign-in
 * (fixation defense) and the session is invalidated at sign-out.
 */
component output="false" {

	public SessionService function init(required struct config) {
		variables.config = arguments.config;
		variables.random = createObject("java", "java.security.SecureRandom");
		variables.MessageDigest = createObject("java", "java.security.MessageDigest");
		return this;
	}

	public boolean function available() {
		return isDefined("session") && isStruct(session);
	}

	public struct function current() {
		if (!available() || !structKeyExists(session, "icf") || !isStruct(session.icf)) return {};
		return session.icf;
	}

	public void function establish(required struct user) {
		if (!available()) return;
		try { sessionRotate(); } catch (any e) { /* engines without rotation support fall back to a fresh state */ }
		session["icf"] = {
			"userId": arguments.user.userId,
			"subject": arguments.user.subject,
			"signedInAt": now(),
			"csrfToken": newToken()
		};
	}

	public void function clear() {
		if (!available()) return;
		if (structKeyExists(session, "icf")) structDelete(session, "icf");
		try { sessionInvalidate(); } catch (any e) { /* ignore engines without sessionInvalidate */ }
	}

	public string function csrfToken() {
		var s = current();
		if (structIsEmpty(s)) return "";
		if (!structKeyExists(s, "csrfToken") || !len(s.csrfToken)) {
			session.icf["csrfToken"] = newToken();
		}
		return session.icf.csrfToken;
	}

	public boolean function csrfTokenValid(required string supplied) {
		var expected = csrfToken();
		if (!len(expected) || !len(arguments.supplied)) return false;
		return variables.MessageDigest.isEqual(javaCast("string", arguments.supplied).getBytes("UTF-8"), javaCast("string", expected).getBytes("UTF-8"));
	}

	private string function newToken() {
		// 256 bits from SecureRandom, hex encoded (64 characters).
		var hi = variables.random.nextLong();
		var lo = variables.random.nextLong();
		var hi2 = variables.random.nextLong();
		var lo2 = variables.random.nextLong();
		var Long = createObject("java", "java.lang.Long");
		var hex = "";
		for (var n in [hi, lo, hi2, lo2]) {
			hex &= right("0000000000000000" & Long.toHexString(javaCast("long", n)), 16);
		}
		return lCase(hex);
	}
}
