# Phase 6 publish-foundation third correction: environment

Live verification environment for the third correction of the Phase 6 publish foundation. The raw
final transcript is `phase6-third-correction-release-gate.txt` in this directory, and the
red-before-green record is `phase6-third-correction-red-before-fix.md`.

| Item | Value |
| --- | --- |
| Branch | `claude/icfwalk-phase-6-admin-publish` |
| Starting commit (the audited candidate) | `bff53f53eaacfed977eefd4648577ed5cbba196c` |
| Frozen Phase 5 baseline | `e55ec08af5b8622db5823b6e353423b891918549` (ancestor of HEAD, verified) |
| Second correction's parent | `332f89f929ff5a9f1e81fe5273c830698fdc80af` |
| Final commit | the single commit this correction adds on top of `bff53f5` |

## Working-tree state

**Before any edit:** clean. `git status --porcelain` produced no output at all, including untracked
files, once the starting-state discrepancy below was resolved.

**After the correction:** clean except for the intentionally committed work. Section 0 of the gate
transcript records `git status --porcelain` immediately before the gate ran, so the tree the gate
executed against is on the record rather than asserted. HEAD there still reads `bff53f5` because
the gate deliberately runs *before* the commit, against the exact tree that is then committed.

One deliberate exclusion: the Playwright suite rewrites the thirteen PNGs under
`docs/evidence/screenshots/` on every run, and they came back byte-different (rendering
nondeterminism -- font hinting and antialiasing on this machine) while being visually identical.
This correction touches no browser code, so they were restored to their committed Phase 5 state
rather than committed as changes. That is the only difference between the tree the gate ran against
and the tree that was committed, and it is confined to regenerated image bytes.

### One starting-state discrepancy, resolved before any edit

The container's checkout was **stale**: the local branch pointed at
`5b243ed3d5a27142e65cdfbba8fc113ed65853e1` (the Phase 6 foundation commit, two behind) while
`origin/claude/icfwalk-phase-6-admin-publish` was at the audited
`bff53f53eaacfed977eefd4648577ed5cbba196c`. The working tree was clean and `5b243ed` is an ancestor
of `bff53f5`, so this was resolved with a plain fast-forward to the published remote tip
(`git merge --ff-only origin/claude/icfwalk-phase-6-admin-publish`). Nothing was reset, discarded or
force-checked-out, no commit was rewritten, and HEAD was then verified to be exactly the audited
candidate with no commits after it. The repository did not otherwise differ from the audited
candidate, so the correction was applied where the audit was performed.

## Phase 5 baseline ancestry

```
$ git merge-base --is-ancestor e55ec08af5b8622db5823b6e353423b891918549 HEAD; echo $?
0
```

Verified at the start of the session and again in section 0 of the gate transcript.

## `phase-5-freeze` tag, local and remote

**It does not exist, in either place**, and this correction did not create, move, delete or
force-push it:

```
$ git tag -l
(no output)
$ git ls-remote --tags origin
(no output)
```

Creating and pushing `phase-5-freeze` at `e55ec08af5b8622db5823b6e353423b891918549` remains an open
repository action for an authorized operator. This is a repository-permission item, not a code or
test result. The gate transcript re-checks both in section 0.

## Versions as executed

| Component | Version |
| --- | --- |
| Operating system | Ubuntu 24.04.4 LTS (kernel 6.18.44-fc-v37, x86_64) |
| Node | v22.22.2 |
| npm | 10.9.7 |
| Java | OpenJDK 21.0.10 2026-01-20 (build 21.0.10+7-Ubuntu-124.04) |
| CFML engine | Lucee 6.2.8.20 (lucee-light, under jetty-runner 9.4.58.v20250814) |
| JDBC driver | Microsoft JDBC 12.10.2.jre11 |
| SQL Server | 16.0.4295.3 Developer Edition (64-bit) |
| SQL Server image | `mcr.microsoft.com/mssql/server:2022-latest` @ `sha256:4402d880dd4c34bfa7d8705e56a86cd6c88da80a1f6bbbe741f999e76264a090` |
| Docker | 29.3.1 |
| Playwright | 1.56.1 (from the checked-in `package-lock.json`) |
| Chromium | 141.0.7390.37 (`/opt/pw-browsers/chromium-1194/chrome-linux/chrome`) |
| axe-core | 4.13.0 |
| mssql (Node driver) | 12.7.2 |

Dependencies were installed with `npm ci` from the checked-in `package-lock.json`. No dependency was
added, upgraded or removed, and the lockfile is byte-identical to the committed one.

