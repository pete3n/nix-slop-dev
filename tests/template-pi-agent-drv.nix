{ self
, pkgs
}:

# Byte-equality regression check for the pi-agent template (ADR-0009). Pins the
# templates/pi-agent devShells.x86_64-linux.default derivation hash so any
# change to the template's eval that ALTERS the resulting derivation (a dropped
# combinator, re-ordered packages, perturbed shellHook) flips this check red.
#
# The template's own `nix-slop-dev` input points at the published flake, so
# inject `self` (this repo) to test the template against local lib changes —
# the same pattern as tests/template-claude-code-drv.nix.
#
# Update the .expected file deliberately when bumping nixpkgs / llm-agents /
# the template's intentional surface.

let
  template = import ../templates/pi-agent/flake.nix;
  outs = template.outputs {
    nixpkgs = self.inputs.nixpkgs;
    nix-slop-dev = self;
  };
  actualDrv = baseNameOf outs.devShells.x86_64-linux.default.drvPath;
  expectedDrv = pkgs.lib.fileContents ./template-pi-agent-drv.expected;
in
if actualDrv == expectedDrv then
  pkgs.runCommand "template-pi-agent-drv" { } ''
    echo "template byte-equality holds: ${actualDrv}" > $out
  ''
else
  throw ''
    pi-agent template byte-equality regressed.
      expected: ${expectedDrv}
      actual:   ${actualDrv}
    If the change to the template was intentional, update
    tests/template-pi-agent-drv.expected with the new hash.
  ''
