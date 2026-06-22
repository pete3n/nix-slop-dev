{
  self,
  pkgs,
  jail-nix,
  llm-agents,
  flake-utils,
  gen-luarc,
}:

# Byte-equality regression check for slice 19 (ADR-0005, issue draft 19).
# Pins the templates/claude-code-nvim-dev devShells.x86_64-linux.default
# derivation hash so the lib-extraction refactor of that template doesn't
# accidentally drop a combinator, re-order packages, or perturb the
# shellHook.
#
# Mirrors tests/template-claude-code-drv.nix; the only differences are
# the extra inputs the nvim template takes (flake-utils + gen-luarc) and
# the .expected file it pins.

let
  template = import ../templates/claude-code-nvim-dev/flake.nix;
  outs = template.outputs {
    nixpkgs = self.inputs.nixpkgs;
    nix-slop-dev = self;
    inherit
      jail-nix
      llm-agents
      flake-utils
      gen-luarc
      ;
  };
  actualDrv = baseNameOf outs.devShells.x86_64-linux.default.drvPath;
  expectedDrv = pkgs.lib.fileContents ./template-nvim-dev-drv.expected;
in
if actualDrv == expectedDrv then
  pkgs.runCommand "template-nvim-dev-drv" { } ''
    echo "nvim template byte-equality holds: ${actualDrv}" > $out
  ''
else
  throw ''
    nvim template byte-equality regressed.
      expected: ${expectedDrv}
      actual:   ${actualDrv}
    If the change was intentional, update
    tests/template-nvim-dev-drv.expected with the new hash.
  ''
