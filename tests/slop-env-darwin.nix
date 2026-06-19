# Behaviour tests for lib/slop-env/darwin.nix's claude and jail-shell
# launchers (slice-21 follow-up).
#
# In zero-touch apps mode (mkBins {} with the default projectName
# placeholder) the launchers must compute PROJECT_NAME from
# NIX_SLOP_DEV_PROJECT_NAME or basename $PWD, sanitise it with Linux's
# regex, export NIX_SLOP_DEV_PROJECT_NAME so the per-jail wrapper
# (slice 1) sees the same value, and use the resolved name in
# CLAUDE_CONFIG_DIR. The literal __SLOP_ENV_PROJECT_NAME__ string must
# NOT appear anywhere in the rendered launcher in placeholder mode —
# otherwise CLAUDE_CONFIG_DIR (forwarded into the sandbox via -e) would
# point at a path the (correctly substituted) SBPL allow set doesn't
# cover, and claude would fail to access its config.
#
# In concrete mode (template caller with projectName = "<name>") the
# launcher hard-codes the name at Nix-eval time and carries no
# placeholder-mode bash dance.
{ pkgs, lib, self }:
let
  slop = self.lib.slopEnv pkgs;
  placeholderBins = slop.mkBins { };
  concreteBins = slop.mkBins { projectName = "concrete-test"; };
in
pkgs.runCommand "slop-env-darwin-launcher-tests" { } ''
  CLAUDE_PLACEHOLDER=${placeholderBins.claude}/bin/claude
  JAILSHELL_PLACEHOLDER=${placeholderBins.jail-shell}/bin/jail-shell
  CLAUDE_CONCRETE=${concreteBins.claude}/bin/claude

  # --- Placeholder mode ---
  for f in "$CLAUDE_PLACEHOLDER" "$JAILSHELL_PLACEHOLDER"; do
    if ! ${pkgs.gnugrep}/bin/grep -q 'PROJECT_NAME=' "$f"; then
      echo "FAIL: $f has no PROJECT_NAME computation" >&2
      cat "$f" >&2
      exit 1
    fi
    # Sanitiser regex (mirrors Linux's placeholderPreamble) — pin the
    # exact character class so a future sloppy refactor that allows
    # more shell metacharacters trips this test.
    if ! ${pkgs.gnugrep}/bin/grep -qF '[^A-Za-z0-9._-]' "$f"; then
      echo "FAIL: $f has no PROJECT_NAME sanitiser regex" >&2
      cat "$f" >&2
      exit 1
    fi
    # The launcher must forward the resolved name to the wrapper so
    # the wrapper's SBPL/preflight subs (slices 1+2) see the value the
    # launcher's basename computed — basename "$PWD" must NOT be
    # re-evaluated inside the wrapper (would race if the user cd's
    # between launcher and wrapper).
    if ! ${pkgs.gnugrep}/bin/grep -q 'export NIX_SLOP_DEV_PROJECT_NAME' "$f"; then
      echo "FAIL: $f doesn't export NIX_SLOP_DEV_PROJECT_NAME" >&2
      cat "$f" >&2
      exit 1
    fi
    # The literal placeholder must NOT survive into the rendered
    # script in placeholder mode — CLAUDE_CONFIG_DIR etc. should use
    # $PROJECT_NAME (the computed bash var), not the literal token.
    if ${pkgs.gnugrep}/bin/grep -q '__SLOP_ENV_PROJECT_NAME__' "$f"; then
      echo "FAIL: $f leaks literal __SLOP_ENV_PROJECT_NAME__" >&2
      ${pkgs.gnugrep}/bin/grep -n '__SLOP_ENV_PROJECT_NAME__' "$f" >&2
      exit 1
    fi
  done

  # --- Concrete mode (template caller path) ---
  if ! ${pkgs.gnugrep}/bin/grep -q 'projects/concrete-test' "$CLAUDE_CONCRETE"; then
    echo "FAIL: concrete-mode claude doesn't bake the projectName" >&2
    cat "$CLAUDE_CONCRETE" >&2
    exit 1
  fi
  if ${pkgs.gnugrep}/bin/grep -q '__SLOP_ENV_PROJECT_NAME__' "$CLAUDE_CONCRETE"; then
    echo "FAIL: concrete-mode claude leaks the placeholder" >&2
    exit 1
  fi
  # Concrete mode shouldn't carry placeholder-mode bash logic — the
  # name is fixed at Nix-eval, no runtime resolution needed.
  if ${pkgs.gnugrep}/bin/grep -q 'NIX_SLOP_DEV_PROJECT_NAME' "$CLAUDE_CONCRETE"; then
    echo "FAIL: concrete-mode claude carries placeholder-mode env var" >&2
    cat "$CLAUDE_CONCRETE" >&2
    exit 1
  fi

  echo "slop-env-darwin launcher tests passed"
  touch $out
''
