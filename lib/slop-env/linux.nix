{
  pkgs,
  sandboxed,
  prereqGuidance,
  defaultProfile,
  jail,
  shared,
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
    {
      projectName ? projectNamePlaceholder,
      agent ? defaultProfile,
      rulesDir ? ./defaults/rules,
      skillsDir ? null,
      agentMdFile ? ./defaults/CLAUDE.md,
      # Local AI module option ({ enable; settings = { endpoints }; }), forwarded
      # to the pi/opencode profile builders. Default {} (disabled) emits no local
      # AI, byte-identical to today. No-op for the Claude profile.
      localAi ? { },
      basePkgs ? shared.defaultBasePkgs,
      projectPkgs ? [ ],
      projectEnv ? { },
      extraCombinators ? [ ],
      extraShellHook ? "",
      extraSandboxedEnvForwards ? [ ],
      # ADR-0014 per-Account credential isolation. `accounts` is the closed,
      # Nix-declared registry ({ <name> = { type = "oauth"|"apikey"; keyFile?; }; });
      # `defaultAccount` is the project default selected when no launch-time
      # NIX_SLOP_DEV_ACCOUNT override is given. Empty `accounts` (the default)
      # reproduces today's single shared-credential behaviour byte-for-byte.
      accounts ? { },
      defaultAccount ? null,
    }:
    # Profiles that supply their own Linux builder (e.g. pi) take it; Claude is
    # the built-in default path below, kept byte-identical (ADR-0009).
    if agent ? mkLinuxBins then
      agent.mkLinuxBins {
        inherit
          projectName
          rulesDir
          skillsDir
          agentMdFile
          localAi
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
            prereqGuidance
            projectNamePlaceholder
            ;
        };
      }
    else if agent.name != "claude" then
      throw "slopEnv (linux): agent '${agent.name}' provides no mkLinuxBins builder"
    else
      let
        claudeMd = agent.mkContext { inherit agentMdFile rulesDir; };
        claudeSettings = agent.settings;

        jailCombinators =
          (agent.mkJailCombinators (
            {
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
            }
            # When Accounts are declared, bake the __SLOP_ENV_ACCOUNT__
            # placeholder into the per-Account session root and credential
            # source; the launcher sed-substitutes it at invocation. Omitted
            # entirely with no Accounts, so the combinator list is byte-identical.
            // lib.optionalAttrs accountsActive {
              accountSessionSuffix = "/${accountPlaceholder}";
              accountCredFile = "~/.local/state/claude/accounts/${accountPlaceholder}/.credentials.json";
            }
          ))
          ++ extraCombinators;

        jailedClaude = jail agent.jailedName agent.package jailCombinators;
        jailedShell = jail "jailed-shell" pkgs.bashInteractive jailCombinators;

        # Linux currently has one sandboxed wrapper for both jails (slice 21
        # adds Darwin's per-jail variant).
        sandboxedPackages = [ sandboxed ];

        usesPlaceholder = projectName == projectNamePlaceholder;

        # ADR-0014: Accounts are opt-in. Declaring any Account switches this
        # Slop Env into the per-Account regime; an empty registry leaves every
        # emitted string untouched (byte-identical no-Account path).
        accountsActive = accounts != { };
        accountNames = builtins.attrNames accounts;
        # Account names ride unquoted into the registry-membership for-loop, the
        # apikey case pattern, the sed replacement, and the per-Account paths.
        # Constrain them to the same safe charset as PROJECT_NAME so a name can
        # never smuggle shell metacharacters, the sed delimiter, whitespace, or a
        # path separator — a deny-by-default registry refused at eval, not
        # misbehaving at launch. Vacuously true for an empty registry, so the
        # no-Account derivation is unchanged.
        accountNamesValid = builtins.all (name: builtins.match "[A-Za-z0-9._-]+" name != null) accountNames;
        # Runtime placeholder for the resolved Account, baked into the jailed
        # binary's destination paths and sed-substituted by the launcher. The
        # sed is slash-anchored ("/__SLOP_ENV_ACCOUNT__") so it rewrites the
        # /projects/<proj>/ and /accounts/ DEST paths but never the dash-form
        # write-text SOURCE store names — the same anchoring the projectName
        # placeholder relies on (see placeholderPreamble).
        accountPlaceholder = "__SLOP_ENV_ACCOUNT__";
        # defaultAccount may be null (no project default → the launch-time
        # override is mandatory). Rendered into the launcher as the `:-` fallback.
        defaultAccountStr = if defaultAccount == null then "" else defaultAccount;

        # Deny-by-default Account resolution + validation, run at the very top
        # of every in-scope launcher before any state dir is touched or the
        # jail is exec'd. Resolves NIX_SLOP_DEV_ACCOUNT (else the project
        # default) and refuses to launch if the result is empty or not in the
        # baked registry — matching the jail/Sandbox deny-by-default posture.
        # Empty when no Accounts are declared, so launchers stay byte-identical.
        accountResolveValidate = lib.optionalString accountsActive ''
          SLOP_ACCOUNT="''${NIX_SLOP_DEV_ACCOUNT:-${defaultAccountStr}}"
          if [ -z "$SLOP_ACCOUNT" ]; then
            printf 'error: no Account selected. Set NIX_SLOP_DEV_ACCOUNT or a defaultAccount (known Accounts: %s).\n' "${lib.concatStringsSep " " accountNames}" >&2
            exit 1
          fi
          _slop_acct_ok=0
          for _slop_a in ${lib.concatStringsSep " " accountNames}; do
            if [ "$_slop_a" = "$SLOP_ACCOUNT" ]; then _slop_acct_ok=1; fi
          done
          if [ "$_slop_acct_ok" -ne 1 ]; then
            printf 'error: Account %s is not declared in this Slop Env (known Accounts: %s). Refusing to launch.\n' "$SLOP_ACCOUNT" "${lib.concatStringsSep " " accountNames}" >&2
            exit 1
          fi
        '';

        # Runtime ANTHROPIC_API_KEY resolution for apikey Accounts. The
        # registry's keyFile PATH is baked (never the secret); the launcher
        # reads it at invocation, exports the key into the launch subshell only,
        # and sets SLOP_API_KEY_FWD so the caller adds `-e ANTHROPIC_API_KEY` to
        # sandboxed. oauth Accounts fall through the default arm (no key). The
        # key never enters the store and never escapes the launch subshell.
        apiKeyCase =
          let
            apikeyArm =
              name:
              let
                acct = accounts.${name};
              in
              lib.optionalString ((acct.type or "oauth") == "apikey") ''
                ${name})
                  if [ -r "${acct.keyFile}" ]; then
                    ANTHROPIC_API_KEY="$(${pkgs.coreutils}/bin/cat "${acct.keyFile}")"
                    export ANTHROPIC_API_KEY
                    SLOP_API_KEY_FWD="-e ANTHROPIC_API_KEY"
                  else
                    printf 'error: Account %s keyFile %s is not readable.\n' "$SLOP_ACCOUNT" "${acct.keyFile}" >&2
                    exit 1
                  fi
                  ;;
              '';
          in
          ''
            SLOP_API_KEY_FWD=""
            case "$SLOP_ACCOUNT" in
            ${lib.concatStrings (map apikeyArm accountNames)}*) ;;
            esac
          '';

        # Per-Account launch preamble (only emitted when Accounts are active).
        # After resolving + validating the Account, it points the session env
        # at the per Account-and-project root, ensures the per-Account
        # credential dir exists (so the graft source is present), and rewrites
        # the jailed launcher's __SLOP_ENV_ACCOUNT__ placeholder to the resolved
        # Account — slash-anchored so only DEST paths (/projects/<proj>/<acct>/
        # and /accounts/<acct>/) are touched, never the dash-form write-text
        # SOURCE store names. The result is left in "$SLOP_LAUNCHER" for the
        # caller to exec. `jailedSrc` is a shell expression yielding the source
        # jailed launcher; `jailedName` names the materialised copy.
        accountLaunchPrep = jailedSrc: jailedName: ''
          ${accountResolveValidate}export CLAUDE_CONFIG_DIR="$HOME/.local/state/claude/projects/${projectName}/$SLOP_ACCOUNT"
          export TMPDIR="$CLAUDE_CONFIG_DIR/tmp"
          export CLAUDE_EXCHANGE_DIR="$CLAUDE_CONFIG_DIR/exchange"
          _slop_cred_dir="$HOME/.local/state/claude/accounts/$SLOP_ACCOUNT"
          mkdir -p "$CLAUDE_CONFIG_DIR" "$_slop_cred_dir" "$TMPDIR" "$CLAUDE_EXCHANGE_DIR"
          touch "$_slop_cred_dir/.credentials.json"
          [ -s "$CLAUDE_CONFIG_DIR/.claude.json" ] || echo '{}' > "$CLAUDE_CONFIG_DIR/.claude.json"
          SLOP_LAUNCH_DIR=$(${pkgs.coreutils}/bin/mktemp -d -t slop-env.XXXXXX)
          trap '${pkgs.coreutils}/bin/rm -rf "$SLOP_LAUNCH_DIR"' EXIT
          SLOP_LAUNCHER="$SLOP_LAUNCH_DIR/${jailedName}"
          ${pkgs.gnused}/bin/sed 's|/__SLOP_ENV_ACCOUNT__|/'"$SLOP_ACCOUNT"'|g' ${jailedSrc} > "$SLOP_LAUNCHER"
          ${pkgs.coreutils}/bin/chmod +x "$SLOP_LAUNCHER"
          ${apiKeyCase}'';

        # First-run state dir + credential bootstrap. Idempotent on every
        # invocation. Matches today's shellHook (slice 18.3). `.claude.json`
        # is initialised with `{}` (not bare `touch`) so claude doesn't
        # hit "JSON Parse error: Unexpected EOF" on first read — HITL
        # 2026-06-19.
        bootstrapBlock = ''
          CLAUDE_SHARED_DIR="$HOME/.local/state/claude/shared"
          # Host-visible Scratch (TMPDIR) and Exchange (CLAUDE_EXCHANGE_DIR) —
          # see CONTEXT.md. Exported here and forwarded into the jail
          # (try-fwd-env in shared.nix) so the agent's temp and the handoff
          # channel land in host-reachable, rw-bound dirs instead of the
          # jail-private /tmp. mkdir host-side so they're browsable pre-launch.
          export TMPDIR="$CLAUDE_CONFIG_DIR/tmp"
          export CLAUDE_EXCHANGE_DIR="$CLAUDE_CONFIG_DIR/exchange"
          mkdir -p "$CLAUDE_CONFIG_DIR" "$CLAUDE_SHARED_DIR" "$TMPDIR" "$CLAUDE_EXCHANGE_DIR"
          touch "$CLAUDE_SHARED_DIR/.credentials.json"
          [ -s "$CLAUDE_CONFIG_DIR/.claude.json" ] || echo '{}' > "$CLAUDE_CONFIG_DIR/.claude.json"
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
          if usesPlaceholder then
            ''
              set -euo pipefail
              ${placeholderPreamble "${jailedClaude}/bin/jailed-claude"}
              exec ${sandboxed}/bin/sandboxed -q --allow api.anthropic.com --allow platform.claude.com --allow 2607:6bc0::/32 \
                -e CLAUDE_CONFIG_DIR -e TMPDIR -e CLAUDE_EXCHANGE_DIR \
                ${pkgs.util-linux}/bin/setpriv --ambient-caps=-sys_nice -- \
                "$SLOP_LAUNCHER" "$@"
            ''
          else
            ''
              set -euo pipefail
              ${
                if accountsActive then
                  accountLaunchPrep "${jailedClaude}/bin/jailed-claude" "jailed-claude"
                else
                  concretePreamble
              }
              exec ${sandboxed}/bin/sandboxed -q --allow api.anthropic.com --allow platform.claude.com --allow 2607:6bc0::/32 \
                -e CLAUDE_CONFIG_DIR -e TMPDIR -e CLAUDE_EXCHANGE_DIR \
                ${lib.optionalString accountsActive "$SLOP_API_KEY_FWD "}${pkgs.util-linux}/bin/setpriv --ambient-caps=-sys_nice -- \
                ${if accountsActive then ''"$SLOP_LAUNCHER"'' else "${jailedClaude}/bin/jailed-claude"} "$@"
            ''
        );

        # Slice 21 parity with Darwin's sandboxed-jailed-shell: Linux's
        # jail-shell is also network-confined by the sandboxed wrapper. No
        # per-invocation --allow flags — the persistent host whitelist
        # (`sandboxed --wl-add`/`--wl-del`) is honoured so users who've
        # curated allows already see them apply.
        jail-shell = pkgs.writeShellScriptBin "jail-shell" (
          if usesPlaceholder then
            ''
              set -euo pipefail
              ${placeholderPreamble "${jailedShell}/bin/jailed-shell"}
              exec ${sandboxed}/bin/sandboxed -q \
                -e CLAUDE_CONFIG_DIR -e TMPDIR -e CLAUDE_EXCHANGE_DIR -- \
                ${pkgs.util-linux}/bin/setpriv --ambient-caps=-sys_nice -- \
                "$SLOP_LAUNCHER" "$@"
            ''
          else
            ''
              set -euo pipefail
              ${
                if accountsActive then
                  accountLaunchPrep "${jailedShell}/bin/jailed-shell" "jailed-shell"
                else
                  concretePreamble
              }
              exec ${sandboxed}/bin/sandboxed -q \
                -e CLAUDE_CONFIG_DIR -e TMPDIR -e CLAUDE_EXCHANGE_DIR -- \
                ${pkgs.util-linux}/bin/setpriv --ambient-caps=-sys_nice -- \
                ${if accountsActive then ''"$SLOP_LAUNCHER"'' else "${jailedShell}/bin/jailed-shell"} "$@"
            ''
        );

        shellHook = # sh
          ''
            # Project unique config
            export CLAUDE_CONFIG_DIR="$HOME/.local/state/claude/projects/${projectName}"
            export CLAUDE_SHARED_DIR="$HOME/.local/state/claude/shared"
            # Host-visible Scratch + Exchange (see CONTEXT.md). Exported in the
            # outer dev shell too so the user can `cd "$CLAUDE_EXCHANGE_DIR"`
            # and drop files in for the agent to ingest.
            export TMPDIR="$CLAUDE_CONFIG_DIR/tmp"
            export CLAUDE_EXCHANGE_DIR="$CLAUDE_CONFIG_DIR/exchange"
            mkdir -p "$CLAUDE_CONFIG_DIR" "$CLAUDE_SHARED_DIR" "$TMPDIR" "$CLAUDE_EXCHANGE_DIR"
            touch "$CLAUDE_SHARED_DIR/.credentials.json"
            [ -s "$CLAUDE_CONFIG_DIR/.claude.json" ] || echo '{}' > "$CLAUDE_CONFIG_DIR/.claude.json"

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
            fi
            printf '\033[1;36mℹ\033[0m Exchange files with the agent via \033[1m%s\033[0m\n' "$CLAUDE_EXCHANGE_DIR"${
              lib.optionalString (extraShellHook != "") "\n${extraShellHook}"
            }

            # Jailed Claude Code
            claude() {
            	mkdir -p "$CLAUDE_CONFIG_DIR" "$CLAUDE_SHARED_DIR" "$TMPDIR" "$CLAUDE_EXCHANGE_DIR"
            	touch "$CLAUDE_SHARED_DIR/.credentials.json"
            	[ -s "$CLAUDE_CONFIG_DIR/.claude.json" ] || echo '{}' > "$CLAUDE_CONFIG_DIR/.claude.json"
            	sandboxed -q --allow api.anthropic.com --allow platform.claude.com --allow 2607:6bc0::/32 \
            		-e CLAUDE_CONFIG_DIR -e TMPDIR -e CLAUDE_EXCHANGE_DIR \
            		${
                lib.concatMapStrings (v: "-e ${v} \\\n\t\t") extraSandboxedEnvForwards
              }setpriv --ambient-caps=-sys_nice -- jailed-claude "$@"
            }
            alias jail-shell="sandboxed -q -e CLAUDE_CONFIG_DIR -e TMPDIR -e CLAUDE_EXCHANGE_DIR -- setpriv --ambient-caps=-sys_nice -- jailed-shell"${lib.optionalString accountsActive ''


              # ADR-0014: per-Account launchers override the single-credential
              # ones above when this Slop Env declares Accounts. Each runs in a
              # subshell so a deny-by-default refusal (or a per-launch Account
              # override) never leaks env or kills the interactive dev shell. The
              # jailed launcher is resolved off PATH and Account-rewritten per run.
              claude() {
              	(
              		${accountLaunchPrep ''"$(command -v jailed-claude)"'' "jailed-claude"}sandboxed -q --allow api.anthropic.com --allow platform.claude.com --allow 2607:6bc0::/32 \
              			-e CLAUDE_CONFIG_DIR -e TMPDIR -e CLAUDE_EXCHANGE_DIR \
              			${
                   lib.concatMapStrings (v: "-e ${v} ") extraSandboxedEnvForwards
                 }$SLOP_API_KEY_FWD setpriv --ambient-caps=-sys_nice -- "$SLOP_LAUNCHER" "$@"
              	)
              }
              # A function shares the jail-shell name with the alias above; the
              # alias would win at the prompt, so drop it before defining ours.
              unalias jail-shell 2>/dev/null || true
              jail-shell() {
              	(
              		${accountLaunchPrep ''"$(command -v jailed-shell)"'' "jailed-shell"}sandboxed -q -e CLAUDE_CONFIG_DIR -e TMPDIR -e CLAUDE_EXCHANGE_DIR -- \
              			setpriv --ambient-caps=-sys_nice -- "$SLOP_LAUNCHER" "$@"
              	)
              }''}
          '';
      in
      # Deny-by-default eval-time guards. Both vacuously pass when no Accounts
      # are declared, so the no-Account derivation is unchanged.
      # (1) Account names ride into shell/sed/path contexts — constrain charset.
      assert lib.assertMsg accountNamesValid
        "slopEnv (linux): Account names must match [A-Za-z0-9._-]+ (got: ${lib.concatStringsSep ", " accountNames}). Other characters can corrupt the launcher's shell/sed/path handling.";
      # (2) Accounts need a concrete projectName: the zero-touch/apps placeholder
      # launcher resolves only the projectName placeholder, never the Account one,
      # so declaring Accounts there would emit an unsubstituted, broken launcher.
      # ADR-0014 scopes Accounts to the template/mkShell/mkBins(projectName) path.
      assert lib.assertMsg (!(accountsActive && usesPlaceholder))
        "slopEnv (linux): Accounts require an explicit projectName. The zero-touch apps path keeps single-credential behavior (ADR-0014) — pass projectName to mkShell/mkBins to use Accounts.";
      {
        # Output keys are agent-neutral (ADR-0009): `agent` is the wrapper bin,
        # `jailedAgent` the jailed agent derivation — the local bindings keep
        # their historical claude names since this is the built-in claude path.
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
      packages =
        projectPkgs
        ++ bins.sandboxedPackages
        ++ [
          bins.jailedAgent
          bins.jailedShell
        ];
      inherit (bins) shellHook;
    };
in
{
  inherit mkShell mkBins;
}
