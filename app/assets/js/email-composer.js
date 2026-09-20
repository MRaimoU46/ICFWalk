/**
 * Part 4 teacher email composer (Phase 5, SUM-06..09).
 *
 * Renders into the email-draft slot the renderer reserves, from the item's own
 * settings.selectableParts: no part label, prompt, or template sentence is written here. The draft
 * itself comes from the shared formatter (summary.js), so what the person sees is what the server
 * would export.
 *
 * Nothing in this module sends mail, and nothing may be added that does. "Copy text" writes to the
 * clipboard; "Open in email app" hands a percent-encoded mailto: URL to the person's own mail
 * client. There is no request, no recipient endpoint, and no server-side delivery anywhere in the
 * application (docs/OPEN_DECISIONS.md; tests/node/no-mail.test.mjs enforces it).
 *
 * Persistence reuses the ordinary walk save path: the document is written into the walk's
 * `email_workflow` response through setResponse + the renderer's commit, so it rides the Phase 4
 * autosave, row-version concurrency, replay, and conflict handling like any other answer. Keys are
 * serialized in the order WalkPayloadValidator.validateEmailDraft canonicalizes them, so a reload
 * compares equal and the conflict panel never reports a phantom unsent edit.
 *
 * Output safety: every stored value reaches the DOM through textContent or .value, never innerHTML,
 * so stored markup stays inert text (SEC-02).
 */
import { emailDraft } from "./summary.js";
import { el } from "./renderer.js";

/** WalkPayloadValidator.MAX_RESPONSE_TEXT: the whole document is one walk_response.text_value. */
const MAX_DOCUMENT_CHARS = 20000;
const COPY = "Copy text";
const COPIED = "Copied!";
const COPIED_MS = 1400;

const TEXT = {
  draft: "Draft email",
  clear: "Clear draft",
  regenerate: "Update draft from checked boxes",
  open: "Open in email app",
  to: "To (teacher’s email — optional)",
  toPlaceholder: "teacher@u46.org",
  subject: "Subject",
  message: "Message",
  note: "Editable — review and personalize before sending. Nothing is sent automatically.",
  copyFailed: "Could not copy automatically — select and copy the text manually.",
  copied: "Draft copied to the clipboard.",
  tooLong: `This draft is too long to save (over ${MAX_DOCUMENT_CHARS.toLocaleString("en-US")} characters). Shorten the message; the text on screen is not saved until you do.`,
  drafted: "Email draft ready to review",
  cleared: "Email draft cleared",
};

const EMPTY = { includedPartKeys: [], drafted: false, to: "", subject: "", body: "" };

/** The stored document, defaulted defensively: an unreadable value must never break the editor. */
export function readEmailDocument(state, itemKey) {
  const raw = (state.responses[itemKey] || {}).textValue;
  if (typeof raw !== "string" || !raw) return { ...EMPTY };
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return { ...EMPTY };
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return { ...EMPTY };
  return {
    includedPartKeys: Array.isArray(parsed.includedPartKeys) ? parsed.includedPartKeys.filter((k) => typeof k === "string") : [],
    drafted: parsed.drafted === true,
    to: typeof parsed.to === "string" ? parsed.to : "",
    subject: typeof parsed.subject === "string" ? parsed.subject : "",
    body: typeof parsed.body === "string" ? parsed.body : "",
  };
}

/**
 * Canonical serialization: the key order WalkPayloadValidator.validateEmailDraft produces, so the
 * string the browser sends is byte-identical to the one the server stores and hands back.
 */
export function serializeEmailDocument(doc) {
  return JSON.stringify({
    body: doc.body,
    drafted: doc.drafted,
    includedPartKeys: doc.includedPartKeys,
    subject: doc.subject,
    to: doc.to,
  });
}

/** SUM-08: the mailto URL is built only from percent-encoded values. */
export function mailtoUrl(doc) {
  const to = encodeURIComponent(doc.to || "");
  const subject = encodeURIComponent(doc.subject || "");
  const body = encodeURIComponent(doc.body || "");
  return `mailto:${to}?subject=${subject}&body=${body}`;
}

export const clipboardText = (doc) => `Subject: ${doc.subject || ""}\n\n${doc.body || ""}`;

let uid = 0;
const nextId = (prefix) => `${prefix}-composer-${++uid}`;

/**
 * Builds the composer once and returns { sync } for the renderer's refresh loop. The DOM is never
 * rebuilt afterwards, so the disabled flags applyEditability sets on a read-only walk survive every
 * refresh.
 */
