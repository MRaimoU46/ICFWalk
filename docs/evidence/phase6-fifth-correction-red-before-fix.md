# Phase 6 publish-foundation fifth correction: red before green

The defect corrected in this pass is in the test harness, not in production: the shared CFML
assertions `BaseSpec.assertEquals` and `BaseSpec.assertNotEquals` compared stringified values with
CFML's `!=` and `==`. The red result below was produced **before any helper was written**, against
the unmodified `BaseSpec` of the audited candidate, by a temporary probe spec that called those
helpers exactly as the specs do. Every block is the runner's output as printed. The migration
inventory is `phase6-fifth-correction-assertion-inventory.md`.

Harness: `tools/runtime/lucee-up.sh` (Lucee 6.2.8.20 under Jetty) against SQL Server 2022
(16.0.4295.3) in Docker, driven through `POST /index.cfm/api/maintenance/tests/run?filter=<Spec>`
with the maintenance token (the route the CFML suite driver uses), by a small client that prints
every case and exits 1 when the report is not ok.

## The defect

```
public void function assertEquals(required any expected, required any actual, string message = "") {
	var e = isSimpleValue(arguments.expected) ? toString(arguments.expected) : serializeJSON(arguments.expected);
	var a = isSimpleValue(arguments.actual) ? toString(arguments.actual) : serializeJSON(arguments.actual);
	if (e != a) { fail(... "Expected [" & left(e, 300) & "] but got [" & left(a, 300) & "]."); }
}
public void function assertNotEquals(required any expected, required any actual, string message = "") {
	... if (e == a) fail(... "Expected values to differ but both were [" & left(e, 300) & "].");
}
```

CFML's `==` ignores case and compares two numeric-looking strings as numbers. A row version written
as 16 hexadecimal digits, such as `000000000000E988`, reads as `0e988`, which is zero, and so does its
successor. An assertion that a row version was unchanged could therefore pass although it moved, and
one that it changed could fail although it did.

## Red: the unmodified helpers

Isolation, checked immediately before the run: `HEAD` was the audited candidate
`04fb1afb05edbdad96d61c160c59217a01ab06e0`, `tests/cfml/BaseSpec.cfc` was its committed blob
`b2c63de97618ef843180d9dd4b7a0e891d7b2f37` (unmodified), and the only file in the working tree that
was not committed was the probe.

The probe, `tests/cfml/specs/CoerciveAssertionProbeTest.cfc` (deleted after this run, never
committed). Its four contract cases state what an exact assertion must do with the two pairs; its
two controls prove the probe itself works:

```
component extends="icfwalktests.BaseSpec" output="false" {

	private string function operatorFacts(required string a, required string b) {
		return "[CFML (a == b) is " & (arguments.a == arguments.b) & "; compare(a, b) is " & compare(arguments.a, arguments.b) & "]";
	}

	private boolean function refuses(required string expected, required string actual) {
		try {
			assertEquals(arguments.expected, arguments.actual);
		} catch (ICFWalk.Test.AssertionFailed e) {
			return true;
		}
		return false;
	}

	public void function testAssertEqualsRefusesCaseOnlyDistinctText() {
		if (!refuses("ICFWalk", "Icfwalk")) {
			fail("BaseSpec.assertEquals accepted [ICFWalk] and [Icfwalk] as equal " & operatorFacts("ICFWalk", "Icfwalk"));
		}
	}

	public void function testAssertEqualsRefusesDistinctRowVersions() {
		if (!refuses("000000000000E988", "000000000000E989")) {
			fail("BaseSpec.assertEquals accepted [000000000000E988] and [000000000000E989] as equal " & operatorFacts("000000000000E988", "000000000000E989"));
		}
	}

	public void function testAssertNotEqualsAcceptsCaseOnlyDistinctText() {
		assertNotEquals("ICFWalk", "Icfwalk", "BaseSpec.assertNotEquals rejected a valid not-equal assertion " & operatorFacts("ICFWalk", "Icfwalk"));
	}

	public void function testAssertNotEqualsAcceptsDistinctRowVersions() {
		assertNotEquals("000000000000E988", "000000000000E989", "BaseSpec.assertNotEquals rejected a valid not-equal assertion " & operatorFacts("000000000000E988", "000000000000E989"));
	}

	public void function testControlIdenticalValuesAreEqual() {
		assertEquals("ICFWalk", "ICFWalk");
		assertEquals("000000000000E988", "000000000000E988");
	}

	public void function testControlIdenticalValuesAreRefusedByNotEquals() {
		var refused = 0;
		try { assertNotEquals("ICFWalk", "ICFWalk"); } catch (ICFWalk.Test.AssertionFailed e) { refused++; }
		try { assertNotEquals("000000000000E988", "000000000000E988"); } catch (ICFWalk.Test.AssertionFailed e) { refused++; }
		if (refused != 2) fail("identical values were not refused by assertNotEquals (" & refused & " of 2)");
	}
}
```

