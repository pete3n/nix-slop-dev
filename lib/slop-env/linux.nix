{ pkgs
, sandboxed
, claude-pkg
, jail
, shared
}:

# Linux-specific Slop Env assembly. NixOS prereq checks (auditd +
# NOPASSWD-sudo) live here. The non-NixOS-Linux variant lands in slice 20.
#
# Produces { mkShell; mkBins; } consumed by lib/slop-env/default.nix.

let
  lib = pkgs.lib;

  mkBins =
    { projectName
    , rulesDir
    , skillsDir
    , claudeMdFile
    , basePkgs ? shared.defaultBasePkgs
    , projectPkgs ? [ ]
    , projectEnv ? { }
    , extraCombinators ? [ ]
    }:
    let
      claudeMd = shared.mkClaudeMd { inherit rulesDir claudeMdFile; };
      claudeSettings = shared.defaultClaudeSettings;

      jailCombinators =
        (shared.mkJailCombinators {
          inherit jail projectName skillsDir claudeMd claudeSettings basePkgs projectPkgs projectEnv;
        })
        ++ extraCombinators;

      jailedClaude = jail "jailed-claude" claude-pkg jailCombinators;
      jailedShell = jail "jailed-shell" pkgs.bashInteractive jailCombinators;

      # Linux currently has one sandboxed wrapper for both jails (slice 21
      # adds Darwin's per-jail variant).
      sandboxedPackages = [ sandboxed ];

      shellHook = # sh
        ''
          # Project unique config
          export CLAUDE_CONFIG_DIR="$HOME/.local/state/claude/projects/${projectName}"
          export CLAUDE_SHARED_DIR="$HOME/.local/state/claude/shared"
          mkdir -p "$CLAUDE_CONFIG_DIR" "$CLAUDE_SHARED_DIR"
          touch "$CLAUDE_SHARED_DIR/.credentials.json" "$CLAUDE_CONFIG_DIR/.claude.json"

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
          		setpriv --ambient-caps=-sys_nice -- jailed-claude "$@"
          }
          alias jail-shell="setpriv --ambient-caps=-sys_nice -- jailed-shell"
        '';
    in
    {
      inherit jailedClaude jailedShell sandboxedPackages shellHook;
    };

  mkShell = args:
    let
      bins = mkBins args;
      projectPkgs = args.projectPkgs or [ ];
    in
    pkgs.mkShell {
      packages = projectPkgs ++ bins.sandboxedPackages ++ [ bins.jailedClaude bins.jailedShell ];
      inherit (bins) shellHook;
    };
in
{
  inherit mkShell mkBins;
}
