/**
 * The no-automatic-send gate (Phase 5 completion gate; docs/OPEN_DECISIONS.md).
 *
 * ICFWalk never sends mail. The Part 4 composer produces text a person reviews, edits, copies, or
 * hands to their own mail client through a mailto: URL. There is no SMTP configuration, no cfmail,
 * no mail library, and no endpoint that accepts a recipient -- and there must never be one added by
 * accident, which is what these checks are for.
 *
 * Two halves: a static scan of the shipped source, and a live check that no such route answers.
 *
 * The static half needs nothing but the working tree and always runs. The live half needs the
 * application, and it is never reported as a pass without it: with no application expected it is
 * an explicit skip naming the reason, and under ICFWALK_REQUIRE_APP (the full integration and
 * release-verification profiles) an unreachable application fails the run. Reporting "the live
 * probe found no mail route" when no probe was made would be evidence of nothing.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { baseUrl, loadRuntimeEnv, requireApp, root } from "./helpers.mjs";

const env = loadRuntimeEnv();

/** Reachable means the health route answered 200, which is what the live probes below need. */
async function appReachable() {
  try {
    const r = await fetch(`${baseUrl(env)}/index.cfm/api/health`, { signal: AbortSignal.timeout(10000) });
    return r.status === 200;
  } catch {
    return false;
  }
}
const appUp = await appReachable();
const appExpected = requireApp(env);
// Skipped only when no application was expected. When one was, the test runs and fails.
const liveSkip = appUp || appExpected
  ? false
  : `application not reachable at ${baseUrl(env)} and ICFWALK_REQUIRE_APP is not set, so no live no-mail route probe was performed`;

