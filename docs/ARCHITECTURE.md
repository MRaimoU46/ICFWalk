# Architecture notes (Phases 1 to 3)

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
| Instrument engine (Phase 3) | `instrument/SnapshotService`, `instrument/RenderModelBuilder`, `instrument/VisibilityEngine` |
| Views | `views/shell.html` served by `controllers/ShellController`; browser modules in `app/assets/js` (`renderer.js`, `rules.js`, `walk-state.js`, `walk-store.js`, `app.js`) |

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

## Identity, roles, and organizational scope (Phase 2)

```
request -> IdentityProvider.resolve(req) -> UserRepository (JIT provision) -> SessionService
        -> AuthorizationService.principalFor(user) -> Router policy check -> controller
                                                    -> authorizeWalk / requirePermission (record level)
```

**Identity adapters** implement `identity/IdentityProvider` (`resolve(req)` returns an asserted
subject or an anonymous result with a reason). `HeaderIdentityProvider` is the production SSO seam:
the district's SSO gateway/reverse proxy authenticates the user and asserts the subject, name, and
email in headers whose names come from `ICFWALK_SSO_*_HEADER`. Only source addresses in
`ICFWALK_SSO_TRUSTED_PROXIES` (IPv4 or CIDR) are believed, an optional shared secret header can be
required, and requests carrying identity headers from untrusted addresses are logged as spoofing
attempts and treated as anonymous. No identity provider product is assumed; an OIDC or SAML adapter
would implement the same interface with `perRequest() = false` so the session retains the identity
between requests. `DevelopmentIdentityProvider` reads `X-ICFWalk-Dev-Subject` and can only be
constructed when `ICFWALK_DEV_IDENTITY_ENABLED=true` outside production; `ConfigLoader` refuses that
setting in production, `IdentityProviderFactory` refuses the mode without it, and the provider's
constructor refuses again, so it cannot be enabled by accident (AUTH-02).

**Users** are matched by `app_user.identity_subject` only. First sign-in provisions the row
(`ICFWALK_AUTO_PROVISION_USERS`, default true; users still have no access until a role assignment
exists). Inactive users are rejected. Sign-in rotates the session id, stores only user id, subject,
sign-in time, and a 256-bit CSRF token, and is audited (`USER_PROVISIONED`, `USER_SIGNED_IN`,
`USER_SIGNED_OUT`). Cookies are HttpOnly, SameSite=Lax, and Secure (the Secure flag cannot be
disabled in production).

**Authorization** (`authorization/AuthorizationService`) rebuilds the principal on every request from
`user_role_scope` joined to `app_role` and `org_unit`, filtered in SQL by the database clock
(`effective_start <= now < effective_end`), active role, and active unit. `include_descendants`
expands to every active descendant of the assigned unit through the in-memory active tree. The five
schema role flags map to permissions `walk.create`, `walk.read`, `walk.edit_owned`, `report.view`
(org-scoped) and `instrument.manage` (global, never grants walks or reports). `requirePermission`
distinguishes a missing capability (403) from an out-of-scope or unknown unit (404) so existence is
not disclosed; malformed identifiers are 400. `authorizeWalk(principal, walkId, action)` re-resolves
the walk's org unit and owner from the database: `read` needs `walk.read` in the walk's unit (or
ownership with `walk.edit_owned`), `edit`/`void` need ownership plus `walk.edit_owned`. Report-only
roles therefore never reach individual walk details. Every denial is audited as `ACCESS_DENIED` with
permission, unit, and record id only.

**Router policies**: every route declares `public`, `maintenance`, `{ authenticated }`, or
`{ permission }`; there is no permissive default. State-changing session routes require the
synchronizer CSRF token header. Maintenance routes (seed, org-unit import, user provisioning, role
assignment, test runner, fixture cleanup) remain token-guarded and never use the session.

**Bootstrap of a deployment**: import org units (`config/org-units.example.json` as a template),
provision the first administrator, assign `MASTER_INSTRUMENT_ADMIN`, then assign walk/report roles
per district or school, all through the maintenance endpoints (documented in `docs/LOCAL_SETUP.md`).

