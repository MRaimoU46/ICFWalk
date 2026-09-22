/**
 * Compiles a normalized instrument contract into the canonical runtime snapshot
 * (icfwalk-instrument-snapshot/1) and its checksums. The full snapshot is stored on
 * icf.instrument_version.compiled_snapshot_json; checksum_sha256 is the SHA-256 of that exact
 * text. The definitions checksum covers only the definition tables and is used to prove that
 * what was persisted in SQL Server round-trips to the imported document.
 *
 * Must stay byte-identical to scripts/lib/snapshot.mjs compileSnapshot.
 */
component output="false" {

	variables.SNAPSHOT_FORMAT = "icfwalk-instrument-snapshot/1";

	/**
	 * The placeholder review status comes from DefinitionValidator, which is the one place that
	 * defines it. The validator re-derives this compiler's counts block to check the stored
	 * snapshot against it, so the two deriving the same number from two copies of the constant
	 * would be a check that cannot fail for the reason it exists.
	 */
	public SnapshotCompiler function init(required any canonicalJson, required any definitionValidator) {
		variables.json = arguments.canonicalJson;
		variables.definitionValidator = arguments.definitionValidator;
		variables.PLACEHOLDER_REVIEW_STATUS = arguments.definitionValidator.placeholderReviewStatus();
		return this;
	}

	public string function snapshotFormat() {
		return variables.SNAPSHOT_FORMAT;
	}

	public string function placeholderReviewStatus() {
		return variables.PLACEHOLDER_REVIEW_STATUS;
	}

	public struct function countDefinitions(required struct definitions) {
		var d = arguments.definitions;
		var placeholders = 0;
		for (var item in d.items) {
			if (structKeyExists(item, "reviewStatus") && !isNull(item.reviewStatus) && item.reviewStatus == variables.PLACEHOLDER_REVIEW_STATUS) placeholders++;
		}
		var counts = {};
		counts["sections"] = arrayLen(d.sections);
		counts["items"] = arrayLen(d.items);
		counts["responseSets"] = arrayLen(d.responseSets);
		counts["responseOptions"] = arrayLen(d.responseOptions);
		counts["rules"] = arrayLen(d.rules);
		counts["dimensions"] = arrayLen(d.dimensions);
		counts["dimensionValues"] = arrayLen(d.dimensionValues);
		counts["instrumentDimensions"] = arrayLen(d.instrumentDimensions);
		counts["placeholders"] = placeholders;
		return counts;
	}

	public struct function compile(required struct normalized) {
		var n = arguments.normalized;
		var counts = countDefinitions(n.definitions);
		var snapshot = {};
		snapshot["snapshotFormat"] = variables.SNAPSHOT_FORMAT;
		putNullable(snapshot, "schemaVersion", n);
		putNullable(snapshot, "source", n);
		putNullable(snapshot, "instrument", n);
		putNullable(snapshot, "version", n);
		snapshot["definitions"] = n.definitions;
		putNullable(snapshot, "behavior", n);
		putNullable(snapshot, "contentReview", n);
		snapshot["counts"] = counts;

		var canonical = variables.json.serialize(snapshot);
		var definitionsCanonical = variables.json.serialize(n.definitions);
		return {
			"snapshot": snapshot,
			"canonicalJson": canonical,
			"checksum": variables.json.sha256(canonical),
			"definitionsCanonicalJson": definitionsCanonical,
			"definitionsChecksum": variables.json.sha256(definitionsCanonical),
			"counts": counts
		};
	}

	public string function definitionsChecksum(required struct definitions) {
		return variables.json.sha256(variables.json.serialize(arguments.definitions));
	}

	/**
	 * Lists placeholder items (unresolved content-review issues) from normalized definitions.
	 */
	public array function placeholders(required struct definitions) {
		var out = [];
		for (var item in arguments.definitions.items) {
			if (structKeyExists(item, "reviewStatus") && !isNull(item.reviewStatus) && item.reviewStatus == variables.PLACEHOLDER_REVIEW_STATUS) {
				arrayAppend(out, {
					"itemKey": item.itemKey,
					"sectionKey": isNull(item.sectionKey) ? javaCast("null", "") : item.sectionKey,
					"sourceLocation": isNull(item.sourceLocation) ? javaCast("null", "") : item.sourceLocation,
					"reviewStatus": item.reviewStatus
				});
			}
		}
		return out;
	}

	private void function putNullable(required struct out, required string key, required struct src) {
		if (structKeyExists(arguments.src, arguments.key) && !isNull(arguments.src[arguments.key])) arguments.out[arguments.key] = arguments.src[arguments.key];
		else arguments.out[arguments.key] = javaCast("null", "");
	}
}
