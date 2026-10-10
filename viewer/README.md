# Loom viewer

Every coding-agent conversation on this machine, in one chat UI. Claude Code, Codex CLI, Pi,
Cursor Agent and Hermes keep their sessions in different stores and formats; Loom already imports
each into one transcript IR, and this viewer lists those sessions and shows any of them as a
thread, rendered by [assistant-ui for Lean](../../leanreact/adapters/assistant-ui/README.md).

It is a sub-package so the Loom core stays dependency-free: `viewer/` requires Loom from the
parent checkout and LeanReact from the sibling `leanreact` checkout, and LeanReact brings LeanAPI.

## Run it

```sh
cd viewer
lake build loom_viewer          # the server (first build compiles LeanReact's dependencies)
lake env lean Generate.lean     # the browser-side Lean, compiled to web/generated/viewer.mjs
node scripts/build.mjs          # the bundle, into web/dist (npm packages come from ../../leanreact)
.lake/build/bin/loom_viewer     # http://127.0.0.1:4800
```

`LOOM_VIEWER_PORT`, `LOOM_VIEWER_HOST`, `LOOM_VIEWER_HOME` (where the stores are; `$HOME` by
default) and `LOOM_VIEWER_WEB` (the built bundle; `web/dist` by default) configure it.

To pick up a new server build, stop the running one first (`pkill -f loom_viewer`): a second
instance cannot bind the port and exits, while the old one keeps serving the new bundle from
`web/dist` with the old Lean behind it.

## The model

The domain is four small modules; everything else derives from them.

- **`Viewer/Harness.lean`.** `Harness` is the closed set of harnesses with a local store. `Store`
  is a type class over it: where the store is, how deep its files sit, how a file name spells the
  session id, which Loom importer reads the file, and which user texts are the harness talking to
  itself (slash-command envelopes, injected environment context). Every harness-specific quirk is
  one instance; the catalog and the server never branch on the harness, they ask the instance.
  Adding a harness is adding an instance.
- **`Viewer/Session.lean`.** `SessionFile` is what the file system says (harness, id, path, time,
  size). `Preview` is what the transcript says it is about (the person's first words, cwd, model,
  start, turn count), derived by `Preview.ofTranscript` with the store's scaffolding rule.
  `Session` is both, as the list shows it.
- **`Viewer/Conversation.lean`.** One pure projection from the Loom IR to the thread: each
  message block becomes an `AssistantUI.Entry`, tool calls are identified positionally
  (`entry.block`) exactly as Loom links results to calls, scaffolding renders as system, and
  `AssistantUI.Message.ofTranscript` folds the entries into messages. The same function runs in
  the native checks and on the server.
- **`Viewer/Wire.lean`.** The JSON the browser receives, written once; `web/client.mjs` decodes it
  once. [CONTRACT.md](CONTRACT.md) is the exact wire and route contract.

`Viewer/UI.lean` is the browser side, portable Lean compiled by LeanJS: the catalog with harness
chips, search and paging on the left, the thread on the right, both through `useResource` over a
`Service` the client implements with fetch. The thread is read-only: the viewer shows what the
harnesses recorded.

`Viewer/Catalog.lean` and `Viewer/Server.lean` are the infrastructure: the depth-bounded store
walk (Loom's rule: an unreadable store is an empty store), previews computed per page from a
256 KiB prefix of each file and cached by path and modification time, full imports cached for
the open conversation, and LeanAPI's router with IO handlers. LeanAPI's typed `api!` layer is
pure by construction (its handlers carry isolation proofs), which is right for a domain over
LeanDB and wrong for seven gigabytes of files other programs own, so the viewer uses the router
directly.

## Checks

```sh
lake build loom_viewer_checks && .lake/build/bin/loom_viewer_checks   # scan, previews, projection, HTTP, on fixtures
node --test web/client.test.mjs                                        # decoders, the service, the mounted UI under jsdom
```

## Not yet

Subagent sidechains are counted, not shown, and so are harness bookkeeping rows (Codex item
lifecycle events, hook results) and reasoning the harness encrypted: the thread header says how
many it left out. Codex auto-review rollouts, which the harness runs for itself, are listed and
labelled as internal sessions rather than hidden. Search covers ids,
paths and the previews already computed; a background index would extend it to every title. Codex
sessions whose first user row is a bare path or an auto-review preamble list under their id, and
the Claude Code and Pi importers do not lift the model into the session header. Hermes and Cursor
Agent stores are walked but their session ids are the file stems.
