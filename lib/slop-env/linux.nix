{ pkgs
, sandboxed
, prereqGuidance
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

  # Sentinel projectName for the zero-touch apps path. When mkBins is
  # called with no projectName (the default), the jail's cfgDir paths
  # contain this string and the wrapper-bins sed-substitute it with
  # basename "$PWD" at invocation. Concrete callers (the claude-code
  # template) pass projectName explicitly and the wrapper exec's the
  # jail directly with no substitution.
  projectNamePlaceholder = "__SLOP_ENV_PROJECT_NAME__";

  mkBins =
    { projectName ? projectNamePlaceholder
    , rulesDir ? ./defaults/rules
    , skillsDir ? null
    , claudeMdFile ? ./defaults/CLAUDE.md
    , basePkgs ? shared.defaultBasePkgs
    , projectPkgs ? [ ]
    , projectEnv ? { }
    , extraCombinators ? [ ]
    , extraShellHook ? ""
    , extraSandboxedEnvForwards ? [ ]
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

      usesPlaceholder = projectName == projectNamePlaceholder;

      # First-run state dir + credential bootstrap. Idempotent on every
      # invocation. Matches today's shellHook (slice 18.3).
      bootstrapBlock = ''
        CLAUDE_SHARED_DIR="$HOME/.local/state/claude/shared"
        mkdir -p "$CLAUDE_CONFIG_DIR" "$CLAUDE_SHARED_DIR"
        touch "$CLAUDE_SHARED_DIR/.credentials.json" "$CLAUDE_CONFIG_DIR/.claude.json"
      '';

      # Per-invocation projectName resolution + sed-substitution of the
      # jail's launch script. Materialised in a tempdir because /nix/store
      # is read-only. The launch script's other /nix/store references
      # (bwrap, the jailed binary, combinator data) are untouched and
      # resolve normally after exec.
      #
      # The sed pattern is anchored on `/projects/` (with slashes) so it
      # only touches DESTINATION paths inside the jail
      # (~/.local/state/claude/projects/<placeholder>/...) and leaves the
      # SOURCE store paths of write-text artifacts alone — those have
      # names like `jail-write-text--.local-state-claude-projects-<placeholder>-...`
      # (dash-separated, no slashes) and were built with the placeholder
      # baked into the store name. Broad substitution would rename the
      # source path to one that doesn't exist on disk and bwrap fails
      # with "Can't find source path".
      placeholderPreamble = jailBinary: ''
        PROJECT_NAME="''${NIX_SLOP_DEV_PROJECT_NAME:-$(basename "$PWD")}"
        # Sanitise so the basename can't smuggle shell metacharacters or
        # sed delimiters into the substitution. Keep alnum + . _ -
        PROJECT_NAME="''${PROJECT_NAME//[^A-Za-z0-9._-]/_}"
        export CLAUDE_CONFIG_DIR="$HOME/.local/state/claude/projects/$PROJECT_NAME"
        ${bootstrapBlock}
        SLOP_LAUNCH_DIR=$(${pkgs.coreutils}/bin/mktemp -d -t slop-env.XXXXXX)
        trap '${pkgs.coreutils}/bin/rm -rf "$SLOP_LAUNCH_DIR"' EXIT
        SLOP_LAUNCHER="$SLOP_LAUNCH_DIR/${baseNameOf jailBinary}"
        ${pkgs.gnused}/bin/sed "s|/projects/${projectNamePlaceholder}|/projects/$PROJECT_NAME|g" \
          ${jailBinary} > "$SLOP_LAUNCHER"
        ${pkgs.coreutils}/bin/chmod +x "$SLOP_LAUNCHER"
      '';

      # Concrete-projectName preamble: cfgDir is baked at Nix-eval time.
      # Still bootstrap state dirs so a fresh host doesn't error on
      # missing credentials.json.
      concretePreamble = ''
        export CLAUDE_CONFIG_DIR="$HOME/.local/state/claude/projects/${projectName}"
        ${bootstrapBlock}
      '';

      # PATH-binary wrappers used by apps.${system}.{claude,jail-shell}
      # (ADR-0005 zero-touch entry points). The template's mkShell still
      # uses a shell function + alias inside shellHook (preserving slice
      # 17's byte-equality) — these are an additive surface for apps and
      # for whoever wants survival across host-shell exec.
      claude = pkgs.writeShellScriptBin "claude" (
        if usesPlaceholder then ''
          set -euo pipefail
          ${placeholderPreamble "${jailedClaude}/bin/jailed-claude"}
          exec ${sandboxed}/bin/sandboxed -q --allow api.anthropic.com --allow 2607:6bc0::/32 \
            -e CLAUDE_CONFIG_DIR \
            ${pkgs.util-linux}/bin/setpriv --ambient-caps=-sys_nice -- \
            "$SLOP_LAUNCHER" "$@"
        '' else ''
          set -euo pipefail
          ${concretePreamble}
          exec ${sandboxed}/bin/sandboxed -q --allow api.anthropic.com --allow 2607:6bc0::/32 \
            -e CLAUDE_CONFIG_DIR \
            ${pkgs.util-linux}/bin/setpriv --ambient-caps=-sys_nice -- \
            ${jailedClaude}/bin/jailed-claude "$@"
        ''
      );

      # Slice 21 parity with Darwin's sandboxed-jailed-shell: Linux's
      # jail-shell is also network-confined by the sandboxed wrapper. No
      # per-invocation --allow flags — the persistent host whitelist
      # (`sandboxed --wl-add`/`--wl-del`) is honoured so users who've
      # curated allows already see them apply.
      jail-shell = pkgs.writeShellScriptBin "jail-shell" (
        if usesPlaceholder then ''
          set -euo pipefail
          ${placeholderPreamble "${jailedShell}/bin/jailed-shell"}
          exec ${sandboxed}/bin/sandboxed -q -- \
            ${pkgs.util-linux}/bin/setpriv --ambient-caps=-sys_nice -- \
            "$SLOP_LAUNCHER" "$@"
        '' else ''
          set -euo pipefail
          ${concretePreamble}
          exec ${sandboxed}/bin/sandboxed -q -- \
            ${pkgs.util-linux}/bin/setpriv --ambient-caps=-sys_nice -- \
            ${jailedShell}/bin/jailed-shell "$@"
        ''
      );

      shellHook = # sh
        ''
          # Project unique config
          export CLAUDE_CONFIG_DIR="$HOME/.local/state/claude/projects/${projectName}"
          export CLAUDE_SHARED_DIR="$HOME/.local/state/claude/shared"
          mkdir -p "$CLAUDE_CONFIG_DIR" "$CLAUDE_SHARED_DIR"
          touch "$CLAUDE_SHARED_DIR/.credentials.json" "$CLAUDE_CONFIG_DIR/.claude.json"

          # Setup checks
          _setup_ok=1

          # Sandbox/Jail prerequisites (auditd + NOPASSWD sudo for the
          # privileged tool set). slop-prereq-guidance picks distro-aware
          # advice based on /etc/NIXOS — on NixOS it points at the
          # security.sandboxed module; elsewhere it points at setup-linux.
          ${prereqGuidance}/bin/slop-prereq-guidance || _setup_ok=0

          # Check Claude credentials
          if [ ! -s "$CLAUDE_SHARED_DIR/.credentials.json" ]; then
          	printf '\033[1;36mℹ Claude Code credentials not found.\033[0m\n'
          	printf '  Run claude to complete OAuth login on first use.\n\n'
          	_setup_ok=0
          fi

          if [ "$_setup_ok" -eq 1 ]; then
          	printf '\033[1;32m✓\033[0m Jailed claude ready. Run \033[1mclaude\033[0m to start.\n'
          fi${lib.optionalString (extraShellHook != "") "\n${extraShellHook}"}

          # Jailed Claude Code
          claude() {
          	mkdir -p "$CLAUDE_CONFIG_DIR" "$CLAUDE_SHARED_DIR"
          	touch "$CLAUDE_SHARED_DIR/.credentials.json" "$CLAUDE_CONFIG_DIR/.claude.json"
          	sandboxed -q --allow api.anthropic.com --allow 2607:6bc0::/32 \
          		-e CLAUDE_CONFIG_DIR \
          		${lib.concatMapStrings (v: "-e ${v} \\\n\t\t") extraSandboxedEnvForwards}setpriv --ambient-caps=-sys_nice -- jailed-claude "$@"
          }
          alias jail-shell="sandboxed -q -- setpriv --ambient-caps=-sys_nice -- jailed-shell"
        '';
    in
    {
      inherit claude jail-shell jailedClaude jailedShell sandboxedPackages shellHook;
    };

  mkShell = args:
    let
      # `name` is a mkShell-level convenience (devShell store-path name).
      # Strip it out before forwarding the rest to mkBins, which doesn't
      # use it. Slice 19.5 added this so the nvim template can keep its
      # historical "nvim-claude-devShell" devShell name.
      binArgs = builtins.removeAttrs args [ "name" ];
      bins = mkBins binArgs;
      projectPkgs = args.projectPkgs or [ ];
    in
    pkgs.mkShell {
      name = args.name or "nix-shell";
      packages = projectPkgs ++ bins.sandboxedPackages ++ [ bins.jailedClaude bins.jailedShell ];
      inherit (bins) shellHook;
    };
in
{
  inherit mkShell mkBins;
}