## Instrument engine and visual shell (Phase 3)

```
instrument_version.compiled_snapshot_json
   -> SnapshotService (current PUBLISHED, or DRAFT fallback outside production; cached by checksum)
   -> RenderModelBuilder.build(snapshot)  -> render model (icfwalk-render-model/1)
   -> GET /api/instrument/current          -> browser renderer.js (DOM) + rules.js (visibility)
                                              VisibilityEngine.cfc = server twin of rules.js
```

**Render model.** `RenderModelBuilder` turns the flat snapshot into a section tree (children by
`parentSectionKey` and `displayOrder`) whose nodes carry only derived facts, never named content:
placements (dimension inputs with label, placeholder, data type, values, option filter), items
with a `layout` derived from item type and response set (`display-heading`, `display-guidance`,
`question` = choice with definitions, `choice-row` = choice without definitions such as yes/no,
`applicability`, `notes`, `text`, `email-draft`), question numbers (scored questions are numbered;
sections without scored questions number every question, which reproduces the prototype), and
section presentation (`card` for top-level sections that hold placements or are conditional,
`accordion` for the other top-level parts, `component` for nested sections with
`settings.partNumber`, `block` otherwise; a block shows its heading only when it has look-fors
or a color). Skippable components are recognised from the rules: the item that is the ITEM-typed
source of SHOW rules on sibling items is the applicability item and the targets are the rated
items. The 17 placeholder items are flagged (`isPlaceholder`) but displayed as the prototype does.
Unsupported rule effects, operators, option filters, and item types are refused at build time.

**Visibility engine.** `VisibilityEngine.cfc` and `app/assets/js/rules.js` implement the same
semantics and are proven equivalent by `tests/fixtures/visibility-vectors.json` (32 states,
asserted by both `VisibilityEngineTest` and `tests/node/visibility.test.mjs`). A target with SHOW
rules is visible when any rule is true; DIMENSION conditions compare the selected value's label or
code, ITEM conditions the stored option code; operators EQUALS/NOT_EQUALS/IN/NOT_IN with AND/OR.
Response states: HIDDEN (section or dimension-driven rule), NOT_APPLICABLE (hidden by a
sibling-item rule, i.e. the applicability answer), ANSWERED (valid option code or non-empty text),
UNANSWERED; nothing is ever coerced to zero. Option filters come from placement settings
(`schoolTypeToGradeBand` = grade values whose `valueGroup` equals the selected school's group; Other
or no school = every grade). `normalize()` applies the prototype's clearing: a filtered selection
that is no longer allowed is cleared; NOT_APPLICABLE responses are cleared (ratings when a
component is set to No; notes are never rated and remain); dimension values hidden by rules are
retained unless `ICFWALK_HIDDEN_PERIOD_POLICY=CLEAR` (docs/OPEN_DECISIONS.md, exposed to the
browser as `policies.hiddenDimensionPolicy`). The working state shape is the Phase 4 autosave
payload from `docs/DATA_CONTRACT.md` (`dimensions` by code, `responses` by item key).

**Browser shell.** `GET /` serves `src/views/shell.html` (no instrument content, no user data,
strict CSP) and the ES modules in `app/assets/js`. `renderer.js` builds the editor DOM once from
the model and keeps it in sync on every edit (visibility, filtered options, pressed pills, rating
counts, live announcements). `walk-store.js` is the persistence boundary: Phase 3 shipped an
in-memory `SessionWalkStore`; Phase 4 replaced it with `ApiWalkStore` (same interface plus
`instrument` and `complete`) and the 700 ms debounced autosave (see the Phase 4 section). My Walks card
composition (title = grade · content, meta = school · date · relative time) is presentation
configuration by dimension code in `app.js` (`LIST_CARD`), not instrument content.

## Walk persistence and autosave (Phase 4)

