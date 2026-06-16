{
  description = "Sandboxed AI agent development environments for NixOS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    # Used only by the template-byte-equality check (so it can call the
    # template's outputs function manually). Not consumed by the lib or
    # by runtime packages.
    jail-nix.url = "sourcehut:~alexdavid/jail.nix";
    llm-agents.url = "github:numtide/llm-agents.nix";
  };

  outputs =
    { self, nixpkgs, jail-nix, llm-agents, ... }:
    let
      # Darwin isn't currently supported by the sanbox solution
      linuxSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs linuxSystems;
    in
    {
      # callPackage makes the derivation overridable so the NixOS module
      # can pass a custom stateDir: package.override { stateDir = "..."; }
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          sandboxed = pkgs.callPackage ./packages/sandboxed/default.nix { };
          default = self.packages.${system}.sandboxed;
        }
      );

      checks = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          slop = self.lib.slopEnv pkgs;
          expected = [ "defaults" "mkBins" "mkShell" ];
          actual = builtins.attrNames slop;
        in
        {
          lib-slop-env-shape =
            if actual == expected then
              pkgs.runCommand "lib-slop-env-shape" { } ''
                echo "lib.slopEnv shape: ${builtins.concatStringsSep " " actual}" > $out
              ''
            else
              throw "lib.slopEnv shape regressed. expected: ${builtins.concatStringsSep " " expected} actual: ${builtins.concatStringsSep " " actual}";

          # Slice 2: defaults are populated from shared.nix (no longer stubs).
          # The list must include coreutils (a baseline shell tool every Slop
          # Env needs). Detects accidental wipes of the default list.
          lib-slop-env-defaults =
            let
              basePkgs = slop.defaults.basePkgs;
              hasCoreutils = builtins.any (p: (p.pname or null) == "coreutils") basePkgs;
            in
            if hasCoreutils then
              pkgs.runCommand "lib-slop-env-defaults" { } ''
                echo "lib.slopEnv defaults.basePkgs has coreutils (count=${toString (builtins.length basePkgs)})" > $out
              ''
            else
              throw "lib.slopEnv defaults.basePkgs missing coreutils (count=${toString (builtins.length basePkgs)})";

          # Slice 3: mkBins assembles the per-OS bins from the template's
          # checked-in claude-config. Asserts the public API shape: keys
          # match the spec and each value is a derivation / string (not
          # the "not implemented" throw).
          lib-slop-env-mkBins-shape =
            let
              bins = slop.mkBins {
                projectName = "byteq-test";
                claudeMdFile = ../templates/claude-code/slop-env/claude-config/CLAUDE.md;
                rulesDir = ../templates/claude-code/slop-env/claude-config/rules;
                skillsDir = ../templates/claude-code/slop-env/claude-config/skills;
              };
              expectedKeys = [ "jailedClaude" "jailedShell" "sandboxedPackages" "shellHook" ];
              actualKeys = builtins.attrNames bins;
            in
            if actualKeys == expectedKeys then
              pkgs.runCommand "lib-slop-env-mkBins-shape" { } ''
                echo "lib.slopEnv mkBins shape: ${builtins.concatStringsSep " " actualKeys}" > $out
              ''
            else
              throw "lib.slopEnv mkBins shape regressed. expected: ${builtins.concatStringsSep " " expectedKeys} actual: ${builtins.concatStringsSep " " actualKeys}";
        } // (
          if system == "x86_64-linux" then {
            template-claude-code-drv = import ./tests/template-claude-code-drv.nix {
              inherit self pkgs jail-nix llm-agents;
            };
          } else { }
        )
      );

      # Slop Env construction lib. Templates and apps call lib.slopEnv pkgs
      # to obtain { mkShell; mkBins; defaults; } — see ADR-0005.
      # jail-nix + llm-agents + our own sandboxed package are injected here
      # so callers don't need to wire those inputs themselves.
      lib = {
        slopEnv = pkgs:
          let
            system = pkgs.stdenv.hostPlatform.system;
          in
          import ./lib/slop-env {
            inherit pkgs;
            sandboxed = self.packages.${system}.sandboxed;
            claude-pkg = llm-agents.packages.${system}.claude-code;
            jail = jail-nix.lib.init pkgs;
          };
      };

      nixosModules = {
        sandboxed = import ./modules/sandboxed/default.nix self;
        default = self.nixosModules.sandboxed;
      };

      templates = {
        claude-code = {
          path = ./templates/claude-code;
          description = "Jailed Claude Code environment with sandboxed network isolation";
        };

        claude-code-nvim-dev = {
          path = ./templates/claude-code-nvim-dev;
          description = "Jailed Claude Code environment for Neovim plugin development with lua tooling and headless test support";
        };
      };
    };
}
