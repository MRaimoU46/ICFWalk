# Database setup and configuration seed

## Run order for a new database

1. Apply `001_schema.sql` to an empty database.
2. Apply `002_alignment_patch.sql`.
3. Apply `003_walk_mutation.sql` (Phase 4 build migration: the append-only walk mutation log that makes create/save/complete/void requests idempotent). Additive and safe to re-run.
4. Apply `004_mutation_fingerprint.sql` (correction migration: `walk_mutation.request_fingerprint`, the SHA-256 of each mutation's canonical semantic request, so the same mutation id cannot replay a different request). Additive, nullable, and safe to re-run.
4. Run the application's configuration importer against `../config/instrument-config.json`.
5. Validate and preview the resulting DRAFT.
6. Publish it through the application when content owners approve it.

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

