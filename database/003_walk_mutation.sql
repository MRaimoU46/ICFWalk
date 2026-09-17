/*
    ICFWalk walk mutation log (Phase 4)
    Target: Microsoft SQL Server 2016 or later

    Purpose
    -------
    Idempotent walk mutations. Every state-changing walk request (create, save, complete, void)
    carries a client mutation id (GUID). The application records the id with the committed result
    in the same transaction as the change, so a retried request (network failure, application
    restart during autosave) replays the committed outcome instead of duplicating walks,
    response rows, or revisions. This patch is additive and idempotent; it never modifies
    existing objects or data. The table is append-only for the application.
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;

BEGIN TRY
    BEGIN TRANSACTION;

    IF OBJECT_ID(N'[icf].[walk]', N'U') IS NULL
    BEGIN
        ;THROW 50030,
            'The icf.walk table does not exist. Apply 001_schema.sql before this patch.',
            1;
    END;

    IF OBJECT_ID(N'[icf].[walk_mutation]', N'U') IS NULL
    BEGIN
        CREATE TABLE [icf].[walk_mutation]
        (
            [mutation_id]     uniqueidentifier NOT NULL,
            [walk_id]         uniqueidentifier NOT NULL,
            [actor_user_id]   uniqueidentifier NOT NULL,
            [action]          nvarchar(20) NOT NULL,
            [result_json]     nvarchar(max) NOT NULL,
            [created_at]      datetime2(3) NOT NULL
                CONSTRAINT [DF_walk_mutation_created] DEFAULT (SYSUTCDATETIME()),

            CONSTRAINT [PK_walk_mutation]
                PRIMARY KEY CLUSTERED ([mutation_id]),
            CONSTRAINT [FK_walk_mutation_walk]
                FOREIGN KEY ([walk_id]) REFERENCES [icf].[walk] ([walk_id]),
            CONSTRAINT [FK_walk_mutation_actor]
                FOREIGN KEY ([actor_user_id]) REFERENCES [icf].[app_user] ([user_id]),
            CONSTRAINT [CK_walk_mutation_action]
                CHECK ([action] IN (N'CREATE', N'SAVE', N'COMPLETE', N'VOID')),
            CONSTRAINT [CK_walk_mutation_result_json]
                CHECK (ISJSON([result_json]) = 1)
        );

        CREATE INDEX [IX_walk_mutation_walk_created]
            ON [icf].[walk_mutation] ([walk_id], [created_at])
            INCLUDE ([actor_user_id], [action]);
    END;

    COMMIT TRANSACTION;

    SELECT
        N'ICFWalk walk mutation log applied successfully.' AS [result],
        CASE
            WHEN OBJECT_ID(N'[icf].[walk_mutation]', N'U') IS NOT NULL THEN 1
            ELSE 0
        END AS [walk_mutation_available];
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;

    THROW;
END CATCH;
