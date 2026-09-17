# Source alignment and version decision

## Decision

The attached `source/current-prototype.html` is the current product and instrument baseline. The supplied legacy workbook was generated from a different HTML version and is retained only for historical context.

Do not combine their section trees, questions, response scales, or behavior.

## Verified source fingerprints

| Artifact | SHA-256 | Status |
| --- | --- | --- |
| `source/current-prototype.html` | `239531267fa1dfaedaf4e1a8842156bc90db425893781330470312e3c34a1361` | Current content and interaction authority |
| `database/001_schema.sql` | `c6c16b6cdc1ae10760e43f0bcbf32a4fd84eed51166f1487fb6b7484532d1374` | Current supplied database authority |
| Original uploaded workbook | `16212bdbafa9e2429940da89380ef818d9c54c80a5e36ae67b58f8502692407f` | Historical workbook file |
| HTML recorded inside the legacy workbook | `8c6c5b4add59b8858232d8b3fd4108668324c24817ebb0853f464deedef87cc3` | Retired, different HTML baseline |

## Material differences

| Area | Legacy workbook baseline | Current aligned baseline |
| --- | --- | --- |
| Part 1 | Target/Task Alignment baseline with older core questions and five-question component treatment | Target / Taxonomy / Pacing with three taxonomy questions, Adopted Curriculum, and Target/Task Alignment |
| Part 2 | Older component grouping and wording | Seven components, each with two rated questions and exact current 1–5 definitions |
| Complex Texts / Vocabulary | Combined in the old section tree | Separate `2.1 Complex Texts` and `2.2 Academic Vocabulary` components |
| Part 3 | Large School Improvement Plan hierarchy, grade-band look-fors, and achievement-walk material | Six-question Conditions for Learning section |
| Conditional classrooms | Older PreK–K content and older conditional coverage | Current PreK–K, Dual Language, MAC/PREP, Ignite, AVID, ESL, and Art/Music/CTE content-area behavior |
| Skippable components | Workshop Model and Academic Teaming with legacy reset-rule rows | Same two components, defaulting to No; current UI hides and clears ratings when No |
| Email drafting | Older workbook represented a broad workflow | Current app exposes one Part 4 composer that can include any prior part and never sends automatically |
| Persistence | Workbook described a configuration model | Current prototype still uses browser localStorage; production must map the same experience to SQL Server |

## Configuration replacement

The aligned JSON and workbook intentionally replace the legacy configuration counts:

| Configuration | Legacy workbook | Aligned current version |
| --- | ---: | ---: |
| Sections | 295 | 23 |
| Items | 1,154 | 144 |
| Response sets | 94 | 29 |
| Response options | 478 | 138 |
| Rules | 29 | 12 |
| Dimensions | 10 | 10 |
| Dimension values | 93 | 95 |
| Instrument dimensions | 10 | 10 |

The aligned item count includes non-response display headings and look-for guidance because the production instrument must remain data driven.

## Current behavior that must remain exact

- My Walks list sorted by most recently updated.
- Browser-visible autosave state with a 700 ms debounce.
- School-based grade filtering and invalid-grade clearing.
- Period visibility only for grades 6–12.
- Conditional classroom sections driven by grade, class type, and content area.
- Workshop Model and Academic Teaming default to not applicable for a new walk.
- Changing either skippable component to No clears its ratings, hides its rating rows, retains notes, and removes it from averages.
- Rating definitions appear on demand.
- Part 2 averages use answered numeric ratings only.
- Plain-text summary export follows current section order and wording.
- The Part 4 email draft is editable and can be copied or opened through `mailto`; it is never automatically sent.

## Intentional unresolved content

The current prototype contains 17 generic prompts:

- PreK–K: 3
- MAC / PREP: 3
- Ignite: 3
- AVID: 3
- Content area: 5

They are marked `Placeholder in source` in the JSON and aligned workbook. Preserve them until content owners provide approved wording. Do not recover older wording from the legacy workbook as a silent substitute.

## Database-only fields

The SQL `walk` table contains `teacher_identifier`, `teacher_display_name`, `teacher_email`, and `classroom_label`. These fields do not appear in the current prototype. Keep them nullable and out of the UI until separately approved. They must also remain excluded from aggregate reporting.

## Retired content guardrail

No section key, item, navigation route, report dimension, or seed path in the new build may restore the legacy SIP hierarchy merely because it exists in `reference/legacy-configuration-workbook.xlsx`. A future SIP feature requires a separately approved new instrument version.

