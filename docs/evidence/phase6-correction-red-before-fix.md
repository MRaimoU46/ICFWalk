# Phase 6 publish-foundation correction: red before green

Every regression family added by this correction was run against the defect it exists to catch,
before the fix was relied on, and observed to fail for the intended reason.

## Method, and why it is this method

The audited candidate is commit `5b243ed3d5a27142e65cdfbba8fc113ed65853e1`. Most of these specs
cannot be executed verbatim at that commit, because the components they exercise did not exist
there: `DefinitionValidator`, `icf.instrument_dimension_value`, the version-scoped dimension
columns, the required-publisher argument, and the maintenance identity overrides the HTTP suite
imports its own fixtures with. Running them there would fail on a missing component, which proves
nothing about the defect.

So each family was run against the **corrected tree with exactly one production change reverted**
to the behavior the audited candidate had. That isolates cause from effect: the only difference
between the red run and the green run is the fix under test. Every revert is recorded below, was
applied by a scripted patch, and was restored byte-for-byte afterwards (`git diff` confirms no
`RED-BEFORE-GREEN` marker survives anywhere in `src/` or `tests/`).

Green totals for comparison, from the run in
`docs/evidence/phase6-correction-release-gate.txt`: **CFML 258 passed, 0 failed, 0 skipped; Node
169 passed, 0 failed, 0 skipped.**

---

## A. Semantic validation at publish time

**Revert.** In `InstrumentPublishService.publish`, the three semantic refusals (snapshot envelope,
snapshot definitions, persisted definitions) are disabled, leaving only the checksum comparison and
the definitions-drift comparison the audited candidate had.

**Spec.** `InstrumentPublishServiceTest` — every case named `testSemantic…` builds a DRAFT whose
normalized rows and stored snapshot agree perfectly on invalid content, with the snapshot
recompiled from the corrupted rows and its checksum recomputed, so the drift check and the checksum
check both pass.

```
  totals {'failed': 15, 'passed': 12, 'skipped': 0}
  FAIL testSemanticBadSectionParentIsRefused            :: Expected an exception of type [ICFWalk.Publish] but nothing was thrown.
  FAIL testSemanticChoiceItemWithoutResponseSetIsRefused :: Expected an exception of type [ICFWalk.Publish] but nothing was thrown.
  FAIL testSemanticDuplicateDimensionValueOrderIsRefused :: Expected an exception of type [ICFWalk.Publish] but nothing was thrown.
  FAIL testSemanticEmptyDefinitionsAreRefused           :: Expected an exception of type [ICFWalk.Publish] but nothing was thrown.
  FAIL testSemanticInvalidDimensionDataTypeIsRefused    :: Expected an exception of type [ICFWalk.Publish] but nothing was thrown.
  FAIL testSemanticInvalidOptionOrderIsRefused          :: Expected an exception of type [ICFWalk.Publish] but nothing was thrown.
  FAIL testSemanticMalformedConditionsAreRefused        :: Expected an exception of type [ICFWalk.Publish] but nothing was thrown.
  FAIL testSemanticOptionInAForeignResponseSetIsRefused :: Expected an exception of type [ICFWalk.Publish] but nothing was thrown.
  FAIL testSemanticPlacementWithMissingRuleIsRefused    :: Expected an exception of type [ICFWalk.Publish] but nothing was thrown.
  FAIL testSemanticResponseSetWithoutOptionsIsRefused   :: Expected an exception of type [ICFWalk.Publish] but nothing was thrown.
  FAIL testSemanticRuleWithMissingTargetIsRefused       :: Expected an exception of type [ICFWalk.Publish] but nothing was thrown.
  FAIL testSemanticSnapshotCountsMismatchIsRefused      :: Expected an exception of type [ICFWalk.Publish] but nothing was thrown.
  FAIL testSemanticSnapshotFormatIsRefused              :: Expected an exception of type [ICFWalk.Publish] but nothing was thrown.
  FAIL testSemanticSnapshotIdentityMismatchIsRefused    :: Expected an exception of type [ICFWalk.Publish] but nothing was thrown.
  FAIL testSemanticUnsupportedRuleEffectIsRefused       :: Expected an exception of type [ICFWalk.Publish] but nothing was thrown.
```

