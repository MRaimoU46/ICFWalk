# ICFWalk acceptance tests

All applicable tests must be automated. Browser/visual and assistive-technology checks may include documented manual evidence where automation cannot prove the result. Use synthetic fixture identities and records only.

## Package and configuration

| ID | Test | Expected result |
| --- | --- | --- |
| PKG-01 | Run `node scripts/validate-handoff.mjs`. | Exit code 0 with source hash, reference checks, unique-key checks, and expected counts confirmed. |
| PKG-02 | Search active JSON sections/items for legacy SIP hierarchy content. | No active School Improvement Plan hierarchy is present; Part 3 title is `Part 3 · Conditions for Learning`. |
| PKG-03 | Count items whose review status is `Placeholder in source`. | Exactly 17, split 3 PreK–K, 3 MAC/PREP, 3 Ignite, 3 AVID, and 5 content-area. |
| PKG-04 | Compare current prototype SHA-256 with JSON source metadata. | Both equal `239531267fa1dfaedaf4e1a8842156bc90db425893781330470312e3c34a1361`. |
| PKG-05 | Compare JSON counts with the aligned workbook tables. | 23 sections, 144 items, 29 response sets, 138 options, 12 rules, 10 dimensions, 95 values, and 10 placements. |

## Database and seed

| ID | Test | Expected result |
| --- | --- | --- |
| DB-01 | Apply `001_schema.sql` then `002_alignment_patch.sql` to an empty SQL Server 2016+ database. | Both complete successfully and commit. |
| DB-02 | Apply `001_schema.sql` to a database where the `icf` schema already contains tables. | Script aborts without dropping or replacing existing objects. |
| DB-03 | Reapply `002_alignment_patch.sql`. | No error and no duplicate column/constraint. |
| DB-04 | Import `instrument-config.json` as a new DRAFT. | All logical references map to GUID rows; snapshot is stored; no duplicate keys. |
| DB-05 | Reimport the unchanged JSON into the same DRAFT. | Idempotent update with no duplicate child rows and identical canonical checksum. |
| DB-06 | Attempt the same import against a PUBLISHED version. | Import is refused; published rows and snapshot remain unchanged. |
| DB-07 | Remove one referenced response set from a disposable JSON copy and import. | Transaction rolls back with a specific missing-reference error. |
| DB-08 | Corrupt a conditions JSON document and import. | Transaction rolls back; no partial version is created. |
| DB-09 | Inspect response-option definitions after import. | Exact current definitions are available to the runtime and match the JSON. |

## Authentication and authorization

| ID | Test | Expected result |
| --- | --- | --- |
| AUTH-01 | Request an authenticated endpoint without an identity. | Denied with no protected data in the response. |
| AUTH-02 | Enable development identity configuration in a production environment. | Application refuses to start or ignores the development stub and logs a safe configuration error. |
| AUTH-03 | District walk/report role accesses a walk inside assigned district scope. | Access allowed according to role permissions. |
| AUTH-04 | School walk/report role accesses a walk in an unassigned school. | Denied even if the walk GUID is known. |
| AUTH-05 | Report-only role requests an individual walk-detail endpoint. | Denied; no partial detail, teacher field, note, or identifier leaks. |
| AUTH-06 | Instrument admin with no walk/report role requests walk details or reports. | Denied; instrument administration remains separate. |
| AUTH-07 | Scope assignment is not yet effective or has expired. | Access denied for that assignment. |
| AUTH-08 | Assignment has `include_descendants = 1`. | Authorized descendant schools are included; unrelated branches are excluded. |
| AUTH-09 | User tampers with version, org-unit, item, option, or dimension GUID in a request. | Server re-resolves membership/scope and rejects the request. |

## My Walks and lifecycle

| ID | Test | Expected result |
| --- | --- | --- |
| WALK-01 | New user with no walks opens My Walks. | Current empty-state wording and New walk action appear. |
| WALK-02 | Create a new walk. | One DRAFT is created, pinned to the current published version and signed-in owner. |
| WALK-03 | Create request is retried with the same mutation/idempotency key. | Only one walk exists. |
| WALK-04 | Open My Walks with several fixtures. | Sorted by `updated_at` descending and displays grade/content, school, date, and relative update time. |
| WALK-05 | Owner opens an authorized DRAFT. | Current saved dimensions/responses render correctly. |
| WALK-06 | User confirms deletion of a disposable DRAFT. | Draft is removed/voided according to policy, list updates, and audit event is recorded. |
| WALK-07 | User cancels deletion. | No mutation occurs. |
| WALK-08 | Attempt physical deletion of a completed/audited walk through the UI/API. | Refused; use VOIDED lifecycle and reason instead. |
| WALK-09 | Complete a walk missing a required Part 1 response. | Completion rejected with field-specific accessible errors; DRAFT remains saved. |
| WALK-10 | Complete a walk with all required values valid. | Status becomes COMPLETED, timestamp is set, and audit/revision behavior is correct. |
| WALK-11 | Open an older walk after a newer instrument version is published. | It renders against its pinned historical snapshot without content drift. |

