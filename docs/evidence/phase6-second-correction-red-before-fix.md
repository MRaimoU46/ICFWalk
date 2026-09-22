# Phase 6 publish-foundation second correction: red before green

Every regression family added by this correction was run against the **audited starting commit's
production code** before the fix, and failed there for the reason the fix exists. This file records
those runs.

## How the red runs were taken

The new and strengthened test files were left in place, and only the corrected *production* code was
withdrawn:

```
$ git stash push -m "phase6-second-correction-production" -- src database/006_version_scoped_dimensions.sql
Saved working directory and index state On claude/icfwalk-phase-6-admin-publish: phase6-second-correction-production
```

That leaves `src/` and `database/006_version_scoped_dimensions.sql` exactly as commit
`332f89f929ff5a9f1e81fe5273c830698fdc80af` has them, with the tests that are meant to catch its
defects already written. The application was restarted so Lucee recompiled from the reverted source,
each spec was run through the live CFML suite endpoint, and the corrected code was then restored
with `git stash pop`. Two files (`src/instrument/RenderContractValidator.cfc` and
`src/instrument/InstrumentMetadataService.cfc`) are new and therefore untracked, so they stayed on
disk during the red run; nothing references them from the audited `Bootstrap.cfc`, so they are inert
there.

Where a red failure is "this capability does not exist" rather than "this capability is wrong", it
is labelled as such below. That is the honest form of red for a guard that was absent: the audited
code has no `updateInstrumentMetadata`, and no version argument on the global identity creators, so
a test of those guards cannot fail any other way.

## Totals, against the audited production code

| Spec | Result before the fix |
| --- | --- |
| `ValidatorRendererContractTest` | **14 failed**, 4 passed |
| `ImportPublishEquivalenceTest` | **10 failed**, 4 passed |
| `InstrumentPublishServiceTest` | **21 failed**, 27 passed |
| `InstrumentImmutabilityTest` | **8 failed**, 7 passed |
| `SharedInstrumentBoundaryTest` | **8 failed**, 0 passed |
| `Migration006LifecycleTest` | **1 failed**, 2 passed |
| `PublishConcurrencyBarrierTest` | **3 failed**, 0 passed |

After the correction, on the same live environment: **CFML 330 passed, 0 failed, 0 skipped**.

## Finding A: publication validity did not imply runtime renderability

`ValidatorRendererContractTest`, against the audited validator. Each case proves the renderer
rejects or silently drops the state, then asserts the shared validator refuses it. The renderer half
passed; the validator half did not exist.

```
FAIL testNoActiveRootSectionIsRefused
     the shared validator must refuse this state; it reported nothing
FAIL testTwoActiveRootSectionsAreRefused
     the shared validator must refuse this state; it reported nothing
FAIL testActiveSectionUnderAnInactiveParentIsRefused
     the shared validator must refuse this state; it reported nothing
FAIL testActiveItemInAnInactiveSectionIsRefused
     the shared validator must refuse this state; it reported nothing
FAIL testMultiChoiceIsRefusedBecauseTheRuntimeDoesNotImplementIt
     the shared validator must refuse this state; it reported nothing
FAIL testShortTextIsRefusedBecauseTheRuntimeDoesNotImplementIt
     the shared validator must refuse this state; it reported nothing
FAIL testUnknownOptionFilterIsRefused
     the shared validator must refuse this state; it reported nothing
FAIL testActiveItemReferencingAnInactiveResponseSetIsRefused
     the shared validator must refuse this state; it reported nothing
FAIL testActiveChoiceItemWhoseSetHasNoActiveOptionIsRefused
     the shared validator must refuse this state; it reported nothing
FAIL testActivePlacementOfAnInactiveDimensionIsRefused
     the shared validator must refuse this state; it reported nothing
FAIL testActiveListPlacementWithNoActiveValuesIsRefused
     the shared validator must refuse this state; it reported nothing
FAIL testActiveRuleTargetingInactiveContentIsRefused
     the shared validator must refuse this state; it reported nothing
FAIL testActiveRuleSourcedFromInactiveContentIsRefused
     the shared validator must refuse this state; it reported nothing
FAIL testRetiredItemTypesAreRefusedAtImportToo
     an import document naming MULTI_CHOICE is refused
```

The last line is `assertFalse(result.valid)` failing: the audited import path **accepted** a
document declaring `MULTI_CHOICE`.

The four that passed are the two positive contract cases (the supplied instrument and a
hand-written minimal instrument both build completely), the supported-option-filter case, and the
detached-subtree case, which the audited validator already caught as `MISSING_REFERENCE`.

