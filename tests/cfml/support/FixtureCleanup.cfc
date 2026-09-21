/**
 * Test-only removal of instrument version fixtures, whatever status they reached.
 *
 * WHY THIS IS NOT IN THE REPOSITORY. DefinitionRepository has no unchecked deletion path any more:
 * every mutator there locks the owning version, refuses anything that is not a DRAFT, and carries
 * `status = N'DRAFT'` in its own DML besides. That is the point of ADM-05, and a
 * "deleteVersionCascadeUnchecked" sitting beside those methods -- reachable by construction from
 * any application code that can reach the repository -- would have undone it for the convenience
 * of test fixtures.
 *
 * So the convenience lives here instead. This component is under tests/cfml, which the application
 * maps as /icfwalktests and only the CFML test runner instantiates; no controller, service or
 * repository references it, and no HTTP route reaches it. Specs that publish a fixture version --
 * which they must, to prove that a published version cannot be written to -- use it in afterAll to
 * take those fixtures back out.
 *
 * It is deliberately blunt: it deletes by version id, with no status predicate, because that is
 * exactly the capability production must not have and a fixture teardown must.
 */
component output="false" {

	public FixtureCleanup function init(required struct container) {
		variables.c = arguments.container;
		variables.db = arguments.container.db;
		return this;
	}

	/**
	 * Removes every instrument version whose label starts with the given prefix, and everything it
	 * owns, regardless of status. Returns the number of versions removed.
	 */
	public numeric function removeVersionsLabelled(required string labelPrefix) {
		var q = variables.db.run(
			"SELECT version_id FROM [icf].[instrument_version] WHERE version_label LIKE :prefix",
			{ "prefix": { "value": arguments.labelPrefix & "%", "cfsqltype": "cf_sql_nvarchar" } }
		);
		var removed = 0;
		for (var r = 1; r <= q.recordCount; r++) {
			removeVersion(uCase(q.version_id[r]));
			removed++;
		}
		return removed;
	}

	/** Removes one instrument version and every definition it owns, regardless of status. */
	public void function removeVersion(required string versionId) {
		var p = { "id": variables.db.guid(arguments.versionId) };
		variables.db.run("DELETE FROM [icf].[instrument_dimension_value] WHERE version_id = :id", p);
		variables.db.run("DELETE FROM [icf].[instrument_dimension] WHERE version_id = :id", p);
		variables.db.run("DELETE FROM [icf].[item_definition] WHERE version_id = :id", p);
		variables.db.run("DELETE FROM [icf].[rule_definition] WHERE version_id = :id", p);
		variables.db.run("DELETE o FROM [icf].[response_option] o JOIN [icf].[response_set] s ON s.response_set_id = o.response_set_id WHERE s.version_id = :id", p);
		variables.db.run("DELETE FROM [icf].[response_set] WHERE version_id = :id", p);
		// Sections are a tree with a self-referencing foreign key, so they come out leaves first.
		// Specs that build a deliberately broken hierarchy leave cycles behind, and a cycle has no
		// leaves at all -- so when a pass removes nothing and rows remain, one section is detached
		// (at an order no sibling can already hold) to break the cycle, and the loop continues.
		for (var pass = 1; pass <= 40; pass++) {
			var before = sectionCount(arguments.versionId);
			if (before == 0) break;
			variables.db.run(
				"DELETE FROM [icf].[section_definition]
				  WHERE version_id = :id
				    AND section_id NOT IN (SELECT parent_section_id FROM [icf].[section_definition] WHERE parent_section_id IS NOT NULL)",
				p
			);
			if (sectionCount(arguments.versionId) == before) {
				variables.db.run(
					"UPDATE TOP (1) [icf].[section_definition] SET parent_section_id = NULL, display_order = :order
					  WHERE version_id = :id AND parent_section_id IS NOT NULL",
					{ "id": variables.db.guid(arguments.versionId), "order": variables.db.integer(2000000 + pass) }
				);
			}
		}
		variables.db.run("DELETE FROM [icf].[audit_event] WHERE entity_type = N'INSTRUMENT_VERSION' AND entity_id = :id", p);
		variables.db.run("DELETE FROM [icf].[instrument_version] WHERE version_id = :id", p);
	}

	private numeric function sectionCount(required string versionId) {
		return variables.db.scalar("SELECT COUNT(*) AS n FROM [icf].[section_definition] WHERE version_id = :id", { "id": variables.db.guid(arguments.versionId) });
	}

	/** Removes fixture instruments (and their versions) whose code starts with the given prefix. */
	public void function removeInstrumentsCoded(required string codePrefix) {
		var q = variables.db.run(
			"SELECT v.version_id FROM [icf].[instrument_version] v JOIN [icf].[instrument] i ON i.instrument_id = v.instrument_id WHERE i.code LIKE :prefix",
			{ "prefix": { "value": arguments.codePrefix & "%", "cfsqltype": "cf_sql_nvarchar" } }
		);
		for (var r = 1; r <= q.recordCount; r++) removeVersion(uCase(q.version_id[r]));
		variables.db.run("DELETE FROM [icf].[instrument] WHERE code LIKE :prefix", { "prefix": { "value": arguments.codePrefix & "%", "cfsqltype": "cf_sql_nvarchar" } });
	}

	/** Creates (or reuses) a fixture application user and returns its user id. */
	public string function ensureUser(required string subject, string displayName = "") {
		var existing = variables.c.userRepository.findBySubject(arguments.subject);
		if (!structIsEmpty(existing)) return existing.userId;
		var name = len(trim(arguments.displayName)) ? arguments.displayName : arguments.subject;
		return variables.c.userRepository.provision(arguments.subject, name, "").userId;
	}

	/** Removes fixture application users whose identity subject starts with the given prefix. */
	public void function removeUsers(required string subjectPrefix) {
		var like = { "value": arguments.subjectPrefix & "%", "cfsqltype": "cf_sql_nvarchar" };
		variables.db.run("UPDATE [icf].[instrument_version] SET created_by_user_id = NULL WHERE created_by_user_id IN (SELECT user_id FROM [icf].[app_user] WHERE identity_subject LIKE :like)", { "like": like });
		variables.db.run("DELETE a FROM [icf].[audit_event] a JOIN [icf].[app_user] u ON u.user_id = a.actor_user_id WHERE u.identity_subject LIKE :like", { "like": like });
		variables.db.run("DELETE s FROM [icf].[user_role_scope] s JOIN [icf].[app_user] u ON u.user_id = s.user_id WHERE u.identity_subject LIKE :like", { "like": like });
		variables.db.run("DELETE FROM [icf].[app_user] WHERE identity_subject LIKE :like", { "like": like });
	}
}