## Metadata and conditional UI

| ID | Test | Expected result |
| --- | --- | --- |
| COND-01 | Select a recognized elementary school. | Grade choices are PreK, K, and 1–5 only. |
| COND-02 | Select a recognized middle school. | Grade choices are 6–8 only. |
| COND-03 | Select a high school, Dream Academy, or Central School. | Grade choices are 9–12 only. |
| COND-04 | Select Other/unrecognized school. | Full PreK–12 list is available. |
| COND-05 | Select grade 5, then change to a middle school. | Invalid grade is cleared and dependent visibility recalculates. |
| COND-06 | Select grades 6–12 and then a lower grade. | Period shows for 6–12 and hides outside that range. Hidden value follows the documented HIDDEN retention policy. |
| COND-07 | Select PreK or K. | PreK–K section shows; it hides for every other grade. |
| COND-08 | Select Dual Language, MAC, PREP, Ignite, AVID, and ESL one at a time. | Only the matching class-type conditional section shows. |
| COND-09 | Select Art, Music, or CTE, then another content area. | Content-area section shows only for the three trigger values. |
| COND-10 | Answer a conditional-section item, hide the section by changing metadata, then restore the condition. | Value is excluded while HIDDEN and reappears when visible again. |
| COND-11 | Start a new walk and open Workshop Model and Academic Teaming. | Both applicability controls default to No and rating rows are hidden. |
| COND-12 | Set a skippable component to Yes and answer ratings, then set it to No. | Ratings clear in one transaction, rows hide, notes remain, state is NOT_APPLICABLE, and average updates. |
| COND-13 | Set the component back to Yes. | Rating rows return UNANSWERED; cleared ratings do not reappear; retained notes remain. |
| COND-14 | Open every rating definition toggle. | Labels 1–5 and exact per-question definitions match the JSON. |
| COND-15 | Leave some ratings unanswered. | Count and average use answered ratings only; blanks never display or calculate as zero. |

## Autosave and concurrency

| ID | Test | Expected result |
| --- | --- | --- |
| SAVE-01 | Type several changes within 700 ms. | UI shows Unsaved changes immediately and coalesces them into one debounced save after activity stops. |
| SAVE-02 | Observe a successful save. | Status advances Saving... to All changes saved and receives a new row version. |
| SAVE-03 | Simulate a recoverable network failure. | Specific failure remains visible, user input remains on screen, and a safe retry is possible. |
| SAVE-04 | Open one walk in two sessions, save A, then save stale B. | B receives a conflict; A is not overwritten. |
| SAVE-05 | Resolve the conflict by reloading the server record. | User can review/preserve unsent B edits; resulting save uses the new row version. |
| SAVE-06 | Retry the same response mutation with the same client mutation ID. | No duplicate response/revision rows and one committed logical change. |
| SAVE-07 | Submit an answer using an option from another response set/version. | Server rejects it even if the option GUID exists. |
| SAVE-08 | Submit text containing HTML/script characters in a narrative field. | Stored safely and rendered as text; no script executes in editor, list, export preview, admin, or reports. |

## Summary export and email draft

| ID | Test | Expected result |
| --- | --- | --- |
| SUM-01 | Export a representative fully answered walk. | UTF-8 text section order, headings, values, notes, scores, and averages match the current prototype. |
| SUM-02 | Export with unanswered items. | Each appears as `not answered`; no fake zero or healthy completion is implied. |
| SUM-03 | Export with Workshop Model set to No. | Section is labeled not part of the lesson, has no ratings/average, and may include retained notes. |
| SUM-04 | Export after a conditional classroom section becomes hidden. | Hidden section and its retained values are excluded. |
| SUM-05 | Export with punctuation/unsafe characters in grade/content/date label inputs. | Filename follows current pattern with unsafe characters replaced; no path traversal is possible. |
| SUM-06 | Generate email draft with selected Part 1, one component, Part 3, and summary. | Subject/body ordering and current template wording match the prototype; only checked parts appear. |
| SUM-07 | Edit email recipient, subject, and body, then autosave/reopen. | Draft state is restored exactly and remains non-reportable. |
| SUM-08 | Use Copy and Open in email app. | Copy contains editable subject/body; mailto is URL encoded; no server-side send occurs. |
| SUM-09 | Clear the email draft. | Drafted flag, subject, and body clear; walk observation responses remain unchanged. |

