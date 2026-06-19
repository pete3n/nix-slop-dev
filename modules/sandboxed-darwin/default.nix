# Thin nix-darwin module for the sandboxed-darwin wrapper (issue 13).
#
# Mirrors the NixOS module's user-facing interface (`enable`, `package`,
# `stateDir`) but stops there. Seatbelt is daemonless and runs without
# root, so the Linux module's sudoers / auditd / cgroup-delegation
# machinery has no counterpart on macOS — it is deliberately absent.
flake:
{ config, lib, pkgs, ... }:
let
  cfg = config.security.sandboxed;
in
{
  options.security.sandboxed = {
    enable = lib.mkEnableOption "sandboxed agent network isolation";

    package = lib.mkOption {
      type = lib.types.package;
      default = flake.packages.${pkgs.stdenv.hostPlatform.system}.sandboxed.override {
        stateDir = cfg.stateDir;
      };
      defaultText = lib.literalExpression "sandboxed built with configured stateDir";
      description = "The sandboxed-darwin package to install.";
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = ".local/state/sandboxed";
      description = ''
        Path relative to $HOME for persistent whitelist state.
        The whitelist file is stored at $HOME/<stateDir>/whitelist.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];
  };
}
