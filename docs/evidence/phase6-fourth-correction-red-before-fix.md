# Phase 6 publish-foundation fourth correction: red before green

One production defect (CORR7-01) was corrected in this pass. Its two regressions were written first
and run against the **unmodified production code** of the audited candidate
(`a8e97f22ae1639faef5b6e68bf7255dea838f8e2`), and only then was the production method changed.
Nothing below is a summary of a result that was not observed: both blocks are the runner's output
as printed.

Harness: `tools/runtime/lucee-up.sh` (Lucee 6.2.8.20) against SQL Server 2022 (16.0.4295.3) in
Docker, driven through `GET /index.cfm/api/maintenance/tests/run?filter=InstrumentMetadataServiceTest`
with the maintenance token, the same route the CFML suite driver uses. The runner prints every case
of the spec, so the fifteen pre-existing cases are shown alongside the two new ones.

## The defect

`InstrumentMetadataService.updateMetadata` decided whether a field had changed with

```
if (toString(before[field]) != toString(after[field])) arrayAppend(changed, field);
```

CFML's string `!=` is case-insensitive, so `ICFWalk` -> `Icfwalk`, or a description whose only
difference is capitalization, compared equal. The operation classified a legitimate edit as a
no-op: it wrote nothing, `row_version` did not move, and no `INSTRUMENT_METADATA_UPDATED` event was
recorded.

## The regressions

`tests/cfml/specs/InstrumentMetadataServiceTest.cfc`:

* `testACaseOnlyNameChangeIsMaterial` sets the name to `ICFWalk` (with a unique description), then
  patches only `{ "name": "Icfwalk" }`.
* `testACaseOnlyDescriptionChangeIsMaterial` sets a unique lower-case description, then patches only
  `{ "description": uCase(thatDescription) }`.

Each asserts the authorized principal is the actor in the result and in the audit row, `noOp` is
false, `changedFields` names exactly the changed field, the exact requested capitalization is stored
and returned, the omitted fields keep their stored values, `row_version` moved, exactly one
`INSTRUMENT_METADATA_UPDATED` event was added since the case's own baseline, that event carries the
correct `instrumentCode`, `changedFields`, `previousName`, `name`, `previousActive`, `active` and
`descriptionChanged`, and no description text appears in the audit JSON (checked with `findNoCase`,
so neither capitalization can leak).

Every text assertion uses a local `assertExactText` built on `compare()`. `BaseSpec.assertEquals`
compares with the same case-insensitive `!=` and would have passed whichever capitalization the row
held, so it could not have detected this defect.

## Red: unmodified production code

Isolation, checked immediately before the run: the only modified file was the spec.

```
$ git rev-parse HEAD
a8e97f22ae1639faef5b6e68bf7255dea838f8e2
$ git status --porcelain=v1 --untracked-files=all
 M tests/cfml/specs/InstrumentMetadataServiceTest.cfc
$ git diff --exit-code -- src/ >/dev/null; echo $?
0
```

Output:

```
SPEC InstrumentMetadataServiceTest: passed=15 failed=2 skipped=0
  FAILED  testACaseOnlyDescriptionChangeIsMaterial
          a case-only description change is material, not a no-op (changedFields=[], stored description=Description case probe narrative 0af7caa7-9192-4f1e-904569cbe884c1c8)  @ /home/user/ICFWalk/tests/cfml/BaseSpec.cfc:38
  FAILED  testACaseOnlyNameChangeIsMaterial
          a case-only name change is material, not a no-op (changedFields=[], stored name=ICFWalk)  @ /home/user/ICFWalk/tests/cfml/BaseSpec.cfc:38
  PASSED  testAKnownUserWithNoRoleAtAllIsDeniedAndChangesNothing
  PASSED  testAKnownUserWithoutInstrumentManageIsDeniedAndChangesNothing
  PASSED  testAMalformedActiveIsRefusedRatherThanCoerced
  PASSED  testAMissingInstrumentIsRefusedWithoutAuditingSuccess
  PASSED  testAnEmptyPatchIsRefusedWithoutAWrite
  PASSED  testAnInvalidDescriptionIsRefusedWithoutAWrite
  PASSED  testAnInvalidNameIsRefusedWithoutAWrite
  PASSED  testAnUnknownPatchMemberIsRefusedWithoutAWrite
  PASSED  testAPartialPatchKeepsTheStoredValueOfWhatItOmits
  PASSED  testAPatchWithNoMaterialDifferenceIsAnAuditFreeNoOp
  PASSED  testAUserWithAnEffectiveInstrumentManageAssignmentSucceeds
  PASSED  testTheAuditActorIsTheAuthorizedPrincipalAndCannotBeOverridden
  PASSED  testTheAuditNamesChangedFieldsWithoutCopyingNarrativeContent
  PASSED  testTheOperationRemainsUnreachableFromHttpAndControllers
  PASSED  testTheOperationRequiresAPrincipalRatherThanAnActorId
engine=Lucee 6.2.8.20 totals passed=15 failed=2 skipped=0 specs=1
```

Both new cases fail at the materiality decision itself: the service returned `changedFields=[]`
(a no-op), and the stored row still held the previous capitalization -- `ICFWalk`, and the
lower-case description. The fifteen existing cases pass, so the failure is the defect and not a
fixture or harness problem.