The same defects at the publish boundary, on checksum-matching, drift-free versions
(`InstrumentPublishServiceTest`). Each of these published successfully against the audited code:

```
FAIL testSemanticNoActiveRootIsRefused                     Expected an exception ... but nothing was thrown.
FAIL testSemanticTwoActiveRootsAreRefused                  Expected an exception ... but nothing was thrown.
FAIL testSemanticSectionOrphanedByAnInactiveParentIsRefused  Expected an exception ... but nothing was thrown.
FAIL testSemanticItemOrphanedByAnInactiveSectionIsRefused  Expected an exception ... but nothing was thrown.
FAIL testSemanticMultiChoiceItemTypeIsRefused              Expected an exception ... but nothing was thrown.
FAIL testSemanticShortTextItemTypeIsRefused                Expected an exception ... but nothing was thrown.
FAIL testSemanticUnknownOptionFilterIsRefused              Expected an exception ... but nothing was thrown.
FAIL testSemanticActiveItemWithInactiveResponseSetIsRefused  Expected an exception ... but nothing was thrown.
FAIL testSemanticChoiceItemWithNoActiveOptionIsRefused     Expected an exception ... but nothing was thrown.
FAIL testSemanticPlacementOfInactiveDimensionIsRefused     Expected an exception ... but nothing was thrown.
FAIL testSemanticListPlacementWithNoActiveValuesIsRefused  Expected an exception ... but nothing was thrown.
```

## Finding B: migration 006 inferred membership on every re-application

Two independent red runs.

**1. The lifecycle spec against the audited migration file.** `Migration006LifecycleTest` publishes
V1, primes both caches, imports V2 with a new value under a shared dimension, then re-applies `006`:

```
FAIL testReapplying006AfterV2AddsANewValueLeavesPublishedV1Untouched
     Cannot insert duplicate key row in object 'icf.instrument_dimension_value'
     with unique index 'UX_instrument_dimension_value_order'.
     The duplicate key value is (5d3e483f-..., 21621bea-..., 10).
```

The re-applied backfill tried to insert V2's new value into **published V1** and collided with V1's
existing display order. The attempt is the defect; whether it collides depends only on which order
the new value happens to take.

**2. An isolated before/after harness**, run on two throwaway databases seeded identically
(Phase 5 schema, one published V1 placing a list dimension with two values, then V2 minting a third
value globally), differing only in which form of `006` is re-applied:

```
EARLIER 006 (audited): reapply OK
   V1 membership rows before=2 after=3  checksum moved=false  rowversion moved=false
   => DEFECT: published V1 gained a V2-only value

CORRECTED 006: reapply OK
   V1 membership rows before=2 after=2  checksum moved=false  rowversion moved=false
   => CORRECT: published V1 unchanged
```

That is the whole defect in two lines: V1's accepted walk values changed, and neither its checksum
nor its `row_version` moved, so nothing downstream could see it.

## Finding C: the shared and global write boundary was open

`SharedInstrumentBoundaryTest` could not even construct against the audited container, because the
operation that is supposed to own the shared row did not exist:

```
FAIL testImportingV2WithAnInactiveInstrumentCannotHidePublishedV1
     beforeAll failed: key [INSTRUMENTMETADATASERVICE] doesn't exist
FAIL testImportingV2RenamesOnlyItsOwnVersionAndNotTheSharedRow
     beforeAll failed: key [INSTRUMENTMETADATASERVICE] doesn't exist
FAIL testImportingV2CannotAlterWhatTheRuntimeServesForV1
     beforeAll failed: key [INSTRUMENTMETADATASERVICE] doesn't exist
FAIL testARefusedSharedMetadataConflictChangesNothingAndIsAudited
     beforeAll failed: key [INSTRUMENTMETADATASERVICE] doesn't exist
FAIL testTheAuthorizedOperationCanChangeSharedMetadataAndAuditsIt
     beforeAll failed: key [INSTRUMENTMETADATASERVICE] doesn't exist
FAIL testTheAuthorizedOperationRefusesAnUnknownActor
     beforeAll failed: key [INSTRUMENTMETADATASERVICE] doesn't exist
FAIL testTheAuthorizedOperationHasNoRoute
     beforeAll failed: key [INSTRUMENTMETADATASERVICE] doesn't exist
```

This is the "capability absent" form of red: the audited build has no authorized instrument-level
operation at all, because the importer wrote the shared row itself, unconditionally, from the
document.

