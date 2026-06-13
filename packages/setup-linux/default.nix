{
  pkgs,
  ...
}:
let
  # The pure check logic, unit-tested in tests/setup-linux-checks.nix. Sourced
  # at runtime by store path so the runnable app and the tests share one copy.
  checkLib = ./check-lib.sh;
in
pkgs.writeShellScriptBin "setup-linux" # bash
  ''
    set -eu

    # Collection layer (impure): probe the live host for each prerequisite
    # fact, then hand the facts to the pure check library. Host services are
    # queried via bare tool names (host systemctl/proc), since this app targets
    # non-NixOS systemd distros; text parsing uses store-pinned helpers.
    source ${checkLib}

    # systemd version integer, e.g. "systemd 257 (257.5)" -> 257.
    systemd_version="$(systemctl --version 2>/dev/null \
        | ${pkgs.gawk}/bin/awk 'NR==1 {print $2}' || true)"

    # `systemctl is-active` prints the state and exits nonzero when not active;
    # keep the string, drop the exit status.
    auditd_state="$(systemctl is-active auditd 2>/dev/null || true)"

    # AppArmor unprivileged-userns sysctl value, or "" when the knob is absent.
    userns_sysctl="$(${pkgs.coreutils}/bin/cat \
        /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null || true)"

    printf 'setup-linux: Sandbox/Jail prerequisites\n\n'

    if run_checks \
        "$systemd_version" \
        /sys/fs/cgroup/cgroup.controllers \
        "$auditd_state" \
        /etc/sudoers.d/sandboxed \
        "$userns_sysctl"; then
        printf '\nAll prerequisites met.\n'
        exit 0
    else
        printf '\nSome prerequisites are not met (see ✗ above).\n' >&2
        exit 1
    fi
  ''
