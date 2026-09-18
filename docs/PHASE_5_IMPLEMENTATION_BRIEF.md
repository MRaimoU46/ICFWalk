# Phase 5 implementation brief: summary export and teacher email draft

Prepared at the end of Phase 4 (baseline commit `0df22bc`, branch `claude/admiring-wozniak-fsuayk`).
This brief is the hand-off for a fresh Claude Code session. It records what Phase 5 must build, what
already exists to build on, the governing wording, the decisions already resolved from source
precedence, and the tests that prove completion. Read the "Fresh session instructions" at the end
first if you are that session.

Governing precedence (from `CLAUDE_FABLE_MASTER_PROMPT.md`): 1 prototype (`source/current-prototype.html`)
for visible content and interaction, 2 `config/instrument-config.json` for the data contract, 3 SQL
scripts for persistence, then `docs/DATA_CONTRACT.md` / `docs/PRODUCT_SPEC.md` / `docs/ACCEPTANCE_TESTS.md`.
Conflicts are resolved in section 14; do not re-derive them.

## 1. Scope and acceptance IDs

`docs/IMPLEMENTATION_PLAN.md`, Phase 5:

- Implement shared server/client summary formatting.
- Implement text export and exact safe filename behavior.
- Implement persisted, editable Part 4 email draft with copy and mailto actions only.
- Completion gate: summary golden-file tests and no-automatic-send tests pass.

Acceptance IDs owned by Phase 5: **SUM-01, SUM-02, SUM-03, SUM-04, SUM-05, SUM-06, SUM-07, SUM-08,
SUM-09** (`docs/ACCEPTANCE_TESTS.md`). Rows touched incidentally and to be extended, not re-proven:
SEC-02 (export preview shows stored markup as text), SEC-05 (export logs carry no content), A11Y-01/02/03
(composer and export controls), AUTH-05 (report-only users get no summary).

Out of scope: publishing/administration (Phase 6), reporting (Phase 7), any outbound mail
integration (never; `docs/OPEN_DECISIONS.md`), teacher fields on the walk row (hidden until approved).

## 2. Phase 4 architecture to reuse

```
browser  app.js -> ApiWalkStore (walk-store.js) -> /api/walks routes (Router policy + CSRF)
server   WalkController -> WalkService -> AuthorizationService.authorizeWalk
                                        -> WalkPayloadValidator (keys/codes/values vs pinned version)
                                        -> VisibilityEngine.normalize / evaluateVisibility
                                        -> WalkRepository (one transaction, UPDLOCK, diff-writes,
                                           walk_revision, walk_mutation) -> AuditRepository
render   SnapshotService.renderModelFor(versionId) -> render model (icfwalk-render-model/1)
```

Facts Phase 5 depends on (all implemented and tested in Phase 4):

- `WalkService.open(principal, walkId)` returns the walk DTO: header (`id, versionId, versionLabel,
  status, isOwner, canEdit, rowVersion, ...`), `state` (`dimensions` by code, `responses` by item key;
  values only, in the `docs/DATA_CONTRACT.md` shape), `states` (`responseStates`, `dimensionStates`
  from the server engine, `persistedResponseStates`). This is exactly the input a summary needs.
- `WalkService.instrumentFor(principal, walkId)` returns `{ version, policies, model }` for the
  walk's pinned version; `app.js` caches models per `versionId` (`app.models`) and uses
  `modelFor(walk)` everywhere. Phase 5 formatters take `(model, state, evaluation)`, never fetch.
- The email-draft item already persists through the ordinary save path: item key `email_workflow`,
  type `EMAIL_DRAFT_JSON`, layout `email-draft`, section `part4`, `settings.selectableParts[]`.
  `WalkPayloadValidator.validateEmailDraft(text)` accepts only `{ includedPartKeys: string[],
  drafted: boolean, to, subject, body: strings }`, canonicalizes key order (`body, drafted,
  includedPartKeys, subject, to`), stores it in `walk_response.text_value` (state `ANSWERED` when
  non-empty), and rejects anything else with 400 `INVALID_EMAIL_DRAFT`. Non-reportable by contract.
- `renderer.js` already reserves the composer slot: for `item.layout === "email-draft"` it appends
  `<div class="email-slot" data-item-key="email_workflow" hidden>` inside the Part 4 accordion after
  the two Part 4 text items (display order 10, 20, then 100) and registers it in `ctx.itemNodes`.
  `refresh()` syncs pills/textareas from state; the slot has no sync yet.
- `walk-state.js`: `setResponse(state, itemKey, { textValue })`, `dimensionDisplay(model, state, code)`
  (selected label, or the typed Other text, or text/date value), `isOtherValue(value)`,
  `ratingSummary(section, evaluation)` (rated question count, answered count, notApplicable flag).
- `VisibilityEngine` / `rules.js`: `evaluate(model, state)` gives `sections`, `items`, `dimensions`,
  `responseStates` (`ANSWERED | UNANSWERED | HIDDEN | NOT_APPLICABLE`), `dimensionStates`. The
  summary must consult these, never re-derive visibility.
- `Responder.send({ status, text, contentType, headers })` already writes a text body with the
  given content type (used by the HTML shell); the text path sets only the status and content
  type, so the summary result must pass `Cache-Control: no-store`, `X-Content-Type-Options:
  nosniff`, and `Content-Disposition` itself through `headers`.
- Router policies: `variables.WALK_READ_PERMISSIONS` (`walk.read`, `walk.edit_owned`) with
  `authorizeWalk(principal, id, "read")` in the service is the pattern for any walk read route.
- `AuditRepository.record(entityType, entityId, eventType, actorUserId, details)` strips keys that
  look like content (`body`, `subject`, `notes`, `text_value`, ...). Never pass narrative anyway.
- Shell CSP: `default-src 'self'; script-src 'self'; ... connect-src 'self' ...; form-action 'self'`.
  No inline scripts/styles; `blob:` is not listed (a `blob:` download link is allowed by browsers as a
  download, but prefer the server route, section 7).
- `#export-btn` exists in `src/views/shell.html` (`hidden`), unwired in `app.js`.
- Tests: `tests/cfml/specs/WalkServiceTest.cfc` (fixtures, helpers `newWalk`, `saveState`,
  `requiredAnswers`), `tests/node/walks.test.mjs` (cookie-jar `client(subject)` with CSRF),
  `tests/node/browser-persistence.test.mjs` (Playwright helpers `openHome`, `startWalk`, `openCard`,
  `waitStatus`, `selectDim`, `clickPill`, `ensureExpanded`), `tests/node/visibility.test.mjs` +
  `tests/cfml/specs/VisibilityEngineTest.cfc` (the vector-parity pattern to copy).

