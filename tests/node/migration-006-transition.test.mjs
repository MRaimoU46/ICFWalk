// Migration 006's one-time legacy membership backfill, at the states a real deployment can be in.
//
// tests/node/db-scripts.test.mjs covers the ordinary path: a clean database, the Phase 5 schema
// with data, and immediate re-application. This file covers the two states that only exist because
// an *earlier form* of 006 is already out in candidate environments, and which decide whether this
// correction is safe to ship:
//
//   ADOPTION   icf.instrument_dimension_value exists but no transition was ever recorded, because
//              the database was migrated by the earlier form. The earlier form created the table
//              and ran its backfill in one transaction, so the table's existence is proof the
//              backfill committed. Such a database is adopted -- recorded as settled, nothing
//              inserted -- because re-running the backfill there is precisely the defect.
//
//   AMBIGUITY  the table exists, nothing was recorded, and some placement of a dimension that has
//              global values carries no version rows at all. That is either an interrupted earlier
//              transition or a version that deliberately offers nothing, and no migration can tell
//              which. It fails with a precondition rather than guessing membership for a version
//              that may be published.
//
// Each case gets its own throwaway database, so nothing here can touch the development one.
import { test } from "node:test";
import assert from "node:assert/strict";
import sql from "mssql";
import { applyScript, connectionConfig, hasDatabaseConfig, loadRuntimeEnv, readScript } from "./helpers.mjs";

const env = loadRuntimeEnv();
const skip = hasDatabaseConfig(env) ? false : "ICFWALK_DB_* not configured";
const PHASE5 = [
  "001_schema.sql", "002_alignment_patch.sql", "003_walk_mutation.sql",
  "004_mutation_fingerprint.sql", "005_org_unit_dimension_map.sql",
];

async function withDatabase(name, fn) {
  const master = await sql.connect(connectionConfig(env, "master", true));
  await master.request().batch(`CREATE DATABASE [${name}]`);
  await master.close();
  const pool = await sql.connect(connectionConfig(env, name, true));
  try {
    for (const script of PHASE5) {
      const r = await applyScript(pool, readScript(script));
      assert.equal(r.ok, true, `${script}: ${r.error?.message}`);
    }
    await fn(pool);
  } finally {
    await pool.close();
    const cleanup = await sql.connect(connectionConfig(env, "master", true));
    await cleanup.request().batch(`ALTER DATABASE [${name}] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [${name}];`);
    await cleanup.close();
  }
}

/** An instrument with one published version placing one list dimension that has two values. */
const FIXTURE = `
INSERT INTO icf.app_user (user_id, identity_subject, display_name, active)
  VALUES ('22222222-2222-2222-2222-2222222222aa', N'mig006-publisher', N'Publisher', 1);
INSERT INTO icf.instrument (instrument_id, code, name) VALUES ('44444444-4444-4444-4444-4444444444aa', 'MIG006T', N'Transition fixture');
INSERT INTO icf.instrument_version (version_id, instrument_id, version_label, status, effective_start, published_at, published_by_user_id, compiled_snapshot_json, checksum_sha256)
  VALUES ('55555555-5555-5555-5555-5555555555aa', '44444444-4444-4444-4444-4444444444aa', 'v1', N'PUBLISHED', SYSUTCDATETIME(), SYSUTCDATETIME(), '22222222-2222-2222-2222-2222222222aa', N'{}', REPLICATE('a', 64));
INSERT INTO icf.section_definition (section_id, version_id, section_key, display_order, title)
  VALUES ('66666666-6666-6666-6666-6666666666aa', '55555555-5555-5555-5555-5555555555aa', 'root', 0, N'Root');
INSERT INTO icf.dimension_definition (dimension_id, code, label, data_type, reportable, sensitive, active)
  VALUES ('77777777-7777-7777-7777-7777777777aa', 'school', N'School', N'LIST', 1, 0, 1);
INSERT INTO icf.dimension_value (value_id, dimension_id, value_code, label, display_order, active)
  VALUES ('88888888-8888-8888-8888-8888888888aa', '77777777-7777-7777-7777-7777777777aa', 'a', N'A', 10, 1),
         ('88888888-8888-8888-8888-8888888888bb', '77777777-7777-7777-7777-7777777777aa', 'b', N'B', 20, 1);
INSERT INTO icf.instrument_dimension (version_id, dimension_id, section_id, display_order, required)
  VALUES ('55555555-5555-5555-5555-5555555555aa', '77777777-7777-7777-7777-7777777777aa', '66666666-6666-6666-6666-6666666666aa', 10, 0);`;

