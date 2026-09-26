# Phase 6 and Phase 7 integration: handoff for a focused independent integration audit

## Current status (supersedes the submission status below)

**Accepted and frozen.** On 2026-09-26 the project owner reported that the independent Phase 7 /
focused integration audit passed. Phase 7 and the integrated Phase 0-7 baseline are accepted and
frozen at code commit `68f9026d39ba0ff44d12d6398c5e933971dad2f4`, the commit this handoff submitted, for the
verified scope. The acceptance was communicated by the owner only: no audit report, identifier or
path was provided or is in the repository, so none is cited. `68f9026` stays the frozen code hash.
The records-only commit that adds `phase6-7-freeze.md` is the records tip and the starting point for
Phase 8. Both source branches are unchanged, and no tag was created. This is not production
certification: Adobe ColdFusion 2023, SQL Server 2016, IIS/Apache or connector-level limits,
Microsoft Excel and a real screen reader were not exercised, and they carry into Phase 8. See
`phase6-7-freeze.md`.

Everything below this section is kept exactly as it was submitted for the audit.

**Status: an integration candidate submitted for a focused independent integration audit.** It is
not accepted, not frozen and not production-certified. Phase 6's acceptance covers its code commit
`158debca5da2c4f3a07f602689cd08af9db9bd6e` and does not extend to this merge. Phase 7 is not accepted.

## What to audit

| Item | Value |
| --- | --- |
| Branch | `claude/icfwalk-phase-6-7-integration` |
| The merge commit (gated) | `68f9026d39ba0ff44d12d6398c5e933971dad2f4` |
| First parent | `64507deb075e267761179d78be966b7a4d3972cc`, the Phase 6 records tip. Its code is the accepted `158debca5da2c4f3a07f602689cd08af9db9bd6e` (the diff between them over code, tests, configuration and migrations is empty). |
| Second parent | `e0342143074f727475ae2d4cb6933fa279902f85`, the Phase 7 tip: gated code commit `98321a16df64005f9b55fcd9bc3b9b4d4a071e4e` plus its gate evidence. |
| Merge base | `0c6fa10972593043508f502538534c2aa95c671b`, the original Phase 7 commit |
| Records commit | the commit that adds this file. It adds records only. |

**The gate passed on the exact merge commit**: Node/HTTP/Playwright 245/245 and CFML 517/517, 0
failed, 0 skipped, 0 todo, 0 cancelled, exactly the totals the two sides predict, from a brand-new SQL
Server container with migrations `001` to `007`, the working tree clean and HEAD unmoved before and
after (`GATE PASSED for 68f9026d39ba0ff44d12d6398c5e933971dad2f4`).

Neither source branch was changed. `claude/icfwalk-phase-6-admin-audit-corrections` stays at
`64507de` as the Phase 6 audit record, and `claude/icfwalk-phase-7-correction-n62s25` stays at
`e034214`. The integration branch was created from `64507de` and the merge is its only code commit.
Nothing was rebased, amended or force-pushed.

The evidence is in `docs/evidence/gate/phase6-7-integration-68f9026d39ba0ff44d12d6398c5e933971dad2f4/`:

| File | What it is |
| --- | --- |
| `phase6-7-integration-gate-transcript.txt` | The raw exact-commit gate of the merge commit. |
| `gate.sh` | The gate script (also printed in section 0 of the transcript). |
| `remerge-diff.txt` | The conflict-resolution diff: `git show --remerge-diff` of the merge commit. |
| `phase6-7-integration-environment.md` | Versions as executed, configuration, and what was not run. |
| `README.md` | The directory's index: each file's SHA-256 and size, and how to check them. |
| `SHA256SUMS` | SHA-256 of every file in the directory. |

## The conflict-resolution diff

`remerge-diff.txt` is `git show --remerge-diff --format=fuller 68f9026d39ba0ff44d12d6398c5e933971dad2f4`: git re-runs the merge of
the two parents, conflict markers included, and shows how the committed result differs from it.
Every hand-made change in the merge appears there, and nothing else does. Regenerate it with the
same command (git 2.36 or later).

The remerge diff contains four files and no others. No code, test, configuration or migration file
was edited by hand.

