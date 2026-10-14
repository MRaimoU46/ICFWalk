# Instrument revision 2026-10-14: environment

Everything below is as executed in this session's container. No production credential, real person,
narrative or secret is recorded here: every person, school and walk is synthetic, and the generated
passwords and tokens were never printed.

## Host

Linux 6.18.44 x86_64, Ubuntu 24.04.5 LTS, 4 CPUs, 15 GB; Docker 29.8.2 (client and daemon; the daemon was
started in the session); OpenJDK 21.0.12.1; Node v22.22.0, npm 10.9.4; git 2.43.0. As the gate's step 2
records them.

## Engines and database

The same pinned images and jars as the Phase 8 correction A8 gate:

| What | Identity |
| --- | --- |
| SQL Server 2022 (Developer), 16.0.4295.3 (RTM-CU27) | `mcr.microsoft.com/mssql/server@sha256:4402d880dd4c34bfa7d8705e56a86cd6c88da80a1f6bbbe741f999e76264a090` |
| Adobe ColdFusion 2023 Update 25 (2023,0,25,330977) | `adobecoldfusion/coldfusion2023@sha256:e42bbf07745ebd4d8c23d6679738ac13e264218618093bc3689ebfaf8966f30e` (Docker Hub answered 429 to the first pull; a later retry succeeded) |
| Lucee 6.2.8.20 (`lucee-light.jar`) | `e004579cf48a6d0f4d527429ad19d7543070803d3454eacb5e8efe674419be80` |
| jetty-runner 9.4.58 | `b692f66bb7a53bfa739b7eb466dc2bf75bddd5bfa0e7d425cd2a0434233987c2` |
| Microsoft JDBC driver 12.10.2.jre11 | `dbf27d0d7ff85f133bbc80b0282ec2cd4d1fa1f0954033dd6bbd68612a1c0a6e` |

The three jar hashes are the ones the A8 environment record names.

## Test harness

`node --test`; Playwright 1.56.1 with Chromium 141.0.7390.37; axe-core 4.13.0; mssql 12.7.2; all from
`package-lock.json` by `npm ci`.

## Google Fonts, and the condition the browser suites ran under

The shell loads Work Sans from Google Fonts. In this session's container the browser **can** reach Google
Fonts through the container's HTTPS proxy, which, judging by their passing console checks, no earlier
gate's container did. With it reachable, a full run of this change failed 36 Playwright tests of the
frozen suites, every one on the same console message, and the frozen code fails the same way (shown for
one test file in `font-cors/`). The reason has nothing to do with the application: Playwright's
`extraHTTPHeaders` sends the development
identity header (`X-ICFWalk-Dev-Subject`) with **every** request, the font request to `fonts.gstatic.com`
included; a cross-origin font request carrying a custom header is preflighted; Google refuses the
preflight; and Chromium reports "Access to font ... has been blocked by CORS policy" on the console, which
those tests' console checks count as a page error. Their filters already pass the network failures an
unreachable font produces (`ERR_`, `net::`, `Failed to load resource`): the suites were written, and every
earlier gate passed, with Google Fonts out of reach.

The gate therefore runs `npm test` without the container's proxy variables, so Chromium cannot reach
Google Fonts, as in every earlier gate (the request fails with `net::ERR_CERT_AUTHORITY_INVALID`, a network
error the suites already ignore). Nothing else uses the network during `npm test`: the application, SQL
Server and the browser all run on 127.0.0.1. The reproduction on the frozen code is in `font-cors/`.

The defect belongs to the test harness, not the application (a real browser never sends that header; the
district's gateway adds identity server-side). It is recorded as open in `BUILD_STATUS.md` with the
proposed correction: abort requests to the two Google Fonts hosts in every Playwright context, so the
suites no longer depend on whether the fonts are reachable.

## Configuration (no secrets)

Development profile, as in Phase 8: `ICFWALK_ENVIRONMENT=development`, the identity stub on, maintenance
and the CFML test runner on (loopback, generated token), cookies without `Secure` over plain HTTP,
`ICFWALK_DB_TRUST_SERVER_CERT=true` for the disposable container's self-signed certificate.
