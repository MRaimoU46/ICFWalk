# Phase 8 evidence: hardening and handoff

Branch `claude/icfwalk-phase-8-hardening-handoff`, started from the Phase 0-7 records-only freeze tip
`133f02192a99970029847bc2da2d31b9d8da06e1` (frozen code `68f9026d39ba0ff44d12d6398c5e933971dad2f4` is its
ancestor). The Phase 8 code commit is **`282a4ec27cd5d200ed190b134c0145632a970cee`**; the commit that adds this directory changes
records only. **Phase 8 is submitted for independent final audit. It is not accepted, frozen,
production-ready or production-certified**, and nothing here says otherwise.

## Verdict of the final gate

**GATE PASSED** on `282a4ec27cd5d200ed190b134c0145632a970cee`, the last line of
`gate-282a4ec27cd5d200ed190b134c0145632a970cee/phase8-final-gate-transcript.txt`, from a clean tree, `npm ci`, a
brand-new SQL Server container and brand-new databases:

| Engine | Node, HTTP and Playwright | CFML |
| --- | --- | --- |
| Lucee 6.2.8.20 | 299/299 | 534/534 (6 parts) |
| Adobe ColdFusion 2023 Update 25 | 299/299 | 534/534 (12 parts) |

0 failed, skipped, todo or cancelled on either engine. Every Node test the baseline gate ran (245)
passed on both engines, all 517 CFML test functions of the frozen code still exist, `test:package`
20/20, `validate:handoff` 51 checks, 58 scripts parsed, migrations 001 to 007 applied, 002 to 007
re-applied and 001 refused on both databases, and the tree and HEAD were unchanged afterwards. The
first attempt stopped at its own step 6 because of a bug in the gate script (`git show | grep -q`
under `pipefail`), before touching any database; its transcript is kept beside the passing one.

## Index

| Path | What it is |
| --- | --- |
| `ACCEPTANCE_LEDGER.md` | Every acceptance ID: method, evidence, environment, result, and what is still not verified |
| `DEFECTS.md` | P8-01 to P8-14: severity, what was wrong, the correction, the red and green evidence; observations left open |
| `OWNER_DECISIONS.md` | D1 to D14 (D13 decided) and the environments only the district has |
| `environment.md` | Versions, images by digest, configuration without secrets, and what was not run |
| `baseline-133f02192a99970029847bc2da2d31b9d8da06e1/` | The existing full gate reproduced on the freeze tip before any change (245/245, 517/517) |
| `gate-282a4ec27cd5d200ed190b134c0145632a970cee/` | The final gate on the code commit: script, transcript, both engines' TAP, totals; the first attempt stopped by a bug in the gate script itself, kept |
| `defects/` | Red-before-green transcripts for every defect, and the ColdFusion diagnostics |
| `acf/` | Adobe ColdFusion 2023 discovery runs before the code commit (CFML in 12 parts, Node and browser suites, reruns) |
| `operations/` | Upgrade from the Phase 6 release through 007 and rollback to the frozen release; backup and restore (a small database and the 2 GB synthetic one); killed and refused migrations; restart during autosave on both engines; the production profile on both engines. `on-the-code-commit/` is all of them again on the exact code commit after the gate (OPERATIONS PASSED), with its script and transcript |
| `performance/` | The synthetic workload: data, method, results before and after P8-14 on both engines, SQL plans, findings. No target was set, so no pass or fail |
| `accessibility/` | The accessibility sweep's findings on both engines and a selection of its screenshots |
| `SHA256SUMS` | Every file here, this README included: `sha256sum -c SHA256SUMS` from this directory |

## Not performed here, and why

Each has a runnable checklist and an evidence slot in `docs/VERIFICATION_CHECKLISTS.md`; until run
there it is **NOT TESTABLE HERE**.

| Check | Why not here | Checklist |
| --- | --- | --- |
| Adobe ColdFusion 2023 with its own SQL Server driver (DataDirect `sqlserver` package), behind IIS or Apache with the ColdFusion connector | The package downloads from adobe.com, which is not reachable here; no Windows host, IIS or connector. ColdFusion 2023 itself was run (Adobe's image, built-in web server, Microsoft's JDBC driver) | 1 |
| Microsoft SQL Server 2016 | Windows only; no image runs here. Every run is SQL Server 2022; a static check finds no newer T-SQL | 2 |
| Request-size limits at IIS, Apache and the connector | No web server or connector here; the application's own limits and ColdFusion's post ceiling were exercised | 3 |
| The instrument workbook round trip in Microsoft Excel | No Excel here; the round trip through the workbook reader and writer is tested | 4 |
| A real screen reader | None here, and it needs a person experienced with it; axe-core, the keyboard sweep and ARIA snapshots were run | 5 |
| The district SSO gateway, TLS and its cookie policy | The gateway product, identity provider and topology are owner decisions (D1, D2); the header adapter was exercised in the production profile | 6 |
| Performance acceptance | No criteria have been approved (D8); the workload measured, it did not judge | 7 |