| File | Lines (+/-) | What the hand-made resolution is |
| --- | --- | --- |
| `BUILD_STATUS.md` | +399 / -336 | The scope line names Phase 7's corrections. The header's current state and reading order are written for this branch in place of the two sides' conflicting paragraphs. Git had interleaved the two sides' appended histories, matching them on a shared table header. They are replaced by the two blocks one after the other, each byte for byte as its side delivered it: Phase 7's three correction rounds, then Phase 6's sections through "Phase 6 accepted". Then the new "Phase 6 and Phase 7 integration" section. Most of the line count is the two blocks re-emitted whole in place of the interleaved hunks. |
| `docs/ACCEPTANCE_TRACKING.md` | +30 / -36 | The current status line for this branch. In the report and administration table, Phase 6's six administration rows and Phase 7's three corrected report rows replace the conflict (neither side had changed the other's rows). Phase 7's correction ledger stays under its section, followed by Phase 6's audit-corrections section. |
| `docs/ENDPOINTS.md` | +1 / -7 | Phase 7's four report rows, with Phase 6's default-version clause in the options row. |
| `manifest.json` | +4 / -14 | The two conflicting entries (`docs/DATA_CONTRACT.md`, `docs/OPEN_DECISIONS.md`), with sizes and SHA-256 recomputed from the merged files. |

Two commands confirm the appended blocks are verbatim (each prints nothing when the blocks are
identical, trailing blank lines aside):

```
strip() { sed -e :a -e '/^\n*$/{$d;N;ba' -e '}'; }
diff <(git show e034214:BUILD_STATUS.md | sed -n '/^## Phase 7 correction: RPT-03/,$p' | strip) \
     <(git show 68f9026:BUILD_STATUS.md | sed -n '/^## Phase 7 correction: RPT-03/,/^## Phase 6 administration: preview/p' | sed '$d' | strip)
diff <(git show 64507de:BUILD_STATUS.md | sed -n '/^## Phase 6 administration: preview/,$p' | strip) \
     <(git show 68f9026:BUILD_STATUS.md | sed -n '/^## Phase 6 administration: preview/,/^## Phase 6 and Phase 7 integration/p' | sed '$d' | strip)
```

## Claims, and where each is proven

| Claim | Where |
| --- | --- |
| The merge is exactly the two parents, over the expected merge base, with the frozen Phase 6 code, Phase 7's gated code and the Phase 0-6 and Phase 5 baselines as ancestors. | Gate transcript, section 1. |
| The Phase 6 parent's commits after `158debc` change no code. | Gate transcript, section 1 (`git diff 158debc 64507de` over code, tests, configuration, migrations and the manifest is empty). |
| Every code, test, configuration or migration file that differs from either parent is a file the other parent changed since the merge base. | Gate transcript, section 1. |
| Each file both parents changed (`src/http/Router.cfc`, `src/reports/ReportService.cfc`, `src/views/shell.html`) is one side's file plus exactly the other side's changed lines. | Gate transcript, section 1 (the SHA-256 of each side's changed lines, before and after the merge). |
| Both phases' tests pass together on the merged tree, from a brand-new SQL Server container with migrations `001` to `007`: every Node, HTTP, Playwright and CFML test of Phase 6 and of Phase 7. | Gate transcript, sections 6 to 10. |
| The manifest describes the merged files. | Gate transcript, section 4 (`test:package`, PKG-01). |
| The documentation conflicts were resolved deliberately, keeping both sides. | `remerge-diff.txt`; `BUILD_STATUS.md`, "Phase 6 and Phase 7 integration". |

## Where to look first

1. **`POST /api/reports/releases` under Phase 6's router.** Phase 7 wrote the route against the
   router of `0c6fa10`. On this branch it runs through Phase 6's pipeline: authentication, CSRF and
   `report.view` before the body is read, then the bounded read (the route has no limit of its own,
   so the 20,000,000-byte server maximum applies) and the parse, then
   `ReportController.createRelease(req.principal, req.body)`. Phase 7's `reports.test.mjs` exercises
   the route's CSRF refusal, unauthenticated refusal, 405 for other methods and its body contract,
   all through the merged router. No test pins this route's body limit specifically: it inherits
   the router default that `RouterBodyOrderTest` covers.
2. **`ReportService.resolveVersion`.** Phase 6's four lines (with no version in service, default to
   the newest frozen version) now sit in Phase 7's rewritten service. Phase 7 left
   `resolveVersion`, `reportableVersions` and `ReportRepository.listFrozenVersions` unchanged, and
   Phase 6's `testReportsStillOpenWhenNoVersionIsInService` runs against Phase 7's service here.
3. **Migration `007` and Phase 6's writes.** `007`'s triggers are only on the four
   `report_release*` tables. Its foreign keys reference `instrument_version`, `org_unit`, `walk` and
   `app_user`. Phase 6 deletes an instrument version only when it is a DRAFT that no walk uses, and a
   release can hold only versions with walks, so a DRAFT discard cannot meet a release's key.
   Retirement updates a version's status and touches no key.
4. **Shared test data.** Phase 7's releases are append-only and cover every active unit. Phase 6's
   and Phase 7's specs share one database in the suite, and Phase 7's fixtures remove their own
   releases with the guards disabled inside a transaction (development login only).
5. **The documentation.** `docs/ENDPOINTS.md`'s options row (Phase 7's row with Phase 6's
   default-version clause), `docs/ACCEPTANCE_TRACKING.md` (Phase 6's administration rows beside
   Phase 7's corrected report rows) and the two appended blocks in `BUILD_STATUS.md`, kept verbatim.

## Not performed

- Adobe ColdFusion 2023, SQL Server 2016, IIS or any connector-level limit, Microsoft Excel and a
  screen reader were not used. The application is not production-certified.
- Phase 7's mutation harness (`mutate.py`, sixteen mutations of the report code) was not re-run on
  the merge.
- No test was written for the combination. Both sides' existing suites ran on the merged tree.
- Phase 7's findings were not re-examined. They keep the status the Phase 7 ledger gives them.
- This session made the merge and ran the gate. It did not audit its own work.
