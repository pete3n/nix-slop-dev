{ pkgs }:

# Platform-agnostic Slop Env building blocks. ADR-0005's `shared` layer.
# Per-OS arms (linux.nix, darwin.nix in slice 21) consume these to assemble
# the jail combinator list and the dev shell.

let
  lib = pkgs.lib;
in
{
  # Default base package set. Every Slop Env ships at least these so the
  # jailed shell is usable (sh + the unix toolbox + git/gh + ripgrep, etc).
  # Projects can extend via mkShell's basePkgs / projectPkgs args.
  defaultBasePkgs = with pkgs; [
    bashInteractive
    bc
    coreutils
    diffutils
    findutils
    gawk
    gh
    git
    gnugrep
    gnused
    gnutar
    gzip
    jq
    nix
    ps
    python314
    ripgrep
    unzip
    which
  ];

  # Settings file dropped into the jail's per-project CLAUDE config dir.
  # JSON-encoded once at lib-load time so the value is a string the
  # write-text combinator can hand to the jail.
  defaultClaudeSettings = builtins.toJSON {
    autoUpdaterStatus = "disabled";
    theme = "dark-ansi";
    permissions = {
      allow = [ ];
      deny = [ ];
    };
  };

  # Assemble the always-in-context instructions file: base file + every
  # rules/*.md concatenated. Universal policy is always in context (unlike
  # relevance-recalled memory, which is per-project and dynamically pathed).
  # Agent-neutral — Claude loads it as CLAUDE.md, Pi as AGENTS.md; the profile
  # decides the destination filename.
  mkContextMd =
    { contextMdFile, rulesDir }:
    let
      ruleNames = builtins.attrNames (
        lib.filterAttrs (name: kind: kind == "regular" && lib.hasSuffix ".md" name) (
          builtins.readDir rulesDir
        )
      );
      ruleBodies = map (name: builtins.readFile (rulesDir + "/${name}")) ruleNames;
    in
    lib.concatStringsSep "\n\n" ([ (builtins.readFile contextMdFile) ] ++ ruleBodies);

  # Loopback liveness probe for declared Local AI endpoints (Slice 3; ADR-0012).
  # Emitted into the devShell shellHook — NOT the launchers — so it runs on the
  # host where the user's SSH tunnels are visible. Each endpoint is probed with
  # a dependency-free bash /dev/tcp connect under a 1s timeout (store-path
  # timeout/bash so it never relies on the outer shell's PATH). Warn-only: a
  # failed probe prints a hint and never blocks shell entry or agent launch.
  # An empty list yields the empty string, so a config without localAiEndpoints
  # emits an unchanged shellHook (the byte-equality invariant).
  localLivenessProbe =
    localAiEndpoints:
    let
      probeOne = endpoint: ''
        if ${pkgs.coreutils}/bin/timeout 1 ${pkgs.bashInteractive}/bin/bash -c 'exec 3<>/dev/tcp/127.0.0.1/${toString endpoint.port}' 2>/dev/null; then
          printf '\033[1;32m✓\033[0m local AI endpoint %s reachable on 127.0.0.1:%s\n' '${endpoint.name}' '${toString endpoint.port}'
          _slop_localai_up=1
        else
          printf '\033[1;33m✗\033[0m local AI endpoint %s unreachable on 127.0.0.1:%s (tunnel down?)\n' '${endpoint.name}' '${toString endpoint.port}'
        fi
      '';
    in
    lib.optionalString (localAiEndpoints != [ ]) ''

      # Local AI endpoint liveness (warn-only; ADR-0012 loopback). No nc/curl
      # dependency, never blocks shell entry.
      _slop_localai_up=0
      ${lib.concatMapStrings probeOne localAiEndpoints}if [ "$_slop_localai_up" -eq 0 ]; then
        printf '\033[1;33mℹ\033[0m no local AI endpoints reachable — start your SSH tunnel(s).\n'
      fi'';

  # Validate a localAiEndpoints list, returning it unchanged on success so it
  # composes inline (`map f (assertEndpoints endpoints)`). Guards two failure
  # modes the profiles cannot represent sanely: duplicate endpoint names (which
  # would silently collide into one ollama-<name> provider via listToAttrs), and
  # an endpoint with no models (the launch/worker model ref ollama-<name>/<id>
  # would be undefined). Both become eval errors with a clear message. An empty
  # list is valid (the back-compat no-endpoints path).
  assertEndpoints =
    localAiEndpoints:
    let
      names = map (endpoint: endpoint.name) localAiEndpoints;
      modelless = builtins.filter (endpoint: (endpoint.models or [ ]) == [ ]) localAiEndpoints;
    in
    if builtins.length (lib.unique names) != builtins.length names then
      throw "slopEnv: localAi.settings.endpoints has duplicate endpoint name(s); each name must be unique (it becomes the ollama-<name> provider key). Got: ${lib.concatStringsSep ", " names}"
    else if modelless != [ ] then
      throw "slopEnv: localAi.settings.endpoints entry '${(builtins.head modelless).name}' declares no models; each endpoint needs at least one { id = ...; }."
    else
      localAiEndpoints;

  # Standard slop-env jail combinator list. Per-OS layers can append
  # additional combinators (e.g. Darwin's host-resolve for /etc/* symlinks)
  # — last-match-wins lets caller-supplied extras narrow defaults.
  #
  # Arg shape mirrors the template's inline let-binding so the byte-eq
  # check holds after the lift.
  mkJailCombinators =
    {
      jail,
      projectName,
      skillsDir ? null,
      claudeMd,
      claudeSettings,
      basePkgs,
      projectPkgs,
      projectEnv,
      # Source path for the env interpreter the jail mounts at
      # /usr/bin/env. Linux bwrap binds coreutils' env into the mount
      # namespace; Darwin's /usr/bin is SIP-protected so the binding's
      # source is the literal /usr/bin/env on the host (slice 21).
      envSrc ? "${pkgs.coreutils}/bin/env",
      # cfgDir lifecycle combinator. Linux uses jail-nix's tmpfs (a
      # real namespace-local mount — the host's cfgDir is shadowed,
      # not modified, so cleanup-on-exit is a host no-op). Darwin's
      # local tmpfs `rm -rf`s the actual host dir at trap-exit, which
      # destroys claude's persistent state (.claude.json, sessions,
      # history) between runs. Darwin overrides with `ensure-dir`
      # (mkdir-only, no cleanup); Linux keeps the tmpfs default.
      # HITL 2026-06-19.
      cfgDirCombinator ? null,
      # When false, omit the shared-credentials symlink graft below.
      # Sound only where cfgDir persists on its own (Darwin's ensure-dir):
      # claude writes .credentials.json atomically (write .tmp + rename),
      # which detaches a single-file symlink, and the next launch's
      # `ln -sfn -f` preflight would delete the real token. Linux keeps it
      # (true) — its tmpfs cfgDir has no other persistence path.
      # HITL 2026-06-19.
      shareCredentialsFile ? true,
      # ADR-0014 per-Account profile-contract hooks. `accountSessionSuffix` is
      # appended to the per-project config dir so an active Account gets its own
      # session/state root (per Account-and-project); `accountCredFile` is the
      # credential graft SOURCE (per-Account, cross-project). Both default to
      # the no-Account values ("" and the shared file), so an Account-free Slop
      # Env emits a byte-identical combinator list. The OS engine fills these
      # with the __SLOP_ENV_ACCOUNT__ placeholder when an Account is active and
      # the launcher sed-substitutes it (slash-anchored) at invocation.
      accountSessionSuffix ? "",
      accountCredFile ? null,
    }:
    let
      sharedDir = "~/.local/state/claude/shared";
      # The Account segment rides on cfgDir, so every per-project state path
      # below (settings, sessions, .credentials.json dest, caches' siblings)
      # inherits it without further plumbing. Empty suffix => today's path.
      cfgDir = "~/.local/state/claude/projects/${projectName}${accountSessionSuffix}";
      # Credential graft source: per-Account dir when active, else the shared
      # single-identity file (byte-identical no-Account default).
      credSourceFile =
        if accountCredFile != null then accountCredFile else "${sharedDir}/.credentials.json";
      c = jail.combinators;
      cfgDirInit =
        if cfgDirCombinator != null then
          cfgDirCombinator (c.noescape cfgDir)
        else
          c.tmpfs (c.noescape cfgDir);
    in
    with c;
    [
      network
      time-zone
      mount-cwd
      no-new-session

      (ro-bind envSrc "/usr/bin/env")

      # Per-project config dir. Linux gets jail-nix's tmpfs (in-
      # namespace ephemeral); Darwin gets ensure-dir (host-
      # persistent) via the cfgDirCombinator parameter.
      cfgDirInit
    ]
    # Skills dir is the per-project starting bundle. Apps' zero-touch
    # path leaves it null (no project-specific skills) — slice 18 spec
    # bundles only CLAUDE.md + rules under lib/slop-env/defaults/.
    ++ lib.optional (skillsDir != null) (ro-bind "${skillsDir}" (noescape "${cfgDir}/skills"))
    ++ [
      (write-text (noescape "${cfgDir}/settings.json") claudeSettings)
      (write-text (noescape "${cfgDir}/CLAUDE.md") claudeMd)
    ]

    # Shared identity, grafted into the per-project config dir via a
    # symlink to one host file. Only sound where cfgDir is ephemeral
    # (Linux tmpfs), where the symlink is the sole persistence path. On
    # Darwin cfgDir persists (ensure-dir) and the symlink is harmful:
    # claude writes .credentials.json atomically (write .tmp + rename),
    # replacing the symlink with a regular file so the shared target
    # never fills, and the next launch's `ln -sfn -f` preflight deletes
    # the real token. Darwin sets shareCredentialsFile=false and lets the
    # token live in the persistent cfgDir directly. HITL 2026-06-19.
    ++ lib.optional shareCredentialsFile (
      rw-bind (noescape credSourceFile) (noescape "${cfgDir}/.credentials.json")
    )

    ++ [
      # Per-project persistent state.
      (try-readwrite (noescape "${cfgDir}/.claude.json"))
      (try-readwrite (noescape "${cfgDir}/.last-cleanup"))
      (try-readwrite (noescape "${cfgDir}/backups"))
      (try-readwrite (noescape "${cfgDir}/history.jsonl"))
      (try-readwrite (noescape "${cfgDir}/plugins"))
      (try-readwrite (noescape "${cfgDir}/policy-limits.json"))
      (try-readwrite (noescape "${cfgDir}/projects"))
      (try-readwrite (noescape "${cfgDir}/remote-settings.json"))
      (try-readwrite (noescape "${cfgDir}/session-env"))
      (try-readwrite (noescape "${cfgDir}/sessions"))
      (try-readwrite (noescape "${cfgDir}/shell-snapshots"))
      (try-readwrite (noescape "${cfgDir}/statsig"))
      (try-readwrite (noescape "${cfgDir}/todos"))

      # Host-visible per-project Scratch (TMPDIR) and Exchange dirs — see
      # CONTEXT.md for both terms. Scratch is the agent's default temp;
      # Exchange is the deliberate user<->agent file-handoff channel (the
      # handoff skill writes here). Both must be reachable from the host: on
      # Linux cfgDir is an in-namespace tmpfs, so these children are rw-bound
      # back to the real host dir (host-visible + persistent); on Darwin
      # cfgDir is a persistent ensure-dir, so the bind is a
      # redundant-but-harmless allow (same as the cfgDir children above). The
      # launchers export TMPDIR / CLAUDE_EXCHANGE_DIR pointing at these paths
      # and forward them in (try-fwd-env below) because `env -i` drops them.
      (try-readwrite (noescape "${cfgDir}/tmp"))
      (try-readwrite (noescape "${cfgDir}/exchange"))

      # Shared caches — safe to share, contents are content-addressed
      # or per-package, not per-session state.
      (try-readwrite (noescape "~/.cache"))
      (try-readwrite (noescape "~/.npm"))
      (try-readwrite (noescape "~/.local/share/claude-code"))

      (try-fwd-env "CLAUDE_CONFIG_DIR")
      # Scratch + Exchange (above). `env -i` in the jail launcher drops
      # these, so Node's os.tmpdir() / the handoff skill would otherwise fall
      # back to the jail-denied /tmp; forward the launcher-set values in.
      (try-fwd-env "TMPDIR")
      (try-fwd-env "CLAUDE_EXCHANGE_DIR")
      (set-env "SHELL" "${pkgs.bashInteractive}/bin/bash")
      # Distinctive prompt inside the jail so the user can tell at a
      # glance which shell they're in. The outer dev shell prints
      # bash's default `bash-5.3$`; the jailed bash prints
      # `(jail) bash-5.3$` in red. Cross-platform — slice-21 brings
      # Darwin parity for this prompt to Linux, where the
      # bwrap-spawned bash respects PS1 the same way Seatbelt's does.
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
    ]
    # ADR-0014: for an active Account (accountCredFile set) forward
    # ANTHROPIC_API_KEY through the jail's `env -i`, so an apikey Account's
    # launcher-supplied key reaches the agent. try-fwd-env only forwards when
    # the var is set, so oauth Accounts (no key) are unaffected. Omitted with
    # no Account, keeping the no-Account combinator list byte-identical.
    ++ lib.optional (accountCredFile != null) (c.try-fwd-env "ANTHROPIC_API_KEY")
    ++ lib.mapAttrsToList (key: value: c.set-env key value) projectEnv;
}
