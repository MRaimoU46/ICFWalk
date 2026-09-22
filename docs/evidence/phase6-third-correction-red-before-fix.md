# Phase 6 publish-foundation third correction: red before green

Every regression below was written first and run against the **audited starting production code**
(`bff53f53eaacfed977eefd4648577ed5cbba196c`), before any production file was changed. This record is
new; it does not overwrite `phase6-second-correction-red-before-fix.md` or the correction record
before that.

**How the red runs were isolated.** The CFML specs, the test-only barrier support and the new Node
test are not production code, so they were added and run while `src/`, `database/*.sql` and
`scripts/` were byte-identical to the audited candidate (`git status --porcelain src/ database/*.sql
scripts/ app/` empty of tracked modifications throughout the red phase). For defect 6 the corrected
`database/README.md` was set aside and the audited one restored for the red run, because the
document *is* the artifact under test there. For defect 4 the audited
`tests/cfml/support/InterceptingDefinitionRepository.cfc` was restored for the red run, because the
absent capability there is the defect.

Harness: `bash tools/runtime/lucee-up.sh` (Lucee 6.2.8.20) against SQL Server 2022 in Docker, driven
through `POST /index.cfm/api/maintenance/tests/run?filter=<Spec>`; Node tests through
`node --test <file>`. Full environment in `phase6-third-correction-environment.md`.

---

## Defect 1: shared metadata performs a stale read before taking its lock

**Behaviour-level red.** A purpose-built harness spec written against the audited signatures
(`updateMetadata(instrumentCode, changes, actorUserId)`) so the failure is the defect itself and not
a changed method signature. The harness was deleted once the permanent regressions replaced it; the
permanent ones are `SharedMetadataConcurrencyBarrierTest.testADeactivationIsNotLostByAConcurrentRename`,
`testARenameIsNotLostByAConcurrentDeactivation`, `testEachAuditDescribesTheRowItActuallyReplaced`,
`testImportDecidesTheSharedConflictOnTheLockedCurrentRowNotItsEarlierLookup`,
`testImportQueuesForTheSharedRowAndThenDecidesOnIt` and
`testAConflictRefusalMovesNothingAndLeavesOneDurableAudit`.

Command: `POST /api/maintenance/tests/run?filter=ZZRedDemonstrationTest`

```
FAILED  ZZRedDemonstrationTest.testRedDefect1AConcurrentPartialUpdateIsLost
        RED EVIDENCE defect 1 (lost update): B outcome=committed; final name=[Red baseline]
        (expected [Renamed by B]); final active=false (expected false).
        A derived its replacement row from a read taken before B committed.

FAILED  ZZRedDemonstrationTest.testRedDefect1ImportJudgesTheConflictOnAStaleRead
        RED EVIDENCE defect 1 (import stale read): committed active=false; import outcome=IMPORTED
        (expected INSTRUMENT_CONFIG_INVALID: the document says active=true and the committed row
        says false).
```

**Why this demonstrates the defect and not a setup error.** In the first case both requests
committed successfully -- B reported `committed` -- and the database still ended with B's rename
absent. The only way a committed rename disappears is that A wrote a `name` it had read before B
ran, which is precisely the stale-read-then-lock sequence. In the second, the metadata change
provably committed (the harness asserts `active=false` is the committed state) *before* import
reached its conflict check, and import accepted a document asserting the opposite; the conflict
check was therefore reading the object import had fetched earlier, not the row.

**Green.** `POST /api/maintenance/tests/run?filter=SharedMetadataConcurrencyBarrierTest` →
`TOTALS passed=6 failed=0 skipped=0`.

---

## Defect 2: a known user is treated as an authorized metadata administrator

**Behaviour-level red**, from the same harness, against the audited signature.

```
FAILED  ZZRedDemonstrationTest.testRedDefect2ANonAdministratorCanChangeTheSharedRow
        RED EVIDENCE defect 2: accepted=true; name before=[Red baseline]
        after=[Renamed by a user with no instrument.manage]; active before=false after=false.
        The operation must have refused this caller: they hold no instrument.manage.
```

