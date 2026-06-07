{
  description = "Project development environment with jailed Claude Code";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nix-slop-dev.url = "github:pete3n/nix-slop-dev";
    jail-nix.url = "sourcehut:~alexdavid/jail.nix";
    llm-agents.url = "github:numtide/llm-agents.nix";
  };

  outputs =
    {
      nixpkgs,
      nix-slop-dev,
      jail-nix,
      llm-agents,
      ...
    }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
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
      # Override if building for a different user or in CI.
      cfgDir = builtins.getEnv "HOME" + "/.config/claude";
      skillsDir = ./slop-env/claude-config/skills;

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

      # ── Customize: add your project's packages here ──
      projectPkgs = [
        # lua-language-server
        # stylua
      ];

      jailCombinators = with jail.combinators; [
        network
        time-zone
        mount-cwd
        no-new-session

        (try-readwrite (noescape "~/.claude.json"))
        (tmpfs (noescape cfgDir))
        (ro-bind "${skillsDir}" "${cfgDir}/skills")
        (write-text (noescape "${cfgDir}/settings.json") claudeSettings)
        (write-text (noescape "${cfgDir}/CLAUDE.md") (builtins.readFile ./slop-env/claude-config/CLAUDE.md))

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
      ];

      jailedClaude = jail "jailed-claude" claude-pkg jailCombinators;
      jailedShell = jail "jailed-shell" pkgs.bashInteractive jailCombinators;
    in
    {
      devShells.${system}.default = pkgs.mkShell {
        packages = projectPkgs ++ [
          sandboxed
          jailedClaude
          jailedShell
        ];
        shellHook = ''
          claude() {
            sandboxed -q --allow api.anthropic.com --allow 2607:6bc0::/32 \
              setpriv --ambient-caps=-sys_nice -- jailed-claude "$@"
          }
          alias jail-test="setpriv --ambient-caps=-sys_nice -- jailed-shell"
        '';
      };
    };
}
