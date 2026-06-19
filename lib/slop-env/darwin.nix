{ pkgs
, sandboxed
, claude-pkg
, jail
, shared
}:

# Darwin-specific Slop Env assembly. Seatbelt-based jail enforcement
# (ADR-0001 + ADR-0004): no daemon, no NOPASSWD-sudo, no nested
# sandbox-exec. The sandboxed wrapper is overridden per-jail because
# `sandbox-exec` cannot enter a sandbox from inside one — the merged
# Sandbox+Jail SBPL profile is baked at Nix-eval and stamped onto each
# wrapper.
#
# Produces { mkShell; mkBins; } consumed by lib/slop-env/default.nix.

let
  lib = pkgs.lib;

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

      # nix-darwin's /etc/bashrc and /etc/zshenv source a hard-coded
      # /nix/store/.../set-environment path baked at activation time to
      # inject the host's nix-darwin system PATH into interactive shells.
      # The jail intentionally builds its own env via add-pkg-deps +
      # set-env, so sourcing the host's environment would leak nix-darwin
      # paths into the sandbox AND the file's specific store hash isn't
      # in the jail's allow set. Both files honour
      # __NIX_DARWIN_SET_ENVIRONMENT_DONE as a skip switch — set it so
      # the jail shell starts cleanly without the closed-by-default deny
      # on the set-environment path.
      darwinJailExtras = with jail.combinators; [
        # nix-darwin's shell startup files at /etc/* are symlinks into
        # /nix/store (SYS_BASHRC=/etc/bashrc compiled into nixpkgs's
        # bashInteractive, plus zsh's /etc/zsh* siblings and
        # /etc/terminfo). Spike 10 F1 dictates that SBPL rules match
        # the kernel-canonical (fully-resolved) path; a static literal
        # allow on /private/etc/bashrc misses the resolved store
        # target on nix-darwin and bash prints `Operation not
        # permitted` at every interactive launch. host-resolve emits a
        # placeholder allow that the darwin wrapper sed-substitutes
        # with `readlink -f` at preflight. On stock macOS (no symlink)
        # the substitution returns the path unchanged and the prelude
        # already covers the literal, so this is a no-op.
        (host-resolve "/etc/bashrc")
        (host-resolve "/etc/zshrc")
        (host-resolve "/etc/zprofile")
        (host-resolve "/etc/zshenv")
        (host-resolve "/etc/terminfo")

        # nix-darwin's /etc/bashrc and /etc/zshenv source a hard-coded
        # /nix/store/.../set-environment path baked at activation time
        # to inject the host's nix-darwin system PATH into interactive
        # shells. The jail intentionally builds its own env via
        # add-pkg-deps + set-env, so sourcing the host's environment
        # would leak nix-darwin paths into the sandbox AND the file's
        # specific store hash isn't in the jail's allow set. Both
        # files honour __NIX_DARWIN_SET_ENVIRONMENT_DONE as a skip
        # switch — set it so the jail shell starts cleanly without
        # the closed-by-default deny on the set-environment path.
        (set-env "__NIX_DARWIN_SET_ENVIRONMENT_DONE" "1")
      ];

      jailCombinators =
        (shared.mkJailCombinators {
          inherit jail projectName skillsDir claudeMd claudeSettings basePkgs projectPkgs projectEnv;
          # SIP keeps /usr/bin read-only on macOS; src and dst point to
          # the same host path (the jail's read-allow emits with no bind
          # preflight when src == dst).
          envSrc = "/usr/bin/env";
        })
        ++ darwinJailExtras
        ++ extraCombinators;

      jailedClaude = jail.jail "jailed-claude" claude-pkg jailCombinators;
      jailedShell = jail.jail "jailed-shell" pkgs.bashInteractive jailCombinators;

      # Per-jail sandboxed-darwin wrappers (issue 11 / ADR-0001 line 17):
      # sandbox-exec doesn't nest, so the Sandbox+Jail SBPL profile is
      # baked into one wrapper per jailed binary. binName disambiguates
      # the two on PATH.
      sandboxedClaude = sandboxed.override {
        jail = jailedClaude;
        binName = "sandboxed-jailed-claude";
      };
      sandboxedShell = sandboxed.override {
        jail = jailedShell;
        binName = "sandboxed-jailed-shell";
      };
      sandboxedPackages = [ sandboxedClaude sandboxedShell ];

      usesPlaceholder = projectName == projectNamePlaceholder;

      # Linux-parity placeholderPreamble (slice-21 follow-up). In zero-
      # touch apps mode the launcher resolves PROJECT_NAME at runtime
      # from $NIX_SLOP_DEV_PROJECT_NAME (caller-supplied, e.g. by a
      # wrapping flake) or basename "$PWD" — and forwards the resolved
      # name to the per-jail wrapper via NIX_SLOP_DEV_PROJECT_NAME so
      # the wrapper's SBPL/preflight sed targets the same cfgDir
      # (avoids a $PWD-race between launcher and wrapper). Sanitiser
      # matches Linux's `[^A-Za-z0-9._-]` regex so the basename can't
      # smuggle sed delimiters or shell metacharacters.
      placeholderPreamble = ''
        PROJECT_NAME="''${NIX_SLOP_DEV_PROJECT_NAME:-$(${pkgs.coreutils}/bin/basename "$PWD")}"
        PROJECT_NAME="''${PROJECT_NAME//[^A-Za-z0-9._-]/_}"
        export NIX_SLOP_DEV_PROJECT_NAME="$PROJECT_NAME"
        export CLAUDE_CONFIG_DIR="$HOME/.local/state/claude/projects/$PROJECT_NAME"
      '';

      # Concrete mode: projectName is baked at Nix-eval (template
      # callers supply it explicitly). No runtime resolution needed —
      # the wrapper's SBPL/preflight already have the concrete name
      # baked in too, so the sed pipeline is a no-op.
      concreteConfigDir = ''
        export CLAUDE_CONFIG_DIR="$HOME/.local/state/claude/projects/${projectName}"
      '';

      configDirSetup =
        if usesPlaceholder then placeholderPreamble else concreteConfigDir;

      # User-facing entry points as PATH binaries (writeShellScriptBin)
      # so they survive the shellHook's exec into the user's login
      # shell — zsh / fish / etc can't see bash functions defined in
      # nix-develop bash, but everything in `packages` is on $PATH.
      claude = pkgs.writeShellScriptBin "claude" ''
        set -euo pipefail
        ${configDirSetup}
        export CLAUDE_SHARED_DIR="$HOME/.local/state/claude/shared"
        mkdir -p "$CLAUDE_CONFIG_DIR" "$CLAUDE_SHARED_DIR"
        touch "$CLAUDE_SHARED_DIR/.credentials.json" "$CLAUDE_CONFIG_DIR/.claude.json"
        exec ${sandboxedClaude}/bin/sandboxed-jailed-claude -q --allow api.anthropic.com \
          -e CLAUDE_CONFIG_DIR \
          ${lib.concatMapStrings (v: "-e ${v} ") extraSandboxedEnvForwards}"$@"
      '';

      jail-shell = pkgs.writeShellScriptBin "jail-shell" ''
        set -euo pipefail
        ${configDirSetup}
        export CLAUDE_SHARED_DIR="$HOME/.local/state/claude/shared"
        mkdir -p "$CLAUDE_CONFIG_DIR" "$CLAUDE_SHARED_DIR"
        touch "$CLAUDE_SHARED_DIR/.credentials.json" "$CLAUDE_CONFIG_DIR/.claude.json"
        exec ${sandboxedShell}/bin/sandboxed-jailed-shell "$@"
      '';

      # Darwin shellHook: skip Linux-only prereq checks (Seatbelt is
      # daemonless and runs unprivileged). Claude credentials check +
      # ready banner are identical to Linux.
      shellHook = ''
        # Project unique config
        export CLAUDE_CONFIG_DIR="$HOME/.local/state/claude/projects/${projectName}"
        export CLAUDE_SHARED_DIR="$HOME/.local/state/claude/shared"
        mkdir -p "$CLAUDE_CONFIG_DIR" "$CLAUDE_SHARED_DIR"
        touch "$CLAUDE_SHARED_DIR/.credentials.json" "$CLAUDE_CONFIG_DIR/.claude.json"

        # Setup checks
        _setup_ok=1

        # Check Claude credentials
        if [ ! -s "$CLAUDE_SHARED_DIR/.credentials.json" ]; then
        	printf '\033[1;36mℹ Claude Code credentials not found.\033[0m\n'
        	printf '  Run claude to complete OAuth login on first use.\n\n'
        	_setup_ok=0
        fi

        if [ "$_setup_ok" -eq 1 ]; then
        	printf '\033[1;32m✓\033[0m Jailed claude ready. Run \033[1mclaude\033[0m to start.\n'
        fi${lib.optionalString (extraShellHook != "") "\n${extraShellHook}"}
      '';
    in
    {
      inherit claude jail-shell jailedClaude jailedShell sandboxedPackages shellHook;
    };

  mkShell = args:
    let
      binArgs = builtins.removeAttrs args [ "name" ];
      bins = mkBins binArgs;
      projectPkgs = args.projectPkgs or [ ];
    in
    pkgs.mkShell {
      name = args.name or "nix-shell";
      packages = projectPkgs ++ bins.sandboxedPackages ++ [
        bins.jailedClaude
        bins.jailedShell
        bins.claude
        bins.jail-shell
      ];
      inherit (bins) shellHook;
    };
in
{
  inherit mkShell mkBins;
}
