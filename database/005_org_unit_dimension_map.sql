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
      CODE_ALIGNED  -- derived by POST /api/maintenance/org-units/align-school-dimension from an
                       exact org_unit_code = value_code match, validated against the instrument's
                       School dimension at the time it ran. Deriving it once and storing it is not
                       the same as trusting code equality at runtime: the stored row is what the
                       walk path reads, and it is re-validated against the walk's pinned version.

    Nothing is ever derived from display names.

    This patch is additive and idempotent: it creates one table and never modifies existing objects
    or data. Deployments whose org-unit codes already equal the instrument's School value codes run
    the align endpoint once after applying it (see docs/LOCAL_SETUP.md); until they do, walks at
    those units carry no School value and refuse a submitted one.
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
                CHECK (LEN(LTRIM(RTRIM([value_code]))) > 0)
        );
    END;

    COMMIT TRANSACTION;

    SELECT
        N'ICFWalk org-unit dimension mapping patch applied successfully.' AS [result],
        CASE
            WHEN OBJECT_ID(N'[icf].[org_unit_dimension_map]', N'U') IS NOT NULL THEN 1
            ELSE 0
        END AS [org_unit_dimension_map_available],
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
