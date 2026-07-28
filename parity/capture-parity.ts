// S9 parity capture: run the TS toolchain (parseSession, which auto-detects
// pi/claude/codex/cursor-agent and adapts to pi-shaped {header, entries}) on
// each fixture under parity/fixtures/, and emit the SAME positional `normalize`
// projection LoomConvert.Parity uses. Output is pinned as a cross-parity golden
// (decide-checked against each Lean importer).
//
// Positional + synthesis-independent: entries keyed by index / parent index,
// tool calls by name only, no ids, no signatures — so the gate is comparable
// across formats regardless of each side's id synthesis.
//
// Run via host tsx against this checkout: tsx parity/capture-parity.ts
import * as sc from "../../../src/pi/sessionCore.ts";
const { parseSession, getBlocks } = sc as {
  parseSession: (file: string) => { header: any; entries: any[] };
  getBlocks: (content: unknown) => Array<{ type: string; text?: string; thinking?: string; name?: string }>;
};
import { readdirSync } from "node:fs";
import { join } from "node:path";

// tsx runs this as CJS, so __dirname is defined at runtime.
declare const __dirname: string;
const FIXDIR = join(__dirname, "fixtures");

function blockTag(b: { type: string; text?: string; thinking?: string; name?: string }): string {
  if (b.type === "text") return "text:" + (b.text ?? "");
  if (b.type === "thinking") return "think:" + (b.thinking ?? "");
  if (b.type === "toolCall") return "call"; // name dropped: canonicalization is modeling-in-flux (Design.lean)
  return b.type;
}

function normalize(header: any, entries: any[]): string {
  // id -> positional index, so parent refs project to parent index.
  const idx = new Map<string, number>();
  entries.forEach((e, i) => idx.set(e.id, i));
  const lines = ["session"]; // cwd dropped: TS fabricates it, machine-dependent, unpinnable
  entries.forEach((e, i) => {
    const par = e.parentId != null && idx.has(e.parentId) ? String(idx.get(e.parentId)) : "-";
    if (e.type === "message") {
      const blocks = getBlocks(e.message?.content).map(blockTag).join(";");
      lines.push(`${i}|${par}|${e.message?.role ?? "?"}|${blocks}`);
    } else if (e.type === "compaction") {
      lines.push(`${i}|${par}|compaction|${e.summary ?? ""}`);
    } else {
      lines.push(`${i}|${par}|event|`);
    }
  });
  return lines.join("\n");
}

const files = readdirSync(FIXDIR).filter((f) => f.endsWith(".jsonl")).sort();
for (const f of files) {
  const { header, entries } = parseSession(join(FIXDIR, f));
  const name = f.replace(/\.jsonl$/, "");
  console.log("=== " + name + " ===");
  console.log(normalize(header, entries));
  console.log("=== end " + name + " ===");
}
