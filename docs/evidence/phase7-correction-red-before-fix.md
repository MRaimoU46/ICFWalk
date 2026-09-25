# Phase 7 correction: red before green (P7-01, RPT-03)

Evidence that the privacy tests of this correction detect the audited defect: first on the real
pre-fix build, then by breaking each protection of the corrected implementation on purpose. Every
output below was captured from the run it describes (Lucee 6.2.8.20, SQL Server 2022, the
development database); nothing is paraphrased. Lines longer than 400 characters are cut where
marked, and scratch paths are shortened to `<scratch>`. The full mutation transcript is delivered
with the handoff, untruncated, as `phase7-correction-mutations-raw.txt` (SHA-256 `d8f98bda911cedad49696145e336227d1fea6ce8fb4052288d0358d580024d86`,
26036 bytes), with the harness `mutate.py` (SHA-256 `6bd6d772d8035dd921fb05ae770f04ade9d99a6254bd7438d6e614230a5f7054`) and the probe `probe.mjs`
(SHA-256 `18559d40230480265143adf1caeeca8b472395de74f51c0539972f4e1281663b`).

## 1. The audited defect on the pre-fix build

The pre-fix commit `0c6fa10972593043508f502538534c2aa95c671b` (tree
`0b7a487975101154b3084bb7ef363fc150d880d4`, the audited candidate) was checked out into a separate
git worktree and served by a second Lucee instance on port 8889, against the same database. The
corrected working tree was served on port 8888. The same probe ran against both: it creates one
school, three completed walks with different answers, a walk role and a `SCHOOL_REPORT_ONLY` role
there, then asks for reports as the report-only role and rebuilds any single walk it can isolate.

### Pre-fix (port 8889): a report-only user reconstructs one walk's answers

```
# probe against http://127.0.0.1:8889  (tag probe-mudvatem)
health: {"application":"ICFWalk","checks":{"database":"ok","schema":"present"},"correlationId":"73d4dafb-4679-4de1-8508-25ac1e4bb8e6","engine":"Lucee 6.2.8.20","environment":"development","status":"ok"}
seeded 3 completed walks at one school: comp_s1_q1 = 1 / 3 / 5, grade = 3 / 7 / 9, visitTiming = beginning / middle / end, comp_s2_q1 = 2 / 4 / 5

REPORT-ONLY GET /api/reports/aggregate?optionItem=comp_s1_q1&option=1 -> HTTP 200
  population.walks = 1
  RECONSTRUCTED ONE WALK'S CATEGORICAL ROW (12 fields): {"dim grade":"3","dim visitTiming":"beginning_of_lesson","p1q1":"Partial","p1q2":"Retrieval","p1q3":"Analysis","part1_adopted_pacing":"on","part1_adopted_ac1":"3","part1_adopted_ac2":"4","part1_targettask_tt1":"5","part1_targettask_tt2":"2","comp_s1_q1":"1","comp_s2_q1":"2"}

REPORT-ONLY GET /api/reports/aggregate?dim_grade=3 -> HTTP 200
  population.walks = 1
  RECONSTRUCTED ONE WALK'S CATEGORICAL ROW (12 fields): {"dim grade":"3","dim visitTiming":"beginning_of_lesson","p1q1":"Partial","p1q2":"Retrieval","p1q3":"Analysis","part1_adopted_pacing":"on","part1_adopted_ac1":"3","part1_adopted_ac2":"4","part1_targettask_tt1":"5","part1_targettask_tt2":"2","comp_s1_q1":"1","comp_s2_q1":"2"}

REPORT-ONLY GET /api/reports/aggregate -> HTTP 200
  population.walks = 3

REPORT-ONLY GET /api/reports/aggregate.csv?optionItem=comp_s1_q1&option=1 -> HTTP 200
  POPULATION,,walks,,1,,,,,,,,,0
  OPTION,comp_s2_q1,1,1,0,,,,,,,,,0
  OPTION,comp_s2_q1,2,2,1,,,,,,,,,0
  OPTION,comp_s2_q1,3,3,0,,,,,,,,,0
  OPTION,comp_s2_q1,4,4,0,,,,,,,,,0
  OPTION,comp_s2_q1,5,5,0,,,,,,,,,0

cleanup: HTTP 200
```

A report narrowed to one walk by an answer filter or by a Grade filter gives that walk's Grade,
Visit Timing and every rated answer (12 categorical fields), in the JSON and in the CSV. That is the
audit's finding P7-01.

### Corrected (port 8888): every one of those requests is refused

```
# probe against http://127.0.0.1:8888  (tag probe-mudvav11)
health: {"application":"ICFWalk","checks":{"database":"ok","schema":"present"},"correlationId":"7188e37e-d435-4b0d-a97f-159fc919635b","engine":"Lucee 6.2.8.20","environment":"development","status":"ok"}
seeded 3 completed walks at one school: comp_s1_q1 = 1 / 3 / 5, grade = 3 / 7 / 9, visitTiming = beginning / middle / end, comp_s2_q1 = 2 / 4 / 5

REPORT-ONLY GET /api/reports/aggregate?optionItem=comp_s1_q1&option=1 -> HTTP 400
  refused: REPORT_RELEASE_REQUIRED -- Reports for your scope come from released reporting dates. Choose a release.

REPORT-ONLY GET /api/reports/aggregate?dim_grade=3 -> HTTP 400
  refused: REPORT_RELEASE_REQUIRED -- Reports for your scope come from released reporting dates. Choose a release.

REPORT-ONLY GET /api/reports/aggregate -> HTTP 400
  refused: REPORT_RELEASE_REQUIRED -- Reports for your scope come from released reporting dates. Choose a release.

REPORT-ONLY GET /api/reports/aggregate.csv?optionItem=comp_s1_q1&option=1 -> HTTP 400
  refused: REPORT_RELEASE_REQUIRED

cleanup: HTTP 200
```

## 2. The new privacy specs against the pre-fix build

The corrected `ReportServiceTest`, `ReportReleaseTest` and `ReportDisclosureTest` were copied into
the pre-fix worktree and run there (port 8889, same database):

