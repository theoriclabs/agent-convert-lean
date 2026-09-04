#!/usr/bin/env node
/**
 * loom-mcp — a Model Context Protocol server exposing the `loom` binary as the
 * control plane for agent transcript operations: search, projection,
 * conversion, inspection, detection, and identity.
 *
 * Zero dependencies. Speaks newline-delimited JSON-RPC 2.0 over stdio, the MCP
 * stdio transport. It shells out to the pinned `loom` binary; it never parses
 * transcripts itself, so the Lean core stays the single source of truth.
 *
 * Binary resolution: $LOOM_BIN, else ../.lake/build/bin/loom next to this file,
 * else `loom` on PATH.
 *
 * Register with an MCP client, e.g. Claude Code:
 *   claude mcp add loom -- node /abs/path/to/agent-convert-lean/mcp/loom-mcp.mjs
 */

import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { createInterface } from "node:readline";

const HERE = dirname(fileURLToPath(import.meta.url));
const PROTOCOL_VERSION = "2024-11-05";
const SERVER_INFO = { name: "loom", version: "0.1.0" };

function resolveLoom() {
  if (process.env.LOOM_BIN) return process.env.LOOM_BIN;
  const local = join(HERE, "..", ".lake", "build", "bin", "loom");
  if (existsSync(local)) return local;
  return "loom";
}
const LOOM = resolveLoom();

/** Run loom with argv; resolve to { code, stdout, stderr }. Never rejects. */
function runLoom(args) {
  return new Promise((resolve) => {
    execFile(
      LOOM,
      args,
      { maxBuffer: 256 * 1024 * 1024, encoding: "utf8" },
      (err, stdout, stderr) => {
        resolve({
          code: err && typeof err.code === "number" ? err.code : err ? 1 : 0,
          stdout: stdout ?? "",
          stderr: stderr ?? "",
        });
      },
    );
  });
}

/** Build the loom argv for a tool call and run it. */
async function callLoom(tool, a = {}) {
  const flags = [];
  const opt = (name, val) => {
    if (val !== undefined && val !== null && val !== "") flags.push(name, String(val));
  };
  switch (tool) {
    case "loom_version":
      return runLoom(["version", "--json"]);
    case "loom_search": {
      if (!a.query || !String(a.query).trim()) throw new Error("query is required");
      opt("--store", a.store);
      opt("--role", a.role);
      opt("--cwd", a.cwd);
      opt("--limit", a.limit);
      // Default to JSON so the caller gets structured rows unless it opts out.
      if (a.json !== false) flags.push("--json");
      return runLoom(["search", String(a.query), ...flags]);
    }
    case "loom_text": {
      const inputs = Array.isArray(a.inputs) ? a.inputs : a.input ? [a.input] : [];
      if (inputs.length === 0) throw new Error("inputs (or input) is required");
      return runLoom(["text", ...inputs.map(String)]);
    }
    case "loom_detect": {
      if (!a.input) throw new Error("input is required");
      return runLoom(["detect", String(a.input), "--json"]);
    }
    case "loom_inspect": {
      if (!a.format) throw new Error("format is required");
      if (!a.input) throw new Error("input is required");
      if (a.json !== false) flags.push("--json");
      return runLoom(["inspect", String(a.format), String(a.input), ...flags]);
    }
    case "loom_convert": {
      if (!a.input) throw new Error("input (session id or path) is required");
      if (!a.target) throw new Error("target is required");
      opt("--target-cwd", a.targetCwd);
      opt("--target-provider", a.targetProvider);
      opt("--target-model", a.targetModel);
      opt("--target-session-id", a.targetSessionId);
      opt("--target-timestamp", a.targetTimestamp);
      if (a.json !== false) flags.push("--json");
      const positional = ["convert", String(a.input), String(a.target)];
      if (a.output) positional.push(String(a.output));
      return runLoom([...positional, ...flags]);
    }
    default:
      throw new Error(`unknown tool: ${tool}`);
  }
}

