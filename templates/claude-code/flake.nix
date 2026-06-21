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
              # hunk is re-exported by nix-slop-dev (ADR-0007), so this flake
              # needs no hunk input of its own.
              hunk = nix-slop-dev.packages.${system}.hunk;

              # worktrunk (`wt`) is re-exported the same way. Unlike hunk its
              # skills are not in the package output, so they're vendored into
              # claude-config/skills (refreshed by hand) and ride along in the
              # bundle below — no per-package merge step here.
              worktrunk = nix-slop-dev.packages.${system}.worktrunk;

              # Merge the checked-in skills with hunk's packaged review skill
              # into one bundle, then bind that single dir as skillsDir.
              # Binding hunk-review *under* the read-only skills mount at
              # runtime would fail (bwrap can't create a mountpoint inside a
              # read-only bind); merging at build time keeps the skill
              # version-locked to the installed hunk without that nesting.
              skills = pkgs.runCommand "claude-code-skills" { } ''
                mkdir -p "$out"
                cp -r ${./slop-env/claude-config/skills}/. "$out/"
                cp -r ${hunk}/skills/hunk-review "$out/hunk-review"
              '';
            in
            slop.mkShell {
              projectName = "nix-slop-dev"; # Update per-project
              agentMdFile = ./slop-env/claude-config/CLAUDE.md;
              rulesDir = ./slop-env/claude-config/rules;
              skillsDir = skills;

              # hunk in projectPkgs reaches BOTH the jail (so the agent can
              # drive a review with `hunk session …`) and this dev shell (so
              # you can watch the `hunk diff` TUI in another terminal). The
              # two halves rendezvous on the loopback broker. See ADR-0007.
              # worktrunk rides alongside it so `wt` is on both the jail and
              # dev-shell PATH for parallel worktree workflows.
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
