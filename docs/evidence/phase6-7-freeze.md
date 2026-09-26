# Phase 0-7 freeze record: Phase 7 and the integrated baseline

**Phase 7 and the integrated Phase 0-7 baseline are accepted and frozen, on the project owner's
direction, at code commit `68f9026d39ba0ff44d12d6398c5e933971dad2f4`, for the verified scope.**

## The decision, and who made it

On 2026-09-26 the project owner reported that the independent Phase 7 / focused integration audit
passed. The owner directed that Phase 7 and the integrated Phase 0-7 baseline be accepted and frozen
at `68f9026d39ba0ff44d12d6398c5e933971dad2f4`, and that this be recorded in a records-only commit.
The acceptance is the owner's decision. This record states it and what it covers.

**The audit itself.** The acceptance was communicated by the project owner only. No audit report,
identifier or path was provided to this session, and none is in the repository: when this record
was made, none of the repository's ten branches, no tag (it has none), no issue and no pull request
held one. This record therefore cites no audit document and restates none of its findings. What
ties the audit to `68f9026`:

- the owner's direction names it as the code commit to accept and freeze;
- it is the commit the integration handoff submitted for the focused integration audit
  (`docs/evidence/phase6-7-integration-handoff.md`, records commit
  `c4a3e1391107f1774203064665fedda9eeefb64c`), and no other integration candidate exists.

This session made the merge, ran its gate and wrote this record. It did not audit its own work.

## What is frozen

The code, tests, configuration, dependencies and migrations of
`68f9026d39ba0ff44d12d6398c5e933971dad2f4`, the exact commit the integration gate ran on.

| Part | Commit |
| --- | --- |
| **The frozen Phase 0-7 code** | `68f9026d39ba0ff44d12d6398c5e933971dad2f4`, a merge: first parent `64507deb075e267761179d78be966b7a4d3972cc` (the Phase 6 records tip), second parent `e0342143074f727475ae2d4cb6933fa279902f85` (the Phase 7 tip), merge base `0c6fa10972593043508f502538534c2aa95c671b` |
| Phase 6 within it, accepted and frozen earlier | `158debca5da2c4f3a07f602689cd08af9db9bd6e` (`phase6-freeze.md`) |
| Phase 7 within it | gated code `98321a16df64005f9b55fcd9bc3b9b4d4a071e4e` (the third correction round). `e034214` after it adds only that round's gate evidence. |
| The Phase 0-6 publish foundation, frozen earlier | `a219d9e0987b85b1a0b587fd62effa4e0ad1ffde` |
| Records only, after the frozen code | `c4a3e1391107f1774203064665fedda9eeefb64c` (the integration gate evidence and handoff) and the commit that adds this file |

**`68f9026d39ba0ff44d12d6398c5e933971dad2f4` stays the frozen code hash.** The commit that adds this
file contains records only, and it becomes the records tip of `claude/icfwalk-phase-6-7-integration`
and the starting point for Phase 8. `git diff 68f9026 <records tip> -- src app tests scripts tools
database config package.json package-lock.json manifest.json .env.example` is empty. Phase 8 has not
begun.

## The evidence for the frozen code

The exact-commit gate of `68f9026`, in
`gate/phase6-7-integration-68f9026d39ba0ff44d12d6398c5e933971dad2f4/` (transcript, gate script,
remerge diff, environment record, `SHA256SUMS`):

| Check | Result |
| --- | --- |
| Node/HTTP/Playwright (`ICFWALK_REQUIRE_APP=1 npm test`) | **245/245**: 0 failed, 0 skipped, 0 todo, 0 cancelled |
| CFML suite | **517/517**: 0 failed, 0 skipped |
| `test:package` | 20/20 |
| `validate:handoff` | ok, 51 checks, 0 errors |
| Totals against the two sides | exactly the merge base's plus each side's additions (Node 193 + 47 + 5, CFML 411 + 72 + 34) |
| Database | a brand-new SQL Server container, migrations `001` to `007` applied, `002` to `007` each re-applied, `001` refused a second time |
| Identity | both parents exact; every code difference from each parent a file the other parent changed; the tree clean and HEAD unmoved before and after |

