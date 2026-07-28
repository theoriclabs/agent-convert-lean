#!/usr/bin/env node

import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const scriptDir = dirname(fileURLToPath(import.meta.url));
const auditScript = join(scriptDir, "audit-codex-claude.mjs");
const scratch = mkdtempSync(join(tmpdir(), "loom-audit-self-test-"));

const callHeader =
  "[Historical tool call from source transcript; not executed by Claude]";
const resultHeader =
  "[Historical tool result from source transcript; not executed by Claude]";
const heuristic = "codexOutputIndicatesError (codexAdapter.ts:75)";
const tinyPng =
  "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2nAAAAABJRU5ErkJggg==";

function jsonl(rows) {
  return `${rows.map((row) => JSON.stringify(row)).join("\n")}\n`;
}

function callCarrier(occurrence, name) {
  return `${callHeader}\n${JSON.stringify({
    carrier: "agent-convert.claude-tool-call.v1",
    id: "duplicate-id",
    name,
    arguments: { command: name },
    reason: "Codex-origin historical lifecycle",
    occurrence,
  })}`;
}

function resultCarrier(occurrence, callOccurrence, output) {
  return resultCarrierContent(occurrence, callOccurrence,
    [{ kind: "text", text: output }]);
}

function resultCarrierContent(occurrence, callOccurrence, content) {
  return `${resultHeader}\n${JSON.stringify({
    carrier: "agent-convert.claude-tool-result.v1",
    occurrence,
    id: "duplicate-id",
    call: {
      kind: "resolved",
      occurrence: callOccurrence,
      rawId: "duplicate-id",
    },
    content,
    error: { kind: "inferred", isError: false, heuristic },
  })}`;
}

function assistantText(text) {
  return { type: "assistant", message: { content: [{ type: "text", text }] } };
}

function userText(text) {
  return { type: "user", message: { content: [{ type: "text", text }] } };
}

const sourceRows = [
  { type: "session_meta", payload: { id: "audit-self-test" } },
  {
    type: "response_item",
    payload: {
      type: "message",
      role: "developer",
      content: [{
        type: "input_text",
        text: "Keep Alpha Release Credentials Outside Every Conversation",
      }],
    },
  },
  {
    type: "response_item",
    payload: {
      type: "message",
      role: "user",
      content: [{
        type: "input_text",
        text: "<environment_context>\n<cwd>/private/audit</cwd>\n</environment_context>",
      }],
    },
  },
  {
    type: "response_item",
    payload: {
      type: "function_call",
      call_id: "duplicate-id",
      name: "first-call",
      arguments: JSON.stringify({ command: "first-call" }),
    },
  },
  {
    type: "response_item",
    payload: {
      type: "function_call_output",
      call_id: "duplicate-id",
      output: "first-result",
    },
  },
  {
    type: "response_item",
    payload: {
      type: "function_call",
      call_id: "duplicate-id",
      name: "second-call",
      arguments: JSON.stringify({ command: "second-call" }),
    },
  },
  {
    type: "response_item",
    payload: {
      type: "function_call_output",
      call_id: "duplicate-id",
      output: "second-result",
    },
  },
];

const validTarget = [
  assistantText(callCarrier("0:0", "first-call")),
  userText(resultCarrier("1:0", "0:0", "first-result")),
  assistantText(callCarrier("2:0", "second-call")),
  userText(resultCarrier("3:0", "2:0", "second-result")),
];

function run(name, targetRows, shouldPass, expectedFailure = "", inputRows = sourceRows) {
  const currentSourcePath = join(scratch, `${name}.codex.jsonl`);
  const targetPath = join(scratch, `${name}.claude.jsonl`);
  writeFileSync(currentSourcePath, jsonl(inputRows));
  writeFileSync(targetPath, jsonl(targetRows));
  const result = spawnSync(process.execPath, [auditScript, currentSourcePath, targetPath], {
    encoding: "utf8",
  });
  if (shouldPass && result.status !== 0) {
    throw new Error(`${name} unexpectedly failed:\n${result.stderr}`);
  }
  if (!shouldPass && result.status === 0) {
    throw new Error(`${name} mutation unexpectedly passed:\n${result.stdout}`);
  }
  if (!shouldPass && expectedFailure && !result.stderr.includes(expectedFailure)) {
    throw new Error(
      `${name} failed for the wrong reason; expected '${expectedFailure}':\n${result.stderr}`,
    );
  }
}

try {
  run("valid", validTarget, true);

  const imageSource = structuredClone(sourceRows);
  imageSource[4].payload.output = [{ type: "input_image", image_url: tinyPng }];
  const imageTarget = structuredClone(validTarget);
  imageTarget[1].message.content[0].text = resultCarrierContent(
    "1:0", "0:0", [{ kind: "media", mimeType: "image", locator: tinyPng }]);
  run("exact-image-locator", imageTarget, true, "", imageSource);

  const collapsedImage = structuredClone(imageTarget);
  collapsedImage[1].message.content[0].text = resultCarrierContent(
    "1:0", "0:0", [{ kind: "media", mimeType: "image", locator: "input_image" }]);
  run("collapsed-image-locator", collapsedImage, false,
    "id/content/error provenance mismatch", imageSource);

  const malformedImageSource = structuredClone(imageSource);
  delete malformedImageSource[4].payload.output[0].image_url;
  run("malformed-image-source", imageTarget, false,
    "malformed recognized Codex input_image", malformedImageSource);

  const carrierContainsControl = structuredClone(sourceRows);
  carrierContainsControl[1].payload.content[0].text = "first-result";
  run("typed-carrier-control-content", validTarget, true, "", carrierContainsControl);

  const swapped = structuredClone(validTarget);
  [swapped[1], swapped[2]] = [swapped[2], swapped[1]];
  run("swapped-result-and-call", swapped, false, "ordered lifecycle kind mismatch");

  const redirected = structuredClone(validTarget);
  const redirectedText = redirected[1].message.content[0].text;
  const [header, encoded] = redirectedText.split("\n", 2);
  const carrier = JSON.parse(encoded);
  carrier.call.occurrence = "2:0";
  redirected[1].message.content[0].text = `${header}\n${JSON.stringify(carrier)}`;
  run("redirected-duplicate-result", redirected, false,
    "independently derived occurrence linkage");

  const leaked = structuredClone(validTarget);
  leaked.push(userText("  ALPHA   release credentials OUTSIDE  "));
  run("normalized-partial-policy-leak", leaked, false,
    "normalized, or partial control-plane");

  const malformedSource = structuredClone(sourceRows);
  delete malformedSource[3].payload.arguments;
  run("malformed-recognized-source", validTarget, false,
    "malformed recognized Codex function_call", malformedSource);

  const validOutput = readFileSync(join(scratch, "valid.claude.jsonl"), "utf8");
  if (!validOutput.includes("agent-convert.claude-tool-result.v1")) {
    throw new Error("self-test fixture was not written completely");
  }
  console.log("audit-codex-claude self-test: 3 valid fixtures passed; 6 mutations rejected");
} finally {
  rmSync(scratch, { recursive: true, force: true });
}
