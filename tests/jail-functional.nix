# Functional test for the Jail (filesystem) boundary — ADR-0006.
#
# Second member of the functional layer (after sandbox-functional.nix, the
# network boundary). Boots a NixOS guest and exercises the real bubblewrap
# confinement built by the lib's jail combinators — the curated mount view
# that the eval/contract checks cannot reach.
#
# Single node, no network: the Jail is filesystem confinement, so unlike the
# Sandbox test there is no stub server. The same `slop-oracle` script asserts
# the three Jail-boundary invariants:
#   #4 path-hidden        — a host path outside the curated view is invisible
#   #5 project-rw         — the bound project dir (mount-cwd) is read-write
#   #6 host-binary-absent — a host tool not in the pkg set is off the jail PATH
#
# The oracle is placed INSIDE the jail via `projectPkgs = [ slop-oracle ]`
# (add-pkg-deps puts it on the jail PATH), then driven with
# `jailed-shell -c '<probes>'`. This tests the raw jail launcher directly,
# isolated from the Sandbox/sudo machinery the network test already covers.
{
  pkgs,
  self,
}:
let
  slop-oracle = pkgs.writeShellScriptBin "slop-oracle" (builtins.readFile ./oracle/slop-oracle.sh);

  # Concrete projectName so the jail launch script is baked (no placeholder
  # sed step needed) and we can exec jailed-shell directly. The oracle rides
  # in via projectPkgs so it resolves on the curated jail PATH.
  bins = (self.lib.slopEnv pkgs).mkBins {
    projectName = "jailtest";
    projectPkgs = [ slop-oracle ];
  };
in
pkgs.testers.runNixOSTest {
  name = "slop-jail-functional";

  nodes.agent =
    { ... }:
    {
      users.users.agent = {
        isNormalUser = true;
      };

      # Only the raw jail launcher is realised; jailedClaude (which pulls the
      # agent package) is evaluated but never referenced, so its closure is
      # not built.
      environment.systemPackages = [ bins.jailedShell ];
    };

  testScript = ''
    agent.wait_for_unit("multi-user.target")

    # Plant a host secret OUTSIDE the jail's curated view ($HOME/.ssh is never
    # bound). If confinement holds it must be invisible inside the jail.
    agent.succeed(
        "install -d -o agent -g users /home/agent/.ssh",
    )
    agent.succeed(
        "echo TOPSECRET > /home/agent/.ssh/id_secret"
        " && chown agent:users /home/agent/.ssh/id_secret",
    )

    # Bootstrap the host state the jail's combinators require: the shared
    # credentials file (a non-optional rw-bind source) and a writable project
    # dir to serve as the bound cwd (mount-cwd).
    agent.succeed(
        "su - agent -c 'mkdir -p ~/.local/state/claude/shared ~/project"
        " && touch ~/.local/state/claude/shared/.credentials.json'",
    )

    # Run all three Jail-boundary invariants INSIDE the jail. cd into the
    # project dir first so mount-cwd binds it; the checks are chained so any
    # single FAIL exits non-zero and surfaces here. Triple-quoted so the
    # nested su / jailed-shell quoting stays readable.
    agent.succeed(
        '''su - agent -c 'cd ~/project && jailed-shell -c "slop-oracle path-rw /home/agent/project && slop-oracle path-hidden /home/agent/.ssh/id_secret && slop-oracle no-host-bin sudo"' '''
    )

    # Negative control: prove the secret really exists on the host, so the
    # path-hidden PASS above means "confined out", not "never created".
    agent.succeed("grep -q TOPSECRET /home/agent/.ssh/id_secret")
  '';
}
