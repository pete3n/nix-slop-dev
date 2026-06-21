{ claude-pkg, shared }:

# Agent Profile for Claude Code — the default profile (ADR-0009). See
# CONTEXT.md for the *Agent Profile* term. It bundles Claude's package with the
# Claude-specific config helpers that today live in shared.nix, so the per-OS
# engine arms (linux.nix / darwin.nix) consume a profile rather than
# referencing `claude-pkg` / `shared.*` directly.
#
# This is a thin manifest pointing at the existing shared helpers: the seam
# moves, but every value is the same reference it was before, so the Claude
# derivation stays byte-identical (tests/template-claude-code-drv.expected).

{
  name = "claude";

  # Jailed-binary derivation name. Kept as the literal the engine used before
  # the profile seam so the jail derivation hash is unchanged.
  jailedName = "jailed-claude";

  package = claude-pkg;

  # Settings file contents dropped into the agent's per-project config dir.
  settings = shared.defaultClaudeSettings;

  # Always-in-context instructions file (base file + rules/*). `agentMdFile` is
  # the profile-neutral caller arg; for Claude it is the CLAUDE.md the agent
  # loads from its config dir.
  mkContext = { agentMdFile, rulesDir }:
    shared.mkContextMd { contextMdFile = agentMdFile; inherit rulesDir; };

  # Claude's jail combinator builder: cfgDir, config injection, per-project rw
  # state, the shared-credentials graft, caches, and env forwards. The OS arms
  # still supply their own envSrc / cfgDirCombinator / shareCredentialsFile.
  mkJailCombinators = shared.mkJailCombinators;
}