## 3. Existing files relevant to Phase 5 (read only these)

| File | Why |
| --- | --- |
| `source/current-prototype.html` lines 660-700 (`SHORT_TITLES`, `PART_SEQUENCE`), 777-790 (`META_FIELDS`), 936-943 (`metaDisplay`), 1359-1549 (email draft generation, composer, copy, mailto), 2064-2213 (`buildSummaryText`, `exportWalk`) | The authoritative wording, line order, filename rule, and composer behavior. Section 7/8 below transcribe them; open the file only to confirm a detail. |
| `config/instrument-config.json` `behavior.export`, `behavior.emailDraft`, item `email_workflow` (`settings.selectableParts`), sections `part1..part4`, `s1..s7` (`settings.partNumber`, `canBeSkipped`) | Data the formatters must be driven by. |
| `docs/PRODUCT_SPEC.md` "Part 4" and "Summary export" | Requirement bullets (transcribed in section 7). |
| `docs/DATA_CONTRACT.md` "Email-draft JSON", "Visibility and clearing rules", "Build decisions recorded in Phase 4" | Persistence shape and hidden-value policy. |
| `docs/ACCEPTANCE_TESTS.md` SUM-01..09 | Exact expected results. |
| `src/walks/WalkService.cfc` (`open`, `instrumentFor`, `loadDto`, `stateOf`, `headerDto`) | Where `summary` plugs in; DTO shape. |
| `src/walks/WalkPayloadValidator.cfc` (`validateEmailDraft`, `modelIndex`) | Email schema, item/placement index. |
| `src/instrument/VisibilityEngine.cfc`, `app/assets/js/rules.js` | Evaluation output consumed by the formatters. |
| `app/assets/js/walk-state.js`, `app/assets/js/renderer.js` lines 52-125 (`renderEditor`, `commit`, `refresh`) and 318-345 (email slot) | Hooks for the composer and state sync. |
| `app/assets/js/app.js` (`openWalk`, `saveCurrent`, `applyEditability`, `modelFor`) | Where the export button and composer wiring go. |
| `src/http/Router.cfc`, `src/controllers/WalkController.cfc`, `src/http/Responder.cfc` (`send`) | Route, controller, and text response. |
| `docs/ARCHITECTURE.md` "Walk persistence and autosave (Phase 4)" and "What Phase 5 builds on" | Architecture context (short). |
| `docs/ENDPOINTS.md`, `docs/ACCEPTANCE_TRACKING.md`, `BUILD_STATUS.md` (Phase 4 section only) | Documents to extend at the end. |

Do not reread: `README.md`, `docs/SOURCE_ALIGNMENT.md`, `docs/IMPLEMENTATION_PLAN.md` beyond Phase 5,
`database/*.sql`, `reference/*`, the Phase 0-3 sections of `BUILD_STATUS.md`, `src/instrument/*Import*`,
`src/identity/*`, `src/authorization/*` (unchanged and not needed).

## 4. New files, classes, and routes

| Path | Responsibility |
| --- | --- |
| `src/walks/WalkSummaryFormatter.cfc` | Pure function of `(model, state, evaluation)`: `summaryText()` (the export), `fileName(walkId)`, `emailDraft(includedPartKeys)`, plus the shared building blocks (`componentAverage`, section line builders). No database, no request scope, no logging. |
| `app/assets/js/summary.js` | JavaScript twin with the same function names and output; imported by `app.js` and by `tests/node/summary.test.mjs`. |
| `tests/fixtures/summary-vectors.json` | Golden vectors (section 6). |
| `tests/cfml/specs/WalkSummaryFormatterTest.cfc` | CFML formatter against the vectors + edge cases. |
| `tests/node/summary.test.mjs` | JS formatter against the vectors (served model) + SUM-05 filename cases. |
| `scripts/prototype-summary-oracle.mjs` | One-off Playwright script that loads the prototype, injects a walk state, and prints `buildSummaryText()` / `generateEmailDraftFor()` output for review of the vectors (section 6). Not part of `npm test`. |
| `app/assets/js/email-composer.js` (or a section of `renderer.js`) | Renders the Part 4 composer into the email slot from `item.settings.selectableParts`, reads/writes the `email_workflow` response through `setResponse` + `commit` (section 8). |
| Route `GET ^/api/walks/([^/]+)/summary$` → `walkController.summary` | Text export (section 7). Policy `{ anyPermission: variables.WALK_READ_PERMISSIONS }`. |
| `WalkService.summary(principal, walkId)` | `authorizeWalk(read)` → load DTO pieces → formatter → `{ text, fileName }`; audit `WALK_SUMMARY_EXPORTED`. |
| `WalkController.summary(req)` | Returns `{ status: 200, text, contentType: "text/plain; charset=utf-8", headers: {...} }`. |
| `tests/node/browser-email.test.mjs` (or extend `browser-persistence.test.mjs`) | SUM-06..09 and export download in Chromium (section 12). |

No new tables, columns, or migrations (section 9).

## 5. Shared summary formatter architecture

Both formatters are deterministic, side-effect-free functions over the render model, the working
state, and the engine evaluation. They must not name a section, item, or option; every string comes
from the model (titles, prompts, option labels, placement labels, `settings.partNumber`,
`selectableParts`) or from a small presentation map (below), exactly as `LIST_CARD` in `app.js` and
the presentation heuristics of `RenderModelBuilder` already do.

Inputs: `model` (`icfwalk-render-model/1`), `state` (`{ dimensions, responses }`), `evaluation`
(`evaluate`/`evaluateVisibility` output). The CFML side computes the evaluation with
`variables.engine.evaluateVisibility(model, stateOf(dims, responses))` exactly as `loadDto` does;
the JS side uses `settle(model, state, policies).evaluation` from `walk-state.js`.

Output contract (both sides, byte-identical):

```
summaryText(model, state, evaluation)            -> string, lines joined with "\n", no trailing newline
fileName(model, state, evaluation, walkId)       -> "ICFWalk_<label>.txt"
emailDraft(model, state, evaluation, includedPartKeys) -> { subject, body }
componentAverage(section, state, evaluation)     -> "3.5" | "n/a"   (string, one decimal, toFixed(1) semantics)
```

Presentation map (the only literals besides prototype template sentences), identical in both files:

```
SUMMARY_TITLE          = "ICFWALK SUMMARY"      underline = "================" (16 "=")
UNANSWERED             = "not answered"
NONE_NOTED             = "(none noted)"
NOT_PART_SUFFIX        = "  (not part of this lesson at the time of the visit)"
AVG_PREFIX/SUFFIX      = "  (avg: " / ")"
NOTES_PREFIX           = "Notes: "
PART4_LABELS           = { summary_strengths: "Strengths", summary_growth: "Growth areas" }   // by item key, see 14.6
TITLE_SEPARATOR        = " · " -> " — " (U+2014) when a part title is uppercased for a heading
```

Number formatting: averages use `toFixed(1)` in JS; in CFML use `numberFormat(avg, "0.0")` and
prove parity on values such as 2.25 (JS `toFixed` rounds half away from zero for exactly
representable halves like 2.5 but not for 2.25 → "2.3"? No: (2.25).toFixed(1) is "2.3" in V8,
while numberFormat may give "2.3" or "2.2"). Put 2.25, 3.05, 4.45, and 2.5 in the vectors and
implement the CFML rounding to match V8 exactly (compute `round(avg * 10) / 10` on the decimal
string representation, or format through `java.math.BigDecimal(String).setScale(1, HALF_UP)` on the
exact decimal text of the mean, then compare). The vectors are the arbiter.

Encoding: em dash `—` (U+2014), en dash in `PreK–K` (from the section title), curly apostrophe `’`
in the email sentences (from the prototype). CFML source files must be UTF-8; the JS file too.

Structure of `summaryText` (prototype `buildSummaryText`, made data-driven):

1. `ICFWALK SUMMARY`, `================`.
2. Visit information: for each placement of the `visit_information` section in authored order,
   when `evaluation.dimensionStates[code] === "ANSWERED"` (visible and populated; hidden Period is
   excluded, see 14.2): `<label>: <display>` where `label` is the placement label with one trailing
   colon removed (14.4) and `display` is `dimensionDisplay` (selected label, Other text, or text/date).
3. Conditional top-level cards (top-level sections before `part1` that are `conditional`): only when
   `evaluation.sections[key]` is true, in the order of 14.1: blank line, heading (14.3), then one line
   per choice item `- <prompt>  [<value>]` (two spaces before `[`; value = option label of the stored
   code, or `not answered`), then `Notes: <text>` only when the section's LONG_TEXT item has text.
4. Part 1: blank line, `PART 1 — TARGET / TAXONOMY / PACING` (title uppercased, ` · ` → ` — `);
   then the part's own placements (`topic`, `tag`) as `<label>: <value>` only when populated; then
   the `target_taxonomy` block's choice items as `- <prompt>  [<label or not answered>]` with no
   heading of its own (the prototype prints these directly under Part 1); then each remaining child
   section (`part1_adopted`, `part1_targettask`): blank line, `<TITLE UPPERCASED>`, choice items
   (`- <prompt>:  [<label>]` for the non-scored pacing item exactly as the prototype: prompt, colon,
   two spaces; scored items `- <prompt>  [<n>/5]`), then `Notes:` when present.
5. Part 2: blank line, `PART 2 — INSTRUCTIONAL CLARITY FRAMEWORK COMPONENTS`; for each component
   section in order: blank line; if the applicability item's state makes the rated items
   `NOT_APPLICABLE` (`ratingSummary(...).notApplicable`): `<partNumber> <TITLE UPPERCASED>  (not part
   of this lesson at the time of the visit)` and `Notes:` when present; otherwise `<partNumber> <TITLE
   UPPERCASED>  (avg: <avg>)`, one `- <prompt>  [<n>/5 | not answered]` per rated item, then `Notes:`.
6. Part 3: blank line, `PART 3 — CONDITIONS FOR LEARNING`, scored items as `- <prompt>  [<n>/5]`,
   `Notes:` when present.
7. Part 4: blank line, `PART 4 — WALK SUMMARY`, `Strengths: <text | (none noted)>`,
   `Growth areas: <text | (none noted)>` (labels from `PART4_LABELS`).

Value rules: scored option → `<storedCode>/<max numeric score in the set>` (5 today); non-scored
option → option label (14.5); empty → `not answered`; `HIDDEN` items never print (their section is
hidden); `NOT_APPLICABLE` rated items never print (the component prints the not-part line instead).
`componentAverage` = mean of `numericScore` over rated items whose state is `ANSWERED`, `n/a` when
none (SUM-02/03, COND-15: blanks never count as zero).

`emailDraft` (prototype `generateEmailDraftFor`, driven by `item.settings.selectableParts`):

```
gradeContent = [display(grade), display(content)].filter(Boolean).join(" ")
dateBit      = date ? " on " + <dateValue as stored, YYYY-MM-DD> : ""
body  = "I enjoyed my time stopping by your classroom today. I wanted to share a quick feedback note from what I observed during the visit"
      + (gradeContent ? " in " + gradeContent : "") + dateBit + ".\n"
for each selectable part in settings order that is included:  body += "\n" + partLines.join("\n") + "\n"
if none included: body += "\n(No sections were selected — check at least one part above, then update the draft.)\n"
body += "\nStop by whenever you can, as I would love to talk through this with you — thanks again for what you do in your classroom for our students.\n\n"
body += display(observer) || "[Your name]"
subject = "Quick note from today’s walk-through" + (gradeContent ? " — " + gradeContent : "")
        + (includedLabels.length ? " (" + includedLabels.join(", ") + ")" : "")
```

Part lines by `kind`:

- `part1merged`: `"<partNum> — <label without the 'Part 1: ' prefix>:"` i.e. `Part 1 — Target / Taxonomy / Pacing:`,
  then for each nested section of `part1` that has a LONG_TEXT item with text: `<section title> notes: <text>`
  (one line each, in order); if none: `(No notes recorded for this part.)`.
- `component`: `"<partNum> — <compTitle>:"`; if the component is not applicable: `• Not part of this
  lesson at the time of the visit.` (U+2022); then `Notes: <text>` when present, else, only when
  applicable, `(No notes recorded for this component.)`. The average is computed but not printed
  (prototype behavior).
- `belonging`: `"<partNum> — Conditions for Learning:"` (title of `part3` after ` · `), then
  `Notes: <text>` or `(No notes recorded for this part.)`.
- `summary`: `"<label>:"` (`Part 4: Walk Summary:`), then `Strengths: <text>` and/or
  `Growth areas: <text>`, or `(No summary notes recorded yet.)` when both empty.