/**
 * Reproduces a database migrated by the EARLIER form of 006: the version-scoped columns and table
 * exist and are backfilled, and no transition state was recorded, because that form had none.
 * Written out here rather than read from git so the test states the shape it is testing.
 */
const EARLIER_FORM = `
ALTER TABLE icf.instrument_dimension
  ADD dimension_label nvarchar(200) NULL, dimension_data_type nvarchar(20) NULL,
      dimension_reportable bit NULL, dimension_sensitive bit NULL, dimension_active bit NULL,
      dimension_settings_json nvarchar(max) NULL;`;

const EARLIER_FORM_BACKFILL = `
UPDATE p SET p.dimension_label = d.label, p.dimension_data_type = d.data_type,
             p.dimension_reportable = d.reportable, p.dimension_sensitive = d.sensitive,
             p.dimension_active = d.active, p.dimension_settings_json = d.settings_json
  FROM icf.instrument_dimension p JOIN icf.dimension_definition d ON d.dimension_id = p.dimension_id;
ALTER TABLE icf.instrument_dimension ALTER COLUMN dimension_label nvarchar(200) NOT NULL;
ALTER TABLE icf.instrument_dimension ALTER COLUMN dimension_data_type nvarchar(20) NOT NULL;
ALTER TABLE icf.instrument_dimension ALTER COLUMN dimension_reportable bit NOT NULL;
ALTER TABLE icf.instrument_dimension ALTER COLUMN dimension_sensitive bit NOT NULL;
ALTER TABLE icf.instrument_dimension ALTER COLUMN dimension_active bit NOT NULL;
CREATE TABLE icf.instrument_dimension_value
(
  version_id uniqueidentifier NOT NULL, dimension_id uniqueidentifier NOT NULL,
  value_id uniqueidentifier NOT NULL, label nvarchar(300) NOT NULL, display_order int NOT NULL,
  effective_start datetime2(3) NULL, effective_end datetime2(3) NULL,
  active bit NOT NULL CONSTRAINT DF_instrument_dimension_value_active DEFAULT (1),
  created_at datetime2(3) NOT NULL CONSTRAINT DF_instrument_dimension_value_created DEFAULT (SYSUTCDATETIME()),
  updated_at datetime2(3) NOT NULL CONSTRAINT DF_instrument_dimension_value_updated DEFAULT (SYSUTCDATETIME()),
  row_version rowversion NOT NULL,
  CONSTRAINT PK_instrument_dimension_value PRIMARY KEY CLUSTERED (version_id, value_id),
  CONSTRAINT FK_instrument_dimension_value_placement FOREIGN KEY (version_id, dimension_id)
    REFERENCES icf.instrument_dimension (version_id, dimension_id),
  CONSTRAINT FK_instrument_dimension_value_identity FOREIGN KEY (value_id, dimension_id)
    REFERENCES icf.dimension_value (value_id, dimension_id),
  CONSTRAINT CK_instrument_dimension_value_order CHECK (display_order >= 0),
  CONSTRAINT CK_instrument_dimension_value_label_not_blank CHECK (LEN(LTRIM(RTRIM(label))) > 0),
  CONSTRAINT CK_instrument_dimension_value_dates CHECK (effective_end IS NULL OR effective_start IS NULL OR effective_end > effective_start)
);
CREATE UNIQUE INDEX UX_instrument_dimension_value_order
  ON icf.instrument_dimension_value (version_id, dimension_id, display_order);
INSERT INTO icf.instrument_dimension_value (version_id, dimension_id, value_id, label, display_order, effective_start, effective_end, active)
SELECT p.version_id, v.dimension_id, v.value_id, v.label, v.display_order, v.effective_start, v.effective_end, v.active
  FROM icf.instrument_dimension p JOIN icf.dimension_value v ON v.dimension_id = p.dimension_id;
ALTER TABLE icf.instrument_version
  ADD CONSTRAINT CK_instrument_version_publisher_required CHECK (status = N'DRAFT' OR published_by_user_id IS NOT NULL);`;

