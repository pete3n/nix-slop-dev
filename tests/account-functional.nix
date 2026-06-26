# Functional test for per-Account credential isolation at the JAIL boundary
# (ADR-0014). Companion to the launcher-level checks (account-launcher.nix /
# account-isolation.nix / account-apikey.nix): those pin how the wrapper
# resolves the Account and rewrites the jailed launcher; this boots a NixOS
# guest and proves the real bubblewrap mounts that result are per-Account
# isolated.
#
# Like jail-functional.nix this exercises the raw `jailed-shell` launcher
# directly (bashInteractive — no agent package, no sandboxed/sudo machinery).
# The Account is selected the way the launcher does it: by sed-substituting the
# baked __SLOP_ENV_ACCOUNT__ placeholder to the resolved Account before exec
# (the exact transform account-isolation.nix locks at the launcher level), then
# running the resulting per-Account jailed-shell. We assert:
#   1. credential isolation — a write to .credentials.json inside Account A's
#      jail lands in accounts/A/ on the host and NOT in accounts/B/;
#   2. session isolation     — a write under the session root inside A's jail
#      lands in projects/<proj>/A/ and NOT in projects/<proj>/B/;
#   3. api-key forwarding     — ANTHROPIC_API_KEY set at launch reaches the
#      jailed process (the jail's env -i otherwise drops it).
{
  pkgs,
  self,
}:
let
  bins = (self.lib.slopEnv pkgs).mkBins {
    projectName = "accttest";
    accounts = {
      acme = {
        type = "oauth";
      };
      globex = {
        type = "oauth";
      };
    };
    defaultAccount = "acme";
  };
in
pkgs.testers.runNixOSTest {
  name = "slop-account-functional";

  nodes.agent =
    { ... }:
    {
      users.users.agent = {
        isNormalUser = true;
      };
      # Only the raw account-enabled jail launcher is realised; jailedClaude
      # (which pulls the agent package) is evaluated but never referenced.
      environment.systemPackages = [
        bins.jailedShell
        pkgs.gnused
      ];
    };

  testScript = ''
    agent.wait_for_unit("multi-user.target")

    state = "/home/agent/.local/state/claude"

    # Bootstrap the host state the per-Account binds require: a per-Account
    # credential dir + file (the rw-bind graft source, non-optional) and a
    # per Account-and-project session dir (the try-readwrite session bind), for
    # both Accounts, plus a writable project dir for mount-cwd.
    for acct in ["acme", "globex"]:
        agent.succeed(
            f"su - agent -c 'mkdir -p {state}/accounts/{acct} {state}/projects/accttest/{acct}/sessions"
            f" && touch {state}/accounts/{acct}/.credentials.json'"
        )
    agent.succeed("su - agent -c 'mkdir -p /home/agent/project'")

    # Materialise the per-Account jailed launchers exactly as the wrapper does:
    # slash-anchored substitution of the baked placeholder (correctness of this
    # transform is pinned by tests/account-isolation.nix).
    for acct in ["acme", "globex"]:
        agent.succeed(
            f"su - agent -c 'sed \"s|/__SLOP_ENV_ACCOUNT__|/{acct}|g\""
            f" ${bins.jailedShell}/bin/jailed-shell > /home/agent/j-{acct}"
            f" && chmod +x /home/agent/j-{acct}'"
        )

    def run_in(acct, script):
        cfg = f"{state}/projects/accttest/{acct}"
        return (
            f"su - agent -c 'cd /home/agent/project && CLAUDE_CONFIG_DIR={cfg}"
            f" /home/agent/j-{acct} -c \"{script}\"'"
        )

    # 1 + 2. Write the Account's token + a session marker from INSIDE acme's jail.
    # $CLAUDE_CONFIG_DIR is escaped (\$) so it survives the agent login shell and
    # is expanded by the JAILED bash, which gets the value via try-fwd-env. An
    # unescaped $ would expand in the agent shell instead, and because it shares
    # the simple command with the CLAUDE_CONFIG_DIR= prefix assignment, bash
    # expands the word using the value from BEFORE the assignment (empty) — the
    # write then lands at /sessions/marker, which doesn't exist.
    agent.succeed(run_in("acme", "echo ACME_TOKEN > \\\"\\$CLAUDE_CONFIG_DIR/.credentials.json\\\" && echo HI > \\\"\\$CLAUDE_CONFIG_DIR/sessions/marker\\\""))

    # Credential isolation: the token landed in accounts/acme on the host and is
    # absent from accounts/globex (distinct cross-project credential stores).
    agent.succeed(f"grep -q ACME_TOKEN {state}/accounts/acme/.credentials.json")
    agent.fail(f"grep -q ACME_TOKEN {state}/accounts/globex/.credentials.json")

    # Session isolation: the marker landed in projects/accttest/acme and is
    # absent from projects/accttest/globex (distinct per Account-and-project).
    agent.succeed(f"test -f {state}/projects/accttest/acme/sessions/marker")
    agent.fail(f"test -f {state}/projects/accttest/globex/sessions/marker")

    # 3. api-key forwarding: ANTHROPIC_API_KEY set at launch must survive the
    # jail's env -i and reach the jailed process (try-fwd-env, added for the
    # per-Account regime). Print it from inside the jail and confirm the value.
    # $ANTHROPIC_API_KEY is escaped (\$) for the same reason as above: let the
    # jailed bash expand the try-fwd-env'd value, not the agent shell (where the
    # prefix-assignment timing would expand it to empty before the var is set).
    out = agent.succeed(
        "su - agent -c 'cd /home/agent/project && CLAUDE_CONFIG_DIR=" + state + "/projects/accttest/acme"
        " ANTHROPIC_API_KEY=SEKRIT-XYZ /home/agent/j-acme -c \"printf GOTKEY=%s \\$ANTHROPIC_API_KEY\"'"
    )
    assert "GOTKEY=SEKRIT-XYZ" in out, f"ANTHROPIC_API_KEY not forwarded into jail: {out!r}"
  '';
}
