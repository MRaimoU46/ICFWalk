# Phase 7 red-before-fix record

Each Phase 7 guarantee that a defect could quietly break was broken on purpose, one at a time, in a
temporary copy of `src/reports/ReportService.cfc`, and the specs that exist to catch it were run
against the broken copy. Every mutation turned the intended tests red. The original file was then
restored and checked byte for byte against a SHA-256 taken before the first mutation
(`sha256sum -c` reported `src/reports/ReportService.cfc: OK`), and the same specs were run green
again. None of these mutations was ever committed.

Environment: Lucee 6.2.8.20 (the repository's verification runtime) on SQL Server 2022
(16.0.4295.3), development configuration, after a Lucee restart for each mutation so the mutated
component was the one compiled. Adobe ColdFusion 2023 was not available (see `BUILD_STATUS.md`).

Command for each run: `GET /api/maintenance/tests/run?filter=<Spec>` with the maintenance token,
exactly what `tests/node/cfml-suite.test.mjs` calls.

## R1 -- the report does not verify its population (coherence)

Mutation: accept the first attempt whatever `verifyPopulation()` found.

```diff
-			if (outcome.moved == 0) {
+			if (true) {
```

`ReportCoherenceTest` against the mutation. It was run twice: first with the retry-count assertions
ahead of the content assertions, where the straddle case failed with `the population was selected
again Expected [2] but got [1]`; then, after reordering the test so the content check runs first,
with this output:

```
{"failed":3,"passed":1,"skipped":0}
   ReportCoherenceTest testAReportThatNeverSeesAStableStateIsRefused failed Expected an exception of type [ICFWalk.Conflict] but nothing was thrown.
   ReportCoherenceTest testAReportThatStraddlesACommittedSaveIsRecomputedCoherently failed the report mixes two committed states of one walk: grade 7 = 1, grade 8 = 0, rating 1 = 0, rating 5 = 1
   ReportCoherenceTest testAWalkVoidedMidReportLeavesThePopulationCleanly failed Expected [2] but got [1].
```

The second line is the defect itself: the walk was committed only as (Grade 7, rating 1) and later
as (Grade 8, rating 5), and the unverified report counted Grade 7 beside rating 5 -- a state the
walk never held. The fourth case (`testAStablePopulationIsReportedOnTheFirstAttempt`) passes
against the mutation, as it should: with nothing moving there is nothing to detect.

Restored: `{"failed":0,"passed":4,"skipped":0}`.

## R2 -- dimension visibility is ignored (hidden retained values)

Mutation: treat every reportable dimension as always visible instead of asking the engine.

```diff
-		var visibility = visibilityFor(code, arguments.ancestry, arguments.model, arguments.index);
+		var visibility = { "mode": "ALWAYS" };
```

`ReportServiceTest`:

```
{"failed":2,"passed":13,"skipped":0}
   ReportServiceTest testRpt07EveryFilterNarrowsThePopulationWithinScope failed period: the hidden retained value does not match {"dim_period":"first"} Expected [1] but got [2].
   ReportServiceTest testTheCatalogIsDerivedFromTheVersionAndItsEngine failed Expected exactly [TUPLES] (6 chars) but got [ALWAYS] ...
```

A Period value retained while hidden (grade corrected to 5 under `RETAIN_HIDDEN`) was matched by
the Period filter.

## R3 -- distributions count every stored option, whatever the state

Mutation: drop the `ANSWERED` condition from the option distribution.

```diff
-			if (row.state == "ANSWERED" && len(row.optionId)) c.options[...]
+			if (len(row.optionId)) c.options[...]
```

`ReportServiceTest`:

```
{"failed":2,"passed":13,"skipped":0}
   ReportServiceTest testRetainedAnswersOfAHiddenSectionAreCountedAsHidden failed the retained yes of the walk that hides the section is not counted Expected [0] but got [1].
   ReportServiceTest testRpt04OnlyAnsweredScoresEnterTheAverage failed the hidden row's retained 5 is not an answer Expected [1] but got [2].
```

## R4 -- a named org unit is trusted instead of checked

Mutation: remove the `requirePermission` check on `orgUnitId` and the intersection with the
caller's covered units.

```diff
-			variables.authz.requirePermission(arguments.principal, "report.view", named.orgUnitId, "ORG_UNIT", named.orgUnitId);
+			// scope check removed for the red run
...
-				if (structKeyExists(coveredSet, uCase(id))) arrayAppend(f.unitIds, uCase(id));
+				arrayAppend(f.unitIds, uCase(id));
```

`ReportServiceTest`:

```
{"failed":3,"passed":12,"skipped":0}
   ReportServiceTest testRpt01SchoolRoleReportsOnlyItsAssignedSchool failed Expected an exception of type [ICFWalk.NotFound] but nothing was thrown.
   ReportServiceTest testRpt02DistrictRoleAggregatesDescendantSchoolsOnly failed Expected an exception of type [ICFWalk.NotFound] but nothing was thrown.
   ReportServiceTest testUnknownMalformedAndOutOfContractFiltersAreRefused failed Expected exception type starting with [ICFWalk.NotFound] but got [expression]: key [grade] doesn't exist
```

The third failure also exposed a robustness gap in the correct code path: with an empty unit set,
`compute()` returned no per-dimension rows and `assemble()` would have failed on a missing key.
That cannot be reached through the unmutated code (a named unit must be covered, and a covered
unit is its own descendant), but `compute()` now initializes every dimension's rows before
reading, so it cannot be reached at all.

## Also red before it was green

* **ConfigLoader threshold (R5).** `ConfigLoaderTest.testReportSuppressionThresholdIsAWholeNumberOrRefused`
  was run against the frozen loader (`git show a219d9e:src/config/ConfigLoader.cfc` put in place,
  Lucee restarted) and failed on its first malformed value:

  ```
  {"failed":1,"passed":9,"skipped":0}
     ConfigLoaderTest testReportSuppressionThresholdIsAWholeNumberOrRefused failed Expected an exception of type [ICFWalk.Configuration] but nothing was thrown.
  ```

  `"5 walks"` was accepted without an error. Reading the frozen code (`len(x) && isNumeric(x) ? int(x) : 0`)
  the other refused values behave the same way -- `"five"` and `"0x10"` become 0 (no suppression),
  `"-3"` becomes -3 and `"2.5"` becomes 2 -- but the loop stops at the first failure, so only the
  first was observed. With the Phase 7 loader restored the spec passes 10/10.
* **Browser download.** `browser-reports.test.mjs` initially failed with the download saved as
  `aggregate.json`: the Download CSV link carried a `download` attribute, which makes Chromium
  fetch the URL on its own instead of following the page navigation, so the request went without
  the development identity header and the route answered with a JSON error instead of the file. The
  attribute was removed -- the route's `Content-Disposition` names the file, exactly as the Phase 5
  summary export does -- and the downloaded bytes now equal the route's apart from the
  `generated_at` line.
* **Keyboard focus.** Not observed red: before the browser suite first ran, the Run button was
  changed from being disabled during a request (a disabled control loses focus in Chromium) to
  staying enabled and ignoring a second press, and the test asserts focus stays on it.
