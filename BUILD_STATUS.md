# ICFWalk build status

Scope of this record: **Phase 0 (baseline), Phase 1 (application and database foundation),
Phase 2 (identity, roles, authorization, organizational scope), Phase 3 (instrument engine and
visual shell), Phase 4 (walk persistence, autosave, completion, concurrency, audit), Phase 5
(summary export and teacher email draft), the Phase 6 publish foundation (ADM-03/04/05 at the
service and endpoint level), and Phase 7 (aggregate reporting, RPT-01..07)** from
`docs/IMPLEMENTATION_PLAN.md`. The rest of Phase 6 -- ADM-02 preview, ADM-06 clone-and-compare,
ADM-07 retirement, ADM-08 placeholder review, and all administration UI -- has **not** been started.

Target platform: Adobe ColdFusion 2023 + Microsoft SQL Server 2016+.

**Current state: Phase 7 aggregate reporting candidate, awaiting independent audit.** Branch
`claude/icfwalk-phase-6-admin-publish`, on top of the Phase 6 commit
`a219d9e0987b85b1a0b587fd62effa4e0ad1ffde`, which the project owner identified as the independently
verified and frozen Phase 0-6 baseline for this phase. Phase 7 is **not** frozen and **not**
accepted; see the Phase 7 section at the end.

Read this file from the end. Sections appear in the order they were delivered: Phase 0-4, five
Phase 0-4 correction sessions, the Phase 5 sections and their corrections, the Phase 6 foundation,
the Phase 6 publish-foundation correction, its second, third, fourth and fifth corrections, and
finally **Phase 7**, which is the current state of the build.
Earlier sections are kept as delivered and are **not** rewritten when a later section supersedes
them; where they disagree, the later section is the record.

## Phase 0 baseline

Supplied artifacts verified on 2026-09-17 (commit `3f0eb8e` of the handoff):

| Artifact | SHA-256 | Status |
| --- | --- | --- |
| `source/current-prototype.html` | `239531267fa1dfaedaf4e1a8842156bc90db425893781330470312e3c34a1361` | matches JSON `source.sha256` |
| `config/instrument-config.json` | `fcbd124346936d4e0a8aa65f44845d2e26d8f1a6c806e2e4656b92e1ddbf2b7c` | unchanged |
| `database/001_schema.sql` | `c6c16b6cdc1ae10760e43f0bcbf32a4fd84eed51166f1487fb6b7484532d1374` | unchanged |
| `database/002_alignment_patch.sql` | `5b22195026b7fc52933cf74e88912a9931ab6a36226b02e82589b395031d5e18` | unchanged |
| `config/ICFWalk_Instrument_Configuration_Aligned.xlsx` | `97f5e0e6def916ac4a4d646b38a15e029106c018a193954f87d4cb05e2d1efb9` | unchanged |
| `reference/legacy-configuration-workbook.xlsx` | `16212bdbafa9e2429940da89380ef818d9c54c80a5e36ae67b58f8502692407f` | unchanged, never read as a build source |
| `scripts/validate-handoff.mjs` | was `5689ef8b…bd01`, now `65b80c233060b62438f3092388618d7cfe8db7f52eee934aeca42edbb74914bf` | patched (defect below); manifest entry refreshed |

Validator result: `node scripts/validate-handoff.mjs` → `{"ok": true, "checks": 51, "errors": 0}`.
Counts confirmed: 23 sections, 144 items, 29 response sets, 138 options, 12 rules, 10 dimensions,
95 dimension values, 10 placements, 17 placeholders (3 PreK–K, 3 MAC/PREP, 3 Ignite, 3 AVID,
5 content-area). No retired SIP content. Part 3 title is `Part 3 · Conditions for Learning`.

**Phase 0 defect fixed:** the supplied validator's manifest completeness check walked `.git/` and
would have failed for every file the build adds. It now ignores `.git/`, `node_modules/`, `.runtime/`
and reports build files as informational; `--strict-package` restores the original strict behavior.
`scripts/refresh-manifest.mjs` refreshes hashes for existing manifest entries only (never adds
files). The validator's own manifest entry was updated this way.

**Reference computed in Phase 0/1:** compiled-snapshot golden (`tests/golden/instrument-snapshot.golden.json`):
snapshot checksum `c125b4ae28524884865956326ecdaaded00019f16635ef13c9830dcf4f84dda9`,
definitions checksum `7df87ad01b10027fe19b8b559bc2c1cd10f33411dba0070aab35b8e4d6dfcb5f`, 218,124 canonical bytes.

Phase 0 gate: **met** (validation passes, no retired SIP content, platform confirmed).

## Phase 1 work completed

1. **CFML application scaffold** (`app/`, `src/`): single-entry front controller, router,
   JSON responder with a typed error model, environment-driven configuration with fail-closed
   production defaults, structured redacting logger, request correlation ids, typed parameterized
   data-access helper, audit repository, health endpoint, maintenance endpoints guarded by an
   explicit enable flag + constant-time token + loopback restriction.
2. **Canonical JSON and compiled snapshot** in CFML and an independent Node reference
   implementation, proven byte-identical by shared vectors and the golden checksum.
3. **Instrument configuration validator** (structure, unique keys, references, enumerations,
   supported effects, orders, response-set integrity, rule JSON shape/consistency, retired-content
   guardrail, placeholder warnings).
4. **JSON import service** per `docs/DATA_CONTRACT.md`: logical-ID → GUID mapping, one
   transaction, version lock, refusal of PUBLISHED/RETIRED versions and DRAFTs with walks,
   idempotent upsert with GUID reuse, two-pass sections, display-order parking, stale-row removal,
   database round-trip verification (recompile persisted rows and compare checksums), snapshot +
   SHA-256 storage, audit events, DRAFT discard.
5. **Database scripts applied** (`001` then `002`) to real SQL Server 2022 through
   `scripts/db/apply-schema.mjs`; DB-01..03 automated.
6. **Seed of the current aligned DRAFT** (`2026-09-17 aligned prototype`) through the maintenance
   endpoint (`scripts/seed-instrument.mjs`), verified directly in SQL Server
   (`docs/evidence/phase1-seed-db-verification.txt`).
7. **Test harness**: dependency-free CFML runner + 6 specs (42 cases), Node harness (`npm test`,
   21 cases) covering PKG-01..05, DB-01..03, canonical/snapshot parity, schema/DAO contract,
   endpoint behavior, and the CFML suite driven through the running app.
8. **Local runtime tooling**: Docker SQL Server helper, Lucee/Jetty verification runtime, `.env.example`.
9. **Documentation**: `docs/LOCAL_SETUP.md`, `docs/ARCHITECTURE.md`, `docs/ENDPOINTS.md`,
   `docs/ACCEPTANCE_TRACKING.md`.

## Files created or changed

Changed (supplied): `scripts/validate-handoff.mjs`, `manifest.json` (validator entry only).

Created:

```
.env.example  .gitignore  package.json  package-lock.json  BUILD_STATUS.md
app/Application.cfc  app/index.cfm
src/Bootstrap.cfc
src/config/ConfigLoader.cfc
src/core/CanonicalJson.cfc  src/core/Db.cfc  src/core/Errors.cfc  src/core/Logger.cfc  src/core/RequestContext.cfc
src/http/Router.cfc  src/http/Responder.cfc  src/http/MaintenanceGuard.cfc
src/controllers/HealthController.cfc  src/controllers/MaintenanceController.cfc
src/instrument/ConfigNormalizer.cfc  src/instrument/InstrumentConfigValidator.cfc  src/instrument/SnapshotCompiler.cfc
src/instrument/DefinitionMapper.cfc  src/instrument/DefinitionRepository.cfc  src/instrument/InstrumentImportService.cfc
src/audit/AuditRepository.cfc
scripts/refresh-manifest.mjs  scripts/compile-snapshot.mjs  scripts/lib/snapshot.mjs  scripts/db/apply-schema.mjs  scripts/seed-instrument.mjs
tests/cfml/TestRunner.cfc  tests/cfml/BaseSpec.cfc  tests/cfml/support/StubConfigLoader.cfc
tests/cfml/specs/{CanonicalJsonTest,ConfigLoaderTest,LoggerTest,InstrumentConfigValidatorTest,SnapshotCompilerTest,InstrumentImportServiceTest}.cfc
tests/node/{helpers.mjs,package.test.mjs,canonical-json.test.mjs,snapshot.test.mjs,schema-contract.test.mjs,db-scripts.test.mjs,cfml-suite.test.mjs}
tests/fixtures/canonical-json-vectors.json  tests/golden/instrument-snapshot.golden.json
tools/runtime/{mssql-up.sh,mssql-down.sh,lucee-up.sh,lucee-down.sh,web.xml}
docs/{LOCAL_SETUP,ARCHITECTURE,ENDPOINTS,ACCEPTANCE_TRACKING}.md
docs/evidence/{phase1-npm-test.txt,phase1-seed-db-verification.txt}
```

## Tests and validators executed

Environment: Ubuntu 24.04 container, Node 22.22, Java 21, Docker (`mcr.microsoft.com/mssql/server:2022-latest`,
SQL Server 16.0.4295.3 Developer), Lucee 6.2.8.20 light on Jetty 9.4.58 with mssql-jdbc 12.10.2.

| Command | Result |
| --- | --- |
| `node scripts/validate-handoff.mjs` | ok, 51 checks, 0 errors |
| `node scripts/validate-handoff.mjs --strict-package` | 62 build files reported as unlisted (expected; strict mode is for pristine packages) |
| `node scripts/db/apply-schema.mjs` (icfwalk_dev) | 001: 20 tables created; 002: definition column available |
| `npm test` (`docs/evidence/phase1-npm-test.txt`) | 21/21 pass: package (5), canonical JSON (3), snapshot (3), schema contract (4), DB scripts (1 = DB-01/02/03), app endpoints + CFML suite + seed (5) |
| CFML suite via `/api/maintenance/tests/run` | 42 passed, 0 failed, 0 skipped (CanonicalJsonTest 6, ConfigLoaderTest 8, LoggerTest 3, InstrumentConfigValidatorTest 12, SnapshotCompilerTest 3, InstrumentImportServiceTest 11) |
| `node scripts/seed-instrument.mjs` | DRAFT `2026-09-17 aligned prototype`, checksum equals golden, 17 placeholders, idempotent re-run (`created: false`) |
| Direct SQL verification | version DRAFT with stored snapshot/checksum; 23/144/29/138/12/10/95/10 rows; 0 walks, 0 users; audit events present; option definitions match |
| Log inspection | JSON lines with correlation ids; no prompt/narrative text present |

## Acceptance-test IDs satisfied

PASS: PKG-01, PKG-02, PKG-03, PKG-04, PKG-05, DB-01, DB-02, DB-03, DB-04, DB-05, DB-06, DB-07, DB-08, DB-09.
Partial/seam-level: AUTH-02 (configuration refusal), ADM-01 (validation summary at service level), SEC-01, SEC-05, SEC-07 (local clean install).
Details and later-phase items: `docs/ACCEPTANCE_TRACKING.md`.

## Assumptions and recorded decisions

1. **Source conflict recorded (JSON vs SQL):** `UX_instrument_dimension_order` is unique per
   `(version_id, display_order)` but the JSON authors placement `displayOrder` per section
   (`topic`/`tag` reuse 10/20). Resolution without changing either supplied file: the snapshot and
   `settings_json.displayOrder` keep the authored per-section order; the `display_order` column
   holds a derived version-unique order (document order of sections, then authored order). The
   validator enforces uniqueness per section. Renderers/reports must use the snapshot order.
2. Fields without a column in the supplied schema are carried in `settings_json` of the owning or
   parent row (documented in `DefinitionMapper.cfc`); rule authoring metadata lives in an
   `authoring` block inside `conditions_json` (runtime reads `logic`/`conditions` only).
3. The compiled snapshot contains no SQL GUIDs so the same document yields the same checksum in
   every environment; the runtime resolves keys → GUIDs through the versioned definition tables
   (which the importer proves are equivalent to the snapshot).
4. Import validation runs entirely before the transaction (DB-07/DB-08 never create a version).
   Database-level failures inside the transaction are also proven to roll back.
5. Global dimension values present in the database but absent from a document are never deleted;
   they are kept, re-ordered after the document's values if their order collides, and reported as
   warnings.
6. Maintenance endpoints are the Phase 1 seeding path; production seeding also uses them (loopback
   + token, temporarily enabled) until the Phase 6 administration UI exists.
7. The dependency-free CFML test runner replaces TestBox because ForgeBox was unreachable from the
   build environment; it can be swapped later without changing the specs' assertions much.
8. Canonical JSON forbids object keys differing only by letter case (CFML structs are
   case-insensitive); the validator rejects such keys (`KEY_CASE_COLLISION`).

## Not testable in this environment (must be verified on the target platform)

- **Adobe ColdFusion 2023 itself.** Adobe's installer/Docker image and the Ortus/ForgeBox
  artifacts were unreachable. All CFML was executed on Lucee 6.2.8. Re-run `npm test` against a
  ColdFusion 2023 deployment. Specific points to confirm on Adobe:
  - JSON `null` handling in `deserializeJSON` and `javaCast("null","")` struct assignments
    (covered by `CanonicalJsonTest.testNullValuedKeysAreRetainedFromJson` and
    `testExplicitNullAssignmentSerializesAsNull`, which will fail loudly if Adobe drops null keys);
  - `cf_sql_longnvarchar` parameters for `nvarchar(max)` columns and `cf_sql_char` for `checksum_sha256`;
  - `this.datasources` with `driver="MSSQLServer"` and the optional `url` for TLS (`Application.cfc`);
  - `transaction {}` with `transactionCommit()/transactionRollback()` inside closures;
  - `cgi.path_info` under the IIS/Apache connector (see `RequestContext.pathInfo` fallback);
  - `writeLog(file="icfwalk")` location and `server.system.environment` availability.
- `Application.cfc` datasource branch for Adobe ColdFusion (only the Lucee branch executed here).
- SQL Server 2016 specifically: verified on 2022; scripts use only 2016-compatible features
  (`ISJSON`, `THROW`, `SYSUTCDATETIME`, filtered indexes).

## Unresolved defects or blockers

None open for Phase 0/1. External items still required before production: an Adobe ColdFusion 2023
environment (verification listed above), identity-provider details (Phase 2), and content-owner
wording for the 17 placeholder prompts (tracked as warnings, not blockers).

## Phase 1 completion gate

| Gate item | Status |
| --- | --- |
| Clean database creation | Met (DB-01, `apply-schema.mjs`) |
| Repeatable seed | Met (DB-05, seed endpoint idempotency, reorder round-trip) |
| Referential checks | Met (validator MISSING_REFERENCE/… plus DB round-trip checksum) |
| No published-version overwrite | Met (DB-06) |

## Phase 2: identity, roles, authorization, and organizational scope

Base: commit `cce5e79`. No Phase 0/1 code was reworked except two additive changes required by
Phase 2 (`Router` route policies, `Logger` actor id); no Phase 1 regression was found.

### Work completed

1. **Identity abstraction** (`src/identity/`): `IdentityProvider` interface; `HeaderIdentityProvider`
   as the production SSO seam (gateway-asserted subject/name/email headers with configurable names,
   trusted-proxy allowlist with IPv4/CIDR, optional shared secret, spoofing attempts logged);
   `IdentityProviderFactory` (unknown modes fail at startup); `DevelopmentIdentityProvider`
   (`X-ICFWalk-Dev-Subject`) constructible only when `ICFWALK_DEV_IDENTITY_ENABLED=true` outside
   production, guarded three times (ConfigLoader, factory, constructor). No identity-provider
   product was invented; an OIDC/SAML adapter plugs into the same interface.
2. **Users and sessions**: `UserRepository` (lookup by subject, JIT provisioning, sign-in
   bookkeeping, email-collision tolerance), `SessionService` (rotation at sign-in, invalidation at
   sign-out, 256-bit synchronizer CSRF token), `AuthenticationService` (per-request flow, inactive
   users rejected, audits `USER_PROVISIONED`/`USER_SIGNED_IN`/`USER_SIGNED_OUT`). `Application.cfc`
   enables sessions with HttpOnly, SameSite=Lax, and Secure cookies (Secure cannot be disabled in
   production; idle timeout configurable).
3. **Roles and scope** (`src/authorization/`): `OrgUnitRepository` (active tree, descendant
   resolution, idempotent upsert), `RoleScopeRepository` (effective-dated assignments filtered by the
   database clock, role and unit active flags), `AuthorizationService` (principal with permissions
   `walk.create`, `walk.read`, `walk.edit_owned`, `report.view` scoped to covered org units and global
   `instrument.manage`; `requirePermission`, `visibleOrgUnitIds`, `resolveScopedOrgUnit`, record-level
   `authorizeWalk` with owner rule; 403 vs 404 fail-closed semantics; every denial audited).
4. **Centralized route authorization**: every route declares `public`, `maintenance`,
   `{ authenticated }`, or `{ permission }` in `Router`; no default grants access; CSRF token
   required on session-authenticated mutating requests. New routes: `GET /api/me`,
   `GET /api/auth/csrf-token`, `POST /api/auth/sign-out`, `GET /api/admin/instrument/versions`
   (`instrument.manage`).
