# Behavior test for ADR-0002 runtime host-tool detection.
#
# The sandboxed wrapper resolves its five privileged tools (systemd-run,
# systemctl, auditctl, ausearch, tail) differently depending on whether it
# runs on NixOS. We observe this through the `--print-tools [marker]`
# diagnostic, which reports the resolved invocation for each privileged
# tool. The optional marker path lets the test select either branch without
# a real NixOS host: a present marker is the NixOS case, an absent one is
# the non-NixOS case.
{
  pkgs,
  sandboxed,
}:
let
  privilegedTools = [
    "systemd-run"
    "systemctl"
    "tail"
    "auditctl"
    "ausearch"
  ];

  # On non-NixOS, every privileged tool is invoked by bare name so sudo's
  # secure_path resolves the host binary (ADR-0002).
  bareNameAssertions = pkgs.lib.concatMapStringsSep "\n" (tool: ''
    grep -qxF '${tool}=${tool}' "$nonNixosOut" \
      || fail "non-NixOS: expected '${tool}=${tool}', got: $(grep '^${tool}=' "$nonNixosOut")"
  '') privilegedTools;

  # On NixOS, every privileged tool is invoked by absolute Nix store path.
  storePathAssertions = pkgs.lib.concatMapStringsSep "\n" (tool: ''
    grep -qE '^${tool}=/nix/store/.*/bin/${tool}$' "$nixosOut" \
      || fail "NixOS: expected '${tool}=/nix/store/.../bin/${tool}', got: $(grep '^${tool}=' "$nixosOut")"
  '') privilegedTools;
in
pkgs.runCommand "sandboxed-wrapper-tool-resolution-tests" { } ''
  set -eu
  fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

  # NixOS branch: marker file present.
  touch nixos-marker
  ${sandboxed}/bin/sandboxed --print-tools "$PWD/nixos-marker" > nixosOut.txt \
    || fail "--print-tools exited non-zero on present marker"
  nixosOut="$PWD/nixosOut.txt"

  # Non-NixOS branch: marker path absent.
  ${sandboxed}/bin/sandboxed --print-tools "$PWD/absent-marker" > nonNixosOut.txt \
    || fail "--print-tools exited non-zero on absent marker"
  nonNixosOut="$PWD/nonNixosOut.txt"

  ${storePathAssertions}
  ${bareNameAssertions}

  touch $out
''
