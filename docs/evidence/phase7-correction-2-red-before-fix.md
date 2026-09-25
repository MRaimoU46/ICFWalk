# Phase 7 correction, second round: red before fix (P7C-01, P7C-02)

Evidence for the second independent audit of the Phase 7 correction (`0c74dbd5a8a79684d38ba0b169dce2682a54fad6`,
"NOT READY TO FREEZE PHASE 7"). Every output below was captured from the run it describes, on
Lucee 6.2.8.20 and SQL Server 2022, and is quoted, not paraphrased. Lines longer than 400
characters are cut where marked, and scratch paths are shortened. The full mutation transcript is
delivered with the handoff, untruncated, as `phase7-correction-2-mutations-raw.txt` (SHA-256
`2e97b91b6b5fe16e9db381bb0666130b484e908f2c757a8294789bb9c3125d0c`, 34307 bytes), with its harness `mutate.py` (SHA-256 `b993b2e6d10d20224ff288db18290fec5df28ec6e70684dc55153d6203aa3b6d`).

## How the audited build was run

The audited commit `0c74dbd5a8a79684d38ba0b169dce2682a54fad6` (tree
`413ac2b7f71d03f30ba18866215939795deccca1`) was checked out into a separate git worktree and served
by a second Lucee instance on port 8889, against its **own** database, `icfwalk_prefix`, created
empty and built with that commit's own migrations 001 to 007, then seeded. (The corrected migration
007 refuses the audited code's release writes, so the audited code could not share the corrected
database.) The two new specs, `ReportIsolationTest` and `ReportReleaseMembershipTest`, were copied
into that worktree as the only change; the audited `InterceptingReportRepository` was left as it
was, since the specs use only its hooks.

## 1. P7C-02 on the audited build: a corrected walk is counted by two releases

```
ReportReleaseMembershipTest passed=0 failed=2 skipped=0
   failed testAWalkWhoseDateIsCorrectedIntoLaterDatesIsNeverCountedByASecondRelease :: release B counts b1, b2 and b3 only: a1 was already counted by release A, so no two releases share it Expected [3] but got [4].  <pre-fix worktree at 0c74dbd>/tests/cfml/BaseSpec.cfc:38
   failed testTheDatabaseRefusesToPutAReleasedWalkIntoAnotherRelease :: the database refuses a second release of the same walk: Invalid object name 'icf.report_release_walk'.  <pre-fix worktree at 0c74dbd>/tests/cfml/BaseSpec.cfc:38
TOTAL {"failed":2,"passed":0,"skipped":0}
```

Release A counts a1, a2 and a3. a1's visit date is then corrected, through the walk service, into
release B's dates. Release B counts it again: 4 walks where 3 are new. That is the audit's finding,
reproduced. The second case fails because the audited schema has no membership at all.

## 2. P7C-01 on the audited build

### 2a. What the tables were at run time

Captured first, before any source file was changed: the main working tree still held the audited
source (only test files had been added), served on port 8888. A report was paused inside its
transaction at the barrier seam, and `tempdb.sys.tables` was read without locks from that report's
own connection by a throwaway probe spec (not kept):

```
report session (@@SPID): 67; global (#) temporary tables in tempdb: 0
tempdb.sys.tables: #icf_report_population ... (128 characters, ends 000000000023); OBJECT_ID from this session: -1606939253
tempdb.sys.tables: #icf_report_units ... (128 characters, ends 000000000022); OBJECT_ID from this session: -1102068455
report walks: 3
```

