# Instrument revision 2026-10-14, step 2: environment

The same container, engines, images, jars and harness as step 1
(`docs/evidence/instrument-revision-2026-10-14/environment.md`), as the gate's step 2 records them again:
Linux 6.18.44 x86_64, Ubuntu 24.04.5 LTS, 4 CPUs, 15 GB; Docker 29.8.2 (client and daemon, the daemon
started in the session); OpenJDK 21.0.12.1; Node v22.22.0, npm 10.9.4. SQL Server 2022 (Developer)
16.0.4295.3, Adobe ColdFusion 2023 Update 25 and Lucee 6.2.8.20 from the same pinned image digests and jar
hashes; Playwright 1.56.1 with Chromium 141.0.7390.37,
axe-core 4.13.0 and mssql 12.7.2 from `package-lock.json` by `npm ci`. No production credential, real
person, narrative or secret is recorded: every person, school and walk is synthetic, and the generated
passwords and tokens were never printed.

What differs from step 1:

- **The session's worker was restarted several times while step 2 was built**, each time stopping the
  Docker daemon and the Lucee process. Each time the daemon was started again in the session and the
  SQL Server container restarted; work in progress was committed and pushed as "not gated" checkpoints so
  that it would survive. The gate itself builds a brand-new SQL Server container and database, so nothing
  from those restarts reaches it.
- **Google Fonts.** As in step 1, the gate runs `npm test` without the container's proxy variables, so the
  browser cannot reach Google Fonts; the operations and red-before-green scripts do the same for every
  run that starts a browser. The test-harness defect step 1 recorded is unchanged.
- **ColdFusion's template cache.** The red-before-green run reloads components through the development
  reinit. In the gate's ColdFusion container the runtime configuration has `trustedCacheEnabled` false,
  so a changed component is compiled again when it is next created.
- **Migration 008.** The gate applies 001 to 008 to each brand-new database and re-applies 002 to 008;
  the operations scenarios apply 008 to their own scratch databases (a Phase 6 installation, the killed
  and refused migrations, the readiness probe, the production profile) and remove them afterwards.