5. **Bootstrap seams** (maintenance, token-guarded): org-unit import (`config/org-units.example.json`
   generated from the instrument's school list), user provisioning, role assignment, and a
   tests-only fixture cleanup.
6. **Tests**: `AuthorizationTest` (12 cases, AUTH-03..09 plus owner rule, inactive unit, audit
   content), `IdentityTest` (10 cases: header adapter trust/secret/malformed input, stub guards,
   config rules, provisioning, inactive users, authentication flow), `tests/node/auth.test.mjs`
   (5 HTTP cases: AUTH-01, session cookie flags, CSRF, AUTH-06 route separation, maintenance
   isolation), `ConfigLoaderTest` extended, schema/DAO contract extended to the new tables.
7. **Documentation**: `docs/ARCHITECTURE.md` (Phase 2 section, Phase 3 hand-off),
   `docs/ENDPOINTS.md` (policies and new routes), `docs/LOCAL_SETUP.md` (SSO configuration and
   bootstrap), `docs/ACCEPTANCE_TRACKING.md`, `.env.example`.

### Files created or changed (Phase 2)

```
Created: src/identity/{IdentityProvider,HeaderIdentityProvider,DevelopmentIdentityProvider,IdentityProviderFactory,UserRepository,SessionService,AuthenticationService}.cfc
         src/authorization/{OrgUnitRepository,RoleScopeRepository,AuthorizationService}.cfc
         src/controllers/{AuthController,AdminInstrumentController}.cfc
         config/org-units.example.json
         tests/cfml/support/Fixtures.cfc  tests/cfml/specs/{AuthorizationTest,IdentityTest}.cfc
         tests/node/auth.test.mjs  docs/evidence/phase2-npm-test.txt
Changed: app/Application.cfc (sessions/cookies)  src/Bootstrap.cfc  src/http/Router.cfc (policies, CSRF)
         src/config/ConfigLoader.cfc (SSO/session settings)  src/core/Logger.cfc (actor id)
         src/controllers/MaintenanceController.cfc (org units, provision, assign, cleanup)
         tests/cfml/specs/ConfigLoaderTest.cfc  tests/node/schema-contract.test.mjs  package.json
         docs/{ARCHITECTURE,ENDPOINTS,LOCAL_SETUP,ACCEPTANCE_TRACKING}.md  .env.example  BUILD_STATUS.md
```

### Tests and validators executed (Phase 2)

| Command | Result |
| --- | --- |
| `npm test` (full regression, `docs/evidence/phase2-npm-test.txt`) | 26/26 pass (Phase 1's 21 plus 5 HTTP auth cases) |
| CFML suite via `/api/maintenance/tests/run` | 64 passed, 0 failed, 0 skipped (Phase 1's 42 + AuthorizationTest 12 + IdentityTest 10) |
| Targeted runs during implementation | `?filter=Identity`, `?filter=Authorization`, `?filter=ConfigLoader`, `node --test tests/node/auth.test.mjs` |
| `node scripts/validate-handoff.mjs` | ok, 51 checks (unchanged supplied files) |

Acceptance IDs satisfied in Phase 2: AUTH-01, AUTH-02, AUTH-03, AUTH-04, AUTH-05, AUTH-06, AUTH-07,
AUTH-08, SEC-03; partial: AUTH-09 (org-unit and walk identifiers; item/option/dimension tampering
belongs to the Phase 4 response endpoints), SEC-04 (local cookie evidence; Secure flag by
configuration rule). See `docs/ACCEPTANCE_TRACKING.md`.

### Assumptions and decisions (Phase 2)

1. **SSO topology**: the production adapter is header assertion by a trusted SSO gateway/reverse
   proxy, the common district pattern (ADFS/Entra/Shibboleth in front of IIS). The provider product
   and claim names are configuration. The web server must strip the identity headers from client
   traffic; the adapter additionally refuses headers from non-allowlisted source addresses and can
   require a shared secret.
2. **Just-in-time provisioning** creates `app_user` rows on first sign-in (configurable). A row
   without role assignments grants nothing.
3. **Role assignments are administered out of band** in Phase 2 (maintenance endpoints or DBA
   scripts); a role-administration UI is not in any phase of the plan and was not added.
4. **Global roles still need an org unit** because `user_role_scope.org_unit_id` is NOT NULL; for
   `MASTER_INSTRUMENT_ADMIN` the unit is informational (the district root by convention).
5. **Denial semantics**: 403 when the caller has no such capability anywhere, 404 when the
   capability exists but not for that unit or record, 400 for malformed identifiers.
6. **Owner rule**: `walk.edit_owned` applies only to the owner and only within an assignment
   covering the walk's unit; non-owners with `walk.read` may open but never edit.
7. **Sessions** hold no roles; the principal is rebuilt every request so revocations apply
   immediately.

### Not testable in this environment (Phase 2 additions)

- Adobe ColdFusion 2023: `this.sessionCookie` keys (`httpOnly`, `secure`, `sameSite`),
  `sessionRotate()`/`sessionInvalidate()` behavior, `interface`/`implements` compilation, and CFML
  session cookie names under the IIS connector. `npm test` plus `npm run test:auth` against a
  ColdFusion deployment with `ICFWALK_SSO_MODE=development` in a development environment verifies
  all of it.
- The header adapter over HTTP end to end (a gateway is required); covered by `IdentityTest` at
  the adapter level with trusted, untrusted, CIDR, secret, and malformed cases.
- The `Secure` cookie flag over TLS (local runtime is plain HTTP).

### Unresolved defects or blockers (Phase 2)

None open. External items before production: identity gateway addresses and header names
(`ICFWALK_SSO_*`), and the district's org-unit codes/names replacing the example fixture.

### Phase 2 completion gate

| Gate item | Status |
| --- | --- |
| Every endpoint has explicit authorization | Met: `Router` requires a declared policy per route; maintenance routes token-guarded; user routes authenticated with permission checks |
| Cross-scope tests fail closed | Met: AUTH-04/05/06/07/08/09 negative tests at service level and AUTH-01/06 at HTTP level, all denials audited |

## Exact recommended starting point for Phase 3 (as recorded at the end of Phase 2)

1. Read `docs/ARCHITECTURE.md` ("What Phase 3 builds on"), `src/http/Router.cfc`, and
   `src/authorization/AuthorizationService.cfc` (`visibleOrgUnitIds`, `authorizeWalk`).
2. Add a snapshot loader (`src/instrument/SnapshotService.cfc`) that returns the current
   published version's compiled snapshot (for Phase 3 fixtures, the seeded DRAFT may be published
   through a test-only path or the renderer can be pointed at the DRAFT snapshot explicitly; do not
   change publish semantics ahead of Phase 6).
3. Build the renderer/visual shell from the snapshot only (sections by `parentSectionKey` +
   `displayOrder`, placements by authored `displayOrder`, rules from `conditions`), matching
   `source/current-prototype.html`; no question text in templates.
4. Serve static assets from `app/assets/` and an HTML shell route (`GET /` → authenticated) that
   embeds `/api/me` data and the CSRF token; keep JSON APIs under `/api`.
5. Keep My Walks scoping to `visibleOrgUnitIds(principal, "walk.read")` plus owned drafts, and
   walk creation to `{ "permission": "walk.create", "orgUnitBody": "orgUnitId" }` routes.
6. Write fixture-driven renderer tests first (desktop/mobile snapshots of the editor states via
   Playwright, which is pre-installed) and extend `tests/node/` with an authenticated browser flow
   using the development identity header.

## Phase 3: instrument engine and visual shell

Base: commit `0b5d91a` (Phase 2). No Phase 0-2 behavior was reworked except one Phase 2 defect
found by the Phase 3 regression run (below); all Phase 1/2 tests still pass.

### Work completed

1. **Snapshot service** (`src/instrument/SnapshotService.cfc`): resolves the version walks render
   from (newest PUBLISHED; outside production the newest DRAFT snapshot when
   `ICFWALK_ALLOW_UNPUBLISHED_INSTRUMENT` permits, marked `isFallbackDraft`), parses the stored
   canonical snapshot once per checksum, and exposes `snapshotFor` / `renderModelFor(versionId)` for
   pinned rendering. Publish semantics were not touched (Phase 6).
2. **Render model builder** (`src/instrument/RenderModelBuilder.cfc`, format
   `icfwalk-render-model/1`): compiles the flat snapshot into the section tree with derived
   presentation facts only (see `docs/ARCHITECTURE.md`, "Instrument engine and visual shell").
   Section presentation, item layouts, question numbering, look-for grouping, skippable-component
   applicability items, placeholder flags, and option filters are all derived from keys, orders,
   settings, response sets, rules, and placements. Unsupported rule effects/operators, option
   filters, and item types are refused.
3. **Visibility engine** in two implementations proven equivalent: `src/instrument/VisibilityEngine.cfc`
   (`evaluateVisibility`, `normalize`, `blankState`) and `app/assets/js/rules.js`, checked against
   `tests/fixtures/visibility-vectors.json` (29 states covering grade filtering, Period, every
   conditional classroom section, skippable components, invalid codes, whitespace text, and both
   hidden-value policies).
4. **HTTP**: `GET /` (HTML shell, strict CSP, HTML error pages for browsers) and
   `GET /api/instrument/current` (render model + policies), both behind the new declarative
   `anyPermission` route policy (walk, report, or instrument capability; role-less users are 403
   and audited). `core/HtmlEncoder` provides engine-independent HTML encoding.
5. **Browser application** (`app/assets/`, plain ES modules, no build step): `renderer.js`
   (dynamic editor: visit-information grid, conditional cards, Part 1-4 accordions, tinted
   component accordions with `n/2 rated` / `Not part of this lesson`, Look Fors boxes from the
   display items, pills with definitions on demand, notes and summary fields, Period and Other
   handling), `walk-state.js` (working state + prototype clearing rules via the engine),
   `walk-store.js` (`WalkStore` boundary with the Phase 3 in-memory `SessionWalkStore`), `app.js`
   (My Walks list: empty state, cards, newest first, open, delete with inline confirmation/cancel,
   school chooser for users who can create in several units), `icfwalk.css` (prototype palette and
   layout plus focus rings, aria-driven states, phone/tablet breakpoints).
6. **Tests**: `RenderModelTest` (9), `VisibilityEngineTest` (10), `SnapshotServiceTest` (4),
   `ConfigLoaderTest` (+1); `tests/node/shell.test.mjs` (4: AUTH-01 on the new routes, 403 for
   role-less users, walker/report-only/admin may read the instrument, CSP/headers/no embedded
   content), `tests/node/visibility.test.mjs` (10: vectors parity against the served model,
   COND-01..15 at engine level, walk-state helpers), `tests/node/browser.test.mjs` (11 Playwright
   cases: dynamic rendering of all 23 sections / 144 items / 138 options from the served model,
   COND-01..15 in the DOM, WALK-01/04/05/06/07 at UI level, keyboard operation, axe-core WCAG 2.1
   AA, responsive overflow checks with screenshots).
7. **Documentation**: `docs/ARCHITECTURE.md` (Phase 3 section and Phase 4 hand-off),
   `docs/ENDPOINTS.md`, `docs/LOCAL_SETUP.md` (browser access, new test commands), `.env.example`,
   `docs/ACCEPTANCE_TRACKING.md`, evidence in `docs/evidence/phase3-npm-test.txt` and
   `docs/evidence/screenshots/`.

### Files created or changed (Phase 3)

```
Created: src/instrument/{SnapshotService,RenderModelBuilder,VisibilityEngine}.cfc
         src/controllers/{InstrumentController,ShellController}.cfc  src/core/HtmlEncoder.cfc  src/views/shell.html
         app/assets/css/icfwalk.css  app/assets/js/{api,rules,walk-state,walk-store,renderer,app}.js
         tests/cfml/specs/{RenderModelTest,VisibilityEngineTest,SnapshotServiceTest}.cfc
         tests/fixtures/visibility-vectors.json  tests/node/{shell,visibility,browser}.test.mjs
         docs/evidence/phase3-npm-test.txt  docs/evidence/screenshots/*.png
Changed: src/Bootstrap.cfc (engine + controllers)  src/http/Router.cfc (anyPermission policy, two routes)
         src/http/Responder.cfc (HTML error pages for page routes)  src/config/ConfigLoader.cfc (ICFWALK_ALLOW_UNPUBLISHED_INSTRUMENT)
         src/authorization/RoleScopeRepository.cfc (Phase 2 timing defect, below)
         tests/cfml/specs/ConfigLoaderTest.cfc  package.json (serial test files, test:shell, test:browser; playwright + axe-core dev deps)  package-lock.json
         docs/{ARCHITECTURE,ENDPOINTS,LOCAL_SETUP,ACCEPTANCE_TRACKING}.md  .env.example  BUILD_STATUS.md
```

### Tests and validators executed (Phase 3)

Environment as before (Lucee 6.2.8 on Jetty, SQL Server 2022 in Docker, Node 22) plus Playwright
1.56 with the pre-installed Chromium and axe-core 4.

| Command | Result |
| --- | --- |
| `npm test` (full regression, serial, `docs/evidence/phase3-npm-test.txt`) | 51/51 pass: Phase 1/2's 26 plus shell (4), visibility (10), browser (11) |
| CFML suite via `/api/maintenance/tests/run` (inside `npm test`) | 88 passed, 0 failed, 0 skipped (Phase 2's 64 + RenderModelTest 9 + VisibilityEngineTest 10 + SnapshotServiceTest 4 + ConfigLoaderTest 1) |
| `npm run test:browser` alone | 11/11; screenshots written to `docs/evidence/screenshots/` |
| Targeted runs during implementation | `?filter=RenderModel`, `?filter=VisibilityEngine`, `?filter=SnapshotService`, `?filter=Authorization` (x6 after the timing fix), `node --test tests/node/{shell,visibility,browser}.test.mjs` |
| `node scripts/validate-handoff.mjs` | ok, 51 checks (supplied files unchanged) |

Test-harness change: `npm test` now runs the Node test files serially (`--test-concurrency=1`).
The CFML import specs create, temporarily publish, and delete throwaway versions; run concurrently
with a browser session they change the "current version" under it.

### Acceptance IDs satisfied in Phase 3

PASS: COND-01, COND-02, COND-03, COND-04, COND-05, COND-06, COND-07, COND-08, COND-09, COND-11,
COND-13, COND-14, COND-15; A11Y-01 (editor), A11Y-03 and A11Y-04 (Phase 3 views), A11Y-05 (automated part).
PASS at UI level against the session store (server persistence re-verifies them in Phase 4):
WALK-01, WALK-04, WALK-05, WALK-06, WALK-07. PARTIAL: WALK-02, COND-10, COND-12, SEC-02, A11Y-02.
Also covered on the new routes: AUTH-01 and AUTH-06 separation (report-only and admin roles may read
the instrument definitions, never walk data). Details: `docs/ACCEPTANCE_TRACKING.md`.

### Visual and browser items requiring later verification

Automated: screenshots at 375, 768, and 1280 px (`docs/evidence/screenshots/`), overflow checks,
axe-core. Not verified here and to be checked by a person against `source/current-prototype.html`:

- Side-by-side visual comparison with the prototype (typography, spacing, colors) in a real
  browser; the sandbox could not load Work Sans from Google Fonts or the U-46 logo from the
  district host, so screenshots use the fallback font stack and hide the logo.
- 200 % zoom (A11Y-05) and screen-reader announcements (A11Y-02) with NVDA/VoiceOver.
- The sticky top bar and focus behavior on iOS/Android browsers.
- The Part 4 email-draft composer (Phase 5) is an empty, hidden slot in Phase 3.

### Assumptions and recorded decisions (Phase 3)

1. **No persistence in Phase 3** (per the phase plan): `WalkStore` is the boundary; the shipped
   `SessionWalkStore` keeps walks in page memory only, nothing is written to localStorage or the
   server, and the My Walks subtitle says so. Save buttons and the status strings (`All changes
   saved`, `Unsaved changes`, `Saving...`) work against that store; the 700 ms debounce, row
   versions, conflicts, and idempotent mutation ids are Phase 4 with an API-backed store.
2. **Walk org unit at creation**: a walk belongs to one org unit the user may create in
   (`walk.create` scope from `/api/me`). One unit starts immediately; several show a school chooser.
   When an org unit code equals a School dimension value code, the School field is preselected.
3. **Source conflict recorded (prototype vs JSON, Content-Area section heading):** the prototype
   retitles the content-area card "<Content> Classroom" / "Shown automatically because the content
   area selected is <Content>." at run time; the JSON authors the static title "Content-Area
   Look-Fors" and instructions "Shown automatically for Music, Art, or CTE." (also in the aligned
   workbook and `docs/PRODUCT_SPEC.md`). The renderer shows the JSON text because the title lives in
   the instrument contract. A dynamic heading needs a `titleTemplate` section setting in a future
   DRAFT version (renderer support would be added with it).
4. **Deviations from the prototype for WCAG 2.1 AA** (A11Y-04): muted text `#7C8A97` -> `#5A6875`,
   REQUIRED badge `#D55300` -> `#B84600`, rating counts use `--gray` on the tinted headers, selected
   pills carry a check mark, delete confirmation is an inline dialog with the prototype's wording
   instead of `window.confirm`, and the Period value is retained while hidden (prototype clears it;
   `docs/OPEN_DECISIONS.md` default RETAIN_HIDDEN, configurable).
5. **Presentation rules are documented heuristics on data**, not names: top-level sections with
   placements or SHOW rules are cards, other top-level sections accordions; nested sections with
   `settings.partNumber` are component accordions; scored questions are numbered, and sections
   without scored questions number every question. My Walks card fields are configured by dimension
   code (`LIST_CARD` in `app.js`).
6. **Report-only and instrument-admin users may load the instrument definitions** (they are not
   walk data; reports need them for filters). Users without any role are refused (403, audited).
7. **`evaluate` is a reserved function name in CFML**; the server method is `evaluateVisibility`
   while the JavaScript twin keeps `evaluate`.
8. **Phase 2 defect fixed**: `RoleScopeRepository.assign` set `effective_start = SYSUTCDATETIME()`
   and `endAssignment` set `effective_end = SYSUTCDATETIME()`; datetime2(3) rounding could place a
   new start a fraction of a millisecond in the future (assignment briefly ineffective) and ending
   in the same millisecond violated `CK_user_role_scope_dates`. New assignments without an explicit
   start are effective from one second before creation; ending uses the last completed millisecond
   (or start + 1 ms). Reproduced 1 in ~4 runs before, 0 in 6 after.

### CF2023 verification items (Phase 3 additions)

- `encodeForHTML` is not available on Lucee light; the build uses `core/HtmlEncoder`. On Adobe
  ColdFusion both exist; keep `HtmlEncoder` so behavior is identical on both engines.
- Struct keys assigned `javaCast("null", "")` in the render model (`responseSet`, `partNumber`,
  `questionNumber`, `defaultApplicable`) rely on the Phase 1 null handling; `RenderModelTest`
  serializes the whole model and fails loudly if Adobe drops those keys.
- `cgi.script_name` under the IIS/Apache connector for `ShellController.basePrefix` (the web-root
  prefix in front of `/index.cfm`; verify `data-api-base` in the served page).
- Static assets: `app/assets/` must be served by IIS/Apache directly (not through ColdFusion), and
  `Application.cfc` keeps rejecting non-`index.cfm` CFML requests.
- The Content-Security-Policy header set through `cfheader` in a `text` response (`Responder.send`)
  and the `Accept`-based HTML error negotiation (`Responder.wantsHtml`).
- Browser suite on the target: `npm run test:browser` against the ColdFusion deployment in
  development mode; the same screenshots then show Work Sans and the district logo.

### Unresolved defects or blockers (Phase 3)

None open. External items unchanged (Adobe ColdFusion 2023 environment, identity gateway details,
district org-unit codes, content-owner wording for the 17 placeholders). Product decision to record
for content owners: whether the content-area card should adopt the prototype's dynamic
"<Content> Classroom" heading (decision 3 above).

### Phase 3 completion gate

| Gate item | Status |
| --- | --- |
| Fixture snapshot renders the current form accurately | Met: `browser.test.mjs` proves all 23 sections, 144 items (exact prompts), 138 options, and 10 placements come from the served model of the seeded snapshot (golden checksum); `RenderModelTest` proves structure, order, layouts, and definitions against `config/instrument-config.json` |
| Desktop and mobile widths | Met (automated): 375/768/1280 px without horizontal overflow, screenshots captured; person-in-the-loop comparison listed above |
| No hardcoded question content | Met: `shell.test.mjs` asserts the shell carries no instrument text; the renderer and engine reference only model facts; `grep` of `app/assets/js` finds no prompt text |
| Grade filtering, conditional sections, skippable components, keyboard behavior, accessible status messaging | Met: COND-01..15 at engine, parity, and DOM level; A11Y-01/03 automated |

## Exact recommended starting point for Phase 4

1. Read `docs/ARCHITECTURE.md` ("Instrument engine and visual shell" and "What Phase 4 builds on"),
   `docs/DATA_CONTRACT.md` (walk aggregate, autosave payload, response states, visibility and
   clearing rules, concurrency), `app/assets/js/walk-store.js` (the interface to implement), and
   `src/instrument/VisibilityEngine.cfc` (`normalize` returns the clearing decisions the autosave
   transaction must apply server-side).
2. Add `src/walks/WalkRepository.cfc` + `WalkService.cfc` and `controllers/WalkController.cfc` with
   routes `GET /api/walks` (`visibleOrgUnitIds(principal, "walk.read")` plus owned drafts, newest
   `updated_at` first, list DTO = the `LIST_CARD` dimensions only), `POST /api/walks`
   (`{ "permission": "walk.create", "orgUnitBody": "orgUnitId" }`, pin `version_id` from
   `SnapshotService.currentVersion()`, seed defaults from `VisibilityEngine.blankState`, idempotency
   key), `GET /api/walks/{id}` (`authorizeWalk(read)`, render model via `renderModelFor(walk.versionId)`),
   `PUT /api/walks/{id}` (`authorizeWalk(edit)`, `row_version` compare, resolve keys -> GUIDs through
   `DefinitionRepository`, reject options/items/dimensions outside the pinned version, persist
   states from `evaluateVisibility`, apply `normalize` changes in the same transaction, revisions,
   audit), `POST /api/walks/{id}/void`, and completion validation on required items.
3. Replace `SessionWalkStore` with `ApiWalkStore` (same interface) and add the 700 ms debounced
   autosave, `Saving...` / `All changes saved` / conflict UI in `app.js`; keep `renderer.js`
   unchanged (it already emits the change list per edit).
4. Decide the column mapping for "Other" free text on a LIST dimension (proposal:
   `selected_value_id` = the Other value plus `text_value`), and record it in `docs/DATA_CONTRACT.md`.
5. Extend `tests/node/browser.test.mjs` with SAVE-01..08 and WALK-02/03/08..11, and `AuthorizationTest`
   with AUTH-09 item/option/dimension tampering through the new endpoints.

## Phase 4: walk persistence and autosave

Base: commit `9c03298` (Phase 3). No Phase 0-3 behavior was reworked except two Phase 3 defects
found by Phase 4 testing (below); every earlier test still passes.

### Work completed

1. **Database migration `database/003_walk_mutation.sql`** (additive, idempotent): `icf.walk_mutation`,
   the append-only client-mutation log that makes create/save/complete/void idempotent. Wired into
   `scripts/db/apply-schema.mjs`, `tests/node/db-scripts.test.mjs` (applied twice, 21 tables),
   `tests/node/schema-contract.test.mjs` (walk tables and `src/walks` now under the contract), and
   `database/README.md`. The supplied `001`/`002` scripts are unchanged.
2. **Server walk aggregate** (`src/walks/`): `WalkRepository` (parameterized access to `walk`,
   `walk_dimension_value`, `walk_response`, `walk_revision`, `walk_mutation`; rowversion exchanged as
   a hex token; cached key→GUID index per version checksum; scoped list query), `WalkPayloadValidator`
   (every dimension code, item key, option code, value code, and typed value checked against the
   pinned version's render model and definition rows; all issues collected), `WalkService`
   (list/open/instrument/create/save/complete/void/refuseDelete; one transaction per mutation with
   `UPDLOCK` on the walk row, row-version compare, server-side `normalize` + `evaluateVisibility`,
   diff-writes, revisions, mutation replay, audit), `controllers/WalkController`, and eight routes in
   `Router` under the existing declarative policies (`walk.create` for the body's org unit; walk
   capabilities for the rest; CSRF on every mutation). Record-level authorization stays in
   `AuthorizationService.authorizeWalk`; the browser carries no authorization logic.
3. **Browser** (`app/assets/js`): `ApiWalkStore` replaces `SessionWalkStore` behind the same
   `WalkStore` interface; `app.js` adds the 700 ms debounced autosave (edits mid-flight coalesce into
   the next save), client mutation ids kept across retries of the same payload, `Unsaved changes` /
   `Saving...` / `All changes saved` / specific failure + Retry, the conflict panel (`alertdialog`
   listing this session's unsent edits against the saved values; use saved version, or keep edits and
   save with the new row version), explicit "Complete walk" with an `alert` summary of field-level
   errors (links expand and focus the control; `aria-invalid` + description), read-only editor for
   non-owners, completed banner, void-with-reason for completed walks, per-version render-model
   cache for historical walks. `api.js` gains PUT/DELETE and a `NetworkError`; `shell.html` and
   `icfwalk.css` gain the new elements/styles. `renderer.js`, `rules.js`, `walk-state.js` unchanged.
4. **Fixture hygiene**: `MaintenanceController.cleanupFixtures` and `tests/cfml/support/Fixtures`
   remove walk child rows (mutations, revisions, responses, dimension values, walk audit) before walks.
5. **Tests**: `WalkServiceTest` (18 database-backed cases), `tests/node/walks.test.mjs` (9 HTTP cases),
   `tests/node/browser-persistence.test.mjs` (7 Playwright cases), `browser.test.mjs` adjusted for the
   asynchronous store (waits for the server round trip), three exact-comparison vectors added to
   `tests/fixtures/visibility-vectors.json` (both engines), `db-scripts` and `schema-contract` extended.
6. **Documentation**: `docs/ARCHITECTURE.md` (Phase 4 section, Phase 5 hand-off), `docs/ENDPOINTS.md`,
   `docs/DATA_CONTRACT.md` (Phase 4 build decisions appendix), `docs/LOCAL_SETUP.md`,
   `docs/ACCEPTANCE_TRACKING.md`, `database/README.md`, evidence `docs/evidence/phase4-npm-test.txt`
   and screenshots `conflict-panel-desktop.png`, `completion-errors-desktop.png`.

### Files created or changed (Phase 4)

```
Created: database/003_walk_mutation.sql
         src/walks/{WalkRepository,WalkPayloadValidator,WalkService}.cfc  src/controllers/WalkController.cfc
         tests/cfml/specs/WalkServiceTest.cfc  tests/node/{walks,browser-persistence}.test.mjs
         docs/evidence/phase4-npm-test.txt  docs/evidence/screenshots/{conflict-panel,completion-errors}-desktop.png
Changed: src/Bootstrap.cfc  src/http/Router.cfc  src/controllers/MaintenanceController.cfc (fixture cleanup)
         src/instrument/VisibilityEngine.cfc (Phase 3 defects, below)
         app/assets/js/{api,walk-store,app}.js  app/assets/css/icfwalk.css  src/views/shell.html
         tests/cfml/support/Fixtures.cfc  tests/fixtures/visibility-vectors.json (+3 vectors)
         tests/node/{browser,db-scripts,schema-contract}.test.mjs  package.json (test:walks, test:browser)
         scripts/db/apply-schema.mjs  database/README.md (supplied file; manifest entry refreshed with scripts/refresh-manifest.mjs)
         docs/{ARCHITECTURE,ENDPOINTS,DATA_CONTRACT,LOCAL_SETUP,ACCEPTANCE_TRACKING}.md  manifest.json  BUILD_STATUS.md
```

### Database and API changes

- New table `icf.walk_mutation` (`003`); no change to supplied `001`/`002` objects. Walk rows now
  carry `observed_at` = the visit-date dimension; response rows exist for every response-capable
  item of the pinned version (`UNANSWERED` when empty); dimension rows exist only with a value.
- New routes: `GET /api/walks[?scope=all]`, `POST /api/walks`, `GET /api/walks/{id}`,
  `GET /api/walks/{id}/instrument`, `PUT /api/walks/{id}`, `POST /api/walks/{id}/complete`,
  `POST /api/walks/{id}/void`, `DELETE /api/walks/{id}` (always 409). Contract in `docs/ENDPOINTS.md`.
- Audit events added: `WALK_CREATED`, `WALK_COMPLETED`, `WALK_COMPLETION_REJECTED`,
  `WALK_POST_COMPLETION_EDIT`, `WALK_VOIDED`, `WALK_DELETE_REFUSED`, `WALK_SAVE_CONFLICT`,
  `WALK_SAVE_REJECTED`, `WALK_MUTATION_REPLAYED`, `WALK_MUTATION_ID_REUSED`.

### Tests and results (Phase 4)

Environment as before (Lucee 6.2.8 on Jetty, SQL Server 2022 Developer in Docker, Node 22.22,
Playwright 1.56 with the pre-installed Chromium, axe-core 4). The Phase 3 baseline (51/51) was
reproduced in this environment before any Phase 4 change.

| Command | Result |
| --- | --- |
| `npm test` (full regression, once, `docs/evidence/phase4-npm-test.txt`) | 68/68 pass: Phase 1-3's 51 plus walks HTTP (9) and browser persistence (7); browser (11) re-run against the persistent store; DB scripts now include `003` |
| CFML suite via `/api/maintenance/tests/run` (inside `npm test`) | 106 passed, 0 failed, 0 skipped (Phase 3's 88 + WalkServiceTest 18) |
| Targeted runs during implementation | `?filter=WalkService` (x6), `?filter=VisibilityEngine`, `?filter=RenderModel`, `?filter=Authorization`, `?filter=SnapshotService`, `node --test tests/node/{walks,browser,browser-persistence,shell,schema-contract,visibility}.test.mjs` |
| `node scripts/validate-handoff.mjs` | ok (supplied files unchanged except `database/README.md`, entry refreshed) |

Concurrency and idempotency results: stale write → 409 `STALE_ROW_VERSION`, first write intact
(service, HTTP, two browser sessions); same mutation id → replay with the committed row version, no
duplicate response/dimension/revision rows, 2 mutation rows (CREATE + SAVE) for a created-then-saved
walk; mutation id reused by another user/walk/action → 409 `MUTATION_ID_REUSED`; browser retry after
an aborted request reuses the mutation id and lands once. Security/tampering results: 15 payload
cases at the service and 10 over HTTP rejected with specific codes and `details.issues`, nothing
written, row version unchanged, every rejection audited; cross-school 404, colleague 403 on edits,
report-only/admin 403 everywhere, 401 without identity, 403 without CSRF. Browser results: 11/11
Phase 3 cases plus 7/7 Phase 4 cases (debounce = exactly one PUT per burst; status transitions;
network failure + retry; conflict panel and both resolutions; reload persistence; markup as text;
completion errors and completion; void with reason; axe clean on the new states).

### Acceptance IDs satisfied in Phase 4

PASS: WALK-01, WALK-02, WALK-03, WALK-04, WALK-05, WALK-06, WALK-07, WALK-08, WALK-09, WALK-10,
WALK-11 (pinned rendering; publishing is Phase 6); SAVE-01, SAVE-02, SAVE-03, SAVE-04, SAVE-05,
SAVE-06, SAVE-07, SAVE-08; COND-05, COND-06, COND-10, COND-12, COND-13 now including persisted
states; AUTH-05, AUTH-09 completed through the walk endpoints; SEC-01, SEC-02 (walk surfaces),
SEC-05 (saves/conflicts/rejections), SEC-06 (idempotent retry; restart not automated); A11Y-01,
A11Y-02, A11Y-03 for the new states. Details: `docs/ACCEPTANCE_TRACKING.md`.

### Assumptions, decisions, and source conflicts (Phase 4)

1. **Idempotency needs a table.** The supplied schema has no place to record a client mutation id,
   so `003_walk_mutation.sql` adds one (append-only, same transaction as the change). Recording ids
   inside `audit_event.details_json` was rejected: audit is not indexed for lookup and must stay a
   log, not a control table.
2. **Delete = void.** Nothing is ever physically deleted. The My Walks delete confirms with the
   prototype's wording and voids the DRAFT with the reason "Deleted by owner from My Walks";
   completed walks require a typed reason (new inline field). `DELETE` is refused with 409.
3. **Completed walks stay editable by their owner**; each edit must keep the walk complete and
   appends a `POST_COMPLETION_EDIT` revision. Drafts append no revisions (autosave would create
   thousands); completion appends the `COMPLETE` revision. The data contract leaves revision policy
   to the application; this is the recorded policy.
4. **"Other" mapping**: `selected_value_id` = the Other value + `text_value` = the text, accepted only
   with Other selected (stale text is dropped, not rejected, because the Phase 3 UI retains it in
   memory when the user switches back to a listed value). Recorded in `docs/DATA_CONTRACT.md`.
5. **My Walks scope**: the UI lists the owner's walks ("My walks" in the prototype); the API also
   offers `scope=all` (readable walks in scope) for later views. Non-owners who may read a walk get a
   read-only editor.
6. **Whole-state saves**: the browser sends the full working state (the contract's payload) rather
   than deltas, so the server's normalization is authoritative and a retry is trivially idempotent.
7. **Conflict merge semantics**: "keep my edits" applies only the fields changed since this session
   last loaded or saved (its unsent edits); a stale baseline is never re-applied over another
   session's newer values (found while testing SAVE-05 and fixed before delivery).
8. **`observed_at`** follows the visit-date dimension; until a date is entered it is the creation
   instant. Reporting indexes on `observed_at` therefore reflect the walk date.
9. **Phase 3 defect fixed (serialization)**: `VisibilityEngine.index` cached its index on the model
   struct with a back-reference to the model; once the server engine ran against the shared cached
   render model, serializing that model (`/api/walks/{id}/instrument`, `/api/instrument/current`)
   recursed until a `StackOverflowError`. The index is now built per call and the model is never
   mutated.
10. **Phase 3 defect fixed (coerced comparison)**: the CFML engine compared codes with `==`, which
    treats `"yes"`/`"1"` and `"1"`/`"1.0"` as equal; a foreign option code on a 1-5 item counted as
    answered (and would have passed SAVE-07 validation). All code comparisons in the engine, the
    validator, and the service now use `compare()`; three shared vectors pin the behavior in both
    engines. The JavaScript twin was already strict.
11. **Lucee runtime note**: Lucee compiles components once and does not watch sources; the local
    helper documents the restart (`docs/LOCAL_SETUP.md`). Not relevant to Adobe ColdFusion.
12. **Source conflict recorded (contract payload vs. persisted row)**: the contract's example
    autosave payload carries a `state` per response; the server derives states itself and ignores
    any client-sent state field (only `storedCode`/`textValue` are accepted). Client-asserted states
    are never trusted.

### CF2023 verification items (Phase 4 additions)

- `CONVERT(varchar(18), CAST(row_version AS binary(8)), 1)` and the hex token round trip through
  the Adobe SQL Server driver (`WalkRepository.findWalk`; `WalkServiceTest` asserts the token shape).
- `WITH (UPDLOCK, ROWLOCK)` inside `transaction {}` with `queryExecute` on Adobe (lock held until
  commit): `WalkServiceTest.testSave04...` and `walks.test.mjs` SAVE-04 exercise the path but a true
  concurrent race is not automated; verify with two parallel PUTs on ColdFusion.
- `cf_sql_date` parameters (`WalkRepository.dateParam`) and `date_value` reads formatted with
  `dateFormat`; `cf_sql_decimal` for `number_value` (unused by the current instrument).
- `compare()` semantics and `structKeyExists` on JSON-deserialized bodies with `null` values in the
  validator (`isNull` guards); closures capturing `variables` inside `Db.transact` on Adobe.
- `getHttpRequestData(true).content` for PUT/DELETE bodies under the IIS connector (`Router.buildRequest`).
- Browser suites on the target: `npm run test:walks` and `npm run test:browser` against the ColdFusion
  deployment in development mode.

### Unresolved defects or blockers (Phase 4)

None open. External items unchanged (Adobe ColdFusion 2023 environment, identity gateway details,
district org-unit codes, content-owner wording for the 17 placeholders, the content-area heading
decision from Phase 3). Not automated here: an application-server restart in the middle of an
autosave (SEC-06); the idempotent retry path that covers it is proven at every level.

### Phase 4 completion gate

| Gate item | Status |
| --- | --- |
| Autosave tests pass without data loss | Met: SAVE-01/02 (one PUT per 700 ms burst, committed row version), SAVE-03 (retry after a lost request lands once) |
| Stale-write tests pass | Met: SAVE-04/05 at service, HTTP, and two-browser-session level; first write never overwritten; conflict UI keeps unsent edits |
| Duplicate-retry tests pass | Met: WALK-03, SAVE-06 (replay, no duplicate rows, ids bound to walk/actor/action) |
| Hidden-state tests pass | Met: COND-06/10 persisted `HIDDEN` with values retained and restored |
| Component-clear tests pass | Met: COND-12/13 ratings cleared to `NOT_APPLICABLE` in the same transaction as the applicability answer, notes retained, ratings do not reappear |

## Exact recommended starting point for Phase 5

**Read `docs/PHASE_5_IMPLEMENTATION_BRIEF.md` first.** It is the implementation-ready hand-off
(scope, reuse, files, formatter architecture, golden vectors, route contract, composer behavior,
security, exact tests, resolved source conflicts, ordered checklist, completion gate, and what not to
reread). The list below is the short form it expands.

1. Read `docs/ARCHITECTURE.md` ("Walk persistence and autosave" and "What Phase 5 builds on"),
   `docs/PRODUCT_SPEC.md` (summary export and email workflow), `source/current-prototype.html`
   (summary text format, filename pattern `ICFWalk_<grade>_<content>_<date>.txt`, email template
   wording and part list), and `config/instrument-config.json` `behavior.export` / `behavior.emailDraft`.
2. Build one summary formatter twice from the same render model + walk state: `src/walks/WalkSummaryFormatter.cfc`
   and `app/assets/js/summary.js`, proven equal by golden vectors (`tests/fixtures/summary-vectors.json`)
   over representative states (fully answered, unanswered items, Workshop Model = No, hidden
   conditional section, unsafe filename characters). Component averages: answered numeric scores only.
3. Serve `GET /api/walks/{id}/summary` (`authorizeWalk(read)`, `text/plain; charset=utf-8`, safe
   `Content-Disposition` filename) and wire `#export-btn` in `app.js` (hidden today).
4. Recreate the Part 4 email-draft composer in the `email-draft` layout slot of `renderer.js`
   (selectable parts from the item's `settings.selectableParts`, generate/regenerate/clear/copy/mailto,
   editable to/subject/body) and persist it through the existing save path (`email_workflow` item,
   validated by `WalkPayloadValidator.validateEmailDraft`); nothing sends mail.
5. Extend `WalkServiceTest`/`walks.test.mjs`/Playwright with SUM-01..09 and keep `npm test` green.

## Phase 0-4 correction session (audit findings)

A correction-only session against commit `4b0bb3f`. No Phase 5 work was started and
`docs/PHASE_5_IMPLEMENTATION_BRIEF.md` was not read. The existing
controller/service/repository/snapshot/visibility architecture is unchanged; every change is a
targeted correction inside it.

### Audit findings confirmed and corrected

1. **Create replay authorization.** `WalkService.loadDto` took a `skipAuthorization` argument it
   never read, and the create path replayed a recorded mutation with no record-level check at all
   (`replay(recorded, principal, "CREATE", "")` passed an empty walk id, so even the
   actor/action/target comparison could not bind it to a walk). A mutation id recorded at School A
   could therefore be replayed by a principal who had since lost School A but kept School B, and the
   School A walk was returned. `replay()` now re-authorizes the recorded walk through
   `AuthorizationService.authorizeWalk` **before** anything is compared or returned (a stale or
   forged id answers 404, exactly as opening that walk would), and only then checks actor, action,
   target, and content. The `skipAuthorization` parameter is gone.
2. **Server-authoritative hidden value retention.** The save path validated and normalized only what
   the browser submitted, then wrote the difference against the persisted rows, so a hidden value the
   browser did not resubmit was deleted and a hidden value a crafted client did submit was written.
   The merge now happens inside the locked transaction against the persisted state
   (`mergeRetainedHidden`): visibility is derived from the pinned instrument, a value hidden under the
   submission is taken from the database, a value that was hidden and is omitted reappears from the
   database, and visible keys stay whole-state so CLEAR still clears. `NOT_APPLICABLE` is unchanged
   (ratings cleared, notes kept, Yes returns them as `UNANSWERED`). No test was changed to echo
   hidden data.
3. **Mandatory mutation/concurrency envelope.** `clientMutationId` was optional on create and void,
   and `rowVersion` was optional on void. All four routes now require `clientMutationId`; save,
   complete, and void require `rowVersion`; create does not. Malformed tokens (including a JSON
   number where a string belongs) are 400 before any write, and a stale void is 409 with the walk's
   status and row version unchanged. `docs/ENDPOINTS.md` and `app/assets/js/walk-store.js` follow the
   corrected contract.
4. **Complete idempotency.** Mutation ids were bound to actor, action, and walk but not to content,
   so the same id could replay a materially different request; and a create retried after a newer
   version was published was refused with `INSTRUMENT_VERSION_CHANGED` before the replay lookup ran,
   stranding the committed walk. Migration `004_mutation_fingerprint.sql` adds
   `walk_mutation.request_fingerprint` (SHA-256 over canonical JSON of the action, the target, and the
   semantic body -- never the concurrency token, the mutation id, the client clock, or the requested
   version id). The recorded-mutation lookup now runs before the version check on create. In the
   browser, transport failures and HTTP 5xx are treated as ambiguous: create, save, complete, and
   void keep their operation id and their exact payload until a definitive success or a definitive,
   non-retryable 4xx. Transaction atomicity is unchanged -- the mutation row is still written in the
   same transaction as the change.
5. **Autosave/navigation data loss.** `backToList()` saved, awaited the in-flight promise, and then
   navigated regardless of the outcome, so a failed, conflicted, or ambiguous save was abandoned; and
   `beforeunload` guarded `app.dirty` only, which is already false while a save is in flight. The
   editor now tracks one pending state (dirty, debounce queued, in-flight, ambiguous failure, failed
   save, unresolved conflict). Internal navigation either completes the save, retains the editor with
   the unsaved input, or requires an explicit discard through an `alertdialog`; `beforeunload` reads
   the same state. Nothing is written to `localStorage`.
6. **School/org consistency.** Nothing bound `walk.org_unit_id` to the School dimension, so a walk
   authorized at School A could be labelled School B or "Other". The authorized active SCHOOL org
   unit is now authoritative: where the pinned instrument defines a School value whose code equals the
   unit's `org_unit_code` the server fills and locks it and refuses any other value (409
   `SCHOOL_ORG_MISMATCH`, audited, nothing written); where no value matches the unit nothing is
   invented, but a value naming a different active SCHOOL org unit is still refused. District-scoped
   users create at authorized descendant SCHOOL units as before. No district-level walk semantics were
   invented, because `docs/PRODUCT_SPEC.md` defines none.
7. **ICFWALK instrument scoping.** `currentVersion()` selected the newest PUBLISHED version of *any*
   active instrument with no effective window, and `discardDraft()` resolved a version by label alone
   (it looked the ICFWalk instrument up and then never used it). Selection is now scoped to
   `ICFWALK_INSTRUMENT_CODE` with `effective_start <= SYSUTCDATETIME()` and
   `effective_end IS NULL OR effective_end > SYSUTCDATETIME()`; the development-only DRAFT preview is
   scoped to the same instrument. Draft discard resolves `(instrument_id, version_label)` and accepts
   an explicit `instrumentCode`.
8. **Related integrity fixes.**
   - **Runtime snapshot checksum**: every uncached load re-computes SHA-256 over the stored canonical
     UTF-8 snapshot and compares it with `checksum_sha256`; a mismatch or a missing digest fails
     closed (nothing parsed, nothing cached, `INSTRUMENT_SNAPSHOT_CHECKSUM_MISMATCH` /
     `INSTRUMENT_SNAPSHOT_CHECKSUM_MISSING`).
   - **Completed-walk no-op saves**: `persistState` was split into `planState` (a dry run) and
     `applyPlan`, so an identical save to a COMPLETED walk appends no revision and does not advance
     the row version, while a material change still appends exactly one `POST_COMPLETION_EDIT`
     revision and one aggregate update.
   - **Visit Date clearing**: `observed_at` follows the Visit Date dimension and falls back to the
     walk's immutable `created_at` when it is absent or cleared (`WalkRepository.touchWalk`).
   - **Strict whole-state payload**: both root containers are required on a save (a create may omit
     both but never one), JSON primitive types are checked against the underlying Java type rather
     than coerced by CFML, and a client-asserted response `state` is refused with
     `CLIENT_STATE_NOT_ACCEPTED`.

### Findings recorded rather than changed

- **Client-asserted response state** was already impossible to honour: the Phase 4 validator rejected
  any unknown value field, so `state` never reached persistence. The audit's concern is real as a
  contract question, not as a defect, so the rejection was given its own code and message
  (`CLIENT_STATE_NOT_ACCEPTED`) and the documented payload example in `docs/DATA_CONTRACT.md` was
  corrected to drop `state` (it had shown a field the server has never accepted). This resolves the
  source conflict recorded as Phase 4 decision 12.
- **District-level walk semantics** were not invented. The audit asked for School/org consistency;
  `docs/PRODUCT_SPEC.md` defines walks at schools and says nothing about walks recorded against a
  DISTRICT org unit, so those are left exactly as they were: no School value is filled, and none is
  refused.
- **Deployments whose org-unit codes are not aligned with the instrument's school list** cannot have
  a School value filled for them, because there is nothing to fill. Rather than refuse every such
  walk (which would break any deployment that has not aligned its codes), the server refuses only a
  School value that names a *different* active SCHOOL org unit. `config/org-units.example.json`
  generates aligned codes, so an aligned deployment gets the full fill-and-lock behaviour.

### Files created or changed (correction session)

Created: `database/004_mutation_fingerprint.sql`, `tests/cfml/specs/WalkCorrectionTest.cfc`,
`tests/cfml/specs/WalkSchoolScopeTest.cfc`, `tests/cfml/specs/InstrumentScopeTest.cfc`.

Changed: `src/walks/WalkService.cfc` (replay authorization and content binding, in-transaction merge,
plan/apply split, school scope, envelope, `observed_at`), `src/walks/WalkRepository.cfc` (fingerprint
column, `observed_at` fallback), `src/walks/WalkPayloadValidator.cfc` (JSON primitive types, root
containers, client state), `src/instrument/SnapshotService.cfc` (instrument scope, effective window,
checksum verification), `src/instrument/InstrumentImportService.cfc` (draft discard scope),
`src/controllers/MaintenanceController.cfc`, `src/config/ConfigLoader.cfc` (`ICFWALK_INSTRUMENT_CODE`,
`ICFWALK_SCHOOL_DIMENSION_CODE`), `src/Bootstrap.cfc`, `src/views/shell.html` (unsaved-work dialog),
`app/assets/js/app.js` (pending state, navigation guard, ambiguous-failure handling, operation-id
retention), `app/assets/js/walk-store.js`, `scripts/db/apply-schema.mjs`, `.env.example`,
`database/README.md`, `docs/ENDPOINTS.md`, `docs/DATA_CONTRACT.md`, `docs/LOCAL_SETUP.md`,
`docs/ACCEPTANCE_TRACKING.md`, `manifest.json`, `tests/cfml/support/Fixtures.cfc`,
`tests/cfml/specs/WalkServiceTest.cfc`, `tests/cfml/specs/SnapshotServiceTest.cfc`,
`tests/node/walks.test.mjs`, `tests/node/browser-persistence.test.mjs`,
`tests/node/db-scripts.test.mjs`, `tests/node/schema-contract.test.mjs`.

### Migration added

`database/004_mutation_fingerprint.sql` -- additive, idempotent, SQL Server 2016 compatible. Adds
nullable `icf.walk_mutation.request_fingerprint char(64)`, a check constraint restricting it to a
lower-case 64-character hexadecimal digest (or NULL), and
`IX_walk_mutation_actor_action`. Rows written before the patch keep their original
actor/action/target binding. The statements that reference the new column run through `sp_executesql`
because the supplied scripts contain no `GO` separators and deferred name resolution does not cover a
column added earlier in the same batch.

### Tests and results (correction session)

Environment as before (Lucee 6.2.8 on Jetty, SQL Server 2022 Developer in Docker, Node 22.22,
Playwright 1.56 with the pre-installed Chromium, axe-core 4). The Phase 4 baseline was reproduced in
this environment before any change: 68/68 Node tests with the one known
`docs/DATA_CONTRACT.md` manifest mismatch failing PKG-01, and 106/106 CFML specs.

| Command | Result |
| --- | --- |
| `npm test` (full regression, once, `docs/evidence/correction-npm-test.txt`) | 75/75 pass, 0 skipped: the Phase 1-4 suites plus 3 walk HTTP cases and 3 browser cases added here |
| CFML suite via `/api/maintenance/tests/run` (inside `npm test`) | 131 passed, 0 failed, 0 skipped (Phase 4's 106 plus `WalkCorrectionTest` 17, `WalkSchoolScopeTest` 4, `InstrumentScopeTest` 4) |
| Targeted runs during implementation | `?filter=WalkService` (x4), `?filter=WalkCorrection` (x3), `?filter=WalkSchoolScope` (x2), `?filter=InstrumentScope` (x2), `?filter=Walk`, `node --test tests/node/{walks,browser,browser-persistence,db-scripts,schema-contract}.test.mjs` |
| `node scripts/db/apply-schema.mjs --only 004` | applied, then re-applied without error (idempotent) |
| `node scripts/refresh-manifest.mjs` then `node scripts/validate-handoff.mjs` | manifest reconciled for `database/README.md` and `docs/DATA_CONTRACT.md` after documentation was final; validator ok, 51 checks, 0 errors |

Every correction carries at least one regression test that fails against the prior behaviour. The
DATA_CONTRACT/manifest mismatch carried since Phase 4 is resolved: the two supplied documents that
this session deliberately corrected were re-hashed through `scripts/refresh-manifest.mjs`, which only
updates entries that already exist, so the manifest still describes exactly the supplied package.

### Unresolved defects or blockers (correction session)

None open. External items unchanged (Adobe ColdFusion 2023 environment, identity gateway details,
district org-unit codes, content-owner wording for the 17 placeholders, the content-area heading
decision from Phase 3).

### CF2023 verification items (correction session additions)

- `isInstanceOf(value, "java.lang.String" | "java.lang.Number" | "java.lang.Boolean")` against values
  from Adobe's `deserializeJSON` (`WalkPayloadValidator.jsonString/jsonNumber/jsonBoolean`,
  `WalkService.isJsonString`). Lucee and Adobe both box JSON primitives as Java types, but the strict
  checks are the one place where a difference would change behaviour: re-run `WalkCorrectionTest` on
  ColdFusion.
- `EXEC sp_executesql` inside the `BEGIN TRY` block of `004_mutation_fingerprint.sql` through the
  Adobe SQL Server driver (the script is applied by tooling here, not by CFML).
- `UPDATE ... SET observed_at = created_at` in the same statement as `updated_at = SYSUTCDATETIME()`
  (`WalkRepository.touchWalk`).
- `hash(text, "SHA-256", "UTF-8")` over a `nvarchar(max)` snapshot read through the Adobe driver
  (`SnapshotService.loadEntry`): the digest must match the one the importer computed.
- The browser navigation guard and `beforeunload` behaviour on the ColdFusion deployment
  (`npm run test:browser`).

## Second Phase 0-4 correction session (independent verification audit)

A correction-only session against commit `b862af9`. No Phase 5 work was started and
`docs/PHASE_5_IMPLEMENTATION_BRIEF.md` was not read. The controller/service/repository/snapshot/
visibility architecture is unchanged, and every behavior the first correction session established is
preserved except where a finding below required it to change.

A second independent verification audit confirmed most of the first correction set and raised four
remaining mutation/data-integrity findings. Each was verified against the current code before
anything was changed. **All four were confirmed; none was rejected.**

### 1. Replay / rowversion coherence (confirmed)

`WalkService.replay()` ended in `loadDto(recorded.walkId, principal)`, which reads the walk as it
stands *now* -- including its current row version -- while the retrying session still held the local
state that went with the *original* mutation. The browser adopted it (`walk.rowVersion = saved.rowVersion`
with `app.baseline` set to its own replayed payload), so an old successful SAVE retried after a later
successful save gave stale local state a live concurrency token, and that session's next save
overwrote the newer work with no conflict at all.

**Correction.** The replay now proves coherence before returning anything. Every action already
records the row version it committed in its own mutation result, so `replay()` compares that recorded
token with the walk's current row version:

- **equal** -- the aggregate still stands where the mutation left it, so the recorded outcome is
  coherent and is replayed exactly as before (the ambiguity-recovery path is unchanged);
- **different** -- the aggregate has advanced, so the replay is refused with 409
  `MUTATION_REPLAY_SUPERSEDED` (audited `WALK_MUTATION_SUPERSEDED`, nothing written). The client is
  told its mutation did commit and that the walk has changed since, so it must reload and reconcile.
  The details carry the **recorded** row version and never the current one, so nothing in the answer
  can be used to overwrite newer work; a save with the recorded token is refused as
  `STALE_ROW_VERSION`, as it should be.

A recorded result with no usable row version is treated as incoherent rather than guessed. In the
browser, `MUTATION_REPLAY_SUPERSEDED` is a definitive outcome: a save enters the existing conflict
panel, and a create, completion, or void reloads what the server holds.

**Invariant:** an idempotent replay never pairs stale client state with a row version representing
newer server state.

### 2. School dimension integrity with unaligned org codes (confirmed)

The first correction bound the School dimension to the walk's org unit through code equality
(`compare(v.valueCode, unit.code) == 0`). For a SCHOOL unit whose code matched no instrument School
value, `expected` was empty and the only remaining refusal was a value that resolved through
`findByCode` to a *different* active SCHOOL org unit. So in a deployment with two such units, any
instrument School value -- including the free-text "Other" -- was accepted at either, and a walk
authorized at School A could be stored carrying School B's School value. The prior spec
`WalkSchoolScopeTest.testUnmappedSchoolUnitStillRefusesAnotherSchoolsLabel` asserted exactly that
acceptance, so its expectation was corrected rather than preserved.

**Correction.** Migration `005_org_unit_dimension_map.sql` adds `icf.org_unit_dimension_map`: an
explicit, stored, validated mapping from a SCHOOL org unit to the instrument School dimension value
that names it. Two constraints carry the invariant structurally rather than procedurally --
`PRIMARY KEY (org_unit_id, dimension_code)` (one unit, at most one School value) and
`UNIQUE (dimension_code, value_code)` (one School value, at most one unit, so School B's value is
never available to School A). `source` records provenance: `EXPLICIT` or `CODE_ALIGNED`.

At walk time `enforceSchoolScope` reads only the stored row and re-validates its `value_code` against
the walk's **pinned** version. A mapped unit is filled and locked and any other value, "Other"
included, is 409 `SCHOOL_ORG_MISMATCH`. An unmapped unit -- or one whose mapped value the pinned
version does not define -- **fails closed**: nothing is filled and any submitted School value is 409
`SCHOOL_ORG_UNMAPPED` (audited `WALK_SCHOOL_SCOPE_UNMAPPED`). Nothing is ever inferred from a display
name, and code equality alone maps nothing: a unit whose `org_unit_code` *is* an instrument School
value still fails closed until a row exists for it.

Operators declare the mapping through `schoolValueCode` on a SCHOOL unit in the org-unit import
(`EXPLICIT`), or derive it for an already-aligned deployment with the new
`POST /api/maintenance/org-units/align-school-dimension` (`CODE_ALIGNED`), which reports every unit
it could not map and supports `{"dryRun": true}`. That endpoint is the only place an org-unit code is
ever compared with a dimension value code, it runs only when an operator asks, and what it produces
is a stored row the walk path reads. A district-authorized user still creates at any authorized
descendant SCHOOL; the School value follows that unit's mapping.

Two consequences follow, and both were implemented rather than left to break:

- The editor no longer offers the School dimension as a control at a SCHOOL org unit. The walk DTO
  carries `lockedDimensions`, the renderer draws those placements read-only with the note "Set from
  the school this walk is recorded at.", and `applyEditability` keeps them read-only however editable
  the walk is. Offering a choice the server must refuse would be a trap.
- `applyOrgUnitDefaults` -- the browser's own code-equality guess, which preselected a School value
  whose code equalled the org unit code -- is removed. It is the same coincidence the server refuses
  to treat as identity, and after this correction it would have made every create at an unmapped
  lookalike unit fail. The create sends the engine's blank state and the server assigns the value.

### 3. Ambiguous browser mutation operations (confirmed)

Three separate defects: `app.completeMutationId` was a single scalar, not scoped per walk (and
`openWalk` cleared it unconditionally), so an unresolved completion on walk X could be sent against
walk Y; the void retry rebuilt its request from the live inputs (`reason.value`, `walk.rowVersion`)
rather than from what it first sent, so a retry after an edited reason was a different request and was
refused; and `hasUnsavedWork()`/`beforeunload` covered only editor save state, so an ambiguous create,
completion, or void could be abandoned silently by navigation or reload.

**Correction.** One registry of immutable operation records (`app.ops`, keyed `ACTION:target`), which
`CREATE`, `SAVE`, `COMPLETE`, and `VOID` all use. A record holds the action, the target (the org unit
for a create, the walk for everything else), the `clientMutationId`, the deep-frozen semantic body,
the `rowVersion` it was issued against, and `PENDING`/`AMBIGUOUS` status. It is created once and never
rebuilt from later UI state; a retry after a transport failure or an HTTP 5xx reuses it exactly. It is
released only on a definitive outcome or an explicit decision by the user to abandon it. Because the
key names the target, a `COMPLETE` id can never cross walks. The void reason field is made read-only
while its record is unresolved and the retry sends the record's reason. Pending records are unsaved
work: `pendingState().operations` counts those on the open walk, and `beforeunload` reads a guard that
also covers the list view, so an ambiguous create or void started from My Walks cannot be lost to a
reload. `app.ambiguous` and `app.pendingMutationId` are gone, replaced by the save's own record; the
save lifecycle (debounce, coalescing, conflict handling, discard) is otherwise unchanged.

### 4. Legacy NULL mutation fingerprints (confirmed)

`replay()` computed `fingerprintMismatch = len(recorded.fingerprint) && ...`, so a row written before
migration `004` -- whose `request_fingerprint` is NULL -- could never mismatch and replayed as an
ordinary success, although nothing recorded about it can prove the new request is the request it
committed.

**Correction.** The replay checks now run in a fixed order, each a precondition of the next:
authorization, then actor/action/target, then provenance, then the fingerprint, then coherence. A row
with no fingerprint is never returned as a successful replay: it answers 409
`MUTATION_LEGACY_UNVERIFIABLE` deterministically (audited `WALK_MUTATION_LEGACY_UNVERIFIABLE`, no
application state written), and an exact-looking retry and an altered one get the same answer because
they are genuinely indistinguishable against a NULL fingerprint. Nothing is fabricated or backfilled:
the stored outcome cannot reconstruct the original semantic request. Because authorization runs first,
a principal who may no longer see the walk gets 404 and never learns that the id, the walk, or a
legacy row exists.

### Files created or changed (second correction session)

Created: `database/005_org_unit_dimension_map.sql`, `tests/cfml/specs/WalkReplayCoherenceTest.cfc`,
`docs/evidence/correction2-npm-test.txt`.

Changed: `src/walks/WalkService.cfc` (replay order, coherence and legacy checks, mapping-based school
scope, `lockedDimensions`), `src/walks/WalkRepository.cfc` (`org_unit_type` on walk rows),
`src/authorization/OrgUnitRepository.cfc` (mapping accessors), `src/controllers/MaintenanceController.cfc`
(`schoolValueCode` on import, `alignSchoolDimension`, fixture cleanup), `src/http/Router.cfc`,
`app/assets/js/app.js` (operation records, navigation/unload guard, superseded/legacy handling, no
client-side school default), `app/assets/js/walk-store.js` (`lockedDimensions`),
`app/assets/js/renderer.js` (read-only server-owned placements), `app/assets/js/walk-state.js`
(`applyOrgUnitDefaults` removed), `app/assets/css/icfwalk.css`, `scripts/db/apply-schema.mjs`,
`database/README.md`, `docs/DATA_CONTRACT.md`, `docs/ENDPOINTS.md`, `docs/LOCAL_SETUP.md`,
`docs/ACCEPTANCE_TRACKING.md`, `manifest.json`, `tests/cfml/support/Fixtures.cfc`,
`tests/cfml/specs/WalkSchoolScopeTest.cfc`, `tests/cfml/specs/WalkServiceTest.cfc`,
`tests/node/walks.test.mjs`, `tests/node/browser.test.mjs`,
`tests/node/browser-persistence.test.mjs`, `tests/node/visibility.test.mjs`,
`tests/node/schema-contract.test.mjs`, `tests/node/db-scripts.test.mjs`.

### Migration added (second correction session)

`database/005_org_unit_dimension_map.sql` -- additive, idempotent, SQL Server 2016 compatible. Creates
`icf.org_unit_dimension_map` and touches no existing object or row. It derives nothing on its own: a
deployment declares `schoolValueCode` per SCHOOL unit in the org-unit import, or runs
`POST /api/maintenance/org-units/align-school-dimension` once. Until a unit is mapped, walks there
carry no School value and a submitted one is refused, which is the intended fail-closed state.

### Tests and results (second correction session)

Environment as before (Lucee 6.2.8 on Jetty, SQL Server 2022 Developer in Docker, Node 22.22,
Playwright 1.56 with the pre-installed Chromium, axe-core 4). The first correction session's baseline
was reproduced in this environment before any change: 75/75 Node tests and 131/131 CFML specs.

| Command | Result |
| --- | --- |
| `npm test` (full regression, once, `docs/evidence/correction2-npm-test.txt`) | 86/86 pass, 0 skipped (75 before, plus 6 walk HTTP cases and 4 browser cases added here and one renamed) |
| CFML suite via `/api/maintenance/tests/run` (inside `npm test`) | 139 passed, 0 failed, 0 skipped (131 before, plus `WalkReplayCoherenceTest` 6 and two more `WalkSchoolScopeTest` cases) |
| Targeted runs during implementation | `?filter=Walk` (x4), `?filter=WalkService` (x2), `?filter=WalkReplay`, `node --test` on `walks`, `browser`, `browser-persistence`, `visibility`, `schema-contract`, `db-scripts` (several each) |
| `node scripts/db/apply-schema.mjs --only 005`, then the whole set again | applied, then re-applied without error (idempotent); `db-scripts.test.mjs` applies every script twice against a throwaway database |
| `node scripts/refresh-manifest.mjs` then `node scripts/validate-handoff.mjs` | manifest reconciled for `database/README.md` and `docs/DATA_CONTRACT.md` after documentation was final; validator ok, 51 checks, 0 errors |

Every correction carries regression coverage at the levels the audit asked for: service
(`WalkReplayCoherenceTest`, `WalkSchoolScopeTest`, `WalkServiceTest`), HTTP (`walks.test.mjs`), and
browser/two-session (`browser-persistence.test.mjs`, `browser.test.mjs`). The tests assert database
rows, mutation rows, row versions, audit events, browser DOM state, and operation ids directly rather
than re-running the production algorithm. No existing test was weakened: two expectations changed
because the behavior they described was the defect (`WalkSchoolScopeTest`'s acceptance of an arbitrary
School value at an unmapped unit, and `WalkServiceTest`'s assertion that a superseded replay still
returned a usable row version), and the browser cases that drove the School dimension from the UI now
drive it from the walk's org unit, which is where it comes from.

### Unresolved defects or blockers (second correction session)

None open. External items unchanged (Adobe ColdFusion 2023 environment, identity gateway details,
district org-unit codes **and their School dimension mappings**, content-owner wording for the 17
placeholders, the content-area heading decision from Phase 3).

### CF2023 verification items (second correction session additions)

Everything recorded for Phase 0-4 and the first correction session still applies. New items:

- `CREATE TABLE` with a composite `PRIMARY KEY CLUSTERED` plus a second `UNIQUE` constraint inside the
  single-batch `BEGIN TRY` of `005_org_unit_dimension_map.sql` through the Adobe SQL Server driver
  (the script is applied by tooling here, not by CFML).
- The `ICFWalk.Validation` raised from `OrgUnitRepository.upsertDimensionMapping` when a value is
  already claimed, and the `UNIQUE` violation behind it, through the Adobe driver: re-run
  `WalkSchoolScopeTest` and the org-unit import cases on ColdFusion.
- `o.org_unit_type` added to the walk `SELECT` under `WITH (UPDLOCK, ROWLOCK)` (`WalkRepository.findWalk`).
- The read-only School placement, the operation-record lifecycle, and the navigation/`beforeunload`
  guard on the ColdFusion deployment (`npm run test:browser`).

## Third Phase 0-4 correction session (residual defects)

Correction-only session against three residual defects reported in commit `d4635b7`. Each was
reproduced against the code before anything changed, and every regression added here was run against
the unfixed code first and observed to fail, so none of them can pass vacuously. The
controller/service/repository/snapshot/visibility architecture is unchanged, no broader refactoring
was done, and Phase 5 was not started (`docs/PHASE_5_IMPLEMENTATION_BRIEF.md` was not read).

### 1. Replay coherence is now atomic

`WalkService.replay` compared the mutation's recorded row version against an **unlocked** read and
then built the DTO from further unlocked reads. A save committing between the two made a replay that
had just been judged coherent return the newer aggregate and the newer row version to a session still
holding the state that went with the original mutation -- the exact stale-state-with-a-live-token
pairing the comparison exists to prevent.

- The comparison and the aggregate materialization now happen inside one transaction that holds the
  walk mutation lock (`WalkRepository.findWalk(id, true)`, `WITH (UPDLOCK, ROWLOCK)`), which is the
  lock every normal mutation path already takes before it writes, so no save, completion, or void can
  interleave between them.
- `loadDto` accepts the locked header row, so the DTO is built from the row that was compared rather
  than from a later read of it.
- The row version is re-asserted under the same lock after materialization. If either check fails the
  answer is 409 `MUTATION_REPLAY_SUPERSEDED` and no DTO leaves: the returned aggregate always carries
  the row version the recorded mutation committed.
- The transaction stays read-only; the audit events (`WALK_MUTATION_REPLAYED`,
  `WALK_MUTATION_SUPERSEDED`) are written outside it, as the existing conflict paths do, so a refusal
  is not rolled back with the read.

The regression (`WalkReplayCoherenceTest.testAConcurrentSaveCannotLandBetweenTheCoherenceCheckAndTheDto`)
forces the interleaving rather than hoping for it. A decorating repository
(`tests/cfml/support/InterceptingWalkRepository.cfc`) fires a callback at the DTO's first aggregate
read -- the precise point that used to follow the comparison -- and that callback starts a real second
session saving the same walk and waits for it, bounded. The test asserts the concurrent save is still
running (held by the lock, not merely slow), that the replay returns the row version and the state its
mutation committed, that the deferred save lands afterwards, and that the token the replay returned is
then refused as stale. `testASupersededReplayNeverMaterializesTheNewerAggregate` proves a superseded
replay refuses without reading the aggregate at all. Against the unfixed `replay`, the first test
fails with the concurrent save observed `COMPLETED` inside the window.

### 2. A value that identifies nothing is never an identity

The School dimension allows free text, so it defines a value coded `other` meaning "none of these,
see the typed text". Every "is this a School value?" check said yes, so it could be stored as a
school's identity -- labelling that school's walks "Other" and, because `icf.org_unit_dimension_map`
is unique on (dimension, value), taking a value that names no school away from every other school.

- `OrgUnitRepository.upsertDimensionMapping` refuses a non-identifying value outright
  (`ORG_UNIT_DIMENSION_VALUE_NOT_IDENTIFYING`). It is the only writer, so no route can store one.
- Migration `005` adds `CK_org_unit_dimension_map_identifying`, so no script or hand-written statement
  can either. The patch converges an existing installation: it removes any non-identifying row, reports
  how many in `non_identifying_rows_removed`, and adds the constraint only when it is absent. It stays
  idempotent and drops nothing else.
- `schoolValueCode: "other"` in the org-unit import is 400 `ORG_UNIT_SCHOOL_VALUE_NOT_IDENTIFYING`,
  raised with the operator-facing reason before the repository's blanket guard is reached.
- `POST /api/maintenance/org-units/align-school-dimension` no longer persists from code equality.
  It reports `candidates[]` and writes only the (orgUnitCode, valueCode) pairs an operator sends back
  in `confirm[]`; each is re-derived and re-validated first, and `refused[]` says why any was not
  written (`NOT_A_CANDIDATE`, `CONFIRMATION_DOES_NOT_MATCH_CANDIDATE`). A unit coded `other` is
  reported `NON_IDENTIFYING_VALUE_CODE` and is never a candidate. Maintenance authorization is
  unchanged (`maintenanceGuard.require` still runs first, before anything is read).
- What is stored is the instrument's spelling of the value code, never the org unit's. The candidate
  search matches codes case-insensitively but the walk path compares them case-sensitively, so storing
  the unit's form would have written a mapping that could never match again.

A SCHOOL unit left without an identifying value stays unmapped, which the walk path already handles by
failing closed: nothing filled, nothing accepted, nothing written.

### 3. A sent browser operation is never deleted by an editor change

The operation registry had one `PENDING` status covering both "minted, nothing sent" and "request on
the wire". An editor change during an in-flight save therefore deleted the record whose request had
already been sent; when that answer was lost there was nothing left to retry, so the committed save was
never confirmed and the queued newer state went out under a brand-new id against a row version the
server had already moved past.

- The status is now `UNSENT` / `IN_FLIGHT` / `AMBIGUOUS`. `markOpSent` is called immediately before
  each request is dispatched, and only an `UNSENT` record may be replaced by a newer payload.
- An edit during an in-flight save queues behind it. If that save's answer is lost, the browser retries
  the **original** request first -- same `clientMutationId`, same `rowVersion`, same frozen semantic
  body -- and only once it resolves definitively does the queued newer state go out under a new id,
  against the row version the retry settled on.
- Reloading a walk from the server releases an `UNSENT` save record but keeps a sent one: a reload
  cannot tell whether the server committed it.
- Ambiguous operations no longer depend on the control that started them. A void's confirmation row is
  destroyed by the next list render and a completion's button is hidden as soon as the walk is reloaded
  and turns out to have been completed, either of which used to strand the record behind a permanent
  unload guard. The browser now renders an unfinished-operations bar from the registry itself, outside
  both views (`#pending-ops`), giving every unresolved operation a retry that re-sends its exact frozen
  request and an explicit "stop trying". A record can no longer outlive every way to resolve it.

### Files changed (third correction session)

- `src/walks/WalkService.cfc` -- atomic, locked replay coherence and materialization; `loadDto` takes a
  pre-loaded header row.
- `src/authorization/OrgUnitRepository.cfc` -- `isIdentifyingValueCode`, and the refusal in
  `upsertDimensionMapping`.
- `src/controllers/MaintenanceController.cfc` -- non-identifying refusal and canonical storage in
  `mapSchoolValue`; candidate-reporting, per-pair-confirmed `alignSchoolDimension` plus
  `confirmationsOf`.
- `database/005_org_unit_dimension_map.sql` -- `CK_org_unit_dimension_map_identifying` and its
  convergence block.
- `app/assets/js/app.js` -- `UNSENT`/`IN_FLIGHT`/`AMBIGUOUS`, `markOpSent`, the narrowed
  `discardPendingOp`, the preserved sent save in `openWalk`, `renderPendingOps`, `resolveAmbiguousOp`,
  `refreshAfterResolvedOp`.
- `src/views/shell.html`, `app/assets/css/icfwalk.css` -- the unfinished-operations bar.
- `tests/cfml/support/InterceptingWalkRepository.cfc` (new), `tests/cfml/specs/WalkReplayCoherenceTest.cfc`,
  `tests/cfml/specs/WalkSchoolScopeTest.cfc`, `tests/node/walks.test.mjs`,
  `tests/node/browser-persistence.test.mjs`, `tests/node/schema-contract.test.mjs`.
- `docs/DATA_CONTRACT.md`, `docs/ENDPOINTS.md`, `docs/LOCAL_SETUP.md`, `docs/ARCHITECTURE.md`,
  `docs/ACCEPTANCE_TRACKING.md`, `manifest.json`.

### Unresolved defects or blockers (third correction session)

None open. External items unchanged (Adobe ColdFusion 2023 environment, identity gateway details,
district org-unit codes and their School dimension mappings, content-owner wording for the 17
placeholders, the content-area heading decision from Phase 3).

### CF2023 verification items (third correction session additions)

Everything recorded earlier still applies. New items:

- The nested read-only `transaction` in `WalkService.replay` under the Adobe SQL Server driver,
  specifically that `WITH (UPDLOCK, ROWLOCK)` held for the whole block serializes a concurrent save
  there as it does on Lucee: re-run `WalkReplayCoherenceTest` on ColdFusion.
- `cfthread` inside a closure, used only by that spec to force the interleaving, on the Adobe engine.
- `ALTER TABLE ... ADD CONSTRAINT` guarded by `sys.check_constraints` inside the single-batch
  `BEGIN TRY` of `005_org_unit_dimension_map.sql` (the script is applied by tooling here, not CFML).
- The unfinished-operations bar and the `UNSENT`/`IN_FLIGHT` record lifecycle on the ColdFusion
  deployment (`npm run test:browser`).

## Fourth correction session (browser operation recovery)

Correction-only session against the two residual browser recovery defects reported against commit
`7f7c86a`. Both were reproduced against the code before anything changed, and all nine regressions
added here were run against the unfixed `app/assets/js/app.js` first and observed to fail, so none
of them can pass vacuously. No server, schema, migration, authorization, or instrument code was
touched; the verified replay/row-version coherence and "other" org-unit identity protections are
unchanged, and Phase 5 was not started.

### Recovery never discards newer editor work (CORR4-01)

Resolving an ambiguous `CREATE`, `COMPLETE`, or `VOID` reloaded or switched the editor
unconditionally, and `openWalk` cancels the scheduled save, replaces the editor state with the
server copy, and clears `dirty`. A change typed after the operation went ambiguous was therefore
lost the moment the user pressed Retry, inside the 700 ms before its own autosave had been
dispatched.

- `editorHoldsNewerWork()` is the single test recovery reads before it reloads, replaces, or leaves
  an editor: dirty, a debounced save, a save on the wire, a definitively failed save, an unresolved
  conflict, or any `SAVE` record still pending for the open walk.
- A resolved `COMPLETE` on that editor adopts the resolved aggregate's **metadata only**
  (`adoptResolvedWalk`): status, the row version the replay proved it still stands at, and the
  stamps that go with it. The state on screen is never touched, so the waiting autosave goes out
  against the right concurrency token and carries the newer edit through with no conflict.
- A resolved `CREATE` leaves the open editor alone and says the walk is waiting in My walks.
- A resolved `VOID` asks before it takes the editor away. Staying keeps the text on screen under a
  live unsaved-work guard; the server's 409 `WALK_VOIDED` on the next save is the definitive answer
  that asks the question again.
- `saveCurrent` settles its record from the save's own outcome — `settleOp` on success and on a
  definitive 4xx, `markOpAmbiguous` on an ambiguous one — before any editor check. The early return
  on `app.current !== walk` used to leave the record `IN_FLIGHT` for good: unfinished work the
  unload guard sees, on an operation the recovery bar never lists. Only the editor-facing work and
  the rescheduling are skipped when the editor has moved on.

### Recovery retries are not re-entrant (CORR4-02)

An ambiguous operation stayed `AMBIGUOUS` for the whole of its retry round trip, so the Retry
control stayed live and a second activation dispatched the same mutation id again.

- `markOpSent` transitions `AMBIGUOUS` → `IN_FLIGHT` as well as `UNSENT` → `IN_FLIGHT`,
  synchronously before the request is created.
- `resolveAmbiguousOp` refuses an `IN_FLIGHT` record outright, and so do `startNewWalk`,
  `completeCurrent`, and the void confirmation (`opInFlight`).
- The recovery bar keeps a retrying record on screen with both controls disabled (`recoveryOps`,
  `data-op-status`), so "already retrying" is visible rather than the bar blinking out and back.
- An ambiguous outcome for the retry returns the record to `AMBIGUOUS` and restores the controls.
  Definitive failures, conflicts, and `MUTATION_REPLAY_SUPERSEDED` keep the existing contract.

### Files changed (fourth correction session)

- `app/assets/js/app.js` -- `markOpSent`, `markOpAmbiguous`, `recoveryOps`, `opInFlight`,
  `renderPendingOps`, `resolveAmbiguousOp`, `editorHoldsNewerWork`, `adoptResolvedWalk`,
  `refreshAfterResolvedOp`, `saveCurrent`, `startNewWalk`, `completeCurrent`, `confirmDelete`, and
  the recovery message constants.
- `tests/node/browser-persistence.test.mjs` -- the nine CORR4 regressions and their barriers
  (`holdFirst`, `until`, `editThenRetry`, `recoveryBar`).
- `BUILD_STATUS.md`, `docs/ACCEPTANCE_TRACKING.md`.

### Unresolved defects or blockers (fourth correction session)

None open. External items unchanged (Adobe ColdFusion 2023 environment, identity gateway details,
district org-unit codes and their School dimension mappings, content-owner wording for the 17
placeholders, the content-area heading decision from Phase 3).

### CF2023 verification items (fourth correction session additions)

Everything recorded earlier still applies. The changes are browser-side only, so nothing new depends
on the CFML engine; re-run `npm run test:browser` against the ColdFusion 2023 deployment to confirm
the recovery lifecycle behaves identically there.


## Fifth correction session (mutation response coherence)

Correction-only session against the single remaining Phase 0-4 freeze blocker reported against
commit `fa59b16`. The defect was reproduced against the code before anything changed: all five
regressions added here were run against the unfixed `src/walks/WalkService.cfc` first and observed
to fail (5 of 5), then against the corrected file and observed to pass (5 of 5). Raw evidence:
`docs/evidence/correction5-red-before-fix.txt`. No schema migration was needed, no browser code was
touched, and Phase 5 was not started.

### A successful SAVE or COMPLETE did not materialize its response atomically with its mutation (CORR5-01)

`save()` and `complete()` locked the walk, applied the mutation, recorded the resulting rowversion
and committed -- and only then called `loadDto()` to build the response, with the transaction over
and the walk mutation lock released. That leaves a window with no lock in it:

1. Session A saves M1 against R0.
2. A commits M1 and produces R1.
3. Before A constructs its response DTO, session B saves M2 against R1 and commits R2.
4. A's later `loadDto()` returns B's aggregate and R2.
5. The browser adopts the returned metadata but does not replace the editor state with
   `saved.state` (`app/assets/js/app.js::saveCurrent`), so A still holds what it sent as M1.
6. A now holds stale local state paired with the live R2 token, and its next whole-state save
   overwrites B without ever being told `STALE_ROW_VERSION`.

The correction is server-side and keeps the API response contract valid; adopting `saved.state` in
the browser was rejected as a fix because it would destroy newer editor work and would leave the
response itself incoherent.

- `mutationDto()` is the one place a successful, non-replay mutation response is built. It takes the
  walk header row the mutation's own result was minted from -- read after the write, under the same
  `findWalk(..., true)` lock -- so the rowversion, header, dimensions, responses, evaluation states
  and revision count all describe one serialized database state.
- `save()` and `complete()` call it **inside** their transaction and return the finished DTO through
  the transaction outcome (`outcome.dto`). Neither calls `loadDto()` after the commit any more.
- The successful no-op SAVE on an already completed walk takes the same path: "nothing changed" is a
  claim about a specific serialized state, so it is answered from that state.
- The DTO rowversion is re-asserted against the rowversion the mutation recorded rather than assumed.
  A mismatch throws and rolls the transaction back, so an incoherent response can never be served.
- The atomic replay implementation and `MUTATION_REPLAY_SUPERSEDED` are unchanged; `replay()` already
  materialized under the same lock (CORR3-01) and is a different code path.
- `create()` and `void()` were deliberately left alone: the work was scoped to SAVE and COMPLETE, and
  the shared helper did not require changing them. See the limitations note below.

### Files changed (fifth correction session)

- `src/walks/WalkService.cfc` -- new private `mutationDto()`; `save()` and `complete()` materialize
  inside the transaction and return `outcome.dto`; a `principal` local for the transaction closures;
  the save-semantics docblock gained point 4.
- `tests/cfml/support/InterceptingDb.cfc` (new) -- a test-only `Db` decorator whose
  `armAfterCommit(fn)` runs a one-shot callback at the exact instant a committed top-level
  transaction hands back to its caller.
- `tests/cfml/support/InterceptingWalkRepository.cfc` -- `countRevisions` promoted from a
  pass-through to a hooked seam (only response materialization reaches it).
- `tests/cfml/specs/WalkMutationResponseTest.cfc` (new) -- the five CORR5 regressions.
- `docs/DATA_CONTRACT.md` (the mutation response coherence rule, under "Build decisions recorded in
  Phase 4") and `manifest.json` refreshed for it; `docs/ACCEPTANCE_TRACKING.md`,
  `docs/LOCAL_SETUP.md`, `BUILD_STATUS.md`, `docs/evidence/correction5-red-before-fix.txt`,
  `docs/evidence/correction5-cfml-suite.txt`, `docs/evidence/correction5-npm-test.txt`.
- `docs/evidence/screenshots/*.png` -- regenerated by `npm run test:browser`, which rewrites them on
  every run.

No production test hook was added: both decorators live under `tests/` and are wired only by
constructing a `WalkService` with them in a spec.

### Tests and results (fifth correction session)

Runtime actually used: **Lucee 6.2.8.20 under Jetty, Microsoft SQL Server 2022 (Developer, Linux
container), Node 22.22.2, Playwright 1.56 with the pre-installed Chromium, axe-core 4.13.** Every
row below was executed in this session.

| Command | Result |
| --- | --- |
| JavaScript syntax checks (`node --check` over all 25 `.js`/`.mjs` files) | 25/25 parse |
| `npm run validate:handoff` | `{"ok": true, "checks": 51, "errors": 0}` |
| `npm run test:package` | 18/18 pass |
| `npm run test:db` | 1/1 pass |
| `npm run test:cfml` | 5/5 Node cases pass; CFML suite `passed=148 failed=0 skipped=0` (143 before, plus the 5 CORR5 specs) |
| `npm run test:auth` | 5/5 pass |
| `npm run test:shell` | 14/14 pass |
| `npm run test:walks` | 20/20 pass |
| `npm run test:browser` | 38/38 pass |
| `npm test` (full regression, `docs/evidence/correction5-npm-test.txt`) | 101/101 pass, 0 skipped; CFML suite `passed=148 failed=0 skipped=0` |
| Migration apply and reapply | `002`-`005` reapply cleanly (idempotent); `001_schema.sql` refuses a populated schema with "The icf schema already contains tables. No changes were made." — its documented guard, unchanged here |
| `node scripts/refresh-manifest.mjs` | Refreshed the one supplied package file this session edited (`docs/DATA_CONTRACT.md`, 27198 -> 28372 bytes); `npm run validate:handoff` and `npm run test:package` re-run green against the refreshed manifest |

The CFML suite total moved from 143 to 148: the five new specs, with no spec removed or weakened.

### Unresolved defects or blockers (fifth correction session)

None blocking the Phase 0-4 freeze. Deliberately out of scope and still open:

- The separately documented indefinitely hung `IN_FLIGHT` request behaviour remains a non-blocking
  deferred hardening item; it was not addressed here, as instructed.
- `create()` and `void()` still materialize their response after their transaction. Neither is the
  reported blocker and neither carries the same exposure — a `CREATE` returns a walk whose id no
  other session can yet know, and a `VOID` is terminal, so the next save is refused with
  `WALK_VOIDED` rather than being handed a usable token. They are candidates for the same treatment
  if that scope is ever opened.

External items unchanged (Adobe ColdFusion 2023 environment, identity gateway details, district
org-unit codes and their School dimension mappings, content-owner wording for the 17 placeholders,
the content-area heading decision from Phase 3).

### CF2023 verification items (fifth correction session additions)

Everything recorded earlier still applies. **Adobe ColdFusion 2023 and SQL Server 2016 were not used
in this session**; the verification above ran on Lucee 6.2.8.20 and SQL Server 2022. New items:

- `loadDto()` called from inside the mutation `transaction` block under the Adobe SQL Server driver:
  specifically that the reads it performs join the open transaction and see the uncommitted write,
  and that holding `WITH (UPDLOCK, ROWLOCK)` across them serializes a concurrent save as it does on
  Lucee. Re-run `WalkMutationResponseTest` on ColdFusion.
- The longer lock hold this introduces (the aggregate read now happens inside the write transaction)
  against production-sized walks on SQL Server 2016.
- `tests/cfml/support/InterceptingDb.cfc` calling a closure immediately after the decorated
  `transaction` block exits, on the Adobe engine.

## Phase 5: summary export and teacher email draft

Base: commit `d8f3736` (the frozen Phase 0-4 baseline, after the fifth correction session). No
Phase 0-4 behavior was reworked except one defect Phase 5 testing exposed (`app/index.cfm`, below);
every earlier test still passes.

The implementation brief (`docs/PHASE_5_IMPLEMENTATION_BRIEF.md`) was written at the end of Phase 4
against commit `0df22bc`. Its functional scope, resolved decisions, formatting contracts,
acceptance criteria and test requirements were followed as written; its starting commit and its
`68/68` / `106/106` baseline totals are historical and were superseded by the frozen baseline's
`101/101` and `148/148`, which this session reproduced before changing anything.

### Work completed

1. **One summary formatting contract, implemented twice.** `src/walks/WalkSummaryFormatter.cfc` and
   `app/assets/js/summary.js` are pure, side-effect-free functions of `(model, state, evaluation)`
   with the same function names and byte-identical output: `summaryText`, `fileName`, `emailDraft`,
   `componentAverage`, `averageText`, `sanitizeFileLabel`, `exportSections`, `resolvePartSection`.
   No section, item, dimension or option is named in either; every string comes from the render
   model (titles, prompts, option labels, placement labels, `partNumber`, `selectableParts`,
   `behavior.export.fileNamePattern`) or from a small documented presentation map, the same device
   as `LIST_CARD` in `app.js` (Phase 3 decision 5). Every code comparison in the CFML twin uses
   `compare()` (Phase 4 decision 10).
2. **Golden vectors, reviewed against the prototype.** `tests/fixtures/summary-vectors.json` holds
   10 walk states with their expected summary text, file name and five email-key combinations each,
   plus 13 rounding cases and 10 file-label cases.
   `scripts/generate-summary-vectors.mjs` produces them from the **served** render model with the
   JavaScript formatter (states normalized first, so a vector describes a walk the database could
   really hold), and `scripts/prototype-summary-oracle.mjs` replays every one through
   `source/current-prototype.html` itself, aligns the output with an LCS diff and classifies each
   difference. All 10 vectors are accounted for by the four recorded deviations below, and **every
   generated email draft matches the prototype exactly, with no deviation at all**. Neither script
   runs in `npm test`.
3. **`GET /api/walks/{id}/summary`** (`WalkService.summary`, `WalkController.summary`, one route
   under the existing `WALK_READ_PERMISSIONS` policy). Read-only: `authorizeWalk(read)`, the walk's
   pinned version (WALK-11), nothing taken from the request but the walk id, nothing written, no
   row version moved, no mutation recorded. `text/plain; charset=utf-8`, no BOM, LF, no trailing
   newline, `Content-Disposition: attachment` with the sanitized name, `Cache-Control: no-store`,
   `X-Content-Type-Options: nosniff`. Audits `WALK_SUMMARY_EXPORTED` with `{ status, versionId,
   bytes }` only.
4. **Part 4 teacher email composer** (`app/assets/js/email-composer.js`, rendered into the
   `email-draft` slot `renderer.js` already reserved). Checkboxes come from the item's
   `settings.selectableParts`; Draft / Clear / Update / Copy / Open in email app behave as the
   prototype does; the box carries To, Subject, Message and the note "Editable -- review and
   personalize before sending. Nothing is sent automatically." The document is written into the
   walk's `email_workflow` response through `setResponse` + the renderer's `commit`, so it rides
   the Phase 4 autosave, row-version compare, idempotency, replay and conflict handling unchanged,
   and it is serialized in the key order the server canonicalizes to so a reload compares equal.
5. **Export button** (`app.js`): shown for every walk the person may read, hidden with the walk
   view. On click it flushes a pending autosave, then downloads the server's copy (authorized,
   pinned, audited). When that flush did not reach the server it falls back to the browser
   formatter over the working state and says so, rather than handing the person a file missing what
   is on their screen. CSS for the composer went into `icfwalk.css`; no inline script or style was
   added and the CSP is unchanged.
6. **No automatic send.** No SMTP configuration, no `cfmail`, no mail library, no endpoint that
   accepts a recipient. The only outbound action is a `mailto:` URL with every value
   percent-encoded. `tests/node/no-mail.test.mjs` is the standing gate.
7. **Tests**: `WalkSummaryFormatterTest` (11 CFML cases), `WalkServiceTest` +6 (persisted-walk
   export, authorization parity with `open`, voided-walk export writes nothing, export audit
   privacy, email round trip and schema), `summary.test.mjs` (15), `no-mail.test.mjs` (5),
   `walks.test.mjs` +10 HTTP cases, `browser-email.test.mjs` (12 Playwright cases).
8. **Documentation**: `docs/ENDPOINTS.md` (the route and the email-draft transport),
   `docs/ARCHITECTURE.md` (Phase 5 section, Phase 6 hand-off), `docs/DATA_CONTRACT.md` (the 14
   Phase 5 decisions), `docs/LOCAL_SETUP.md` (new commands and the vector/oracle workflow),
   `docs/ACCEPTANCE_TRACKING.md` (SUM-01..09, the no-send gate, SEC-02/05, AUTH-05, A11Y-01/02/03),
   `package.json` scripts, evidence `docs/evidence/phase5-npm-test.txt` and
   `docs/evidence/phase5-red-before-fix.txt`, screenshots `email-composer-desktop.png` and
   `email-composer-phone.png`.

### Files created or changed (Phase 5)

```
Created: src/walks/WalkSummaryFormatter.cfc   app/assets/js/{summary,email-composer}.js
         tests/fixtures/summary-vectors.json  tests/cfml/specs/WalkSummaryFormatterTest.cfc
         tests/node/{summary,no-mail,browser-email}.test.mjs
         scripts/{generate-summary-vectors,prototype-summary-oracle}.mjs
         docs/evidence/{phase5-npm-test.txt,phase5-red-before-fix.txt}
         docs/evidence/screenshots/email-composer-{desktop,phone}.png
Changed: src/Bootstrap.cfc (construct and inject the formatter)  src/walks/WalkService.cfc (summary())
         src/controllers/WalkController.cfc (summary())  src/http/Router.cfc (one route)
         app/index.cfm (trailing newline; see the defect below)
         app/assets/js/{app,renderer}.js  app/assets/css/icfwalk.css
         tests/cfml/specs/{WalkServiceTest,WalkReplayCoherenceTest,WalkMutationResponseTest}.cfc
         tests/node/walks.test.mjs  package.json
         docs/{ENDPOINTS,ARCHITECTURE,DATA_CONTRACT,LOCAL_SETUP,ACCEPTANCE_TRACKING}.md  BUILD_STATUS.md
```

`WalkReplayCoherenceTest` and `WalkMutationResponseTest` changed only because they construct
`WalkService` directly and the constructor gained the formatter argument. No assertion in them was
touched. `manifest.json` is unchanged: no manifest-tracked supplied file was modified.

### Database and API changes

- **No new table, column, or migration.** The summary is derived on demand and never stored, the
  file name is derived, and the email draft is the existing `EMAIL_DRAFT_JSON` response. The
  migration scripts are byte-identical to the baseline and `npm run test:db` still applies them
  twice to a clean database.
- New route: `GET /api/walks/{id}/summary` (read-only, no CSRF). No other route changed.
- New audit event: `WALK_SUMMARY_EXPORTED`. New log event: `walk.summary.exported`.

### Phase 0-4 defect found and fixed

**Every response carried a trailing newline.** `app/index.cfm` ended with a newline after
`</cfscript>`. Anything after the closing tag is template output, and `cfcontent(reset=true)` has
already run inside `dispatch()`, so that byte was appended to every response body. JSON parsers
ignored it for four phases. The Phase 5 export cannot: its contract is byte-exact and ends without
a newline, and the first HTTP test of the route failed on exactly that. The fix is to end the file
at its closing tag, with a comment saying why. It is the smallest change that makes the contract
achievable, and it makes every other response byte-exact as a side effect. No test's expectations
were weakened to accommodate it.

### Tests and results (Phase 5)

Environment: Lucee 6.2.8.20 on Jetty, SQL Server 2022 Developer in Docker, Node 22.22.2,
Playwright 1.56 with the pre-installed Chromium, axe-core 4. The frozen Phase 0-4 baseline
(`npm test` 101/101, CFML 148/148, handoff 51 checks / 0 errors) was reproduced in this environment
before any Phase 5 change.

| Command | Result |
| --- | --- |
| `npm test` (full regression, `docs/evidence/phase5-npm-test.txt`) | **144/144 pass**, 0 failed, 0 skipped (baseline 101) |
| CFML suite via `/api/maintenance/tests/run` (inside `npm test`) | **166 passed, 0 failed, 0 skipped** (baseline 148) |

> Corrected in the Phase 5 correction session. This table previously read 143 and 165. Both were
> transcription errors: `docs/evidence/phase5-npm-test.txt`, the transcript of the run this table
> describes, records `1..144 / # tests 144 / # pass 144` and `passed=166 failed=0 skipped=0`. The
> run is unchanged; only the numbers written down here were wrong.
| `node scripts/validate-handoff.mjs` | ok, 51 checks, 0 errors (unchanged) |
| `node --check` on every browser module, script, and test | clean |
| `npm run oracle:summary` | 10/10 vectors accounted for; 0 UNEXPLAINED differences |
| Targeted runs during implementation | `?filter=WalkSummaryFormatter` (x7), `?filter=WalkService` (x3), `npm run test:walks`, `npm run test:summary`, `node --test tests/node/browser-email.test.mjs` (x6) |

New coverage: 42 Node/HTTP/Playwright cases and 17 CFML cases.

**Red-before-green evidence** (`docs/evidence/phase5-red-before-fix.txt`): five mutations were
applied to `WalkSummaryFormatter.cfc` one at a time, each removing exactly one recorded decision,
and the suite was re-run against each. Every one failed and named the divergence -- rounding the
exact rational instead of the IEEE-754 double (`3.1` for `3.05`), keeping the doubled trailing
colon, printing the stored code instead of the option label, exporting a hidden dimension, and
dropping the conditional-card reordering. The corrected formatter passes 11/11. This also
demonstrates that each decision is load-bearing in the output rather than only described in a
comment.

### Acceptance IDs satisfied in Phase 5

PASS: SUM-01, SUM-02, SUM-03, SUM-04, SUM-05, SUM-06, SUM-07, SUM-08, SUM-09, and the
no-automatic-send gate. Extended: SEC-02 (export and composer surfaces), SEC-05 (export audit and
logs), AUTH-05 (the summary route), A11Y-01/02/03 (the composer states). Details:
`docs/ACCEPTANCE_TRACKING.md`.

### Assumptions, decisions, and source conflicts (Phase 5)

The brief's section 14 resolved these from source precedence; the form each one took in the code is
recorded in `docs/DATA_CONTRACT.md` ("Summary export and email-draft decisions recorded in Phase
5"). Four of them are visible deviations from `source/current-prototype.html`, and the oracle
classifies every one of them on every vector:

1. **Hidden values are excluded from the export** (SUM-04), where the prototype cleared them
   outright. The values stay in the database and print again when the instrument shows them.
2. **The content-area heading is the section title uppercased** (`CONTENT-AREA LOOK-FORS`), matching
   the on-screen card, where the prototype composed `MUSIC CLASSROOM`. OPEN with the card heading.
3. **One trailing colon is stripped from a placement label**, so `Visit occurred at the:` prints
   once. The prototype's doubled colon is a defect.
4. **Non-scored choices print the option label** (`[Yes]`), where the prototype printed the raw
   stored code (`[yes]`). The label is what the person saw on the pill.

Also decided, without a visible prototype difference:

5. **Conditional-card export order** is one rule keyed on the SHOW rule's source dimension (a
   `content`-sourced card prints immediately before the last `classType`-sourced card), which
   reproduces the prototype's order today and becomes a no-op once content owners renumber
   `displayOrder`. The renderer keeps `displayOrder`. Recorded next to Phase 3 decision 3.
6. **The file name is driven by `behavior.export.fileNamePattern`** rather than by a restated list
   of dimension codes, because that setting is the contract for the exported name.
7. **Averages match JavaScript's `toFixed(1)`** on the IEEE-754 double quotient, reproduced in CFML
   with `BigDecimal(double).setScale(1, HALF_UP)` after taking the quotient to 40 significant digits
   and narrowing, so the result never depends on whether the CFML engine widens arithmetic. The
   vectors pin 2.25 → `2.3` and 3.05 → `3.0`.
8. **Upper-casing goes through `Locale.ROOT`** in the CFML twin, so a server whose default locale is
   Turkish cannot produce a dotted capital and break the vectors.
9. **Characters that must survive byte-exactly are built with `chr()`** in the CFML twin (em dash,
   en dash, bullet, middle dot, curly apostrophe) rather than written as source literals, so the
   exported bytes never depend on how a CFML engine decodes the file.
10. **The export button falls back to the browser formatter** only when a flush did not reach the
    server, and says so. The two formatters are proven identical, so the text is the same; what
    differs is that the fallback is not authorized, pinned, or audited, which is why it is not the
    default.
11. **A read-only editor for a non-owner is not reachable through the Phase 4 My Walks UI**, which
    lists only the signed-in user's own walks. `applyEditability` disables the composer's controls
    and the browser test proves its selector set reaches every one of them, but the read-only flow
    itself is proven at the API, where the decision is actually made (a reader with a valid session,
    a valid CSRF token and the current row version is refused 403).
12. **`{"drafted":"yes"}` is coerced, not refused.** CFML's `isBoolean()` accepts `"yes"`/`"no"`/
    `1`/`0`, so the Phase 4 validator canonicalizes such a value to a real JSON boolean. This is
    existing Phase 0-4 behavior, it always yields a well-formed stored document, and the browser
    only ever sends a real boolean. It was left alone (the baseline is frozen) and pinned by a test
    so a future change is deliberate.

### CF2023 verification items (Phase 5 additions)

Adobe ColdFusion 2023 and SQL Server 2016 were **not** available in this environment. Nothing was
executed on them and nothing below is claimed as tested. A compatibility review was done and these
are the items to verify on the target:

- `chr()` for the non-ASCII literals and `javaCast("string", x).toUpperCase(Locale.ROOT)` in
  `WalkSummaryFormatter`, and that the `.cfc` file itself is read as UTF-8 by the ColdFusion
  compiler. `WalkSummaryFormatterTest` fails loudly if either is wrong, because the vectors are
  byte-exact.
- `java.math.BigDecimal.divide(BigDecimal, MathContext)` → `doubleValue()` →
  `new BigDecimal(double).setScale(1, HALF_UP)` producing the same string ColdFusion's own
  arithmetic would, which is why the division is not left to the engine. Pinned by the rounding
  vectors (2.25 → `2.3`, 3.05 → `3.0`, 4.45 → `4.5`).
- `cfcontent(type = "text/plain; charset=utf-8", reset = true)` + `writeOutput` on Adobe emitting
  the body with no added whitespace and no BOM, and `cfheader` emitting `Content-Disposition`
  before it. `walks.test.mjs` asserts the exact bytes; re-run it against the ColdFusion deployment.
- That no template under the ColdFusion connector appends output after `dispatch()` (the
  `app/index.cfm` defect above); the byte-exactness assertions catch a regression.
- `reFind("<([^<>]+)>", pattern, at, true)` position/length semantics in `fileNameSpec`, and
  `reReplace(..., "[^A-Za-z0-9_-]+", "_", "all")` in `sanitizeFileLabel`.
- Closures passed to `eachSection` capturing an outer array on Adobe (`emailItem`,
  `resolvePartSection`).
- `charsetDecode(text, "utf-8")` for the audited byte count.
- Browser suites on the target: `npm run test:browser` and `npm run test:summary` against the
  ColdFusion deployment in development mode.

### Unresolved defects or blockers (Phase 5)

None open. Deliberately not addressed, and out of the approved Phase 5 scope: the deferred
indefinitely hung `IN_FLIGHT` request behavior, and CREATE/VOID response materialization. External
items unchanged (Adobe ColdFusion 2023 environment, identity gateway details, district org-unit
codes, content-owner wording for the 17 placeholders). OPEN for content owners: the conditional-card
`displayOrder` (decision 5), the content-area heading (decision 2), an `exportLabel` item setting to
retire `PART4_LABELS`, and whether a voided walk's export should carry a status line.

### Phase 5 completion gate

| Gate item | Status |
| --- | --- |
| Summary golden-file tests pass | Met: `WalkSummaryFormatterTest` and `summary.test.mjs` byte-equal on all 10 vectors, 13 rounding cases and 10 file-label cases; the persisted path through `WalkService.summary`, the HTTP body of `GET /api/walks/{id}/summary`, and the browser's downloaded file all compared with the same vectors |
| No-automatic-send tests pass | Met: `no-mail.test.mjs` (source scan, composer scan, route/controller/config scan, live 404 probes, `mailto:` encoding), `browser-email.test.mjs` "SUM-08" (no mail request, no navigation), `walks.test.mjs` "SUM-08" (`/email` and `/send` are 404) |
| SUM-01..09 PASS with evidence | Met: `docs/ACCEPTANCE_TRACKING.md`, plus screenshots |
| Phase 0-4 suites still green | Met: `npm test` 144/144 (baseline 101), CFML 166/166 (baseline 148), 0 failed, 0 skipped, handoff unchanged at 51 checks / 0 errors |
| Documentation and BUILD_STATUS updated, committed, pushed | Met |

## Phase 5 correction session (export coherence, browser fallback, test gating)

Scope: the three defects an independent audit raised against the Phase 5 candidate, and nothing
else. No redesign, no product-contract change, no outbound mail, no migration, no unrelated
refactoring. Phase 6 was not started.

The frozen Phase 0-4 baseline `d8f3736` is in this branch's ancestry; the Phase 5 commit `2522e79`
is its parent.

### Summary export could combine two committed states (CORR-P5-01, HIGH)

`WalkService.summary()` authorized the read and then performed its reads unlocked and in sequence:
the walk header, the dimension values, the responses, the pinned render model. SAVE, COMPLETE, VOID
and a mutation replay all open `variables.db.transact(...)` and take the walk mutation lock --
`WalkRepository.findWalk(id, true)`, `SELECT ... WITH (UPDLOCK, ROWLOCK)` -- as their first act. The
export took part in none of that, so a mutation could commit between the export's dimension read and
its response read.

The result is not merely stale, it is unreal: the file carries one committed state's dimensions
beside another's responses, a combination no version of the walk ever held. And because the
dimensions are what the visibility engine evaluates, the older dimensions can show a section the
committed dimensions hide, so the export prints a retained answer the walk's actual state excludes.
That is SUM-01 and SUM-04 broken at the same time.

**The correction.** `summary()` now materializes inside one transaction that takes
`findWalk(id, true)` first and holds it across the header, both halves of the aggregate, the
visibility evaluation, the summary text, the file name and the returned metadata. The complete
result is returned through the transaction outcome. The metadata-only log line and the
`WALK_SUMMARY_EXPORTED` audit event are written afterwards, from that already-coherent result, so
the lock lasts no longer than the reads that need it. Authorization, the pinned version, voided-walk
behavior, the response headers, the file name and the audit payload are all unchanged, and the
export still writes nothing: no row version moves, no revision, no mutation record.

**The invariant now enforced.** The text, the file name, every visibility decision, the status and
the version metadata of one export all describe one serialized database state. Equivalently: no
SAVE, COMPLETE or VOID can commit between the beginning and the end of a summary materialization.
One concurrent SAVE proves it for all three because the serialization is a property of the row lock,
not of SAVE: every mutation path queues on the same walk row. `create()` is the only transaction
that does not take it, and cannot -- there is no walk row until its own insert makes one, and until
that commits no other session can see the walk at all.

**Regression:** `tests/cfml/specs/WalkSummaryCoherenceTest.cfc` (3 cases).
`testASummaryExportCannotStraddleAConcurrentSave` uses the existing intercepting-repository and
concurrent-session pattern (`WalkMutationResponseTest`): it fires at `loadDimensionValues`, the
exact boundary between the export's two aggregate reads, and starts a real second session running a
real SAVE that changes both `classType` (which drives the Dual Language section's visibility) and
`summary_strengths` (visible under both states). The writer is still blocked when the bounded join
expires; the export describes state A only; the writer then commits; a later export describes state
B only, with the retained Dual Language note excluded from the text while still present in the
table. `testEveryMutationPathTakesTheSameWalkLock` asserts the shared-lock structure against the
source. `testTheLockedExportStillWritesNothingAboutTheWalk` proves holding the lock did not turn the
read into a write.

### Browser export fell back to a local file when the server was reachable (CORR-P5-02, MEDIUM)

`exportSummary()` chose the download path from the editor's unsent-work flags:

```js
const unsent = walk.canEdit && (app.dirty || app.failed || Boolean(ambiguousSave()));
```

That is broader than the Phase 5 contract, which allows a browser-generated file only when the save
flush fails because of a network transport failure. Two wrong paths followed from it:

1. **An edit made during an in-flight save.** `saveCurrent()` coalesces: called with a request
   already on the wire it returns that request's promise and leaves the newer state on the autosave
   timer. The export awaited the older save, saw `app.dirty` still set, and built a Blob while the
   queued edit sat unsent. The file was browser-made and the person was told the server could not be
   reached, when the server was answering normally.
2. **A definitive rejection.** Any 4xx sets `app.failed`. The server was reached and refused the
   state; the export nevertheless produced a file of the refused state and blamed the network.

**The correction.** A new `flushForExport(walk)` drives the editor state onto the server before the
path is chosen. It loops: each pass awaits whatever `saveCurrent()` does, then re-reads the real
unsaved-work signals and sends again if any is still set, cancelling the autosave timer rather than
waiting it out. It is bounded at `EXPORT_FLUSH_PASSES` (6; a normal flush takes at most three), so a
pathological state ends in a blocked export rather than a spinning tab. `saveCurrent()` now records
how each attempt ended in `app.saveOutcome` -- `saved`, `transport`, `server`, `conflict`,
`rejected` -- because `app.dirty` and `app.failed` cannot tell a refused state from a lost answer,
and neither says whether the server was ever reached.

**The fallback rule now enforced.** The browser formatter is used when, and only when, the flush
failed with a transport failure: no HTTP response at all, which `api.js` raises as `NetworkError`
rather than `ApiError`. Everything else blocks the export with its own accurate message and no file:

| Flush outcome | Export |
| --- | --- |
| everything saved | `GET /api/walks/{id}/summary` (authoritative, authorized, audited) |
| read-only viewer (nothing to flush) | `GET /api/walks/{id}/summary` |
| transport failure (no response produced) | browser formatter, and the message says the file was generated in the browser from unsaved information and is not the saved copy |
| definitive 4xx rejection | blocked; "The server did not accept the latest changes..." |
| HTTP 5xx (ambiguous, server reached) | blocked; "The last save did not finish..." -- never described as a network failure |
| 409 conflict | blocked; the existing conflict workflow is untouched |

Phase 4 is unaffected: the operation record, its mutation id and its frozen body are not touched on
any of these paths, so replay, row-version comparison, conflict handling and the unfinished-work
guards behave exactly as before. The byte-identical formatter contract and the sanitized file name
are unchanged.

**Regression:** `tests/node/browser-export.test.mjs` (7 cases) on
`tests/node/export-harness.mjs`. The harness serves the shipped browser modules and the real
`src/views/shell.html` (with the three substitutions `ShellController.cfc` makes) against a scripted
API, so a save can be held open at a chosen instant and the next one answered 400, 409 or 503 on
demand. Nothing under test is stubbed; the instrument is a small synthetic one, because the behavior
under test is which URL the export downloads from, not the district's content. A transport failure
is produced as a transport failure (`route.abort("connectionreset")`) and an HTTP error as a real
response, so the two are never conflated. `browser-email.test.mjs` continues to prove the export
against the real application, the real instrument and SQL Server.

### An unavailable application counted as a passing live test (CORR-P5-03, LOW)

The live half of `tests/node/no-mail.test.mjs` returned early when the application was unreachable,
so TAP counted it as a pass although no endpoint was probed. A live test that did not run is not a
live test that succeeded.

**The correction.** `tests/node/helpers.mjs` gains `requireApp(env)`, reading
`ICFWALK_REQUIRE_APP`. With no application expected, the live test reports as an explicit skip
naming the reason. Under `ICFWALK_REQUIRE_APP=1` -- the full integration and release-verification
profile -- an unreachable application fails the run. The four static no-mail scans always run, and
none was weakened. The requirement itself is unchanged: ICFWalk has no mail-delivery route, no
server mail integration, no SMTP configuration and no automatic-send mechanism.

### Files changed (Phase 5 correction session)

| File | Change |
| --- | --- |
| `src/walks/WalkService.cfc` | `summary()` materialized inside one transaction under the walk mutation lock |
| `app/assets/js/app.js` | `flushForExport`, `app.saveOutcome`, the rewritten `exportSummary`, `blockExport`, and the two new blocked-export messages |
| `tests/cfml/specs/WalkSummaryCoherenceTest.cfc` | new: 3 cases |
| `tests/node/browser-export.test.mjs` | new: 7 cases |
| `tests/node/export-harness.mjs` | new: the deterministic stub the export regressions run against |
| `tests/node/helpers.mjs` | new `requireApp(env)` |
| `tests/node/no-mail.test.mjs` | live probe skips explicitly, or fails under `ICFWALK_REQUIRE_APP` |
| `docs/DATA_CONTRACT.md` | "Summary export coherence" |
| `docs/ENDPOINTS.md` | the summary route is materialized under the walk mutation lock |
| `docs/ARCHITECTURE.md` | export line: "flush to the server, then download" |
| `BUILD_STATUS.md` | this section; Phase 5 totals corrected to the transcript's 144/166 |
| `docs/evidence/phase5-correction-npm-test.txt` | new: the full suite transcript |
| `docs/evidence/phase5-correction-red-before-fix.txt` | new: red-before-green record |
| `docs/evidence/phase5-correction-environment.md` | new: what was verified where, and what was not |

No migration, no schema change, no new table or column; `database/` is untouched. No outbound-mail
capability of any kind was added.

### Tests and results (Phase 5 correction session)

Environment: Node 22.22.2, Playwright 1.56.1 with the pre-installed Chromium, Lucee 6.2.8.20 on
Jetty 9.4.58 for CFML compilation only. **No SQL Server and no application runtime.**
`docs/evidence/phase5-correction-environment.md` records why and what it costs.

| Command | Result |
| --- | --- |
| `npm test` (`docs/evidence/phase5-correction-npm-test.txt`) | **151 cases, 29 pass, 0 fail, 122 skipped** |
| `node --test tests/node/browser-export.test.mjs` | **7/7 pass** |
| `node --test tests/node/no-mail.test.mjs` | 5 cases, 4 pass, 1 explicit skip (no application) |
| `ICFWALK_REQUIRE_APP=1 node --test tests/node/no-mail.test.mjs` | 5 cases, 4 pass, **1 fail** -- the profile refusing to pass an unrun live check |
| `npm run test:package` | 18/18 pass |
| `npm run test:summary` | 20 cases, 4 pass, 16 skipped (the rest need the application) |
| `npm run validate:handoff` | ok, 51 checks, 0 errors |
| `npm run oracle:summary` | 10/10 vectors accounted for; 0 unexplained differences |
| `node --check` on every browser module, script and test | 34 files, 0 failures |
| CFML compilation on Lucee 6.2.8.20 | 67 components, 0 failures |
| CFML suite | **not run**: needs SQL Server |
| `npm run vectors:summary:check` | **not run**: needs the running application |

**Totals.** Node/HTTP/Playwright: **151** declared cases, up from the 144 in
`docs/evidence/phase5-npm-test.txt` (7 new export regressions). CFML: **169** declared cases, up
from 166 (3 new coherence cases), counted from the spec sources by the same rule `TestRunner` uses
and **not executed in this environment**. The 122 skips are the application-dependent cases; 29
pass. Nothing was weakened and no required test became a skip -- the one case that moved from pass
to skip is the no-mail live probe, which is the CORR-P5-03 correction doing its job, and it accounts
exactly for the delta (23 pass + 7 new - 1 = 29; 121 skips + 1 = 122).

**Red-before-green** (`docs/evidence/phase5-correction-red-before-fix.txt`): each new regression was
run against the Phase 5 implementation exactly as committed at `2522e79`. Four of the seven export
regressions failed, each naming the audited behavior -- one PUT instead of two, a Blob carrying a
server-refused state, a Blob on an HTTP 5xx, and a message that did not say the file was made in the
browser -- and all seven pass against the correction. The three that passed under the unfixed code
did so on purpose: they prove the correction did not break the paths that were already right. The
CFML structural lock assertion fails against the unfixed `summary()` and passes against the
correction. No temporary mutation remains in the tree.

### Unresolved and not verified (Phase 5 correction session)

1. **The concurrency regression itself has not been executed.**
   `testASummaryExportCannotStraddleAConcurrentSave` needs SQL Server's UPDLOCK/ROWLOCK semantics --
   that is the whole point of it -- and SQL Server could not be installed: Docker is absent, and the
   native package redirects to a host this session's egress policy refuses with HTTP 403. The spec
   compiles and its structural sibling runs green, but the interleaving it forces has not been
   observed. This is the first thing an environment with SQL Server should run.
2. **The CFML suite total of 169 is a count of declared cases, not a run.**
3. **Adobe ColdFusion 2023 was not available and was not used.** No CF2023 claim is made. The CF2023
   verification items listed for Phase 5 and the earlier correction sessions are unchanged and still
   outstanding, plus: the locked `summary()` transaction should be exercised on CF2023, whose
   `transaction` + closure semantics and datasource locking behavior are the reason those items
   exist.
4. **SQL Server 2016 was not available and was not used.** The frozen Phase 5 evidence records SQL
   Server 2022; this session adds no SQL Server run of any version.
5. **Phase 5 is not declared ready to freeze here.** This session reports a correction candidate and
   its evidence; whether the candidate is sound is for a fresh independent audit to determine.

## Phase 5 final correction pass (NetworkError-only fallback, concurrency seam)

Scope: the one MEDIUM and one LOW defect the second independent audit left open, and nothing else.
That audit confirmed the HIGH summary-coherence correction, the no-mail test gating and the
corrected Phase 5 totals, and none of them is touched here. No redesign, no change to the summary
text or file-name contract, no schema change, no migration, no mail. Phase 6 was not started.

`d8f3736` (frozen Phase 0-4 baseline) and `2522e79` (Phase 5) are both in this branch's ancestry;
`30f46be` (the first correction pass) is the parent of this work.

### Only a genuine NetworkError may permit the browser fallback (CORR-P5B-01, MEDIUM)

`api.js` defines `ApiError` and `NetworkError`; `app.js` imported only `ApiError` and classified by
elimination -- anything that was not an `ApiError` became a transport failure, and a transport
failure is the one outcome that permits a browser-generated summary.

Two real paths reach that branch without ever producing a `NetworkError`:

1. **An HTTP 200 whose body is not JSON.** `api.js` swallowed the parse failure and returned `null`;
   `ApiWalkStore.save()` then read a walk out of `null` and threw a plain `TypeError`.
2. **An HTTP 200 whose body fails after the headers arrived.** `await response.text()` rejected, and
   that rejection was outside the `try` that builds `NetworkError`, so it escaped untyped.

Both were classified as an unreachable server. In both the server was reached, answered 200, and may
already have committed the mutation -- so the browser produced an unaudited local file of a state the
server may hold, and told the person the server could not be reached. Two falsehoods in one action.

**The correction.** `api.js` gains a third type, `ResponseError`, for an answer that arrived and
could not be used: `unreadable-body` when `response.text()` rejects, `malformed-body` when an OK
response's body is not JSON. A failing status still raises `ApiError` for its status even when its
body is unparseable, so nothing about the 4xx and 5xx paths moves. `app.js` imports `NetworkError`
and `ResponseError` and classifies once, by type, in `classifySaveFailure`:

| Failure | Outcome | Ambiguous? | Export |
| --- | --- | --- | --- |
| `NetworkError` | `transport` | yes | **browser formatter** -- the only path that gets one |
| `ApiError` >= 500 | `server` | yes | blocked, "the last save did not finish" |
| `ApiError` 409 stale/superseded | `conflict` | no | blocked, conflict workflow untouched |
| `ApiError`, anything else | `rejected` | no | blocked, "the server did not accept the latest changes" |
| `ResponseError` | `unknown` | yes | blocked, "the last save did not finish" |
| anything else at all | `unknown` | yes | blocked, "the last save did not finish" |

The rule is default-deny by construction: `transport` requires an actual `NetworkError`, which
`api.js` constructs in exactly one place -- the `catch` around `fetch()` itself -- so nothing new
that the save path can throw becomes a transport outcome by accident. `isAmbiguousFailure` is now
derived from the same classifier and its answers are unchanged for every input, so the Phase 4
recovery lifecycle is byte-for-byte what it was: an `unknown` outcome keeps the operation record,
its mutation id, its row version and its frozen body, stays `AMBIGUOUS`, and is offered for retry.
A response-shaped failure means the request was delivered, so the mutation behind it is exactly as
likely to be committed as one whose answer was a 500, and it is treated the same way.

The same "not an `ApiError`, therefore unreachable" inference appeared in the user-facing text of
the create, complete, void and pending-operation-retry paths. Those four messages now ask
`isUnreachable(e)` instead. Only the sentence shown changes; no recovery gating moves. The two
read-only load messages (`/api/walks`, `/api/me`) were left alone: they are outside this defect and
carry no mutation.

### The concurrency hook was not at the mixed-read boundary (CORR-P5B-02, LOW)

`WalkSummaryCoherenceTest` said its concurrent writer started after the export read dimensions and
before it read responses. It armed `loadDimensionValues`, and `InterceptingWalkRepository` fires
before delegating -- so the writer actually started *ahead of both* child reads. Against the
unlocked implementation a writer there can commit before either read, and the export then sees
state B coherently. That still detects the missing lock; it does not reproduce the mixed read the
comments describe.

**The correction.** `InterceptingWalkRepository` gains a `loadResponses` seam, firing before it
delegates, and the spec arms that instead. `loadDimensionValues` is untouched, because
`WalkReplayCoherenceTest` arms it both to start a writer as a replay loads the aggregate and to
prove a refused replay never loads it at all. At the new seam the dimensions are in hand and the
responses are not, so a commit landing there produces state A's dimensions beside state B's
responses -- the mixed aggregate itself. The spec's comments now describe the seam that executes.

A fourth case, `testTheConcurrencySeamFiresBetweenTheTwoAggregateReads`, asserts the placement
directly: it drives the decorator against a recording delegate and checks the callback runs after
the dimension read returns and before the response read is delegated, and that the older seam still
fires ahead of both. It needs no database, which is what makes the seam correction verifiable
without SQL Server.

### Files changed (Phase 5 final correction pass)

| File | Change |
| --- | --- |
| `app/assets/js/api.js` | `ResponseError`; the body read and the JSON parse raise it instead of escaping untyped or being swallowed |
| `app/assets/js/app.js` | imports `NetworkError`/`ResponseError`; `classifySaveFailure`, `AMBIGUOUS_KINDS`, `isUnreachable`; the save catch and four lifecycle messages read the classifier |
| `tests/cfml/support/InterceptingWalkRepository.cfc` | new `loadResponses` seam; `loadDimensionValues` unchanged |
| `tests/cfml/specs/WalkSummaryCoherenceTest.cfc` | armed on `loadResponses`; corrected comments; new seam case (3 -> 4 cases) |
| `tests/node/browser-export.test.mjs` | 4 new cases (7 -> 11) |
| `tests/node/export-harness.mjs` | request bodies logged; `raw` / `body` / `bodyFails` / `clearPlan` controls |
| `docs/DATA_CONTRACT.md` | what counts as a transport failure is a type, not a default |
| `docs/ENDPOINTS.md` | an unusable answer is ambiguous like a 5xx |
| `docs/ARCHITECTURE.md` | the narrow fallback rule |
| `docs/LOCAL_SETUP.md` | the export suite's new cases |
| `manifest.json` | one refreshed entry, `docs/DATA_CONTRACT.md`, via `scripts/refresh-manifest.mjs` |
| `BUILD_STATUS.md` | this section |
| `docs/evidence/phase5-correction2-*.{txt,md}` | new: suite transcript, red-before-green, environment |

No schema change, no migration, no new table or column; `database/` is untouched. No outbound-mail
capability was added. No Phase 0-4 file was reopened and no Phase 6 work was started.

### Tests and results (Phase 5 final correction pass)

Environment: Node 22.22.2, Playwright 1.56.1 with the pre-installed Chromium, Lucee 6.2.8.20 on
Jetty 9.4.58 for CFML compilation and the database-free CFML cases. **No SQL Server and no
application runtime**; `docs/evidence/phase5-correction2-environment.md` records why and what it
costs, item by item.

| Command | Result |
| --- | --- |
| `node --test tests/node/browser-export.test.mjs` | **11/11 pass** |
| `npm test` (optional profile, `docs/evidence/phase5-correction2-npm-test.txt`) | 155 cases, 33 pass, **0 fail**, 122 skipped |
| `ICFWALK_REQUIRE_APP=1 npm test` (release-verification profile) | 155 cases, 33 pass, **1 fail**, 121 skipped |
| `node --test tests/node/no-mail.test.mjs` | 5 cases, 4 pass, 1 explicit skip |
| `ICFWALK_REQUIRE_APP=1 node --test tests/node/no-mail.test.mjs` | 5 cases, 4 pass, **1 fail** |
| `npm run validate:handoff` | ok, 51 checks, 0 errors |
| `npm run test:package` | 18/18 pass |
| `npm run test:summary` | 20 cases, 4 pass, 16 skipped |
| `npm run oracle:summary` | 10/10 vectors accounted for, 0 unexplained |
| `node --check` on every `.js` and `.mjs` | 34 files, 0 failures |
| CFML compilation, Lucee 6.2.8.20 | 67 components, 0 failures |
| `WalkSummaryCoherenceTest`, database-free cases | 2 of 4 run, both pass |
| CFML suite (all 170 cases) | **not run** -- needs SQL Server |
| Migration apply/reapply on a clean database | **not run** -- needs SQL Server |

The single failure under the required-application profile is the no-mail live route probe refusing
to report a check it could not perform. That is the CORR-P5-03 gate behaving as designed, not a
regression, and it is why this run is not a passing freeze gate.

**Totals and where the increases come from.** Node/HTTP/Playwright: **155** declared, up from 151 --
the four new export regressions (a 200 that is not JSON; the retryability of an unresolved save; a
200 that is not a walk; a body that fails after its headers). CFML: **170** declared, up from 169 --
the one new seam case. Counted from the spec sources by the rule `TestRunner` itself uses. No case
was removed, weakened, or turned into a skip.

**Red-before-green** (`docs/evidence/phase5-correction2-red-before-fix.txt`). Each regression was
written and run before the production change. The four new export cases failed against `app.js` and
`api.js` as committed at `30f46be`, every one of them by producing a browser-generated Blob under a
false "server could not be reached", and all eleven pass against the correction. The new seam case
failed against `InterceptingWalkRepository.cfc` as committed at `30f46be` with "the loadResponses
seam exists and fired", and passes against the correction. No temporary mutation remains in the tree.

### Unresolved and not verified (Phase 5 final correction pass)

1. **`testASummaryExportCannotStraddleAConcurrentSave` still has not been executed** -- and it is
   the case the Defect 2 seam correction exists to serve. It needs SQL Server's UPDLOCK/ROWLOCK
   semantics. The seam's *placement* is now proved by a case that does run; the interleaving it
   forces is not, and the corrected regression has not been demonstrated to fail against the
   unlocked Phase 5 `summary()`.
2. **The CFML suite total of 170 is a count of declared cases, not a run.**
3. **Migration apply/reapply was not re-run.** `database/` is byte-identical to the baseline, so
   nothing changed; that is not the same as re-verified and is not offered as such.
4. **Adobe ColdFusion 2023 and SQL Server 2016 remain target-platform verification items.** Neither
   was available and neither was used. The CF2023 items listed for Phase 5 and the earlier
   correction sessions are unchanged, plus the locked `summary()` transaction and the closure-based
   `classifySaveFailure` path should both be exercised there.
5. **The Phase 5 freeze gate is not satisfied by this run.** A complete `ICFWALK_REQUIRE_APP=1 npm
   test` with zero failures and zero skips is the gate; this environment produces 1 failure and 121
   skips for want of a database. Phase 5 is not declared ready to freeze here.

## Phase 5 final live verification (full release gate executed)

This session executed the complete release-verification gate that every previous Phase 5 session had
to leave undone for want of a database and an application runtime. It made no speculative change: two
failures surfaced, both were diagnosed to root cause, and **no production code was changed**. Evidence:
`docs/evidence/phase5-final-verification-environment.md`, `-database.txt`, `-targeted.txt`,
`-supporting.txt`, `-release-gate.txt`, `-red-before-fix.txt`.

### Environment as executed

| Component | Version |
| --- | --- |
| Operating system | Ubuntu 24.04.4 LTS, kernel 6.18.44, x86_64 |
| Node / npm | 22.22.2 / 10.9.7 |
| Java | OpenJDK 21.0.10+7-Ubuntu-124.04 |
| Lucee | 6.2.8.20 (lucee-light on jetty-runner 9.4.58.v20250814) |
| Microsoft JDBC driver | 12.10.2.jre11 |
| SQL Server | 16.0.4295.3 Developer Edition (64-bit), RTM-CU27, Linux (SQL Server 2022) |
| Playwright / Chromium | 1.56.1 / 141.0.7390.37 |
| axe-core / mssql (Node) | 4.13.0 / 12.7.2 |

Dependencies installed with `npm ci` from the checked-in `package-lock.json`. No dependency was
added, upgraded or removed; the lockfile is unchanged.

### Database verification

| Step | Result |
| --- | --- |
| Clean disposable database created (`DROP`/`CREATE icfwalk_dev`) | `icf` schema absent before apply |
| First apply, `001`..`005` in order | all five ok, exit 0; 20 tables from `001`, 22 after `005` |
| Reapply of the complete set | `002`-`005` ok; `001` refuses by design ("The icf schema already contains tables. No changes were made."), so the script exits 1 |
| `002`/`003`/`004`/`005` reapplied individually | each exit 0 |
| Idempotence proved directly | full `icf` object/column fingerprint (455 rows) identical before and after a further reapply, sha256 `15b239a3...5f02ddef` |
| `npm run test:db` | 1 case, **1 pass, 0 fail, 0 skip** |
| Seed | `2026-09-17 aligned prototype` DRAFT, checksum `c125b4ae...4dda9`, 23 sections / 144 items / 95 dimension values |

No schema change was made and no migration was edited. None was needed.

### Targeted correction verification

| Check | Result |
| --- | --- |
| `node --test tests/node/browser-export.test.mjs` | 11 cases, **11 pass, 0 fail, 0 skip** |
| `ICFWALK_REQUIRE_APP=1 node --test tests/node/no-mail.test.mjs` | 5 cases, **5 pass, 0 fail, 0 skip** |
| `/api/maintenance/tests/run?filter=WalkSummaryCoherence` | 4 cases, **4 pass, 0 fail, 0 skip** |

The CORR-P5-03 gate that failed in the previous session now passes for the right reason: the live
route probe performed its check against a running application rather than refusing to report one.

**The real concurrent SAVE ran.** `testASummaryExportCannotStraddleAConcurrentSave`, unexecuted in
every prior session, executed against SQL Server in 6236 ms and passed. What that run established:

- the concurrent writer started at the `loadResponses` seam, between the export's dimension read and
  its response read (`interceptor.fired("loadResponses")`);
- the writer was still blocked when the bounded 6000 ms join expired, while the summary transaction
  held the walk mutation lock -- the 6.2 s duration is that block, not overhead;
- the export described state A coherently: state A's response, state A's Dual Language section,
  state A's grade in the file name, and the walk's own pinned version;
- the writer committed state B after the export released the lock, on a new row version;
- the later export described state B alone, and `dual_language_notes` was absent from it while still
  stored in the database -- SUM-04 retained-but-hidden, proved against the real store.

Item 1 of "Unresolved and not verified (Phase 5 final correction pass)" is discharged by this run.
Items 2 and 3 are discharged by the CFML suite total and the migration results above.

### Supporting checks

| Command | Result |
| --- | --- |
| `npm run validate:handoff` | ok, **51 checks, 0 errors** |
| `npm run test:package` | **18/18 pass**, 0 skip |
| `npm run test:db` | **1/1 pass**, 0 skip |
| `npm run test:cfml` | 5 Node cases pass; CFML suite **170 pass, 0 fail, 0 skip** |
| `npm run test:summary` | **20/20 pass**, 0 skip |
| `npm run vectors:summary:check` | `summary-vectors.json is current` |
| `npm run oracle:summary` | **10/10 vectors accounted for, 0 unexplained** |
| `node --check` on every `.js` and `.mjs` | **34 files, 0 failures** |

### Complete release gate

```
ICFWALK_REQUIRE_APP=1 npm test
```

| Suite | Cases | Passed | Failed | Skipped |
| --- | --- | --- | --- | --- |
| Node / HTTP / Playwright | 155 | **155** | **0** | **0** |
| CFML, executed live within the run | 170 | **170** | **0** | **0** |

Exit 0. Wall time 234 s for the Node suite, with the CFML suite completing in 52.9 s inside it. No
request-timeout entry was logged. This is a real gate result from one commit and one working tree,
not a combination of runs.

### Failures found, and what they were

Both are recorded in full, observed-failure-first, in
`docs/evidence/phase5-final-verification-red-before-fix.txt`.

1. **Test-harness defect (corrected).** `WalkSummaryCoherenceTest`'s `storedDimensionCode()` helper
   selected `value_code` from `[icf].[walk_dimension_value]`, which has no such column -- it holds
   `selected_value_id`, and `value_code` lives on `[icf].[dimension_value]`. The assigned concurrency
   case failed with `Invalid column name 'value_code'` the first time it ever reached a database.
   The three sibling specs that read the same thing have always joined correctly. Fixed by adding
   that join, one line, test code only. **No assertion was weakened, removed, renamed or skipped**;
   the two assertions the helper feeds still demand `general_education` and `5`, and the change only
   lets them execute.

2. **Environmental (runtime configuration).** The whole 170-case CFML suite runs inside a single
   `/api/maintenance/tests/run` request, which on this container takes 52-57 s -- past Lucee's 50 s
   default. Lucee stopped the request mid-suite and interrupted the thread, and the *next* spec died
   with `java.nio.channels.ClosedByInterruptException` on its first file write, which reads like a
   logging fault and is not one. Proved by A/B on one variable: without the override the request is
   killed at 50061 ms; with it the suite completes 170/170. `tools/runtime/lucee-up.sh` now exports
   `LUCEE_REQUESTTIMEOUT` (default 600, overridable). That is the Lucee-under-Jetty verification
   runtime only, which `docs/LOCAL_SETUP.md` already states is not a supported production platform.
   **No application code, no `Application.cfc` setting and no production configuration is involved,
   and no individual test is given longer to pass.**

   The interrupted runs left test instrument versions behind, which then failed four version-selection
   specs on the next attempt. Those were consequences of the interruption, not defects, and none
   reproduces on a clean database. The database was dropped, rebuilt, re-migrated and re-seeded, and
   the entire gate re-executed from that clean state; every number above comes from that re-run.

### Files changed (final live verification session)

| File | Why |
| --- | --- |
| `tests/cfml/specs/WalkSummaryCoherenceTest.cfc` | one-line join correction in the `storedDimensionCode()` test helper (failure 1). Test code only. |
| `tools/runtime/lucee-up.sh` | exports `LUCEE_REQUESTTIMEOUT` (default 600) for the verification runtime (failure 2). |
| `docs/LOCAL_SETUP.md` | documents that knob and the misleading `ClosedByInterruptException` it prevents. |
| `docs/evidence/phase5-final-verification-*` | new evidence set, six files. |
| `docs/evidence/screenshots/*.png` | regenerated by `npm run test:browser` inside the gate, as that suite is specified to do. |
| `BUILD_STATUS.md` | this section. |

**No production code changed.** `app/`, `src/`, `database/`, `config/`, `manifest.json`,
`package.json` and `package-lock.json` are untouched. All historical evidence files are unchanged.

### Unresolved and not verified (final live verification session)

1. **Adobe ColdFusion 2023 is unverified.** All CFML execution was on Lucee 6.2.8.20, the documented
   verification runtime. ColdFusion 2023 cannot be installed in this container, so no target-platform
   check could be run separately. Every CF2023 verification item from Phase 5 and the correction
   sessions stands, including the locked `summary()` transaction and the closure-based
   `classifySaveFailure` path.
2. **SQL Server 2016 is unverified.** All SQL execution was against SQL Server 2022 (16.0.4295.3).
   The migrations and the `UPDLOCK, ROWLOCK` serialization the concurrency case depends on are now
   proved on 2022 only.
3. Nothing else. No test is skipped, no assertion is weakened, and no defect is outstanding within
   the correction scope.

### Phase 5 candidate status

The complete gate was executed against this exact candidate with **zero failures and zero skips**.
The freeze decision itself belongs to the independent auditor, not to this session.

## Phase 6 foundation: the publish transaction and published immutability

Started from the verified Phase 5 baseline `e55ec08af5b8622db5823b6e353423b891918549` (tree
`403d964ce250d6b089419a34ac29b91fa0915a38`), confirmed against the live repository by an independent
fresh clone before any Phase 6 code was written. This is the completion gate named in
`docs/IMPLEMENTATION_PLAN.md` for Phase 6 -- "publish transaction produces a verified
snapshot/checksum and every published child mutation is rejected" -- and nothing beyond it. DRAFT
editing, preview, version compare, retire and the placeholder review queue are not started, and no
admin UI was added.

### What publishing now does

`src/instrument/InstrumentPublishService.cfc`. One transaction, the version row taken under
`UPDLOCK, ROWLOCK` first, so a concurrent publish or import of the same version queues behind it
rather than interleaving -- the same lock discipline every walk mutation path uses.

| Step | Refusal |
| --- | --- |
| Version exists | `ICFWalk.NotFound` / `INSTRUMENT_VERSION_NOT_FOUND` |
| Status is DRAFT, read under the lock | `ICFWalk.Publish.NotDraft` / `INSTRUMENT_VERSION_NOT_DRAFT` (409) |
| A compiled snapshot exists and parses | `INSTRUMENT_VERSION_NOT_PUBLISHABLE` (422) |
| `checksum_sha256` is the SHA-256 of `compiled_snapshot_json` | `CHECKSUM_MISMATCH` |
| The snapshot's definitions still equal the definitions SQL Server holds | `DEFINITIONS_DRIFT` |
| Unresolved placeholders, where the deployment blocks on them | `UNRESOLVED_PLACEHOLDERS` |

Then `DefinitionRepository.markPublished` writes status, publisher, `published_at`,
`effective_start`, snapshot and checksum in one statement, whose `WHERE` re-asserts `DRAFT`. The
database's existing `CK_instrument_version_publish_values` rejects any non-DRAFT row missing one of
those columns, so a half-published row cannot be stored even by a future caller that tried. **No
schema change was needed and none was made.**

**Publishing does not recompute the snapshot.** It freezes the text the import compiled, byte for
byte, under the checksum the import stored. The compiled snapshot carries metadata that exists only
in the imported document (`schemaVersion`, `source`, `version`, `behavior`, `contentReview`) and is
not reconstructible from the definition tables, so recompiling it here would be a guess dressed as a
check. What publishing can prove it does prove: the stored checksum hashes the stored snapshot, and
the snapshot's definitions still match the database's, compared by the same canonical checksum the
import's own round-trip proof uses. That drift is the only thing that can have changed since import,
and freezing a snapshot that no longer describes its definitions is the one unrecoverable mistake
available here.

Structural document validation (duplicate keys, bad parents, missing sets, option order, malformed
rule JSON -- ADM-03) stays where it already is, in `InstrumentConfigValidator` at import, which is
the only writer of these tables. `InstrumentConfigValidator` has no normalized-definitions entry
point, and inventing one to re-run at publish would have duplicated the rule set against a partial
input; the drift check covers the gap that actually exists.

### Published immutability (ADM-05)

`assertDraftForWrite(versionId, actor, operation)` is a callable guard, so ADM-05's "or direct
service call" holds for code that never touches a route. It reads status under the same row lock the
write will take, refuses anything that is not a DRAFT, and audits the attempt.

One consequence is documented rather than glossed: that guard's audit record is written in whatever
transaction the caller has open, so a caller that rolls back rolls the record back too. The refusal
itself is unaffected. `publish()` handles this correctly for its own refusals -- see below.

### A real defect the tests caught

The first implementation wrote every refusal's audit record inside the publish transaction, and then
raised, which rolled the transaction back -- taking the audit record with it. A refused publish left
no trace at all, which is precisely what ADM-05 asks for and precisely what was missing.

Two cases failed against that implementation, red before green:

```
FAILED  testDefinitionsDriftIsRefusedAndNothingChanges
        :: and the refusal is audited Expected [1] but got [0].
FAILED  testPublishingAPublishedVersionIsRefusedAndAudited
        :: and the refusal is on the record Expected [1] but got [0].
```

Corrected by deferring the record: a refusing branch marks what it decided (`markRefusal` mutates a
struct that outlives the closure) and raises; the audit is written in the `catch`, after the
rollback, where it survives. Only refusals this service decided on are recorded there -- a deadlock,
a constraint violation or a driver fault propagates unannotated. All 8 cases pass against the
correction.

### Files changed (Phase 6 foundation)

| File | Why |
| --- | --- |
| `src/instrument/InstrumentPublishService.cfc` | New. The publish transaction and the `assertDraftForWrite` guard. |
| `src/instrument/DefinitionRepository.cfc` | `findVersionByIdForUpdate` (the locking read) and `markPublished` (the one-statement publish write, read back inside the transaction rather than trusting a driver row count). |
| `src/core/Errors.cfc` | `ICFWalk.Publish.NotDraft` (409) and `ICFWalk.Publish.Validation` (422), with their status mappings. |
| `src/controllers/AdminInstrumentController.cfc` | `publishVersion` action. |
| `src/http/Router.cfc` | `POST /api/admin/instrument/versions/{id}/publish`, permission `instrument.manage`. |
| `src/Bootstrap.cfc` | Wires `instrumentPublishService`. |
| `tests/cfml/specs/InstrumentPublishServiceTest.cfc` | New. 8 cases. |
| `docs/ACCEPTANCE_TRACKING.md` | ADM-03 PARTIAL, ADM-04 and ADM-05 PASS at the service/endpoint level; ADM-02/06/07/08 still PENDING. |

### Tests and results (Phase 6 foundation)

Environment as for the Phase 5 final verification: SQL Server 2022 (16.0.4295.3), Lucee 6.2.8.20,
Node 22.22.2, Playwright 1.56.1 with Chromium 141.0.7390.37, all actually running.

| Command | Result |
| --- | --- |
| `?filter=InstrumentPublish` | 8 cases, **8 pass, 0 fail, 0 skip** |
| `ICFWALK_REQUIRE_APP=1 npm test` | Node/HTTP/Playwright **155 pass, 0 fail, 0 skip**; CFML **178 pass, 0 fail, 0 skip** |
| `npm run validate:handoff` | ok, 51 checks, 0 errors |
| `node --check` on every `.js` and `.mjs` | 34 files, 0 failures |

CFML rises from 170 to **178**: the eight new publish cases. No existing case was removed, weakened
or turned into a skip, and the Phase 5 totals are unchanged within the same run.

### Unresolved and not verified (Phase 6 foundation)

1. **Adobe ColdFusion 2023 and SQL Server 2016 remain unverified**, unchanged from Phase 5. The
   publish path adds a second `UPDLOCK, ROWLOCK` user, so it inherits that limitation directly: the
   serialization it depends on is proved on SQL Server 2022 only.
2. **Concurrent publish is argued from the lock, not yet forced.** `WalkSummaryCoherenceTest` forces
   its interleaving deterministically through an interception seam; publishing has no equivalent
   spec yet. The `WHERE status = N'DRAFT'` on the publish write and the read-back are what make a
   double publish safe if two ever did race.
3. **ADM-02, ADM-06, ADM-07, ADM-08 are not started**, nor is any admin UI.
4. **The Phase 5 freeze tag could not be published.** The tag `phase-5-freeze` was created locally on
   `e55ec08`, but `git push origin refs/tags/phase-5-freeze` is refused with HTTP 403 by the session
   credential, which permits branch refs (including new ones) and not tag refs. The verified baseline
   is unaffected -- it is the commit, not the label -- but the tag itself has to be pushed by a
   credential that may write tags.

## Exact recommended starting point for the rest of Phase 6

Superseded in part: the section above ("Phase 6 foundation") has since built the publish transaction
and published immutability (ADM-03 partial, ADM-04 and ADM-05 at the service and endpoint level).
What remains of Phase 6 is **ADM-02 preview, ADM-06 new DRAFT from a published version with compare,
ADM-07 retire, ADM-08 placeholder review queue, and the admin UI for all of it**. The guidance below
was written before that foundation existed and still applies to the remainder; where it says Phase 6
has not been started, read it as the remainder above.

1. Read `docs/IMPLEMENTATION_PLAN.md` Phase 6, `docs/ARCHITECTURE.md` ("What Phase 6 builds on" and
   the Phase 5 section), and `docs/ACCEPTANCE_TRACKING.md` rows ADM-01..08.
2. Publishing must freeze a snapshot and leave existing walks on their pinned versions (WALK-11 is
   already proven). Both summary formatters are driven by `behavior.export.fileNamePattern` and the
   `email_workflow` item's `settings.selectableParts`, so a publish that changes either changes the
   export: regenerate and re-review the vectors (`npm run vectors:summary`, `npm run oracle:summary`)
   as part of that work.
3. Two content-owner decisions are waiting and would each retire a presentation map: the
   conditional-card `displayOrder` and a `settings.titleTemplate` for the content-area heading. An
   `exportLabel` item setting would retire `PART4_LABELS`.
4. The admin UI takes over the import/publish operations the maintenance endpoints do today.

## Phase 6 publish-foundation correction (superseded by the second correction below)

Correction-only session against an independent audit of the Phase 6 foundation
(`5b243ed3d5a27142e65cdfbba8fc113ed65853e1`). It corrects that foundation; it does **not** add any
of the remaining Phase 6 scope. **This is a correction candidate awaiting independent
re-verification: Phase 6 is not frozen and not complete.**

Starting point: branch `claude/icfwalk-phase-6-admin-publish` at
`5b243ed3d5a27142e65cdfbba8fc113ed65853e1`, clean tree, with the frozen Phase 5 baseline
`e55ec08af5b8622db5823b6e353423b891918549` verified as an ancestor and its tree hash
`403d964ce250d6b089419a34ac29b91fa0915a38` confirmed.

### What was wrong, and what each fix is

**A. Publishing proved self-consistency, not validity.** The audited publish path proved that the
stored snapshot hashed to its stored checksum and that the snapshot's definitions equalled the
definitions SQL Server held. A DRAFT carrying the *same invalid content* in both places satisfies
both checks perfectly and was published. Structural validation existed only in
`InstrumentConfigValidator`, over the authoring document, at import.

The rules are now in one place. `src/instrument/DefinitionValidator.cfc` holds the authoritative
semantic rule set over **normalized definitions** -- the representation the importer produces, the
compiler serializes into the snapshot, and `loadNormalizedDefinitions` reads back out of SQL Server.
`InstrumentConfigValidator` keeps only what is meaningful for an inbound document (authoring ids,
`conditionsJson` as text, the DRAFT declaration) and delegates the rest to the shared validator on
the normalized form of that document. `InstrumentPublishService` runs the same component, under the
version's row lock, on the stored snapshot's envelope, on the snapshot's definitions, and on the
persisted definitions **independently** -- because agreeing with each other is exactly what a
corrupted DRAFT does. Snapshot bytes and checksum are untouched on success; publishing still never
recompiles.

**B. Immutability was a helper nobody called.** `assertDraftForWrite` existed and was invoked by no
production mutator; every `DefinitionRepository` method would have happily overwritten a PUBLISHED
version, and `deleteVersionCascadeUnchecked` deleted one on request. The boundary is now
structural: every mutator resolves and locks the owning `instrument_version` row
(`UPDLOCK, ROWLOCK`) and refuses a non-DRAFT before any write; a method handed only a child id
resolves the owner from the database rather than from its arguments; and every statement carries
`status = N'DRAFT'` in its own predicate, so a bypassed guard still writes nothing. The unchecked
cascade is gone -- `deleteDraftVersionCascade` refuses a frozen version like everything else, and
fixture teardown moved to the test-only `tests/cfml/support/FixtureCleanup.cfc`, which no
application code references.

**C. Dimensions and values were global, and the importer rewrote them in place.** So importing V2
with a renamed dimension, or a relabelled, reordered, deactivated or dropped value, silently changed
what a published V1's definitions said -- invisibly, because V1's snapshot did not move. Migration
`006` splits identity from meaning: `icf.dimension_definition` and `icf.dimension_value` keep
`dimension_id`, `code`, `value_id` and `value_code` as immutable reporting identity (created once,
never updated), while label, data type, reportability, sensitivity, settings, activity, membership,
order and effective window move to `icf.instrument_dimension` and the new
`icf.instrument_dimension_value`. `loadNormalizedDefinitions`, the render model and the walk path's
definition index all read the version-scoped rows. A walk's stored `value_id` still means the same
thing across versions, so cross-version reporting identity is preserved.

**D. Refused-write audits died with their transaction.** A record written inside a failing mutation
rolls back with it, so a refused import or discard left no trace. Both now use the shape `publish()`
already had: capture a descriptor inside the transaction, roll back, write exactly one
`INSTRUMENT_VERSION_WRITE_REFUSED` event afterwards, rethrow the established typed error. Details
carry lifecycle facts only.

**E. Publication could name nobody.** `publish()` defaulted `actorUserId` to `""` and
`markPublished` had the same default. The publisher is now required at the service boundary,
validated as a GUID, checked against `icf.app_user` under the lock, read back from the stored row
before the success audit is written, required again by `markPublished`, and enforced by
`CK_instrument_version_publisher_required`. Over HTTP it comes from the authenticated principal
only: the route takes **no request body at all** and refuses a non-empty one with 400
`PUBLISH_BODY_NOT_ALLOWED`, so a client cannot believe it supplied an actor.

**F. The publish route had no live HTTP coverage.** The audited candidate's Node total was the
Phase 5 count. `tests/node/admin-publish.test.mjs` now drives the real route against the running
application and real SQL Server.

**G. A lock-order inversion, found by the gate rather than by the audit.** Adding the instrument
join to `findVersionByIdForUpdate` (needed for the snapshot identity check) gave publication the
order `instrument_version` → `instrument`, while the importer took `instrument` (exclusive, via
`updateInstrument`) → `instrument_version`. The first full `ICFWALK_REQUIRE_APP=1 npm test` run
deadlocked on the publish-versus-mutation race. `importConfig` now takes the version lock first and
updates the instrument row after it, so both paths share one order, and a repeated-race regression
guards it.

### Files changed

| File | Change |
| --- | --- |
| `src/instrument/DefinitionValidator.cfc` | **New.** The authoritative semantic rule set over normalized definitions, plus snapshot-envelope and identity validation. |
| `src/instrument/InstrumentConfigValidator.cfc` | Keeps the import-document-only rules; delegates every reusable rule to `DefinitionValidator` on the normalized form. |
| `src/instrument/InstrumentPublishService.cfc` | Validates envelope, snapshot definitions and persisted definitions under the lock; requires and verifies a publisher; audits refusals after rollback with an actor the audit foreign key accepts. |
| `src/instrument/DefinitionRepository.cfc` | `requireDraftVersion` / `requireDraftOwnerOf` and status-qualified DML on every mutator; `deleteDraftVersionCascade` replaces the unchecked cascade; version-scoped dimension reads and writes; `userExists`; `markPublished` requires a publisher and verifies it. |
| `src/instrument/InstrumentImportService.cfc` | One lock order (version before instrument); dimension/value identity created once and never updated; version-scoped dimension and value writes; durable refusal audits for import and discard; optional identity overrides. |
| `src/walks/WalkRepository.cfc` | The pinned version's definition index reads version-scoped dimensions and values, so a later import cannot change which values an older version accepts. |
| `src/controllers/AdminInstrumentController.cfc` | The publish route takes no request body and refuses one. |
| `src/controllers/MaintenanceController.cfc` | `instrumentCode` / `versionLabel` import overrides (maintenance-guarded); fixture cleanup also removes fixture instruments and their versions, before the fixture users they reference. |
| `src/Bootstrap.cfc` | Wires `definitionValidator`; `definitionRepository` gains `errors`. |
| `database/006_version_scoped_dimensions.sql` | **New.** Version-scoped dimension columns and `icf.instrument_dimension_value` with an exact non-destructive backfill; `CK_instrument_version_publisher_required`, which refuses to invent a publisher. |
| `database/README.md`, `scripts/db/apply-schema.mjs` | Migration `006` in the run order. |
| `tests/cfml/specs/DefinitionValidatorTest.cfc` | **New.** 45 cases: the shared rule set at its own boundary, including the classes SQL constraints make unpersistable. |
| `tests/cfml/specs/InstrumentImmutabilityTest.cfc` | **New.** 8 cases: every mutator against PUBLISHED and RETIRED, the mutator inventory, durable refusal audits. |
| `tests/cfml/specs/DimensionVersionIsolationTest.cfc` | **New.** 8 cases: V1 unchanged by V2, cross-version reporting identity, the walk index, direct writes to the shared rows. |
| `tests/cfml/specs/InstrumentPublishServiceTest.cfc` | 27 cases: publisher attribution and fifteen checksum-matching semantic refusals added. |
| `tests/cfml/support/FixtureCleanup.cfc` | **New.** Test-only fixture teardown, reachable only by the CFML test runner. |
| `tests/node/admin-publish.test.mjs` | **New.** 13 live HTTP cases for the publish route. |
| `tests/node/schema-contract.test.mjs`, `tests/node/db-scripts.test.mjs` | Migration `006` contract and behavior, including the publisher precondition and its refusal to invent one. |
| `tests/cfml/specs/InstrumentImportServiceTest.cfc`, `InstrumentScopeTest.cfc` | Fixtures name a real publisher, which the new database constraint requires. |
| `docs/ENDPOINTS.md`, `docs/DATA_CONTRACT.md`, `docs/ARCHITECTURE.md`, `docs/ACCEPTANCE_TRACKING.md` | The publish route, the shared validation path, the write boundary, the lock order, the publisher invariant, the dimension design, and acceptance rows from executed evidence. |
| `manifest.json` | Refreshed hashes for the two supplied-package documents this correction edits (`docs/DATA_CONTRACT.md`, `database/README.md`). |

### Tests and results

Environment: `docs/evidence/phase6-correction-environment.md`. Full transcript:
`docs/evidence/phase6-correction-release-gate.txt`. Red-before-green:
`docs/evidence/phase6-correction-red-before-fix.md`.

| Command | Result |
| --- | --- |
| `ICFWALK_REQUIRE_APP=1 npm test` (the full live gate) | Node/HTTP/Playwright **169 pass, 0 fail, 0 skip**; CFML **258 pass, 0 fail, 0 skip** |
| `npm run validate:handoff` | ok, 51 checks, 0 errors |
| `npm run test:package` | 19 pass, 0 fail, 0 skip |
| `node --check` on every `.js` and `.mjs` | 35 files, 0 failures |
| `npm run vectors:summary:check` | `summary-vectors.json is current.` |
| Migration `006` on a clean database | applied; 23 `icf` tables; idempotent over three consecutive applications |
| Migration `006` over the Phase 5 schema with data | applied; backfilled the placed dimension and all of its values exactly; re-application inserts nothing |
| Migration `006` publisher precondition | refuses with error 50053 and the row count when a non-DRAFT row has no publisher, rolls its whole transaction back, and applies unchanged once the row is resolved |

Totals against the audited candidate: CFML **178 → 258**, Node **155 → 169**. No existing case was
removed, weakened, skipped or renamed away.

### Unresolved and not verified

1. **Adobe ColdFusion 2023 and SQL Server 2016 remain unverified.** Everything above ran on Lucee
   6.2.8.20 and SQL Server 2022. Migration `006` is written to SQL Server 2016 syntax and statically
   checked for it, but running it on 2016 was not possible here and is not claimed.
2. **The `phase-5-freeze` tag does not exist**, locally or on the remote (`git tag -l` and
   `git ls-remote --tags origin` are both empty). There was nothing to verify and nothing to push,
   and this correction did not create it. An earlier record says the tag was created locally and its
   push refused with HTTP 403; that local tag was in a previous container and is gone. Creating and
   pushing `phase-5-freeze` at `e55ec08af5b8622db5823b6e353423b891918549` remains an open repository
   action for an authorized operator. This is a repository-permission item, not a code or test
   result.
3. **ADM-02, ADM-06, ADM-07, ADM-08 are not started**, nor is any administration UI, nor Phase 7.
4. **This correction has not been independently audited.** It is a correction candidate, ready for a
   fresh independent audit.

## Phase 6 publish-foundation second correction (superseded by the third correction below)

Correction-only session against a second independent audit, this one of the first correction
(`332f89f929ff5a9f1e81fe5273c830698fdc80af`). It corrects that candidate; it does **not** add any of
the remaining Phase 6 scope. **This is a correction candidate awaiting independent
re-verification: Phase 6 is not frozen and not complete.**

Starting point: branch `claude/icfwalk-phase-6-admin-publish` at
`332f89f929ff5a9f1e81fe5273c830698fdc80af`, clean tree, with the frozen Phase 5 baseline
`e55ec08af5b8622db5823b6e353423b891918549` verified as an ancestor and no commits after the audited
candidate. (The container's checkout was one commit stale at
`5b243ed3d5a27142e65cdfbba8fc113ed65853e1`; that was resolved by a plain fast-forward to the
published remote tip before any edit. Nothing was reset, discarded or rewritten. See
`docs/evidence/phase6-second-correction-environment.md`.)

### What was wrong, and what each fix is

**A (HIGH). Publication validity did not imply runtime renderability.** `DefinitionValidator`
accepted states `RenderModelBuilder` throws on, and -- worse -- states it builds while silently
dropping content. Checksums and the drift check cannot see either: the rows and the snapshot agree
perfectly on content the renderer will not build.

The validator now carries a rule for every one of them: exactly one active root section
(`SECTION_ROOT_MISSING`, `SECTION_ROOT_AMBIGUOUS`), no active section, item or placement orphaned
from that root (`*_ORPHANED_FROM_ROOT`), a placement that names a section
(`PLACEMENT_SECTION_REQUIRED`), only item types the runtime implements, only option filters it
implements and only with a source dimension this version offers (`UNSUPPORTED_OPTION_FILTER`,
`OPTION_FILTER_SOURCE_MISSING`), an active item's response set active (`RESPONSE_SET_INACTIVE`) and,
for a choice item, carrying at least one active option (`RESPONSE_SET_NO_ACTIVE_OPTIONS`), an active
placement's dimension active (`DIMENSION_INACTIVE`) and, for a list dimension, offering at least one
active value (`DIMENSION_NO_ACTIVE_VALUES`), and an active rule's target and sources still active
after the runtime's filter (`RULE_TARGET_INACTIVE`, `RULE_SOURCE_INACTIVE`).

`MULTI_CHOICE` and `SHORT_TEXT` are **removed from the accepted item types**. Neither has a renderer
layout, and `icf.walk_response` stores one selected option per item, so `MULTI_CHOICE` had nowhere
to be persisted even if it were drawn. Neither appears anywhere in the shipped instrument. They are
refused at import and at publication rather than half-supported.

Because a hand-maintained rule set drifts from the thing it describes -- which is precisely this
defect -- import and publication now also run the **real renderer** over the compiled snapshot
(`src/instrument/RenderContractValidator.cfc`, new). A throw becomes a stable
`{ code, message, path }` issue instead of escaping as a runtime 500, and the built model is counted
against the definitions so a build that succeeds while dropping a subtree is refused as
`RENDER_MODEL_INCOMPLETE`.

The shared vocabulary now has one home. Item types, choice types, selection modes, target types,
effects, source types, operators, data types, logics, the order limit, the retired-content strings,
the placeholder review status and the option-filter table live on `DefinitionValidator` and are read
from it by `InstrumentConfigValidator`, `SnapshotCompiler` and `RenderModelBuilder`.

**B (HIGH). Migration `006` inferred membership on every re-application.** Its legacy backfill asked
"which global values does this version not have a row for?" -- correct as a description of the
one-time transition, wrong as a condition to re-evaluate. Once V2 minted a new value under a shared
dimension, a re-applied `006` inferred it into **published V1**, changing V1's normalized
definitions and the walk values it accepted while its snapshot bytes, checksum and `row_version`
stayed put. `WalkRepository.definitionIndex()` caches by that checksum, so a running application
kept serving the old index and a restarted one silently served a different instrument.

Eligibility is now tied to the transition itself, recorded durably in the new
`icf.schema_migration_state` table. A database with no `instrument_dimension_value` runs the
backfill once and records `COMPLETED`. A database that already has the table -- the earlier form of
`006` created it and backfilled in one transaction, so its existence is proof the backfill committed
-- is **adopted**: recorded `ADOPTED_PRE_STATE`, nothing inserted. After that the backfill never
runs again, for any version, in any status. A half-finished transition (table present, nothing
recorded, and a placement of a dimension that has values carrying no version rows) **fails** with
error 50054 and the count rather than guessing. Nothing is auto-deleted: `database/README.md` now
carries two read-only detection queries and a reviewed remediation procedure that requires an
authorized decision wherever intended historical membership cannot be read from the version's own
frozen snapshot.

**C (HIGH). The shared and global write boundary was open, and the inventory said so.** The
immutability inventory carried an exclusion list -- `createInstrument`, `updateInstrument`,
`createDimensionIdentity`, `createDimensionValueIdentity` -- whose members were tested not at all.
One of them was the defect: the importer called `updateInstrument` on the shared `icf.instrument`
row on every re-import, straight from the document, and `icf.instrument.active` is part of
`SnapshotService.currentVersion()`'s predicate. Importing a V2 DRAFT whose document said
`"active": false` removed an already PUBLISHED V1 from the runtime, with no version row changed and
nobody named.

Ownership is now explicit and enforced. `code` is identity, written once. `name` and `description`
are **version** facts: they are compiled into each version's snapshot and served from it, so V2 may
describe the instrument differently from V1 and each walk sees its own version's wording -- stored
at the right scope, not ignored. `active` is a shared operational decision: an import that declares
it differently from the stored row is refused atomically with `SHARED_METADATA_CONFLICT` and
audited. `updateInstrument` is gone, replaced by `updateInstrumentMetadata`, which requires a named
known `icf.app_user`, takes the instrument row under its own `UPDLOCK, ROWLOCK`, and is reached only
by the new `src/instrument/InstrumentMetadataService.cfc` -- which audits one
`INSTRUMENT_METADATA_UPDATED` event and has **no route**. `createDimensionIdentity` and
`createDimensionValueIdentity` now take the requesting version id and call `requireDraftVersion`
inside the repository, before the INSERT, so global reporting identity is minted only on behalf of a
DRAFT and a caller's earlier guard is not accepted in its place. The exclusion list is gone: every
public mutator is in the inventory, under the contract it actually has, and two inventory tests fail
if a mutator escapes the list or the list names something that no longer exists.

**D (MEDIUM). Import ran two semantic rule sets.** `InstrumentConfigValidator` kept a complete
second copy of the semantics *and* delegated to `DefinitionValidator`, so import was judged by two
rule sets and publish by one. It now keeps only what an inbound document can be wrong about:
parseability and document shape, authoring-id uniqueness and resolution, `conditionsJson` as text,
the DRAFT declaration, and the content-review placeholder warnings. Everything else is the shared
validator, on the normalized form. Its duplicate constants are gone.

**E (MEDIUM). The snapshot envelope was not enforced, and the canonical-byte claim was not
checked.** The validator accepted a missing `counts` block, an empty one, or missing members, and
noticed a non-numeric or negative count only as a mismatch with the array length. All nine members
are now required, each a whole non-negative number equal to the definitions' own, with no extra
members (`SNAPSHOT_COUNTS_MISSING`, `SNAPSHOT_COUNTS_INVALID`, `SNAPSHOT_COUNTS_MISMATCH`,
`SNAPSHOT_COUNTS_UNEXPECTED`). And the documented canonical-byte invariant is now enforced:
publication parses the stored snapshot, re-serializes it through the one canonicalizer and requires
byte-for-byte equality (`SNAPSHOT_NOT_CANONICAL`). It refuses rather than rewriting, because
rewriting would move the checksum the DRAFT was reviewed under.

**F (MEDIUM). Two refusals left no trace.** The DRAFT-in-use branches of import and `discardDraft`
threw `INSTRUMENT_VERSION_IN_USE` without marking the refusal, so the catch that writes the
post-rollback audit had nothing to persist. Being DRAFTs, they had no status guard behind them
either, so the refusal record was the only evidence there would ever have been. Both now mark before
they throw, with `operation` and a stable `reason` of `VERSION_IN_USE`.

**G (MEDIUM). Concurrency evidence was probabilistic.** The repeated `Promise.all` races remain, as
stress coverage, but they cannot show that two transactions ever overlapped.
`tests/cfml/support/InterceptingDefinitionRepository.cfc` (new, test-only) fires a callback
immediately after the statement that takes the version's row lock.
`PublishConcurrencyBarrierTest` uses it to hold transaction A there, start B, observe that B
**cannot finish**, release A by letting it commit, and then assert the one permitted serial outcome
and the final state -- for publish/publish, publish/import and import/publish. The decorator is
constructed by the spec and handed to a service the spec constructs; the container never holds it
and no route reaches it, so no production configuration exposes a lock hook.

**H (LOW). The no-body contract was not the documented one.** The publish route tested
`structCount(req.body)`, which cannot tell a request with no body from one carrying a literal `{}`
-- both parse to an empty struct -- so `{}` was accepted while the documentation said the endpoint
takes no body. The route now asks whether any body bytes arrived, from `Content-Length` falling back
to the parsed content for a chunked request. `Content-Length: 0` is not a body.

Two further defects surfaced from that case and are fixed here: Lucee returns an empty string from
`getHttpRequestData()` for a whitespace-only body, so whitespace could not be seen at all through
the parsed content; and a body of literal `null` parses to CFML null, so reading it back raised
`variable [PARSED] doesn't exist` and the request escaped as a **500** instead of the documented
400. `Router.buildRequest` now tests `isNull()` before `isStruct()`.

**One harness defect, found by the release gate itself.** The whole CFML suite runs inside one
`/api/maintenance/tests/run` request, and Lucee is configured for it (`LUCEE_REQUESTTIMEOUT=600`).
The *client* never had the same allowance: Node's `fetch` abandons a request after five minutes
without response headers, and none are sent until the suite finishes. At 258 cases that ceiling was
never reached; at 330 it was, and the first full run of this correction failed as `fetch failed`
after 300.7 seconds -- and the abort also skipped every spec's `afterAll`, leaving a fixture version
behind that then failed an unrelated later test (`shell.test.mjs` found a fixture label where it
expected the seeded one). The suite is now requested in three deterministic parts
(`?part=<n>&of=<m>`, specs dealt round-robin over a stable name order), the reports are summed, and
`cfml-suite.test.mjs` additionally asserts that the set of specs that ran equals the set of spec
files on disk -- so a partition that silently dropped a spec fails rather than looking healthy.
Nothing was filtered out, shortened or skipped to achieve this: all 330 cases still run, and all
still have to pass.

### What was executed, and what it proves

Every command below was run personally, on the live environment described in
`docs/evidence/phase6-second-correction-environment.md`, against the final tree. The development
database was dropped, recreated, taken through `001` to `006` and re-seeded immediately before the
release run, so the gate ran on a database whose whole history is known.

| Command | Result |
| --- | --- |
| CFML suite, filter `ValidatorRendererContract` | 18 passed, 0 failed, 0 skipped |
| CFML suite, filter `ImportPublishEquivalence` | 14 passed, 0 failed, 0 skipped |
| CFML suite, filter `InstrumentPublishService` | 48 passed, 0 failed, 0 skipped |
| CFML suite, filter `InstrumentImmutability` | 14 passed, 0 failed, 0 skipped |
| CFML suite, filter `SharedInstrumentBoundary` | 7 passed, 0 failed, 0 skipped |
| CFML suite, filter `Migration006Lifecycle` | 3 passed, 0 failed, 0 skipped |
| CFML suite, filter `PublishConcurrencyBarrier` | 3 passed, 0 failed, 0 skipped |
| `node --test tests/node/admin-publish.test.mjs` (`ICFWALK_REQUIRE_APP=1`) | 14 passed, 0 failed, 0 skipped |
| `node --test tests/node/migration-006-transition.test.mjs` | 4 passed, 0 failed, 0 skipped |
| `node --test tests/node/db-scripts.test.mjs` | 1 passed, 0 failed, 0 skipped |
| `npm run validate:handoff` | ok, 51 checks, 0 errors |
| `npm run test:package` | 19 passed, 0 failed, 0 skipped |
| `node --check` over every `.js`/`.mjs` | 36 files, 0 failures |
| `ICFWALK_REQUIRE_APP=1 npm test` (the full live gate) | see below |

Migration `006`, by state:

| State | Command | Result |
| --- | --- | --- |
| Clean database (Phase 5 schema, no data) | `migration-006-transition.test.mjs` | Applies; `legacy_membership_backfill_ran_now = 1`, `state = COMPLETED`, 0 value rows |
| Phase 5 schema **with representative data** | `db-scripts.test.mjs` | Applies; backfills exactly what `loadNormalizedDefinitions` already returned (labels, orders and activity asserted row by row) |
| Immediate re-application | both | No-op; `ran_now = 0`, no duplicate rows, no second table |
| Re-application **after a later version mints a new global value** | `db-scripts.test.mjs` | The published version does **not** gain it; checksum and `row_version` unmoved |
| A database the earlier form already migrated | `migration-006-transition.test.mjs` | Adopted: `state = ADOPTED_PRE_STATE`, nothing inserted, and a further re-apply is still a no-op |
| A half-finished transition | `migration-006-transition.test.mjs` | Refused with error 50054 and the count; whole transaction rolled back; nothing recorded |
| A dimension with no global values at all | `migration-006-transition.test.mjs` | Not treated as ambiguous |
| The full V1/V2 lifecycle, cached and uncached | `Migration006LifecycleTest` | V1's version-scoped rows, normalized definitions, snapshot bytes, checksum, row version, allowed walk values and render model all unchanged, from the primed cache **and** from a fresh uncached load; V2 keeps its own value |
| Publisher precondition | `db-scripts.test.mjs` | Refuses with 50053 and the count when a non-DRAFT row has no publisher, rolls back, and applies unchanged once resolved |


### The release gate

```
ICFWALK_REQUIRE_APP=1 npm test
```

Run on the final tree, against the live stack, after the development database had been dropped,
recreated, taken through `001` to `006` and re-seeded:

```
# tests 174
# pass 174
# fail 0
# cancelled 0
# skipped 0
# todo 0
exit 0
engine=Lucee 6.2.8.20 passed=330 failed=0 skipped=0 ms=274011 parts=3
```

**Node / HTTP / Playwright: 174 passed, 0 failed, 0 skipped.**
**CFML, live in-run: 330 passed, 0 failed, 0 skipped.**

`ICFWALK_REQUIRE_APP=1` makes an unreachable application a failure rather than a skip, so `skipped 0`
means every application-dependent case really ran. Totals against the audited candidate: CFML
**258 -> 330**, Node **169 -> 174**. No existing case was removed, weakened, skipped or renamed away.

The new CFML specs, as reported by that run: `ValidatorRendererContractTest` 18,
`ImportPublishEquivalenceTest` 14, `SharedInstrumentBoundaryTest` 7, `Migration006LifecycleTest` 3,
`PublishConcurrencyBarrierTest` 3, plus 21 new semantic and envelope cases in
`InstrumentPublishServiceTest` (27 -> 48) and 6 new cases in `InstrumentImmutabilityTest` (8 -> 14).

### Unresolved and not verified

1. **Adobe ColdFusion 2023 and SQL Server 2016 remain unverified.** Everything above ran on Lucee
   6.2.8.20 and SQL Server 2022 (16.0.4295.3). Migration `006` is written to SQL Server 2016 syntax
   and statically checked for it, and every construct this correction adds to it is a 2016
   construct, but *running* it on 2016 was not possible here and is not claimed. This is a
   deployment gate, and it is not the same thing as the implementation acceptance gate above, which
   did pass in full on Lucee and SQL Server 2022.
2. **The `phase-5-freeze` tag does not exist**, locally or on the remote (`git tag -l` and
   `git ls-remote --tags origin` are both empty). There was nothing to verify and nothing to push,
   and this correction did not create, move or force-push it. Creating and pushing `phase-5-freeze`
   at `e55ec08af5b8622db5823b6e353423b891918549` remains an open repository action for an authorized
   operator. This is a repository-permission item, not a code or test result.
3. **ADM-02, ADM-06, ADM-07, ADM-08 are not started**, nor is any administration UI, nor Phase 7.
   ADM-02 preview, ADM-06 clone-and-compare, ADM-07 retirement and ADM-08 the placeholder review
   queue all remain PENDING, deliberately and entirely.
4. **This correction has not been independently audited.** It is a correction candidate, ready for a
   fresh independent audit. Phase 6 is **not** frozen and **not** complete, and no `phase-6-freeze`
   tag was created.

## Phase 6 publish-foundation third correction (superseded in part by the fourth correction below)

Correction-only session against a third independent audit, this one of the second correction
(`bff53f53eaacfed977eefd4648577ed5cbba196c`), whose verdict was **NOT READY TO ACCEPT THE PHASE 6
PUBLISH FOUNDATION**. It corrects that candidate; it does **not** add any of the remaining Phase 6
scope. **This is a correction candidate awaiting independent verification: Phase 6 is not frozen,
not complete, and not accepted.**

Starting point: branch `claude/icfwalk-phase-6-admin-publish` at
`bff53f53eaacfed977eefd4648577ed5cbba196c`, clean tree, with the frozen Phase 5 baseline
`e55ec08af5b8622db5823b6e353423b891918549` verified as an ancestor and no commits after the audited
candidate. (The container's checkout was two commits stale at
`5b243ed3d5a27142e65cdfbba8fc113ed65853e1`; that was resolved by a plain fast-forward to the
published remote tip before any edit. Nothing was reset, discarded, force-pushed or rewritten. See
`docs/evidence/phase6-third-correction-environment.md`.)

Everything the audited candidate got right is preserved: the shared normalized semantic validator,
import and publish preflighting through the real render model builder, migration `006`'s one-time
membership transition state, version-scoped dimension and dimension-value semantics, the removal of
ordinary import writes to an existing `icf.instrument` row, durable post-rollback refusal audits,
canonical snapshot byte verification, the nine-member snapshot count envelope, and the raw no-body
distinction on the publish endpoint.

### What was wrong, and what each fix is

**1 (HIGH). Shared metadata read the row before it locked it.**
`InstrumentMetadataService.updateMetadata` read `icf.instrument` with an ordinary unlocked
`findInstrumentByCode`, derived a **complete** replacement row from it -- a patch that changes one
field restates the stored value of every field it omits -- and only then called
`DefinitionRepository.updateInstrumentMetadata`, where the row lock was finally taken. A lock
acquired after a read does not protect that read. Two concurrent partial patches both restated what
they had read before the other ran, so whichever committed second silently undid the first; because
`icf.instrument.active` is part of `SnapshotService.currentVersion()`'s predicate, the change that
got undone could be a deliberate "take this published version out of service", and the audit trail
recorded a `before` image that was never the row that request replaced. Import had the same shape:
it read `icf.instrument` before locking the version and then judged `SHARED_METADATA_CONFLICT`
against that earlier object, so an authorized change committing in the gap was invisible.

*Fix.* `DefinitionRepository.lockInstrumentByCode` / `lockInstrumentById` take the row under
`UPDLOCK, HOLDLOCK, ROWLOCK` and read it in the same statement. The metadata operation's locked
read, merge, update and audit are now one transaction, and `updateInstrumentMetadata` performs the
UPDATE only, with the lock as its documented caller contract. Import re-reads the shared row under
that lock **after** its version lock -- preserving the declared version-then-instrument order -- and
decides the conflict on it. The metadata operation requests no version lock at all, so it cannot
invert the order. The guarantee is the database transaction and its row locks, never an
application-process lock: the deployment can run more than one process or node.

**2 (HIGH). A known user was being treated as an authorized administrator.**
The operation required a GUID actor and the repository checked `userExists`. That is an **integrity**
check for `icf.audit_event.actor_user_id`'s foreign key -- every row in `icf.app_user` satisfies it --
and it was standing in for authorization, so any existing user could be supplied as the alleged
authorizer by any internal caller. The existing suite's "successful" actor had never been granted
`instrument.manage`. The absence of an HTTP route is not authorization either.

*Fix.* `updateMetadata` takes the **current principal** and asks the central `AuthorizationService`
for global `instrument.manage` before any mutation. There is no actor argument: the audit actor is
the principal's `userId` and cannot be named, substituted or overridden from the call site.
`Bootstrap` constructs the service after the authorization model so the dependency is real, not
nominal. `userExists` stays, documented in source, `ARCHITECTURE.md` and `DATA_CONTRACT.md` as an
integrity check and not as authorization. The patch itself is validated strictly before any
mutation: only `name`, `description`, `active`; an unknown member refused rather than ignored;
`name` a non-blank JSON string within `nvarchar(200)`; `description` a JSON string within
`nvarchar(1000)`; `active` an **actual** JSON boolean, never coerced (in CFML `isBoolean("144")`,
`isBoolean(0)` and `isBoolean("no")` are all true, and a coerced `false` removes a published version
from the runtime); at least one supported member. A patch with no material difference is a
documented **no-op** (`docs/OPEN_DECISIONS.md`): no write, no audit, no `row_version` movement. The
operation is still unrouted, and that is now stated as a scope decision rather than a control.

**3 (HIGH). Global identity creation was not atomically DRAFT-qualified.**
`createDimensionIdentity` and `createDimensionValueIdentity` called `requireDraftVersion` and then
issued an **unconditional** INSERT. Inside the import's transaction that is sound. But these are
public repository methods called directly, outside any transaction, where the `UPDLOCK` lives only
for the length of the SELECT: a publish could freeze the version in the gap and the INSERT ran
anyway, minting permanent global reporting identity on the authority of a version that was no
longer a DRAFT.

*Fix.* The authority decision now lives inside the minting statement. Each creator issues one
`INSERT ... SELECT` whose source is the owning `icf.instrument_version` row under `UPDLOCK, ROWLOCK`
and predicated on `status = N'DRAFT'`, with `OUTPUT INSERTED` returning the row the database reports
inserting. One statement is atomic, so no caller has a window to lose, with or without a
transaction; when the predicate matches nothing, nothing is inserted and the caller receives a typed
non-DRAFT refusal rather than a GUID for a row that does not exist. SQL Server 2016 compatible.

**4 (MEDIUM). The concurrency tests inferred the competing request's arrival.**
`PublishConcurrencyBarrierTest` held transaction A, started B, joined B with `threadJoin(..., 6000)`
and treated `status != "COMPLETED"` as proof that B had reached the competing row lock. A scheduler
delay, a datasource-pool wait or setup work produces the same reading, and so does an implementation
whose lock does nothing on a run where B merely started late.

*Fix.* A two-sided barrier. `tests/cfml/support/ConcurrencyBarrier.cfc` carries two announcements
across the thread boundary on `java.util.concurrent` structures: A emits `A_LOCKED` from inside its
transaction once it holds the production lock and has done nothing else, and B emits
`B_AT_COMPETING_BOUNDARY` immediately **before** the database call that will contend for it, through
a new `armBefore` seam on the decorating repository. The spec blocks on a real `LinkedBlockingQueue`
poll -- no CFML sleep -- and releases A only after hearing B. Non-completion is still asserted, but
only as a supplemental fact after B's arrival has been independently observed. Seven deterministic
cases: publish/publish, publish/import, import/publish, publish/new dimension identity, publish/new
dimension-value identity, metadata/metadata, and import's shared-state check/authorized metadata
update. The interception components remain test-only: nothing in `src/` references them, the
container never holds them, and no route, environment flag or remotely activatable hook reaches
them.

**5 (MEDIUM). Snapshot counts accepted numeric strings, and top-level `null` escaped the refusal
path.** `DefinitionValidator.checkCounts` used `isNumeric` and loose comparison; in CFML the
java.lang.String `"144"` is numeric for coercion and compares equal to `144`, so a counts block that
did not meet the contract every reader trusts was publishable. The existing `"many"` case proved
only that non-numeric text was rejected. Separately, publication accepted `isJSON("null")`,
deserialized it and handed the result straight to the canonical serializer; on Lucee a top-level
JSON null leaves the variable null and reading it back is an engine error, which fired **before**
`markRefusal`, so the caller received a 500 and the attempt left no durable refusal audit at all.

*Fix.* A shared `src/core/JsonTypes.cfc` decides JSON type from the value's Java class. Counts must
be actual JSON numbers -- strings, booleans, arrays and objects are type errors -- and whole, not
negative, finite and within the supported integer range, with the equality comparison made between
known whole numbers. Publication now establishes that the parsed snapshot is a JSON **object**
before anything dereferences or serializes it, refusing `null`, arrays, strings, numbers and
booleans as a documented 422 `INSTRUMENT_VERSION_NOT_PUBLISHABLE` with a stable `SNAPSHOT_SHAPE`
issue at `$`, one durable refusal audit and no success audit -- the same defensive principle
`Router.cfc` already applies to the request body. Corrupt bytes are never rewritten.

**6 (MEDIUM). The historical remediation DELETE was not scoped to a dimension.**
`database/README.md`'s sample deleted version membership by `version_id` and `value_code`.
`icf.dimension_value.value_code` is unique only *within* a dimension, and the supplied instrument
uses `other` under `school`, `content` and `classType`, so an operator who approved one
`(dimension_code, value_code)` pair removed three. `@@ROWCOUNT` reports 3 either way, so a row-count
check does not catch it.

*Fix.* An exact-identity procedure: a signed-off pair list whose own primary key rejects a repeated
pair, resolution of each pair to an exact `(version_id, dimension_id, value_id)` triple displayed
before any mutation, a typed refusal (error 50060) for anything missing or ambiguous, a transaction
with rollback as the default, a delete of only the resolved rows, `OUTPUT ... INTO` capture of what
was really deleted, an `EXCEPT` comparison of the deleted and approved sets in both directions
(error 50061), and a commit only after that check and an explicit `@signedOff`. SQL Server 2016
compatible.

**7 (LOW). An import document could omit its DRAFT declaration.**
`checkInstrument` rejected a non-DRAFT status only when `instrument.version.status` existed, so a
document that omitted it imported -- silence read as consent on the one field that says which of
three lifecycle states the author believes they are writing. CFML's `!=` is case-insensitive
besides, so `draft` passed as a DRAFT declaration.

*Fix.* The status is required, must be a JSON string, and must equal `DRAFT` case-sensitively
(`compare`), with three distinct stable codes at `$.instrument.version.status`:
`VERSION_STATUS_REQUIRED`, `VERSION_STATUS_INVALID`, `VERSION_STATUS_NOT_DRAFT`. Persisted-version
lifecycle checks are not duplicated here; they stay under the version's row lock.

**Also corrected, because this correction's own verification depended on it.** The CFML suite driver
skipped silently when the application was unreachable even under `ICFWALK_REQUIRE_APP=1`, and that
file carries the entire CFML suite including every new concurrency barrier. It now fails loudly, the
way `admin-publish.test.mjs` and `no-mail.test.mjs` already did. The suite's client ceiling is also
explicit now rather than inherited from undici's 300-second `headersTimeout`, which a healthy but
slower run was reaching and reporting as "fetch failed" -- and which, by aborting mid-suite, skipped
every spec's `afterAll` and left fixtures behind that failed later tests. Neither change gives any
test more room to pass; both make a real result distinguishable from a harness limit.

### Files changed (third correction)

| File | Change |
| --- | --- |
| `src/core/JsonTypes.cfc` | **New.** JSON type decisions from the value's Java class, because CFML's `isNumeric`/`isBoolean` answer a coercion question. Defines no envelope and no canonical form; constructed by its users so no constructor signature changed. |
| `src/instrument/DefinitionValidator.cfc` | Counts must be actual JSON numbers, whole, non-negative, finite and in range; equality compared between known whole numbers. |
| `src/instrument/InstrumentPublishService.cfc` | The parsed snapshot must be a JSON object, established before any dereference or serialization; `SNAPSHOT_SHAPE` refusal with a durable audit. |
| `src/instrument/InstrumentConfigValidator.cfc` | `instrument.version.status` required, a JSON string, exactly `DRAFT` (case-sensitive); three stable codes at one path. |
| `src/instrument/DefinitionRepository.cfc` | `lockInstrumentByCode` / `lockInstrumentById`; `updateInstrumentMetadata` performs the UPDATE only and documents `userExists` as an integrity check; both identity creators are one status-qualified `INSERT ... SELECT` with `OUTPUT INSERTED` and a typed refusal when nothing was minted. |
| `src/instrument/InstrumentMetadataService.cfc` | Takes the principal and requires `instrument.manage`; locked read, merge, update and audit in one transaction; strict patch validation; documented no-op; `descriptionChanged` instead of description text in the audit. |
| `src/instrument/InstrumentImportService.cfc` | Re-reads `icf.instrument` under its own lock after the version lock and decides `SHARED_METADATA_CONFLICT` on that row. |
| `src/Bootstrap.cfc` | `instrumentMetadataService` constructed after `authorizationService`, so the authorization dependency is real. |
| `database/README.md` | The exact-identity remediation procedure replaces the dimension-blind DELETE. |
| `tests/cfml/support/ConcurrencyBarrier.cfc` | **New.** Test-only two-sided barrier over `java.util.concurrent`. |
| `tests/cfml/support/InterceptingDefinitionRepository.cfc` | `armBefore` as well as `armAfter`; seams for the instrument locks, the identity creators and the pre-correction unlocked read. |
| `tests/cfml/support/FixtureCleanup.cfc` | `grantRole` / `principalFor`, so a spec's authorized actor holds the permission because the role data says so. |
| `tests/cfml/specs/PublishConcurrencyBarrierTest.cfc` | Rewritten on the two-sided barrier; two new cases for the global identity creators. |
| `tests/cfml/specs/SharedMetadataConcurrencyBarrierTest.cfc` | **New.** Lost updates in both arrival orders, audit before-images, and import's conflict decision both by ordering and under real lock contention. |
| `tests/cfml/specs/InstrumentMetadataServiceTest.cfc` | **New.** Authorization, strict patch validation, the documented no-op, actor attribution, and the absence of any route. |
| `tests/cfml/specs/GlobalIdentityBoundaryTest.cfc` | **New.** The structural qualification of the minting DML, DRAFT/PUBLISHED/RETIRED behaviour outside any transaction, and both serial outcomes against a concurrent publish. |
| `tests/cfml/specs/InstrumentPublishServiceTest.cfc` | Top-level `null`, array and scalar snapshots; a count stored as the exact matching string; negative, fractional and oversized counts. |
| `tests/cfml/specs/DefinitionValidatorTest.cfc` | Table-driven type cases over all nine count members. |
| `tests/cfml/specs/InstrumentConfigValidatorTest.cfc` | Missing, null, non-string, blank, lower-case, PUBLISHED, RETIRED and valid DRAFT status cases. |
| `tests/cfml/specs/SharedInstrumentBoundaryTest.cfc` | Updated to the principal contract; an actor id is no longer an authorization. |
| `tests/node/remediation-exact-identity.test.mjs` | **New.** Runs the procedure published in `database/README.md` against a real SQL Server, with the repeated `other` code. |
| `tests/node/cfml-suite.test.mjs`, `tests/node/helpers.mjs` | `ICFWALK_REQUIRE_APP` honoured for the CFML suite; an explicit client ceiling instead of undici's inherited default. |
| `docs/*`, `manifest.json` | Documentation corrected to describe what exists, and the manifest refreshed for the supplied files that changed. |

### Unresolved and not verified (third correction)

1. **Adobe ColdFusion 2023 and SQL Server 2016 remain unverified.** All CFML execution was on Lucee
   6.2.8.20 and all SQL on SQL Server 2022; neither target is installable in this container. The new
   SQL constructs (`OUTPUT INSERTED` on an `INSERT ... SELECT`, `OUTPUT ... INTO` on a `DELETE`,
   `EXCEPT`, table variables with a primary key, `;THROW`) are all SQL Server 2016 constructs and are
   checked statically by `schema-contract.test.mjs`, but *running* them on SQL Server 2016 is not
   claimed. The Lucee-specific cases (top-level JSON null, the Java-class type checks) are listed in
   the Adobe ColdFusion 2023 verification checklist and have not been run there.
2. **The `phase-5-freeze` tag still does not exist**, locally or on the remote. This correction did
   not create, move or force-push it. It remains an open repository action for an authorized
   operator.
3. **ADM-02, ADM-06, ADM-07, ADM-08 are not started**, nor is any administration UI, nor Phase 7.
4. **This correction has not been independently audited.** It is a correction candidate. Phase 6 is
   **not** frozen, **not** complete and **not** accepted, and no `phase-6-freeze` tag was created.

## Phase 6 publish-foundation fourth correction (superseded in part by the fifth correction below)

Correction-only session against a fourth independent audit, this one of the third correction
(`a8e97f22ae1639faef5b6e68bf7255dea838f8e2`), whose verdict was **NOT READY TO ACCEPT THE PHASE 6
PUBLISH FOUNDATION** with 0 HIGH, 2 MEDIUM and 2 LOW findings. The audit found all seven defects of
the preceding cycle materially closed, and those fixes are preserved unchanged: the locked shared
metadata read, import's version-then-instrument re-read before `SHARED_METADATA_CONFLICT`, the
current-principal and `instrument.manage` requirement with the actor derived from the principal,
the single status-qualified identity `INSERT ... SELECT` with `OUTPUT INSERTED`, the two-sided
`A_LOCKED` / `B_AT_COMPETING_BOUNDARY` barrier, JSON-number snapshot counts with the typed
non-object refusal, and the exact-identity remediation with the explicit `DRAFT` declaration. No
schema migration, route, dependency, production hook or freeze tag was added, and none of ADM-02,
ADM-06, ADM-07, ADM-08, the administration UI or Phase 7 was started. **This is a correction
candidate awaiting independent verification: Phase 6 is not frozen, not complete and not accepted.**

Starting point, verified before any edit: branch `claude/icfwalk-phase-6-admin-publish` at exactly
`a8e97f22ae1639faef5b6e68bf7255dea838f8e2` (tree `7b2e175afc7668e7d19df7966a59067f7145dacf`), a
completely clean working tree including untracked files, the Phase 5 baseline
`e55ec08af5b8622db5823b6e353423b891918549` an ancestor of HEAD, and the local branch equal to
`origin/claude/icfwalk-phase-6-admin-publish`. No freeze tag exists locally or on the remote.

### What was wrong, and what each fix is

**1 (LOW; audit P6C3-03). Metadata change detection ignored case.** `InstrumentMetadataService.updateMetadata`
compared `toString(before[field]) != toString(after[field])`, and CFML's string `!=` is
case-insensitive. A legitimate rename from `ICFWalk` to `Icfwalk`, or a capitalization-only
description edit, was classified as a no-op: nothing written, `row_version` unmoved, no audit event.

*Fix.* `name` and `description` are compared with `compare()`, which is case-sensitive, and `active`
as a boolean (`XOR`), never through `toString`. The locked read, the transaction, authorization,
actor attribution, validation, the narrative exclusion, the absent route and the public method
contract are unchanged. Two regressions, `testACaseOnlyNameChangeIsMaterial` and
`testACaseOnlyDescriptionChangeIsMaterial`, were written first and observed to fail against the
unmodified production code (`changedFields=[]`, old capitalization still stored); they pass after
the fix, and the existing no-op case still passes. Their text assertions use a byte-exact
`compare()` helper, because `BaseSpec.assertEquals` uses the same case-insensitive operator and
could not have detected the defect. Record: `docs/evidence/phase6-fourth-correction-red-before-fix.md`.

**2 (MEDIUM; audit P6C3-02). The primary acceptance rows described the superseded implementation.** ADM-04 still
said B's non-completion proved it had reached the competing lock and named three pairings; ADM-05
still said the global identity creators call `requireDraftVersion` before an INSERT and that
`updateInstrumentMetadata` requires a named known `icf.app_user`.

*Fix.* Both rows in `docs/ACCEPTANCE_TRACKING.md` were rewritten in place. ADM-04 describes the two
independently observed barrier signals, states that non-completion is supplemental only, and names
all seven pairings with their test methods. ADM-05 describes the single status-qualified
`INSERT ... SELECT` with `OUTPUT INSERTED`, the current-principal requirement, central
`instrument.manage`, and actor derivation from `principal.userId`, with current test names and
counts. The same superseded barrier description was corrected in `docs/ARCHITECTURE.md` and
`docs/DATA_CONTRACT.md`, ARCHITECTURE's lock-order paragraph no longer names `requireDraftVersion`
for every mutator, and the no-op statements in `DATA_CONTRACT.md` and `OPEN_DECISIONS.md` now say
materiality is case-sensitive. The header of this file had also gone stale (it still named the
second correction as current) and was corrected. A new CORR7 ledger records all four findings.

**3 (LOW; audit P6C3-04). The evidence ledger overstated two facts.** The third correction's environment record
said 26 CFML spec files ran; there were 31, and its raw transcript names the same 31. Its
red-before-green record said the remediation regression exercised 50060, 50061 and 2627; the test
executes 50060 and 2627 and only asserts structurally that the published SQL contains
`THROW 50061`.

*Fix.* The count is corrected to 31 with the reconciliation recorded (`git ls-tree` at `a8e97f2`
and the transcript's distinct spec names both give 31, and the lists are identical). The 50061
wording now says structurally asserted, not behaviourally exercised; no artificial 50061 path was
added. The replacement of `testTheAuthorizedOperationRefusesAnUnknownActor` by
`testTheAuthorizedOperationRefusesACallerThatIsNotAPrincipal` is recorded explicitly: the service no
longer accepts an actor id, the replacement also refuses the id of a user who holds
`instrument.manage`, and no behaviour coverage was removed. The raw third-correction transcript is
unchanged.

**4 (MEDIUM; audit P6C3-01). The previous gate did not prove the committed tree.** It ran at `bff53f5` with a dirty
working tree and was committed afterwards.

*Fix.* This correction is committed first; the working tree is then confirmed completely clean;
the complete clean-database release gate runs from that exact commit with its transcript captured
outside the repository; and `HEAD`, `HEAD^{tree}`, porcelain status, both diffs, baseline ancestry
and the remote ref are recorded before and after. The raw final transcript and the final
environment record are handoff artifacts outside the repository, because committing them after the
gate would create a different, untested commit. The browser suites previously wrote their
screenshots only into the tracked `docs/evidence/screenshots/`, and Playwright's PNG bytes differ
run to run, so an honest exact-commit gate would have dirtied its own tree. They now honour a
test-harness variable, `ICFWALK_SCREENSHOT_DIR` (default unchanged, documented in
`docs/LOCAL_SETUP.md`), which the final gate points outside the repository.

### Files changed (fourth correction)

| File | Change |
| --- | --- |
| `src/instrument/InstrumentMetadataService.cfc` | Case-sensitive `compare()` for `name` and `description`, boolean comparison for `active`; header comment records that materiality is case-sensitive. |
| `tests/cfml/specs/InstrumentMetadataServiceTest.cfc` | Two case-only regressions, a byte-exact `assertExactText` helper and a `metadataEventsSince` helper; the new cases compare row versions with `compare()`. 15 -> 17 cases. |
| `tests/cfml/specs/InstrumentPublishServiceTest.cfc` | `testSemanticOptionInAForeignResponseSetIsRefused` chooses a receiving response set that can hold every moved option, instead of an arbitrary one; found by the first exact-commit gate. No assertion about publication changed. |
| `tests/node/helpers.mjs` | `screenshotDir(env)`: `ICFWALK_SCREENSHOT_DIR` or the tracked default. |
| `tests/node/browser.test.mjs`, `browser-email.test.mjs`, `browser-persistence.test.mjs` | Write screenshots to `screenshotDir(env)`. No assertion changed. |
| `docs/ACCEPTANCE_TRACKING.md` | ADM-04 and ADM-05 rewritten in place; CORR6-02 and CORR6-06 made exact; CORR7 ledger added. |
| `docs/ARCHITECTURE.md`, `docs/DATA_CONTRACT.md`, `docs/OPEN_DECISIONS.md` | Superseded barrier and lock-order statements corrected; case-sensitive materiality stated. |
| `docs/LOCAL_SETUP.md` | `ICFWALK_SCREENSHOT_DIR` documented for exact-commit gates. |
| `docs/evidence/phase6-third-correction-environment.md` | 26 -> 31 spec files, with the reconciliation. |
| `docs/evidence/phase6-third-correction-red-before-fix.md` | 50061 stated as structural only; the replaced test recorded. |
| `docs/evidence/phase6-fourth-correction-red-before-fix.md` | **New.** The observed red and green output for CORR7-01. |
| `manifest.json` | Refreshed for `DATA_CONTRACT.md` and `OPEN_DECISIONS.md` with `scripts/refresh-manifest.mjs`. |
| `BUILD_STATUS.md` | Header corrected; this section. |

### Verification

Focused, against the live stack (Lucee 6.2.8.20, SQL Server 2022 16.0.4295.3), after the fix:
`InstrumentMetadataServiceTest` 17/17, `SharedMetadataConcurrencyBarrierTest` 6/6,
`GlobalIdentityBoundaryTest` 6/6, `PublishConcurrencyBarrierTest` 5/5,
`SharedInstrumentBoundaryTest` 7/7, `InstrumentConfigValidatorTest` 18/18,
`InstrumentImportServiceTest` 10/10, `DefinitionValidatorTest` 50/50,
`InstrumentPublishServiceTest` 53/53, and `tests/node/remediation-exact-identity.test.mjs` 1/1, all
with zero skips.

Development run of the complete gate, before this commit existed, against the uncommitted working
tree of this correction (a gate script kept outside the repository, in its development mode): a
freshly dropped and recreated `icfwalk_dev` taken through `001`..`006`, `006` immediately re-applied
(`legacy_membership_backfill_ran_now = 0`), Lucee restarted on it and the DRAFT seeded;
`npm ci`; `validate:handoff` 51 checks, 0 errors; `test:package` 19/19, 0 skipped; all 37 tracked
JavaScript/MJS files parse; `ICFWALK_REQUIRE_APP=1 npm test` 175/175 with 0 failed, 0 cancelled, 0
skipped, 0 todo; CFML 377/377 (375 before, plus the two new cases) with 0 failed and 0 skipped, from
31 spec files whose reported names equal the `*Test.cfc` files exactly. No suite or case
disappeared. The 13 screenshots went to a directory outside the repository and no tracked PNG
changed.

### The first exact-commit gate failed, and why

The gate was first run from a clean tree at `c7f6f48a36626dc357bd36aa65db85a26083f15a` (tree
`cf668336aae02f2f23d76696226546ca04fadae9`). HEAD and the tree were unchanged and the tree was still
clean afterwards, but the run **failed**: Node 174/175, the failure being the CFML suite driver,
which stops at the first failing part. Part 4 of 6 reported two failed cases (291 of 293 reported
cases passed, across 21 of the 31 spec files; parts 5 and 6 did not run). Neither failure was a
production defect, and neither was re-run away:

1. `InstrumentMetadataServiceTest.testACaseOnlyDescriptionChangeIsMaterial`, new in this
   correction, failed with `the row was written Expected values to differ but both were
   [000000000000E988]`. `BaseSpec.assertNotEquals` compares with CFML's `==`, which compares two
   numeric-looking strings as numbers, and a hex `row_version` such as `000000000000E988` parses as
   `0e988`, which is zero, so it equalled its successor. Observed directly on Lucee 6.2.8.20 with a
   temporary probe spec that was deleted, not committed: `"000000000000E988" == "000000000000E989"`
   is `true`, and `compare()` returns -1. Every assertion before that one in the case had passed in
   that run, including the stored exact capitalization. *Fix:* both new cases compare row versions
   with `compare()`.
2. `InstrumentPublishServiceTest.testSemanticOptionInAForeignResponseSetIsRefused`, pre-existing
   and not otherwise touched by this correction, failed with `Violation of UNIQUE KEY constraint
   'UQ_response_option_set_code'` on the code `behind`, inside its own setup. It moved every option
   of one response set into a set of a second draft chosen by `SELECT TOP (1)` with no `ORDER BY`
   and no compatibility condition. Both drafts are copies of the same instrument, and 585 of the 841
   possible (moved set, receiving set) pairings in the supplied instrument share an option key or a
   stored code, so whether the setup UPDATE succeeded depended on the query plan and the generated
   ids. It had passed in every earlier run, including this correction's development gate. *Fix:* the
   receiving set is chosen, in a stated order, from the sets that share neither `option_key` nor
   `stored_code` with the moved options (every set the instrument uses has at least five such
   candidates), and the existence of one is asserted as a precondition. What the case asserts
   about publication (`RESPONSE_SET_EMPTY`, a 422, nothing written) is unchanged.

Both fixes are test-only and are carried by the next commit; the exact-commit gate is then repeated
from that commit, and its result is reported with the handoff. The failed attempt's raw transcript
is kept with the handoff artifacts rather than discarded.

**The authoritative result is the exact-commit gate**, run after this commit existed, from a
completely clean tree, and recorded outside the repository with the final environment record. Its
totals are reported with the handoff, not here, because writing them here would change the commit
they describe.

### Unresolved and not verified (fourth correction)

1. **Adobe ColdFusion 2023 and SQL Server 2016 remain unverified.** All CFML execution was on Lucee
   6.2.8.20 and all SQL on SQL Server 2022. `compare()` is documented as case-sensitive on Adobe
   ColdFusion as well, but the new cases have not been run there; they are listed for that
   platform in `docs/evidence/phase6-fourth-correction-red-before-fix.md`. This correction adds no
   SQL.
2. **The `phase-5-freeze` tag still does not exist**, locally or on the remote. This correction did
   not create, move or push any tag. It remains an open repository action for an authorized
   operator.
3. **`BaseSpec.assertEquals` / `assertNotEquals` coerce.** They compare with CFML's `!=` / `==`,
   which ignore case and compare numeric-looking strings as numbers. The second matters for row
   versions: 87 call sites across 16 spec files pass a row version to one of them, and when both
   hex values have the form `0...0E<digits>` an "unchanged" assertion can pass although the version
   moved. That is a latent weakness in existing evidence, not an observed false pass; it was not
   changed here, because changing the shared assertions alters every case in the suite. The new
   cases in this pass use `compare()`. Recommended follow-up: byte-exact comparison for row versions
   throughout.
4. **ADM-02, ADM-06, ADM-07, ADM-08 are not started**, nor is any administration UI, nor Phase 7.
5. **This correction has not been independently audited.** It is a correction candidate. Phase 6 is
   **not** frozen, **not** complete and **not** accepted, and no `phase-6-freeze` tag was created.

## Phase 6 publish-foundation fifth correction (frozen as the Phase 0-6 baseline)

Correction-only session against the independent audit of the fourth correction (the supplied
candidate `04fb1afb05edbdad96d61c160c59217a01ab06e0`), whose verdict was **NOT READY TO ACCEPT THE
PHASE 6 PUBLISH FOUNDATION** with 0 HIGH findings, one new MEDIUM, one new LOW, and the prior MEDIUM
P6C3-01 still open because the external final gate transcript and final environment record had not
been supplied. The audit found P6C3-02 (the primary ADM-04 and ADM-05 rows), P6C3-03 (case-only
metadata materiality) and P6C3-04 (evidence accounting) closed, and those corrections are preserved
unchanged, as is everything the earlier cycles verified: the locked shared-metadata read, merge,
update and audit; principal authorization and actor attribution; the atomic status-qualified
identity `INSERT ... SELECT`; the two-sided concurrency barriers; JSON type and count validation
with the top-level `null` refusal; the exact-identity remediation SQL; the exact `DRAFT`
requirements; `ICFWALK_SCREENSHOT_DIR`; and the deterministic response-set fixture. **No production
file changed**: this correction touches the CFML test harness, its specs and the records. No schema
migration, route, dependency, production hook or tag was added, and none of ADM-02, ADM-06, ADM-07,
ADM-08, the administration UI or Phase 7 was started. **This is a correction candidate awaiting
independent verification: Phase 6 is not frozen, not complete and not accepted.**

Starting point. The container was provisioned with the local branch **stale** at
`a8e97f22ae1639faef5b6e68bf7255dea838f8e2` (the prior audited candidate; its tracking ref was stale
too), while `git ls-remote` showed the remote branch at the supplied
`04fb1afb05edbdad96d61c160c59217a01ab06e0`; the reflog shows the harness had checked `04fb1afb` out
detached and then switched to the stale local branch. The working tree was clean and `a8e97f2` is
an ancestor of `04fb1af` (two commits, `c7f6f48` and `04fb1af`), so the branch was brought to the
supplied candidate with `git pull --ff-only origin claude/icfwalk-phase-6-admin-publish`: a
fast-forward, with no reset, rebase, force or rewrite. Then, verified before any edit: branch
`claude/icfwalk-phase-6-admin-publish` at exactly `04fb1afb05edbdad96d61c160c59217a01ab06e0` (tree
`52788191fea2749570aad261103dbd4b49dd24be`), a completely clean working tree and index including
untracked files, the Phase 5 baseline `e55ec08af5b8622db5823b6e353423b891918549` an ancestor, and
the remote branch equal to HEAD. The supplied archive itself was not present in the container, so
its SHA-256 (`02293173c911a8ea15f098675af463af6e3a92b1aa2d5f2ebec7b35c23b09237`) could not be
checked here; the commit identity was verified against the remote instead.

### What was wrong, and what each fix is

**1 (MEDIUM). Exact-contract tests compared through coercive equality.** `BaseSpec.assertEquals`
and `assertNotEquals` stringified both values and compared them with CFML's `!=` and `==`, which
ignore case and compare numeric-looking strings as numbers. A row version written as 16 hex digits
reads as a number: `000000000000E988` is `0e988`, zero, equal to its successor. So the assertions
behind immutability, refusal atomicity, no-ops, optimistic concurrency, replay, response coherence
and concurrency outcomes could pass although a value moved, or fail although it did (the fourth
correction's first exact-commit gate failed on exactly that). Ninety row-version comparisons in 16
spec files went through those helpers, besides several hundred comparisons of codes, identifiers,
checksums, canonical JSON and authored text.

*Red, before any helper existed.* A temporary probe spec (deleted, never committed) called the
unmodified helpers with `ICFWalk` / `Icfwalk` and `000000000000E988` / `000000000000E989`:
`assertEquals` accepted both pairs as equal and `assertNotEquals` rejected both valid inequalities,
while two identical-value controls passed; 4 failed, 2 passed, exit 1. Command, output and probe
source: `docs/evidence/phase6-fifth-correction-red-before-fix.md`.

*Fix.* `BaseSpec` gains five exact helpers built on `compare()`, never on `==` or `!=`:
`assertExactTextEquals`, `assertExactTextNotEquals`, `assertRowVersionEquals`,
`assertRowVersionChanged` and `assertExactJsonEquals`. They are case-sensitive, never read text as a
number, boolean or date, and never normalize case, a `0x` prefix, padding or representation. The
text helpers refuse null and structures instead of stringifying them; the row-version helpers also
refuse an empty token, so a row version that was never read cannot make "unchanged" true. Failure
messages name both values with their lengths and the first differing character. The general
`assertEquals` / `assertNotEquals` keep their semantics for the numeric and boolean contracts they
still serve, are documented as not exact, name both values when `assertNotEquals` fails, and refuse
any operand shaped like a row-version token. `assertThrows` compares the errorcode exactly (it is a
client's `error.code`) and the type prefix with an explicit `compareNoCase` (CFML resolves exception
types case-insensitively, and `Errors.statusFor` relies on it).

*Migration.* A traced run of the unmodified suite (temporary instrumentation, never committed)
recorded 3,999 assertion executions and found exact and coercive comparison agreeing in every one,
so no expectation changed. Each call was then classified by the contract of the value it compares,
with aliases (`r0`, `r1`, `r2`, `rv`), loops and struct-valued fingerprints reviewed by hand. Of the
933 general-helper calls, 523 moved to `assertExactTextEquals`, 25 to `assertExactTextNotEquals`, 87
to the row-version helpers and 21 to `assertExactJsonEquals`; three wrappers were split by field
contract; and 274 numeric and boolean comparisons stay on the general helpers, with their reason in
`docs/evidence/phase6-fifth-correction-assertion-inventory.md`. In the final suite the exact helpers
carry 548 text, 25 text-inequality, 92 row-version and 23 structure comparisons, and the general
helpers 275 (the split wrapper adds one numeric loop). All 92 row-version comparisons
(the 90 above and two inline `compare()` checks) now use `assertRowVersionEquals` (78) or
`assertRowVersionChanged` (14); high-water marks are read as exact text from SQL Server
(`CONVERT(varchar(20), MAX(CAST(row_version AS bigint)))`), because Lucee returns SQL `bigint` as a
`Double`. The fourth correction's spec-local `assertExactText` is gone and its 22 calls use the
shared helper. Assertion-deciding `==` predicates on error codes, paths, migration states and
barrier signals now use `compare()`. A traced run of the migrated suite found the general helpers
receiving only numbers and booleans outside the focused spec.

*Coverage and guard.* `tests/cfml/specs/ExactAssertionTest.cfc` (14 cases) proves both directions
of every helper with both pairs, the traps the old operator fell into (`4`/`04`, `1E3`/`1000`,
`true`/`YES`, case, prefix and padding of row versions, two tokens that are both zero), the
refusals, the messages, and the exact errorcode. It also guards the result: the general helpers
refuse a row-version-shaped value at run time, and a scan of every spec and support component
(comments and literals masked) fails on a row-version expression or a quoted text literal passed to
them, a row version compared with `==`, `!=`, `EQ` or `NEQ`, or a spec shadowing a shared helper.
Run before the migration, that scan reported 500 findings; after it, none.

**2 (LOW). The fourth correction's severity labels were reversed.** Its list above labelled the
case-only metadata item (P6C3-03) MEDIUM and the exact-commit traceability item (P6C3-01) LOW; the
audit classified them LOW and MEDIUM. *Fix.* The four items now read `1 (LOW; audit P6C3-03)`,
`2 (MEDIUM; audit P6C3-02)`, `3 (LOW; audit P6C3-04)` and `4 (MEDIUM; audit P6C3-01)`. The aggregate
(0 HIGH, 2 MEDIUM, 2 LOW) and the substance of every item are unchanged. The CORR7 ledger in
`docs/ACCEPTANCE_TRACKING.md` states only the aggregate, which was already right, and the fourth
correction's evidence records carry no per-item severity.

**3 (MEDIUM; P6C3-01, carried open). The exact-commit gate's evidence was not handed over.** The
fourth correction ran an exact-commit gate but its handoff supplied only a repository archive, not
the raw final transcript or the final environment record, so the gate could not be tied to the
exact pushed commit. *Fix.* This correction is committed first; the working tree and index are then
confirmed completely clean; the complete clean-database gate runs from that exact commit with its
raw transcript captured outside the repository and identity recorded before and after; the commit
is pushed normally and the remote branch hash is shown equal to the tested commit; and the
repository ZIP is made from the pushed commit. The ZIP, the transcript and the environment record
are three separate handoff artifacts with their SHA-256 values. None is committed, because
committing it would create a different, untested commit, and any evidence from an earlier commit is
obsolete.

### Files changed (fifth correction)

| File | Change |
| --- | --- |
| `tests/cfml/BaseSpec.cfc` | Five exact helpers on `compare()`; the general helpers documented as not exact, refusing row-version-shaped operands, `assertNotEquals` naming both values; `assertThrows` errorcode exact and type prefix explicitly `compareNoCase`. |
| `tests/cfml/specs/ExactAssertionTest.cfc` | **New.** 14 cases: both directions of every helper with both pairs, the traps, refusals and messages, the exact errorcode, and the run-time and source guards. |
| `tests/cfml/specs/*Test.cfc` (all 31 existing specs) | Exact-contract comparisons moved to the exact helpers (653 renamed calls); in `InstrumentImmutabilityTest`, `InstrumentPublishServiceTest` and `InstrumentImportServiceTest` the wrappers were split by field contract and high-water marks are read as exact text; in `InstrumentMetadataServiceTest` the local `assertExactText` is removed; assertion-deciding `==` predicates use `compare()`. No case was added, removed or renamed, and no expected value changed. |
| `tests/cfml/support/ConcurrencyBarrier.cfc` | `signalledInOrder` matches signal names with `compare()`. |
| `docs/evidence/phase6-fifth-correction-red-before-fix.md` | **New.** The red probe (source, command, output, exit 1), operator facts, the helper design, the permanent cases. |
| `docs/evidence/phase6-fifth-correction-assertion-inventory.md` | **New.** Method, files reviewed, every call's disposition by category and file, the 92 row-version comparisons, the migrated predicates, what was kept and why, the guard. |
| `docs/ACCEPTANCE_TRACKING.md` | CORR8 ledger; forward pointers on CORR7-01 and CORR7-05; the fourth correction's heading marked superseded in part. |
| `BUILD_STATUS.md` | Header; the fourth correction's severity labels (item 2 above); this section. |

`manifest.json` needed no refresh: none of the files it lists changed.

### Verification

Development runs, before this commit existed, on Lucee 6.2.8.20 and SQL Server 2022
(16.0.4295.3): the red probe as above; `ExactAssertionTest` 13/14 against the unmigrated suite (the
source guard failing with 500 findings), then 14/14; the complete CFML suite 377/377 traced before
the migration and 391/391 traced after it (377 plus the 14 new cases), 0 failed and 0 skipped each
time. No case disappeared: the 377 test methods at the audited commit are all present, under the
same names in the same specs, and the 14 added are all in `ExactAssertionTest`.

Development run of the complete gate against the uncommitted working tree (the gate script is kept
outside the repository; development mode): a new SQL Server container whose `icfwalk_dev` had no
tables, taken through `001`..`006`; `002`..`006` re-applied (`legacy_membership_backfill_ran_now`
0); `001` re-applied and refused with 50001 as documented; Lucee started, the DRAFT seeded, Lucee
restarted and the seeded DRAFT confirmed through the maintenance route; `npm ci`;
`validate:handoff` 51 checks, 0 errors; `test:package` 19/19; all 37 tracked JavaScript/MJS files
parse; `ICFWALK_REQUIRE_APP=1 npm test` 175/175 with 0 failed, 0 cancelled, 0 skipped, 0 todo;
CFML 391/391 with 0 failed and 0 skipped, from 32 spec files whose reported names equal the
`*Test.cfc` files; the 13 screenshots written outside the repository; then the application, the
container and every temporary artifact removed. The Node total is unchanged at 175 because no Node
test file changed; the CFML total rose from 377 by the 14 new cases.

**The authoritative result is the exact-commit gate**, run after this commit exists, from a
completely clean tree, with its raw transcript and the final environment record kept outside the
repository. Its totals are reported with the handoff, not here, because writing them here would
change the commit they describe.

### Unresolved and not verified (fifth correction)

1. **Adobe ColdFusion 2023 and SQL Server 2016 remain unverified.** All CFML ran on Lucee 6.2.8.20
   and all SQL on SQL Server 2022. The exact helpers rest on `compare()`, `compareNoCase()` and
   `serializeJSON`; the first two are documented with the same semantics on Adobe ColdFusion, but
   Adobe ColdFusion's `serializeJSON` infers types from string content, so `ExactAssertionTest` and
   the specs that use `assertExactJsonEquals` should be run there before any claim about that
   engine (`docs/evidence/phase6-fifth-correction-red-before-fix.md`). The one SQL construct this
   correction adds, `CONVERT(varchar(20), MAX(CAST(row_version AS bigint)))`, is SQL Server 2005+
   and appears only in test code.
2. **The supplied archive's SHA-256 was not verified here**: the archive was not present in the
   container. The starting commit was verified against the remote branch instead.
3. **The `phase-5-freeze` tag still does not exist**, locally or on the remote. This correction did
   not create, move or push any tag.
4. **The general `assertEquals` / `assertNotEquals` still coerce** for the numeric and boolean
   contracts they serve. That is deliberate and documented in `BaseSpec`; they refuse row-version
   tokens, and the source guard keeps text literals and row-version expressions away from them. A
   new comparison of text through a non-literal expression would still reach them unless a
   reviewer applies the inventory's rule; the guard makes that likely to be caught, not impossible.
5. **ADM-02, ADM-06, ADM-07, ADM-08 are not started**, nor is any administration UI, nor Phase 7.
6. **This correction has not been independently audited.** It is a correction candidate. Phase 6 is
   **not** frozen, **not** complete and **not** accepted, and no `phase-6-freeze` tag was created.

## Phase 7: aggregate reporting (current state)

**Starting point.** The container's local branch was stale at `a8e97f22ae1639faef5b6e68bf7255dea838f8e2`,
three commits behind `origin/claude/icfwalk-phase-6-admin-publish`, which stood at the frozen
`a219d9e0987b85b1a0b587fd62effa4e0ad1ffde`. The tree was clean and `a8e97f2` is an ancestor, so the
branch was fast-forwarded (`git merge --ff-only`): no reset, rebase, force or rewrite. Verified before
any edit: HEAD exactly `a219d9e…`, working tree and index clean including untracked files, remote
branch equal to HEAD. The full suite was then run on that untouched commit against a freshly
created database: **Node/HTTP/Playwright 175/175 and CFML 391/391, 0 failed, 0 skipped**.

**Scope.** `docs/IMPLEMENTATION_PLAN.md` Phase 7: scoped filters, distributions, item-level
weighted averages, state counts and an export; narrative/teacher/email exclusion in the query,
service and DTO layers; no report-only drill-through; completion gate "scope, denominator,
exclusion, and report-only tests pass". Acceptance IDs RPT-01..07, plus the report parts of
AUTH-01, AUTH-06, SEC-01, SEC-02, SEC-05 and A11Y-01..05.

**A scope discrepancy, recorded rather than resolved.** The project owner identified `a219d9e` as
the independently verified, frozen Phase 0-6 baseline. The records at that commit describe Phase 6
as the publish foundation only (ADM-03/04/05); ADM-02, ADM-06, ADM-07, ADM-08 and the administration
UI were never built. They are not Phase 7 and were not started here.

### What Phase 7 adds

| Piece | What it does |
| --- | --- |
| `src/reports/ReportService.cfc` | Validates filters against the caller's scope and the selected version, derives the reportable catalog from the pinned render model and the instrument's own `VisibilityEngine`, computes the report with population verification and retry, applies the suppression seam, formats the CSV, audits exports. |
| `src/reports/ReportRepository.cfc` | Every report statement: the session population and scope temp tables, the S1 candidate selection (walk rows only, row versions captured), the population filters, the aggregates (counts keyed by ids), and the S3 verification. Selects no narrative, identifying or teacher column. |
| `src/controllers/ReportController.cfc` | `options`, `aggregate`, `exportCsv`. |
| Routes | `GET /api/reports/options`, `/api/reports/aggregate`, `/api/reports/aggregate.csv`, each `{ permission: "report.view" }` (`docs/ENDPOINTS.md`). |
| `app/assets/js/reports.js` + shell | The Reports view: filters from `/options`, the report, a CSV link. Report-only roles land on it without ever calling a walk route; walk roles get a Reports button beside My walks. |

Design and decisions (full text in `docs/ARCHITECTURE.md` "Aggregate reporting (Phase 7)",
`docs/DATA_CONTRACT.md` "How Phase 7 reports implement this", `docs/OPEN_DECISIONS.md`):

* **One version per report**, default the current one; versions may score an item differently.
* **Population**: the caller's covered units (optionally one named covered unit and its covered
  descendants), COMPLETED walks (drafts on request, VOIDED never), an inclusive observation window.
* **Reportable surface**: active reportable `SINGLE_CHOICE` items; reportable non-sensitive `LIST`
  dimensions except School (reported as the org unit). Free-text dimensions, Date, notes, text,
  display items and the email draft are never reported, whatever their flags say.
* **States and scores**: persisted response states are read (they are the engine's evaluation,
  written with the value); distributions count ANSWERED only; means are `BigDecimal` sums of
  answered, scored, non-N/A option scores over their count; sections pool responses. Dimension
  visibility is not persisted, so the engine is evaluated for every combination of the source
  dimensions' values and the visible combinations become the SQL condition; a hidden retained
  Period is HIDDEN, never its value.
* **Coherence**: optimistic, using the row version every mutation already moves (S1 capture, S3
  verification, up to three attempts, then 409 `REPORT_POPULATION_CHANGED`). No lock is held that a
  writer waits on, so reports never stall autosave.
* **Suppression**: the undecided threshold, default none; when set, small populations and small
  org-unit and dimension-value groups are withheld. What it does not attempt is documented.

### Narrow integration changes to frozen Phase 0-6 files

| File | Change | Why it was necessary |
| --- | --- | --- |
| `src/Bootstrap.cfc` | Constructs `reportRepository`, `reportService`, `reportController`. | Wiring; nothing existing moved. |
| `src/http/Router.cfc` | Three GET routes. | The endpoints; no existing route or policy changed. |
| `src/config/ConfigLoader.cfc` | `ICFWALK_REPORT_SUPPRESSION_THRESHOLD` must be empty or a whole number (up to six digits), otherwise startup is refused. | Phase 7 is the seam's first consumer. The frozen loader turned `"5 walks"`, `"five"` or `"0x10"` into 0 (no suppression) and `"-3"` into -3 silently -- a fail-open privacy control. Strengthens validation only; empty and 0 still mean none. |
| `src/views/shell.html` | A Reports nav button and the Reports view section. | The view; the existing views are unchanged. |
| `app/assets/js/app.js` | Imports the reports module; records `canWalk` / `canReport` from `/api/me`; `showView` knows the reports view; report-only roles land on Reports and skip the walk bootstrap. | Report-only users previously landed on My walks and got `FORBIDDEN` from `/api/walks`. For walk users `nav-list-btn` behaves exactly as before in the list and walk views. |
| `app/assets/css/icfwalk.css` | Report styles appended. | Styles live in the stylesheet so the CSP is unchanged. |
| `tests/cfml/specs/ConfigLoaderTest.cfc` | One new case. | Covers the stricter threshold rule; nothing existing changed. |
| `tests/node/schema-contract.test.mjs` | `ReportRepository` added to the table-name scan. | Extends existing coverage to the new data-access file. |
| `package.json` | `test:reports`; `browser-reports` added to `test:browser`. | Scripts only; no dependency added. |

No schema migration, dependency, framework or infrastructure was added. No existing test was
removed, skipped, weakened or rewritten.

### Files changed (Phase 7)

| File | Status |
| --- | --- |
| `src/reports/ReportService.cfc`, `src/reports/ReportRepository.cfc`, `src/controllers/ReportController.cfc` | New |
| `app/assets/js/reports.js` | New |
| `tests/cfml/specs/ReportServiceTest.cfc` (15 cases), `tests/cfml/specs/ReportCoherenceTest.cfc` (4 cases) | New |
| `tests/cfml/support/InterceptingReportRepository.cfc`, `tests/cfml/support/CapturingLogger.cfc` | New, test-only |
| `tests/node/reports.test.mjs` (12 cases), `tests/node/browser-reports.test.mjs` (6 cases) | New |
| `docs/evidence/phase7-red-before-fix.md`, `docs/evidence/screenshots/reports-desktop.png`, `reports-phone.png` | New |
| `src/Bootstrap.cfc`, `src/http/Router.cfc`, `src/config/ConfigLoader.cfc`, `src/views/shell.html`, `app/assets/js/app.js`, `app/assets/css/icfwalk.css` | Integration (table above) |
| `tests/cfml/specs/ConfigLoaderTest.cfc`, `tests/node/schema-contract.test.mjs`, `package.json` | Test coverage and scripts (table above) |
| `docs/ENDPOINTS.md`, `docs/ARCHITECTURE.md`, `docs/DATA_CONTRACT.md`, `docs/OPEN_DECISIONS.md`, `docs/LOCAL_SETUP.md`, `docs/ACCEPTANCE_TRACKING.md`, `.env.example`, `BUILD_STATUS.md` | Records |
| `manifest.json` | Refreshed for `docs/DATA_CONTRACT.md` and `docs/OPEN_DECISIONS.md` (`node scripts/refresh-manifest.mjs`) |

### Tests and results (development runs, before the commit)

Environment: Lucee 6.2.8.20, SQL Server 2022 (16.0.4295.3) in Docker, Node 22.22.2, Playwright
1.56.1 with Chromium 141.0.7390.37, axe-core 4.13.0.

| Run | Result |
| --- | --- |
| Frozen baseline `a219d9e`, fresh database | Node/HTTP/Playwright **175/175**, CFML **391/391**; 0 failed, 0 skipped |
| Phase 7 working tree, same database, `ICFWALK_REQUIRE_APP=1 npm test` | Node/HTTP/Playwright **193/193** (175 + 12 `reports` + 6 `browser-reports`), CFML **411/411** (391 + 15 `ReportServiceTest` + 4 `ReportCoherenceTest` + 1 `ConfigLoaderTest`); 0 failed, 0 skipped |
| `npm run validate:handoff` | ok, 51 checks, 0 errors |

Red before green (`docs/evidence/phase7-red-before-fix.md`): removing population verification made
the coherence spec report Grade 7 beside rating 5, a state the walk never held; ignoring dimension
visibility let a hidden retained Period match the Period filter; counting options regardless of
state let a hidden retained 5 and a hidden section's "yes" into distributions; trusting a named org
unit let out-of-scope schools be reported; the frozen `ConfigLoader` accepted `"5 walks"`.

**The authoritative result is the exact-commit gate**, run after this commit exists, on a freshly
created database, from a completely clean tree, with screenshots written outside the repository.
Its totals are reported with the handoff rather than here, because writing them here would change
the commit they describe.

### Unresolved and not verified (Phase 7)

1. **Adobe ColdFusion 2023 and SQL Server 2016 remain unverified**, as for every earlier phase. Phase
   7 adds engine-sensitive constructs that must be re-run there: session temporary tables inside a
   `transaction` block (one pooled connection per transaction on Adobe ColdFusion's datasource),
   `createObject("java", "java.math.BigDecimal")` arithmetic, `cfthread` in `ReportCoherenceTest`,
   URL-scope key case (parameter names are matched case-insensitively for that reason), and a
   `CASE WHEN EXISTS (...)` inside a derived table. All SQL is SQL Server 2016 syntax.
2. **The suppression threshold is still an open decision.** The seam withholds small populations and
   small org-unit and dimension-value groups; cell-level, per-status, complementary and differencing
   protection are not implemented (`docs/DATA_CONTRACT.md`). With the default (none), a filter that
   narrows the population to one walk shows that walk's ratings in aggregate form -- never its
   identity, owner or narrative.
3. **Reports never pool instrument versions.** Cross-version trend reporting needs an approved
   comparability mapping (`docs/OPEN_DECISIONS.md`).
4. **A dimension whose visibility depends on an item response or free text would be left out of
   reports** (fail closed). The current instrument has none; Period depends on Grade only.
5. **Scale.** Reports aggregate in SQL over the existing indexes; no load test was run. A population
   that changes on every one of three attempts is refused (409), which on a very busy district could
   surface during heavy editing of completed walks; drafts are excluded by default, so ordinary
   autosave traffic does not affect a default report.
6. **The remainder of Phase 6** (ADM-02, ADM-06, ADM-07, ADM-08, administration UI) was not built by this session. It was built afterwards, on top of Phase 7: see "Phase 6 administration" below.
7. **This is an implementation candidate.** Phase 7 has not been independently audited and is not
   frozen or accepted.

## Phase 6 administration: preview, clone and compare, retire, placeholder queue, and the UI

**Starting point.** The branch was fast-forwarded (clean tree, ancestor, no reset, rebase, force or
rewrite) from `a8e97f22ae1639faef5b6e68bf7255dea838f8e2` to
`0c6fa10972593043508f502538534c2aa95c671b` (the fourth and fifth publish-foundation corrections and
Phase 7, all by other sessions). On that untouched commit against a fresh database:
**Node/HTTP/Playwright 193/193 and CFML 411/411, 0 failed, 0 skipped.** The `phase-5-freeze` tag
exists neither locally nor on the remote; it was not created, moved or deleted.

**Scope.** The remainder of `docs/IMPLEMENTATION_PLAN.md` Phase 6 named in "Exact recommended
starting point for the rest of Phase 6": ADM-02 preview, ADM-06 new DRAFT from a published version
with an edited prompt and a compare view, ADM-07 retire, ADM-08 the placeholder review queue, and the
administration UI for all of it, including ADM-01 import and ADM-04 publish from the browser.

### What it adds

| Piece | What it does |
| --- | --- |
| `src/instrument/InstrumentAdminService.cfc` | Version list (`isCurrent`, `isRuntimeInstrument`), preview, import, clone, wording search and edit, compare, placeholder queue, discard. Reads snapshots through `SnapshotService`; every DRAFT write goes through `writeNormalizedDraft`. |
| `src/instrument/DraftEditor.cfc` | Pure: which wording fields may change (and their limits), applying an edit set with every issue and its path, keeping `contentReview.unresolvedPlaceholders` consistent, search. |
| `src/instrument/InstrumentVersionComparer.cfc` | Pure: row-by-row diff of two snapshots on logical keys, exact and type-aware, plus version metadata. |
| `InstrumentImportService.writeNormalizedDraft` | The one DRAFT write path, now shared by import, clone and edit (options: operation, `mustCreate`, `targetVersionId` + `expectedChecksum`, `skipWhenUnchanged`, success event and audit details). `importConfig` calls it. |
| `InstrumentPublishService.retire` + `DefinitionRepository.markRetired` / `lockRetirement` | PUBLISHED to RETIRED under the version lock, `effective_end` set, nothing else touched; refuses leaving no version in service unless confirmed, with retirements of one instrument serialized so two at once cannot defeat that check; refusals audited after rollback. |
| Routes (`docs/ENDPOINTS.md`) | `POST /api/admin/instrument/import`, `GET .../versions/{id}/preview`, `/wording`, `/placeholders`, `POST .../clone`, `/edits`, `/retire`, `/discard`, `GET /api/admin/instrument/compare`; all `instrument.manage`, CSRF on every POST. |
| `app/assets/js/admin.js` + shell | The administration view: import with the validation summary, the version list with status and in-service badges, preview through `renderer.js`, compare, placeholder queue, wording editor, new draft, publish / retire / discard confirmations. An admin-only user lands on it. |

Design and decisions (`docs/ARCHITECTURE.md` "Instrument administration (Phase 6)",
`docs/DATA_CONTRACT.md` "Instrument administration writes and retirement (Phase 6)",
`docs/OPEN_DECISIONS.md`):

* **Wording only in the browser.** Structure stays authored in the document and imported. Behavior
  and item settings are not editable, so no in-app edit can change the summary export or the email
  draft; the summary vectors stay valid without regeneration.
* **Placeholders are resolved by DRAFT edit** (the recorded safe default), and the queue shrinks.
* **Lost updates are refused**: an edit names the checksum it was made against (409 `DRAFT_CHANGED`).
* **Retirement is attributed in the audit event**, with `effective_end`; no column, no migration.
  Retiring the only version in service needs explicit confirmation (asked twice in the UI).
* **Any instrument code may be administered**; only `ICFWALK_INSTRUMENT_CODE` is what walks use.
* **The shared-metadata operation stays unrouted**; nobody has decided who may rename or take an
  instrument out of service.

### Narrow changes to earlier-phase files

| File | Change | Why it was necessary |
| --- | --- | --- |
| `src/walks/WalkRepository.cfc` (`insertWalk`) | Status-qualified `INSERT ... SELECT` from the version row `WITH (HOLDLOCK, ROWLOCK)`, `OUTPUT INSERTED`; returns `""` when nothing was inserted. | Without it a retirement between version resolution and insert pinned a new walk to a RETIRED version, and the other ordering deadlocked (red evidence 1). |
| `src/walks/WalkService.cfc` (`create`) | Nothing inserted: 409 `INSTRUMENT_VERSION_CHANGED` with `retiredVersionId`. | The existing code for "the version changed; reload". |
| `src/reports/ReportService.cfc` (`resolveVersion`) | With nothing in service, default to the newest frozen version. | Retiring the only version made `/api/reports/options` 404 and the Reports view unopenable (red evidence 3). |
| `src/controllers/AdminInstrumentController.cfc` (`publishVersion`) | Uses the shared `refuseAnyBody` helper. | Same contract and codes; the helper is shared with discard. |
| `src/instrument/InstrumentImportService.cfc` | `importConfig` delegates its write to `writeNormalizedDraft`; `unchangedResult`, `recordRefusal`, `discardDraftById` added. | One write path for import, clone and edit. The existing import tests pass unchanged. |
| `src/instrument/InstrumentPublishService.cfc` | `retire` added beside `publish`. | Retirement is the other lifecycle transition and shares publish's lock, refusal-audit and actor rules; `publish` is unchanged. |
| `src/instrument/DefinitionRepository.cfc` | `markRetired`, `lockRetirement`, `findCurrentVersionExcluding`, `currentVersionIds`. | Retirement, its per-instrument serialization (red evidence 4), and the list's in-service marker (the same predicate as `SnapshotService.currentVersion`). |
| `src/instrument/InstrumentConfigValidator.cfc` | `definitionValidator()` accessor. | The write path validates edited definitions with the one shared rule set. |
| `src/core/Errors.cfc` | `retireNotPublished` (409), `payloadTooLarge` (413). | New refusals, mapped centrally. |
| `src/Bootstrap.cfc`, `src/http/Router.cfc` | Wiring and the nine routes. | Nothing existing moved; no existing route or policy changed. |
| `src/views/shell.html`, `app/assets/js/app.js`, `app/assets/js/api.js`, `app/assets/css/icfwalk.css` | Admin nav button and view; `canAdmin` from `/api/me` (a boolean for the global permission); admin-only users land on it; `api.postEmpty` for the no-body routes; styles appended. | The view. Walk and report users see exactly what they saw before, plus the button when they also hold `instrument.manage`. |
| `tests/cfml/specs/InstrumentImmutabilityTest.cfc` | `markRetired` in a new lifecycle inventory, with its own contract test. | The mutator inventory test fails on any unlisted mutator, by design. |
| `tests/cfml/support/Intercepting{Definition,Walk}Repository.cfc` | `markRetired`, `lockRetirement`, `findCurrentVersionExcluding` and `insertWalk` barrier seams. | Test-only, like every other seam: nothing in `src/` references them and no route, flag or hook reaches them. |
| `package.json` | `test:admin`; `browser-admin` added to `test:browser`. | Scripts only; no dependency added. |

No schema migration, dependency, framework or infrastructure was added. No existing test was
removed, skipped, weakened or rewritten.

### Files changed

| File | Status |
| --- | --- |
| `src/instrument/InstrumentAdminService.cfc`, `src/instrument/DraftEditor.cfc`, `src/instrument/InstrumentVersionComparer.cfc`, `app/assets/js/admin.js` | New |
| `tests/cfml/specs/InstrumentAdministrationTest.cfc` (17), `DraftEditorTest.cfc` (11), `InstrumentVersionComparerTest.cfc` (6), `RetireConcurrencyBarrierTest.cfc` (3) | New |
| `tests/node/admin-instrument.test.mjs` (11), `tests/node/browser-admin.test.mjs` (6) | New |
| `docs/evidence/phase6-admin-red-before-fix.md`, `docs/evidence/screenshots/admin-*.png` | New |
| The files in the table above | Changed |
| `docs/ENDPOINTS.md`, `docs/ARCHITECTURE.md`, `docs/DATA_CONTRACT.md`, `docs/OPEN_DECISIONS.md`, `docs/LOCAL_SETUP.md`, `docs/ACCEPTANCE_TRACKING.md`, `BUILD_STATUS.md` | Records |
| `manifest.json` | Refreshed (`node scripts/refresh-manifest.mjs`) |

### Tests and results (development runs, before the commit)

Environment: Lucee 6.2.8.20, SQL Server 2022 Developer in Docker, Node 22.22.2, Playwright 1.56.1
with Chromium, axe-core 4.13.0.

| Run | Result |
| --- | --- |
| Base `0c6fa10`, fresh database | Node/HTTP/Playwright 193/193, CFML 411/411 |
| New and affected CFML specs | `InstrumentAdministrationTest` 17/17, `DraftEditorTest` 11/11, `InstrumentVersionComparerTest` 6/6, `RetireConcurrencyBarrierTest` 3/3, `InstrumentImmutabilityTest` 15/15, `ReportServiceTest` 15/15, `ReportCoherenceTest` 4/4 |
| New HTTP and browser files | `admin-instrument` 11/11, `browser-admin` 6/6 |
| Neighbouring suites after the shell and router changes | `shell`, `visibility`, `admin-publish`, `walks`, `browser`, `browser-reports`, `browser-persistence`: 102/102 |

Red before green (`docs/evidence/phase6-admin-red-before-fix.md`): the retire race (a walk pinned
to a RETIRED version; a deadlock victim), a 500 for an import without a document, Reports
unopenable after retiring the only version, two concurrent retirements leaving nothing in service,
and every new check failing against the base source.

**The authoritative result is the full gate on the exact commit**, from a clean tree on a freshly
created database with screenshots written outside the repository. Its transcript is
`docs/evidence/phase6-admin-release-gate.txt`, added in the commit that follows this one, because
recording it here would change the commit it describes. **Result on
`407b0cdb5616575ef92cfb84ac57566b87f6424d`: Node/HTTP/Playwright 210/210 (193 + 11 `admin-instrument` +
6 `browser-admin`), CFML 449/449 (411 + 17 + 11 + 6 + 3 + 1 new `InstrumentImmutabilityTest` case), 0
failed, 0 skipped**, `validate:handoff` ok (51 checks), migration `006` re-application idempotent,
working tree unchanged afterwards. Lucee 6.2.8.20 and SQL Server 2022 (16.0.4295.3) only.

### Unresolved and not verified (Phase 6 administration)

1. **Adobe ColdFusion 2023 and SQL Server 2016 remain unverified.** New engine-sensitive constructs
   to re-run there: `WITH (HOLDLOCK, ROWLOCK)` on the `INSERT ... SELECT` source with `OUTPUT
   INSERTED` (SQL Server 2016 syntax, but the lock behavior under the Adobe datasource's isolation
   level must be re-proved by `RetireConcurrencyBarrierTest`), `sp_getapplock` with a
   transaction owner inside the Adobe `transaction` block (it must run on the transaction's own
   connection), a non-`required` argument receiving
   `null` positionally, `cfthread` in the new barrier spec, `compare()` for case-sensitive key
   matching, and the raw body length the 413 cap reads (since the audit corrections, the router's
   bounded byte read of the servlet container's input stream, P6A-01 below -- the unwrapping of the
   engine's request is exactly the part to re-prove on Adobe ColdFusion).
2. **The approved wording for the 17 placeholder prompts is still the district's to supply.** The
   tooling to apply it exists; the content does not.
3. **Structure is not editable in the browser** by decision; a structural change is a document edit
   and import.
4. **Screen readers were not tested.** The view passes axe-core (WCAG 2.1 A/AA, serious and critical)
   and keyboard checks; that is not the same thing.
5. **On a phone the version list scrolls sideways inside its own region** (no page overflow). It is
   usable, not designed for 375 px; administrators are expected on a desktop.
6. **A 422 publish refusal is not browser-tested** (ADM-03 row). The service and HTTP evidence is
   unchanged.
7. **Nothing here is independently audited.** Phase 6 administration and Phase 7 are implementation
   candidates: not frozen, not accepted.

## Excel round-trip for the yearly instrument update

**Why.** The product owner confirmed the instrument changes once a year, in summer, and chose to
make structural changes in Excel first, with a friendlier in-app editor scoped after the first
summer shows what actually changes. The plan and its status are in the Phase 6 review document.

**Starting point.** `2b68cc06db98bf335b375529088ca5adef7132fb` (Phase 6 administration and its gate
transcript), clean tree, remote equal to HEAD.

### What it adds

| Piece | What it does |
| --- | --- |
| `src/instrument/InstrumentDocumentExporter.cfc` | Pure: a version's normalized content back to the authoring document, the exact inverse of `ConfigNormalizer` (rows keep their authoring ids; references resolve to the ids they had; the version declares DRAFT; rows in reading order). |
| `GET /api/admin/instrument/versions/{id}/document` | `InstrumentAdminService.exportDocument`: any version as that document, from its checksum-verified snapshot. |
| `app/assets/js/workbook.js` | Dependency-free .xlsx writer and reader in the page: the aligned workbook's layout plus Start Here and document sheets; typed cell handling; problems by sheet, row and column; `locate()` for server paths; limits, CRC checks, no DOCTYPE. |
| Admin view | Download on every version (Excel workbook or JSON document). Import takes a workbook or a JSON document and an optional new draft label, lists workbook problems by cell, locates server problems on their cells, and asks before replacing a draft that changed since the download or that the file did not come from. |

The server never parses a spreadsheet: an uploaded workbook becomes the same JSON document any
upload sends, through the unchanged import route. No schema migration, dependency, framework or
infrastructure was added. `libreoffice-calc` was installed into this build container to produce and
check fixtures; nothing in the project depends on it.

### Changes to existing files

| File | Change |
| --- | --- |
| `src/instrument/InstrumentAdminService.cfc` | `exportDocument`; the exporter is a new constructor argument. |
| `src/controllers/AdminInstrumentController.cfc`, `src/http/Router.cfc`, `src/Bootstrap.cfc` | The action, the route (`instrument.manage`), the wiring. |
| `app/assets/js/admin.js`, `src/views/shell.html` | Download panel; the import card accepts .xlsx and an optional draft label; problems located on cells; the replace check. |
| `tests/node/admin-instrument.test.mjs`, `tests/node/browser-admin.test.mjs` | New cases (below); the document route joins the 401/403 table; one assertion updated for deliberately changed wording. |
| `package.json` | `test:workbook`; the workbook test joins `test:admin`. |

### Files changed

| File | Status |
| --- | --- |
| `src/instrument/InstrumentDocumentExporter.cfc`, `app/assets/js/workbook.js` | New |
| `tests/cfml/specs/InstrumentDocumentExporterTest.cfc` (6), `tests/node/workbook.test.mjs` (12) | New |
| `tests/fixtures/workbooks/` (two LibreOffice-saved workbooks, the script that edited one, a README) | New |
| `docs/evidence/excel-roundtrip-red-before-green.md`, `docs/evidence/screenshots/admin-download-desktop.png` | New |
| The files in the table above; `docs/evidence/screenshots/admin-*.png` refreshed | Changed |
| `docs/ENDPOINTS.md`, `docs/ARCHITECTURE.md`, `docs/DATA_CONTRACT.md`, `docs/OPEN_DECISIONS.md`, `docs/ACCEPTANCE_TRACKING.md`, `docs/LOCAL_SETUP.md`, `BUILD_STATUS.md`, `manifest.json` | Records |

### Tests and results (development runs, before the commit)

| Run | Result |
| --- | --- |
| `InstrumentDocumentExporterTest` | 6/6 |
| `workbook.test.mjs` | 12/12 |
| `admin-instrument.test.mjs` | 13/13 (2 new: an edited workbook imports as a draft with exactly the edit; the LibreOffice-edited workbook imports and the comparison shows exactly its five edits) |
| `browser-admin.test.mjs` | 7/7 (1 new: download, upload, problems by cell, nothing sent for a workbook problem, the replace check; the download panel added to the accessibility case) |

Red before green: `docs/evidence/excel-roundtrip-red-before-green.md` (every new check fails without
the new source; no product defect was found). **The authoritative result is the full gate on the
exact commit**, recorded in `docs/evidence/excel-roundtrip-release-gate.txt` in the commit after it.
**Result on `0a784d58f66d6796d7ce6d55b1965f6e7d408340`: Node/HTTP/Playwright 225/225 (210 + 12
`workbook` + 2 HTTP + 1 browser), CFML 455/455 (449 + 6 `InstrumentDocumentExporterTest`), 0 failed,
0 skipped**, `validate:handoff` ok, working tree unchanged afterwards. Lucee 6.2.8.20 and SQL Server
2022 only.

### Unresolved and not verified (Excel round-trip)

1. **Not opened in Microsoft Excel.** Excel is not available in this environment. The reader is
   proven against the aligned workbook written by other software and against LibreOffice Calc 24.2
   output; the writer's files open in LibreOffice. A check in real Excel (open, edit, save, upload)
   belongs in the spring practice run.
2. **Adobe ColdFusion 2023 and SQL Server 2016 remain unverified.** The exporter is plain CFML
   (closures passed to `arraySort`, recursive private methods); re-run
   `InstrumentDocumentExporterTest` there.
3. **Editing structure in Excel is still technical.** Rows point at each other by id, and rules and
   settings are JSON in cells. Validation catches mistakes and names the cell, but the admin still
   has to understand the sheets. That is what the later in-app editor is for.
4. **Uploading under an existing draft's label replaces that draft.** The page asks first when the
   draft changed since the download or the file did not come from it; the server itself does not
   compare checksums on import. *(Superseded by audit correction P6A-02 below: an administrator's
   import is now create-only unless it names the draft's id and the checksum agreed to, which the
   server compares under the version lock.)*
5. **Not independently audited**, like the rest of Phase 6 administration and Phase 7.

## Submitted for audit (superseded by the audit corrections below)

Phase 6 administration and the Excel round-trip are submitted for independent audit as an
implementation candidate: range `0c6fa10..786e572`. What to audit, where each claim is, the changes
outside Phase 6 files, where to look first and the known gaps are in
`docs/evidence/phase6-admin-audit-handoff.md`; the environment is in
`docs/evidence/phase6-admin-environment.md`. Not accepted, frozen or complete until the audit says so.

## Phase 6 administration audit corrections (P6A-01 to P6A-04)

An independent audit of the Phase 6 administration candidate at
`2a3f2ecb4f070401cba00518c0db8a2de823a29d` (branch `claude/icfwalk-phase-6-admin-publish`) found it
not ready to freeze, with four findings. They are corrected on
`claude/icfwalk-phase-6-admin-audit-corrections`, created from that exact commit. Each correction
was preceded by a regression that failed on the candidate for the intended reason
(`docs/evidence/phase6-admin-audit-corrections-red-before-fix.md`). No schema migration, no
dependency, no test removed, skipped or loosened. **Implementation candidate submitted for
independent re-audit; not accepted, frozen or complete.**

### What was wrong, and what each fix is

**P6A-01 -- bodies were read and parsed before anyone asked who sent them.** `Router.dispatch` built
the request by reading and deserializing the whole body, then authenticated, then checked CSRF;
the import's 5,000,000-byte limit was the controller's, after all of that; the chunked fallback
measured `len()` of text (characters); the page read a whole file before checking its size.
*Fix:* `Router.handle(source)` matches the route and reads metadata only; runs the maintenance
token check, or authentication, CSRF and the permission; only then reads the body, under the
route's `maxBodyBytes` (route metadata: 5,000,000 for the import, else the 20,000,000-byte server
maximum) -- a declared length over it is refused without reading, otherwise at most one byte past it
is read from the servlet container's stream and counted in bytes; then parses (`JsonBodyParser`);
then decides the one body-dependent permission (walk creation's `orgUnitBody`). New
`HttpRequestSource` (reads the container's stream underneath Lucee's wrapper, which otherwise copies
the whole body into memory first; falls back to the engine's buffered body measured in UTF-8 bytes)
and `JsonBodyParser`; `MaintenanceGuard.precheck`. The controller's own size check is gone.
`admin.js` reads the first 8 bytes to tell a workbook from JSON, compares `file.size` with 20 MB / 5
MB, and only then reads the file.

**P6A-02 -- re-import had no server-side concurrency control.** The page compared the workbook with
its cached version list and sent `{ document }`; the server overwrote whatever DRAFT held the label.
*Fix:* the administrator's import is create-only (409 `DRAFT_REPLACEMENT_REQUIRED`, with the DRAFT's
id and current checksum) unless it sends `replace: { versionId, expectedChecksum }`; both are compared
in `writeNormalizedDraft` on the row its `UPDLOCK, HOLDLOCK` read holds, and any other state is 409
`DRAFT_CHANGED` (or the existing immutable/in-use 409s) with nothing written and one refusal audit.
A replacement never creates. Success audits `replacedVersionId` and `previousChecksum`. The page
keeps its confirmation, sends the token (the workbook's checksum when nothing needed asking, the
listed checksum when it asked), asks about exactly the DRAFT the server reports when a label was
taken after it looked, and on `DRAFT_CHANGED` says so, reloads and imports nothing. The export takes
metadata and document from one read (`SnapshotService.loadVersion`). The maintenance import is
deliberately unchanged (label re-import, the seed path).

**P6A-03 -- a discard by id could delete a different version.** `discardDraftById` read the row
unlocked and delegated to the label-addressed `discardDraft`. *Fix:* one transaction: lock the path
id (`findVersionByIdForUpdate`), derive everything from that row, require a DRAFT no walk references,
delete that id (`deleteDraftVersionCascade` now returns the version rows deleted; exactly one is
required), audit and return that id. The label-addressed discard stays, for the maintenance route.

**P6A-04 -- malformed workbook XML escaped as a JavaScript exception.** `&#999999999;` reached
`String.fromCodePoint` (`RangeError`), a malformed cell reference threw `TypeError`, `readWorkbook`
converted only `WorkbookError`, and the import handler parsed outside its guarded flow. *Fix:*
character references must name an XML 1.0 `Char` (else `XML_MALFORMED`); row and cell references must
be spreadsheet references within A..XFD / 1..1048576, the cell's row matching its row (else
`CELL_REFERENCE_INVALID` with the sheet); `readWorkbook` returns any other failure as a
`WORKBOOK_UNREADABLE` problem; the page reads and parses inside `guarded`, so a rejected file shows
its problems, sends nothing and leaves the page usable.

### Files changed (audit corrections)

| File | Change |
| --- | --- |
| `src/http/Router.cfc` | `handle(source)`, the ordered pipeline, route `maxBodyBytes`, `declaredLength`, 413 before parsing. |
| `src/http/HttpRequestSource.cfc`, `src/http/JsonBodyParser.cfc` | New: request metadata and the bounded byte read; the one body parser. |
| `src/http/MaintenanceGuard.cfc` | `precheck` (the token check before the body); `require` unchanged in effect. |
| `src/Bootstrap.cfc` | Wires the two new components. |
| `src/controllers/AdminInstrumentController.cfc` | Import: `replace` accepted and passed through; the size check removed (it is the route's). |
| `src/instrument/InstrumentAdminService.cfc` | `importDocument`: create-only or a validated replacement token (400 `REPLACE_INVALID`); `exportDocument` from one read. |
| `src/instrument/InstrumentImportService.cfc` | `importConfig` options; `createOnly` / `replaceVersionId` decided under the version lock; replacement audit; `discardDraftById` rewritten as one id-addressed transaction. |
| `src/instrument/SnapshotService.cfc` | `loadVersion`: the row and its verified snapshot from one read. |
| `src/instrument/DefinitionRepository.cfc` | `deleteDraftVersionCascade` returns the version rows deleted. |
| `app/assets/js/admin.js` | Header-first size check; read and parse inside `guarded`; replacement tokens; 409 handling. |
| `app/assets/js/workbook.js` | Character-reference and cell-reference validation; `readWorkbook` never throws. |
| `tests/cfml/specs/RouterBodyOrderTest.cfc` (12), `DraftReplacementConcurrencyTest.cfc` (6), `DiscardIdentityBarrierTest.cfc` (2) | New. |
| `tests/cfml/support/FakeRequestSource.cfc`, `SpyJsonBodyParser.cfc`, `RouterTestDoubles.cfc` | New, test-only. |
| `tests/cfml/support/InterceptingDefinitionRepository.cfc` | A `findVersionById` seam. |
| `tests/node/admin-instrument.test.mjs` | 6 new cases (P6A-01 x5, P6A-02); the ADM-01 re-import case now also proves the create-only refusal before the explicit replacement's 200. |
| `tests/node/browser-admin.test.mjs` | 5 new cases (P6A-02 x2, P6A-04 x2, P6A-01). |
| `tests/node/workbook.test.mjs` | 4 new cases (P6A-04). |
| `docs/ENDPOINTS.md`, `docs/ARCHITECTURE.md`, `docs/DATA_CONTRACT.md`, `docs/OPEN_DECISIONS.md`, `docs/ACCEPTANCE_TRACKING.md`, `docs/LOCAL_SETUP.md`, `BUILD_STATUS.md`, `manifest.json` | Records. |

One existing assertion changed, deliberately and by the audit's instruction: the ADM-01 HTTP case
(`admin-instrument.test.mjs`) re-imported the same label with `{ document }` and expected 200. That
is now refused 409 `DRAFT_REPLACEMENT_REQUIRED` (asserted, with the row version unmoved), and the same
re-import with the exact replacement token is what answers 200, with every original assertion on
that 200 kept.

### Tests and results (development runs, before the commit)

| Run | Result |
| --- | --- |
| `RouterBodyOrderTest` | 12/12 |
| `DraftReplacementConcurrencyTest` | 6/6 |
| `DiscardIdentityBarrierTest` | 2/2 |
| `InstrumentAdministrationTest`, `InstrumentImmutabilityTest`, `InstrumentImportServiceTest` | 17/17, 15/15, 10/10 |
| `workbook.test.mjs` | 16/16 (12 + 4) |
| `admin-instrument.test.mjs` | 19/19 (13 + 6) |
| `browser-admin.test.mjs` | 12/12 (7 + 5) |
| Whole suite, `ICFWALK_REQUIRE_APP=1 npm test`, before the manifest refresh | CFML 475/475 (455 + 20 new); Node/HTTP/Playwright 239/240 -- the one failure was PKG-01, the manifest hashes of `docs/DATA_CONTRACT.md` and `docs/OPEN_DECISIONS.md`, edited during the run and refreshed afterwards with `scripts/refresh-manifest.mjs` |

**The authoritative result is the full gate on the exact code commit**, recorded in the commit after
it (`docs/evidence/phase6-admin-audit-corrections-release-gate.txt`).

### Unresolved and not verified (audit corrections)

1. **Adobe ColdFusion 2023, SQL Server 2016, IIS were not available and were not run.** The parts
   most likely to differ: `HttpRequestSource`'s unwrapping of the engine's request
   (`ServletRequestWrapper.getRequest()` on ColdFusion) and whether ColdFusion has already consumed
   the body (then the fallback applies and the connector's "Maximum size of post data" is what bounds
   a chunked body); `isInstanceOf` with Java class names; the barrier specs' use of
   `sys.dm_exec_requests` (needs `VIEW SERVER STATE` for the test login); `DELETE ... OUTPUT
   DELETED` through the Adobe datasource.
2. **The connector limits are documented, not verified.** ColdFusion's "Maximum size of post data",
   IIS `maxAllowedContentLength` and Apache `LimitRequestBody` (docs/LOCAL_SETUP.md) have not been
   exercised; the verification runtime configures no connector limit, so the application's limits
   are the ones tested.
3. **Microsoft Excel was not used; no screen reader was used.**
4. **Adjacent, not changed (outside the four findings).** `preview`, `wording`, `placeholders`,
   `compareVersions` and `editDraft` still read the version row and then its snapshot in two reads,
   as the export did. For the reads that is a display mismatch at worst; `editDraft` is protected by
   its under-lock checksum comparison except in an A-B-A sequence (the DRAFT changes and changes
   back between its two reads). Worth the same one-read treatment in a later round.
5. **Not independently audited.**

