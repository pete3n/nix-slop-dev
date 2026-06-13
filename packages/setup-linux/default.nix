{
  pkgs,
  ...
}:
let
  # Pure logic, unit-tested in tests/setup-linux-checks.nix and
  # tests/setup-linux-apply.nix. Sourced at runtime by store path so the
  # runnable app and the tests share one copy.
  checkLib = ./check-lib.sh;
  applyLib = ./apply-lib.sh;
in
pkgs.writeShellScriptBin "setup-linux" # bash
  ''
    set -eu

    source ${checkLib}
    source ${applyLib}

    sudoers_file=/etc/sudoers.d/sandboxed
    userns_sysctl_path=/proc/sys/kernel/apparmor_restrict_unprivileged_userns
    cgroup_controllers=/sys/fs/cgroup/cgroup.controllers

    _usage() {
    	printf >&2 '%s\n' \
    	"Usage: setup-linux [--check | --apply]" \
    	"" \
    	"  --check   Diagnose Sandbox/Jail prerequisites; mutate nothing (default)" \
    	"  --apply   Show planned changes, confirm, then write the sudoers drop-in" \
    	"            and install/enable auditd"
    }

    # Distro ID from os-release (e.g. ubuntu, debian, fedora), or "" if unknown.
    _detect_distro_id() {
    	${pkgs.gnugrep}/bin/grep -h '^ID=' /etc/os-release 2>/dev/null \
    		| ${pkgs.gnused}/bin/sed -e 's/^ID=//' -e 's/"//g' \
    		| ${pkgs.coreutils}/bin/head -n1 \
    		|| true
    }

    # ----- check mode (impure collection -> pure run_checks) -----
    _run_check_mode() {
    	# systemd version integer, e.g. "systemd 257 (257.5)" -> 257.
    	systemd_version="$(systemctl --version 2>/dev/null \
    		| ${pkgs.gawk}/bin/awk 'NR==1 {print $2}' || true)"
    	# `systemctl is-active` prints the state and exits nonzero when inactive.
    	auditd_state="$(systemctl is-active auditd 2>/dev/null || true)"
    	# AppArmor unprivileged-userns sysctl value, or "" when the knob is absent.
    	userns_sysctl="$(${pkgs.coreutils}/bin/cat "$userns_sysctl_path" 2>/dev/null || true)"

    	printf 'setup-linux: Sandbox/Jail prerequisites\n\n'
    	if run_checks \
    		"$systemd_version" \
    		"$cgroup_controllers" \
    		"$auditd_state" \
    		"$sudoers_file" \
    		"$userns_sysctl"; then
    		printf '\nAll prerequisites met.\n'
    		exit 0
    	else
    		printf '\nSome prerequisites are not met (see ✗ above).\n' >&2
    		exit 1
    	fi
    }

    # ----- apply mode -----
    # Order is fail-safe: compute the plan and get confirmation BEFORE any host
    # mutation, and detect tool paths (which may fail) only after consent but
    # before the first write, so a decline or a detection error never leaves the
    # system half-configured.
    _run_apply_mode() {
    	apply_user="$(${pkgs.coreutils}/bin/id -un)"
    	distro_id="$(_detect_distro_id)"
    	apparmor_profile_name=nix-slop-dev-bwrap
    	apparmor_profile_path="/etc/apparmor.d/''${apparmor_profile_name}"
    	bwrap_glob='/nix/store/*/bin/bwrap'

    	if [ -f "$sudoers_file" ]; then sudoers_ok=1; else sudoers_ok=0; fi
    	if [ "$(systemctl is-active auditd 2>/dev/null || true)" = active ]; then
    		auditd_ok=1
    	else
    		auditd_ok=0
    	fi
    	# Ubuntu 23.10+/24.04 restricts unprivileged userns when the sysctl is 1.
    	if [ "$(${pkgs.coreutils}/bin/cat "$userns_sysctl_path" 2>/dev/null || true)" = 1 ]; then
    		userns_ok=0
    	else
    		userns_ok=1
    		printf 'setup-linux: unprivileged user namespaces permitted; no AppArmor profile needed.\n'
    	fi

    	plan="$(plan_actions "$sudoers_ok" "$auditd_ok" "$userns_ok")"
    	if [ -z "$plan" ]; then
    		printf 'setup-linux: already configured; nothing to do.\n'
    		exit 0
    	fi

    	printf 'setup-linux: the following changes will be made for user %s:\n' "$apply_user"
    	printf '%s\n' "$plan" | ${pkgs.gnused}/bin/sed 's/^/  - /'
    	printf '\nProceed? [y/N] '
    	read -r reply || reply=""
    	case "$reply" in
    		y | Y | yes | YES) ;;
    		*)
    			printf 'Aborted; no changes made.\n'
    			if [ "$userns_ok" != 1 ]; then
    				printf '\nTo permit unprivileged user namespaces for bubblewrap manually,\n'
    				printf 'write the following to %s, then run `sudo apparmor_parser -r %s`:\n\n' \
    					"$apparmor_profile_path" "$apparmor_profile_path"
    				apparmor_profile_content "$apparmor_profile_name" "$bwrap_glob" \
    					| ${pkgs.gnused}/bin/sed 's/^/    /'
    			fi
    			exit 0
    			;;
    	esac

    	# Install + enable auditd first (the sudoers grant references auditctl).
    	if [ "$auditd_ok" != 1 ]; then
    		if ! install_cmd="$(auditd_install_cmd "$distro_id")"; then
    			printf >&2 'setup-linux: unsupported distro %s — install auditd manually.\n' "$distro_id"
    			exit 1
    		fi
    		sudo $install_cmd
    		sudo systemctl enable --now auditd
    	fi

    	# Write the sudoers drop-in, validated before install.
    	if [ "$sudoers_ok" != 1 ]; then
    		missing_tools=""
    		tool_systemd_run="$(detect_tool_path systemd-run)" || missing_tools="''${missing_tools} systemd-run"
    		tool_systemctl="$(detect_tool_path systemctl)"     || missing_tools="''${missing_tools} systemctl"
    		tool_tail="$(detect_tool_path tail)"               || missing_tools="''${missing_tools} tail"
    		tool_auditctl="$(detect_tool_path auditctl)"       || missing_tools="''${missing_tools} auditctl"
    		tool_ausearch="$(detect_tool_path ausearch)"       || missing_tools="''${missing_tools} ausearch"
    		if [ -n "$missing_tools" ]; then
    			printf >&2 'setup-linux: required tools not found:%s — cannot write sudoers.\n' "$missing_tools"
    			exit 1
    		fi

    		content="$(sudoers_content "$apply_user" \
    			"$tool_systemd_run" "$tool_systemctl" "$tool_tail" \
    			"$tool_auditctl" "$tool_ausearch")"

    		tmp_sudoers="$(${pkgs.coreutils}/bin/mktemp)"
    		printf '%s\n' "$content" > "$tmp_sudoers"
    		if sudo visudo -cf "$tmp_sudoers" >/dev/null; then
    			sudo ${pkgs.coreutils}/bin/install -m 0440 -o root -g root \
    				"$tmp_sudoers" "$sudoers_file"
    			${pkgs.coreutils}/bin/rm -f "$tmp_sudoers"
    		else
    			${pkgs.coreutils}/bin/rm -f "$tmp_sudoers"
    			printf >&2 'setup-linux: generated sudoers failed validation; not installed.\n'
    			exit 1
    		fi
    	fi

    	# Install the AppArmor profile that lifts the unprivileged-userns
    	# restriction for bubblewrap, validated before it is loaded.
    	if [ "$userns_ok" != 1 ]; then
    		tmp_aa="$(${pkgs.coreutils}/bin/mktemp)"
    		apparmor_profile_content "$apparmor_profile_name" "$bwrap_glob" > "$tmp_aa"
    		if sudo apparmor_parser -Q "$tmp_aa" >/dev/null 2>&1; then
    			sudo ${pkgs.coreutils}/bin/install -m 0644 -o root -g root \
    				"$tmp_aa" "$apparmor_profile_path"
    			sudo apparmor_parser -r "$apparmor_profile_path"
    			${pkgs.coreutils}/bin/rm -f "$tmp_aa"
    		else
    			${pkgs.coreutils}/bin/rm -f "$tmp_aa"
    			printf >&2 'setup-linux: AppArmor profile failed to parse; not installed.\n'
    			exit 1
    		fi
    	fi

    	printf 'setup-linux: done. Run `setup-linux --check` to verify.\n'
    	exit 0
    }

    mode=check
    while [ $# -gt 0 ]; do
    	case "$1" in
    		--apply)
    			mode=apply
    			shift
    			;;
    		--check)
    			mode=check
    			shift
    			;;
    		-h | --help)
    			_usage
    			exit 0
    			;;
    		*)
    			printf >&2 'setup-linux: unknown argument %s\n' "$1"
    			_usage
    			exit 1
    			;;
    	esac
    done

    if [ "$mode" = apply ]; then
    	_run_apply_mode
    else
    	_run_check_mode
    fi
  ''
