# Eval-level tests for the sandboxed NixOS module.
#
# Evaluates a NixOS system with the module enabled and asserts on the
# resulting configuration — the module's public interface. Pure eval:
# the check derivation is only reached when every assertion holds, so
# `nix flake check` (and even bare `nix eval` of the check) fails fast
# with the collected failure messages.
{
  nixpkgs,
  pkgs,
  system,
  sandboxedModule,
}:
let
  inherit (nixpkgs) lib;

  evaluatedSystem = lib.nixosSystem {
    inherit system;
    modules = [
      sandboxedModule
      {
        security.sandboxed = {
          enable = true;
          users = [ "agent-user" ];
        };
      }
    ];
  };

  userSessionServiceConfig = evaluatedSystem.config.systemd.services."user@".serviceConfig;

  failures = lib.optional (userSessionServiceConfig ? Delegate) ''
    user@ sessions must not receive cgroup-controller delegation: the
    sandboxed wrapper creates system-level transient units via sudo, so
    user-session delegation is dead config (rootless --user was rejected).
  '';
in
if failures == [ ] then
  pkgs.runCommand "sandboxed-nixos-module-tests" { } "touch $out"
else
  throw (lib.concatStringsSep "\n" failures)
