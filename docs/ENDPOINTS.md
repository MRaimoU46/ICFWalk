# HTTP endpoints (Phase 1)

All routes are served through `index.cfm`; with the ColdFusion connector's default configuration the
paths below are reached as `/index.cfm/api/...`. Responses are JSON (`application/json; charset=utf-8`)
serialized in canonical form. Every response carries `X-Correlation-Id`.

Errors: `{ "error": { "code": "...", "message": "...", "correlationId": "...", "details": {...} } }`.

| Method | Path | Auth | Purpose |
| --- | --- | --- | --- |
| GET | `/api/health` | none | Liveness/readiness: `{ application, status: ok/degraded, checks: { database, schema }, correlationId }`. 503 when the database is unreachable. Non-production adds `environment` and `engine`. |
| POST | `/api/maintenance/instrument/import` | maintenance token | Imports the instrument configuration (`config/instrument-config.json` by default, or `{ "configFile": "name.json" }` inside the same directory) as a DRAFT. 201 when created, 200 when an existing DRAFT was updated. Body: import result (ids, checksum, counts, warnings, placeholders). 422 `INSTRUMENT_CONFIG_INVALID` with `details.issues[]`; 409 `INSTRUMENT_VERSION_IMMUTABLE` / `INSTRUMENT_VERSION_IN_USE`. |
| GET | `/api/maintenance/instrument/versions` | maintenance token | Lists instrument versions with status, checksum, timestamps, and walk counts. |
| POST | `/api/maintenance/instrument/discard-draft` | maintenance token | `{ "versionLabel": "..." }` deletes a DRAFT no walk references. Published/retired versions are refused (409). |
| POST/GET | `/api/maintenance/tests/run` | maintenance token + `ICFWALK_TESTS_ENABLED` | Runs the CFML test suite; optional `?filter=Name`. Never available in production. |

Maintenance token header: `X-ICFWalk-Maintenance-Token`. Requests without a valid token, from a
non-loopback address (unless `ICFWALK_MAINTENANCE_ALLOW_REMOTE=true`), or while maintenance is
disabled receive 404.

Import result shape:

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