## Runtime configuration

```
ICFWALK_ENVIRONMENT=development
ICFWALK_SSO_MODE=development          ICFWALK_DEV_IDENTITY_ENABLED=true
ICFWALK_MAINTENANCE_ENABLED=true      ICFWALK_MAINTENANCE_TOKEN=<44 random characters, not recorded>
ICFWALK_TESTS_ENABLED=true            ICFWALK_COOKIE_SECURE=false
ICFWALK_DB_HOST=127.0.0.1             ICFWALK_DB_NAME=icfwalk_dev
ICFWALK_DB_TRUST_SERVER_CERT=true     (local container certificate only)
ICFWALK_REQUIRE_APP=1                 (release run)
```

`.env` is git-ignored and is not part of this evidence set. The development identity stub and the
maintenance/test routes are enabled only in this development environment; `Application.cfc` refuses
to start with either in production, and `ConfigLoader` forces `testsEnabled` to false there.

## Exact database setup sequence for the gate

The gate script performs this itself, so the transcript records it rather than describing it:

```
DROP DATABASE icfwalk_dev; CREATE DATABASE icfwalk_dev;      (a database with no history at all)
node scripts/db/apply-schema.mjs
    001_schema.sql .. 005_org_unit_dimension_map.sql          applied in order
    006_version_scoped_dimensions.sql                         applied once
        legacy_membership_backfill_state  = COMPLETED
        legacy_membership_backfill_ran_now = 1
006_version_scoped_dimensions.sql                             immediately re-applied (idempotence)
tools/runtime/lucee-up.sh                                     application restarted on the clean database
node scripts/seed-instrument.mjs                              imports the aligned prototype as a DRAFT
ICFWALK_REQUIRE_APP=1 npm test                                the whole suite
```

The database therefore goes Phase 5 schema → `006` → data, which is what makes
`Migration006LifecycleTest` (publish V1, prime the caches, import V2 with a new value, re-apply
`006`) run on a database that really did come through the one-time transition rather than one
constructed to look as if it had. `tests/node/remediation-exact-identity.test.mjs` and
`tests/node/db-scripts.test.mjs` create and drop their own disposable databases inside the run and
do not touch `icfwalk_dev`.

## Counts as executed

Exact totals are in the gate transcript. At the time this record was written:

| Suite | Result |
| --- | --- |
| `npm run test:package` | `# tests 19  # pass 19  # fail 0  # skipped 0  # todo 0` |
| Node / HTTP / Playwright / CFML driver (`ICFWALK_REQUIRE_APP=1 npm test`) | `# tests 175  # pass 175  # fail 0  # skipped 0  # todo 0` |
| CFML specs, summed over 6 parts | `engine=Lucee 6.2.8.20 passed=375 failed=0 skipped=0 ms=294332 parts=6` |

The 175 figure counts Node test *cases*, one of which is the CFML suite driver; the 375 figure is
the CFML spec cases it in turn ran, reported by the suite driver itself and appearing in the
transcript as a `t.diagnostic` line. 31 spec files ran, each exactly once, asserted by comparing the
names that reported against the `*Test.cfc` files on disk.

**Corrected by the fourth correction pass.** This record originally said 26 spec files ran. That
was wrong; the transcript itself was not. Reconciled by counting both sides independently:

```
$ git ls-tree --name-only a8e97f22ae1639faef5b6e68bf7255dea838f8e2 tests/cfml/specs/ | grep -c 'Test\.cfc$'
31
$ grep -oE '^# [A-Za-z0-9]+Test\.test' phase6-third-correction-release-gate.txt | sed -E 's/^# //; s/\.test$//' | sort -u | wc -l
31
```

and the two sorted name lists are identical (`diff` prints nothing). The raw transcript
`phase6-third-correction-release-gate.txt` is kept exactly as it was produced.

For comparison with the preceding archive, which claimed 174 Node/HTTP/Playwright passes and 330
CFML passes without including the matching raw transcript: the Node count moved 174 → 175 because
this correction adds `tests/node/remediation-exact-identity.test.mjs`, and the CFML count moved
330 → 375 because it adds three spec files and cases to five existing ones. This pass includes the
raw transcript (`phase6-third-correction-release-gate.txt`), which corrects that evidence gap.

## Zero-skip enforcement method

Stated precisely, because "we set a flag" is not the whole mechanism:

1. **The gate asserts it on the totals.** `node --test` reports `# skipped`, and the gate requires
   it to be `0`. This is the enforcement that covers every test file without exception: a test that
   skipped for any reason appears in that count.
