#!/usr/bin/env bash
# Runs ICFWalk on Adobe ColdFusion 2023 -- the target engine -- in Adobe's official container image,
# for verification (Phase 8). The counterpart of lucee-up.sh: the same repository, read-only, and the
# same kind of environment file. Nothing in the repository is written.
#
# What this is, and what it is not:
#   - The engine is Adobe ColdFusion 2023 from the image named by ICFWALK_ACF_IMAGE (Adobe's
#     `adobecoldfusion/coldfusion2023`; pin it by digest for a recorded run). It runs as the
#     image's Developer edition, which Adobe licenses for development and testing only.
#   - The site is the image's built-in web server (Tomcat, port 8500) with its document root set to
#     <repo>/app, which is what docs/LOCAL_SETUP.md asks of the production site. It is not IIS or
#     Apache in front of ColdFusion through the connector.
#   - The datasource is the documented Option A: an administrator-defined datasource named
#     ICFWALK_DATASOURCE, created here through the ColdFusion Administrator API. ColdFusion 2023 ships
#     its SQL Server driver (DataDirect, driver "MSSQLServer") as the `sqlserver` package, which cfpm
#     downloads from www.adobe.com. Where that is not reachable, this script registers Microsoft's
#     JDBC driver (the jar lucee-up.sh downloads) as an "Other" JDBC datasource instead, and says so.
#   - The Administrator's "Timeout requests after" is raised to ICFWALK_ACF_REQUEST_TIMEOUT seconds
#     (default 600), for the reason lucee-up.sh raises Lucee's: the CFML suite runs inside one
#     request and several specs hold a writer blocked for seconds. No application setting changes.
#
# The application reads ICFWALK_ENV_FILE=/opt/icfwalk-env/app.env: a copy of <repo>/.env without
# ICFWALK_DB_* (so Application.cfc defines no datasource of its own and uses the administrator's).
# The Node test harness keeps using <repo>/.env, so both address the same database.
#
# Usage: tools/runtime/acf-up.sh          start (or reuse) the container and wait for /api/health
#        tools/runtime/acf-down.sh        stop and remove it
# Then:  ICFWALK_BASE_URL=http://127.0.0.1:8500 ICFWALK_REQUIRE_APP=1 npm test
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RUNTIME="$ROOT/.runtime"
STATE="$RUNTIME/acf"
CONTAINER="${ICFWALK_ACF_CONTAINER:-icfwalk-acf}"
IMAGE="${ICFWALK_ACF_IMAGE:-adobecoldfusion/coldfusion2023:latest}"
TIMEOUT="${ICFWALK_ACF_REQUEST_TIMEOUT:-600}"
PORT=8500
mkdir -p "$STATE"
chmod 700 "$STATE"

# The Microsoft JDBC driver, from Maven Central (the same jar and version as lucee-up.sh).
MSSQL_JDBC_VERSION="${MSSQL_JDBC_VERSION:-12.10.2.jre11}"
JAR="$RUNTIME/jars/mssql-jdbc.jar"
if [ ! -s "$JAR" ]; then
  mkdir -p "$RUNTIME/jars"
  curl -sS -L --fail --max-time 900 -o "$JAR.part" "https://repo1.maven.org/maven2/com/microsoft/sqlserver/mssql-jdbc/$MSSQL_JDBC_VERSION/mssql-jdbc-$MSSQL_JDBC_VERSION.jar"
  mv "$JAR.part" "$JAR"
fi

# Settings the harness uses, from <repo>/.env (and .runtime/mssql.env for the local container).
envval() { # envval <name>: process environment, then .env, then empty
  local v="${!1:-}"
  if [ -z "$v" ] && [ -f "$ROOT/.env" ]; then v=$(grep -E "^$1=" "$ROOT/.env" | tail -1 | cut -d= -f2- || true); fi
  printf '%s' "$v"
}
DB_HOST=$(envval ICFWALK_DB_HOST); DB_HOST=${DB_HOST:-127.0.0.1}
DB_PORT=$(envval ICFWALK_DB_PORT); DB_PORT=${DB_PORT:-1433}
DB_NAME=$(envval ICFWALK_DB_NAME); DB_NAME=${DB_NAME:-icfwalk_dev}
DB_USER=$(envval ICFWALK_DB_USER)
DB_PASSWORD=$(envval ICFWALK_DB_PASSWORD)
DSN=$(envval ICFWALK_DATASOURCE); DSN=${DSN:-icfwalk}
TRUST=$(envval ICFWALK_DB_TRUST_SERVER_CERT); TRUST=${TRUST:-false}
ENCRYPT=$(envval ICFWALK_DB_ENCRYPT); ENCRYPT=${ENCRYPT:-true}
if [ -z "$DB_USER" ] && [ -f "$RUNTIME/mssql.env" ]; then DB_USER=sa; DB_PASSWORD=$(grep -E '^MSSQL_SA_PASSWORD=' "$RUNTIME/mssql.env" | cut -d= -f2-); TRUST=true; fi
[ -n "$DB_USER" ] && [ -n "$DB_PASSWORD" ] || { echo "ICFWALK_DB_USER / ICFWALK_DB_PASSWORD are not set" >&2; exit 1; }

