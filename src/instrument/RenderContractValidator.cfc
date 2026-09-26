/**
 * Proves that a snapshot the semantic rules accepted is one the actual runtime renderer will
 * actually build, completely.
 *
 * WHY A PREFLIGHT AND NOT JUST RULES. DefinitionValidator now carries every rule that corresponds
 * to a way RenderModelBuilder can fail, and those rules are what produce good errors: a stable
 * code, a message naming the offending key, a path an author can find. But a rule set is a
 * *description* of the renderer, maintained by hand, and the defect being corrected here is
 * exactly what happens when such a description drifts from the thing it describes. So publication
 * also runs the renderer itself, on the exact bytes it is about to freeze, and refuses if the real
 * renderer will not build them.
 *
 * TWO FAILURES, NOT ONE. A renderer can fail loudly or quietly, and the quiet one did more damage:
 *
 *   - Loudly: RenderModelBuilder throws ICFWalk.Configuration. Caught here and turned into a
 *     structured issue carrying the builder's own errorcode, so a refusal reads like every other
 *     validation refusal instead of escaping as a runtime 500.
 *   - Quietly: it builds, but the model is missing content the definitions declared -- a second
 *     root whose subtree is dropped, items under a section the tree walk never reaches. Nothing
 *     throws, no checksum moves, and the instrument is simply smaller than it says it is. So the
 *     model is counted: every active section, item and placement in the definitions must appear
 *     in the built model, and a shortfall is a refusal naming what went missing.
 *
 * This component holds no rules of its own and makes no judgements about content. It runs the
 * renderer and reports what the renderer did. That is the point: it cannot drift, because there is
 * nothing in it to drift.
 */
component output="false" {

	public RenderContractValidator function init(required any renderModelBuilder) {
		variables.builder = arguments.renderModelBuilder;
		return this;
	}

	/**
	 * Builds `snapshot` through the real render model builder.
	 *
	 * options.path  root JSON path for reported issues (default "$")
	 *
	 * @return { valid: boolean, errors: [ { code, message, path } ] }
	 */
	public struct function validate(required any snapshot, struct options = {}) {
		var root = structKeyExists(arguments.options, "path") ? arguments.options.path : "$";
		var r = { "valid": true, "errors": [] };
		if (!isStruct(arguments.snapshot) || !structKeyExists(arguments.snapshot, "definitions") || !isStruct(arguments.snapshot.definitions)) {
			// The envelope check reports this properly; there is nothing here to render.
			err(r, "RENDER_MODEL_FAILED", "The snapshot has no definitions object to build a render model from.", root & ".definitions");
			r.valid = false;
			return r;
		}

		var model = "";
		try {
			model = variables.builder.build(arguments.snapshot);
		} catch (any e) {
			// ICFWalk.Configuration carries the builder's own stable code; anything else is reported
			// under one code rather than leaking an engine message as if it were a contract.
			var code = (structKeyExists(e, "errorCode") && len(trim(e.errorCode))) ? trim(e.errorCode) : "RENDER_MODEL_FAILED";
			err(r, code, "The runtime render model could not be built from this snapshot: " & e.message, root & ".definitions");
			r.valid = false;
			return r;
		}

		checkCompleteness(r, arguments.snapshot.definitions, model, root);
		r.valid = arrayLen(r.errors) == 0;
		return r;
	}

	/**
	 * Everything the definitions declare as active must have reached the model. A renderer that
	 * builds a smaller instrument than it was given has rejected content without saying so, and a
	 * publication that froze it would be freezing an instrument nobody can see all of.
	 */
	private void function checkCompleteness(required struct r, required struct d, required struct model, required string root) {
		var declared = { "sections": 0, "items": 0, "placements": 0 };
		for (var s in arguments.d.sections) if (truthy(s, "active")) declared.sections++;
		for (var it in arguments.d.items) if (truthy(it, "active")) declared.items++;
		for (var p in arguments.d.instrumentDimensions) if (truthy(p, "active")) declared.placements++;

		var rendered = { "sections": 0, "items": 0, "placements": 0 };
		walk(arguments.model.root, rendered);

		report(arguments.r, "sections", declared.sections, rendered.sections, arguments.root & ".definitions.sections");
		report(arguments.r, "items", declared.items, rendered.items, arguments.root & ".definitions.items");
		report(arguments.r, "placements", declared.placements, rendered.placements, arguments.root & ".definitions.instrumentDimensions");
	}

	private void function report(required struct r, required string what, required numeric declared, required numeric rendered, required string p) {
		if (arguments.declared == arguments.rendered) return;
		if (arguments.rendered < arguments.declared) {
			err(arguments.r, "RENDER_MODEL_INCOMPLETE", "The runtime render model carries " & arguments.rendered & " of the " & arguments.declared & " active " & arguments.what & " this version declares; " & (arguments.declared - arguments.rendered) & " would be silently missing.", arguments.p);
			return;
		}
		// More rendered than declared would mean the model invented content; impossible today, and
		// worth refusing rather than assuming if it ever became possible.
		err(arguments.r, "RENDER_MODEL_INCOMPLETE", "The runtime render model carries " & arguments.rendered & " " & arguments.what & " but this version declares only " & arguments.declared & " active.", arguments.p);
	}

	private void function walk(required struct node, required struct out) {
		arguments.out.sections++;
		arguments.out.items += arrayLen(arguments.node.items);
		arguments.out.placements += arrayLen(arguments.node.placements);
		for (var child in arguments.node.children) walk(child, arguments.out);
	}

	private boolean function truthy(required any row, required string key) {
		if (!isStruct(arguments.row) || !structKeyExists(arguments.row, arguments.key)) return false;
		var v = arguments.row[arguments.key];
		if (isBoolean(v)) return v ? true : false;
		if (isSimpleValue(v)) {
			var t = lCase(trim(toString(v)));
			return t == "true" || t == "yes" || t == "1";
		}
		return false;
	}

	private void function err(required struct r, required string code, required string message, required string p) {
		arrayAppend(arguments.r.errors, { "code": arguments.code, "message": arguments.message, "path": arguments.p });
	}
}