Command and output (2026-09-22T22:01:21Z):

```
$ node run-spec.mjs CoerciveAssertionProbeTest --all-cases
# CoerciveAssertionProbeTest: passed=2 failed=4 skipped=0
  FAILED testAssertEqualsRefusesCaseOnlyDistinctText - BaseSpec.assertEquals accepted [ICFWalk] and [Icfwalk] as equal [CFML (a == b) is true; compare(a, b) is -1] @ /home/user/ICFWalk/tests/cfml/BaseSpec.cfc:38
  FAILED testAssertEqualsRefusesDistinctRowVersions - BaseSpec.assertEquals accepted [000000000000E988] and [000000000000E989] as equal [CFML (a == b) is true; compare(a, b) is -1] @ /home/user/ICFWalk/tests/cfml/BaseSpec.cfc:38
  FAILED testAssertNotEqualsAcceptsCaseOnlyDistinctText - BaseSpec.assertNotEquals rejected a valid not-equal assertion [CFML (a == b) is true; compare(a, b) is -1] Expected values to differ but both were [ICFWalk]. @ /home/user/ICFWalk/tests/cfml/BaseSpec.cfc:38
  FAILED testAssertNotEqualsAcceptsDistinctRowVersions - BaseSpec.assertNotEquals rejected a valid not-equal assertion [CFML (a == b) is true; compare(a, b) is -1] Expected values to differ but both were [000000000000E988]. @ /home/user/ICFWalk/tests/cfml/BaseSpec.cfc:38
  PASSED testControlIdenticalValuesAreEqual
  PASSED testControlIdenticalValuesAreRefusedByNotEquals
engine=Lucee 6.2.8.20 passed=2 failed=4 skipped=0 ok=false ms=14
[exit=1]
```

Both failure modes are shown for both pairs: `assertEquals` **accepted** `ICFWalk`/`Icfwalk` and
`000000000000E988`/`000000000000E989` as equal (a false pass), and `assertNotEquals` **rejected** both
valid not-equal assertions (a false failure). Its message is itself misleading: "both were
[ICFWalk]", although the second value was `Icfwalk`. The two controls pass, so identical values
behave and the four failures are the defect, not the probe.

A second temporary probe (also deleted, never committed) recorded the operator facts the permanent
cases rely on, on the same engine:

```
[ICFWalk] vs [Icfwalk]: (a == b)=true compare=-1
[000000000000E988] vs [000000000000E989]: (a == b)=true compare=-1
[4] vs [04]: (a == b)=true compare=1
[1E3] vs [1000]: (a == b)=true compare=1
[0] vs [0.0]: (a == b)=true compare=-1
[true] vs [YES]: (a == b)=true compare=1
[ICFWALK_DRAFT] vs [icfwalk_draft]: (a == b)=true compare=-1
[0000000000000000] vs [000000000000E988]: (a == b)=true compare=-1
[00000000000012E4] vs [0000000000120000]: (a == b)=true compare=-1
[0x000000000000E988] vs [0x000000000000e988]: (a == b)=true compare=-1
arrayContains(['Name'], 'name')=0
arrayContains(['000000000000E988'], '000000000000E989')=0
arrayContains(['4'], '04')=0
```

## The fix

`tests/cfml/BaseSpec.cfc` gains five exact helpers, all built on `compare()` and none on `==` or `!=`:

| Helper | Passes when | Refuses |
| --- | --- | --- |
| `assertExactTextEquals(expected, actual, message)` | the two simple values are the same characters | null; a struct, array or query (use `assertExactJsonEquals`) |
| `assertExactTextNotEquals(unexpected, actual, message)` | they are not the same characters | the same |
| `assertRowVersionEquals(expected, actual, message)` | the two tokens are the same characters | null, structures, and an **empty** token, so a row version that was never read cannot make "unchanged" true |
| `assertRowVersionChanged(before, after, message)` | `after` is not exactly `before` | the same |
| `assertExactJsonEquals(expected, actual, message)` | their `serializeJSON` text is identical | null |

Nothing is trimmed, re-cased, padded, or stripped of a `0x`: no production contract permits that
normalization for a value the tests compare. A failure message names both values in brackets with
their lengths, and where they first differ, for example `Expected row version [000000000000E988]
(16 chars) but got [000000000000E989] (16 chars); the first difference is at character 16 ([8]
expected, [9] found).` A value longer than 300 characters is shown as the window around its first
difference.

