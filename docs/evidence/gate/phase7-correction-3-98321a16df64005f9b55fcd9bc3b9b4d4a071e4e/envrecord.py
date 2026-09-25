#!/usr/bin/env python3
"""Writes the Phase 7 correction's final environment record after the exact-commit gate.
Every value is read from the gate transcript, the suite's TAP output, git, docker or the
runtime configuration; secrets are redacted.
usage: envrecord.py <commit> <transcript> <tap> <source-zip> <out.md> [other delivered file...]"""
import hashlib, json, pathlib, re, subprocess, sys, tempfile

commit, transcript, tap, archive, out = sys.argv[1:6]
others = sys.argv[6:]
REPO = "/home/user/ICFWalk"
BRANCH = "claude/icfwalk-phase-7-correction-n62s25"
BASELINE = "a219d9e0987b85b1a0b587fd62effa4e0ad1ffde"
FIRST_CANDIDATE = "0c6fa10972593043508f502538534c2aa95c671b"
SCRATCH = pathlib.Path("/tmp/claude-0/-home-user-ICFWalk/49fb0df4-a8fa-5d20-9a14-861bafa45a22/scratchpad")


def sh(cmd, cwd=REPO):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True, cwd=cwd).stdout.strip()


def sha(p):
    b = pathlib.Path(p).read_bytes()
    return hashlib.sha256(b).hexdigest(), len(b)


def last(pattern, text):
    m = re.findall(pattern, text, re.M)
    return m[-1] if m else "(not found)"


def first(pattern, text):
    m = re.findall(pattern, text, re.M)
    return m[0] if m else "(not found)"


def section(text, number):
    """Transcript section <number>: from its '== <time>  <number>. ' header to the next header
    (section 0 prints the gate script, whose own text names every section, so match headers only)."""
    a = re.search(rf"^== \S+  {number}\. ", text, re.M)
    if not a:
        return ""
    b = re.search(r"^== \S+  \d+\. ", text[a.end():], re.M)
    return text[a.start(): a.end() + b.start()] if b else text[a.start():]


t = pathlib.Path(transcript).read_text()
tapt = pathlib.Path(tap).read_text()
totals = {k: last(rf"^# {k} (\d+)", tapt) for k in ["tests", "suites", "pass", "fail", "cancelled", "skipped", "todo"]}
cfml = last(r"^# (engine=Lucee.*)$", tapt)
node_files = [f for f in sh(f"git ls-tree -r --name-only {commit} tests/node").splitlines() if f.endswith(".test.mjs")]
tst, tbytes = sha(transcript)
zst, zbytes = sha(archive)
tree = sh(f"git rev-parse {commit}^{{tree}}")
parent = sh(f"git rev-parse {commit}^")
remote = (sh(f"git ls-remote origin refs/heads/{BRANCH}").split() or ["(none)"])[0]
anc = lambda a: "yes" if subprocess.run(f"git merge-base --is-ancestor {a} {commit}", shell=True, cwd=REPO).returncode == 0 else "NO"
audited_ok = anc("0c74dbd5a8a79684d38ba0b169dce2682a54fad6")
round2_ok = anc("b67df76a9fe46eefe38d47f7919a89d19c1b5d79")
first_ok = "yes" if subprocess.run(f"git merge-base --is-ancestor {FIRST_CANDIDATE} {commit}", shell=True, cwd=REPO).returncode == 0 else "NO"
baseline_ok = "yes" if subprocess.run(f"git merge-base --is-ancestor {BASELINE} {commit}", shell=True, cwd=REPO).returncode == 0 else "NO"
tree_state = "clean" if not sh("git status --porcelain=v1 --untracked-files=all") else "NOT CLEAN"
started = first(r"^== (\S+)  1\. ", t)
ended = first(r"^== (\S+)  11\. ", t)
verdict = "GATE PASSED" if ("GATE PASSED for " + commit) in t else "NOT PASSED"
origin_url = sh("git remote get-url origin")

tmp = tempfile.mkdtemp(dir=SCRATCH)
zip_tree = sh(f"unzip -q {archive} -d {tmp} && cd {tmp}/ICFWalk && git init -q && git add -A && git write-tree", cwd=tmp)
zip_verdict = "the commit's own tree" if zip_tree == tree else "NOT the commit's tree"

