# Phase 8 correction A8: evidence

Branch `claude/icfwalk-phase-8-correction-cgsc7q`, at the audited Phase 8 handoff tip
`10f476ba9a69359f23a259be0e903afeed64b415` before any change (the branch pointed at an earlier commit
of the same line and was fast-forwarded to the tip with the owner's approval: `00-starting-state/`).
The **correction code commit is `b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d`** (tree
`d6458eeb5ae98e705a57a0dd6062de2a91443640`, only parent `10f476ba`). The commit that adds this directory
changes records only. **Phase 8 is submitted for independent re-audit. It is not accepted, frozen,
production-ready or production-certified**, and nothing here says otherwise. The original Phase 8
evidence (`../phase8/`) is unchanged, byte for byte.

| Finding | Audit severity | Disposition |
| --- | --- | --- |
| A8-01 `/api/health` answered 200 `ok` with no ICFWalk schema | MEDIUM | **Corrected** in `b73f519`: 200 only with `database: ok`, `schema: present` and `longText: ok` together, 503 `degraded` otherwise. Red before green, all four table states covered, a live operation on both engines against a brand-new database, docs made consistent |
| A8-02 the delivered archive was not bound to the gated code tree | MEDIUM | **Closed by the offline delivery**: a records-only commit after the gated code commit, and an archive built from it that carries a generated delivery identity record and a payload checksum manifest, verified offline (sections 6 and 7) |
| A8-03 unexplained Lucee 500s in the drafts-only workload | LOW | **Reproduced and root-caused**: every reproduced 500 was a SQL Server deadlock victim (1205) of a live report's aggregate against autosave. **Corrected** in `b73f519` (the report is computed again, within its existing three attempts), red before green. A limitation remains: `a8-03/FINDINGS.md` section 8 |

Performance acceptance remains open until the owner decides D8. Production certification is outside
this correction. Details and dispositions: `DEFECTS.md`; acceptance status: `ACCEPTANCE.md`;
environment: `environment.md`.

## 1. Red before the fix

Each red ran with the production code it tests unchanged from the audited tip, and names the
expectation the old code broke. Every red transcript records the HEAD, the working tree's status and
the SHA-256 of each file involved, compared with HEAD. The A8-01 red ran with only the new spec and its
double added; the A8-03 red ran later, with the A8-01 correction and the workload capture already in
the working tree and `ReportService.cfc` still the audited tip's.

| Finding | Red | What it shows |
| --- | --- | --- |
| A8-01 | `a8-01/red-HealthReadinessTest-lucee.txt` | `HealthReadinessTest` on Lucee: 4 passed, 2 failed, both "Expected [503] but got [200]" with the body `status: ok`, `schema: missing` (the reachable database without the schema, with and without production information-hiding). `HealthController.cfc` has the audited tip's hash |
| A8-01, live | `operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/readiness-*-live-red-on-10f476ba/` | The committed live operation run on the audited tip's code on each engine against a brand-new, unmigrated database (operations attempt 2): it fails because health answered 200 before the schema existed |
| A8-03 | `a8-03/regression/red-ReportDeadlockVictimTest-lucee.txt` | `ReportDeadlockVictimTest` on Lucee: a real deadlock (SQL Server error 1205) inside the report's transaction reached the caller as an error; the every-attempt case saw 1 attempt, not 3. `ReportService.cfc` has the audited tip's hash |
| A8-03, not red | `a8-03/regression/not-red-1-*.txt`, `not-red-2-*.txt`, `not-red-3-*.txt` | Three earlier runs of the spec that are **not** red evidence and are kept as such: twice Lucee's compiler refused the spec, once the spec's second session returned nothing. Each was fixed in the spec |

## 2. Targeted green

| Finding | Green | Result |
| --- | --- | --- |
| A8-01 | `a8-01/green-HealthReadinessTest-LongTextRetrievalTest-lucee.txt` | Lucee: `HealthReadinessTest` 6/6 and the existing `LongTextRetrievalTest` 3/3, on the corrected controller |
| A8-03 | `a8-03/regression/green-ReportDeadlockVictimTest-and-report-specs-lucee.txt` | Lucee: `ReportDeadlockVictimTest` 2/2 and every existing report spec, on the corrected service |
| Both | `targeted-green-coldfusion.txt` | Adobe ColdFusion 2023 Update 25: the new specs and the existing health and report specs, on the corrected code |

Every file these runs name has the SHA-256 it has in the correction code commit (the transcripts
print them): the code tested green is the code committed.

## 3. The exact-commit gate

`gate-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/`: `gate.sh`, `gate-transcript.txt` (every command
with its start time and exit code), each engine's TAP and passing test names, and the Phase 8 gate's
299 names it is compared with. From a clean tree at the correction code commit: `npm ci`, handoff
validation, package tests, every JavaScript and MJS file parsed, every CFML test function of the
tested Phase 8 code present, a brand-new SQL Server container (pinned digest), migrations 001 to 007
on brand-new databases with 002 to 007 re-applied and 001 refused, then the full suite on each
engine.

**GATE PASSED** for `b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d` tree
`d6458eeb5ae98e705a57a0dd6062de2a91443640`, the last line of `gate-transcript.txt` (10:43:37 to 11:18:42
UTC on 2026-09-27, exit 0):

| Engine | Node, HTTP and Playwright | CFML | Suite |
| --- | --- | --- | --- |
| Lucee 6.2.8.20 | 299/299 | 542/542 (6 parts) | 952 s, exit 0 |
| Adobe ColdFusion 2023 Update 25 (`2023,0,25,330977`) | 299/299 | 542/542 (12 parts) | 1,046 s, exit 0 |

0 failed, skipped, todo or cancelled on either engine. Also in the transcript: `validate:handoff` 51
checks, 0 errors; `test:package` 20/20; 61 JavaScript and MJS files parsed, 0 syntax errors; all 534
CFML test functions of `282a4ec` present and the 8 new ones listed by name (534 + 8 = 542 required on
each engine); SQL Server 2022 16.0.4295.3 in a brand-new container from the pinned digest; migrations
001 to 007 applied to the brand-new `icfwalk_dev` and `icfwalk_acf_gate`, 002 to 007 re-applied and
001 refused on both; ColdFusion from Adobe's pinned image in a brand-new container; every one of the
299 Node test names the Phase 8 gate passed on both engines passed on both here; HEAD, tree and a clean
status the same afterwards. `cfml-names-check.txt`, run after the gate on its two TAP files, finds all
542 CFML test functions passed by name on each engine, none missing, none extra, none twice.

## 4. Live schema-missing operations, and the other operations

`operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/`: `ops.sh`, `ops-transcript.txt`, and each
scenario's TAP and JSON record, run on the correction code commit after the gate from a clean tree.

**OPERATIONS PASSED** on `b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d`, the last line of `ops-transcript.txt`
(attempt 2, 11:52:27 to 12:01:29 UTC), from a clean tree at the gated commit, with HEAD, tree and a
clean status the same afterwards:

| Scenario | Adobe ColdFusion 2023 Update 25 | Lucee 6.2.8.20 |
| --- | --- | --- |
| Restart during autosave: the server killed mid-transaction and after commit, then Retry (`restart-*/`) | 3/3 | 3/3 |
| Production profile: fail-closed starts, gateway-only identity, cookies, CSRF, safe errors, a database outage, clean logs, a least-privileged login (`production-profile-*/`) | 1/1 | 1/1 |
| **Readiness on a brand-new database without the schema, A8-01** (`readiness-*/`) | 1/1 | 1/1 |
| **Its live red: the same operation on the audited tip's code** (`readiness-*-live-red-on-10f476ba/`) | fails as required | fails as required |
| Upgrade from the Phase 6 release through 007, this release, rollback to the frozen one (`upgrade-and-rollback/`) | | 1/1 |
| Backup and restore, a migration killed half way, a migration refused (`database-operations/`) | | 3/3 |
| The normal environment afterwards | 200 (8500, `icfwalk_acf_gate`) | 200 (8888, `icfwalk_dev`) |

No temporary database or login was left. The live readiness runs, from their own records
(`node tools/readiness-table.mjs ...`):

| Run | Engine | The brand-new database (no credentials) | Connection | Health before the migrations | Afterwards | Cleanup |
| --- | --- | --- | --- | --- | --- | --- |
| ColdFusion, corrected code | ColdFusion Server 2023,0,25,330977 | `icfwalk_a801readymujristg`: created 2026-09-27T11:56:04.410, 16.0.4295.3 Developer Edition (64-bit), tables 0, icf schemas 0, icf.instrument 0 | yes, as the runtime login (reader and writer, not owner) | 503 degraded: database ok, schema missing, longText ok | migrations (exit 0): 7 of 7 scripts OK; afterMigrationsWithoutRestart: 200 ok; afterRestart: 200 ok | engine removed true, database dropped true, login dropped true, left 0 |
| ColdFusion, audited tip's code (live red) | Adobe ColdFusion 2023 Update 25 (pinned image) | `icfwalk_a801readymujrkmgh`: created 2026-09-27T11:57:29.483, 16.0.4295.3 Developer Edition (64-bit), tables 0, icf schemas 0, icf.instrument 0 | yes, as the runtime login (reader and writer, not owner) | 200 ok: database ok, schema missing, longText ok | none: the operation failed here, "health answered 200 before the ICFWalk schema exists" (the red) | not in this record: the test stopped at its failed assertion, and its after-hook cleanup ran (the operations' final check: no temporary database or login left) |
| Lucee, corrected code | Lucee 6.2.8.20 | `icfwalk_a801readymujrn667`: created 2026-09-27T11:59:28.383, 16.0.4295.3 Developer Edition (64-bit), tables 0, icf schemas 0, icf.instrument 0 | yes, as the runtime login (reader and writer, not owner) | 503 degraded: database ok, schema missing, longText ok | migrations (exit 0): 7 of 7 scripts OK; afterMigrationsWithoutRestart: 200 ok; afterRestart: 200 ok | engine removed true, database dropped true, login dropped true, left 0 |
| Lucee, audited tip's code (live red) | Lucee 6.2.8.20 | `icfwalk_a801readymujrnfz6`: created 2026-09-27T11:59:41.070, 16.0.4295.3 Developer Edition (64-bit), tables 0, icf schemas 0, icf.instrument 0 | yes, as the runtime login (reader and writer, not owner) | 200 ok: database ok, schema missing, longText ok | none: the operation failed here, "health answered 200 before the ICFWalk schema exists" (the red) | not in this record: the test stopped at its failed assertion, and its after-hook cleanup ran (the operations' final check: no temporary database or login left) |

