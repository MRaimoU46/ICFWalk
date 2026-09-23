# Phase 7 correction, third round: final environment record

Record of the environment that ran the exact-commit gate for the third round of the Phase 7
correction (re-audit findings P7C-03 and P7C-04). Every value
below was read from the gate transcript, the suite's output, git, docker or the runtime
configuration when this record was written. The raw gate transcript is `phase7-correction-3-98321a16df64005f9b55fcd9bc3b9b4d4a071e4e-gate-transcript.txt`
(SHA-256 `62c4cc06e6b98cbaaf8ebe95e9c4330aca2878d1ae1110fde594e68731c0024c`, 122791 bytes). A source archive of the same commit is `phase7-correction-3-98321a16df64005f9b55fcd9bc3b9b4d4a071e4e-source.zip`
(SHA-256 `b1faa142112854b1af2dc4463398388c48e477c30e16f9d3528961659031e221`, 3780642 bytes). None of these files is part of the gated commit. The commit after
it adds this record, the transcript and the rest of the gate's evidence under `docs/evidence/gate/`
and changes nothing else (BUILD_STATUS.md, "Phase 7 correction, third round").

## Identity

| Item | Value |
| --- | --- |
| Repository | `origin` = https://github.com/MRaimoU46/ICFWalk |
| Branch | `claude/icfwalk-phase-7-correction-n62s25` |
| Commit under test (HEAD) | `98321a16df64005f9b55fcd9bc3b9b4d4a071e4e` |
| Tree | `01ce5e6d357b1ca452369fecae0e3da811d030ac` |
| Parent (the re-audited commit) | `9ef9b97b5b4ee20dd51d6ca023c0841b7ca872ba` |
| Second round's first commit | `b67df76a9fe46eefe38d47f7919a89d19c1b5d79`, ancestor of HEAD: yes |
| First audited correction | `0c74dbd5a8a79684d38ba0b169dce2682a54fad6`, ancestor of HEAD: yes |
| First audited Phase 7 candidate | `0c6fa10972593043508f502538534c2aa95c671b`, ancestor of HEAD: yes |
| Frozen Phase 6 baseline | `a219d9e0987b85b1a0b587fd62effa4e0ad1ffde`, ancestor of HEAD: yes |
| Remote branch `refs/heads/claude/icfwalk-phase-7-correction-n62s25` when this record was written | `98321a16df64005f9b55fcd9bc3b9b4d4a071e4e` |
| Working tree before the gate | transcript section 1 (`git status --porcelain=v1 --untracked-files=all`, the gate stops unless it is empty) |
| Working tree after the gate | clean (transcript section 11, and again when this record was written) |
| Gate started / ended (UTC) | 2026-09-23T18:32:58Z / 2026-09-23T18:49:08Z |
| Gate verdict | GATE PASSED |

The source archive is `git archive --format=zip --prefix=ICFWalk/ 98321a16df64005f9b55fcd9bc3b9b4d4a071e4e`. Checked when this record
was written: unzipping it into an empty directory, then `git init`, `git add -A` and `git write-tree`,
gives tree `01ce5e6d357b1ca452369fecae0e3da811d030ac`, the commit's own tree.

## Versions as executed

| Component | Version |
| --- | --- |
| OS | Ubuntu 24.04.4 LTS (kernel 6.18.44-fc-v37, x86_64) |
| Node | v22.22.2 |
| npm | 10.9.7 |
| Java | openjdk version "21.0.10" 2026-01-20 OpenJDK Runtime Environment (build 21.0.10+7-Ubuntu-124.04) |
| CFML engine (health check in the transcript) | Lucee 6.2.8.20 |
| Jetty runner | 9.4.58.v20250814 (tools/runtime/lucee-up.sh default) |
| JDBC driver | Microsoft JDBC 12.10.2.jre11 (tools/runtime/lucee-up.sh default) |
| SQL Server (SELECT @@VERSION in the transcript) | Microsoft SQL Server 2022 (RTM-CU27) (KB5104824) - 16.0.4295.3 (X64) Aug 26 2026 11:02:22 |
| SQL Server image | mcr.microsoft.com/mssql/server@sha256:4402d880dd4c34bfa7d8705e56a86cd6c88da80a1f6bbbe741f999e76264a090 |
| SQL Server container | bc165640a427 created 2026-09-23 18:33:15 +0000 UTC |
| Docker | client 29.3.1, server 29.3.1 |
| Playwright | 1.56.1 |
| Chromium | chromium chromium-1194 chromium_headless_shell-1194 ffmpeg-1011 |
| axe-core | 4.13.0 |
| mssql (Node driver) | 12.7.2 |

