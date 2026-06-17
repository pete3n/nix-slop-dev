# Behavior tests for the template prerequisite-guidance script.
#
# slop-prereq-guidance is what the claude-code template shellHooks call to
# report unmet Sandbox prerequisites. Its guidance is distro-aware: on NixOS
# (marker present) it prints the security.sandboxed module advice unchanged; on
# any other distro it points at setup-linux. The marker path is overridable by
# argument so the branch can be exercised without a real NixOS host; the live
# auditd/sudo probes (which fail in the build sandbox, making the guidance
# print) are verified HITL.
{
  pkgs,
  prereqGuidance,
}:
pkgs.runCommand "template-prereq-guidance-tests" { } ''
  set -eu
  fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

  touch nixos-marker

  # Non-NixOS: guidance points at setup-linux, not the NixOS module.
  nonnixos="$(${prereqGuidance}/bin/slop-prereq-guidance "$PWD/absent-marker" 2>&1 || true)"
  case "$nonnixos" in
    *setup-linux*) ;;
    *) fail "non-NixOS guidance should mention setup-linux; got:
$nonnixos" ;;
  esac
  case "$nonnixos" in
    *security.sandboxed*) fail "non-NixOS guidance should not mention the NixOS module; got:
$nonnixos" ;;
    *) ;;
  esac

  # NixOS: guidance is the unchanged module advice, not setup-linux.
  nixos="$(${prereqGuidance}/bin/slop-prereq-guidance "$PWD/nixos-marker" 2>&1 || true)"
  case "$nixos" in
    *security.sandboxed*) ;;
    *) fail "NixOS guidance should mention the security.sandboxed module; got:
$nixos" ;;
  esac
  case "$nixos" in
    *setup-linux*) fail "NixOS guidance should not mention setup-linux; got:
$nixos" ;;
    *) ;;
  esac

  touch "$out"
''
