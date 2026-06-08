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

      # Add your project's packages here
      projectPkgs = [
        # lua-language-server
        # stylua
      ];

      projectEnv = {
        # Add project ENV VARS here
      };

      jailCombinators =
        with jail.combinators;
        [
          network
          time-zone
          mount-cwd
          no-new-session

          (ro-bind "${pkgs.coreutils}/bin/env" "/usr/bin/env")
          (try-readwrite (noescape "~/.claude.json"))
          (tmpfs (noescape cfgDir))
          (ro-bind "${skillsDir}" "${cfgDir}/skills")
          (write-text (noescape "${cfgDir}/settings.json") claudeSettings)
          (try-readwrite (noescape "${cfgDir}/.credentials.json"))
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

          (try-fwd-env "CLAUDE_CONFIG_DIR")
          (set-env "SHELL" "${pkgs.bashInteractive}/bin/bash")
          (add-pkg-deps (basePkgs ++ projectPkgs))
        ]
        ++ lib.mapAttrsToList (key: value: jail.combinators.set-env key value) projectEnv;

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
        shellHook = # sh
          ''
            export CLAUDE_CONFIG_DIR="$HOME/.config/claude"
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
            _cfg_dir="$HOME/.config/claude"
            if [ ! -s "$_cfg_dir/.credentials.json" ] && [ ! -s "$_cfg_dir/.claude.json" ]; then
            	printf '\033[1;36mℹ Claude Code credentials not found.\033[0m\n'
            	printf '  Run claude to complete OAuth login on first use.\n\n'
            	_setup_ok=0
            fi

            if [ "$_setup_ok" -eq 1 ]; then
            	printf '\033[1;32m✓\033[0m Jailed claude ready. Run \033[1mclaude\033[0m to start.\n'
            fi

            # Jailed Claude Code
            claude() {
            	mkdir -p "$CLAUDE_CONFIG_DIR"
            	touch "$CLAUDE_CONFIG_DIR/.credentials.json" "$CLAUDE_CONFIG_DIR/.claude.json"
            	sandboxed -q --allow api.anthropic.com --allow 2607:6bc0::/32 \
            		-e CLAUDE_CONFIG_DIR \
            		setpriv --ambient-caps=-sys_nice -- jailed-claude "$@"
            }
            alias jail-shell="setpriv --ambient-caps=-sys_nice -- jailed-shell"
          '';
      };
    };
}
