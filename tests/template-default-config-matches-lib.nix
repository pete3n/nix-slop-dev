{ pkgs }:

# Drift detector for the duplication called out in ADR-0005: the lib's
# canonical defaults under `lib/slop-env/defaults/` and the template's
# editable starting copy under `templates/claude-code/slop-env/
# claude-config/` are intentionally kept in sync until a deliberate
# divergence is wanted. This check fails CI on accidental drift.
#
# Opt-out: drop a `.diverged` file into the template's claude-config
# directory with a comment explaining the divergence and the check
# skips. This is a deliberate ratchet, not a soft warning — keep it
# load-bearing.

let
  templateConfig = ../templates/claude-code/slop-env/claude-config;
  libDefaults = ../lib/slop-env/defaults;
  divergenceMarker = templateConfig + "/.diverged";
  divergent = builtins.pathExists divergenceMarker;
in
if divergent then
  pkgs.runCommand "template-default-config-matches-lib" { } ''
    echo "template claude-config has opted out via .diverged" > $out
  ''
else
  pkgs.runCommand "template-default-config-matches-lib" { } ''
    # CLAUDE.md and rules/ are the canonical-bundled surface. skills/
    # is template-only (the lib intentionally ships no default skills
    # per ADR-0005 + issue 18 spec) and is excluded from the diff.
    if ! diff -u ${libDefaults}/CLAUDE.md ${templateConfig}/CLAUDE.md; then
      echo "lib/slop-env/defaults/CLAUDE.md drifted from template's claude-config/CLAUDE.md" >&2
      echo "Resync, or drop a .diverged file with a reason." >&2
      exit 1
    fi
    if ! diff -ru ${libDefaults}/rules ${templateConfig}/rules; then
      echo "lib/slop-env/defaults/rules/ drifted from template's claude-config/rules/" >&2
      echo "Resync, or drop a .diverged file with a reason." >&2
      exit 1
    fi
    echo "lib defaults and template claude-config are in sync" > $out
  ''
