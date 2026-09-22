/**
 * A two-sided, observable barrier for the deterministic concurrency specs.
 *
 * WHY IT EXISTS. The earlier barrier specs started a competing transaction B, joined it with a
 * bounded wait, and treated "B has not completed" as proof that B had reached the competing row
 * lock. That is an inference, not an observation: a scheduler delay, a datasource-pool wait, or
 * setup work inside B produces exactly the same reading, and so does an implementation whose lock
 * does nothing on a run where B simply started late.
 *
 * So both sides now SAY where they are, and the spec waits for what they said:
 *
 *   A_LOCKED                    emitted by transaction A once it holds the production lock and has
 *                               done nothing else.
 *   B_AT_COMPETING_BOUNDARY     emitted by B immediately at the database call that will contend for
 *                               that same lock, before the call is made.
 *
 * A is released by the spec, after it has observed both signals -- never by elapsed time. The
 * bounded timeouts below are safety ceilings that turn a hang into a failure; they are never the
 * evidence that an interleaving happened. `observed()` and `sequence()` are that evidence, and a
 * spec asserts on them.
 *
 * IMPLEMENTATION. Signals are held in java.util.concurrent structures rather than CFML scopes,
 * because the two participants are different threads with different request contexts and the
 * signal has to cross that boundary as shared mutable state. `await` is a real blocking poll on a
 * LinkedBlockingQueue: no CFML sleep is involved, so a spec never confuses "we waited a while"
 * with "the other side arrived".
 *
 * TEST-ONLY. This component lives under tests/cfml, which only the CFML test runner maps. Nothing
 * in src/ references it, the application container never holds it, and no route reaches it.
 */
component output="false" {

	public ConcurrencyBarrier function init() {
		variables.queues = createObject("java", "java.util.concurrent.ConcurrentHashMap").init();
		variables.counts = createObject("java", "java.util.concurrent.ConcurrentHashMap").init();
		variables.order = createObject("java", "java.util.concurrent.CopyOnWriteArrayList").init();
		variables.millis = createObject("java", "java.util.concurrent.TimeUnit").MILLISECONDS;
		return this;
	}

	/** Records that the named point was reached, and releases anyone waiting for it. */
	public void function signal(required string name) {
		variables.order.add(arguments.name);
		var seen = variables.counts.get(arguments.name);
		variables.counts.put(arguments.name, javaCast("int", (isNull(seen) ? 0 : seen) + 1));
		queueFor(arguments.name).put(arguments.name);
	}

	/** signal(), but only the first time. Used where two arming points cover one logical boundary. */
	public void function signalOnce(required string name) {
		if (observed(arguments.name)) return;
		signal(arguments.name);
	}

	/**
	 * Blocks until the named point is reached, or the ceiling expires. Returns true only when the
	 * signal really arrived. A false return means the other side never got there, which is a test
	 * failure and never a reason to carry on.
	 */
	public boolean function await(required string name, numeric timeoutMs = 30000) {
		var taken = queueFor(arguments.name).poll(javaCast("long", arguments.timeoutMs), variables.millis);
		return !isNull(taken);
	}

	/** Whether the named point was ever reached. This, not a timeout, is a spec's evidence. */
	public boolean function observed(required string name) {
		var seen = variables.counts.get(arguments.name);
		return !isNull(seen) && seen > 0;
	}

	public numeric function count(required string name) {
		var seen = variables.counts.get(arguments.name);
		return isNull(seen) ? 0 : seen;
	}

	/** Every signal in the order it was emitted, so a spec can assert A really did get there first. */
	public array function sequence() {
		var out = [];
		var raw = variables.order.toArray();
		for (var i = 1; i <= arrayLen(raw); i++) arrayAppend(out, raw[i]);
		return out;
	}

	/** True when `first` was signalled and `second` was signalled strictly after it. */
	public boolean function signalledInOrder(required string first, required string second) {
		var seq = sequence();
		var firstAt = 0;
		for (var i = 1; i <= arrayLen(seq); i++) {
			if (firstAt == 0 && compare(seq[i], arguments.first) == 0) { firstAt = i; continue; }
			if (firstAt > 0 && compare(seq[i], arguments.second) == 0) return true;
		}
		return false;
	}

	private any function queueFor(required string name) {
		var q = variables.queues.get(arguments.name);
		if (!isNull(q)) return q;
		var created = createObject("java", "java.util.concurrent.LinkedBlockingQueue").init();
		var prior = variables.queues.putIfAbsent(arguments.name, created);
		return isNull(prior) ? created : prior;
	}
}
