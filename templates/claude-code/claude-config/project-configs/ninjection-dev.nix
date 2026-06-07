# Project jail for ninjection.nvim — Neovim plugin development
#
# Provides lua tooling for linting, formatting, and headless testing
# with PlenaryBusted via the kickstart-nix test harness.
{
  makeJailedClaude,
  makeJailedShell,
  pkgs,
  inputs,
}:
let
  system = pkgs.stdenv.hostPlatform.system;
  nvimDev = inputs.kickstart-nix.packages.${system}.default;
  nvimPackDir = nvimDev.packDir;

  extraPkgs = with pkgs; [
    lua-language-server
    nixd
    stylua
    luajitPackages.luacheck
    luajitPackages.busted
    nvimDev
  ];

  extraEnv = {
    VIMRUNTIME = "${nvimDev}/share/nvim/runtime";
    NVIM_PACKPATH = "${nvimPackDir}";
    NVIM_RTP = "${nvimPackDir}";
  };

  jailArgs = {
    name = "ninjection";
    inherit extraPkgs extraEnv;
  };
in
{
  packages = [
    (makeJailedClaude jailArgs)
    (makeJailedShell jailArgs)
  ];

  shellAliases = {
    "jail-ninjection-dev-claude" = "sandboxed -q --allow api.anthropic.com --allow 2607:6bc0::/32 setpriv --ambient-caps=-sys_nice -- jailed-claude-ninjection";
    "jail-ninjection-dev-shell" = "setpriv --ambient-caps=-sys_nice -- jailed-shell-ninjection";
  };
}
