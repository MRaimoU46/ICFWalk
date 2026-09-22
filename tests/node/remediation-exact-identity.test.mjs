// The reviewed remediation procedure in database/README.md, executed against a real SQL Server.
//
// THE DEFECT THIS EXISTS FOR. The sample in that document removed version membership with
//
//     DELETE iv FROM icf.instrument_dimension_value iv
//       JOIN icf.dimension_value dv ON dv.value_id = iv.value_id
//      WHERE iv.version_id = @versionId AND dv.value_code IN (/* the codes the review excluded */);
//
// icf.dimension_value.value_code is unique only WITHIN a dimension, and the supplied instrument
// uses the code `other` under `school`, `content` and `classType`. An operator who approved the
// removal of one (dimension_code, value_code) pair therefore silently removed three -- from a
// PUBLISHED version, whose membership is exactly what the remediation exists to correct. A
// row-count check does not catch it: @@ROWCOUNT is 3 either way.
//
// The corrected procedure resolves each approved pair to an exact (version_id, dimension_id,
// value_id) triple, refuses anything missing or ambiguous, captures what it really deleted with
// OUTPUT, and compares the deleted set with the approved set in both directions before it can
// commit. Rollback is the default.
//
// THIS TEST RUNS THE DOCUMENT. The SQL is extracted from database/README.md rather than copied
// here, so the procedure an operator would run is the procedure that is proved, and the two
// cannot drift apart. Only the three places the document marks REPLACE are substituted.
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import sql from "mssql";
import { applyScript, connectionConfig, hasDatabaseConfig, loadRuntimeEnv, readScript, root } from "./helpers.mjs";

const env = loadRuntimeEnv();
const available = hasDatabaseConfig(env);
const dbName = `icfwalk_remediation_${Date.now().toString(36)}`;

const VERSION_ID = "66666666-6666-6666-6666-666666666601";
const DIMENSIONS = [
  { code: "school", id: "66666666-6666-6666-6666-6666666611dd", order: 1 },
  { code: "content", id: "66666666-6666-6666-6666-6666666612dd", order: 2 },
  { code: "classType", id: "66666666-6666-6666-6666-6666666613dd", order: 3 },
];
// Every dimension carries the SAME value code. That is the whole point.
const SHARED_VALUE_CODE = "other";