```
browser app.js (700 ms debounce, mutation ids, rowVersion)
   -> ApiWalkStore (walk-store.js) -> /api/walks routes (Router policy: walk capability + CSRF)
   -> WalkController -> WalkService
        AuthorizationService.authorizeWalk (scope + owner + status re-read from the database)
        WalkPayloadValidator (keys, codes, values against the pinned version's render model)
        VisibilityEngine.normalize + evaluateVisibility (server clearing and states)
        WalkRepository (one transaction: UPDLOCK on icf.walk, diff-writes, revision, mutation log)
        AuditRepository (lifecycle and security facts only)
```

**Aggregate and transaction.** A walk is `icf.walk` plus one `walk_dimension_value` row per
dimension with a value and one `walk_response` row per response-capable item of the pinned
version (state `UNANSWERED` when empty, so state counts are reportable). `PUT /api/walks/{id}`
carries the whole working state; the server validates it (`WalkPayloadValidator`), re-normalizes it
with the same engine the browser uses, then, inside one transaction, locks the walk row, compares the
client's `rowVersion` token with the row's `rowversion` (409 `STALE_ROW_VERSION`, nothing written,
audited `WALK_SAVE_CONFLICT`), writes only the rows whose value or state changed, bumps
`updated_at`/`rowversion`, and records the client mutation id with the committed outcome
(`icf.walk_mutation`, migration `003`). A retry with the same id replays that outcome; the id is
bound to its walk, actor, and action. Reads never trust request fields for scope: org unit, owner,
version, and status always come from the row.

**Validation (fail closed).** Dimension codes must be placements of the pinned version; list codes
resolve to `dimension_value` GUIDs of that dimension, `otherText` is accepted only on `allowOther`
dimensions and stored only with the Other value selected (documented mapping: `selected_value_id`
= Other, `text_value` = the text); TEXT/DATE/NUMBER/BOOLEAN values must fit the data type
(`YYYY-MM-DD` calendar dates, 1000-character texts). Item keys must be active items of the version;
display items accept nothing; choice items accept only a `storedCode` of their own response set
(resolved to the option GUID of that set, so an option that exists in another set or version is
refused, SAVE-07); text items accept `textValue` only (20,000 characters); the email-draft item
accepts only the application schema of `docs/DATA_CONTRACT.md` and is stored as canonical JSON.
All comparisons of codes use exact string comparison (`compare`), never CFML `==`, which treats
`"yes"` and `"1"` (and `"1"` and `"1.0"`) as equal; the shared vectors carry cases for this.

**States and clearing.** The engine's `normalize` runs server-side on every save: a grade outside
the selected school's band is cleared (`DIMENSION_CLEARED/OPTION_FILTER`), and setting a skippable
component to No clears its ratings (`RESPONSE_CLEARED/NOT_APPLICABLE`) in the same transaction as
the applicability answer; notes are never rated and are retained. Persisted response states follow
`evaluateVisibility`: `HIDDEN` rows keep their value (conditional classroom sections reappear with
their answers), `NOT_APPLICABLE` rows have no option, Period hidden outside grades 6–12 keeps its
row (`RETAIN_HIDDEN`, configurable). `observed_at` follows the visit-date dimension.

**Lifecycle.** `POST .../complete` validates every required, currently visible item and placement
(400 `WALK_INCOMPLETE` with field-specific errors; the draft is untouched), appends revision
`COMPLETE` (the pre-completion snapshot), sets `COMPLETED`/`completed_at`, audits `WALK_COMPLETED`.
Owners may still edit a completed walk: each such save must leave it complete (400
`WALK_COMPLETION_INVALID`) and appends revision `POST_COMPLETION_EDIT`; drafts append no revisions
(autosave would create thousands). `POST .../void` sets `VOIDED` with a reason (required for
completed walks; drafts use the default reason from the My Walks delete action) and keeps every row;
`DELETE` is always refused (409 `WALK_DELETE_REFUSED`). Voided walks leave the list, stay readable
by id, and reject edits. Audit events: `WALK_CREATED`, `WALK_COMPLETED`, `WALK_COMPLETION_REJECTED`,
`WALK_POST_COMPLETION_EDIT`, `WALK_VOIDED`, `WALK_DELETE_REFUSED`, `WALK_SAVE_CONFLICT`,
`WALK_SAVE_REJECTED` (tampering: code and paths), `WALK_MUTATION_REPLAYED`, `WALK_MUTATION_ID_REUSED`,
plus `ACCESS_DENIED` from the authorization layer. No narrative value is ever written to the audit
or mutation logs.