/** Every shipped source file: the application, the browser bundle, the tooling, and the config. */
function sourceFiles() {
  const roots = ["src", "app/assets/js", "app/assets/css", "scripts", "config", "database"];
  const out = [];
  const skipDirs = new Set(["node_modules", "WEB-INF", ".runtime"]);
  const walk = (dir) => {
    let entries;
    try {
      entries = fs.readdirSync(path.join(root, dir), { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      const rel = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        if (!skipDirs.has(entry.name)) walk(rel);
        continue;
      }
      if (/\.(cfc|cfm|js|mjs|json|css|html|sql)$/i.test(entry.name)) out.push(rel);
    }
  };
  for (const dir of roots) walk(dir);
  out.push("app/index.cfm", "app/Application.cfc", "src/views/shell.html");
  return [...new Set(out)].filter((p) => fs.existsSync(path.join(root, p)));
}

const files = sourceFiles();
const read = (rel) => fs.readFileSync(path.join(root, rel), "utf8");

test("no mail-delivery construct exists anywhere in the shipped source", () => {
  assert.ok(files.length > 40, `the scan found only ${files.length} files; it is not looking at the source`);
  // Each pattern is a way an application actually sends mail. "email" on its own is not one of them:
  // the instrument has an email-draft item and the SSO gateway asserts an email header.
  const forbidden = [
    /<\s*cfmail\b/i,
    /\bcfmail\s*\(/i,
    /<\s*cfmailpart\b/i,
    /<\s*cfmailparam\b/i,
    /\bsmtp\b/i,
    /javax\.mail/i,
    /jakarta\.mail/i,
    /\bnodemailer\b/i,
    /\bsendgrid\b/i,
    /\bmailgun\b/i,
    /\bpostmark\b/i,
    /\bses\.sendEmail\b/i,
    /\bsendMail\s*\(/i,
    /\bsendEmail\s*\(/i,
    /\bmailSend\s*\(/i,
  ];
  const hits = [];
  for (const rel of files) {
    if (rel === "tests/node/no-mail.test.mjs") continue;
    const text = read(rel);
    for (const pattern of forbidden) {
      const m = text.match(pattern);
      if (m) hits.push(`${rel}: ${JSON.stringify(m[0])}`);
    }
  }
  assert.deepEqual(hits, [], `mail-delivery constructs found:\n${hits.join("\n")}`);
});

test("the browser never posts a draft anywhere: the only outbound action is a mailto: URL", () => {
  const composer = read("app/assets/js/email-composer.js");
  // The recipient, subject, and body reach exactly one place, and it is a URL the browser hands to
  // the operating system. Every value in it is percent-encoded, so a CR/LF or "bcc:" in the
  // recipient is data in a URL and can never become a mail header.
  assert.match(composer, /window\.location\.href = mailtoUrl\(/);
  assert.match(composer, /return `mailto:\$\{to\}\?subject=\$\{subject\}&body=\$\{body\}`/);
  for (const field of ["to", "subject", "body"]) {
    assert.match(composer, new RegExp(`const ${field} = encodeURIComponent\\(doc\\.${field} \\|\\| ""\\)`), `${field} is percent-encoded`);
  }
  // No request of any kind leaves the composer.
  for (const pattern of [/\bfetch\s*\(/, /XMLHttpRequest/, /navigator\.sendBeacon/, /\bnew WebSocket\b/, /\bEventSource\b/]) {
    assert.doesNotMatch(composer, pattern, `the composer must issue no request (${pattern})`);
  }
  // It reaches the server only through the walk save path, which is the renderer's commit callback.
  assert.doesNotMatch(composer, /\/api\//, "the composer names no endpoint at all");
});

test("mailtoUrl percent-encodes every value, so a recipient can never become a mail header", async () => {
  const { mailtoUrl, clipboardText } = await import("../../app/assets/js/email-composer.js");

  // The header-injection shape, reaching the composer from a stored document rather than from the
  // single-line input (which strips line breaks before it ever gets there).
  const hostile = { to: "a@b.test\r\nbcc: victim@example.test", subject: "S\r\nX-Spoof: 1", body: "B\r\n.\r\nQUIT" };
  const url = mailtoUrl(hostile);
  assert.ok(url.startsWith("mailto:"), url);
  assert.ok(!url.includes("\r") && !url.includes("\n"), "no raw CR or LF survives");
  assert.ok(url.includes("%0D%0A"), "the CR/LF is percent-encoded as data");
  assert.ok(url.includes("bcc%3A"), "a bcc: attempt is encoded, not a parameter");
  assert.ok(!/[?&]bcc=/i.test(url), "it can never become a mailto bcc parameter");
  assert.ok(!/[?&]cc=/i.test(url), "nor a cc parameter");
  // Exactly the two parameters the composer builds, in the documented order.
  assert.equal(url.split("?")[1].split("&").length, 2);
  assert.match(url, /^mailto:[^?&]*\?subject=[^&]*&body=[^&]*$/);
  assert.equal(url, `mailto:${encodeURIComponent(hostile.to)}?subject=${encodeURIComponent(hostile.subject)}&body=${encodeURIComponent(hostile.body)}`);

  // An empty draft is still a well-formed, harmless URL.
  assert.equal(mailtoUrl({ to: "", subject: "", body: "" }), "mailto:?subject=&body=");
  assert.equal(mailtoUrl({}), "mailto:?subject=&body=");

  // Copying is plain text: it neither sends nor encodes anything.
  assert.equal(clipboardText({ subject: "S", body: "B" }), "Subject: S\n\nB");
  assert.equal(clipboardText({}), "Subject: \n\n");
});

test("no route, controller action, or configuration key accepts a recipient", () => {
  const router = read("src/http/Router.cfc");
  assert.doesNotMatch(router, /\/(email|mail|send|notify)\b/i, "no mail-shaped route is declared");
  // The walk routes are exactly the Phase 4 set plus the Phase 5 read-only summary export.
  const walkRoutes = [...router.matchAll(/add\("(GET|POST|PUT|DELETE)", "\^\\?\/api\\?\/walks([^"]*)"/g)].map((m) => `${m[1]} ${m[2]}`);
  assert.deepEqual(walkRoutes.sort(), [
    "DELETE /([^/]+)$",
    "GET $",
    "GET /([^/]+)$",
    "GET /([^/]+)/instrument$",
    "GET /([^/]+)/summary$",
    "POST $",
    "POST /([^/]+)/complete$",
    "POST /([^/]+)/void$",
    "PUT /([^/]+)$",
  ]);

  const controller = read("src/controllers/WalkController.cfc");
  const actions = [...controller.matchAll(/public struct function (\w+)\(/g)].map((m) => m[1]).sort();
  assert.deepEqual(actions, ["complete", "create", "instrument", "list", "open", "remove", "save", "summary", "void"]);

  // Configuration offers no mail server to point at.
  for (const rel of [".env.example", "src/config/ConfigLoader.cfc"]) {
    const text = fs.readFileSync(path.join(root, rel), "utf8");
    assert.doesNotMatch(text, /smtp|mail_?(host|port|server|from|user)/i, `${rel} configures no mail transport`);
  }
});

test("the summary export is the only new endpoint and it is read-only", { skip: liveSkip }, async () => {
  // Reached only when the application was expected or was found running. If it was expected and is
  // not there, this is a failure: the probes below are the only thing that can establish that no
  // mail-shaped route answers at runtime, and they did not happen.
  assert.ok(
    appUp,
    `ICFWALK_REQUIRE_APP is set, so the live no-mail route probe must run, but the application is not reachable at ${baseUrl(env)}. ` +
    `Start it (tools/runtime/lucee-up.sh) or clear ICFWALK_REQUIRE_APP for an optional local run.`,
  );
  // Unauthenticated probes: a route that does not exist answers 404 before any authorization runs,
  // so a 404 here proves the endpoint is absent rather than merely refused.
  for (const [method, p] of [
    ["POST", "/api/walks/00000000-0000-4000-8000-000000000000/email"],
    ["POST", "/api/walks/00000000-0000-4000-8000-000000000000/send"],
    ["POST", "/api/walks/00000000-0000-4000-8000-000000000000/notify"],
    ["POST", "/api/mail"],
    ["POST", "/api/email"],
    ["POST", "/api/walks/00000000-0000-4000-8000-000000000000/summary"],
  ]) {
    const res = await fetch(`${baseUrl(env)}/index.cfm${p}`, { method });
    assert.ok(res.status === 404 || res.status === 405, `${method} ${p} must not exist (got ${res.status})`);
  }
});
