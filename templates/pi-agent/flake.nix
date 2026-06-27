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

              # Local AI over loopback ollama. `enable = false` keeps this inert
              # (the endpoints below are a ready-to-use example). Flip `enable`
              # to true, with the SSH tunnels up, to add a `pi-local`
              # (PI_OFFLINE) launcher, one ollama-<name> provider per endpoint in
              # models.json, and — because `big` is the coordinator — a
              # coordinator->workers topology (generated worker agent defs + the
              # vendored subagent extension). Endpoints are port-only: the
              # loopback URL http://127.0.0.1:<port>/v1 is derived. See
              # docs/usage.md and ADRs 0011/0012/0013.
              localAi = {
                enable = false;
                settings.endpoints = [
                  {
                    name = "big"; # → provider ollama-big (127.0.0.1:11435/v1)
                    port = 11435;
                    coordinator = true; # launch model; delegates to the workers
                    models = [
                      {
                        id = "qwen3-coder:latest";
                        name = "Qwen3 Coder";
                        reasoning = true;
                      }
                    ];
                  }
                  {
                    name = "fast"; # → provider ollama-fast, a worker subagent
                    port = 11434;
                    role = "Quick edits and small refactors";
                    models = [
                      {
                        id = "qwen3:8b";
                        reasoning = true;
                      }
                    ];
                  }
                ];
              };

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
