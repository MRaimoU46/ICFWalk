# Phase 6 administration audit corrections: red before green

Every regression below was written first and run against the audited candidate before any
production change was made to what it tests. "The candidate" is
`2a3f2ecb4f070401cba00518c0db8a2de823a29d` (the tip of `claude/icfwalk-phase-6-admin-publish` that
the audit reviewed), and a red run means: the new or changed test files on disk, and `src/` and
`app/` exactly as in that commit (`git stash push -- src app` before the run, `git stash pop`
after; for the two browser runs noted below only `app/assets/js/workbook.js` was reverted, with
`git show 2a3f2ec:app/assets/js/workbook.js`, because `admin.js` was still the candidate's there).
Nothing was probed in production code: no temporary source edit was made, and none remains.

Environment for every run: Lucee 6.2.8.20 under jetty-runner 9.4.58, restarted after every change to
`src/` or `tests/cfml/` (Lucee compiles components once); SQL Server 2022 (16.0.4295.3 Developer) in
Docker; Node 22.22.2; Playwright 1.56.1 with Chromium 141.0.7390.37. CFML specs were run through
`POST /index.cfm/api/maintenance/tests/run?filter=<Spec>` with the maintenance token, Node files with
`node --test`. Adobe ColdFusion 2023 and SQL Server 2016 were not available and were not run.

Each entry gives the failing checks as printed (trimmed to the assertion), the cause, and the
correction. The green side is the same checks passing on the corrected tree, recorded in
`BUILD_STATUS.md` and, authoritatively, in the exact-commit gate transcript that follows the code
commit.

## P6A-04 -- malformed workbook XML escaped as a JavaScript exception

### Red: `tests/node/workbook.test.mjs` (4 new cases), candidate `workbook.js`

```
not ok 1 - P6A-04: a numeric character reference outside Unicode is a structured XML problem
  error: 'readWorkbook threw RangeError: Invalid code point 999999999 -- a malformed workbook must be a structured problem, not an exception'
not ok 2 - P6A-04: surrogate and XML-forbidden character references are structured XML problems
  error: the workbook is refused
    expected: false
    actual: true
not ok 3 - P6A-04: a malformed cell or row reference is a structured workbook problem
  error: "readWorkbook threw TypeError: Cannot read properties of null (reading '0') -- a malformed workbook must be a structured problem, not an exception"
not ok 4 - P6A-04: any other shape the reader does not expect is a structured problem, not an exception
  error: "readWorkbook threw TypeError: Cannot read properties of undefined (reading 'toLowerCase') -- a malformed workbook must be a structured problem, not an exception"
# pass 0
# fail 4
```

Case 2 is red a different way on purpose: `&#xD800;`, `&#x1;`, `&#xFFFE;` and the rest did not throw
at all -- `String.fromCodePoint` accepted them -- so a workbook carrying a lone surrogate or a
forbidden control character was **accepted** (`ok: true`).

### Red: `tests/node/browser-admin.test.mjs` "P6A-04 (browser)" (2 new cases), candidate `workbook.js` and `admin.js`

```
not ok 1 - P6A-04 (browser): a workbook the reader rejects sends nothing and leaves the page usable
  error: 'an exception escaped the page instead: Invalid code point 999999999'
not ok 2 - P6A-04 (browser): a file the browser cannot read is reported in the page's error flow and leaves the page usable
  error: 'an exception escaped the page instead: The requested file could not be read.'
```

The first case was also run with the corrected `workbook.js` and the candidate `admin.js`: it
passed, because the reader no longer throws. That is why the second case exists: a file read that
rejects (simulated `NotReadableError`) exercises the page's own guarded flow independently of the
reader, and it escaped from the candidate's submit handler as an unhandled rejection.

**Cause.** `decodeEntities` passed any finite numeric reference to `String.fromCodePoint`;
`sheetGrid` dereferenced `/^[A-Z]+/i.exec(ref)[0]` without checking the match; a `<sheet>` without a
name reached `name.toLowerCase()`; `readWorkbook` converted only `WorkbookError`; and
`onImport` read the file and parsed it before entering `guarded`.
**Correction.** XML `Char` validation of every numeric reference (`XML_MALFORMED`); validated row and
cell references (`CELL_REFERENCE_INVALID`, with the sheet); `readWorkbook` never throws (anything
unexpected is `WORKBOOK_UNREADABLE`); `admin.js` reads and parses inside `guarded`.

## P6A-01 -- bodies were acquired and parsed before authentication, CSRF and the size limit

### Red: `tests/node/admin-instrument.test.mjs` (5 new P6A-01 cases), candidate router

Run with the final committed version of the file (its raw-socket `rawRequest` helper; see the note at
the end of this section).

```
not ok 3 - P6A-01: an unauthenticated import is answered 401 without its body being read, however large or malformed
  expected: 401   actual: 400   {"error":{"code":"INVALID_JSON_BODY", ...}}
not ok 4 - P6A-01: an import with a missing or wrong CSRF token is answered 403 without its body being read
  expected: 403   actual: 400   {"error":{"code":"INVALID_JSON_BODY", ...}}
not ok 5 - P6A-01: an authorized import over 5,000,000 bytes is 413 DOCUMENT_TOO_LARGE before it is parsed, malformed or not
  expected: 413   actual: 400   {"error":{"code":"INVALID_JSON_BODY", ...}}
not ok 6 - P6A-01: a chunked import is measured in UTF-8 bytes, so multibyte text cannot slip under the limit
  expected: 413   actual: 400   {"error":{"code":"DOCUMENT_REQUIRED", ...}}
not ok 7 - P6A-01: a maintenance route without its token is hidden without its body being read
  error: 'no answer within 15000 ms: the server was waiting for the rest of the body'
```

Case 6 shows the chunked defect on Lucee concretely: the candidate's `getHttpRequestData(true)`
returned **no content at all** for a chunked body, so 5.1 MB of UTF-8 text reached the controller as
an empty body, passed the character-count limit, and was answered `DOCUMENT_REQUIRED` rather than
413. Case 7 is the partial-body technique: the request declares 50,000,000 bytes and sends ten; the
candidate read the body before its token guard and waited for bytes that never came.

The same technique against the unauthenticated import, run separately for this record (an ad hoc
probe, not committed):

```
anonymous, Content-Length 50000000, 10 bytes sent: no answer within 15000 ms (server waiting for the body)
anonymous, chunked, 10 bytes sent:                 401 after 10 ms
```

The chunked line is not a pass for the candidate: it answered at once only because it never read a
chunked body (case 6).

### Red: `tests/cfml/specs/RouterBodyOrderTest.cfc` (12), candidate router

```
FAILED  RouterBodyOrderTest.<every case>
        key [JSONBODYPARSER] doesn't exist
        @ tests/cfml/specs/RouterBodyOrderTest.cfc:202
TOTALS passed=0 failed=12 skipped=0
```

This red is **structural, not behavioral**, and is recorded as such: the candidate had no
interception seam -- `Router.dispatch` read `cgi` and `getHttpRequestData(true)` directly and parsed
inline -- so the spec cannot even construct its spy. The behavioral reds for the same defects are the
HTTP cases above. The spec's value is on the corrected tree, where it observes zero body reads and
zero parses for every refused request instead of inferring them from a status.

### Red: `tests/node/browser-admin.test.mjs` "P6A-01 (browser)", candidate `admin.js`

```
not ok 3 - P6A-01 (browser): a file over the workbook or document limit is refused before the whole file is read
  error: 'huge.json: only a header was read before the size was checked: [{"method":"arrayBuffer","size":5000001}]'
```

**Cause.** `Router.buildRequest` called `getHttpRequestData(true)` and `deserializeJSON` before
`enforcePolicy`; the 5,000,000-byte check lived in `AdminInstrumentController.importDocument`, after
the parse; its fallback measured `len(content)` (characters); `onImport` read the whole file first.
**Correction.** `Router.handle`: metadata only, then the policy's pre-body checks
(`MaintenanceGuard.precheck`, or authentication, CSRF and the permission), then a bounded byte read
under the route's `maxBodyBytes` (413 from a declared length without reading), then
`JsonBodyParser`, then the body-dependent permission. *(Erratum, P6A-R01: at this round the bound
was loose -- each read asked for 65,536 bytes, so up to 65,536 bytes past the limit could be read
before the refusal. Made exact by the re-audit's correction; see
`phase6-admin-read-bound-red-before-fix.md`.)* `HttpRequestSource` reads the servlet
container's stream beneath Lucee's wrapper. `admin.js` reads 8 bytes, checks `file.size`, then reads.

**Found while making it green.** The first corrected build still hung on a never-finished chunked
body over the limit. A thread dump showed why:
`HTTPServletRequestWrap.getInputStream -> storeEL -> IOUtil.copy -> HttpInput.blockForContent` --
Lucee's request wrapper copies the entire body into memory on first access, so no bounded read is
possible through it. `HttpRequestSource` now unwraps it (`getOriginalRequest()`) and reads Jetty's
stream; the same request is then answered 413 in about 130 ms.

**Note on the helper.** After the first red capture, `rawRequest` in the test file was changed from
`node:http` to a raw socket: once the corrected server answered 413 from the declared length and
closed, `node:http` reported the client's refused write (`EPIPE`) instead of the server's answer. The
red above was captured again with the final helper; the results are the same as the first capture
(every expected/actual pair identical).

## P6A-02 -- DRAFT re-import had no server-side concurrency control; export read twice

### Red: `tests/cfml/specs/DraftReplacementConcurrencyTest.cfc` (6), candidate services

```
FAILED  testAReplacementNamingAnOlderChecksumCannotOverwriteTheNewerDraft
        Expected an exception of type [ICFWalk.Conflict] but nothing was thrown.
FAILED  testACreateOnlyImportQueuedBehindTheCreationOfItsLabelIsRefused
        the uploader was refused, not silently re-imported Expected exactly [DRAFT_REPLACEMENT_REQUIRED] (26 chars) but got [imported] (8 chars)
FAILED  testAReplacementQueuedBehindAnEditMadeAfterItWasConfirmedIsRefused
        the confirmed replacement was refused Expected exactly [DRAFT_CHANGED] (13 chars) but got [imported] (8 chars)
FAILED  testACorrectReplacementSucceedsOnceAndIsAuditedAgainstTheExactPriorVersion
        key [REPLACEDVERSIONID] doesn't exist
FAILED  testAReplacementThatNamesAnythingElseIsRefusedAndWritesNothing
        Expected an exception of type [ICFWalk.Conflict] but nothing was thrown.
FAILED  testAnExportNeverPairsOneStatesMetadataWithAnotherStatesDocument
        the document is exactly the state the metadata names Expected exactly [7cc20178...6a] (64 chars) but got [27d20757...64] (64 chars)
TOTALS passed=0 failed=6 skipped=0
```

The two queued cases failed on the outcome: the competing import, released after the holder
committed, **overwrote** the newer DRAFT ("imported"). The candidate's `importDocument` took two
arguments, so the spec's replacement token was simply ignored -- the red is behavioral, not a
missing method. The export case paired checksum C1 (the metadata) with a document that compiles to
C2 (the edit forced between its two reads).

### Red: `tests/node/admin-instrument.test.mjs`, candidate server

```
not ok 1 - ADM-01: an administrator imports a document and gets the validation summary; re-import answers 200
  expected: 409   actual: 200   ("created": false -- the unasked re-import replaced the DRAFT)
not ok 2 - P6A-02: an import replaces a DRAFT only when it names that DRAFT's exact id and checksum
  expected: 409   actual: 400   {"error":{"code":"IMPORT_BODY_INVALID","message":"'replace' is not accepted by this endpoint."}}
```

### Red: `tests/node/browser-admin.test.mjs` "P6A-02 (browser)" (2 new cases), candidate server and `admin.js`

```
not ok 1 - P6A-02 (browser): two sessions read a draft at C1, B saves C2, and A's upload from the stale page cannot overwrite C2
  error: nothing was reported as imported
    1 !== 0          (A's page reported the upload as imported: C2 was overwritten)
not ok 2 - P6A-02 (browser): a label created by someone else after the page loaded is never silently replaced
  error: locator.waitFor: Timeout 20000ms exceeded.
    waiting for getByRole('alertdialog', { name: 'Replace draft bradm-...-late-2?' })
                     (no question was asked: the other session's draft was replaced silently)
```

**Cause.** The server received only `{ document }` and re-imported whatever DRAFT held the label; the
only protection was the page comparing the workbook with a list it loaded earlier. The export read
the row for its metadata and then the snapshot again.
**Correction.** Create-only unless `replace: { versionId, expectedChecksum }`, decided in
`writeNormalizedDraft` on the locked row (409 `DRAFT_REPLACEMENT_REQUIRED` / `DRAFT_CHANGED`); the
replacement audit names `replacedVersionId` and `previousChecksum`; the page sends the token and
handles both 409s; `SnapshotService.loadVersion` gives the export one read.

## P6A-03 -- a discard naming V1 could delete V2

### Red: `tests/cfml/specs/DiscardIdentityBarrierTest.cfc`, candidate `discardDraftById`

```
FAILED  DiscardIdentityBarrierTest.testADiscardNamingV1NeverDeletesTheV2ThatTookItsLabel
        the discard reports the version its path named Expected exactly [22ECD3D6-3CBF-47E6-BD2D-C4AB9F592AEE] (36 chars)
        but got [FC0B3E4F-BE38-48AB-A38A-84375C1C92F5] (36 chars)
PASSED  DiscardIdentityBarrierTest.testTheIdAddressedDiscardRefusesExactlyAsBefore
TOTALS passed=1 failed=1 skipped=0
```

The request named V1 (`22ECD3D6...`). While it was paused after its unlocked read, the barrier's
other side discarded V1 and created V2 under the same label; the request then resolved the label and
deleted and reported V2 (`FC0B3E4F...`). The second case is a preservation check (the refusal codes
of the id-addressed path) and passes on both trees by design.

**Cause.** `discardDraftById` read the row without a lock and delegated to the label-addressed
`discardDraft`. **Correction.** One transaction on the path id: lock it, derive everything from the
locked row, delete that id (exactly one version row asserted), audit and return that id.

## What was not done

No production source was temporarily edited to produce any red; the reds come from the candidate's
own files. The Lucee thread dump above was taken of the development server while a probe request was
blocked; it is not part of any test. Every temporary stash was popped, and `git status` after each
restore listed only the intended working changes.
