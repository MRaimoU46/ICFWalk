# Database setup and configuration seed

## Run order for a new database

1. Apply `001_schema.sql` to an empty database.
2. Apply `002_alignment_patch.sql`.
3. Apply `003_walk_mutation.sql` (Phase 4 build migration: the append-only walk mutation log that makes create/save/complete/void requests idempotent). Additive and safe to re-run.
4. Apply `004_mutation_fingerprint.sql` (correction migration: `walk_mutation.request_fingerprint`, the SHA-256 of each mutation's canonical semantic request, so the same mutation id cannot replay a different request). Additive, nullable, and safe to re-run.
5. Apply `005_org_unit_dimension_map.sql` (correction migration: `icf.org_unit_dimension_map`, the explicit validated mapping from a SCHOOL org unit to the instrument School dimension value that names it, so a walk at School A can never carry School B's School value). Additive and safe to re-run. It derives nothing on its own: after applying it, deployments whose org-unit codes already equal the instrument's School value codes run `POST /api/maintenance/org-units/align-school-dimension` once, and others declare `schoolValueCode` per SCHOOL unit in the org-unit import. Until a unit is mapped, walks there carry no School value and a submitted one is refused.
6. Apply `006_version_scoped_dimensions.sql` (Phase 6 publish-foundation correction). Additive and safe to re-run. It does three things. First, it makes a published version's dimensions immutable: `icf.dimension_definition` and `icf.dimension_value` become reporting identity only (`dimension_id`, `code`, `value_id`, `value_code`, created once and never updated), while what a version authors moves to version-scoped rows -- new `dimension_*` columns on `icf.instrument_dimension`, and the new `icf.instrument_dimension_value` table. Second, it records its one-time steps in the new `icf.schema_migration_state` table, so a re-application never repeats a data transition (see "The legacy membership backfill is one-time" below). Third, it adds `CK_instrument_version_publisher_required`, so a PUBLISHED or RETIRED row must name its publisher. **It never invents a publisher.** If a non-DRAFT version already has a NULL `published_by_user_id`, the patch fails with error 50053 and the count: deciding who published an existing row is an authorized remediation decision, not a migration's. Resolve those rows (or return them to DRAFT) and re-apply.
7. Run the application's configuration importer against `../config/instrument-config.json`.
8. Validate and preview the resulting DRAFT.
9. Publish it through the application when content owners approve it.

## The legacy membership backfill is one-time

`006` has to answer "which values does this version offer?" for versions that existed before
`icf.instrument_dimension_value` did. Before the transition a version offered, by construction,
every global value of every dimension it placed, so the transition copies exactly that.

**That is a one-time statement about the past, not a rule.** The first form of this patch expressed
it as "insert every global value this version does not already have a row for", and re-evaluated
that on every apply. Once V2 imports a new value under a shared dimension, the value exists
globally and published V1 has no row for it -- so a re-apply *infers* that V1 meant to offer it and
inserts it. V1's normalized definitions and the walk values it accepts change while its snapshot
bytes, its checksum and its `row_version` do not, so nothing downstream can see it:
`WalkRepository.definitionIndex()` caches by the version checksum, which did not move.

Eligibility is therefore tied to the transition itself, recorded in `icf.schema_migration_state`:

| State of the database when 006 runs | What happens | Recorded state |
| --- | --- | --- |
| No `icf.instrument_dimension_value` (fresh, or Phase 5 with data) | Table created; legacy backfill runs once | `COMPLETED` |
| Table exists, no recorded state (the earlier form of 006 already ran) | Adopted; **no** backfill, nothing inserted | `ADOPTED_PRE_STATE` |
| Any recorded state | Schema shape asserted; no membership written | unchanged |
| Table exists, no recorded state, and a placement of a dimension that has values carries no version rows | **Fails with error 50054**; whole transaction rolled back | none |

The last row is deliberate. That shape is either an interrupted earlier transition or a version
that genuinely offers nothing, and a migration cannot tell which. Inventing membership for a
version that may be published is the mistake this correction exists to prevent, so it stops and
asks. (A placement of a dimension with no global values at all -- a TEXT or DATE dimension -- is
not ambiguous and is not counted.)

After the transition, membership is written only by the application, through
`DefinitionRepository.replaceVersionDimensionValues`, under the owning version's row lock and only
while that version is a DRAFT.

### Detecting memberships a re-applied 006 may have inferred

Environments that ran the **earlier** form of 006 more than once may already carry inferred rows.
This patch never deletes them: a row inferred by a backfill is indistinguishable from one an author
intended, so removing them automatically would be the same class of mistake in the other direction.

Run this read-only query to list the candidates. It reports version-scoped values whose row was
created after the version stopped being editable -- which an import cannot produce, because a
published version cannot be written to.

```sql
/* Read-only. Lists version-scoped dimension values that appear to post-date their version's
   publication, which is the signature of a membership a re-applied backfill inferred. */
SELECT  i.[code]                AS instrument_code,
        v.[version_label],
        v.[status],
        v.[published_at],
        d.[code]                AS dimension_code,
        dv.[value_code],
        iv.[label]              AS version_label_for_value,
        iv.[created_at]         AS membership_created_at
FROM    [icf].[instrument_dimension_value] iv
JOIN    [icf].[instrument_version]  v  ON v.[version_id]   = iv.[version_id]
JOIN    [icf].[instrument]          i  ON i.[instrument_id] = v.[instrument_id]
JOIN    [icf].[dimension_value]     dv ON dv.[value_id]    = iv.[value_id]
JOIN    [icf].[dimension_definition] d ON d.[dimension_id] = iv.[dimension_id]
WHERE   v.[status] <> N'DRAFT'
  AND   v.[published_at] IS NOT NULL
  AND   iv.[created_at] > v.[published_at]
ORDER BY i.[code], v.[version_label], d.[code], dv.[value_code];
```

A second, independent signal: a published version whose stored snapshot disagrees with its rows.

```sql
/* Read-only. Published versions whose snapshot's dimensionValues count no longer matches the
   version-scoped rows beside it. A non-zero difference means something changed the rows after
   the snapshot was frozen. */
SELECT  i.[code] AS instrument_code, v.[version_label], v.[status],
        JSON_VALUE(v.[compiled_snapshot_json], '$.counts.dimensionValues') AS snapshot_says,
        (SELECT COUNT(*) FROM [icf].[instrument_dimension_value] iv WHERE iv.[version_id] = v.[version_id]) AS rows_now
FROM    [icf].[instrument_version] v
JOIN    [icf].[instrument] i ON i.[instrument_id] = v.[instrument_id]
WHERE   v.[status] <> N'DRAFT'
  AND   v.[compiled_snapshot_json] IS NOT NULL
  AND   ISJSON(v.[compiled_snapshot_json]) = 1
  AND   TRY_CONVERT(int, JSON_VALUE(v.[compiled_snapshot_json], '$.counts.dimensionValues'))
        <> (SELECT COUNT(*) FROM [icf].[instrument_dimension_value] iv WHERE iv.[version_id] = v.[version_id]);
```

### Reviewed remediation procedure

Do not run this unattended. Each step produces something a person signs off.

1. **Back up** the database. Every later step is reversible only from that backup.
2. **Collect the candidates** with both queries above. An empty result from both means this
   environment was never contaminated and there is nothing to do.
3. **Establish the intended membership for each candidate version** from the version's own frozen
   snapshot, which a backfill never touched:
   ```sql
   SELECT [compiled_snapshot_json] FROM [icf].[instrument_version] WHERE [version_id] = @versionId;
   ```
   The `definitions.dimensionValues` array in that snapshot is what the version was published
   with, and `counts.dimensionValues` is how many there were. Where the snapshot is present and
   valid, it **is** the answer: any version-scoped row whose `(dimension_code, value_code)` is not
   in that array was not part of the published version.
4. **Where the snapshot cannot answer** -- it is absent, unparseable, or itself disagrees with the
   version's other counts -- stop. Intended historical membership cannot be inferred, and an
   authorized decision is required: the instrument owner must state, in writing, which values that
   version offered. Record that decision before touching a row. Do not fall back to "whatever is
   there now" and do not copy another version's membership.
5. **Remove only the rows the signed-off list excludes**, one version at a time, inside a
   transaction, with the count checked before committing:
   ```sql
   BEGIN TRANSACTION;
   DELETE iv
     FROM [icf].[instrument_dimension_value] iv
     JOIN [icf].[dimension_value] dv ON dv.[value_id] = iv.[value_id]
    WHERE iv.[version_id] = @versionId
      AND dv.[value_code] IN (/* the value codes the review excluded, listed explicitly */);
   /* Expect exactly the number the review named. Anything else means the review is stale. */
   SELECT @@ROWCOUNT AS removed;
   -- COMMIT TRANSACTION;  -- only after `removed` matches the reviewed count
   -- ROLLBACK TRANSACTION;
   ```
6. **Re-verify**: re-run both detection queries (expect no rows for that version) and confirm the
   version's snapshot still hashes to its stored checksum:
   ```sql
   SELECT [version_id], [checksum_sha256] FROM [icf].[instrument_version] WHERE [version_id] = @versionId;
   ```
   The checksum must be unchanged -- remediation corrects the rows to agree with the frozen
   snapshot, and never the other way round.
7. **Restart the application** (or otherwise clear its caches). `WalkRepository.definitionIndex()`
   and `SnapshotService` cache by version checksum, which remediation does not move, so a running
   process keeps serving the pre-remediation index until it is restarted.
8. **Record** the decision, the rows removed and the verification output alongside the backup.

Once this patch has been applied in its current form, the state row makes a repeat contamination
impossible, so this procedure is a one-off for environments the earlier form already touched.

## Notes

`001_schema.sql` intentionally refuses to run when the `icf` schema already contains tables. For an existing installation, use reviewed migrations and backups rather than rerunning the creation script.

## Import requirements

The application must implement the import/publish algorithm in `../docs/DATA_CONTRACT.md`.

- Workbook/JSON logical IDs are authoring keys, not SQL GUID literals.
- Import must map/reuse GUIDs by stable unique keys.
- Import must be idempotent for an unchanged DRAFT.
- Import must refuse to replace PUBLISHED or RETIRED versions.
- Exact response-option definitions populate `icf.response_option.definition`.
- Extra presentation/reportability fields are compiled into the version snapshot and applicable `settings_json` columns.
- The importer must create no real users, role assignments, or production walk records.

## Production responsibilities

- Configure the ColdFusion datasource through environment/deployment configuration.
- Use a least-privilege database login.
- Back up before every migration.
- Apply migrations transactionally and record their versions.
- Parameterize every application query with `cfqueryparam`.
- Treat `walk_revision` and `audit_event` as append-only application records.
- Keep published versions and child definitions immutable.

