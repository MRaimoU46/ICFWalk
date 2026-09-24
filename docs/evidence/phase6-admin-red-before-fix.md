# Phase 6 administration: red before green

Environment for every run below: Lucee 6.2.8.20 (Jetty), SQL Server 2022 Developer in Docker,
Node 22.22.2, Playwright 1.56.1 with Chromium. Base commit `0c6fa10972593043508f502538534c2aa95c671b`.
Adobe ColdFusion 2023 and SQL Server 2016 were not available and were not run.

Each entry names the failing check, what it printed, the cause, and the change that made it pass.
The green side is the same check passing on the finished tree.

## 1. A walk could be pinned to a version that was already retired (behavioral)

`RetireConcurrencyBarrierTest` drives a real walk creation and a real retirement through the
two-sided barrier (`A_LOCKED` / `B_AT_COMPETING_BOUNDARY`, the test-only seams on
`InterceptingWalkRepository.insertWalk` and `InterceptingDefinitionRepository.markRetired`).
Captured with retirement implemented and the walk insert still the unqualified
`INSERT ... VALUES` it had been since Phase 4:

```
FAILED  RetireConcurrencyBarrierTest.testARetirementInsideCreationsWindowRefusesTheWalk
        Expected an exception of type [ICFWalk.Conflict] but nothing was thrown.
FAILED  RetireConcurrencyBarrierTest.testARetirementQueuesBehindAWalkAlreadyPinnedToTheVersion
        and succeeded (retirement failed: ... Transaction (Process ID 65) was deadlocked on lock
        resources with another process and has been chosen as the deadlock victim. Rerun the
        transaction.) Expected exactly [retired] (7 chars) but got [database] (8 chars)
TOTALS passed=0 failed=2 skipped=0 ms=17442
```

Cause. `WalkService.create` resolves the current version, then inserts the walk. A retirement
committing between the two left the new walk pinned to a RETIRED version (case 1). When the walk's
insert came first and the retirement arrived while the walk's transaction was still open, the two
transactions deadlocked and SQL Server chose a victim (case 2). The deadlock graph was not captured;
what is known is that the unqualified insert took no lock on the version row that a retirement had
to wait for, so the two acquired their locks in no agreed order.

Fix. `WalkRepository.insertWalk` is a status-qualified `INSERT ... SELECT` from the version row
`WITH (HOLDLOCK, ROWLOCK)` where the status is not RETIRED, with `OUTPUT INSERTED`. Nothing inserted
means the version was retired, and `WalkService.create` answers 409 `INSTRUMENT_VERSION_CHANGED`
with `details.retiredVersionId`. The held range lock makes a later retirement queue behind the
walk's transaction instead of deadlocking. Green: both cases pass, every run.

## 2. An import request without a `document` was a 500 (behavioral)

`tests/node/admin-instrument.test.mjs`, "ADM-01: the import body contract and the size cap":

```
POST /api/admin/instrument/import  {}
{"error":{"code":"INTERNAL_ERROR", ... "details":{"exceptionMessage":"The parameter [document] to
function [importDocument] is required but was not passed in.","exceptionType":"expression"}, ...}}
500 !== 400
```

Cause. `InstrumentAdminService.importDocument` declared `required any document`. The controller
passes null for an absent member, and the engine rejects a null required argument before the
method's own check can run.

Fix. The argument is not `required`; the method's `isNull` check raises 400 `DOCUMENT_REQUIRED`.
Green: 11/11 in `admin-instrument.test.mjs`.

## 3. Retiring the only version in service made Reports unopenable (behavioral, cross-phase)

`InstrumentAdministrationTest.testReportsStillOpenWhenNoVersionIsInService`, written before the fix:

```
FAILED  InstrumentAdministrationTest.testReportsStillOpenWhenNoVersionIsInService
        No instrument version is available to report on yet.
        at /home/user/ICFWalk/src/core/Errors.cfc:111
TOTALS passed=16 failed=1 skipped=0
```

