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
      systems = [ "x86_64-linux" "aarch64-linux" ];
      neovim-overlay = import ./neovim-overlay.nix { inherit inputs; };
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
        homeDir = builtins.getEnv "HOME";
        cfgDir = homeDir + "/.config/claude";
        skillsDir = ./claude-config/skills;

        basePkgs = with pkgs; [
          bashInteractive
          coreutils
          diffutils
          findutils
          gawk
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

            (try-readwrite (noescape "~/.claude.json"))
            (tmpfs (noescape cfgDir))
            (ro-bind "${skillsDir}" "${cfgDir}/skills")
            (write-text (noescape "${cfgDir}/settings.json") claudeSettings)
            (write-text (noescape "${cfgDir}/CLAUDE.md") (builtins.readFile ./claude-config/CLAUDE.md))

            # Persistent runtime state
            (try-readwrite (noescape "${cfgDir}/.claude.json"))
            (try-readwrite (noescape "${cfgDir}/.credentials.json"))
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

            (try-readwrite (noescape "~/.cache"))
            (try-readwrite (noescape "~/.npm"))
            (try-readwrite (noescape "~/.local/share/claude-code"))

            (set-env "CLAUDE_CONFIG_DIR" cfgDir)
            (set-env "SHELL" "${pkgs.bashInteractive}/bin/bash")
            (add-pkg-deps (basePkgs ++ projectPkgs))
          ]
          ++ lib.mapAttrsToList (k: v: jail.combinators.set-env k v) projectEnv;

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
          shellHook = ''
            # Neovim dev environment setup
            ln -fs ${pkgs.nvim-luarc-json} .luarc.json
            mkdir -p ~/.config
            ln -Tfns $PWD/nvim ~/.config/nvim-dev

            export NVIM_PACKPATH="${nvimPackDir}"
            export NVIM_RTP="${nvimPackDir}"
            export VIMRUNTIME="${nvimDev}/share/nvim/runtime"
            export LUA_PATH="$PWD/lua/?.lua;$PWD/lua/?/init.lua;$PWD/plugin/?.lua;$PWD/plugin/?/init.lua;$LUA_PATH"

            printf 'nvim-dev: %s\n' "$(which nvim-dev)"
            printf 'NVIM_PACKPATH: %s\n' "$NVIM_PACKPATH"
            printf 'VIMRUNTIME: %s\n' "$VIMRUNTIME"

            # Jailed Claude Code
            claude() {
              sandboxed -q --allow api.anthropic.com --allow 2607:6bc0::/32 \
                setpriv --ambient-caps=-sys_nice -- jailed-claude "$@"
            }
            alias jail-test="setpriv --ambient-caps=-sys_nice -- jailed-shell"
            printf "Jailed claude available. Run claude to start.\n"
          '';
        };
      }
    )
    // {
      overlays.default = neovim-overlay;
    };
}
