{ pi-pkg, shared }:

# Agent Profile for Pi (earendil-works/pi) — ADR-0009. See CONTEXT.md for the
# *Agent Profile* term.
#
# Pi's layout differs from Claude's in nearly every structural detail, so this
# profile supplies its own per-OS builders rather than reusing the engine's
# built-in Claude path:
#   - Config dir is the GLOBAL ~/.pi/agent (not a per-project tmpfs). settings/
#     AGENTS.md are injected read-only from the store; auth.json is host-bound
#     so `/login` persists once across all projects.
#   - Per-project isolation is sessions-only, via PI_CODING_AGENT_SESSION_DIR
#     (config.ts ENV_SESSION_DIR) pointed at a per-project state dir.
#   - Pi loads ~/.pi/agent/AGENTS.md as global context (resource-loader.ts).
#
# Supports both the greenfield template (concrete projectName) and the
# zero-touch apps.${system}.pi entry point (projectName left as the placeholder,
# resolved at invocation — sed-substituted into the bwrap launcher on Linux,
# forwarded via NIX_SLOP_DEV_PROJECT_NAME to the per-jail wrapper on Darwin,
# mirroring the engine's Claude path). Both Linux (bwrap) and Darwin (Seatbelt)
# are supported; the combinator list is shared (mkPiCombinators) so they cannot
# drift, and the concrete path stays byte-identical to its template baseline.