**Browser.** `ApiWalkStore` implements the Phase 3 `WalkStore` interface over the routes. `app.js`
debounces edits 700 ms, coalesces edits made mid-flight into the next save, and shows `Unsaved
changes` / `Saving...` / `All changes saved` / a specific failure with a Retry action (input stays on
screen). Every ambiguity-capable mutation owns an immutable operation record (`docs/DATA_CONTRACT.md`,
"Pending mutation operations in the browser") keyed by action and target, carrying its
`clientMutationId`, its row version, and its frozen semantic body. A record whose request has been
sent is never replaced by a newer payload: an edit made during an in-flight save queues behind it, and
a lost answer retries the original request before the queued state goes out under a new id. Unresolved
operations are rendered from that registry into an unfinished-operations bar that lives outside both
views, so a retry is still reachable after the list re-renders or the walk is reloaded from the
server. On 409 `STALE_ROW_VERSION` it stops autosaving, loads the server record, and shows an
`alertdialog` listing only the fields this session changed since it last loaded or saved (its unsent
edits) against the saved values; "Use the saved version" discards them, "Keep my edits and save"
applies them on top of the server record and saves with the new row version. Completion errors are
rendered as an `alert` summary with links that expand the section and focus the control, and each
field is marked `aria-invalid` with a description. Non-owners get a read-only editor; completed walks
show a banner; a completed walk's delete action asks for a void reason. Walks pinned to an older
version load their render model through `GET /api/walks/{id}/instrument` and cache it per version.

## Summary export and teacher email draft (Phase 5)

```
browser  app.js #export-btn -> GET /api/walks/{id}/summary            (flush to the server, then download)
         renderer.js email-draft slot -> email-composer.js -> setResponse + commit -> PUT /api/walks/{id}
server   WalkController.summary -> WalkService.summary
                                   -> AuthorizationService.authorizeWalk(read)
                                   -> WalkRepository (header, dimension values, responses)
                                   -> SnapshotService.renderModelFor(pinned versionId)
                                   -> VisibilityEngine.evaluateVisibility
                                   -> WalkSummaryFormatter.summaryText / fileName
                                   -> AuditRepository (WALK_SUMMARY_EXPORTED: ids and a byte count)
shared   src/walks/WalkSummaryFormatter.cfc  ==  app/assets/js/summary.js
         proven byte-identical by tests/fixtures/summary-vectors.json
```

**One formatting contract, implemented twice.** The export is the same problem the visibility engine
already had: the browser must show what the server would produce, and neither may drift. It is
solved the same way. Both formatters are pure functions of `(model, state, evaluation)` with the
same function names and the same output, and `tests/fixtures/summary-vectors.json` holds golden
expectations that both suites compare byte for byte (`compare()` in CFML, never `==`). Nothing else
formats a summary: the browser's fallback export, the email draft, and the server's download all
come from these two files.

The browser's fallback is narrow on purpose. `#export-btn` flushes the editor state to the server
and downloads `GET /api/walks/{id}/summary`; it uses the browser formatter **only** when that flush
failed with an actual `NetworkError` -- the one failure that means no response was produced and the
server was not reached. A 4xx, a 5xx, a conflict, and any answer the browser could not use all block
the export instead, because in every one of them the request reached the server and a
browser-generated file could describe a state the server already holds (`docs/DATA_CONTRACT.md`,
"Pending mutation operations in the browser").

The vectors are not self-certifying. `scripts/generate-summary-vectors.mjs` produces them from the
**served** render model with the JavaScript formatter, and `scripts/prototype-summary-oracle.mjs`
then replays every vector through `source/current-prototype.html` itself and classifies each
difference. Only the deviations recorded in `BUILD_STATUS.md` (hidden values excluded, the
content-area heading, the doubled trailing colon, yes/no capitalization) are allowed; anything else
fails. The generated email drafts match the prototype exactly, with no deviation at all.