The general `assertEquals` and `assertNotEquals` keep their semantics for the numeric and boolean
contracts they still serve (3 equals 3.0, true equals true), are documented as not exact, and gain
one guard: an operand that is exactly 16 hexadecimal digits, optionally `0x`-prefixed, is refused
with a message naming the row-version helpers. `assertNotEquals` now names both values when it
fails. `assertThrows` compares the errorcode with `compare()` (the errorcode is what a client
receives as `error.code`) and the type prefix with `compareNoCase` (the way CFML resolves exception
types).

## Green: the permanent cases

`tests/cfml/specs/ExactAssertionTest.cfc`, 14 cases, exercising the shared implementation the
migrated specs call:

| Case | Proves |
| --- | --- |
| `testExactTextTellsACaseOnlyDifferenceApart` | `ICFWalk` / `Icfwalk` fails `assertExactTextEquals` (message names both and character 2) and passes `assertExactTextNotEquals` |
| `testIdenticalTextPassesTheEqualsHelper` | identical text, the empty text and `04` pass `assertExactTextEquals` |
| `testIdenticalTextFailsTheNotEqualsHelper` | identical text fails `assertExactTextNotEquals`, naming the value |
| `testExactTextNeverReadsTextAsANumberOrABoolean` | `4`/`04`, `1E3`/`1000`, `0`/`0.0`, `true`/`YES`, `ICFWALK_DRAFT`/`icfwalk_draft` are each different text |
| `testExactTextRefusesNullAndStructuresInsteadOfStringifyingThem` | null and structures are refused with a message saying which |
| `testRowVersionsE988AndE989AreDifferentTokens` | `000000000000E988` / `000000000000E989` fails `assertRowVersionEquals` (message names both and character 16) and passes `assertRowVersionChanged` |
| `testIdenticalRowVersionsPassTheEqualsHelper` | identical tokens pass, in the bare, `0x` and decimal forms |
| `testIdenticalRowVersionsFailTheChangedHelper` | identical tokens fail `assertRowVersionChanged`, naming the token |
| `testRowVersionsAreNeverNormalized` | case, the `0x` prefix, padding, and two tokens that are both zero to `==` are all different tokens |
| `testAnUnreadRowVersionIsRefusedRatherThanCompared` | empty and null tokens and structures are refused |
| `testExactJsonKeepsTheCaseOfCodesAndKeys` | `["DRAFT"]` / `["draft"]`, `{"code":"A"}` / `{"code":"a"}` and reordered lists differ |
| `testAssertThrowsComparesTheErrorcodeExactly` | a lower-case expected errorcode fails; the type prefix matches as CFML matches types |
| `testTheCoerciveHelpersRefuseARowVersionToken` | `assertEquals` / `assertNotEquals` refuse bare, `0x` and lower-case tokens; `144`, `3`/`3.0` and `true` still compare |
| `testNoSpecSendsARowVersionOrALiteralTextThroughTheCoercivePath` | the source guard: no spec passes a row-version expression or a quoted literal to the general helpers, compares a row version with an operator, or shadows a shared helper |

Run against the helpers **before** the call sites were migrated (2026-09-22T22:22:45Z), 13 of the 14
passed and the source guard failed, which is the state it exists to detect:

```
$ node run-spec.mjs ExactAssertionTest --all-cases
# ExactAssertionTest: passed=13 failed=1 skipped=0
  ...
  FAILED testNoSpecSendsARowVersionOrALiteralTextThroughTheCoercivePath - 500 coercive comparison(s) of exact values: SnapshotServiceTest.cfc:22 passes a quoted text literal to assertEquals; ... WalkSummaryCoherenceTest.cfc:227 passes a row version to assertEquals; ...
engine=Lucee 6.2.8.20 passed=13 failed=1 skipped=0 ok=false
```

(500 findings: 155 row-version arguments and 345 quoted-literal arguments across 27 spec files.)
After the migration all 14 pass, and the complete suite passed 391/391 with no skips in the
development run, 377 before plus the 14 new cases. The exact-commit gate's own result is reported
with the handoff, not here, because writing it here would change the commit it describes.

## Adobe ColdFusion 2023

Not executed; everything above ran on Lucee 6.2.8.20. `compare()` and `compareNoCase()` are
documented with the same semantics on Adobe ColdFusion. Two things should be confirmed there before
any claim about that engine: that `ExactAssertionTest` passes as a whole, and that
`assertExactJsonEquals` still separates the cases it separates here, because Adobe ColdFusion's
`serializeJSON` infers types from string content (a string `"4"` may serialize as the number `4`),
which Lucee does not. The cases above avoid depending on that difference; production code does not
use these helpers.
