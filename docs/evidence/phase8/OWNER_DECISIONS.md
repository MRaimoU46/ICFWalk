# Phase 8: decisions and environment the owner must supply

Phase 8 does not guess any of these. Each row says what the build does meanwhile, why the answer
matters, and where it lands once given. Status is **OPEN** until the owner answers in writing; an
answer is recorded here verbatim with its date, as the report-privacy rule was.

## Decisions

| # | Decision | Why it matters | What the build does meanwhile | Lands in | Status |
| --- | --- | --- | --- | --- | --- |
| D1 | **Production SSO**: the gateway or reverse proxy product, the claims it asserts (subject, display name, email) and their header names, the addresses it connects from, whether it sends a shared secret | Identity is asserted per request; the application trusts headers only from listed addresses and refuses to start in production without them | Header adapter with configurable names; development stub outside production only; production refuses an empty trusted-proxy list | `ICFWALK_SSO_*` (`docs/OPERATIONS.md` 3.1, 4.5) | OPEN |
| D2 | **Hosting topology**: IIS or Apache with the ColdFusion connector; one server or several behind a load balancer (sticky sessions); where TLS terminates; the public host name and base URL | Front-door rule, request limits, header stripping and cookie security all live there | Verified on ColdFusion's built-in Tomcat with an equivalent rewrite rule; IIS/Apache untested | `docs/OPERATIONS.md` 1, 4.4, 4.5 | OPEN |
| D3 | **Datasource**: administrator-defined (recommended) or application-defined; driver (ColdFusion's DataDirect `MSSQLServer`, or Microsoft JDBC); SQL Server host, database name, encryption | Long text retrieval must be on; the runtime login must hold data permissions only | Both datasource shapes supported; verified with Microsoft JDBC 12.10 only (DataDirect package unobtainable here) | `ICFWALK_DATASOURCE`, `docs/OPERATIONS.md` 4.1, 4.2 | OPEN |
| D4 | **Secret storage**: where the datasource password, `ICFWALK_SSO_SHARED_SECRET` and the ColdFusion Administrator password live, and how they reach the service | Nothing secret is in source control; the service must read them from somewhere protected | Environment variables or an `ICFWALK_ENV_FILE` readable by the service account only | `docs/OPERATIONS.md` 3.2 | OPEN |
| D5 | **Backups**: schedule, retention, off-server storage, recovery point objective, recovery time objective, drill cadence | Walks are the district's record; restore procedure verified, policy not set | Recommendation only (FULL recovery; nightly full, midday differential, 15-minute log backups; a school year of fulls; a drill each term) | `docs/OPERATIONS.md` 7.1 | OPEN |
| D6 | **Placeholder wording**: approved text for the 17 questions still marked "Placeholder in source" | Walkers see placeholder prompts until replaced | Prompts preserved and flagged; replacement is a DRAFT edit and a publication | A new instrument version (`docs/OPERATIONS.md` 9.4) | OPEN |
| D7 | Whether placeholder warnings **block publication** | A version with placeholders can be published today | `ICFWALK_PLACEHOLDER_WARNINGS_BLOCK_PUBLISH=false` | Configuration | OPEN |
| D8 | **Performance criteria**: response-time and throughput targets, the load they apply to, and the environment they are measured in; and, once set, whether the two walk-table indexes SQL Server suggests are needed (a new migration) | "Performance complete" needs an agreed target; none is invented | A reproducible synthetic workload with its observations on both engines, no pass/fail claimed; the indexes are recommended, not added | `docs/OPERATIONS.md` 12; `docs/evidence/phase8/performance/` | OPEN |
| D9 | **Maintenance operations**: who may enable the maintenance endpoints, when, and how the token is handled | Maintenance provisions users and roles and seeds instruments | Off by default, loopback only, token required, every call audited | `docs/OPERATIONS.md` 10.1 | OPEN |
| D10 | **Teacher fields**: whether teacher identifier, name, email and classroom label appear anywhere | Personal data about staff | Nullable, hidden, excluded from aggregate reports (unchanged from `docs/OPEN_DECISIONS.md`) | `docs/OPEN_DECISIONS.md` | OPEN |
| D11 | **Session lifetime**: the idle timeout (default 60 minutes) and whether the gateway's session policy is the one that ends a person's sign-in | A shared computer is protected by the gateway sign-out, since identity is asserted per request | 60 minutes; application session cookies end with the browser session (P8-05) | `ICFWALK_SESSION_TIMEOUT_MINUTES`, gateway policy | OPEN |
| D12 | **Monitoring and log retention**: the tool that reads the health endpoint and `icfwalk.log`, alert recipients, retention period | Section 8 of the runbook names what to alert on | Health endpoint, structured log, audit table | `docs/OPERATIONS.md` 8, 9.5 | OPEN |
| D14 | **Live district reports while completed walks are being edited**: whether a live report that answers 409 "run the report again" when walks in its population changed during it (after three attempts) is acceptable, or whether reports should read a point-in-time snapshot instead (an engineering change: SQL Server snapshot isolation, a new migration, and a review of the Phase 7 coherence design) | A district report during heavy post-completion editing can be refused; releases are unaffected | Refuses and asks for a retry, never mixes two states of a walk (Phase 7 design). After P8-14 rare: none on ColdFusion at 25 simultaneous walkers, a few in twenty on Lucee at its higher write rate | `docs/OPERATIONS.md` 12; `docs/evidence/phase8/performance/` | OPEN |
| D13 | **Report privacy minimum and releases** | RPT-03 | k = 3, frozen releases | `docs/OPEN_DECISIONS.md`, "Aggregate privacy rule (RPT-03)" | **DECIDED** 2026-09-23, owner, verbatim: "K=3, frozen releases" |

## Environments and people the verification still needs

These are not decisions but things only the district has. Each has a runnable checklist and an
evidence slot in `docs/VERIFICATION_CHECKLISTS.md`; until run there, the item is **NOT TESTABLE
HERE**.

| Need | For | Checklist |
| --- | --- | --- |
| Adobe ColdFusion 2023 with the `sqlserver` (DataDirect) package, behind IIS or Apache with the ColdFusion connector | The production stack as it will run | 1 |
| SQL Server 2016 (SP3+) | The oldest supported database engine | 2 |
| The connector's request-size limits in place | 413 at the connector for oversized bodies | 3 |
| Microsoft Excel (desktop, current build) | The instrument workbook round trip in Excel itself | 4 |
| A screen reader (NVDA with Firefox or Chrome on Windows; VoiceOver with Safari on macOS or iOS) and a person experienced with it | A11Y-01/02 with real assistive technology | 5 |
| The SSO gateway (a test tenant), TLS certificates, the production cookie and header configuration | SEC-04 and the production identity path end to end | 6 |
| A production-sized environment and approved criteria (D8) | Performance acceptance | 7 |
