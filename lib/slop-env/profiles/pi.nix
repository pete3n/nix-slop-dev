{ pi-pkg, shared }:

# Agent Profile for Pi (earendil-works/pi) — ADR-0009. See CONTEXT.md for the
# *Agent Profile* term.
#
# Pi's layout differs from Claude's in nearly every structural detail, so this
# profile supplies its own Linux builder (`mkLinuxBins`) rather than reusing the
# engine's built-in Claude path:
#   - Config dir is the GLOBAL ~/.pi/agent (not a per-project tmpfs). settings/
#     AGENTS.md are injected read-only from the store; auth.json is host-bound
#     so `/login` persists once across all projects.
#   - Per-project isolation is sessions-only, via PI_CODING_AGENT_SESSION_DIR
#     (config.ts ENV_SESSION_DIR) pointed at a per-project state dir.
#   - Pi loads ~/.pi/agent/AGENTS.md as global context (resource-loader.ts).
#
# Scope: greenfield template only — a concrete projectName is required (no
# zero-touch apps.${system}.pi path, so no placeholder/sed machinery). Darwin
# is not yet supported (no mkDarwinBins); darwin.nix throws for this profile.

let
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
in
{
  name = "pi";
  jailedName = "jailed-pi";
  package = pi-pkg;
  settings = piSettings;
  models = piModels;

  # Always-in-context instructions: base AGENTS.md + rules/*, injected at
  # ~/.pi/agent/AGENTS.md where Pi loads it as global context.
  mkContext = { agentMdFile, rulesDir }:
    shared.mkContextMd { contextMdFile = agentMdFile; inherit rulesDir; };

  # Linux builder. Returns the agent-neutral mkBins output shape
  # ({ agent; jailedAgent; jail-shell; jailedShell; sandboxedPackages;
  # shellHook; }). `engine` carries the OS-specific scaffolding from linux.nix.
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

      # Pi has no zero-touch apps path yet, so a concrete projectName is
      # required — the per-project session/scratch/exchange paths are baked at
      # eval time with no runtime sed substitution.
      _ =
        if projectName == projectNamePlaceholder then
          throw "pi-agent: a concrete projectName is required (no zero-touch apps.\${system}.pi path yet)"
        else
          null;

      contextMd = shared.mkContextMd { contextMdFile = agentMdFile; inherit rulesDir; };

      # Per-project state root on the host (sessions, scratch, exchange).
      # ~/.pi/agent stays global (auth.json + settings = login once).
      stateDir = "~/.local/state/pi/projects/${projectName}";
      sessionDir = "${stateDir}/sessions";
      scratchDir = "${stateDir}/tmp";
      exchangeDir = "${stateDir}/exchange";

      c = jail.combinators;

      piCombinators =
        (with c; [
          network
          time-zone
          mount-cwd
          no-new-session

          (ro-bind "${pkgs.coreutils}/bin/env" "/usr/bin/env")

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

          # Host-visible Scratch (TMPDIR) + Exchange (see CONTEXT.md). The jail
          # denies /tmp and `env -i` drops these, so the launcher exports them
          # into this writable, host-reachable dir and forwards them in.
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
          c.ro-bind "${skillsDir}" (c.noescape "~/.pi/agent/skills")
        )
        ++ lib.optional enableLocalAi (
          c.write-text (c.noescape "~/.pi/agent/models.json") (builtins.toJSON piModels)
        )
        ++ lib.mapAttrsToList (key: value: c.set-env key value) projectEnv
        ++ extraCombinators;

      jailedPi = jail "jailed-pi" pi-pkg piCombinators;
      jailedShell = jail "jailed-shell" pkgs.bashInteractive piCombinators;

      sandboxedPackages = [ sandboxed ];

      # Shared launcher preamble: relocate Pi's per-project dirs + Scratch/
      # Exchange, bake $HOME-relative paths, and create them host-side so
      # they're browsable before launch. PI_EXCHANGE_DIR is the AGENTS.md
      # handoff convention (Pi doesn't read it natively; the instructions do).
      preamble = ''
        export PI_CODING_AGENT_SESSION_DIR="$HOME/.local/state/pi/projects/${projectName}/sessions"
        export TMPDIR="$HOME/.local/state/pi/projects/${projectName}/tmp"
        export PI_EXCHANGE_DIR="$HOME/.local/state/pi/projects/${projectName}/exchange"
        export PI_SKIP_VERSION_CHECK=1
        mkdir -p "$HOME/.pi/agent" "$PI_CODING_AGENT_SESSION_DIR" "$TMPDIR" "$PI_EXCHANGE_DIR"
      '';

      # Optional API-key forward: only add `-e ANTHROPIC_API_KEY` when it's set,
      # so an unset var doesn't perturb the sandboxed invocation.
      sandboxedInvocation = jailBin: ''
        _pi_extra_e=""
        [ -n "''${ANTHROPIC_API_KEY:-}" ] && _pi_extra_e="-e ANTHROPIC_API_KEY"
        exec ${sandboxed}/bin/sandboxed -q \
          --allow api.anthropic.com --allow platform.claude.com --allow 2607:6bc0::/32 \
          -e PI_CODING_AGENT_SESSION_DIR -e TMPDIR -e PI_EXCHANGE_DIR -e PI_SKIP_VERSION_CHECK \
          $_pi_extra_e ${lib.concatMapStrings (v: "-e ${v} ") extraSandboxedEnvForwards}\
          ${pkgs.util-linux}/bin/setpriv --ambient-caps=-sys_nice -- ${jailBin} "$@"
      '';

      # PATH-binary wrapper (mirrors the Claude profile's `agent` key). Unused
      # by the Linux dev shell (which calls the pi() shellHook function) but
      # kept for output-shape parity and any future apps entry point.
      pi = pkgs.writeShellScriptBin "pi" ''
        set -euo pipefail
        ${preamble}
        ${sandboxedInvocation "${jailedPi}/bin/jailed-pi"}
      '';

      jail-shell = pkgs.writeShellScriptBin "jail-shell" ''
        set -euo pipefail
        ${preamble}
        exec ${sandboxed}/bin/sandboxed -q \
          -e PI_CODING_AGENT_SESSION_DIR -e TMPDIR -e PI_EXCHANGE_DIR -e PI_SKIP_VERSION_CHECK -- \
          ${pkgs.util-linux}/bin/setpriv --ambient-caps=-sys_nice -- ${jailedShell}/bin/jailed-shell "$@"
      '';

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
          	${sandboxed}/bin/sandboxed -q \
          		--allow api.anthropic.com --allow platform.claude.com --allow 2607:6bc0::/32 \
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
}