The inventory failures are the sharper evidence, because they are about the audited code's own
claims (`InstrumentImmutabilityTest`):

```
FAIL testEveryRepositoryMutatorIsCoveredHere
     DefinitionRepository mutators with no immutability coverage: updateInstrument
     Expected [0] but got [1].
FAIL testTheSharedAndGlobalInventoryNamesOnlyRealMethods
     the inventory names methods that no longer exist: updateInstrumentMetadata
     Expected [0] but got [1].
FAIL testEverySharedOrGlobalMutatorEnforcesItsOwnContract
     Expected exception type starting with [ICFWalk.Validation] but got [expression]:
     Component [icfwalk.instrument.DefinitionRepository] has no function with name [updateInstrumentMetadata]
FAIL testARefusedGlobalIdentityCreationWritesNothing
     Expected exception type starting with [ICFWalk.Publish.NotDraft] but got [expression]:
     Invalid call of the function [createDimensionIdentity], first Argument [row] is of invalid type,
     Cannot cast String [10CE2CAF-...] to a value of type [struct]
FAIL testGlobalIdentityCreationStillWorksForADraft
     Invalid call of the function [createDimensionIdentity], first Argument [row] is of invalid type,
     Cannot cast String [70701EB8-...] to a value of type [struct]
```

`testEveryRepositoryMutatorIsCoveredHere` is the load-bearing one. Once the exclusion list is
removed, the audited repository's own metadata reports `updateInstrument` as a public mutator with
no immutability coverage -- which is exactly the method that could make a published version
disappear.

The two `createDimensionIdentity` failures show that the audited signature takes no version at all:
the spec passes a version id first and the audited method reads it as the row struct.

## Finding D (section 9): DRAFT-in-use refusals left no trace

`InstrumentImmutabilityTest`, against the audited import service:

```
FAIL testRefusedImportOfADraftInUseRollsBackAndLeavesExactlyOneDurableAudit
     exactly one refusal survived the rollback Expected [1] but got [0].
FAIL testRefusedDiscardOfADraftInUseRollsBackAndLeavesExactlyOneDurableAudit
     exactly one refusal survived the rollback Expected [1] but got [0].
```

Both branches threw `INSTRUMENT_VERSION_IN_USE` without marking the refusal first, so the catch that
writes the post-rollback audit had nothing to write. Zero records, for an attempt that really
happened.

## Finding (section 7): two semantic rule sets

`ImportPublishEquivalenceTest`. Six cases fail on *paths*, and the failure message is itself the
proof that two rule sets were running -- the same defect is reported twice, from two different
components, at two different paths:

```
FAIL testChoiceItemWithoutAResponseSetIsReportedIdenticallyByBothPaths
     import and publish must report ITEM_RESPONSE_SET_REQUIRED at the same path(s)
     Expected [$.definitions.items[139].responseSetKey]
     but got  [$.definitions.items[139].responseSetKey | $.items[0].responseSetId]
FAIL testUnsupportedRuleEffectIsReportedIdenticallyByBothPaths
     Expected [$.definitions.rules[11].effect]
     but got  [$.definitions.rules[11].effect | $.rules[0].effect]
FAIL testInvalidDimensionDataTypeIsReportedIdenticallyByBothPaths
     Expected [$.definitions.dimensions[2].dataType]
     but got  [$.definitions.dimensions[2].dataType | $.dimensions[0].dataType]
FAIL testInvalidDisplayOrderIsReportedIdenticallyByBothPaths
     Expected [$.definitions.items[139].displayOrder]
     but got  [$.definitions.items[139].displayOrder | $.items[0].displayOrder]
FAIL testBlankSectionTitleIsReportedIdenticallyByBothPaths
     Expected [$.definitions.sections[22].title]
     but got  [$.definitions.sections[22].title | $.sections[1].title]
FAIL testRetiredContentIsReportedIdenticallyByBothPaths
     Expected [$.definitions] but got [$ | $.definitions]
```

And four cases where the two rule sets did not merely duplicate but **disagreed** -- import accepted
a document that publish would refuse:

```
FAIL testUnsupportedItemTypeIsReportedIdenticallyByBothPaths   import must refuse this document
FAIL testInactiveRootIsReportedIdenticallyByBothPaths          import must refuse this document
FAIL testUnknownOptionFilterIsReportedIdenticallyByBothPaths   import must refuse this document
FAIL testInactiveResponseSetIsReportedIdenticallyByBothPaths   import must refuse this document
```

## Finding (section 8): the snapshot envelope and canonical bytes

`InstrumentPublishServiceTest`, against the audited validator:

```
FAIL testEnvelopeWithNoCountsIsRefused            Expected an exception of type [ICFWalk.Publish] but nothing was thrown.
FAIL testEnvelopeWithEmptyCountsIsRefused         Expected an exception of type [ICFWalk.Publish] but nothing was thrown.
FAIL testEnvelopeWithNoPlaceholderCountIsRefused  Expected an exception of type [ICFWalk.Publish] but nothing was thrown.
FAIL testEnvelopeWithAnUnexpectedCountIsRefused   Expected an exception of type [ICFWalk.Publish] but nothing was thrown.
FAIL testEnvelopeWithAnyMissingCountMemberIsRefused
     Component [icfwalk.instrument.DefinitionValidator] has no function with name [snapshotCountKeys]
FAIL testEnvelopeWithNonNumericCountIsRefused
     expected one of SNAPSHOT_COUNTS_INVALID but got
     [{"message":"The stored snapshot's counts.items is many but it carries 144.", ... "code":"SNAPSHOT_COUNTS_MISMATCH"}]
FAIL testEnvelopeWithFractionalCountIsRefused
     expected one of SNAPSHOT_COUNTS_INVALID but got
     [{"message":"The stored snapshot's counts.items is 144.5 but it carries 144.", ... "code":"SNAPSHOT_COUNTS_MISMATCH"}]
FAIL testEnvelopeWithNegativeCountIsRefused
     expected one of SNAPSHOT_COUNTS_INVALID but got
     [{"message":"The stored snapshot's counts.rules is -1 but it carries 12.", ... "code":"SNAPSHOT_COUNTS_MISMATCH"}]
FAIL testNoncanonicalSnapshotBytesAreRefusedEvenWithAMatchingChecksum
FAIL testSnapshotWithNoncanonicalKeyOrderIsRefused
```

The three "MISMATCH instead of INVALID" lines are worth reading closely: the audited validator did
notice `"many"`, `144.5` and `-1`, but only as a count that disagreed with the array length. It had
no notion that a count must be a whole non-negative number, so a snapshot whose `counts.items` was
the string `"144"` would have passed.

The last two are the canonical-byte contract, which the audited code did not check at all: bytes
that merely encode the right content some other way were published under a checksum that hashes
them exactly.

## Finding (section 10): concurrency evidence was probabilistic

`PublishConcurrencyBarrierTest` cannot run against the audited container because the barriered
services need the preflight collaborator the correction introduces:

```
FAIL testPublishVersusPublishReachesOneSerialOutcome     key [RENDERCONTRACTVALIDATOR] doesn't exist
FAIL testPublishVersusImportReachesOneSerialOutcome      key [RENDERCONTRACTVALIDATOR] doesn't exist
FAIL testImportVersusPublishQueuesRatherThanDeadlocking  key [RENDERCONTRACTVALIDATOR] doesn't exist
```

This is again the "capability absent" form of red, and it is the weakest evidence in this file: the
audited build had no deterministic barrier for these paths at all, only the repeated `Promise.all`
races in `admin-publish.test.mjs`, which pass whether or not the two transactions ever overlap. The
substantive claim -- that the barrier really does force the interleaving -- is made by the green
run, which asserts that the competing transaction **cannot complete** while the first holds the
lock (`assertNotEquals("COMPLETED", joinedStatus)`) and then completes with the expected refusal
once it is released.

## Finding (section 11): the no-body contract

`admin-publish.test.mjs`, against the audited controller, which tested `structCount(req.body)`:

```
not ok - the publish route's no-body contract is exact: {}, whitespace and null are all bodies
  error: 'an empty JSON object must be refused: {"checksum":"...","status":"PUBLISHED",...}'
         200 !== 400
```

A literal `{}` published the version. Two further defects surfaced from the same case while the
correction was being built, both against code that was otherwise already corrected, and both are
fixed here:

```
  error: 'whitespace only must be refused: {... "status":"PUBLISHED" ...}'  200 !== 400
```
Lucee returns an empty string from `getHttpRequestData()` for a whitespace-only body, so checking
the parsed content could not see it; the route now reads `Content-Length`.

```
  error: 'a JSON null must be refused: {"error":{"code":"INTERNAL_ERROR", ...
           "exceptionMessage":"variable [PARSED] doesn'\''t exist" ...}}'  500 !== 400
```
A body of literal `null` parses to CFML null, and reading that variable back is an error, so the
request escaped as a 500 instead of the documented 400. `Router.buildRequest` now tests `isNull()`
before `isStruct()`.