## The fix

```
var changed = [];
if (compare(before.name, after.name) != 0) arrayAppend(changed, "name");
if (compare(before.description, after.description) != 0) arrayAppend(changed, "description");
if (before.active XOR after.active) arrayAppend(changed, "active");
```

`compare()` is documented as case-sensitive on both Lucee and Adobe ColdFusion; it was executed
here only on Lucee. `active` is compared with a
boolean operator on two values that are already CFML booleans (`? true : false` on both sides), never
through `toString`. The order of `changedFields` (name, description, active) is unchanged. Nothing
else in the method changed: the locked read, the transaction, `requireManagePermission`, the actor
derived from `principal.userId`, `validatePatch`, the audit's `descriptionChanged` instead of text,
and the public signature are all as they were.

## Green: after the fix

Lucee was restarted (`tools/runtime/lucee-down.sh`, `tools/runtime/lucee-up.sh`) so the application
container held the recompiled service, and the same request was repeated:

```
SPEC InstrumentMetadataServiceTest: passed=17 failed=0 skipped=0
  PASSED  testACaseOnlyDescriptionChangeIsMaterial
  PASSED  testACaseOnlyNameChangeIsMaterial
  PASSED  testAKnownUserWithNoRoleAtAllIsDeniedAndChangesNothing
  PASSED  testAKnownUserWithoutInstrumentManageIsDeniedAndChangesNothing
  PASSED  testAMalformedActiveIsRefusedRatherThanCoerced
  PASSED  testAMissingInstrumentIsRefusedWithoutAuditingSuccess
  PASSED  testAnEmptyPatchIsRefusedWithoutAWrite
  PASSED  testAnInvalidDescriptionIsRefusedWithoutAWrite
  PASSED  testAnInvalidNameIsRefusedWithoutAWrite
  PASSED  testAnUnknownPatchMemberIsRefusedWithoutAWrite
  PASSED  testAPartialPatchKeepsTheStoredValueOfWhatItOmits
  PASSED  testAPatchWithNoMaterialDifferenceIsAnAuditFreeNoOp
  PASSED  testAUserWithAnEffectiveInstrumentManageAssignmentSucceeds
  PASSED  testTheAuditActorIsTheAuthorizedPrincipalAndCannotBeOverridden
  PASSED  testTheAuditNamesChangedFieldsWithoutCopyingNarrativeContent
  PASSED  testTheOperationRemainsUnreachableFromHttpAndControllers
  PASSED  testTheOperationRequiresAPrincipalRatherThanAnActorId
engine=Lucee 6.2.8.20 totals passed=17 failed=0 skipped=0 specs=1
```

`testAPatchWithNoMaterialDifferenceIsAnAuditFreeNoOp` passes before and after, so the no-op contract
for genuinely unchanged values is preserved.

## Revised after the first exact-commit gate

The red and green blocks above were produced by the first version of the two cases, which asserted
that `row_version` moved with `BaseSpec.assertNotEquals`. The first exact-commit gate (at
`c7f6f48a36626dc357bd36aa65db85a26083f15a`) then failed `testACaseOnlyDescriptionChangeIsMaterial`
on that assertion, with the message `the row was written Expected values to differ but both were
[000000000000E988]`. CFML's `==` compares two numeric-looking strings as numbers, and that hex
value reads as `0e988`, which is zero, so it equalled its successor. Observed directly on Lucee
6.2.8.20 with a temporary probe spec (deleted, never committed):

```
PROBE isNumeric(a)=true val(a)=0 | a==b true | compare(a,b)=-1 | a==c false | compare(a,c)=-1
      where a = 000000000000E988, b = 000000000000E989, c = 000000000000E98A
```

Both cases now compare row versions with `compare()`. The red result is unaffected: in the red run
both cases failed at `noOp`, before the row-version assertion was reached. The revised cases were
re-run green against the fixed code, and again in the repeated exact-commit gate.

## What was not changed

* `BaseSpec.assertEquals` / `assertNotEquals` still coerce: they ignore case and compare
  numeric-looking strings as numbers. Changing a shared assertion would alter the meaning of every
  existing case in the suite and is outside this correction; the new cases avoid it instead. It
  matters when reading older assertions about stored text and about row versions (87 call sites
  across 16 spec files pass a row version to one of them).
* `DefinitionRepository.updateInstrumentMetadata`'s post-write check (`WHERE ... AND name = :name`)
  compares under the column's collation, which in this environment is
  `SQL_Latin1_General_CP1_CI_AS` (case-insensitive; the schema sets none, so it inherits the
  database default). It confirms that a row was
  written under the lock the caller holds; it is not the materiality decision and was not changed.

## Adobe ColdFusion 2023

Not executed; everything above ran on Lucee 6.2.8.20. Before any claim about the production engine,
run `testACaseOnlyNameChangeIsMaterial` and `testACaseOnlyDescriptionChangeIsMaterial` there, along
with the checklist in `phase6-third-correction-environment.md`. The fix relies on `compare()` being
case-sensitive and on `XOR` over two CFML booleans, both documented behaviour on Adobe ColdFusion,
but documented is not the same as observed.