The full application gate ran on `68f9026` only. The records-only commit that adds this file was
checked with `test:package` and `validate:handoff`, and nothing else was run on it.

## Source branches

Both source branches are unchanged (checked with `git ls-remote` when this record was made):

| Branch | Tip | Role |
| --- | --- | --- |
| `claude/icfwalk-phase-6-admin-audit-corrections` | `64507deb075e267761179d78be966b7a4d3972cc` | The Phase 6 audit record |
| `claude/icfwalk-phase-7-correction-n62s25` | `e0342143074f727475ae2d4cb6933fa279902f85` | The Phase 7 correction record |

## Verified, and not verified

Every result above was produced on Lucee 6.2.8.20 under jetty-runner 9.4.58, with Microsoft SQL
Server 2022 (16.0.4295.3) in Docker, Node 22.22.2 and Playwright 1.56.1 with Chromium 141. Workbooks
were checked against LibreOffice Calc output, and accessibility with axe-core and the keyboard.

**This is not production certification.** The following were not exercised in the recorded
environment and carry into Phase 8:

1. **Adobe ColdFusion 2023**, the target engine. Every CFML-backed PASS in
   `docs/ACCEPTANCE_TRACKING.md` has to be re-run there. The engine-sensitive constructs are listed
   in each round's "Unresolved and not verified" in `BUILD_STATUS.md`.
2. **SQL Server 2016**, the minimum target database.
3. **IIS, Apache or any connector-level request limit** (`docs/LOCAL_SETUP.md`, "Request size
   limits").
4. **Microsoft Excel.** The workbooks were checked against LibreOffice Calc output only.
5. **A real screen reader.** Only axe-core and keyboard checks were run.

## Known limitations carried into Phase 8

None is an open audit finding. Each is recorded where it was first found.

From Phase 6 (`phase6-freeze.md`, "Known limitations carried into the freeze"):

- `preview`, `wording`, `placeholders`, `compareVersions` and `editDraft` read a version's row and
  then its snapshot in two reads. For the reads this is a display mismatch at worst, and
  `editDraft`'s under-lock checksum covers every case except an A-B-A change between its two reads.
- The approved wording for the 17 placeholder prompts is still the district's to supply.
- Structure is edited in the Excel workbook, not in the browser, by decision, and editing it there
  is still technical (ids, JSON in cells).
- A 422 publish refusal is exercised at the service and HTTP level but not in the browser.
- At 375 px the version list scrolls sideways inside its own region.

From Phase 7 (`BUILD_STATUS.md`, "Unresolved and not verified" of the three Phase 7 correction
rounds):

- The accepted residuals of the approved RPT-03 rule: a block whose walks all fall in one category
  publishes it complete, collusion between users with different scopes and outside knowledge are not
  addressed by aggregate suppression, and walk-and-report roles keep unsuppressed live figures for
  walks they can open.
- Utility: small schools disappear from released reports, report-only district figures exclude
  withheld cells, linked groups are withheld whole where one member has a small cell, and a walk
  corrected into dates already released is never released.
- The application enforces closed, non-overlapping release dates but no term or school-year
  cadence, and a release made in error cannot be withdrawn.
- A release omits walks pinned to a version that is neither current nor PUBLISHED or RETIRED.
- A login allowed to alter the schema can still change or remove a release. The runtime login must
  not be one.

From the integration (`BUILD_STATUS.md`, "Phase 6 and Phase 7 integration", and the integration
handoff, "Not performed"):

- No test pins the release route's 20,000,000-byte body limit specifically. The route inherits the
  router's default, which `RouterBodyOrderTest` covers.
- Phase 7's mutation harness was not re-run on the merged code.

## No tag

No tag was created. The repository has none, locally or remotely, and the project's earlier freezes
were recorded by commit. A tag is created only if separately requested. If one is wanted, it belongs
on `68f9026d39ba0ff44d12d6398c5e933971dad2f4`.
