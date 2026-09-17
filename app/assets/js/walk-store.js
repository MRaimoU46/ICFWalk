/**
 * WalkStore: the boundary between the editor/list UI and walk persistence.
 *
 * Phase 3 ships SessionWalkStore, which keeps walks in page memory only (nothing is written to
 * localStorage or the server; a reload discards them). It exists so the My Walks list and the
 * editor can be exercised and tested end to end against the real instrument model. Phase 4
 * replaces it with an API-backed store (POST/GET/PUT /api/walks, 700 ms debounced autosave,
 * row_version concurrency, idempotent mutation ids) implementing this same interface:
 *
 *   description()            short sentence for the My Walks subtitle
 *   list()                   -> Promise<WalkSummary[]>   newest updated first
 *   create({orgUnitId, orgUnitName, versionId, state}) -> Promise<Walk>
 *   open(id)                 -> Promise<Walk | null>
 *   save(walk)               -> Promise<Walk>   (Phase 4: returns committed rowVersion)
 *   remove(id)               -> Promise<void>   (Phase 4: void with reason / audit)
 *
 * Walk: { id, orgUnitId, orgUnitName, versionId, status, createdAt, updatedAt, state }
 * WalkSummary: { id, orgUnitId, orgUnitName, versionId, status, createdAt, updatedAt, state }
 */
export class SessionWalkStore {
  constructor() {
    this.walks = new Map();
  }
  description() {
    return "Walks in this list are kept in this browser tab only until server saving is enabled.";
  }
  async list() {
    return [...this.walks.values()].map(clone).sort((a, b) => b.updatedAt - a.updatedAt);
  }
  async create({ orgUnitId, orgUnitName, versionId, state }) {
    const now = Date.now();
    const id = `w_${now.toString(36)}${Math.random().toString(36).slice(2, 7)}`;
    const walk = { id, orgUnitId, orgUnitName, versionId, status: "DRAFT", createdAt: now, updatedAt: now, state: clone(state) };
    this.walks.set(id, walk);
    return clone(walk);
  }
  async open(id) {
    const walk = this.walks.get(id);
    return walk ? clone(walk) : null;
  }
  async save(walk) {
    const stored = { ...clone(walk), updatedAt: Date.now() };
    this.walks.set(stored.id, stored);
    return clone(stored);
  }
  async remove(id) {
    this.walks.delete(id);
  }
}

function clone(value) {
  return JSON.parse(JSON.stringify(value));
}
