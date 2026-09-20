<cfscript>
// Front controller. All routing, authorization, and response encoding happens in the router
// and controllers under /icfwalk (../src). Keep this template free of logic.
//
// This file deliberately ends at the closing tag with no trailing newline. Any character after
// </cfscript> is template output, and cfcontent(reset=true) has already run inside dispatch(), so
// a trailing newline here is appended to every response body. JSON parsers ignored it; the Phase 5
// text export cannot, because its contract is byte-exact and ends without a newline
// (docs/PHASE_5_IMPLEMENTATION_BRIEF.md 14.14/14.15).
application.icf.router.dispatch();
</cfscript>