let
  hosts = "--allow api.anthropic.com --allow platform.claude.com --allow 2607:6bc0::/32";

  # Anthropic by default; claude-sonnet-4-6 is in Pi's model registry.
  piSettings = {
    defaultProvider = "anthropic";
    defaultModel = "claude-sonnet-4-6";
    defaultThinkingLevel = "medium";
    # pi.dev telemetry/version pings are blocked by the Sandbox; disabling them
    # avoids blocked-network noise on every launch.
    enableInstallTelemetry = false;
    quietStartup = true;
    theme = "dark";
    # "Don't use compaction; it's bad for you" — keep full context.
    compaction = {
      enabled = false;
      reserveTokens = 16384;
      keepRecentTokens = 20000;
    };
  };

  # Local-AI provider, injected to ~/.pi/agent/models.json only when
  # enableLocalAi is set. Shape matches Pi's ModelsConfigSchema
  # (model-registry.ts: providers → ProviderConfigSchema).
  piModels = {
    providers = {
      ollama = {
        baseUrl = "http://localhost:11434/v1";
        api = "openai-completions";
        apiKey = "ollama";
        compat = {
          supportsDeveloperRole = false;
          supportsReasoningEffort = false;
        };
        models = [
          {
            id = "qwen3-coder:latest";
            name = "Qwen3 Coder (Local)";
            reasoning = false;
            cost = { input = 0; output = 0; cacheRead = 0; cacheWrite = 0; };
          }
          {
            id = "gemma3:latest";
            name = "Gemma3 (Local)";
            reasoning = false;
            cost = { input = 0; output = 0; cacheRead = 0; cacheWrite = 0; };
          }
        ];
      };
    };
  };

  contextOf = { agentMdFile, rulesDir }:
    shared.mkContextMd { contextMdFile = agentMdFile; inherit rulesDir; };

  # Shared jail combinator list. `jailC` is jail.combinators (same access path
  # on both platforms); `envSrc` is the /usr/bin/env source (coreutils on
  # Linux, the SIP path on Darwin); `extra` carries OS-specific combinators
  # (Darwin's host-resolve / set-environment shims). Built once so the Linux
  # and Darwin jails cannot drift. The Linux value is byte-identical to the
  # original inline list (tests/template-pi-agent-drv.expected).
  mkPiCombinators =
    { jailC
    , lib
    , pkgs
    , envSrc
    , extra ? [ ]
    , projectName
    , skillsDir
    , agentMdFile
    , rulesDir
    , enableLocalAi
    , basePkgs
    , projectPkgs
    , projectEnv
    , extraCombinators
    }:
    let
      contextMd = contextOf { inherit agentMdFile rulesDir; };
      sessionDir = "~/.local/state/pi/projects/${projectName}/sessions";
      scratchDir = "~/.local/state/pi/projects/${projectName}/tmp";
      exchangeDir = "~/.local/state/pi/projects/${projectName}/exchange";
    in
    (with jailC; [
      network
      time-zone
      mount-cwd
      no-new-session

      (ro-bind envSrc "/usr/bin/env")

      # Config injected read-only from the store into the GLOBAL agent dir.
      (write-text (noescape "~/.pi/agent/settings.json") (builtins.toJSON piSettings))
      (write-text (noescape "~/.pi/agent/AGENTS.md") contextMd)

      # Global, host-backed: `/login` writes auth.json here and it persists
      # across projects. npm packages cache here too.
      (try-readwrite (noescape "~/.pi/agent/auth.json"))
      (try-readwrite (noescape "~/.pi/agent/npm"))

      # Per-project sessions (host-visible, isolated per projectName). The
      # launcher points PI_CODING_AGENT_SESSION_DIR here.
      (try-readwrite (noescape sessionDir))

      # Host-visible Scratch (TMPDIR) + Exchange (see CONTEXT.md).
      (try-readwrite (noescape scratchDir))
      (try-readwrite (noescape exchangeDir))

      # Shared caches — content-addressed / per-package, safe to share.
      (try-readwrite (noescape "~/.cache"))
      (try-readwrite (noescape "~/.bun"))
      (try-readwrite (noescape "~/.npm"))

      # Optional API-key auth; auth.json (/login) takes priority when both
      # are present. `try-` so the jail doesn't hard-fail when unset.
      (try-fwd-env "ANTHROPIC_API_KEY")
      (try-fwd-env "PI_CODING_AGENT_SESSION_DIR")
      (try-fwd-env "PI_SKIP_VERSION_CHECK")
      (try-fwd-env "TMPDIR")
      (try-fwd-env "PI_EXCHANGE_DIR")

      (set-env "SHELL" "${pkgs.bashInteractive}/bin/bash")
      # Distinctive in-jail prompt, matching the Claude profile.
      (set-env "PS1" "\\[\\e[1;31m\\](jail)\\[\\e[0m\\] bash-\\v\\$ ")
      (add-pkg-deps (basePkgs ++ projectPkgs))
    ])
    ++ lib.optional (skillsDir != null) (
      jailC.ro-bind "${skillsDir}" (jailC.noescape "~/.pi/agent/skills")
    )
    ++ lib.optional enableLocalAi (
      jailC.write-text (jailC.noescape "~/.pi/agent/models.json") (builtins.toJSON piModels)
    )
    ++ lib.mapAttrsToList (key: value: jailC.set-env key value) projectEnv
    ++ extra
    ++ extraCombinators;

  # Launcher preamble shared by both OSes: relocate Pi's per-project dirs +
  # Scratch/Exchange, and create them host-side so they're browsable before
  # launch. PI_EXCHANGE_DIR is the AGENTS.md handoff convention (Pi doesn't
  # read it natively; the instructions do).
  preambleOf = projectName: ''
    export PI_CODING_AGENT_SESSION_DIR="$HOME/.local/state/pi/projects/${projectName}/sessions"
    export TMPDIR="$HOME/.local/state/pi/projects/${projectName}/tmp"
    export PI_EXCHANGE_DIR="$HOME/.local/state/pi/projects/${projectName}/exchange"
    export PI_SKIP_VERSION_CHECK=1
    mkdir -p "$HOME/.pi/agent" "$PI_CODING_AGENT_SESSION_DIR" "$TMPDIR" "$PI_EXCHANGE_DIR"
  '';

