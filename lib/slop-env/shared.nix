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
    , skillsDir
    , claudeMd
    , claudeSettings
    , basePkgs
    , projectPkgs
    , projectEnv
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

      (ro-bind "${pkgs.coreutils}/bin/env" "/usr/bin/env")

      # Ephemeral config dir; project-fixed content written on top.
      (tmpfs (noescape cfgDir))
      (ro-bind "${skillsDir}" (noescape "${cfgDir}/skills"))
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
      (add-pkg-deps (basePkgs ++ projectPkgs))
    ]
    ++ lib.mapAttrsToList (key: value: c.set-env key value) projectEnv;
}