**Why this demonstrates the defect.** The actor is a real, active `icf.app_user` with a real,
currently effective `DISTRICT_WALK_REPORT` assignment, and the harness asserts
`authorizationService.can(principal, "instrument.manage") == false` as a precondition before
calling. The operation accepted them and committed the change, so the only check standing between an
arbitrary known user and the shared row was `userExists`.

The permanent regression `InstrumentMetadataServiceTest` is written against the corrected contract
(the principal replaces the actor id, which is the fix). Against the audited code all 15 of its
cases fail at the call itself:

```
FAILED  InstrumentMetadataServiceTest.testAKnownUserWithoutInstrumentManageIsDeniedAndChangesNothing
        Invalid call of the function [updateMetadata], 3th Argument [actorUserId] is of invalid type,
        Cannot cast Object type [Struct] to a value of type [string]
        ... (15 of 15, same cause)
TOTALS passed=0 failed=15 skipped=0
```

**Labelled honestly:** that is an *absent capability* failure, not a behaviour failure -- the
audited service has no principal parameter and no authorization call at all. The behavioural red
above is what demonstrates the defect; this is what demonstrates the capability was missing.

**Green.** `POST /api/maintenance/tests/run?filter=InstrumentMetadataServiceTest` →
`TOTALS passed=15 failed=0 skipped=0`.

---

## Defect 3: global identity creation is not atomically DRAFT-qualified

**Structural red**, and labelled as such. The window this closes is *between two statements*
(`requireDraftVersion`, then an unconditional INSERT). Observing it from outside the repository
would require an interception point inside production code, which this correction is forbidden to
add, so the regression asserts the property that replaces the window -- that there is only one
statement, and that it carries its own authority -- over the real production SQL.

Command: `POST /api/maintenance/tests/run?filter=GlobalIdentityBoundaryTest`

```
FAILED  GlobalIdentityBoundaryTest.testMintingIdentityIsQualifiedByItsOwnStatement
        createDimensionIdentity reads the owning version under UPDLOCK in the same statement that inserts
TOTALS passed=5 failed=1 skipped=0
```

**Why this demonstrates the defect rather than a stylistic preference.** The audited
`createDimensionIdentity` issues `INSERT INTO [icf].[dimension_definition] ... VALUES (...)` with no
reference to `icf.instrument_version` at all. Its only authority is a `requireDraftVersion` call
whose `UPDLOCK` is released when that SELECT ends -- which, outside a transaction, is before the
INSERT begins. The assertion names exactly that: the minting statement must read the owning version
under `UPDLOCK` and carry `status = N'DRAFT'` in its own predicate.

The five behavioural cases in the same spec pass against the audited code and are kept as the
boundary's protection rather than as evidence of the defect: minting works for a DRAFT outside any
transaction, is refused for PUBLISHED and RETIRED with both global tables byte-identical afterwards
(SHA-256 fingerprint), is refused for an absent version, and both serial outcomes against a
concurrent publish hold. The converse serial outcome is in
`PublishConcurrencyBarrierTest.testPublishVersusNewDimensionIdentityReachesOneSerialOutcome` and its
value-identity twin.

**Green.** `TOTALS passed=6 failed=0 skipped=0`.

---

## Defect 4: the concurrency tests still infer the competing request's arrival

**Absent-capability red, labelled as such, and it is the right kind here** -- defect 4 is a defect
in the *evidence method*, not in production behaviour. The audited production locking is correct;
what was missing was any way to observe that the competitor had arrived. Run with the audited
`tests/cfml/support/InterceptingDefinitionRepository.cfc` restored (no `armBefore` seam):

Command: `POST /api/maintenance/tests/run?filter=PublishConcurrencyBarrierTest`

```
FAILED  PublishConcurrencyBarrierTest.testPublishVersusPublishReachesOneSerialOutcome
        Component [icfwalk.instrument.DefinitionRepository] has no  function with name [armBefore]
FAILED  PublishConcurrencyBarrierTest.testPublishVersusImportReachesOneSerialOutcome            (same)
FAILED  PublishConcurrencyBarrierTest.testImportVersusPublishQueuesRatherThanDeadlocking        (same)
FAILED  PublishConcurrencyBarrierTest.testPublishVersusNewDimensionIdentityReachesOneSerialOutcome (same)
FAILED  PublishConcurrencyBarrierTest.testPublishVersusNewDimensionValueIdentityReachesOneSerialOutcome (same)
TOTALS passed=0 failed=5 skipped=0
```

