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
{
  pkgs,
  lib,
  self,
}:
let
  slop = self.lib.slopEnv pkgs;
  placeholderBins = slop.mkBins { };
  concreteBins = slop.mkBins { projectName = "concrete-test"; };

  # Materialise the apps-mode jail's SBPL profile so the runCommand
  # can grep its allow rules directly. The wrapper does the same
  # writeText internally at build time; we re-emit it here for
  # standalone inspection.
  placeholderSbpl = pkgs.writeText "darwin-apps-jail-sbpl" placeholderBins.jailedAgent.jailData.sbpl;

  # First per-jail wrapper: sandboxed-jailed-claude. Carries the
  # rendered preflight/cleanup blocks slices 1+2 + 5b touch.
  placeholderWrapper = builtins.head placeholderBins.sandboxedPackages;
in
pkgs.runCommand "slop-env-darwin-launcher-tests" { } ''
  CLAUDE_PLACEHOLDER=${placeholderBins.agent}/bin/claude
  JAILSHELL_PLACEHOLDER=${placeholderBins.jail-shell}/bin/jail-shell
  CLAUDE_CONCRETE=${concreteBins.agent}/bin/claude
  PLACEHOLDER_SBPL=${placeholderSbpl}
  PLACEHOLDER_WRAPPER=${placeholderWrapper}/bin/sandboxed-jailed-claude

  # --- .claude.json bootstrap (HITL 2026-06-19) ---
  # Slice 5c: replace the bare `touch ... .claude.json` (which leaves
  # a zero-byte file that claude reads as "JSON Parse error:
  # Unexpected EOF" on first run) with a conditional `echo '{}' >`
  # init. Applied to both launchers + shellHook + Linux symmetry.
  for f in "$CLAUDE_PLACEHOLDER" "$JAILSHELL_PLACEHOLDER"; do
    if ${pkgs.gnugrep}/bin/grep -qF 'touch "$CLAUDE_SHARED_DIR/.credentials.json" "$CLAUDE_CONFIG_DIR/.claude.json"' "$f"; then
      echo "FAIL: $f still touches .claude.json empty (would EOF-corrupt claude's first read)" >&2
      exit 1
    fi
    if ! ${pkgs.gnugrep}/bin/grep -qF '[ -s "$CLAUDE_CONFIG_DIR/.claude.json" ]' "$f"; then
      echo "FAIL: $f has no conditional init guard for .claude.json" >&2
      cat "$f" >&2
      exit 1
    fi
  done

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

  # --- Keychain access (HITL 2026-06-19) ---
  # Claude (Bun-built) spawns /usr/bin/security to read OAuth
  # credentials from the macOS keychain. Without an explicit
  # process-exec allow the Seatbelt jail denies the spawn and Bun
  # surfaces it as a hard EPERM (no graceful fallback to the
  # plaintext .credentials.json provider). Adding /usr/bin/security
  # to darwinJailExtras via ro-bind grants both file-read* AND
  # process-exec subpath allows — what claude needs to read keychain
  # or store an OAuth token.
  if ! ${pkgs.gnugrep}/bin/grep -q 'process-exec.*"/usr/bin/security"' "$PLACEHOLDER_SBPL"; then
    echo "FAIL: apps-mode jail SBPL doesn't allow process-exec for /usr/bin/security" >&2
    echo "      Claude (Bun) will crash with EPERM trying to read keychain." >&2
    cat "$PLACEHOLDER_SBPL" >&2
    exit 1
  fi
  if ! ${pkgs.gnugrep}/bin/grep -q 'file-read.*"/usr/bin/security"' "$PLACEHOLDER_SBPL"; then
    echo "FAIL: apps-mode jail SBPL doesn't allow file-read* for /usr/bin/security" >&2
    cat "$PLACEHOLDER_SBPL" >&2
    exit 1
  fi

  # --- API endpoints (HITL 2026-06-19) ---
  # claude-code v2.1.178+ connects to platform.claude.com (not just
  # api.anthropic.com). The Darwin proxy does hostname-level matching
  # — no L3 fallback like Linux's `2607:6bc0::/32` v6 CIDR allow —
  # so each Anthropic-side hostname needs explicit `--allow`.
  if ! ${pkgs.gnugrep}/bin/grep -qF -- '--allow platform.claude.com' "$CLAUDE_PLACEHOLDER"; then
    echo "FAIL: claude launcher doesn't allow platform.claude.com" >&2
    cat "$CLAUDE_PLACEHOLDER" >&2
    exit 1
  fi

  # --- cfgDir persistence (HITL 2026-06-19) ---
  # The apps-mode jail must NOT rm-rf its cfgDir on exit. Slice 2's
  # bash-var rewrite made the rm-rf target the resolved cfgDir, which
  # destroys claude's .claude.json, sessions, history etc. between
  # runs — a second `nix run #claude` then hits "JSON Parse error:
  # Unexpected EOF" on the empty file the next launcher's touch
  # creates. Slice 5b replaces the cfgDir tmpfs with `ensure-dir`
  # (no cleanup) so state persists.
  #
  # The line we expect to be GONE is the cfgDir-wide rm-rf. Per-file
  # rm -f lines from write-text cleanups (settings.json, CLAUDE.md)
  # are fine and stay — those wipe symlinks the wrapper itself
  # creates, not host state.
  if ${pkgs.gnugrep}/bin/grep -qF 'rm -rf "$HOME/.local/state/claude/projects/''${_project_name}"' "$PLACEHOLDER_WRAPPER"; then
    echo "FAIL: wrapper still rm-rf's cfgDir on exit — claude state will not persist across runs" >&2
    ${pkgs.gnugrep}/bin/grep -nF 'rm -rf "$HOME/.local/state/claude/projects' "$PLACEHOLDER_WRAPPER" >&2
    exit 1
  fi

  # ensure-dir still creates the cfgDir at preflight; the mkdir must
  # survive (without it the launcher's CLAUDE_CONFIG_DIR points at a
  # non-existent path until the launcher's own mkdir runs — which is
  # fine, but the in-jail SBPL allow still expects the dir to exist).
  if ! ${pkgs.gnugrep}/bin/grep -qF 'mkdir -p "$HOME/.local/state/claude/projects/''${_project_name}"' "$PLACEHOLDER_WRAPPER"; then
    echo "FAIL: wrapper preflight doesn't mkdir cfgDir — ensure-dir's preflight regressed" >&2
    exit 1
  fi

  # --- cwd canonicalisation (HITL 2026-06-19) ---
  # The wrapper substitutes __JAIL_CWD__ in the SBPL with the resolved
  # form of $PWD. macOS /tmp and /var are symlinks (/tmp → /private/tmp,
  # /var → /private/var); sandbox-exec matches SBPL rules against the
  # kernel-canonical (resolved) path. Plain `realpath` follows the
  # symlinks; `realpath -s` strips them and emits the unresolved form,
  # which the kernel then refuses to match — claude-code's bash child
  # hits `shell-init: …getcwd…Operation not permitted` and Bun dies
  # with `An unknown error occurred (Unexpected)`. Reproduced verbatim
  # by `cd /tmp/test && nix run …#claude`. Anti-test pinning the bare
  # `realpath` form.
  if ${pkgs.gnugrep}/bin/grep -qE 'realpath[[:space:]]+-s[[:space:]]+"\$PWD"' "$PLACEHOLDER_WRAPPER"; then
    echo "FAIL: wrapper uses 'realpath -s \"\$PWD\"' — strips symlinks, so /tmp/test won't match the kernel's /private/tmp/test view" >&2
    ${pkgs.gnugrep}/bin/grep -nE 'realpath.*PWD' "$PLACEHOLDER_WRAPPER" >&2
    exit 1
  fi
  if ! ${pkgs.gnugrep}/bin/grep -qE 'realpath[[:space:]]+"\$PWD"' "$PLACEHOLDER_WRAPPER"; then
    echo "FAIL: wrapper has no 'realpath \"\$PWD\"' — _jail_cwd resolution lost" >&2
    ${pkgs.gnugrep}/bin/grep -nE 'realpath' "$PLACEHOLDER_WRAPPER" >&2
    exit 1
  fi

  echo "slop-env-darwin launcher tests passed"
  touch $out
''
