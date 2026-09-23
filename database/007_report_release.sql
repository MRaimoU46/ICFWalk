/*
    ICFWalk frozen report releases (Phase 7 correction, RPT-03)
    Target: Microsoft SQL Server 2016 or later

    Purpose
    -------
    A report-only user must not be able to drill into a walk or infer an individual row from an API
    or an export (RPT-03). A report computed on demand over live walks cannot promise that: two
    requests whose filters differ by one walk, or the same request run before and after one walk is
    completed, differ by exactly that walk, and subtraction returns its answers. The owner-approved
    rule (docs/OPEN_DECISIONS.md, "Aggregate privacy-suppression threshold") therefore gives
    report-only users frozen releases instead of live data:

      * a release covers one closed observation period, and no two releases' periods overlap, so no
        two releases share a walk and none can be subtracted from another;
      * a release is computed once, when it is created, and never changes afterwards, so rerunning a
        report after a walk is completed or edited returns the same figures;
      * within a release, walks are counted in blocks -- one block per (instrument version, org
        unit) -- and a block with fewer walks than the release's minimum is not stored at all, so it
        contributes to nothing, at any level of the organization.

    What is stored is counts keyed by instrument codes: how many walks of a block fell into each
    category of each reportable breakdown. No walk id, owner, narrative, teacher or classroom value
    is stored, and nothing here can be joined back to a walk. Cell suppression (primary and
    complementary) is applied when a release is read, deterministically, from these counts and the
    release's own minimum, so a release reads the same way every time.

    Tables
    ------
      icf.report_release         one row per release: its dates (observed_from..observed_to), the
                                 minimum in force, who released it and when
      icf.report_release_block   one row per (release, version, org unit) block that met the minimum
      icf.report_release_cell    one row per non-zero category of one breakdown in one block

    Guarantees enforced here, not only in the application
    -----------------------------------------------------
      CK_report_release_dates           the last date is on or after the first
      CK_report_release_minimum         the minimum is 3 or more (the approved floor)
      TR_report_release_no_overlap      no two releases cover the same date, whatever wrote the row
      TR_report_release_block_floor     no block below its release's minimum is ever stored
      TR_report_release_immutable       no release, block or cell row is ever updated

    Nothing in the application deletes a release. A deleted release would free its period for a
    second, overlapping release, and the two could then be subtracted; see docs/DATA_CONTRACT.md.

    This patch is idempotent and additive: it creates what is missing and changes nothing else.
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;

BEGIN TRY
    BEGIN TRANSACTION;

    IF OBJECT_ID(N'[icf].[walk]', N'U') IS NULL OR OBJECT_ID(N'[icf].[instrument_version]', N'U') IS NULL
    BEGIN
        ;THROW 50061,
            'The icf schema does not exist. Apply 001_schema.sql through 006_version_scoped_dimensions.sql before this patch.',
            1;
    END;

    IF OBJECT_ID(N'[icf].[report_release]', N'U') IS NULL
    BEGIN
        CREATE TABLE [icf].[report_release]
        (
            [release_id]            uniqueidentifier NOT NULL,
            [observed_from]         date NOT NULL,
            [observed_to]           date NOT NULL,
            [minimum_walks]         int NOT NULL,
            [released_by_user_id]   uniqueidentifier NOT NULL,
            [released_at]           datetime2(3) NOT NULL
                CONSTRAINT [DF_report_release_released_at] DEFAULT (SYSUTCDATETIME()),

            CONSTRAINT [PK_report_release]
                PRIMARY KEY CLUSTERED ([release_id]),
            CONSTRAINT [FK_report_release_released_by]
                FOREIGN KEY ([released_by_user_id])
                REFERENCES [icf].[app_user] ([user_id]),
            CONSTRAINT [CK_report_release_dates]
                CHECK ([observed_to] >= [observed_from]),
            CONSTRAINT [CK_report_release_minimum]
                CHECK ([minimum_walks] >= 3)
        );

        CREATE INDEX [IX_report_release_observed]
            ON [icf].[report_release] ([observed_from], [observed_to]);
    END;

    IF OBJECT_ID(N'[icf].[report_release_block]', N'U') IS NULL
    BEGIN
        CREATE TABLE [icf].[report_release_block]
        (
            [release_id]    uniqueidentifier NOT NULL,
            [version_id]    uniqueidentifier NOT NULL,
            [org_unit_id]   uniqueidentifier NOT NULL,
            [walks]         int NOT NULL,

            CONSTRAINT [PK_report_release_block]
                PRIMARY KEY CLUSTERED ([release_id], [version_id], [org_unit_id]),
            CONSTRAINT [FK_report_release_block_release]
                FOREIGN KEY ([release_id])
                REFERENCES [icf].[report_release] ([release_id]),
            CONSTRAINT [FK_report_release_block_version]
                FOREIGN KEY ([version_id])
                REFERENCES [icf].[instrument_version] ([version_id]),
            CONSTRAINT [FK_report_release_block_org_unit]
                FOREIGN KEY ([org_unit_id])
                REFERENCES [icf].[org_unit] ([org_unit_id]),
            CONSTRAINT [CK_report_release_block_walks]
                CHECK ([walks] >= 3)
        );
    END;

    IF OBJECT_ID(N'[icf].[report_release_cell]', N'U') IS NULL
    BEGIN
        CREATE TABLE [icf].[report_release_cell]
        (
            [release_id]      uniqueidentifier NOT NULL,
            [version_id]      uniqueidentifier NOT NULL,
            [org_unit_id]     uniqueidentifier NOT NULL,
            [subject_type]    nvarchar(12) NOT NULL,
            [subject_key]     nvarchar(100) NOT NULL,
            [category_type]   nvarchar(12) NOT NULL,
            [category_code]   nvarchar(100) NOT NULL,
            [responses]       int NOT NULL,

            CONSTRAINT [PK_report_release_cell]
                PRIMARY KEY CLUSTERED ([release_id], [version_id], [org_unit_id], [subject_type], [subject_key], [category_type], [category_code]),
            CONSTRAINT [FK_report_release_cell_block]
                FOREIGN KEY ([release_id], [version_id], [org_unit_id])
                REFERENCES [icf].[report_release_block] ([release_id], [version_id], [org_unit_id]),
            CONSTRAINT [CK_report_release_cell_subject_type]
                CHECK ([subject_type] IN (N'ITEM', N'DIMENSION')),
            CONSTRAINT [CK_report_release_cell_category_type]
                CHECK ([category_type] IN (N'OPTION', N'VALUE', N'STATE')),
            CONSTRAINT [CK_report_release_cell_responses]
                CHECK ([responses] > 0),
            CONSTRAINT [CK_report_release_cell_subject_not_blank]
                CHECK (LEN(LTRIM(RTRIM([subject_key]))) > 0),
            CONSTRAINT [CK_report_release_cell_category_not_blank]
                CHECK (LEN(LTRIM(RTRIM([category_code]))) > 0)
        );
    END;

    /* CREATE TRIGGER must open its own batch, and SQL Server 2016 RTM cannot replace a trigger in place. */
    IF OBJECT_ID(N'[icf].[TR_report_release_no_overlap]', N'TR') IS NULL
    BEGIN
        EXEC (N'
CREATE TRIGGER [icf].[TR_report_release_no_overlap]
ON [icf].[report_release]
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (
        SELECT 1
        FROM inserted i
        JOIN [icf].[report_release] r
          ON r.[release_id] <> i.[release_id]
         AND r.[observed_from] <= i.[observed_to]
         AND i.[observed_from] <= r.[observed_to]
    )
    BEGIN
        ;THROW 50062, ''A report release must not cover a date another release covers.'', 1;
    END;
END;');
    END;

    IF OBJECT_ID(N'[icf].[TR_report_release_block_floor]', N'TR') IS NULL
    BEGIN
        EXEC (N'
CREATE TRIGGER [icf].[TR_report_release_block_floor]
ON [icf].[report_release_block]
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (
        SELECT 1
        FROM inserted b
        JOIN [icf].[report_release] r ON r.[release_id] = b.[release_id]
        WHERE b.[walks] < r.[minimum_walks]
    )
    BEGIN
        ;THROW 50063, ''A report release block below its release minimum must not be stored.'', 1;
    END;
END;');
    END;

    IF OBJECT_ID(N'[icf].[TR_report_release_immutable]', N'TR') IS NULL
    BEGIN
        EXEC (N'
CREATE TRIGGER [icf].[TR_report_release_immutable]
ON [icf].[report_release]
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM inserted)
    BEGIN
        ;THROW 50064, ''A report release is immutable once created.'', 1;
    END;
END;');
    END;

    IF OBJECT_ID(N'[icf].[TR_report_release_block_immutable]', N'TR') IS NULL
    BEGIN
        EXEC (N'
CREATE TRIGGER [icf].[TR_report_release_block_immutable]
ON [icf].[report_release_block]
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM inserted)
    BEGIN
        ;THROW 50064, ''A report release is immutable once created.'', 1;
    END;
END;');
    END;

    IF OBJECT_ID(N'[icf].[TR_report_release_cell_immutable]', N'TR') IS NULL
    BEGIN
        EXEC (N'
CREATE TRIGGER [icf].[TR_report_release_cell_immutable]
ON [icf].[report_release_cell]
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM inserted)
    BEGIN
        ;THROW 50064, ''A report release is immutable once created.'', 1;
    END;
END;');
    END;

    COMMIT TRANSACTION;

    SELECT
        N'ICFWalk report release patch applied successfully.' AS [result],
        CASE WHEN OBJECT_ID(N'[icf].[report_release]', N'U') IS NOT NULL
              AND OBJECT_ID(N'[icf].[report_release_block]', N'U') IS NOT NULL
              AND OBJECT_ID(N'[icf].[report_release_cell]', N'U') IS NOT NULL THEN 1 ELSE 0 END AS [report_release_available],
        (
            SELECT COUNT(*)
            FROM sys.triggers
            WHERE [parent_id] IN (OBJECT_ID(N'[icf].[report_release]', N'U'), OBJECT_ID(N'[icf].[report_release_block]', N'U'), OBJECT_ID(N'[icf].[report_release_cell]', N'U'))
              AND [name] IN (N'TR_report_release_no_overlap', N'TR_report_release_block_floor', N'TR_report_release_immutable',
                             N'TR_report_release_block_immutable', N'TR_report_release_cell_immutable')
        ) AS [release_guards_present],
        (SELECT COUNT(*) FROM [icf].[report_release]) AS [release_rows];
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;

    THROW;
END CATCH;
