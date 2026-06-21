# Nix Slop Dev

Sandboxed development environments for AI coding agents: a NixOS module and
wrapper that confine agent processes, plus flake templates that assemble
per-project jailed agent shells.

## Language

**Sandbox**:
The network-confinement boundary around a single command: a Host Whitelist
plus violation alerting, created by the `sandboxed` wrapper. Enforced by a
systemd-run transient unit on Linux and by the network rules of a Seatbelt
profile on macOS. Defined by what it confines (network), not by the OS
mechanism that enforces it.
_Avoid_: Jail (that's the filesystem boundary), container

**Jail**:
The filesystem-confinement boundary built per project template (e.g.
`jailed-claude`). Enforced by bubblewrap (jail.nix combinators) on Linux and
by the filesystem rules of a Seatbelt profile on macOS. Distinct from and
composable with a Sandbox, even where one OS mechanism enforces both.
_Avoid_: Sandbox, chroot

**Seatbelt**:
macOS's process sandboxing facility (`sandbox-exec` profiles). The single
enforcement mechanism for both the Sandbox and the Jail on macOS.
_Avoid_: sandbox (unqualified — collides with Sandbox)

**Host Whitelist**:
The set of hostnames, IPs, and CIDRs a Sandbox may connect to, supplied
per-invocation (`-a/--allow`) or persisted in the whitelist file
(`--wl-add`/`--wl-del`).
_Avoid_: allowlist

**Slop Env**:
A per-project AI-agent harness composed of a Sandbox and a Jail. The unit a
user "enters" when they run their agent (e.g. `claude`, `pi`) or
`jail-shell`. Produced by
`nix-slop-dev.lib.${system}.mkSlopEnvBins { ... }` and consumed by the
`claude-code` / `claude-code-nvim-dev` / `pi-agent` templates (for greenfield
projects) and the `apps.${system}.{claude,jail-shell}` zero-touch entry points
(for existing-flake projects). Which agent it confines is set by an Agent
Profile — Claude Code by default; Pi via the `pi-agent` template. Combines
both confinement boundaries into one artifact; an agent run outside a Slop Env
has neither.
_Avoid_: agent shell (overloaded — used generically for any AI session),
sandbox (collides with Sandbox), jail (collides with Jail)

**Agent Profile**:
The per-agent half of a Slop Env's configuration: which coding agent it
confines (Claude Code, Pi, …) together with that agent's config-file layout,
its credential and session locations, and the network hosts its provider
needs. The Slop Env library carries one profile per supported agent; an
agent-agnostic engine combines a profile with a project's Sandbox and Jail to
emit the runnable bins. Claude Code is the default profile.
_Avoid_: adapter, backend, agent kind, harness (collides with the agent's own
naming)

**Exchange**:
The per-project, host-visible directory through which a user and a jailed
agent deliberately pass files in either direction — the user dropping inputs
in for the agent to ingest, the agent leaving outputs (e.g. handoff
documents) for the user to collect. Persists across agent runs and lives
outside both the project working tree and the agent's private temp. Scoped
per Slop Env (per `projectName`), not shared across projects.
_Avoid_: tmp, scratch (that's Scratch), share (collides with the
shared-credentials concept)

**Scratch**:
The per-project temp directory a jailed agent writes to by default, made
host-visible so the user can inspect what the agent produced. Throwaway, not
a deliberate handoff channel (that's the Exchange). Exists because a Jail's
own private temp lives in the agent's mount namespace and is unreachable
from the host.
_Avoid_: tmp (unqualified), Exchange (deliberate and persistent — different
intent)
