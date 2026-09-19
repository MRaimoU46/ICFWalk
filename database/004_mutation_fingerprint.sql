/*
    ICFWalk mutation request fingerprint (Phase 0-4 correction)
    Target: Microsoft SQL Server 2016 or later

    Purpose
    -------
    Binds every recorded client mutation id to the canonical semantic request it committed.
    Before this patch a mutation id was bound only to (actor, action, walk), so the same id could
    be replayed for a materially different request and the committed outcome would be returned as
    if it were that request's result. The application now records a SHA-256 fingerprint of the
    canonical semantic request (action, target, and the meaningful body fields; never the
    concurrency token, the mutation id, or the client clock) with each new mutation row, and a
    retry whose fingerprint differs is refused with 409 MUTATION_ID_REUSED.

    The column is nullable so rows written before this patch remain valid and replayable on their
    (actor, action, walk) binding alone; every row written after it carries a fingerprint. This
    patch is additive and idempotent: it never modifies existing objects or data.

    The statements that reference the new column run through sp_executesql because the whole file
    is applied as one batch (the supplied scripts contain no GO separators) and deferred name
    resolution does not cover a column added earlier in the same batch.
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;

BEGIN TRY
    BEGIN TRANSACTION;

    IF OBJECT_ID(N'[icf].[walk_mutation]', N'U') IS NULL
    BEGIN
        ;THROW 50031,
            'The icf.walk_mutation table does not exist. Apply 003_walk_mutation.sql before this patch.',
            1;
    END;

    IF COL_LENGTH(N'[icf].[walk_mutation]', N'request_fingerprint') IS NULL
    BEGIN
        EXEC sp_executesql
            N'ALTER TABLE [icf].[walk_mutation] ADD [request_fingerprint] char(64) NULL;';
    END;

    /* Lower-case hexadecimal SHA-256, or NULL for rows written before this patch. */
    IF NOT EXISTS (
        SELECT 1 FROM sys.check_constraints
        WHERE [name] = N'CK_walk_mutation_fingerprint'
          AND [parent_object_id] = OBJECT_ID(N'[icf].[walk_mutation]', N'U')
    )
    BEGIN
        EXEC sp_executesql
            N'ALTER TABLE [icf].[walk_mutation] WITH NOCHECK
                  ADD CONSTRAINT [CK_walk_mutation_fingerprint]
                      CHECK
                      (
                          [request_fingerprint] IS NULL
                          OR ([request_fingerprint] NOT LIKE ''%[^0-9a-f]%'' AND LEN([request_fingerprint]) = 64)
                      );';
    END;

    IF NOT EXISTS (
        SELECT 1 FROM sys.indexes
        WHERE [name] = N'IX_walk_mutation_actor_action'
          AND [object_id] = OBJECT_ID(N'[icf].[walk_mutation]', N'U')
    )
    BEGIN
        EXEC sp_executesql
            N'CREATE INDEX [IX_walk_mutation_actor_action]
                  ON [icf].[walk_mutation] ([actor_user_id], [action])
                  INCLUDE ([walk_id], [request_fingerprint]);';
    END;

    COMMIT TRANSACTION;

    SELECT
        N'ICFWalk mutation fingerprint patch applied successfully.' AS [result],
        CASE
            WHEN COL_LENGTH(N'[icf].[walk_mutation]', N'request_fingerprint') IS NOT NULL THEN 1
            ELSE 0
        END AS [request_fingerprint_available];
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;

    THROW;
END CATCH;
