/**
 * Compares two instrument versions definition by definition (Phase 6, ADM-06).
 *
 * WHAT IT COMPARES. The two versions' compiled snapshots -- the frozen documents walks render from
 * -- not the definition tables. For a PUBLISHED or RETIRED version the snapshot *is* the version,
 * and for a DRAFT it is exactly what publication would freeze. Rows are matched by the stable
 * logical keys every version shares, never by GUID, so "the same item in V1 and V2" means the same
 * itemKey, which is what reporting and walk history also mean by it:
 *
 *   sections              sectionKey
 *   items                 itemKey
 *   responseSets          setKey
 *   responseOptions       setKey/optionKey
 *   rules                 ruleKey
 *   dimensions            code
 *   dimensionValues       dimensionCode/valueCode
 *   instrumentDimensions  dimensionCode
 *
 * Each keyed row is `added`, `removed`, or `changed` with every differing field reported as its
 * exact before and after value. Nothing is summarized away: wording, keys, response options,
 * scores, rules, reportability and review state are all fields, so "compare version keys,
 * wording, response options, rules, and reportability" is the same operation as "compare
 * everything". Structured values (settings, conditions) are compared as canonical JSON, so key
 * order and formatting are never reported as a change.
 *
 * Document-level facts outside the definitions -- the instrument block, the version block, the
 * schema version, the source reference, the behavior and content-review documents -- are reported
 * separately as `metadata`, because they are not keyed rows.
 *
 * Pure: no database, no request scope. The caller supplies two parsed snapshots.
 */
