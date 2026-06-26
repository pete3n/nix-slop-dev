# Launcher-level functional checks for per-Account credential isolation
# (ADR-0014). These exercise the Account resolution + deny-by-default
# validation that the template/mkShell launcher performs BEFORE it exec's the
# sandboxed jail — the half of the feature that is observable without
# bwrap/namespaces.
#
# Why this shape: the dev-shell `claude` function (and the jail-shell alias)
# in mkBins' shellHook invoke `sandboxed` / `setpriv` / `jailed-claude` by bare
# name (PATH-resolved), and the shellHook is a plain string that references no
# agent package. So we source the real shellHook with those three commands
# stubbed on PATH and drive `claude` directly — testing the actual emitted
# launcher, not a copy. The simultaneous-two-Account filesystem behaviour
# (distinct cred/session dirs, no cross-Account clobber, key in the jailed
# env) needs a real run and lives in the nixosTest functional suite.
{
  self,
  pkgs,
}:
let
  slop = self.lib.slopEnv pkgs;

  # An accounts-enabled Slop Env with a concrete projectName (the
  # template / mkShell path Accounts are scoped to).
  accountShellHook =
    (slop.mkBins {
      projectName = "acct-test";
      agentMdFile = ../templates/claude-code/slop-env/claude-config/CLAUDE.md;
      rulesDir = ../templates/claude-code/slop-env/claude-config/rules;
      skillsDir = ../templates/claude-code/slop-env/claude-config/skills;
      accounts = {
        acme = {
          type = "oauth";
        };
        globex = {
          type = "oauth";
        };
      };
      defaultAccount = "acme";
    }).shellHook;
in
pkgs.runCommand "account-launcher-fail-closed"
  {
    shellHook = accountShellHook;
    passAsFile = [ "shellHook" ];
  }
  ''
    set -u
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"

    # Stub the bare-name commands the launcher exec's, so reaching the jail is
    # observable (and harmless) instead of requiring bwrap.
    mkdir -p "$TMPDIR/stub-bin"
    for cmd in sandboxed setpriv jailed-claude jailed-shell; do
      printf '#!/bin/sh\necho "REACHED_EXEC:$0"\n' > "$TMPDIR/stub-bin/$cmd"
      chmod +x "$TMPDIR/stub-bin/$cmd"
    done
    export PATH="$TMPDIR/stub-bin:$PATH"

    # Source the real shellHook to define the `claude` function exactly as a
    # user gets it after `nix develop`. (The prereq/credential banners it
    # prints are harmless here.)
    . "$shellHookPath" >/dev/null 2>&1 || true

    # Deny-by-default: an override naming an Account absent from the baked
    # registry must refuse to launch, non-zero, BEFORE reaching the jail exec.
    set +e
    stdout_capture="$(NIX_SLOP_DEV_ACCOUNT=nonexistent claude --version 2>err.txt)"
    rc=$?
    set -e

    if [ "$rc" -eq 0 ]; then
      echo "FAIL: unknown Account did not refuse launch (exit 0)" >&2
      echo "--- stdout ---" >&2; echo "$stdout_capture" >&2
      echo "--- stderr ---" >&2; cat err.txt >&2
      exit 1
    fi
    if printf '%s' "$stdout_capture" | grep -q 'REACHED_EXEC'; then
      echo "FAIL: unknown Account reached the jail exec instead of refusing" >&2
      exit 1
    fi
    if ! grep -qi 'account' err.txt; then
      echo "FAIL: refusal did not mention the Account in its error" >&2
      echo "--- stderr ---" >&2; cat err.txt >&2
      exit 1
    fi

    echo "ok: unknown Account refused launch with a clear error, before exec" > $out
  ''
