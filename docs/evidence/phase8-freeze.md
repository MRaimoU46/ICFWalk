# Phase 8 freeze record: hardening and handoff, with correction A8

**Phase 8 is accepted and frozen, on the independent final freeze audit the project owner supplied,
with records and delivery tip `bbb4d1592d09d35d707741af462849622000091a` and gated code anchor
`b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d`, for the verified scope.**

## The decision, and who made it

On 2026-09-29 the project owner gave this session the independent "ICFWalk Phase 8 Final Freeze
Audit" (independent final correction and delivery verification). Its verdict is **READY TO FREEZE
PHASE 8**, with A8-01, A8-02 and A8-03 closed and no remaining freeze blocker. Its final decision:
Phase 8 has earned its freeze, the freeze records and delivery tip is `bbb4d15`, the gated code anchor
`b73f519` and the archive checksum are preserved, and the archive, its sidecar and the audit are kept
together as the Phase 8 acceptance set. The acceptance is the owner's, on that audit. This record
states it and what it covers.

**The audits.** The owner supplied the text of two audits. Both are kept in `phase8-freeze/`, exactly
as supplied (table cells separated by tabs, as received):

| File | Audit | Verdict |
| --- | --- | --- |
| `phase8-freeze/final-freeze-audit-2026-09-29.txt` | ICFWalk Phase 8 Final Freeze Audit, 2026-09-29, of the packaged archive `ICFWalk-phase8-correction-a8-bbb4d1592d09.zip` and its sidecar | READY TO FREEZE PHASE 8. A8-01, A8-02 and A8-03 verified and closed |
| `phase8-freeze/correction-reaudit-2026-09-29.txt` | ICFWalk Phase 8 Correction Independent Re-audit, 2026-09-29, of the branch export `ICFWalk-claude-icfwalk-phase-8-correction-cgsc7q.zip` | NOT READY TO FREEZE PHASE 8. A8-01 and A8-03 verified and closed, A8-02 open until the archive built by `package.sh` and its sidecar were supplied |

