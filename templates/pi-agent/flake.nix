{
  description = "Project development environment with jailed Pi";

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

              # Merge the checked-in skills with hunk's packaged review skill
              # into one bundle, then bind that as the Pi skills dir.
              skills = pkgs.runCommand "pi-agent-skills" { } ''
                mkdir -p "$out"
                cp -r ${./slop-env/pi-config/skills}/. "$out/"
                cp -r ${hunk}/skills/hunk-review "$out/hunk-review"
              '';
            in
            slop.mkShell {
              projectName = "pi-project"; # Update per-project
              agent = slop.profiles.pi;
              agentMdFile = ./slop-env/pi-config/AGENTS.md;
              rulesDir = ./slop-env/pi-config/rules;
              skillsDir = skills;

              # Flip to true to add a `pi-local` (PI_OFFLINE) launcher and an
              # ollama provider (models.json) alongside the anthropic `pi`.
              # Requires a local ollama on http://localhost:11434.
              enableLocalAi = false;

              # hunk in projectPkgs reaches BOTH the jail (so the agent can
              # drive a review with `hunk session …`) and this dev shell (so
              # you can watch the `hunk diff` TUI in another terminal).
              projectPkgs = [
                hunk
                worktrunk
              ];

              # Add your project's packages and env here
              # projectPkgs = [ hunk worktrunk pkgs.nodejs ];
              # projectEnv = { FOO = "bar"; };
            };
        }
      );
    };
}
