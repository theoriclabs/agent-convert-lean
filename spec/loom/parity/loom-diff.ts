// S18 cutover harness — the RC2 mechanism for retiring the TS convert-to-pi.
//
// Runs BOTH converters on the same source file and reports where they diverge:
//   - Lean:  `lake exe loom convert <fmt> pi <file>`  (LoomConvert/Main.lean)
//   - TS:    `convert-to-pi <fmt> <file> <out.pi.jsonl>`  (src/convertToPi.ts)
// then projects both pi outputs through the SAME positional `normalize`
// skeleton that parity/capture-parity.ts pins as the cross-parity golden, and
// compares at that level (structural, not byte-level — Loom is deliberately
// richer in representation: ids, signatures, usage, provider all differ).
//
// The contract: TS may only be retired once Lean AGREES on every real session
// (parity -> cutover -> retire). A DIVERGE is a blocker, printed as a
// line-level diff of the two normalize strings so the fault is legible.
//
// Run from utils/:  node_modules/.bin/tsx spec/loom/parity/loom-diff.ts <fmt> <dir> [--ts-parity] [--allow-ts-errors]
// Set LOOM_BIN to exercise an immutable release binary directly. Without it,
// the development fallback is `lake exe loom` from spec/loom.
//   <fmt> in: pi claude codex cursor-agent hermes gais/google-ai-studio
//   <dir>    : a directory of source-format files (claude/codex/... = *.jsonl,
//              google-ai-studio = *.json)
//   --ts-parity : gate at TS-PARITY, not full fidelity. Loom's importers are
//              deliberately richer than TS — they keep `media` (images/
//              attachments) and `unmodeled` blocks that TS silently drops, which
//              makes a handful of real sessions "DIVERGE" purely because Loom
//              kept more (an adjudicated improvement, not a bug). This flag
//              drops only those Loom-richer block kinds (plus Claude's raw
//              `fallback` block if pi export re-emits it verbatim) and exact
//              inert Loom event carriers from BOTH sides' projection. A file
//              that differs from TS only by those adjudicated enrichments then
//              counts as AGREE and the gate flags real regressions only.
//   --allow-ts-errors : do not fail the run when Lean succeeds but the TS
//              converter refuses the same file. This encodes the Codex burn-in
//              criterion where empty TS-side rollouts are acceptable only when
//              Loom still imports them; Lean errors and divergences still fail.

import { spawnSync } from "node:child_process";
import {
  existsSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, relative, resolve } from "node:path";

// tsx runs this as CJS, so __dirname is defined at runtime.
declare const __dirname: string;

// Reuse the exact reader + block extractor the TS toolchain uses everywhere.
// parseSession auto-detects pi/codex/claude/cursor-agent, so it reads BOTH the
// Lean pi output and the TS pi output (both carry an explicit `type:"session"`
// header) and — for the cursor-agent/pi fallback — the raw source too.
import * as sc from "../../../src/pi/sessionCore.ts";
const { parseSession, getBlocks } = sc as {
  parseSession: (file: string) => { header: any; entries: any[] };
  getBlocks: (content: unknown) => Array<{ type: string; text?: string; thinking?: string; name?: string }>;
};

// ---------------------------------------------------------------------------
// normalize — the base projection is inlined from parity/capture-parity.ts:
// positional + synthesis-independent, entries keyed by index / parent index,
// tool calls by name only, no ids, no signatures. The `--ts-parity` variant below
// intentionally narrows only the known Loom-richer block drops so the gate still
// reports any unexpected new block type.
// ---------------------------------------------------------------------------
// `tsParity` mirrors LoomConvert/Parity.lean's `normalizeTsParity`: in that
// mode the intended Loom-richer block kinds project to `null` and are filtered
// out. If a message contains only those richer blocks, the whole projected
// message is dropped and children collapse to the nearest visible ancestor.
// Keep this list narrow: any other fall-through type is reported as its raw tag
// so the gate cannot hide a newly introduced block kind.
const TS_PARITY_DROPPED_BLOCK_TYPES = new Set(["media", "unmodeled", "fallback", "document"]);

