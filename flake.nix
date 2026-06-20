{
  description = "Sandboxed AI agent development environments for NixOS and nix-darwin";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    jail-nix.url = "sourcehut:~alexdavid/jail.nix";
    llm-agents.url = "github:numtide/llm-agents.nix";

    # flake-utils and gen-luarc are not used by lib or runtime packages.
    # They satisfy the nvim template's input signature when
    # tests/template-nvim-dev-drv.nix invokes its outputs function
    # directly to capture the rendered devShell's drvPath.
    flake-utils.url = "github:numtide/flake-utils";
    gen-luarc.url = "github:mrcjkb/nix-gen-luarc-json";
  };

  outputs =
    {
      self,
      nixpkgs,
      jail-nix,
      llm-agents,
      flake-utils,
      gen-luarc,
      ...
    }:
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
      isLinuxSystem = system: builtins.elem system linuxSystems;
    in
    {
      # callPackage keeps each derivation overridable so the NixOS /
      # nix-darwin modules can pass a custom stateDir via
      # package.override { stateDir = "..."; }.
      # On Darwin the wrapper spawns sandbox-proxy at runtime (ADR-0003);
      # the proxy is exposed as a separate output for direct invocation
      # and testing.
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        if isLinuxSystem system then
          {
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
        if !(isLinuxSystem system) then
          let
            slop = self.lib.slopEnv pkgs;
            slopExpected = [
              "defaults"
              "jail"
              "mkBins"
              "mkShell"
            ];
            slopActual = builtins.attrNames slop;
            binsExpected = [
              "claude"
              "jail-shell"
              "jailedClaude"
              "jailedShell"
              "sandboxedPackages"
              "shellHook"
            ];
            binsActual = builtins.attrNames (
              slop.mkBins {
                projectName = "byteq-test";
                claudeMdFile = ./templates/claude-code/slop-env/claude-config/CLAUDE.md;
                rulesDir = ./templates/claude-code/slop-env/claude-config/rules;
                skillsDir = ./templates/claude-code/slop-env/claude-config/skills;
              }
            );
          in
          {
            # Darwin checks cover:
            #   - sandbox-proxy: the proxy's hostname allowlist matcher
            #     (pure Go).
            #   - sandbox-profile: the Seatbelt profile generator (pure Nix).
            #   - jail-lib: the Jail combinator library (pure Nix).
            #   - sandboxed-darwin: the per-jail wrapper builder.
            #   - lib-slop-env-{shape,mkBins-shape}: darwin.nix
            #     dispatch matches the Linux contract.
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

            # Eval-level only — checks the public options
            # (`enable`, `package`, `stateDir`) plus the anti-tests pinning
            # the deliberate absence of the NixOS module's sudoers/auditd machinery.
            darwin-module = import ./tests/darwin-module.nix {
              inherit pkgs;
              inherit (pkgs) lib;
            };

            # Asserts the claude / jail-shell launchers compute PROJECT_NAME and
            # export NIX_SLOP_DEV_PROJECT_NAME so the per-jail wrapper's
            # SBPL/preflight sed targets the right cfgDir. Mirrors Linux's
            # apps-jail-has-placeholder check at the launcher layer.
            slop-env-darwin = import ./tests/slop-env-darwin.nix {
              inherit pkgs self;
              inherit (pkgs) lib;
            };

            # Darwin parallel of Linux's apps-jail-has-placeholder
            # (flake.nix's Linux branch). The placeholder must survive into
            # the materialised per-jail wrapper — without it, the sed pattern
            # has nothing to match and the apps silently break for any
            # non-template invocation. Greps the SBPL sed pipeline's match pattern
            # via the rendered sandboxed-jailed-claude wrapper.
            apps-darwin-jail-has-placeholder =
              let
                bins = (self.lib.slopEnv pkgs).mkBins { };
                sandboxedClaudeWrapper = builtins.head bins.sandboxedPackages;
              in
              pkgs.runCommand "apps-darwin-jail-has-placeholder" { } ''
                if ! ${pkgs.gnugrep}/bin/grep -q '__SLOP_ENV_PROJECT_NAME__' \
                     ${sandboxedClaudeWrapper}/bin/sandboxed-jailed-claude; then
                  echo "expected __SLOP_ENV_PROJECT_NAME__ in sandboxed-jailed-claude wrapper" >&2
                  exit 1
                fi
                echo "ok" > $out
              '';

            lib-slop-env-shape =
              if slopActual == slopExpected then
                pkgs.runCommand "lib-slop-env-shape" { } ''
                  echo "lib.slopEnv shape: ${builtins.concatStringsSep " " slopActual}" > $out
                ''
              else
                throw "lib.slopEnv shape regressed on Darwin. expected: ${builtins.concatStringsSep " " slopExpected} actual: ${builtins.concatStringsSep " " slopActual}";

            lib-slop-env-mkBins-shape =
              if binsActual == binsExpected then
                pkgs.runCommand "lib-slop-env-mkBins-shape" { } ''
                  echo "lib.slopEnv mkBins shape: ${builtins.concatStringsSep " " binsActual}" > $out
                ''
              else
                throw "lib.slopEnv mkBins shape regressed on Darwin. expected: ${builtins.concatStringsSep " " binsExpected} actual: ${builtins.concatStringsSep " " binsActual}";

            # Regression (HITL 2026-06-19): the jailed-claude OAuth token
            # must persist in the per-project cfgDir, not via a shared-file
            # symlink. claude writes .credentials.json atomically (write
            # .tmp + rename), which (a) detaches a single-file symlink so
            # the token lands as a regular file in cfgDir and the shared
            # target never fills, and (b) is then deleted by the next
            # launch's `ln -sfn -f` preflight — so login was neither
            # detected (banner checked the empty shared file) nor preserved
            # (relaunch clobbered the real token). Two invariants lock it:
            #   1. the emitted shellHook detects login via the per-project
            #      $CLAUDE_CONFIG_DIR/.credentials.json, not a shared sidecar;
            #   2. the rendered jail preflight contains no .credentials.json
            #      symlink to clobber.
            darwin-creds-persist-in-cfgdir =
              let
                # Uses lib defaults (lib/slop-env/defaults/*) for
                # claudeMd/rules — in-repo, so no template path needed; this
                # check only inspects the shellHook + jail preflight, which
                # don't depend on the bundled config contents.
                bins = (self.lib.slopEnv pkgs).mkBins { projectName = "byteq-test"; };
                checksConfigDir =
                  pkgs.lib.hasInfix ''[ ! -s "$CLAUDE_CONFIG_DIR/.credentials.json" ]'' bins.shellHook;
                noSharedCredCheck =
                  !(pkgs.lib.hasInfix "CLAUDE_SHARED_DIR/.credentials.json" bins.shellHook);
                noCredSymlink =
                  !(builtins.any (line: pkgs.lib.hasInfix ".credentials.json" line)
                    bins.jailedClaude.jailData.preflight);
              in
              if checksConfigDir && noSharedCredCheck && noCredSymlink then
                pkgs.runCommand "darwin-creds-persist-in-cfgdir" { } ''
                  echo "login detection targets cfgDir; no credentials symlink in preflight" > $out
                ''
              else
                throw "darwin creds regression: checksConfigDir=${pkgs.lib.boolToString checksConfigDir} noSharedCredCheck=${pkgs.lib.boolToString noSharedCredCheck} noCredSymlink=${pkgs.lib.boolToString noCredSymlink}";

            # Regression (HITL 2026-06-19): the jail launches via
            # `/usr/bin/env -i` (drops TMPDIR) and `(deny default)` blocks
            # /tmp, so without redirection the agent's Node tooling EPERMs
            # creating its temp dir under os.tmpdir()=/tmp. The launchers
            # point TMPDIR into the writable cfgDir and the jail forwards it
            # in. Pin both halves: the launcher redirect and the forward.
            darwin-tmpdir-redirected =
              let
                bins = (self.lib.slopEnv pkgs).mkBins { projectName = "byteq-test"; };
                forwardsTmpdir = builtins.elem "TMPDIR" bins.jailedClaude.jailData.envForward;
              in
              if forwardsTmpdir then
                pkgs.runCommand "darwin-tmpdir-redirected" { } ''
                  launcher=${bins.claude}/bin/claude
                  if ! ${pkgs.gnugrep}/bin/grep -qF 'export TMPDIR="$CLAUDE_CONFIG_DIR/tmp"' "$launcher"; then
                    echo "FAIL: claude launcher doesn't redirect TMPDIR into cfgDir — agent temp would hit jail-denied /tmp" >&2
                    cat "$launcher" >&2
                    exit 1
                  fi
                  echo "TMPDIR redirected into cfgDir and forwarded into the jail" > $out
                ''
              else
                throw "darwin TMPDIR regression: jail does not forward TMPDIR into the sandbox (env -i would drop it)";
          }
        else
          let
            slop = self.lib.slopEnv pkgs;
            # lib re-exposes the initialised jail-nix object so
            # templates can build extraCombinators without importing jail-nix
            # themselves (the nvim template's nvim-dev paths use this).
            expected = [
              "defaults"
              "jail"
              "mkBins"
              "mkShell"
            ];
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

            # Defaults are populated from shared.nix
            # The list must include coreutils.
            # Detects accidental wipes of the default list.
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

            # mkBins assembles the per-OS bins from the template's
            # checked-in claude-config. Asserts the public API shape: keys
            # match the spec and each value is a derivation / string 
            lib-slop-env-mkBins-shape =
              let
                bins = slop.mkBins {
                  projectName = "byteq-test";
                  claudeMdFile = ./templates/claude-code/slop-env/claude-config/CLAUDE.md;
                  rulesDir = ./templates/claude-code/slop-env/claude-config/rules;
                  skillsDir = ./templates/claude-code/slop-env/claude-config/skills;
                };
                expectedKeys = [
                  "claude"
                  "jail-shell"
                  "jailedClaude"
                  "jailedShell"
                  "sandboxedPackages"
                  "shellHook"
                ];
                actualKeys = builtins.attrNames bins;
              in
              if actualKeys == expectedKeys then
                pkgs.runCommand "lib-slop-env-mkBins-shape" { } ''
                  echo "lib.slopEnv mkBins shape: ${builtins.concatStringsSep " " actualKeys}" > $out
                ''
              else
                throw "lib.slopEnv mkBins shape regressed. expected: ${builtins.concatStringsSep " " expectedKeys} actual: ${builtins.concatStringsSep " " actualKeys}";

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

            # ADR-0006 consequence: the roadmap skeletons (opencode, pi-agent)
            # stay UN-EXPORTED (absent from the flake `templates` output) and
            # STILL PARSE, until they are promoted to real templates. A cheap
            # eval guard so a skeleton can neither rot into a parse error
            # unnoticed nor be shipped before it is ready. `import` parses the
            # whole file and returns its builder function; forcing to a lambda
            # (isFunction) proves it parses without evaluating the heavy body
            # (which needs inputs/pkgs/makeNix* it is never given here).
            roadmap-skeletons-guarded =
              let
                skeletons = {
                  opencode = ./templates/opencode/opencode.nix;
                  pi-agent = ./templates/pi-agent/pi-agent.nix;
                };
                names = builtins.attrNames skeletons;
                exportedTemplates = builtins.attrNames self.templates;
                exported = builtins.filter (name: builtins.elem name exportedTemplates) names;
                unparsable = builtins.filter (name: !(builtins.isFunction (import skeletons.${name}))) names;
              in
              if exported != [ ] then
                throw "roadmap skeleton(s) unexpectedly exported in flake `templates`: ${builtins.concatStringsSep " " exported}"
              else if unparsable != [ ] then
                throw "roadmap skeleton(s) no longer parse as a builder function: ${builtins.concatStringsSep " " unparsable}"
              else
                pkgs.runCommand "roadmap-skeletons-guarded" { } ''
                  echo "roadmap skeletons un-exported and still parse: ${builtins.concatStringsSep " " names}" > $out
                '';

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
          }
          // (
            if system == "x86_64-linux" then
              {
                template-claude-code-drv = import ./tests/template-claude-code-drv.nix {
                  inherit
                    self
                    pkgs
                    jail-nix
                    llm-agents
                    ;
                };

                # Slice 19.4: byte-equality baseline for the nvim template.
                # Captured pre-refactor so slice 19.5's template flip can
                # prove it preserves the rendered devShell derivation.
                template-nvim-dev-drv = import ./tests/template-nvim-dev-drv.nix {
                  inherit
                    self
                    pkgs
                    jail-nix
                    llm-agents
                    flake-utils
                    gen-luarc
                    ;
                };
              }
            else
              { }
          )
      );

      # Functional test layer (ADR-0006). Kept OUT of `checks` so that a
      # bare `nix flake check` on a PR runner stays eval-only and fast — these
      # boot a KVM guest and exercise real enforcement. The merge/nightly
      # workflow builds them explicitly:
      #   nix build .#functionalTests.x86_64-linux.sandbox
      # x86_64-linux only: the enforcement primitives (systemd IPAddressDeny,
      # bubblewrap, auditd) are arch-independent, so aarch64 stays eval-level.
      functionalTests = {
        x86_64-linux = {
          # Sandbox (network) boundary: deny-closed, allow-connects,
          # violation-recorded, plus whitelist persistence. First member of
          # the layer; the Jail-boundary nixosTest is the planned second.
          sandbox = import ./tests/sandbox-functional.nix {
            pkgs = nixpkgs.legacyPackages.x86_64-linux;
            sandboxedModule = self.nixosModules.sandboxed;
          };

          # The `--wl-add` LIVE-UPDATE half (ADR-0006 slice 4.1): a host denied
          # at launch becomes reachable from inside the SAME still-running
          # sandbox unit after `sandboxed --wl-add` set-property's it — the
          # runtime counterpart to sandbox-functional.nix's persistence half.
          wl-live-update = import ./tests/sandbox-wl-live-update.nix {
            pkgs = nixpkgs.legacyPackages.x86_64-linux;
            sandboxedModule = self.nixosModules.sandboxed;
          };

          # Jail (filesystem) boundary: path-hidden, project-rw,
          # host-binary-absent. Drives the raw bubblewrap launcher via
          # `jailed-shell -c` with the oracle on the jail PATH.
          jail = import ./tests/jail-functional.nix {
            pkgs = nixpkgs.legacyPackages.x86_64-linux;
            inherit self;
          };

          # Exported templates compose an enforcing jail carrying their
          # configured tooling. Reconstructs each template's jail from its real
          # config via the lib (faithful per the byte-eq checks), then runs the
          # oracle inside it. The nvim arm also asserts its lua tooling /
          # headless plumbing is on the jail PATH.
          template = import ./tests/template-functional.nix {
            pkgs = nixpkgs.legacyPackages.x86_64-linux;
            inherit self;
          };
        };
      }
      # Darwin: no VM-test framework, so the macOS functional harness
      # (ci/macos-functional.sh) runs on a real mac. It needs the shared
      # oracle to run INSIDE the real Seatbelt jail, so we expose the default
      # `jail-shell` rebuilt with curl + the oracle added to projectPkgs
      # (curl is not in defaultBasePkgs). The harness builds this and drives
      # it as `jail-shell [-a host] -- -c '<oracle ...>'`. Mirrors the oracle
      # injection in tests/jail-functional.nix.
      // nixpkgs.lib.genAttrs darwinSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          probeOracle = pkgs.writeShellScriptBin "slop-oracle" (
            builtins.readFile ./tests/oracle/slop-oracle.sh
          );
        in
        {
          probe-jail-shell =
            (
              (self.lib.slopEnv pkgs).mkBins {
                projectName = "macos-functional";
                projectPkgs = [
                  pkgs.curl
                  probeOracle
                ];
              }
            ).jail-shell;
        }
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
        // (
          # setup-linux is the non-NixOS prereq probe + apply tool;
          # Darwin's Seatbelt is daemonless so the app has no Darwin
          # equivalent.
          if isLinuxSystem system then
            {
              setup-linux = {
                type = "app";
                program = "${self.packages.${system}.setup-linux}/bin/setup-linux";
              };
            }
          else
            { }
        )
      );

      # Slop Env construction lib. Templates and apps call lib.slopEnv pkgs
      # to obtain { mkShell; mkBins; defaults; } — see ADR-0005.
      # jail-nix + llm-agents + our own sandboxed package are injected here
      # so callers don't need to wire those inputs themselves.
      lib = {
        slopEnv =
          pkgs:
          let
            system = pkgs.stdenv.hostPlatform.system;
            isDarwin = pkgs.stdenv.isDarwin;
          in
          import ./lib/slop-env {
            inherit pkgs;
            sandboxed = self.packages.${system}.sandboxed;
            prereqGuidance = if isDarwin then null else self.packages.${system}.prereq-guidance;
            claude-pkg = llm-agents.packages.${system}.claude-code;
            # Linux: jail-nix's __functor (bwrap-based combinators).
            # Darwin: nix-slop-dev's Seatbelt combinator library.
            jail = if isDarwin then self.lib.jail pkgs else jail-nix.lib.init pkgs;
          };

        # Seatbelt combinator library for the Darwin Jail (issue 10).
        # Shape mirrors upstream jail-nix's `jail-nix.lib.init pkgs`:
        # consumers call `lib.jail pkgs` to instantiate the library
        # against a concrete pkgs set, then use the returned
        # `combinators` and `jail` constructor to build a per-binary
        # SBPL profile + bind/forward slice (see ADR-0004).
        jail =
          pkgs:
          import ./lib/jail {
            inherit (pkgs) lib;
            inherit pkgs;
          };
      };

      nixosModules = {
        sandboxed = import ./modules/sandboxed/default.nix self;
        default = self.nixosModules.sandboxed;
      };

      # Issue 13: parallel of nixosModules for nix-darwin hosts.
      # Thin by design — installs the sandboxed-darwin package with the
      # configured stateDir. Seatbelt needs no root, so the NixOS
      # module's sudoers/auditd surface has no counterpart here.
      darwinModules = {
        sandboxed = import ./modules/sandboxed-darwin/default.nix self;
        default = self.darwinModules.sandboxed;
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