# The application's environment file: <repo>/.env without the datasource-defining ICFWALK_DB_* values.
grep -v -E '^ICFWALK_DB_(HOST|PORT|NAME|USER|PASSWORD|ENCRYPT|TRUST_SERVER_CERT)=' "$ROOT/.env" > "$STATE/app.env"
chmod 600 "$STATE/app.env"

if [ ! -f "$STATE/admin.env" ]; then
  printf 'ACF_ADMIN_PASSWORD=%s\n' "Acf$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)" > "$STATE/admin.env"
  chmod 600 "$STATE/admin.env"
fi
ADMIN_PASSWORD=$(grep -E '^ACF_ADMIN_PASSWORD=' "$STATE/admin.env" | cut -d= -f2-)

health() { curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:$PORT/index.cfm/api/health" 2>/dev/null || true; }

if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  echo "Container $CONTAINER is running. Health: $(curl -sS --max-time 10 "http://127.0.0.1:$PORT/index.cfm/api/health")"
  exit 0
fi
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true

# The container shares the host network so that 127.0.0.1 is the same SQL Server the harness uses
# and the same loopback the maintenance guard trusts.
docker run -d --name "$CONTAINER" --network host \
  -e acceptEULA=YES -e password="$ADMIN_PASSWORD" \
  -e ICFWALK_ENV_FILE=/opt/icfwalk-env/app.env \
  -v "$ROOT:/icfwalk:ro" \
  -v "$JAR:/opt/coldfusion/cfusion/lib/mssql-jdbc.jar:ro" \
  "$IMAGE" >/dev/null
echo "Started $CONTAINER from $IMAGE ($(docker inspect --format '{{.Image}}' "$CONTAINER"))"

# First start: the image configures itself (document root /app, the administrator password) and then
# writes /opt/startup/disableScripts. Wait for that.
for i in $(seq 1 120); do
  if docker exec "$CONTAINER" test -f /opt/startup/disableScripts 2>/dev/null; then break; fi
  sleep 3
  [ "$i" = 120 ] && { echo "ColdFusion did not finish its first start; see docker logs $CONTAINER" >&2; exit 1; }
done

# The administrator datasource, created through the Administrator API by a one-off template placed
# in the image's own (empty) /app document root and removed straight after. It never touches the
# repository, and its output carries no secret. Values are written as CFML string literals, so # and
# " are doubled. Long text retrieval is on (disable_clob = false): without it ColdFusion returns the
# first 32,000 characters of an nvarchar(max) value and the instrument snapshot cannot be read (P8-04).
cfstr() { printf '%s' "$1" | sed -e 's/#/##/g' -e 's/"/""/g'; }
URL=$(cfstr "jdbc:sqlserver://$DB_HOST:$DB_PORT;databaseName=$DB_NAME;encrypt=$ENCRYPT;trustServerCertificate=$TRUST")
ADMIN_PASSWORD_CF=$(cfstr "$ADMIN_PASSWORD"); DB_USER_CF=$(cfstr "$DB_USER"); DB_PASSWORD_CF=$(cfstr "$DB_PASSWORD"); DSN_CF=$(cfstr "$DSN")
docker exec -i "$CONTAINER" sh -c 'cat > /app/icfwalk-acf-setup.cfm' <<CFM
<cfscript>
admin = createObject("component", "CFIDE.adminapi.administrator");
if (!admin.login("$ADMIN_PASSWORD_CF")) { writeOutput("LOGIN_FAILED"); abort; }
ds = createObject("component", "CFIDE.adminapi.datasource");
ds.setOther(name = "$DSN_CF", url = "$URL", class = "com.microsoft.sqlserver.jdbc.SQLServerDriver", driver = "mssql-jdbc", username = "$DB_USER_CF", password = "$DB_PASSWORD_CF", disable_clob = false, description = "ICFWalk verification (Microsoft JDBC driver $MSSQL_JDBC_VERSION)");
writeOutput("DSN_VERIFIED=" & ds.verifyDsn("$DSN_CF"));
</cfscript>
CFM
RESULT=$(docker exec "$CONTAINER" curl -sS --max-time 120 "http://127.0.0.1:$PORT/icfwalk-acf-setup.cfm" || true)
docker exec "$CONTAINER" rm -f /app/icfwalk-acf-setup.cfm
echo "Administrator datasource '$DSN' (Microsoft JDBC driver $MSSQL_JDBC_VERSION, Other): $RESULT"
case "$RESULT" in *DSN_VERIFIED=YES*|*DSN_VERIFIED=true*) ;; *) echo "the datasource could not be created or verified" >&2; exit 1 ;; esac