in
{
  name = "pi";
  jailedName = "jailed-pi";
  package = pi-pkg;
  settings = piSettings;
  models = piModels;

  # Always-in-context instructions: base AGENTS.md + rules/*, injected at
  # ~/.pi/agent/AGENTS.md where Pi loads it as global context.
  mkContext = contextOf;

  # --- Linux (bwrap) builder ---
  mkLinuxBins =
    { projectName
    , rulesDir
    , skillsDir
    , agentMdFile
    , enableLocalAi
    , basePkgs
    , projectPkgs
    , projectEnv
    , extraCombinators
    , extraShellHook
    , extraSandboxedEnvForwards
    , engine
    }:
    let
      inherit (engine) pkgs lib jail sandboxed prereqGuidance projectNamePlaceholder;
      usesPlaceholder = projectName == projectNamePlaceholder;

      piCombinators = mkPiCombinators {
        jailC = jail.combinators;
        inherit lib pkgs projectName skillsDir agentMdFile rulesDir enableLocalAi
          basePkgs projectPkgs projectEnv extraCombinators;
        envSrc = "${pkgs.coreutils}/bin/env";
        extra = [ ];
      };

      jailedPi = jail "jailed-pi" pi-pkg piCombinators;
      jailedShell = jail "jailed-shell" pkgs.bashInteractive piCombinators;
      sandboxedPackages = [ sandboxed ];

      # Concrete (template) preamble — projectName baked at eval time.
      preamble = preambleOf projectName;

      # Zero-touch (apps) preamble — resolve PROJECT_NAME at invocation and
      # sed-substitute the placeholder out of the bwrap launcher's baked
      # per-project bind paths. Mirrors the engine's Claude Linux path; the sed
      # is anchored on /projects/ so it only rewrites the session/scratch/
      # exchange bind destinations, never ~/.pi/agent write-text sources.
      placeholderPreamble = jailBinary: ''
        PROJECT_NAME="''${NIX_SLOP_DEV_PROJECT_NAME:-$(${pkgs.coreutils}/bin/basename "$PWD")}"
        PROJECT_NAME="''${PROJECT_NAME//[^A-Za-z0-9._-]/_}"
        export PI_CODING_AGENT_SESSION_DIR="$HOME/.local/state/pi/projects/$PROJECT_NAME/sessions"
        export TMPDIR="$HOME/.local/state/pi/projects/$PROJECT_NAME/tmp"
        export PI_EXCHANGE_DIR="$HOME/.local/state/pi/projects/$PROJECT_NAME/exchange"
        export PI_SKIP_VERSION_CHECK=1
        mkdir -p "$HOME/.pi/agent" "$PI_CODING_AGENT_SESSION_DIR" "$TMPDIR" "$PI_EXCHANGE_DIR"
        SLOP_LAUNCH_DIR=$(${pkgs.coreutils}/bin/mktemp -d -t slop-env.XXXXXX)
        trap '${pkgs.coreutils}/bin/rm -rf "$SLOP_LAUNCH_DIR"' EXIT
        SLOP_LAUNCHER="$SLOP_LAUNCH_DIR/${baseNameOf jailBinary}"
        ${pkgs.gnused}/bin/sed "s|/projects/${projectNamePlaceholder}|/projects/$PROJECT_NAME|g" \
          ${jailBinary} > "$SLOP_LAUNCHER"
        ${pkgs.coreutils}/bin/chmod +x "$SLOP_LAUNCHER"
      '';

      sandboxedInvocation = jailBin: ''
        _pi_extra_e=""
        [ -n "''${ANTHROPIC_API_KEY:-}" ] && _pi_extra_e="-e ANTHROPIC_API_KEY"
        exec ${sandboxed}/bin/sandboxed -q ${hosts} \
          -e PI_CODING_AGENT_SESSION_DIR -e TMPDIR -e PI_EXCHANGE_DIR -e PI_SKIP_VERSION_CHECK \
          $_pi_extra_e ${lib.concatMapStrings (v: "-e ${v} ") extraSandboxedEnvForwards}\
          ${pkgs.util-linux}/bin/setpriv --ambient-caps=-sys_nice -- ${jailBin} "$@"
      '';

      pi = pkgs.writeShellScriptBin "pi" (
        if usesPlaceholder then ''
          set -euo pipefail
          ${placeholderPreamble "${jailedPi}/bin/jailed-pi"}
          ${sandboxedInvocation ''"$SLOP_LAUNCHER"''}
        '' else ''
          set -euo pipefail
          ${preamble}
          ${sandboxedInvocation "${jailedPi}/bin/jailed-pi"}
        ''
      );

      jail-shell = pkgs.writeShellScriptBin "jail-shell" (
        if usesPlaceholder then ''
          set -euo pipefail
          ${placeholderPreamble "${jailedShell}/bin/jailed-shell"}
          exec ${sandboxed}/bin/sandboxed -q \
            -e PI_CODING_AGENT_SESSION_DIR -e TMPDIR -e PI_EXCHANGE_DIR -e PI_SKIP_VERSION_CHECK -- \
            ${pkgs.util-linux}/bin/setpriv --ambient-caps=-sys_nice -- "$SLOP_LAUNCHER" "$@"
        '' else ''
          set -euo pipefail
          ${preamble}
          exec ${sandboxed}/bin/sandboxed -q \
            -e PI_CODING_AGENT_SESSION_DIR -e TMPDIR -e PI_EXCHANGE_DIR -e PI_SKIP_VERSION_CHECK -- \
            ${pkgs.util-linux}/bin/setpriv --ambient-caps=-sys_nice -- ${jailedShell}/bin/jailed-shell "$@"
        ''
      );

      localShellHook = lib.optionalString enableLocalAi ''
        pi-local() {
          mkdir -p "$HOME/.pi/agent" "$PI_CODING_AGENT_SESSION_DIR" "$TMPDIR" "$PI_EXCHANGE_DIR"
          PI_OFFLINE=1 ${sandboxed}/bin/sandboxed -q \
            -e PI_CODING_AGENT_SESSION_DIR -e TMPDIR -e PI_EXCHANGE_DIR -e PI_OFFLINE \
            ${pkgs.util-linux}/bin/setpriv --ambient-caps=-sys_nice -- jailed-pi "$@"
        }
        alias pl="pi-local"
      '';

      shellHook = # sh
        ''
          # Per-project state (sessions/scratch/exchange); ~/.pi/agent is global.
          ${preamble}

          # Setup checks
          _setup_ok=1
          ${prereqGuidance}/bin/slop-prereq-guidance || _setup_ok=0

          if [ ! -s "$HOME/.pi/agent/auth.json" ]; then
          	printf '\033[1;36mℹ Pi credentials not found.\033[0m\n'
          	printf '  Run pi and use /login (or export ANTHROPIC_API_KEY) on first use.\n\n'
          	_setup_ok=0
          fi

          if [ "$_setup_ok" -eq 1 ]; then
          	printf '\033[1;32m✓\033[0m Jailed pi ready. Run \033[1mpi\033[0m to start.\n'
          fi
          printf '\033[1;36mℹ\033[0m Exchange files with the agent via \033[1m%s\033[0m\n' "$PI_EXCHANGE_DIR"${lib.optionalString (extraShellHook != "") "\n${extraShellHook}"}

          # Jailed Pi
          pi() {
          	mkdir -p "$HOME/.pi/agent" "$PI_CODING_AGENT_SESSION_DIR" "$TMPDIR" "$PI_EXCHANGE_DIR"
          	_pi_extra_e=""
          	[ -n "''${ANTHROPIC_API_KEY:-}" ] && _pi_extra_e="-e ANTHROPIC_API_KEY"
          	${sandboxed}/bin/sandboxed -q ${hosts} \
          		-e PI_CODING_AGENT_SESSION_DIR -e TMPDIR -e PI_EXCHANGE_DIR -e PI_SKIP_VERSION_CHECK \
          		$_pi_extra_e ${lib.concatMapStrings (v: "-e ${v} ") extraSandboxedEnvForwards}\
          		${pkgs.util-linux}/bin/setpriv --ambient-caps=-sys_nice -- jailed-pi "$@"
          }
          alias jail-shell="${sandboxed}/bin/sandboxed -q -e PI_CODING_AGENT_SESSION_DIR -e TMPDIR -e PI_EXCHANGE_DIR -e PI_SKIP_VERSION_CHECK -- ${pkgs.util-linux}/bin/setpriv --ambient-caps=-sys_nice -- jailed-shell"
        '' + localShellHook;
    in
    {
      agent = pi;
      jailedAgent = jailedPi;
      inherit jail-shell jailedShell sandboxedPackages shellHook;
    };

  # --- Darwin (Seatbelt) builder ---
  # Mirrors the engine's built-in Claude Darwin path: per-jail sandboxed
  # overrides (sandbox-exec doesn't nest), host-resolve for nix-darwin's
  # /etc/* symlinks, and the set-environment skip switch. Pi-specific: no
  # /usr/bin/security keychain bind (Pi auth lives in auth.json), and no
  # prereq/auditd checks (Seatbelt is daemonless). Concrete projectName only.
  mkDarwinBins =
    { projectName
    , rulesDir
    , skillsDir
    , agentMdFile
    , enableLocalAi
    , basePkgs
    , projectPkgs
    , projectEnv
    , extraCombinators
    , extraShellHook
    , extraSandboxedEnvForwards
    , engine
    }:
    let
      inherit (engine) pkgs lib jail sandboxed projectNamePlaceholder;
      usesPlaceholder = projectName == projectNamePlaceholder;

      jailC = jail.combinators;

      # nix-darwin /etc/* shells are /nix/store symlinks; SBPL must allow the
      # kernel-canonical resolved path (host-resolve), and the set-environment
      # source is skipped via __NIX_DARWIN_SET_ENVIRONMENT_DONE. No keychain
      # bind — Pi reads auth.json, not the macOS keychain.
      darwinExtras = with jailC; [
        (host-resolve "/etc/bashrc")
        (host-resolve "/etc/zshrc")
        (host-resolve "/etc/zprofile")
        (host-resolve "/etc/zshenv")
        (host-resolve "/etc/terminfo")
        (set-env "__NIX_DARWIN_SET_ENVIRONMENT_DONE" "1")
      ];

      piCombinators = mkPiCombinators {
        inherit jailC lib pkgs projectName skillsDir agentMdFile rulesDir enableLocalAi
          basePkgs projectPkgs projectEnv extraCombinators;
        # SIP keeps /usr/bin read-only; src == dst so the read-allow emits with
        # no bind preflight.
        envSrc = "/usr/bin/env";
        extra = darwinExtras;
      };

      jailedPi = jail.jail "jailed-pi" pi-pkg piCombinators;
      jailedShell = jail.jail "jailed-shell" pkgs.bashInteractive piCombinators;

      # Per-jail Sandbox+Jail SBPL wrappers — sandbox-exec cannot nest.
      sandboxedPi = sandboxed.override {
        jail = jailedPi;
        binName = "sandboxed-jailed-pi";
      };
      sandboxedShell = sandboxed.override {
        jail = jailedShell;
        binName = "sandboxed-jailed-shell";
      };
      sandboxedPackages = [ sandboxedPi sandboxedShell ];

      # Concrete (template) vs zero-touch (apps) config setup. On Darwin the
      # per-jail wrapper does the SBPL projectName substitution itself, so the
      # placeholder launcher only resolves PROJECT_NAME and forwards it via
      # NIX_SLOP_DEV_PROJECT_NAME (mirroring the engine's Claude Darwin path) —
      # no sed in the launcher.
      placeholderPreamble = ''
        PROJECT_NAME="''${NIX_SLOP_DEV_PROJECT_NAME:-$(${pkgs.coreutils}/bin/basename "$PWD")}"
        PROJECT_NAME="''${PROJECT_NAME//[^A-Za-z0-9._-]/_}"
        export NIX_SLOP_DEV_PROJECT_NAME="$PROJECT_NAME"
        export PI_CODING_AGENT_SESSION_DIR="$HOME/.local/state/pi/projects/$PROJECT_NAME/sessions"
        export TMPDIR="$HOME/.local/state/pi/projects/$PROJECT_NAME/tmp"
        export PI_EXCHANGE_DIR="$HOME/.local/state/pi/projects/$PROJECT_NAME/exchange"
        export PI_SKIP_VERSION_CHECK=1
        mkdir -p "$HOME/.pi/agent" "$PI_CODING_AGENT_SESSION_DIR" "$TMPDIR" "$PI_EXCHANGE_DIR"
      '';
      configDirSetup = if usesPlaceholder then placeholderPreamble else preambleOf projectName;

      # sandbox-exec passes the exported parent env through (no `env -i`), so
      # the -e flags below mirror the Linux forwards for parity.
      pi = pkgs.writeShellScriptBin "pi" ''
        set -euo pipefail
        ${configDirSetup}
        _pi_extra_e=""
        [ -n "''${ANTHROPIC_API_KEY:-}" ] && _pi_extra_e="-e ANTHROPIC_API_KEY"
        exec ${sandboxedPi}/bin/sandboxed-jailed-pi -q ${hosts} \
          -e PI_CODING_AGENT_SESSION_DIR -e TMPDIR -e PI_EXCHANGE_DIR -e PI_SKIP_VERSION_CHECK \
          $_pi_extra_e ${lib.concatMapStrings (v: "-e ${v} ") extraSandboxedEnvForwards}"$@"
      '';

      jail-shell = pkgs.writeShellScriptBin "jail-shell" ''
        set -euo pipefail
        ${configDirSetup}
        exec ${sandboxedShell}/bin/sandboxed-jailed-shell -q \
          -e PI_CODING_AGENT_SESSION_DIR -e TMPDIR -e PI_EXCHANGE_DIR -e PI_SKIP_VERSION_CHECK "$@"
      '';

      localShellHook = lib.optionalString enableLocalAi ''
        pi-local() {
          mkdir -p "$HOME/.pi/agent" "$PI_CODING_AGENT_SESSION_DIR" "$TMPDIR" "$PI_EXCHANGE_DIR"
          PI_OFFLINE=1 ${sandboxedPi}/bin/sandboxed-jailed-pi -q -e PI_OFFLINE "$@"
        }
        alias pl="pi-local"
      '';

      shellHook = ''
        # Per-project state (sessions/scratch/exchange); ~/.pi/agent is global.
        ${configDirSetup}

        _setup_ok=1
        if [ ! -s "$HOME/.pi/agent/auth.json" ]; then
        	printf '\033[1;36mℹ Pi credentials not found.\033[0m\n'
        	printf '  Run pi and use /login (or export ANTHROPIC_API_KEY) on first use.\n\n'
        	_setup_ok=0
        fi

        if [ "$_setup_ok" -eq 1 ]; then
        	printf '\033[1;32m✓\033[0m Jailed pi ready. Run \033[1mpi\033[0m to start.\n'
        fi
        printf '\033[1;36mℹ\033[0m Exchange files with the agent via \033[1m%s\033[0m\n' "$PI_EXCHANGE_DIR"${lib.optionalString (extraShellHook != "") "\n${extraShellHook}"}
      '' + localShellHook;
    in
    {
      agent = pi;
      jailedAgent = jailedPi;
      inherit jail-shell jailedShell sandboxedPackages shellHook;
    };
}
