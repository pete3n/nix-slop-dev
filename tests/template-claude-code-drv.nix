{
  self,
  pkgs,
  jail-nix,
  llm-agents,
}:

# Byte-equality regression check for slice 17 (ADR-0005). Pins the
# templates/claude-code devShells.x86_64-linux.default derivation hash so
# any change to the template's eval that ALTERS the resulting derivation
# (e.g. a refactor accidentally drops a combinator, re-orders packages,
# or perturbs the shellHook) flips this check red.
#
# Update the .expected file deliberately when bumping nixpkgs / jail-nix /
# llm-agents / the template's intentional surface.

let
  template = import ../templates/claude-code/flake.nix;
  outs = template.outputs {
    nixpkgs = self.inputs.nixpkgs;
    nix-slop-dev = self;
    inherit jail-nix llm-agents;
  };
  actualDrv = baseNameOf outs.devShells.x86_64-linux.default.drvPath;
  expectedDrv = pkgs.lib.fileContents ./template-claude-code-drv.expected;
in
if actualDrv == expectedDrv then
  pkgs.runCommand "template-claude-code-drv" { } ''
    echo "template byte-equality holds: ${actualDrv}" > $out
  ''
else
  throw ''
    template byte-equality regressed.
      expected: ${expectedDrv}
      actual:   ${actualDrv}
    If the change to the template was intentional, update
    tests/template-claude-code-drv.expected with the new hash.
  ''