On the correction commit both engines answered 503 `degraded` until the migrations and 200 after them,
with no restart and after one, and the operation checked each production answer: only `application`,
`checks`, `correlationId` and `status` in the body, the same correlation id in the header, and no
database, login, datasource, secret, host, port, engine or environment value in the body. On the
audited tip's code both engines answered 200 `status: ok` with `schema: missing`, and the operation
failed there with "health answered 200 before the ICFWalk schema exists", before reaching those
checks; the bodies it recorded carry the same four keys.

**Attempt 1 is kept** (`attempt-1-coldfusion-live-red-not-observed/`, its own `README.md`): the first
run, right after the gate, ended OPERATIONS FAILED because the ColdFusion live red was not observed.
Every other scenario passed. The cause was the harness: the audited tip's tree was extracted into a
directory of mode 0700 that ColdFusion's service user could not read, so ColdFusion never answered.
It was diagnosed (ColdFusion's own log: the site's document root "is not readable"), `ops.sh` was
fixed (`chmod 755` on that directory, nothing else), the ColdFusion red was checked alone, and the
complete operations ran again from the same starting state: attempt 2, above.

## 5. A8-03 investigation and performance

`a8-03/FINDINGS.md` is the written finding: the capture added to `tests/perf/workload.mjs`, every run
with its expected 409 and unexpected totals, the seven reproduced 500s each traced by correlation id
to its `request.failed` event and to SQL Server's deadlock graph, the root cause, the correction, the
runs on the correction commit on both engines, the conditions of the submitted run, and what remains.
In every run's raw JSON, `failureTotals` and `unexpectedFailures` keep expected `409
REPORT_POPULATION_CHANGED` refusals apart from unexpected answers. No figure is a performance target
or a pass (D8).

## 6. Records-only provenance

No commit can name itself, so the proof that the commit adding this directory changes records only is
generated at packaging, from that already-final commit, outside the repository, into the archive's
`DELIVERY-IDENTITY.md` (by `tools/package.sh`):

* its only parent is the correction code commit `b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d`, whose parent
  is the audited tip, and the four Phase 8 and freeze anchors are its ancestors;
* the restricted diff from the correction code commit to it is empty:
  `git diff --name-status b73f519 <records commit> -- src app tests scripts tools database config
  package.json package-lock.json manifest.json .env.example`;
* the full `--stat` and `--name-status` of that range (this directory, `docs/ACCEPTANCE_TRACKING.md`
  and `BUILD_STATUS.md` only);
* the original Phase 8 evidence is unchanged since the audited tip, and both evidence directories pass
  `sha256sum -c`;
* the working tree was clean at exactly that HEAD and tree immediately before packaging.

That the gate and the operations ran on exactly `b73f519` is in their own transcripts: each prints
HEAD, tree and a clean status before it starts and again after it ends.

## 7. The final archive: integrity and checksums

The archive is built by `tools/package.sh` from the records-only commit with `git archive`, so its
ZIP comment is that commit. Its single top-level folder holds the commit's tree plus two generated
files: `DELIVERY-IDENTITY.md` (section 6, and the archive's name, comment and construction command) and
`PAYLOAD-SHA256SUMS` (the SHA-256 of every file in the archive except itself). Its own SHA-256 is in
the sidecar `<archive>.sha256`, beside it and outside it. The archive cannot hold its own checksum or
the commit that records it, so neither is in this directory.

To verify a delivery offline (no network, no repository; needs `unzip`, `sha256sum`, `python3`, and
`git` for the last check), with the archive and its sidecar in one folder:

```bash
sha256sum -c ICFWalk-phase8-correction-a8-<12 hex>.zip.sha256
unzip -q ICFWalk-phase8-correction-a8-<12 hex>.zip -d /tmp/x
bash /tmp/x/ICFWalk-phase8-correction-a8-<12 hex>/docs/evidence/phase8-correction-a8/tools/verify-delivery.sh \
  ICFWalk-phase8-correction-a8-<12 hex>.zip /tmp/verify
