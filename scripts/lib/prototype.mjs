// Reads a prototype HTML file (source/*.html) as data: the instrument tables its script declares
// (PART1, PART1_SECTIONS, COMPONENTS, BELONGING_QS, the option lists, META_FIELDS ...) and the few
// facts that live only in its markup.
//
// The prototype wraps its whole application in one IIFE, and everything an instrument document is
// derived from is declared in the "DATA MODEL" part of that function, before "STATE". That part is
// run here on its own in an empty node:vm context -- no require, no process, no DOM -- with an
// epilogue that hands the declarations back. Nothing after the STATE marker (storage, rendering,
// the wire-up that needs a document) is evaluated, and the source file is never edited.
import vm from "node:vm";

const DATA_MODEL_MARKER = "// ---------------- DATA MODEL ----------------";
const STATE_MARKER = "// ---------------- STATE ----------------";

// Declarations the instrument is built from. A name the prototype does not declare comes back
// undefined rather than throwing, so one reader serves every prototype revision.
const DECLARATIONS = [
  "SCALE", "SCALE_NAMES", "PART1", "PART1_SECTIONS", "COMPONENTS", "BELONGING_QS", "SHORT_TITLES",
  "PART_SEQUENCE", "GRADE_OPTIONS", "CONTENT_OPTIONS", "CLASS_TYPE_OPTIONS", "PREK_K_ITEMS",
  "DUAL_LANG_ITEMS", "MAC_PRER_ITEMS", "IGNITE_ITEMS", "AVID_ITEMS", "ESL_ITEMS",
  "CONTENT_AREA_TRIGGERS", "CONTENT_AREA_ITEMS", "SCHOOL_OPTIONS", "VISIT_TIMING_OPTIONS",
  "PERIOD_OPTIONS", "META_FIELDS", "ELEM_GRADES", "MIDDLE_GRADES", "HIGH_GRADES",
];

/** The data-model part of the prototype's script, unwrapped from its IIFE. */
export function dataModelSource(html) {
  const open = html.indexOf("<script>");
  const close = html.lastIndexOf("</script>");
  if (open < 0 || close < 0) throw new Error("The prototype has no inline script.");
  const body = html.slice(open + "<script>".length, close);
  const start = body.indexOf(DATA_MODEL_MARKER);
  const end = body.indexOf(STATE_MARKER);
  if (start < 0 || end < 0 || end < start) throw new Error("The prototype script has no DATA MODEL ... STATE block.");
  return body.slice(start, end);
}

/** The prototype's instrument tables, as plain JSON values (functions are dropped). */
export function readPrototype(html) {
  const epilogue = `\n;__out = { ${DECLARATIONS.map((n) => `${n}: typeof ${n} === "undefined" ? undefined : ${n}`).join(", ")} };\n`;
  const context = vm.createContext({ __out: null });
  vm.runInContext(dataModelSource(html) + epilogue, context, { timeout: 2000 });
  // A JSON round trip leaves the vm's realm behind: plain objects and arrays of this realm.
  const tables = JSON.parse(JSON.stringify(context.__out));
  return { ...tables, markup: markupFacts(html) };
}

/** Facts the instrument takes from the prototype's markup rather than its script. */
function markupFacts(html) {
  const text = (re) => {
    const m = html.match(re);
    return m ? m[1] : null;
  };
  return {
    hasTagField: /id="part1-tag"/.test(html),
    lessonStandardPlaceholder: text(/id="part1-lesson-standard" placeholder="([^"]*)"/),
    brand: text(/<div class="brand">[\s\S]*?<div>([\s\S]*?)<\/div>/),
  };
}

/** The prototype's own value-to-code convention: lower case, every other run of characters "_". */
export function codeOf(label) {
  return String(label).toLowerCase().replace(/[^a-z0-9]+/g, "_").replace(/^_+|_+$/g, "");
}
