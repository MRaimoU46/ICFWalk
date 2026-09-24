# Phase 6 administration and the Excel round-trip: environment

The environment the Phase 6 administration work and the Excel round-trip were built and verified in.
The raw gate transcripts are `phase6-admin-release-gate.txt` and `excel-roundtrip-release-gate.txt`
in this directory; the red-before-green records are `phase6-admin-red-before-fix.md` and
`excel-roundtrip-red-before-green.md`; the handoff for the auditor is `phase6-admin-audit-handoff.md`.

| Item | Value |
| --- | --- |
| Branch | `claude/icfwalk-phase-6-admin-publish` |
| Starting commit | `0c6fa10972593043508f502538534c2aa95c671b` (Phase 7, on top of the frozen Phase 0-6 foundation `a219d9e0987b85b1a0b587fd62effa4e0ad1ffde`) |
| Frozen Phase 5 baseline | `e55ec08af5b8622db5823b6e353423b891918549` (ancestor of HEAD, verified by both gates) |
| Commits in this work | `407b0cd` Phase 6 administration, `2b68cc0` its gate transcript, `0a784d5` Excel round-trip, `786e572` its gate transcript |
| Gated commits | `407b0cdb5616575ef92cfb84ac57566b87f6424d` and `0a784d58f66d6796d7ce6d55b1965f6e7d408340` |

## Starting state

The container's local branch was stale at `a8e97f22ae1639faef5b6e68bf7255dea838f8e2` while the
remote branch was at `0c6fa10`. The tree was clean and `a8e97f2` is an ancestor, so the branch was
fast-forwarded (`git merge --ff-only`). Nothing was reset, rebased, force-pushed or rewritten. On that
untouched commit, against a freshly created database, the whole suite passed: Node/HTTP/Playwright
193/193 and CFML 411/411, 0 failed, 0 skipped.

## Working-tree state around each gate

Each gate ran on a committed tree with **no** uncommitted or untracked files (section 0 of each
transcript prints `git status --porcelain`, empty), and section 10 shows the tree was still empty
after the run and HEAD unchanged. Screenshots were written outside the repository during the gates
(`ICFWALK_SCREENSHOT_DIR`); the committed `docs/evidence/screenshots/admin-*.png` come from
development runs made before each commit. Each transcript was then committed on its own, as the next
commit: `2b68cc0` for `407b0cd` and `786e572` for `0a784d5`. Those two commits add only the transcript,
result text in `BUILD_STATUS.md`, and the refreshed `manifest.json`; no code, test or configuration.

## `phase-5-freeze` tag, local and remote

It does not exist in either place (`git tag -l` and `git ls-remote --tags origin` both empty,
re-checked in section 0 of both transcripts). This work did not create, move or delete it.

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
| LibreOffice Calc | 24.2.7.2 -- installed into the build container (`apt-get install libreoffice-calc`) only to produce and check the workbook fixtures in `tests/fixtures/workbooks`. Nothing in the project or the gate depends on it. |

Dependencies were installed with `npm ci` from the checked-in `package-lock.json` at the start of
each gate. No dependency was added, upgraded or removed.

## Runtime configuration

```
ICFWALK_ENVIRONMENT=development
ICFWALK_SSO_MODE=development          ICFWALK_DEV_IDENTITY_ENABLED=true
ICFWALK_MAINTENANCE_ENABLED=true      ICFWALK_MAINTENANCE_TOKEN=<random, not recorded>
ICFWALK_TESTS_ENABLED=true            ICFWALK_COOKIE_SECURE=false
ICFWALK_DB_HOST=127.0.0.1             ICFWALK_DB_NAME=icfwalk_dev
ICFWALK_DB_TRUST_SERVER_CERT=true     (local container certificate only)
ICFWALK_REQUIRE_APP=1                 (release runs)
ICFWALK_SCREENSHOT_DIR=<outside the repository>   (release runs)
```

`.env` is git-ignored and not part of this evidence. The development identity stub and the
maintenance and test routes exist only in this development configuration; `Application.cfc` refuses
to start with either in production, and `ConfigLoader` forces `testsEnabled` off there.

## Database setup for each gate

The gate script performs this itself, so each transcript records it:

```
DROP DATABASE icfwalk_dev; CREATE DATABASE icfwalk_dev;
node scripts/db/apply-schema.mjs                          001 .. 006 in order
006_version_scoped_dimensions.sql                         re-applied immediately (idempotence)
tools/runtime/lucee-up.sh                                 application restarted on the clean database
node scripts/seed-instrument.mjs                          the aligned prototype as a DRAFT
ICFWALK_REQUIRE_APP=1 npm test                            the whole suite
```

No schema migration was added by this work (`git diff 0c6fa10..HEAD -- database` is empty).

## Interruptions

The build container was restarted twice during the session. Each restart stopped Docker, SQL Server
and Lucee; they were started again (`dockerd`, `tools/runtime/mssql-up.sh`, `tools/runtime/lucee-up.sh`)
and the database container kept its data. Neither restart happened during a gate: each gate ran
start to finish in one container lifetime, from a freshly created database.

## Results

| Gate | Node, HTTP, Playwright | CFML |
| --- | --- | --- |
| `407b0cd` (Phase 6 administration) | 210/210 | 449/449 |
| `0a784d5` (Excel round-trip) | 225/225 | 455/455 |

0 failed, 0 skipped in both. `validate:handoff` ok (51 checks) in both.

## Not run

Adobe ColdFusion 2023, SQL Server 2016 and Microsoft Excel were not available and were not run.
No screen reader was used.
