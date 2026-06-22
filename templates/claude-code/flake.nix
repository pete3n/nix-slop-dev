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
          default =
            let
              hunk = nix-slop-dev.packages.${system}.hunk;
              worktrunk = nix-slop-dev.packages.${system}.worktrunk;

              # Keep hunk-review template skill in sync with upstream repo
              skills = pkgs.runCommand "claude-code-skills" { } ''
                mkdir -p "$out"
                cp -r ${./slop-env/claude-config/skills}/. "$out/"
                cp -r ${hunk}/skills/hunk-review "$out/hunk-review"
              '';
            in
            slop.mkShell {
              projectName = "nix-slop-dev"; # <-- Update for your project name
              agentMdFile = ./slop-env/claude-config/CLAUDE.md;
              rulesDir = ./slop-env/claude-config/rules;
              skillsDir = skills;

              # hunk in projectPkgs reaches BOTH the jail (so the agent can
              # drive a review with `hunk session …`) and this dev shell (so
              # you can watch the `hunk diff` TUI in another terminal).
              projectPkgs = [
                hunk
                worktrunk
              ];

              # Add your project's packages and env here
              # projectPkgs = [ hunk worktrunk pkgs.lua-language-server pkgs.stylua ];
              # projectEnv = { FOO = "bar"; };
            };
        }
      );
    };
}
