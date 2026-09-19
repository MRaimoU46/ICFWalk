/*
    ICFWalk org-unit / instrument-dimension mapping (second Phase 0-4 correction)
    Target: Microsoft SQL Server 2016 or later

    Purpose
    -------
    Makes the relationship between a SCHOOL org unit and the instrument's School dimension value an
    explicit, stored, validated fact instead of a runtime string comparison.

    Before this patch the server decided that a School dimension value named a walk's org unit when
    the value's code happened to equal the unit's org_unit_code. That is a coincidence, not an
    identity relationship: in a deployment whose org-unit codes are not the instrument's school
    value codes, no value matched any unit, so a walk authorized at School A could be stored
    carrying School B's School dimension value (or the free-text "Other"), because nothing could
    contradict it.

    icf.org_unit_dimension_map records the mapping one row at a time. A walk at a SCHOOL org unit
    can only ever carry the value its own mapping row names; a SCHOOL unit with no mapping row gets
    no School value at all and any submitted School value is refused (fail closed). The unique
    constraint on (dimension_code, value_code) is what makes "School A cannot carry School B's
    School value" structural rather than procedural: one dimension value belongs to at most one org
    unit.

    source records where a row came from:
      EXPLICIT      -- declared in the org-unit import payload (schoolValueCode)
      CODE_ALIGNED  -- an exact org_unit_code = value_code match that
                       POST /api/maintenance/org-units/align-school-dimension reported as a
                       candidate and an operator then confirmed pair by pair, validated against the
                       instrument's School dimension at the time it ran. Deriving it once and
                       storing it is not the same as trusting code equality at runtime: the stored
                       row is what the walk path reads, and it is re-validated against the walk's
                       pinned version.

    Nothing is ever derived from display names.

    Non-identifying values
    ----------------------
    A dimension that allows free text carries a value whose code is 'other' and whose meaning is
    "none of these, see the typed text". It names no school. Storing it as a unit's identity would
    label that unit's walks "Other" and, because of the unique constraint below, would take a value
    that identifies no school away from every other school. CK_org_unit_dimension_map_identifying
    refuses it in the database, so no application path, script, or hand-written statement can
    create one. A unit with no identifying value stays unmapped, which the walk path handles by
    failing closed.

    This patch is idempotent. It creates the table when absent and, on an installation that already
    has it, adds the identifying-value constraint (removing any non-identifying row first, and
    reporting how many, so an existing deployment converges on the same guarantee rather than
    failing to apply). It changes nothing else.
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;

BEGIN TRY
    BEGIN TRANSACTION;

    IF OBJECT_ID(N'[icf].[org_unit]', N'U') IS NULL
    BEGIN
        ;THROW 50041,
            'The icf.org_unit table does not exist. Apply 001_schema.sql before this patch.',
            1;
    END;

    IF OBJECT_ID(N'[icf].[org_unit_dimension_map]', N'U') IS NULL
    BEGIN
        CREATE TABLE [icf].[org_unit_dimension_map]
        (
            [org_unit_id]     uniqueidentifier NOT NULL,
            [dimension_code]  nvarchar(100) NOT NULL,
            [value_code]      nvarchar(100) NOT NULL,
            [source]          nvarchar(30) NOT NULL,
            [created_at]      datetime2(3) NOT NULL
                CONSTRAINT [DF_org_unit_dimension_map_created] DEFAULT (SYSUTCDATETIME()),
            [updated_at]      datetime2(3) NOT NULL
                CONSTRAINT [DF_org_unit_dimension_map_updated] DEFAULT (SYSUTCDATETIME()),

            /* One value per (unit, dimension): a unit never carries two School values. */
            CONSTRAINT [PK_org_unit_dimension_map]
                PRIMARY KEY CLUSTERED ([org_unit_id], [dimension_code]),
            /* One unit per (dimension, value): School B's value is never available to School A. */
            CONSTRAINT [UQ_org_unit_dimension_map_value]
                UNIQUE ([dimension_code], [value_code]),
            CONSTRAINT [FK_org_unit_dimension_map_org_unit]
                FOREIGN KEY ([org_unit_id])
                REFERENCES [icf].[org_unit] ([org_unit_id]),
            CONSTRAINT [CK_org_unit_dimension_map_source]
                CHECK ([source] IN (N'EXPLICIT', N'CODE_ALIGNED')),
            CONSTRAINT [CK_org_unit_dimension_map_dimension_not_blank]
                CHECK (LEN(LTRIM(RTRIM([dimension_code]))) > 0),
            CONSTRAINT [CK_org_unit_dimension_map_value_not_blank]
                CHECK (LEN(LTRIM(RTRIM([value_code]))) > 0),
            /* A value that names nothing is never an identity (see "Non-identifying values"). */
            CONSTRAINT [CK_org_unit_dimension_map_identifying]
                CHECK (LOWER(LTRIM(RTRIM([value_code]))) <> N'other')
        );
    END;

    DECLARE @removed int = 0;

    /* An installation created before the constraint existed: converge it. */
    IF NOT EXISTS (
        SELECT 1
        FROM sys.check_constraints
        WHERE [name] = N'CK_org_unit_dimension_map_identifying'
          AND [parent_object_id] = OBJECT_ID(N'[icf].[org_unit_dimension_map]', N'U')
    )
    BEGIN
        DELETE FROM [icf].[org_unit_dimension_map]
        WHERE LOWER(LTRIM(RTRIM([value_code]))) = N'other';

        SET @removed = @@ROWCOUNT;

        ALTER TABLE [icf].[org_unit_dimension_map]
            ADD CONSTRAINT [CK_org_unit_dimension_map_identifying]
                CHECK (LOWER(LTRIM(RTRIM([value_code]))) <> N'other');
    END;

    COMMIT TRANSACTION;

    SELECT
        N'ICFWalk org-unit dimension mapping patch applied successfully.' AS [result],
        CASE
            WHEN OBJECT_ID(N'[icf].[org_unit_dimension_map]', N'U') IS NOT NULL THEN 1
            ELSE 0
        END AS [org_unit_dimension_map_available],
        CASE
            WHEN EXISTS (
                SELECT 1
                FROM sys.check_constraints
                WHERE [name] = N'CK_org_unit_dimension_map_identifying'
                  AND [parent_object_id] = OBJECT_ID(N'[icf].[org_unit_dimension_map]', N'U')
            ) THEN 1
            ELSE 0
        END AS [identifying_value_constraint_present],
        @removed AS [non_identifying_rows_removed],
        (
            SELECT COUNT(*)
            FROM [icf].[org_unit_dimension_map]
        ) AS [mapping_rows];
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;

    THROW;
END CATCH;
