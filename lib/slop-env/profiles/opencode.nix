{ opencode-pkg, shared }:

# Agent Profile for opencode (sst/opencode) — ADR-0009 + ADR-0010. See
# CONTEXT.md for the *Agent Profile* term.
#
# Structurally pi-like (it supplies its own per-OS builders rather than reusing
# the engine's built-in Claude path), but it diverges from pi in one decided
# way (ADR-0010): the zero-touch apps.${system}.opencode launcher resolves the
# per-project Scratch/Exchange dirs at invocation WITHOUT the
# __SLOP_ENV_PROJECT_NAME__ placeholder/sed machinery that claude and pi use.
#
# opencode's layout (verified against the opencode source):
#   - Sessions live in a single global SQLite db under ~/.local/share/opencode,
#     keyed by project directory — so the Jail's mount-cwd bind self-isolates
#     sessions per project with no per-project bind to substitute (ADR-0010).
#   - Config dir ~/.config/opencode is read-only: opencode.json + AGENTS.md are
#     injected from the store; AGENTS.md at the global config dir is loaded as
#     ambient instructions natively (instruction-context.ts).
#   - Skills are scanned from {skill,skills}/**/SKILL.md under each config dir
#     (skill/index.ts + config/paths.ts directories()), so the merged bundle
#     ro-bound at ~/.config/opencode/skills is picked up unmodified.
#   - Auth persists as ~/.local/share/opencode/auth.json (`opencode auth login`)
#     unless ANTHROPIC_API_KEY is forwarded in.
#   - The only genuinely per-project dirs are slop-env's Scratch (TMPDIR) and
#     Exchange (OPENCODE_EXCHANGE_DIR); they ride the parent rw bind
#     ~/.local/state/opencode and are mkdir'd by the launcher (ADR-0010).
#
# Both Linux (bwrap) and Darwin (Seatbelt) are supported; the combinator list
# is shared (mkOpencodeCombinators) so they cannot drift.

