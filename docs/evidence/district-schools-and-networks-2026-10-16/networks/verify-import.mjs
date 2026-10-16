// Verifies config/org-units.networks.json on a live application (Lucee or ColdFusion): imports
// org-units.example.json and then org-units.networks.json by file name, as docs/LOCAL_SETUP.md step 8
// says, and reads the tree back as a district-level report user sees it (/api/reports/options). Every
// listed school must sit under its network, the closed schools must be out of every scope, every open
// school must be coded as a School value of the 2026-10-14 version (and every such value an open school),
// and the import must be idempotent (a second import changes nothing). Run on a scratch database: the units
// it imports are the deployment's own codes and are left in place. Never prints a token or a password.
//
// usage: node verify-import.mjs <owner-list.tsv>     (ICFWALK_BASE_URL selects the engine)
import assert from "node:assert/strict";
import fs from "node:fs";
const { api, baseUrl, loadRuntimeEnv } = await import("/home/user/ICFWalk/tests/node/helpers.mjs");

const env = loadRuntimeEnv();
const token = env.ICFWALK_MAINTENANCE_TOKEN || "";
assert.ok(token, "ICFWALK_MAINTENANCE_TOKEN is set (not printed)");
const listed = fs.readFileSync(process.argv[2], "utf8").trim().split("\n").slice(1).map((l) => l.split("\t").map((x) => x.trim()));
const networksFile = JSON.parse(fs.readFileSync("/home/user/ICFWalk/config/org-units.networks.json", "utf8"));
const example = JSON.parse(fs.readFileSync("/home/user/ICFWalk/config/org-units.example.json", "utf8")).orgUnits;
const revision = JSON.parse(fs.readFileSync("/home/user/ICFWalk/config/instrument-config-2026-10-14.json", "utf8"));
let step = 0;
const ok = (what) => console.log(`ok ${++step} - ${what}`);
let failed = false;
try {
  console.log(`engine at ${baseUrl(env)}, database ${env.ICFWALK_DB_NAME || "icfwalk_dev"}`);
  for (const file of ["org-units.example.json", "org-units.networks.json"]) {
    const r = await api(env, "POST", "/api/maintenance/org-units/import", { token, body: { file } });
    assert.equal(r.status, 200, r.text);
    console.log(`import ${file}: ${JSON.stringify(r.json)}`);
  }
  ok("org-units.example.json, then org-units.networks.json, imported by file name");

  const subject = `netverify-${Date.now().toString(36)}-reader`;
  const u = await api(env, "POST", "/api/maintenance/identity/provision-user", { token, body: { subject, displayName: "Network check reader" } });
  assert.ok(u.status === 200 || u.status === 201, u.text);
  const a = await api(env, "POST", "/api/maintenance/identity/assign-role", { token, body: { subject, roleCode: "DISTRICT_REPORT_ONLY", orgUnitCode: "district", includeDescendants: true } });
  assert.equal(a.status, 201, a.text);
  const read = async () => {
    const r = await fetch(`${baseUrl(env)}/index.cfm/api/reports/options`, { headers: { Accept: "application/json", "X-ICFWalk-Dev-Subject": subject } });
    assert.equal(r.status, 200);
    return (await r.json()).orgUnits;
  };
  const units = await read();
  const byId = new Map(units.map((x) => [x.orgUnitId, x]));
  const byCode = new Map(units.map((x) => [x.code, x]));
  const parentCode = (x) => (x.parentOrgUnitId ? byId.get(x.parentOrgUnitId).code : null);
  const district = byCode.get("district");
  assert.ok(district && district.type === "DISTRICT");

  const networks = units.filter((x) => x.type === "NETWORK");
  assert.deepEqual(networks.map((n) => n.name).sort(), [...new Set(listed.map((r) => r[0]))].sort());
  assert.ok(networks.every((n) => parentCode(n) === "district"));
  ok(`${networks.length} networks, each directly under the district: ${networks.map((n) => n.name).join(", ")}`);

  // Every school of the networks file under the network it names, the network being the one the owner
  // listed it in (row by row, in the owner's order).
  const fileSchools = networksFile.orgUnits.filter((x) => x.type === "SCHOOL" && x.active !== false);
  const closedSchools = networksFile.orgUnits.filter((x) => x.type === "SCHOOL" && x.active === false);
  assert.equal(fileSchools.length, listed.length);
  for (let i = 0; i < listed.length; i++) {
    const [network, name] = listed[i];
    const want = fileSchools[i];
    const got = byCode.get(want.code);
    assert.ok(got, `${want.code} is in the reader's scope`);
    assert.equal(got.type, "SCHOOL");
    assert.equal(byCode.get(parentCode(got)).name, network, `${name} is under ${network}`);
  }
  ok(`all ${listed.length} listed schools sit under the network the owner listed them in`);

  for (const x of closedSchools) assert.ok(!byCode.has(x.code), `${x.name} is closed, so in no scope`);
  ok(`the ${closedSchools.length} closed schools are inactive and in no scope: ${closedSchools.map((x) => x.name).join(", ")}`);
  const accounted = new Set([...fileSchools, ...closedSchools].map((x) => x.code));
  assert.deepEqual(example.filter((x) => x.type === "SCHOOL" && !accounted.has(x.code)).map((x) => x.code), [], "every example school is placed or closed");
  const schoolDim = revision.dimensions.find((d) => d.code === "school").dimensionId;
  const values = revision.dimensionValues.filter((v) => v.dimensionId === schoolDim && v.valueCode !== "other").map((v) => v.valueCode).sort();
  assert.deepEqual(units.filter((x) => x.type === "SCHOOL").map((x) => x.code).sort(), values);
  ok(`the ${values.length} open schools are exactly the 2026-10-14 version's School values, code for code`);

  const names = new Map(example.map((x) => [x.code, x.name]));
  for (const x of fileSchools) if (names.has(x.code)) assert.equal(byCode.get(x.code).name, names.get(x.code), `${x.code} keeps its name`);
  ok("every existing school keeps its name; only its parent changed");

  const again = await api(env, "POST", "/api/maintenance/org-units/import", { token, body: { file: "org-units.networks.json" } });
  assert.equal(again.status, 200, again.text);
  assert.equal(again.json.created, 0);
  assert.deepEqual((await read()).map((x) => `${x.code}<${x.parentOrgUnitId}`), units.map((x) => `${x.code}<${x.parentOrgUnitId}`));
  ok(`a second import creates nothing and changes no parent (${JSON.stringify(again.json)})`);
} catch (e) {
  failed = true;
  console.log(`not ok ${++step} - ${e.message}`);
}
console.log(failed ? "NETWORKS IMPORT CHECK FAILED" : "NETWORKS IMPORT CHECK PASSED");
process.exit(failed ? 1 : 0);
