{
  pkgs,
  ...
}:
# Reports unmet Sandbox prerequisites (auditd running, NOPASSWD sudo, the
# AppArmor unprivileged-userns restriction on non-NixOS Ubuntu, and the
# SELinux /nix file-context on non-NixOS Fedora/RHEL) with distro-aware
# remediation, shared by the claude-code template shellHooks. Returns 0
# when all system prerequisites are met, nonzero otherwise.
#
# Probe paths and the SELinux facts are overridable by positional argument
# so the build sandbox can exercise every branch without touching /etc/NIXOS,
# /proc/sys, or running getenforce on a real Fedora host; production calls
# pass nothing and the script collects the live state.
#
# On non-NixOS we always offer the canonical one-shot
#   `nix run github:pete3n/nix-slop-dev#setup-linux -- --apply`
# and, when /etc/os-release identifies a supported distro, the equivalent
# manual install command for users who prefer to do it by hand. The supported
# set matches apply-lib.sh's auditd_install_cmd (ubuntu/debian/fedora) so the
# script never advertises a manual path apply mode itself can't take.
pkgs.writeShellScriptBin "slop-prereq-guidance" # bash
  ''
    set -u

    nixos_marker="''${1:-/etc/NIXOS}"
    userns_sysctl_path="''${2:-/proc/sys/kernel/apparmor_restrict_unprivileged_userns}"
    # The legacy /sys/kernel/security/apparmor/profiles file is 0440 (root
    # only). The newer policy/profiles/ directory is world-listable on
    # AppArmor 3.0+ (Ubuntu 22.04+, where the userns sysctl also lives), so
    # we look there for a `nix-slop-dev-bwrap[.NN]` entry.
    apparmor_profiles_path="''${3:-/sys/kernel/security/apparmor/policy/profiles}"
    apparmor_profile_name=nix-slop-dev-bwrap
    # SELinux fact overrides. Sentinel `__unset__` distinguishes "not passed"
    # from "passed as empty string" — production passes nothing and we
    # collect via `getenforce` + `stat -c %C` on a nix-store binary; tests
    # pass explicit values to drive each branch deterministically.
    selinux_state_override="''${4-__unset__}"
    nix_store_label_override="''${5-__unset__}"
    setup_linux_cmd='nix run github:pete3n/nix-slop-dev#setup-linux -- --apply'
    prereq_ok=1

    # Distro ID drives the manual-install hint. Unknown / unsupported distros
    # only see the nix-run one-shot (apply mode would reject them too).
    distro_id=""
    if [ -r /etc/os-release ]; then
    	# shellcheck disable=SC1091
    	. /etc/os-release 2>/dev/null || true
    	distro_id="''${ID:-}"
    fi

    case "$distro_id" in
    	ubuntu | debian)
    		manual_auditd='sudo apt-get install -y auditd && sudo systemctl enable --now auditd'
    		;;
    	fedora)
    		manual_auditd='sudo dnf install -y audit && sudo systemctl enable --now auditd'
    		;;
    	*)
    		manual_auditd=""
    		;;
    esac

    if [ -f "$nixos_marker" ]; then
    	# On NixOS the wrapper invokes systemd-run by its embedded store path,
    	# so that is what NOPASSWD sudo must be checked against (ADR-0002).
    	systemd_run_check="${pkgs.systemd}/bin/systemd-run"
    else
    	systemd_run_check="systemd-run"
    fi

    if ! systemctl is-active --quiet auditd 2>/dev/null; then
    	printf '\033[1;33m⚠ auditd is not running.\033[0m\n'
    	printf '  The sandboxed wrapper requires auditd for violation detection.\n'
    	if [ -f "$nixos_marker" ]; then
    		printf '  Add to your NixOS config:\n'
    		printf '    security.sandboxed.enable = true;\n'
    		printf '    security.sandboxed.users = [ "<your-user>" ];\n\n'
    	else
    		printf '  Run all setup steps with confirmation:\n'
    		printf '    %s\n' "$setup_linux_cmd"
    		if [ -n "$manual_auditd" ]; then
    			printf '  Or install and enable auditd by hand:\n'
    			printf '    %s\n' "$manual_auditd"
    		fi
    		printf '\n'
    	fi
    	prereq_ok=0
    fi

    if ! sudo -n "$systemd_run_check" --help >/dev/null 2>&1; then
    	printf '\033[1;33m⚠ NOPASSWD sudo for systemd-run is not configured.\033[0m\n'
    	printf '  The sandboxed wrapper needs passwordless sudo for:\n'
    	printf '    systemd-run, systemctl, auditctl, ausearch, tail\n'
    	if [ -f "$nixos_marker" ]; then
    		printf '  Add to your NixOS config:\n'
    		printf '    security.sandboxed.users = [ "<your-user>" ];\n\n'
    	else
    		printf '  Run (apply mode writes a visudo-validated drop-in at\n'
    		printf '  /etc/sudoers.d/sandboxed after showing the changes):\n'
    		printf '    %s\n' "$setup_linux_cmd"
    		printf '  Or see docs/non-nixos-linux.md for the manual sudoers steps.\n\n'
    	fi
    	prereq_ok=0
    fi

    # Ubuntu 23.10+/24.04 restricts unprivileged user namespaces via an
    # AppArmor sysctl. bubblewrap (the Jail) cannot create a userns when this
    # is on UNLESS our nix-slop-dev-bwrap AppArmor profile is loaded — that
    # profile grants the userns capability to bwrap only (the system-wide
    # sysctl stays restricted, which is the intended posture). Skipped on
    # NixOS where the sysctl isn't a typical concern.
    if [ ! -f "$nixos_marker" ] && [ -r "$userns_sysctl_path" ]; then
    	userns_val=""
    	read -r userns_val < "$userns_sysctl_path" 2>/dev/null || true
    	if [ "$userns_val" = "1" ]; then
    		profile_loaded=0
    		# Match either the bare profile name or name.NN (the generation
    		# suffix AppArmor adds at load time). The trailing literal `.`
    		# stops nix-slop-dev-bwrap-foo from false-positiving.
    		for _aa_entry in "$apparmor_profiles_path/''${apparmor_profile_name}" \
    			"$apparmor_profiles_path/''${apparmor_profile_name}".*; do
    			if [ -e "$_aa_entry" ]; then
    				profile_loaded=1
    				break
    			fi
    		done
    		if [ "$profile_loaded" != 1 ]; then
    			printf '\033[1;33m⚠ Unprivileged user namespaces are restricted (Ubuntu 23.10+/24.04 default) and the nix-slop-dev-bwrap AppArmor profile is not loaded.\033[0m\n'
    			printf '  bubblewrap (the Jail) needs to create a user namespace; it will fail until\n'
    			printf '  the AppArmor profile grants the userns capability to bwrap.\n'
    			printf '  Run (apply mode installs a narrow profile granting userns to bwrap only):\n'
    			printf '    %s\n' "$setup_linux_cmd"
    			printf '  Or see docs/non-nixos-linux.md §4 for the manual profile steps.\n\n'
    			prereq_ok=0
    		fi
    	fi
    fi

    # SELinux /nix file-context (non-NixOS Fedora/RHEL). When the host is
    # Enforcing and /nix/store carries default_t, init_t cannot execve the
    # store binaries `sudo systemd-run --property=User=…` hands as ExecStart
    # — the wrapper dies with EXIT_EXEC=203. Apply mode installs a
    # `semanage fcontext -a -e /usr /nix` equivalence and restorecons; after
    # that the type is bin_t and init_t can exec. Skipped on NixOS (the
    # NixOS-managed selinux policies already handle /nix correctly).
    if [ ! -f "$nixos_marker" ]; then
    	if [ "$selinux_state_override" = "__unset__" ]; then
    		selinux_state="$(getenforce 2>/dev/null || true)"
    	else
    		selinux_state="$selinux_state_override"
    	fi
    	if [ "$nix_store_label_override" = "__unset__" ]; then
    		nix_store_label=""
    		_nix_bin="$(command -v nix 2>/dev/null || true)"
    		if [ -n "$_nix_bin" ]; then
    			_nix_bin="$(${pkgs.coreutils}/bin/readlink -f "$_nix_bin" 2>/dev/null || printf '%s' "$_nix_bin")"
    			nix_store_label="$(${pkgs.coreutils}/bin/stat -c '%C' "$_nix_bin" 2>/dev/null \
    				| ${pkgs.coreutils}/bin/cut -d: -f3 || true)"
    		fi
    	else
    		nix_store_label="$nix_store_label_override"
    	fi
    	if [ "$selinux_state" = "Enforcing" ] \
    		&& { [ -z "$nix_store_label" ] || [ "$nix_store_label" = "default_t" ]; }; then
    		printf '\033[1;33m⚠ SELinux is enforcing and /nix/store carries default_t.\033[0m\n'
    		printf '  sudo systemd-run cannot execve store binaries (init_t→default_t deny);\n'
    		printf '  the sandboxed wrapper will exit 203 before the jailed binary runs.\n'
    		printf '  Run (apply mode installs a `semanage fcontext -a -e /usr /nix` equivalence\n'
    		printf '  and restorecons /nix so store paths inherit bin_t):\n'
    		printf '    %s\n' "$setup_linux_cmd"
    		printf '  Or see docs/non-nixos-linux.md §5 for the manual semanage steps.\n\n'
    		prereq_ok=0
    	fi
    fi

    [ "$prereq_ok" -eq 1 ]
  ''
