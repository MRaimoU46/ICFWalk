# Build ICFWalk as a production application

You are the lead engineer for a complete production build of ICFWalk. Work autonomously through the entire implementation, verification, and documentation cycle. Do not stop at a mockup, static prototype, architecture memo, or partial scaffold.

## Read these files first, in order

1. `README.md`
2. `docs/SOURCE_ALIGNMENT.md`
3. `docs/PRODUCT_SPEC.md`
4. `docs/DATA_CONTRACT.md`
5. `docs/ACCEPTANCE_TESTS.md`
6. `docs/IMPLEMENTATION_PLAN.md`
7. `docs/OPEN_DECISIONS.md`
8. `config/instrument-config.json`
9. `database/001_schema.sql`
10. `database/002_alignment_patch.sql`
11. `source/current-prototype.html`

Read `reference/legacy-configuration-workbook.xlsx` only if you need historical context. It is not a build source and must never restore its retired School Improvement Plan hierarchy.

## Non-negotiable source precedence

1. The current prototype is authoritative for visible content and interaction behavior.
2. The normalized JSON is authoritative for the current data-driven instrument contract.
3. The SQL scripts are authoritative for persistence, access scope, versioning, responses, revisions, and audit history.
4. The aligned workbook is the business-review view of the JSON.
5. The legacy workbook is historical reference only.

If you find a conflict, follow this precedence, record it in the implementation notes, and keep moving. Do not merge incompatible versions.

## Target platform

- Adobe ColdFusion 2023 application.
- Microsoft SQL Server 2016 or later.
- Standards-based HTML, CSS, and JavaScript for the browser UI.
- Responsive support for desktop, tablet, and phone.
- No production dependence on browser `localStorage` for authoritative records.
- No hardcoded database credentials, signing secrets, identity-provider secrets, or environment URLs.

Use a clear, maintainable CFML architecture with separate request/controller, service, authorization, validation, data-access, and view concerns. You may choose the specific CFML organization, but the delivered repository must run without replacing the required platform with a different backend stack.

## Required build outcome

Build a runnable application that includes all of the following.

### 1. Authentication and authorization

- Create an authentication adapter suitable for district SSO. Keep identity-provider details environment-driven because the provider is not specified.
- Permit a development identity stub only in an explicit development environment. It must be impossible to enable accidentally in production.
- Enforce authorization on the server for every request and mutation.
- Implement the role and organizational-scope model in `database/001_schema.sql`.
- Respect district, school, and global scope, including `include_descendants` and effective dates.
- Keep `MASTER_INSTRUMENT_ADMIN` separate from walk and report access.
- A report-only role must never receive individual walk details, narrative notes, teacher fields, or response-edit endpoints.

### 2. My Walks

- Recreate the current `My walks` experience: newest-updated first, empty state, new walk, open, and delete with confirmation.
- Show grade/content title, school, date, and relative last-updated time as in the prototype.
- Scope lists to the signed-in user and permissions.
- Use soft business states from the schema (`DRAFT`, `COMPLETED`, `VOIDED`). Do not physically delete completed/audited history.

### 3. Data-driven walk editor

- Render the current published instrument version from a compiled configuration snapshot. Do not hardcode current questions in view templates.
- Match the prototype's U-46 visual character, layout, accordion flow, labels, definitions, colors, buttons, responsive behavior, and section order.
- Preserve the current wording exactly from `config/instrument-config.json`.
- Keep all 17 placeholder prompts visibly flagged in instrument administration, but display them as the current prototype does until content owners replace them.
- Support exact response types in the JSON: single choice, long text, display heading/guidance, and the Part 4 email-draft workflow.
- Display rating definitions on demand.
- Treat an unanswered response as missing, never as zero.

### 4. Conditional behavior

- Filter grade options by selected school type exactly as specified in `instrument-config.json`.
- If a school change makes the selected grade invalid, clear the grade and update dependent visibility.
- Show Period only for grades 6–12.
- Show PreK–K Classroom for PreK or K.
- Show Dual Language, MAC / PREP, Ignite, AVID, and ESL sections for their matching class type.
- Show Content-Area Look-Fors only for Music, Art, or CTE.
- Workshop Model and Academic Teaming are skippable. Their applicability defaults to No for a new walk, matching the prototype.
- When applicability changes to No, hide and clear that component's rating responses in the same server transaction, retain its notes, mark the cleared response state appropriately, and exclude it from averages.

### 5. Autosave and concurrency

- Preserve the prototype's 700 ms debounced autosave experience.
- Persist drafts to SQL Server through authenticated endpoints.
- Use `row_version` for optimistic concurrency on every edited aggregate.
- Return a conflict response when a stale write occurs. Do not silently overwrite a newer revision.
- Present a clear conflict-resolution UI that can reload the server version and preserve the user's unsent edits for review.
- Make retries idempotent. Prevent duplicate walks and duplicate response rows.
- Show `Unsaved changes`, `Saving...`, `All changes saved`, and actionable failure status.

