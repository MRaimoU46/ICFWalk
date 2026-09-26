// One-off probe for the P8-01 red record: after a session replacement, does Retry recover, and what
// does a reload keep? Run against the unmodified application.
import { createRequire } from "node:module"; const { chromium } = createRequire("/home/user/ICFWalk/package.json")("playwright");
import { api, baseUrl, loadRuntimeEnv } from "/home/user/ICFWalk/tests/node/helpers.mjs";
const env = loadRuntimeEnv(); const token = env.ICFWALK_MAINTENANCE_TOKEN; const tag = `p8probe-${Date.now().toString(36)}`; const subject = `${tag}-walker`;
await api(env, "POST", "/api/maintenance/org-units/import", { token, body: { orgUnits: [{ code: `${tag}-district`, type: "DISTRICT", name: "Probe district", parentCode: null }, { code: `${tag}-school`, type: "SCHOOL", name: "Probe school", parentCode: `${tag}-district` }] } });
await api(env, "POST", "/api/maintenance/identity/provision-user", { token, body: { subject, displayName: "Probe" } });
await api(env, "POST", "/api/maintenance/identity/assign-role", { token, body: { subject, roleCode: "SCHOOL_WALK_REPORT", orgUnitCode: `${tag}-school` } });
const browser = await chromium.launch(); const ctx = await browser.newContext({ extraHTTPHeaders: { "X-ICFWalk-Dev-Subject": subject } }); const page = await ctx.newPage();
page.on("dialog", (d) => { console.log(`dialog: ${d.type()}`); d.accept(); });
await page.goto(`${baseUrl(env)}/index.cfm/`, { waitUntil: "networkidle" }); await page.waitForSelector("body[data-ready=true]");
await page.click("#new-walk-btn"); await page.waitForSelector("#view-walk:not([hidden])");
await page.click('[data-section-key="part2"] > h2 > .acc-head'); await page.click('[data-section-key="s1"] > h3 > .acc-head, [data-section-key="s1"] > h2 > .acc-head');
await page.fill('[data-item-key="comp_s1_notes"] textarea', "first note, saved");
await page.waitForFunction(() => document.getElementById("save-status").textContent === "All changes saved");
await ctx.clearCookies();
await page.fill('[data-item-key="comp_s1_notes"] textarea', "second note, typed after the session was replaced");
await page.waitForFunction(() => /^Could not save/.test(document.getElementById("save-status").textContent), null, { timeout: 20000 });
console.log(`after the edit: ${await page.textContent("#save-status")}`);
for (let i = 1; i <= 3; i++) {
  await page.click("#save-retry");
  await page.waitForTimeout(1500);
  console.log(`after Retry ${i}: ${await page.textContent("#save-status")}`);
}
await page.reload({ waitUntil: "networkidle" }); await page.waitForSelector("body[data-ready=true]");
await page.click(".walk-card .open-btn"); await page.waitForSelector("#view-walk:not([hidden])");
await page.click('[data-section-key="part2"] > h2 > .acc-head'); await page.click('[data-section-key="s1"] > h3 > .acc-head, [data-section-key="s1"] > h2 > .acc-head');
console.log(`after a reload, the note reads: ${JSON.stringify(await page.inputValue('[data-item-key="comp_s1_notes"] textarea'))}`);
await browser.close();
const r = await api(env, "POST", "/api/maintenance/identity/cleanup-fixtures", { token, body: { tag } }); console.log(`cleanup ${r.status}`);
