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
  # The userns sysctl fixture is the same file format /proc exposes — a single
  # line with "1" (restricted) or "0" (permitted). Build-sandbox /proc paths
  # aren't readable in a deterministic way, so the script's second arg lets
  # the test stand in its own files for both branches.
  printf '1\n' > userns-restricted
  printf '0\n' > userns-permitted

  # Non-NixOS: guidance points at setup-linux, not the NixOS module.
  nonnixos="$(${prereqGuidance}/bin/slop-prereq-guidance "$PWD/absent-marker" "$PWD/userns-permitted" 2>&1 || true)"
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
  nixos="$(${prereqGuidance}/bin/slop-prereq-guidance "$PWD/nixos-marker" "$PWD/userns-permitted" 2>&1 || true)"
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

  # Non-NixOS + AppArmor userns restriction on: the third prereq fires,
  # naming the user-namespace issue and the docs section that walks through
  # the manual profile install. NixOS marker takes precedence — even with a
  # restricted sysctl file present, the NixOS branch never prints the userns
  # warning (the knob isn't a typical NixOS concern).
  userns_restricted="$(${prereqGuidance}/bin/slop-prereq-guidance "$PWD/absent-marker" "$PWD/userns-restricted" 2>&1 || true)"
  case "$userns_restricted" in
    *"user namespaces"*) ;;
    *) fail "non-NixOS + restricted userns should mention 'user namespaces'; got:
$userns_restricted" ;;
  esac
  case "$userns_restricted" in
    *"non-nixos-linux.md"*) ;;
    *) fail "non-NixOS + restricted userns should reference the manual-steps docs; got:
$userns_restricted" ;;
  esac

  userns_on_nixos="$(${prereqGuidance}/bin/slop-prereq-guidance "$PWD/nixos-marker" "$PWD/userns-restricted" 2>&1 || true)"
  case "$userns_on_nixos" in
    *"user namespaces"*) fail "NixOS branch should not surface the userns guidance; got:
$userns_on_nixos" ;;
    *) ;;
  esac

  touch "$out"
''
