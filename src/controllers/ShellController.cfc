/**
 * Serves the single HTML page for My Walks and the walk editor (src/views/shell.html). The page
 * contains no instrument content and no user data: the browser fetches /api/me and
 * /api/instrument/current after loading. Only the deployment-relative base paths are injected,
 * HTML-encoded. A strict Content-Security-Policy allows scripts and styles from this origin only
 * (plus the district logo host and Google Fonts used by the prototype).
 */
component output="false" {

	public ShellController function init(required struct container) {
		variables.c = arguments.container;
		variables.viewPath = arguments.container.repoRoot & "src/views/shell.html";
		variables.template = "";
		variables.html = new icfwalk.core.HtmlEncoder();
		return this;
	}

	public struct function index(required struct req) {
		var template = loadTemplate();
		var prefix = basePrefix();
		var html = replace(template, "{{assetBase}}", variables.html.encodeAttribute(prefix & "/assets"), "all");
		html = replace(html, "{{apiBase}}", variables.html.encodeAttribute(prefix & "/index.cfm/api"), "all");
		html = replace(html, "{{environment}}", variables.html.encodeAttribute(variables.c.config.environment), "all");
		return {
			"status": 200,
			"text": html,
			"contentType": "text/html; charset=utf-8",
			"headers": {
				"Cache-Control": "no-store",
				"X-Content-Type-Options": "nosniff",
				"X-Frame-Options": "DENY",
				"Referrer-Policy": "same-origin",
				"Content-Security-Policy": "default-src 'self'; script-src 'self'; style-src 'self' https://fonts.googleapis.com; font-src 'self' https://fonts.gstatic.com; img-src 'self' data: https://cmsv2-assets.apptegy.net; connect-src 'self' https://fonts.googleapis.com https://fonts.gstatic.com; frame-ancestors 'none'; base-uri 'none'; form-action 'self'; object-src 'none'"
			}
		};
	}

	/** Web-root prefix in front of /index.cfm (empty at the site root). */
	private string function basePrefix() {
		var script = cgi.script_name;
		var idx = findNoCase("/index.cfm", script);
		if (idx > 1) return left(script, idx - 1);
		return "";
	}

	private string function loadTemplate() {
		if (!len(variables.template) || variables.c.config.environment == "development") {
			variables.template = fileRead(variables.viewPath, "utf-8");
		}
		return variables.template;
	}
}
