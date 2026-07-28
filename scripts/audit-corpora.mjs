#!/usr/bin/env node

import { createHash } from "node:crypto";
import {
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { dirname, join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const scriptPath = fileURLToPath(import.meta.url);
const scriptDir = dirname(scriptPath);
const loomRoot = resolve(scriptDir, "..");
const utilsRoot = resolve(loomRoot, "..", "..");
const tsx = join(utilsRoot, "node_modules", ".bin", "tsx");
const differential = join(loomRoot, "parity", "loom-diff.ts");
const maxBuffer = 1024 * 1024 * 1024;
const supportedFormats = new Set([
  "pi", "claude", "codex", "cursor-agent", "hermes",
  "gais", "google-ai-studio",
]);

function sha256(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

function relativeName(root, path) {
  return relative(root, path).split(sep).join("/");
}

function sourceFiles(root, extension) {
  const files = [];
  const visit = (dir) => {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      if (entry.name.startsWith(".")) continue;
      const path = join(dir, entry.name);
      if (entry.isDirectory()) visit(path);
      else if (entry.isFile() && entry.name.endsWith(extension) &&
          !entry.name.endsWith(".pi.jsonl")) files.push(path);
    }
  };
  visit(root);
  return files.sort((left, right) =>
    relativeName(root, left).localeCompare(relativeName(root, right)));
}

export function inventoryCorpus(rootInput, extension) {
  const root = resolve(rootInput);
  const files = sourceFiles(root, extension).map((path) => {
    const bytes = readFileSync(path);
    return {
      path: relativeName(root, path),
      bytes: bytes.length,
      sha256: sha256(bytes),
    };
  });
  const inventory = files.map((file) =>
    `${file.sha256} ${file.bytes} ${file.path}\n`).join("");
  return {
    root,
    extension,
    fileCount: files.length,
    byteCount: files.reduce((total, file) => total + file.bytes, 0),
    inventorySha256: sha256(inventory),
    files,
  };
}

function parseArgs(args) {
  let loom;
  let out;
  const corpora = [];
  for (let index = 0; index < args.length; index++) {
    if (args[index] === "--loom") loom = args[++index];
    else if (args[index] === "--out") out = args[++index];
    else {
      const separator = args[index].indexOf("=");
      if (separator <= 0) throw new Error(`invalid corpus argument: ${args[index]}`);
      corpora.push({
        format: args[index].slice(0, separator),
        root: args[index].slice(separator + 1),
      });
    }
  }
  if (!loom || !out || corpora.length === 0) {
    throw new Error("usage: audit-corpora.mjs --loom <immutable-loom> --out <new-dir> <format=corpus-dir>...");
  }
  const labels = corpora.map((corpus) => corpus.format);
  if (new Set(labels).size !== labels.length) {
    throw new Error("each corpus format may be supplied only once");
  }
  for (const format of labels) {
    if (!supportedFormats.has(format)) throw new Error(`unsupported corpus format: ${format}`);
  }
  return { loom: resolve(loom), out: resolve(out), corpora };
}

function command(executable, args, options = {}) {
  return spawnSync(executable, args, {
    cwd: utilsRoot,
    encoding: "utf8",
    maxBuffer,
    ...options,
  });
}

function requireImmutableCandidate(path) {
  if (!existsSync(path) || !statSync(path).isFile()) {
    throw new Error(`Loom candidate is not a file: ${path}`);
  }
  const result = command(path, ["version", "--json"]);
  if (result.status !== 0) {
    throw new Error(`Loom version failed (${result.status}): ${result.stderr || result.stdout}`);
  }
  const candidate = JSON.parse(result.stdout);
  if (!/^[0-9a-f]{40}$/.test(candidate.coreRevision ?? "")) {
    throw new Error(`candidate coreRevision is not immutable: ${candidate.coreRevision}`);
  }
  return candidate;
}

function corpusExtension(format) {
  return format === "gais" || format === "google-ai-studio" ? ".json" : ".jsonl";
}

function writeBundleManifest(out) {
  const files = readdirSync(out, { withFileTypes: true })
    .filter((entry) => entry.isFile() && entry.name !== "MANIFEST.sha256")
    .map((entry) => entry.name)
    .sort();
  const lines = files.map((name) =>
    `${sha256(readFileSync(join(out, name)))}  ${name}`);
  writeFileSync(join(out, "MANIFEST.sha256"), `${lines.join("\n")}\n`);
}

async function main() {
  const parsed = parseArgs(process.argv.slice(2));
  if (!existsSync(tsx) || !statSync(tsx).isFile()) {
    throw new Error(`tsx is not available: ${tsx}`);
  }
  const candidate = requireImmutableCandidate(parsed.loom);
  if (existsSync(parsed.out)) throw new Error(`output directory already exists: ${parsed.out}`);
  mkdirSync(dirname(parsed.out), { recursive: true });
  mkdirSync(parsed.out);

  writeFileSync(join(parsed.out, "candidate.json"), `${JSON.stringify(candidate, null, 2)}\n`);

  const gitHead = command("git", ["rev-parse", "HEAD"]);
  const gitStatus = command("git", ["status", "--porcelain"]);
  const run = {
    schema: "agent-convert.corpus-evidence.v1",
    generatedAt: new Date().toISOString(),
    candidateRevision: candidate.coreRevision,
    candidateTargetTriple: candidate.targetTriple,
    validationHarnessRevision: gitHead.status === 0 ? gitHead.stdout.trim() : null,
    validationHarnessDirty: gitStatus.status !== 0 || gitStatus.stdout.trim().length > 0,
    scriptSha256: sha256(readFileSync(scriptPath)),
    differentialProjection: "legacy-ts-parity; compatibility evidence only",
    corpora: [],
  };

  let failed = false;
  for (const corpus of parsed.corpora) {
    const inventory = inventoryCorpus(corpus.root, corpusExtension(corpus.format));
    if (inventory.fileCount === 0) {
      throw new Error(`no ${inventory.extension} inputs in ${inventory.root}`);
    }
    const inventoryName = `${corpus.format}.inputs.json`;
    writeFileSync(join(parsed.out, inventoryName), `${JSON.stringify(inventory, null, 2)}\n`);

    const args = [differential, corpus.format, inventory.root, "--ts-parity"];
    if (corpus.format === "codex") args.push("--allow-ts-errors");
    const result = command(tsx, args, {
      env: {
        ...process.env,
        LOOM_BIN: parsed.loom,
        PI_CONVERT_ENGINE: "ts",
      },
    });
    const logName = `${corpus.format}.differential.log`;
    writeFileSync(join(parsed.out, logName),
      `${result.stdout || ""}${result.stderr ? `\n[stderr]\n${result.stderr}` : ""}`);
    const summary = (result.stdout || "").split("\n")
      .find((line) => line.startsWith("summary:")) ?? null;
    run.corpora.push({
      format: corpus.format,
      root: inventory.root,
      fileCount: inventory.fileCount,
      byteCount: inventory.byteCount,
      inventorySha256: inventory.inventorySha256,
      differentialExit: result.status,
      differentialSummary: summary,
      inventory: inventoryName,
      log: logName,
    });
    if (result.status !== 0) failed = true;
  }

  writeFileSync(join(parsed.out, "run.json"), `${JSON.stringify(run, null, 2)}\n`);
  writeBundleManifest(parsed.out);
  console.log(parsed.out);
  if (failed) process.exitCode = 1;
}

if (resolve(process.argv[1] ?? "") === resolve(scriptPath)) {
  main().catch((error) => {
    console.error(`error: ${error instanceof Error ? error.message : String(error)}`);
    process.exitCode = 2;
  });
}
