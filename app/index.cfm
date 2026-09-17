<cfscript>
// Front controller. All routing, authorization, and response encoding happens in the router
// and controllers under /icfwalk (../src). Keep this template free of logic.
application.icf.router.dispatch();
</cfscript>