sql_version = " ".join(first(r"(Microsoft SQL Server 20[^\n]*\n[^\n]*)", t).split())
engine = last(r'"engine":"([^"]+)"', t)
npm_ci = section(t, 3)
npm_ci_state = "tree unchanged afterwards" if "status after npm ci: <empty>" in npm_ci else "SEE TRANSCRIPT"
handoff = section(t, 4)
handoff_json = re.search(r'"ok": (true|false),\s*"checks": (\d+),\s*"errors": (\d+)', handoff)
handoff_result = (f"ok {handoff_json.group(1)}, {handoff_json.group(2)} checks, {handoff_json.group(3)} errors"
                  if handoff_json else "SEE TRANSCRIPT")
package = "; ".join(re.findall(r"^# ((?:tests|pass|fail|cancelled|skipped|todo) \d+)", handoff, re.M))
syntax = first(r"^(checked \d+ files, \d+ syntax errors)", t)
schema = section(t, 7)
refused_001 = "refused, as designed" if "001 refused a second application, as designed" in schema else "SEE TRANSCRIPT"
triggers = re.findall(r"^(TR_\w+)\s*$", schema, re.M)
tables = first(r"^\s*(\d+)\s*$", schema)

env_lines = []
for line in pathlib.Path(REPO, ".env").read_text().splitlines():
    if not line.strip() or line.lstrip().startswith("#"):
        continue
    key, _, value = line.partition("=")
    if re.search(r"PASSWORD|TOKEN|SECRET|KEY", key):
        value = f"<{len(value)} characters, not recorded>" if value else "<empty>"
    env_lines.append(f"{key}={value}")

versions = {
    "OS": sh(". /etc/os-release; echo $PRETTY_NAME") + " (kernel " + sh("uname -r") + ", " + sh("uname -m") + ")",
    "Node": sh("node --version"),
    "npm": sh("npm --version"),
    "Java": sh("java -version 2>&1 | grep -v '^Picked up' | head -2 | tr '\\n' ' '"),
    "CFML engine (health check in the transcript)": engine,
    "Jetty runner": "9.4.58.v20250814 (tools/runtime/lucee-up.sh default)",
    "JDBC driver": "Microsoft JDBC 12.10.2.jre11 (tools/runtime/lucee-up.sh default)",
    "SQL Server (SELECT @@VERSION in the transcript)": sql_version,
    "SQL Server image": sh("docker image inspect --format '{{index .RepoDigests 0}}' mcr.microsoft.com/mssql/server:2022-latest"),
    "SQL Server container": sh("docker ps --filter name=icfwalk-mssql --format '{{.ID}} created {{.CreatedAt}}'"),
    "Docker": sh("docker version --format 'client {{.Client.Version}}, server {{.Server.Version}}'"),
    "Playwright": sh("node -p \"require('./node_modules/playwright/package.json').version\""),
    "Chromium": sh("ls /opt/pw-browsers | tr '\\n' ' '"),
    "axe-core": sh("node -p \"require('./node_modules/axe-core/package.json').version\""),
    "mssql (Node driver)": sh("node -p \"require('./node_modules/mssql/package.json').version\""),
}
version_rows = "\n".join(f"| {k} | {v} |" for k, v in versions.items())
env_block = "\n".join(env_lines)
trigger_list = ", ".join(f"`{x}`" for x in triggers) or "(see transcript)"
transcript_name = pathlib.Path(transcript).name
archive_name = pathlib.Path(archive).name
node_count = len(node_files)
t_tests, t_pass, t_fail = totals["tests"], totals["pass"], totals["fail"]
t_canc, t_skip, t_todo = totals["cancelled"], totals["skipped"], totals["todo"]

