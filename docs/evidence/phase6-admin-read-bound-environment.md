# Phase 6 re-audit correction P6A-R01: environment

The environment the P6A-R01 correction was built and gated in. The raw gate transcript is
`phase6-admin-read-bound-release-gate.txt` in this directory; the red-before-green record is
`phase6-admin-read-bound-red-before-fix.md`; the freeze record is `phase6-freeze.md`.

| Item | Value |
| --- | --- |
| Branch | `claude/icfwalk-phase-6-admin-audit-corrections` |
| Starting commit | `3e1168663c14d069d3f033cd62456653f2bf369d` (the re-audited tip; equal to `origin` at the start) |
| Code commit (gated) | `158debca5da2c4f3a07f602689cd08af9db9bd6e` |
| Records commit | the commit that adds this file; records only |
| Ancestry verified by the gate | `3e11686`, `06660a2` (audit corrections), `2a3f2ec` (the audited candidate), `a219d9e` (the Phase 0-6 foundation) and `e55ec08` (the Phase 5 baseline) are all ancestors of the gated commit |

## Starting state

The working tree was clean at `3e1168663c14d069d3f033cd62456653f2bf369d`, the same as
`origin/claude/icfwalk-phase-6-admin-audit-corrections`. The build container had been restarted since
the previous round: Docker, SQL Server and Lucee were down. `dockerd` was started again, then
`tools/runtime/mssql-up.sh` (the existing database container, which kept its data) and
`tools/runtime/lucee-up.sh`. Nothing in the repository was changed by the restart; the gate below
dropped and recreated the database anyway.

## Versions as executed

Identical to the previous round (`phase6-admin-audit-corrections-environment.md`), re-read by the gate
(section 1 of the transcript): Ubuntu 24.04.4 LTS (6.18.44-fc-v37, x86_64); Node v22.22.2; npm 10.9.7;
OpenJDK 21.0.10; Lucee 6.2.8.20 under jetty-runner 9.4.58.v20250814 with Microsoft JDBC 12.10.2; SQL
Server 16.0.4295.3 Developer Edition (64-bit), image `mcr.microsoft.com/mssql/server:2022-latest` @
`sha256:4402d880dd4c34bfa7d8705e56a86cd6c88da80a1f6bbbe741f999e76264a090`; Docker 29.3.1; Playwright
and playwright-core 1.56.1 with Chromium 141.0.7390.37; axe-core 4.13.0; mssql 12.7.2. Dependencies
from `npm ci` with the checked-in lock file; none added, upgraded or removed; no schema migration
(`git diff 3e11686 158debc -- database package.json package-lock.json tools config` is empty).

## Runtime configuration

As in the previous round: development environment, development identity stub, maintenance and tests
enabled with a random token (not recorded), `ICFWALK_DB_*` for the local container (`sa`, which has
`VIEW SERVER STATE` for the barrier specs), `ICFWALK_REQUIRE_APP=1` and `ICFWALK_SCREENSHOT_DIR` outside
the repository for the gate. `.env` is git-ignored and not part of this evidence.

## The gate

Run by a script outside the repository (as in every earlier round), recorded in full in the
transcript: repository state and ancestry; versions; `npm ci`; `npm run validate:handoff`;
`npm run test:package`; a parse check of every tracked JavaScript/MJS file; Lucee stopped,
`icfwalk_dev` dropped and recreated, `node scripts/db/apply-schema.mjs` (001 to 006), `006` re-applied
at once; Lucee started on the clean database and the aligned DRAFT seeded; `ICFWALK_REQUIRE_APP=1 npm
test`; repository state after.

## Working-tree state around the gate

Section 0 of the transcript: HEAD `158debca5da2c4f3a07f602689cd08af9db9bd6e`, `porcelain lines: 0`.
Section 10: HEAD unchanged, `porcelain lines: 0`. The records were written only after the gate
finished, and committed as the next commit.

## Results

| Run | Node, HTTP, Playwright | CFML | Other |
| --- | --- | --- | --- |
| Gate on `158debca5da2c4f3a07f602689cd08af9db9bd6e` | 240/240 | 483/483 (6 parts) | `validate:handoff` ok (51 checks); `test:package` 19/19; every tracked JavaScript/MJS file parses |

0 failed, 0 skipped. Against the previous gate (`06660a2`: 240/240, 475/475): +8 CFML cases
(`RequestBodyReadBoundTest`), no Node case added or removed. The 8 new CFML cases appear by name as
passed in the transcript. Every browser case in `browser-admin.test.mjs` asserts that no page error
and no console error other than failed resource loads occurred, and none of those assertions failed.

## Development runs before the commit, and one failure among them

Recorded in `BUILD_STATUS.md` ("Tests and results" of P6A-R01) and in
`phase6-admin-read-bound-red-before-fix.md`: the new spec red on the committed reader (2/8) and green
after the fix (8/8); and one failure of an existing HTTP case in a development run, traced to the test
client (P6A-R02), fixed in the test's transport, then 19/19 three times and 68/68 for the four files
together.

## Not run

Adobe ColdFusion 2023, SQL Server 2016, IIS or any connector-level limit, Microsoft Excel and a screen
reader were not available and were not used.
