{
  description = "Neovim plugin development with jailed Claude Code";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    flake-utils.url = "github:numtide/flake-utils";
    gen-luarc.url = "github:mrcjkb/nix-gen-luarc-json";
    nix-slop-dev.url = "github:pete3n/nix-slop-dev";
    jail-nix.url = "sourcehut:~alexdavid/jail.nix";
    llm-agents.url = "github:numtide/llm-agents.nix";
  };

  outputs =
    inputs@{
      nixpkgs,
      flake-utils,
      nix-slop-dev,
      jail-nix,
      llm-agents,
      ...
    }:
    let
      # Darwin not supported by the sandbox solution
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      neovim-overlay = import ./slop-env/nix/neovim-overlay.nix { inherit inputs; };
    in
    flake-utils.lib.eachSystem systems (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [
            neovim-overlay
            inputs.gen-luarc.overlays.default
          ];
        };
        lib = pkgs.lib;

        nvimDev = pkgs.nvim-dev;
        nvimPackDir = nvimDev.packDir;

        jail = jail-nix.lib.init pkgs;
        claude-pkg = llm-agents.packages.${system}.claude-code;
        sandboxed = nix-slop-dev.packages.${system}.sandboxed;

        claudeSettings = builtins.toJSON {
          autoUpdaterStatus = "disabled";
          theme = "dark-ansi";
          permissions = {
            allow = [ ];
            deny = [ ];
          };
        };

        # Resolved at nix eval time — correct for local devShell builds.
        projectName = "slop-dev-nvim-project"; # Update per-project
        sharedDir = "~/.local/state/claude/shared";
        cfgDir = "~/.local/state/claude/projects/${projectName}";
        skillsDir = ./slop-env/claude-config/skills;
        rulesDir = ./slop-env/claude-config/rules;

        # CLAUDE.md ships as the base file followed by every rules/*.md,
        # concatenated so universal policy is always in context (unlike
        # relevance-recalled memory, which is per-project and dynamically pathed).
        claudeMd =
          let
            ruleNames = builtins.attrNames (
              pkgs.lib.filterAttrs (name: kind: kind == "regular" && pkgs.lib.hasSuffix ".md" name) (
                builtins.readDir rulesDir
              )
            );
            ruleBodies = map (name: builtins.readFile (rulesDir + "/${name}")) ruleNames;
          in
          pkgs.lib.concatStringsSep "\n\n" (
            [ (builtins.readFile ./slop-env/claude-config/CLAUDE.md) ] ++ ruleBodies
          );

        basePkgs = with pkgs; [
          bashInteractive
          bc
          coreutils
          diffutils
          findutils
          gawk
          gh
          git
          gnugrep
          gnused
          gnutar
          gzip
          jq
          nix
          ps
          ripgrep
          unzip
          which
        ];

        projectPkgs = with pkgs; [
          lua-language-server
          nixd
          stylua
          luajitPackages.luacheck
          luajitPackages.busted
          nvimDev
        ];

        projectEnv = {
          VIMRUNTIME = "${nvimDev}/share/nvim/runtime";
          NVIM_PACKPATH = "${nvimPackDir}";
          NVIM_RTP = "${nvimPackDir}";
        };

        jailCombinators =
          with jail.combinators;
          [
            network
            time-zone
            mount-cwd
            no-new-session

            (ro-bind "${pkgs.coreutils}/bin/env" "/usr/bin/env")

            # Ephemeral config dir; project-fixed content written on top.
            (tmpfs (noescape cfgDir))
            (ro-bind "${skillsDir}" (noescape "${cfgDir}/skills"))
            (write-text (noescape "${cfgDir}/settings.json") claudeSettings)
            (write-text (noescape "${cfgDir}/CLAUDE.md") claudeMd)

            # Shared identity, grafted into the per-project config dir.
            # Host file must exist before launch (touched in shellHook).
            (rw-bind (noescape "${sharedDir}/.credentials.json") (noescape "${cfgDir}/.credentials.json"))

            # Per-project persistent state.
            (try-readwrite (noescape "${cfgDir}/.claude.json"))
            (try-readwrite (noescape "${cfgDir}/.last-cleanup"))
            (try-readwrite (noescape "${cfgDir}/backups"))
            (try-readwrite (noescape "${cfgDir}/history.jsonl"))
            (try-readwrite (noescape "${cfgDir}/plugins"))
            (try-readwrite (noescape "${cfgDir}/policy-limits.json"))
            (try-readwrite (noescape "${cfgDir}/projects"))
            (try-readwrite (noescape "${cfgDir}/remote-settings.json"))
            (try-readwrite (noescape "${cfgDir}/session-env"))
            (try-readwrite (noescape "${cfgDir}/sessions"))
            (try-readwrite (noescape "${cfgDir}/shell-snapshots"))
            (try-readwrite (noescape "${cfgDir}/statsig"))
            (try-readwrite (noescape "${cfgDir}/todos"))

            # Shared caches — safe to share, contents are content-addressed
            # or per-package, not per-session state.
            (try-readwrite (noescape "~/.cache"))
            (try-readwrite (noescape "~/.npm"))
            (try-readwrite (noescape "~/.local/share/claude-code"))

            # nvim-dev runtime state
            (try-readwrite (noescape "~/.local/state/nvim-dev"))
            (try-readwrite (noescape "~/.local/share/nvim-dev"))
            # Host symlink to $PWD/nvim; bwrap resolves the source host-side
            (try-readwrite (noescape "~/.config/nvim-dev"))
            # $PWD-dependent, so it travels the runtime forwarding chain
            (try-fwd-env "LUA_PATH")

            (try-fwd-env "CLAUDE_CONFIG_DIR")
            (set-env "SHELL" "${pkgs.bashInteractive}/bin/bash")
            (add-pkg-deps (basePkgs ++ projectPkgs))

            (ro-bind "${pkgs.nvim-luarc-json}" "${pkgs.nvim-luarc-json}")
          ]
          ++ lib.mapAttrsToList (key: value: jail.combinators.set-env key value) projectEnv;

        jailedClaude = jail "jailed-claude" claude-pkg jailCombinators;
        jailedShell = jail "jailed-shell" pkgs.bashInteractive jailCombinators;
      in
      {
        packages = {
          default = nvimDev;
          nvim = pkgs.nvim-pkg;
        };

        devShells.default = pkgs.mkShell {
          name = "nvim-claude-devShell";
          buildInputs = projectPkgs ++ [
            sandboxed
            jailedClaude
            jailedShell
          ];
          shellHook = # sh
            ''
              # Project unique clonfig
              export CLAUDE_CONFIG_DIR="$HOME/.local/state/claude/projects/${projectName}"
              export CLAUDE_SHARED_DIR="$HOME/.local/state/claude/shared"
              mkdir -p "$CLAUDE_CONFIG_DIR" "$CLAUDE_SHARED_DIR"
              touch "$CLAUDE_SHARED_DIR/.credentials.json" "$CLAUDE_CONFIG_DIR/.claude.json"

              export NVIM_PACKPATH="${nvimPackDir}"
              export NVIM_RTP="${nvimPackDir}"
              export VIMRUNTIME="${nvimDev}/share/nvim/runtime"
              export LUA_PATH="$PWD/lua/?.lua;$PWD/lua/?/init.lua;$PWD/plugin/?.lua;$PWD/plugin/?/init.lua;''${LUA_PATH:-}"

              # Neovim dev environment setup
              ln -fs ${pkgs.nvim-luarc-json} .luarc.json
              mkdir -p ~/.config
              rm -rf ~/.local/state/nvim-dev/swap
              mkdir -p ~/.local/state/nvim-dev/swap
              ln -Tfns "$PWD/nvim" ~/.config/nvim-dev
              printf 'nvim-dev: %s\n' "$(which nvim-dev)"


              # Setup checks
              _setup_ok=1

              # Check system prerequisites
              if ! systemctl is-active --quiet auditd 2>/dev/null; then
              	printf '\033[1;33m⚠ auditd is not running.\033[0m\n'
              	printf '  The sandboxed wrapper requires auditd for violation detection.\n'
              	printf '  Add to your NixOS config:\n'
              	printf '    security.sandboxed.enable = true;\n'
              	printf '    security.sandboxed.users = [ "<your-user>" ];\n\n'
              	_setup_ok=0
              fi

              if ! sudo -n ${pkgs.systemd}/bin/systemd-run --help >/dev/null 2>&1; then
              	printf '\033[1;33m⚠ NOPASSWD sudo for systemd-run is not configured.\033[0m\n'
              	printf '  The sandboxed wrapper needs passwordless sudo for:\n'
              	printf '    systemd-run, systemctl, auditctl, ausearch, tail\n'
              	printf '  Add to your NixOS config:\n'
              	printf '    security.sandboxed.users = [ "<your-user>" ];\n\n'
              	_setup_ok=0
              fi

              # Check Claude credentials
              if [ ! -s "$CLAUDE_SHARED_DIR/.credentials.json" ]; then
              	printf '\033[1;36mℹ Claude Code credentials not found.\033[0m\n'
              	printf '  Run claude to complete OAuth login on first use.\n\n'
              	_setup_ok=0
              fi

              if [ "$_setup_ok" -eq 1 ]; then
              	printf '\033[1;32m✓\033[0m Jailed claude ready. Run \033[1mclaude\033[0m to start.\n'
              fi

              # Jailed Claude Code
              claude() {
              	mkdir -p "$CLAUDE_CONFIG_DIR" "$CLAUDE_SHARED_DIR"
              	touch "$CLAUDE_SHARED_DIR/.credentials.json" "$CLAUDE_CONFIG_DIR/.claude.json"
              	sandboxed -q --allow api.anthropic.com --allow 2607:6bc0::/32 \
              		-e CLAUDE_CONFIG_DIR \
              		-e LUA_PATH \
              		setpriv --ambient-caps=-sys_nice -- jailed-claude "$@"
              }
              alias jail-shell="setpriv --ambient-caps=-sys_nice -- jailed-shell"
            '';
        };
      }
    )
    // {
      overlays.default = neovim-overlay;
    };
}
