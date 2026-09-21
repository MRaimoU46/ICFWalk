/*
    ICFWalk version-scoped dimensions, version-scoped dimension values, and the publisher invariant
    (Phase 6 publish-foundation correction)
    Target: Microsoft SQL Server 2016 or later

    Purpose
    -------
    1. Make a published version's dimensions and dimension values immutable.
    2. Make a publisher mandatory for every version that is not a DRAFT.

    1. Why the dimensions had to move
    ---------------------------------
    icf.dimension_definition and icf.dimension_value are global: one row per dimension code, one row
    per (dimension, value code), shared by every version that places the dimension. The importer
    updated those rows in place, and DefinitionRepository.loadNormalizedDefinitions read them back
    through icf.instrument_dimension. So importing V2 with a renamed dimension, a re-ordered value,
    a relabelled value or a deactivated value silently rewrote what V1's definitions said -- after
    V1 was published, frozen, and already reported on. V1's stored snapshot did not change, so the
    corruption was invisible until something compared the snapshot with the tables and found drift
    in a version nobody had touched.

    The fix keeps the global rows as *reporting identity* and nothing else:

      icf.dimension_definition.dimension_id   the stable id a walk's dimension value points at
      icf.dimension_definition.code           the stable code reporting groups by, across versions
      icf.dimension_value.value_id            the stable id icf.walk_dimension_value stores
      icf.dimension_value.value_code          the stable code reporting groups by, across versions

    Those four are created once, when a code is first seen, and are never updated again. Everything
    a version actually authors -- label, data type, reportability, sensitivity, settings, activity,
    display order, effective window, and which values are in the version at all -- becomes
    version-scoped:

      icf.instrument_dimension.dimension_*         the dimension as *this version* defines it
      icf.instrument_dimension_value               the values *this version* offers, in its order

    A walk conducted under V1 still points at value_id X, and a report can still group V1 and V2
    walks by the code of X, because the identity row is untouched. What V1 called X, and where V1
    put it, now live on V1's own rows, where a V2 import cannot reach them.

    Backfill is exact and non-destructive: every existing instrument_dimension row takes the
    dimension attributes it was already reading, and every existing placement gets one
    instrument_dimension_value row per value of that dimension -- which is precisely the set
    loadNormalizedDefinitions returned for it before this patch. No label, order, publisher or other
    fact is invented, and nothing is deleted. Existing versions therefore read back byte-identically
    and keep their definitions checksums.

    2. Why the publisher had to become mandatory
    --------------------------------------------
    CK_instrument_version_publish_values already refuses a non-DRAFT row missing its snapshot,
    checksum, publication time or effective start. It says nothing about who published it, so a
    PUBLISHED row could carry no publisher at all and the audit trail had no one to name.
    CK_instrument_version_publisher_required closes that.

    This patch never invents a publisher for an existing row. If a non-DRAFT version already has a
    NULL published_by_user_id, the patch fails loudly with the count, because choosing a user to
    attribute an existing publication to is an authorized remediation decision and not a migration's
    to make.

    Idempotence
    -----------
    Every step is guarded by a catalog check, so re-applying the patch is a no-op. Applying it to a
    database at the Phase 5 schema (001..005) performs the backfill; applying it to a database that
    already carries it changes nothing.
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;

BEGIN TRY
    BEGIN TRANSACTION;

    /* ---- preconditions ---------------------------------------------------------------- */

    IF OBJECT_ID(N'[icf].[instrument_version]', N'U') IS NULL
        OR OBJECT_ID(N'[icf].[instrument_dimension]', N'U') IS NULL
        OR OBJECT_ID(N'[icf].[dimension_definition]', N'U') IS NULL
        OR OBJECT_ID(N'[icf].[dimension_value]', N'U') IS NULL
    BEGIN
        ;THROW 50051,
            'The icf instrument tables do not exist. Apply 001_schema.sql through 005_org_unit_dimension_map.sql before this patch.',
            1;
    END;

    /* ---- 1a. version-scoped dimension attributes on icf.instrument_dimension ----------- */

    IF COL_LENGTH(N'[icf].[instrument_dimension]', N'dimension_label') IS NULL
    BEGIN
        EXEC sp_executesql
            N'ALTER TABLE [icf].[instrument_dimension]
                  ADD [dimension_label]         nvarchar(200) NULL,
                      [dimension_data_type]     nvarchar(20) NULL,
                      [dimension_reportable]    bit NULL,
                      [dimension_sensitive]     bit NULL,
                      [dimension_active]        bit NULL,
                      [dimension_settings_json] nvarchar(max) NULL;';
    END;

    /* Backfill exactly what loadNormalizedDefinitions was already reading for these rows. */
    EXEC sp_executesql
        N'UPDATE p
             SET p.[dimension_label]         = d.[label],
                 p.[dimension_data_type]     = d.[data_type],
                 p.[dimension_reportable]    = d.[reportable],
                 p.[dimension_sensitive]     = d.[sensitive],
                 p.[dimension_active]        = d.[active],
                 p.[dimension_settings_json] = d.[settings_json]
            FROM [icf].[instrument_dimension] p
            JOIN [icf].[dimension_definition] d ON d.[dimension_id] = p.[dimension_id]
           WHERE p.[dimension_label] IS NULL
              OR p.[dimension_data_type] IS NULL
              OR p.[dimension_reportable] IS NULL
              OR p.[dimension_sensitive] IS NULL
              OR p.[dimension_active] IS NULL;';

    /* Every placement has a dimension row (FK_instrument_dimension_definition), so the backfill
       above cannot leave a NULL behind. Assert it rather than assume it before tightening. */
    DECLARE @unbackfilled int;

    EXEC sp_executesql
        N'SELECT @n = COUNT(*)
            FROM [icf].[instrument_dimension]
           WHERE [dimension_label] IS NULL
              OR [dimension_data_type] IS NULL
              OR [dimension_reportable] IS NULL
              OR [dimension_sensitive] IS NULL
              OR [dimension_active] IS NULL;',
        N'@n int OUTPUT',
        @n = @unbackfilled OUTPUT;

    IF @unbackfilled > 0
    BEGIN
        DECLARE @backfillMessage nvarchar(400) =
            N'Version-scoped dimension attributes could not be backfilled for '
            + CAST(@unbackfilled AS nvarchar(20))
            + N' icf.instrument_dimension row(s); their dimension definition is missing. Resolve the orphaned placements before applying this patch.';
        ;THROW 50052, @backfillMessage, 1;
    END;

    IF EXISTS (
        SELECT 1 FROM sys.columns
        WHERE [object_id] = OBJECT_ID(N'[icf].[instrument_dimension]', N'U')
          AND [name] = N'dimension_label'
          AND [is_nullable] = 1
    )
    BEGIN
        EXEC sp_executesql
            N'ALTER TABLE [icf].[instrument_dimension] ALTER COLUMN [dimension_label] nvarchar(200) NOT NULL;';
        EXEC sp_executesql
            N'ALTER TABLE [icf].[instrument_dimension] ALTER COLUMN [dimension_data_type] nvarchar(20) NOT NULL;';
        EXEC sp_executesql
            N'ALTER TABLE [icf].[instrument_dimension] ALTER COLUMN [dimension_reportable] bit NOT NULL;';
        EXEC sp_executesql
            N'ALTER TABLE [icf].[instrument_dimension] ALTER COLUMN [dimension_sensitive] bit NOT NULL;';
        EXEC sp_executesql
            N'ALTER TABLE [icf].[instrument_dimension] ALTER COLUMN [dimension_active] bit NOT NULL;';
    END;

    IF NOT EXISTS (
        SELECT 1 FROM sys.check_constraints
        WHERE [name] = N'CK_instrument_dimension_data_type'
          AND [parent_object_id] = OBJECT_ID(N'[icf].[instrument_dimension]', N'U')
    )
    BEGIN
        EXEC sp_executesql
            N'ALTER TABLE [icf].[instrument_dimension]
                  ADD CONSTRAINT [CK_instrument_dimension_data_type]
                      CHECK ([dimension_data_type] IN (N''LIST'', N''TEXT'', N''NUMBER'', N''DATE'', N''BOOLEAN''));';
    END;

    IF NOT EXISTS (
        SELECT 1 FROM sys.check_constraints
        WHERE [name] = N'CK_instrument_dimension_dimension_settings_json'
          AND [parent_object_id] = OBJECT_ID(N'[icf].[instrument_dimension]', N'U')
    )
    BEGIN
        EXEC sp_executesql
            N'ALTER TABLE [icf].[instrument_dimension]
                  ADD CONSTRAINT [CK_instrument_dimension_dimension_settings_json]
                      CHECK ([dimension_settings_json] IS NULL OR ISJSON([dimension_settings_json]) = 1);';
    END;

    /* ---- 1b. version-scoped dimension values ------------------------------------------ */

    IF OBJECT_ID(N'[icf].[instrument_dimension_value]', N'U') IS NULL
    BEGIN
        CREATE TABLE [icf].[instrument_dimension_value]
        (
            [version_id]       uniqueidentifier NOT NULL,
            [dimension_id]     uniqueidentifier NOT NULL,
            /* The stable reporting identity. icf.walk_dimension_value.selected_value_id points here
               and keeps pointing here across every version that offers the value. */
            [value_id]         uniqueidentifier NOT NULL,
            [label]            nvarchar(300) NOT NULL,
            [display_order]    int NOT NULL,
            [effective_start]  datetime2(3) NULL,
            [effective_end]    datetime2(3) NULL,
            [active]           bit NOT NULL
                CONSTRAINT [DF_instrument_dimension_value_active] DEFAULT (1),
            [created_at]       datetime2(3) NOT NULL
                CONSTRAINT [DF_instrument_dimension_value_created] DEFAULT (SYSUTCDATETIME()),
            [updated_at]       datetime2(3) NOT NULL
                CONSTRAINT [DF_instrument_dimension_value_updated] DEFAULT (SYSUTCDATETIME()),
            [row_version]      rowversion NOT NULL,

            CONSTRAINT [PK_instrument_dimension_value]
                PRIMARY KEY CLUSTERED ([version_id], [value_id]),
            /* A value row only exists where the version actually places the dimension, and it is
               removed with the placement. */
            CONSTRAINT [FK_instrument_dimension_value_placement]
                FOREIGN KEY ([version_id], [dimension_id])
                REFERENCES [icf].[instrument_dimension] ([version_id], [dimension_id]),
            /* The value must belong to the dimension it is offered under. */
            CONSTRAINT [FK_instrument_dimension_value_identity]
                FOREIGN KEY ([value_id], [dimension_id])
                REFERENCES [icf].[dimension_value] ([value_id], [dimension_id]),
            CONSTRAINT [CK_instrument_dimension_value_order]
                CHECK ([display_order] >= 0),
            CONSTRAINT [CK_instrument_dimension_value_label_not_blank]
                CHECK (LEN(LTRIM(RTRIM([label]))) > 0),
            CONSTRAINT [CK_instrument_dimension_value_dates]
                CHECK ([effective_end] IS NULL OR [effective_start] IS NULL OR [effective_end] > [effective_start])
        );

        CREATE UNIQUE INDEX [UX_instrument_dimension_value_order]
            ON [icf].[instrument_dimension_value] ([version_id], [dimension_id], [display_order]);
    END;

    /* Backfill: the values every existing version was already reading for each placed dimension. */
    EXEC sp_executesql
        N'INSERT INTO [icf].[instrument_dimension_value]
              ([version_id], [dimension_id], [value_id], [label], [display_order], [effective_start], [effective_end], [active])
          SELECT p.[version_id], v.[dimension_id], v.[value_id], v.[label], v.[display_order], v.[effective_start], v.[effective_end], v.[active]
            FROM [icf].[instrument_dimension] p
            JOIN [icf].[dimension_value] v ON v.[dimension_id] = p.[dimension_id]
           WHERE NOT EXISTS (
                     SELECT 1
                       FROM [icf].[instrument_dimension_value] x
                      WHERE x.[version_id] = p.[version_id]
                        AND x.[value_id] = v.[value_id]
                 );';

    /* ---- 2. the publisher invariant ---------------------------------------------------- */

    DECLARE @unattributed int;

    SELECT @unattributed = COUNT(*)
      FROM [icf].[instrument_version]
     WHERE [status] <> N'DRAFT'
       AND [published_by_user_id] IS NULL;

    IF @unattributed > 0
    BEGIN
        DECLARE @publisherMessage nvarchar(500) =
            N'Cannot require a publisher: '
            + CAST(@unattributed AS nvarchar(20))
            + N' non-DRAFT icf.instrument_version row(s) have a NULL published_by_user_id. '
            + N'This patch does not invent a publisher. Decide, under your own authorization, which app_user published each row (or return the row to DRAFT), record it, then re-apply this patch.';
        ;THROW 50053, @publisherMessage, 1;
    END;

    IF NOT EXISTS (
        SELECT 1 FROM sys.check_constraints
        WHERE [name] = N'CK_instrument_version_publisher_required'
          AND [parent_object_id] = OBJECT_ID(N'[icf].[instrument_version]', N'U')
    )
    BEGIN
        EXEC sp_executesql
            N'ALTER TABLE [icf].[instrument_version]
                  ADD CONSTRAINT [CK_instrument_version_publisher_required]
                      CHECK ([status] = N''DRAFT'' OR [published_by_user_id] IS NOT NULL);';
    END;

    COMMIT TRANSACTION;

    SELECT
        N'ICFWalk version-scoped dimension patch applied successfully.' AS [result],
        CASE
            WHEN COL_LENGTH(N'[icf].[instrument_dimension]', N'dimension_label') IS NOT NULL THEN 1
            ELSE 0
        END AS [version_scoped_dimension_columns_available],
        CASE
            WHEN OBJECT_ID(N'[icf].[instrument_dimension_value]', N'U') IS NOT NULL THEN 1
            ELSE 0
        END AS [instrument_dimension_value_available],
        CASE
            WHEN EXISTS (
                SELECT 1
                FROM sys.check_constraints
                WHERE [name] = N'CK_instrument_version_publisher_required'
                  AND [parent_object_id] = OBJECT_ID(N'[icf].[instrument_version]', N'U')
            ) THEN 1
            ELSE 0
        END AS [publisher_required_constraint_present],
        (SELECT COUNT(*) FROM [icf].[instrument_dimension]) AS [version_dimension_rows],
        (SELECT COUNT(*) FROM [icf].[instrument_dimension_value]) AS [version_dimension_value_rows];
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;

    THROW;
END CATCH;
