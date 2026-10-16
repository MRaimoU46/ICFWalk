// Builds the district's network import (config/org-units.networks.json) and the demo's org tree from the
// owner's list of 2026-10-16 (owner-list.tsv, verbatim) and config/org-units.example.json.
//
// A listed school is an existing SCHOOL unit when exactly one example name is the listed name or starts
// with it ("Centennial" -> "Centennial Elementary School"), or when it is one of the matches below that
// names differ on (the owner confirmed them: "correct on the matching"). Anything else is a new SCHOOL
// unit under the official name the owner gave ("those names are correct. Legacy Middle School. Hawk
// Hollow Middle School, Laurel Hill Elementary, Spring Trail Elementary, Sycamore Trails Elementary."),
// coded as the instrument codes the same name, so the School dimension's alignment can map it. The
// example schools no network lists are closed ("Those schools are all closed."): listed inactive under
// the district. Existing units keep their code, name and type; only their parent (and, for a closed
// school, its active flag) changes. Prints every decision.
//
// usage: node build.mjs <owner-list.tsv> <org-units.example.json> <out: import json> <out: demo json>
import fs from "node:fs";

const [listPath, examplePath, importOut, demoOut] = process.argv.slice(2);
const rows = fs.readFileSync(listPath, "utf8").trim().split("\n").slice(1).map((l) => l.split("\t").map((x) => x.trim()));
const example = JSON.parse(fs.readFileSync(examplePath, "utf8")).orgUnits;
const district = example.find((u) => u.type === "DISTRICT");
const schools = example.filter((u) => u.type === "SCHOOL");
const byCode = new Map(schools.map((u) => [u.code, u]));

// Names that differ between the owner's list and the unit names, matched by hand and confirmed by the owner.
const CONFIRMED = {
  "South Elgin Network|Bartlett": "bartlett_elementary_school", // Bartlett High School is listed on its own
  "Elgin Network|Ronald O'Neal": "o_neal_elementary_school",
  "Larkin Network|Harriet Gifford": "gifford_elementary_school",
  "High School Network|Central Schools Program": "central_school",
};
// The official names of the listed schools that are new units (the owner, 2026-10-16); the others are
// named as listed.
const OFFICIAL = {
  "Legacy": "Legacy Middle School",
  "Hawk Hollow Middle": "Hawk Hollow Middle School",
  "Laurel Hill": "Laurel Hill Elementary",
  "Spring Trail": "Spring Trail Elementary",
  "Sycamore Trails": "Sycamore Trails Elementary",
};
const norm = (s) => s.toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
// The instrument's own rule (scripts/lib/prototype.mjs codeOf).
const codeOf = (label) => String(label).toLowerCase().replace(/[^a-z0-9]+/g, "_").replace(/^_+|_+$/g, "");

const networks = [];
const placed = [];
const decisions = { matched: [], confirmed: [], added: [] };
for (const [network, school] of rows) {
  const networkCode = codeOf(network);
  if (!networks.some((n) => n.code === networkCode)) networks.push({ code: networkCode, type: "NETWORK", name: network, parentCode: district.code });
  const key = `${network}|${school}`;
  let unit = null;
  if (CONFIRMED[key]) {
    unit = byCode.get(CONFIRMED[key]);
    decisions.confirmed.push(`${network}: "${school}" = ${unit.name} (${unit.code})`);
  } else {
    const hits = schools.filter((u) => norm(u.name) === norm(school) || norm(u.name).startsWith(`${norm(school)} `));
    if (hits.length === 1) { unit = hits[0]; decisions.matched.push(`${network}: "${school}" = ${unit.name}`); }
    else if (hits.length > 1) throw new Error(`"${school}" matches ${hits.map((h) => h.code).join(", ")}: add it to CONFIRMED`);
  }
  if (unit) {
    if (placed.some((p) => p.code === unit.code)) throw new Error(`${unit.code} listed twice`);
    placed.push({ code: unit.code, type: unit.type, name: unit.name, parentCode: networkCode });
  } else {
    const name = OFFICIAL[school] || school;
    const code = codeOf(name);
    if (byCode.has(code) || placed.some((p) => p.code === code)) throw new Error(`new code ${code} collides`);
    placed.push({ code, type: "SCHOOL", name, parentCode: networkCode, added: true });
    decisions.added.push(`${network}: "${school}" = new unit ${name} (${code})`);
  }
}
const closed = schools.filter((u) => !placed.some((p) => p.code === u.code));

const description = [
  "The district's networks and schools as the product owner gave them on 2026-10-16 (docs/OPEN_DECISIONS.md).",
  "Import it after org-units.example.json: it adds a NETWORK unit for each network under the district, lists each school with its network as parent, adds the schools the example does not have, and closes the schools no network lists. Every other field of an existing school stays as it is.",
  `Matched under a different name (confirmed by the owner): ${decisions.confirmed.map((d) => d.replace(/^[^:]+: /, "")).join("; ")}.`,
  `New units, under their official names and coded as the 2026-10-14 version's School values: ${placed.filter((p) => p.added).map((p) => p.name).join(", ")}.`,
  `Closed, so imported inactive under the district: ${closed.map((u) => u.name).join(", ")}.`,
].join(" ");
const doc = {
  description,
  orgUnits: [...networks, ...placed.map(({ added, ...u }) => u), ...closed.map((u) => ({ code: u.code, type: u.type, name: u.name, parentCode: district.code, active: false }))],
};
fs.writeFileSync(importOut, `${JSON.stringify(doc, null, 2)}\n`);

// The demo's tree as the two imports leave it: the district, its networks and every open school under
// its network. A school's code is its School value in the amended 2026-10-14 list.
const demo = {
  district: { code: district.code, name: district.name },
  networks: networks.map((n) => ({ code: n.code, name: n.name })),
  schools: placed.map((p) => ({ code: p.code, name: p.name, parent: p.parentCode, schoolValue: p.code })),
};
fs.writeFileSync(demoOut, `${JSON.stringify(demo)}\n`);

console.log(`networks: ${networks.length}; listed schools: ${rows.length} (matched ${decisions.matched.length}, confirmed ${decisions.confirmed.length}, added ${decisions.added.length}); closed: ${closed.length}`);
console.log("\nconfirmed:"); decisions.confirmed.forEach((d) => console.log(`  ${d}`));
console.log("\nadded:"); decisions.added.forEach((d) => console.log(`  ${d}`));
console.log("\nclosed:"); closed.forEach((u) => console.log(`  ${u.name} (${u.code})`));
console.log(`\nimport units: ${doc.orgUnits.length}; demo schools: ${demo.schools.length}`);
