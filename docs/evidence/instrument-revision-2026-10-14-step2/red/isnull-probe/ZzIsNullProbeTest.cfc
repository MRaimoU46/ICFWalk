/**
 * Instrument revision 2026-10-14, step 2: which forms of isNull() answer true for the text "null" on each
 * engine. Run once from tests/cfml/specs through the maintenance test runner on each engine, then removed;
 * never committed under tests/. It fails on purpose, to report every answer in its message.
 */
component extends="icfwalktests.BaseSpec" output="false" {
	public void function testProbe() {
		var out = [];
		var text = "Null";
		arrayAppend(out, "local=" & isNull(text));
		var s = { "k": "Null" };
		arrayAppend(out, "structMember=" & isNull(s.k));
		arrayAppend(out, "argument=" & probeArg("null"));
		arrayAppend(out, "argumentMember=" & probeArgMember({ "multiple": "null" }));
		var a = ["null"];
		var e = a[1];
		arrayAppend(out, "arrayElementLocal=" & isNull(e));
		var c = "";
		for (c in a) arrayAppend(out, "forInLocal=" & isNull(c));
		var parsed = deserializeJSON('{"t":"Null","codes":["null"]}');
		arrayAppend(out, "parsedMember=" & isNull(parsed.t));
		var pe = parsed.codes[1];
		arrayAppend(out, "parsedElementLocal=" & isNull(pe));
		var q = queryNew("text_value", "varchar", [["Null"]]);
		var cell = q.text_value[1];
		arrayAppend(out, "queryCellLocal=" & isNull(cell));
		arrayAppend(out, "queryCell=" & isNull(q.text_value[1]));
		arrayAppend(out, "literal=" & isNull("null"));
		fail(arrayToList(out, " "));
	}
	private boolean function probeArg(required any x) { return isNull(arguments.x); }
	private boolean function probeArgMember(required struct dim) { return isNull(arguments.dim.multiple); }
}
