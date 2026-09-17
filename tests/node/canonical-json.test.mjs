import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { canonicalize, sha256Hex } from "../../scripts/lib/snapshot.mjs";
import { root } from "./helpers.mjs";

const fixture = JSON.parse(fs.readFileSync(path.join(root, "tests", "fixtures", "canonical-json-vectors.json"), "utf8"));

test("shared canonical JSON vectors (reference implementation)", () => {
  for (const vector of fixture.vectors) {
    const actual = canonicalize(JSON.parse(vector.input));
    assert.equal(actual, vector.expected, vector.name);
    assert.equal(sha256Hex(actual), vector.sha256, `${vector.name} sha256`);
  }
});

test("canonicalize rejects undefined and non-finite numbers", () => {
  assert.throws(() => canonicalize({ a: undefined }));
  assert.throws(() => canonicalize({ a: Number.NaN }));
  assert.throws(() => canonicalize({ a: Number.POSITIVE_INFINITY }));
});

test("canonicalize is stable under key insertion order", () => {
  const a = canonicalize({ z: 1, a: { y: 2, b: 3 } });
  const b = canonicalize({ a: { b: 3, y: 2 }, z: 1 });
  assert.equal(a, b);
});