const TOOLS = [
  {
    name: "loom_search",
    description:
      "Search agent transcripts across every local store (codex, claude, pi, cursor-agent, hermes). Case-insensitive AND-of-tokens over the canonical IR projection. Returns JSON rows: {store, file, role, index, snippet}. Scope with store/limit for speed.",
    inputSchema: {
      type: "object",
      properties: {
        query: { type: "string", description: "Whitespace-separated tokens; every token must appear." },
        store: { type: "string", enum: ["codex", "claude", "pi", "cursor-agent", "hermes"], description: "Restrict to one harness." },
        role: { type: "string", enum: ["user", "assistant", "toolResult"], description: "Restrict to one role." },
        cwd: { type: "string", description: "Only sessions whose recorded cwd contains this substring." },
        limit: { type: "integer", description: "Max hits (default 200)." },
        json: { type: "boolean", description: "Structured rows (default true)." },
      },
      required: ["query"],
    },
  },
  {
    name: "loom_text",
    description:
      "Project one or more sessions (by id or path) to JSON search rows: a session header row plus one entry row per IR entry {role, index, ms, iso, tools, text}. Failures are isolated per input.",
    inputSchema: {
      type: "object",
      properties: {
        inputs: { type: "array", items: { type: "string" }, description: "Session ids or file paths." },
        input: { type: "string", description: "A single session id or path (alternative to inputs)." },
      },
    },
  },
  {
    name: "loom_convert",
    description:
      "Convert a session (id or path) to another harness: loom, pi, claude, codex, cursor-agent, opencode. Writes to output if given, else stdout (claude installs when output omitted). Refuses lossy/destructive conversions.",
    inputSchema: {
      type: "object",
      properties: {
        input: { type: "string", description: "Session id or source path." },
        target: { type: "string", enum: ["loom", "pi", "claude", "codex", "cursor-agent", "opencode"] },
        output: { type: "string", description: "Output path (optional)." },
        targetCwd: { type: "string" },
        targetProvider: { type: "string" },
        targetModel: { type: "string" },
        targetSessionId: { type: "string" },
        targetTimestamp: { type: "string" },
        json: { type: "boolean", description: "Emit a JSON result summary (default true)." },
      },
      required: ["input", "target"],
    },
  },
  {
    name: "loom_inspect",
    description: "Human/JSON review of one session: roles, threads, tool calls, losses. Requires the source format.",
    inputSchema: {
      type: "object",
      properties: {
        format: { type: "string", description: "Source format (claude, codex, pi, cursor-agent, hermes, gais, opencode, loom)." },
        input: { type: "string", description: "File path." },
        json: { type: "boolean", description: "JSON (default true)." },
      },
      required: ["format", "input"],
    },
  },
  {
    name: "loom_detect",
    description: "Detect the harness format of a transcript file from its bytes. Returns JSON.",
    inputSchema: {
      type: "object",
      properties: { input: { type: "string", description: "File path." } },
      required: ["input"],
    },
  },
  {
    name: "loom_version",
    description: "Report the loom core identity: engine, engineVersion, coreRevision, protocolVersion, wireSchemas.",
    inputSchema: { type: "object", properties: {} },
  },
];

// --- JSON-RPC plumbing over newline-delimited stdio -------------------------

function send(msg) {
  process.stdout.write(JSON.stringify(msg) + "\n");
}
function ok(id, result) {
  send({ jsonrpc: "2.0", id, result });
}
function fail(id, code, message) {
  send({ jsonrpc: "2.0", id, error: { code, message } });
}

async function handle(msg) {
  const { id, method, params } = msg;
  const isNotification = id === undefined || id === null;
  try {
    switch (method) {
      case "initialize":
        return ok(id, {
          protocolVersion: PROTOCOL_VERSION,
          capabilities: { tools: {} },
          serverInfo: SERVER_INFO,
        });
      case "notifications/initialized":
        return; // notification, no response
      case "ping":
        return ok(id, {});
      case "tools/list":
        return ok(id, { tools: TOOLS });
      case "tools/call": {
        const name = params?.name;
        const args = params?.arguments ?? {};
        let res;
        try {
          res = await callLoom(name, args);
        } catch (e) {
          return ok(id, {
            content: [{ type: "text", text: `error: ${e.message}` }],
            isError: true,
          });
        }
        const body = res.stdout.trim() || res.stderr.trim() || "(no output)";
        const text = res.code === 0 ? body : `exit ${res.code}\n${res.stderr.trim() || body}`;
        return ok(id, { content: [{ type: "text", text }], isError: res.code !== 0 });
      }
      default:
        if (isNotification) return;
        return fail(id, -32601, `method not found: ${method}`);
    }
  } catch (e) {
    if (!isNotification) fail(id, -32603, `internal error: ${e.message}`);
  }
}

let pending = 0;
let closed = false;
const maybeExit = () => {
  if (closed && pending === 0) process.exit(0);
};

const rl = createInterface({ input: process.stdin });
rl.on("line", (line) => {
  const trimmed = line.trim();
  if (!trimmed) return;
  let msg;
  try {
    msg = JSON.parse(trimmed);
  } catch {
    return; // ignore non-JSON lines
  }
  pending += 1;
  Promise.resolve(handle(msg)).finally(() => {
    pending -= 1;
    maybeExit();
  });
});
// Don't kill in-flight tool calls on EOF; drain them, then exit.
rl.on("close", () => {
  closed = true;
  maybeExit();
});
