# Slop Env construction is agent-agnostic; each agent is an Agent Profile

The `slopEnv` lib (ADR-0005) was built around Claude Code: `claude-pkg`, a
baked `~/.local/state/claude/projects/$NAME` cfgDir, `CLAUDE.md`/`.claude.json`
injection, `api.anthropic.com`/`platform.claude.com` hosts, and `claude` /
`jailed-claude` bin names were all hard-coded in `shared.nix` + `linux.nix` +
`darwin.nix`. The roadmap promises `opencode` and `pi-agent` templates that
give other agents "the same Sandbox / Jail guarantees" — but Pi's layout
diverges in nearly every structural detail (global `~/.pi/agent` config dir
instead of a per-project tmpfs, `auth.json` instead of a grafted
`.credentials.json`, sessions relocated via `PI_CODING_AGENT_SESSION_DIR`,
`AGENTS.md` instead of `CLAUDE.md`), so Claude's combinator list cannot simply
be parameterized into Pi's.

We generalize the lib around an **Agent Profile** (see [`CONTEXT.md`](../../CONTEXT.md)):
the per-agent half of a Slop Env's config — package, config-file layout,
credential/session locations, network hosts, bin name, and a builder for the
agent-specific jail combinators. An agent-agnostic engine owns everything
genuinely shared (the Sandbox wrapper, OS dispatch, the projectName/placeholder
machinery, Scratch/Exchange setup, the common combinator preamble, and the
`mkBins` / `mkShell` return shape); each profile contributes its own combinator
list plus hosts/env/bootstrap/settings. `claudeProfile` reproduces today's
behavior verbatim so the byte-equality baseline
(`tests/template-claude-code-drv.expected`) holds unchanged, and it remains the
default profile. `piProfile` is the first second agent, proving the boundary.

## Considered Options

- **Bypass the lib** — let `pi-agent` drive `jail` combinators + `sandboxed`
  directly (as the original skeleton did). Rejected: it creates a second,
  divergent way to build a Slop Env and violates the glossary's "produced by
  the lib" definition, duplicating Scratch/Exchange, OS dispatch, and prereq
  guidance.
- **One parameterized `mkJailCombinators`** — a single function whose rich
  profile record drives every path/file via conditionals. Rejected: the two
  layouts differ so much that the body becomes a shallow, conditional-ridden
  module — the opposite of the codebase's deep-module discipline — and carries
  high byte-equality risk for the Claude path.

## Consequences

- The public contract from ADR-0005 grows an `agent` (profile) arg defaulting
  to `claudeProfile`; `claudeMdFile` becomes `agentMdFile` and an
  `enableLocalAi` arg is added. Claude callers that omit `agent` are
  unaffected and byte-identical.
- Per-OS arms (`linux.nix`, `darwin.nix`) consume the profile instead of
  `claude-pkg`; the claude-specific combinator block moves into
  `profiles/claude.nix` unchanged.
- Pi scopes to the greenfield **template only** in this pass — concrete
  `projectName`, no `apps.${system}.pi`. The runtime placeholder/sed
  resolution stays exercised only by Claude until an apps entry point for
  another agent is actually wanted.
- Pi's per-project isolation is sessions-only (`PI_CODING_AGENT_SESSION_DIR`);
  `auth.json` + `settings.json` stay global in `~/.pi/agent` so a user logs in
  once across projects — the faithful analog of Claude's shared
  `.credentials.json` + per-project sessions, achieved with one env var rather
  than a symlink graft.
- A second profile (`opencode`) is now an additive file, not a lib rewrite.