# The application's environment file, readable by the ColdFusion runtime user only -- the shape
# docs/LOCAL_SETUP.md asks of a deployment (a file only the service account can read). It is copied
# in rather than mounted, so the host copy keeps its own owner and mode.
docker exec "$CONTAINER" mkdir -p /opt/icfwalk-env
docker cp "$STATE/app.env" "$CONTAINER:/opt/icfwalk-env/app.env" >/dev/null
docker exec "$CONTAINER" sh -c 'chown -R cfuser:cfuser /opt/icfwalk-env && chmod 700 /opt/icfwalk-env && chmod 600 /opt/icfwalk-env/app.env'

# The site: document root <repo>/app, the front door, and the request timeout for the verification
# runtime. All are applied with ColdFusion stopped, then it is started again.
#
# The front door is the rule docs/OPERATIONS.md requires of the production web server: only
# /index.cfm (with its path) and /assets/ are served. ColdFusion itself refuses a direct request for
# Application.cfc, but with its own error page (HTTP 500, naming the engine and echoing the client);
# the application's code never runs, so it cannot answer instead. Here Tomcat's rewrite valve sends
# every other path to the application's router, which answers its JSON 404 -- the stand-in for the
# IIS request-filtering or Apache rule a deployment uses.
docker exec "$CONTAINER" /opt/coldfusion/cfusion/bin/coldfusion stop >/dev/null
docker exec "$CONTAINER" sed -i 's#docBase="/app"#docBase="/icfwalk/app"#' /opt/coldfusion/cfusion/runtime/conf/server.xml
# The valve sits on the site's Context, which reads its rules from /WEB-INF/rewrite.config: ColdFusion
# mounts /WEB-INF from its own wwwroot/WEB-INF (the embedded Tomcat's base directory is not the
# conf/ directory a Host-level valve would read).
# Tomcat matches a rule's pattern against the whole normalized path (Java matches(), not Apache's
# find()), hence the trailing .*$; rules, not RewriteCond %{REQUEST_URI}, because a condition sees the
# raw URI and /assets/../Application.cfc would pass for an asset. With these rules the ColdFusion
# Administrator (/CFIDE/administrator) is not reachable on the site either.
docker exec "$CONTAINER" sh -c 'grep -q RewriteValve /opt/coldfusion/cfusion/runtime/conf/server.xml || xmlstarlet ed -P -S -L \
  -s /Server/Service/Engine/Host/Context -t elem -n RewriteValveHolder -v "" \
  -i //RewriteValveHolder -t attr -n className -v org.apache.catalina.valves.rewrite.RewriteValve \
  -r //RewriteValveHolder -v Valve /opt/coldfusion/cfusion/runtime/conf/server.xml'
docker exec -i "$CONTAINER" sh -c 'cat > /opt/coldfusion/cfusion/wwwroot/WEB-INF/rewrite.config && chown cfuser /opt/coldfusion/cfusion/wwwroot/WEB-INF/rewrite.config' <<'RULES'
RewriteRule ^/assets/.*$ - [L]
RewriteRule ^/index\.cfm(/.*)?$ - [L]
RewriteRule ^/$ - [L]
RewriteRule ^.*$ /index.cfm/not-found [L]
RULES
docker exec "$CONTAINER" sed -i "s#<var name='timeoutRequestTimeLimit'><number>[0-9.]*</number></var>#<var name='timeoutRequestTimeLimit'><number>$TIMEOUT.0</number></var>#" /opt/coldfusion/cfusion/lib/neo-runtime.xml
docker exec "$CONTAINER" grep -c 'docBase="/icfwalk/app"' /opt/coldfusion/cfusion/runtime/conf/server.xml >/dev/null
docker exec "$CONTAINER" /opt/coldfusion/cfusion/bin/coldfusion start >/dev/null

for i in $(seq 1 90); do
  code=$(health)
  if [ "$code" = "200" ]; then
    echo "Health: $(curl -sS --max-time 10 "http://127.0.0.1:$PORT/index.cfm/api/health")"
    exit 0
  fi
  sleep 2
done
echo "The application did not answer on port $PORT; see docker logs $CONTAINER and /opt/coldfusion/cfusion/logs" >&2
exit 1
