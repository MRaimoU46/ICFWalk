# HTTP endpoints (Phases 1 to 3)

All routes are served through `index.cfm`; with the ColdFusion connector's default configuration the
paths below are reached as `/index.cfm/api/...` (the HTML shell as `/index.cfm/`). Static assets
(`app/assets/css`, `app/assets/js`) are served by the web server directly at `/assets/...`. Responses are JSON (`application/json; charset=utf-8`)
serialized in canonical form. Every response carries `X-Correlation-Id`.

Errors: `{ "error": { "code": "...", "message": "...", "correlationId": "...", "details": {...} } }`.

## Authorization policies

Every route declares one policy in `src/http/Router.cfc`:

| Policy | Meaning |
| --- | --- |
| `public` | No identity required (health only). |
| `maintenance` | Operator token guard: `X-ICFWalk-Maintenance-Token`, explicit enable flag, loopback caller unless remote access is allowed. No session, no CSRF. Denials are 404. |
| `{ authenticated }` | A signed-in user (identity asserted by the configured adapter), with or without roles. |
| `{ permission }` | A signed-in user holding the permission (`instrument.manage` globally, or an org-scoped permission for the unit named by the route). Record-level checks (walk owner/scope) happen in controllers through `AuthorizationService.authorizeWalk`. |
| `{ anyPermission }` | A signed-in user holding at least one of the listed permissions anywhere. Used for shared, non-record resources (the HTML shell and the instrument render model). Denials are audited `ACCESS_DENIED`. |

Status codes on denial: 401 `UNAUTHENTICATED` (no identity), 403 `FORBIDDEN` (capability missing),
403 `CSRF_TOKEN_INVALID`, 404 `NOT_FOUND` (record or unit outside the caller's scope, so existence
is not disclosed).

Session-authenticated state-changing requests (POST/PUT/PATCH/DELETE) must send the session's token
in `X-ICFWalk-CSRF-Token` (from `GET /api/me` or `GET /api/auth/csrf-token`).

Identity headers by adapter (`ICFWALK_SSO_MODE`):

- `header` (production): the SSO gateway sends `X-Auth-Subject` (+ optional `X-Auth-Name`,
  `X-Auth-Email`, `X-Auth-Proxy-Secret`); header names are configurable. Only requests from
  `ICFWALK_SSO_TRUSTED_PROXIES` are believed.
- `development` (dev/test only): `X-ICFWalk-Dev-Subject` (+ `X-ICFWalk-Dev-Name`, `X-ICFWalk-Dev-Email`).

## Routes

| Method | Path | Policy | Purpose |
| --- | --- | --- | --- |
| GET | `/` (i.e. `/index.cfm/`) | anyPermission walk.create, walk.read, walk.edit_owned, report.view, instrument.manage | The single HTML page for My Walks and the walk editor (`src/views/shell.html`). Contains no instrument content or user data; the browser loads `/api/me` and `/api/instrument/current`. Strict `Content-Security-Policy` (scripts and styles from this origin; Google Fonts and the district logo host allowed), `X-Frame-Options: DENY`, `no-store`. Browsers (`Accept: text/html`) receive HTML error pages for 401/403/404 on this route; APIs always answer JSON. |
| GET | `/api/instrument/current` | anyPermission (same list) | `{ version: { versionId, versionLabel, status, checksum, publishedAt, isFallbackDraft }, policies: { hiddenDimensionPolicy }, model, correlationId }`. `model` is the render model (`icfwalk-render-model/1`, see `docs/ARCHITECTURE.md`) of the newest PUBLISHED version, or of the newest DRAFT when `ICFWALK_ALLOW_UNPUBLISHED_INSTRUMENT` permits (never in production). 404 `INSTRUMENT_NOT_AVAILABLE` when no renderable version exists. Read-only; contains no walk data and no SQL identifiers. |
| GET | `/api/health` | public | Liveness/readiness: `{ application, status, checks: { database, schema }, correlationId }`. 503 when the database is unreachable. Non-production adds `environment` and `engine`. |
| GET | `/api/me` | authenticated | `{ user: { userId, displayName, email }, identityProvider, permissions, orgUnits, assignments, csrfToken, correlationId }`. `permissions` maps `walk.create`, `walk.read`, `walk.edit_owned`, `report.view` to arrays of covered org unit ids and `instrument.manage` to a boolean. |
| GET | `/api/auth/csrf-token` | authenticated | `{ csrfToken }`. |
| POST | `/api/auth/sign-out` | authenticated + CSRF | Invalidates the server session; audited. |
| GET | `/api/admin/instrument/versions` | permission `instrument.manage` | Instrument versions with status, checksum, timestamps, walk counts. |
| POST | `/api/maintenance/instrument/import` | maintenance | Imports the instrument configuration as a DRAFT (`config/instrument-config.json` or `{ "configFile": "name.json" }`). 201 created / 200 updated; 422 `INSTRUMENT_CONFIG_INVALID`; 409 `INSTRUMENT_VERSION_IMMUTABLE` / `INSTRUMENT_VERSION_IN_USE`. |
| GET | `/api/maintenance/instrument/versions` | maintenance | Same listing as the admin route, for operators without a session. |
| POST | `/api/maintenance/instrument/discard-draft` | maintenance | `{ "versionLabel" }` deletes a DRAFT no walk references. |
| POST | `/api/maintenance/org-units/import` | maintenance | `{ "orgUnits": [ { code, type, name, parentCode, active? } ] }` or `{ "file": "org-units.example.json" }`. Idempotent upsert by code, parents resolved in a second pass. |
| POST | `/api/maintenance/identity/provision-user` | maintenance | `{ subject, displayName?, email? }` creates the application account (201) or returns the existing one (200). |
| POST | `/api/maintenance/identity/assign-role` | maintenance | `{ subject, roleCode, orgUnitCode, includeDescendants?, effectiveStart?, effectiveEnd? }` (ISO-8601 instants). 201 with the assignment id. |
| POST | `/api/maintenance/identity/cleanup-fixtures` | maintenance, tests enabled only | `{ tag }` removes test fixture users/units whose subject/code starts with `tag-`. Never available in production. |
| POST/GET | `/api/maintenance/tests/run` | maintenance, tests enabled only | Runs the CFML test suite; optional `?filter=Name`. |

Import result shape (instrument import):

```json
{
  "instrumentId": "GUID", "versionId": "GUID", "instrumentCode": "ICFWALK",
  "versionLabel": "2026-09-17 aligned prototype", "status": "DRAFT", "created": true,
  "checksum": "sha256 of the stored canonical snapshot",
  "definitionsChecksum": "sha256 of the definitions block",
  "snapshotFormat": "icfwalk-instrument-snapshot/1",
  "counts": { "sections": 23, "items": 144, "responseSets": 29, "responseOptions": 138, "rules": 12, "dimensions": 10, "dimensionValues": 95, "instrumentDimensions": 10, "placeholders": 17 },
  "warnings": [ { "code": "PLACEHOLDER_CONTENT", "message": "...", "path": "..." } ],
  "placeholders": [ { "itemKey": "prek_k_q1", "sectionKey": "prek_k_classroom", "sourceLocation": "PREK_K_ITEMS[0]", "reviewStatus": "Placeholder in source" } ],
  "elapsedMs": 1234, "sourcePath": "instrument-config.json"
}
```