component output="false" {

	variables.COLLECTIONS = [
		{ "name": "sections", "key": ["sectionKey"], "label": "title" },
		{ "name": "items", "key": ["itemKey"], "label": "prompt" },
		{ "name": "responseSets", "key": ["setKey"], "label": "name" },
		{ "name": "responseOptions", "key": ["setKey", "optionKey"], "label": "label" },
		{ "name": "rules", "key": ["ruleKey"], "label": "ruleKey" },
		{ "name": "dimensions", "key": ["code"], "label": "label" },
		{ "name": "dimensionValues", "key": ["dimensionCode", "valueCode"], "label": "label" },
		{ "name": "instrumentDimensions", "key": ["dimensionCode"], "label": "labelOverride" }
	];
	variables.METADATA = [
		["instrument", "code"], ["instrument", "name"], ["instrument", "description"], ["instrument", "active"],
		["version", "versionLabel"], ["version", "reviewStatus"], ["version", "revisionNotes"],
		["version", "extractedOn"], ["version", "sourceFile"], ["version", "sourceSha256"],
		["schemaVersion"], ["source"], ["behavior"], ["contentReview"]
	];

	public InstrumentVersionComparer function init(required any canonicalJson) {
		variables.json = arguments.canonicalJson;
		return this;
	}

	/**
	 * @return {
	 *   identical: boolean,
	 *   summary:   { added, removed, changed, metadata },
	 *   metadata:  [ { field, from, to } ],
	 *   changes:   [ { collection, key, change, label, fields: [ { field, from, to } ] } ]
	 * }
	 */
	public struct function diff(required struct fromSnapshot, required struct toSnapshot) {
		var changes = [];
		var summary = { "added": 0, "removed": 0, "changed": 0, "metadata": 0 };
		var fromDefs = definitionsOf(arguments.fromSnapshot);
		var toDefs = definitionsOf(arguments.toSnapshot);

		for (var spec in variables.COLLECTIONS) {
			var before = keyed(fromDefs, spec);
			var after = keyed(toDefs, spec);
			var keys = unionSorted(structKeyArray(before.rows), structKeyArray(after.rows));
			for (var k in keys) {
				var inFrom = structKeyExists(before.rows, k);
				var inTo = structKeyExists(after.rows, k);
				if (inFrom && !inTo) {
					arrayAppend(changes, { "collection": spec.name, "key": before.keys[k], "change": "removed", "label": labelOf(before.rows[k], spec), "fields": [] });
					summary.removed++;
				} else if (!inFrom && inTo) {
					arrayAppend(changes, { "collection": spec.name, "key": after.keys[k], "change": "added", "label": labelOf(after.rows[k], spec), "fields": [] });
					summary.added++;
				} else {
					var fields = fieldDifferences(before.rows[k], after.rows[k]);
					if (arrayLen(fields)) {
						arrayAppend(changes, { "collection": spec.name, "key": after.keys[k], "change": "changed", "label": labelOf(after.rows[k], spec), "fields": fields });
						summary.changed++;
					}
				}
			}
		}

		var metadata = [];
		for (var path in variables.METADATA) {
			var a = valueAt(arguments.fromSnapshot, path);
			var b = valueAt(arguments.toSnapshot, path);
			if (!same(a, b)) {
				arrayAppend(metadata, { "field": arrayToList(path, "."), "from": a, "to": b });
				summary.metadata++;
			}
		}

		return {
			"identical": arrayLen(changes) == 0 && arrayLen(metadata) == 0,
			"summary": summary,
			"metadata": metadata,
			"changes": changes
		};
	}

	// ---- internals -------------------------------------------------------------------------------

	private struct function definitionsOf(required struct snapshot) {
		if (structKeyExists(arguments.snapshot, "definitions") && isStruct(arguments.snapshot.definitions)) {
			return arguments.snapshot.definitions;
		}
		return {};
	}

	/**
	 * Rows by key. A CFML struct is case-insensitive, and logical keys are exact identifiers, so the
	 * index is built from the key's lower-case form and the exact key is kept beside it; two keys
	 * differing only in case cannot coexist within one version (the schema's unique indexes are
	 * case-insensitive), so this loses nothing.
	 */
	private struct function keyed(required struct defs, required struct spec) {
		var out = { "rows": {}, "keys": {} };
		if (!structKeyExists(arguments.defs, arguments.spec.name) || !isArray(arguments.defs[arguments.spec.name])) return out;
		for (var row in arguments.defs[arguments.spec.name]) {
			if (!isStruct(row)) continue;
			var parts = [];
			for (var f in arguments.spec.key) arrayAppend(parts, structKeyExists(row, f) ? toString(row[f]) : "");
			var exact = arrayToList(parts, "/");
			out.rows[lCase(exact)] = row;
			out.keys[lCase(exact)] = exact;
		}
		return out;
	}

	private array function unionSorted(required array a, required array b) {
		var seen = {};
		var out = [];
		for (var k in arguments.a) if (!structKeyExists(seen, k)) { seen[k] = true; arrayAppend(out, k); }
		for (var k in arguments.b) if (!structKeyExists(seen, k)) { seen[k] = true; arrayAppend(out, k); }
		arraySort(out, "text");
		return out;
	}

	private array function fieldDifferences(required struct a, required struct b) {
		var out = [];
		var names = unionSorted(structKeyArray(arguments.a), structKeyArray(arguments.b));
		for (var name in names) {
			var x = structKeyExists(arguments.a, name) ? arguments.a[name] : javaCast("null", "");
			var y = structKeyExists(arguments.b, name) ? arguments.b[name] : javaCast("null", "");
			if (!same(!structKeyExists(local, "x") ? javaCast("null", "") : x, !structKeyExists(local, "y") ? javaCast("null", "") : y)) {
				arrayAppend(out, { "field": exactName(arguments.a, arguments.b, name), "from": !structKeyExists(local, "x") ? javaCast("null", "") : x, "to": !structKeyExists(local, "y") ? javaCast("null", "") : y });
			}
		}
		return out;
	}

	/** The field name as the document spells it (struct keys come back in the engine's case). */
	private string function exactName(required struct a, required struct b, required string name) {
		for (var k in structKeyArray(arguments.b)) if (compareNoCase(k, arguments.name) == 0) return k;
		for (var k in structKeyArray(arguments.a)) if (compareNoCase(k, arguments.name) == 0) return k;
		return arguments.name;
	}

	/** Canonical equality: type, value and structure, never CFML's coercive `==`. */
	private boolean function same(any a, any b) {
		if (!structKeyExists(arguments, "a") && !structKeyExists(arguments, "b")) return true;
		if (!structKeyExists(arguments, "a") || !structKeyExists(arguments, "b")) return false;
		return compare(variables.json.serialize({ "v": arguments.a }), variables.json.serialize({ "v": arguments.b })) == 0;
	}

	private any function valueAt(required struct doc, required array path) {
		var node = arguments.doc;
		for (var part in arguments.path) {
			if (!structKeyExists(local, "node") || !isStruct(node) || !structKeyExists(node, part)) return javaCast("null", "");
			node = node[part];
		}
		return node;
	}

	private string function labelOf(required struct row, required struct spec) {
		var f = arguments.spec.label;
		if (structKeyExists(arguments.row, f) && isSimpleValue(arguments.row[f]) && len(toString(arguments.row[f]))) return toString(arguments.row[f]);
		var parts = [];
		for (var k in arguments.spec.key) arrayAppend(parts, structKeyExists(arguments.row, k) ? toString(arguments.row[k]) : "");
		return arrayToList(parts, "/");
	}
}
