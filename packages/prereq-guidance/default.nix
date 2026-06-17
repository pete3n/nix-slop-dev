{
  pkgs,
  ...
}:
# Reports unmet Sandbox prerequisites (auditd running, NOPASSWD sudo) with
# distro-aware remediation, shared by the claude-code template shellHooks.
# Returns 0 when all system prerequisites are met, nonzero otherwise. The
# NixOS marker is overridable by argument for testing; production calls pass
# nothing and detect /etc/NIXOS.
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

    [ "$prereq_ok" -eq 1 ]
  ''