Resolve `kind` to sections by data: `component` → the section whose `settings.partNumber ==
partNum` (fallback `sectionKey == compId`); `part1merged` → top-level section whose title starts
with `partNum` (`Part 1`); `belonging` → `Part 3`; `summary` → `Part 4`. Fail loudly (throw) when a
selectable part cannot be resolved; never silently skip.

## 6. Golden-vector strategy

Copy the visibility-vector pattern exactly (`tests/fixtures/visibility-vectors.json`,
`tests/node/visibility.test.mjs`, `tests/cfml/specs/VisibilityEngineTest.cfc`):

- `tests/fixtures/summary-vectors.json`: `{ format: "icfwalk-summary-vectors/1", source: "<golden
  checksum>", vectors: [ { name, state, walkId, expected: { summaryText, fileName, emails: {
  "<comma-joined includedPartKeys>": { subject, body } } } } ] }`.
- Generate `expected` with the JS formatter from the served model (`GET /api/instrument/current`
  through a maintenance fixture user, as `visibility.test.mjs` does), then **review every vector
  against the prototype** with `scripts/prototype-summary-oracle.mjs`: it launches Chromium on
  `file://source/current-prototype.html`, sets `current` to the prototype's state shape built from
  the vector's working state (mapping below), and prints `buildSummaryText()` and
  `generateEmailDraftFor(keys)`. Every difference between oracle output and vector output must be one
  of the documented deviations in section 14 (hidden Period excluded, content-area heading,
  trailing-colon labels, yes/no capitalization); anything else is a formatter bug.
- Prototype state mapping for the oracle: `meta.{date, observer, school, grade, content, period,
  classType, visitTiming, topic, tag}` hold option **labels** (`'Other'` + `meta.<code>_other` for
  Other text); `part1.{p1q1,p1q2,p1q3}` labels; `part1Sections.adopted.{pacing (code), ac1, ac2,
  notes}`, `part1Sections.targetTask.{tt1, tt2, notes}`; `components.s1..s7 = { applicable:
  true|false|null, ratings: ['4','','2', ...] (strings, one per question in order), notes }`;
  `belonging.{b1..b6, notes}`; `prekK|dualLang|macPrer|ignite|avid|esl|contentArea.{q1.., notes}` with
  `'yes'|'no'` codes; `summaryStrengths`, `summaryGrowth`; `email.checkpoints.summary = { inc: {key:
  bool}, drafted, to, subject, body }`.
- Required vectors (names are suggestions): `fully answered high school walk` (SUM-01: every part
  answered, Workshop yes with ratings, Academic Teaming yes, notes everywhere, averages including a
  half value such as 2.5 and a value such as 2.25), `unanswered items` (SUM-02: some ratings blank,
  Part 1 partially answered, no notes), `workshop model no with notes` (SUM-03), `dual language then
  hidden` (SUM-04: dual-language answers present while `classType` is General Education so the
  section is hidden), `period retained but hidden` (grade 3 with a Period value), `other school and
  other content with punctuation` (SUM-05: `Other` school text `Unlisted/Site?`, content Other
  `Art & Design`, date `2026-09-17`), `content area music` (heading decision 14.3), `markup in notes`
  (SEC-02: `<b>` and `&` pass through verbatim), `blank new walk` (defaults only), `email: part1 +
  one component + part3 + summary` (SUM-06), `email: nothing selected`, `email: no observer`
  (`[Your name]`), `email: component not applicable`.
- Both test suites assert byte equality of `summaryText`, `fileName`, and every `emails` entry.
  `WalkSummaryFormatterTest.cfc` also runs one vector through `WalkService.summary` against a real
  walk saved through `WalkService.save` (fixtures from `WalkServiceTest`) to prove the persisted
  path yields the same text as the pure formatter.

## 7. `GET /api/walks/{id}/summary`

- Route: `add("GET", "^/api/walks/([^/]+)/summary$", "walkController", "summary", { "anyPermission": variables.WALK_READ_PERMISSIONS })`
  placed with the other walk routes in `Router.init`. `GET /api/walks/{id}` still matches only the
  bare id (`$` anchored), so no ambiguity.
- Service: `authorizeWalk(principal, id, "read")` (403 for report-only/admin, 404 outside scope, 400
  malformed id, same as `open`), then load `row`, `dims`, `responses`, model via
  `renderModelFor(row.versionId)` (pinned version, WALK-11), evaluation, `formatter.summaryText`,
  `formatter.fileName(..., row.walkId)`. Voided walks: allowed for readers (history is retained and
  readable by id in Phase 4); the text is unchanged. Audit `WALK_SUMMARY_EXPORTED` with
  `{ status, versionId, bytes }` only. Log `walk.summary.exported` with walk id and byte count.
- Response: `200`, body = the text exactly (no BOM, `\n` line ends, no trailing newline),
  `Content-Type: text/plain; charset=utf-8`, headers `Content-Disposition: attachment;
  filename="<fileName>"` (ASCII-only by construction), `Cache-Control: no-store`,
  `X-Content-Type-Options: nosniff`, `X-Correlation-Id` (already added by the request context).
  Add `Content-Disposition` handling to the Responder text path only if `headers` are not already
  emitted there (they are: `send()` writes `result.headers` before the text branch).
- Filename (prototype `exportWalk`): `label = [display(grade), display(content), dateValue]
  .filter(Boolean).join("_") || walkId`; `fileName = "ICFWalk_" + label.replace(/[^a-z0-9_-]+/gi, "_")
  + ".txt"`. Note the prototype replaces **runs** of unsafe characters with one underscore and keeps
  case; `Unlisted/Site?` → `Unlisted_Site_`; a walk with nothing set →
  `ICFWalk_<WALKID>.txt`. The label uses the same displays as the summary (Other text, not "Other").
  SUM-05: only `[A-Za-z0-9_-]` survive, so `..`, `/`, `\`, and quotes cannot reach the header.
- Browser: un-hide `#export-btn` in `openWalk` for every walk the user can read (owners and
  read-only viewers), keep it hidden until the walk is loaded. On click: if `app.dirty` or a save is
  in flight, `await saveCurrent()`; if a conflict is open, do nothing but announce; then trigger the
  download by creating `<a href="<apiBase>/walks/<id>/summary" download>` and clicking it (the
  session cookie and, in tests, the dev identity header travel with the top-level GET). If the flush
  failed with a `NetworkError`, fall back to the JS formatter: `Blob` of `summaryText(...)` with
  `URL.createObjectURL`, same `fileName`, so the person still gets the text of what is on screen
  (SAVE-03 spirit; document that the fallback is browser-generated). Announce "Summary exported".