**Why this demonstrates the defect.** `B_AT_COMPETING_BOUNDARY` cannot be emitted at all with the
audited support, because there is no seam that runs *before* the contending database call. The only
signal available to the audited specs was B's non-completion inside a timeout, which is the
inference the audit objected to. Two of the five cases (the identity creators) did not exist in the
audited suite in any form.

Stated plainly, and not claimed as more than it is: the audited *production* code passes the
corrected barrier specs once the seam exists. The correction is to the evidence, and the evidence
now distinguishes a working lock from a coincidence.

**Green.** `POST /api/maintenance/tests/run?filter=PublishConcurrencyBarrierTest` →
`TOTALS passed=5 failed=0 skipped=0`; `…?filter=SharedMetadataConcurrencyBarrierTest` →
`TOTALS passed=6 failed=0 skipped=0`. Seven deterministic cases in total.

---

## Defect 5: snapshot counts accept numeric strings, and top-level null escapes the refusal path

**Behaviour-level red, at both the validator boundary and the publish endpoint.**

Command: `POST /api/maintenance/tests/run?filter=DefinitionValidatorTest`

```
FAILED  DefinitionValidatorTest.testEveryCountMemberRefusesAJsonStringEvenWhenItNamesTheRightNumber
        counts.sections as the string [23] must not be accepted
FAILED  DefinitionValidatorTest.testCountsRefuseNegativeFractionalAndOversizedNumbers
        counts.items = 2147483648 must be refused: SNAPSHOT_COUNTS_MISMATCH@$.counts.items
TOTALS passed=48 failed=2 skipped=0
```

Command: `POST /api/maintenance/tests/run?filter=InstrumentPublishServiceTest`

```
FAILED  InstrumentPublishServiceTest.testACountStoredAsTheExactMatchingStringIsRefused
        Expected an exception of type [ICFWalk.Publish] but nothing was thrown.
FAILED  InstrumentPublishServiceTest.testATopLevelNullSnapshotIsARefusalAndNotAnEngineError
        Expected exception type starting with [ICFWalk.Publish.Validation] but got [expression]:
        variable [SNAPSHOT] doesn't exist
FAILED  InstrumentPublishServiceTest.testNegativeFractionalAndOversizedCountsAreRefused
        counts.items = 2147483648 is refused
TOTALS passed=50 failed=3 skipped=0
```

**Why these demonstrate the defects.**

