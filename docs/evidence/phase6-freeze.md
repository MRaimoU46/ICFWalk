# Phase 6 freeze record

**Phase 6 is frozen, on the project owner's direction, at code commit
`158debca5da2c4f3a07f602689cd08af9db9bd6e`.**

## Acceptance

**Accepted.** On 2026-09-25 the project owner reported that the independent re-audit passed for code
commit `158debca5da2c4f3a07f602689cd08af9db9bd6e` with records tip
`330ffb4ca50ebc68909a192b2ca7d35f4d9e5e24`. **P6A-R01 is closed. Phase 6 is accepted and frozen at
that code commit, for the verified scope**: Lucee 6.2.8.20 under jetty-runner 9.4.58, SQL Server
2022 (16.0.4295.3) and Chromium 141, with workbooks checked against LibreOffice Calc output and
accessibility checked with axe-core and the keyboard. The re-audit was independent of this session,
which did not audit its own work.

The owner's directions that come with the acceptance:

- No further Phase 6 source, test, configuration, dependency or migration change. The commits after
  `158debc` on this branch are records only, and this branch is kept as the audit record.
- Phase 7 stays separate and is not part of this acceptance. Phase 6 and Phase 7 are integrated on a
  separate branch, `claude/icfwalk-phase-6-7-integration`, created from this branch's records tip. That
  integration is a new candidate with its own gate and audit. It does not change this freeze.
- The application is not to be described as production-certified until the Adobe ColdFusion 2023,
  SQL Server 2016, connector, Microsoft Excel and screen-reader checks are completed.

The sections below are the freeze record as written before the re-audit's result. Only the list
of records-only commits has been brought up to date.

## The decision, and who made it

After the independent re-audit of the Phase 6 administration audit corrections, the project owner
directed: correct P6A-R01 (limit each stream read to `min(65536, maxBytes - total + 1)`), make the
"at most one byte past the limit" statement genuinely true in the tests and the documentation, add a
regression that exercises the production reader rather than only `FakeRequestSource`, rerun the
complete exact-commit gate -- **then freeze Phase 6**. The freeze is the owner's decision; this record
states it and what it covers. This session implemented the correction and ran the gate; it did not
audit its own work.

The condition was met:

| Step | Where |
| --- | --- |
| P6A-R01 corrected, with a regression on the production reader, red before green | `158debca5da2c4f3a07f602689cd08af9db9bd6e`; `docs/evidence/phase6-admin-read-bound-red-before-fix.md` |
| The complete gate on that exact commit, from a clean tree and a freshly created database | `docs/evidence/phase6-admin-read-bound-release-gate.txt`: Node/HTTP/Playwright 240/240, CFML 483/483, `test:package` 19/19, `validate:handoff` ok; 0 failed, 0 skipped |
| The tree clean and HEAD unchanged before and after the gate | sections 0 and 10 of that transcript |

## What is frozen

The code, tests, configuration and migrations of `158debca5da2c4f3a07f602689cd08af9db9bd6e`, the exact
commit the gate ran on. The commits after it on `claude/icfwalk-phase-6-admin-audit-corrections` add
only records: `330ffb4` (this file, the gate transcript, the environment record, and status text)
and the acceptance commit (the "Acceptance" section above and status text). `git diff
158debc <records tip> -- src app tests scripts tools database config package.json
package-lock.json manifest.json` is empty.

"Phase 6" in this freeze is everything the Phase 6 plan and the owner's additions put on this branch:

