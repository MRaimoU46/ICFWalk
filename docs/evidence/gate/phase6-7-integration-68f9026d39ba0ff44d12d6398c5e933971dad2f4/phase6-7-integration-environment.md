# Phase 6 and Phase 7 integration: environment

The environment the merge was built and gated in. The raw gate transcript is
`phase6-7-integration-gate-transcript.txt` in this directory. The conflict-resolution diff is
`remerge-diff.txt`. The handoff is `docs/evidence/phase6-7-integration-handoff.md`.

| Item | Value |
| --- | --- |
| Branch | `claude/icfwalk-phase-6-7-integration`, created for this merge |
| Created from | `64507deb075e267761179d78be966b7a4d3972cc`, the Phase 6 records tip (code `158debca5da2c4f3a07f602689cd08af9db9bd6e`) |
| Merged | `e0342143074f727475ae2d4cb6933fa279902f85`, the Phase 7 tip, equal to `origin/claude/icfwalk-phase-7-correction-n62s25` when merged |
| Merge commit (gated) | `68f9026d39ba0ff44d12d6398c5e933971dad2f4` |
| Records commit | the commit that adds this file; records only |

## Versions as executed

Read by the gate (sections 2, 3, 6 and 10 of the transcript): Ubuntu 24.04.4 LTS (Linux 6.18.44-fc-v37,
x86_64); Node v22.22.2; npm 10.9.7; OpenJDK 21.0.10; Lucee 6.2.8.20 under jetty-runner 9.4.58.v20250814
with Microsoft JDBC 12.10.2; SQL Server 2022 16.0.4295.3 Developer Edition (64-bit) in a container created
by the gate from `mcr.microsoft.com/mssql/server:2022-latest` @
`sha256:4402d880dd4c34bfa7d8705e56a86cd6c88da80a1f6bbbe741f999e76264a090`; Docker 29.3.1; Playwright and
playwright-core 1.56.1 with Chromium 141.0.7390.37; axe-core 4.13.0; mssql 12.7.2. The same versions as
the Phase 6 gate of `158debc` and the Phase 7 gate of `98321a1`.

Dependencies came from `npm ci` with the checked-in lock file. Neither side changed `package.json`'s
dependencies or `package-lock.json` since the merge base, and the merge adds, upgrades or removes
none.

## Runtime configuration

Development environment, development identity stub, maintenance and tests enabled with a random
token (not recorded), `ICFWALK_DB_*` pointed at the gate's brand-new container (`sa`, which has
`VIEW SERVER STATE` for the barrier specs and `ALTER` for Phase 7's test-only release cleanup),
`ICFWALK_REPORT_SUPPRESSION_THRESHOLD` empty (Phase 7's approved minimum of 3), `ICFWALK_REQUIRE_APP=1`
and `ICFWALK_SCREENSHOT_DIR` outside the repository. `.env` is git-ignored and not part of this
evidence. The gate wrote the new container's generated password into it without printing it.

## Working-tree state around the gate

Section 1 of the transcript: HEAD `68f9026d39ba0ff44d12d6398c5e933971dad2f4`, both parents named exactly, the tree clean including
untracked files, the remote branch equal to HEAD. Section 11: HEAD unchanged, the tree clean and the remote branch still equal to HEAD. The
records were written only after the gate finished and were committed as the next commit.

## Results

**GATE PASSED for `68f9026d39ba0ff44d12d6398c5e933971dad2f4`** (the transcript's last line), from 2026-09-25T14:09:56Z to 14:28:42Z:

| Step | Result |
| --- | --- |
| Identity (section 1) | both parents exactly `64507de` and `e034214`, merge base `0c6fa10`; `a219d9e`, `e55ec08`, `0c6fa10`, `158debc` and `98321a1` are ancestors; the Phase 6 records after `158debc` change no code; 27 code files differ from the Phase 6 parent and 50 from the Phase 7 parent, every one a file the other parent changed; `Router.cfc`, `ReportService.cfc` and `shell.html` are each one side plus exactly the other side's changed lines; tree clean; remote equals HEAD |
| `npm ci` | 76 packages from the lock file, tree unchanged |
| `validate:handoff` | ok, 51 checks, 0 errors |
| `test:package` | 20/20 |
| JavaScript syntax | 45 tracked files, 0 errors |
| Database | a brand-new container; `001` to `007` applied; `002` to `007` each re-applied; `001` refused a second time |
| `ICFWALK_REQUIRE_APP=1 npm test` | Node/HTTP/Playwright **245/245** (fail 0, cancelled 0, skipped 0, todo 0); CFML **517/517** (failed 0, skipped 0) on Lucee 6.2.8.20; exactly the totals the two sides predict |
| Identity after (section 11) | HEAD unchanged, tree clean, remote equal to HEAD |

22 screenshots were written outside the repository. The transcript was checked for the database
password, the maintenance token, proxy settings and local scratch paths: none appears. The only
redaction is Java's `Picked up JAVA_TOOL_OPTIONS` line (the container's proxy and truststore settings).

## Development runs before the merge commit

One run of the merged tree before the merge commit, on a freshly created `icfwalk_dev` with
migrations `001` to `007` and the aligned DRAFT seeded: Node/HTTP/Playwright 245/245, CFML 517/517, 0
failed, 0 skipped, 0 todo, 0 cancelled, and `validate:handoff` ok. It used a provisional recomputation of
the manifest. After the tree was final the manifest's conflict was recreated from the index, resolved and
recomputed again, and the result was byte-identical. No failure occurred and nothing was changed after
the run except the integration section's own text in `BUILD_STATUS.md`.

## Not run

Adobe ColdFusion 2023, SQL Server 2016, IIS or any connector-level limit, Microsoft Excel and a screen
reader were not available and were not used. Phase 7's mutation harness was not re-run on the merge.
