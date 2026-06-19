{ pkgs
, sandboxed
, prereqGuidance ? null
, claude-pkg
, jail
}:

# Slop Env construction library — entry point.
# See ADR-0005 for the L4/L5 boundary and the file-layout rationale.
#
# Public API (stable contract):
#   slop.mkShell { projectName, rulesDir, skillsDir, claudeMdFile,
#                  basePkgs?, projectPkgs?, projectEnv?, extraCombinators? }
#     → pkgs.mkShell ...
#   slop.mkBins  { same args }
#     → { claude; jail-shell; jailedClaude; jailedShell;
#         sandboxedPackages; shellHook; }
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
  perOs =
    if pkgs.stdenv.isDarwin then
      import ./darwin.nix { inherit pkgs sandboxed claude-pkg jail shared; }
    else
      import ./linux.nix { inherit pkgs sandboxed prereqGuidance claude-pkg jail shared; };
in
{
  inherit (perOs) mkShell mkBins;

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
