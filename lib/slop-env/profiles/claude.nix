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
  mkContext =
    { agentMdFile, rulesDir }:
    shared.mkContextMd {
      contextMdFile = agentMdFile;
      inherit rulesDir;
    };

  # Claude's jail combinator builder: cfgDir, config injection, per-project rw
  # state, the shared-credentials graft, caches, and env forwards. The OS arms
  # still supply their own envSrc / cfgDirCombinator / shareCredentialsFile.
  #
  # ADR-0014 per-Account contract: this builder also accepts the agent-agnostic
  # `accountSessionSuffix` (appended to the per-project state root for per
  # Account-and-project isolation) and `accountCredFile` (the per-Account
  # credential graft source). Both default to the no-Account values, so an
  # Account-free Slop Env is byte-identical. Pi/opencode implement the same two
  # hooks when they gain Account support (their auth files differ); the
  # launcher-level keyFile/ANTHROPIC_API_KEY plumbing in linux.nix is Claude-
  # first this pass and generalises to a profile hook as a follow-up.
  mkJailCombinators = shared.mkJailCombinators;
}
