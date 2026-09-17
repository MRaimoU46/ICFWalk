/**
 * icf.app_user access: lookup by identity subject, just-in-time provisioning, sign-in bookkeeping.
 * Users are matched by identity_subject only (never by email, which may change or be reused).
 */
component output="false" {

	public UserRepository function init(required any db) {
		variables.db = arguments.db;
		return this;
	}

	public struct function findBySubject(required string subject) {
		var q = variables.db.run("SELECT user_id, identity_subject, display_name, email, active, last_sign_in_at FROM [icf].[app_user] WHERE identity_subject = :subject",
			{ "subject": variables.db.nvarchar(arguments.subject, 255) });
		return q.recordCount ? rowToUser(q, 1) : {};
	}

	public struct function findById(required string userId) {
		var q = variables.db.run("SELECT user_id, identity_subject, display_name, email, active, last_sign_in_at FROM [icf].[app_user] WHERE user_id = :id",
			{ "id": variables.db.guid(arguments.userId) });
		return q.recordCount ? rowToUser(q, 1) : {};
	}

	/**
	 * Creates the user row for a new subject. Email uniqueness is enforced by the schema; a
	 * colliding email is stored as NULL rather than failing sign-in (the subject remains the key).
	 */
	public struct function provision(required string subject, required string displayName, string email = "") {
		var id = variables.db.newGuid();
		var emailParam = (len(arguments.email) && !emailInUse(arguments.email))
			? variables.db.nvarchar(arguments.email, 320)
			: { "value": "", "cfsqltype": "cf_sql_nvarchar", "null": true };
		variables.db.run(
			"INSERT INTO [icf].[app_user] (user_id, identity_subject, display_name, email, active) VALUES (:id, :subject, :name, :email, 1)",
			{ "id": variables.db.guid(id), "subject": variables.db.nvarchar(arguments.subject, 255), "name": variables.db.nvarchar(arguments.displayName, 200), "email": emailParam }
		);
		return findById(id);
	}

	public void function recordSignIn(required string userId, required string displayName, string email = "") {
		var params = { "id": variables.db.guid(arguments.userId), "name": variables.db.nvarchar(arguments.displayName, 200) };
		var sql = "UPDATE [icf].[app_user] SET last_sign_in_at = SYSUTCDATETIME(), display_name = :name, updated_at = SYSUTCDATETIME()";
		if (len(arguments.email) && !emailInUse(arguments.email, arguments.userId)) {
			sql &= ", email = :email";
			params["email"] = variables.db.nvarchar(arguments.email, 320);
		}
		variables.db.run(sql & " WHERE user_id = :id", params);
	}

	public void function setActive(required string userId, required boolean active) {
		variables.db.run("UPDATE [icf].[app_user] SET active = :active, updated_at = SYSUTCDATETIME() WHERE user_id = :id",
			{ "id": variables.db.guid(arguments.userId), "active": variables.db.bit(arguments.active) });
	}

	private boolean function emailInUse(required string email, string exceptUserId = "") {
		var params = { "email": variables.db.nvarchar(arguments.email, 320) };
		var sql = "SELECT COUNT(*) AS n FROM [icf].[app_user] WHERE email = :email";
		if (len(arguments.exceptUserId)) { sql &= " AND user_id <> :id"; params["id"] = variables.db.guid(arguments.exceptUserId); }
		return variables.db.scalar(sql, params) > 0;
	}

	private struct function rowToUser(required query q, required numeric r) {
		return {
			"userId": uCase(arguments.q.user_id[arguments.r]),
			"subject": arguments.q.identity_subject[arguments.r],
			"displayName": arguments.q.display_name[arguments.r],
			"email": arguments.q.email[arguments.r],
			"active": (isBoolean(arguments.q.active[arguments.r]) && arguments.q.active[arguments.r]) ? true : false,
			"lastSignInAt": isDate(arguments.q.last_sign_in_at[arguments.r]) ? arguments.q.last_sign_in_at[arguments.r] : ""
		};
	}
}