function blockTag(
  b: { type: string; text?: string; thinking?: string; name?: string },
  tsParity: boolean,
): string | null {
  if (b.type === "text") return "text:" + (b.text ?? "");
  if (b.type === "thinking") return "think:" + (b.thinking ?? "");
  if (b.type === "toolCall") return "call"; // name dropped: canonicalization is modeling-in-flux (Design.lean)
  if (tsParity && TS_PARITY_DROPPED_BLOCK_TYPES.has(b.type)) return null;
  return b.type;
}

type CarrierProjection = { role: "user" | "assistant" | "toolResult" | null; body: string };

// Foreign assistant calls/results are deliberately inert in Pi output. Decode
// only the exact, versioned carriers emitted by Loom so parity compares their
// logical payload with the legacy TS output without treating them as executable.
// Any malformed or unknown carrier falls through to `event|` and therefore
// remains visible as a divergence.
function exactCarrierProjection(e: any, tsParity: boolean): CarrierProjection | null {
  if (e?.type !== "custom" || e.customType !== "loom.pi.carrier") return null;
  const data = e.data;
  if (data?.version !== 1 || typeof data.kind !== "string" || data.value === null ||
      typeof data.value !== "object" || Array.isArray(data.value)) return null;

  if (data.kind === "assistantMessage") {
    const value = data.value;
    if (value.representation !== "historical-assistant-blocks" ||
        !Array.isArray(value.blocks) || !Array.isArray(value.sourceBlockIndices) ||
        value.blocks.length !== value.sourceBlockIndices.length ||
        !value.sourceBlockIndices.every((index: unknown) =>
          typeof index === "number" && Number.isSafeInteger(index) && index >= 0)) return null;
    const tags: string[] = [];
    for (const block of value.blocks) {
      if (block === null || typeof block !== "object" || Array.isArray(block) ||
          typeof block.kind !== "string") return null;
      if (block.kind === "text" && typeof block.text === "string") {
        tags.push(`text:${block.text}`);
      } else if (block.kind === "thinking" && typeof block.thinking === "string") {
        tags.push(`think:${block.thinking}`);
      } else if (block.kind === "toolCall" && typeof block.name === "string") {
        tags.push("call");
      } else if (block.kind === "unmodeled" && typeof block.label === "string") {
        if (!tsParity) tags.push(`unmodeled:${block.label}`);
      } else {
        return null;
      }
    }
    return { role: "assistant", body: tags.join(";") };
  }

  if (data.kind === "toolResult") {
    const content = data.value.content;
    if (!Array.isArray(content)) return null;
    const tags: string[] = [];
    for (const block of content) {
      if (block === null || typeof block !== "object" || Array.isArray(block) ||
          typeof block.type !== "string") return null;
      const tag = blockTag(block, tsParity);
      if (tag !== null) tags.push(tag);
    }
    return { role: "toolResult", body: tags.join(";") };
  }

  if (data.kind === "historicalPayload" && data.value.kind === "userMsg" &&
      Array.isArray(data.value.blocks)) {
    const tags: string[] = [];
    for (const block of data.value.blocks) {
      if (block === null || typeof block !== "object" || Array.isArray(block) ||
          typeof block.kind !== "string") return null;
      if (block.kind === "text" && typeof block.text === "string") {
        tags.push(`text:${block.text}`);
      } else if (block.kind === "media" && typeof block.mimeType === "string" &&
          typeof block.data === "string") {
        if (!tsParity) tags.push(`media:${block.mimeType}`);
      } else if (block.kind === "unmodeled" && typeof block.label === "string" &&
          block.raw !== null && typeof block.raw === "object") {
        if (!tsParity) tags.push(`unmodeled:${block.label}`);
      } else {
        return null;
      }
    }
    if (tsParity && tags.length === 0) return { role: null, body: "" };
    return { role: "user", body: tags.join(";") };
  }

  // The legacy converters omit source lifecycle/control events entirely.
  // Ignore only Loom's exact inert event carrier in the explicitly requested
  // TS-parity view; full-fidelity gates continue to retain and inspect it.
  if (tsParity && data.kind === "event" &&
      typeof data.value.label === "string" &&
      data.value.raw !== null && typeof data.value.raw === "object" &&
      !Array.isArray(data.value.raw)) {
    return { role: null, body: "" };
  }

  return null;
}

