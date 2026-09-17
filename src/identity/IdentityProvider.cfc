/**
 * Contract for identity adapters. An adapter turns the incoming request into an asserted identity
 * or reports that no identity is present. It never touches the database or the session; the
 * AuthenticationService provisions users, establishes sessions, and audits.
 *
 * resolve(req) returns a struct:
 *   { "authenticated": boolean, "subject": string, "displayName": string, "email": string,
 *     "claims": struct, "reason": string }
 * where subject is the stable identity-provider identifier stored in icf.app_user.identity_subject
 * (never an email alone), and reason explains an unauthenticated result for logging (no secrets).
 *
 * Implementations:
 *   HeaderIdentityProvider       production SSO seam: identity asserted by a trusted reverse proxy /
 *                                SSO gateway in request headers (environment-driven header names,
 *                                proxy allowlist, optional shared secret).
 *   DevelopmentIdentityProvider  development/test only; enabled solely through configuration that
 *                                cannot be turned on in production.
 * A future OIDC or SAML adapter implements this same interface (redirect flow, token validation)
 * and declares perRequest() = false so the session keeps the identity between requests.
 */
interface {

	public string function name();

	/** True when the identity must be re-asserted on every request (header and stub adapters). */
	public boolean function perRequest();

	public struct function resolve(required struct req);
}