### 6. Completion, revisions, and history

- Allow incomplete drafts to save at any time.
- On explicit completion, validate required current-version inputs on the server.
- Pin every walk and response to the instrument version used at creation.
- Treat published instrument versions and their child definitions as immutable.
- Append `walk_revision` records for material post-save changes according to the data contract.
- Append audit events for security- and lifecycle-relevant actions without logging narrative content or secrets.

### 7. Summary export and teacher email draft

- Preserve the prototype's plain-text summary content, section order, unanswered labels, not-applicable wording, component-average calculation, and filename behavior.
- Generate the same summary on the server as well as in the browser so results can be tested and authorized consistently.
- Recreate the Part 4 email-draft composer, selectable part list, editable recipient/subject/body, regenerate, clear, copy, and open-in-email-app actions.
- Nothing is sent automatically. Do not add an outbound mail integration without separate authorization.
- Store draft email workflow state as non-reportable walk data.

### 8. Instrument administration

- Allow authorized administrators to create a DRAFT version, edit definitions, validate references, preview it, publish it, retire it, and compare versions.
- Publishing must compile a canonical snapshot, calculate SHA-256, set effective/published timestamps, and make the version immutable.
- The seed/import path must read `config/instrument-config.json`, map logical authoring IDs to SQL GUIDs, validate every reference, and refuse to overwrite a published version.
- Expose the 17 placeholder items as unresolved content-review issues.
- Do not expose the database-only teacher/classroom fields in the UI unless separately approved.

### 9. Reporting

- Implement aggregate reports for authorized district and school scopes using the reporting indexes in the schema.
- Include useful filters supported by the data: date range, school, grade, content, period, class type, visit timing, instrument version, section/item, and response option.
- Report distributions and correctly weighted numeric averages from answered numeric scores only.
- Never include hidden, unanswered, or not-applicable responses in numeric denominators.
- Exclude narrative notes, email drafts, teacher identifiers, teacher names, teacher emails, and classroom labels from aggregate reports.
- Report-only users may view aggregate results but may not drill into individual walks.
- Do not invent a privacy-suppression threshold. Isolate that policy behind configuration for later approval.

### 10. Security, privacy, and accessibility

- Use `cfqueryparam` for every database input.
- Validate identifiers, version membership, response type, allowed option, visibility, and authorization on the server.
- Encode untrusted output and sanitize any allowed rich content. The current content is plain text.
- Protect state-changing requests against CSRF.
- Use secure session-cookie settings and environment-appropriate transport security.
- Do not place narrative response values, email draft bodies, secrets, or tokens in logs.
- Meet WCAG 2.1 AA behavior: keyboard access, visible focus, programmatic labels, semantic controls, error announcements, contrast, and no color-only meaning.
- Preserve user input on recoverable errors.

### 11. Tests and verification

- Implement unit, integration, authorization, database, and browser-level tests.
- Execute every applicable case in `docs/ACCEPTANCE_TESTS.md`.
- Add fixture data that contains no real staff or student information.
- Verify the current prototype hash and configuration referential integrity with `node scripts/validate-handoff.mjs` before building.
- Test SQL injection, stored/reflected XSS, CSRF, cross-scope access, stale row versions, duplicate retries, and published-version mutation attempts.
- Visually compare the primary walk editor states with `source/current-prototype.html` at desktop and mobile widths.

## Required repository deliverables

- Complete runnable CFML source.
- Environment template with no secrets.
- Database initialization/migration and JSON seed/import tooling.
- Automated tests and commands to run them.
- Local setup and production deployment documentation.
- Architecture and authorization notes.
- API/endpoint documentation.
- Seeded current DRAFT instrument plus a documented publish step.
- A final verification report mapping each acceptance-test ID to evidence and status.

## Working method

1. Run the handoff validator.
2. Produce a short implementation plan tied to the supplied plan and acceptance tests.
3. Build end to end in small, testable vertical slices.
4. Run tests and visual checks throughout; fix root causes rather than suppressing failures.
5. Do not pause for the open decisions listed in `docs/OPEN_DECISIONS.md`. Use the specified safe defaults and configuration seams.
6. Stop only for a true external blocker such as missing ColdFusion/SQL Server access, missing identity-provider credentials, or a required deployment permission. If blocked, finish everything that can be completed locally and report the exact command/configuration needed to continue.

The task is complete only when the application is runnable, the database can be initialized and seeded, current instrument behavior matches the prototype, authorization is enforced, and the acceptance evidence is delivered.

