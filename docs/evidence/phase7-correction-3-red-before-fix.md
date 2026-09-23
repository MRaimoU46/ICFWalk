# Phase 7 correction, third round: red before fix (P7C-04)

Evidence for the re-audit of `9ef9b97b5b4ee20dd51d6ca023c0841b7ca872ba`, finding P7C-04 (a release could
be changed by deleting some of its rows). Every output below was captured from the run it
describes, on Lucee 6.2.8.20 and SQL Server 2022, and is quoted, not paraphrased; long lines are cut
where marked.

## 1. The new CFML case on the re-audited schema

Run before any source or schema change: the working tree was `9ef9b97` plus the new case
`ReportReleaseTest.testNoPartOfAReleaseCanBeDeleted`, against the development database with the
re-audited migration 007. Each deletion ran in a transaction that was always rolled back, so the
fixture release was not damaged for the cases after it (the other 15 cases passed).

```
testNoPartOfAReleaseCanBeDeleted
every deletion is refused by the database; not refused: one cell -> DELETED
  | one block -> The DELETE statement conflicted with the REFERENCE constraint "FK_report_release_cell_block". The conflict occurred in database "icfwalk_dev", table "icf.report
  | one recorded walk -> The walks a stored report release block counts cannot change.
  | the release row -> The DELETE statement conflicted with the REFERENCE constraint "FK_report_release_block_release". The conflict occurred in database "icfwalk_dev", table "icf.rep
  | a block with its cells and walks, in the order the keys allow -> DELETED
  | the whole release, in the order the keys allow -> DELETED Expected [0] but got [6].
```

One cell is deleted outright. A block, and the release row, are stopped only by foreign keys and one
recorded walk only by the membership guard -- none by any rule against deletion. A block with its
cells and walks, and the whole release, go through when deleted in the order the keys allow.

## 2. The new database test on the re-audited migration

`tests/node/db-scripts.test.mjs` from this round, run in a worktree of `9ef9b97` (so against that
commit's own `007_report_release.sql`, applied to an empty scratch database):

```
    Expected values to be strictly equal:
    
    8 !== 12
```

It stops at the guard count (the re-audited migration creates 8 guards, this round's 12). With that
one count set to 8 in the worktree copy, so the run reaches the deletion cases:

```
    one cell is never deleted
    
    true !== false
```

"one cell is never deleted" fails because the deletion succeeded.

## 3. After the fix

With the four `INSTEAD OF DELETE` guards (50068), both tests pass: every deletion is refused, the
release reads identically, a principal with data permissions only cannot delete a release row or
disable, drop or truncate past the guard, and the privileged removal still has to go in key order.
The totals are the exact-commit gate's; its evidence is in `docs/evidence/gate/`, added by the commit
after the gated one.
