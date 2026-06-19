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
    ,
    }:
    let
      sharedDir = "~/.local/state/claude/shared";
      cfgDir = "~/.local/state/claude/projects/${projectName}";
      c = jail.combinators;
    in
    with c;
    [
      network
      time-zone
      mount-cwd
      no-new-session

      (ro-bind envSrc "/usr/bin/env")

      # Ephemeral config dir; project-fixed content written on top.
      (tmpfs (noescape cfgDir))
    ]
    # Skills dir is the per-project starting bundle. Apps' zero-touch
    # path leaves it null (no project-specific skills) — slice 18 spec
    # bundles only CLAUDE.md + rules under lib/slop-env/defaults/.
    ++ lib.optional (skillsDir != null) (ro-bind "${skillsDir}" (noescape "${cfgDir}/skills"))
    ++ [
      (write-text (noescape "${cfgDir}/settings.json") claudeSettings)
      (write-text (noescape "${cfgDir}/CLAUDE.md") claudeMd)

      # Shared identity, grafted into the per-project config dir.
      # Host file must exist before launch (touched in shellHook).
      (rw-bind (noescape "${sharedDir}/.credentials.json") (noescape "${cfgDir}/.credentials.json"))

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
