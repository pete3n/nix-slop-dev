{
  description = "Sandboxed AI agent development environments for NixOS and nix-darwin";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    jail-nix.url = "sourcehut:~alexdavid/jail.nix";
    llm-agents.url = "github:numtide/llm-agents.nix";
    hunk.url = "github:modem-dev/hunk";
    hunk.inputs.nixpkgs.follows = "nixpkgs";
    flake-utils.url = "github:numtide/flake-utils";
    gen-luarc.url = "github:mrcjkb/nix-gen-luarc-json";
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-unstable,
      jail-nix,
      llm-agents,
      flake-utils,
      gen-luarc,
      hunk,
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

            # CI test harness script
            slop-oracle = pkgs.writeShellScriptBin "slop-oracle" (
              builtins.readFile ./tests/oracle/slop-oracle.sh
            );
            hunk = hunk.packages.${system}.default;
            worktrunk = nixpkgs-unstable.legacyPackages.${system}.worktrunk;
            default = self.packages.${system}.sandboxed;
          }
        else
          let
            sandbox-proxy = pkgs.callPackage ./packages/sandbox-proxy/default.nix { };
          in
          {
            inherit sandbox-proxy;
            sandboxed = pkgs.callPackage ./packages/sandboxed-darwin/default.nix { inherit sandbox-proxy; };
            hunk = hunk.packages.${system}.default;
            worktrunk = nixpkgs-unstable.legacyPackages.${system}.worktrunk;
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
              "profiles"
            ];
            slopActual = builtins.attrNames slop;
            binsExpected = [
              "agent"
              "jail-shell"
              "jailedAgent"
              "jailedShell"
              "sandboxedPackages"
              "shellHook"
            ];
            binsActual = builtins.attrNames (
              slop.mkBins {
                projectName = "byteq-test";
                agentMdFile = ./templates/claude-code/slop-env/claude-config/CLAUDE.md;
                rulesDir = ./templates/claude-code/slop-env/claude-config/rules;
                skillsDir = ./templates/claude-code/slop-env/claude-config/skills;
              }
            );
          in
          {
            # Darwin checks cover:
            #   - sandbox-proxy: custom Go proxy package to workaround Seatbelt limitations
            #   - sandbox-profile: the Seatbelt profile generator.
            #   - jail-lib: the Jail combinator library.
            #   - sandboxed-darwin: the per-jail wrapper builder.
            #   - lib-slop-env-{shape,mkBins-shape}: darwin.nix
            #     dispatch matches the Linux contract.
            sandbox-proxy = import ./tests/sandbox-proxy.nix { inherit pkgs; };
            worktrunk-reexport =
              let
                worktrunkPkg = self.packages.${system}.worktrunk;
                isDrv = pkgs.lib.isDerivation worktrunkPkg;
                mainProgram = worktrunkPkg.meta.mainProgram or null;
              in
              if isDrv && mainProgram == "wt" then
                pkgs.runCommand "worktrunk-reexport" { } ''
                  echo "worktrunk re-export resolves to a derivation with mainProgram=wt" > $out
                ''
              else
                throw "worktrunk re-export regressed: isDrv=${pkgs.lib.boolToString isDrv} mainProgram=${toString mainProgram}";

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

            darwin-module = import ./tests/darwin-module.nix {
              inherit pkgs;
              inherit (pkgs) lib;
            };

            slop-env-darwin = import ./tests/slop-env-darwin.nix {
              inherit pkgs self;
              inherit (pkgs) lib;
            };

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

            apps-pi-darwin-jail-has-placeholder =
              let
                slop = self.lib.slopEnv pkgs;
                piBins = slop.mkBins { agent = slop.profiles.pi; };
                sandboxedPiWrapper = builtins.head piBins.sandboxedPackages;
              in
              pkgs.runCommand "apps-pi-darwin-jail-has-placeholder" { } ''
                if ! ${pkgs.gnugrep}/bin/grep -q '__SLOP_ENV_PROJECT_NAME__' \
                     ${sandboxedPiWrapper}/bin/sandboxed-jailed-pi; then
                  echo "expected __SLOP_ENV_PROJECT_NAME__ in sandboxed-jailed-pi wrapper" >&2
                  exit 1
                fi
                echo "ok" > $out
              '';

            apps-opencode-darwin-scratch-exchange =
              let
                slop = self.lib.slopEnv pkgs;
                ocBins = slop.mkBins { agent = slop.profiles.opencode; };
              in
              pkgs.runCommand "apps-opencode-darwin-scratch-exchange" { } ''
                launcher=${ocBins.agent}/bin/opencode
                if ! ${pkgs.gnugrep}/bin/grep -qF -- '-e TMPDIR -e OPENCODE_EXCHANGE_DIR' "$launcher"; then
                  echo "FAIL: darwin opencode launcher does not forward TMPDIR + OPENCODE_EXCHANGE_DIR" >&2
                  exit 1
                fi
                if ${pkgs.gnugrep}/bin/grep -q '__SLOP_ENV_PROJECT_NAME__' "$launcher"; then
                  echo "FAIL: darwin opencode launcher contains __SLOP_ENV_PROJECT_NAME__ — ADR-0010 says it must not" >&2
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

            darwin-creds-persist-in-cfgdir =
              let
                bins = (self.lib.slopEnv pkgs).mkBins { projectName = "byteq-test"; };
                checksConfigDir = pkgs.lib.hasInfix ''[ ! -s "$CLAUDE_CONFIG_DIR/.credentials.json" ]'' bins.shellHook;
                noSharedCredCheck = !(pkgs.lib.hasInfix "CLAUDE_SHARED_DIR/.credentials.json" bins.shellHook);
                noCredSymlink =
                  !(builtins.any (
                    line: pkgs.lib.hasInfix ".credentials.json" line
                  ) bins.jailedAgent.jailData.preflight);
              in
              if checksConfigDir && noSharedCredCheck && noCredSymlink then
                pkgs.runCommand "darwin-creds-persist-in-cfgdir" { } ''
                  echo "login detection targets cfgDir; no credentials symlink in preflight" > $out
                ''
              else
                throw "darwin creds regression: checksConfigDir=${pkgs.lib.boolToString checksConfigDir} noSharedCredCheck=${pkgs.lib.boolToString noSharedCredCheck} noCredSymlink=${pkgs.lib.boolToString noCredSymlink}";

            darwin-tmpdir-redirected =
              let
                bins = (self.lib.slopEnv pkgs).mkBins { projectName = "byteq-test"; };
                forwardsTmpdir = builtins.elem "TMPDIR" bins.jailedAgent.jailData.envForward;
              in
              if forwardsTmpdir then
                pkgs.runCommand "darwin-tmpdir-redirected" { } ''
                  launcher=${bins.agent}/bin/claude
                  if ! ${pkgs.gnugrep}/bin/grep -qF 'export TMPDIR="$CLAUDE_CONFIG_DIR/tmp"' "$launcher"; then
                    echo "FAIL: claude launcher doesn't redirect TMPDIR into cfgDir — agent temp would hit jail-denied /tmp" >&2
                    cat "$launcher" >&2
                    exit 1
                  fi
                  echo "TMPDIR redirected into cfgDir and forwarded into the jail" > $out
                ''
              else
                throw "darwin TMPDIR regression: jail does not forward TMPDIR into the sandbox (env -i would drop it)";

            darwin-exchange-forwarded =
              let
                bins = (self.lib.slopEnv pkgs).mkBins { projectName = "byteq-test"; };
                forwardsExchange = builtins.elem "CLAUDE_EXCHANGE_DIR" bins.jailedAgent.jailData.envForward;
              in
              if forwardsExchange then
                pkgs.runCommand "darwin-exchange-forwarded" { } ''
                  launcher=${bins.agent}/bin/claude
                  if ! ${pkgs.gnugrep}/bin/grep -qF 'export CLAUDE_EXCHANGE_DIR="$CLAUDE_CONFIG_DIR/exchange"' "$launcher"; then
                    echo "FAIL: claude launcher doesn't export CLAUDE_EXCHANGE_DIR into cfgDir" >&2
                    cat "$launcher" >&2
                    exit 1
                  fi
                  echo "CLAUDE_EXCHANGE_DIR exported into cfgDir and forwarded into the jail" > $out
                ''
              else
                throw "darwin exchange regression: jail does not forward CLAUDE_EXCHANGE_DIR into the sandbox";
          }
        else
          let
            slop = self.lib.slopEnv pkgs;
            expected = [
              "defaults"
              "jail"
              "mkBins"
              "mkShell"
              "profiles"
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

            worktrunk-reexport =
              let
                worktrunkPkg = self.packages.${system}.worktrunk;
                isDrv = pkgs.lib.isDerivation worktrunkPkg;
                mainProgram = worktrunkPkg.meta.mainProgram or null;
              in
              if isDrv && mainProgram == "wt" then
                pkgs.runCommand "worktrunk-reexport" { } ''
                  echo "worktrunk re-export resolves to a derivation with mainProgram=wt" > $out
                ''
              else
                throw "worktrunk re-export regressed: isDrv=${pkgs.lib.boolToString isDrv} mainProgram=${toString mainProgram}";

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

            lib-slop-env-mkBins-shape =
              let
                bins = slop.mkBins {
                  projectName = "byteq-test";
                  agentMdFile = ./templates/claude-code/slop-env/claude-config/CLAUDE.md;
                  rulesDir = ./templates/claude-code/slop-env/claude-config/rules;
                  skillsDir = ./templates/claude-code/slop-env/claude-config/skills;
                };
                expectedKeys = [
                  "agent"
                  "jail-shell"
                  "jailedAgent"
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
                piApp = self.apps.${system}.pi or null;
                opencodeApp = self.apps.${system}.opencode or null;
                ok = app: app != null && (app.type or null) == "app" && (app.program or null) != null;
              in
              if ok claudeApp && ok jailShellApp && ok piApp && ok opencodeApp then
                pkgs.runCommand "apps-shape" { } ''
                  echo "apps.${system}.{claude,jail-shell,pi,opencode} wired" > $out
                ''
              else
                throw "apps.${system}.{claude,jail-shell,pi,opencode} missing or wrong shape";

            apps-jail-has-placeholder =
              let
                bins = (self.lib.slopEnv pkgs).mkBins { };
              in
              pkgs.runCommand "apps-jail-has-placeholder" { } ''
                if ! grep -q "__SLOP_ENV_PROJECT_NAME__" ${bins.jailedAgent}/bin/jailed-claude; then
                  echo "expected __SLOP_ENV_PROJECT_NAME__ placeholder in jailed-claude launch script" >&2
                  exit 1
                fi
                echo "ok" > $out
              '';

            apps-pi-jail-has-placeholder =
              let
                slop = self.lib.slopEnv pkgs;
                piBins = slop.mkBins { agent = slop.profiles.pi; };
              in
              pkgs.runCommand "apps-pi-jail-has-placeholder" { } ''
                if ! grep -q "__SLOP_ENV_PROJECT_NAME__" ${piBins.jailedAgent}/bin/jailed-pi; then
                  echo "expected __SLOP_ENV_PROJECT_NAME__ placeholder in jailed-pi launch script" >&2
                  exit 1
                fi
                echo "ok" > $out
              '';

            apps-pi-scratch-exchange =
              let
                slop = self.lib.slopEnv pkgs;
                piBins = slop.mkBins { agent = slop.profiles.pi; };
              in
              pkgs.runCommand "apps-pi-scratch-exchange" { } ''
                if ! ${pkgs.gnugrep}/bin/grep -qF -- '-e TMPDIR -e PI_EXCHANGE_DIR' ${piBins.agent}/bin/pi; then
                  echo "FAIL: pi launcher does not forward TMPDIR + PI_EXCHANGE_DIR through sandboxed" >&2
                  exit 1
                fi
                echo "pi Scratch + Exchange forwarded on the pi launcher" > $out
              '';

            apps-opencode-scratch-exchange =
              let
                slop = self.lib.slopEnv pkgs;
                ocBins = slop.mkBins { agent = slop.profiles.opencode; };
              in
              pkgs.runCommand "apps-opencode-scratch-exchange" { } ''
                if ! ${pkgs.gnugrep}/bin/grep -qF -- '-e TMPDIR -e OPENCODE_EXCHANGE_DIR' ${ocBins.agent}/bin/opencode; then
                  echo "FAIL: opencode launcher does not forward TMPDIR + OPENCODE_EXCHANGE_DIR through sandboxed" >&2
                  exit 1
                fi
                if ${pkgs.gnugrep}/bin/grep -q '__SLOP_ENV_PROJECT_NAME__' ${ocBins.agent}/bin/opencode; then
                  echo "FAIL: opencode launcher contains __SLOP_ENV_PROJECT_NAME__ — ADR-0010 says it must not (no placeholder/sed)" >&2
                  exit 1
                fi
                echo "opencode Scratch + Exchange forwarded; no placeholder in launcher (ADR-0010)" > $out
              '';

            template-default-config-matches-lib = import ./tests/template-default-config-matches-lib.nix {
              inherit pkgs;
            };

            # Multi-endpoint Local AI feature (Slices 1-6; ADRs 0011/0012/0013).
            # Pure-eval: the profile generators turn the localAi option
            # into provider/worker config, asserted at eval time (throws on
            # mismatch). System-agnostic, so it lives in the shared block.
            local-ai-config = import ./tests/local-ai-config.nix {
              inherit self pkgs;
            };

            # Allow for incomplete project templates without throwing CI errors
            roadmap-skeletons-guarded =
              let
                skeletons = { };
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

            lib-slop-env-scratch-exchange =
              let
                bins = (self.lib.slopEnv pkgs).mkBins { projectName = "byteq-test"; };
                hook = bins.shellHook;
                exportsTmpdir = pkgs.lib.hasInfix ''export TMPDIR="$CLAUDE_CONFIG_DIR/tmp"'' hook;
                exportsExchange = pkgs.lib.hasInfix ''export CLAUDE_EXCHANGE_DIR="$CLAUDE_CONFIG_DIR/exchange"'' hook;
                forwardsBoth = pkgs.lib.hasInfix "-e TMPDIR -e CLAUDE_EXCHANGE_DIR" hook;
              in
              if exportsTmpdir && exportsExchange && forwardsBoth then
                pkgs.runCommand "lib-slop-env-scratch-exchange" { } ''
                  for launcher in ${bins.agent}/bin/claude ${bins.jail-shell}/bin/jail-shell; do
                    if ! ${pkgs.gnugrep}/bin/grep -qF -- '-e TMPDIR -e CLAUDE_EXCHANGE_DIR' "$launcher"; then
                      echo "FAIL: $launcher does not forward TMPDIR + CLAUDE_EXCHANGE_DIR through sandboxed" >&2
                      exit 1
                    fi
                  done
                  echo "Scratch + Exchange exported and forwarded on Linux launchers + shellHook" > $out
                ''
              else
                throw "linux scratch/exchange regression: exportsTmpdir=${pkgs.lib.boolToString exportsTmpdir} exportsExchange=${pkgs.lib.boolToString exportsExchange} forwardsBoth=${pkgs.lib.boolToString forwardsBoth}";

            nixos-module = import ./tests/nixos-module.nix {
              inherit nixpkgs pkgs system;
              sandboxedModule = self.nixosModules.sandboxed;
            };

            wrapper-tool-resolution = import ./tests/wrapper-tool-resolution.nix {
              inherit pkgs;
              sandboxed = self.packages.${system}.sandboxed;
            };

            setup-linux-checks = import ./tests/setup-linux-checks.nix {
              inherit pkgs;
            };

            setup-linux-app = import ./tests/setup-linux-app.nix {
              inherit pkgs;
              setupLinux = self.packages.${system}.setup-linux;
            };

            setup-linux-apply = import ./tests/setup-linux-apply.nix {
              inherit pkgs;
            };

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

                template-pi-agent-drv = import ./tests/template-pi-agent-drv.nix {
                  inherit self pkgs;
                };

                template-opencode-drv = import ./tests/template-opencode-drv.nix {
                  inherit self pkgs;
                };

                # ADR-0014 per-Account credential isolation: launcher-level
                # behaviour (Account resolution + deny-by-default validation)
                # that is observable without bwrap/namespaces. The full
                # simultaneous-two-Account filesystem behaviour lives in the
                # nixosTest functional suite (functionalTests below).
                account-launcher = import ./tests/account-launcher.nix {
                  inherit self pkgs;
                };

                account-isolation = import ./tests/account-isolation.nix {
                  inherit self pkgs;
                };

                account-apikey = import ./tests/account-apikey.nix {
                  inherit self pkgs;
                };

                account-name-validation = import ./tests/account-name-validation.nix {
                  inherit self pkgs;
                };

                account-zerotouch-refused = import ./tests/account-zerotouch-refused.nix {
                  inherit self pkgs;
                };

                account-apikey-unreadable = import ./tests/account-apikey-unreadable.nix {
                  inherit self pkgs;
                };
              }
            else
              { }
          )
      );

      functionalTests = {
        x86_64-linux = {
          sandbox = import ./tests/sandbox-functional.nix {
            pkgs = nixpkgs.legacyPackages.x86_64-linux;
            sandboxedModule = self.nixosModules.sandboxed;
          };

          wl-live-update = import ./tests/sandbox-wl-live-update.nix {
            pkgs = nixpkgs.legacyPackages.x86_64-linux;
            sandboxedModule = self.nixosModules.sandboxed;
          };

          jail = import ./tests/jail-functional.nix {
            pkgs = nixpkgs.legacyPackages.x86_64-linux;
            inherit self;
          };

          template = import ./tests/template-functional.nix {
            pkgs = nixpkgs.legacyPackages.x86_64-linux;
            inherit self;
          };

          # Boots the real jailed opencode under the bwrap jail and asserts no
          # config-dir write is denied — the runtime coverage the opencode
          # .gitignore EPERM slipped through (macOS counterpart, covering all
          # three agents on Seatbelt, lives in ci/macos-functional.sh).
          agent-boot = import ./tests/agent-boot-functional.nix {
            pkgs = nixpkgs.legacyPackages.x86_64-linux;
            inherit self;
          };

          account = import ./tests/account-functional.nix {
            pkgs = nixpkgs.legacyPackages.x86_64-linux;
            inherit self;
          };
        };
      }
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
            ((self.lib.slopEnv pkgs).mkBins {
              projectName = "macos-functional";
              projectPkgs = [
                pkgs.curl
                probeOracle
              ];
            }).jail-shell;

          # Zero-touch opencode launcher (mirrors `nix run .#opencode`), built
          # so ci/macos-functional.sh can boot the REAL jailed opencode under
          # Seatbelt and assert it gets through Config bootstrap. Every other
          # macOS check is static (it greps this launcher / its SBPL, never runs
          # it) and the byte-equality pin only flips on OUR eval changes — so an
          # upstream opencode that writes into its config dir at boot (the err_*
          # EPERM on ~/.config/opencode/.gitignore via Config.loadInstanceState)
          # sails straight through. This probe is the runtime signal that would
          # have caught it. ".agent" is bin/opencode.
          probe-opencode-boot =
            ((self.lib.slopEnv pkgs).mkBins {
              agent = (self.lib.slopEnv pkgs).profiles.opencode;
            }).agent;

          # claude (.agent = bin/claude) and pi (bin/pi) zero-touch launchers,
          # same purpose. Both profiles already make their config dir writable
          # (claude's tmpfs/ensure-dir cfgDir; pi's `try-readwrite ~/.pi/agent`),
          # so these are REGRESSION guards: they pass today and go red if a
          # future change makes a config dir read-only the way opencode's was.
          probe-claude-boot = ((self.lib.slopEnv pkgs).mkBins { }).agent;
          probe-pi-boot =
            ((self.lib.slopEnv pkgs).mkBins {
              agent = (self.lib.slopEnv pkgs).profiles.pi;
            }).agent;
        }
      );

      apps = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          slop = self.lib.slopEnv pkgs;
          bins = slop.mkBins { };
          piBins = slop.mkBins { agent = slop.profiles.pi; };
          ocBins = slop.mkBins { agent = slop.profiles.opencode; };
        in
        {
          claude = {
            type = "app";
            program = "${bins.agent}/bin/claude";
            meta.description = "Zero-touch jailed Claude Code Slop Env for the current project";
          };
          jail-shell = {
            type = "app";
            program = "${bins.jail-shell}/bin/jail-shell";
            meta.description = "Zero-touch jailed interactive shell with the current project's Slop Env";
          };
          pi = {
            type = "app";
            program = "${piBins.agent}/bin/pi";
            meta.description = "Zero-touch jailed Pi (earendil-works/pi) Slop Env for the current project";
          };
          opencode = {
            type = "app";
            program = "${ocBins.agent}/bin/opencode";
            meta.description = "Zero-touch jailed opencode (sst/opencode) Slop Env for the current project";
          };
        }
        // (
          if isLinuxSystem system then
            {
              setup-linux = {
                type = "app";
                program = "${self.packages.${system}.setup-linux}/bin/setup-linux";
                meta.description = "Diagnose and optionally apply Sandbox/Jail prerequisites on non-NixOS Linux";
              };
            }
          else
            { }
        )
      );

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
            pi-pkg = llm-agents.packages.${system}.pi;
            opencode-pkg = llm-agents.packages.${system}.opencode;
            # Linux: jail-nix's __functor (bwrap-based combinators).
            # Darwin: nix-slop-dev's Seatbelt combinator library.
            jail = if isDarwin then self.lib.jail pkgs else jail-nix.lib.init pkgs;
          };

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

        pi-agent = {
          path = ./templates/pi-agent;
          description = "Jailed Pi (earendil-works/pi) environment with sandboxed network isolation";
        };

        opencode = {
          path = ./templates/opencode;
          description = "Jailed opencode (sst/opencode) environment with sandboxed network isolation";
        };
      };
    };
}
