# Instrument revision 2026-10-14, step 1: evidence

Branch `claude/icfwalk-phase-8-correction-cgsc7q`, starting from the Phase 8 freeze records commit
`452bd2690f6b29f24cbd0555147f4a2d75e614ba`, the point the freeze names for any later work. The revision's
**code commit is `36f9db09f595294bdc5f8e151706dbb8dc7b758b`** (tree
`c4fd7fe6d5d1328c6778db9c7cc4477ec2380bd3`, only parent `452bd26`). The commit that adds this directory
changes records only. What the revision is, and why, is `docs/INSTRUMENT_REVISION_2026-10-14.md`.

**Not audited, not frozen, not in service.** The 2026-10-14 version is a DRAFT document until an
administrator imports and publishes it. Phase 8's frozen code (`b73f519`) and records (`bbb4d15`,
`452bd26`) are unchanged; this change adds to them.

| Directory or file | What it holds |
| --- | --- |
| `gate/` | The exact-commit gate of `36f9db0`: `gate.sh`, its transcript, each engine's TAP and passing names, and the A8 gate's names they are compared with |
| `red/` | Red before green for the two code corrections, each with the production file reverted to `452bd26` and the test unchanged |
| `font-cors/` | A frozen Phase 8 browser test file failing on the same font CORS refusal when Google Fonts is reachable, and passing when it is not |
| `environment.md` | Host, engines, images, jars, harness, and the Google Fonts condition the suites ran under |
| `SHA256SUMS` | Every file here but itself |

## Results

| Run | Result |
| --- | --- |
| The gate of `36f9db0` (`gate/`) | **GATE PASSED.** Node/HTTP/Playwright 316/316 and CFML 548/548 on Lucee 6.2.8.20, and 316/316 and 548/548 on Adobe ColdFusion 2023 Update 25 (`ColdFusion Server 2023,0,25,330977`), with 0 failed, skipped, todo or cancelled, each on a brand-new SQL Server database. `test:package` 31/31, `validate:handoff` 51 checks, and the revision document current (`npm run revision:check`). All 299 Node tests the A8 gate passed pass on both engines, both engines passed the same names, and the 17 new names are REV-01 to REV-11 and REV-E1 to REV-E6. The CFML suites ran the frozen code's 542 test functions, every one still present, plus the 6 of `InstrumentRevisionTest` |
| Red before green (`red/`) | **RED BEFORE GREEN CONFIRMED.** With `app/assets/js/app.js` at `452bd26`, REV-E5 fails waiting for the My walks button "Open 7 · Visual Arts" (the walk lists as "7" alone). With `app/assets/js/renderer.js` at `452bd26`, REV-E5 fails because the scored definitions read "1: ..." where "1 · Not evident: ..." is due. In both runs REV-E1 to REV-E4 and REV-E6 pass. With nothing reverted, 6/6 pass, and the tree is clean afterwards |
| The font CORS failure on the frozen code (`font-cors/`) | **REPRODUCED.** `tests/node/browser-email.test.mjs` from a worktree of `452bd26`, served by its own Lucee: 11/13 with Google Fonts reachable, both failures on the font CORS refusal alone (66 page errors, every one "Request header field x-icfwalk-dev-subject is not allowed by Access-Control-Allow-Headers in preflight response", and no other); 13/13 with it out of reach |

## How each was run

- `gate/gate.sh 36f9db09f595294bdc5f8e151706dbb8dc7b758b <directory outside the repository>`, its
  output in `gate/gate-transcript.txt` (the last line, `gate exit=0`, is the wrapper's record of the
  script's exit status). The TAP of each engine's `npm test` and the names it passed are `gate/lucee/`
  and `gate/acf/`; `gate/baseline-names.txt` is the A8 gate's list they are compared with. Screenshots
  (92 per engine) were written outside the repository and are not kept.
- `red/red.sh 36f9db09f595294bdc5f8e151706dbb8dc7b758b <directory outside the repository>`, after the
  gate, with Lucee on the gate's development database and Google Fonts out of the browser's reach;
  transcript `red/red-transcript.txt`, TAP `red/red-list-titles.tap`, `red/red-level-names.tap` and
  `red/green.tap`.
- `font-cors/reproduce.sh <worktree of 452bd26> <output directory>`, before the gate, against the
  development database of that time; transcript `font-cors/reproduce-transcript.txt` (it does not
  print the script, which is kept beside it as run), TAP `font-cors/1-fonts-reachable.tap` and
  `font-cors/2-fonts-out-of-reach.tap`.

`gate/gate.sh` and `red/red.sh` are byte for byte the copies their transcripts print.

`gate.sh` says the branch is pushed only after the gate passes. It was not: the code commit was pushed at
2026-10-14T20:36:53Z, while the gate ran (it had started at 20:32:17Z), so that the commit would survive
the session's container. A push moves neither HEAD nor the working tree, which the gate checks at its
end. The gate's step 1 records the remote branch at `452bd26`, and its step 14 at `36f9db0`. The script
is kept exactly as it ran.

No transcript or TAP file here holds a password, token or proxy credential: each was checked against
the session's generated values before it was added.
