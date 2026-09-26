/**
 * Minimal JSON API client. Same-origin cookies carry the session; state-changing calls send the
 * synchronizer CSRF token from /api/me.
 *
 * Three failure kinds leave here, and the difference between them is the difference between
 * "nothing was sent" and "something may already be committed", so each is its own type:
 *
 *   NetworkError    fetch() itself rejected. No response was produced, so no status line, no
 *                   headers, nothing. This is the only kind that means the server was not reached.
 *   ApiError        the server answered with a status the call cannot use. It carries the status
 *                   and the server's own error code.
 *   ResponseError   the server answered, and the answer could not be read or parsed. The request
 *                   reached the server either way.
 *
 * Callers must not treat "not an ApiError" as a transport failure: a response-shaped failure is not
 * an unreachable server, and a mutation behind one may well have committed.
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

export class NetworkError extends Error {
  constructor(cause) {
    super("The server could not be reached.");
    this.code = "NETWORK_ERROR";
    this.cause = cause;
  }
}

/**
 * The server answered and the answer was unusable: the body could not be read after the headers
 * arrived (`unreadable-body`), or it arrived and was not JSON (`malformed-body`).
 *
 * Deliberately not a NetworkError. A response existed, which means the request was delivered and a
 * mutation it carried may be committed, so the safe response is to keep the operation record and
 * let the person retry it under its own mutation id -- never to treat the state as never-sent.
 */
export class ResponseError extends Error {
  constructor(status, reason, cause) {
    super("The server answered, but the answer could not be read.");
    this.status = status;
    this.code = "INVALID_RESPONSE";
    this.reason = reason;
    this.cause = cause;
  }
}

export function createApi(baseUrl) {
  let csrfToken = "";
  // The user this page was loaded for (/api/me): a refused token is renewed only for them.
  let userId = "";
  async function call(method, path, body, renewed = false) {
    const headers = { Accept: "application/json" };
    if (body !== undefined) headers["Content-Type"] = "application/json";
    if (csrfToken && method !== "GET") headers["X-ICFWalk-CSRF-Token"] = csrfToken;
    let response;
    try {
      response = await fetch(`${baseUrl}${path}`, { method, headers, credentials: "same-origin", body: body === undefined ? undefined : JSON.stringify(body) });
    } catch (e) {
      throw new NetworkError(e);
    }
    // Past this point a response exists. Reading its body can still fail, and that failure is not a
    // transport failure: the status line and the headers already arrived.
    let text;
    try {
      text = await response.text();
    } catch (e) {
      throw new ResponseError(response.status, "unreadable-body", e);
    }
    let json = null;
    if (text) {
      try {
        json = JSON.parse(text);
      } catch (e) {
        // On a failing status the status itself is the more useful fact and the one every 4xx/5xx
        // path is built on, so an unparseable error body is still an ApiError for that status.
        if (!response.ok) throw new ApiError(response.status, null);
        throw new ResponseError(response.status, "malformed-body", e);
      }
    }
    if (!response.ok) {
      const error = new ApiError(response.status, json);
      // P8-01. The server's session can be replaced under an open page -- an application restart,
      // or ICFWALK_SESSION_TIMEOUT_MINUTES without a request -- and the identity adapter then
      // quietly establishes a new one with a new token, so the token this page holds is refused.
      // The router checks the token before it reads the body (P6A-01), so a refused request changed
      // nothing, and sending it once more, unchanged, under the new session's token is safe. Only
      // for the same person: a session that now belongs to someone else never sends this page's work.
      if (!renewed && method !== "GET" && error.status === 403 && error.code === "CSRF_TOKEN_INVALID") {
        await renewCsrfToken(error);
        return call(method, path, body, true);
      }
      throw error;
    }
    return json;
  }

  /** Takes the current session's token from /api/me, or throws why it cannot. */
  async function renewCsrfToken(refused) {
    let me;
    try { me = await call("GET", "/me"); } catch { throw refused; }
    if (!userId || !me || !me.user || !me.csrfToken) throw refused;
    if (me.user.userId !== userId) {
      throw new ApiError(403, { error: {
        code: "SESSION_USER_CHANGED",
        message: "Someone else is now signed in on this browser, so nothing was sent. Your changes are kept on this page; reload to continue as the person now signed in.",
        correlationId: refused.correlationId,
      } });
    }
    csrfToken = me.csrfToken;
  }

  return {
    get: (path) => call("GET", path),
    post: (path, body) => call("POST", path, body ?? {}),
    // A POST with no body bytes at all, for the routes that refuse any body (publish, discard, retire).
    postEmpty: (path) => call("POST", path),
    put: (path, body) => call("PUT", path, body ?? {}),
    del: (path) => call("DELETE", path),
    setCsrfToken(token) { csrfToken = token || ""; },
    setUser(id) { userId = id || ""; },
  };
}
