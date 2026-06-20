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
	printf '✗ auditd not active (%s) — run: nix run github:pete3n/nix-slop-dev#setup-linux -- --apply\n' "$auditd_state"
	return 1
}

# The sudoers drop-in grants the invoking users passwordless access to the
# host's five privileged tools by absolute path (ADR-0002). Apply mode writes
# it; check mode only reports presence.
#
# Direct file detection is the fast path, but /etc/sudoers.d/ is typically
# 0750 root:root and a non-root user not in the root group can't even
# traverse into it (most visible on Fedora). When `[ -f … ]` fails for that
# reason we fall back to a functional probe: `sudo -n auditctl -h` succeeds
# without prompting if our NOPASSWD grant is active, which is the only way
# the drop-in could be functional anyway — so a successful probe is proof
# of presence even when we can't see the file directly.
check_sudoers() {
	sudoers_file="$1"
	if [ -f "$sudoers_file" ] 2>/dev/null; then
		printf '✓ sudoers drop-in present (%s)\n' "$sudoers_file"
		return 0
	fi
	if sudo -n auditctl -h >/dev/null 2>&1; then
		printf '✓ sudoers drop-in active (NOPASSWD probe via auditctl succeeded; %s not directly readable)\n' "$sudoers_file"
		return 0
	fi
	printf '✗ sudoers drop-in missing or inactive (%s) — run: nix run github:pete3n/nix-slop-dev#setup-linux -- --apply\n' "$sudoers_file"
	return 1
}

# Ubuntu 24.04+ blocks unprivileged user namespaces (which bubblewrap needs to
# build the Jail) when kernel.apparmor_restrict_unprivileged_userns=1. The
# system-wide knob can be lifted two ways:
#   - sysctl set to 0 (broad, not recommended — see docs/non-nixos-linux.md §4)
#   - the nix-slop-dev-bwrap AppArmor profile loaded, which grants userns to
#     bwrap only (apply mode installs this)
# The two facts together: userns_sysctl is the raw /proc value (or "" when the
# knob is absent), apparmor_profile_loaded is "1" if the nix-slop-dev-bwrap
# profile is in the loaded-profile list and "0" otherwise.
check_userns_restriction() {
	userns_sysctl="$1"
	apparmor_profile_loaded="$2"

	if [ "$userns_sysctl" != "1" ]; then
		printf '✓ unprivileged user namespaces permitted (sysctl)\n'
		return 0
	fi
	if [ "$apparmor_profile_loaded" = "1" ]; then
		printf '✓ AppArmor profile nix-slop-dev-bwrap loaded — grants userns to bwrap (sysctl still restricted system-wide, which is intended)\n'
		return 0
	fi
	printf '✗ unprivileged user namespaces restricted (kernel.apparmor_restrict_unprivileged_userns=1) and nix-slop-dev-bwrap AppArmor profile not loaded — bubblewrap Jail will fail; run: nix run github:pete3n/nix-slop-dev#setup-linux -- --apply (apply mode installs a narrow AppArmor profile granting userns to bwrap only — see docs/non-nixos-linux.md §4 for manual steps)\n'
	return 1
}

# Fedora's audit package ships /etc/audit/rules.d/audit.rules containing
# `-a task,never`, which clears the per-task audit context. With it active,
# no `__audit_syscall_exit` ever fires — so even `-a always,exit -S connect`
# rules log nothing. The sandbox's violation banner and `--log` depend on
# those syscall events, so we have to remove this rule on Fedora for
# observability to work. The fact is "1 if the running kernel currently
# carries a task,never rule, 0 otherwise"; the running-kernel state is
# what matters because file-only changes don't take effect until augenrules
# --load (which apply mode runs).
check_task_never() {
	task_never_active="$1"
	if [ "$task_never_active" = "1" ]; then
		printf '✗ `-a task,never` audit rule active — suppresses all syscall auditing including sandbox violation logging; run: nix run github:pete3n/nix-slop-dev#setup-linux -- --apply (apply mode comments out the line in /etc/audit/rules.d/audit.rules and removes it from the running kernel)\n'
		return 1
	fi
	printf '✓ no task,never audit rule (syscall auditing enabled)\n'
	return 0
}

# Fedora's targeted SELinux policy has no entry for /nix, so everything under
# /nix/store ends up labeled default_t. `sudo systemd-run --property=User=…`
# runs the unit's ExecStart via systemd-executor in init_t, and the kernel
# refuses init_t → default_t : file execute — the wrapper dies with
# EXIT_EXEC=203 before the jailed binary ever runs (Fedora 44 HITL
# 2026-06-19). Apply mode installs a `semanage fcontext -a -e /usr /nix`
# equivalence rule and restorecons; afterwards /nix/store binaries inherit
# /usr's labels (typically bin_t) which init_t can exec.
#
# Two facts: selinux_state from `getenforce` ("Enforcing" / "Permissive" /
# "Disabled" / "" when getenforce is absent), and nix_store_label from
# `stat -c %C` on a representative store binary (typically the type field,
# e.g. "default_t" or "bin_t"). Empty label means we couldn't probe — fails
# in Enforcing mode because we cannot prove the wrapper will work; passes
# in Permissive/Disabled/absent because policy isn't enforcing anyway.
check_selinux_nix_label() {
	selinux_state="$1"
	nix_store_label="$2"

	case "$selinux_state" in
		""|Disabled)
			printf '✓ SELinux not active (%s) — no /nix labelling needed\n' "${selinux_state:-not installed}"
			return 0
			;;
		Permissive)
			# Permissive logs but doesn't enforce — wrapper works today. Warn
			# so the user knows toggling to Enforcing without applying first
			# would break things, but pass the prereq.
			if [ "$nix_store_label" = "default_t" ]; then
				printf '✓ SELinux Permissive; /nix/store label %s (toggling to Enforcing without setup-linux --apply would break the wrapper)\n' "$nix_store_label"
			else
				printf '✓ SELinux Permissive; /nix/store label %s\n' "${nix_store_label:-unprobed}"
			fi
			return 0
			;;
	esac

	# Enforcing path.
	if [ -z "$nix_store_label" ]; then
		printf '✗ SELinux Enforcing but /nix/store label could not be probed (no nix binary on PATH) — install nix-on-PATH then re-check, or run: nix run github:pete3n/nix-slop-dev#setup-linux -- --apply\n'
		return 1
	fi
	if [ "$nix_store_label" = "default_t" ]; then
		printf '✗ SELinux Enforcing and /nix/store labeled default_t — sudo systemd-run cannot execve store binaries (init_t→default_t deny, exit 203); run: nix run github:pete3n/nix-slop-dev#setup-linux -- --apply\n'
		return 1
	fi
	printf '✓ SELinux Enforcing; /nix/store labeled %s (init_t can execve)\n' "$nix_store_label"
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
	apparmor_profile_loaded="$6"
	task_never_active="$7"
	selinux_state="${8:-}"
	nix_store_label="${9:-}"

	checks_failed=0
	check_systemd_version "$systemd_version" || checks_failed=1
	check_cgroup_v2 "$controllers_file" || checks_failed=1
	check_auditd "$auditd_state" || checks_failed=1
	check_sudoers "$sudoers_file" || checks_failed=1
	check_userns_restriction "$userns_sysctl" "$apparmor_profile_loaded" || checks_failed=1
	check_task_never "$task_never_active" || checks_failed=1
	check_selinux_nix_label "$selinux_state" "$nix_store_label" || checks_failed=1

	return "$checks_failed"
}
