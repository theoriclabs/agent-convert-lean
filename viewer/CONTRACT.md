# Loom viewer: the contract between the server and the browser

Both sides are built from the Lean domain in `Viewer/` (read `Viewer/Harness.lean`,
`Viewer/Session.lean`, `Viewer/Conversation.lean`, `Viewer/Wire.lean`, `Viewer/UI.lean` first).
This file fixes what crosses the wire and where files live, so the two halves can be built apart.

## HTTP (server: `Viewer/Server.lean` + `Main.lean`, exe `loom_viewer`)

LeanAPI's raw router (`LeanApi.Route.get template (handler : Req → IO Res)`, `Router.build!`,
`Service.ofRouter router (Stack.of [accessLog, recover])`, `serve svc { host, port }`); the
typed `api!` layer is pure by construction and cannot read files, so it is not used here.
Templates spell parameters `{name}`; `req.param? "name"`, `req.query? "name"`.

| Route | Answer |
| --- | --- |
| `GET /api/health` | `{"ok":true}` |
| `GET /api/sessions?harness=<slug>&q=<text>&offset=<n>&limit=<n>` | `{"sessions":[Session…],"total":N}` newest first (by `modifiedMs`). `harness` absent = all. `q` is a case-insensitive substring of id, path, title or cwd (title and cwd only when the session's preview is already known). `limit` defaults 40, max 200. |
| `GET /api/sessions/{harness}/{id}` | Conversation JSON. 404 problem JSON (`LeanApi.Problem.notFound.toRes`) when no such session; 422 (`Problem.make 422 (some msg)`) when the harness slug is unknown; 500 with the importer's message when Loom cannot import the file. |
| `GET /` | `web/dist/index.html` (`Res.html`) |
| `GET /app.js`, `/style.css`, `/thread.css` | the file from `web/dist`, `Res.bytes body "text/javascript"` / `"text/css"`; 404 problem when missing |

Environment: `LOOM_VIEWER_PORT` (default 4800), `LOOM_VIEWER_HOST` (default 127.0.0.1),
`LOOM_VIEWER_HOME` (store roots are `<home>/<Store.root>`; default `$HOME`), `LOOM_VIEWER_WEB`
(the dist directory; default `web/dist` under the current directory). Print the URL when ready.

### Session JSON (`Viewer/Wire.lean`, `ToJson Session`)

```json
{"harness":"claude","id":"<uuid>","path":"/abs/file.jsonl","modifiedMs":1791589431313,"bytes":4598658,
 "title":"Build a GREAT overview of the project","cwd":"/Users/x/code/leanreact","model":"claude-…",
 "startedMs":1791589431313,"turns":12,"internal":false}
```
`title`, `cwd`, `model`, `startedMs` are `null` when unknown.

### Conversation JSON (`ToJson Conversation`, `ToJson Message`)

```json
{"messages":[{"id":"3.0","role":"assistant","atMs":1791589431313,"status":{"type":"complete"},
   "parts":[{"type":"text","text":"…"},{"type":"reasoning","text":"…"},
            {"type":"toolCall","callId":"3.1","name":"Bash","arguments":{"fields":[["description","List files"],["command","ls"]]},"result":{"value":"…","isError":false}}]}],
 "sidechains":0,"importNotes":2,"hidden":{"events":37,"redacted":4}}
```
`role` is `user|assistant|system`; `atMs` null when unknown; `status.type` is
`complete|running|cancelled|failed|requiresAction`, with `error` on `failed`; `result` is null while pending. `arguments` is `{"raw": text}` or `{"fields": [[key, value], …]}` in display order (the first field summarizes the call).

### The catalog (server: `Viewer/Catalog.lean`)

For each `h` in `Harness.all`, with `s := h.store`: walk `<home>/<s.root>` at most `s.depth` levels
(Loom's rule: unreadable directories are skipped, never fatal), keep files whose name ends with
`s.suffix`, and make a `SessionFile` with `id := s.sessionId stem` (stem = file name without the
suffix), `modifiedMs` from `System.FilePath.metadata` (`modified.sec * 1000 + nsec / 1000000`),
`bytes := metadata.byteSize`. Sort newest first.

Previews are computed per page, not for the whole store (stores hold gigabytes): for each session
on the requested page, read at most the first 256 KiB, cut at the last newline (a complete-line
prefix is a valid shorter transcript for every JSONL harness; for `.json` stores read the whole
file), run `s.parse`, then `Preview.ofTranscript h t`. A parse failure yields
`{ title := none, cwd := none, model := none, startedMs := none, turns := 0 }` and one stderr line.
Cache previews in an `IO.Ref` keyed by `(path, modifiedMs)`.

A conversation is the full file through `s.parse` then `Conversation.ofTranscript h t`; cache the
last few by `(path, modifiedMs)`.

## Browser (`web/`, built by `scripts/build.mjs` into `web/dist/`)

`web/generated/viewer.mjs` is the LeanJS module (`lake env lean Generate.lean`). It exports
`Viewer.UI.App`, `Viewer.UI.pageSize`, `Viewer.Harness.parse`, `Viewer.Harness.slug`,
`Viewer.Harness.all`, `Viewer.Harness.label`, `AssistantUI.Message.ofTranscript`, and imports the
LeanReact adapter by relative path (`../../../../leanreact/engine/adapters/leanjs-react.mjs`).

Files: `web/index.html` (loads `./app.js` as a module, `./style.css`, `./thread.css`; a `<div id="root">`),
`web/main.mjs` (entry), `web/client.mjs` (fetch + decoding, exported for tests), `web/style.css`.
`scripts/build.mjs` runs esbuild from `../../leanreact/node_modules/esbuild` with
`nodePaths: ['<abs>/leanreact/node_modules']` (so `react`, `react-dom`, `@assistant-ui/react`
resolve), bundles `web/main.mjs` to `web/dist/app.js` (esm, browser, es2022, sourcemap,
`define: {'process.env.NODE_ENV': '"development"'}`), copies `web/index.html`, `web/style.css`
and `../../leanreact/adapters/assistant-ui/thread.css` into `web/dist/`.

`web/main.mjs` must import `../../../leanreact/adapters/assistant-ui/index.mjs` (registers the
thread) before mounting, then:

```js
import { mountElement, ctor } from '../../../leanreact/engine/adapters/leanjs-react.mjs';
import * as program from './generated/viewer.mjs';
import { createService } from './client.mjs';
createRoot(document.getElementById('root')).render(React.createElement(React.StrictMode, null,
  mountElement(program['Viewer.UI.App'], ctor('Viewer.UI.AppProps.mk', [createService(program)]))));
```

### Lean values the browser builds (LeanJS ABI: `{tag, fields}`, `Nat` is `bigint`, `Option` is `Option.some [v]` / `Option.none`, `Bool` is `Bool.true` / `Bool.false`, arrays are JS arrays, field order is declaration order)

- `Viewer.Harness.*`: use `program['Viewer.Harness.parse'](slug)` (an `Option Harness`), never spell the tags by hand; `program['Viewer.Harness.slug'](h)` the other way.
- `Viewer.SessionFile.mk [harness, id, path, modifiedMs, bytes]`
- `Viewer.Preview.mk [title?, cwd?, model?, startedMs?, turns, internal]`
- `Viewer.Session.mk [file, preview]`
- `Viewer.UI.SessionPage.mk [sessions, total]`
- `Viewer.Conversation.mk [messages, sidechains, importNotes, Viewer.Hidden.mk [events, redacted]]`
- `AssistantUI.Message.mk [id, role, parts, createdAtMs?, status]`, `AssistantUI.Role.user|assistant|system`,
  `AssistantUI.Part.text [s]`, `AssistantUI.Part.reasoning [s]`, `AssistantUI.Part.image [url]` (wire `{"type":"image","url":…}`), `AssistantUI.Part.toolCall [callId, name, arguments, result?]` with `arguments` = `AssistantUI.ToolArguments.raw [text]` or `AssistantUI.ToolArguments.fields [[Prod.mk [key, value], …]]`,
  `AssistantUI.ToolResult.mk [value, isError]`, `AssistantUI.MessageStatus.complete|running|cancelled|requiresAction`, `AssistantUI.MessageStatus.failed [error]`.
- The service: `ctor('Viewer.UI.Service.mk', [sessions, conversation])` where `sessions(query)` and
  `conversation(harness, id)` are JS functions (one parameter per Lean argument) returning an
  `action(async () => …)` (from `../../../leanreact/engine/runtime/actions.mjs`) that resolves to
  `ctor('Except.ok', [value])` or `ctor('Except.error', [message])`. `query` arrives as
  `Viewer.UI.Query.mk [harness?, text, offset, limit]`.
- Encode a query as `?harness=<slug>&q=<text>&offset=<n>&limit=<n>` (omit `harness` when none).
- LeanJS applies a host function by its declared parameter count (`Function.length`). A service
  function must declare one parameter per Lean argument (`query => …`, `(harness, id) => …`); a
  zero-parameter function is called with no arguments and its result is then applied to the
  argument, which fails with `LeanJS: application of a non-function`.