- Playwright verifies the download with `page.waitForEvent("download")`, reads
  `download.suggestedFilename()` and the saved file's text, and compares with the vector text of the
  same state and with `GET /api/walks/{id}/summary` fetched directly.

## 8. Part 4 email-draft composer

Rendered into the existing `email-slot` (un-hide it) from `item.settings.selectableParts`, in
`renderer.js`'s email branch (or a helper module it imports). Prototype `renderEmailCheckpoint`
transcribed (only the final "summary" checkpoint exists in the current prototype; cumulative
checkpoints per part are legacy and were not rebuilt):

- `<p class="email-q">` = the item prompt (`Would you like to email the teacher about today’s
  responses so far?`), an `id` used as the group label.
- One checkbox per selectable part, in settings order, labelled with `part.label`
  (`Part 1: Target / Taxonomy / Pacing`, `2.1: Complex Texts`, ..., `Part 3: Conditions for
  Learning`, `Part 4: Walk Summary`), inside a `role="group"` labelled by the prompt. Checking or
  unchecking writes `includedPartKeys` (order = settings order) and autosaves.
- Buttons `Draft email` (primary) and `Clear draft`. Draft: `emailDraft(model, state, evaluation,
  includedPartKeys)` → sets `subject`, `body`, `drafted = true`, shows the box. Clear: `drafted =
  false`, `subject = ""`, `body = ""`, hides the box (`to` and the checkboxes are kept, as in the
  prototype). Both autosave.
- Box (hidden until `drafted`): labelled `To (teacher’s email — optional)` text input with
  placeholder `teacher@u46.org`, `Subject` input, `Message` textarea (`min-height: 220px`), buttons
  `Update draft from checked boxes` (same as Draft), `Copy text`, `Open in email app` (primary), and
  the muted note `Editable — review and personalize before sending. Nothing is sent automatically.`
  Every input edit writes its field and autosaves.
- Copy text: `navigator.clipboard.writeText("Subject: " + subject + "\n\n" + body)`; on success the
  button reads `Copied!` for 1.4 s; on failure show an inline message (not `alert`) telling the person
  to select and copy manually (A11Y: `role="status"`).
- Open in email app: `window.location.href = "mailto:" + encodeURIComponent(to) + "?subject=" +
  encodeURIComponent(subject) + "&body=" + encodeURIComponent(body)`. Nothing else. No server call.
  (Playwright: intercept navigation or stub `window.location` assignment through
  `page.addInitScript`; assert the URL is percent-encoded and that no request left the page.)
- Persistence: the composer's state object is `{ includedPartKeys, drafted, to, subject, body }`.
  Write it with `setResponse(ctx.state, "email_workflow", { textValue: JSON.stringify(doc) })` then
  `commit(ctx)`, serializing keys in the canonical order `body, drafted, includedPartKeys, subject,
  to` so the string equals what the server returns after canonicalization (otherwise the Phase 4
  conflict panel would list a false "unsent edit" on every reload). Read it back in `refresh()`
  (parse `state.responses.email_workflow.textValue`, tolerate absence → defaults) and sync the
  checkboxes, inputs, and box visibility; this is what makes SUM-07 (reopen restores the draft) and the
  conflict reload work. `emailDraft` reads the observer/grade/content/date from the same state.
- Validation is already server-side (`validateEmailDraft`): unknown keys, non-string fields, or
  non-array `includedPartKeys` are 400 `INVALID_EMAIL_DRAFT`; keep the client from ever sending them.
  Size: `textValue` ≤ 20,000 characters (validator limit); show a message if the body exceeds it.
- Read-only walks (`!walk.canEdit`): `applyEditability` already disables `select, input, textarea,
  .pill`; add the composer's inputs and buttons to that selector list (`.email-slot button` too).
  Completed walks remain editable by their owner (Phase 4 policy), so drafting after completion is
  allowed and appends a `POST_COMPLETION_EDIT` revision like any edit.
- Non-reportable: nothing new is needed (`walk_response.text_value` of a non-reportable item).
  Phase 7 must exclude it; note it in the reporting brief later.

## 9. Database changes

None required. The email draft is `walk_response.text_value` of the `EMAIL_DRAFT_JSON` item
(`docs/DATA_CONTRACT.md` "Values by type"); the summary is derived on demand and never stored; the
filename is derived. Do not add a summary cache, a "last exported" column, or an email table. If a
future decision wants export history, `audit_event` (`WALK_SUMMARY_EXPORTED`) already records the
fact without content.

## 10. Security, privacy, and validation requirements

- Authorization: the summary route uses the same read policy and `authorizeWalk(read)` as opening a
  walk. Report-only and instrument-admin roles: 403 with no walk data; other schools: 404. No new
  permission. Never accept a version id, org unit, or item list from the request for the summary.
- CSRF: `GET /summary` is read-only (no CSRF, like `open`). Every composer change goes through
  `PUT /api/walks/{id}` (CSRF enforced by the Router). No new mutating route.
- Server-side validation: `validateEmailDraft` is already enforced; add tests that a `to` value with
  header-injection characters (`\r\n`, `bcc:`) is stored as text and never interpreted (the server
  never sends mail; `mailto` encoding on the client neutralizes it). Do not validate `to` as an email
  address (the prototype does not; it is optional free text) beyond the length limit.
- Output encoding: the text export is served as `text/plain` with `nosniff`; stored markup (`<b>`,
  `<script>`) appears verbatim as text (SEC-02). The composer renders through DOM construction with
  `textContent`/`value`, never `innerHTML` with content. The `mailto` URL is built only with
  `encodeURIComponent`.
- Privacy: the audit event and logs for export carry walk id, status, version, and byte count only.
  Never log the text, subject, body, or `to`. `AuditRepository` already strips `subject`/`body`
  keys; do not rely on it, do not pass them.
- No automatic send: no `cfmail`, no SMTP configuration, no server endpoint that takes a recipient.
  A test greps `src/` for `cfmail`/`mail(`/`smtp` and fails if found (the "no-automatic-send" gate).
- CSP unchanged. No inline scripts or styles for the composer (use classes in `icfwalk.css`).
- Filename: only `[A-Za-z0-9_-]` in the `Content-Disposition` value (section 7). Reject nothing;
  sanitize.