let
  hosts = "--allow api.anthropic.com --allow platform.claude.com --allow 2607:6bc0::/32 --allow models.dev";

  # opencode.json. NO `shell` key (the launcher sets SHELL to nix's
  # bashInteractive via set-env instead); NO empty `provider` (that would be a
  # no-op the schema doesn't need). AGENTS.md is loaded from the global config
  # dir natively; the `instructions` entry additionally pulls in any project
  # AGENTS.md.
  opencodeSettings = {
    "$schema" = "https://opencode.ai/config.json";
    model = "anthropic/claude-sonnet-4-6";
    autoupdate = false;
    instructions = [ "AGENTS.md" ];
  };

  # Local-AI provider + sub-agent, merged into opencode.json only when
  # localAi is enabled. The npm package (@ai-sdk/openai-compatible) is bundled
  # in the opencode binary, so no registry fetch is needed; the loopback
  # baseURL is not network-confined by the Sandbox, so the local launcher runs
  # genuinely offline (OPENCODE_DISABLE_MODELS_FETCH=1, no --allow hosts).
  opencodeLocalProvider = {
    ollama = {
      npm = "@ai-sdk/openai-compatible";
      name = "Ollama (local)";
      options = {
        baseURL = "http://localhost:11434/v1";
        apiKey = "ollama";
      };
      models = {
        "qwen3-coder:latest" = {
          name = "Qwen3 Coder (Local)";
        };
        "gemma3:latest" = {
          name = "Gemma3 (Local)";
        };
      };
    };
  };

  opencodeLocalAgent = {
    local = {
      model = "ollama/qwen3-coder:latest";
      mode = "subagent";
      description = "Fully-local agent backed by ollama; no data leaves the machine.";
      prompt = ''
        You are a fully-local coding assistant running on the user's machine via
        ollama. No data leaves the system. Prefer concise, direct answers.
      '';
    };
  };

  # Loopback base URL derived from a port alone (ADR-0012): a localAi endpoint
  # is port-only, so the emitted provider can never be pointed off 127.0.0.1.
  endpointBaseUrl = port: "http://127.0.0.1:${toString port}/v1";

  # One opencode provider per endpoint, keyed `ollama-<name>`, exposing that
  # endpoint's models. Mirrors opencodeLocalProvider's shape (the bundled
  # @ai-sdk/openai-compatible npm package + a placeholder apiKey Ollama
  # ignores) but with the per-endpoint loopback baseURL. `builtins.listToAttrs`
  # (not lib.*) because the profile's top-level `let` has no `lib` in scope.
  opencodeProvidersFor =
    endpoints:
    builtins.listToAttrs (
      map (endpoint: {
        name = "ollama-${endpoint.name}";
        value = {
          npm = "@ai-sdk/openai-compatible";
          name = "Ollama (${endpoint.name})";
          options = {
            baseURL = endpointBaseUrl endpoint.port;
            apiKey = "ollama";
          };
          models = builtins.listToAttrs (
            map (model: {
              name = model.id;
              value = {
                name = model.name or model.id;
              };
            }) endpoint.models
          );
        };
      }) endpoints
    );

  # First model id of an endpoint. The launch model and each worker's model are
  # referenced as `ollama-<name>/<first model id>` (provider key + model id).
  endpointModelRef = endpoint: "ollama-${endpoint.name}/${(builtins.head endpoint.models).id}";

  coordinatorsOf = endpoints: builtins.filter (endpoint: endpoint.coordinator or false) endpoints;
  defaultsOf = endpoints: builtins.filter (endpoint: endpoint.default or false) endpoints;

  # Worker agent system prompt: a local, offline worker scoped to its declared
  # role. Shares its shape with the pi worker .md body (Slice 6).
  workerPrompt = endpoint: ''
    You are a local worker agent ("${endpoint.name}") running fully offline on the user's machine, backed by a loopback Ollama endpoint — no data leaves the system.

    Your role: ${endpoint.role or "a local worker"}.

    Work autonomously to complete the delegated task, then return a concise result the coordinator can act on.
  '';

  # Coordinator/worker (B2) launch model + subagents for a multi-endpoint
  # config. Precedence (recovered): a single `coordinator` endpoint is the
  # launch model AND is excluded from the worker pool (so no loopback port hosts
  # both coordinator and a worker — avoids OLLAMA_MAX_LOADED_MODELS=1 eviction);
  # else a single `default = true` endpoint is the launch model with NO workers;
  # else the built-in anthropic model is kept. More than one coordinator, or
  # more than one default, is ambiguous and is a hard error.
  opencodeCoordinatorSettings =
    endpoints:
    let
      coordinators = coordinatorsOf endpoints;
      defaults = defaultsOf endpoints;
      workerEndpoints = builtins.filter (endpoint: !(endpoint.coordinator or false)) endpoints;
      workerAgents = builtins.listToAttrs (
        map (endpoint: {
          name = endpoint.name;
          value = {
            model = endpointModelRef endpoint;
            mode = "subagent";
            description = endpoint.role or "Local worker";
            prompt = workerPrompt endpoint;
          };
        }) workerEndpoints
      );
    in
    if builtins.length coordinators > 1 then
      throw "slopEnv (opencode): localAi.settings.endpoints declares ${toString (builtins.length coordinators)} coordinators; exactly one is allowed."
    else if builtins.length defaults > 1 then
      throw "slopEnv (opencode): localAi.settings.endpoints declares ${toString (builtins.length defaults)} default endpoints; at most one is allowed."
    else if coordinators != [ ] then
      {
        model = endpointModelRef (builtins.head coordinators);
        agent = workerAgents;
      }
    else if defaults != [ ] then
      { model = endpointModelRef (builtins.head defaults); }
    else
      { };

  # opencode.json local-AI settings, driven by the `localAi` module option
  # ({ enable; settings = { endpoints }; }). `enable` is the master switch: when
  # false, `settings` is ignored entirely and no provider is emitted (so a
  # template can ship example endpoints that stay inert). When enabled, a
  # non-empty `endpoints` list emits one provider per endpoint plus the
  # coordinator/worker launch model + agents; an empty list falls back to the
  # legacy single-localhost provider + agent. Exposed for the test vehicle.
  settingsFor =
    {
      enable ? false,
      settings ? { },
    }:
    let
      endpoints = settings.endpoints or [ ];
    in
    opencodeSettings
    // (
      if !enable then
        { }
      else if endpoints != [ ] then
        let
          validated = shared.assertEndpoints endpoints;
        in
        { provider = opencodeProvidersFor validated; } // opencodeCoordinatorSettings validated
      else
        {
          provider = opencodeLocalProvider;
          agent = opencodeLocalAgent;
        }
    );

  contextOf =
    { agentMdFile, rulesDir }:
    shared.mkContextMd {
      contextMdFile = agentMdFile;
      inherit rulesDir;
    };

  # Shared jail combinator list. `jailC` is jail.combinators; `envSrc` is the
  # /usr/bin/env source (coreutils on Linux, the SIP path on Darwin); `extra`
  # carries OS-specific combinators (Darwin's host-resolve / set-environment
  # shims). Built once so the Linux and Darwin jails cannot drift.
  #
  # ADR-0010: there is NO per-project bind here. opencode's per-project state
  # (the SQLite session db) self-keys by cwd inside the global data bind, and
  # Scratch/Exchange ride the parent rw bind ~/.local/state/opencode — so the
  # jail launch script is byte-identical regardless of projectName, and carries
  # no __SLOP_ENV_PROJECT_NAME__ sentinel.
  mkOpencodeCombinators =
    {
      jailC,
      lib,
      pkgs,
      envSrc,
      extra ? [ ],
      skillsDir,
      agentMdFile,
      rulesDir,
      localAi ? { },
      basePkgs,
      projectPkgs,
      projectEnv,
      extraCombinators,
      cfgDirCombinator ? null,
    }:
    let
      contextMd = contextOf { inherit agentMdFile rulesDir; };

      # opencode writes instance state into its config dir at boot
      # (InstanceStore.boot -> Config.loadInstanceState drops a .gitignore),
      # so ~/.config/opencode must be a writable base. Linux gets jail-nix's
      # tmpfs (in-namespace ephemeral, so the host config dir is never
      # exposed); Darwin gets ensure-dir (host-persistent, no cleanup) via the
      # cfgDirCombinator param. The injected opencode.json/AGENTS.md/skills are
      # layered read-only on top — opencode only reads those.
      cfgDirInit =
        if cfgDirCombinator != null then
          cfgDirCombinator (jailC.noescape "~/.config/opencode")
        else
          jailC.tmpfs (jailC.noescape "~/.config/opencode");
    in
    (with jailC; [
      network
      time-zone
      mount-cwd
      no-new-session

      (ro-bind envSrc "/usr/bin/env")

      # State (rw, host-backed + persistent):
      #   ~/.local/share/opencode — sqlite session db, auth.json, log, repos.
      #     Sessions self-key by cwd, so this single global bind isolates them
      #     per project (ADR-0010).
      #   ~/.local/state/opencode — XDG state + Flock lock files, and the parent
      #     of slop-env's per-project projects/<name>/{tmp,exchange} subtree.
      #   ~/.cache — opencode caches the models.dev catalog + its bin/ dir here.
      (try-readwrite (noescape "~/.local/share/opencode"))
      (try-readwrite (noescape "~/.local/state/opencode"))
      (try-readwrite (noescape "~/.cache"))

      # Config dir: a writable base (cfgDirInit) so opencode can persist the
      # instance state it writes at boot (a .gitignore via
      # Config.loadInstanceState — opencode would otherwise EPERM here). The
      # store-injected opencode.json + AGENTS.md are layered read-only on top;
      # opencode reads those, never writes them.
      cfgDirInit
      (write-text (noescape "~/.config/opencode/opencode.json") (
        builtins.toJSON (settingsFor localAi)
      ))
      (write-text (noescape "~/.config/opencode/AGENTS.md") contextMd)

      # Optional API-key auth; auth.json (`opencode auth login`) takes priority
      # when both are present. `try-` so the jail doesn't hard-fail when unset.
      (try-fwd-env "ANTHROPIC_API_KEY")
      # Scratch (TMPDIR) + Exchange (OPENCODE_EXCHANGE_DIR), set by the launcher
      # and forwarded in because `env -i` drops them. OPENCODE_DISABLE_MODELS_FETCH
      # is forwarded for the local (offline) launcher.
      (try-fwd-env "TMPDIR")
      (try-fwd-env "OPENCODE_EXCHANGE_DIR")
      (try-fwd-env "OPENCODE_DISABLE_MODELS_FETCH")

      (set-env "SHELL" "${pkgs.bashInteractive}/bin/bash")
      # Distinctive in-jail prompt, matching the other profiles.
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
      jailC.ro-bind "${skillsDir}" (jailC.noescape "~/.config/opencode/skills")
    )
    ++ lib.mapAttrsToList (key: value: jailC.set-env key value) projectEnv
    ++ extra
    ++ extraCombinators;

  # Launcher preamble: relocate Scratch/Exchange under the project and create
  # them (plus the parent state/data/cache dirs the jail binds rw) host-side so
  # they're browsable before launch. ADR-0010: this just mkdirs + exports — no
  # sed of the jail script, because nothing per-project is baked into a bind.
  #
  # `projectExpr` is the shell expression that expands to the project name —
  # a baked literal in concrete (template) mode, or "$PROJECT_NAME" after the
  # resolver runs in zero-touch (apps) mode.
  preambleBody = projectExpr: ''
    export TMPDIR="$HOME/.local/state/opencode/projects/${projectExpr}/tmp"
    export OPENCODE_EXCHANGE_DIR="$HOME/.local/state/opencode/projects/${projectExpr}/exchange"
    mkdir -p "$HOME/.local/share/opencode" "$HOME/.local/state/opencode" "$HOME/.cache" \
      "$TMPDIR" "$OPENCODE_EXCHANGE_DIR"
  '';

in
{
  name = "opencode";
  jailedName = "jailed-opencode";
  package = opencode-pkg;
  settings = opencodeSettings;

  # Pure opencode.json generator, exposed for the local-ai-config test vehicle.
  inherit settingsFor;

  # Always-in-context instructions: base AGENTS.md + rules/*, injected at
  # ~/.config/opencode/AGENTS.md where opencode loads it as ambient context.
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
      localAiEndpoints = localAi.settings.endpoints or [ ];

      ocCombinators = mkOpencodeCombinators {
        jailC = jail.combinators;
        inherit
          lib
          pkgs
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

      jailedOpencode = jail "jailed-opencode" opencode-pkg ocCombinators;
      jailedShell = jail "jailed-shell" pkgs.bashInteractive ocCombinators;
      sandboxedPackages = [ sandboxed ];

      # Concrete (template) preamble — projectName baked at eval time.
      concretePreamble = preambleBody projectName;

      # Zero-touch (apps) preamble — resolve PROJECT_NAME at invocation, then
      # mkdir + export. ADR-0010: NO sed of the jail launcher (no baked
      # per-project bind to rewrite), NO mktemp/trap. The sanitiser matches the
      # engine's Claude/pi path so the basename can't smuggle shell metacharacters.
      resolvePreamble = ''
        PROJECT_NAME="''${NIX_SLOP_DEV_PROJECT_NAME:-$(${pkgs.coreutils}/bin/basename "$PWD")}"
        PROJECT_NAME="''${PROJECT_NAME//[^A-Za-z0-9._-]/_}"
      ''
      + preambleBody "$PROJECT_NAME";

      preamble = if usesPlaceholder then resolvePreamble else concretePreamble;

      sandboxedInvocation = ''
        _oc_extra_e=""
        [ -n "''${ANTHROPIC_API_KEY:-}" ] && _oc_extra_e="-e ANTHROPIC_API_KEY"
        exec ${sandboxed}/bin/sandboxed -q ${hosts} \
          -e TMPDIR -e OPENCODE_EXCHANGE_DIR \
          $_oc_extra_e ${lib.concatMapStrings (v: "-e ${v} ") extraSandboxedEnvForwards}\
          ${pkgs.util-linux}/bin/setpriv --ambient-caps=-sys_nice -- ${jailedOpencode}/bin/jailed-opencode "$@"
      '';

      opencode = pkgs.writeShellScriptBin "opencode" ''
        set -euo pipefail
        ${preamble}
        ${sandboxedInvocation}
      '';

      jail-shell = pkgs.writeShellScriptBin "jail-shell" ''
        set -euo pipefail
        ${preamble}
        exec ${sandboxed}/bin/sandboxed -q \
          -e TMPDIR -e OPENCODE_EXCHANGE_DIR -- \
          ${pkgs.util-linux}/bin/setpriv --ambient-caps=-sys_nice -- ${jailedShell}/bin/jailed-shell "$@"
      '';

      # Local (offline) launcher: loopback isn't network-confined, so no --allow
      # hosts; OPENCODE_DISABLE_MODELS_FETCH=1 keeps it from touching models.dev.
      localShellHook = lib.optionalString localAiEnabled ''
        opencode-local() {
          ${preamble}
          OPENCODE_DISABLE_MODELS_FETCH=1 ${sandboxed}/bin/sandboxed -q \
            -e TMPDIR -e OPENCODE_EXCHANGE_DIR -e OPENCODE_DISABLE_MODELS_FETCH \
            ${pkgs.util-linux}/bin/setpriv --ambient-caps=-sys_nice -- jailed-opencode --agent local "$@"
        }
        alias ocl="opencode-local"
      '';

      shellHook = # sh
      ''
        # Per-project Scratch/Exchange; opencode's own state is global.
        ${preamble}

        # Setup checks
        _setup_ok=1
        ${prereqGuidance}/bin/slop-prereq-guidance || _setup_ok=0

        if [ ! -s "$HOME/.local/share/opencode/auth.json" ] && [ -z "''${ANTHROPIC_API_KEY:-}" ]; then
        	printf '\033[1;36mℹ opencode credentials not found.\033[0m\n'
        	printf '  Run opencode and use /login (or export ANTHROPIC_API_KEY) on first use.\n\n'
        	_setup_ok=0
        fi

        if [ "$_setup_ok" -eq 1 ]; then
        	printf '\033[1;32m✓\033[0m Jailed opencode ready. Run \033[1mopencode\033[0m to start.\n'
        fi
        printf '\033[1;36mℹ\033[0m Exchange files with the agent via \033[1m%s\033[0m\n' "$OPENCODE_EXCHANGE_DIR"${
          lib.optionalString (extraShellHook != "") "\n${extraShellHook}"
        }${shared.localLivenessProbe (lib.optionals localAiEnabled localAiEndpoints)}

        # Jailed opencode
        opencode() {
        	${preamble}
        	_oc_extra_e=""
        	[ -n "''${ANTHROPIC_API_KEY:-}" ] && _oc_extra_e="-e ANTHROPIC_API_KEY"
        	${sandboxed}/bin/sandboxed -q ${hosts} \
        		-e TMPDIR -e OPENCODE_EXCHANGE_DIR \
        		$_oc_extra_e ${lib.concatMapStrings (v: "-e ${v} ") extraSandboxedEnvForwards}\
        		${pkgs.util-linux}/bin/setpriv --ambient-caps=-sys_nice -- jailed-opencode "$@"
        }
        alias jail-shell="${sandboxed}/bin/sandboxed -q -e TMPDIR -e OPENCODE_EXCHANGE_DIR -- ${pkgs.util-linux}/bin/setpriv --ambient-caps=-sys_nice -- jailed-shell"
      ''
      + localShellHook;
    in
    {
      agent = opencode;
      jailedAgent = jailedOpencode;
      inherit
        jail-shell
        jailedShell
        sandboxedPackages
        shellHook
        ;
    };

  # --- Darwin (Seatbelt) builder ---
  # Mirrors the engine's Claude Darwin path: per-jail sandboxed overrides
  # (sandbox-exec doesn't nest), host-resolve for nix-darwin's /etc/* symlinks,
  # and the set-environment skip switch. opencode-specific: no keychain bind
  # (auth.json, not the macOS keychain), and — ADR-0010 — no SBPL projectName
  # substitution, so the per-jail wrapper is byte-identical regardless of
  # projectName and the launcher just mkdirs + exports.
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
      localAiEndpoints = localAi.settings.endpoints or [ ];

      jailC = jail.combinators;

      darwinExtras = with jailC; [
        (host-resolve "/etc/bashrc")
        (host-resolve "/etc/zshrc")
        (host-resolve "/etc/zprofile")
        (host-resolve "/etc/zshenv")
        (host-resolve "/etc/terminfo")
        (set-env "__NIX_DARWIN_SET_ENVIRONMENT_DONE" "1")
      ];

      ocCombinators = mkOpencodeCombinators {
        inherit
          jailC
          lib
          pkgs
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
        # Seatbelt can't mount a tmpfs, so the writable config dir must persist
        # on the host (no rm-rf cleanup) — same rationale as the Claude cfgDir.
        cfgDirCombinator = jailC.ensure-dir;
      };

      jailedOpencode = jail.jail "jailed-opencode" opencode-pkg ocCombinators;
      jailedShell = jail.jail "jailed-shell" pkgs.bashInteractive ocCombinators;

      # Per-jail Sandbox+Jail SBPL wrappers — sandbox-exec cannot nest.
      sandboxedOpencode = sandboxed.override {
        jail = jailedOpencode;
        binName = "sandboxed-jailed-opencode";
      };
      sandboxedShell = sandboxed.override {
        jail = jailedShell;
        binName = "sandboxed-jailed-shell";
      };
      sandboxedPackages = [
        sandboxedOpencode
        sandboxedShell
      ];

      # ADR-0010: no NIX_SLOP_DEV_PROJECT_NAME forwarding (the wrapper has no
      # SBPL projectName substitution to feed). Concrete bakes the name;
      # zero-touch resolves it at invocation. Both just mkdir + export.
      resolvePreamble = ''
        PROJECT_NAME="''${NIX_SLOP_DEV_PROJECT_NAME:-$(${pkgs.coreutils}/bin/basename "$PWD")}"
        PROJECT_NAME="''${PROJECT_NAME//[^A-Za-z0-9._-]/_}"
      ''
      + preambleBody "$PROJECT_NAME";
      preamble = if usesPlaceholder then resolvePreamble else preambleBody projectName;

      # sandbox-exec passes the exported parent env through (no `env -i`), so the
      # -e flags below mirror the Linux forwards for parity.
      opencode = pkgs.writeShellScriptBin "opencode" ''
        set -euo pipefail
        ${preamble}
        _oc_extra_e=""
        [ -n "''${ANTHROPIC_API_KEY:-}" ] && _oc_extra_e="-e ANTHROPIC_API_KEY"
        exec ${sandboxedOpencode}/bin/sandboxed-jailed-opencode -q ${hosts} \
          -e TMPDIR -e OPENCODE_EXCHANGE_DIR \
          $_oc_extra_e ${lib.concatMapStrings (v: "-e ${v} ") extraSandboxedEnvForwards}"$@"
      '';

      jail-shell = pkgs.writeShellScriptBin "jail-shell" ''
        set -euo pipefail
        ${preamble}
        exec ${sandboxedShell}/bin/sandboxed-jailed-shell -q \
          -e TMPDIR -e OPENCODE_EXCHANGE_DIR "$@"
      '';

      localShellHook = lib.optionalString localAiEnabled ''
        opencode-local() {
          ${preamble}
          OPENCODE_DISABLE_MODELS_FETCH=1 ${sandboxedOpencode}/bin/sandboxed-jailed-opencode -q \
            -e TMPDIR -e OPENCODE_EXCHANGE_DIR -e OPENCODE_DISABLE_MODELS_FETCH --agent local "$@"
        }
        alias ocl="opencode-local"
      '';

      shellHook = ''
        # Per-project Scratch/Exchange; opencode's own state is global.
        ${preamble}

        _setup_ok=1
        if [ ! -s "$HOME/.local/share/opencode/auth.json" ] && [ -z "''${ANTHROPIC_API_KEY:-}" ]; then
        	printf '\033[1;36mℹ opencode credentials not found.\033[0m\n'
        	printf '  Run opencode and use /login (or export ANTHROPIC_API_KEY) on first use.\n\n'
        	_setup_ok=0
        fi

        if [ "$_setup_ok" -eq 1 ]; then
        	printf '\033[1;32m✓\033[0m Jailed opencode ready. Run \033[1mopencode\033[0m to start.\n'
        fi
        printf '\033[1;36mℹ\033[0m Exchange files with the agent via \033[1m%s\033[0m\n' "$OPENCODE_EXCHANGE_DIR"${
          lib.optionalString (extraShellHook != "") "\n${extraShellHook}"
        }${shared.localLivenessProbe (lib.optionals localAiEnabled localAiEndpoints)}
      ''
      + localShellHook;
    in
    {
      agent = opencode;
      jailedAgent = jailedOpencode;
      inherit
        jail-shell
        jailedShell
        sandboxedPackages
        shellHook
        ;
    };
}