function normalize(header: any, entries: any[], tsParity: boolean): string {
  const byId = new Map<string, any>();
  entries.forEach((e) => {
    if (typeof e.id === "string") byId.set(e.id, e);
  });
  const projected: Array<{ entry: any; role: string; body: string }> = [];
  for (const e of entries) {
    if (e.type === "model_change" && e.loomPi?.targetModelChange?.author === "target") {
      continue;
    }
    const carrier = exactCarrierProjection(e, tsParity);
    if (carrier !== null) {
      if (carrier.role === null) continue;
      if (tsParity && carrier.role === "assistant" && carrier.body === "") continue;
      projected.push({ entry: e, ...carrier });
    } else if (e.type === "message") {
      const blocks = getBlocks(e.message?.content)
        .map((b) => blockTag(b, tsParity))
        .filter((t): t is string => t !== null) // filterMap: a dropped block leaves no empty ";"-segment
        .join(";");
      // In TS-parity mode, a Loom-only media/unmodeled/fallback/document message
      // with no remaining comparable blocks should disappear completely. Leaving
      // it as `role|` shifts every later parent/index and turns an additive Loom
      // enrichment into a fake structural divergence.
      if (tsParity && blocks === "") continue;
      projected.push({ entry: e, role: e.message?.role ?? "?", body: blocks });
    } else if (e.type === "compaction") {
      projected.push({ entry: e, role: "compaction", body: e.summary ?? "" });
    } else {
      projected.push({ entry: e, role: "event", body: "" });
    }
  }
  // id -> projected positional index, so parent refs project to parent index
  // after Loom-richer entries are removed.
  const idx = new Map<string, number>();
  projected.forEach((p, i) => {
    if (typeof p.entry.id === "string") idx.set(p.entry.id, i);
  });
  function parentIndex(e: any): string {
    let parentId = e.parentId;
    const seen = new Set<string>();
    while (typeof parentId === "string" && parentId.length > 0) {
      const visible = idx.get(parentId);
      if (visible !== undefined) return String(visible);
      if (seen.has(parentId)) break;
      seen.add(parentId);
      parentId = byId.get(parentId)?.parentId;
    }
    return "-";
  }
  const lines = ["session"]; // cwd dropped: TS fabricates it, machine-dependent, unpinnable
  projected.forEach((p, i) => {
    lines.push(`${i}|${parentIndex(p.entry)}|${p.role}|${p.body}`);
  });
  return lines.join("\n");
}

// ---------------------------------------------------------------------------
// Layout: this file is <utils>/spec/loom/parity/loom-diff.ts.
//   loomRoot  = <utils>/spec/loom  — lakefile.lean lives here; `lake exe loom`
//               MUST run from here (running from utils/ fails: no lakefile).
//   utilsRoot = <utils>            — convert-to-pi (tsx) runs from here.
// ---------------------------------------------------------------------------
const LOOM_ROOT = resolve(__dirname, "..");
const UTILS_ROOT = resolve(__dirname, "..", "..", "..");
const TSX_BIN = join(UTILS_ROOT, "node_modules", ".bin", "tsx");
const CONVERT_SCRIPT = join(UTILS_ROOT, "src", "convertToPi.ts");
const DIRECT_LOOM_BIN = process.env.LOOM_BIN
  ? resolve(process.env.LOOM_BIN)
  : null;
const MAX_BUFFER = 256 * 1024 * 1024; // 256 MB — real sessions get large.
const PI_TARGET_ARGS = [
  "--target-cwd", "/tmp/agent-convert-loom-diff",
  "--target-provider", "deepseek",
  "--target-model", "deepseek-v4-flash",
  "--target-session-id", "loom-diff-target",
  "--target-timestamp", "2026-07-20T00:00:00.000Z",
  "--target-harness-version", "0.74.0",
  "--pi-assistant-history", "carrier",
];

// loom import format -> convert-to-pi subcommand. Formats absent here have no
// file-based TS subcommand (cursor-agent is parseSession-only; pi is identity),
// so their TS side falls back to parseSession auto-detect on the raw source.
const TS_SUBCOMMAND: Record<string, string> = {
  claude: "claude",
  codex: "codex",
  hermes: "hermes",
  gais: "google-ai-studio",
  "google-ai-studio": "google-ai-studio",
};

