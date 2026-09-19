/**
 * WalkStore: the boundary between the editor/list UI and walk persistence.
 *
 * Phase 4 ships ApiWalkStore, backed by the authenticated /api/walks endpoints (SQL Server
 * persistence, server-side validation against the walk's pinned instrument version, row_version
 * optimistic concurrency, idempotent client mutation ids). Nothing is written to localStorage.
 *
 *   description()                        sentence for the My Walks subtitle
 *   list()                               -> Promise<Walk[]>  newest updated first (own walks)
 *   create({orgUnitId, versionId, state, clientMutationId}) -> Promise<Walk>
 *   open(id)                             -> Promise<Walk | null>
 *   instrument(id)                       -> Promise<{version, policies, model}> pinned render model
 *   save(walk, clientMutationId)         -> Promise<Walk> committed rowVersion, normalized state,
 *                                           server clearing changes; throws ApiError 409
 *                                           STALE_ROW_VERSION on a stale write
 *   complete(walk, clientMutationId)     -> Promise<Walk>; throws ApiError 400 WALK_INCOMPLETE
 *   remove(id, {reason, rowVersion, clientMutationId}) -> Promise<Walk>  voids (never deletes);
 *                                           rowVersion and clientMutationId are required
 *
 * Walk: { id, orgUnitId, orgUnitName, versionId, versionLabel, status, ownerDisplayName, isOwner,
 *         canEdit, createdAt, updatedAt (epoch ms), completedAt, rowVersion, state, states?, changes? }
 */
export class ApiWalkStore {
  constructor(api) {
    this.api = api;
  }
  description() {
    return "Walks are saved to the district server as you work.";
  }
  async list() {
    const res = await this.api.get("/walks");
    return res.walks.map(toWalk);
  }
  async create({ orgUnitId, versionId, state, clientMutationId }) {
    const res = await this.api.post("/walks", { orgUnitId, versionId, clientMutationId: clientMutationId || newId(), dimensions: state.dimensions, responses: state.responses });
    return toWalk(res.walk);
  }
  async open(id) {
    try {
      const res = await this.api.get(`/walks/${encodeURIComponent(id)}`);
      return toWalk(res.walk);
    } catch (e) {
      if (e && e.status === 404) return null;
      throw e;
    }
  }
  async instrument(id) {
    return this.api.get(`/walks/${encodeURIComponent(id)}/instrument`);
  }
  async save(walk, clientMutationId) {
    const res = await this.api.put(`/walks/${encodeURIComponent(walk.id)}`, {
      walkId: walk.id, versionId: walk.versionId, rowVersion: walk.rowVersion, clientMutationId: clientMutationId || newId(),
      changedAt: new Date().toISOString(), dimensions: walk.state.dimensions, responses: walk.state.responses,
    });
    return toWalk(res.walk);
  }
  async complete(walk, clientMutationId) {
    const res = await this.api.post(`/walks/${encodeURIComponent(walk.id)}/complete`, { rowVersion: walk.rowVersion, clientMutationId: clientMutationId || newId() });
    return toWalk(res.walk);
  }
  async remove(id, { reason, rowVersion, clientMutationId } = {}) {
    // rowVersion and clientMutationId are required by the void contract (docs/ENDPOINTS.md); they
    // are always sent so the server can refuse a stale or duplicated void.
    const body = { clientMutationId: clientMutationId || newId(), rowVersion };
    if (reason) body.reason = reason;
    const res = await this.api.post(`/walks/${encodeURIComponent(id)}/void`, body);
    return toWalk(res.walk);
  }
}

export function newId() {
  if (globalThis.crypto && typeof globalThis.crypto.randomUUID === "function") return globalThis.crypto.randomUUID().toUpperCase();
  const bytes = new Uint8Array(16);
  globalThis.crypto.getRandomValues(bytes);
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("").toUpperCase();
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

function toWalk(dto) {
  return {
    id: dto.id,
    orgUnitId: dto.orgUnitId,
    orgUnitName: dto.orgUnitName,
    orgUnitCode: dto.orgUnitCode,
    // Dimension codes the server owns for this walk; the editor renders them read-only.
    lockedDimensions: Array.isArray(dto.lockedDimensions) ? dto.lockedDimensions : [],
    versionId: dto.versionId,
    versionLabel: dto.versionLabel,
    status: dto.status,
    ownerUserId: dto.ownerUserId,
    ownerDisplayName: dto.ownerDisplayName,
    isOwner: Boolean(dto.isOwner),
    canEdit: Boolean(dto.canEdit),
    createdAt: Date.parse(dto.createdAt),
    updatedAt: Date.parse(dto.updatedAt),
    completedAt: dto.completedAt ? Date.parse(dto.completedAt) : null,
    voidedAt: dto.voidedAt ? Date.parse(dto.voidedAt) : null,
    rowVersion: dto.rowVersion,
    revisionCount: dto.revisionCount ?? 0,
    state: { dimensions: (dto.state && dto.state.dimensions) || {}, responses: (dto.state && dto.state.responses) || {} },
    states: dto.states || null,
    changes: dto.changes || [],
    replayed: Boolean(dto.replayed),
    clientMutationId: dto.clientMutationId || null,
  };
}
