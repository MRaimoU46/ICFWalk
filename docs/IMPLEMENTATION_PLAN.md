# Recommended implementation plan

## Phase 0: verify and lock the baseline

- Run `node scripts/validate-handoff.mjs`.
- Record the source/config/schema hashes.
- Create an acceptance-test tracking file keyed to `docs/ACCEPTANCE_TESTS.md`.
- Confirm the build remains Adobe ColdFusion 2023 plus SQL Server 2016+.

Completion gate: package validation passes and no retired SIP content is present in the active config.

## Phase 1: application and database foundation

- Scaffold the CFML application, configuration loader, environment handling, error model, logging, request correlation, and test harness.
- Apply `001_schema.sql` then `002_alignment_patch.sql` to an empty test database.
- Implement JSON import with logical-ID-to-GUID mapping, validation, idempotent DRAFT behavior, compiled snapshot, and checksum.
- Seed the current aligned DRAFT version.

Completion gate: clean database creation, repeatable seed, referential checks, and no published-version overwrite.

## Phase 2: identity, roles, and organizational scope

- Implement production SSO adapter interface and development-only identity stub.
- Implement role/scope resolution with effective dates and descendants.
- Add centralized server authorization checks and negative tests.

Completion gate: every endpoint has explicit authorization and cross-scope tests fail closed.

## Phase 3: instrument engine and visual shell

- Build compiled-snapshot renderer for sections, dimensions, items, response sets, definitions, notes, and display guidance.
- Recreate My Walks and the walk-editor visual baseline.
- Implement grade filtering, conditional sections, skippable components, keyboard behavior, and accessible status messaging.

Completion gate: a fixture snapshot renders the current form accurately at desktop and mobile widths without hardcoded question content.

## Phase 4: walk persistence and autosave

- Create/list/open/update/void walks.
- Implement typed dimension/response persistence and validation.
- Add 700 ms debounced autosave, idempotency, optimistic concurrency, conflict UX, and retry behavior.
- Add completion validation, revisions, and audit events.

Completion gate: autosave, stale-write, duplicate-retry, hidden-state, and component-clear tests pass without data loss.

## Phase 5: summary and email workflow

- Implement shared server/client summary formatting.
- Implement text export and exact safe filename behavior.
- Implement persisted, editable Part 4 email draft with copy and mailto actions only.

Completion gate: summary golden-file tests and no-automatic-send tests pass.

## Phase 6: instrument administration

- Add DRAFT editing, validation, preview, publish, retire, version compare, immutable published state, and placeholder review queue.
- Use the same renderer for preview and walk entry.

Completion gate: publish transaction produces a verified snapshot/checksum and every published child mutation is rejected.

## Phase 7: aggregate reporting

- Implement scoped filters, distributions, item-level weighted averages, state counts, and exports if authorized.
- Enforce narrative/teacher/email exclusions in the query/service layer and response DTOs.
- Prevent report-only drill-through.

Completion gate: scope, denominator, exclusion, and report-only tests pass.

## Phase 8: hardening and handoff

- Complete injection, XSS, CSRF, session, authorization, concurrency, performance, accessibility, and responsive checks.
- Run every acceptance test and capture evidence.
- Finish setup, deployment, backup/restore, migration, endpoint, and operations documentation.

Completion gate: runnable clean install, complete test evidence, and no unresolved critical/high defects.

