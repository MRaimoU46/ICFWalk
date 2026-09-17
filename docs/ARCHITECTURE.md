# Architecture notes (Phase 1 baseline)

## Shape

```
HTTP -> app/index.cfm -> Router -> Controller -> Service -> Repository -> SQL Server (icf schema)
                          |            |             |
                          |            |             +-- Validator / Normalizer / SnapshotCompiler
                          |            +-- MaintenanceGuard (Phase 1) / Authorization (Phase 2)
                          +-- Responder (JSON, error mapping) + RequestContext (correlation)
```

Everything is plain CFML script components wired by `src/Bootstrap.cfc` into a singleton container
stored in `application.icf`. There is no framework dependency, and no CFC is reachable directly
over HTTP: `Application.cfc` rejects every request except `index.cfm`.

| Layer | Components |
| --- | --- |
| Request/controller | `http/Router`, `http/Responder`, `http/MaintenanceGuard`, `controllers/*` |
| Service | `instrument/InstrumentImportService` |
| Validation | `instrument/InstrumentConfigValidator` (document rules), `core/Db` typed parameters |
| Data access | `instrument/DefinitionRepository`, `instrument/DefinitionMapper`, `audit/AuditRepository` |
| Cross-cutting | `config/ConfigLoader`, `core/Errors`, `core/Logger`, `core/RequestContext`, `core/CanonicalJson` |
| Views | none yet (Phase 3) |

## Configuration and environments

`ConfigLoader` reads `ICFWALK_*` environment variables, then an optional `.env` file. The
environment defaults to `production`, which disables maintenance endpoints, the test runner, and the
development identity stub. A production configuration that tries to enable the development identity
stub is refused at startup (`ICFWalk.Configuration`), which is the AUTH-02 seam. All open decisions
from `docs/OPEN_DECISIONS.md` are surfaced as configuration seams with their documented safe defaults
(`ICFWALK_PLACEHOLDER_WARNINGS_BLOCK_PUBLISH`, `ICFWALK_HIDDEN_PERIOD_POLICY`,
`ICFWALK_REPORT_SUPPRESSION_THRESHOLD`; outbound email is not configurable and always off).

## Error model

Deliberate failures throw `ICFWalk.*` exception types with a stable `errorcode` and optional JSON
details (`core/Errors`). `Responder` maps types to HTTP statuses (400/401/403/404/409/422/500) and
returns `{ error: { code, message, correlationId, details? } }`. Unexpected exceptions are logged
with their location and returned as a generic 500 with only the correlation id outside development.

## Logging and correlation

`RequestContext` assigns or accepts (`X-Correlation-Id`, restricted character set) a correlation id
per request and echoes it in the response header. `Logger` writes one canonical JSON line per event
to the ColdFusion log `icfwalk` and redacts by key name (passwords, tokens, cookies, narrative
fields such as `text_value`, `notes`, `body`, `subject`, teacher and email fields, prompts and
labels) and truncates any string over 200 characters, so free text never reaches the log even under
an unexpected field name. `AuditRepository` applies the same key denylist before persisting
`details_json`.

## Canonical JSON and snapshots

`core/CanonicalJson` implements `icfwalk-canonical-json/1` (sorted keys, JSON.stringify escaping,
plain decimal numbers, ISO-8601 UTC dates). It is used for the compiled snapshot, checksums, stored
`settings_json`/`conditions_json` documents, log lines, and API responses (so numeric-looking
strings never become numbers, a known `serializeJSON` hazard on Adobe ColdFusion).

`scripts/lib/snapshot.mjs` is the independent Node reference implementation. Shared vectors
(`tests/fixtures/canonical-json-vectors.json`) and the golden checksum
(`tests/golden/instrument-snapshot.golden.json`) prove the CFML and Node implementations are
byte-identical. The compiled snapshot (`icfwalk-instrument-snapshot/1`) contains the instrument,
version provenance, all definitions keyed by logical keys (never SQL GUIDs), the prototype behavior
block, the content-review block, and counts. Because it carries no environment-specific identifiers,
the same document produces the same checksum in every environment.

## Import algorithm

`InstrumentImportService.importConfig` follows `docs/DATA_CONTRACT.md`:

1. Full validation of the authoring document before any database access (structure, unique keys,
   case-collision guard, references, enumerations, supported rule effects, orders, response-set
   integrity, conditions JSON shape and consistency with the flat authoring columns, ISO instants,
   retired SIP text guardrail, placeholder warnings).
2. One transaction: resolve instrument by `code`; lock and resolve the version by
   `(instrument_id, version_label)`; refuse `PUBLISHED`/`RETIRED` (`ICFWalk.Import.PublishedVersion`)
   and DRAFTs referenced by walks (`ICFWalk.Import.VersionInUse`); create the DRAFT when absent.
3. Upsert by unique key with GUID reuse: sections in two passes (content first with parked orders,
   then parent + final order), response sets and options, global dimensions and values (never
   deleted; stale values are kept and reported), rules (target logical IDs resolved to keys), items,
   placements. Version-scoped rows that disappeared from the document are deleted. Display orders
   are "parked" (+1,000,000) before updates so reorders never violate the unique sibling-order
   indexes mid-transaction.
4. Read every definition back from SQL Server, recompile, and compare the definitions checksum with
   the one compiled from the input. Any difference rolls the whole import back
   (`IMPORT_ROUNDTRIP_MISMATCH`).
5. Store the canonical snapshot and SHA-256 on the version and append an audit event.

Fields the supplied schema has no column for are stored in the owning row's `settings_json`
(or, for `response_option` and `dimension_value`, in the parent's `settings_json`; for rules, in an
`authoring` block inside `conditions_json`). `DefinitionMapper` documents the exact layout.

## Recorded source conflict

`icf.instrument_dimension` carries the unique index `UX_instrument_dimension_order (version_id,
display_order)`, but `config/instrument-config.json` authors placement `displayOrder` per section
(Visit information uses 10..80; Target / Taxonomy reuses 10 and 20 for `topic` and `tag`). Per the
source precedence (JSON is the instrument contract, SQL is the persistence authority) neither
supplied file was changed: the snapshot and `settings_json.displayOrder` keep the authored
per-section order, and the `display_order` column receives a derived version-unique value
(document order of sections, then authored order). The validator checks placement order uniqueness
per section. Reporting and rendering must read the authored order from the snapshot.

## Security posture (Phase 1 scope)

- Every SQL statement is parameterized through `core/Db` (`queryExecute` with typed params).
- Maintenance endpoints (seed, versions, discard draft, test runner) require an explicit enable
  flag, a constant-time-compared token header, and a loopback caller unless remote access is
  explicitly allowed; failures respond 404 and are logged, successes are audited. They are not
  cookie-authenticated, so CSRF does not apply to them; Phase 2 adds session auth and CSRF tokens
  for user routes.
- Responses set `Cache-Control: no-store` and `X-Content-Type-Options: nosniff`.
- `configFile` for the import endpoint is restricted to a `.json` file name inside the configured
  instrument directory (no path traversal).

## What Phase 2 builds on

- `Router.add` for new routes and a per-route authorization hook in `Router.dispatch`.
- `ConfigLoader` already validates `ICFWALK_DEV_IDENTITY_ENABLED`; the stub itself, the SSO adapter
  interface, `app_user`/`user_role_scope` resolution with effective dates and descendants, and
  session cookie settings (`this.sessionManagement`, `this.sessionCookie`) are Phase 2 work.
- `AuditRepository.record` accepts the actor user id once identity exists.