// loom import format -> expected source-file extension in <dir>.
function sourceExt(fmt: string): string {
  return fmt === "gais" || fmt === "google-ai-studio" ? ".json" : ".jsonl";
}

function sourceFiles(root: string, ext: string): string[] {
  const files: string[] = [];
  const visit = (dir: string): void => {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      if (entry.name.startsWith(".")) continue;
      const path = join(dir, entry.name);
      if (entry.isDirectory()) visit(path);
      else if (entry.isFile() && entry.name.endsWith(ext) &&
          !entry.name.endsWith(".pi.jsonl")) files.push(path);
    }
  };
  visit(root);
  return files.sort((left, right) =>
    relative(root, left).localeCompare(relative(root, right)));
}

// ---------------------------------------------------------------------------
// Build-noise stripping. `lake exe loom` replays elaboration of the LoomConvert
// modules on first run, emitting `ℹ [n/m] Replayed ...`, `info: file:line: ...`,
// and `warning:` / `Note:` deprecation chatter. Empirically this all lands on
// stderr and the pi JSONL on stdout — but we filter stdout defensively anyway
// so a stray info: line (or a future Lean that mixes streams) can't corrupt the
// parse. A surviving line must (a) not match a known noise prefix and (b) parse
// as a JSON object. That second gate alone removes every non-output line.
// ---------------------------------------------------------------------------
function isBuildNoise(line: string): boolean {
  const t = line.replace(/^\s+/, "");
  // Lean diagnostic prefixes + lake progress glyphs.
  if (/^(info:|warning:|error:|trace:|Note:)/.test(t)) return true;
  if (/^[ℹ⚠✔✖✗●•]/u.test(t)) return true; // ℹ/⚠/✔ progress + bullets
  // Lake progress "[n/m] Replayed Module" — ANCHORED to that exact shape, not a
  // bare `includes("Replayed")`, which also ate legit pi entries whose content
  // mentions "Replayed" (Lean/lake dev sessions). Glyph-prefixed progress lines
  // are already caught above; this catches the rare non-glyph case only.
  if (/^\[\d+\/\d+\]\s+Replayed\b/.test(t)) return true;
  if (/^wrote .+\(\d+ entries\)$/.test(t)) return true; // emit()'s file-write line
  return false;
}

function looksLikeJsonObject(line: string): boolean {
  const t = line.trim();
  if (!t.startsWith("{")) return false;
  try {
    JSON.parse(t);
    return true;
  } catch {
    return false;
  }
}

function stripLeanNoise(stdout: string): string {
  return stdout
    .split("\n")
    .map((l) => l.replace(/\r$/, ""))
    .filter((l) => l.trim().length > 0)
    .filter((l) => !isBuildNoise(l))
    .filter(looksLikeJsonObject)
    .join("\n");
}

// ---------------------------------------------------------------------------
// Per-side producers. Each returns { skeleton } on success or { error } on a
// graceful failure (missing tool, bad file, importer refusal). We never throw
// per file — one bad file must not abort the sweep.
// ---------------------------------------------------------------------------
type Side = { skeleton: string } | { error: string };

