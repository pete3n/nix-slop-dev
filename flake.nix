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
              # Slice 18 added `claude` and `jail-shell` PATH binaries to
              # the return shape (consumed by apps.${system}.{claude,jail-shell}).
              expectedKeys = [ "claude" "jail-shell" "jailedClaude" "jailedShell" "sandboxedPackages" "shellHook" ];
              actualKeys = builtins.attrNames bins;
            in
            if actualKeys == expectedKeys then
              pkgs.runCommand "lib-slop-env-mkBins-shape" { } ''
                echo "lib.slopEnv mkBins shape: ${builtins.concatStringsSep " " actualKeys}" > $out
              ''
            else
              throw "lib.slopEnv mkBins shape regressed. expected: ${builtins.concatStringsSep " " expectedKeys} actual: ${builtins.concatStringsSep " " actualKeys}";

          # Slice 18.1 tracer: apps wiring exists. Both apps must have
          # type = "app" and a non-null program string.
          apps-shape =
            let
              claudeApp = self.apps.${system}.claude or null;
              jailShellApp = self.apps.${system}.jail-shell or null;
              ok = app: app != null && (app.type or null) == "app" && (app.program or null) != null;
            in
            if ok claudeApp && ok jailShellApp then
              pkgs.runCommand "apps-shape" { } ''
                echo "apps.${system}.{claude,jail-shell} wired" > $out
              ''
            else
              throw "apps.${system}.{claude,jail-shell} missing or wrong shape";

          # Slice 18.2: zero-touch apps build the jail with a
          # __SLOP_ENV_PROJECT_NAME__ sentinel in cfgDir paths. The
          # wrapper sed-substitutes basename "$PWD" at invocation. This
          # check verifies the sentinel is actually present in the
          # rendered jail launch script when mkBins is called with no
          # args (apps path). The template calls mkBins with a concrete
          # projectName, so its launch script must NOT contain the
          # sentinel (covered by byte-equality in slice 17's check).
          apps-jail-has-placeholder =
            let
              bins = (self.lib.slopEnv pkgs).mkBins { };
            in
            pkgs.runCommand "apps-jail-has-placeholder" { } ''
              if ! grep -q "__SLOP_ENV_PROJECT_NAME__" ${bins.jailedClaude}/bin/jailed-claude; then
                echo "expected __SLOP_ENV_PROJECT_NAME__ placeholder in jailed-claude launch script" >&2
                exit 1
              fi
              echo "ok" > $out
            '';
          # Slice 18.6: lib/slop-env/defaults/ and the template's
          # claude-config/ are intentionally duplicated (one is library-
          # lifecycle, one is project-lifecycle). This check fails when
          # they drift accidentally; a `.diverged` sentinel in the
          # template opts out deliberately.
          template-default-config-matches-lib = import ./tests/template-default-config-matches-lib.nix {
            inherit pkgs;
          };
        } // (
          if system == "x86_64-linux" then {
            template-claude-code-drv = import ./tests/template-claude-code-drv.nix {
              inherit self pkgs jail-nix llm-agents;
            };
          } else { }
        )
      );

      # Slice 18: zero-touch entry points for existing-Nix-flake users.
      # `nix run github:pete3n/nix-slop-dev#claude` works from any project
      # root without touching the project's flake.nix. The lib-bundled
      # defaults (lib/slop-env/defaults/) feed mkBins's CLAUDE.md / rules
      # when no caller-supplied paths are given.
      apps = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          bins = (self.lib.slopEnv pkgs).mkBins { };
        in
        {
          claude = {
            type = "app";
            program = "${bins.claude}/bin/claude";
          };
          jail-shell = {
            type = "app";
            program = "${bins.jail-shell}/bin/jail-shell";
          };
        }
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
