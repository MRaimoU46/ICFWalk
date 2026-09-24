/**
 * A request body for the read-bound spec (P6A-R01): a real java.io.ByteArrayInputStream holding the
 * body, behind a recorder of every read the production loop asks for.
 *
 * `read(buffer, offset, length)` is the InputStream call the loop makes. It is passed straight to the
 * ByteArrayInputStream, which -- like a chunked body that has fully arrived -- returns as many bytes
 * as are asked for while any remain: the worst case for a bound, because nothing but the size the
 * loop asks for limits what one read consumes. `maxPerRead` (optional) instead returns at most that
 * many bytes per read, as a network stream returns only what has arrived so far.
 *
 * consumed() is exact: the body's size minus ByteArrayInputStream.available(), i.e. the bytes the
 * production loop actually took from the stream. reads() lists every read: what it asked for, what it
 * got, and how many bytes had been delivered before it.
 *
 * TEST-ONLY. Lives under tests/cfml; nothing in src/ references it.
 */
component output="false" {

	public RecordingInputStream function init(required any bytes, numeric maxPerRead = 0) {
		variables.size = createObject("java", "java.lang.reflect.Array").getLength(arguments.bytes);
		variables.inner = createObject("java", "java.io.ByteArrayInputStream").init(arguments.bytes);
		variables.cap = arguments.maxPerRead;
		variables.log = [];
		variables.delivered = 0;
		return this;
	}

	/** InputStream.read(byte[], int, int), exactly as the production loop calls it. */
	public numeric function read(required any buffer, required numeric offset, required numeric length) {
		var ask = arguments.length;
		if (variables.cap > 0 && ask > variables.cap) ask = variables.cap;
		var n = variables.inner.read(arguments.buffer, javaCast("int", arguments.offset), javaCast("int", ask));
		arrayAppend(variables.log, { "requested": arguments.length, "returned": n, "before": variables.delivered });
		if (n > 0) variables.delivered += n;
		return n;
	}

	/** Bytes the reader took from the stream. */
	public numeric function consumed() { return variables.size - variables.inner.available(); }

	public numeric function size() { return variables.size; }

	public array function reads() { return duplicate(variables.log); }
}
