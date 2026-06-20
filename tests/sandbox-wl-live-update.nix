# Functional test for the Linux `--wl-add` LIVE-UPDATE half — ADR-0006 slice 4.1.
#
# sandbox-functional.nix covers whitelist *persistence* (a `--wl-add`'d host is
# allowed on the NEXT launch). It explicitly defers the other half: that
# `--wl-add` also `systemctl set-property`'s every RUNNING sandbox unit, so a
# host denied when a long-lived unit launched becomes reachable from inside that
# SAME unit with no relaunch (packages/sandboxed/default.nix `_wl_add`, the
# "running sandboxes updated" path). That live cgroup update is pure runtime —
# the eval layer cannot reach it — so it lives here as the follow-on nixosTest.
#
# Shape mirrors sandbox-functional.nix (stub server node + sandboxed agent
# node), with one addition: a long-lived sandboxed session driven by an in-env
# coordinator. The Sandbox confines NETWORK only (systemd-run IPAddressDeny),
# not the filesystem, so the coordinator and the harness rendezvous over plain
# files in a shared dir (`--same-dir` keeps cwd identical inside and out):
#
#   coordinator (inside the running unit):
#     1. net-deny  -> the un-whitelisted stub must fail closed   (phase1.rc)
#     2. touch ready; wait (bounded) for the harness to drop `go`
#     3. net-allow -> the SAME unit must now reach the stub      (phase2.rc)
#
#   harness (outside):
#     wait for `ready` + the running unit -> `sandboxed --wl-add <ip>`
#     -> touch `go` -> assert phase1.rc==0 AND phase2.rc==0.
{
  pkgs,
  sandboxedModule,
}:
let
  # Same bytes as every other harness (ADR-0006 single-oracle rule).
  slop-oracle = pkgs.writeShellScriptBin "slop-oracle" (builtins.readFile ./oracle/slop-oracle.sh);

  # The in-env coordinator. Runs as the single command of the long-lived
  # sandboxed unit; slop-oracle / curl resolve via the forwarded PATH.
  coordinator = pkgs.writeShellScriptBin "slop-wl-coord" ''
    set -u
    share="$1"
    url="$2"

    # Phase 1: the stub is NOT whitelisted at launch -> must fail closed.
    slop-oracle net-deny "$url"; printf '%s' "$?" > "$share/phase1.rc"

    # Tell the harness phase 1 is done; the unit now idles, still RUNNING.
    : > "$share/ready"

    # Wait (bounded, 30s) for the harness to run `--wl-add` then drop `go`.
    attempt=0
    while [ ! -e "$share/go" ] && [ "$attempt" -lt 60 ]; do
      sleep 0.5
      attempt=$((attempt + 1))
    done

    # Phase 2: SAME running unit, no relaunch -> the live set-property must let
    # the previously-denied stub through.
    slop-oracle net-allow "$url"; printf '%s' "$?" > "$share/phase2.rc"
    : > "$share/done"
  '';

  stubToken = "SLOP_OK";
in
pkgs.testers.runNixOSTest {
  name = "slop-sandbox-wl-live-update";

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

      environment.systemPackages = [
        slop-oracle
        coordinator
        pkgs.curl
      ];
    };

  testScript = ''
    start_all()

    server.wait_for_unit("nginx.service")
    agent.wait_for_unit("multi-user.target")
    agent.wait_for_unit("auditd.service")

    # The node's address on the shared test VLAN (eth1), NOT the per-VM QEMU
    # user-mode NAT (eth0 = 10.0.2.15, identical and isolated on every node).
    # The test framework numbers the inter-node net 192.168.<vlan>.<n>, so a
    # bare `head -1` over all global IPs would wrongly pick the NAT address.
    server_ip = server.succeed(
        "ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1"
        " | grep 192.168 | head -1"
    ).strip()
    url = f"http://{server_ip}/"

    # Anchor: the stub is reachable UNCONFINED, so a later deny is the boundary.
    agent.succeed(f"curl --fail --silent --max-time 5 {url} | grep -q ${stubToken}")

    share = "/home/agent/share"
    agent.succeed(f"su - agent -c 'mkdir -p {share}'")

    # Launch a long-lived sandboxed session in the background, with NO -a, so
    # the stub is denied at launch. nohup + redirected stdio so it outlives the
    # `su` session; the coordinator keeps the transient unit RUNNING while it
    # waits for `go`.
    agent.succeed(
        "su - agent -c 'nohup sandboxed -q -- "
        f"slop-wl-coord {share} {url} </dev/null >{share}/run.log 2>&1 & '"
    )

    # Phase 1 done (deny attempted) AND a sandbox unit is actually running.
    agent.wait_until_succeeds(f"test -e {share}/ready", timeout=60)
    agent.wait_until_succeeds(
        "systemctl list-units --type=service --state=running --no-legend"
        " | grep -q sandbox-",
        timeout=30,
    )

    # The un-whitelisted stub failed closed at launch (oracle net-deny -> 0).
    phase1 = agent.succeed(f"cat {share}/phase1.rc").strip()
    assert phase1 == "0", f"phase1 (deny-at-launch) rc={phase1}, expected 0"

    # THE LIVE UPDATE: `--wl-add` from OUTSIDE the running unit. Its stderr must
    # report it updated a running sandbox (not merely "next session").
    wl_out = agent.succeed(f"su - agent -c 'sandboxed --wl-add {server_ip} 2>&1'")
    assert "running sandboxes updated" in wl_out, (
        f"--wl-add did not report a live update: {wl_out!r}"
    )

    # Release the coordinator to re-probe inside the SAME running unit.
    agent.succeed(f"su - agent -c 'touch {share}/go'")

    # Phase 2: the previously-denied stub is now reachable, no relaunch.
    agent.wait_until_succeeds(f"test -e {share}/phase2.rc", timeout=60)
    phase2 = agent.succeed(f"cat {share}/phase2.rc").strip()
    assert phase2 == "0", f"phase2 (reach-after-live-wl-add) rc={phase2}, expected 0"
  '';
}
