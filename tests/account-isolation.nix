# Per-Account session + credential path isolation (ADR-0014), at the launcher
# level. Verifies that when an Account is active the dev-shell `claude` launcher:
#   1. points CLAUDE_CONFIG_DIR at the per Account-and-project session root
#      (~/.local/state/claude/projects/<proj>/<acct>);
#   2. rewrites the jailed launcher's __SLOP_ENV_ACCOUNT__ placeholder to the
#      resolved Account in BOTH the session (/projects/<proj>/<acct>/) and the
#      credential (/accounts/<acct>/) path contexts, via a slash-anchored sed
#      that never touches the dash-form write-text source store names;
#   3. creates the per-Account credential dir on the host so the graft source
#      exists;
#   4. yields DISTINCT paths for two different Accounts (no cross-Account
#      clobber of the same project).
#
# This drives the real shellHook `claude` function with `sandboxed`/`setpriv`
# stubbed and a fake `jailed-claude` carrying placeholder paths, so the actual
# launcher sed + path logic is exercised without bwrap or the agent package.
# Whether bwrap then binds those host paths is the nixosTest's job.
{
  self,
  pkgs,
}:
let
  slop = self.lib.slopEnv pkgs;

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
pkgs.runCommand "account-isolation"
  {
    shellHook = accountShellHook;
    passAsFile = [ "shellHook" ];
  }
  ''
    set -eu
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"

    mkdir -p "$TMPDIR/stub-bin"
    # `sandboxed` stub: reports the forwarded CLAUDE_CONFIG_DIR and dumps any
    # file argument (the rewritten jailed launcher) so we can assert on the
    # substituted paths.
    cat > "$TMPDIR/stub-bin/sandboxed" <<'STUB'
    #!/bin/sh
    echo "CFG=$CLAUDE_CONFIG_DIR"
    for arg in "$@"; do
      if [ -f "$arg" ]; then
        echo "JAILED_BEGIN"
        cat "$arg"
        echo "JAILED_END"
      fi
    done
    STUB
    printf '#!/bin/sh\nexit 0\n' > "$TMPDIR/stub-bin/setpriv"
    # Fake jailed launcher carrying both placeholder contexts the real jail bakes.
    cat > "$TMPDIR/stub-bin/jailed-claude" <<'STUB'
    #!/bin/sh
    # SESSION:/h/.local/state/claude/projects/acct-test/__SLOP_ENV_ACCOUNT__/sessions
    # CRED:/h/.local/state/claude/accounts/__SLOP_ENV_ACCOUNT__/.credentials.json
    echo JAILED_RAN
    STUB
    chmod +x "$TMPDIR/stub-bin/"*
    export PATH="$TMPDIR/stub-bin:$PATH"

    . "$shellHookPath" >/dev/null 2>&1 || true

    run_account() {
      acct="$1"
      NIX_SLOP_DEV_ACCOUNT="$acct" claude 2>/dev/null
    }

    # --- acme ---
    acme_out="$(run_account acme)"
    echo "$acme_out" | grep -q "CFG=$HOME/.local/state/claude/projects/acct-test/acme" || {
      echo "FAIL: acme CLAUDE_CONFIG_DIR not Account-qualified" >&2; echo "$acme_out" >&2; exit 1; }
    echo "$acme_out" | grep -q "/projects/acct-test/acme/sessions" || {
      echo "FAIL: acme session path placeholder not rewritten" >&2; echo "$acme_out" >&2; exit 1; }
    echo "$acme_out" | grep -q "/accounts/acme/.credentials.json" || {
      echo "FAIL: acme credential path placeholder not rewritten" >&2; echo "$acme_out" >&2; exit 1; }
    if echo "$acme_out" | grep -q "__SLOP_ENV_ACCOUNT__"; then
      echo "FAIL: placeholder left unsubstituted in jailed launcher" >&2; echo "$acme_out" >&2; exit 1; fi
    [ -d "$HOME/.local/state/claude/accounts/acme" ] || {
      echo "FAIL: per-Account credential dir accounts/acme not created" >&2; exit 1; }

    # --- globex: must be distinct from acme ---
    globex_out="$(run_account globex)"
    echo "$globex_out" | grep -q "CFG=$HOME/.local/state/claude/projects/acct-test/globex" || {
      echo "FAIL: globex CLAUDE_CONFIG_DIR not Account-qualified" >&2; echo "$globex_out" >&2; exit 1; }
    echo "$globex_out" | grep -q "/accounts/globex/.credentials.json" || {
      echo "FAIL: globex credential path not rewritten" >&2; echo "$globex_out" >&2; exit 1; }
    if echo "$globex_out" | grep -q "/acme/"; then
      echo "FAIL: globex run leaked acme paths (cross-Account clobber)" >&2; echo "$globex_out" >&2; exit 1; fi

    echo "ok: per-Account session + credential paths isolated and rewritten" > $out
  ''
