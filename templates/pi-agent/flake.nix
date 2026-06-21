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
              # hunk and worktrunk are re-exported by nix-slop-dev (ADR-0007 /
              # ADR-0008), so this flake needs no inputs of its own for them.
              hunk = nix-slop-dev.packages.${system}.hunk;
              worktrunk = nix-slop-dev.packages.${system}.worktrunk;

              # Merge the checked-in skills with hunk's packaged review skill
              # into one bundle, then bind that as the Pi skills dir. Binding
              # hunk-review *under* the read-only skills mount at runtime would
              # fail (bwrap can't create a mountpoint inside a read-only bind);
              # merging at build time keeps the skill version-locked to the
              # installed hunk. Pi reads SKILL.md dirs from ~/.pi/agent/skills.
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
              # you can watch the `hunk diff` TUI in another terminal). See
              # ADR-0007. worktrunk rides alongside it so `wt` is on both the
              # jail and dev-shell PATH for parallel worktree workflows.
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
