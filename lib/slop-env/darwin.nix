{
  pkgs,
  sandboxed,
  defaultProfile,
  jail,
  shared,
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
    {
      projectName ? projectNamePlaceholder,
      agent ? defaultProfile,
      rulesDir ? ./defaults/rules,
      skillsDir ? null,
      agentMdFile ? ./defaults/CLAUDE.md,
      enableLocalAi ? false,
      basePkgs ? shared.defaultBasePkgs,
      projectPkgs ? [ ],
      projectEnv ? { },
      extraCombinators ? [ ],
      extraShellHook ? "",
      extraSandboxedEnvForwards ? [ ],
      # ADR-0014 per-Account credential isolation is Linux-only in this pass
      # (macOS OAuth is keychain-single-slot — see the ADR's platform
      # asymmetry). These args are accepted so a cross-platform template still
      # evaluates here, but a non-empty `accounts` is refused below rather than
      # silently giving macOS broken isolation.
      accounts ? { },
      defaultAccount ? null,
    }:
    # Deny-by-default: refuse Accounts on Darwin this pass instead of ignoring
    # them. Empty `accounts` is the no-Account path and stays byte-identical.
    assert lib.assertMsg (accounts == { })
      "slopEnv (darwin): per-Account credential isolation (ADR-0014) is not implemented on macOS in this pass; declare `accounts` only on Linux (e.g. gate on pkgs.stdenv.isLinux for a cross-platform config).";
    # Profiles that supply their own Darwin builder take it; Claude is the
    # built-in default path below (ADR-0009). Profiles without a Darwin builder
    # (e.g. pi) are rejected with a clear message rather than misbuilt.
    if agent ? mkDarwinBins then
      agent.mkDarwinBins {
        inherit
          projectName
          rulesDir
          skillsDir
          agentMdFile
          enableLocalAi
          basePkgs
          projectPkgs
          projectEnv
          extraCombinators
          extraShellHook
          extraSandboxedEnvForwards
          ;
        engine = {
          inherit
            pkgs
            lib
            jail
            sandboxed
            projectNamePlaceholder
            ;
        };
      }
    else if agent.name != "claude" then
      throw "slopEnv (darwin): agent '${agent.name}' is not yet supported on Darwin"
    else
      let
        claudeMd = agent.mkContext { inherit agentMdFile rulesDir; };
        claudeSettings = agent.settings;

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

          # TMPDIR (Scratch) and CLAUDE_EXCHANGE_DIR (Exchange) are now
          # forwarded by the shared combinator list (shared.nix) on both
          # platforms — `env -i` drops them, and the launchers below export
          # both pointing into the persistent cfgDir.

          # claude-code (Bun) spawns /usr/bin/security to read OAuth
          # credentials from the macOS keychain (and to store new ones
          # after first-run OAuth). Without an exec allow Bun surfaces
          # the Seatbelt deny as a hard EPERM rather than falling back
          # to the plaintext .credentials.json provider — the jail
          # then can't reach the keychain layer Apple stores
          # claude.ai's OAuth token under. src == dst because /usr/bin
          # is SIP-protected and the binary lives at its canonical
          # path on every macOS host (stock and nix-darwin alike). The
          # ro-bind emits both file-read* and process-exec subpath
          # allows — exactly what claude needs.
          # HITL surfaced 2026-06-19.
          (ro-bind "/usr/bin/security" "/usr/bin/security")
        ];

        jailCombinators =
          (agent.mkJailCombinators {
            inherit
              jail
              projectName
              skillsDir
              claudeMd
              claudeSettings
              basePkgs
              projectPkgs
              projectEnv
              ;
            # SIP keeps /usr/bin read-only on macOS; src and dst point to
            # the same host path (the jail's read-allow emits with no bind
            # preflight when src == dst).
            envSrc = "/usr/bin/env";
            # Darwin's local tmpfs is destructive (rm-rf the host dir on
            # exit) — wrong semantics for cfgDir, which must persist
            # claude state across runs. ensure-dir keeps the dir between
            # invocations. HITL 2026-06-19.
            cfgDirCombinator = jail.combinators.ensure-dir;
            # cfgDir persists across runs here, so the token lives in it
            # directly — the shared-file symlink graft would only clobber
            # it (see shared.nix). HITL 2026-06-19.
            shareCredentialsFile = false;
          })
          ++ darwinJailExtras
          ++ extraCombinators;

        jailedClaude = jail.jail agent.jailedName agent.package jailCombinators;
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
        sandboxedPackages = [
          sandboxedClaude
          sandboxedShell
        ];

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

        configDirSetup = if usesPlaceholder then placeholderPreamble else concreteConfigDir;

        # User-facing entry points as PATH binaries (writeShellScriptBin)
        # so they survive the shellHook's exec into the user's login
        # shell — zsh / fish / etc can't see bash functions defined in
        # nix-develop bash, but everything in `packages` is on $PATH.
        claude = pkgs.writeShellScriptBin "claude" ''
          set -euo pipefail
          ${configDirSetup}
          # Keep agent scratch inside the writable cfgDir — the jail denies
          # /tmp and `env -i` drops TMPDIR, so Node's os.tmpdir() would EPERM
          # there (both forwarded via try-fwd-env in shared.nix). Exchange is
          # the deliberate user<->agent handoff channel (see CONTEXT.md);
          # sandbox-exec passes the exported env through, so no -e is needed.
          export TMPDIR="$CLAUDE_CONFIG_DIR/tmp"
          export CLAUDE_EXCHANGE_DIR="$CLAUDE_CONFIG_DIR/exchange"
          mkdir -p "$CLAUDE_CONFIG_DIR" "$TMPDIR" "$CLAUDE_EXCHANGE_DIR"
          [ -s "$CLAUDE_CONFIG_DIR/.claude.json" ] || echo '{}' > "$CLAUDE_CONFIG_DIR/.claude.json"
          exec ${sandboxedClaude}/bin/sandboxed-jailed-claude -q \
            --allow api.anthropic.com \
            --allow platform.claude.com \
            -e CLAUDE_CONFIG_DIR \
            ${lib.concatMapStrings (v: "-e ${v} ") extraSandboxedEnvForwards}"$@"
        '';

        jail-shell = pkgs.writeShellScriptBin "jail-shell" ''
          set -euo pipefail
          ${configDirSetup}
          # Keep agent scratch inside the writable cfgDir — the jail denies
          # /tmp and `env -i` drops TMPDIR, so Node's os.tmpdir() would EPERM
          # there (both forwarded via try-fwd-env in shared.nix). Exchange is
          # the deliberate user<->agent handoff channel (see CONTEXT.md);
          # sandbox-exec passes the exported env through, so no -e is needed.
          export TMPDIR="$CLAUDE_CONFIG_DIR/tmp"
          export CLAUDE_EXCHANGE_DIR="$CLAUDE_CONFIG_DIR/exchange"
          mkdir -p "$CLAUDE_CONFIG_DIR" "$TMPDIR" "$CLAUDE_EXCHANGE_DIR"
          [ -s "$CLAUDE_CONFIG_DIR/.claude.json" ] || echo '{}' > "$CLAUDE_CONFIG_DIR/.claude.json"
          exec ${sandboxedShell}/bin/sandboxed-jailed-shell "$@"
        '';

        # Darwin shellHook: skip Linux-only prereq checks (Seatbelt is
        # daemonless and runs unprivileged). Unlike Linux (shared-file
        # credentials over a tmpfs cfgDir), the login check here targets the
        # persistent per-project cfgDir — see shareCredentialsFile above.
        shellHook = ''
          # Project unique config
          export CLAUDE_CONFIG_DIR="$HOME/.local/state/claude/projects/${projectName}"
          # Host-visible Scratch + Exchange (see CONTEXT.md). Exported in the
          # outer dev shell too so the user can `cd "$CLAUDE_EXCHANGE_DIR"`
          # and drop files in for the agent to ingest.
          export TMPDIR="$CLAUDE_CONFIG_DIR/tmp"
          export CLAUDE_EXCHANGE_DIR="$CLAUDE_CONFIG_DIR/exchange"
          mkdir -p "$CLAUDE_CONFIG_DIR" "$TMPDIR" "$CLAUDE_EXCHANGE_DIR"
          [ -s "$CLAUDE_CONFIG_DIR/.claude.json" ] || echo '{}' > "$CLAUDE_CONFIG_DIR/.claude.json"

          # Setup checks
          _setup_ok=1

          # Check Claude credentials. The jailed claude persists its OAuth
          # token as a regular file in the per-project config dir (cfgDir is
          # a persistent ensure-dir on Darwin), so detect login by testing
          # that file — NOT a shared sidecar, which claude's atomic
          # write-and-rename never populates. HITL 2026-06-19.
          if [ ! -s "$CLAUDE_CONFIG_DIR/.credentials.json" ]; then
          	printf '\033[1;36mℹ Claude Code credentials not found.\033[0m\n'
          	printf '  Run claude to complete OAuth login on first use.\n\n'
          	_setup_ok=0
          fi

          if [ "$_setup_ok" -eq 1 ]; then
          	printf '\033[1;32m✓\033[0m Jailed claude ready. Run \033[1mclaude\033[0m to start.\n'
          fi
          printf '\033[1;36mℹ\033[0m Exchange files with the agent via \033[1m%s\033[0m\n' "$CLAUDE_EXCHANGE_DIR"${
            lib.optionalString (extraShellHook != "") "\n${extraShellHook}"
          }
        '';
      in
      {
        # Output keys are agent-neutral (ADR-0009); local bindings keep their
        # historical claude names since this is the built-in claude path.
        agent = claude;
        jailedAgent = jailedClaude;
        inherit
          jail-shell
          jailedShell
          sandboxedPackages
          shellHook
          ;
      };

  mkShell =
    args:
    let
      binArgs = builtins.removeAttrs args [ "name" ];
      bins = mkBins binArgs;
      projectPkgs = args.projectPkgs or [ ];
    in
    pkgs.mkShell {
      name = args.name or "nix-shell";
      packages =
        projectPkgs
        ++ bins.sandboxedPackages
        ++ [
          bins.jailedAgent
          bins.jailedShell
          bins.agent
          bins.jail-shell
        ];
      inherit (bins) shellHook;
    };
in
{
  inherit mkShell mkBins;
}
