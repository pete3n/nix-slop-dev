flake:
{
  config,
  lib,
  pkgs,
  ...
}:
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
      description = "The sandboxed package to install.";
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = ".local/state/sandboxed";
      description = ''
        Path relative to $HOME for persistent whitelist state.
        The whitelist file is stored at $HOME/<stateDir>/whitelist.
      '';
    };

    users = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Users permitted to run sandboxed commands via passwordless sudo.
        Each user gets NOPASSWD access to systemd-run, systemctl,
        auditctl, ausearch, and tail (for real-time violation monitoring).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    security.audit.enable = true;
    security.auditd.enable = true;

    # Install sandboxed system-wide
    environment.systemPackages = [ cfg.package ];

    security.sudo.extraRules = map (user: {
      users = [ user ];
      commands = [
        {
          command = "${pkgs.systemd}/bin/systemd-run";
          options = [ "NOPASSWD" ];
        }
        {
          command = "${pkgs.systemd}/bin/systemctl";
          options = [ "NOPASSWD" ];
        }
        {
          command = "${pkgs.coreutils}/bin/tail";
          options = [ "NOPASSWD" ];
        }
        {
          command = "${pkgs.audit}/bin/auditctl";
          options = [ "NOPASSWD" ];
        }
        {
          command = "${pkgs.audit}/bin/ausearch";
          options = [ "NOPASSWD" ];
        }
      ];
    }) cfg.users;
  };
}