* `testACountStoredAsTheExactMatchingStringIsRefused` builds a DRAFT whose stored snapshot is
  canonical, hashes to its stored checksum, whose definitions are valid and match the tables, and
  which the renderer builds -- the spec asserts those preconditions -- and whose only defect is that
  `counts.items` is the java.lang.String `"144"` rather than the number `144` (the spec asserts the
  stored value's Java class). It **published successfully**. That is the contract violation exactly:
  `docs/DATA_CONTRACT.md` defines the member as a JSON number and every reader parses it as one.
* `testATopLevelNullSnapshotIsARefusalAndNotAnEngineError` fails with a CFML *expression* error
  (`variable [SNAPSHOT] doesn't exist`), not a refusal. That is a 500 to the caller, raised inside
  `CanonicalJson.serialize` before `markRefusal` had run, so no `INSTRUMENT_VERSION_PUBLISH_REFUSED`
  event was written -- the attempt left no durable trace at all.
* The oversized count was reported only as a `SNAPSHOT_COUNTS_MISMATCH`, so a snapshot whose
  definitions genuinely carried that many items would have been accepted with a count outside the
  range the schema's `int` columns and the runtime's counters hold.

Note on the scalar cases: `testATopLevelScalarSnapshotIsRefused` and
`testATopLevelArraySnapshotIsRefused` pass against the audited code (a non-struct that survives
serialization reaches `validateEnvelope`, which reports `SNAPSHOT_SHAPE`). They are kept as
protection, not claimed as red. Those cases also establish the database's own defence first:
`CK_instrument_version_snapshot_json` uses a 2016-era `ISJSON`, which accepts only objects and
arrays, so a schema-conformant database refuses to store a top-level scalar at all. The spec asserts
that refusal, then drops the constraint for the length of the store, restores it immediately,
asserts it is back, and re-validates it in `afterAll`.

**Green.** `DefinitionValidatorTest` → `TOTALS passed=50 failed=0 skipped=0`;
`InstrumentPublishServiceTest` → `TOTALS passed=53 failed=0 skipped=0`.

---

## Defect 6: the historical remediation DELETE is not scoped to a dimension

**Behaviour-level red inside a structural one.** Run with the audited `database/README.md` restored.

Command: `node --test tests/node/remediation-exact-identity.test.mjs`

```
not ok 1 - the documented remediation removes only the approved (dimension_code, value_code) pair
  error: 'database/README.md publishes exactly one exact-identity remediation block\n\n0 !== 1\n'
  at remediationTemplate (tests/node/remediation-exact-identity.test.mjs:48:10)
# fail 1
```

**Why this demonstrates the defect.** The test extracts the procedure *from the document*, so the
failure is that the audited document publishes no exact-identity procedure at all -- only the
dimension-blind `DELETE ... WHERE iv.version_id = @versionId AND dv.value_code IN (...)`. The
behavioural half runs before that point and passed in the same red run: against a PUBLISHED version
carrying the code `other` under `school`, `content` and `classType`, the audited sample removed
**three** rows and reported `removed = 3` for one approved pair. That assertion
(`assert.equal(Number(naive.recordset[0].removed), 3, "the value_code-only delete reaches all three
dimensions")`) is kept permanently in the test, so the corrected procedure is measured against the
thing it replaces.

**Green.** `node --test tests/node/remediation-exact-identity.test.mjs` → `# pass 1 # fail 0`, with
only `school/other` removed, `content/other` and `classType/other` intact, all three global `other`
identities surviving, the frozen checksum unmoved, and the refusal paths (50060, 50061, 2627)
exercised.

---

## Defect 7: an import document can omit its DRAFT declaration

**Behaviour-level red.**

Command: `POST /api/maintenance/tests/run?filter=InstrumentConfigValidatorTest`

```
FAILED  InstrumentConfigValidatorTest.testAMissingStatusIsRejected
        a document that declares no status is not importable
FAILED  InstrumentConfigValidatorTest.testANullStatusIsRejected
        Expected condition to be false.
FAILED  InstrumentConfigValidatorTest.testANonStringStatusIsRejected
        as a type error: VERSION_STATUS_NOT_DRAFT@$.instrument.version.status
FAILED  InstrumentConfigValidatorTest.testALowerCaseStatusIsRejected
        'draft' is not the DRAFT the data contract names
TOTALS passed=14 failed=4 skipped=0
```

**Why these demonstrate the defect.** The first two show a document with no status declaration, and
one whose status is null, validating as **valid** -- the audited check only ran when the member
existed, so silence was read as a DRAFT declaration. The third shows a numeric status reported as a
wrong *value* rather than a wrong *type*, so a caller cannot tell a malformed document from one
declaring the wrong lifecycle state. The fourth shows `draft` accepted, because CFML's `!=` is
case-insensitive while `CK_instrument_version_status` names three upper-case literals.

`testABlankStatusIsRejected` passes against the audited code (a blank string is not `DRAFT`, so the
existing value check caught it) and is kept as protection rather than claimed as red.

**Green.** `TOTALS passed=18 failed=0 skipped=0`.

---

## Summary

| Defect | Red kind | Red result against `bff53f5` | Green |
| --- | --- | --- | --- |
| 1 stale read before the lock | behaviour | lost update committed; racing import accepted | 6/6 |
| 2 known user treated as authorized | behaviour (+ absent capability) | non-administrator's change committed | 15/15 |
| 3 identity mint not atomically qualified | structural, labelled | minting DML carries no `status = N'DRAFT'` | 6/6 |
| 4 arrival inferred from a timeout | absent capability, labelled | `armBefore` does not exist; 5/5 fail | 5/5 + 6/6 |
| 5 numeric-string counts, top-level null | behaviour | `"144"` published; null raised a 500 with no audit | 50/50 + 53/53 |
| 6 dimension-blind remediation DELETE | behaviour inside structural | one approved pair removed three rows | 1/1 |
| 7 missing DRAFT declaration | behaviour | absent, null and lower-case status all accepted | 18/18 |
