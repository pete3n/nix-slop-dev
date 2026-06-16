{
  description = "Project development environment with jailed Claude Code";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nix-slop-dev.url = "github:pete3n/nix-slop-dev";
  };

  outputs =
    { nixpkgs, nix-slop-dev, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      slop = nix-slop-dev.lib.slopEnv pkgs;
    in
    {
      devShells.${system}.default = slop.mkShell {
        projectName = "slop-dev-project"; # Update per-project
        claudeMdFile = ./slop-env/claude-config/CLAUDE.md;
        rulesDir = ./slop-env/claude-config/rules;
        skillsDir = ./slop-env/claude-config/skills;

        # Add your project's packages and env here
        # projectPkgs = with pkgs; [ lua-language-server stylua ];
        # projectEnv = { FOO = "bar"; };
      };
    };
}
