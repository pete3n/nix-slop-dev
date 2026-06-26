# API-key Account secret flow (ADR-0014), at the launcher level. Verifies that
# for an `apikey` Account the dev-shell `claude` launcher:
#   1. reads the secret from the Account's `keyFile` at invocation and forwards
#      it to the jailed exec as ANTHROPIC_API_KEY (sandboxed `-e` + the key set
#      in the launch subshell);
#   2. does NOT leak ANTHROPIC_API_KEY into the parent (dev) shell;
#   3. never bakes the secret into the launcher text — only the keyFile PATH is
#      baked, and the key is read at runtime.
#
# The keyFile here is a store fixture purely so the test is hermetic; real
# keyFiles are runtime paths (e.g. /run/agenix/...) outside the store. The
# meaningful no-leak assertion is that the SECRET does not appear in the
# emitted launcher (shellHook), which it must not regardless of keyFile origin.
{
  self,
  pkgs,
}:
let
  slop = self.lib.slopEnv pkgs;
  # A recognisable fake secret + a fixture keyFile holding it.
  secret = "sk-ant-test-SECRET-DO-NOT-LEAK";
  keyFixture = pkgs.writeText "slop-test-apikey" secret;

  accountShellHook =
    (slop.mkBins {
      projectName = "acct-apikey";
      agentMdFile = ../templates/claude-code/slop-env/claude-config/CLAUDE.md;
      rulesDir = ../templates/claude-code/slop-env/claude-config/rules;
      skillsDir = ../templates/claude-code/slop-env/claude-config/skills;
      accounts = {
        globex = {
          type = "apikey";
          keyFile = toString keyFixture;
        };
      };
      defaultAccount = "globex";
    }).shellHook;
in
pkgs.runCommand "account-apikey"
  {
    shellHook = accountShellHook;
    passAsFile = [ "shellHook" ];
  }
  ''
    set -eu
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"

    mkdir -p "$TMPDIR/stub-bin"
    # `sandboxed` stub reports its argv and the ANTHROPIC_API_KEY it was given.
    cat > "$TMPDIR/stub-bin/sandboxed" <<'STUB'
    #!/bin/sh
    echo "ARGS:$*"
    echo "KEY:''${ANTHROPIC_API_KEY:-UNSET}"
    STUB
    printf '#!/bin/sh\nexit 0\n' > "$TMPDIR/stub-bin/setpriv"
    printf '#!/bin/sh\necho JAILED\n' > "$TMPDIR/stub-bin/jailed-claude"
    chmod +x "$TMPDIR/stub-bin/"*
    export PATH="$TMPDIR/stub-bin:$PATH"

    . "$shellHookPath" >/dev/null 2>&1 || true

    claude_out="$(claude 2>/dev/null)"

    # 1. the jailed exec must receive the key read from keyFile, via -e forwarding
    printf '%s\n' "$claude_out" | grep -q "KEY:${secret}" || {
      echo "FAIL: apikey Account did not forward ANTHROPIC_API_KEY from keyFile" >&2
      printf '%s\n' "$claude_out" >&2; exit 1; }
    printf '%s\n' "$claude_out" | grep -q -- "-e ANTHROPIC_API_KEY" || {
      echo "FAIL: sandboxed not told to forward ANTHROPIC_API_KEY (-e missing)" >&2
      printf '%s\n' "$claude_out" >&2; exit 1; }

    # 2. the secret must not leak into the parent (dev) shell env
    if [ -n "''${ANTHROPIC_API_KEY:-}" ]; then
      echo "FAIL: ANTHROPIC_API_KEY leaked into the parent shell env" >&2; exit 1; fi

    # 3. the secret must never be baked into the launcher text (only the path)
    if grep -q "${secret}" "$shellHookPath"; then
      echo "FAIL: secret baked into the launcher derivation" >&2; exit 1; fi

    echo "ok: apikey Account forwards key from keyFile, scoped + unbaked" > $out
  ''