```

`verify-delivery.sh` checks the sidecar; `unzip -t`; no absolute, `..`, backslash, drive-letter,
duplicate, case-colliding, symbolic-link or `.git` entry and one top-level folder; that the ZIP comment
is the source commit the identity record names; `sha256sum -c PAYLOAD-SHA256SUMS` with every file
listed and nothing else; and that `git write-tree` over the extracted files, the two generated files set
aside, reproduces the source tree the identity record names. `package.sh` runs it on the archive it
builds and stops if any check fails.

`SHA256SUMS` in this directory lists every file here except itself: `sha256sum -c SHA256SUMS` from this
directory.

## Index

| Path | What it is |
| --- | --- |
| `README.md` | This index |
| `DEFECTS.md` | A8-01, A8-02, A8-03: what was wrong, the correction or disposition, the evidence, what remains; the starting-state discrepancy |
| `ACCEPTANCE.md` | What the correction changes in the Phase 8 acceptance status, and what it does not |
| `environment.md` | Host, engines, database, harness, configuration without secrets, the host reboot |
| `00-starting-state/` | The pre-edit checks, the discrepancy found (HEAD behind the audited tip) and the approved fast-forward |
| `a8-01/` | A8-01 red and green on Lucee |
| `targeted-green-coldfusion.txt` | A8-01 and A8-03 green on ColdFusion 2023 |
| `a8-03/` | `FINDINGS.md`; the regression's red, not-red and green runs; every workload run before and after the correction; SQL Server's deadlock record |
| `gate-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/` | The exact-commit gate |
| `operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/` | The operations on the correction code commit, the live readiness operation and its live red included (attempt 2, OPERATIONS PASSED); `attempt-1-coldfusion-live-red-not-observed/`: the first run, its diagnosis and the check of the harness fix |
| `tools/` | Every script used here: `package.sh` and `verify-delivery.sh` (A8-02); the targeted CFML runner; the workload wrappers; the deadlock and correlation tools and the table builders (`runs-table.mjs`, `correlate.mjs`, `absorbed.mjs`, `window-graphs.mjs`, `readiness-table.mjs`); `cfml-names.sh` (every CFML test passed by name); `secret-scan.sh` (no secret value of the environment in this directory); `assemble.sh` and `stage-final.sh`, which built this directory from the raw outputs |
| `SHA256SUMS` | Every file here but itself |
