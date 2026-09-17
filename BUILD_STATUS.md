# ICFWalk build status

Scope of this record: **Phase 0 (baseline), Phase 1 (application and database foundation),
Phase 2 (identity, roles, authorization, organizational scope), and Phase 3 (instrument engine and
visual shell)** from `docs/IMPLEMENTATION_PLAN.md`. Phase 4 and later have not been started. Phase 3
details are in the section "Phase 3" at the end; earlier records are kept as delivered.

Target platform: Adobe ColdFusion 2023 + Microsoft SQL Server 2016+. Branch: `claude/sharp-faraday-szq937`
(Phase 2 base commit `0b5d91a`).

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
