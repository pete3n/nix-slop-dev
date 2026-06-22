{
  description = "Neovim plugin development with jailed Claude Code";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    flake-utils.url = "github:numtide/flake-utils";
    gen-luarc.url = "github:mrcjkb/nix-gen-luarc-json";
    nix-slop-dev.url = "github:pete3n/nix-slop-dev";
  };

  outputs =
    inputs@{
      nixpkgs,
      flake-utils,
      nix-slop-dev,
      ...
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
        "x86_64-darwin"
      ];
      neovim-overlay = import ./slop-env/nix/neovim-overlay.nix { inherit inputs; };
    in
    flake-utils.lib.eachSystem systems (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [
            neovim-overlay
            inputs.gen-luarc.overlays.default
          ];
        };
        slop = nix-slop-dev.lib.slopEnv pkgs;

        hunk = nix-slop-dev.packages.${system}.hunk;
        worktrunk = nix-slop-dev.packages.${system}.worktrunk;

        # Keep hunk template skill in sync with upstream repo.
        skills = pkgs.runCommand "nvim-dev-skills" { } ''
          mkdir -p "$out"
          cp -r ${./slop-env/claude-config/skills}/. "$out/"
          cp -r ${hunk}/skills/hunk-review "$out/hunk-review"
        '';

        nvimDev = pkgs.nvim-dev;
        nvimPackDir = nvimDev.packDir;
      in
      {
        packages = {
          default = nvimDev;
          nvim = pkgs.nvim-pkg;
        };

        devShells.default = slop.mkShell {
          name = "nvim-claude-devShell";
          projectName = "slop-dev-nvim-project"; # Update per-project
          agentMdFile = ./slop-env/claude-config/CLAUDE.md;
          rulesDir = ./slop-env/claude-config/rules;
          skillsDir = skills;

          # hunk in projectPkgs reaches BOTH the jail (agent `hunk session …`)
          # and this dev shell (your `hunk diff` TUI).
          projectPkgs = with pkgs; [
            lua-language-server
            nixd
            stylua
            luajitPackages.luacheck
            luajitPackages.busted
            nvimDev
            hunk
            worktrunk
          ];

          projectEnv = {
            VIMRUNTIME = "${nvimDev}/share/nvim/runtime";
            NVIM_PACKPATH = "${nvimPackDir}";
            NVIM_RTP = "${nvimPackDir}";
          };

          # nvim-dev runtime state + LUA_PATH (PWD-dependent, so jail-side
          # try-fwd-env grabs it at exec time) + nvim-luarc-json read mount.
          extraCombinators = with slop.jail.combinators; [
            (try-readwrite (noescape "~/.local/state/nvim-dev"))
            (try-readwrite (noescape "~/.local/share/nvim-dev"))
            (try-readwrite (noescape "~/.config/nvim-dev"))
            (try-fwd-env "LUA_PATH")
            (ro-bind "${pkgs.nvim-luarc-json}" "${pkgs.nvim-luarc-json}")
          ];

          # LUA_PATH is PWD-dependent so it must travel the sandboxed →
          # jail forwarding chain (sandboxed -e + jail try-fwd-env).
          extraSandboxedEnvForwards = [ "LUA_PATH" ];

          # Host-shell setup: re-export the projectEnv vars (so `nvim`
          # launched outside the jail finds its runtime), set LUA_PATH,
          # symlink the generated luarc.json into the project, ensure the
          # nvim-dev swap dir is fresh, and stitch the project's nvim
          # config into the host's nvim-dev config path.
          extraShellHook = # sh
            ''
              export NVIM_PACKPATH="${nvimPackDir}"
              export NVIM_RTP="${nvimPackDir}"
              export VIMRUNTIME="${nvimDev}/share/nvim/runtime"
              export LUA_PATH="$PWD/lua/?.lua;$PWD/lua/?/init.lua;$PWD/plugin/?.lua;$PWD/plugin/?/init.lua;''${LUA_PATH:-}"

              ln -fs ${pkgs.nvim-luarc-json} .luarc.json
              mkdir -p ~/.config
              rm -rf ~/.local/state/nvim-dev/swap
              mkdir -p ~/.local/state/nvim-dev/swap
              # Point ~/.config/nvim-dev at the project's nvim config. Done as
              # rm + ln -s (not `ln -Tfns`) because -T is GNU-only and the host
              # dev shell on Darwin resolves BSD /usr/bin/ln, which lacks it.
              rm -rf ~/.config/nvim-dev
              ln -s "$PWD/nvim" ~/.config/nvim-dev
              printf 'nvim-dev: %s\n' "$(which nvim-dev)"
            '';
        };
      }
    )
    // {
      overlays.default = neovim-overlay;
    };
}
