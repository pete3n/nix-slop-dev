{ pkgs, self }:

# Pure-eval behavioural checks for the multi-endpoint Local AI feature
# (ADRs 0011/0012/0013).
#
# Why this shape: the Agent Profile generators (lib/slop-env/profiles/{opencode,
# pi}.nix) expose pure helpers that turn the `localAi` module option
# ({ enable; settings = { endpoints }; }) into the provider / worker config each
# agent consumes. We import those profiles with a dummy package and call the
# helpers directly, asserting on the resulting Nix values at EVALUATION time:
# each `expectEq` throws a labelled error on mismatch, and the whole list is
# forced via deepSeq, so evaluating this derivation (even just its drvPath)
# exercises every behaviour. A build exiting 0 == all behaviours hold.
#
# Run: nix build '.#checks.x86_64-linux.local-ai-config' --no-link
#  or: nix eval --raw '.#checks.x86_64-linux.local-ai-config.drvPath'  (eval-only)

let
  lib = pkgs.lib;

  shared = import ../lib/slop-env/shared.nix { inherit pkgs; };

  # Profiles imported with a dummy package: the pure config generators under
  # test never touch the agent package, only the endpoint data.
  opencode = import ../lib/slop-env/profiles/opencode.nix {
    opencode-pkg = pkgs.hello;
    inherit shared;
  };

  pi = import ../lib/slop-env/profiles/pi.nix {
    pi-pkg = pkgs.hello;
    inherit shared;
  };

  # Eval-time assertion: returns true on match, else throws a labelled error
  # naming the expected and actual JSON. Collected into `behaviours` below.
  expectEq =
    label: expected: actual:
    if expected == actual then
      true
    else
      throw "FAIL ${label}: expected ${builtins.toJSON expected}, got ${builtins.toJSON actual}";

  # Helper: wrap an endpoints list as an enabled localAi option value.
  enabledWith = endpoints: {
    enable = true;
    settings.endpoints = endpoints;
  };

  # --- Slice 1: opencode emits one ollama-<name> provider per endpoint ---

  # A single endpoint declared port-only (ADR-0012) must yield a provider keyed
  # `ollama-<name>` whose baseURL is the loopback URL derived from the port.
  ocSingle = opencode.settingsFor (enabledWith [
    {
      name = "solo";
      port = 11434;
      models = [ { id = "qwen3:8b"; } ];
    }
  ]);

  # Two endpoints (the dual-GPU topology) → exactly two providers, one per
  # endpoint, each keyed ollama-<name> with its own loopback port + models.
  ocMulti = opencode.settingsFor (enabledWith [
    {
      name = "big";
      port = 11435;
      models = [
        {
          id = "qwen3-coder:latest";
          name = "Qwen3 Coder";
        }
      ];
    }
    {
      name = "fast";
      port = 11434;
      models = [ { id = "qwen3:8b"; } ];
    }
  ]);

  # enable=true with no endpoints reproduces the legacy single localhost
  # provider + local agent; enable=false emits no provider at all (the disabled
  # default), even when settings carries endpoints (see ocDisabledWithEndpoints).
  ocEnabledNoEndpoints = opencode.settingsFor { enable = true; };
  ocDisabled = opencode.settingsFor { };

  # --- Slice 2: pi models.json (one ollama-<name> provider per endpoint) ---
  piSingle = pi.modelsFor (enabledWith [
    {
      name = "solo";
      port = 11434;
      models = [ { id = "qwen3:8b"; } ];
    }
  ]);

  piMulti = pi.modelsFor (enabledWith [
    {
      name = "big";
      port = 11435;
      models = [
        {
          id = "qwen3-coder:latest";
          name = "Qwen3 Coder";
          reasoning = true;
        }
      ];
    }
    {
      name = "fast";
      port = 11434;
      models = [ { id = "qwen3:8b"; } ];
    }
  ]);

  # enable=true, no endpoints → the legacy single localhost provider (piModels).
  piEnabledNoEndpoints = pi.modelsFor { enable = true; };

  # --- The localAi.enable master switch: disabled ignores settings entirely ---
  # This is the templates-as-examples contract: a template can ship endpoints
  # under settings while enable=false leaves the config inert.
  disabledWithEndpoints = {
    enable = false;
    settings.endpoints = coordWorkerEndpoints;
  };
  ocDisabledWithEndpoints = opencode.settingsFor disabledWithEndpoints;
  piDisabledWithEndpoints = pi.modelsFor disabledWithEndpoints;

  # --- Slice 3: loopback liveness probe (shell snippet for the shellHook) ---
  probeMulti = shared.localLivenessProbe [
    {
      name = "big";
      port = 11435;
    }
    {
      name = "fast";
      port = 11434;
    }
  ];

  # Integration: an enabled localAi must reach each profile's emitted shellHook
  # (where the probe is injected); a disabled localAi (even with endpoints) and
  # the no-config default must stay free of it. Through the real mkBins API.
  slop = self.lib.slopEnv pkgs;
  endpointsForHook = [
    {
      name = "fast";
      port = 11434;
      models = [ { id = "qwen3:8b"; } ];
    }
  ];
  ocHookEnabled =
    (slop.mkBins {
      agent = slop.profiles.opencode;
      projectName = "probe-oc";
      localAi = enabledWith endpointsForHook;
    }).shellHook;
  piHookEnabled =
    (slop.mkBins {
      agent = slop.profiles.pi;
      projectName = "probe-pi";
      localAi = enabledWith endpointsForHook;
    }).shellHook;
  ocHookDisabledWithEndpoints =
    (slop.mkBins {
      agent = slop.profiles.opencode;
      projectName = "probe-oc-disabled";
      localAi = {
        enable = false;
        settings.endpoints = endpointsForHook;
      };
    }).shellHook;

  # --- Slice 4: opencode local coordinator/workers (B2) ---
  # `big` is the coordinator (launch model); `fast` is a worker (subagent).
  coordWorkerEndpoints = [
    {
      name = "big";
      port = 11435;
      coordinator = true;
      models = [
        {
          id = "qwen3-coder:latest";
          name = "Qwen3 Coder";
        }
      ];
    }
    {
      name = "fast";
      port = 11434;
      role = "Quick edits and small refactors";
      models = [ { id = "qwen3:8b"; } ];
    }
  ];
  ocCoord = opencode.settingsFor (enabledWith coordWorkerEndpoints);

  # A `default = true` endpoint (no coordinator) sets only the launch model.
  ocDefault = opencode.settingsFor (enabledWith [
    {
      name = "primary";
      port = 11434;
      default = true;
      models = [ { id = "qwen3:8b"; } ];
    }
    {
      name = "other";
      port = 11435;
      models = [ { id = "gemma3:latest"; } ];
    }
  ]);

  # No coordinator and no default: providers only; launch model stays anthropic.
  ocPlain = opencode.settingsFor (enabledWith [
    {
      name = "solo";
      port = 11434;
      models = [ { id = "qwen3:8b"; } ];
    }
  ]);

  twoCoordEndpoints = [
    {
      name = "c1";
      port = 11434;
      coordinator = true;
      models = [ { id = "m"; } ];
    }
    {
      name = "c2";
      port = 11435;
      coordinator = true;
      models = [ { id = "m"; } ];
    }
  ];
  ocTwoCoord = builtins.tryEval (opencode.settingsFor (enabledWith twoCoordEndpoints)).model;

  twoDefaultEndpoints = [
    {
      name = "d1";
      port = 11434;
      default = true;
      models = [ { id = "m"; } ];
    }
    {
      name = "d2";
      port = 11435;
      default = true;
      models = [ { id = "m"; } ];
    }
  ];
  ocTwoDefault = builtins.tryEval (opencode.settingsFor (enabledWith twoDefaultEndpoints)).model;

  # --- Slice 6: pi coordinator (settings.json) + worker .md generation ---
  piCoord = pi.settingsFor (enabledWith coordWorkerEndpoints);
  piWorkerDefs = pi.workerAgentDefsFor coordWorkerEndpoints;

  # pi parses worker-def frontmatter with eemeli yaml (unguarded), so a role
  # carrying YAML metacharacters must round-trip as a double-quoted scalar. This
  # adversarial role (colon-space, quotes, backslash, hash) is the recovered
  # test plan's hostile case.
  piHostileDefs = pi.workerAgentDefsFor [
    {
      name = "boss";
      port = 11434;
      coordinator = true;
      models = [ { id = "m0"; } ];
    }
    {
      name = "tricky";
      port = 11435;
      role = ''Reason: "deep" \ dives #1'';
      models = [ { id = "deepseek-r1:latest"; } ];
    }
  ];

  # Hardening: malformed endpoint lists must fail with a clear error, not a
  # silent provider collision or a cryptic builtins.head failure. tryEval forces
  # .providers so the validating throw inside the generator is exercised.
  dupNameEval = builtins.tryEval (pi.modelsFor (enabledWith [
    {
      name = "dup";
      port = 11434;
      models = [ { id = "a"; } ];
    }
    {
      name = "dup";
      port = 11435;
      models = [ { id = "b"; } ];
    }
  ])).providers;
  emptyModelsEval = builtins.tryEval (pi.modelsFor (enabledWith [
    {
      name = "x";
      port = 11434;
      models = [ ];
    }
  ])).providers;

  behaviours = [
    (expectEq "opencode: single endpoint derives loopback baseURL for ollama-<name>"
      "http://127.0.0.1:11434/v1"
      ocSingle.provider."ollama-solo".options.baseURL
    )
    (expectEq "opencode: one provider per endpoint, keyed ollama-<name>"
      [ "ollama-big" "ollama-fast" ]
      (builtins.attrNames ocMulti.provider)
    )
    (expectEq "opencode: each endpoint's baseURL derives from its own port"
      "http://127.0.0.1:11435/v1"
      ocMulti.provider."ollama-big".options.baseURL
    )
    (expectEq "opencode: declared model name flows into the provider's models"
      "Qwen3 Coder"
      ocMulti.provider."ollama-big".models."qwen3-coder:latest".name
    )
    (expectEq "opencode: a model without a name defaults its display name to its id"
      "qwen3:8b"
      ocMulti.provider."ollama-fast".models."qwen3:8b".name
    )
    (expectEq "opencode: enabled with no endpoints keeps the legacy localhost provider"
      "http://localhost:11434/v1"
      ocEnabledNoEndpoints.provider.ollama.options.baseURL
    )
    (expectEq "opencode: enabled with no endpoints keeps the legacy local subagent"
      "subagent"
      ocEnabledNoEndpoints.agent.local.mode
    )
    (expectEq "opencode: disabled (no config) emits no provider"
      false
      (builtins.hasAttr "provider" ocDisabled)
    )

    # --- localAi.enable master switch: disabled ignores configured endpoints ---
    (expectEq "opencode: disabled ignores configured endpoints (no provider)"
      false
      (builtins.hasAttr "provider" ocDisabledWithEndpoints)
    )
    (expectEq "opencode: disabled ignores configured endpoints (launch model stays anthropic)"
      "anthropic/claude-sonnet-4-6"
      ocDisabledWithEndpoints.model
    )
    (expectEq "pi: disabled ignores configured endpoints (no ollama-<name> provider)"
      false
      (builtins.hasAttr "ollama-big" piDisabledWithEndpoints.providers)
    )

    # --- Slice 2: pi emits one ollama-<name> provider per endpoint in models.json ---
    (expectEq "pi: single endpoint derives loopback baseUrl for ollama-<name>"
      "http://127.0.0.1:11434/v1"
      piSingle.providers."ollama-solo".baseUrl
    )
    (expectEq "pi: one provider per endpoint, keyed ollama-<name>"
      [ "ollama-big" "ollama-fast" ]
      (builtins.attrNames piMulti.providers)
    )
    (expectEq "pi: each endpoint's baseUrl derives from its own port"
      "http://127.0.0.1:11435/v1"
      piMulti.providers."ollama-big".baseUrl
    )
    (expectEq "pi: providers use the openai-completions API"
      "openai-completions"
      piMulti.providers."ollama-big".api
    )
    (expectEq "pi: local-server compat flags are set per provider"
      false
      piMulti.providers."ollama-big".compat.supportsDeveloperRole
    )
    (expectEq "pi: declared model reasoning flag flows into the model entry"
      true
      (builtins.head piMulti.providers."ollama-big".models).reasoning
    )
    (expectEq "pi: a model without a name defaults its display name to its id"
      "qwen3:8b"
      (builtins.head piMulti.providers."ollama-fast".models).name
    )
    (expectEq "pi: a model without a reasoning flag defaults to false"
      false
      (builtins.head piMulti.providers."ollama-fast".models).reasoning
    )
    (expectEq "pi: enabled with no endpoints keeps the legacy localhost provider"
      "http://localhost:11434/v1"
      piEnabledNoEndpoints.providers.ollama.baseUrl
    )

    # --- Slice 3: loopback liveness probe ---
    (expectEq "probe: TCP-connects each endpoint's port via /dev/tcp on loopback"
      true
      (lib.hasInfix "/dev/tcp/127.0.0.1/11435" probeMulti)
    )
    (expectEq "probe: probes every declared endpoint"
      true
      (lib.hasInfix "/dev/tcp/127.0.0.1/11434" probeMulti)
    )
    (expectEq "probe: empty endpoint list yields no probe (byte-identical default)"
      ""
      (shared.localLivenessProbe [ ])
    )
    (expectEq "probe: prints a summary hint when nothing is reachable"
      true
      (lib.hasInfix "no local AI endpoints reachable" probeMulti)
    )
    (expectEq "probe: reaches the opencode shellHook when localAi is enabled"
      true
      (lib.hasInfix "/dev/tcp/127.0.0.1/11434" ocHookEnabled)
    )
    (expectEq "probe: reaches the pi shellHook when localAi is enabled"
      true
      (lib.hasInfix "/dev/tcp/127.0.0.1/11434" piHookEnabled)
    )
    (expectEq "probe: absent from the opencode shellHook when localAi is disabled (even with endpoints)"
      false
      (lib.hasInfix "/dev/tcp" ocHookDisabledWithEndpoints)
    )

    # --- Slice 4: opencode local coordinator/workers (B2) ---
    (expectEq "opencode: the coordinator endpoint becomes the launch model"
      "ollama-big/qwen3-coder:latest"
      ocCoord.model
    )
    (expectEq "opencode: one subagent worker per non-coordinator endpoint"
      [ "fast" ]
      (builtins.attrNames ocCoord.agent)
    )
    (expectEq "opencode: a worker is a subagent"
      "subagent"
      ocCoord.agent.fast.mode
    )
    (expectEq "opencode: a worker's model is its endpoint's ollama-<name>/<id>"
      "ollama-fast/qwen3:8b"
      ocCoord.agent.fast.model
    )
    (expectEq "opencode: a worker's description is its endpoint's role"
      "Quick edits and small refactors"
      ocCoord.agent.fast.description
    )
    (expectEq "opencode: a default endpoint sets the launch model"
      "ollama-primary/qwen3:8b"
      ocDefault.model
    )
    (expectEq "opencode: a default endpoint generates no workers"
      false
      (builtins.hasAttr "agent" ocDefault)
    )
    (expectEq "opencode: no coordinator/default keeps the anthropic launch model"
      "anthropic/claude-sonnet-4-6"
      ocPlain.model
    )
    (expectEq "opencode: no coordinator/default still emits providers"
      true
      (builtins.hasAttr "provider" ocPlain)
    )
    (expectEq "opencode: more than one coordinator is a hard error"
      false
      ocTwoCoord.success
    )
    (expectEq "opencode: more than one default endpoint is a hard error"
      false
      ocTwoDefault.success
    )

    # --- Slice 6: pi coordinator (settings.json) ---
    (expectEq "pi: the coordinator endpoint becomes the default provider"
      "ollama-big"
      piCoord.defaultProvider
    )
    (expectEq "pi: the coordinator's first model becomes the default model"
      "qwen3-coder:latest"
      piCoord.defaultModel
    )

    # --- Slice 6: pi worker .md generation ---
    (expectEq "pi: one worker .md per non-coordinator endpoint (coordinator excluded)"
      [ "fast" ]
      (builtins.attrNames piWorkerDefs)
    )
    (expectEq "pi worker .md: opens with a YAML frontmatter fence at byte 0"
      true
      (lib.hasPrefix "---\nname:" piWorkerDefs.fast)
    )
    (expectEq "pi worker .md: name is the endpoint name (double-quoted)"
      true
      (lib.hasInfix ''name: "fast"'' piWorkerDefs.fast)
    )
    (expectEq "pi worker .md: description is the role (double-quoted)"
      true
      (lib.hasInfix ''description: "Quick edits and small refactors"'' piWorkerDefs.fast)
    )
    (expectEq "pi worker .md: model is ollama-<name>/<id> (double-quoted)"
      true
      (lib.hasInfix ''model: "ollama-fast/qwen3:8b"'' piWorkerDefs.fast)
    )
    (expectEq "pi worker .md: body scopes the worker to its role"
      true
      (lib.hasInfix "Your role: Quick edits and small refactors." piWorkerDefs.fast)
    )
    (expectEq "pi worker .md: a hostile role round-trips as an escaped double-quoted scalar"
      true
      (lib.hasInfix ''description: "Reason: \"deep\" \\ dives #1"'' piHostileDefs.tricky)
    )

    # --- Hardening: malformed endpoint lists fail clearly ---
    (expectEq "validation: duplicate endpoint names are a hard error"
      false
      dupNameEval.success
    )
    (expectEq "validation: an endpoint declaring no models is a hard error"
      false
      emptyModelsEval.success
    )
  ];

in
builtins.deepSeq behaviours (
  pkgs.runCommand "local-ai-config" { } ''
    touch $out
  ''
)