| Part | Commits |
| --- | --- |
| Publish foundation, ADM-03/04/05 (frozen earlier as the Phase 0-6 baseline) | `a219d9e0987b85b1a0b587fd62effa4e0ad1ffde` and its correction history |
| Administration: ADM-02 preview, ADM-06 clone and compare, ADM-07 retire, ADM-08 placeholder queue, and the administration UI for ADM-01 to ADM-08 | `407b0cdb5616575ef92cfb84ac57566b87f6424d` |
| The Excel round-trip for the yearly update (requested by the owner; no acceptance ID) | `0a784d58f66d6796d7ce6d55b1965f6e7d408340` |
| Audit corrections P6A-01 to P6A-04 | `06660a238c8dd6c62cacd8a27ed970e757ef22a1` |
| Re-audit correction P6A-R01, and P6A-R02 (a test-client race found while verifying it) | `158debca5da2c4f3a07f602689cd08af9db9bd6e` |
| Records only (gate transcripts, environment records, handoffs, status text) | `2b68cc0`, `786e572`, `6c2575a`, `bb6f750`, `2a3f2ec`, `3e11686`, `330ffb4` (which added this file), and the acceptance commit |

## What is not frozen

**Phase 7.** This history contains `0c6fa10972593043508f502538534c2aa95c671b` (Phase 7, aggregate
reporting), beneath the Phase 6 administration commits: the original Phase 7 commit, built by another
session before the Phase 6 administration work. A separate branch,
`claude/icfwalk-phase-7-correction-n62s25`, carries Phase 7 corrections from that commit (it forks at
`0c6fa10`) and is **not merged here**. This freeze says nothing about Phase 7: its code is present in
the frozen commit because of the order the work was done in, not because it is accepted. Bringing the
Phase 7 corrections together with frozen Phase 6 is a merge that has not been done.

## Verified, and not verified

Every result above was produced on Lucee 6.2.8.20 (under jetty-runner 9.4.58) with Microsoft SQL Server
2022 (16.0.4295.3) and Chromium 141. **Not verified:**

1. Adobe ColdFusion 2023 -- the target engine. `docs/ACCEPTANCE_TRACKING.md` requires every CFML-backed
   PASS to be re-run there before handoff. The parts most likely to differ are listed in
   `BUILD_STATUS.md` ("Unresolved and not verified" of the audit corrections and of P6A-R01): the
   unwrapping of the engine's request and whether ColdFusion has already consumed the body (which
   decides whether the byte bound applies there or the measured fallback does), `isInstanceOf` with
   Java class names, `HOLDLOCK` / `sp_getapplock` under the Adobe datasource, and the barrier specs'
   `sys.dm_exec_requests` (it needs `VIEW SERVER STATE`).
2. SQL Server 2016.
3. IIS, Apache, or any connector-level request limit (documented in `docs/LOCAL_SETUP.md`, "Request size
   limits"; not exercised).
4. Microsoft Excel (workbooks were checked against LibreOffice Calc 24.2 output only).
5. A screen reader (axe-core and keyboard checks only).

## Known limitations carried into the freeze

Recorded in `BUILD_STATUS.md` and the earlier handoffs; none is an audit finding left open.

- `preview`, `wording`, `placeholders`, `compareVersions` and `editDraft` read a version's row and then
  its snapshot in two reads (the export no longer does). For the reads this is a display mismatch at
  worst; `editDraft`'s under-lock checksum covers every case except an A-B-A change between its two
  reads.
- The approved wording for the 17 placeholder prompts is still the district's to supply.
- Structure is edited in the Excel workbook, not in the browser, by decision; editing it there is
  still technical (ids, JSON in cells).
- A 422 publish refusal is exercised at the service and HTTP level but not in the browser.
- At 375 px the version list scrolls sideways inside its own region.

## No tag

The project's earlier freezes -- the Phase 0-4 baseline `d8f3736` and the Phase 0-6 baseline
`a219d9e` -- were recorded by commit, not tagged, and the repository has no tags at all, locally or
remotely (`git tag -l` and `git ls-remote --tags origin` both empty when this record was made; the
gate transcript's section 0 also shows no `phase-5-freeze` tag). No tag was created for this freeze.
If the owner wants one, it belongs on `158debca5da2c4f3a07f602689cd08af9db9bd6e`.
