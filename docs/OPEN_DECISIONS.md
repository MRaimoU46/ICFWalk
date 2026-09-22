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
| Who may change shared instrument metadata (`icf.instrument` name, description, and whether the instrument is in service) | Not the importer. `InstrumentMetadataService.updateMetadata` requires a named `icf.app_user` and audits the change; no route is exposed for it in this pass, so the deployment decides how that operation is reached when the administration UI is built |

Fable should complete the application with these defaults and surface each item in configuration or administration documentation.

