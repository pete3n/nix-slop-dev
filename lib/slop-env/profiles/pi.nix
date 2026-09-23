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
  # localAi is enabled. Shape matches Pi's ModelsConfigSchema
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
            cost = {
              input = 0;
              output = 0;
              cacheRead = 0;
              cacheWrite = 0;
            };
          }
          {
            id = "gemma3:latest";
            name = "Gemma3 (Local)";
            reasoning = false;
            cost = {
              input = 0;
              output = 0;
              cacheRead = 0;
              cacheWrite = 0;
            };
          }
        ];
      };
    };
  };

  # Loopback base URL derived from a port alone (ADR-0012): a localAi endpoint
  # is port-only, so the emitted provider can never be pointed off 127.0.0.1.
  endpointBaseUrl = port: "http://127.0.0.1:${toString port}/v1";

  # One pi provider per endpoint, keyed `ollama-<name>`, in ModelsConfigSchema
  # shape: api openai-completions, a placeholder apiKey Ollama ignores, and the
  # local-server compat flags from the single-provider baseline. Each
  # endpoint's models become pi model entries with zero cost. `builtins.*` (not
  # lib.*) because the profile's top-level `let` has no `lib` in scope.
  piProvidersFor =
    endpoints:
    builtins.listToAttrs (
      map (endpoint: {
        name = "ollama-${endpoint.name}";
        value = {
          baseUrl = endpointBaseUrl endpoint.port;
          api = "openai-completions";
          apiKey = "ollama";
          compat = {
            supportsDeveloperRole = false;
            supportsReasoningEffort = false;
          };
          models = map (model: {
            id = model.id;
            name = model.name or model.id;
            reasoning = model.reasoning or false;
            cost = {
              input = 0;
              output = 0;
              cacheRead = 0;
              cacheWrite = 0;
            };
          }) endpoint.models;
        };
      }) endpoints
    );

  # models.json content, driven by the `localAi` option. When enabled with a
  # non-empty endpoints list, emits one provider per endpoint (multi-endpoint
  # path); otherwise the legacy single localhost provider (piModels). Exposed
  # for the test vehicle. The write itself stays gated on `localAi.enable` in
  # mkPiCombinators.
  modelsFor =
    {
      enable ? false,
      settings ? { },
    }:
    let
      endpoints = if enable then settings.endpoints or [ ] else [ ];
    in
    if endpoints != [ ] then
      { providers = piProvidersFor (shared.assertEndpoints endpoints); }
    else
      piModels;

  # First model id of an endpoint, referenced as ollama-<name>/<id> in worker
  # agent defs (Slice 6).
  endpointModelRef = endpoint: "ollama-${endpoint.name}/${(builtins.head endpoint.models).id}";

  coordinatorsOf = endpoints: builtins.filter (endpoint: endpoint.coordinator or false) endpoints;
  defaultsOf = endpoints: builtins.filter (endpoint: endpoint.default or false) endpoints;
  hasCoordinatorTopology = endpoints: coordinatorsOf endpoints != [ ];

  # settings.json content. With a coordinator/worker topology the marked
  # coordinator endpoint (else a single default=true endpoint) becomes pi's
  # launch defaultProvider (ollama-<name>) + defaultModel (its first model id);
  # otherwise piSettings (anthropic) is unchanged. Precedence coordinator ->
  # default -> anthropic; more than one coordinator or default is a hard error.
  # Exposed for the pure-eval test vehicle.
  settingsFor =
    {
      enable ? false,
      settings ? { },
    }:
    let
      endpoints = if enable then settings.endpoints or [ ] else [ ];
      coordinators = coordinatorsOf endpoints;
      defaults = defaultsOf endpoints;
      launchOf = endpoint: {
        defaultProvider = "ollama-${endpoint.name}";
        defaultModel = (builtins.head endpoint.models).id;
      };
    in
    if builtins.length coordinators > 1 then
      throw "slopEnv (pi): localAi.settings.endpoints declares ${toString (builtins.length coordinators)} coordinators; exactly one is allowed."
    else if builtins.length defaults > 1 then
      throw "slopEnv (pi): localAi.settings.endpoints declares ${toString (builtins.length defaults)} default endpoints; at most one is allowed."
    else if coordinators != [ ] then
      piSettings // launchOf (builtins.head coordinators)
    else if defaults != [ ] then
      piSettings // launchOf (builtins.head defaults)
    else
      piSettings;

  # YAML double-quoted scalar escaping for worker .md frontmatter. pi parses
  # frontmatter with eemeli yaml (UNGUARDED — a malformed scalar crashes agent
  # discovery), so name/description/model values are emitted as double-quoted
  # scalars with backslash and double-quote escaped. replaceStrings is a single
  # left-to-right pass with no re-scan, so escaping `\` and `"` together is safe
  # (neither is a prefix of the other).
  yamlQuote = str: "\"" + builtins.replaceStrings [ "\\" "\"" ] [ "\\\\" "\\\"" ] str + "\"";

  # The worker agent .md for one endpoint: frontmatter (name; description = role;
  # model = ollama-<name>/<id>) plus a body scoping the worker to its role,
  # fully offline. Matches the recovered fast.md verbatim.
  workerAgentMd =
    endpoint:
    let
      role = endpoint.role or "Local worker";
    in
    ''
      ---
      name: ${yamlQuote endpoint.name}
      description: ${yamlQuote role}
      model: ${yamlQuote (endpointModelRef endpoint)}
      ---
      You are a local worker agent ("${endpoint.name}") running fully offline on the user's machine, backed by a loopback Ollama endpoint — no data leaves the system.

      Your role: ${role}.

      Work autonomously to complete the delegated task, then return a concise result the coordinator can act on.
    '';

  # One worker .md per NON-coordinator endpoint, keyed by endpoint name (written
  # to ~/.pi/agent/agents/<name>.md). The coordinator drives pi's launch model
  # and is excluded from the worker pool. Exposed for the test vehicle.
  workerAgentDefsFor =
    endpoints:
    builtins.listToAttrs (
      map (endpoint: {
        name = endpoint.name;
        value = workerAgentMd endpoint;
      }) (builtins.filter (endpoint: !(endpoint.coordinator or false)) endpoints)
    );

  contextOf =
    { agentMdFile, rulesDir }:
    shared.mkContextMd {
      contextMdFile = agentMdFile;
      inherit rulesDir;
    };

  # Shared jail combinator list. `jailC` is jail.combinators (same access path
  # on both platforms); `envSrc` is the /usr/bin/env source (coreutils on
  # Linux, the SIP path on Darwin); `extra` carries OS-specific combinators
  # (Darwin's host-resolve / set-environment shims). Built once so the Linux
  # and Darwin jails cannot drift. The Linux value is byte-identical to the
  # original inline list (tests/template-pi-agent-drv.expected).
  mkPiCombinators =
    {
      jailC,
      lib,
      pkgs,
      envSrc,
      extra ? [ ],
      projectName,
      skillsDir,
      agentMdFile,
      rulesDir,
      localAi ? { },
      basePkgs,
      projectPkgs,
      projectEnv,
      extraCombinators,
    }:
    let
      contextMd = contextOf { inherit agentMdFile rulesDir; };
      sessionDir = "~/.local/state/pi/projects/${projectName}/sessions";
      scratchDir = "~/.local/state/pi/projects/${projectName}/tmp";
      exchangeDir = "~/.local/state/pi/projects/${projectName}/exchange";
      # localAi module option, normalized: when disabled, settings (endpoints)
      # are ignored entirely so the emitted jail is byte-identical.
      localAiEnabled = localAi.enable or false;
      localAiEndpoints = if localAiEnabled then localAi.settings.endpoints or [ ] else [ ];
    in
    (with jailC; [
      network
      time-zone
      mount-cwd
      no-new-session

      (ro-bind envSrc "/usr/bin/env")

      # Whole agent dir, host-backed rw + persistent. Pi creates lock dirs
      # (settings.json.lock / auth.json.lock — proper-lockfile uses mkdir),
      # writes auth.json on /login, caches packages under npm/, and persists
      # trust.json / themes / tools / bin — all of which need ~/.pi/agent itself
      # writable, not just individual files. This is also the "login once,
      # global agent dir" model. Must precede the write-text overlays below so
      # they layer on top (bwrap bind order; Seatbelt allows are additive).
      # HITL 2026-06-21: without this, pi EPERMs on settings.json.lock at start.
      (try-readwrite (noescape "~/.pi/agent"))

      # Nix-injected config, overlaid on top of the writable agent dir.
      (write-text (noescape "~/.pi/agent/settings.json") (
        builtins.toJSON (settingsFor localAi)
      ))
      (write-text (noescape "~/.pi/agent/AGENTS.md") contextMd)

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
      # Worktrunk worktrees inside .git/ (see ADR-0015). The jail only binds
      # the project dir (cwd), so worktrunk's default sibling path would land
      # outside the jail and the agent couldn't reach it; .git/ is under cwd,
      # reachable, and git never reports its own contents — so the worktrees
      # need no .gitignore. Jail-scoped: the user's own `wt` outside the jail
      # keeps worktrunk's default path. Value is worktrunk template syntax it
      # expands itself; set-env stores it verbatim.
      (set-env "WORKTRUNK_WORKTREE_PATH" ".git/slop-worktrees/{{branch|sanitize}}")
      (add-pkg-deps (basePkgs ++ projectPkgs))
    ])
    ++ lib.optional (skillsDir != null) (
      jailC.ro-bind "${skillsDir}" (jailC.noescape "~/.pi/agent/skills")
    )
    ++ lib.optional localAiEnabled (
      jailC.write-text (jailC.noescape "~/.pi/agent/models.json") (
        builtins.toJSON (modelsFor localAi)
      )
    )
    # B2 coordinator topology: one worker agent def per non-coordinator endpoint
    # at ~/.pi/agent/agents/<name>.md (Slice 6). Only emitted when a coordinator
    # is declared, so a plain multi-endpoint config (providers only) and the
    # default no-endpoints path stay byte-identical.
    ++ lib.optionals (hasCoordinatorTopology localAiEndpoints) (
      lib.mapAttrsToList (
        workerName: mdContent:
        jailC.write-text (jailC.noescape "~/.pi/agent/agents/${workerName}.md") mdContent
      ) (workerAgentDefsFor localAiEndpoints)
    )
    # B2: ro-bind the vendored pi subagent extension (ADR-0013) so the
    # coordinator can delegate to local workers. Gated on a coordinator topology
    # so provider-only and no-endpoint configs stay byte-identical. The bind
    # source holds exactly index.ts + agents.ts; pi auto-loads user-scope
    # extensions with no trust gate. See pi-subagent-ext/VENDORED.md.
    ++ lib.optional (hasCoordinatorTopology localAiEndpoints) (
      jailC.ro-bind "${./pi-subagent-ext/subagent}" (jailC.noescape "~/.pi/agent/extensions/subagent")
    )
    # Slice 5 (ADR-0013): put pi itself on the jail PATH so the subagent
    # extension can spawn a child `pi --mode json -p --no-session --model
    # ollama-<name>/<id>` for a worker. Gated on a coordinator topology (the
    # only case that spawns child pis), so other configs stay byte-identical.
    ++ lib.optional (hasCoordinatorTopology localAiEndpoints) (jailC.add-pkg-deps [ pi-pkg ])
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

  # Pure config generators, exposed for the local-ai-config test vehicle.
  inherit modelsFor settingsFor workerAgentDefsFor;

  # Always-in-context instructions: base AGENTS.md + rules/*, injected at
  # ~/.pi/agent/AGENTS.md where Pi loads it as global context.
  mkContext = contextOf;

  # --- Linux (bwrap) builder ---
  mkLinuxBins =
    {
      projectName,
      rulesDir,
      skillsDir,
      agentMdFile,
      localAi ? { },
      basePkgs,
      projectPkgs,
      projectEnv,
      extraCombinators,
      extraShellHook,
      extraSandboxedEnvForwards,
      engine,
    }:
    let
      inherit (engine)
        pkgs
        lib
        jail
        sandboxed
        prereqGuidance
        projectNamePlaceholder
        ;
      usesPlaceholder = projectName == projectNamePlaceholder;
      localAiEnabled = localAi.enable or false;
      localAiEndpoints = if localAiEnabled then localAi.settings.endpoints or [ ] else [ ];

      piCombinators = mkPiCombinators {
        jailC = jail.combinators;
        inherit
          lib
          pkgs
          projectName
          skillsDir
          agentMdFile
          rulesDir
          localAi
          basePkgs
          projectPkgs
          projectEnv
          extraCombinators
          ;
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
        if usesPlaceholder then
          ''
            set -euo pipefail
            ${placeholderPreamble "${jailedPi}/bin/jailed-pi"}
            ${sandboxedInvocation ''"$SLOP_LAUNCHER"''}
          ''
        else
          ''
            set -euo pipefail
            ${preamble}
            ${sandboxedInvocation "${jailedPi}/bin/jailed-pi"}
          ''
      );

      jail-shell = pkgs.writeShellScriptBin "jail-shell" (
        if usesPlaceholder then
          ''
            set -euo pipefail
            ${placeholderPreamble "${jailedShell}/bin/jailed-shell"}
            exec ${sandboxed}/bin/sandboxed -q \
              -e PI_CODING_AGENT_SESSION_DIR -e TMPDIR -e PI_EXCHANGE_DIR -e PI_SKIP_VERSION_CHECK -- \
              ${pkgs.util-linux}/bin/setpriv --ambient-caps=-sys_nice -- "$SLOP_LAUNCHER" "$@"
          ''
        else
          ''
            set -euo pipefail
            ${preamble}
            exec ${sandboxed}/bin/sandboxed -q \
              -e PI_CODING_AGENT_SESSION_DIR -e TMPDIR -e PI_EXCHANGE_DIR -e PI_SKIP_VERSION_CHECK -- \
              ${pkgs.util-linux}/bin/setpriv --ambient-caps=-sys_nice -- ${jailedShell}/bin/jailed-shell "$@"
          ''
      );

      localShellHook = lib.optionalString localAiEnabled ''
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
        printf '\033[1;36mℹ\033[0m Exchange files with the agent via \033[1m%s\033[0m\n' "$PI_EXCHANGE_DIR"${
          lib.optionalString (extraShellHook != "") "\n${extraShellHook}"
        }${shared.localLivenessProbe localAiEndpoints}

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
      ''
      + localShellHook;
    in
    {
      agent = pi;
      jailedAgent = jailedPi;
      inherit
        jail-shell
        jailedShell
        sandboxedPackages
        shellHook
        ;
    };

  # --- Darwin (Seatbelt) builder ---
  # Mirrors the engine's built-in Claude Darwin path: per-jail sandboxed
  # overrides (sandbox-exec doesn't nest), host-resolve for nix-darwin's
  # /etc/* symlinks, and the set-environment skip switch. Pi-specific: no
  # /usr/bin/security keychain bind (Pi auth lives in auth.json), and no
  # prereq/auditd checks (Seatbelt is daemonless). Concrete projectName only.
  mkDarwinBins =
    {
      projectName,
      rulesDir,
      skillsDir,
      agentMdFile,
      localAi ? { },
      basePkgs,
      projectPkgs,
      projectEnv,
      extraCombinators,
      extraShellHook,
      extraSandboxedEnvForwards,
      engine,
    }:
    let
      inherit (engine)
        pkgs
        lib
        jail
        sandboxed
        projectNamePlaceholder
        ;
      usesPlaceholder = projectName == projectNamePlaceholder;
      localAiEnabled = localAi.enable or false;
      localAiEndpoints = if localAiEnabled then localAi.settings.endpoints or [ ] else [ ];

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
        inherit
          jailC
          lib
          pkgs
          projectName
          skillsDir
          agentMdFile
          rulesDir
          localAi
          basePkgs
          projectPkgs
          projectEnv
          extraCombinators
          ;
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
      sandboxedPackages = [
        sandboxedPi
        sandboxedShell
      ];

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

      localShellHook = lib.optionalString localAiEnabled ''
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
        printf '\033[1;36mℹ\033[0m Exchange files with the agent via \033[1m%s\033[0m\n' "$PI_EXCHANGE_DIR"${
          lib.optionalString (extraShellHook != "") "\n${extraShellHook}"
        }${shared.localLivenessProbe localAiEndpoints}
      ''
      + localShellHook;
    in
    {
      agent = pi;
      jailedAgent = jailedPi;
      inherit
        jail-shell
        jailedShell
        sandboxedPackages
        shellHook
        ;
    };
}
