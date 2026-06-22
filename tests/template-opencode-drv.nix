{
  self,
  pkgs,
}:

# Byte-equality regression check for the opencode template (ADR-0010). Pins the
# templates/opencode devShells.x86_64-linux.default derivation hash so any
# change to the template's eval that ALTERS the resulting derivation (a dropped
# combinator, re-ordered packages, perturbed shellHook) flips this check red.
#
# The template's own `nix-slop-dev` input points at the published flake, so
# inject `self` (this repo) to test the template against local lib changes —
# the same pattern as tests/template-pi-agent-drv.nix.
#
# Update the .expected file deliberately when bumping nixpkgs / llm-agents /
# the template's intentional surface:
#   nix eval --raw .#checks.x86_64-linux.template-opencode-drv 2>&1   # shows actual
# or read the drvPath basename directly and write it into the .expected file.

let
  template = import ../templates/opencode/flake.nix;
  outs = template.outputs {
    nixpkgs = self.inputs.nixpkgs;
    nix-slop-dev = self;
  };
  actualDrv = baseNameOf outs.devShells.x86_64-linux.default.drvPath;
  expectedDrv = pkgs.lib.fileContents ./template-opencode-drv.expected;
in
if actualDrv == expectedDrv then
  pkgs.runCommand "template-opencode-drv" { } ''
    echo "template byte-equality holds: ${actualDrv}" > $out
  ''
else
  throw ''
    opencode template byte-equality regressed.
      expected: ${expectedDrv}
      actual:   ${actualDrv}
    If the change to the template was intentional, update
    tests/template-opencode-drv.expected with the new hash.
  ''
