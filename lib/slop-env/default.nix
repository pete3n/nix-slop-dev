{
  pkgs,
  sandboxed,
  prereqGuidance ? null,
  claude-pkg,
  pi-pkg,
  opencode-pkg,
  jail,
}:

# Slop Env construction library — entry point.
# See ADR-0005 for the L4/L5 boundary and the file-layout rationale.
#
# Public API (stable contract):
#   slop.mkShell { projectName, agent?, rulesDir, skillsDir, agentMdFile,
#                  enableLocalAi?, basePkgs?, projectPkgs?, projectEnv?,
#                  extraCombinators? }
#     → pkgs.mkShell ...
#   slop.mkBins  { same args }
#     → { claude; jail-shell; jailedClaude; jailedShell;
#         sandboxedPackages; shellHook; }
#   slop.profiles
#     → { claude; pi; }  the Agent Profiles selectable via the `agent` arg
#       (ADR-0009). Defaults to `profiles.claude` when `agent` is omitted.
#   slop.defaults
#     → { basePkgs; claudeSettings; }
#
# Dispatch: Linux (NixOS + non-NixOS-Linux via slice 20) versus Darwin
# (slice 21). Each is a per-OS file plus one dispatch arm. The `jail`
# arg differs per platform — Linux passes jail-nix's __functor (bwrap
# combinators); Darwin passes nix-slop-dev's lib.jail return (Seatbelt
# combinators, with explicit `.jail` constructor) — and each arm
# consumes its own shape.

let
  shared = import ./shared.nix { inherit pkgs; };

  # Agent Profiles (ADR-0009). Claude Code is the default; callers pick another
  # via mkShell/mkBins' `agent` arg (e.g. `agent = slop.profiles.pi`).
  claudeProfile = import ./profiles/claude.nix { inherit claude-pkg shared; };
  piProfile = import ./profiles/pi.nix { inherit pi-pkg shared; };
  opencodeProfile = import ./profiles/opencode.nix { inherit opencode-pkg shared; };
  profiles = {
    claude = claudeProfile;
    pi = piProfile;
    opencode = opencodeProfile;
  };

  perOs =
    if pkgs.stdenv.isDarwin then
      import ./darwin.nix {
        inherit
          pkgs
          sandboxed
          jail
          shared
          ;
        defaultProfile = claudeProfile;
      }
    else
      import ./linux.nix {
        inherit
          pkgs
          sandboxed
          prereqGuidance
          jail
          shared
          ;
        defaultProfile = claudeProfile;
      };
in
{
  inherit (perOs) mkShell mkBins;
  inherit profiles;

  defaults = {
    basePkgs = shared.defaultBasePkgs;
    claudeSettings = shared.defaultClaudeSettings;
  };

  # Slice 19.1: re-expose the initialised jail object. Templates that
  # need to construct extra combinators (e.g. nvim-dev's bind/try-fwd-env
  # entries via `extraCombinators`) can use `slop.jail.combinators.*`
  # without taking jail-nix as a direct flake input themselves. The
  # value's shape differs by OS — Linux: jail-nix's __functor;
  # Darwin: nix-slop-dev.lib.jail's `{ jail; combinators; ... }` —
  # but the `.combinators` access path is portable.
  inherit jail;
}
