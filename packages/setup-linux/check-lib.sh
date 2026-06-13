# Pure prerequisite checks for setup-linux.
#
# Each check_* takes its already-collected host fact as an argument, prints
# exactly one report line (✓ on pass, ✗ plus a remediation hint on fail),
# and returns 0 (pass) or 1 (fail). There is no host I/O in this file:
# collection lives in the setup-linux main, keeping this logic deterministic
# and unit-testable with fixtures.

# systemd >= 235 first shipped IPAddressDeny/IPAddressAllow, on which the
# Sandbox network filtering depends.
check_systemd_version() {
	systemd_version="$1"
	if [ "$systemd_version" -ge 235 ] 2>/dev/null; then
		printf '✓ systemd %s (>= 235, IPAddressDeny supported)\n' "$systemd_version"
		return 0
	fi
	printf '✗ systemd %s too old — need >= 235 for IPAddressDeny network filtering; upgrade systemd\n' "$systemd_version"
	return 1
}

# The unified cgroup v2 hierarchy (required for per-unit IP address filtering)
# exposes cgroup.controllers at the cgroup mount root; a legacy/hybrid v1
# hierarchy does not.
check_cgroup_v2() {
	controllers_file="$1"
	if [ -f "$controllers_file" ]; then
		printf '✓ cgroup v2 unified hierarchy active\n'
		return 0
	fi
	printf '✗ cgroup v2 unified hierarchy not active — boot with systemd.unified_cgroup_hierarchy=1\n'
	return 1
}

# auditd records the connect() syscall violations the Sandbox alerts on. The
# fact is `systemctl is-active auditd`; only "active" means installed and
# running.
check_auditd() {
	auditd_state="$1"
	if [ "$auditd_state" = "active" ]; then
		printf '✓ auditd installed and active\n'
		return 0
	fi
	printf '✗ auditd not active (%s) — install and enable it: apt/dnf install auditd && systemctl enable --now auditd\n' "$auditd_state"
	return 1
}

# The sudoers drop-in grants the invoking users passwordless access to the
# host's five privileged tools by absolute path (ADR-0002). Apply mode writes
# it; check mode only reports presence.
check_sudoers() {
	sudoers_file="$1"
	if [ -f "$sudoers_file" ]; then
		printf '✓ sudoers drop-in present (%s)\n' "$sudoers_file"
		return 0
	fi
	printf '✗ sudoers drop-in missing (%s) — run: setup-linux --apply\n' "$sudoers_file"
	return 1
}

# Ubuntu 24.04+ blocks unprivileged user namespaces (which bubblewrap needs to
# build the Jail) when kernel.apparmor_restrict_unprivileged_userns=1. The fact
# is the sysctl value, or "" when the knob is absent; only the value 1 fails.
check_userns_restriction() {
	userns_sysctl="$1"
	if [ "$userns_sysctl" = "1" ]; then
		printf '✗ unprivileged user namespaces restricted (kernel.apparmor_restrict_unprivileged_userns=1) — bubblewrap Jail will fail; sysctl -w kernel.apparmor_restrict_unprivileged_userns=0 or install an AppArmor profile\n'
		return 1
	fi
	printf '✓ unprivileged user namespaces permitted\n'
	return 0
}

# Run every prerequisite check against already-collected host facts, printing
# each report line in order. Returns 0 only if all pass, 1 if any fail — the
# check-mode exit contract. Each check runs regardless of earlier failures so
# the user sees the full picture in one pass.
run_checks() {
	systemd_version="$1"
	controllers_file="$2"
	auditd_state="$3"
	sudoers_file="$4"
	userns_sysctl="$5"

	checks_failed=0
	check_systemd_version "$systemd_version" || checks_failed=1
	check_cgroup_v2 "$controllers_file" || checks_failed=1
	check_auditd "$auditd_state" || checks_failed=1
	check_sudoers "$sudoers_file" || checks_failed=1
	check_userns_restriction "$userns_sysctl" || checks_failed=1

	return "$checks_failed"
}
