/**
 * Append-only audit events (icf.audit_event). Details are canonical JSON containing lifecycle and
 * security facts only: identifiers, counts, checksums, states. Callers must never pass narrative
 * notes, email bodies, secrets, or tokens; a redaction pass removes obviously unsafe keys anyway.
 */
component output="false" {

	variables.UNSAFE_KEY_PATTERN = "(?i)(password|secret|token|authorization|cookie|text_value|textvalue|body|subject|notes|narrative)";

	public AuditRepository function init(required any db, required any canonicalJson, required any requestContext) {
		variables.db = arguments.db;
		variables.json = arguments.canonicalJson;
		variables.requestContext = arguments.requestContext;
		return this;
	}

	public void function record(required string entityType, string entityId = "", required string eventType, string actorUserId = "", struct details = {}) {
		var safe = {};
		for (var key in structKeyArray(arguments.details)) {
			if (reFind(variables.UNSAFE_KEY_PATTERN, key)) continue;
			if (!structKeyExists(arguments.details, key)) safe[key] = javaCast("null", "");
			else safe[key] = arguments.details[key];
		}
		variables.db.run(
			"INSERT INTO [icf].[audit_event] ([entity_type], [entity_id], [event_type], [actor_user_id], [correlation_id], [details_json])
			 VALUES (:entityType, :entityId, :eventType, :actorUserId, :correlationId, :details)",
			{
				"entityType": variables.db.nvarchar(arguments.entityType, 60),
				"entityId": variables.db.guid(arguments.entityId),
				"eventType": variables.db.nvarchar(arguments.eventType, 80),
				"actorUserId": variables.db.guid(arguments.actorUserId),
				"correlationId": correlationParam(),
				"details": variables.db.ntext(variables.json.serialize(safe))
			}
		);
	}

	private struct function correlationParam() {
		var id = variables.requestContext.correlationId();
		if (variables.db.isGuid(id)) return variables.db.guid(id);
		// Caller-supplied correlation ids that are not GUIDs are kept in the log line only.
		return variables.db.guid("");
	}
}
