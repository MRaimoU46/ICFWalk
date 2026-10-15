/*
    ICFWalk several values per visit field (instrument revision 2026-10-14, step 2)
    Target: Microsoft SQL Server 2016 or later

    Purpose
    -------
    The 2026-10-14 prototype turns four visit fields -- Grade level, Content / Subject Area, Program
    and Visit timing -- into checkboxes: one walk can be Grade 7 and Grade 8. A version says so per
    placement (icf.instrument_dimension.settings_json, "multiple": true); every other version, and
    every other field, keeps exactly one value. Until this patch a walk could store one row per
    dimension (PK_walk_dimension_value was (walk_id, dimension_id)).

      * icf.walk_dimension_value gains selection_ordinal (0 for a single value, and 0, 1, 2 ... for
        the values of a field that takes several, in the version's value order), and its key becomes
        (walk_id, dimension_id, selection_ordinal). Every existing row is ordinal 0, so every stored
        walk reads exactly as before.
      * UQ_walk_dimension_value_selected keeps a value from being stored twice for one walk and
        field. SQL Server treats NULLs as equal in a unique constraint, so a typed value (text, date,
        number, boolean: selected_value_id NULL) can still have one row only.
      * CK_walk_dimension_value_ordinal: only a selected list value can take an ordinal above 0.
      * icf.report_release_cell.category_code widens from 100 to 300 characters. A frozen release
        stores a walk's values in such a field as one category: their codes joined by "+" in the
        version's order (docs/DATA_CONTRACT.md, "Releases"), and the longest combination the
        2026-10-14 version allows (every Program) is 145 characters. DefinitionValidator refuses a
        version whose combination could exceed 300. The key it is part of is rebuilt for the wider
        column: 3 x 16 + 2 x 24 + 2 x 100 + 2 x 300 = 896 bytes, under the 900 a clustered key may
        hold. No row of a release changes, and no release guard fires: rebuilding a key updates,
        inserts and deletes nothing.

    Rollback
    --------
    The previous release runs on a database with this patch: it reads and writes ordinal 0 (the
    default) exactly as before. It reads one of the several values of a field that has several, and
    it cannot change such a field: its UPDATE would give every row the same value, which
    UQ_walk_dimension_value_selected refuses, so the save fails and nothing is written. It never
    reads selection_ordinal or the wider column. See docs/OPERATIONS.md.

    This patch is idempotent: each step checks what is already there, and a second application
    changes nothing. It is one batch, which SQL Server compiles before it runs, so the statements that
    name selection_ordinal -- a column the batch itself adds -- run through EXEC.
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;

BEGIN TRY
    BEGIN TRANSACTION;

    IF OBJECT_ID(N'[icf].[walk_dimension_value]', N'U') IS NULL OR OBJECT_ID(N'[icf].[report_release_cell]', N'U') IS NULL
    BEGIN
        ;THROW 50081,
            'The icf schema is incomplete. Apply 001_schema.sql through 007_report_release.sql before this patch.',
            1;
    END;

    -- 1. The ordinal of each of a walk's values in a field.
    IF COL_LENGTH(N'[icf].[walk_dimension_value]', N'selection_ordinal') IS NULL
    BEGIN
        ALTER TABLE [icf].[walk_dimension_value]
            ADD [selection_ordinal] tinyint NOT NULL
                CONSTRAINT [DF_walk_dimension_value_selection_ordinal] DEFAULT (0);
    END;

    -- 2. The key: one row per walk, field and ordinal.
    IF NOT EXISTS (
        SELECT 1
        FROM sys.key_constraints k
        JOIN sys.index_columns ic ON ic.object_id = k.parent_object_id AND ic.index_id = k.unique_index_id
        JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
        WHERE k.parent_object_id = OBJECT_ID(N'[icf].[walk_dimension_value]', N'U')
          AND k.[name] = N'PK_walk_dimension_value'
          AND c.[name] = N'selection_ordinal'
    )
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.key_constraints WHERE [parent_object_id] = OBJECT_ID(N'[icf].[walk_dimension_value]', N'U') AND [name] = N'PK_walk_dimension_value')
            ALTER TABLE [icf].[walk_dimension_value] DROP CONSTRAINT [PK_walk_dimension_value];

        EXEC (N'ALTER TABLE [icf].[walk_dimension_value]
            ADD CONSTRAINT [PK_walk_dimension_value]
                PRIMARY KEY CLUSTERED ([walk_id], [dimension_id], [selection_ordinal]);');
    END;

    -- 3. A value is stored once per walk and field; a typed value has one row.
    IF NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE [parent_object_id] = OBJECT_ID(N'[icf].[walk_dimension_value]', N'U') AND [name] = N'UQ_walk_dimension_value_selected')
    BEGIN
        ALTER TABLE [icf].[walk_dimension_value]
            ADD CONSTRAINT [UQ_walk_dimension_value_selected]
                UNIQUE ([walk_id], [dimension_id], [selected_value_id]);
    END;

    -- 4. Only a selected list value takes an ordinal above 0.
    IF OBJECT_ID(N'[icf].[CK_walk_dimension_value_ordinal]', N'C') IS NULL
    BEGIN
        EXEC (N'ALTER TABLE [icf].[walk_dimension_value]
            ADD CONSTRAINT [CK_walk_dimension_value_ordinal]
                CHECK ([selection_ordinal] = 0 OR [selected_value_id] IS NOT NULL);');
    END;

    -- 5. A release category wide enough for a combination of values.
    IF COL_LENGTH(N'[icf].[report_release_cell]', N'category_code') < 600
    BEGIN
        IF OBJECT_ID(N'[icf].[CK_report_release_cell_category_not_blank]', N'C') IS NOT NULL
            ALTER TABLE [icf].[report_release_cell] DROP CONSTRAINT [CK_report_release_cell_category_not_blank];
        IF EXISTS (SELECT 1 FROM sys.key_constraints WHERE [parent_object_id] = OBJECT_ID(N'[icf].[report_release_cell]', N'U') AND [name] = N'PK_report_release_cell')
            ALTER TABLE [icf].[report_release_cell] DROP CONSTRAINT [PK_report_release_cell];

        ALTER TABLE [icf].[report_release_cell] ALTER COLUMN [category_code] nvarchar(300) NOT NULL;

        ALTER TABLE [icf].[report_release_cell]
            ADD CONSTRAINT [PK_report_release_cell]
                PRIMARY KEY CLUSTERED ([release_id], [version_id], [org_unit_id], [subject_type], [subject_key], [category_type], [category_code]);
        ALTER TABLE [icf].[report_release_cell]
            ADD CONSTRAINT [CK_report_release_cell_category_not_blank]
                CHECK (LEN(LTRIM(RTRIM([category_code]))) > 0);
    END;

    COMMIT TRANSACTION;

    SELECT
        N'ICFWalk multiple dimension values patch applied successfully.' AS [result],
        CASE WHEN COL_LENGTH(N'[icf].[walk_dimension_value]', N'selection_ordinal') IS NOT NULL
              AND EXISTS (SELECT 1 FROM sys.key_constraints WHERE [parent_object_id] = OBJECT_ID(N'[icf].[walk_dimension_value]', N'U') AND [name] = N'UQ_walk_dimension_value_selected')
              AND OBJECT_ID(N'[icf].[CK_walk_dimension_value_ordinal]', N'C') IS NOT NULL
             THEN 1 ELSE 0 END AS [multiple_values_available],
        COL_LENGTH(N'[icf].[report_release_cell]', N'category_code') / 2 AS [release_category_characters];
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;

    THROW;
END CATCH;
