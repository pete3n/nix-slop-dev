{
  description = "Sandboxed AI agent development environments for NixOS and nix-darwin";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    # Used only by the template-byte-equality checks (so they can call
    # the templates' outputs functions manually). Not consumed by the
    # lib or by runtime packages. The nvim template additionally needs
    # flake-utils + gen-luarc for the byte-eq path (slice 19.4).
    jail-nix.url = "sourcehut:~alexdavid/jail.nix";
    llm-agents.url = "github:numtide/llm-agents.nix";
    flake-utils.url = "github:numtide/flake-utils";
    gen-luarc.url = "github:mrcjkb/nix-gen-luarc-json";
  };

  outputs =
    { self, nixpkgs, jail-nix, llm-agents, flake-utils, gen-luarc, ... }:
    let
      linuxSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      darwinSystems = [
        "aarch64-darwin"
        "x86_64-darwin"
      ];
      allSystems = linuxSystems ++ darwinSystems;
      forAllSystems = nixpkgs.lib.genAttrs allSystems;
      forLinux = nixpkgs.lib.genAttrs linuxSystems;
      forDarwin = nixpkgs.lib.genAttrs darwinSystems;
      isLinuxSystem = system: builtins.elem system linuxSystems;
    in
    {
      # Linux: the existing sandboxed wrapper. callPackage keeps the
      # derivation overridable so the NixOS module can pass a custom
      # stateDir: package.override { stateDir = "..."; }.
      # Darwin: the sandboxed-darwin wrapper (issue 08) plus the
      # sandbox-proxy binary it spawns (per ADR-0003). The wrapper is
      # the user-facing default; the proxy is exposed separately for
      # direct invocation and testing.
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        if isLinuxSystem system then {
          sandboxed = pkgs.callPackage ./packages/sandboxed/default.nix { };
          setup-linux = pkgs.callPackage ./packages/setup-linux/default.nix { };
          prereq-guidance = pkgs.callPackage ./packages/prereq-guidance/default.nix { };
          default = self.packages.${system}.sandboxed;
        }
        else
          let
            sandbox-proxy = pkgs.callPackage ./packages/sandbox-proxy/default.nix { };
          in
          {
            inherit sandbox-proxy;
            sandboxed = pkgs.callPackage ./packages/sandboxed-darwin/default.nix { inherit sandbox-proxy; };
            default = self.packages.${system}.sandboxed;
          }
      );

      checks = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        if !(isLinuxSystem system) then {
          # Darwin checks cover:
          #   - sandbox-proxy: the proxy's hostname allowlist matcher
          #     (pure Go).
          #   - sandbox-profile: the Seatbelt profile generator (pure Nix).
          #   - jail-lib: the Jail combinator library (pure Nix; issue 10).
          #   - sandboxed-darwin: the per-jail wrapper builder (issue 11).
          # No Seatbelt enforcement here — that part is HITL per spike 07.
          sandbox-proxy = import ./tests/sandbox-proxy.nix { inherit pkgs; };
          sandbox-profile = import ./tests/sandbox-profile.nix {
            inherit pkgs;
            inherit (pkgs) lib;
          };
          jail-lib = import ./tests/jail-lib.nix {
            inherit pkgs;
            inherit (pkgs) lib;
          };
          sandboxed-darwin = import ./tests/sandboxed-darwin.nix {
            inherit pkgs;
            inherit (pkgs) lib;
          };
        }
        else
        let
          slop = self.lib.slopEnv pkgs;
          # Slice 19.1: lib re-exposes the initialised jail-nix object so
          # templates can build extraCombinators without importing jail-nix
          # themselves (the nvim template's nvim-dev paths use this).
          expected = [ "defaults" "jail" "mkBins" "mkShell" ];
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

          # Slice 19.2: mkBins/mkShell accept extraShellHook (string) that
          # the lib appends to its emitted shellHook. The nvim template
          # uses this for .luarc.json symlinking, swap-dir reset, and the
          # nvim-dev config symlink — bits that today live in an inline
          # template shellHook the refactor needs to dissolve.
          lib-slop-env-extra-shell-hook =
            let
              marker = "SLOP_HOOK_MARKER_FROM_TEST";
              bins = (self.lib.slopEnv pkgs).mkBins {
                extraShellHook = "echo ${marker}";
              };
            in
            if pkgs.lib.hasInfix marker bins.shellHook then
              pkgs.runCommand "lib-slop-env-extra-shell-hook" { } ''
                echo "extraShellHook content reached the emitted shellHook" > $out
              ''
            else
              throw "extraShellHook arg did not flow into the emitted shellHook";

          # Slice 19.3: mkBins/mkShell accept extraSandboxedEnvForwards
          # (list of env var names) appended as -e flags to the claude()
          # function's sandboxed invocation inside the emitted shellHook.
          # The nvim template needs this because LUA_PATH is
          # $PWD-dependent and the jail-side try-fwd-env combinator only
          # takes effect once the sandbox lets the var through.
          lib-slop-env-extra-sandboxed-env =
            let
              bins = (self.lib.slopEnv pkgs).mkBins {
                extraSandboxedEnvForwards = [ "LUA_PATH" ];
              };
            in
            if pkgs.lib.hasInfix "-e LUA_PATH" bins.shellHook then
              pkgs.runCommand "lib-slop-env-extra-sandboxed-env" { } ''
                echo "extraSandboxedEnvForwards entry added a -e flag" > $out
              ''
            else
              throw "extraSandboxedEnvForwards arg did not add an -e flag to the claude() sandboxed call";

          # Slice 20 (#01): NixOS module evaluation — asserts user@
          # sessions carry no cgroup Delegate after the dead BPF
          # delegation was removed from modules/sandboxed/default.nix.
          nixos-module = import ./tests/nixos-module.nix {
            inherit nixpkgs pkgs system;
            sandboxedModule = self.nixosModules.sandboxed;
          };

          # Slice 20 (#02): sandboxed wrapper --print-tools exercises the
          # runtime NixOS detection (store paths vs bare names) without a
          # real NixOS host.
          wrapper-tool-resolution = import ./tests/wrapper-tool-resolution.nix {
            inherit pkgs;
            sandboxed = self.packages.${system}.sandboxed;
          };

          # Slice 20 (#03): setup-linux check-only mode uses a pure
          # check-lib.sh evaluator driven by fixtures, so we cover every
          # prerequisite branch without a real Ubuntu/Fedora host. The
          # -app companion smoke-tests the wired-up nix run entry point.
          setup-linux-checks = import ./tests/setup-linux-checks.nix {
            inherit pkgs;
          };

          setup-linux-app = import ./tests/setup-linux-app.nix {
            inherit pkgs;
            setupLinux = self.packages.${system}.setup-linux;
          };

          # Slice 20 (#04): --apply mode's pure planning + sudoers /
          # tool-path / auditd-install logic is fixture-driven via
          # apply-lib.sh, so we cover every distro branch without
          # mutating any host.
          setup-linux-apply = import ./tests/setup-linux-apply.nix {
            inherit pkgs;
          };

          # Slice 20 (#06 lib-layer rewrite): slop-prereq-guidance picks
          # distro-aware advice (NixOS module options vs setup-linux) at
          # runtime via the /etc/NIXOS marker. The marker path is
          # overridable by argument so both branches are exercised in
          # the build sandbox; the live auditd/sudo probes are HITL.
          template-prereq-guidance = import ./tests/template-prereq-guidance.nix {
            inherit pkgs;
            prereqGuidance = self.packages.${system}.prereq-guidance;
          };
        } // (
          if system == "x86_64-linux" then {
            template-claude-code-drv = import ./tests/template-claude-code-drv.nix {
              inherit self pkgs jail-nix llm-agents;
            };

            # Slice 19.4: byte-equality baseline for the nvim template.
            # Captured pre-refactor so slice 19.5's template flip can
            # prove it preserves the rendered devShell derivation.
            template-nvim-dev-drv = import ./tests/template-nvim-dev-drv.nix {
              inherit self pkgs jail-nix llm-agents flake-utils gen-luarc;
            };
          } else { }
        )
      );

      # Slice 18: zero-touch entry points for existing-Nix-flake users.
      # `nix run github:pete3n/nix-slop-dev#claude` works from any project
      # root without touching the project's flake.nix. The lib-bundled
      # defaults (lib/slop-env/defaults/) feed mkBins's CLAUDE.md / rules
      # when no caller-supplied paths are given.
      #
      # Slice 20 (#03) adds setup-linux for non-NixOS hosts (diagnoses
      # Sandbox/Jail prerequisites; #04 adds --apply mode behind the same
      # entry point).
      apps = forLinux (
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
          setup-linux = {
            type = "app";
            program = "${self.packages.${system}.setup-linux}/bin/setup-linux";
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
            prereqGuidance = self.packages.${system}.prereq-guidance;
            claude-pkg = llm-agents.packages.${system}.claude-code;
            jail = jail-nix.lib.init pkgs;
          };

        # Seatbelt combinator library for the Darwin Jail (issue 10).
        # Shape mirrors upstream jail-nix's `jail-nix.lib.init pkgs`:
        # consumers call `lib.jail pkgs` to instantiate the library
        # against a concrete pkgs set, then use the returned
        # `combinators` and `jail` constructor to build a per-binary
        # SBPL profile + bind/forward slice (see ADR-0004).
        jail = pkgs: import ./lib/jail { inherit (pkgs) lib; inherit pkgs; };
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
