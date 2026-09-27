// A8-03: reduces SQL Server's deadlock graphs (deadlock-NN.xml, as tools/deadlocks.mjs wrote them from the
// system_health session) to what identifies each deadlock: when, which process SQL Server chose as the
// victim, each process's isolation level, lock mode, wait resource, wait time, log used and statement
// (parameterized text only: a graph's input buffer carries no parameter value), and each locked resource.
//
//   node summarize-deadlocks.mjs <directory of deadlock-NN.xml> > summary.json
import fs from "node:fs";
import path from "node:path";

const dir = process.argv[2];
const unescape = (s) => s.replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, "\"").replace(/&apos;/g, "'").replace(/&#x0A;|&#x0D;|&#x09;/g, " ").replace(/&amp;/g, "&");
const attr = (text, name) => new RegExp(`\\b${name}="([^"]*)"`).exec(text)?.[1] ?? null;
const out = [];
for (const file of fs.readdirSync(dir).filter((f) => /^deadlock-\d+\.xml$/.test(f)).sort()) {
  const g = fs.readFileSync(path.join(dir, file), "utf8");
  const victim = attr(/<victimProcess [^>]*>/.exec(g)?.[0] || "", "id");
  const processes = [...g.matchAll(/<process (id="[^"]+"[^>]*)>([\s\S]*?)<\/process>/g)].map((m) => {
    const a = m[1];
    const input = unescape(/<inputbuf>([\s\S]*?)<\/inputbuf>/.exec(m[2])?.[1] || "").replace(/\s+/g, " ").trim();
    // The statement proper follows the parameter declarations "(@P0 nvarchar(4000),...)".
    const statement = input.replace(/^\((?:@P\d+ [A-Za-z0-9_]+(?:\((?:\d+(?:,\s*\d+)?|max)\))?,?)+\)?/, "").trim();
    return {
      id: attr(a, "id"), role: attr(a, "id") === victim ? "victim" : "survivor", spid: Number(attr(a, "spid")), ecid: Number(attr(a, "ecid")),
      isolation: attr(a, "isolationlevel"), lockMode: attr(a, "lockMode"), waitResource: (attr(a, "waitresource") || "").trim(),
      waitMs: Number(attr(a, "waittime")), logUsed: Number(attr(a, "logused")), trancount: Number(attr(a, "trancount")),
      statement: statement.slice(0, 240),
    };
  });
  const resources = [...g.matchAll(/<(keylock|pagelock|ridlock|objectlock|exchangeEvent)\b([^>]*)>([\s\S]*?)<\/\1>/g)].map((m) => ({
    kind: m[1], object: attr(m[2], "objectname"), index: attr(m[2], "indexname"), page: attr(m[2], "pageid"), mode: attr(m[2], "mode"),
    owners: [...m[3].matchAll(/<owner id="([^"]+)" mode="([^"]+)"/g)].map((o) => `${o[1] === victim ? "victim" : "survivor"} ${o[2]}`),
    waiters: [...m[3].matchAll(/<waiter id="([^"]+)" mode="([^"]+)"/g)].map((w) => `${w[1] === victim ? "victim" : "survivor"} ${w[2]}`),
  }));
  out.push({ file, processes, resources });
}
console.log(JSON.stringify({ graphs: out.length, deadlocks: out }, null, 2));
