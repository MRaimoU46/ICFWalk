/**
 * Minting GLOBAL reporting identity is atomically qualified by the DRAFT that authorizes it.
 *
 * WHAT THESE ROWS ARE. icf.dimension_definition and icf.dimension_value hold the stable ids and
 * codes every version of every instrument points at forever: icf.walk_dimension_value stores a
 * value_id, and reporting groups walks across versions by the code beside it. They are created
 * once, when a code is first seen, and never updated. There is no version column on them, so the
 * only thing that can authorize creating one is the DRAFT it is being created on behalf of.
 *
 * THE DEFECT THIS EXISTS FOR. The two creators called requireDraftVersion() -- a SELECT taking
 * UPDLOCK on the owning instrument_version row -- and then issued an UNCONDITIONAL INSERT. Inside
 * an import that is safe, because the import's transaction holds the lock from the SELECT through
 * the INSERT. But these are public repository methods and they are called directly, outside any
 * transaction, by callers including this suite. Outside a transaction the UPDLOCK lives only for
 * the duration of the SELECT statement, so this sequence is legal:
 *
 *   1. the status SELECT observes DRAFT and releases its lock;
 *   2. a publish takes the row and freezes the version;
 *   3. the INSERT runs anyway, minting permanent global identity on the authority of a version
 *      that is no longer a DRAFT.
 *
 * A lock that is released before the write it is supposed to protect is not a write boundary.
 *
 * THE CORRECTION, AND WHAT IS PROVED HERE. The authority decision now lives INSIDE the minting
 * statement: an INSERT ... SELECT whose source is the owning instrument_version row under
 * UPDLOCK/ROWLOCK, predicated on `status = N'DRAFT'`, with OUTPUT returning the row that was
 * actually inserted. One statement is atomic, so there is no window at all -- the qualification
 * cannot be separated from the write even by a caller who owns no transaction. When the predicate
 * matches nothing, nothing is inserted, OUTPUT returns no row, and the caller gets a typed
 * non-DRAFT refusal rather than a GUID for a row that does not exist.
 *
 * testMintingIdentityIsQualifiedByItsOwnStatement asserts that structure directly, over the real
 * production SQL, because the window it closes is between two statements and cannot be observed
 * from outside without putting a seam into production code -- which this correction must not do.
 * The behavioural cases around it prove the boundary holds from every direction a caller can take.
 */
