# Phase 6 administration audit corrections: environment

The environment the corrections for audit findings P6A-01 to P6A-04 were built and verified in. The
raw gate transcript is `phase6-admin-audit-corrections-release-gate.txt` in this directory; the
red-before-green record is `phase6-admin-audit-corrections-red-before-fix.md`; the handoff for the
re-audit is `phase6-admin-audit-corrections-handoff.md`.

| Item | Value |
| --- | --- |
| Branch | `claude/icfwalk-phase-6-admin-audit-corrections` (new; created from the audited commit) |
| Starting commit | `2a3f2ecb4f070401cba00518c0db8a2de823a29d` (tip of `claude/icfwalk-phase-6-admin-publish`, the candidate the audit reviewed) |
| Code commit (gated) | `06660a238c8dd6c62cacd8a27ed970e757ef22a1` |
| Records commit | the commit that adds this file; records only (see "Records-only commit" below) |
| Ancestry verified by the gate | the audited candidate `2a3f2ec`, the Phase 0-6 foundation `a219d9e0987b85b1a0b587fd62effa4e0ad1ffde`, and the Phase 5 baseline `e55ec08af5b8622db5823b6e353423b891918549` are all ancestors of the gated commit |

## Starting state

The container's local branch was `claude/icfwalk-phase-6-admin-publish` at
`0c6fa10972593043508f502538534c2aa95c671b`, behind the remote by seven commits. `git fetch origin`
showed the remote tip `2a3f2ecb4f070401cba00518c0db8a2de823a29d`; `0c6fa10` is its ancestor
(`git merge-base --is-ancestor`), the tree was clean, and the branch was fast-forwarded
(`git merge --ff-only`). The correction branch was then created from exactly `2a3f2ec` (`git checkout
-b`). Nothing was reset, rebased, force-pushed or rewritten, on either branch.

On that untouched commit, against a freshly created database, the administration suites passed:
`admin-instrument.test.mjs`, `workbook.test.mjs` and `browser-admin.test.mjs` 32/32, 0 failed, 0
skipped. (The whole suite was not run on the untouched commit in this session; its gate transcript
`excel-roundtrip-release-gate.txt` records 225/225 and 455/455 on the code commit beneath it.)

## Versions as executed

| Component | Version |
| --- | --- |
| Operating system | Ubuntu 24.04.4 LTS (kernel 6.18.44-fc-v37, x86_64) |
| Node | v22.22.2 |
| npm | 10.9.7 |
| Java | OpenJDK 21.0.10 2026-01-20 (build 21.0.10+7-Ubuntu-124.04) |
| CFML engine | Lucee 6.2.8.20 (lucee-light, under jetty-runner 9.4.58.v20250814) |
| JDBC driver | Microsoft JDBC 12.10.2 |
| SQL Server | 16.0.4295.3 Developer Edition (64-bit) |
| SQL Server image | `mcr.microsoft.com/mssql/server:2022-latest` @ `sha256:4402d880dd4c34bfa7d8705e56a86cd6c88da80a1f6bbbe741f999e76264a090` |
| Docker | 29.3.1 |
| Playwright | 1.56.1 (from the checked-in `package-lock.json`) |
| Chromium | 141.0.7390.37 |
| axe-core | 4.13.0 |
| mssql (Node driver) | 12.7.2 |

Dependencies were installed with `npm ci` from the checked-in `package-lock.json`. No dependency was
added, upgraded or removed; no schema migration was added (`git diff 2a3f2ec 06660a2 -- database
package.json package-lock.json` is empty).

## Runtime configuration

```
ICFWALK_ENVIRONMENT=development
ICFWALK_SSO_MODE=development          ICFWALK_DEV_IDENTITY_ENABLED=true
ICFWALK_MAINTENANCE_ENABLED=true      ICFWALK_MAINTENANCE_TOKEN=<random, not recorded>
ICFWALK_TESTS_ENABLED=true            ICFWALK_COOKIE_SECURE=false
ICFWALK_DB_HOST=127.0.0.1             ICFWALK_DB_NAME=icfwalk_dev   ICFWALK_DB_USER=sa
ICFWALK_DB_TRUST_SERVER_CERT=true     (local container certificate only)
ICFWALK_REQUIRE_APP=1                 (release run)
ICFWALK_SCREENSHOT_DIR=<outside the repository>   (release run)
```

`.env` is git-ignored and not part of this evidence. The barrier specs added here read
`sys.dm_exec_requests`, which needs `VIEW SERVER STATE`; the development login (`sa`) has it. A test
login without it would see only its own requests, and those specs would fail rather than pass
vacuously (the blocking observation is asserted).

## Database setup for the gate

The gate performed this itself, so the transcript records it:

```
lucee-down; ALTER DATABASE icfwalk_dev SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
DROP DATABASE icfwalk_dev; CREATE DATABASE icfwalk_dev;
node scripts/db/apply-schema.mjs                  001 .. 006 in order
node scripts/db/apply-schema.mjs --only 006       re-applied immediately (idempotence)
tools/runtime/lucee-up.sh                         application restarted on the clean database
node scripts/seed-instrument.mjs                  the aligned prototype as a DRAFT
ICFWALK_REQUIRE_APP=1 npm test                    the whole suite, screenshots outside the repository
```

## Working-tree state around the gate

The gate ran on the committed tree with no uncommitted or untracked files (section 0 of the
transcript: `porcelain lines: 0`) and with HEAD equal to the code commit; section 10 shows HEAD
unchanged and `porcelain lines: 0` afterwards. Screenshots were written outside the repository; the
committed `docs/evidence/screenshots/*.png` are unchanged by this work. The transcript was committed
in the next commit, which is records only.

## Results

| Run | Node, HTTP, Playwright | CFML | Other |
| --- | --- | --- | --- |
| Gate on `06660a238c8dd6c62cacd8a27ed970e757ef22a1` | 240/240 | 475/475 (6 parts) | `validate:handoff` ok (51 checks); `test:package` 19/19; 45 JavaScript/MJS files parse |

0 failed, 0 skipped. The browser files record page errors and console errors other than failed
resource loads (the expected 4xx answers) and assert the record empty -- `browser-admin.test.mjs` at
the end of every case -- and none of those assertions failed. The 20 new CFML cases
(`RouterBodyOrderTest` 12, `DraftReplacementConcurrencyTest` 6, `DiscardIdentityBarrierTest` 2) and
the 15 new Node cases each appear by name as passed in the transcript. Compared with the gate beneath
this work (`excel-roundtrip-release-gate.txt`, 225/225 and 455/455): +15 Node cases, +20 CFML cases,
none removed.

## Interruptions

None. Docker, SQL Server and Lucee were started once at the beginning of the session and not
restarted except for the Lucee restarts the development cycle needs (Lucee compiles components once)
and the one the gate performs.

## Not run

Adobe ColdFusion 2023, SQL Server 2016, IIS (or any connector limit), Microsoft Excel and a screen
reader were not available and were not used.