"Nothing was thrown" is the defect stated exactly: fifteen semantically invalid versions were
**published**. Green: 27 passed, 0 failed.

## B. The DRAFT-only write boundary

**Revert.** `DefinitionRepository.requireDraftVersion` and `requireDraftOwnerOf` stop refusing, and
all 32 status-qualified predicates in that file are neutralised — the state where immutability is a
helper (`assertDraftForWrite`) that no production mutator calls.

**Spec.** `InstrumentImmutabilityTest`, which invokes every production mutator against a PUBLISHED
fixture and a RETIRED one.

```
  totals {'failed': 3, 'passed': 5, 'skipped': 0}
  FAIL testEveryMutatorIsRefusedForAPublishedVersion :: storeSnapshot was NOT refused for a PUBLISHED version.
  FAIL testEveryMutatorIsRefusedForARetiredVersion   :: storeSnapshot was NOT refused for a RETIRED version.
  FAIL testAChildOfAnotherVersionCannotBeWrittenThroughThisOne :: Expected an exception of type [ICFWalk.Validation] but nothing was thrown.
```

Green: 8 passed, 0 failed.

## C. Shared dimension and value immutability

**Revert.** `loadNormalizedDefinitions` reads `icf.dimension_definition` and `icf.dimension_value`
directly again, and the importer writes the document's label, order and activity into those shared
rows in place — the pre-correction model.

**Spec.** `DimensionVersionIsolationTest`.

```
  totals {'failed': 8, 'passed': 0, 'skipped': 0}
  every case :: beforeAll failed: Persisted definitions do not match the imported document;
                the import was rolled back.  @ src/instrument/InstrumentImportService.cfc:143
```

The defect surfaces as unverifiability, which is precisely its shape: under the shared-row model a
second version of an instrument cannot be imported alongside a published first version without
changing what SQL Server reports the first version's definitions to be, so the import's own
round-trip proof rejects it. Green: 8 passed, 0 failed, including
`testWritingTheGlobalIdentityRowsDoesNotChangeAPublishedVersion`, which rewrites the shared rows
directly — exactly the write the old importer made — and proves V1 does not move.

## D. Durable refused-write audits

**Revert.** `InstrumentImportService` writes the refusal record where the refusal is decided, inside
the transaction that is about to roll back, instead of after the rollback.

**Spec.** `InstrumentImmutabilityTest`, the three cases that drive the real application-service
mutation transactions.

```
  totals {'failed': 3, 'passed': 5, 'skipped': 0}
  FAIL testRefusedImportRollsBackAndLeavesExactlyOneDurableAudit  :: exactly one refusal survived the rollback Expected [1] but got [0].
  FAIL testRefusedDiscardRollsBackAndLeavesExactlyOneDurableAudit :: exactly one refusal survived the rollback Expected [1] but got [0].
  FAIL testRefusalAuditCarriesLifecycleFactsAndNoContent          :: Expected [1] but got [0].
```

Zero records, not one: the audit rolled back with the transaction that wrote it. Green: 8 passed.

## E. Publisher attribution

**Revert.** `publish()` and `markPublished()` take an optional publisher defaulting to `""`, the
`PUBLISHER_REQUIRED` / `PUBLISHER_INVALID` / `PUBLISHER_UNKNOWN` refusals and the stored-publisher
read-back are removed, and `CK_instrument_version_publisher_required` is dropped for the duration —
the database state the audited candidate ran against.

**Spec.** `InstrumentPublishServiceTest`.

