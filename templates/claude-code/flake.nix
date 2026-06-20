{
  description = "Project development environment with jailed Claude Code";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nix-slop-dev.url = "github:pete3n/nix-slop-dev";
  };

  outputs =
    { nixpkgs, nix-slop-dev, ... }:
    let
      linuxSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      darwinSystems = [
        "aarch64-darwin"
        "x86_64-darwin"
      ];
      allSystems = linuxSystems ++ darwinSystems;
      forAllSystems = nixpkgs.lib.genAttrs allSystems;

    in
    {

      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          slop = nix-slop-dev.lib.slopEnv pkgs;
        in
        {
          default = slop.mkShell {
            projectName = "nix-slop-dev"; # Update per-project
            claudeMdFile = ./slop-env/claude-config/CLAUDE.md;
            rulesDir = ./slop-env/claude-config/rules;
            skillsDir = ./slop-env/claude-config/skills;

            # Add your project's packages and env here
            # projectPkgs = with pkgs; [ lua-language-server stylua ];
            # projectEnv = { FOO = "bar"; };
          };
        }
      );
    };
}