component extends="icfwalktests.BaseSpec" output="false" {

	public string function skipReason() {
		return schemaPresent() ? "" : "icf schema is not present in datasource '" & variables.c.db.datasourceName() & "'.";
	}

	public void function beforeAll() {
		variables.run = "gid-" & lCase(left(replace(createUUID(), "-", "", "all"), 8));
		variables.instrumentCode = "GIDFIX" & uCase(left(replace(createUUID(), "-", "", "all"), 8));
		variables.db = variables.c.db;
		variables.repo = variables.c.definitionRepository;
		variables.importSvc = variables.c.instrumentImportService;
		variables.publishSvc = variables.c.instrumentPublishService;
		variables.fixtures = new icfwalktests.support.FixtureCleanup(variables.c);
		variables.publisher = variables.fixtures.ensureUser(variables.run & "-publisher", "Global identity fixture publisher");
		variables.minted = [];

		variables.draft = variables.importSvc.importConfig(config(label("draft")));
		variables.published = variables.importSvc.importConfig(config(label("published")));
		variables.publishSvc.publish(variables.published.versionId, variables.publisher);
		variables.retired = variables.importSvc.importConfig(config(label("retired")));
		variables.publishSvc.publish(variables.retired.versionId, variables.publisher);
		retire(variables.retired.versionId);
	}

	public void function afterAll() {
		for (var code in variables.minted) {
			variables.db.run("DELETE FROM [icf].[dimension_value] WHERE dimension_id IN (SELECT dimension_id FROM [icf].[dimension_definition] WHERE code = :code)", { "code": variables.db.nvarchar(code, 100) });
			variables.db.run("DELETE FROM [icf].[dimension_definition] WHERE code = :code", { "code": variables.db.nvarchar(code, 100) });
		}
		variables.fixtures.removeInstrumentsCoded(variables.instrumentCode);
		variables.fixtures.removeUsers(variables.run & "-");
	}

	// ---- the structural property -----------------------------------------------------------------

	/**
	 * The minting statement carries its own DRAFT predicate, and the identity returned is the
	 * identity the database reported inserting.
	 *
	 * This is asserted over the production source because the defect is a gap BETWEEN two
	 * statements: closing it means there is only one statement left, and "there is no second
	 * statement" is a structural fact. Observing the gap from outside would need an interception
	 * point inside DefinitionRepository, which would be a production seam and is exactly what this
	 * correction is forbidden to add.
	 */
	public void function testMintingIdentityIsQualifiedByItsOwnStatement() {
		var source = fileRead(expandPath("/icfwalk/instrument/DefinitionRepository.cfc"), "utf-8");
		for (var method in ["createDimensionIdentity", "createDimensionValueIdentity"]) {
			var body = methodBody(source, method);
			assertTrue(len(body) > 0, "found the source of " & method);
			assertTrue(findNoCase("INSERT INTO", body) > 0, method & " issues an insert");
			assertTrue(
				findNoCase("instrument_version", body) > 0 && findNoCase("UPDLOCK", body) > 0,
				method & " reads the owning version under UPDLOCK in the same statement that inserts"
			);
			assertTrue(
				findNoCase("status = N'DRAFT'", body) > 0,
				method & " carries the owning version's DRAFT predicate in its own DML, so no separate check can go stale before the write"
			);
			assertTrue(
				findNoCase("OUTPUT INSERTED", body) > 0,
				method & " returns the row the database reports inserting, rather than a GUID generated before the attempt"
			);
			assertFalse(
				findNoCase("requireDraftVersion", body) > 0,
				method & " does not rely on a separate status check whose lock is released before the insert"
			);
		}
	}

	// ---- a DRAFT may mint, outside any transaction -----------------------------------------------

	/** Called directly, with no outer transaction, against a DRAFT: both creators write. */
	public void function testBothCreatorsWriteForADraftOutsideAnyTransaction() {
		var dimensionCode = probeCode("dim");
		var dimensionId = variables.repo.createDimensionIdentity(variables.draft.versionId, dimensionRow(dimensionCode));
		assertTrue(variables.db.isGuid(dimensionId), "a DRAFT may mint a dimension identity");
		assertEquals(1, variables.db.scalar(
			"SELECT COUNT(*) AS n FROM [icf].[dimension_definition] WHERE dimension_id = :id AND code = :code",
			{ "id": variables.db.guid(dimensionId), "code": variables.db.nvarchar(dimensionCode, 100) }
		), "and the row the creator reported is the row that exists");

		var valueCode = probeCode("val");
		var valueId = variables.repo.createDimensionValueIdentity(variables.draft.versionId, dimensionId, { "valueCode": valueCode, "label": "Probe value", "active": true });
		assertTrue(variables.db.isGuid(valueId), "and a value identity under it");
		assertEquals(1, variables.db.scalar(
			"SELECT COUNT(*) AS n FROM [icf].[dimension_value] WHERE value_id = :id AND dimension_id = :dim AND value_code = :code",
			{ "id": variables.db.guid(valueId), "dim": variables.db.guid(dimensionId), "code": variables.db.nvarchar(valueCode, 100) }
		), "which is the row the creator reported");
	}

	// ---- a frozen version may not, and leaves nothing behind -------------------------------------

	/** PUBLISHED and RETIRED versions are refused, and nothing anywhere moves. */
	public void function testAFrozenVersionCannotMintIdentityAndNothingMoves() {
		var repo = variables.repo;
		for (var frozen in [variables.published.versionId, variables.retired.versionId]) {
			var status = variables.repo.findVersionById(frozen).status;
			var before = globalState();
			var versionBefore = variables.repo.findVersionById(frozen);
			var dimensionCode = probeCode("frozen");
			var row = dimensionRow(dimensionCode);
			var frozenId = frozen;

			assertThrows(function() { repo.createDimensionIdentity(frozenId, row); }, "ICFWalk.Publish.NotDraft", "INSTRUMENT_VERSION_NOT_DRAFT");
			assertEquals(0, variables.db.scalar(
				"SELECT COUNT(*) AS n FROM [icf].[dimension_definition] WHERE code = :code",
				{ "code": variables.db.nvarchar(dimensionCode, 100) }
			), "a " & status & " version minted no dimension identity");

			var existingDimension = anyDimensionIdOf(frozen);
			var valueCode = probeCode("frozenval");
			assertThrows(
				function() { repo.createDimensionValueIdentity(frozenId, existingDimension, { "valueCode": valueCode, "label": "Frozen probe", "active": true }); },
				"ICFWalk.Publish.NotDraft", "INSTRUMENT_VERSION_NOT_DRAFT"
			);
			assertEquals(0, variables.db.scalar(
				"SELECT COUNT(*) AS n FROM [icf].[dimension_value] WHERE value_code = :code",
				{ "code": variables.db.nvarchar(valueCode, 100) }
			), "a " & status & " version minted no value identity");

			assertExactTextEquals(before, globalState(), "and the global identity tables are byte-identical after both refusals");
			var versionAfter = variables.repo.findVersionById(frozen);
			assertRowVersionEquals(versionBefore.rowVersion, versionAfter.rowVersion, "the frozen version's row did not move");
			assertExactTextEquals(versionBefore.checksum, versionAfter.checksum, "nor its checksum");
			assertExactTextEquals(status, versionAfter.status, "nor its status");
		}
	}

	/** A version that does not exist cannot mint either, and is reported as missing. */
	public void function testAnAbsentVersionCannotMintIdentity() {
		var repo = variables.repo;
		var absent = variables.db.newGuid();
		var dimensionCode = probeCode("absent");
		var row = dimensionRow(dimensionCode);
		var before = globalState();
		assertThrows(function() { repo.createDimensionIdentity(absent, row); }, "ICFWalk.NotFound", "INSTRUMENT_VERSION_NOT_FOUND");
		assertExactTextEquals(before, globalState(), "and nothing was minted");
	}

	// ---- the two serial outcomes against a concurrent publish ------------------------------------

	/**
	 * IDENTITY CREATION WINS. The mint completes while the publish is in flight but before the
	 * publish has taken the version's row lock; the publish then proceeds normally.
	 *
	 * The ordering is forced rather than raced: the mint runs inside the publish's own pre-lock
	 * callback, so the publish provably had not locked the version when the mint ran, and provably
	 * continued afterwards.
	 *
	 * The converse outcome -- publish first, mint refused -- is proved under a real two-sided
	 * barrier in PublishConcurrencyBarrierTest.
	 */
	public void function testWhenTheMintWinsExactlyOneIdentityAppearsAndPublishStillSucceeds() {
		var imported = variables.importSvc.importConfig(config(label("mint-wins")));
		var versionId = imported.versionId;
		var dimensionCode = probeCode("mintwins");
		var globalBefore = globalCounts();

		var interceptor = createObject("component", "icfwalktests.support.InterceptingDefinitionRepository").init(variables.repo);
		var barriered = publishServiceWith(interceptor);
		var repo = variables.repo;
		var row = dimensionRow(dimensionCode);
		var mintedId = "";
		var mintedBeforeLock = false;
		interceptor.armBefore("findVersionByIdForUpdate", function() {
			// The publish has entered its transaction and has NOT yet taken the version's row lock.
			mintedId = repo.createDimensionIdentity(versionId, row);
			mintedBeforeLock = true;
		});

		var published = barriered.publish(versionId, variables.publisher);

		assertTrue(mintedBeforeLock, "the mint ran before the publish took the version's row lock");
		assertTrue(variables.db.isGuid(mintedId), "and succeeded: the version was still a DRAFT when it ran");
		assertEquals(1, variables.db.scalar(
			"SELECT COUNT(*) AS n FROM [icf].[dimension_definition] WHERE code = :code",
			{ "code": variables.db.nvarchar(dimensionCode, 100) }
		), "exactly one identity appeared -- not none, and not a duplicate");
		assertExactTextEquals(mintedId, uCase(variables.db.run(
			"SELECT dimension_id FROM [icf].[dimension_definition] WHERE code = :code",
			{ "code": variables.db.nvarchar(dimensionCode, 100) }
		).dimension_id[1]), "and it is the identity the creator reported");
		assertEquals(globalBefore.dimensions + 1, globalCounts().dimensions, "exactly one global dimension row was added in total");
		assertEquals(globalBefore.values, globalCounts().values, "and no value rows");

		assertExactTextEquals("PUBLISHED", variables.repo.findVersionById(versionId).status, "the publish proceeded afterwards");
		assertExactTextEquals(variables.publisher, variables.repo.findVersionById(versionId).publishedByUserId);
		assertExactTextEquals(published.checksum, variables.repo.findVersionById(versionId).checksum, "on the snapshot the import compiled");
	}

	/** The same, for a value identity. */
	public void function testWhenTheValueMintWinsExactlyOneIdentityAppearsAndPublishStillSucceeds() {
		var imported = variables.importSvc.importConfig(config(label("valmint-wins")));
		var versionId = imported.versionId;
		var dimensionId = anyDimensionIdOf(versionId);
		var valueCode = probeCode("valmintwins");
		var globalBefore = globalCounts();

		var interceptor = createObject("component", "icfwalktests.support.InterceptingDefinitionRepository").init(variables.repo);
		var barriered = publishServiceWith(interceptor);
		var repo = variables.repo;
		var mintedId = "";
		interceptor.armBefore("findVersionByIdForUpdate", function() {
			mintedId = repo.createDimensionValueIdentity(versionId, dimensionId, { "valueCode": valueCode, "label": "Mint wins", "active": true });
		});

		barriered.publish(versionId, variables.publisher);

		assertTrue(variables.db.isGuid(mintedId), "the value mint succeeded while the version was still a DRAFT");
		assertEquals(1, variables.db.scalar(
			"SELECT COUNT(*) AS n FROM [icf].[dimension_value] WHERE value_code = :code",
			{ "code": variables.db.nvarchar(valueCode, 100) }
		), "exactly one value identity appeared");
		assertEquals(globalBefore.values + 1, globalCounts().values, "and exactly one global value row in total");
		assertExactTextEquals("PUBLISHED", variables.repo.findVersionById(versionId).status, "the publish proceeded afterwards");
	}

	// ---- helpers ---------------------------------------------------------------------------------

	/**
	 * The source of one method, from its signature to the start of the next public declaration.
	 * Used only by the structural case above.
	 */
	private string function methodBody(required string source, required string methodName) {
		var start = findNoCase("function " & arguments.methodName & "(", arguments.source);
		if (!start) return "";
		var rest = mid(arguments.source, start, len(arguments.source));
		var next = reFindNoCase("[\r\n]\t(public|private)[ \t]", rest, 2);
		return next > 0 ? left(rest, next) : rest;
	}

	private any function publishServiceWith(required any repository) {
		return createObject("component", "icfwalk.instrument.InstrumentPublishService").init(
			variables.c.config, variables.c.db, variables.c.errors, variables.c.logger,
			arguments.repository, variables.c.auditRepository, variables.c.canonicalJson,
			variables.c.snapshotCompiler, variables.c.definitionValidator, variables.c.renderContractValidator
		);
	}

	private string function probeCode(required string kind) {
		var code = "gid_" & arguments.kind & "_" & lCase(left(replace(createUUID(), "-", "", "all"), 10));
		arrayAppend(variables.minted, code);
		return code;
	}

	private struct function dimensionRow(required string code) {
		return { "code": arguments.code, "label": "Global identity probe", "dataType": "LIST", "reportable": false, "sensitive": false, "settingsJson": "{}", "active": true };
	}

	private string function label(required string suffix) {
		return variables.run & "-" & arguments.suffix;
	}

	private struct function config(required string versionLabel) {
		var cfg = repoJson("config/instrument-config.json");
		cfg.instrument.code = variables.instrumentCode;
		cfg.instrument.version.versionLabel = arguments.versionLabel;
		return cfg;
	}

	private string function anyDimensionIdOf(required string versionId) {
		var q = variables.db.run(
			"SELECT TOP (1) dimension_id FROM [icf].[instrument_dimension] WHERE version_id = :id ORDER BY display_order",
			{ "id": variables.db.guid(arguments.versionId) }
		);
		return uCase(q.dimension_id[1]);
	}

	/** Test-only: a published fixture version cannot be retired by any production method. */
	private void function retire(required string versionId) {
		variables.db.run(
			"UPDATE [icf].[instrument_version] SET status = N'RETIRED' WHERE version_id = :id",
			{ "id": variables.db.guid(arguments.versionId) }
		);
	}

	private struct function globalCounts() {
		return {
			"dimensions": variables.db.scalar("SELECT COUNT(*) AS n FROM [icf].[dimension_definition]"),
			"values": variables.db.scalar("SELECT COUNT(*) AS n FROM [icf].[dimension_value]")
		};
	}

	/**
	 * A fingerprint of both global identity tables: every id, code and the value each carries, so
	 * a refusal is shown to have added, removed and changed nothing rather than merely to have
	 * kept the row count the same.
	 */
	private string function globalState() {
		var q = variables.db.run(
			"SELECT d.dimension_id, d.code, d.label, d.data_type, d.reportable, d.sensitive, d.active
			   FROM [icf].[dimension_definition] d ORDER BY d.code"
		);
		var parts = [];
		for (var r = 1; r <= q.recordCount; r++) {
			arrayAppend(parts, uCase(q.dimension_id[r]) & "|" & q.code[r] & "|" & q.label[r] & "|" & q.data_type[r] & "|" & (q.reportable[r] ? 1 : 0) & "|" & (q.sensitive[r] ? 1 : 0) & "|" & (q.active[r] ? 1 : 0));
		}
		var v = variables.db.run(
			"SELECT value_id, dimension_id, value_code, label, display_order, active FROM [icf].[dimension_value] ORDER BY dimension_id, value_code"
		);
		for (var r = 1; r <= v.recordCount; r++) {
			arrayAppend(parts, uCase(v.value_id[r]) & "|" & uCase(v.dimension_id[r]) & "|" & v.value_code[r] & "|" & v.label[r] & "|" & v.display_order[r] & "|" & (v.active[r] ? 1 : 0));
		}
		return hash(arrayToList(parts, ";"), "SHA-256");
	}
}
