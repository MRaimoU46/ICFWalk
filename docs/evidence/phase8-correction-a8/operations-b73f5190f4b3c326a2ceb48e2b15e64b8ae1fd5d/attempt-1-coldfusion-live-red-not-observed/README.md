# Operations on b73f519, attempt 1: OPERATIONS FAILED (kept)

The first run of `ops.sh` on the correction code commit, 11:18:43 to 11:45:31 UTC, right after the gate.
Every scenario passed except one: **the ColdFusion live red on the audited tip's code was not
observed** (`ops-transcript.txt`: `LIVE RED NOT OBSERVED`), so the script ended `OPERATIONS FAILED`.
Nothing was packaged or pushed on it.

| Scenario | Result |
| --- | --- |
| restart-coldfusion, production-profile-coldfusion, readiness-coldfusion | passed (exit 0) |
| readiness-coldfusion-live-red-on-10f476ba | **not observed**: the operation failed, but because ColdFusion never answered, not because health answered 200 |
| restart-lucee, production-profile-lucee, readiness-lucee | passed (exit 0) |
| readiness-lucee-live-red-on-10f476ba | the red as required: "health answered 200 before the ICFWalk schema exists" |
| upgrade-and-rollback, database-operations | passed (exit 0) |
| the normal environment afterwards | Lucee 200, ColdFusion 200, no temporary database or login left; HEAD, tree and a clean status unchanged |

**Cause: the harness, not the application.** `ops.sh` extracts the audited tip's tree with `mktemp -d`,
which makes the directory mode 0700. ColdFusion runs as `cfuser` in its container and reads the
bind-mounted tree as its document root, so it could not: Tomcat refused the site ("The main resource
set specified [/icfwalk/app] is not a directory or war file, or is not readable",
`diagnosis/cf-logs.txt`), every health request hung until curl's 10-second limit, and the audited tip's
own `tools/runtime/acf-up.sh` gave up after its 90 polls (about 18.7 minutes). Lucee runs as the host
user and was not affected. The trial of the same red before the correction commit used a tree of mode
0755 and saw the red.

**Diagnosis** (`diagnosis/`): the same red run alone, with a watcher that probed health every ten
seconds and, after three minutes without an answer, recorded the container's log, ColdFusion's logs,
the site's permissions (`site.txt`: `/icfwalk` is `drwx------ root root`), the processes and a thread
dump. It reproduced the failure; its run was stopped early so the operation's own cleanup ran.

**The fix** (`../ops.sh`, and nothing else): `chmod 755` on the extracted tree. No code, test or tool
of the repository changed.

**Targeted check** (`targeted-check-after-the-fix/`): the ColdFusion red alone with the fix: the
audited tip's code answers 200 `status: ok` with `schema: missing`, and the operation fails because
health answered 200 before the schema existed, as required.

Then the complete operations ran again from the same starting state (ColdFusion on the gate's
database, Lucee stopped): `../ops-transcript.txt`, attempt 2.