async function seedEarlierForm(pool) {
  await pool.request().batch(FIXTURE);
  await pool.request().batch(EARLIER_FORM);
  await pool.request().batch(EARLIER_FORM_BACKFILL);
}

test(
  "006 on a clean database runs the transition once and records it, and a re-apply is a no-op",
  { skip },
  async () => {
    await withDatabase(`icfwalk_mig006_clean_${Date.now().toString(36)}`, async (pool) => {
      // No instrument data at all: the Phase 5 schema and nothing else.
      const first = await applyScript(pool, readScript("006_version_scoped_dimensions.sql"));
      assert.equal(first.ok, true, first.error?.message);
      assert.equal(first.recordset[0].version_scoped_dimension_columns_available, 1);
      assert.equal(first.recordset[0].instrument_dimension_value_available, 1);
      assert.equal(first.recordset[0].publisher_required_constraint_present, 1);
      assert.equal(first.recordset[0].legacy_membership_backfill_state, "COMPLETED");
      assert.equal(first.recordset[0].legacy_membership_backfill_ran_now, 1, "the transition ran in this apply");
      assert.equal(first.recordset[0].version_dimension_value_rows, 0, "and had nothing to copy");

      const again = await applyScript(pool, readScript("006_version_scoped_dimensions.sql"));
      assert.equal(again.ok, true, again.error?.message);
      assert.equal(again.recordset[0].legacy_membership_backfill_state, "COMPLETED");
      assert.equal(again.recordset[0].legacy_membership_backfill_ran_now, 0, "and never runs again");
      assert.equal(
        (await pool.request().query("SELECT COUNT(*) AS n FROM icf.schema_migration_state")).recordset[0].n,
        1, "one recorded step, not two");
    });
  },
);

test(
  "006 adopts a database the earlier form already migrated, and infers no membership there",
  { skip },
  async () => {
    await withDatabase(`icfwalk_mig006_adopt_${Date.now().toString(36)}`, async (pool) => {
      await seedEarlierForm(pool);
      const before = await pool.request().query("SELECT COUNT(*) AS n FROM icf.instrument_dimension_value");
      assert.equal(before.recordset[0].n, 2, "precondition: the earlier form backfilled both values");
      assert.equal(
        (await pool.request().query("SELECT COUNT(*) AS n FROM sys.tables WHERE schema_id = SCHEMA_ID('icf') AND name = 'schema_migration_state'")).recordset[0].n,
        0, "precondition: the earlier form recorded no transition state");

      // A later version mints a new value globally, exactly as importing V2 would.
      await pool.request().batch(`
        INSERT INTO icf.dimension_value (value_id, dimension_id, value_code, label, display_order, active)
          VALUES ('88888888-8888-8888-8888-8888888888cc', '77777777-7777-7777-7777-7777777777aa', 'v2only', N'V2 only', 30, 1);`);

      const adopted = await applyScript(pool, readScript("006_version_scoped_dimensions.sql"));
      assert.equal(adopted.ok, true, adopted.error?.message);
      assert.equal(adopted.recordset[0].legacy_membership_backfill_state, "ADOPTED_PRE_STATE",
        "the earlier transition is adopted rather than repeated");
      assert.equal(adopted.recordset[0].legacy_membership_backfill_ran_now, 0, "and no backfill ran");

      const after = await pool.request().query("SELECT COUNT(*) AS n FROM icf.instrument_dimension_value");
      assert.equal(after.recordset[0].n, 2, "the published version did not gain the later value");
      const leaked = await pool.request().query(`
        SELECT COUNT(*) AS n FROM icf.instrument_dimension_value iv
          JOIN icf.dimension_value dv ON dv.value_id = iv.value_id WHERE dv.value_code = 'v2only'`);
      assert.equal(leaked.recordset[0].n, 0, "and nothing offers it");

      // A further re-application is a no-op too.
      const again = await applyScript(pool, readScript("006_version_scoped_dimensions.sql"));
      assert.equal(again.ok, true, again.error?.message);
      assert.equal(again.recordset[0].legacy_membership_backfill_ran_now, 0);
      assert.equal((await pool.request().query("SELECT COUNT(*) AS n FROM icf.instrument_dimension_value")).recordset[0].n, 2);
    });
  },
);

