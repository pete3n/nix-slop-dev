{ pkgs
, sandboxed
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
#     → { jailedClaude; jailedShell; sandboxedPackages; shellHook; }
#   slop.defaults
#     → { basePkgs; claudeSettings; }
#
# Dispatch: currently Linux-only (the original NixOS path). Slice 20 adds
# the non-NixOS-Linux variant; slice 21 adds Darwin. Each is a new per-OS
# file plus one dispatch arm.

let
  shared = import ./shared.nix { inherit pkgs; };
  linux = import ./linux.nix { inherit pkgs sandboxed claude-pkg jail shared; };
in
{
  inherit (linux) mkShell mkBins;

  defaults = {
    basePkgs = shared.defaultBasePkgs;
    claudeSettings = shared.defaultClaudeSettings;
  };

  # Slice 19.1: re-expose the initialised jail-nix object. Templates that
  # need to construct extra combinators (e.g. nvim-dev's bind/try-fwd-env
  # entries via `extraCombinators`) can use `slop.jail.combinators.*`
  # without taking jail-nix as a direct flake input themselves.
  inherit jail;
}
