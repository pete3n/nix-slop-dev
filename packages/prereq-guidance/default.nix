{
  pkgs,
  ...
}:
# Reports unmet Sandbox prerequisites (auditd running, NOPASSWD sudo) with
# distro-aware remediation, shared by the claude-code template shellHooks.
# Returns 0 when all system prerequisites are met, nonzero otherwise. The
# NixOS marker is overridable by argument for testing; production calls pass
# nothing and detect /etc/NIXOS.
pkgs.writeShellScriptBin "slop-prereq-guidance" # bash
  ''
    set -u

    nixos_marker="''${1:-/etc/NIXOS}"
    prereq_ok=1

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
    		printf '  Run `setup-linux --apply` to install and enable auditd.\n\n'
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
    		printf '  Run `setup-linux --apply` to write /etc/sudoers.d/sandboxed.\n\n'
    	fi
    	prereq_ok=0
    fi

    [ "$prereq_ok" -eq 1 ]
  ''
