# ICFWalk build status

Scope of this record: **Phase 0 (baseline) and Phase 1 (application and database foundation)**
from `docs/IMPLEMENTATION_PLAN.md`. Phase 2 and later have not been started.

Target platform: Adobe ColdFusion 2023 + Microsoft SQL Server 2016+. Branch: `claude/hopeful-keller-wwpeio`.

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

## Exact recommended starting point for Phase 2

1. Read `docs/ARCHITECTURE.md` ("What Phase 2 builds on") and `src/http/Router.cfc`.
2. Add `src/identity/`: an `IdentityProvider` interface (SSO adapter driven by `ICFWALK_SSO_*`
   environment values), the development stub gated by `config.devIdentityEnabled` (already
   validated to be impossible in production), and `UserRepository` over `icf.app_user`.
3. Add `src/authorization/AuthorizationService.cfc` resolving `icf.user_role_scope` with
   `effective_start/effective_end`, `include_descendants` over `icf.org_unit`, and the five role
   flags from `icf.app_role`; expose `requirePermission(user, permission, orgUnitId)` and a
   `Router.dispatch` hook so every non-maintenance route declares its authorization explicitly.
4. Enable sessions in `app/Application.cfc` (`this.sessionManagement = true`, secure/HttpOnly/
   SameSite cookie settings, rotation on sign-in) and add CSRF tokens for state-changing routes.
5. Write negative tests first (AUTH-01, AUTH-04..AUTH-09) in `tests/cfml/specs/AuthorizationTest.cfc`
   using synthetic org units/users/assignments created and removed by the spec, and extend
   `tests/node/cfml-suite.test.mjs` with unauthenticated-request checks.
6. Record `USER_SIGNED_IN`, `ACCESS_DENIED` audit events through `AuditRepository.record`
   with the actor user id.