```
ReportServiceTest passed=10 failed=5 skipped=0
   failed testCsvExportIsRfc4180AndNeutralizesFormulas :: Expected exactly [record_type,group,key,label,count,withheld,scored_responses,score_sum,mean] (74 chars) but got [record_type,group,key,label,count,answered,unanswered,hidden,not_applicable,unrecorded,scored_responses,score_sum,mean,suppressed] (129 chars); the first diff
   failed testLiveFiguresOnlyForSomeoneWhoCanOpenEveryWalkCounted :: key [MODE] doesn't exist  <pre-fix worktree at 0c6fa10>/tests/cfml/specs/ReportServiceTest.cfc:603
   failed testRpt01SchoolRoleReportsOnlyItsAssignedSchool :: Expected an exception of type [ICFWalk.Validation] but nothing was thrown.  <pre-fix worktree at 0c6fa10>/tests/cfml/BaseSpec.cfc:38
   failed testRpt02DistrictRoleAggregatesDescendantSchoolsOnly :: Expected an exception of type [ICFWalk.Validation] but nothing was thrown.  <pre-fix worktree at 0c6fa10>/tests/cfml/BaseSpec.cfc:38
   failed testRpt03ReportOnlyUsersReceiveNoIndividualWalkOrIdentifier :: Expected an exception of type [ICFWalk.Validation] but nothing was thrown.  <pre-fix worktree at 0c6fa10>/tests/cfml/BaseSpec.cfc:38
TOTAL {"failed":5,"passed":10,"skipped":0}
ReportReleaseTest passed=0 failed=16 skipped=0
   failed testAReleaseDoesNotChangeWhenWalksDo :: beforeAll failed: Component [icfwalk.reports.ReportService] has no  function with name [minimumWalks]  @ <pre-fix worktree at 0c6fa10>/tests/cfml/specs/ReportReleaseTest.cfc:36  
   failed testAReleaseRequestIsExactlyAClosedPeriod :: beforeAll failed: Component [icfwalk.reports.ReportService] has no  function with name [minimumWalks]  @ <pre-fix worktree at 0c6fa10>/tests/cfml/specs/ReportReleaseTest.cfc:36  
   failed testASectionMeanOnTooFewRatingsIsWithheld :: beforeAll failed: Component [icfwalk.reports.ReportService] has no  function with name [minimumWalks]  @ <pre-fix worktree at 0c6fa10>/tests/cfml/specs/ReportReleaseTest.cfc:36  
   failed testLogsAndAuditCarryNoWithheldFigureOrNarrative :: beforeAll failed: Component [icfwalk.reports.ReportService] has no  function with name [minimumWalks]  @ <pre-fix worktree at 0c6fa10>/tests/cfml/specs/ReportReleaseTest.cfc:36  
   failed testNoBreakdownWithholdsASingleRecoverableCell :: beforeAll failed: Component [icfwalk.reports.ReportService] has no  function with name [minimumWalks]  @ <pre-fix worktree at 0c6fa10>/tests/cfml/specs/ReportReleaseTest.cfc:36  
   failed testNoFilterThatChangesWhoIsCountedIsAcceptedOnARelease :: beforeAll failed: Component [icfwalk.reports.ReportService] has no  function with name [minimumWalks]  @ <pre-fix worktree at 0c6fa10>/tests/cfml/specs/ReportReleaseTest.cfc:36  
   failed testOneWalkAndBelowMinimumPopulationsAreWithheldAndNeverStored :: beforeAll failed: Component [icfwalk.reports.ReportService] has no  function with name [minimumWalks]  @ <pre-fix worktree at 0c6fa10>/tests/cfml/specs/ReportReleaseTest.cfc:36  
   failed testOnlyCompletedWalksOfThePeriodAreReleasedWithNoStatusSplit :: beforeAll failed: Component [icfwalk.reports.ReportService] has no  function with name [minimumWalks]  @ <pre-fix worktree at 0c6fa10>/tests/cfml/specs/ReportReleaseTest.cfc:36  
   failed testOnlySomeoneWhoCanOpenEveryWalkMayRelease :: beforeAll failed: Component [icfwalk.reports.ReportService] has no  function with name [minimumWalks]  @ <pre-fix worktree at 0c6fa10>/tests/cfml/specs/ReportReleaseTest.cfc:36  
   failed testReleasedDatesNeverOverlap :: beforeAll failed: Component [icfwalk.reports.ReportService] has no  function with name [minimumWalks]  @ <pre-fix worktree at 0c6fa10>/tests/cfml/specs/ReportReleaseTest.cfc:36  
   failed testReportOnlyUsersCannotReadLiveFigures :: beforeAll failed: Component [icfwalk.reports.ReportService] has no  function with name [minimumWalks]  @ <pre-fix worktree at 0c6fa10>/tests/cfml/specs/ReportReleaseTest.cfc:36  
   failed testSmallDimensionValueAndStateCellsAreWithheld :: beforeAll failed: Component [icfwalk.reports.ReportService] has no  function with name [minimumWalks]  @ <pre-fix worktree at 0c6fa10>/tests/cfml/specs/ReportReleaseTest.cfc:36  
   failed testSmallItemCellsAndTheirComplementsAreWithheld :: beforeAll failed: Component [icfwalk.reports.ReportService] has no  function with name [minimumWalks]  @ <pre-fix worktree at 0c6fa10>/tests/cfml/specs/ReportReleaseTest.cfc:36  
   failed testTheDistrictIsTheSumOfWhatEachSchoolPublishes :: beforeAll failed: Component [icfwalk.reports.ReportService] has no  function with name [minimumWalks]  @ <pre-fix worktree at 0c6fa10>/tests/cfml/specs/ReportReleaseTest.cfc:36  
   failed testTheExportCarriesExactlyWhatTheJsonPublishes :: beforeAll failed: Component [icfwalk.reports.ReportService] has no  function with name [minimumWalks]  @ <pre-fix worktree at 0c6fa10>/tests/cfml/specs/ReportReleaseTest.cfc:36  
   failed (afterAll) :: Component [icfwalktests.specs.ReportReleaseTest] has no accessible Member with name [RELEASES]  <pre-fix worktree at 0c6fa10>/tests/cfml/specs/ReportReleaseTest.cfc:88
TOTAL {"failed":16,"passed":0,"skipped":0}
ReportDisclosureTest passed=0 failed=8 skipped=0
   failed testAPartialBreakdownNeverWithholdsExactlyOneCell :: beforeAll failed: invalid component definition, can't find component [icfwalk.reports.DisclosureControl]  @ <pre-fix worktree at 0c6fa10>/tests/cfml/specs/ReportDisclosureTest.cfc:16  
   failed testAPartialPatternThatWouldPinItsCellsIsWithheldWhole :: beforeAll failed: invalid component definition, can't find component [icfwalk.reports.DisclosureControl]  @ <pre-fix worktree at 0c6fa10>/tests/cfml/specs/ReportDisclosureTest.cfc:16  
   failed testEveryWithheldCellHasAtLeastTwoConsistentValuesFork3 :: beforeAll failed: invalid component definition, can't find component [icfwalk.reports.DisclosureControl]  @ <pre-fix worktree at 0c6fa10>/tests/cfml/specs/ReportDisclosureTest.cfc:16  
   failed testEveryWithheldCellHasAtLeastTwoConsistentValuesFork4 :: beforeAll failed: invalid component definition, can't find component [icfwalk.reports.DisclosureControl]  @ <pre-fix worktree at 0c6fa10>/tests/cfml/specs/ReportDisclosureTest.cfc:16  
   failed testInstrumentRulesLinkBreakdownsIntoGroups :: beforeAll failed: invalid component definition, can't find component [icfwalk.reports.DisclosureControl]  @ <pre-fix worktree at 0c6fa10>/tests/cfml/specs/ReportDisclosureTest.cfc:16  
   failed testKnownBreakdowns :: beforeAll failed: invalid component definition, can't find component [icfwalk.reports.DisclosureControl]  @ <pre-fix worktree at 0c6fa10>/tests/cfml/specs/ReportDisclosureTest.cfc:16  
   failed testTheGroupRuleIsAllOrNothing :: beforeAll failed: invalid component definition, can't find component [icfwalk.reports.DisclosureControl]  @ <pre-fix worktree at 0c6fa10>/tests/cfml/specs/ReportDisclosureTest.cfc:16  
   failed testTheMinimumCannotGoBelowTheApprovedFloor :: beforeAll failed: invalid component definition, can't find component [icfwalk.reports.DisclosureControl]  @ <pre-fix worktree at 0c6fa10>/tests/cfml/specs/ReportDisclosureTest.cfc:16  
TOTAL {"failed":8,"passed":0,"skipped":0}
```

