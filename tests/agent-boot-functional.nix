# Functional test for AGENT BOOT under the real Sandbox+Jail — ADR-0006.
#
# The sibling sandbox/jail functional tests drive a jailed *bash* + the oracle:
# they prove the network and filesystem BOUNDARIES, but never launch the actual
# agents. That gap is exactly what let the opencode regression ship — opencode
# writes ~/.config/opencode/.gitignore during Config.loadInstanceState at boot,
# the read-only config dir denied it (EPERM), and nothing in CI booted opencode
# to notice. This test closes the bwrap half of that gap (the macOS harness,
# ci/macos-functional.sh, covers the Seatbelt half).
#
# It runs each REAL `.agent` launcher (the same path as `nix run .#<agent>`:
# preamble -> sandboxed -> bwrap jail -> agent) far enough to reach the agent's
# config bootstrap, where it writes into its own config dir. The VM is hermetic
# (no upstream), so each agent boots, fails the eventual model call, and exits —
# we assert only that the JAIL never denied a config-dir write.
#
# NEGATIVE assertion (matches ci/macos-functional.sh boot_check): a FAIL means a
# filesystem write-denial signature appeared; an auth/network error does not
# match and cannot false-FAIL. The residual risk is a false-PASS if a launcher
# aborts BEFORE config bootstrap — the full per-agent log is printed so the
# first CI run reveals where boot actually got to (a model/network error in the
# tail = bootstrap was reached). opencode is the regressed case; claude and pi
# are regression guards (their config dirs are already writable), so they should
# be green today and only flip if a future change makes a config dir read-only.
{
  pkgs,
  self,
  sandboxedModule,
}:
let
  slop = self.lib.slopEnv pkgs;

  # Concrete projectName so the launchers bake their paths (no placeholder/sed),
  # mirroring tests/jail-functional.nix. The config-dir bootstrap this test
  # exercises is identical in zero-touch mode.
  claudeBins = slop.mkBins { projectName = "boottest"; };
  opencodeBins = slop.mkBins {
    projectName = "boottest";
    agent = slop.profiles.opencode;
  };
  piBins = slop.mkBins {
    projectName = "boottest";
    agent = slop.profiles.pi;
  };
in
pkgs.testers.runNixOSTest {
  name = "slop-agent-boot-functional";

  nodes.agent =
    { ... }:
    {
      imports = [ sandboxedModule ];

      security.sandboxed = {
        enable = true;
        users = [ "agent" ];
      };

      users.users.agent = {
        isNormalUser = true;
      };

      # Booting the agents realises their full closures (bun/node runtimes), so
      # the guest needs more headroom than the bash-only jail test.
      virtualisation = {
        memorySize = 4096;
        diskSize = 10240;
      };

      # The three real launchers (bin/{claude,opencode,pi}); `sandboxed` itself
      # is installed by the module.
      environment.systemPackages = [
        claudeBins.agent
        opencodeBins.agent
        piBins.agent
      ];
    };

  testScript = ''
    import re

    agent.wait_for_unit("multi-user.target")
    agent.wait_for_unit("auditd.service")

    # claude's jail HARD-binds the shared credentials file (a non-optional
    # rw-bind source — bwrap fails if it is missing), so create it (empty is
    # fine; we never reach a real login) plus a project cwd for mount-cwd.
    # opencode and pi create their own state dirs in the launcher preamble.
    agent.succeed(
        "su - agent -c 'mkdir -p ~/.local/state/claude/shared ~/project"
        " && touch ~/.local/state/claude/shared/.credentials.json'",
    )

    def boot_check(name, cmd, denial):
        # Run the launcher far enough to reach config bootstrap, capture all
        # output, and FAIL only on a filesystem write-denial. ANTHROPIC_API_KEY
        # is a dummy so the agent doesn't stall on interactive auth; `timeout`
        # bounds a hang; `; true` keeps su's exit clean so we always get the log.
        out = agent.succeed(
            f"su - agent -c 'cd ~/project && ANTHROPIC_API_KEY=slop-vm-dummy "
            f"timeout 120 {cmd} > /tmp/boot-{name}.log 2>&1; true'"
            f" && cat /tmp/boot-{name}.log"
        )
        print(f"---------- boot:{name} ----------\n{out}\n--------------------------------")
        assert not re.search(denial, out), (
            f"{name} boot hit a filesystem write-denial inside the jail:\n{out}"
        )

    # opencode: the regressed case. loadInstanceState/PlatformError in the log
    # would mean the .gitignore write was denied again.
    boot_check(
        "opencode",
        "opencode run 'slop boot probe'",
        r"EPERM|EACCES|PlatformError|loadInstanceState|err_[0-9a-f]+",
    )
    # claude: headless print mode boots config, then fails the model call.
    boot_check(
        "claude",
        "claude -p 'slop boot probe'",
        r"EPERM|EACCES|operation not permitted|permission denied",
    )
    # pi: -p headless mode (validated on the macOS harness). The os-error
    # variants cover a Rust strerror surface alongside the node/bun errno text.
    boot_check(
        "pi",
        "pi -p 'slop boot probe'",
        r"EPERM|EACCES|operation not permitted|permission denied|os error 1[^0-9]|os error 13",
    )
  '';
}
