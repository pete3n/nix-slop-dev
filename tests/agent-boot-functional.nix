# Functional test for AGENT BOOT under the real bwrap Jail — ADR-0006.
#
# The sibling sandbox/jail functional tests drive a jailed *bash* + the oracle:
# they prove the network and filesystem BOUNDARIES, but never launch the actual
# agent. That gap is what let the opencode regression ship — opencode writes
# ~/.config/opencode/.gitignore during Config.loadInstanceState at boot, the
# read-only config dir denied it (EPERM), and nothing in CI booted opencode to
# notice. This closes the bwrap half of that gap (ci/macos-functional.sh's
# boot_check covers the Seatbelt half, for all three agents).
#
# Scope = opencode only, and the JAILED binary directly (not the `.agent`
# launcher):
#   - The bug is opencode's; it lives in the bwrap mount view, NOT the network
#     Sandbox. Driving `jailed-opencode` isolates exactly that layer, mirroring
#     tests/jail-functional.nix ("the raw jail launcher directly, isolated from
#     the Sandbox/sudo machinery").
#   - The full `.agent` launcher wraps `sandboxed`, which DNS-resolves its
#     --allow hosts at launch. A nixosTest is hermetic (no upstream), so that
#     resolution fails before the agent ever boots — the launcher can't run
#     here at all.
#   - claude/pi boot-coverage stays in the macOS harness: replicating their
#     launcher preambles (claude's .claude.json/.credentials bootstrap, pi's
#     session-dir env) host-side here is fragile and would risk non-bug
#     failures. Their config dirs are already writable, so opencode is the
#     case that actually exercises this regression on bwrap.
#
# The VM is hermetic, so opencode boots, writes its config-dir .gitignore, then
# fails the eventual model call and exits. NEGATIVE assertion (matches the macOS
# boot_check): a FAIL means a write-denial signature appeared; the model/network
# error does not match and cannot false-FAIL. Residual risk is a false-PASS if
# opencode aborts BEFORE Config.loadInstanceState — the full boot log is printed
# so the first CI run reveals where boot actually got to.
{
  pkgs,
  self,
}:
let
  slop = self.lib.slopEnv pkgs;

  # Concrete projectName so the jail bakes its paths (no placeholder/sed),
  # mirroring tests/jail-functional.nix. The config-dir bootstrap this test
  # exercises is identical in zero-touch mode.
  opencodeBins = slop.mkBins {
    projectName = "boottest";
    agent = slop.profiles.opencode;
  };

  # Replicates the minimal slice of the opencode launcher preamble that the jail
  # forwards (TMPDIR/OPENCODE_EXCHANGE_DIR via try-fwd-env) and binds rw (the
  # share/state/cache dirs via try-readwrite, which no-op if their host source is
  # absent — so they must exist). OPENCODE_DISABLE_MODELS_FETCH keeps boot off
  # the (unreachable) models.dev catalog. Then execs the jailed binary directly.
  # Baked into a script so the testScript carries no nested quoting.
  opencodeBoot = pkgs.writeShellScript "boot-opencode" ''
    export OPENCODE_DISABLE_MODELS_FETCH=1
    export ANTHROPIC_API_KEY=slop-vm-dummy
    export TMPDIR="$HOME/.local/state/opencode/projects/boottest/tmp"
    export OPENCODE_EXCHANGE_DIR="$HOME/.local/state/opencode/projects/boottest/exchange"
    mkdir -p "$HOME/.local/share/opencode" "$HOME/.local/state/opencode" "$HOME/.cache" \
      "$TMPDIR" "$OPENCODE_EXCHANGE_DIR"
    exec ${opencodeBins.jailedAgent}/bin/jailed-opencode run probe
  '';
in
pkgs.testers.runNixOSTest {
  name = "slop-agent-boot-functional";

  nodes.agent =
    { ... }:
    {
      users.users.agent = {
        isNormalUser = true;
      };

      # Booting opencode realises its full closure (the bun runtime), so the
      # guest needs more headroom than the bash-only jail test.
      virtualisation = {
        memorySize = 4096;
        diskSize = 8192;
      };

      # The boot script pulls jailed-opencode into the closure; install it so
      # the derivation is realised in the guest.
      environment.systemPackages = [ opencodeBins.jailedAgent ];
    };

  testScript = ''
    agent.wait_for_unit("multi-user.target")

    # Run the jailed agent far enough to reach Config bootstrap, where it writes
    # ~/.config/opencode/.gitignore. `execute` (not succeed) ignores the exit
    # code — boot is EXPECTED to fail at the model call in the hermetic VM; we
    # only care that the jail never denied the config-dir write. `timeout`
    # bounds a hang. The boot logic is baked into ${opencodeBoot}, so this
    # su -c carries no nested quotes.
    agent.execute(
        "su - agent -c 'timeout 120 ${opencodeBoot} > /tmp/boot-opencode.log 2>&1'"
    )
    # NB: `log` is a reserved driver global (the AbstractLogger) — shadowing it
    # makes the type checker treat this str as AbstractLogger, so use boot_log.
    boot_log = agent.succeed("cat /tmp/boot-opencode.log || true")
    print("---------- opencode boot log ----------\n" + boot_log + "\n---------------------------------------")

    # Substring match (not re) over the denial markers. "err_" stands in for
    # opencode's err_<hex> ref; "loadInstanceState" only appears in its boot
    # error stack.
    denials = ["EPERM", "EACCES", "PlatformError", "loadInstanceState", "err_"]
    hit = [marker for marker in denials if marker in boot_log]
    assert not hit, f"opencode boot hit a config-dir write-denial inside the jail {hit}:\n{boot_log}"
  '';
}
