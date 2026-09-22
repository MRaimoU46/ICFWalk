# Open decisions and safe defaults

These items require district or deployment-owner decisions. They must not block the base build, and the implementation must not guess irreversible answers.

| Decision | Safe build default |
| --- | --- |
| Approved wording for 17 placeholder questions | Preserve and visibly flag the current placeholder prompts; make replacement a new DRAFT version edit |
| Whether teacher identifier, name, email, and classroom label should appear | Keep nullable, hidden, and excluded from aggregate reports |
| Production SSO provider and claims | Implement an adapter and environment mapping; use a development stub only outside production |
| Hosting topology, datasource name, base URL, and secret store | Use environment/config placeholders and deployment documentation; commit no secrets |
| Aggregate privacy-suppression threshold | Implement a configurable policy seam with no invented threshold; never expose individual rows to report-only roles |
| Whether hidden Period values should be cleared | Retain as HIDDEN by default, exclude from reports/export, and document the policy |
| Whether placeholder warnings block instrument publication | Treat as warnings by default; make blocking policy configurable |
| Migration of browser-local prototype records | Do not attempt automatic migration without an approved export/import process; production begins with SQL as authority |
| Automated outbound teacher email | Disabled. Preserve copy and mailto only until separately authorized |
| Whether an environment that ran the earlier form of migration `006` more than once carries dimension-value memberships it never authored | Detect, never auto-correct. `006` now records its one-time transition and can no longer infer membership, but it deletes nothing it may have inferred before. `database/README.md` carries two read-only detection queries and a reviewed remediation procedure; where a version's frozen snapshot cannot establish the intended membership, the instrument owner must state it in writing before any row is removed |
| Who may change shared instrument metadata (`icf.instrument` name, description, and whether the instrument is in service) | Not the importer, and not merely somebody the database has heard of. `InstrumentMetadataService.updateMetadata` takes the **current principal** and asks `AuthorizationService` for global `instrument.manage` before any mutation; the audit actor is that principal's `userId` and no argument can name another. `DefinitionRepository.userExists` remains, as an **integrity** check for the audit foreign key, and is not authorization. No route is exposed for the operation in this pass, so the deployment decides how it is reached when the administration UI is built -- the absence of a route is a scope decision and is not the security control |
| Whether a shared-metadata patch that produces no material difference is an audited operation or a no-op | **A no-op.** The locked read establishes, under the row lock, that every supplied value already equals the stored one exactly -- `name` and `description` case-sensitively, `active` as a boolean, so a capitalization-only edit is a change; the row is then not written, `updated_at` and `row_version` do not move, and no `INSTRUMENT_METADATA_UPDATED` event is recorded. The result carries `noOp: true` and an empty `changedFields`, so the caller is told plainly. An administrative action that changed nothing is not a change, and an audit trail that records it makes the events that did change something harder to find. A patch naming no supported field at all is a different case and is refused (`INSTRUMENT_METADATA_NO_CHANGES`) |

Fable should complete the application with these defaults and surface each item in configuration or administration documentation.