other_rows = "\n".join(f"| `{pathlib.Path(o).name}` | `{sha(o)[0]}` | {sha(o)[1]} |" for o in others)
doc = f"""# Phase 7 correction, third round: final environment record

Record of the environment that ran the exact-commit gate for the third round of the Phase 7
correction (re-audit findings P7C-03 and P7C-04). Every value
below was read from the gate transcript, the suite's output, git, docker or the runtime
configuration when this record was written. The raw gate transcript is `{transcript_name}`
(SHA-256 `{tst}`, {tbytes} bytes). A source archive of the same commit is `{archive_name}`
(SHA-256 `{zst}`, {zbytes} bytes). None of these files is part of the gated commit. The commit after
it adds this record, the transcript and the rest of the gate's evidence under `docs/evidence/gate/`
and changes nothing else (BUILD_STATUS.md, "Phase 7 correction, third round").

## Identity

| Item | Value |
| --- | --- |
| Repository | `origin` = {origin_url} |
| Branch | `{BRANCH}` |
| Commit under test (HEAD) | `{commit}` |
| Tree | `{tree}` |
| Parent (the re-audited commit) | `{parent}` |
| Second round's first commit | `b67df76a9fe46eefe38d47f7919a89d19c1b5d79`, ancestor of HEAD: {round2_ok} |
| First audited correction | `0c74dbd5a8a79684d38ba0b169dce2682a54fad6`, ancestor of HEAD: {audited_ok} |
| First audited Phase 7 candidate | `{FIRST_CANDIDATE}`, ancestor of HEAD: {first_ok} |
| Frozen Phase 6 baseline | `{BASELINE}`, ancestor of HEAD: {baseline_ok} |
| Remote branch `refs/heads/{BRANCH}` when this record was written | `{remote}` |
| Working tree before the gate | transcript section 1 (`git status --porcelain=v1 --untracked-files=all`, the gate stops unless it is empty) |
| Working tree after the gate | {tree_state} (transcript section 11, and again when this record was written) |
| Gate started / ended (UTC) | {started} / {ended} |
| Gate verdict | {verdict} |

The source archive is `git archive --format=zip --prefix=ICFWalk/ {commit}`. Checked when this record
was written: unzipping it into an empty directory, then `git init`, `git add -A` and `git write-tree`,
gives tree `{zip_tree}`, {zip_verdict}.

## Versions as executed

| Component | Version |
| --- | --- |
{version_rows}

Adobe ColdFusion 2023 and SQL Server 2016, the production targets, were **not** executed: neither is
installable here. All CFML ran on Lucee (the repository's documented verification runtime) and all
SQL on SQL Server 2022.

## Runtime configuration (`.env`, secrets redacted)

```
{env_block}
```

For the suite run: `ICFWALK_REQUIRE_APP=1` and `ICFWALK_SCREENSHOT_DIR` set to a directory outside
the repository.

## Database: creation and schema

Transcript sections 6 and 7. The previous SQL Server container was removed (`docker rm -f`) and its
generated password file deleted. `tools/runtime/mssql-up.sh` started a new container from the image
above with a new generated password and created empty `icfwalk_dev` and `icfwalk_test` databases.
`node scripts/db/apply-schema.mjs` then applied `001_schema.sql` through `007_report_release.sql` in
order. `002` through `007` were each applied a second time (idempotence). A second application of
`001` was {refused_001}. The resulting schema: {tables} `icf` tables, triggers {trigger_list}. The
application was started on that database (section 8) and the instrument seeded as a DRAFT.

## Commands and results

| Step | Command | Result |
| --- | --- | --- |
| Dependencies | `npm ci` | from the checked-in lockfile, {npm_ci_state} |
| Handoff validation | `node scripts/validate-handoff.mjs` | {handoff_result} |
| Package tests | `npm run test:package` | {package} |
| JavaScript syntax | `node --check` on every tracked `.js` / `.mjs` | {syntax} |
| Full suite | `ICFWALK_REQUIRE_APP=1 ICFWALK_SCREENSHOT_DIR=<outside> npm test` | Node/HTTP/Playwright test cases: tests {t_tests}, pass {t_pass}, fail {t_fail}, cancelled {t_canc}, skipped {t_skip}, todo {t_todo} |
| CFML suite (driven by `tests/node/cfml-suite.test.mjs`, one of the Node cases above) | `/api/maintenance/tests/run` in six parts | `{cfml}` |

The Node figure counts test cases across {node_count} files, one of which is the CFML suite
driver. The CFML figure is the spec cases that driver ran, reported by the driver itself. Zero skips
are enforced three ways: the gate requires `# skipped 0`, the CFML driver asserts its own
`skipped === 0` and that every `*Test.cfc` on disk ran, and `ICFWALK_REQUIRE_APP=1` turns an absent
application into a failure rather than a skip.

## Artifacts

| File | SHA-256 | Bytes |
| --- | --- | --- |
| `{transcript_name}` | `{tst}` | {tbytes} |
| `{archive_name}` | `{zst}` | {zbytes} |
{other_rows}

This record's own hash is reported with the handoff (a file cannot contain its own digest).
"""
pathlib.Path(out).write_text(doc)
print(json.dumps({"totals": totals, "cfml": cfml, "verdict": verdict, "zip_tree": zip_tree, "tree": tree,
                  "transcript": [tst, tbytes], "zip": [zst, zbytes]}))