- Accessibility (A11Y-01/02/03): every composer control has a label; the checkbox set is a labelled
  group; the box appearing/disappearing is announced through the existing `announce()`; `Copied!`
  and failure messages use `role="status"`; axe runs on the composer state.

## 11. Targeted unit and integration tests to write

CFML (`tests/cfml/specs/`):

1. `WalkSummaryFormatterTest.cfc`
   - `testMatchesTheSharedSummaryVectorsExactly`: every vector's `summaryText`, `fileName`, and email
     entries byte-equal (use `compare(a, b) == 0`, not `==`).
   - `testComponentAverageUsesAnsweredScoresOnly`: 4 and 2 answered, one blank → `3.0`; none → `n/a`;
     NOT_APPLICABLE component → not-part line, no average; rounding cases 2.25/2.5/3.05.
   - `testHiddenSectionsAndHiddenPeriodAreExcluded` (SUM-04, 14.2).
   - `testFileNameSanitization` (SUM-05): `Unlisted/Site?` + `Art & Design` + date, `../../etc`,
     empty label → walk id, unicode letters replaced.
   - `testEmailDraftPartsAndTemplates` (SUM-06): selections in and out of order, none selected,
     missing observer, not-applicable component.
   - `testServiceSummaryMatchesFormatterForAPersistedWalk`: save a vector state through
     `WalkService.save`, then `WalkService.summary` equals the vector text; report-only user → 403;
     other-school user → 404; audit `WALK_SUMMARY_EXPORTED` recorded with no text; voided walk still
     exports.
2. `WalkServiceTest.cfc` (extend): `testEmailDraftRoundTripAndSchema` (SUM-07/09): save a draft →
   reopen returns canonical JSON; clear (`drafted:false, subject:"", body:""`) leaves other responses
   untouched; `to` with `\r\nbcc:` stored verbatim; extra key → 400 `INVALID_EMAIL_DRAFT`; email
   response never counted in `completionIssues`.

Node (`tests/node/`):

3. `summary.test.mjs`: JS formatter reproduces every vector against the served model; filename
   cases; `emailDraft` with each `kind`; `componentAverage` parity values.
4. `walks.test.mjs` (extend): `GET /api/walks/{id}/summary` → 200, `content-type` matches
   `/^text\/plain;\s*charset=utf-8$/i`, `content-disposition` matches
   `/^attachment; filename="ICFWalk_[A-Za-z0-9_-]+\.txt"$/`, `x-content-type-options: nosniff`,
   `cache-control: no-store`; body equals the vector text for the saved state; 401 without identity;
   403 report-only/admin; 404 other school; 400 malformed id; markup in notes appears verbatim in the
   text; hidden Period absent.
5. `package.test.mjs` or a new `no-mail.test.mjs`: `src/` contains no `cfmail`, `mail(`, `smtp`
   (case-insensitive), and `app/assets/js` contains no `fetch(` to a mail route.

## 12. Playwright tests required

Add to `tests/node/browser-persistence.test.mjs` or a new `browser-email.test.mjs` (same fixture
pattern, serial, cleanup by tag):

1. **Export download (SUM-01/02/05)**: answer a walk (use the "fully answered" vector's state through
   the UI or by saving it through the API and reopening), click `#export-btn`,
   `page.waitForEvent("download")`, assert `suggestedFilename()` equals the vector `fileName` and
   the file text equals the vector `summaryText`; then with unsaved edits (type in notes and click
   export within 700 ms) assert the download reflects the edit (flush happened) and status is
   `All changes saved`.
2. **Export with markup (SEC-02)**: notes containing `<script>` appear verbatim in the downloaded
   text; no page error.
3. **Read-only viewer export**: second fixture user with `SCHOOL_WALK_REPORT` on the same school
   opens the walk read-only and can export; a `SCHOOL_REPORT_ONLY` user gets 403 on the route (API
   assertion) and no `#export-btn` (the shell is 403 for them already; assert via API only).
4. **Composer (SUM-06)**: open Part 4, check `Part 1`, `2.3: Workshop Model`, `Part 3`, `Part 4`,
   click `Draft email`; assert subject and body equal the vector email for those keys; box visible;
   only checked parts appear.
5. **Edit and reopen (SUM-07)**: edit To/Subject/Body, wait `All changes saved`, reload the page,
   reopen the walk: fields restored exactly; `GET /api/walks/{id}` shows the canonical JSON in
   `state.responses.email_workflow.textValue`; the Phase 4 conflict panel does not appear on reopen.
6. **Copy and mailto (SUM-08)**: grant clipboard permission (`context.grantPermissions(["clipboard-read",
   "clipboard-write"])`), click `Copy text`, read the clipboard: `Subject: ...\n\n<body>`; button
   shows `Copied!`. Stub `window.location` navigation with `page.addInitScript` (or listen for the
   `mailto:` navigation request and abort it) and assert the URL starts with `mailto:` and is
   percent-encoded; assert no `POST`/`PUT` to any mail route fired (record all requests).
7. **Clear (SUM-09)**: click `Clear draft`; box hidden; API shows `drafted:false`, empty subject/body,
   `to` and `includedPartKeys` preserved, every other response unchanged (compare `state.responses`
   before/after minus `email_workflow`).
8. **A11Y-03**: axe on the composer open state and on the Part 4 accordion with a drafted email; no
   serious/critical violations. Screenshots `email-composer-desktop.png` and `email-composer-phone.png`
   (375 px) into `docs/evidence/screenshots/`.
9. **Keyboard (A11Y-01)**: tab to a part checkbox, Space toggles it; Enter on `Draft email` drafts.

## 13. Existing tests that must remain passing

`npm test` at commit `0df22bc`: 68/68 Node tests, CFML 106/106. In particular:

- `tests/node/browser.test.mjs` (11) and `browser-persistence.test.mjs` (7): the Part 4 accordion
  gains controls; nothing there selects `#export-btn` or the email slot, but `A11Y-03` runs axe on the
  expanded editor, so the composer must be accessible even when hidden (the slot is `hidden` until
  Part 4 renders it; keep `hidden` semantics or render the composer only when the box is drafted).
- `tests/node/shell.test.mjs`: asserts the shell contains no instrument text. Do not add prompt
  text, part labels, or template sentences to `shell.html`; they come from the model at run time
  (template sentences live in `summary.js`, which the shell test does not scan, but keep them out of
  HTML anyway).
