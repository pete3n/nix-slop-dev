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
    # The legacy /sys/kernel/security/apparmor/profiles file is 0440 (root
    # only), so we use the newer policy/profiles/ directory: world-listable
    # on AppArmor 3.0+ (Ubuntu 22.04+, where the userns sysctl also lives).
    # Each loaded profile appears as a directory whose name is the profile
    # name plus a generation suffix (e.g. nix-slop-dev-bwrap.193).
    apparmor_profiles_path=/sys/kernel/security/apparmor/policy/profiles
    apparmor_profile_name=nix-slop-dev-bwrap
    apparmor_profile_path="/etc/apparmor.d/''${apparmor_profile_name}"
    bwrap_glob='/nix/store/*/bin/bwrap'
    cgroup_controllers=/sys/fs/cgroup/cgroup.controllers

    _usage() {
    	printf >&2 '%s\n' \
    	"Usage: setup-linux [--check | --apply | --remove]" \
    	"" \
    	"  --check    Diagnose Sandbox/Jail prerequisites; mutate nothing (default)" \
    	"  --apply    Show planned changes, confirm, then write the sudoers drop-in" \
    	"             and install/enable auditd" \
    	"  --remove   Show planned removals, confirm, then unload + delete the" \
    	"             AppArmor profile and the sudoers drop-in. Does not touch" \
    	"             auditd — remove it by hand (apt/dnf) if you no longer need it"
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
    	# nix-slop-dev-bwrap AppArmor profile loaded? Check the policy/profiles
    	# directory for an entry matching the profile name (with or without
    	# the .NN generation suffix). The trailing literal `.` prevents a
    	# future nix-slop-dev-bwrap-foo from false-positiving.
    	apparmor_profile_loaded=0
    	for _aa_entry in "$apparmor_profiles_path/''${apparmor_profile_name}" \
    		"$apparmor_profiles_path/''${apparmor_profile_name}".*; do
    		if [ -e "$_aa_entry" ]; then
    			apparmor_profile_loaded=1
    			break
    		fi
    	done

    	printf 'setup-linux: Sandbox/Jail prerequisites\n\n'
    	if run_checks \
    		"$systemd_version" \
    		"$cgroup_controllers" \
    		"$auditd_state" \
    		"$sudoers_file" \
    		"$userns_sysctl" \
    		"$apparmor_profile_loaded"; then
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

    	if [ -f "$sudoers_file" ]; then sudoers_ok=1; else sudoers_ok=0; fi
    	if [ "$(systemctl is-active auditd 2>/dev/null || true)" = active ]; then
    		auditd_ok=1
    	else
    		auditd_ok=0
    	fi
    	# Userns is satisfied if the sysctl is unrestricted system-wide OR our
    	# AppArmor profile is loaded (the latter is what apply mode installs;
    	# it grants userns to bwrap only without lifting the restriction
    	# globally). Treating "profile already loaded" as satisfied keeps apply
    	# mode idempotent — a second run is a no-op, not a reinstall.
    	userns_sysctl_now="$(${pkgs.coreutils}/bin/cat "$userns_sysctl_path" 2>/dev/null || true)"
    	apparmor_profile_loaded=0
    	for _aa_entry in "$apparmor_profiles_path/''${apparmor_profile_name}" \
    		"$apparmor_profiles_path/''${apparmor_profile_name}".*; do
    		if [ -e "$_aa_entry" ]; then
    			apparmor_profile_loaded=1
    			break
    		fi
    	done
    	if [ "$userns_sysctl_now" != 1 ] || [ "$apparmor_profile_loaded" = 1 ]; then
    		userns_ok=1
    		if [ "$apparmor_profile_loaded" = 1 ]; then
    			printf 'setup-linux: AppArmor profile %s already loaded; no userns work needed.\n' "$apparmor_profile_name"
    		else
    			printf 'setup-linux: unprivileged user namespaces permitted; no AppArmor profile needed.\n'
    		fi
    	else
    		userns_ok=0
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
    		# `detect_tool_paths` returns every standard sudo-path location
    		# where the tool exists (newline-separated). Joining with ", "
    		# yields the sudoers Cmnd_Spec list format and ensures that
    		# whichever absolute path sudo's secure_path picks at invocation
    		# time matches a NOPASSWD entry. Without this, merged-usr
    		# distros (Fedora) where /sbin → /usr/sbin → /usr/bin all
    		# coexist would silently fail NOPASSWD because sudoers would
    		# only carry one of the path strings.
    		_collect_paths() {
    			out="$(detect_tool_paths "$1" \
    				| ${pkgs.gawk}/bin/awk 'NR>1 {printf ", "} {printf "%s", $0}')"
    			[ -n "$out" ] || return 1
    			printf '%s' "$out"
    		}
    		missing_tools=""
    		tool_systemd_run="$(_collect_paths systemd-run)" || missing_tools="''${missing_tools} systemd-run"
    		tool_systemctl="$(_collect_paths systemctl)"     || missing_tools="''${missing_tools} systemctl"
    		tool_tail="$(_collect_paths tail)"               || missing_tools="''${missing_tools} tail"
    		tool_auditctl="$(_collect_paths auditctl)"       || missing_tools="''${missing_tools} auditctl"
    		tool_ausearch="$(_collect_paths ausearch)"       || missing_tools="''${missing_tools} ausearch"
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

    	printf 'setup-linux: done. Run `nix run github:pete3n/nix-slop-dev#setup-linux -- --check` to verify.\n'
    	exit 0
    }

    # ----- remove mode -----
    # Symmetric to apply mode: compute the removal plan and get confirmation
    # BEFORE any host mutation. Always unload the AppArmor profile before
    # deleting its file so a "loaded but file-gone" state is never created.
    # We re-render the profile content to a tempfile for `apparmor_parser -R`
    # so unload works even if /etc/apparmor.d/nix-slop-dev-bwrap was already
    # deleted (apparmor_parser identifies profiles by name from the file
    # content, not by the file path).
    _run_remove_mode() {
    	if [ -f "$apparmor_profile_path" ]; then
    		apparmor_profile_present=1
    	else
    		apparmor_profile_present=0
    	fi

    	apparmor_profile_loaded=0
    	for _aa_entry in "$apparmor_profiles_path/''${apparmor_profile_name}" \
    		"$apparmor_profiles_path/''${apparmor_profile_name}".*; do
    		if [ -e "$_aa_entry" ]; then
    			apparmor_profile_loaded=1
    			break
    		fi
    	done

    	if [ -f "$sudoers_file" ]; then
    		sudoers_present=1
    	else
    		sudoers_present=0
    	fi

    	plan="$(plan_remove_actions "$apparmor_profile_present" \
    		"$apparmor_profile_loaded" "$sudoers_present")"
    	if [ -z "$plan" ]; then
    		printf 'setup-linux: nothing to remove (host already clean).\n'
    		exit 0
    	fi

    	printf 'setup-linux: the following will be removed:\n'
    	printf '%s\n' "$plan" | ${pkgs.gnused}/bin/sed 's/^/  - /'
    	printf '\nProceed? [y/N] '
    	read -r reply || reply=""
    	case "$reply" in
    		y | Y | yes | YES) ;;
    		*)
    			printf 'Aborted; no changes made.\n'
    			exit 0
    			;;
    	esac

    	if [ "$apparmor_profile_loaded" = 1 ] || [ "$apparmor_profile_present" = 1 ]; then
    		# Unload first. Re-rendering to a tempfile lets -R work even when
    		# the file has already been deleted from /etc/apparmor.d/.
    		if [ "$apparmor_profile_loaded" = 1 ]; then
    			tmp_aa="$(${pkgs.coreutils}/bin/mktemp)"
    			apparmor_profile_content "$apparmor_profile_name" "$bwrap_glob" > "$tmp_aa"
    			sudo apparmor_parser -R "$tmp_aa" \
    				|| printf >&2 'setup-linux: warning: apparmor_parser -R failed; profile may still be loaded\n'
    			${pkgs.coreutils}/bin/rm -f "$tmp_aa"
    		fi
    		if [ "$apparmor_profile_present" = 1 ]; then
    			sudo ${pkgs.coreutils}/bin/rm -f "$apparmor_profile_path"
    		fi
    	fi

    	if [ "$sudoers_present" = 1 ]; then
    		sudo ${pkgs.coreutils}/bin/rm -f "$sudoers_file"
    	fi

    	printf 'setup-linux: done. Run `nix run github:pete3n/nix-slop-dev#setup-linux -- --check` to verify.\n'
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
    		--remove)
    			mode=remove
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

    case "$mode" in
    	apply)  _run_apply_mode  ;;
    	remove) _run_remove_mode ;;
    	*)      _run_check_mode  ;;
    esac
  ''
