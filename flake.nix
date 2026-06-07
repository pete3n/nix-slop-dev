{
  description = "Sandboxed AI agent development environments for NixOS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  };

  outputs =
    { self, nixpkgs, ... }:
    let
      # Darwin isn't currently supported by the sanbox solution
      linuxSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs linuxSystems;
    in
    {
      # callPackage makes the derivation overridable so the NixOS module
      # can pass a custom stateDir: package.override { stateDir = "..."; }
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          sandboxed = pkgs.callPackage ./packages/sandboxed/default.nix { };
          default = self.packages.${system}.sandboxed;
        }
      );

      nixosModules = {
        sandboxed = import ./modules/sandboxed/default.nix self;
        default = self.nixosModules.sandboxed;
      };

      templates = {
        claude-code = {
          path = ./templates/claude-code;
          description = "Jailed Claude Code environment with sandboxed network isolation";
        };

        claude-code-nvim-dev = {
          path = ./templates/claude-code-nvim-dev;
          description = "Jailed Claude Code environment for Neovim plugin development with lua tooling and headless test support";
        };
      };
    };
}