// Lean side: run an explicit candidate binary when LOOM_BIN is set, otherwise
// use the source-tree development fallback. Strip noise, re-parse, and project.
function leanSide(fmt: string, absInput: string, scratch: string, tsParity: boolean): Side {
  // In ts-parity mode, pass --ts-parity THROUGH to the loom binary so the Lean
  // side applies the codex.ts convert-path renderer (codexTsParity, D15) — the
  // envelope-unwrap / text-join / developer transforms a JS-side projection drop
  // cannot reproduce. For non-codex formats it is a harmless no-op inside loom.
  const convertArgs = ["convert", fmt, "pi", absInput, ...PI_TARGET_ARGS];
  const executable = DIRECT_LOOM_BIN ?? "lake";
  const leanArgs = DIRECT_LOOM_BIN
    ? convertArgs
    : ["exe", "loom", ...convertArgs];
  if (tsParity) leanArgs.push("--ts-parity");
  const r = spawnSync(executable, leanArgs, {
    cwd: LOOM_ROOT,
    encoding: "utf8",
    maxBuffer: MAX_BUFFER,
  });
  if (r.error) {
    const code = (r.error as NodeJS.ErrnoException).code;
    const label = DIRECT_LOOM_BIN ? `LOOM_BIN '${DIRECT_LOOM_BIN}'` : "`lake`";
    return { error: code === "ENOENT" ? `${label} not found` : `${label} spawn failed: ${r.error.message}` };
  }
  if (r.status !== 0) {
    // import/export errors go to stderr as `import error: ...` / `export error: ...`.
    const msg = (r.stderr || "")
      .split("\n")
      .map((l) => l.trim())
      .find((l) => /error/i.test(l) && !isBuildNoise(l));
    const label = DIRECT_LOOM_BIN ? "loom" : "lake";
    return { error: `${label} exited ${r.status}${msg ? `: ${msg}` : ""}` };
  }
  const pi = stripLeanNoise(r.stdout || "");
  const piFile = join(scratch, "lean.pi.jsonl");
  writeFileSync(piFile, pi + (pi.length ? "\n" : ""));
  try {
    const { header, entries } = parseSession(piFile);
    return { skeleton: normalize(header, entries, tsParity) };
  } catch (e) {
    return { error: `parse of Lean pi output failed: ${e instanceof Error ? e.message : String(e)}` };
  }
}

// TS side: convert-to-pi if the format has a subcommand, else parseSession
// auto-detect on the raw source (cursor-agent / pi). Either path yields pi-shaped
// { header, entries }; we project with the same normalize.
function tsSide(fmt: string, absInput: string, scratch: string, tsParity: boolean): Side & { via: string } {
  const subcmd = TS_SUBCOMMAND[fmt];
  if (!subcmd) {
    // No file-based convert-to-pi subcommand — use the library reader the tool
    // wraps (parseSession auto-detects claude/codex/cursor-agent/pi).
    try {
      const { header, entries } = parseSession(absInput);
      return { skeleton: normalize(header, entries, tsParity), via: "parseSession auto-detect" };
    } catch (e) {
      return { error: `parseSession failed: ${e instanceof Error ? e.message : String(e)}`, via: "parseSession auto-detect" };
    }
  }
  if (!existsSync(TSX_BIN)) return { error: "tsx not found (run npm install in utils/)", via: `convert-to-pi ${subcmd}` };
  const outFile = join(scratch, "ts.pi.jsonl");
  const r = spawnSync(TSX_BIN, [CONVERT_SCRIPT, subcmd, absInput, outFile], {
    cwd: UTILS_ROOT,
    env: { ...process.env, PI_CONVERT_ENGINE: "ts" },
    encoding: "utf8",
    maxBuffer: MAX_BUFFER,
  });
  const via = `convert-to-pi ${subcmd}`;
  if (r.error) return { error: `tsx spawn failed: ${r.error.message}`, via };
  // convert-to-pi prints `Error: ...` and exits non-zero on bad input.
  if (r.status !== 0 || !existsSync(outFile)) {
    const msg = (r.stderr || r.stdout || "").split("\n").map((l) => l.trim()).find((l) => l.startsWith("Error:"));
    return { error: `convert-to-pi exited ${r.status}${msg ? ` (${msg})` : ""}`, via };
  }
  try {
    const { header, entries } = parseSession(outFile);
    return { skeleton: normalize(header, entries, tsParity), via };
  } catch (e) {
    return { error: `parse of TS pi output failed: ${e instanceof Error ? e.message : String(e)}`, via };
  }
}

