# ICFWalk product specification

## Product purpose

ICFWalk is a district instructional walkthrough application for recording short observations against the current Instructional Clarity Framework, saving drafts continuously, producing a readable summary, drafting optional teacher feedback, and reporting aggregate patterns within authorized organizational scope.

## Primary users

| User | Primary job | Access boundary |
| --- | --- | --- |
| District walk and report user | Conduct walks, manage owned drafts, open permitted walk details, and view district/school aggregates | Assigned district scope and descendants |
| District report-only user | View aggregate district and school reports | No individual walk details or edits |
| School walk and report user | Conduct walks and view permitted school aggregates/details | Assigned school scope |
| School report-only user | View aggregate reports for assigned schools | No individual walk details or edits |
| Instrument administrator | Create, validate, preview, publish, and retire instrument versions | No walk or report access unless assigned a separate role |

The exact seeded role codes and permissions are in `database/001_schema.sql`.

## Application areas

### My Walks

- Default signed-in landing page.
- Shows only walks the user may list.
- Sorts by `updated_at` descending.
- Shows grade/content, school, observation date, and relative update time.
- Supports New walk, Open, and Delete/Void with confirmation.
- Empty state matches the current prototype's plain language.

### Walk editor

The editor loads a pinned instrument-version snapshot and renders these areas in order:

1. Visit information.
2. Any applicable conditional classroom sections.
3. Part 1: Target / Taxonomy / Pacing.
4. Part 2: seven Instructional Clarity Framework components.
5. Part 3: Conditions for Learning.
6. Part 4: Walk Summary and optional teacher email draft.

Every visible prompt, definition, choice, look-for, color, placeholder, section number, and conditional rule comes from the configuration snapshot.

### Visit information

| Field | Type | Current behavior |
| --- | --- | --- |
| Date | Date | Visible by default |
| Observer(s) | Text | Visible by default |
| School | Controlled list plus Other | Drives grade filtering |
| Grade level | Controlled list | Filtered by school group |
| Content area / subject | Controlled list plus Other | Art, Music, and CTE show content-area look-fors |
| Period | Controlled list plus Other | Visible only for grades 6–12 |
| Class type | Controlled list plus Other | Drives conditional classroom sections |
| Visit occurred at the | Controlled list | Beginning, Middle, or End of Lesson |

The current prototype does not expose teacher identity or classroom-label fields.

### Conditional sections

| Condition | Section |
| --- | --- |
| Grade is PreK or K | PreK–K Classroom |
| Class type is Dual Language | Dual Language Classroom |
| Class type is MAC or PREP | MAC / PREP Classroom |
| Class type is Ignite | Ignite Classroom |
| Class type is AVID | AVID Classroom |
| Class type is ESL | ESL Classroom |
| Content is Art, Music, or CTE | Content-Area Look-Fors |

Each conditional section uses Yes/No questions and a non-reportable notes field. Hidden sections do not contribute report values.

### Part 1

- Header: `Part 1 · Target / Taxonomy / Pacing`.
- Lesson Standard and Other disaggregation tag(s) appear first.
- Three required current core questions:
  - learning target from the content-area standard;
  - level of thinking in the standard;
  - level of thinking required by observed student evidence.
- Adopted Curriculum includes look-fors, pacing, two 1–5 questions, and notes.
- Target/Task Alignment includes look-fors, two 1–5 questions, and notes.
- Drafts may remain incomplete. Explicit completion performs server-side required-field validation.

### Part 2

The current components are:

1. Daily Engagement with Complex Texts.
2. Daily Engagement with Academic Vocabulary.
3. Workshop Model of Instruction.
4. Academic Teaming.
5. Formative Assessment.
6. Actionable Feedback.
7. Culturally & Linguistically Responsive.

Each component has current student/teacher look-fors, two 1–5 rating questions, exact per-question definitions, and notes.

Workshop Model and Academic Teaming have an applicability question. A new walk defaults both to No, matching the prototype. No hides and clears ratings but keeps notes. Yes exposes the questions. Component averages use answered numeric values only.

### Part 3

- Header: `Part 3 · Conditions for Learning`.
- Six current 1–5 questions with exact definitions.
- One non-reportable evidence/notes field.
- No School Improvement Plan categories or grade-band hierarchy in this version.

### Part 4

- Overall strengths observed.
- Priority area(s) for growth.
- Optional email-draft workflow.

The email workflow lets the user select one or more completed parts, generate editable subject/body text, optionally enter a recipient, regenerate, clear, copy, or open the default email client. The application does not send an email.

## Saving and lifecycle

- New walks begin as DRAFT and are pinned to the current published instrument version.
- Client changes trigger a 700 ms debounced autosave.
- Every mutation is authenticated, authorized, validated, parameterized, and protected by optimistic concurrency.
- UI states: Unsaved changes, Saving..., All changes saved, and a specific failure/conflict message.
- A draft may be incomplete.
- Completion is explicit and server-validates required fields.
- Completed history is retained. Voiding records a reason and audit event.
- Published instrument versions and completed version definitions are immutable.

## Summary export

- Plain UTF-8 text.
- Includes populated visit metadata in current order.
- Includes only applicable conditional sections.
- Prints unanswered items as `not answered`.
- Prints numeric ratings as `n/5`.
- Prints component average from answered numeric ratings only.
- Prints skippable No sections as not part of the lesson.
- Includes Part 3 and Part 4 in current order.
- Filename pattern follows `ICFWalk_<grade>_<content>_<date>.txt` with unsafe filename characters replaced.

## Instrument administration

- List versions and statuses.
- Create a new DRAFT from a prior snapshot or JSON import.
- Edit only DRAFT definitions.
- Validate unique keys, references, order, option membership, rules, JSON settings, required fields, and placeholder issues.
- Preview with the same renderer used by walks.
- Publish an immutable canonical snapshot and SHA-256.
- Retire a version without changing historical walks.
- Compare version keys, wording, response options, rules, and reportability.

## Aggregate reporting

- Enforce district/school scope on the server.
- Filter by authorized school, date range, instrument version, grade, content, period, class type, visit timing, section, item, and option.
- Show response counts/distributions and numeric averages using answered numeric scores only.
- Keep hidden, unanswered, and not-applicable states distinct.
- Exclude all narrative text, email draft content, and database-only teacher/classroom fields.
- Report-only users receive no individual walk identifiers or drill-through.

## Visual and interaction requirements

- Use the prototype as the visual baseline: U-46 navy/blue palette, Work Sans-compatible appearance, clear cards, pill controls, section accordions, and compact status text.
- Maintain usable layout at desktop, tablet, and phone sizes.
- All controls must be keyboard operable with visible focus.
- Use semantic headings, field labels, grouped controls, accessible status/error announcements, and contrast meeting WCAG 2.1 AA.
- Do not rely on color alone for selection, validation, or required state.

## Quality requirements

- No silent data loss.
- No cross-scope data exposure.
- No raw SQL concatenation.
- No hardcoded secrets.
- No authoritative localStorage records in production.
- No aggregate reporting of narrative or teacher-identifying content.
- No automatic outbound email.
- No reintroduction of retired legacy SIP content.

