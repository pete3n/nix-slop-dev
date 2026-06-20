# Functional test for the Sandbox (network) boundary — ADR-0006.
#
# This is the first member of the functional layer. Unlike the eval/contract
# checks, it BOOTS a real NixOS guest under KVM and exercises the actual
# enforcement path: `sudo systemd-run` with `IPAddressDeny=any` + per-host
# `IPAddressAllow`, and auditd recording the denied connect(). It therefore
# runs inside `nix build` and belongs in `checks` on x86_64-linux only
# (functional coverage is x86_64-only per ADR-0006; aarch64 stays eval-level).
#
# Two nodes:
#   server — a stub HTTP endpoint (nginx returning a known token). The single
#            target; whether the agent may reach it is decided per-run by the
#            presence of `-a server-ip`. No real internet is ever touched, so
#            the test is hermetic and cannot flake on network.
#   agent  — the sandboxed NixOS module enabled, the oracle on PATH, and a
#            normal user in `security.sandboxed.users` for the NOPASSWD sudo
#            the wrapper needs.
#
# The oracle (tests/oracle/slop-oracle.sh) encodes the expected outcome, so the
# harness just asserts exit 0. Run ordering is deliberate: net-deny first
# (proves the block), then violation-logged (proves auditd saw it), then
# net-allow (proves the endpoint was alive all along — which retroactively
# attributes net-deny's failure to the boundary, not a dead server).
{
  pkgs,
  sandboxedModule,
}:
let
  # Single source of truth: the same bytes the distro/macOS harnesses run.
  # writeShellScriptBin installs the script verbatim (no shellcheck rewrite);
  # curl is provided via the agent node's systemPackages so it resolves on the
  # confined PATH (which inherits the caller's PATH at invocation).
  slop-oracle = pkgs.writeShellScriptBin "slop-oracle" (builtins.readFile ./oracle/slop-oracle.sh);

  stubToken = "SLOP_OK";
in
pkgs.testers.runNixOSTest {
  name = "slop-sandbox-functional";

  nodes.server =
    { ... }:
    {
      services.nginx = {
        enable = true;
        virtualHosts."stub" = {
          default = true;
          locations."/".return = "200 ${stubToken}";
        };
      };
      networking.firewall.allowedTCPPorts = [ 80 ];
    };

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

      # `sandboxed` itself is installed by the module (cfg.package); curl backs
      # the oracle's HTTP probes both inside and outside the sandbox.
      environment.systemPackages = [
        slop-oracle
        pkgs.curl
      ];
    };

  # `su - agent -c` runs the wrapper as the unprivileged sandbox user with a
  # login session, so `sudo systemd-run --pty` gets a clean session to allocate
  # its pty in. If --pty proves unhappy headless, that is itself a real finding.
  testScript = ''
    start_all()

    server.wait_for_unit("nginx.service")
    agent.wait_for_unit("multi-user.target")
    agent.wait_for_unit("auditd.service")

    # Discover the stub's address on the test VLAN (interface-agnostic:
    # first global-scope IPv4). Used as a raw IP so no DNS is involved —
    # the deny path is exercised purely by the cgroup IP filter.
    server_ip = server.succeed(
        "ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -1"
    ).strip()

    url = f"http://{server_ip}/"

    # Sanity: the stub is reachable from an UNCONFINED context on the agent.
    # This anchors every later assertion — if this fails the test setup is
    # broken, not the boundary.
    agent.succeed(f"curl --fail --silent --max-time 5 {url} | grep -q ${stubToken}")

    # #1 deny-closed: no -a, so IPAddressDeny=any blocks the stub. The oracle
    # returns 0 only if the transfer yields no data (failed closed).
    agent.succeed(
        f"su - agent -c 'sandboxed -q -- slop-oracle net-deny {url}'"
    )

    # #3 violation-recorded: the denied connect must surface via the audit
    # log. Runs UNCONFINED (sandboxed --log = sudo ausearch) as the agent
    # user, with bounded retry inside the oracle for auditd's async flush.
    agent.succeed(
        f"su - agent -c 'SLOP_LOG_CMD=\"sandboxed --log\" slop-oracle violation-logged {server_ip}'"
    )

    # #2 allow-connects: with -a <ip>, the wrapper adds IPAddressAllow for the
    # stub and the transfer must succeed. Passing also proves the stub was live
    # during the deny run above.
    agent.succeed(
        f"su - agent -c 'sandboxed -q -a {server_ip} -- slop-oracle net-allow {url}'"
    )

    # Linux extra (whitelist persistence half): a --wl-add'd host is allowed on
    # a subsequent run with no -a. The live-update-of-a-running-unit half needs
    # a backgrounded long-lived sandbox and is deferred to a follow-on test.
    agent.succeed(f"su - agent -c 'sandboxed --wl-add {server_ip}'")
    agent.succeed(
        f"su - agent -c 'sandboxed -q -- slop-oracle net-allow {url}'"
    )
  '';
}