2. **The CFML suite driver asserts it on its own totals too.**
   `cfml-suite.test.mjs` asserts `totals.skipped === 0` across all six parts, and separately that
   the set of spec names that ran equals the set of `*Test.cfc` files on disk -- so a spec cannot be
   silently dropped by the partitioning and still leave the totals looking healthy.
3. **`ICFWALK_REQUIRE_APP=1` turns an absent application into a hard error** rather than a skip, in
   `admin-publish.test.mjs`, `no-mail.test.mjs` and -- added by this correction --
   `cfml-suite.test.mjs`. That last one matters most, because that file carries the entire CFML
   suite including every new deterministic concurrency barrier, and it previously skipped silently
   under the flag. **Stated accurately: the remaining app-dependent Node files
   (`auth`, `shell`, `visibility`, `walks`, `summary`, `browser`, `browser-persistence`,
   `browser-email`) still compute their own skip from reachability without consulting the flag.**
   They are covered by (1) and (2), which is why the gate's `skipped 0` is the enforcement being
   claimed here, not the flag.

## Adobe ColdFusion 2023 and SQL Server 2016 execution status

**Neither was executed. Neither is claimed.**

The production target is Adobe ColdFusion 2023 with SQL Server 2016 or later. Neither is installable
in this container, so:

* All CFML execution in this run is on **Lucee 6.2.8.20**, the repository's documented verification
  runtime (`tools/runtime/lucee-up.sh`, `docs/LOCAL_SETUP.md`). **Adobe ColdFusion 2023 remains
  unverified.**
* All SQL execution is against **SQL Server 2022**. **SQL Server 2016 remains unverified.**

### Adobe ColdFusion 2023 checklist for this correction

These are the cases whose behaviour is engine-specific and which must be re-run on Adobe ColdFusion
2023 before any claim about that platform is made:

1. `InstrumentPublishServiceTest.testATopLevelNullSnapshotIsARefusalAndNotAnEngineError`. The defect
   is Lucee's documented handling of a top-level JSON null; Adobe ColdFusion may deserialize it
   differently. The guard (`isNull(parsed) || !isStruct(parsed)`) is correct on either engine, but
   the *red* was observed only on Lucee.
2. Every case that depends on `core/JsonTypes` deciding a JSON type from the value's Java class:
   `DefinitionValidatorTest.testEveryCountMemberRefusesAJsonStringEvenWhenItNamesTheRightNumber`,
   `…RefusesABoolean`, `InstrumentPublishServiceTest.testACountStoredAsTheExactMatchingStringIsRefused`,
   `InstrumentMetadataServiceTest.testAMalformedActiveIsRefusedRatherThanCoerced`, and
   `InstrumentConfigValidatorTest.testANonStringStatusIsRejected`. `deserializeJSON` produces
   `java.lang.String` / a `java.lang.Number` subclass / `java.lang.Boolean` on both engines, but
   that is the assumption the helper rests on and it should be confirmed rather than assumed.
3. Every deterministic concurrency case, because `cfthread` attribute passing and `threadJoin`
   semantics differ between engines: `PublishConcurrencyBarrierTest` (5) and
   `SharedMetadataConcurrencyBarrierTest` (6).
4. `GlobalIdentityBoundaryTest.testBothCreatorsWriteForADraftOutsideAnyTransaction`, which depends
   on `queryExecute` returning the `OUTPUT INSERTED` result set.

### SQL Server 2016 checklist for this correction

Every SQL construct this correction adds is a SQL Server 2016 construct, and
`tests/node/schema-contract.test.mjs` refuses the later-only ones (`STRING_AGG`, `JSON_OBJECT`,
`GENERATED ALWAYS`, `GREATEST`, `LEAST`, `CREATE OR ALTER`). The constructs added are:

* `OUTPUT INSERTED.<column>` on an `INSERT ... SELECT` (SQL Server 2005+; the target tables have no
  triggers and are not the referencing side of a cascading foreign key, so the OUTPUT restrictions
  do not apply);
* `OUTPUT deleted.<column> INTO @table` on a `DELETE ... FROM ... JOIN` (2005+);
* `EXCEPT` (2005+), table variables with a `PRIMARY KEY` (2005+), `;THROW` (2012+);
* the table hint `WITH (UPDLOCK, HOLDLOCK, ROWLOCK)` on a `SELECT`.

*Running* them on SQL Server 2016 was not possible here and is not claimed.