`ReportServiceTest`'s RPT-01, RPT-02 and RPT-03 cases fail for the intended reason: a report-only
role asks for live figures (the whole scope, a population narrowed to one walk by an answer, a Grade
or a date) and **receives them** instead of being refused. `testCsvExportIsRfc4180AndNeutralizesFormulas`
and `testLiveFiguresOnlyForSomeoneWhoCanOpenEveryWalkCounted` fail on the new export and report
shape. `ReportReleaseTest` and `ReportDisclosureTest` cannot run at all: the pre-fix build has no
release, no minimum and no suppression (`minimumWalks`, `DisclosureControl` and `createRelease` do
not exist). That is a red result, but a weaker one than a failed assertion, so the protections
those specs cover are shown red individually in section 3, by removing each from the corrected
implementation.

## 3. Deliberate mutations of the corrected implementation

`mutate.py` applied each mutation below to the corrected working tree (the source as committed),
restarted Lucee, ran the named specs and Node tests, then restored the file byte for byte -- the
SHA-256 before the mutation and after the restore are printed and equal -- and restarted again.
Each block prints the exact unified diff of the mutation. Each mutation removes exactly one
protection:

| Mutation | Protection removed | What went red |
| --- | --- | --- |
| M1 | complementary suppression | the exhaustive proof (a lone withheld cell is recovered from the total, e.g. `[W,3]` pins the cell to 1); a one-walk breakdown published as partial; `testNoBreakdownWithholdsASingleRecoverableCell`; the complements of the single rating of 2 (four ratings of 5) and of the three middle-of-lesson visits are published; a section mean includes the ratings of an item that must be withheld whole |
| M2 | the ambiguity audit | the exhaustive proof: `[3,W,W]` pins both cells to 2 and `[4,W,W]` (k = 4) pins both to 3, for a reader who knows the rule |
| M3 | report-only users sent to releases (pre-correction behaviour) | every report-only refusal: `testReportOnlyUsersCannotReadLiveFigures`, `testLiveFiguresOnlyForSomeoneWhoCanOpenEveryWalkCounted`, RPT-01/02/03 in `ReportServiceTest`, and `reports.test.mjs` over HTTP (the refusals and the options' `liveAvailable`) |
| M4 | refusal of narrowing filters on a release | `testNoFilterThatChangesWhoIsCountedIsAcceptedOnARelease` and the no-drafts check |
| M5 | linked breakdowns as groups | the PreK-K section's HIDDEN count (every walk not in PreK or K) is published beside the withheld Grade cell; `testInstrumentRulesLinkBreakdownsIntoGroups` |
| M6 | suppress each block, then add up | `testTheDistrictIsTheSumOfWhatEachSchoolPublishes`: the district's figures are no longer the sum of the schools' published figures (first mismatch: the PreK-K item's HIDDEN count), which is what lets the district minus one school give back a cell the other school withholds |
| M7 | withheld values never sent | the single rating of 2 is sent (with its withheld flag) in the JSON, the CSV, and to the browser (`browser-reports.test.mjs` "RPT-03 (browser)") |
| M8 | the CSV carries exactly the JSON's figures | CSV/JSON comparison and the HTTP CSV contract |
| M9 | logs carry counts only | the exact key set of the `report.generated` line |
| M10 | the block floor where a release is frozen | the release cannot be stored: the database refuses a block below 3 (`CK_report_release_block_walks`) -- the schema guard holds without the service check |
| M11 | the overlap check in the service | the database refuses the overlapping release (`TR_report_release_no_overlap`), as a database error rather than 409 `REPORT_RELEASE_OVERLAP` -- the trigger holds without the service check |

A note on the record itself: a first run of this harness (delivered with the handoff as
`phase7-correction-mutations-first-run.txt`, SHA-256 `fba939e49ffafff9c5e59056f694c433717f4646d48f6ee98b1ebe4a5bddbb46`, 559039 bytes) printed each mutation's diff with `git diff` against HEAD rather than against
the file as it stood before the mutation, so for `ReportService.cfc` it printed the whole correction
and for the then-untracked `DisclosureControl.cfc` (M1, M2) nothing. Its test results were the same
as below (every failing test and message matches). The harness was corrected to diff the file before and after the mutation, and the whole
set was run again after the last source change; this record and the delivered raw transcript are
that second run.

The full output, one block per mutation:

```
## M1: complementary suppression removed: primary cells withheld alone
file: src/reports/DisclosureControl.cfc  (sha256 before mutation cb640ffbd651ee45a33def958f5d89e40f65412d2cd97413440ee071cae99cb5)
mutation (unified diff of the file before and after the mutation):
--- a/src/reports/DisclosureControl.cfc
+++ b/src/reports/DisclosureControl.cfc
@@ -85,2 +85,3 @@
 		if (size == 0) return { "mode": "COMPLETE", "withheld": withheld };
+		return { "mode": "PARTIAL", "withheld": withheld };
 		while (true) {
restart: Health: {"application":"ICFWalk","checks":{"database":"ok","
$ CFML ReportDisclosureTest
ReportDisclosureTest passed=3 failed=5 skipped=0
   failed testAPartialBreakdownNeverWithholdsExactlyOneCell :: [6,3,0,1] withholds 1 cell(s)  /home/user/ICFWalk/tests/cfml/BaseSpec.cfc:38
   failed testAPartialPatternThatWouldPinItsCellsIsWithheldWhole :: Expected exactly [WITHHELD] (8 chars) but got [PARTIAL] (7 chars); the first difference is at character 1 ([W] expected, [P] found).  /home/user/ICFWalk/tests/cfml/BaseSpec.cfc:38
   failed testEveryWithheldCellHasAtLeastTwoConsistentValuesFork3 :: k=3 pattern [W,3] (T=4) pins withheld cell 1 to 1, from [[1,3]]  /home/user/ICFWalk/tests/cfml/BaseSpec.cfc:38
   failed testEveryWithheldCellHasAtLeastTwoConsistentValuesFork4 :: k=4 pattern [W,4] (T=5) pins withheld cell 1 to 1, from [[1,4]]  /home/user/ICFWalk/tests/cfml/BaseSpec.cfc:38
   failed testKnownBreakdowns :: one walk: the whole breakdown, zeros too [1,0,0,0] Expected exactly [WITHHELD] (8 chars) but got [PARTIAL] (7 chars); the first difference is at character 1 ([W] expected, [P] found).  /home/user/ICFWalk/tests/cfml/BaseSpec.cfc:38
TOTAL {"failed":5,"passed":3,"skipped":0}
$ CFML ReportReleaseTest
ReportReleaseTest passed=11 failed=4 skipped=0
   failed testASectionMeanOnTooFewRatingsIsWithheld :: comp_s2_q1 is withheld whole; comp_s2_q2's six 3s are published Expected [6] but got [9].  /home/user/ICFWalk/tests/cfml/BaseSpec.cfc:38
   failed testNoBreakdownWithholdsASingleRecoverableCell :: c comp_s1_q1 withholds a single category, which the total would give back  /home/user/ICFWalk/tests/cfml/BaseSpec.cfc:38
   failed testSmallDimensionValueAndStateCellsAreWithheld :: three middle-of-lesson visits, the complement must be withheld (null), found 3  /home/user/ICFWalk/tests/cfml/BaseSpec.cfc:38
   failed testSmallItemCellsAndTheirComplementsAreWithheld :: its complement, the four ratings of 5 must be withheld (null), found 4  /home/user/ICFWalk/tests/cfml/BaseSpec.cfc:38
TOTAL {"failed":4,"passed":11,"skipped":0}
restored: sha256 cb640ffbd651ee45a33def958f5d89e40f65412d2cd97413440ee071cae99cb5 (identical to before)

## M2: audit step removed: a partial pattern is published even when a reader who knows the rule can pin a cell
file: src/reports/DisclosureControl.cfc  (sha256 before mutation cb640ffbd651ee45a33def958f5d89e40f65412d2cd97413440ee071cae99cb5)
mutation (unified diff of the file before and after the mutation):
--- a/src/reports/DisclosureControl.cfc
+++ b/src/reports/DisclosureControl.cfc
@@ -90,3 +90,3 @@
 				for (var key in structKeyArray(possible)) {
-					if (structCount(possible[key]) < 2) return { "mode": "WITHHELD", "withheld": allTrue(n) };
+					if (false) return { "mode": "WITHHELD", "withheld": allTrue(n) };
 				}
restart: Health: {"application":"ICFWalk","checks":{"database":"ok","
$ CFML ReportDisclosureTest
ReportDisclosureTest passed=5 failed=3 skipped=0
   failed testAPartialPatternThatWouldPinItsCellsIsWithheldWhole :: Expected exactly [WITHHELD] (8 chars) but got [PARTIAL] (7 chars); the first difference is at character 1 ([W] expected, [P] found).  /home/user/ICFWalk/tests/cfml/BaseSpec.cfc:38
   failed testEveryWithheldCellHasAtLeastTwoConsistentValuesFork3 :: k=3 pattern [3,W,W] (T=7) pins withheld cell 2 to 2, from [[3,2,2]]  /home/user/ICFWalk/tests/cfml/BaseSpec.cfc:38
   failed testEveryWithheldCellHasAtLeastTwoConsistentValuesFork4 :: k=4 pattern [4,W,W] (T=10) pins withheld cell 2 to 3, from [[4,3,3]]  /home/user/ICFWalk/tests/cfml/BaseSpec.cfc:38
TOTAL {"failed":3,"passed":5,"skipped":0}
restored: sha256 cb640ffbd651ee45a33def958f5d89e40f65412d2cd97413440ee071cae99cb5 (identical to before)

## M3: live figures for everyone: report-only roles no longer sent to releases (the pre-correction behaviour)
file: src/reports/ReportService.cfc  (sha256 before mutation 71da534f3d8622480fd138142b21599b3083cac2a676cc4c5b34d24878af7a8e)
mutation (unified diff of the file before and after the mutation):
--- a/src/reports/ReportService.cfc
+++ b/src/reports/ReportService.cfc
@@ -609,4 +609,2 @@
 	private boolean function isProtected(required struct principal, required array unitIds) {
-		var readable = unitSet(variables.authz.visibleOrgUnitIds(arguments.principal, "walk.read"));
-		for (var id in arguments.unitIds) if (!structKeyExists(readable, uCase(id))) return true;
 		return false;
restart: Health: {"application":"ICFWalk","checks":{"database":"ok","
$ CFML ReportReleaseTest
ReportReleaseTest passed=14 failed=1 skipped=0
   failed testReportOnlyUsersCannotReadLiveFigures :: Expected an exception of type [ICFWalk.Validation] but nothing was thrown.  /home/user/ICFWalk/tests/cfml/BaseSpec.cfc:38
TOTAL {"failed":1,"passed":14,"skipped":0}
$ CFML ReportServiceTest
ReportServiceTest passed=11 failed=4 skipped=0
   failed testLiveFiguresOnlyForSomeoneWhoCanOpenEveryWalkCounted :: Expected an exception of type [ICFWalk.Validation] but nothing was thrown.  /home/user/ICFWalk/tests/cfml/BaseSpec.cfc:38
   failed testRpt01SchoolRoleReportsOnlyItsAssignedSchool :: Expected an exception of type [ICFWalk.Validation] but nothing was thrown.  /home/user/ICFWalk/tests/cfml/BaseSpec.cfc:38
   failed testRpt02DistrictRoleAggregatesDescendantSchoolsOnly :: Expected an exception of type [ICFWalk.Validation] but nothing was thrown.  /home/user/ICFWalk/tests/cfml/BaseSpec.cfc:38
   failed testRpt03ReportOnlyUsersReceiveNoIndividualWalkOrIdentifier :: Expected an exception of type [ICFWalk.Validation] but nothing was thrown.  /home/user/ICFWalk/tests/cfml/BaseSpec.cfc:38
TOTAL {"failed":4,"passed":11,"skipped":0}
$ ICFWALK_REQUIRE_APP=1 node --test tests/node/reports.test.mjs
ok 1 - RPT-06 (structural): the report repository selects no narrative, identifying or teacher column
ok 2 - reports are driven by the instrument, not by names written into the report code
ok 3 - SEC-02 (structural): the reports view builds its DOM without HTML strings
ok 4 - AUTH-01: every report route requires an identity and discloses nothing without one
ok 5 - AUTH-06 / RPT-03: instrument administration and role-less users are refused every report route
not ok 6 - RPT-03: a report-only role is refused every live figure, however the request is narrowed
  error: |-
ok 7 - RPT-01: a school report role reads its school's release; another school is 404 over HTTP
ok 8 - RPT-02: district roles aggregate their descendant schools and nothing else, live or released
ok 9 - RPT-03 / RPT-06: payload and export carry no walk, owner, narrative, email or free text
ok 10 - releases: only someone who can open every walk may release, with CSRF, a closed period, and no overlap
ok 11 - report routes are read-only: other methods are refused before anything runs
ok 12 - the CSV export is an attachment with a safe name, no-store, nosniff, a BOM and CRLF rows
ok 13 - SEC-01: injection payloads in any parameter are refused as data, and nothing is returned
not ok 14 - options describe the version, the scope, the releases and the reportable surface only
  error: |-
# pass 12
# fail 2
# skipped 0
restored: sha256 71da534f3d8622480fd138142b21599b3083cac2a676cc4c5b34d24878af7a8e (identical to before)

## M4: a release accepts filters that narrow who is counted
file: src/reports/ReportService.cfc  (sha256 before mutation 71da534f3d8622480fd138142b21599b3083cac2a676cc4c5b34d24878af7a8e)
mutation (unified diff of the file before and after the mutation):
--- a/src/reports/ReportService.cfc
+++ b/src/reports/ReportService.cfc
@@ -548,3 +548,3 @@
 			for (var raw in dimensionNames) arrayAppend(refused, { "parameter": left(variables.DIMENSION_PREFIX & raw, 60), "code": "REPORT_FILTER_NOT_PERMITTED" });
-			if (arrayLen(refused)) {
+			if (false) {
 				variables.errors.validation("A released report is narrowed by version, school, section and question only.", "REPORT_FILTER_NOT_PERMITTED", { "issues": refused });
restart: Health: {"application":"ICFWalk","checks":{"database":"ok","
$ CFML ReportReleaseTest
ReportReleaseTest passed=13 failed=2 skipped=0
   failed testNoFilterThatChangesWhoIsCountedIsAcceptedOnARelease :: Expected an exception of type [ICFWalk.Validation] but nothing was thrown.  /home/user/ICFWalk/tests/cfml/BaseSpec.cfc:38
   failed testOnlyCompletedWalksOfThePeriodAreReleasedWithNoStatusSplit :: Expected an exception of type [ICFWalk.Validation] but nothing was thrown.  /home/user/ICFWalk/tests/cfml/BaseSpec.cfc:38
TOTAL {"failed":2,"passed":13,"skipped":0}
restored: sha256 71da534f3d8622480fd138142b21599b3083cac2a676cc4c5b34d24878af7a8e (identical to before)

## M5: instrument-rule links ignored: linked breakdowns suppressed independently
file: src/reports/ReportService.cfc  (sha256 before mutation 71da534f3d8622480fd138142b21599b3083cac2a676cc4c5b34d24878af7a8e)
mutation (unified diff of the file before and after the mutation):
--- a/src/reports/ReportService.cfc
+++ b/src/reports/ReportService.cfc
@@ -1088,3 +1088,3 @@
 		catalog.sections = kept;
-		catalog["linkGroups"] = linkGroupsOf(model, catalog);
+		catalog["linkGroups"] = {};
 		variables.catalogCache[cacheKey] = catalog;
restart: Health: {"application":"ICFWalk","checks":{"database":"ok","
$ CFML ReportReleaseTest
ReportReleaseTest passed=14 failed=1 skipped=0
   failed testSmallDimensionValueAndStateCellsAreWithheld :: a PreK-K item's HIDDEN count (= every walk not PreK or K) must be withheld (null), found 10  /home/user/ICFWalk/tests/cfml/BaseSpec.cfc:38
TOTAL {"failed":1,"passed":14,"skipped":0}
$ CFML ReportDisclosureTest
ReportDisclosureTest passed=7 failed=1 skipped=0
   failed testInstrumentRulesLinkBreakdownsIntoGroups :: Period follows Grade  /home/user/ICFWalk/tests/cfml/BaseSpec.cfc:38
TOTAL {"failed":1,"passed":7,"skipped":0}
restored: sha256 71da534f3d8622480fd138142b21599b3083cac2a676cc4c5b34d24878af7a8e (identical to before)

## M6: aggregate, then suppress: blocks summed before protection, so district minus schools gives cells back
file: src/reports/ReportService.cfc  (sha256 before mutation 71da534f3d8622480fd138142b21599b3083cac2a676cc4c5b34d24878af7a8e)
mutation (unified diff of the file before and after the mutation):
--- a/src/reports/ReportService.cfc
+++ b/src/reports/ReportService.cfc
@@ -853,2 +853,3 @@
 		var byUnit = {};
+		var pooledCells = {};
 		for (var b in blocks) {
@@ -857,4 +858,5 @@
 			var cells = structKeyExists(stored, b.orgUnitId) ? stored[b.orgUnitId] : {};
-			publishBlock(subjects, cells, catalog.linkGroups, k, totals);
-		}
+			for (var sk in cells) { if (!structKeyExists(pooledCells, sk)) pooledCells[sk] = {}; for (var ck in cells[sk]) pooledCells[sk][ck] = (structKeyExists(pooledCells[sk], ck) ? pooledCells[sk][ck] : 0) + cells[sk][ck]; }
+		}
+		publishBlock(subjects, pooledCells, catalog.linkGroups, k, totals);
 		report.population = { "walks": total, "byStatus": { "COMPLETED": total }, "withheld": false };
restart: Health: {"application":"ICFWalk","checks":{"database":"ok","
$ CFML ReportReleaseTest
ReportReleaseTest passed=14 failed=1 skipped=0
   failed testTheDistrictIsTheSumOfWhatEachSchoolPublishes :: prek_k_q1 HIDDEN Expected [3] but got [0].  /home/user/ICFWalk/tests/cfml/BaseSpec.cfc:38
TOTAL {"failed":1,"passed":14,"skipped":0}
restored: sha256 71da534f3d8622480fd138142b21599b3083cac2a676cc4c5b34d24878af7a8e (identical to before)

## M7: the protected value is sent alongside the suppression flag
file: src/reports/ReportService.cfc  (sha256 before mutation 71da534f3d8622480fd138142b21599b3083cac2a676cc4c5b34d24878af7a8e)
mutation (unified diff of the file before and after the mutation):
--- a/src/reports/ReportService.cfc
+++ b/src/reports/ReportService.cfc
@@ -924,3 +924,3 @@
 				if (decision.withheld[i]) into[key].withheld = true;
-				else into[key].sum += p.counts[i];
+				into[key].sum += p.counts[i];
 			}
restart: Health: {"application":"ICFWalk","checks":{"database":"ok","
$ CFML ReportReleaseTest
ReportReleaseTest passed=9 failed=6 skipped=0
   failed testASectionMeanOnTooFewRatingsIsWithheld :: comp_s2_q1 is withheld whole; comp_s2_q2's six 3s are published Expected [6] but got [11].  /home/user/ICFWalk/tests/cfml/BaseSpec.cfc:38
   failed testNoBreakdownWithholdsASingleRecoverableCell :: c prek_k_q1 hides only 0 walks between its withheld categories  /home/user/ICFWalk/tests/cfml/BaseSpec.cfc:38
   failed testSmallDimensionValueAndStateCellsAreWithheld :: three middle-of-lesson visits, the complement must be withheld (null), found 3  /home/user/ICFWalk/tests/cfml/BaseSpec.cfc:38
   failed testSmallItemCellsAndTheirComplementsAreWithheld :: the single rating of 2 must be withheld (null), found 1  /home/user/ICFWalk/tests/cfml/BaseSpec.cfc:38
   failed testTheDistrictIsTheSumOfWhatEachSchoolPublishes :: the district's rating of 2 must be withheld (null), found 1  /home/user/ICFWalk/tests/cfml/BaseSpec.cfc:38
   failed testTheExportCarriesExactlyWhatTheJsonPublishes :: the withheld rating of 2 is an empty count flagged withheld Expected to find [
OPTION,comp_s1_q1,2,2,,1,,,
] in [
﻿record_type,group,key,label,count,withheld,scored_responses,score_sum,mean
META,,format,icfwalk-aggregate-report/2,,,,,
META,,mode,RELEASE,,,,,
META,,version_label,2026-09-17 aligned prototype,,,,,
META,,version_status,DRAFT,,,,,
META,,generated_at,2026-09-23T09:14:02.952Z,,,,,
META,,statuse].  /home/user/ICFWalk/tests/cfml/BaseSpec.cfc:38
TOTAL {"failed":6,"passed":9,"skipped":0}
$ ICFWALK_REQUIRE_APP=1 node --test tests/node/browser-reports.test.mjs
not ok 1 - RPT-03 (browser): a report-only user reads released figures only and is never sent a withheld value
  error: |-
ok 2 - RPT-07 (browser): filters narrow the population and the CSV download is the route's own file
ok 3 - a refused filter is announced and leaves no stale results behind
ok 4 - a walk user moves between My walks and Reports and sees only their own scope
ok 5 - SEC-02 (browser): stored markup in an org unit name is shown as text and never runs
ok 6 - releases (browser): someone who can open every walk releases dates from the page
ok 7 - A11Y-01 / A11Y-03 / A11Y-05: keyboard operation, axe-core, and 375 px without horizontal loss
# pass 6
# fail 1
# skipped 0
restored: sha256 71da534f3d8622480fd138142b21599b3083cac2a676cc4c5b34d24878af7a8e (identical to before)

## M8: the CSV writes a number where the JSON withholds one
file: src/reports/ReportService.cfc  (sha256 before mutation 71da534f3d8622480fd138142b21599b3083cac2a676cc4c5b34d24878af7a8e)
mutation (unified diff of the file before and after the mutation):
--- a/src/reports/ReportService.cfc
+++ b/src/reports/ReportService.cfc
@@ -1425,3 +1425,3 @@
 	private string function cell(required struct holder, required string key) {
-		if (!structKeyExists(arguments.holder, arguments.key) || isNull(arguments.holder[arguments.key])) return "";
+		if (!structKeyExists(arguments.holder, arguments.key) || isNull(arguments.holder[arguments.key])) return "0";
 		return num(arguments.holder[arguments.key]);
restart: Health: {"application":"ICFWalk","checks":{"database":"ok","
$ CFML ReportReleaseTest
ReportReleaseTest passed=13 failed=2 skipped=0
   failed testOneWalkAndBelowMinimumPopulationsAreWithheldAndNeverStored :: a: the export withholds the count and says so Expected to find [
POPULATION,,walks,,,1,,,
] in [
﻿record_type,group,key,label,count,withheld,scored_responses,score_sum,mean
META,,format,icfwalk-aggregate-report/2,,,,,
META,,mode,RELEASE,,,,,
META,,version_label,2026-09-17 aligned prototype,,,,,
META,,version_status,DRAFT,,,,,
META,,generated_at,2026-09-23T09:14:37.359Z,,,,,
META,,statuse].  /home/user/ICFWalk/tests/cfml/BaseSpec.cfc:38
   failed testTheExportCarriesExactlyWhatTheJsonPublishes :: prek_k_q1 option yes Expected exactly [] (0 chars) but got [0] (1 chars); one is a prefix of the other (0 and 1 chars).  /home/user/ICFWalk/tests/cfml/BaseSpec.cfc:38
TOTAL {"failed":2,"passed":13,"skipped":0}
$ ICFWALK_REQUIRE_APP=1 node --test tests/node/reports.test.mjs
ok 1 - RPT-06 (structural): the report repository selects no narrative, identifying or teacher column
ok 2 - reports are driven by the instrument, not by names written into the report code
ok 3 - SEC-02 (structural): the reports view builds its DOM without HTML strings
ok 4 - AUTH-01: every report route requires an identity and discloses nothing without one
ok 5 - AUTH-06 / RPT-03: instrument administration and role-less users are refused every report route
ok 6 - RPT-03: a report-only role is refused every live figure, however the request is narrowed
ok 7 - RPT-01: a school report role reads its school's release; another school is 404 over HTTP
ok 8 - RPT-02: district roles aggregate their descendant schools and nothing else, live or released
ok 9 - RPT-03 / RPT-06: payload and export carry no walk, owner, narrative, email or free text
ok 10 - releases: only someone who can open every walk may release, with CSRF, a closed period, and no overlap
ok 11 - report routes are read-only: other methods are refused before anything runs
not ok 12 - the CSV export is an attachment with a safe name, no-store, nosniff, a BOM and CRLF rows
  error: 'the single rating of 2: an empty count, flagged withheld'
ok 13 - SEC-01: injection payloads in any parameter are refused as data, and nothing is returned
ok 14 - options describe the version, the scope, the releases and the reportable surface only
# pass 13
# fail 1
# skipped 0
restored: sha256 71da534f3d8622480fd138142b21599b3083cac2a676cc4c5b34d24878af7a8e (identical to before)

## M9: the report log line carries figures
file: src/reports/ReportService.cfc  (sha256 before mutation 71da534f3d8622480fd138142b21599b3083cac2a676cc4c5b34d24878af7a8e)
mutation (unified diff of the file before and after the mutation):
--- a/src/reports/ReportService.cfc
+++ b/src/reports/ReportService.cfc
@@ -171,3 +171,3 @@
 			"versionId": f.version.versionId, "mode": f.mode, "walks": report.population.withheld ? -1 : report.population.walks,
-			"items": arrayLen(report.items), "attempts": report.attempts, "filters": filterCount(f), "ms": getTickCount() - started
+			"items": arrayLen(report.items), "attempts": report.attempts, "filters": filterCount(f), "ms": getTickCount() - started, "figures": report.items
 		});
restart: Health: {"application":"ICFWalk","checks":{"database":"ok","
$ CFML ReportReleaseTest
ReportReleaseTest passed=14 failed=1 skipped=0
   failed testLogsAndAuditCarryNoWithheldFigureOrNarrative :: the report log line Expected JSON [["attempts","filters","items","mode","ms","versionId","walks"]] (62 chars) but got [["attempts","figures","filters","items","mode","ms","versionId","walks"]] (72 chars); the first difference is at character 16 ([l] expected, [g] found).  /home/user/ICFWalk/tests/cfml/BaseSpec.cfc:38
TOTAL {"failed":1,"passed":14,"skipped":0}
restored: sha256 71da534f3d8622480fd138142b21599b3083cac2a676cc4c5b34d24878af7a8e (identical to before)

## M10: the block floor removed where a release is frozen (the database guard is what refuses it)
file: src/reports/ReportService.cfc  (sha256 before mutation 71da534f3d8622480fd138142b21599b3083cac2a676cc4c5b34d24878af7a8e)
mutation (unified diff of the file before and after the mutation):
--- a/src/reports/ReportService.cfc
+++ b/src/reports/ReportService.cfc
@@ -438,3 +438,2 @@
 		for (var unitId in unitIds) {
-			if (walksByUnit[unitId] < arguments.k) continue;
 			var cells = [];
restart: Health: {"application":"ICFWalk","checks":{"database":"ok","
$ CFML ReportReleaseTest
ReportReleaseTest passed=0 failed=15 skipped=0
   failed testAReleaseDoesNotChangeWhenWalksDo :: beforeAll failed: The INSERT statement conflicted with the CHECK constraint "CK_report_release_block_walks". The conflict occurred in database "icfwalk_dev", table "icf.report_release_block", column 'walks'.  @ /home/user/ICFWalk/src/core/Db.cfc:19  
   failed testAReleaseRequestIsExactlyAClosedPeriod :: beforeAll failed: The INSERT statement conflicted with the CHECK constraint "CK_report_release_block_walks". The conflict occurred in database "icfwalk_dev", table "icf.report_release_block", column 'walks'.  @ /home/user/ICFWalk/src/core/Db.cfc:19  
   failed testASectionMeanOnTooFewRatingsIsWithheld :: beforeAll failed: The INSERT statement conflicted with the CHECK constraint "CK_report_release_block_walks". The conflict occurred in database "icfwalk_dev", table "icf.report_release_block", column 'walks'.  @ /home/user/ICFWalk/src/core/Db.cfc:19  
   failed testLogsAndAuditCarryNoWithheldFigureOrNarrative :: beforeAll failed: The INSERT statement conflicted with the CHECK constraint "CK_report_release_block_walks". The conflict occurred in database "icfwalk_dev", table "icf.report_release_block", column 'walks'.  @ /home/user/ICFWalk/src/core/Db.cfc:19  
   failed testNoBreakdownWithholdsASingleRecoverableCell :: beforeAll failed: The INSERT statement conflicted with the CHECK constraint "CK_report_release_block_walks". The conflict occurred in database "icfwalk_dev", table "icf.report_release_block", column 'walks'.  @ /home/user/ICFWalk/src/core/Db.cfc:19  
   failed testNoFilterThatChangesWhoIsCountedIsAcceptedOnARelease :: beforeAll failed: The INSERT statement conflicted with the CHECK constraint "CK_report_release_block_walks". The conflict occurred in database "icfwalk_dev", table "icf.report_release_block", column 'walks'.  @ /home/user/ICFWalk/src/core/Db.cfc:19  
   failed testOneWalkAndBelowMinimumPopulationsAreWithheldAndNeverStored :: beforeAll failed: The INSERT statement conflicted with the CHECK constraint "CK_report_release_block_walks". The conflict occurred in database "icfwalk_dev", table "icf.report_release_block", column 'walks'.  @ /home/user/ICFWalk/src/core/Db.cfc:19  
   failed testOnlyCompletedWalksOfThePeriodAreReleasedWithNoStatusSplit :: beforeAll failed: The INSERT statement conflicted with the CHECK constraint "CK_report_release_block_walks". The conflict occurred in database "icfwalk_dev", table "icf.report_release_block", column 'walks'.  @ /home/user/ICFWalk/src/core/Db.cfc:19  
   failed testOnlySomeoneWhoCanOpenEveryWalkMayRelease :: beforeAll failed: The INSERT statement conflicted with the CHECK constraint "CK_report_release_block_walks". The conflict occurred in database "icfwalk_dev", table "icf.report_release_block", column 'walks'.  @ /home/user/ICFWalk/src/core/Db.cfc:19  
   failed testReleasedDatesNeverOverlap :: beforeAll failed: The INSERT statement conflicted with the CHECK constraint "CK_report_release_block_walks". The conflict occurred in database "icfwalk_dev", table "icf.report_release_block", column 'walks'.  @ /home/user/ICFWalk/src/core/Db.cfc:19  
   failed testReportOnlyUsersCannotReadLiveFigures :: beforeAll failed: The INSERT statement conflicted with the CHECK constraint "CK_report_release_block_walks". The conflict occurred in database "icfwalk_dev", table "icf.report_release_block", column 'walks'.  @ /home/user/ICFWalk/src/core/Db.cfc:19  
   failed testSmallDimensionValueAndStateCellsAreWithheld :: beforeAll failed: The INSERT statement conflicted with the CHECK constraint "CK_report_release_block_walks". The conflict occurred in database "icfwalk_dev", table "icf.report_release_block", column 'walks'.  @ /home/user/ICFWalk/src/core/Db.cfc:19  
   failed testSmallItemCellsAndTheirComplementsAreWithheld :: beforeAll failed: The INSERT statement conflicted with the CHECK constraint "CK_report_release_block_walks". The conflict occurred in database "icfwalk_dev", table "icf.report_release_block", column 'walks'.  @ /home/user/ICFWalk/src/core/Db.cfc:19  
   failed testTheDistrictIsTheSumOfWhatEachSchoolPublishes :: beforeAll failed: The INSERT statement conflicted with the CHECK constraint "CK_report_release_block_walks". The conflict occurred in database "icfwalk_dev", table "icf.report_release_block", column 'walks'.  @ /home/user/ICFWalk/src/core/Db.cfc:19  
   failed testTheExportCarriesExactlyWhatTheJsonPublishes :: beforeAll failed: The INSERT statement conflicted with the CHECK constraint "CK_report_release_block_walks". The conflict occurred in database "icfwalk_dev", table "icf.report_release_block", column 'walks'.  @ /home/user/ICFWalk/src/core/Db.cfc:19  
TOTAL {"failed":15,"passed":0,"skipped":0}
restored: sha256 71da534f3d8622480fd138142b21599b3083cac2a676cc4c5b34d24878af7a8e (identical to before)

## M11: the overlap check removed from the service (the database trigger is what refuses it)
file: src/reports/ReportService.cfc  (sha256 before mutation 71da534f3d8622480fd138142b21599b3083cac2a676cc4c5b34d24878af7a8e)
mutation (unified diff of the file before and after the mutation):
--- a/src/reports/ReportService.cfc
+++ b/src/reports/ReportService.cfc
@@ -283,3 +283,3 @@
 			reports.lockReleases();
-			if (reports.overlapsRelease(span.fromText, span.toText)) {
+			if (false) {
 				variables.errors.conflict("Those dates overlap dates that have already been released. Released dates never overlap.", "REPORT_RELEASE_OVERLAP");
restart: Health: {"application":"ICFWalk","checks":{"database":"ok","
$ CFML ReportReleaseTest
ReportReleaseTest passed=14 failed=1 skipped=0
   failed testReleasedDatesNeverOverlap :: Expected exception type starting with [ICFWalk.Conflict] but got [database]: A report release must not cover a date another release covers.  /home/user/ICFWalk/tests/cfml/BaseSpec.cfc:38
TOTAL {"failed":1,"passed":14,"skipped":0}
restored: sha256 71da534f3d8622480fd138142b21599b3083cac2a676cc4c5b34d24878af7a8e (identical to before)

exit 0
```
