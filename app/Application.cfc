/**
 * ICFWalk application root (Adobe ColdFusion 2023 / CFML).
 *
 * The web root is this directory. Application source lives outside the web root in ../src
 * (mapped as /icfwalk) and CFML tests in ../tests/cfml (mapped as /icfwalktests). Every HTTP
 * request goes through index.cfm and the router; direct requests to other templates are
 * rejected so that there is exactly one entry point to authorize.
 */
component output="false" {

	this.name = "ICFWalk";
	this.applicationTimeout = createTimeSpan(1, 0, 0, 0);
	// Arrays are passed to functions by reference, as Lucee always does. Adobe ColdFusion passes a
	// copy unless this is set, and the code sorts and fills arrays in place through arguments
	// (ConfigNormalizer.sortBy, every issue collector): on ColdFusion without it the snapshot came
	// out in the wrong order and its checksum differed (P8-02). Lucee ignores the setting.
	this.passArrayByReference = true;

	variables.appRoot = getDirectoryFromPath(getCurrentTemplatePath());
	variables.repoRoot = createObject("java", "java.io.File").init(variables.appRoot & "..").getCanonicalPath() & "/";

	// Sessions hold only the signed-in user id, subject, and CSRF token (see SessionService).
	// Cookie flags: HttpOnly always; Secure unless explicitly disabled outside production
	// (ConfigLoader refuses ICFWALK_COOKIE_SECURE=false in production); SameSite=Lax.
	variables.sessionMinutes = envValue("ICFWALK_SESSION_TIMEOUT_MINUTES", "60");
	if (!isNumeric(variables.sessionMinutes) || variables.sessionMinutes < 5 || variables.sessionMinutes > 720) variables.sessionMinutes = 60;
	this.sessionManagement = true;
	this.sessionTimeout = createTimeSpan(0, 0, int(variables.sessionMinutes), 0);
	this.clientManagement = false;
	this.setClientCookies = true;
	this.sessionCookie = {
		"httpOnly": true,
		"secure": lCase(envValue("ICFWALK_COOKIE_SECURE", "true")) != "false",
		"sameSite": "Lax"
	};

	this.mappings["/icfwalk"] = variables.repoRoot & "src";
	this.mappings["/icfwalktests"] = variables.repoRoot & "tests/cfml";

	// Datasource: either an administrator-defined datasource named by ICFWALK_DATASOURCE, or an
	// application-defined one built from ICFWALK_DB_* environment values (development, test, or
	// container deployments). Credentials are never stored in source control.
	variables.datasourceName = envValue("ICFWALK_DATASOURCE", "icfwalk");
	variables.dbHost = envValue("ICFWALK_DB_HOST", "");
	if (len(variables.dbHost)) {
		this.datasources[variables.datasourceName] = buildDatasource();
	}
	this.datasource = variables.datasourceName;

	/**
	 * Reads an environment variable, falling back to a repository .env file (ICFWALK_ENV_FILE or
	 * <repo>/.env). The pseudo-constructor cannot use application-scoped services, so this helper
	 * duplicates the minimal lookup that ConfigLoader performs.
	 */
	private string function envValue(required string name, string defaultValue = "") {
		var system = createObject("java", "java.lang.System");
		var value = system.getenv(arguments.name);
		if (!isNull(value) && len(value)) {
			return value;
		}
		var envFile = system.getenv("ICFWALK_ENV_FILE");
		if (isNull(envFile) || !len(envFile)) {
			envFile = variables.repoRoot & ".env";
		}
		if (fileExists(envFile)) {
			var lines = listToArray(fileRead(envFile, "utf-8"), chr(10));
			for (var line in lines) {
				line = trim(line);
				if (!len(line) || left(line, 1) == "##") continue;
				if (left(line, 7) == "export ") line = trim(mid(line, 8, len(line)));
				var eqAt = find("=", line);
				if (eqAt <= 1) continue;
				if (trim(left(line, eqAt - 1)) != arguments.name) continue;
				var raw = trim(mid(line, eqAt + 1, len(line)));
				if (len(raw) >= 2 && ((left(raw, 1) == '"' && right(raw, 1) == '"') || (left(raw, 1) == "'" && right(raw, 1) == "'"))) {
					raw = mid(raw, 2, len(raw) - 2);
				}
				return raw;
			}
		}
		return arguments.defaultValue;
	}

	private struct function buildDatasource() {
		var host = variables.dbHost;
		var port = envValue("ICFWALK_DB_PORT", "1433");
		var database = envValue("ICFWALK_DB_NAME", "icfwalk");
		var username = envValue("ICFWALK_DB_USER", "");
		var password = envValue("ICFWALK_DB_PASSWORD", "");
		var encrypt = envValue("ICFWALK_DB_ENCRYPT", "true") == "true";
		var trustCert = envValue("ICFWALK_DB_TRUST_SERVER_CERT", "false") == "true";
		var isLucee = findNoCase("lucee", server.coldfusion.productname) > 0;
		if (isLucee) {
			return {
				"class": "com.microsoft.sqlserver.jdbc.SQLServerDriver",
				"connectionString": "jdbc:sqlserver://" & host & ":" & port & ";databaseName=" & database
					& ";encrypt=" & (encrypt ? "true" : "false")
					& ";trustServerCertificate=" & (trustCert ? "true" : "false"),
				"username": username,
				"password": password,
				"validate": false
			};
		}
		// Adobe ColdFusion 2023 application-defined datasource (MS SQL Server driver). Long text
		// retrieval is on: without it ColdFusion returns only the first 32,000 characters of an
		// nvarchar(max) value, and an instrument snapshot is about 218,000 (P8-04).
		var ds = {
			"driver": "MSSQLServer",
			"host": host,
			"port": port,
			"database": database,
			"username": username,
			"password": password,
			"disable_clob": false
		};
		if (encrypt) {
			ds["url"] = "jdbc:macromedia:sqlserver://" & host & ":" & port & ";databaseName=" & database
				& ";EncryptionMethod=SSL;ValidateServerCertificate=" & (trustCert ? "false" : "true");
		}
		return ds;
	}

	public boolean function onApplicationStart() {
		application.icf = createObject("component", "icfwalk.Bootstrap").init(variables.repoRoot, variables.appRoot).build();
		return true;
	}

	public boolean function onRequestStart(required string targetPage) {
		// Single entry point: only index.cfm is served through CFML.
		if (listLast(arguments.targetPage, "/") != "index.cfm") {
			cfheader(statusCode = 404, statusText = "Not Found");
			cfcontent(type = "application/json; charset=utf-8", reset = true);
			writeOutput('{"error":{"code":"NOT_FOUND","message":"Not found."}}');
			return false;
		}
		if (!structKeyExists(application, "icf")) {
			lock scope="application" type="exclusive" timeout="30" {
				if (!structKeyExists(application, "icf")) onApplicationStart();
			}
		} else if (structKeyExists(url, "reinit") && application.icf.config.environment == "development") {
			lock scope="application" type="exclusive" timeout="30" {
				onApplicationStart();
			}
		}
		application.icf.requestContext.begin();
		return true;
	}

	public void function onError(required any exception, required string eventName) {
		if (structKeyExists(application, "icf") && structKeyExists(application.icf, "responder")) {
			application.icf.responder.sendException(arguments.exception);
			return;
		}
		// The application failed to start (for example an invalid configuration). Emit a safe
		// error without any configuration values and log the message only.
		var message = startupMessage(arguments.exception);
		writeLog(file = "icfwalk", type = "error", text = '{"event":"application.start.failed","message":' & serializeJSON(message) & '}');
		cfheader(statusCode = 500, statusText = "Internal Server Error");
		cfcontent(type = "application/json; charset=utf-8", reset = true);
		writeOutput('{"error":{"code":"STARTUP_FAILED","message":"The application could not start. Check the server log."}}');
	}

	/**
	 * The message of a failed start, on either engine (P8-03). Adobe ColdFusion hands onError an
	 * exception that isStruct() does not recognise, and wraps the cause of a failed
	 * onApplicationStart in rootCause (its own message names only the event), so the cause is read
	 * first. Nothing here may throw: this runs when the application could not start.
	 */
	private string function startupMessage(required any exception) {
		var candidates = [];
		try { if (!isNull(arguments.exception.rootCause)) arrayAppend(candidates, arguments.exception.rootCause); } catch (any ignored) {}
		arrayAppend(candidates, arguments.exception);
		for (var candidate in candidates) {
			try {
				if (!isNull(candidate.message) && isSimpleValue(candidate.message) && len(candidate.message)) return candidate.message;
			} catch (any ignored) {}
		}
		return "Startup failure";
	}
}