Two earlier audits were not supplied to this session and are not in the repository: the independent
audit of the Phase 8 handoff that raised A8-01 to A8-03 (NOT READY TO FREEZE PHASE 8, as the
correction's records quote it), and a re-audit of a duplicate upload, which the correction re-audit
says it supersedes.

This session built Phase 8 (code `282a4ec`, records `10f476b`), packaged the A8 delivery from
`bbb4d15` and wrote this record. Correction A8 (`b73f519`, `bbb4d15`) was made in another Claude
session on this branch. The audits were independent. No session audited its own work.

## What is frozen

The code, tests, configuration, dependencies and migrations of
`b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d`, the exact commit the correction gate and operations ran on,
with the records of `bbb4d1592d09d35d707741af462849622000091a`, the source of the accepted archive.

| Part | Commit |
| --- | --- |
| **Records and delivery tip**, the accepted archive's source | `bbb4d1592d09d35d707741af462849622000091a`, tree `4e0afcd710987847081594e4d42d8a15b604aa87`, only parent `b73f519` |
| **Gated code anchor**, the correction code commit | `b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d`, tree `d6458eeb5ae98e705a57a0dd6062de2a91443640`, only parent `10f476b` |
| The audited Phase 8 handoff tip, records only | `10f476ba9a69359f23a259be0e903afeed64b415` |
| The tested Phase 8 code before the correction | `282a4ec27cd5d200ed190b134c0145632a970cee` |
| The Phase 0-7 records-only freeze tip Phase 8 started from | `133f02192a99970029847bc2da2d31b9d8da06e1` |
| The frozen Phase 0-7 code | `68f9026d39ba0ff44d12d6398c5e933971dad2f4` |
| Records only, after the freeze | the commit that adds this file |

**`b73f519` is the frozen Phase 8 code and `bbb4d15` its records and delivery tip.** The commit that
adds this file contains records only: `git diff b73f519 <that commit> -- src app tests scripts tools
database config package.json package-lock.json manifest.json .env.example` is empty, and neither
`docs/evidence/phase8/` nor `docs/evidence/phase8-correction-a8/` changes. It becomes the tip of
`claude/icfwalk-phase-8-correction-cgsc7q` and the starting point for any later work. It is not part of
the accepted delivery. Phase 8 is the last phase of `docs/IMPLEMENTATION_PLAN.md`.

## The acceptance set

| Item | Value |
| --- | --- |
| Archive | `ICFWalk-phase8-correction-a8-bbb4d1592d09.zip` |
| Archive SHA-256 | `65fdd70c9fc8162ee5276fea84d7b2ffc267adbb77ca2d9323bbdcc41b61dd9d` |
| Archive size | 9,378,493 bytes |
| ZIP comment | `bbb4d1592d09d35d707741af462849622000091a`, written by `git archive` |
| Contents | 943 entries under `ICFWalk-phase8-correction-a8-bbb4d1592d09/`: 145 folders and 798 files, the 796 of the source tree, `DELIVERY-IDENTITY.md` and `PAYLOAD-SHA256SUMS` (797 files) |
| Sidecar | `phase8-freeze/ICFWalk-phase8-correction-a8-bbb4d1592d09.zip.sha256`, byte for byte the delivered one |
| Delivery identity record | `phase8-freeze/DELIVERY-IDENTITY.md`, byte for byte the one in the archive (SHA-256 `0a349540941c8d8d6bb6dde19b98269719ab94c4d725c68cacc417eea8aeb68b`), written at packaging, 2026-09-29T13:35:15Z, by `docs/evidence/phase8-correction-a8/tools/package.sh` |
| The audit | `phase8-freeze/final-freeze-audit-2026-09-29.txt` |

`phase8-freeze/SHA256SUMS` lists every file of that directory except itself: `sha256sum -c SHA256SUMS`
from that directory.

`package.sh` built the archive from `bbb4d15` on a clean tree and ran the included verifier on it
(DELIVERY VERIFIED). This session then ran the verifier shipped inside the archive on a copy of the
archive and sidecar in an empty folder, with a minimal environment (only `PATH` and a new `HOME`) and no
repository: exit 0, DELIVERY VERIFIED. The auditor verified the same bytes offline.

**The archive's bytes are not in the repository.** They hold the whole source tree of `bbb4d15`, so
committing them would put a second copy of the source into every later archive of this branch. They
also cannot be rebuilt byte for byte: `package.sh` writes the time of packaging into
`DELIVERY-IDENTITY.md`, so a new run makes a different archive with a different checksum, although
`git archive bbb4d15` still reproduces the same source tree. The copy the auditor verified is the one
the owner holds, and it is the one to keep with the sidecar and the audit. The copy made in this
session's container was temporary.

To check a copy of the archive offline, with the archive and the sidecar in one folder:

```bash
sha256sum -c ICFWalk-phase8-correction-a8-bbb4d1592d09.zip.sha256
unzip -q ICFWalk-phase8-correction-a8-bbb4d1592d09.zip -d /tmp/x
bash /tmp/x/ICFWalk-phase8-correction-a8-bbb4d1592d09/docs/evidence/phase8-correction-a8/tools/verify-delivery.sh \
  ICFWalk-phase8-correction-a8-bbb4d1592d09.zip /tmp/verify
```

The verifier must end `DELIVERY VERIFIED` with exit 0.

## Findings

| Finding | Severity | Disposition | Record |
| --- | --- | --- | --- |
| A8-01 `/api/health` answered 200 without the ICFWalk schema | MEDIUM | VERIFIED AND CLOSED | `phase8-correction-a8/DEFECTS.md` |
| A8-02 the delivery was not bound to the gated tree | MEDIUM | VERIFIED AND CLOSED | the acceptance set above |
| A8-03 unexplained Lucee report 500s | LOW | VERIFIED AND CLOSED in the original scope | `phase8-correction-a8/a8-03/FINDINGS.md` |
| P8-01 to P8-14 | 2 CRITICAL, 2 HIGH, 7 MEDIUM, 3 LOW | Corrected in Phase 8. The correction's records report that the Phase 8 audit verified them within their stated scope | `phase8/DEFECTS.md` |

## The evidence for the frozen code

The exact-commit gate of `b73f519`, in
`phase8-correction-a8/gate-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/`, 2026-09-27, 10:43:37 to 11:18:42
UTC, from a clean tree, on a brand-new SQL Server container and brand-new databases:

| Engine | Node, HTTP and Playwright | CFML |
| --- | --- | --- |
| Lucee 6.2.8.20 | **299/299** | **542/542** |
| Adobe ColdFusion 2023 Update 25 | **299/299** | **542/542** |

0 failed, skipped, todo or cancelled on either engine. Also: `validate:handoff` 51 checks and 0
errors, `test:package` 20/20, every JavaScript and MJS file parsed, migrations 001 to 007 applied, 002 to
007 re-applied and 001 refused, and every CFML test function passed by name on each engine (the 534 of
`282a4ec` and 8 new ones).

The operations on `b73f519`, in
`phase8-correction-a8/operations-b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d/`: OPERATIONS PASSED (attempt 2.
Attempt 1 is kept, ended by a harness fault that was diagnosed and fixed in the harness only). They
cover readiness on a brand-new database without the schema on both engines, with its live red on the
audited tip's code, restart during autosave (3/3 on each engine), the production profile on both
engines, upgrade from the Phase 6 release and rollback, backup and restore, and a killed and a refused
migration.

The Phase 8 evidence before the correction is unchanged since `10f476b` (`phase8/`, 200 checksums): the
baseline reproduced on the Phase 0-7 freeze tip, the Phase 8 gate on `282a4ec` (299/299 and 534/534 on
both engines), the Phase 8 operations, performance and accessibility.

On the commit that adds this file only `validate:handoff`, `test:package`, `sha256sum -c` of both
evidence directories and of `phase8-freeze/`, and the restricted diff were run.

## Verified, and not verified

Every result above was produced on Lucee 6.2.8.20 under jetty-runner 9.4.58 and on Adobe ColdFusion
2023 Update 25 (Adobe's image, its built-in web server, Microsoft JDBC 12.10.2), with Microsoft SQL
Server 2022 (16.0.4295.3) in Docker, Node 22.22.2, Playwright 1.56.1 with Chromium 141 and axe-core
4.13.0.

**This is not production certification.** Each item below has a runnable checklist and an evidence slot
in `docs/VERIFICATION_CHECKLISTS.md` and stays NOT TESTABLE HERE until it is run there:

1. Adobe ColdFusion 2023 with its own SQL Server driver (the DataDirect `sqlserver` package), behind IIS
   or Apache with the ColdFusion connector (checklist 1).
2. SQL Server 2016 (checklist 2). A static check finds no T-SQL newer than it.
3. Request-size limits at IIS, Apache and the connector (checklist 3).
4. The instrument workbook round trip in Microsoft Excel (checklist 4).
5. A real screen reader, used by a person experienced with it (checklist 5).
6. The district SSO gateway, TLS and its cookie policy (checklist 6, owner decisions D1 and D2).
7. Performance acceptance (checklist 7). No criteria are approved (D8), so the workload measured and did
   not judge.

Also not done: the email draft opened in a real mail client, production hardware, and several
application servers behind a load balancer.

## Known limitations carried with the freeze

None is an open audit finding. Each is recorded where it was found.

From A8-03, the residuals the final audit lists as non-blocking (`phase8-correction-a8/a8-03/FINDINGS.md`):

- Deadlocks between a live district report and autosave still occur and can use up retry attempts.
- A report that is the deadlock victim on all three attempts still fails with a database error.
- Release creation reads through a related path and does not get this retry. No such failure was
  observed.
- Removing the conflict needs row-versioned reads, a database isolation change and a migration, and an
  owner decision.

From Phase 8 and the correction:

- **D14.** Over the full synthetic population, while completed walks were edited, most live and CSV
  district reports answered the expected 409 "run the report again", by design. The Phase 8 records'
  "now rare" rested on runs that counted only a few hundred walks, as the correction found.
  `docs/OPERATIONS.md` section 12 no longer states a rate.
- **D8.** My Walks and the report's candidate selection scan the walk table. The indexes SQL Server
  suggests are not added.
- The instrument version row, with its snapshot of about 218 KB, is read on every walk request.
- The response to the request that signs a person in shows the stored display name until the next
  request.
- On Lucee only, the servlet container's JSESSIONID lacks `Secure` behind a TLS-terminating gateway. It
  is proven to carry no session.

Owner decisions D1 to D12 and D14 are open. D13 (k = 3, frozen releases) is decided
(`phase8/OWNER_DECISIONS.md`).

## Branches

Checked with `git ls-remote` when this record was made:

| Branch | Tip | Role |
| --- | --- | --- |
| `claude/icfwalk-phase-8-correction-cgsc7q` | `bbb4d15` before the commit that adds this file | The frozen Phase 8 records and delivery, then this record |
| `claude/icfwalk-phase-8-hardening-handoff` | `10f476ba9a69359f23a259be0e903afeed64b415` | The audited Phase 8 handoff, unchanged |
| `claude/icfwalk-phase-6-7-integration` | `133f02192a99970029847bc2da2d31b9d8da06e1` | The Phase 0-7 freeze, unchanged |

## No tag

No tag was created. The repository has none, locally or remotely, and the project's freezes are
recorded by commit. A tag is created only if separately requested. If tags are wanted, they belong on
`b73f5190f4b3c326a2ceb48e2b15e64b8ae1fd5d`, the code anchor, and on
`bbb4d1592d09d35d707741af462849622000091a`, the records and delivery tip.