- `tests/node/visibility.test.mjs` + `VisibilityEngineTest`: untouched engines.
- `WalkServiceTest` (18), `walks.test.mjs` (9): the `email_workflow` round trip already exists there
  (`testSaveRoundTrip...`, canonical string
  `{"body":"B","drafted":true,"includedPartKeys":["part1"],"subject":"S","to":""}`); keep that
  canonical form.
- `schema-contract.test.mjs`: lists the CFML files whose SQL is checked; add
  `src/walks/WalkSummaryFormatter.cfc` only if it contains SQL (it must not).
- `package.test.mjs` / `validate-handoff.mjs`: supplied files unchanged; new files under `src/`,
  `app/`, `tests/`, `scripts/` are reported as build files (informational). If you must touch a
  supplied file (do not), refresh the manifest with `scripts/refresh-manifest.mjs`.
- Run the full suite once at the end; use `?filter=WalkSummaryFormatter`, `?filter=WalkService`,
  `node --test tests/node/summary.test.mjs`, `npm run test:walks`, and the single browser file while
  developing. Restart Lucee after editing any `.cfc` (`tools/runtime/lucee-down.sh && lucee-up.sh`);
  `?reinit=1` does not recompile.

## 14. Conflicts and decisions (resolved from precedence unless marked OPEN)

1. **Conditional section order in the export.** Prototype export order: PreK–K, Dual Language,
   MAC / PREP, Ignite, AVID, **Content-Area, ESL**. JSON section `displayOrder`: ..., ESL (70),
   Content-Area (80); the Phase 3 renderer shows JSON order on screen. The JSON itself sets
   `behavior.export.preservePrototypeSectionOrder = true`, so for the export the JSON delegates order
   to the prototype. **Decision:** the export prints the conditional cards in snapshot order except
   that the card whose SHOW rule is sourced from the `content` dimension prints before the cards whose
   rules are sourced from `classType` that follow it (today: Content-Area before ESL). Implement it as
   one documented presentation rule keyed on the rule source dimension, applied only in the formatters
   (the renderer keeps JSON order), and record it in BUILD_STATUS next to Phase 3 decision 3. OPEN for
   content owners: change `displayOrder` in the next DRAFT so the rule becomes a no-op.
2. **Hidden Period (and other hidden dimensions).** Prototype clears Period, so its export never
   shows a stale value; Phase 4 retains it as `HIDDEN` (`docs/DATA_CONTRACT.md`, `docs/OPEN_DECISIONS.md`).
   The contract says "exclude from reports and export while hidden". **Decision:** print a dimension
   only when `dimensionStates[code] == "ANSWERED"`. Same for hidden sections (SUM-04).
3. **Content-area heading.** Prototype prints `<CONTENT> CLASSROOM` (e.g. `MUSIC CLASSROOM`); the JSON
   title is `Content-Area Look-Fors`, and Phase 3 recorded the same conflict for the on-screen card
   (BUILD_STATUS Phase 3 decision 3: the title lives in the contract; a `titleTemplate` setting would
   be needed). **Decision:** the export heading is the section title uppercased
   (`CONTENT-AREA LOOK-FORS`), consistent with the card, and the vector for the Music case records
   this as a documented deviation from the prototype. OPEN for content owners together with the card
   heading. (If content owners choose the dynamic heading, add `settings.titleTemplate` in a new DRAFT
   and support `{contentLabel}` in both the renderer and both formatters; not now.)
4. **Trailing colon in a placement label.** The dimension label `Visit occurred at the:` makes the
   prototype print `Visit occurred at the:: Beginning`. **Decision:** strip one trailing colon from
   a label before appending `: ` (documented deviation; the double colon is a prototype defect).
5. **Yes/No answers.** The prototype stores `'yes'`/`'no'` and prints the raw code (`[yes]`) for
   PreK–K, Dual Language, MAC/PREP, Ignite, AVID, ESL, and content-area items; it prints the option
   **label** for pacing (`[ON pace]`) and raw values that equal labels for `p1q1..p1q3`. **Decision:**
   print the option label for every non-scored choice (`[Yes]`, `[ON pace]`, `[Partial]`); scored
   choices print `<code>/<max>`. The only visible difference from the prototype is `Yes`/`No`
   capitalization, recorded as a deviation (labels are what the person sees on the pills).
6. **Part 4 export labels.** Prototype prints `Strengths:` and `Growth areas:`; the item prompts are
   `Overall strengths observed` and `Priority area(s) for growth`; no JSON setting carries an export
   label. **Decision:** a presentation map by item key (`PART4_LABELS`) in both formatters, the same
   device as `LIST_CARD` (Phase 3 decision 5). OPEN for a future DRAFT: an `exportLabel` item setting
   would remove the map.
7. **`part1Notes`.** The prototype export prints `Notes:` for `w.part1Notes`, but the prototype has
   no control that sets it (legacy field, always empty). The JSON has no Part 1 level notes item.
   **Decision:** nothing to print; do not invent an item.
8. **Part 1 sub-section headings and the pacing line.** Prototype: `ADOPTED CURRICULUM`, then
   `- Pacing:  [ON pace]` (prompt + colon + two spaces), then scored questions `- <prompt>  [n/5]`,
   then `TARGET/TASK ALIGNMENT`. **Decision:** reproduce exactly; the pacing line format applies to
   any non-scored choice item inside a Part 1 child section (data rule: non-scored item in a section
   whose siblings are scored → `<prompt>:  [<label>]`).
9. **Email date text.** The prototype inserts the raw `meta.date` (`YYYY-MM-DD` from the date input).
   **Decision:** use `dateValue` as stored (`YYYY-MM-DD`); no locale formatting.
10. **Email checkpoints.** Prototype state has `email.checkpoints.<key>`; the contract stores one
    document `{ includedPartKeys, drafted, to, subject, body }` (Phase 4 validator). Only the final
    checkpoint exists in the current prototype. **Decision:** one composer, one document; no
    per-part checkpoints (SOURCE_ALIGNMENT: "one Part 4 composer that can include any prior part").
11. **Component average in the email.** Computed by the prototype but never printed. **Decision:**
    do not print it (prototype text is authoritative); keep the function shared for the export.
12. **Export of a voided walk.** Not addressed by any source. **Decision:** readable by id in Phase
    4, so exportable; no banner in the text (the text has no status line in the prototype). OPEN:
    a status line could be added later if owners want it.