test(
  "006 refuses a half-finished transition rather than guessing membership",
  { skip },
  async () => {
    await withDatabase(`icfwalk_mig006_ambig_${Date.now().toString(36)}`, async (pool) => {
      await seedEarlierForm(pool);
      // An interrupted earlier transition: the table exists, nothing was recorded, and this
      // placement has no version rows although its dimension has global values.
      await pool.request().batch("DELETE FROM icf.instrument_dimension_value;");

      const refused = await applyScript(pool, readScript("006_version_scoped_dimensions.sql"));
      assert.equal(refused.ok, false, "the patch stops rather than inventing membership");
      assert.equal(refused.error.number, 50054);
      assert.match(refused.error.message, /no recorded transition state/);
      assert.match(refused.error.message, /will not guess/);
      assert.match(refused.error.message, /1 placement/, "and says how many rows need a decision");

      // It rolled its whole transaction back: no state row, no inferred membership.
      assert.equal(
        (await pool.request().query("SELECT COUNT(*) AS n FROM sys.tables WHERE schema_id = SCHEMA_ID('icf') AND name = 'schema_migration_state'")).recordset[0].n,
        0, "and recorded nothing");
      assert.equal((await pool.request().query("SELECT COUNT(*) AS n FROM icf.instrument_dimension_value")).recordset[0].n, 0);
    });
  },
);

test(
  "a placement of a dimension that has no values at all is not ambiguous",
  { skip },
  async () => {
    await withDatabase(`icfwalk_mig006_novals_${Date.now().toString(36)}`, async (pool) => {
      await pool.request().batch(FIXTURE);
      // A TEXT dimension has no dimension_value rows by nature, so a placement of it legitimately
      // carries no version-scoped values and must not be read as an interrupted transition.
      await pool.request().batch(`
        INSERT INTO icf.dimension_definition (dimension_id, code, label, data_type, reportable, sensitive, active)
          VALUES ('77777777-7777-7777-7777-7777777777bb', 'observer', N'Observer', N'TEXT', 0, 0, 1);
        INSERT INTO icf.instrument_dimension (version_id, dimension_id, section_id, display_order, required)
          VALUES ('55555555-5555-5555-5555-5555555555aa', '77777777-7777-7777-7777-7777777777bb', '66666666-6666-6666-6666-6666666666aa', 20, 0);`);
      await pool.request().batch(EARLIER_FORM);
      await pool.request().batch(EARLIER_FORM_BACKFILL);

      const adopted = await applyScript(pool, readScript("006_version_scoped_dimensions.sql"));
      assert.equal(adopted.ok, true, adopted.error?.message);
      assert.equal(adopted.recordset[0].legacy_membership_backfill_state, "ADOPTED_PRE_STATE");
      assert.equal(adopted.recordset[0].version_dimension_value_rows, 2, "only the list dimension has values");
    });
  },
);
