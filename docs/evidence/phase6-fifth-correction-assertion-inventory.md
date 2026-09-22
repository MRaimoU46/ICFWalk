# Phase 6 publish-foundation fifth correction: exact-assertion inventory

Every assertion call site in the CFML suite whose contract requires an exact comparison, what it
compares, where it went, and every comparison deliberately kept on the general helpers, with the
contract reason. The red-before-green record for the helpers themselves is
`phase6-fifth-correction-red-before-fix.md`.

## Why

`tests/cfml/BaseSpec.cfc` implemented `assertEquals` and `assertNotEquals` by stringifying both
values and comparing them with CFML's `!=` and `==`. Observed on Lucee 6.2.8.20, that operator
reports every one of these pairs as equal, although `compare()` reports each pair as different text:

| Pair | Why `==` calls them equal |
| --- | --- |
| `ICFWalk` / `Icfwalk` | case-insensitive |
| `000000000000E988` / `000000000000E989` | both numeric in exponent notation: 0e988 and 0e989 are zero |
| `0000000000000000` / `000000000000E988` | both zero |
| `00000000000012E4` / `0000000000120000` | 12e4 = 120000 |
| `4` / `04`, `1E3` / `1000`, `0` / `0.0` | numeric |
| `true` / `YES` | boolean |
| `ICFWALK_DRAFT` / `icfwalk_draft`, `0x000000000000E988` / `0x000000000000e988` | case-insensitive |

So an assertion that a value was unchanged could pass although it moved, and an assertion that it
changed could fail although it did (the fourth correction's first exact-commit gate failed on
exactly that). Row versions are the sharpest case, because this application writes them as 16
hexadecimal digits (`binaryEncode(row_version, "hex")` for instrument rows) and every
`0...0E<digits>` token is zero to `==`; but the same operator also sat under every assertion about
codes, statuses, identifiers, checksums, canonical JSON, stored codes and authored text.

## Method

1. **Static parse.** Every call to `assertEquals`, `assertNotEquals` and `assertThrows` in
   `tests/cfml/specs/*.cfc` was located with comments and string literals masked, its full
   multi-line span resolved by balanced parentheses, and its arguments split at the top level.
   Result at the audited commit: 895 `assertEquals` and 38 `assertNotEquals` calls in 31 spec files,
   and 213 `assertThrows` calls.
2. **Traced run of the unmodified suite.** `BaseSpec` was temporarily instrumented (never
   committed) to record, for every execution, the call site, both operands' Java classes and values,
   and whether `==` and `compare()` agreed. 3,999 executions were recorded over the complete suite
   (377/377 passing). Exact and coercive comparison **disagreed in none of them**, and all 236
   errorcode checks inside `assertThrows` matched exactly: no passing case depended on coercion in
   that run, so moving a call to an exact helper cannot turn a genuine pass into a failure. The
   hazard is that row-version values differ from run to run, which is how `E988`/`E989` surfaced.
3. **Contextual review.** Each call was classified from its source and its traced operands: the
   value's contract, not its variable name, decides the category. Aliases were traced by value
   (`r0`, `r1`, `r2` and `rv` hold row versions), loops were split by field, and struct-valued
   fingerprints were opened up.
4. **Traced run of the migrated suite.** The same temporary instrumentation (again never committed)
   recorded 3,827 executions over the migrated suite (391/391 passing): outside
   `ExactAssertionTest`, the general helpers ran 782 times and **every operand was a number or a
   boolean**; every text operand went through an exact helper.
5. **Guard.** `ExactAssertionTest` makes the result permanent (below).

## Files reviewed

`tests/cfml/BaseSpec.cfc`; every spec in `tests/cfml/specs/` (`AuthorizationTest`,
`CanonicalJsonTest`, `ConfigLoaderTest`, `DefinitionValidatorTest`, `DimensionVersionIsolationTest`,
`GlobalIdentityBoundaryTest`, `IdentityTest`, `ImportPublishEquivalenceTest`,
`InstrumentConfigValidatorTest`, `InstrumentImmutabilityTest`, `InstrumentImportServiceTest`,
`InstrumentMetadataServiceTest`, `InstrumentPublishServiceTest`, `InstrumentScopeTest`, `LoggerTest`,
`Migration006LifecycleTest`, `PublishConcurrencyBarrierTest`, `RenderModelTest`,
`SharedInstrumentBoundaryTest`, `SharedMetadataConcurrencyBarrierTest`, `SnapshotCompilerTest`,
`SnapshotServiceTest`, `ValidatorRendererContractTest`, `VisibilityEngineTest`, `WalkCorrectionTest`,
`WalkMutationResponseTest`, `WalkReplayCoherenceTest`, `WalkSchoolScopeTest`, `WalkServiceTest`,
`WalkSummaryCoherenceTest`, `WalkSummaryFormatterTest`); every component in `tests/cfml/support/`
(`ConcurrencyBarrier`, `FixtureCleanup`, `Fixtures`, `InterceptingDb`,
`InterceptingDefinitionRepository`, `InterceptingWalkRepository`, `StubConfigLoader`); and the new
`ExactAssertionTest`.