## Instrument administration

| ID | Test | Expected result |
| --- | --- | --- |
| ADM-01 | Instrument admin imports the aligned JSON into a DRAFT. | Validation summary shows counts and 17 placeholder warnings. |
| ADM-02 | Preview the DRAFT. | Uses the same renderer and rules as the walk editor. |
| ADM-03 | Introduce duplicate keys, bad parent, missing set, invalid option order, or malformed rule JSON. | Publish is blocked with specific errors and no partial state change. |
| ADM-04 | Publish a valid DRAFT. | Canonical snapshot and checksum are stored; timestamps/publisher/status set atomically. |
| ADM-05 | Try to edit any published definition through UI, endpoint, or direct service call. | Rejected and audited; published data unchanged. |
| ADM-06 | Create a new DRAFT from a published version and alter one prompt. | Prior version remains unchanged; compare view shows the exact prompt change. |
| ADM-07 | Retire a published version used by historical walks. | No new walks use it; existing walks continue rendering from it. |
| ADM-08 | Search admin for source placeholders. | Exactly 17 current items appear with source location and review status. |

## Aggregate reporting

| ID | Test | Expected result |
| --- | --- | --- |
| RPT-01 | School report role requests its assigned school and another school. | Assigned school aggregate returns; other school is denied or omitted. |
| RPT-02 | District report role filters across descendant schools. | Only in-scope schools contribute. |
| RPT-03 | Report-only user tries to drill into a walk or infer an individual row from an export/API. | No individual detail or identifier is returned. |
| RPT-04 | Dataset includes answered 1 and 5, one unanswered, one hidden, and one not applicable. | Average is 3.0 using denominator 2; states remain separately countable. |
| RPT-05 | Components have different answered-item counts across walks. | Aggregate is calculated from item-level scored responses, not an unweighted average of walk averages. |
| RPT-06 | Inspect report payload/export/logs with notes, email draft, and teacher fields populated. | None of those values appear. |
| RPT-07 | Apply date, school, grade, content, period, class type, visit timing, version, section, item, and option filters. | Each uses the requested population and retains scope restrictions. |

## Security, privacy, and operations

| ID | Test | Expected result |
| --- | --- | --- |
| SEC-01 | Exercise inputs with SQL metacharacters and common injection payloads. | Queries remain parameterized; no injection or data exposure. |
| SEC-02 | Exercise reflected and stored XSS payloads in every text field and imported label. | Output is encoded/sanitized; no script or event handler executes. |
| SEC-03 | Submit a state-changing request without/with invalid CSRF protection. | Request denied with no mutation. |
| SEC-04 | Inspect cookies and session behavior in production configuration. | Secure, HttpOnly, appropriate SameSite, rotation/expiry, and TLS assumptions are documented/enforced. |
| SEC-05 | Inspect logs during saves, conflicts, exports, and errors. | Correlation and safe facts present; no notes, email bodies, secrets, tokens, or unnecessary personal data. |
| SEC-06 | Restart application during an autosave and retry. | Database remains consistent; retry is idempotent; user receives accurate status. |
| SEC-07 | Run schema/seed/app deployment from documented clean-install steps. | A new environment becomes runnable without undocumented manual database edits. |

## Accessibility and responsive behavior

| ID | Test | Expected result |
| --- | --- | --- |
| A11Y-01 | Complete a walk using keyboard only. | Every action is reachable, focus order is logical, accordions/pills expose state, and focus remains visible. |
| A11Y-02 | Inspect labels, groups, headings, statuses, and errors with accessibility tooling. | Programmatic names/relationships are correct; save and validation messages are announced. |
| A11Y-03 | Run automated WCAG checks on My Walks, all editor states, admin, and reports. | No critical/serious WCAG 2.1 AA violations; documented manual checks complete the coverage. |
| A11Y-04 | Check current colors in normal, selected, error, and disabled states. | Required contrast passes and meaning is not color-only. |
| A11Y-05 | Test at approximately 375 px, 768 px, and desktop widths with 200% zoom. | No clipped controls, horizontal loss of required content, overlapping text, or unreachable actions. |

## Completion evidence

The final build report must list every test ID, automation/manual method, result, and evidence location. Any non-applicable test needs a concrete reason. No critical or high-severity failed test may remain open at handoff.

