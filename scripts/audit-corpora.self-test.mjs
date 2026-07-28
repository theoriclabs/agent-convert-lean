#!/usr/bin/env node

import { createHash } from "node:crypto";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { inventoryCorpus } from "./audit-corpora.mjs";

const root = mkdtempSync(join(tmpdir(), "loom-corpus-audit-self-test-"));

function digest(value) {
  return createHash("sha256").update(value).digest("hex");
}

try {
  mkdirSync(join(root, "nested"));
  mkdirSync(join(root, ".hidden"));
  writeFileSync(join(root, "b.jsonl"), "b\n");
  writeFileSync(join(root, "nested", "a.jsonl"), "a\n");
  writeFileSync(join(root, "nested", "ignored.pi.jsonl"), "generated\n");
  writeFileSync(join(root, ".hidden", "ignored.jsonl"), "hidden\n");
  writeFileSync(join(root, "ignored.json"), "{}\n");

  const inventory = inventoryCorpus(root, ".jsonl");
  const expected = [
    { path: "b.jsonl", bytes: 2, sha256: digest("b\n") },
    { path: "nested/a.jsonl", bytes: 2, sha256: digest("a\n") },
  ];
  if (JSON.stringify(inventory.files) !== JSON.stringify(expected) ||
      inventory.fileCount !== 2 || inventory.byteCount !== 4) {
    throw new Error(`unexpected inventory: ${JSON.stringify(inventory)}`);
  }
  const canonical = expected.map((file) =>
    `${file.sha256} ${file.bytes} ${file.path}\n`).join("");
  if (inventory.inventorySha256 !== digest(canonical)) {
    throw new Error("aggregate inventory digest changed");
  }
  console.log("audit-corpora self-test: recursive inventory and digest passed");
} finally {
  rmSync(root, { recursive: true, force: true });
}
