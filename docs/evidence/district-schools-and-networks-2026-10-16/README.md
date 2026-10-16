# The district's schools and networks (the owner's answers of 2026-10-16), evidence

Branch `claude/icfwalk-phase-8-correction-cgsc7q`. The **last code commit is
`f07d5423cdab6b42a690b77ab01a9f84252e1e80`** (tree `f98cacacef7ee56229dd38b56857ec7a6d6cd3d0`). The change is two commits in a line on the
report filters' records commit `6feacd4`: `a13af10` (the 2026-10-14 School list as the owner amended it)
and `f07d542` (the district's org-unit file). The commit that adds this directory changes records only.

**What the owner sent.** Their seven networks and the 53 schools in them (`networks/owner-list.tsv`,
verbatim). Asked about what did not match the system, they answered, verbatim: "1. correct on the
matching", "2. those names are correct. Legacy Middle School. Hawk Hollow Middle School, Laurel Hill
Elementary, Spring Trail Elementary, Sycamore Trails Elementary." and "3. Those schools are all closed."
(`docs/OPEN_DECISIONS.md`).

**What changed.**

- The 2026-10-14 version's School list (still a DRAFT) is the prototype's as the owner amended it: the four
  closed schools (Ellis Middle, Hanover Countryside Elementary, Lowrie Elementary, Washington Elementary)
  leave, and the seven schools the prototype does not list (Hawk Hollow Middle School, Illinois Park,
  Independence, Laurel Hill Elementary, Legacy Middle School, Spring Trail Elementary, Sycamore Trails
  Elementary) join, coded from their labels, each in its network's grade band. The 2026-09-17 version is
  untouched. Definitions checksum `d324ec76b61b236620e28de03d03803890ae2817974707d95bdc46f837d2146c`.
- `config/org-units.networks.json`, imported after `config/org-units.example.json`, gives the district its
  seven networks, each open school under its network, the seven new schools and the four closed schools
  (inactive). It was generated from the owner's list by `networks/build.mjs`, which prints every match.

| Directory or file | What it holds |
| --- | --- |
| `gate/` | The exact-commit gate of `f07d542`: `gate.sh`, its transcript, each engine's TAP and passing names, and the report filters' gate names they are compared with |
| `networks/` | The owner's list (`owner-list.tsv`), the generator (`build.mjs`) and its output, and the file's import checked on each engine (`verify-import.mjs` and its output) |
| `SHA256SUMS` | Every file here but itself |

## Result

**GATE PASSED** for `f07d542` (tree `f98cacacef7ee56229dd38b56857ec7a6d6cd3d0`), from a clean tree, each
engine on a brand-new database migrated 001 to 008 (002 to 008 re-applied, 001 refused a second time):

| Engine | Node, HTTP, Playwright | CFML |
| --- | --- | --- |
| Lucee 6.2.8.20 | 327/327 | 559/559 |
| Adobe ColdFusion 2023 Update 25 (`ColdFusion Server 2023,0,25,330977`) | 327/327 | 559/559 |

Every one of the 326 Node test names the report filters' gate passed on both engines passes on both
engines here. The one name it did not have is REV-12, and both engines passed the same names. The 559
CFML test functions at `6feacd4` all exist and ran, and this change adds none. Among them is
`InstrumentRevisionTest`, which compiles the amended document on each engine to the golden bytes.
`validate:handoff` (51 checks), `revision:check` and `test:package` (33/33) passed.

**The org-unit file (`networks/`), 7 of 7 on each engine.** `build.mjs` reproduces
`config/org-units.networks.json` and the demo's tree byte for byte from the owner's list
(`build-output.txt` prints every match). Imported by file name after the example (14 units created, 50
updated), it gives the district the seven networks, and every one of the 53 listed schools sits under
the network the owner listed it in. The four closed schools are inactive and in no scope, and the open
schools are exactly the 2026-10-14 version's School values, code for code. Every existing school keeps
its name, and a second import creates nothing and moves nothing.

**The amended document on the server.** Imported into Lucee after the gate, the 2026-10-14 DRAFT has the
golden snapshot checksum `2f2d62fe2473d04808c2091f76bc56ca74a0824a9886a05b21952e5f1652b686`; its render
model is the demo's, and the draft was then discarded.

## How it was run

`gate/gate.sh f07d5423cdab6b42a690b77ab01a9f84252e1e80 <directory outside the repository>`, its output in
`gate/gate-transcript.txt` (the last line, `gate exit=0`, is the wrapper's record of the script's exit
status). It is the report filters' gate (`../report-filters-2026-10-16/gate/gate.sh`) with its base moved
to their records commit, its identity check to this change's two commits, its diff check to this
change's ten files, and its baselines to that gate's results plus exactly one new Node test (REV-12) and
no new CFML test function. `gate/gate.sh` is byte for byte the copy its transcript prints. Screenshots
were written outside the repository and are not kept.

`networks/verify-import.mjs` ran after the gate against ColdFusion (port 8500, database
`icfwalk_acf_gate`), then against Lucee (port 8888, database `icfwalk_dev`, started on the same code). It
imports `org-units.example.json` and then `org-units.networks.json` by file name, as `docs/LOCAL_SETUP.md`
step 8 does, and reads the tree back as a district-level report user. The units it imports are the
deployment's own codes and stay in those scratch databases.

Before the gate, `test:package` (33/33), `validate:handoff` (51 checks), `revision:check`, `workbook`,
`browser-revision` and `browser-multiple` passed on Lucee, the last two importing the amended document
into the server with its new golden definitions checksum.

No transcript, TAP or output here holds a password, token or proxy credential: each was checked against
the session's generated values before it was added.