```
  totals {'failed': 2, 'passed': 25, 'skipped': 0}
  FAIL testPublishingWithoutAValidPublisherIsRefusedAndChangesNothing :: Expected an exception of type [ICFWalk.Validation] but nothing was thrown.
  FAIL testMarkPublishedRefusesAnEmptyPublisher                       :: Expected an exception of type [ICFWalk.Validation] but nothing was thrown.
```

The constraint was restored immediately afterwards and the spec re-run green (27 passed).

## F. Live HTTP, security and concurrency coverage

At `5b243ed` `tests/node/admin-publish.test.mjs` did not exist and the Node total was the Phase 5
count, **155**. It is now **169**.

**Revert.** The route's two Phase 6 corrections: the controller ignores the request body again
(instead of refusing it), and `publish()` checks only self-consistency.

**Suite.** `tests/node/admin-publish.test.mjs` against the live application.

```
  ok 1 - publish refuses an anonymous request and discloses nothing
  ok 2 - publish refuses a signed-in user without instrument.manage
  ok 3 - publish refuses a missing and an invalid CSRF token
  ok 4 - publish refuses a malformed version id
  ok 5 - publish answers 404 for an unknown version without disclosing or mutating anything
  not ok 6 - publish takes no request body, and a client cannot name the publisher
  ok 7 - an administrator publishes a DRAFT: frozen bytes, stored publisher, one audit
  not ok 8 - a checksum-matching semantically invalid DRAFT is refused with the validation response and changes nothing
  ...
  # pass 10
  # fail 2
```

Green: 13 passed, 0 failed.

## G. One lock order (found during verification, not in the audit)

**How it was found.** The first full `ICFWALK_REQUIRE_APP=1 npm test` run failed one case:

```
not ok 12 - a publish racing a mutation ends in one serial order, and published content never changes after
  error: the mutation must be refused once publication committed:
    {"error":{"code":"INTERNAL_ERROR", ... "Transaction (Process ID 59) was deadlocked on lock
     resources with another process and has been chosen as the deadlock victim."}}
  500 !== 409
```

**Cause.** Adding the instrument-code join to `findVersionByIdForUpdate` (needed for the snapshot's
identity check) gave publication the order `instrument_version` (U) → `instrument` (S), while the
importer took `instrument` (X, via `updateInstrument`) → `instrument_version` (U). A lock-order
inversion, introduced by this correction, so a publish racing an import deadlocked instead of
queueing.

**Fix.** `InstrumentImportService.importConfig` now takes the version lock first and updates the
instrument row afterwards, so both paths lock `instrument_version` and then `instrument`.

**Regression.** `tests/node/admin-publish.test.mjs` gained
`repeated publish/mutation races never deadlock: the two paths share one lock order`, which releases
four races on fresh DRAFTs and asserts no 5xx and no deadlock victim in either response. Reverting
the import ordering makes it red, while the single-race case passes by luck — which is exactly why
the repeated form earns its place:

```
  ok 12 - a publish racing a mutation ends in one serial order, and published content never changes after
  not ok 13 - repeated publish/mutation races never deadlock: the two paths share one lock order
  # pass 12
  # fail 1
```

Green: 13 passed, and five consecutive clean runs of the whole HTTP suite.

---

## Test integrity

No existing assertion was weakened, and no test was deleted, skipped, quarantined or renamed away.
Three pre-existing specs were changed, each for one reason:

- `InstrumentImportServiceTest` and `InstrumentScopeTest` build non-DRAFT version rows with direct
  SQL. `CK_instrument_version_publisher_required` now refuses a non-DRAFT row with no publisher, so
  those fixtures name a real fixture user. The assertions they make are unchanged.
- `InstrumentPublishServiceTest` was rewritten around the required publisher argument and gained the
  semantic, publisher and identity families. Every assertion it made before is still made.

Two specs (`InstrumentPublishServiceTest`, `InstrumentImmutabilityTest`) were additionally scoped to
their own instrument code, so a frozen fixture can never become the ICFWalk instrument's current
version for another spec — a real cross-test coupling that produced three spurious failures during
this work before it was removed.