Adobe ColdFusion 2023 and SQL Server 2016, the production targets, were **not** executed: neither is
installable here. All CFML ran on Lucee (the repository's documented verification runtime) and all
SQL on SQL Server 2022.

## Runtime configuration (`.env`, secrets redacted)

```
ICFWALK_ENVIRONMENT=development
ICFWALK_DATASOURCE=icfwalk
ICFWALK_DB_HOST=127.0.0.1
ICFWALK_DB_PORT=1433
ICFWALK_DB_NAME=icfwalk_dev
ICFWALK_DB_USER=sa
ICFWALK_DB_PASSWORD=<29 characters, not recorded>
ICFWALK_DB_ENCRYPT=true
ICFWALK_DB_TRUST_SERVER_CERT=true
ICFWALK_LOG_LEVEL=INFO
ICFWALK_LOG_NAME=icfwalk
ICFWALK_INSTRUMENT_CODE=ICFWALK
ICFWALK_SCHOOL_DIMENSION_CODE=school
ICFWALK_MAINTENANCE_ENABLED=true
ICFWALK_MAINTENANCE_TOKEN=<44 characters, not recorded>
ICFWALK_MAINTENANCE_ALLOW_REMOTE=false
ICFWALK_TESTS_ENABLED=true
ICFWALK_SSO_MODE=development
ICFWALK_DEV_IDENTITY_ENABLED=true
ICFWALK_AUTO_PROVISION_USERS=true
ICFWALK_SESSION_TIMEOUT_MINUTES=60
ICFWALK_COOKIE_SECURE=false
ICFWALK_PLACEHOLDER_WARNINGS_BLOCK_PUBLISH=false
ICFWALK_HIDDEN_PERIOD_POLICY=RETAIN_HIDDEN
ICFWALK_REPORT_SUPPRESSION_THRESHOLD=
ICFWALK_ALLOW_UNPUBLISHED_INSTRUMENT=true
ICFWALK_PORT=8888
```

For the suite run: `ICFWALK_REQUIRE_APP=1` and `ICFWALK_SCREENSHOT_DIR` set to a directory outside
the repository.

## Database: creation and schema

Transcript sections 6 and 7. The previous SQL Server container was removed (`docker rm -f`) and its
generated password file deleted. `tools/runtime/mssql-up.sh` started a new container from the image
above with a new generated password and created empty `icfwalk_dev` and `icfwalk_test` databases.
`node scripts/db/apply-schema.mjs` then applied `001_schema.sql` through `007_report_release.sql` in
order. `002` through `007` were each applied a second time (idempotence). A second application of
`001` was refused, as designed. The resulting schema: 28 `icf` tables, triggers `TR_report_release_block_floor`, `TR_report_release_block_immutable`, `TR_report_release_block_members`, `TR_report_release_block_no_delete`, `TR_report_release_cell_immutable`, `TR_report_release_cell_no_delete`, `TR_report_release_cell_sealed`, `TR_report_release_immutable`, `TR_report_release_no_delete`, `TR_report_release_no_overlap`, `TR_report_release_walk_guard`, `TR_report_release_walk_no_delete`. The
application was started on that database (section 8) and the instrument seeded as a DRAFT.

## Commands and results

| Step | Command | Result |
| --- | --- | --- |
| Dependencies | `npm ci` | from the checked-in lockfile, tree unchanged afterwards |
| Handoff validation | `node scripts/validate-handoff.mjs` | ok true, 51 checks, 0 errors |
| Package tests | `npm run test:package` | tests 20; pass 20; fail 0; cancelled 0; skipped 0; todo 0 |
| JavaScript syntax | `node --check` on every tracked `.js` / `.mjs` | checked 40 files, 0 syntax errors |
| Full suite | `ICFWALK_REQUIRE_APP=1 ICFWALK_SCREENSHOT_DIR=<outside> npm test` | Node/HTTP/Playwright test cases: tests 198, pass 198, fail 0, cancelled 0, skipped 0, todo 0 |
| CFML suite (driven by `tests/node/cfml-suite.test.mjs`, one of the Node cases above) | `/api/maintenance/tests/run` in six parts | `engine=Lucee 6.2.8.20 passed=445 failed=0 skipped=0 ms=539089 parts=6` |

The Node figure counts test cases across 21 files, one of which is the CFML suite
driver. The CFML figure is the spec cases that driver ran, reported by the driver itself. Zero skips
are enforced three ways: the gate requires `# skipped 0`, the CFML driver asserts its own
`skipped === 0` and that every `*Test.cfc` on disk ran, and `ICFWALK_REQUIRE_APP=1` turns an absent
application into a failure rather than a skip.

## Artifacts

| File | SHA-256 | Bytes |
| --- | --- | --- |
| `phase7-correction-3-98321a16df64005f9b55fcd9bc3b9b4d4a071e4e-gate-transcript.txt` | `62c4cc06e6b98cbaaf8ebe95e9c4330aca2878d1ae1110fde594e68731c0024c` | 122791 |
| `phase7-correction-3-98321a16df64005f9b55fcd9bc3b9b4d4a071e4e-source.zip` | `b1faa142112854b1af2dc4463398388c48e477c30e16f9d3528961659031e221` | 3780642 |
| `phase7-correction-3-98321a16df64005f9b55fcd9bc3b9b4d4a071e4e-push.txt` | `7faf4f547eea262355025faa173765bea688c66adcee1bc709ad37328245a0c7` | 633 |

This record's own hash is reported with the handoff (a file cannot contain its own digest).