Cause. Phase 7's `ReportService.resolveVersion` defaulted only to the current version. Once the
only in-service version is retired with confirmation there is none, so `/api/reports/options`
without a `versionId` was 404 and the Reports view could not load to offer the retired version its
walks still belong to.

Fix. With nothing in service, the default is the newest frozen version (first in the list the
service already builds). Green: 17/17 in `InstrumentAdministrationTest`; `ReportServiceTest` 15/15
and `ReportCoherenceTest` 4/4 unchanged.

## 4. Two retirements at once could leave nothing in service (behavioral)

Found in review of the retirement code, then proved: `retire` refuses to leave an instrument with
no version in service unless confirmed, but decided that from the other versions' rows without
serializing against another retirement. `RetireConcurrencyBarrierTest.testTwoRetirementsCannotTogetherLeaveNothingInService`
holds A (retiring V1) just after it has found V0 still in service, and starts B (retiring V0).
Before the fix, B never reached a competing boundary; it ran to completion while A waited:

```
PASSED  RetireConcurrencyBarrierTest.testARetirementInsideCreationsWindowRefusesTheWalk
PASSED  RetireConcurrencyBarrierTest.testARetirementQueuesBehindAWalkAlreadyPinnedToTheVersion
FAILED  RetireConcurrencyBarrierTest.testTwoRetirementsCannotTogetherLeaveNothingInService
        V0 is still in service: the two retirements did not together leave nothing Expected exactly
        [PUBLISHED] (9 chars) but got [RETIRED] (7 chars)
TOTALS passed=2 failed=1 skipped=0 ms=20782
```

Fix. `DefinitionRepository.lockRetirement` takes an exclusive, transaction-owned `sp_getapplock`
named for the instrument; `retire` takes it after its version lock and before the successor check.
Only retirement takes it, so no other operation's lock order changes. Green: B announces
`B_AT_COMPETING_BOUNDARY` before the lock, stays queued while A holds it, then sees V1 retired and is
refused `RETIRE_LEAVES_NO_CURRENT_VERSION`; V0 stays in service. 3/3, repeated three times.

## 5. Absent capability: every new check fails against the base source

To show the new checks test something, the Phase 6 source (`src/`, `app/`, `package.json`) was
stashed, leaving only the new and changed tests, and Lucee restarted on `0c6fa10`. Then the stash was
restored and Lucee restarted again.

| Check | Result on the base source | Why |
| --- | --- | --- |
| `DraftEditorTest` | 0 passed, 11 failed | `key [DRAFTEDITOR] doesn't exist` |
| `InstrumentVersionComparerTest` | 0 passed, 6 failed | the comparer does not exist |
| `InstrumentAdministrationTest` | 0 passed, 16 failed (+ afterAll) | `key [INSTRUMENTADMINSERVICE] doesn't exist` |
| `RetireConcurrencyBarrierTest` | 0 passed, 2 failed | `DefinitionRepository` has no `currentVersionIds` / `markRetired` (the third case was written later; entry 4 is its red) |
| `InstrumentImmutabilityTest` | 13 passed, 2 failed | `markRetired` is named in the lifecycle inventory but does not exist |
| `admin-instrument.test.mjs` | 0 passed, 11 failed | every new route is 404 `NOT_FOUND` |
| `browser-admin.test.mjs` | 0 passed, 6 failed | the administration view does not exist |

## Green on the finished tree (development runs)

| Check | Result |
| --- | --- |
| `DraftEditorTest`, `InstrumentVersionComparerTest`, `InstrumentAdministrationTest`, `RetireConcurrencyBarrierTest`, `InstrumentImmutabilityTest` | 11/11, 6/6, 17/17, 3/3, 15/15 |
| `ReportServiceTest`, `ReportCoherenceTest` | 15/15, 4/4 |
| `admin-instrument.test.mjs`, `browser-admin.test.mjs` | 11/11, 6/6 |
| `shell`, `visibility`, `admin-publish`, `walks`, `browser`, `browser-reports`, `browser-persistence` | 102/102 |

The full gate on a freshly created database is recorded in `phase6-admin-release-gate.txt`.