13. **Whose text is exported.** The prototype exports the in-memory walk. **Decision:** the button
    flushes autosave and downloads the server text (authoritative, authorized, audited); the JS
    formatter is the fallback when the flush fails and the source of the email draft. Both are
    proven identical by vectors, so the person cannot tell the difference.
14. **Trailing newline.** The prototype joins lines with `\n` and adds none at the end. Keep that.
15. **Line endings and BOM.** `\n` only, UTF-8 without BOM (prototype `Blob` behavior).
16. **Copy failure.** Prototype uses `alert`; Phase 3 replaced `confirm` with inline dialogs for
    WCAG. **Decision:** inline `role="status"` message, same wording.

## 15. Ordered implementation checklist

1. Start the runtime (Docker SQL Server, Lucee, seed) per `docs/LOCAL_SETUP.md`; confirm
   `npm run test:walks` passes before changing anything (baseline).
2. Write `app/assets/js/summary.js` first (pure functions, section 5), driven by the served model;
   write `scripts/prototype-summary-oracle.mjs`; produce `tests/fixtures/summary-vectors.json` with
   `scripts/generate-summary-vectors.mjs` (fixture user through the maintenance endpoints, served
   model, JS formatter, cleanup by tag; the Phase 4 visibility vectors were generated the same way),
   then diff each vector against the oracle and confirm every difference is in section 14.
3. Write `tests/node/summary.test.mjs`; run it.
4. Write `src/walks/WalkSummaryFormatter.cfc` (same structure and names; `compare()` for every code
   equality; `numberFormat`/BigDecimal rounding proven against the vectors); wire it in
   `Bootstrap.cfc` (`c["walkSummaryFormatter"]`, injected into `WalkService`); write
   `WalkSummaryFormatterTest.cfc`; restart Lucee; run `?filter=WalkSummaryFormatter` until byte-equal.
5. Add `WalkService.summary`, `WalkController.summary`, the route; extend `walks.test.mjs`; run
   `npm run test:walks`.
6. Wire `#export-btn` in `app.js` (flush, download, fallback, announce); read-only visibility.
7. Build the composer (section 8) in the email slot; state sync in `refresh()`; canonical JSON
   serialization; disable in read-only mode; CSS in `icfwalk.css`.
8. Extend `WalkServiceTest.cfc` with the email round-trip/schema cases; run `?filter=WalkService`.
9. Write the Playwright cases (section 12); run that file alone until green; capture screenshots.
10. Add the no-automatic-send grep test.
11. Run `npm test` once; save `docs/evidence/phase5-npm-test.txt`.
12. Update `docs/ENDPOINTS.md` (summary route), `docs/ARCHITECTURE.md` (Phase 5 section + "What
    Phase 6 builds on"), `docs/DATA_CONTRACT.md` (export decisions appendix), `docs/LOCAL_SETUP.md`
    (new test commands), `docs/ACCEPTANCE_TRACKING.md` (SUM-01..09, SEC-02/05, A11Y rows),
    `BUILD_STATUS.md` (Phase 5 section in the same format as Phase 4: work, files, API changes,
    tests/results, IDs, decisions, CF2023 items, blockers, gate, Phase 6 starting point),
    `package.json` scripts (`test:summary`, browser file list).
13. Commit on the designated branch and push. Stop; do not start Phase 6.

## 16. Phase 5 completion gate

| Gate item | Proof |
| --- | --- |
| Summary golden-file tests pass | `WalkSummaryFormatterTest` and `summary.test.mjs` byte-equal on every vector, including the persisted-walk path through `WalkService.summary` and the HTTP body of `GET /api/walks/{id}/summary` |
| No-automatic-send tests pass | Grep test (no `cfmail`/SMTP), Playwright SUM-08 (mailto only, no mail request), `walks.test.mjs` (no mail route exists: any `POST /api/walks/{id}/email` is 404) |
| SUM-01..09 PASS in `docs/ACCEPTANCE_TRACKING.md` with evidence | Tests above plus screenshots |
| Phase 0-4 suites still green | `npm test` 68 + new cases, CFML 106 + new cases, 0 failed, 0 skipped |
| Documentation and BUILD_STATUS updated, committed, pushed | Section 15 step 12-13 |

## 17. Fresh session instructions

Read, in this order, and nothing else first:

1. This brief (you are here).
2. `BUILD_STATUS.md` from the heading "## Phase 4: walk persistence and autosave" to the end (about
   120 lines): environment, runtime commands, decisions, and the Phase 5 starting point.
3. `docs/ACCEPTANCE_TESTS.md` rows SUM-01..09 (one table).
4. `source/current-prototype.html` lines 1359-1549 and 2064-2213 only, to confirm the wording
   transcribed in sections 5, 7, and 8 (do not read the rest of the prototype; Phases 3-4 already
   reproduced it).
5. `src/walks/WalkService.cfc` `open`/`instrumentFor`/`loadDto`/`stateOf` and
   `src/walks/WalkPayloadValidator.cfc` `validateEmailDraft`; `app/assets/js/app.js` `openWalk`,
   `saveCurrent`, `applyEditability`; `app/assets/js/renderer.js` lines 52-125 and 318-345;
   `tests/node/visibility.test.mjs` (vector pattern) and `tests/cfml/specs/VisibilityEngineTest.cfc`
   lines 1-40.

Do not reread: `CLAUDE_FABLE_MASTER_PROMPT.md` beyond the precedence list (already applied here),
`README.md`, `docs/SOURCE_ALIGNMENT.md`, `docs/PRODUCT_SPEC.md` (its two Phase 5 bullets are quoted
in section 7/8), the Phase 0-3 parts of `BUILD_STATUS.md`, `docs/ARCHITECTURE.md` before the Phase
4 section, any `src/instrument/*`, `src/identity/*`, `src/authorization/*`, `database/*`,
`reference/*`, `config/*.xlsx`, and the Phase 4 test files beyond the helpers named above.

Environment: `.env` and `.runtime/` are git-ignored and must be recreated in a fresh container
(`docs/LOCAL_SETUP.md` "Clean install"; the Phase 4 session needed `dockerd` started manually,
`npm install`, `tools/runtime/mssql-up.sh`, `node scripts/db/apply-schema.mjs`, `tools/runtime/lucee-up.sh`,
`node scripts/seed-instrument.mjs`). Lucee does not recompile edited `.cfc` files: restart it.
Adobe ColdFusion 2023 is not available; record CF2023 verification items as Phase 4 did.

Work on the designated branch from commit `0df22bc`; execute only Phase 5; stop at the gate.
