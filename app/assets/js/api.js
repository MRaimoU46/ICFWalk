/**
 * Minimal JSON API client. Same-origin cookies carry the session; state-changing calls send the
 * synchronizer CSRF token from /api/me. Errors are surfaced as ApiError with the server's code.
 */
export class ApiError extends Error {
  constructor(status, body) {
    const err = body && body.error ? body.error : {};
    super(err.message || `Request failed (${status})`);
    this.status = status;
    this.code = err.code || "REQUEST_FAILED";
    this.correlationId = err.correlationId || null;
    this.details = err.details || null;
  }
}

export function createApi(baseUrl) {
  let csrfToken = "";
  async function call(method, path, body) {
    const headers = { Accept: "application/json" };
    if (body !== undefined) headers["Content-Type"] = "application/json";
    if (csrfToken && method !== "GET") headers["X-ICFWalk-CSRF-Token"] = csrfToken;
    const response = await fetch(`${baseUrl}${path}`, { method, headers, credentials: "same-origin", body: body === undefined ? undefined : JSON.stringify(body) });
    const text = await response.text();
    let json = null;
    try { json = text ? JSON.parse(text) : null; } catch { json = null; }
    if (!response.ok) throw new ApiError(response.status, json);
    return json;
  }
  return {
    get: (path) => call("GET", path),
    post: (path, body) => call("POST", path, body ?? {}),
    setCsrfToken(token) { csrfToken = token || ""; },
  };
}
