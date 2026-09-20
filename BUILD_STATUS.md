# ICFWalk build status

Scope of this record: **Phase 0 (baseline), Phase 1 (application and database foundation),
Phase 2 (identity, roles, authorization, organizational scope), Phase 3 (instrument engine and
visual shell), and Phase 4 (walk persistence, autosave, completion, concurrency, audit)** from
`docs/IMPLEMENTATION_PLAN.md`. Phase 5 and later have not been started. Phase 4 details are in the
section "Phase 4" at the end; earlier records are kept as delivered.

Target platform: Adobe ColdFusion 2023 + Microsoft SQL Server 2016+. Branch: `claude/admiring-wozniak-fsuayk`
(Phase 3 base commit `9c03298`, itself on `claude/sharp-faraday-szq937`).

Two correction-only sessions followed Phase 4, each against an independent audit; their records are
the last two sections of this file. The second one is the current state of the build.

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