**Nothing new is stored.** The summary is derived on demand and never cached; the file name is
derived; the email draft is one ordinary `walk_response.text_value` of the existing
`EMAIL_DRAFT_JSON` item. Phase 5 adds no table, column, or migration.

**Exporting is a read.** The route carries the same policy and the same `authorizeWalk(read)` as
opening a walk, takes nothing from the request but the walk id, writes nothing, and moves no row
version. A VOIDED walk still exports, because Phase 4 keeps it readable by id.

**The draft rides the existing mutation path.** The composer writes the whole document into the
walk's `email_workflow` response and commits through the renderer, so autosave, the row-version
compare, mutation idempotency, replay coherence, and the conflict panel all apply unchanged. The
browser serializes its keys in the order the server canonicalizes to, so a reload compares equal
and no phantom unsent edit appears.

**Nothing sends mail, and nothing may.** No SMTP configuration, no `cfmail`, no mail library, no
endpoint that accepts a recipient. The only outbound action is a `mailto:` URL the browser hands to
the person's own mail client, with every value percent-encoded.
`tests/node/no-mail.test.mjs` is the standing gate on all of that.

## What Phase 6 builds on

- `WalkSummaryFormatter` / `summary.js` are the one place walk content becomes prose. Anything that
  has to render or export a walk (an administration preview, a report) should call them rather than
  format again; the vectors are what keeps that promise enforceable.
- `GET /api/walks/{id}/summary` is the pattern for any future read-only, downloadable artifact:
  `authorizeWalk(read)`, the walk's pinned version, a sanitized `Content-Disposition`, `no-store`,
  `nosniff`, and an audit event carrying identifiers and counts only.
- The composer shows how a composite control lives inside the renderer: it is built once into the
  item's slot, syncs from the walk state on every refresh, writes through `setResponse` + `commit`,
  and is disabled by `applyEditability` like every other control.
- Publishing (Phase 6) must keep `behavior.export.fileNamePattern` and the `email_workflow` item's
  `settings.selectableParts` intact, because both formatters are driven by them. Adding an
  `exportLabel` item setting and a `settings.titleTemplate` would retire the two presentation maps
  that remain (`PART4_LABELS` and the content-area heading decision).
- The email draft is non-reportable by contract: Phase 7 must exclude `email_workflow` from every
  report and extract.

## What Phase 5 built on (Phase 4 hand-off)

- `WalkService.open` returns the normalized state plus derived states; the summary/export
  formatter was built once in CFML and once in JavaScript over the same render model + state,
  like the visibility engine, and proven equal by vectors.
- The email-draft item (`EMAIL_DRAFT_JSON`) already persisted the `docs/DATA_CONTRACT.md` document
  through the ordinary save path (validated, canonical JSON in `text_value`, non-reportable).
- `renderer.js` exposed the `email-draft` layout slot; `app.js` `#export-btn` was the hidden hook for
  the text export.

## What Phase 4 built on (Phase 3 hand-off)

- `SnapshotService.renderModelFor(versionId)` and `snapshotFor(versionId)` render a walk against
  its pinned version; `currentVersion()` is the version new walks are created against.
- `VisibilityEngine.evaluateVisibility(model, state)` and `normalize(model, state, policies)` give
  the server the same HIDDEN / NOT_APPLICABLE / clearing decisions the browser makes, for the
  autosave transaction, completion validation, and reports.
- `WalkStore` (browser) is the seam for `/api/walks` endpoints; `app.js` already carries the
  org-unit selection for creation (`walk.create` scope from `/api/me`) and the save-status states.

## What Phase 3 built on (Phase 2 hand-off)

- `AuthorizationService.visibleOrgUnitIds(principal, "walk.read")` and `authorizeWalk` are the
  scope primitives for My Walks and the walk editor; `req.principal` is available in every
  authenticated controller.
- `Router.add(method, pattern, controller, action, policy)` with `{ "permission": "walk.create",
  "orgUnitBody": "orgUnitId" }` authorizes creation against the unit named in the JSON body.
- The compiled snapshot on `instrument_version` is the rendering contract; `DefinitionRepository`
  resolves keys to GUIDs for persistence.
