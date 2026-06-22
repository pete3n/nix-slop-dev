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
    # AppArmor profile fixtures match the policy/profiles/ directory shape:
    # one subdirectory per loaded profile, named profile-name plus a .NN
    # generation suffix (e.g. nix-slop-dev-bwrap.193). We need two fixtures:
    # one without and one with the nix-slop-dev-bwrap profile present, to
    # drive both branches of the userns check.
    mkdir apparmor-no-bwrap-profile
    : > apparmor-no-bwrap-profile/unconfined.5
    mkdir apparmor-bwrap-profile-loaded
    : > apparmor-bwrap-profile-loaded/unconfined.5
    : > apparmor-bwrap-profile-loaded/nix-slop-dev-bwrap.193

    # Non-NixOS: guidance points at setup-linux, not the NixOS module.
    nonnixos="$(${prereqGuidance}/bin/slop-prereq-guidance "$PWD/absent-marker" "$PWD/userns-permitted" "$PWD/apparmor-no-bwrap-profile" 2>&1 || true)"
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
    nixos="$(${prereqGuidance}/bin/slop-prereq-guidance "$PWD/nixos-marker" "$PWD/userns-permitted" "$PWD/apparmor-no-bwrap-profile" 2>&1 || true)"
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

    # Non-NixOS + AppArmor userns restriction on + profile NOT loaded: the
    # third prereq fires, naming the user-namespace issue and the docs section
    # that walks through the manual profile install.
    userns_restricted="$(${prereqGuidance}/bin/slop-prereq-guidance "$PWD/absent-marker" "$PWD/userns-restricted" "$PWD/apparmor-no-bwrap-profile" 2>&1 || true)"
    case "$userns_restricted" in
      *"user namespaces"*) ;;
      *) fail "non-NixOS + restricted userns + no profile should mention 'user namespaces'; got:
  $userns_restricted" ;;
    esac
    case "$userns_restricted" in
      *"non-nixos-linux.md"*) ;;
      *) fail "non-NixOS + restricted userns + no profile should reference the manual-steps docs; got:
  $userns_restricted" ;;
    esac

    # Non-NixOS + sysctl still restricted + AppArmor profile loaded: this is the
    # post-apply-mode state. The bwrap profile grants userns to bwrap only, so
    # the check must NOT fire — even with the sysctl still at 1.
    userns_profile_loaded="$(${prereqGuidance}/bin/slop-prereq-guidance "$PWD/absent-marker" "$PWD/userns-restricted" "$PWD/apparmor-bwrap-profile-loaded" 2>&1 || true)"
    case "$userns_profile_loaded" in
      *"user namespaces"*) fail "AppArmor profile loaded should silence userns warning; got:
  $userns_profile_loaded" ;;
      *) ;;
    esac

    # NixOS marker takes precedence — even with a restricted sysctl file
    # present, the NixOS branch never prints the userns warning (the knob
    # isn't a typical NixOS concern).
    userns_on_nixos="$(${prereqGuidance}/bin/slop-prereq-guidance "$PWD/nixos-marker" "$PWD/userns-restricted" "$PWD/apparmor-no-bwrap-profile" 2>&1 || true)"
    case "$userns_on_nixos" in
      *"user namespaces"*) fail "NixOS branch should not surface the userns guidance; got:
  $userns_on_nixos" ;;
      *) ;;
    esac

    # SELinux /nix file-context check (Fedora 44 HITL 2026-06-19). Args 4+5
    # are fact overrides for testing — getenforce output and the SELinux
    # type field for /nix/store/.../bin/nix. The check fires only when both
    # are set the bad way (Enforcing + default_t / empty).
    selinux_bad="$(${prereqGuidance}/bin/slop-prereq-guidance "$PWD/absent-marker" "$PWD/userns-permitted" "$PWD/apparmor-no-bwrap-profile" Enforcing default_t 2>&1 || true)"
    case "$selinux_bad" in
      *SELinux*) ;;
      *) fail "Enforcing + default_t should mention SELinux; got:
  $selinux_bad" ;;
    esac
    case "$selinux_bad" in
      *setup-linux*) ;;
      *) fail "selinux guidance should point at setup-linux; got:
  $selinux_bad" ;;
    esac
    case "$selinux_bad" in
      *"non-nixos-linux.md"*) ;;
      *) fail "selinux guidance should reference §5 docs; got:
  $selinux_bad" ;;
    esac

    # Enforcing + bin_t: the post-apply state. SELinux warning must NOT
    # fire even though SELinux is still enforcing.
    selinux_good="$(${prereqGuidance}/bin/slop-prereq-guidance "$PWD/absent-marker" "$PWD/userns-permitted" "$PWD/apparmor-no-bwrap-profile" Enforcing bin_t 2>&1 || true)"
    case "$selinux_good" in
      *SELinux*) fail "Enforcing + bin_t should silence the SELinux warning; got:
  $selinux_good" ;;
      *) ;;
    esac

    # Permissive + default_t: deny would log but not block. Don't fire the
    # warning (the wrapper works today; user just doesn't have the
    # post-apply state pinned for a future Enforcing toggle).
    selinux_permissive="$(${prereqGuidance}/bin/slop-prereq-guidance "$PWD/absent-marker" "$PWD/userns-permitted" "$PWD/apparmor-no-bwrap-profile" Permissive default_t 2>&1 || true)"
    case "$selinux_permissive" in
      *SELinux*) fail "Permissive should not surface the SELinux warning; got:
  $selinux_permissive" ;;
      *) ;;
    esac

    # SELinux Disabled / absent: warning silent (no enforcement at all).
    selinux_disabled="$(${prereqGuidance}/bin/slop-prereq-guidance "$PWD/absent-marker" "$PWD/userns-permitted" "$PWD/apparmor-no-bwrap-profile" Disabled "" 2>&1 || true)"
    case "$selinux_disabled" in
      *SELinux*) fail "Disabled SELinux should not surface the warning; got:
  $selinux_disabled" ;;
      *) ;;
    esac

    # NixOS marker takes precedence — even with Enforcing + default_t, the
    # NixOS branch skips the SELinux check (NixOS policies handle /nix
    # correctly via its own mechanism).
    selinux_on_nixos="$(${prereqGuidance}/bin/slop-prereq-guidance "$PWD/nixos-marker" "$PWD/userns-permitted" "$PWD/apparmor-no-bwrap-profile" Enforcing default_t 2>&1 || true)"
    case "$selinux_on_nixos" in
      *SELinux*) fail "NixOS branch should not surface the SELinux guidance; got:
  $selinux_on_nixos" ;;
      *) ;;
    esac

    touch "$out"
''
