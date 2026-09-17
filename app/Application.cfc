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
	// Phase 2 (identity) enables session management with secure cookie settings.
	this.sessionManagement = false;
	this.clientManagement = false;
	this.setClientCookies = false;

	variables.appRoot = getDirectoryFromPath(getCurrentTemplatePath());
	variables.repoRoot = createObject("java", "java.io.File").init(variables.appRoot & "..").getCanonicalPath() & "/";

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
				var eq = find("=", line);
				if (eq <= 1) continue;
				if (trim(left(line, eq - 1)) != arguments.name) continue;
				var raw = trim(mid(line, eq + 1, len(line)));
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
		// Adobe ColdFusion 2023 application-defined datasource (MS SQL Server driver).
		var ds = {
			"driver": "MSSQLServer",
			"host": host,
			"port": port,
			"database": database,
			"username": username,
			"password": password
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
		var message = isStruct(arguments.exception) && structKeyExists(arguments.exception, "message") ? arguments.exception.message : "Startup failure";
		writeLog(file = "icfwalk", type = "error", text = '{"event":"application.start.failed","message":' & serializeJSON(message) & '}');
		cfheader(statusCode = 500, statusText = "Internal Server Error");
		cfcontent(type = "application/json; charset=utf-8", reset = true);
		writeOutput('{"error":{"code":"STARTUP_FAILED","message":"The application could not start. Check the server log."}}');
	}
}
