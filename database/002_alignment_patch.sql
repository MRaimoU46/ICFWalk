/*
    ICFWalk current-prototype alignment patch
    Target: Microsoft SQL Server 2016 or later

    Purpose
    -------
    Preserve the exact, item-specific response-option definitions present in
    the current prototype and aligned configuration. This patch is additive,
    idempotent, and does not modify existing values.
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;

BEGIN TRY
    BEGIN TRANSACTION;

    IF OBJECT_ID(N'[icf].[response_option]', N'U') IS NULL
    BEGIN
        ;THROW 50020,
            'The icf.response_option table does not exist. Apply 001_schema.sql before this patch.',
            1;
    END;

    IF COL_LENGTH(N'icf.response_option', N'definition') IS NULL
    BEGIN
        ALTER TABLE [icf].[response_option]
            ADD [definition] nvarchar(max) NULL;
    END;

    COMMIT TRANSACTION;

    SELECT
        N'ICFWalk alignment patch applied successfully.' AS [result],
        CASE
            WHEN COL_LENGTH(N'icf.response_option', N'definition') IS NOT NULL THEN 1
            ELSE 0
        END AS [response_option_definition_available];
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;

    THROW;
END CATCH;