## The 933 general-helper calls, by disposition

| Disposition | Calls |
| --- | --- |
| to `assertExactTextEquals` | 523 |
| to `assertExactTextNotEquals` | 25 |
| to `assertRowVersionEquals` | 75 |
| to `assertRowVersionChanged` | 12 |
| to `assertExactJsonEquals` | 21 |
| split by field contract (three wrapper helpers, below) | 3 |
| kept on `assertEquals`: numeric contract | 259 |
| kept on `assertNotEquals`: numeric contract | 1 |
| kept on `assertEquals`: boolean contract | 14 |
| **total** | **933** |

Besides the general helpers, the review found and migrated: the fourth correction's spec-local
`assertExactText` helper in `InstrumentMetadataServiceTest` (22 calls, already exact; removed, and
the calls now use the shared `assertExactTextEquals`); two inline `assertTrue(compare(before.rowVersion,
after.rowVersion) != 0)` checks in the same spec (now `assertRowVersionChanged`); one
`assertTrue(x == "ANSWERED")` in `VisibilityEngineTest` (now `assertExactTextEquals`); and the
assertion-deciding predicates listed further down.

## Exact-sensitive call sites by category

Categories of the exact text comparisons are those of the values they compared in the traced run of
the unmodified suite; the 32 that had no traced value (the 22 former `assertExactText` calls, six
lines of `InstrumentImmutabilityTest` whose line numbers moved when its wrappers were split, the
former `assertTrue(==)`, and three loop bodies that did not execute) were categorized by reading
them.

| Category | Helper | Call sites |
| --- | --- | --- |
| Row versions (opaque tokens) | `assertRowVersionEquals` / `assertRowVersionChanged` | 92 (78 / 14) |
| Codes, statuses, error codes, audit event types | `assertExactTextEquals` / `NotEquals` | 170 |
| Authored or rendered text: prompts, labels, instrument names and descriptions, messages, file names | `assertExactTextEquals` | 122 |
| Keys, value codes, field names | `assertExactTextEquals` / `NotEquals` | 91 |
| Identifiers (GUIDs) | `assertExactTextEquals` / `NotEquals` | 71 |
| Checksums and hashes (SHA-256 hex) | `assertExactTextEquals` | 56 |
| Canonical or serialized JSON text | `assertExactTextEquals` | 27 |
| Stored codes that look numeric (`"4"`, `"04"`) | `assertExactTextEquals` | 17 |
| Dates and instants rendered as text | `assertExactTextEquals` | 10 |
| Empty text | `assertExactTextEquals` | 9 |
| Structures: ordered lists of codes, keys and value codes; count and key-set structs | `assertExactJsonEquals` | 23 |
| **Total** | | **688** |

## Row versions: all 92 comparisons, 16 spec files

Every equality or change assertion on a row version now goes through `assertRowVersionEquals` or
`assertRowVersionChanged`, which compare the token as opaque text: no numeric reading, no case
folding, no `0x` added or removed, no padding, and an empty or null token is refused rather than
compared. The representations covered:

* **Instrument rows**: `binaryEncode(row_version, "hex")`, 16 hex digits without prefix
  (`DefinitionRepository.findVersionById`, and the specs' own `instrumentRow()` helpers). This is
  the form `==` reads as a number.
* **Walks**: `CONVERT(varchar(18), CAST(row_version AS binary(8)), 1)`, `0x` plus 16 hex digits
  (`WalkRepository`, and the specs' `storedRowVersion()` helpers). The production contract lets a
  *client* send lower-case hex, which `WalkService.rowVersionOf` normalizes on the server; the
  tests compare what the server returns and stores, exactly.
* **High-water marks**: `MAX(CAST(row_version AS bigint))` over a version's child tables and over
  `icf.instrument`. Lucee returns SQL `bigint` as `java.lang.Double`, so these are now read as exact
  decimal text from SQL Server itself, `CONVERT(varchar(20), MAX(CAST(row_version AS bigint)))`,
  and compared as tokens. Same value, no floating point in the path.

| Spec | Row-version comparisons | Including |
| --- | --- | --- |
| `WalkReplayCoherenceTest` | 20 | replay idempotence, supersession, legacy rows, the coherence seam |
| `WalkMutationResponseTest` | 19 | the aliases `r0`, `r1`, `r2` of the commit-boundary interleaving |
| `WalkCorrectionTest` | 11 | stale void, no-op completed save, required row versions |
| `WalkServiceTest` | 11 | stale write, retry, completion, round trip |
| `InstrumentMetadataServiceTest` | 7 | refused patches, no-op, the two case-only regressions |
| `InstrumentPublishServiceTest` | 4 | refused publishes leave the version row untouched |
| `WalkSchoolScopeTest` | 4 | the alias `rv` of a rejected save |
| `InstrumentImmutabilityTest` | 3 | the version row, every child table's high-water mark, the shared instrument row |
| `WalkSummaryCoherenceTest` | 3 | the export straddling a concurrent save |
| `InstrumentImportServiceTest` | 2 | a published version cannot be reimported |
| `SharedInstrumentBoundaryTest` | 2 | V2 import cannot move V1; the conflict refusal moves nothing |
| `SharedMetadataConcurrencyBarrierTest` | 2 | the conflict refusal moves nothing |
| `DimensionVersionIsolationTest` | 1 | the published snapshot after the next import |
| `GlobalIdentityBoundaryTest` | 1 | a frozen version cannot mint identity |
| `Migration006LifecycleTest` | 1 | re-applying 006 leaves V1 untouched |
| `PublishConcurrencyBarrierTest` | 1 | publish versus publish |

Ninety of these went through the coercive helpers before; the other two are the inline `compare()`
checks the fourth correction had added.

### The three wrappers split by field contract

* `InstrumentImmutabilityTest.assertSharedUnchanged` compared seven fields in one loop. It now
  compares the three counts numerically, the three digests as exact text and `instrumentRowVersion`
  as a row version, and first asserts that those seven are exactly the fields `sharedState()`
  records, so a field added later cannot escape comparison.
* `InstrumentImmutabilityTest.assertUnchanged` compared `childRowVersions`, a struct of seven
  high-water marks, as one serialized struct. It now asserts the same tables on both sides
  (`assertExactJsonEquals` over the sorted keys) and compares each table's mark with
  `assertRowVersionEquals`, so a failure names the table.
* `InstrumentPublishServiceTest.assertUntouchedDraft` compared eight fields in one loop. Seven are
  text and stay in the loop on `assertExactTextEquals`; `rowVersion` is asserted separately with
  `assertRowVersionEquals`. Same eight fields as before.

`InstrumentImportServiceTest.testDb06ImportAgainstPublishedVersionIsRefusedWithoutChanges` read the
item rows' high-water mark and count into a query variable named `itemRowVersion`; the variable is
now `items`, because one of its two columns is a count, and a count compared numerically should not
look like a row version to a reader or to the guard.

## Comparisons outside the helpers that decided an assertion

Each of these used `==` or `!=` on an exact value to decide whether an assertion passed. Each now
uses `compare()`, the same idiom production code uses:

| Where | What it decides |
| --- | --- |
| `DefinitionValidatorTest.hasError`, `.hasPath`, and the `$.persistedDefinitions.items` path-prefix check | an error code or path was reported |
| `ImportPublishEquivalenceTest` (`MISSING_REFERENCE` match, `pathsFor`) | an error code was reported, at which paths |
| `InstrumentConfigValidatorTest.hasPath`, `.hasError`, the `PLACEHOLDER_CONTENT` count | a path or code was reported; how many placeholder warnings |
| `ValidatorRendererContractTest.hasError` | an error code was reported |
| `InstrumentPublishServiceTest.hasIssue`, `.hasIssuePath` | a publish issue code or path was reported |
| `InstrumentImportServiceTest` (`MISSING_REFERENCE` issue; the label lookup behind "the imported version is listed") | an issue code; which listed version is the imported one |
| `InstrumentImmutabilityTest.refused` | the refusal's errorcode is exactly `INSTRUMENT_VERSION_NOT_DRAFT` |
| `Migration006LifecycleTest` | the backfill state is `COMPLETED` or `ADOPTED_PRE_STATE` |
| `support/ConcurrencyBarrier.signalledInOrder` | one barrier signal was observed before another |

`ImportPublishEquivalenceTest`'s positive check that the import names the authoring id the author
wrote, at its `.sectionId` path, used `findNoCase`; it now uses the case-sensitive `find`.

`BaseSpec.assertThrows` compared the errorcode with `!=`. The errorcode is what a client receives as
`error.code`, so it is now compared with `compare()`. All 236 errorcode checks in the traced run
matched exactly, so no expectation changed.

## Deliberately kept, with the contract reason

* **275 general-helper calls, numeric or boolean.** 261 compare counts (`COUNT(*)`, audit and
  revision counts, `recordCount`, `arrayLen`, `structCount`), lengths, `displayOrder`, numeric scores,
  HTTP statuses from `Errors.statusFor`, and six `compare()` results that are already exact; 14
  compare `active` flags. Numeric equality and boolean equality are those contracts, and in the
  migrated traced run every operand of these calls was a `java.lang.Double`, `Integer`, `Long` or
  `Boolean`. `assertEquals` also refuses any operand shaped like a row-version token, so none can
  come back this way.
* **Explicit GUID normalization.** Twelve comparisons apply `uCase()` to a GUID read back from SQL
  Server before comparing it exactly (for example `assertExactTextEquals(variables.publisher,
  uCase(row.published_by_user_id[1]))`), and `AuthorizationTest` passes `lCase()` of an org-unit id
  to prove the service returns the canonical form. A `uniqueidentifier`'s text case carries no
  meaning, the normalization is visible at the call site, and the comparison after it is exact.
* **`assertThrows` type prefixes stay case-insensitive**, now written as `compareNoCase`. CFML
  resolves exception types case-insensitively (`catch (ICFWalk.Validation e)`, and the `switch` in
  `Errors.statusFor` that maps a type to an HTTP status), so that is the contract production relies
  on. `InstrumentImmutabilityTest.refused` makes the same choice explicitly for its type check.
* **`findNoCase` that means absence or source structure.** Absence checks (no narrative text in an
  audit or mutation log, no route or controller naming the metadata operation, no deadlock, the
  publish refusal not naming an authoring id) are stronger case-insensitively. Structural checks over
  SQL and CFML source (`GlobalIdentityBoundaryTest`, `InstrumentImmutabilityTest`'s mutator inventory
  over method names, and the SQL Server constraint name in `InstrumentPublishServiceTest`) search
  languages whose keywords and identifiers are case-insensitive.
* **`arrayContains`** (11 calls: org-unit ids and field names such as `name`). Observed on Lucee
  6.2.8.20 to be case-sensitive and not numeric: `arrayContains(["Name"], "name")`,
  `arrayContains(["4"], "04")` and `arrayContains(["000000000000E988"], "000000000000E989")` are
  all false.
* **Fixture lookups** that select test data by key with `==` (for example `if (it.itemKey == key)
  return it;`) are not assertions. The keys they match are unique under the database's
  case-insensitive collation, so a case-insensitive lookup selects the same row.
* **`WalkSummaryFormatterTest.assertSame`** is already exact (`compare()`, with a first-difference
  report) and was left as it is.

## The guard

`tests/cfml/specs/ExactAssertionTest.cfc`:

* **At run time**, `assertEquals` and `assertNotEquals` refuse any simple operand that is exactly
  16 hexadecimal digits, optionally `0x`-prefixed. That is how this application writes a row
  version, so a row version cannot reach the coercive comparison under any variable name, alias
  included. `testTheCoerciveHelpersRefuseARowVersionToken` proves it for both forms and both cases.
* **Over the source**, `testNoSpecSendsARowVersionOrALiteralTextThroughTheCoercivePath` masks
  comments and string literals in every spec and support component and fails when a call to
  `assertEquals` or `assertNotEquals` passes a row-version expression (`row_version`, `rowVersion`,
  `rv`) or a quoted text literal, when a row version is compared with `==`, `!=`, `EQ` or `NEQ`, or
  when a spec defines its own method under a shared assertion's name. Before the migration it
  reported 500 such findings (155 row-version arguments, 345 literal-text arguments); after it, none.

The source scan covers paths a run does not execute; the run-time refusal covers values whose
variable names say nothing. Neither replaces this inventory.

## Reproducing the counts

From the repository root, on this correction's commit:

```
grep -ohE '\b(assertExactTextEquals|assertExactTextNotEquals|assertRowVersionEquals|assertRowVersionChanged|assertExactJsonEquals|assertEquals|assertNotEquals)\(' \
  tests/cfml/specs/*Test.cfc | sort | uniq -c
```

counts calls including `ExactAssertionTest`, which contributes 9, 4, 7, 5, 5, 4 and 2 of them
respectively (the helpers' own proof, not migrated call sites). Subtracting those gives the
per-helper totals of the table above: 548, 25, 78, 14, 23, and 275 on the general helpers.
