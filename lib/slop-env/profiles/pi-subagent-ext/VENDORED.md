# Vendored: pi `subagent` example extension

This is a verbatim, pinned copy of the upstream `subagent` example extension
from [earendil-works/pi](https://github.com/earendil-works/pi), used to bring
the local coordinator→workers topology (B2) to the pi Agent Profile — see
**ADR-0013**.

## Source

- Repo: `earendil-works/pi`
- Path: `packages/coding-agent/examples/extensions/subagent/`
- Pin: commit `0d145e89`
- License: MIT (see `LICENSE` here, copied from the upstream repo root)

## What is vendored — and what is not

Only the two files pi needs to load the extension are vendored:

- `subagent/index.ts`
- `subagent/agents.ts`

The upstream example also ships `README.md`, a `prompts/` dir, and an `agents/`
dir; those are **not** needed at runtime and are deliberately omitted so the
ro-bound source directory contains exactly `index.ts` + `agents.ts`.

## How it is used

`lib/slop-env/profiles/pi.nix` ro-binds `subagent/` into the jail at
`~/.pi/agent/extensions/subagent`, gated on a coordinator topology
(`hasCoordinatorTopology`). pi auto-loads user-scope extensions (enabled by
default, no trust prompt), so the coordinator gains the `subagent` tool and can
delegate to the generated worker agents. Child `pi` processes the tool spawns
run inside the same jail because `pi` is added to the jail PATH when `localAi`
is enabled with a coordinator topology (ADR-0013, Slice 5).

## Updating

Re-copy both files from the upstream repo at the desired commit, update the
**Pin** above, and re-run `nix build '.#checks.x86_64-linux.local-ai-config'`
plus the HITL test plan (`$CLAUDE_EXCHANGE_DIR/test-local-ai-orchestration.md`).