// ---------------------------------------------------------------------------
// Line-level diff of two normalize strings. Positional walk (the skeletons are
// index-aligned by construction), flagging the lines that differ on each side.
// ---------------------------------------------------------------------------
function printSkeletonDiff(lean: string, ts: string): void {
  const a = lean.split("\n");
  const b = ts.split("\n");
  const n = Math.max(a.length, b.length);
  let shown = 0;
  const CAP = 60; // don't flood on a wholesale mismatch
  for (let i = 0; i < n; i++) {
    const la = a[i];
    const lb = b[i];
    if (la === lb) continue;
    if (shown >= CAP) {
      console.log(`    … (${n - i} more line(s) not shown)`);
      break;
    }
    if (la !== undefined) console.log(`    - lean  L${i}: ${la}`);
    if (lb !== undefined) console.log(`    + ts    L${i}: ${lb}`);
    shown++;
  }
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------
function main(): void {
  const args = process.argv.slice(2);
  // --ts-parity: compare with the TS-parity projection (drop Loom-richer
  // media/unmodeled/fallback/document blocks and exact inert event carriers),
  // so a file that differs from TS only by those enrichments counts as AGREE.
  // Off by default: the plain projection is what the goldens/pins use.
  const tsParity = args.includes("--ts-parity");
  const allowTsErrors = args.includes("--allow-ts-errors");
  const [fmt, dir] = args.filter((a) => !a.startsWith("--"));
  if (!fmt || !dir) {
    console.error("usage: tsx spec/loom/parity/loom-diff.ts <fmt> <dir> [--ts-parity] [--allow-ts-errors]");
    console.error("  <fmt> in: pi claude codex cursor-agent hermes gais/google-ai-studio");
    console.error("  --ts-parity: ignore known Loom-richer blocks and exact inert event carriers (apples-to-apples cutover gate)");
    console.error("  --allow-ts-errors: accept Lean-success/TS-error files, used for Codex empty-rollout burn-in");
    process.exit(2);
  }
  const absDir = resolve(dir);
  if (!existsSync(absDir) || !statSync(absDir).isDirectory()) {
    console.error(`error: not a directory: ${absDir}`);
    process.exit(2);
  }
  if (DIRECT_LOOM_BIN && (!existsSync(DIRECT_LOOM_BIN) ||
      !statSync(DIRECT_LOOM_BIN).isFile())) {
    console.error(`error: LOOM_BIN is not a file: ${DIRECT_LOOM_BIN}`);
    process.exit(2);
  }

  const ext = sourceExt(fmt);
  const files = sourceFiles(absDir, ext);

  if (files.length === 0) {
    console.error(`error: no ${ext} files in ${absDir}`);
    process.exit(2);
  }

  console.log(
    `loom-diff: fmt=${fmt}  dir=${absDir}  (${files.length} file(s))` +
      (tsParity ? "  [ts-parity: known richer blocks and exact inert events ignored]" : "") +
      (DIRECT_LOOM_BIN ? `  [loom=${DIRECT_LOOM_BIN}]` : "  [loom=lake exe]"),
  );
  console.log("");

  const scratch = mkdtempSync(join(tmpdir(), "loom-diff-"));
  let agree = 0;
  let diverge = 0;
  let errored = 0;
  let tsOnlyErrored = 0;

  try {
    for (const absInput of files) {
      const f = relative(absDir, absInput);
      const lean = leanSide(fmt, absInput, scratch, tsParity);
      const ts = tsSide(fmt, absInput, scratch, tsParity);

      if ("error" in lean || "error" in ts) {
        if (allowTsErrors && !("error" in lean) && "error" in ts) {
          tsOnlyErrored++;
          console.log(`TS-ERROR  ${f}`);
          console.log(`    ts  : ${ts.error}  [${ts.via}]`);
          continue;
        }
        errored++;
        console.log(`ERROR  ${f}`);
        if ("error" in lean) console.log(`    lean: ${lean.error}`);
        if ("error" in ts) console.log(`    ts  : ${ts.error}  [${ts.via}]`);
        continue;
      }

      if (lean.skeleton === ts.skeleton) {
        agree++;
        console.log(`AGREE  ${f}  [ts via ${ts.via}]`);
      } else {
        diverge++;
        console.log(`DIVERGE  ${f}  [ts via ${ts.via}]`);
        printSkeletonDiff(lean.skeleton, ts.skeleton);
      }
    }
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }

  console.log("");
  console.log(
    `summary: ${files.length} file(s)  ${agree} agree  ${diverge} diverge` +
      (errored ? `  ${errored} error` : "") +
      (tsOnlyErrored ? `  ${tsOnlyErrored} ts-error` : ""),
  );
  // Non-zero exit when the cutover isn't clean, so CI/gates can key on it.
  process.exit(diverge > 0 || errored > 0 ? 1 : 0);
}

main();
