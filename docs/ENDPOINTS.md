# HTTP endpoints (Phases 1 to 4)

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
| GET | `/api/walks` | anyPermission walk.create, walk.read, walk.edit_owned | My Walks: `{ walks: [WalkHeader + state.dimensions], scope }`. Default `scope=mine` (own non-voided walks in units where the caller holds walk.read or walk.edit_owned); `?scope=all` adds every non-voided walk in walk.read units (never drafts of other districts). Newest `updated_at` first, at most 500. Responses are not included in the list. |
| POST | `/api/walks` + CSRF | permission `walk.create` for body `orgUnitId` | Creates a DRAFT pinned to the current instrument version and the signed-in owner. Body `{ orgUnitId, clientMutationId, versionId?, dimensions?, responses? }`. `clientMutationId` is required (400 `CLIENT_MUTATION_ID_REQUIRED` / `CLIENT_MUTATION_ID_INVALID`); `rowVersion` is not, because there is no prior row. `dimensions` and `responses` may both be omitted (the engine's blank state) but never just one (400 `STATE_CONTAINER_REQUIRED`). 201 `{ walk }`; 200 with `walk.replayed=true` when the mutation id was already committed (WALK-03) -- the replay re-authorizes the recorded walk first, so an id recorded before access changed answers 404 rather than disclosing it; 409 `MUTATION_ID_REUSED` when the id was committed for a different semantic request; 409 `INSTRUMENT_VERSION_CHANGED` when `versionId` is not the current version (a replay is not subject to this: a create committed against an earlier version still replays after a newer one is published); 409 `SCHOOL_ORG_MISMATCH` when the School dimension contradicts the walk's SCHOOL org unit; 404 for an out-of-scope or inactive unit. |
| GET | `/api/walks/{id}` | anyPermission walk.read, walk.edit_owned; then `authorizeWalk(read)` | The walk aggregate: header (`id, orgUnitId, orgUnitName, versionId, versionLabel, status, ownerUserId, ownerDisplayName, isOwner, canEdit, observedAt, createdAt, updatedAt, completedAt, voidedAt, rowVersion, revisionCount`), `state` (`dimensions` by code, `responses` by item key, docs/DATA_CONTRACT.md shape), `states` (`responseStates`, `dimensionStates` derived by the server engine, `persistedResponseStates` as stored). 404 outside scope (existence not disclosed), 403 without any walk capability, 400 for a malformed id. |
| GET | `/api/walks/{id}/instrument` | same as open | `{ version: { versionId, versionLabel }, policies, model }`: the render model of the walk's pinned version (WALK-11), authorized through the walk, not by version id. |
| PUT | `/api/walks/{id}` + CSRF | anyPermission walk.edit_owned; then `authorizeWalk(edit)` (owner in scope) | Autosave of the whole working state: `{ rowVersion, clientMutationId, dimensions, responses, walkId?, versionId?, changedAt? }`. `rowVersion`, `clientMutationId`, and both state containers are required (400 `ROW_VERSION_REQUIRED/INVALID`, `CLIENT_MUTATION_ID_REQUIRED/INVALID`, `STATE_CONTAINER_REQUIRED/INVALID`). Validated against the pinned version (400 `UNKNOWN_ITEM`, `UNKNOWN_DIMENSION`, `INVALID_OPTION`, `INVALID_DIMENSION_VALUE`, `INVALID_DATE`, `INVALID_RESPONSE_VALUE`, `INVALID_EMAIL_DRAFT`, `VALUE_TOO_LONG`, `VERSION_MISMATCH`, `WALK_ID_MISMATCH`, `CLIENT_STATE_NOT_ACCEPTED`; `details.issues[]` lists every problem). JSON primitive types are checked, never coerced: a code, text, or date must arrive as a JSON string, a number as a JSON number, a boolean as a JSON boolean. Response `state` is derived by the server and refused from a client. 409 `STALE_ROW_VERSION` with `details.serverRowVersion` (nothing written), 409 `WALK_VOIDED`, 409 `MUTATION_ID_REUSED`, 409 `SCHOOL_ORG_MISMATCH`, 400 `WALK_COMPLETION_INVALID` (a completed walk must stay complete). 200 `{ walk }` with the committed `rowVersion`, normalized `state`, `states`, `changes[]` (server clearing decisions), `savedAt`, `clientMutationId`, `replayed`. An identical save to a COMPLETED walk is a no-op: no revision, no new `rowVersion`. |
| POST | `/api/walks/{id}/complete` + CSRF | anyPermission walk.edit_owned; then `authorizeWalk(edit)` | `{ rowVersion, clientMutationId }`, both required. Server validates every required, visible item/dimension: 400 `WALK_INCOMPLETE` with `details.errors[] = { kind, key, sectionKey, questionNumber, message }` (the draft stays saved); 409 `STALE_ROW_VERSION`, `WALK_ALREADY_COMPLETED`, `WALK_VOIDED`. Success appends revision `COMPLETE`, sets `COMPLETED`/`completed_at`, audits `WALK_COMPLETED`. |
| POST | `/api/walks/{id}/void` + CSRF | anyPermission walk.edit_owned; then `authorizeWalk(void)` | `{ rowVersion, clientMutationId, reason? }`. `rowVersion` and `clientMutationId` are required (400 `ROW_VERSION_REQUIRED/INVALID`, `CLIENT_MUTATION_ID_REQUIRED/INVALID`); `reason` must be a JSON string (400 `INVALID_VOID_REASON`). Drafts void with the default reason (the My Walks delete action); a COMPLETED walk needs `reason` (400 `VOID_REASON_REQUIRED`). 409 `STALE_ROW_VERSION` (the walk is not voided and its row version does not move), `WALK_ALREADY_VOIDED`, `MUTATION_ID_REUSED`. Audits `WALK_VOIDED`; rows are retained. |
| DELETE | `/api/walks/{id}` + CSRF | anyPermission walk.edit_owned; then `authorizeWalk(void)` | Always 409 `WALK_DELETE_REFUSED` (WALK-08): walks are never physically deleted. Audited. |
| POST | `/api/maintenance/instrument/import` | maintenance | Imports the instrument configuration as a DRAFT (`config/instrument-config.json` or `{ "configFile": "name.json" }`). 201 created / 200 updated; 422 `INSTRUMENT_CONFIG_INVALID`; 409 `INSTRUMENT_VERSION_IMMUTABLE` / `INSTRUMENT_VERSION_IN_USE`. |
| GET | `/api/maintenance/instrument/versions` | maintenance | Same listing as the admin route, for operators without a session. |
| POST | `/api/maintenance/instrument/discard-draft` | maintenance | `{ "versionLabel", "instrumentCode"? }` deletes a DRAFT no walk references. The lookup is scoped by instrument identity as well as by label (labels are unique only within an instrument); `instrumentCode` defaults to `ICFWALK_INSTRUMENT_CODE`. 404 `VERSION_NOT_FOUND` when that instrument has no such label, `INSTRUMENT_NOT_FOUND` for an unknown code. |
| POST | `/api/maintenance/org-units/import` | maintenance | `{ "orgUnits": [ { code, type, name, parentCode, active? } ] }` or `{ "file": "org-units.example.json" }`. Idempotent upsert by code, parents resolved in a second pass. |
| POST | `/api/maintenance/identity/provision-user` | maintenance | `{ subject, displayName?, email? }` creates the application account (201) or returns the existing one (200). |
| POST | `/api/maintenance/identity/assign-role` | maintenance | `{ subject, roleCode, orgUnitCode, includeDescendants?, effectiveStart?, effectiveEnd? }` (ISO-8601 instants). 201 with the assignment id. |
| POST | `/api/maintenance/identity/cleanup-fixtures` | maintenance, tests enabled only | `{ tag }` removes test fixture users/units whose subject/code starts with `tag-`. Never available in production. |
| POST/GET | `/api/maintenance/tests/run` | maintenance, tests enabled only | Runs the CFML test suite; optional `?filter=Name`. |

### Walk mutation and concurrency envelope

`clientMutationId` is **required** on create, save, complete, and void. `rowVersion` is **required**
on save, complete, and void; create does not take one because there is no prior row. Both are
validated before anything is written, so a missing or malformed token is a 400 that leaves the walk
and its row version untouched.

`clientMutationId` is a client-generated GUID recorded with the committed outcome in
`icf.walk_mutation` inside the same transaction. Each record is bound to its **actor**, **action**,
**target**, and a **SHA-256 fingerprint of the canonical semantic request** (migration
`004_mutation_fingerprint.sql`). The fingerprint covers the action, the target (the walk, or the org
unit for a create) and the meaningful body fields -- the whole-state `dimensions`/`responses` for
create and save, the `reason` for a void. It deliberately excludes `rowVersion`, `clientMutationId`,
`changedAt`, and the requested `versionId`: those are not what the request means, and a create
retried after a newer instrument version is published must still match what it committed.

So a retry (network failure, HTTP 5xx, application restart mid-autosave) with the same id **and the
same request** replays the committed result (`walk.replayed = true`, `walk.mutation` = the recorded
result) and writes nothing, while the same id with a different actor, action, target, or semantic
request is 409 `MUTATION_ID_REUSED`. Every replay **re-authorizes the recorded walk** against the
current principal and the current authorization graph before anything about it is returned: a
mutation id recorded before the caller's access changed answers 404, exactly as opening that walk
would, and never discloses it.

Browsers must therefore treat a transport failure or any HTTP 5xx as **ambiguous** -- the mutation
may already have committed -- and retry the same operation with the same `clientMutationId` and the
same body. An operation id is spent only on a definitive success or a definitive, non-retryable 4xx.

`rowVersion` is the SQL Server rowversion of the walk row as a hex token (`0x` + 16 hex digits) and
must match the current row inside the transaction; the walk row is locked (`UPDLOCK`) while the
aggregate is written, so concurrent saves of one walk serialize and the later one is told it is
stale. Rows recorded before migration 004 carry no fingerprint and keep their original
actor/action/target binding.

### Server-authoritative state on a whole-state save

A save carries the whole working state, and the server owns what that means:

- visibility and applicability are derived from the walk's **pinned** instrument, never from the
  browser;
- a value the instrument currently hides is taken from the database: an omitted hidden value is
  **retained** without the browser echoing it, and a value a client sends for a hidden target is
  ignored (`SAVE` still answers 200; the response `state` shows the stored value);
- a value that was hidden and is now visible reappears from the database when the browser omits it;
- a **visible** key the browser omits is a cleared value -- that is how CLEAR works;
- a skippable component marked No clears its rating responses to `NOT_APPLICABLE` and keeps its
  notes, whatever the browser sends; switching back to Yes returns them as `UNANSWERED`;
- a walk at a SCHOOL org unit carries the School dimension value naming that unit. The server fills
  and locks it when the instrument defines a matching value, and refuses a School value (including
  "Other") that contradicts the authorized unit with 409 `SCHOOL_ORG_MISMATCH`;
- `observed_at` follows the Visit Date dimension and falls back to the walk's immutable creation
  instant when no Visit Date is present -- including after one is cleared.

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
