// Acceptance DB-01, DB-02, DB-03 against a real SQL Server (2016+). Creates a disposable
// database with the admin login, applies the supplied scripts, and drops it afterwards.
// Skipped when no database configuration is available.
import { test } from "node:test";
import assert from "node:assert/strict";
import sql from "mssql";
import { applyScript, connectionConfig, hasDatabaseConfig, loadRuntimeEnv, readScript } from "./helpers.mjs";

const env = loadRuntimeEnv();
const available = hasDatabaseConfig(env);
const dbName = `icfwalk_scripts_${Date.now().toString(36)}`;

test("DB-01..03 supplied scripts against an empty SQL Server database", { skip: available ? false : "ICFWALK_DB_* not configured" }, async (t) => {
  const master = await sql.connect(connectionConfig(env, "master", true));
  await master.request().batch(`CREATE DATABASE [${dbName}]`);
  await master.close();
  const pool = await sql.connect(connectionConfig(env, dbName, true));
  try {
    const version = await pool.request().query("SELECT SERVERPROPERTY('ProductVersion') AS v, SERVERPROPERTY('Edition') AS e");
    t.diagnostic(`SQL Server ${version.recordset[0].v} ${version.recordset[0].e}`);
    assert.ok(Number(String(version.recordset[0].v).split(".")[0]) >= 13, "SQL Server 2016 or later");

    // DB-01: both scripts complete and commit.
    const first = await applyScript(pool, readScript("001_schema.sql"));
    assert.equal(first.ok, true, first.error?.message);
    assert.equal(first.recordset[0].result, "ICFWalk database objects created successfully.");
    assert.equal(Number(first.recordset[0].table_count), 20);
    const patch = await applyScript(pool, readScript("002_alignment_patch.sql"));
    assert.equal(patch.ok, true, patch.error?.message);
    assert.equal(patch.recordset[0].response_option_definition_available, 1);
    const roles = await pool.request().query("SELECT role_code, can_manage_instruments, can_open_walk_details FROM icf.app_role ORDER BY role_code");
    assert.deepEqual(roles.recordset.map((r) => r.role_code), ["DISTRICT_REPORT_ONLY", "DISTRICT_WALK_REPORT", "MASTER_INSTRUMENT_ADMIN", "SCHOOL_REPORT_ONLY", "SCHOOL_WALK_REPORT"]);
    const admin = roles.recordset.find((r) => r.role_code === "MASTER_INSTRUMENT_ADMIN");
    assert.equal(admin.can_manage_instruments, true);
    assert.equal(admin.can_open_walk_details, false);
    const instrument = await pool.request().query("SELECT code FROM icf.instrument");
    assert.deepEqual(instrument.recordset.map((r) => r.code), ["ICFWALK"]);

    // DB-02: rerunning 001 aborts without dropping or replacing objects.
    const before = await pool.request().query("SELECT COUNT(*) AS n FROM sys.tables WHERE schema_id = SCHEMA_ID('icf')");
    const rerun = await applyScript(pool, readScript("001_schema.sql"));
    assert.equal(rerun.ok, false);
    assert.equal(rerun.error.number, 50001);
    assert.match(rerun.error.message, /already contains tables/);
    const after = await pool.request().query("SELECT COUNT(*) AS n FROM sys.tables WHERE schema_id = SCHEMA_ID('icf')");
    assert.equal(after.recordset[0].n, before.recordset[0].n);
    const rolesAfter = await pool.request().query("SELECT COUNT(*) AS n FROM icf.app_role");
    assert.equal(rolesAfter.recordset[0].n, 5, "no duplicate seed rows");

    // DB-03: reapplying 002 is a no-op without error or duplicate column.
    const patchAgain = await applyScript(pool, readScript("002_alignment_patch.sql"));
    assert.equal(patchAgain.ok, true, patchAgain.error?.message);
    const cols = await pool.request().query("SELECT COUNT(*) AS n FROM sys.columns WHERE object_id = OBJECT_ID('icf.response_option') AND name = 'definition'");
    assert.equal(cols.recordset[0].n, 1);

    // Phase 4 migration 003: walk mutation log, additive and idempotent.
    const mutation = await applyScript(pool, readScript("003_walk_mutation.sql"));
    assert.equal(mutation.ok, true, mutation.error?.message);
    assert.equal(mutation.recordset[0].walk_mutation_available, 1);
    const mutationAgain = await applyScript(pool, readScript("003_walk_mutation.sql"));
    assert.equal(mutationAgain.ok, true, mutationAgain.error?.message);
    const tables = await pool.request().query("SELECT COUNT(*) AS n FROM sys.tables WHERE schema_id = SCHEMA_ID('icf')");
    assert.equal(tables.recordset[0].n, 21);
    const mutationCols = await pool.request().query("SELECT COUNT(*) AS n FROM sys.columns WHERE object_id = OBJECT_ID('icf.walk_mutation')");
    assert.equal(mutationCols.recordset[0].n, 6);

    // Correction migration 004: the request fingerprint column, additive and idempotent.
    const fingerprint = await applyScript(pool, readScript("004_mutation_fingerprint.sql"));
    assert.equal(fingerprint.ok, true, fingerprint.error?.message);
    assert.equal(fingerprint.recordset[0].request_fingerprint_available, 1);
    const fingerprintAgain = await applyScript(pool, readScript("004_mutation_fingerprint.sql"));
    assert.equal(fingerprintAgain.ok, true, fingerprintAgain.error?.message);
    const fingerprintCol = await pool.request().query("SELECT COUNT(*) AS n FROM sys.columns WHERE object_id = OBJECT_ID('icf.walk_mutation') AND name = 'request_fingerprint'");
    assert.equal(fingerprintCol.recordset[0].n, 1, "one fingerprint column after two applications");
    const mutationColsAfter = await pool.request().query("SELECT COUNT(*) AS n FROM sys.columns WHERE object_id = OBJECT_ID('icf.walk_mutation')");
    assert.equal(mutationColsAfter.recordset[0].n, 7);
    const tablesAfter = await pool.request().query("SELECT COUNT(*) AS n FROM sys.tables WHERE schema_id = SCHEMA_ID('icf')");
    assert.equal(tablesAfter.recordset[0].n, 21, "004 adds no table");
    // The digest constraint accepts a lower-case hexadecimal SHA-256 and refuses anything else.
    await pool.request().batch(`INSERT INTO icf.org_unit (org_unit_id, org_unit_code, org_unit_type, name) VALUES ('11111111-1111-1111-1111-111111111111', 'fp-unit', 'SCHOOL', 'Fingerprint fixture');
      INSERT INTO icf.app_user (user_id, identity_subject, display_name) VALUES ('22222222-2222-2222-2222-222222222222', 'fp-user', 'Fingerprint fixture');
      INSERT INTO icf.instrument (instrument_id, code, name) VALUES ('33333333-3333-3333-3333-333333333333', 'FPTEST', 'Fingerprint fixture');
      INSERT INTO icf.instrument_version (version_id, instrument_id, version_label, status) VALUES ('44444444-4444-4444-4444-444444444444', '33333333-3333-3333-3333-333333333333', 'fp', 'DRAFT');
      INSERT INTO icf.walk (walk_id, version_id, org_unit_id, owner_user_id) VALUES ('55555555-5555-5555-5555-555555555555', '44444444-4444-4444-4444-444444444444', '11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222');`);
    const good = await applyScript(pool, `INSERT INTO icf.walk_mutation (mutation_id, walk_id, actor_user_id, action, request_fingerprint, result_json)
      VALUES ('66666666-6666-6666-6666-666666666666', '55555555-5555-5555-5555-555555555555', '22222222-2222-2222-2222-222222222222', 'SAVE', '${"a".repeat(64)}', '{}');`);
    assert.equal(good.ok, true, good.error?.message);
    const bad = await applyScript(pool, `INSERT INTO icf.walk_mutation (mutation_id, walk_id, actor_user_id, action, request_fingerprint, result_json)
      VALUES ('77777777-7777-7777-7777-777777777777', '55555555-5555-5555-5555-555555555555', '22222222-2222-2222-2222-222222222222', 'SAVE', '${"Z".repeat(64)}', '{}');`);
    assert.equal(bad.ok, false, "a non-hexadecimal digest is refused");
    const legacy = await applyScript(pool, `INSERT INTO icf.walk_mutation (mutation_id, walk_id, actor_user_id, action, result_json)
      VALUES ('88888888-8888-8888-8888-888888888888', '55555555-5555-5555-5555-555555555555', '22222222-2222-2222-2222-222222222222', 'SAVE', '{}');`);
    assert.equal(legacy.ok, true, "rows written before the patch stay valid");

    // Correction migration 005: the org unit -> instrument dimension value mapping, additive and
    // idempotent, and the relational facts the School invariant rests on.
    const mapping = await applyScript(pool, readScript("005_org_unit_dimension_map.sql"));
    assert.equal(mapping.ok, true, mapping.error?.message);
    assert.equal(mapping.recordset[0].org_unit_dimension_map_available, 1);
    assert.equal(mapping.recordset[0].mapping_rows, 0, "the patch derives nothing on its own");
    const mappingAgain = await applyScript(pool, readScript("005_org_unit_dimension_map.sql"));
    assert.equal(mappingAgain.ok, true, mappingAgain.error?.message);
    const mappingTables = await pool.request().query("SELECT COUNT(*) AS n FROM sys.tables WHERE schema_id = SCHEMA_ID('icf')");
    assert.equal(mappingTables.recordset[0].n, 22, "005 adds exactly one table");

    await pool.request().batch(`INSERT INTO icf.org_unit (org_unit_id, org_unit_code, org_unit_type, name) VALUES ('99999999-9999-9999-9999-999999999999', 'map-unit-b', 'SCHOOL', 'Mapping fixture B');`);
    const firstMapping = await applyScript(pool, `INSERT INTO icf.org_unit_dimension_map (org_unit_id, dimension_code, value_code, source)
      VALUES ('11111111-1111-1111-1111-111111111111', 'school', 'some_school', 'EXPLICIT');`);
    assert.equal(firstMapping.ok, true, firstMapping.error?.message);
    // One unit per (dimension, value): School B cannot claim School A's School value.
    const stolen = await applyScript(pool, `INSERT INTO icf.org_unit_dimension_map (org_unit_id, dimension_code, value_code, source)
      VALUES ('99999999-9999-9999-9999-999999999999', 'school', 'some_school', 'EXPLICIT');`);
    assert.equal(stolen.ok, false, "one School dimension value belongs to at most one org unit");
    // One value per (unit, dimension): a unit never carries two School values.
    const second = await applyScript(pool, `INSERT INTO icf.org_unit_dimension_map (org_unit_id, dimension_code, value_code, source)
      VALUES ('11111111-1111-1111-1111-111111111111', 'school', 'another_school', 'EXPLICIT');`);
    assert.equal(second.ok, false, "one org unit carries at most one School value");
    const unknownSource = await applyScript(pool, `INSERT INTO icf.org_unit_dimension_map (org_unit_id, dimension_code, value_code, source)
      VALUES ('99999999-9999-9999-9999-999999999999', 'school', 'another_school', 'GUESSED_FROM_NAME');`);
    assert.equal(unknownSource.ok, false, "only declared or code-aligned provenance is storable");
    const orphan = await applyScript(pool, `INSERT INTO icf.org_unit_dimension_map (org_unit_id, dimension_code, value_code, source)
      VALUES ('00000000-0000-0000-0000-0000000000ff', 'school', 'orphan_school', 'EXPLICIT');`);
    assert.equal(orphan.ok, false, "a mapping always names a real org unit");

    // ---- Correction migration 006 -------------------------------------------------------------
    // Applied here over a database that is at exactly the Phase 5 schema (001..005) and carries
    // data, so this is the "over the Phase 5 schema and data shape" case, not only a clean one.
    await pool.request().batch(`
      INSERT INTO icf.instrument (instrument_id, code, name) VALUES ('44444444-4444-4444-4444-444444444444', 'MIG006', 'Migration 006 fixture');
      INSERT INTO icf.instrument_version (version_id, instrument_id, version_label, status, effective_start, published_at, published_by_user_id, compiled_snapshot_json, checksum_sha256)
        VALUES ('55555555-5555-5555-5555-555555555501', '44444444-4444-4444-4444-444444444444', 'v1', N'PUBLISHED', SYSUTCDATETIME(), SYSUTCDATETIME(), '22222222-2222-2222-2222-222222222222', N'{}', REPLICATE('a', 64));
      INSERT INTO icf.section_definition (section_id, version_id, section_key, display_order, title)
        VALUES ('66666666-6666-6666-6666-666666666601', '55555555-5555-5555-5555-555555555501', 'sec', 10, N'Section');
      INSERT INTO icf.dimension_definition (dimension_id, code, label, data_type, reportable, sensitive, active)
        VALUES ('77777777-7777-7777-7777-777777777701', 'grade', N'Grade as V1 named it', N'LIST', 1, 0, 1);
      INSERT INTO icf.dimension_value (value_id, dimension_id, value_code, label, display_order, active)
        VALUES ('88888888-8888-8888-8888-888888888801', '77777777-7777-7777-7777-777777777701', 'k', N'Kindergarten as V1 labelled it', 10, 1),
               ('88888888-8888-8888-8888-888888888802', '77777777-7777-7777-7777-777777777701', 'g1', N'Grade 1 as V1 labelled it', 20, 1);
      INSERT INTO icf.instrument_dimension (version_id, dimension_id, section_id, display_order, required)
        VALUES ('55555555-5555-5555-5555-555555555501', '77777777-7777-7777-7777-777777777701', '66666666-6666-6666-6666-666666666601', 10, 0);`);

    const scoped = await applyScript(pool, readScript("006_version_scoped_dimensions.sql"));
    assert.equal(scoped.ok, true, scoped.error?.message);
    assert.equal(scoped.recordset[0].version_scoped_dimension_columns_available, 1);
    assert.equal(scoped.recordset[0].instrument_dimension_value_available, 1);
    assert.equal(scoped.recordset[0].publisher_required_constraint_present, 1);
    assert.equal(scoped.recordset[0].version_dimension_rows, 1);
    assert.equal(scoped.recordset[0].version_dimension_value_rows, 2, "every value of the placed dimension is backfilled for the version");

    // The backfill copies exactly what the version was already reading -- no label, order or
    // activity is invented, so an existing version reads back unchanged.
    const backfilled = await pool.request().query(`
      SELECT p.dimension_label, p.dimension_data_type, p.dimension_reportable, p.dimension_sensitive, p.dimension_active
        FROM icf.instrument_dimension p WHERE p.version_id = '55555555-5555-5555-5555-555555555501'`);
    assert.equal(backfilled.recordset[0].dimension_label, "Grade as V1 named it");
    assert.equal(backfilled.recordset[0].dimension_data_type, "LIST");
    assert.equal(backfilled.recordset[0].dimension_active, true);
    const values = await pool.request().query(`
      SELECT dv.value_code, iv.label, iv.display_order, iv.active
        FROM icf.instrument_dimension_value iv JOIN icf.dimension_value dv ON dv.value_id = iv.value_id
       WHERE iv.version_id = '55555555-5555-5555-5555-555555555501' ORDER BY iv.display_order`);
    assert.deepEqual(values.recordset.map((r) => [r.value_code, r.label, r.display_order, r.active]), [
      ["k", "Kindergarten as V1 labelled it", 10, true],
      ["g1", "Grade 1 as V1 labelled it", 20, true],
    ]);

    // Re-applying changes nothing: no duplicate rows, no second table, no altered column.
    const scopedAgain = await applyScript(pool, readScript("006_version_scoped_dimensions.sql"));
    assert.equal(scopedAgain.ok, true, scopedAgain.error?.message);
    assert.equal(scopedAgain.recordset[0].version_dimension_value_rows, 2, "re-application inserts nothing");
    const scopedTables = await pool.request().query("SELECT COUNT(*) AS n FROM sys.tables WHERE schema_id = SCHEMA_ID('icf')");
    // icf.instrument_dimension_value, plus icf.schema_migration_state -- the durable record that
    // says the one-time legacy membership backfill has already happened, so a re-application never
    // infers membership again.
    assert.equal(scopedTables.recordset[0].n, 24, "006 adds exactly two tables");
    assert.equal(scopedAgain.recordset[0].legacy_membership_backfill_ran_now, 0, "and the second apply did not run the backfill");
    assert.equal(scoped.recordset[0].legacy_membership_backfill_ran_now, 1, "while the first apply did");
    assert.equal(scopedAgain.recordset[0].legacy_membership_backfill_state, "COMPLETED");

    // THE CORRECTION, at the schema level: a value that appears globally AFTER the transition is
    // never inferred into an existing version, whatever that version's status. This is the exact
    // shape of the defect -- V2 mints a new value under a shared dimension, and a re-applied 006
    // used to add it to published V1, changing V1's definitions and the walk values it accepts
    // while its snapshot, checksum and row_version stayed put.
    const v1Before = await pool.request().query(`
      SELECT (SELECT COUNT(*) FROM icf.instrument_dimension_value WHERE version_id = '55555555-5555-5555-5555-555555555501') AS members,
             (SELECT CAST(row_version AS bigint) FROM icf.instrument_version WHERE version_id = '55555555-5555-5555-5555-555555555501') AS rv,
             (SELECT checksum_sha256 FROM icf.instrument_version WHERE version_id = '55555555-5555-5555-5555-555555555501') AS ck`);
    await pool.request().batch(`
      INSERT INTO icf.dimension_value (value_id, dimension_id, value_code, label, display_order, active)
        VALUES ('88888888-8888-8888-8888-888888888803', '77777777-7777-7777-7777-777777777701', 'v2only', N'Introduced by a later version', 30, 1);`);
    const afterNewValue = await applyScript(pool, readScript("006_version_scoped_dimensions.sql"));
    assert.equal(afterNewValue.ok, true, afterNewValue.error?.message);
    assert.equal(afterNewValue.recordset[0].legacy_membership_backfill_ran_now, 0, "the backfill is settled and does not run");
    const v1After = await pool.request().query(`
      SELECT (SELECT COUNT(*) FROM icf.instrument_dimension_value WHERE version_id = '55555555-5555-5555-5555-555555555501') AS members,
             (SELECT CAST(row_version AS bigint) FROM icf.instrument_version WHERE version_id = '55555555-5555-5555-5555-555555555501') AS rv,
             (SELECT checksum_sha256 FROM icf.instrument_version WHERE version_id = '55555555-5555-5555-5555-555555555501') AS ck`);
    assert.equal(v1After.recordset[0].members, v1Before.recordset[0].members,
      "a re-application must not infer the later value into the published version");
    assert.equal(v1After.recordset[0].ck, v1Before.recordset[0].ck);
    assert.equal(String(v1After.recordset[0].rv), String(v1Before.recordset[0].rv));
    const inferred = await pool.request().query(`
      SELECT COUNT(*) AS n FROM icf.instrument_dimension_value iv JOIN icf.dimension_value dv ON dv.value_id = iv.value_id
       WHERE iv.version_id = '55555555-5555-5555-5555-555555555501' AND dv.value_code = 'v2only'`);
    assert.equal(inferred.recordset[0].n, 0, "and the published version does not offer it");

    // The publisher invariant is real: a non-DRAFT row with nobody named is now unstorable.
    const unattributed = await applyScript(pool, `INSERT INTO icf.instrument_version (version_id, instrument_id, version_label, status, effective_start, published_at, compiled_snapshot_json, checksum_sha256)
      VALUES ('55555555-5555-5555-5555-555555555502', '44444444-4444-4444-4444-444444444444', 'v2', N'PUBLISHED', SYSUTCDATETIME(), SYSUTCDATETIME(), N'{}', REPLICATE('b', 64));`);
    assert.equal(unattributed.ok, false, "a PUBLISHED row must name its publisher");
    const retiredUnattributed = await applyScript(pool, `INSERT INTO icf.instrument_version (version_id, instrument_id, version_label, status, effective_start, published_at, compiled_snapshot_json, checksum_sha256)
      VALUES ('55555555-5555-5555-5555-555555555503', '44444444-4444-4444-4444-444444444444', 'v3', N'RETIRED', SYSUTCDATETIME(), SYSUTCDATETIME(), N'{}', REPLICATE('c', 64));`);
    assert.equal(retiredUnattributed.ok, false, "and so must a RETIRED one");
    const draftWithout = await applyScript(pool, `INSERT INTO icf.instrument_version (version_id, instrument_id, version_label, status)
      VALUES ('55555555-5555-5555-5555-555555555504', '44444444-4444-4444-4444-444444444444', 'v4', N'DRAFT');`);
    assert.equal(draftWithout.ok, true, "a DRAFT still needs no publisher");

    // A version-scoped value cannot be offered under a dimension it does not belong to, and two
    // values of one version-dimension cannot claim the same position.
    const wrongDimension = await applyScript(pool, `INSERT INTO icf.instrument_dimension_value (version_id, dimension_id, value_id, label, display_order, active)
      VALUES ('55555555-5555-5555-5555-555555555501', '77777777-7777-7777-7777-777777777701', '88888888-8888-8888-8888-8888888888ff', N'Ghost', 30, 1);`);
    assert.equal(wrongDimension.ok, false, "a version value always names a real dimension value identity");
    const duplicateOrder = await applyScript(pool, `UPDATE icf.instrument_dimension_value SET display_order = 10
      WHERE version_id = '55555555-5555-5555-5555-555555555501' AND value_id = '88888888-8888-8888-8888-888888888802';`);
    assert.equal(duplicateOrder.ok, false, "two values of one version-dimension cannot share a position");

    // 006 refuses to invent a publisher: an existing unattributed non-DRAFT row fails it loudly.
    await pool.request().batch(`
      ALTER TABLE icf.instrument_version DROP CONSTRAINT CK_instrument_version_publisher_required;
      INSERT INTO icf.instrument_version (version_id, instrument_id, version_label, status, effective_start, published_at, compiled_snapshot_json, checksum_sha256)
        VALUES ('55555555-5555-5555-5555-555555555505', '44444444-4444-4444-4444-444444444444', 'v5', N'PUBLISHED', SYSUTCDATETIME(), SYSUTCDATETIME(), N'{}', REPLICATE('d', 64));`);
    const refused = await applyScript(pool, readScript("006_version_scoped_dimensions.sql"));
    assert.equal(refused.ok, false, "the patch stops rather than attributing an existing publication");
    assert.match(refused.error.message, /does not invent a publisher/);
    assert.match(refused.error.message, /1 non-DRAFT/, "and says how many rows need a decision");
    const stillNoConstraint = await pool.request().query(
      "SELECT COUNT(*) AS n FROM sys.check_constraints WHERE name = 'CK_instrument_version_publisher_required'");
    assert.equal(stillNoConstraint.recordset[0].n, 0, "and rolls its whole transaction back");
    // Resolving the row lets it apply again, unchanged.
    await pool.request().batch(`UPDATE icf.instrument_version SET published_by_user_id = '22222222-2222-2222-2222-222222222222' WHERE version_id = '55555555-5555-5555-5555-555555555505';`);
    const resolved = await applyScript(pool, readScript("006_version_scoped_dimensions.sql"));
    assert.equal(resolved.ok, true, resolved.error?.message);
    assert.equal(resolved.recordset[0].publisher_required_constraint_present, 1);

    // ---- Correction migration 007: frozen report releases (RPT-03) ---------------------------
    // Additive and idempotent, and the database itself enforces what a release may hold.
    const releases = await applyScript(pool, readScript("007_report_release.sql"));
    assert.equal(releases.ok, true, releases.error?.message);
    assert.equal(releases.recordset[0].report_release_available, 1);
    assert.equal(releases.recordset[0].release_guards_present, 8);
    const releasesAgain = await applyScript(pool, readScript("007_report_release.sql"));
    assert.equal(releasesAgain.ok, true, releasesAgain.error?.message);
    assert.equal(releasesAgain.recordset[0].release_guards_present, 8, "re-applying creates no second trigger");
    const releaseTables = await pool.request().query("SELECT COUNT(*) AS n FROM sys.tables WHERE schema_id = SCHEMA_ID('icf')");
    assert.equal(releaseTables.recordset[0].n, 28, "007 adds exactly four tables");
    const V = "44444444-4444-4444-4444-444444444444";
    const U = "11111111-1111-1111-1111-111111111111";
    const USER = "22222222-2222-2222-2222-222222222222";
    const W = [1, 2, 3, 4, 5, 6, 7].map((n) => `66666666-0000-0000-0000-00000000000${n}`);
    await pool.request().batch(W.map((w) => `INSERT INTO icf.walk (walk_id, version_id, org_unit_id, owner_user_id) VALUES ('${w}', '${V}', '${U}', '${USER}');`).join("\n"));
    const member = (w, r) => `INSERT INTO icf.report_release_walk (walk_id, release_id, version_id, org_unit_id) VALUES ('${w}', '${r}', '${V}', '${U}');`;
    const inOneTransaction = (body) => `SET XACT_ABORT ON; BEGIN TRANSACTION; ${body} COMMIT TRANSACTION;`;
    // A release is written the only way the database accepts: the release, the walks each block
    // counts, the blocks and their cells, all in the one transaction that creates it.
    const R1 = "77777777-0000-0000-0000-000000000001";
    const firstRelease = await applyScript(pool, inOneTransaction(`
      INSERT INTO icf.report_release (release_id, observed_from, observed_to, minimum_walks, released_by_user_id) VALUES ('${R1}', '1930-03-01', '1930-03-31', 3, '${USER}');
      ${member(W[0], R1)} ${member(W[1], R1)} ${member(W[2], R1)}
      INSERT INTO icf.report_release_block (release_id, version_id, org_unit_id, walks) VALUES ('${R1}', '${V}', '${U}', 3);
      INSERT INTO icf.report_release_cell (release_id, version_id, org_unit_id, subject_type, subject_key, category_type, category_code, responses)
      VALUES ('${R1}', '${V}', '${U}', 'ITEM', 'q', 'OPTION', '1', 3);`));
    assert.equal(firstRelease.ok, true, firstRelease.error?.message);
    for (const [from, to, why] of [["1930-03-31", "1930-04-30", "sharing the last day"], ["1930-02-01", "1930-03-01", "sharing the first day"], ["1930-03-10", "1930-03-12", "inside it"], ["1930-01-01", "1930-12-31", "around it"]]) {
      const overlap = await applyScript(pool, `INSERT INTO icf.report_release (release_id, observed_from, observed_to, minimum_walks, released_by_user_id)
        VALUES (NEWID(), '${from}', '${to}', 3, '${USER}');`);
      assert.equal(overlap.ok, false, `a release ${why} is refused`);
      assert.equal(overlap.error?.number, 50062);
    }
    const R2 = "77777777-0000-0000-0000-000000000002";
    const adjacent = await applyScript(pool, `INSERT INTO icf.report_release (release_id, observed_from, observed_to, minimum_walks, released_by_user_id)
      VALUES ('${R2}', '1930-04-01', '1930-04-30', 5, '${USER}');`);
    assert.equal(adjacent.ok, true, "the next day on is a different set of dates");
    const belowFloor = await applyScript(pool, `INSERT INTO icf.report_release (release_id, observed_from, observed_to, minimum_walks, released_by_user_id)
      VALUES (NEWID(), '1931-01-01', '1931-01-02', 2, '${USER}');`);
    assert.equal(belowFloor.ok, false, "no release below the approved minimum of 3");
    const smallBlock = await applyScript(pool, `INSERT INTO icf.report_release_block (release_id, version_id, org_unit_id, walks)
      VALUES ('${R1}', '${V}', '${U}', 2);`);
    assert.equal(smallBlock.ok, false, "no block of fewer than 3 walks");
    // Each case below breaks one rule and satisfies every other, so the refusal is that rule's own.
    const underOwnMinimum = await applyScript(pool, inOneTransaction(`
      INSERT INTO icf.report_release (release_id, observed_from, observed_to, minimum_walks, released_by_user_id) VALUES ('77777777-0000-0000-0000-000000000003', '1930-05-01', '1930-05-31', 5, '${USER}');
      ${member(W[3], "77777777-0000-0000-0000-000000000003")} ${member(W[4], "77777777-0000-0000-0000-000000000003")} ${member(W[5], "77777777-0000-0000-0000-000000000003")} ${member(W[6], "77777777-0000-0000-0000-000000000003")}
      INSERT INTO icf.report_release_block (release_id, version_id, org_unit_id, walks) VALUES ('77777777-0000-0000-0000-000000000003', '${V}', '${U}', 4);`));
    assert.equal(underOwnMinimum.ok, false, "no block below its own release's minimum");
    assert.equal(underOwnMinimum.error?.number, 50063);
    const zeroCell = await applyScript(pool, `INSERT INTO icf.report_release_cell (release_id, version_id, org_unit_id, subject_type, subject_key, category_type, category_code, responses)
      VALUES ('${R1}', '${V}', '${U}', 'ITEM', 'q', 'OPTION', '2', 0);`);
    assert.equal(zeroCell.ok, false, "zero cells are not stored");
    assert.equal(zeroCell.error?.number, 547, "refused by CK_report_release_cell_responses");

    // Membership (P7C-02): a walk is counted by one release at most, and a block counts exactly
    // the walks recorded for it.
    const secondRelease = await applyScript(pool, inOneTransaction(`
      INSERT INTO icf.report_release (release_id, observed_from, observed_to, minimum_walks, released_by_user_id) VALUES ('77777777-0000-0000-0000-000000000004', '1930-06-01', '1930-06-30', 3, '${USER}');
      ${member(W[0], "77777777-0000-0000-0000-000000000004")}`));
    assert.equal(secondRelease.ok, false, "a walk one release counted can never join another");
    assert.equal(secondRelease.error?.number, 2627, "refused by PK_report_release_walk");
    assert.match(secondRelease.error?.message ?? "", /PK_report_release_walk/);
    const unbacked = await applyScript(pool, inOneTransaction(`
      INSERT INTO icf.report_release (release_id, observed_from, observed_to, minimum_walks, released_by_user_id) VALUES ('77777777-0000-0000-0000-000000000005', '1930-07-01', '1930-07-31', 3, '${USER}');
      ${member(W[3], "77777777-0000-0000-0000-000000000005")} ${member(W[4], "77777777-0000-0000-0000-000000000005")} ${member(W[5], "77777777-0000-0000-0000-000000000005")}
      INSERT INTO icf.report_release_block (release_id, version_id, org_unit_id, walks) VALUES ('77777777-0000-0000-0000-000000000005', '${V}', '${U}', 4);`));
    assert.equal(unbacked.ok, false, "a block cannot claim more walks than are recorded for it");
    assert.equal(unbacked.error?.number, 50065);
    const grown = await applyScript(pool, inOneTransaction(`
      INSERT INTO icf.report_release (release_id, observed_from, observed_to, minimum_walks, released_by_user_id) VALUES ('77777777-0000-0000-0000-000000000006', '1930-08-01', '1930-08-31', 3, '${USER}');
      ${member(W[3], "77777777-0000-0000-0000-000000000006")} ${member(W[4], "77777777-0000-0000-0000-000000000006")} ${member(W[5], "77777777-0000-0000-0000-000000000006")}
      INSERT INTO icf.report_release_block (release_id, version_id, org_unit_id, walks) VALUES ('77777777-0000-0000-0000-000000000006', '${V}', '${U}', 3);
      ${member(W[6], "77777777-0000-0000-0000-000000000006")}`));
    assert.equal(grown.ok, false, "a stored block's recorded walks never grow, even in its own transaction");
    assert.equal(grown.error?.number, 50065);
    const shrunk = await applyScript(pool, `DELETE FROM icf.report_release_walk WHERE walk_id = '${W[0]}';`);
    assert.equal(shrunk.ok, false, "and never shrink: a counted walk cannot be freed for another release");
    assert.equal(shrunk.error?.number, 50065);

    // Sealed: nothing is added to a release after the transaction that created it.
    for (const [sqlText, what] of [
      [member(W[3], R2), "a membership row"],
      [`INSERT INTO icf.report_release_block (release_id, version_id, org_unit_id, walks) VALUES ('${R2}', '${V}', '${U}', 5);`, "a block"],
      [`INSERT INTO icf.report_release_cell (release_id, version_id, org_unit_id, subject_type, subject_key, category_type, category_code, responses)
        VALUES ('${R1}', '${V}', '${U}', 'ITEM', 'q', 'OPTION', '2', 1);`, "a cell"]]) {
      const late = await applyScript(pool, inOneTransaction(sqlText));
      assert.equal(late.ok, false, `${what} cannot be added to a release later`);
      assert.equal(late.error?.number, 50066);
    }
    for (const [sqlText, what] of [[`UPDATE icf.report_release SET observed_to = '1930-03-30' WHERE release_id = '${R1}'`, "a release"],
      [`UPDATE icf.report_release_block SET walks = 4 WHERE release_id = '${R1}'`, "a block"],
      [`UPDATE icf.report_release_cell SET responses = 4 WHERE release_id = '${R1}'`, "a cell"],
      [`UPDATE icf.report_release_walk SET org_unit_id = org_unit_id WHERE release_id = '${R1}'`, "a membership row"]]) {
      const changed = await applyScript(pool, sqlText);
      assert.equal(changed.ok, false, `${what} is never updated`);
      assert.equal(changed.error?.number, 50064);
    }
    const counted = await pool.request().query(`SELECT COUNT(*) AS n FROM icf.report_release_walk`);
    assert.equal(counted.recordset[0].n, 3, "only the first release's three walks were ever recorded");
    // What the database does not refuse: removing a whole release in dependency order (the
    // accepted residual, used only by the test-only fixture cleanup).
    const removed = await applyScript(pool, `DELETE FROM icf.report_release_cell WHERE release_id = '${R1}';
      DELETE FROM icf.report_release_block WHERE release_id = '${R1}';
      DELETE FROM icf.report_release_walk WHERE release_id = '${R1}';
      DELETE FROM icf.report_release WHERE release_id = '${R1}';`);
    assert.equal(removed.ok, true, removed.error?.message);
  } finally {
    await pool.close();
    const cleanup = await sql.connect(connectionConfig(env, "master", true));
    await cleanup.request().batch(`ALTER DATABASE [${dbName}] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [${dbName}];`);
    await cleanup.close();
  }
});
