{ pkgs }:

# Platform-agnostic Slop Env building blocks. ADR-0005's `shared` layer.
# Per-OS arms (linux.nix, darwin.nix in slice 21) consume these to assemble
# the jail combinator list and the dev shell.

let
  lib = pkgs.lib;
in
rec {
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

  # Assemble the CLAUDE.md contents: base file + every rules/*.md
  # concatenated. Universal policy is always in context (unlike
  # relevance-recalled memory, which is per-project and dynamically pathed).
  mkClaudeMd =
    { claudeMdFile, rulesDir }:
    let
      ruleNames = builtins.attrNames (
        lib.filterAttrs (name: kind: kind == "regular" && lib.hasSuffix ".md" name) (
          builtins.readDir rulesDir
        )
      );
      ruleBodies = map (name: builtins.readFile (rulesDir + "/${name}")) ruleNames;
    in
    lib.concatStringsSep "\n\n" ([ (builtins.readFile claudeMdFile) ] ++ ruleBodies);

  # Standard slop-env jail combinator list. Per-OS layers can append
  # additional combinators (e.g. Darwin's host-resolve for /etc/* symlinks)
  # — last-match-wins lets caller-supplied extras narrow defaults.
  #
  # Arg shape mirrors the template's inline let-binding so the byte-eq
  # check holds after the lift.
  mkJailCombinators =
    { jail
    , projectName
    , skillsDir ? null
    , claudeMd
    , claudeSettings
    , basePkgs
    , projectPkgs
    , projectEnv
    , # Source path for the env interpreter the jail mounts at
      # /usr/bin/env. Linux bwrap binds coreutils' env into the mount
      # namespace; Darwin's /usr/bin is SIP-protected so the binding's
      # source is the literal /usr/bin/env on the host (slice 21).
      envSrc ? "${pkgs.coreutils}/bin/env"
    , # cfgDir lifecycle combinator. Linux uses jail-nix's tmpfs (a
      # real namespace-local mount — the host's cfgDir is shadowed,
      # not modified, so cleanup-on-exit is a host no-op). Darwin's
      # local tmpfs `rm -rf`s the actual host dir at trap-exit, which
      # destroys claude's persistent state (.claude.json, sessions,
      # history) between runs. Darwin overrides with `ensure-dir`
      # (mkdir-only, no cleanup); Linux keeps the tmpfs default.
      # HITL 2026-06-19.
      cfgDirCombinator ? null
    , # When false, omit the shared-credentials symlink graft below.
      # Sound only where cfgDir persists on its own (Darwin's ensure-dir):
      # claude writes .credentials.json atomically (write .tmp + rename),
      # which detaches a single-file symlink, and the next launch's
      # `ln -sfn -f` preflight would delete the real token. Linux keeps it
      # (true) — its tmpfs cfgDir has no other persistence path.
      # HITL 2026-06-19.
      shareCredentialsFile ? true
    ,
    }:
    let
      sharedDir = "~/.local/state/claude/shared";
      cfgDir = "~/.local/state/claude/projects/${projectName}";
      c = jail.combinators;
      cfgDirInit =
        if cfgDirCombinator != null
        then cfgDirCombinator (c.noescape cfgDir)
        else c.tmpfs (c.noescape cfgDir);
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
    ++ lib.optional shareCredentialsFile
      (rw-bind (noescape "${sharedDir}/.credentials.json") (noescape "${cfgDir}/.credentials.json"))

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

      # Shared caches — safe to share, contents are content-addressed
      # or per-package, not per-session state.
      (try-readwrite (noescape "~/.cache"))
      (try-readwrite (noescape "~/.npm"))
      (try-readwrite (noescape "~/.local/share/claude-code"))

      (try-fwd-env "CLAUDE_CONFIG_DIR")
      (set-env "SHELL" "${pkgs.bashInteractive}/bin/bash")
      # Distinctive prompt inside the jail so the user can tell at a
      # glance which shell they're in. The outer dev shell prints
      # bash's default `bash-5.3$`; the jailed bash prints
      # `(jail) bash-5.3$` in red. Cross-platform — slice-21 brings
      # Darwin parity for this prompt to Linux, where the
      # bwrap-spawned bash respects PS1 the same way Seatbelt's does.
      (set-env "PS1" "\\[\\e[1;31m\\](jail)\\[\\e[0m\\] bash-\\v\\$ ")
      (add-pkg-deps (basePkgs ++ projectPkgs))
    ]
    ++ lib.mapAttrsToList (key: value: c.set-env key value) projectEnv;
}
