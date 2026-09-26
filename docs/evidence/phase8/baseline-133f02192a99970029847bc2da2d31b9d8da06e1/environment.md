# Phase 8 baseline: environment

The environment the Phase 8 baseline gate ran in, before any Phase 8 change was made. The raw
transcript is `phase8-baseline-gate-transcript.txt` in this directory; the script is `gate.sh`.

| Item | Value |
| --- | --- |
| Branch | `claude/icfwalk-phase-8-hardening-handoff`, created and pushed for Phase 8 |
| Created from | `133f02192a99970029847bc2da2d31b9d8da06e1`, the Phase 0-7 records-only freeze tip (`docs/evidence/phase6-7-freeze.md`) |
| Frozen code | `68f9026d39ba0ff44d12d6398c5e933971dad2f4`, an ancestor of the branch; `git diff 68f9026 133f021` over code, tests, configuration, dependencies, migrations and the manifest is empty (section 1 of the transcript) |
| Gated commit | `133f02192a99970029847bc2da2d31b9d8da06e1` (tree `a7ad1822baa4fa86c380c312361276c277895ffa`) |
| Frozen branches | `claude/icfwalk-phase-6-7-integration` at `133f021`, `claude/icfwalk-phase-6-admin-audit-corrections` at `64507de`, `claude/icfwalk-phase-7-correction-n62s25` at `e034214`: each read with `git ls-remote` and unchanged |

## Versions as executed

Read by the gate (sections 2, 3, 6 and 8 of the transcript): Ubuntu 24.04.4 LTS (Linux 6.18.44-fc-v37,
x86_64); Node v22.22.2; npm 10.9.7; OpenJDK 21.0.10; Lucee 6.2.8.20 under jetty-runner 9.4.58.v20250814
with Microsoft JDBC 12.10.2 (`tools/runtime/lucee-up.sh` defaults); SQL Server 2022 (RTM-CU27)
16.0.4295.3 Developer Edition in a container created by the gate from
`mcr.microsoft.com/mssql/server@sha256:4402d880dd4c34bfa7d8705e56a86cd6c88da80a1f6bbbe741f999e76264a090`
(pinned to the digest the frozen gate of `68f9026` recorded, so the database build is the same one);
Docker 29.3.1; Playwright and playwright-core 1.56.1 with Chromium 141.0.7390.37; axe-core 4.13.0;
mssql 12.7.2. The same versions as the frozen gate of `68f9026`.

Dependencies came from `npm ci` with the checked-in lock file (76 packages; the tree unchanged).

## Runtime configuration

Development environment, the development identity stub, maintenance and the CFML test route
enabled with a random 48-character token (not recorded), `ICFWALK_DB_*` pointed at the gate's
brand-new container (`sa`), `ICFWALK_REPORT_SUPPRESSION_THRESHOLD` empty (the approved minimum of 3),
`ICFWALK_REQUIRE_APP=1` and `ICFWALK_SCREENSHOT_DIR` outside the repository. `.env` is git-ignored and
not part of this evidence; the gate wrote the new container's generated password into it without
printing it. This session had to start the Docker daemon itself (`dockerd`) before the gate; nothing
else about the machine was changed.

## Results

**GATE PASSED for `133f02192a99970029847bc2da2d31b9d8da06e1` (baseline reproduced)**, the
transcript's last line, from 2026-09-26T03:51:03Z to 04:08:16Z:

| Step | Result |
| --- | --- |
| Identity (section 1) | HEAD is the freeze tip; `68f9026` is an ancestor and the code difference from it is empty; the tree is clean including untracked files; the remote branch equals HEAD; the three frozen branches are unchanged |
| `npm ci` | 76 packages from the lock file, tree unchanged |
| `validate:handoff` | ok, 51 checks, 0 errors |
| `test:package` | 20/20 |
| JavaScript syntax | 45 tracked files, 0 errors |
| Database | a brand-new container; `001` to `007` applied; `002` to `007` each re-applied; `001` refused a second time |
| `ICFWALK_REQUIRE_APP=1 npm test` | Node/HTTP/Playwright **245/245** (fail 0, cancelled 0, skipped 0, todo 0); CFML **517/517** (failed 0, skipped 0) on Lucee 6.2.8.20: exactly the frozen gate's totals |
| Identity after (section 11) | HEAD unchanged, tree clean, remote equal to HEAD |

22 screenshots were written outside the repository and are not part of this evidence. The transcript
was checked for the database password and the maintenance token (both absent) and for proxy settings
(only Java's `Picked up JAVA_TOOL_OPTIONS` line, redacted by the gate).

## Not run

Adobe ColdFusion 2023, SQL Server 2016, IIS or Apache with the ColdFusion connector, Microsoft Excel
and a screen reader: the baseline reproduces the frozen gate's own scope and nothing more. Each is
taken up by Phase 8 separately.