export function createEmailComposer(slot, item, { model, announce, read, write }) {
  const parts = (item.settings || {}).selectableParts || [];
  const promptId = nextId("email-prompt");
  const toId = nextId("email-to");
  const subjectId = nextId("email-subject");
  const bodyId = nextId("email-body");

  const prompt = el("p", { class: "email-q", id: promptId, text: item.prompt || "" });
  const group = el("div", { class: "email-parts", role: "group", "aria-labelledby": promptId });
  const boxes = new Map();
  for (const part of parts) {
    const input = el("input", { type: "checkbox", "data-part": String(part.key) });
    group.appendChild(el("label", { class: "checkrow" }, [input, el("span", { text: ` ${part.label}` })]));
    boxes.set(String(part.key), input);
  }

  const draftBtn = el("button", { type: "button", class: "btn btn-sm btn-primary email-draft-btn", text: TEXT.draft });
  const clearBtn = el("button", { type: "button", class: "btn btn-sm email-clear-btn", text: TEXT.clear });
  const regenBtn = el("button", { type: "button", class: "btn btn-sm email-regen-btn", text: TEXT.regenerate });
  const copyBtn = el("button", { type: "button", class: "btn btn-sm email-copy-btn", text: COPY });
  const openBtn = el("button", { type: "button", class: "btn btn-sm btn-primary email-open-btn", text: TEXT.open });

  const toInput = el("input", { type: "text", class: "email-to", id: toId, placeholder: TEXT.toPlaceholder });
  const subjectInput = el("input", { type: "text", class: "email-subject", id: subjectId });
  const bodyInput = el("textarea", { class: "email-body", id: bodyId, rows: "10" });
  const status = el("p", { class: "email-status", role: "status", "aria-live": "polite" });

  const box = el("div", { class: "email-box", hidden: true }, [
    el("label", { for: toId, text: TEXT.to }),
    toInput,
    el("label", { for: subjectId, text: TEXT.subject }),
    subjectInput,
    el("label", { for: bodyId, text: TEXT.message }),
    bodyInput,
    el("div", { class: "email-actions" }, [regenBtn, copyBtn, openBtn]),
    status,
    el("p", { class: "muted email-note", text: TEXT.note }),
  ]);

  slot.appendChild(
    el("div", { class: "email-prompt" }, [prompt, group, el("div", { class: "email-actions" }, [draftBtn, clearBtn]), box]),
  );

  // The document the controls currently describe. It is rebuilt from the walk state on every sync,
  // so the walk state stays the single source of truth and this is only a working copy.
  let doc = { ...EMPTY };
  let copiedTimer = null;

  function currentDoc() {
    return {
      includedPartKeys: parts.map((p) => String(p.key)).filter((key) => boxes.get(key).checked),
      drafted: doc.drafted,
      to: toInput.value,
      subject: subjectInput.value,
      body: bodyInput.value,
    };
  }

  /** Persists through the ordinary save path, unless the document would exceed the stored limit. */
  function persist(next) {
    doc = next;
    const text = serializeEmailDocument(next);
    if (text.length > MAX_DOCUMENT_CHARS) {
      status.textContent = TEXT.tooLong;
      return false;
    }
    if (status.textContent === TEXT.tooLong) status.textContent = "";
    write(text);
    return true;
  }

  const persistFromControls = () => persist(currentDoc());

  function applyDoc(next) {
    doc = next;
    for (const [key, input] of boxes) input.checked = next.includedPartKeys.includes(key);
    if (toInput.value !== next.to) toInput.value = next.to;
    if (subjectInput.value !== next.subject) subjectInput.value = next.subject;
    if (bodyInput.value !== next.body) bodyInput.value = next.body;
    box.hidden = !next.drafted;
  }

  function draftNow() {
    const { state, evaluation } = read();
    const includedPartKeys = parts.map((p) => String(p.key)).filter((key) => boxes.get(key).checked);
    const generated = emailDraft(model, state, evaluation, includedPartKeys);
    const next = { includedPartKeys, drafted: true, to: toInput.value, subject: generated.subject, body: generated.body };
    applyDoc(next);
    status.textContent = "";
    persist(next);
    announce(TEXT.drafted);
  }

  function clearNow() {
    // The prototype keeps the recipient and the ticked parts: clearing is about the generated text,
    // not about throwing away what the person chose.
    const next = { includedPartKeys: doc.includedPartKeys, drafted: false, to: toInput.value, subject: "", body: "" };
    applyDoc(next);
    status.textContent = "";
    persist(next);
    announce(TEXT.cleared);
  }

  async function copyNow() {
    const text = clipboardText(currentDoc());
    try {
      await navigator.clipboard.writeText(text);
      copyBtn.textContent = COPIED;
      status.textContent = TEXT.copied;
      if (copiedTimer) clearTimeout(copiedTimer);
      copiedTimer = setTimeout(() => {
        copyBtn.textContent = COPY;
        copiedTimer = null;
      }, COPIED_MS);
    } catch {
      // Phase 3 replaced the prototype's alert() with inline, announced messages (A11Y).
      status.textContent = TEXT.copyFailed;
    }
  }

  function openNow() {
    // Handing the URL to the browser is the whole action: no request is made and the `to` value is
    // percent-encoded, so a CR/LF or a "bcc:" in it is data in a URL and never a mail header.
    window.location.href = mailtoUrl(currentDoc());
  }

  for (const input of boxes.values()) input.addEventListener("change", persistFromControls);
  for (const input of [toInput, subjectInput, bodyInput]) input.addEventListener("input", persistFromControls);
  draftBtn.addEventListener("click", draftNow);
  regenBtn.addEventListener("click", draftNow);
  clearBtn.addEventListener("click", clearNow);
  copyBtn.addEventListener("click", copyNow);
  openBtn.addEventListener("click", openNow);

  return {
    /** Re-reads the stored document so a reload, a conflict reload, or a replay restores it exactly. */
    sync() {
      const { state } = read();
      applyDoc(readEmailDocument(state, item.itemKey));
    },
  };
}
