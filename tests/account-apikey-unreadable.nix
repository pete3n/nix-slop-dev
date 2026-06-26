# An apikey Account whose keyFile is unreadable must fail-closed at launch
# (ADR-0014): no silent launch with a missing/empty key. The launcher reads the
# keyFile at invocation and refuses (non-zero, clear error) before exec.
#
# Same shellHook-sourcing harness as account-apikey.nix; here the baked keyFile
# path points at a file that does not exist, so the apikey case arm takes its
# error branch.
{
  self,
  pkgs,
}:
let
  slop = self.lib.slopEnv pkgs;
  accountShellHook =
    (slop.mkBins {
      projectName = "acct-apikey-bad";
      agentMdFile = ../templates/claude-code/slop-env/claude-config/CLAUDE.md;
      rulesDir = ../templates/claude-code/slop-env/claude-config/rules;
      skillsDir = ../templates/claude-code/slop-env/claude-config/skills;
      accounts = {
        globex = {
          type = "apikey";
          keyFile = "/nonexistent/slop-keyfile-does-not-exist";
        };
      };
      defaultAccount = "globex";
    }).shellHook;
in
pkgs.runCommand "account-apikey-unreadable"
  {
    shellHook = accountShellHook;
    passAsFile = [ "shellHook" ];
  }
  ''
    set -u
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"

    mkdir -p "$TMPDIR/stub-bin"
    printf '#!/bin/sh\necho REACHED_EXEC\n' > "$TMPDIR/stub-bin/sandboxed"
    printf '#!/bin/sh\nexit 0\n' > "$TMPDIR/stub-bin/setpriv"
    printf '#!/bin/sh\nexit 0\n' > "$TMPDIR/stub-bin/jailed-claude"
    chmod +x "$TMPDIR/stub-bin/"*
    export PATH="$TMPDIR/stub-bin:$PATH"

    . "$shellHookPath" >/dev/null 2>&1 || true

    set +e
    claude_out="$(claude 2>err.txt)"
    rc=$?
    set -e

    if [ "$rc" -eq 0 ]; then
      echo "FAIL: apikey Account with unreadable keyFile did not refuse launch" >&2
      cat err.txt >&2; exit 1
    fi
    if printf '%s' "$claude_out" | grep -q 'REACHED_EXEC'; then
      echo "FAIL: reached the jail exec despite an unreadable keyFile" >&2; exit 1
    fi
    if ! grep -qi 'keyfile' err.txt; then
      echo "FAIL: error did not mention the keyFile" >&2; cat err.txt >&2; exit 1
    fi

    echo "ok: apikey Account with unreadable keyFile fails closed before exec" > $out
  ''