/** The remediation SQL as database/README.md publishes it. */
function remediationTemplate() {
  const readme = fs.readFileSync(path.join(root, "database", "README.md"), "utf8");
  const blocks = [...readme.matchAll(/```sql\n([\s\S]*?)```/g)].map((m) => m[1]);
  const found = blocks.filter((b) => b.includes("ICFWalk exact-identity membership remediation"));
  assert.equal(found.length, 1, "database/README.md publishes exactly one exact-identity remediation block");
  const body = found[0].replace(/^ {3}/gm, "");
  // The three marked substitution points must still be there, or this test is running something
  // other than the documented procedure.
  assert.match(body, /DECLARE @versionId uniqueidentifier = N'00000000-0000-0000-0000-000000000000';/);
  assert.match(body, /DECLARE @signedOff bit = 0;/);
  assert.match(body, /\(N'REPLACE_DIMENSION_CODE', N'REPLACE_VALUE_CODE'\)/);
  // And the properties the correction is about.
  assert.match(body, /OUTPUT deleted\.\[dimension_id\], deleted\.\[value_id\] INTO @deleted/, "it captures deleted identities with OUTPUT");
  assert.match(body, /EXCEPT/, "it compares the deleted set with the approved set");
  assert.match(body, /THROW 50060/, "it refuses unresolved or ambiguous pairs");
  assert.match(body, /THROW 50061/, "and refuses a deleted set that is not the approved set");
  assert.doesNotMatch(body, /dv\.\[?value_code\]? IN \(/, "and never keys the delete on value_code alone");
  return body;
}

/** The documented procedure, with the marked places filled in. */
function remediation(pairs, { signedOff = false, versionId = VERSION_ID } = {}) {
  const values = pairs.map(([d, v]) => `    (N'${d}', N'${v}')`).join(",\n");
  return remediationTemplate()
    .replace("N'00000000-0000-0000-0000-000000000000'", `N'${versionId}'`)
    .replace("DECLARE @signedOff bit = 0;", `DECLARE @signedOff bit = ${signedOff ? 1 : 0};`)
    .replace("    (N'REPLACE_DIMENSION_CODE', N'REPLACE_VALUE_CODE');", `${values};`);
}

/** The pre-correction sample, kept here only to demonstrate what it did. Never run on real data. */
const NAIVE_REMEDIATION = `
BEGIN TRANSACTION;
DELETE iv
  FROM [icf].[instrument_dimension_value] iv
  JOIN [icf].[dimension_value] dv ON dv.[value_id] = iv.[value_id]
 WHERE iv.[version_id] = N'${VERSION_ID}'
   AND dv.[value_code] IN (N'${SHARED_VALUE_CODE}');
SELECT @@ROWCOUNT AS removed;
ROLLBACK TRANSACTION;`;

const FIXTURE = `
INSERT INTO icf.app_user (user_id, identity_subject, display_name)
VALUES ('66666666-6666-6666-6666-6666666600aa', 'remediation-publisher', 'Remediation publisher');

INSERT INTO icf.instrument (instrument_id, code, name, active)
VALUES ('66666666-6666-6666-6666-66666666001f', 'REMEDIATION', 'Remediation fixture', 1);

INSERT INTO icf.instrument_version
  (version_id, instrument_id, version_label, status, effective_start, published_at, published_by_user_id, compiled_snapshot_json, checksum_sha256)
VALUES
  ('${VERSION_ID}', '66666666-6666-6666-6666-66666666001f', 'v1', 'PUBLISHED', SYSUTCDATETIME(), SYSUTCDATETIME(),
   '66666666-6666-6666-6666-6666666600aa', '{"snapshotFormat":"icfwalk.snapshot.v1"}', REPLICATE('a', 64));

${DIMENSIONS.map((d) => `
INSERT INTO icf.dimension_definition (dimension_id, code, label, data_type, reportable, sensitive, active)
VALUES ('${d.id}', '${d.code}', '${d.code} label', 'LIST', 1, 0, 1);

INSERT INTO icf.dimension_value (value_id, dimension_id, value_code, label, display_order, active)
VALUES ('${d.id.slice(0, -2)}01', '${d.id}', '${SHARED_VALUE_CODE}', 'Other', 1, 1),
       ('${d.id.slice(0, -2)}02', '${d.id}', 'kept_${d.code}', 'Kept', 2, 1);

INSERT INTO icf.instrument_dimension
  (version_id, dimension_id, display_order, required, dimension_label, dimension_data_type, dimension_reportable, dimension_sensitive, dimension_active)
VALUES ('${VERSION_ID}', '${d.id}', ${d.order}, 0, '${d.code} label', 'LIST', 1, 0, 1);

INSERT INTO icf.instrument_dimension_value (version_id, dimension_id, value_id, label, display_order, active)
VALUES ('${VERSION_ID}', '${d.id}', '${d.id.slice(0, -2)}01', 'Other', 1, 1),
       ('${VERSION_ID}', '${d.id}', '${d.id.slice(0, -2)}02', 'Kept', 2, 1);`).join("\n")}
`;

test(
  "the documented remediation removes only the approved (dimension_code, value_code) pair",
  { skip: available ? false : "ICFWALK_DB_* not configured" },
  async (t) => {
    const master = await sql.connect(connectionConfig(env, "master", true));
    await master.request().batch(`CREATE DATABASE [${dbName}]`);
    await master.close();
    const pool = await sql.connect(connectionConfig(env, dbName, true));

    const membership = async () => {
      const r = await pool.request().query(`
        SELECT d.code AS dimension_code, dv.value_code
        FROM icf.instrument_dimension_value iv
        JOIN icf.dimension_definition d ON d.dimension_id = iv.dimension_id
        JOIN icf.dimension_value dv ON dv.value_id = iv.value_id
        WHERE iv.version_id = '${VERSION_ID}'
        ORDER BY d.code, dv.value_code`);
      return r.recordset.map((x) => `${x.dimension_code}/${x.value_code}`);
    };
    const checksum = async () =>
      (await pool.request().query(`SELECT checksum_sha256 AS c FROM icf.instrument_version WHERE version_id = '${VERSION_ID}'`))
        .recordset[0].c;

    try {
      for (const name of ["001_schema.sql", "002_alignment_patch.sql", "003_walk_mutation.sql", "004_mutation_fingerprint.sql", "005_org_unit_dimension_map.sql", "006_version_scoped_dimensions.sql"]) {
        const r = await applyScript(pool, readScript(name));
        assert.equal(r.ok, true, `${name}: ${r.error?.message}`);
      }
      // The supplied 001 seeds its own ICFWALK instrument; the fixture is a separate one.
      await pool.request().batch(FIXTURE);

      const before = await membership();
      const checksumBefore = await checksum();
      assert.deepEqual(before, [
        "classType/kept_classType", "classType/other",
        "content/kept_content", "content/other",
        "school/kept_school", "school/other",
      ], "the fixture reproduces one repeated value code under three dimensions");

      // 1. The defect, demonstrated: the pre-correction sample removes all three `other` rows for
      //    one approved pair, and its row count reports 3 as if that were expected.
      const naive = await applyScript(pool, NAIVE_REMEDIATION);
      assert.equal(naive.ok, true, naive.error?.message);
      assert.equal(Number(naive.recordset[0].removed), 3, "the value_code-only delete reaches all three dimensions");
      assert.deepEqual(await membership(), before, "(rolled back, so the fixture is intact for the real procedure)");

      // 2. Rollback is the default: the documented procedure changes nothing until signed off.
      const dryRun = await applyScript(pool, remediation([["school", SHARED_VALUE_CODE]]));
      assert.equal(dryRun.ok, true, dryRun.error?.message);
      assert.deepEqual(await membership(), before, "an un-signed-off run rolls back and removes nothing");

      // 3. Signed off: exactly the approved pair goes, and the other two `other` rows stay.
      const applied = await applyScript(pool, remediation([["school", SHARED_VALUE_CODE]], { signedOff: true }));
      assert.equal(applied.ok, true, applied.error?.message);
      assert.deepEqual(await membership(), [
        "classType/kept_classType", "classType/other",
        "content/kept_content", "content/other",
        "school/kept_school",
      ], "only school/other was removed; content/other and classType/other are untouched");

      // 4. The global identity rows are untouched: reporting still resolves every historical walk.
      const identities = await pool.request().query(
        `SELECT COUNT(*) AS n FROM icf.dimension_value WHERE value_code = '${SHARED_VALUE_CODE}'`);
      assert.equal(Number(identities.recordset[0].n), 3, "all three global `other` identities survive");

      // 5. The frozen snapshot checksum did not move: remediation corrects rows to agree with the
      //    snapshot, never the other way round.
      assert.equal(await checksum(), checksumBefore, "the published version's checksum is unchanged");

      // 6. An approved pair that does not resolve is refused before anything is deleted.
      const unresolved = await applyScript(pool, remediation([["school", "no_such_value"]], { signedOff: true }));
      assert.equal(unresolved.ok, false, "an unresolvable pair is refused");
      assert.equal(unresolved.error.number, 50060);
      assert.deepEqual(await membership(), [
        "classType/kept_classType", "classType/other",
        "content/kept_content", "content/other",
        "school/kept_school",
      ], "and nothing else was removed");

      // 7. A pair naming a dimension the version does not place is refused too, rather than
      //    matching the same value code under a dimension that was never approved.
      const wrongDimension = await applyScript(pool, remediation([["nosuchdimension", SHARED_VALUE_CODE]], { signedOff: true }));
      assert.equal(wrongDimension.ok, false);
      assert.equal(wrongDimension.error.number, 50060);

      // 8. A repeated pair in the signed-off list fails on the list's own primary key rather than
      //    being deduplicated silently.
      const repeated = await applyScript(pool, remediation([["content", SHARED_VALUE_CODE], ["content", SHARED_VALUE_CODE]], { signedOff: true }));
      assert.equal(repeated.ok, false, "a duplicated approval is refused");
      assert.equal(Number(repeated.error.number), 2627, `expected a primary key violation, got ${repeated.error.number}: ${repeated.error.message}`);

      t.diagnostic(`remediation verified on ${dbName}`);
    } finally {
      await pool.close();
      const drop = await sql.connect(connectionConfig(env, "master", true));
      await drop.request().batch(`ALTER DATABASE [${dbName}] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [${dbName}];`);
      await drop.close();
    }
  },
);
