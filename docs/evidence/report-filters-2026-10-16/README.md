# Report filters (the owner's decisions of 2026-10-16), evidence

Branch `claude/icfwalk-phase-8-correction-cgsc7q`. The **last code commit is
`0c7cf916507e47fa7f83b4e6c1e897f81252a294`** (tree `b6ab58e8d98c1d776a79af68d0b6f34d927ea1ac`). The change is five commits in a line on
the step 2 wording correction's records commit `eb0d4ef`: `8597069` (the server), `2e359a7` (the page),
`e9e0a3b` (the new-walk chooser, the counting note only when true, the docs), `04548c7` (a filter's
summary) and `0c7cf91` (two comments). The commit that adds this directory changes records only.

**What the owner asked**, verbatim: "I selected Section filter, ran a report. and it kept the upper walk
summary counts the same and only filtered the data at the bottom. Also, I will need a filter for network.
We have schools grouped by network. Filters should also be multi select for School, Network, Grade,
Subject, Period, Program, Visit occurred at the:. The other filters are fine." Asked which walks a report
should cover when someone picks a Section, they chose "Walks where it was shown (Recommended)". Both
decisions are recorded in `docs/OPEN_DECISIONS.md`.

**What changed.**

- A live report with a Section or Question counts only the walks where it was shown (a recorded response
  state other than `HIDDEN` for the question, or for any reportable question of the section), in every
  figure, and says so: `filters.walksWhereShown`, the CSV's `META` `population_rule`, and a line under
  "Walks in this report". A released report keeps counting every released walk, because a release holds
  block totals, not walks, and says that instead. A section with no reportable question beneath it
  narrows nothing and says nothing.
- `orgUnitId` and every `dim_<code>` take several values, as a comma list or the parameter repeated: a walk
  matches any value of a filter and every filter. Each named unit is authorized on its own, and the
  population is the named units' covered descendants, each walk once. The report format is
  `icfwalk-aggregate-report/3` (`filters.orgUnitIds[]`, each `filters.dimensions` entry a list,
  `walksWhereShown`).
- Networks are `NETWORK` org units between the district and its schools, loaded by the org-unit import
  (`docs/OPERATIONS.md` 9.2); the schema does not change. The page offers Network, and School narrowed to
  the chosen networks, Grade level, Content / Subject Area, Period, Program and Visit timing as checkbox
  lists in a disclosure, operable from the keyboard. The new-walk chooser never offers a network.

| Directory or file | What it holds |
| --- | --- |
| `gate/` | The exact-commit gate of `0c7cf91`: `gate.sh`, its transcript, each engine's TAP and passing names, and the wording correction's gate names they are compared with |
| `ops/` | `docs/OPERATIONS.md` 9.2 on each engine, on the gate's databases: `ops-networks.mjs` and its output for ColdFusion and Lucee |
| `red/` | Red before green on Lucee: `red.sh`, its transcript, and the TAPs of both runs |
| `SHA256SUMS` | Every file here but itself |

## Result

**GATE PASSED** for `0c7cf91` (tree `b6ab58e8d98c1d776a79af68d0b6f34d927ea1ac`), from a clean tree, each
engine on a brand-new database migrated 001 to 008 (002 to 008 re-applied, 001 refused a second time):

| Engine | Node, HTTP, Playwright | CFML |
| --- | --- | --- |
| Lucee 6.2.8.20 | 326/326 | 559/559 |
| Adobe ColdFusion 2023 Update 25 (`ColdFusion Server 2023,0,25,330977`) | 326/326 | 559/559 |

Every one of the 324 Node test names the wording correction's gate passed on both engines passes on both
engines here; the two names it did not have are this change's HTTP and browser tests ("owner
2026-10-16: ..."), and both engines passed the same names. The 557 CFML test functions at `eb0d4ef` all
exist and ran, with this change's two (`testSeveralValuesOfAFilterCountAnyOfThem`,
`testNetworksAndSeveralUnitsNarrowTogetherWithinScope`). `validate:handoff` (51 checks), `revision:check`
and `test:package` (32/32) passed; Node 22.22.0, Playwright 1.56.1 with Chromium 141.0.7390.37,
axe-core 4.13.0, mssql 12.7.2.

**Operations (`ops/`), 10 of 10 on each engine.** On a district whose two schools already have walks, one
of them mapped to a School value, the documented re-import puts each school under a new network. After
it the district lead still counts every walk, a network counts exactly its schools' walks, two networks
count all of them, and a network named with one of its schools counts each walk once. The school's
walker still lists and reports its walks, and a new walk there still carries the school's School value,
so the mapping stayed. The documented warning holds: with a network inactive the district lead loses
its school, and the school's own walker keeps it. Reactivating restores it, and moving the school first
and then deactivating the network loses nothing.

**Red before green (`red/`).** With the five files this change's code is in put back to `eb0d4ef` and the
tests as committed, `reports.test.mjs` failed the options route's format and the owner's test (14 of 16
passed), and `browser-reports.test.mjs` failed the owner's test and the five others that operate the new
checkbox lists (2 of 8 passed). Restored, both passed in full (16/16, 8/8) and the tree was clean.

## How it was run

`gate/gate.sh 0c7cf916507e47fa7f83b4e6c1e897f81252a294 <directory outside the repository>`, its output in
`gate/gate-transcript.txt` (the last line, `gate exit=0`, is the wrapper's record of the script's exit
status). It is the wording correction's gate
(`../instrument-revision-2026-10-14-step2-wording/gate/gate.sh`) with its base moved to that
correction's records commit, its identity check moved from one commit to the change's five, its diff
check to the change's sixteen files, and its baselines to that gate's results plus exactly two new Node
tests and two new CFML test functions. `gate/gate.sh` is byte for byte the copy its transcript prints.
Screenshots were written outside the repository and are not kept.

Two earlier starts of the gate were stopped by hand during the Lucee suite, before any result, each to
add a commit to the change (`04548c7`, then `0c7cf91`); the gate here is the only one that ran to the end.

`ops/ops-networks.mjs` ran after the gate against ColdFusion (port 8500, database `icfwalk_acf_gate`),
then against Lucee (port 8888, database `icfwalk_dev`, started on the same code), each with its own
fixtures, removed at the end through the maintenance cleanup. Two earlier runs on ColdFusion are not kept:
the first stopped on the probe's own error (it loaded the SQL Server driver as an ES module default), and
the second tried to delete its scratch draft, which ICFWalk always refuses (409, WALK-08); the probe now
voids it. Both fixtures were removed by the same cleanup.

`red/red.sh 0c7cf916507e47fa7f83b4e6c1e897f81252a294 <directory outside the repository>` ran last, on
Lucee.

Before the gate, `reports`, `browser-reports`, `browser-multiple`, `browser-a11y-sweep`,
`browser-xss-sweep`, `shell`, `security-surface`, `cfml-portability` and `package` passed on Lucee, run
one file at a time with Google Fonts out of the browser's reach, as the gate runs them. On the first
run of `browser-a11y-sweep` its keyboard traversal counted the checkboxes of closed lists as visible
(Chromium keeps a layout box for a closed disclosure's content), so it now asks `checkVisibility()` too;
and the administration panel at 375 px timed out once while the server compiled its pages, then passed.

No transcript, TAP or output here holds a password, token or proxy credential: each was checked against
the session's generated values before it was added.
