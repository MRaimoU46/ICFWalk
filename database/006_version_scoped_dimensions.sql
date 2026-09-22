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

    2. The legacy membership backfill is a ONE-TIME schema transition
    -----------------------------------------------------------------
    This is the correction to the first form of this patch, and it matters more than it looks.

    That form backfilled icf.instrument_dimension_value with "every global value of every placed
    dimension that this version does not already have a row for". As a description of the schema
    transition that is exactly right: before the transition a version offered, by construction, all
    of its dimension's global values, so copying them in reproduces what loadNormalizedDefinitions
    was already returning.

    As a condition to re-evaluate on every apply it is wrong, and dangerously so. Once V2 imports a
    new value under a shared dimension, that value exists globally and published V1 has no row for
    it -- so a re-apply *infers* that V1 must have meant to offer it, and inserts it. V1's
    normalized definitions and the walk values it accepts then change, while its snapshot bytes,
    its checksum and its row_version do not. Nothing downstream can see it: WalkRepository
    .definitionIndex() caches by the version checksum, which did not move, so even a running
    application keeps serving the old index until it restarts and then silently serves a different
    one.

    So eligibility is now tied to the transition itself, recorded durably in
    icf.schema_migration_state, and never to what is currently missing:

      - A database that has never carried icf.instrument_dimension_value is mid-transition: the
        table is created, the legacy backfill runs once, and the step is recorded COMPLETED.
      - A database that already carries the table has already been through the transition. The step
        is recorded COMPLETED without running any backfill (see "Adoption" below).
      - Once the step is COMPLETED the backfill never runs again, for any version, in any status.
        A re-apply is pure DDL idempotence: it asserts the shape and changes no membership.

    Membership after the transition is written only by the application, through
    DefinitionRepository.replaceVersionDimensionValues, under the owning version's row lock and only
    while that version is a DRAFT.

    Adoption of a database where the earlier form of 006 already ran
    ----------------------------------------------------------------
    The earlier form created icf.instrument_dimension_value and ran its backfill inside this same
    transaction, so the table's existence is proof the backfill committed. Such a database is
    adopted: the step is recorded COMPLETED, with state 'ADOPTED_PRE_STATE', and nothing is
    inserted. That is the only safe reading -- re-running the backfill there is precisely the defect
    being corrected.

    Adoption cannot tell whether an earlier re-apply already contaminated a published version,
    because a contaminated row is indistinguishable from an authored one. It therefore never
    deletes anything. Use the read-only detection query in database/README.md ("Detecting
    memberships a re-applied 006 may have inferred") and the reviewed remediation procedure beside
    it; where intended historical membership cannot be inferred, that procedure requires an
    authorized decision rather than a guess.

    Conservative on ambiguity
    -------------------------
    A database whose transition looks half-finished is refused rather than guessed at. If the table
    exists, the step has never been recorded, and some placement of a dimension that has global
    values carries no version rows at all, the patch fails with error 50054 and the count. That
    shape means either an interrupted earlier transition or a version that genuinely offers nothing;
    a migration cannot tell which, and inventing membership for a published version is the mistake
    this correction exists to prevent.

    3. Why the publisher had to become mandatory
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
    Every schema step is guarded by a catalog check and every data step by the recorded migration
    state, so re-applying the patch asserts the shape and changes no row. Applying it to a database
    at the Phase 5 schema (001..005) performs the one-time transition; applying it again, before or
    after any number of later imports and publications, changes nothing.
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

    /* ---- 0. durable migration state ---------------------------------------------------
       The record that says a one-time data transition has already happened. Without it, a data
       step has only the current contents of the database to judge by, and "this row is missing"
       is not the same question as "was this row ever supposed to exist". */

    IF OBJECT_ID(N'[icf].[schema_migration_state]', N'U') IS NULL
    BEGIN
        CREATE TABLE [icf].[schema_migration_state]
        (
            [migration]   nvarchar(100) NOT NULL,
            [step]        nvarchar(100) NOT NULL,
            [state]       nvarchar(40)  NOT NULL,
            [detail]      nvarchar(400) NULL,
            [applied_at]  datetime2(3)  NOT NULL
                CONSTRAINT [DF_schema_migration_state_applied] DEFAULT (SYSUTCDATETIME()),

            CONSTRAINT [PK_schema_migration_state] PRIMARY KEY CLUSTERED ([migration], [step]),
            CONSTRAINT [CK_schema_migration_state_state]
                CHECK ([state] IN (N'COMPLETED', N'ADOPTED_PRE_STATE', N'NOT_REQUIRED'))
        );
    END;

    /* Was the legacy membership backfill already settled, one way or another? */
    DECLARE @backfillSettled bit = 0;

    IF EXISTS (
        SELECT 1 FROM [icf].[schema_migration_state]
        WHERE [migration] = N'006_version_scoped_dimensions'
          AND [step] = N'legacy_membership_backfill'
    )
        SET @backfillSettled = 1;

    /* The table's absence is what identifies a database that has not been through the transition.
       Captured before any DDL below creates it. */
    DECLARE @valueTableExistedBefore bit =
        CASE WHEN OBJECT_ID(N'[icf].[instrument_dimension_value]', N'U') IS NULL THEN 0 ELSE 1 END;

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

    /* Backfill exactly what loadNormalizedDefinitions was already reading for these rows.

       Unlike the membership backfill below, this one cannot invent anything: it is a column-fill
       of attributes for rows that already exist, and it only ever touches a row whose attributes
       are still NULL -- a state the application can no longer produce, because the columns are
       NOT NULL from the end of this patch onwards. It is therefore a no-op on every re-apply by
       construction, and needs no migration-state guard. */
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

    /* ---- 1c. the ONE-TIME legacy membership backfill ----------------------------------- */

    IF @backfillSettled = 0 AND @valueTableExistedBefore = 0
    BEGIN
        /* The transition itself. Before it, a version offered every global value of every
           dimension it placed -- that is what loadNormalizedDefinitions returned -- so copying
           them in reproduces the version exactly. This runs once, in the apply that creates the
           table, and never again. */
        EXEC sp_executesql
            N'INSERT INTO [icf].[instrument_dimension_value]
                  ([version_id], [dimension_id], [value_id], [label], [display_order], [effective_start], [effective_end], [active])
              SELECT p.[version_id], v.[dimension_id], v.[value_id], v.[label], v.[display_order], v.[effective_start], v.[effective_end], v.[active]
                FROM [icf].[instrument_dimension] p
                JOIN [icf].[dimension_value] v ON v.[dimension_id] = p.[dimension_id];';

        INSERT INTO [icf].[schema_migration_state] ([migration], [step], [state], [detail])
        VALUES (
            N'006_version_scoped_dimensions',
            N'legacy_membership_backfill',
            N'COMPLETED',
            N'One-time transition: every placement took the global values of its dimension, which is what loadNormalizedDefinitions returned before this patch.'
        );
    END
    ELSE IF @backfillSettled = 0 AND @valueTableExistedBefore = 1
    BEGIN
        /* Adoption. The table already exists, so an earlier form of this patch created it and,
           in the same transaction, ran its backfill. Refuse instead of adopting if the result
           looks half-finished: a placed dimension that has global values but no version rows at
           all is either an interrupted transition or a version that offers nothing, and no
           migration can tell those apart. */
        DECLARE @emptyPlacements int;

        EXEC sp_executesql
            N'SELECT @n = COUNT(*)
                FROM [icf].[instrument_dimension] p
               WHERE EXISTS (SELECT 1 FROM [icf].[dimension_value] v WHERE v.[dimension_id] = p.[dimension_id])
                 AND NOT EXISTS (
                         SELECT 1 FROM [icf].[instrument_dimension_value] x
                          WHERE x.[version_id] = p.[version_id] AND x.[dimension_id] = p.[dimension_id]
                     );',
            N'@n int OUTPUT',
            @n = @emptyPlacements OUTPUT;

        IF @emptyPlacements > 0
        BEGIN
            DECLARE @ambiguousMessage nvarchar(500) =
                N'icf.instrument_dimension_value exists but this patch has no recorded transition state, and '
                + CAST(@emptyPlacements AS nvarchar(20))
                + N' placement(s) of a dimension that has values carry no version-scoped values at all. '
                + N'That is either an interrupted earlier transition or a version that deliberately offers none, and this patch will not guess. '
                + N'Review them with the detection query in database/README.md, record the intended membership under your own authorization, then re-apply.';
            ;THROW 50054, @ambiguousMessage, 1;
        END;

        INSERT INTO [icf].[schema_migration_state] ([migration], [step], [state], [detail])
        VALUES (
            N'006_version_scoped_dimensions',
            N'legacy_membership_backfill',
            N'ADOPTED_PRE_STATE',
            N'icf.instrument_dimension_value already existed when this form of the patch first ran; the earlier transition is adopted and no membership was inferred.'
        );
    END;

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
        (SELECT [state] FROM [icf].[schema_migration_state]
          WHERE [migration] = N'006_version_scoped_dimensions'
            AND [step] = N'legacy_membership_backfill') AS [legacy_membership_backfill_state],
        CASE WHEN @backfillSettled = 0 AND @valueTableExistedBefore = 0 THEN 1 ELSE 0 END AS [legacy_membership_backfill_ran_now],
        (SELECT COUNT(*) FROM [icf].[instrument_dimension]) AS [version_dimension_rows],
        (SELECT COUNT(*) FROM [icf].[instrument_dimension_value]) AS [version_dimension_value_rows];
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;

    THROW;
END CATCH;
