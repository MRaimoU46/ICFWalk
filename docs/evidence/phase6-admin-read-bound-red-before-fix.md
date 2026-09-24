# Phase 6 administration re-audit correction P6A-R01: red before green

**The finding.** The re-audit of the audit corrections (`3e1168663c14d069d3f033cd62456653f2bf369d`)
found that `HttpRequestSource.readBody` did not keep the bound its documentation stated. Every read
asked the servlet container's stream for a fixed 65,536 bytes and the running total was compared
with the limit only afterwards, so a read that began just under the limit could consume up to 65,536
bytes past it before the reader noticed. The records said "at most one byte past the limit".
`RouterBodyOrderTest` did not catch it, because it drives `FakeRequestSource`, which stated the
contract rather than exercising the production loop.

**The correction the re-audit specified.** Each read asks for `min(65536, maxBytes - total + 1)`
bytes. `java.io.InputStream.read(byte[], int, int)` returns at most the length asked for, so the
reader then consumes at most `maxBytes + 1` bytes from the stream, and exactly `maxBytes + 1` whenever
the body is longer.

## The regression, on the production loop

`tests/cfml/specs/RequestBodyReadBoundTest.cfc` (8 cases) drives the **production** `readBody`:
`tests/cfml/support/StreamedRequestSource.cfc` extends `icfwalk.http.HttpRequestSource` and replaces
only `containerRequest()` (where the stream comes from) and the request metadata; `readBody` -- the
loop, the size of every read it asks for, the count, the fallback decision -- is inherited unchanged.
`tests/cfml/support/RecordingInputStream.cfc` holds the body in a real `java.io.ByteArrayInputStream`
(which, like a chunked body that has fully arrived, returns as much as is asked for: the worst case)
and records every read; bytes consumed are measured exactly as the body's size minus
`ByteArrayInputStream.available()`. Three cases drive the same reader through `Router.handle`.

## Red: the committed reader of `3e11686`

Run with `src/` and `app/` exactly as in `3e1168663c14d069d3f033cd62456653f2bf369d` (`git status`
showed only the three new, untracked test files), on Lucee 6.2.8.20 restarted after the files were
added, SQL Server 2022 (16.0.4295.3), through
`POST /index.cfm/api/maintenance/tests/run?filter=RequestBodyReadBoundTest`:

```
FAILED  RequestBodyReadBoundTest.testABodyWithinTheLimitIsReadWholeAndExactly
        limit 70000, body 65535: read 2 asked for 65536 bytes with 65535 already read; the bound is 4466 (min(65536, limit - total + 1)).
FAILED  RequestBodyReadBoundTest.testMultibyteTextIsBoundedInBytes
        euro signs: the reader counted exactly one byte past the limit Expected [5000001] but got [5046272].
FAILED  RequestBodyReadBoundTest.testShortReadsLikeANetworkStreamStopAtTheSameByte
        limit 0, at most 1 bytes delivered per read: read 1 asked for 65536 bytes with 0 already read; the bound is 1 (min(65536, limit - total + 1)).
FAILED  RequestBodyReadBoundTest.testTheReaderConsumesExactlyOneBytePastTheLimitWhenTheWholeBodyHasArrived
        limit 0, body 1: read 1 asked for 65536 bytes with 0 already read; the bound is 1 (min(65536, limit - total + 1)).
PASSED  RequestBodyReadBoundTest.testTheRouterReadsABodyWithinTheLimitToItsEndAndParsesItOnce
FAILED  RequestBodyReadBoundTest.testTheRouterRefusesAnOversizedChunkedImportAfterReadingExactlyOneBytePast
        the router's read consumed exactly one byte past the import limit Expected [5000001] but got [5046272].
PASSED  RequestBodyReadBoundTest.testTheRouterTakesNothingFromTheStreamBeforeAuthenticationCsrfOrADeclaredOversizedLength
FAILED  RequestBodyReadBoundTest.testTheServerMaximumIsBoundTheSameWay
        the server maximum: the reader counted exactly one byte past the limit Expected [20000001] but got [20054016].
TOTALS passed=2 failed=6 skipped=0 ms=1113
```

Red for the intended reason, behaviorally, on the unmodified loop: with the import limit the reader
consumed **5,046,272** bytes (46,271 past the limit), with the server maximum **20,054,016** (54,015
past), and single reads asked for 65,536 bytes where the bound was 1 or 4,466. The two cases that
passed are preservation checks and pass on both trees by design: nothing is taken from the stream
before authentication, CSRF or a declared-length refusal, and a body within the limit is read whole.

## The fix

`src/http/HttpRequestSource.cfc`, the whole executable change:

```
-			var n = input.read(chunk, javaCast("int", 0), javaCast("int", variables.CHUNK));
+			var want = min(variables.CHUNK, limit - total + 1);
+			var n = input.read(chunk, javaCast("int", 0), javaCast("int", want));
```

## Green

Same runtime, Lucee restarted after the change:

```
PASSED  RequestBodyReadBoundTest.testABodyWithinTheLimitIsReadWholeAndExactly
PASSED  RequestBodyReadBoundTest.testMultibyteTextIsBoundedInBytes
PASSED  RequestBodyReadBoundTest.testShortReadsLikeANetworkStreamStopAtTheSameByte
PASSED  RequestBodyReadBoundTest.testTheReaderConsumesExactlyOneBytePastTheLimitWhenTheWholeBodyHasArrived
PASSED  RequestBodyReadBoundTest.testTheRouterReadsABodyWithinTheLimitToItsEndAndParsesItOnce
PASSED  RequestBodyReadBoundTest.testTheRouterRefusesAnOversizedChunkedImportAfterReadingExactlyOneBytePast
PASSED  RequestBodyReadBoundTest.testTheRouterTakesNothingFromTheStreamBeforeAuthenticationCsrfOrADeclaredOversizedLength
PASSED  RequestBodyReadBoundTest.testTheServerMaximumIsBoundTheSameWay
TOTALS passed=8 failed=0 skipped=0
```

`RouterBodyOrderTest` 12/12 and the five P6A-01 HTTP cases in `tests/node/admin-instrument.test.mjs`
5/5 on the same build; a never-finished chunked body over the server maximum is still answered 413
promptly on the running server. The authoritative result is the exact-commit gate recorded after the
code commit.

## P6A-R02: found while verifying -- a race in an existing test's client

Not an audit finding, and not part of P6A-R01; recorded here because it was found while verifying it.

**Observed.** A development run of `admin-publish`, `auth`, `walks` and `admin-instrument` together
(`node --test --test-concurrency=1`) failed once:

```
not ok 5 - ADM-01: the import body contract and the size cap
```

The case had passed in every earlier run, including the previous gate. Its failure output was not
kept (the run's output was filtered to the result lines), so the cause was established from the
server's log and by reproduction, not from that output. The application log for that run
(`icfwalk.log`, `request.rejected` events on `/api/admin/instrument/import`, UTC) shows every request
of the case answered as the test expects, the oversized one included, and the next test starting 26
ms later:

```
21:13:15.782 400 IMPORT_BODY_INVALID      the case: an extra member
21:13:15.792 400 DOCUMENT_REQUIRED        the case: no document
21:13:15.801 400 DOCUMENT_REQUIRED        the case: a document that is not an object
21:13:15.890 413 DOCUMENT_TOO_LARGE       the case: the oversized body
21:13:15.916 401 UNAUTHENTICATED          the next test (P6A-01, unauthenticated) begins
```

The failure was the client's. Two further runs of
the same four files, and four runs of the P6A-01 and ADM-01 cases alone, passed.

**Reproduced** with ad hoc probes (scripts outside the repository, not committed) against the running
server, each signing in a fresh administrator and sending the case's exact 5,000,029-byte body:

| Client, sequence | Attempts | Result |
| --- | --- | --- |
| `fetch`, the oversized request alone each time | 60, then 4 x 60 in parallel | 300 x 413 `DOCUMENT_TOO_LARGE` |
| `fetch`, the case's own sequence: three small requests on one keep-alive connection, then the oversized body | 100 | 99 x 413; **1 x `TypeError: fetch failed (cause: EPIPE: write EPIPE)`** |
| the file's raw-socket `rawRequest` helper, the same sequence | 300 | 300 x 413 `DOCUMENT_TOO_LARGE` |

**Cause.** Since P6A-01 the server refuses a body over the limit from its declared length, before
reading it, and Jetty closes the connection while the client may still be uploading. `fetch` (undici)
then sometimes surfaces its own failed write (`EPIPE`) instead of the response the server had already
sent. Before P6A-01 the server read the whole body first, so the race could not arise; the previous
gate passed this case by chance. The application's answer is correct in every observed case.

**Fix.** That one request is sent with `rawRequest`, which ignores the fate of its own write and
parses whatever the server sent before closing. The request bytes, the signed-in headers (identity,
session cookie, CSRF token, content type) and both assertions (413, `DOCUMENT_TOO_LARGE`) are
unchanged.

## What the bound is, precisely

At most `limit + 1` bytes are **taken by the application from the servlet container's input stream**.
Two things are outside it and are documented as such (`docs/ENDPOINTS.md`, "Request bodies";
`docs/LOCAL_SETUP.md`, "Request size limits"): bytes the container has already received from the
network into its own buffers, and a body an engine had already buffered before the application read
it, which the reader measures (in UTF-8 bytes, before parsing) but did not bound; the connector's
limit bounds that.

## What was not done

No production source was temporarily edited to produce the red; it is the committed loop. The
records of the previous round that stated the bound were corrected in place with a visible erratum
(`phase6-admin-audit-corrections-handoff.md`, `phase6-admin-audit-corrections-red-before-fix.md`,
and the audit-corrections section of `BUILD_STATUS.md`), following the precedent of CORR7-03.
