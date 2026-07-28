# agent-convert-lean

Private Lean 4 semantic core for [agent-convert](https://github.com/theoriclabs/agent-convert).

Sources live under [`spec/loom`](./spec/loom). That tree models agent transcripts
as a format-neutral IR, records conversion judgments, and refuses known
destructive exports.

WOW21, Inc. authorized publication of the former private
`utils/spec/loom` scope under the MIT license into this repository.

## Build

Requires [Lean 4.28.0](https://lean-lang.org/) (see `spec/loom/lean-toolchain`).

```sh
cd spec/loom
lake build loom
lake exe loom version
```

## Docs

Start with [`spec/loom/README.md`](./spec/loom/README.md). Release procedure,
requirements, and evidence live beside it.

## Host coupling

Full `scripts/verify.sh` still expects the TypeScript utils host (parity /
thin-launcher tests). Until that cutover, develop against the monorepo working
tree at `thecentralhub/utils/spec/loom` when you need the full gate; this repo
is the independent Lean core source of truth.