The tables are `#icf_report_population` and `#icf_report_units`, padded by SQL Server to 128
characters with a per-connection suffix: that is how tempdb names a **connection-local** temporary
table. A global table would be listed under its bare `##` name. The count of global temporary tables
(names matching `chr(35) & chr(35) & "%"`) is 0. (The label on that line prints one `#` where two were
meant: the probe's own label was a CFML string literal, and CFML turns `##` into `#` -- the very
escaping that makes the audited source's `"##icf_report_population"` a one-`#` name.)

### 2b. The barrier cases on the audited build, unchanged

```
ReportIsolationBarrierOnlyTest passed=4 failed=0 skipped=0
TOTAL {"failed":0,"passed":4,"skipped":0}
```

All four pass on the audited code (`ReportIsolationBarrierOnlyTest` is `ReportIsolationTest`
without its three guard cases, which test mechanisms the audited code does not have; see 2d). Report
B ran to completion while report A was paused holding its tables, in every pairing, and both counted
exactly their own school's walks. P7C-01, as described, does not reproduce.

### 2c. The same cases detect the defect the audit describes

To show the barrier would have caught global tables, the audited repository was changed to name
genuinely global tables (a CFML literal needs `####` to produce `##`):

```diff
--- a/src/reports/ReportRepository.cfc
+++ b/src/reports/ReportRepository.cfc
@@ -34,8 +34,8 @@
  */
 component output="false" {
 
-	variables.POP = "##icf_report_population";
-	variables.UNITS = "##icf_report_units";
+	variables.POP = "####icf_report_population";
+	variables.UNITS = "####icf_report_units";
 	variables.UNIT_BATCH = 500;
 	variables.CELL_BATCH = 250;
 
```

```
ReportIsolationBarrierOnlyTest passed=0 failed=4 skipped=0
   failed testALiveReportAndAReleaseAreIsolatedAtTheScopeBoundary :: the release finished while the live report held its scope and population (; session 54 waits on 52 (LCK_M_SCH_S OBJECT: 2:981578535:0 , CONDITIONAL)) Expected exactly [COMPLETED] (9 chars) but got [RUNNING] (7 chars); the first difference is at character 1 ([C] expected, [R] found).  <pre-fix worktree at 0c74dbd>/tests/cfml/BaseS ...[line truncated here; 410 characters in the raw output]
   failed testAReleaseAndALiveReportAreIsolatedAtTheScopeBoundary :: the live report finished while the release held its scope, population and release lock (; session 52 waits on 54 (LCK_M_SCH_S OBJECT: 2:1109578991:0 , CONDITIONAL)) Expected exactly [COMPLETED] (9 chars) but got [RUNNING] (7 chars); the first difference is at character 1 ([C] expected, [R] found).  <pre-fix worktree at 0c74dbd>/t ...[line truncated here; 425 characters in the raw output]
   failed testAReportLeavesNoPopulationTableBehindOnSuccessOrFailure :: its two tables existed when it failed Expected [2] but got [0].  <pre-fix worktree at 0c74dbd>/tests/cfml/BaseSpec.cfc:38
   failed testTwoReportsOnDisjointScopesAreIsolatedAtTheScopeBoundary :: report B finished while report A held its scope and population: B did not wait on A (; session 54 waits on 52 (LCK_M_SCH_S OBJECT: 2:1365579903:0 , CONDITIONAL)) Expected exactly [COMPLETED] (9 chars) but got [RUNNING] (7 chars); the first difference is at character 1 ([C] expected, [R] found).  <pre-fix worktree at 0c74dbd>/ ...[line truncated here; 426 characters in the raw output]
TOTAL {"failed":4,"passed":0,"skipped":0}
```

Every barrier fails: the second request waits (`LCK_M_SCH_S`, a schema lock on the shared tempdb
object) until the first commits. The file was then restored byte for byte (SHA-256 checked) and the
instance restarted before any further run.

### 2d. The full new spec on the audited build

```
ReportIsolationTest passed=3 failed=4 skipped=0
   failed testAPopulationIsRefusedOutsideATransaction :: Expected an exception of type [ICFWalk.Configuration] but nothing was thrown.  <pre-fix worktree at 0c74dbd>/tests/cfml/BaseSpec.cfc:38
   failed testAPopulationRefusesToContinueOnAnotherConnection :: variable [POPULATION] doesn't exist  <pre-fix worktree at 0c74dbd>/tests/cfml/specs/ReportIsolationTest.cfc:379
   failed testAReleaseAndALiveReportAreIsolatedAtTheScopeBoundary :: at the report's boundary, the release's two tables and the report's own two exist side by side Expected [6] but got [4].  <pre-fix worktree at 0c74dbd>/tests/cfml/BaseSpec.cfc:38
   failed testPopulationTablesAreConnectionLocalAndUniquePerComputation :: variable [TWO] doesn't exist  <pre-fix worktree at 0c74dbd>/tests/cfml/specs/ReportIsolationTest.cfc:358
TOTAL {"failed":4,"passed":3,"skipped":0}
```

The three guard cases fail because the mechanisms are new: the audited `beginPopulation` returns no
handle and does not refuse to run outside a transaction. That second point also explains the one
barrier failure here, which 2b does not show. The guard case ran first and, on the audited code,
**succeeded** in building a population outside any transaction. Its fixed-name tables were
committed on a pooled connection and left there. The next computation that drew that connection
dropped and recreated them under the same names, so the count of tables at the barrier came out 2
short. The corrected code refuses to build a population outside a transaction
(`REPORT_POPULATION_NO_TRANSACTION`) and never reuses a name.

A note on the barrier itself: the first version of the probe read `tempdb.sys.tables` under READ
COMMITTED, and on the audited build report B then waited on report A's uncommitted catalog rows --
the probe blocking, not the report. The probe now reads the catalog with `NOLOCK` and records every
lock wait when the barrier times out; 2b and 2c are both from that version.

## 3. Deliberate mutations of the corrected code

`mutate.py` applies each mutation to the corrected source, restarts Lucee, runs the named specs and
Node tests, restores the file byte for byte (the SHA-256 before and after are printed and equal),
and restarts again. M1 to M11 are the first round's, re-run on this round's source. M12 to M16 are
new:

| Mutation | Protection removed | What went red |
| --- | --- | --- |
| M12 | P7C-01 as the audit describes it: one fixed pair of global tables shared by every request | every barrier case (the second request waits on the first, `LCK_M_X` at `CREATE TABLE` of the shared name), the cleanup case, and the uniqueness case ("There is already an object named '##icf_report_units'") |
| M13 | a population may be built outside a transaction | `testAPopulationIsRefusedOutsideATransaction` |
| M14 | a population continues after reaching another connection | `testAPopulationRefusesToContinueOnAnotherConnection` |
| M15 | a new release no longer leaves out walks an earlier one counted | release B cannot be stored: the database refuses the second membership (`PK_report_release_walk`) |
| M16 | a release stores blocks without recording the walks they count | no release can be stored: the database refuses a block whose count its recorded walks do not match (50065) |

M1 to M11 fail exactly as they did in the first round; only two Node test numbers moved by one,
because a structural test was added ahead of them. M15 and M16 show the database holding without the
service's own step. Section 1 shows the service
step is what the corrected behaviour needs: the audited schema has no key to fall back on.

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
file: src/reports/ReportService.cfc  (sha256 before mutation 9008db41e4ee51300a1159a74bfacde7a93fd00b6bcffd88d0fe66f6d575287b)
mutation (unified diff of the file before and after the mutation):
--- a/src/reports/ReportService.cfc
+++ b/src/reports/ReportService.cfc
@@ -633,4 +633,2 @@
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
ok 2 - P7C-01 / P7C-02 (structural): report tables are connection-local, and release membership is never read out
ok 3 - reports are driven by the instrument, not by names written into the report code
ok 4 - SEC-02 (structural): the reports view builds its DOM without HTML strings
ok 5 - AUTH-01: every report route requires an identity and discloses nothing without one
ok 6 - AUTH-06 / RPT-03: instrument administration and role-less users are refused every report route
not ok 7 - RPT-03: a report-only role is refused every live figure, however the request is narrowed
  error: |-
ok 8 - RPT-01: a school report role reads its school's release; another school is 404 over HTTP
ok 9 - RPT-02: district roles aggregate their descendant schools and nothing else, live or released
ok 10 - RPT-03 / RPT-06: payload and export carry no walk, owner, narrative, email or free text
ok 11 - releases: only someone who can open every walk may release, with CSRF, a closed period, and no overlap
ok 12 - report routes are read-only: other methods are refused before anything runs
ok 13 - the CSV export is an attachment with a safe name, no-store, nosniff, a BOM and CRLF rows
ok 14 - SEC-01: injection payloads in any parameter are refused as data, and nothing is returned
not ok 15 - options describe the version, the scope, the releases and the reportable surface only
  error: |-
# pass 13
# fail 2
# skipped 0
restored: sha256 9008db41e4ee51300a1159a74bfacde7a93fd00b6bcffd88d0fe66f6d575287b (identical to before)

## M4: a release accepts filters that narrow who is counted
file: src/reports/ReportService.cfc  (sha256 before mutation 9008db41e4ee51300a1159a74bfacde7a93fd00b6bcffd88d0fe66f6d575287b)
mutation (unified diff of the file before and after the mutation):
--- a/src/reports/ReportService.cfc
+++ b/src/reports/ReportService.cfc
@@ -572,3 +572,3 @@
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
restored: sha256 9008db41e4ee51300a1159a74bfacde7a93fd00b6bcffd88d0fe66f6d575287b (identical to before)

## M5: instrument-rule links ignored: linked breakdowns suppressed independently
file: src/reports/ReportService.cfc  (sha256 before mutation 9008db41e4ee51300a1159a74bfacde7a93fd00b6bcffd88d0fe66f6d575287b)
mutation (unified diff of the file before and after the mutation):
--- a/src/reports/ReportService.cfc
+++ b/src/reports/ReportService.cfc
@@ -1112,3 +1112,3 @@
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
restored: sha256 9008db41e4ee51300a1159a74bfacde7a93fd00b6bcffd88d0fe66f6d575287b (identical to before)

## M6: aggregate, then suppress: blocks summed before protection, so district minus schools gives cells back
file: src/reports/ReportService.cfc  (sha256 before mutation 9008db41e4ee51300a1159a74bfacde7a93fd00b6bcffd88d0fe66f6d575287b)
mutation (unified diff of the file before and after the mutation):
--- a/src/reports/ReportService.cfc
+++ b/src/reports/ReportService.cfc
@@ -877,2 +877,3 @@
 		var byUnit = {};
+		var pooledCells = {};
 		for (var b in blocks) {
@@ -881,4 +882,5 @@
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
restored: sha256 9008db41e4ee51300a1159a74bfacde7a93fd00b6bcffd88d0fe66f6d575287b (identical to before)

## M7: the protected value is sent alongside the suppression flag
file: src/reports/ReportService.cfc  (sha256 before mutation 9008db41e4ee51300a1159a74bfacde7a93fd00b6bcffd88d0fe66f6d575287b)
mutation (unified diff of the file before and after the mutation):
--- a/src/reports/ReportService.cfc
+++ b/src/reports/ReportService.cfc
@@ -948,3 +948,3 @@
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
META,,generated_at,2026-09-23T14:22:54.013Z,,,,,
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
restored: sha256 9008db41e4ee51300a1159a74bfacde7a93fd00b6bcffd88d0fe66f6d575287b (identical to before)

## M8: the CSV writes a number where the JSON withholds one
file: src/reports/ReportService.cfc  (sha256 before mutation 9008db41e4ee51300a1159a74bfacde7a93fd00b6bcffd88d0fe66f6d575287b)
mutation (unified diff of the file before and after the mutation):
--- a/src/reports/ReportService.cfc
+++ b/src/reports/ReportService.cfc
@@ -1449,3 +1449,3 @@
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
META,,generated_at,2026-09-23T14:23:34.792Z,,,,,
META,,statuse].  /home/user/ICFWalk/tests/cfml/BaseSpec.cfc:38
   failed testTheExportCarriesExactlyWhatTheJsonPublishes :: prek_k_q1 option yes Expected exactly [] (0 chars) but got [0] (1 chars); one is a prefix of the other (0 and 1 chars).  /home/user/ICFWalk/tests/cfml/BaseSpec.cfc:38
TOTAL {"failed":2,"passed":13,"skipped":0}
$ ICFWALK_REQUIRE_APP=1 node --test tests/node/reports.test.mjs
ok 1 - RPT-06 (structural): the report repository selects no narrative, identifying or teacher column
ok 2 - P7C-01 / P7C-02 (structural): report tables are connection-local, and release membership is never read out
ok 3 - reports are driven by the instrument, not by names written into the report code
ok 4 - SEC-02 (structural): the reports view builds its DOM without HTML strings
ok 5 - AUTH-01: every report route requires an identity and discloses nothing without one
ok 6 - AUTH-06 / RPT-03: instrument administration and role-less users are refused every report route
ok 7 - RPT-03: a report-only role is refused every live figure, however the request is narrowed
ok 8 - RPT-01: a school report role reads its school's release; another school is 404 over HTTP
ok 9 - RPT-02: district roles aggregate their descendant schools and nothing else, live or released
ok 10 - RPT-03 / RPT-06: payload and export carry no walk, owner, narrative, email or free text
ok 11 - releases: only someone who can open every walk may release, with CSRF, a closed period, and no overlap
ok 12 - report routes are read-only: other methods are refused before anything runs
not ok 13 - the CSV export is an attachment with a safe name, no-store, nosniff, a BOM and CRLF rows
  error: 'the single rating of 2: an empty count, flagged withheld'
ok 14 - SEC-01: injection payloads in any parameter are refused as data, and nothing is returned
ok 15 - options describe the version, the scope, the releases and the reportable surface only
# pass 14
# fail 1
# skipped 0
restored: sha256 9008db41e4ee51300a1159a74bfacde7a93fd00b6bcffd88d0fe66f6d575287b (identical to before)

## M9: the report log line carries figures
file: src/reports/ReportService.cfc  (sha256 before mutation 9008db41e4ee51300a1159a74bfacde7a93fd00b6bcffd88d0fe66f6d575287b)
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
restored: sha256 9008db41e4ee51300a1159a74bfacde7a93fd00b6bcffd88d0fe66f6d575287b (identical to before)

## M10: the block floor removed where a release is frozen (the database guard is what refuses it)
file: src/reports/ReportService.cfc  (sha256 before mutation 9008db41e4ee51300a1159a74bfacde7a93fd00b6bcffd88d0fe66f6d575287b)
mutation (unified diff of the file before and after the mutation):
--- a/src/reports/ReportService.cfc
+++ b/src/reports/ReportService.cfc
@@ -462,3 +462,2 @@
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
restored: sha256 9008db41e4ee51300a1159a74bfacde7a93fd00b6bcffd88d0fe66f6d575287b (identical to before)

## M11: the overlap check removed from the service (the database trigger is what refuses it)
file: src/reports/ReportService.cfc  (sha256 before mutation 9008db41e4ee51300a1159a74bfacde7a93fd00b6bcffd88d0fe66f6d575287b)
mutation (unified diff of the file before and after the mutation):
--- a/src/reports/ReportService.cfc
+++ b/src/reports/ReportService.cfc
@@ -285,3 +285,3 @@
 			reports.lockReleases();
-			if (reports.overlapsRelease(span.fromText, span.toText)) {
+			if (false) {
 				variables.errors.conflict("Those dates overlap dates that have already been released. Released dates never overlap.", "REPORT_RELEASE_OVERLAP");
restart: Health: {"application":"ICFWalk","checks":{"database":"ok","
$ CFML ReportReleaseTest
ReportReleaseTest passed=14 failed=1 skipped=0
   failed testReleasedDatesNeverOverlap :: Expected exception type starting with [ICFWalk.Conflict] but got [database]: A report release must not cover a date another release covers.  /home/user/ICFWalk/tests/cfml/BaseSpec.cfc:38
TOTAL {"failed":1,"passed":14,"skipped":0}
restored: sha256 9008db41e4ee51300a1159a74bfacde7a93fd00b6bcffd88d0fe66f6d575287b (identical to before)

## M12: P7C-01 as the audit describes it: one fixed pair of global (##) population tables shared by every request
file: src/reports/ReportRepository.cfc  (sha256 before mutation ba16f7eda9f12331bd2f895c02f0c99ab4d84eb0091afff66682aa5e52a25a3a)
mutation (unified diff of the file before and after the mutation):
--- a/src/reports/ReportRepository.cfc
+++ b/src/reports/ReportRepository.cfc
@@ -99,4 +99,4 @@
 		var population = {
-			"pop": variables.LOCAL_TEMP & "icf_rp_" & token,
-			"units": variables.LOCAL_TEMP & "icf_ru_" & token,
+			"pop": variables.LOCAL_TEMP & variables.LOCAL_TEMP & "icf_report_population",
+			"units": variables.LOCAL_TEMP & variables.LOCAL_TEMP & "icf_report_units",
 			"spid": 0
@@ -150,3 +150,3 @@
 	private void function checkName(required string name) {
-		if (!reFind("^" & variables.LOCAL_TEMP & "icf_r[pu]_[0-9A-F]{32}$", arguments.name)) {
+		if (false) {
 			throw(type = "ICFWalk.Configuration", message = "A report population table name is malformed.", errorcode = "REPORT_POPULATION_NAME_INVALID");
restart: Health: {"application":"ICFWalk","checks":{"database":"ok","
$ CFML ReportIsolationTest
ReportIsolationTest passed=2 failed=5 skipped=0
   failed testALiveReportAndAReleaseAreIsolatedAtTheScopeBoundary :: the release finished while the live report held its scope and population (; session 61 waits on 59 (LCK_M_X KEY: 2:562949955649536 (7c4b09f6b1ab), CREATE TABLE)) Expected exactly [COMPLETED] (9 chars) but got [RUNNING] (7 chars); the first difference is at character 1 ([C] expected, [R] found).  /home/user/ICFWalk/tests/cfml/Base ...[line truncated here; 411 characters in the raw output]
   failed testAReleaseAndALiveReportAreIsolatedAtTheScopeBoundary :: the live report finished while the release held its scope, population and release lock (; session 59 waits on 61 (LCK_M_X KEY: 2:562949955649536 (7c4b09f6b1ab), CREATE TABLE)) Expected exactly [COMPLETED] (9 chars) but got [RUNNING] (7 chars); the first difference is at character 1 ([C] expected, [R] found).  /home/user/ICFWalk/t ...[line truncated here; 425 characters in the raw output]
   failed testAReportLeavesNoPopulationTableBehindOnSuccessOrFailure :: its two tables existed when it failed Expected [2] but got [0].  /home/user/ICFWalk/tests/cfml/BaseSpec.cfc:38
   failed testPopulationTablesAreConnectionLocalAndUniquePerComputation :: There is already an object named '##icf_report_units' in the database.  /home/user/ICFWalk/src/core/Db.cfc:19
   failed testTwoReportsOnDisjointScopesAreIsolatedAtTheScopeBoundary :: report B finished while report A held its scope and population: B did not wait on A (; session 61 waits on 59 (LCK_M_X KEY: 2:562949955649536 (7c4b09f6b1ab), CREATE TABLE)) Expected exactly [COMPLETED] (9 chars) but got [RUNNING] (7 chars); the first difference is at character 1 ([C] expected, [R] found).  /home/user/ICFWalk/ ...[line truncated here; 426 characters in the raw output]
TOTAL {"failed":5,"passed":2,"skipped":0}
restored: sha256 ba16f7eda9f12331bd2f895c02f0c99ab4d84eb0091afff66682aa5e52a25a3a (identical to before)

## M13: P7C-01 guard removed: a population may be built outside a transaction
file: src/reports/ReportRepository.cfc  (sha256 before mutation ba16f7eda9f12331bd2f895c02f0c99ab4d84eb0091afff66682aa5e52a25a3a)
mutation (unified diff of the file before and after the mutation):
--- a/src/reports/ReportRepository.cfc
+++ b/src/reports/ReportRepository.cfc
@@ -112,3 +112,3 @@
 		);
-		if (q.open_transactions[1] < 1) {
+		if (false) {
 			throw(type = "ICFWalk.Configuration", message = "A report population must be built inside a transaction.", errorcode = "REPORT_POPULATION_NO_TRANSACTION");
restart: Health: {"application":"ICFWalk","checks":{"database":"ok","
$ CFML ReportIsolationTest
ReportIsolationTest passed=6 failed=1 skipped=0
   failed testAPopulationIsRefusedOutsideATransaction :: Expected an exception of type [ICFWalk.Configuration] but nothing was thrown.  /home/user/ICFWalk/tests/cfml/BaseSpec.cfc:38
TOTAL {"failed":1,"passed":6,"skipped":0}
restored: sha256 ba16f7eda9f12331bd2f895c02f0c99ab4d84eb0091afff66682aa5e52a25a3a (identical to before)

## M14: P7C-01 guard removed: a population goes on after its statements reach another connection
file: src/reports/ReportRepository.cfc  (sha256 before mutation ba16f7eda9f12331bd2f895c02f0c99ab4d84eb0091afff66682aa5e52a25a3a)
mutation (unified diff of the file before and after the mutation):
--- a/src/reports/ReportRepository.cfc
+++ b/src/reports/ReportRepository.cfc
@@ -160,3 +160,3 @@
 		var spid = variables.db.scalar("SELECT @@SPID AS spid");
-		if (spid != arguments.population.spid) {
+		if (false) {
 			throw(type = "ICFWalk.Conflict", message = "The report moved to another database connection and was discarded.", errorcode = "REPORT_POPULATION_CONNECTION_CHANGED");
restart: Health: {"application":"ICFWalk","checks":{"database":"ok","
$ CFML ReportIsolationTest
ReportIsolationTest passed=6 failed=1 skipped=0
   failed testAPopulationRefusesToContinueOnAnotherConnection :: verification refuses a session other than the one that built the population Expected exactly [REPORT_POPULATION_CONNECTION_CHANGED] (36 chars) but got [] (0 chars); one is a prefix of the other (36 and 0 chars).  /home/user/ICFWalk/tests/cfml/BaseSpec.cfc:38
TOTAL {"failed":1,"passed":6,"skipped":0}
restored: sha256 ba16f7eda9f12331bd2f895c02f0c99ab4d84eb0091afff66682aa5e52a25a3a (identical to before)

## M15: P7C-02: a new release no longer leaves out walks an earlier release counted (the database key is what refuses it)
file: src/reports/ReportService.cfc  (sha256 before mutation 9008db41e4ee51300a1159a74bfacde7a93fd00b6bcffd88d0fe66f6d575287b)
mutation (unified diff of the file before and after the mutation):
--- a/src/reports/ReportService.cfc
+++ b/src/reports/ReportService.cfc
@@ -382,3 +382,3 @@
 			// a candidate again, wherever a correction has moved its date since (P7C-02).
-			reports.selectCandidates(population, arguments.versionId, ["COMPLETED"], arguments.observedFrom, arguments.observedBefore, true);
+			reports.selectCandidates(population, arguments.versionId, ["COMPLETED"], arguments.observedFrom, arguments.observedBefore, false);
 			// S2: every aggregate reads child rows.
restart: Health: {"application":"ICFWalk","checks":{"database":"ok","
$ CFML ReportReleaseMembershipTest
ReportReleaseMembershipTest passed=1 failed=1 skipped=0
   failed testAWalkWhoseDateIsCorrectedIntoLaterDatesIsNeverCountedByASecondRelease :: Violation of PRIMARY KEY constraint 'PK_report_release_walk'. Cannot insert duplicate key in object 'icf.report_release_walk'. The duplicate key value is (9af73c1b-c895-4d2f-b5eb-ee901fb84381).  /home/user/ICFWalk/src/core/Db.cfc:19
TOTAL {"failed":1,"passed":1,"skipped":0}
restored: sha256 9008db41e4ee51300a1159a74bfacde7a93fd00b6bcffd88d0fe66f6d575287b (identical to before)

## M16: P7C-02: a release stores its blocks without recording the walks they count (the database trigger is what refuses it)
file: src/reports/ReportService.cfc  (sha256 before mutation 9008db41e4ee51300a1159a74bfacde7a93fd00b6bcffd88d0fe66f6d575287b)
mutation (unified diff of the file before and after the mutation):
--- a/src/reports/ReportService.cfc
+++ b/src/reports/ReportService.cfc
@@ -298,3 +298,2 @@
 				for (var b in frozen.blocks) {
-					reports.insertMembers(releaseId, versionId, b.orgUnitId, b.walkIds);
 					reports.insertBlock(releaseId, versionId, b.orgUnitId, b.walks);
restart: Health: {"application":"ICFWalk","checks":{"database":"ok","
$ CFML ReportReleaseMembershipTest
ReportReleaseMembershipTest passed=0 failed=2 skipped=0
   failed testAWalkWhoseDateIsCorrectedIntoLaterDatesIsNeverCountedByASecondRelease :: A report release block must count exactly the walks recorded for it.  /home/user/ICFWalk/src/core/Db.cfc:19
   failed testTheDatabaseRefusesToPutAReleasedWalkIntoAnotherRelease :: A report release block must count exactly the walks recorded for it.  /home/user/ICFWalk/src/core/Db.cfc:19
TOTAL {"failed":2,"passed":0,"skipped":0}
restored: sha256 9008db41e4ee51300a1159a74bfacde7a93fd00b6bcffd88d0fe66f6d575287b (identical to before)

exit 0
```
