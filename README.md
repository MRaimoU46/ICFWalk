# ICFWalk full-build handoff

This package is ready to give to Claude Fable for a production build of ICFWalk. It realigns the configuration to the attached current prototype instead of the older workbook baseline.

## Start here

1. Upload or unpack this entire folder in the Fable working environment.
2. Paste the complete contents of `CLAUDE_FABLE_MASTER_PROMPT.md` as the build instruction.
3. Let Fable read the package in the order specified in that prompt.
4. Require the tests in `docs/ACCEPTANCE_TESTS.md` to pass before accepting the build.

## Source priority

| Priority | File | Authority |
| --- | --- | --- |
| 1 | `source/current-prototype.html` | Current visible wording, ordering, controls, defaults, conditional behavior, summary export, and email-draft experience |
| 2 | `config/instrument-config.json` | Normalized, machine-readable contract extracted from the current prototype |
| 3 | `database/001_schema.sql` and `database/002_alignment_patch.sql` | SQL Server persistence, security scope, versioning, responses, revisions, and audit history |
| 4 | `config/ICFWalk_Instrument_Configuration_Aligned.xlsx` | Human-editable review view of the normalized current configuration |
| Reference only | `reference/legacy-configuration-workbook.xlsx` | Historical baseline; never seed or rebuild the retired SIP hierarchy from this file |

When two files disagree, follow this order and record the conflict. Do not blend the old and current instrument versions.

## What was realigned

- The current prototype SHA-256 is `239531267fa1dfaedaf4e1a8842156bc90db425893781330470312e3c34a1361`.
- The older workbook points to a different HTML hash: `8c6c5b4add59b8858232d8b3fd4108668324c24817ebb0853f464deedef87cc3`.
- Part 3 is now `Conditions for Learning`, not the legacy School Improvement Plan hierarchy.
- Part 1 is now `Target / Taxonomy / Pacing`, including Adopted Curriculum and Target/Task Alignment.
- Part 2 contains seven two-question components. Workshop Model and Academic Teaming are skippable and default to not applicable until selected.
- ESL and content-area conditional sections are included.
- The current prototype contains 17 intentional placeholder questions. They remain flagged for content-owner review and are not silently rewritten.

The normalized baseline contains 23 sections, 144 items (including display guidance and notes), 29 response sets, 138 response options, 12 conditional rules, 10 dimensions, and 95 controlled dimension values.

## Package contents

- `CLAUDE_FABLE_MASTER_PROMPT.md` — the complete autonomous build instruction.
- `docs/PRODUCT_SPEC.md` — users, flows, behavior, and nonfunctional requirements.
- `docs/SOURCE_ALIGNMENT.md` — exact reconciliation decisions and retired content.
- `docs/DATA_CONTRACT.md` — JSON-to-SQL mapping, versioning, autosave, and reporting rules.
- `docs/ACCEPTANCE_TESTS.md` — executable acceptance criteria.
- `docs/IMPLEMENTATION_PLAN.md` — recommended build sequence and completion gates.
- `docs/OPEN_DECISIONS.md` — decisions that must remain configurable rather than guessed.
- `config/instrument-config.json` — canonical normalized instrument seed.
- `config/ICFWalk_Instrument_Configuration_Aligned.xlsx` — aligned review workbook.
- `database/001_schema.sql` — supplied non-destructive database creation script.
- `database/002_alignment_patch.sql` — additive compatibility patch for exact response-option definitions.
- `database/README.md` — database initialization and seed requirements.
- `source/current-prototype.html` — exact UI and content baseline.
- `scripts/validate-handoff.mjs` — package and referential-integrity check.
- `reference/legacy-configuration-workbook.xlsx` — historical reference only.

Do not place production credentials, real walk records, student data, or staff narrative notes into an AI project context or source-control repository.

