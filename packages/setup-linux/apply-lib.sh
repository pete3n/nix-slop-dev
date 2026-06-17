# Pure apply-mode logic for setup-linux.
#
# These functions are deterministic given their arguments: they generate the
# sudoers drop-in, detect tool paths against the caller's PATH, map a distro to
# its auditd install command, and compute the idempotent change plan. They
# perform no host mutation — writing /etc, running the package manager, and the
# confirmation prompt all live in the setup-linux main.

# Render the /etc/sudoers.d/sandboxed content granting <user> passwordless sudo
# for the five privileged tools by their detected absolute paths. The wrapper
# invokes bare names (ADR-0002); sudo's secure_path resolves them to these
# paths and matches the Cmnd specs below.
sudoers_content() {
	sudoers_user="$1"
	tool_systemd_run="$2"
	tool_systemctl="$3"
	tool_tail="$4"
	tool_auditctl="$5"
	tool_ausearch="$6"

	printf '%s\n' \
		"# Managed by nix-slop-dev setup-linux — do not edit by hand." \
		"# Grants ${sudoers_user} passwordless sudo for the sandboxed wrapper's" \
		"# privileged tools (systemd-run, systemctl, tail, auditctl, ausearch)." \
		"${sudoers_user} ALL=(root) NOPASSWD: ${tool_systemd_run}, ${tool_systemctl}, ${tool_tail}, ${tool_auditctl}, ${tool_ausearch}"
}

# Resolve a privileged tool to its absolute host path: first via the caller's
# PATH (command -v), then by probing fallback system dirs (auditctl/ausearch
# commonly live in /sbin or /usr/sbin, off a normal user's PATH). Prints the
# path and returns 0, or returns 1 if the tool is found nowhere. Fallback dirs
# default to the system sbin dirs but may be overridden (used by tests).
detect_tool_path() {
	tool_name="$1"
	shift
	if [ "$#" -eq 0 ]; then
		set -- /usr/sbin /sbin
	fi

	resolved="$(command -v "$tool_name" 2>/dev/null || true)"
	if [ -n "$resolved" ]; then
		printf '%s\n' "$resolved"
		return 0
	fi

	for fallback_dir in "$@"; do
		if [ -x "${fallback_dir}/${tool_name}" ]; then
			printf '%s\n' "${fallback_dir}/${tool_name}"
			return 0
		fi
	done
	return 1
}

# Map an os-release distro ID to the command that installs auditd, accounting
# for the package-name difference (Debian/Ubuntu ship "auditd"; Fedora ships
# "audit"). Prints the command and returns 0, or returns 1 for an unsupported
# distro.
auditd_install_cmd() {
	distro_id="$1"
	case "$distro_id" in
		ubuntu | debian)
			printf 'apt-get install -y auditd\n'
			;;
		fedora)
			printf 'dnf install -y audit\n'
			;;
		*)
			return 1
			;;
	esac
}

# Render an AppArmor profile that lifts Ubuntu 23.10+/24.04's unprivileged
# user-namespace restriction for bubblewrap. The profile attaches to the
# bwrap store-path glob (not a fixed path) so it stays valid when a flake
# update changes bwrap's /nix/store hash, and grants the userns permission
# while otherwise leaving the program unconfined.
apparmor_profile_content() {
	profile_name="$1"
	bwrap_glob="$2"

	printf '%s\n' \
		"abi <abi/4.0>," \
		"include <tunables/global>" \
		"" \
		"profile ${profile_name} \"${bwrap_glob}\" flags=(unconfined) {" \
		"  userns," \
		"" \
		"  include if exists <local/${profile_name}>" \
		"}"
}

# Compute the idempotent change plan from two satisfied-booleans (1 = already
# in place, 0 = needs action): the sudoers drop-in and auditd. Prints one line
# per planned action, in apply order; prints nothing when the host is already
# configured (the no-op the caller detects by empty output). Always returns 0.
plan_actions() {
	sudoers_ok="$1"
	auditd_ok="$2"
	# Optional: 1 = unprivileged userns permitted (no profile needed). Absent
	# defaults to satisfied, preserving the original two-argument behavior.
	userns_ok="${3:-1}"

	if [ "$auditd_ok" != "1" ]; then
		printf 'install and enable auditd\n'
	fi
	if [ "$sudoers_ok" != "1" ]; then
		printf 'write /etc/sudoers.d/sandboxed\n'
	fi
	if [ "$userns_ok" != "1" ]; then
		printf 'install AppArmor profile permitting unprivileged user namespaces for bubblewrap\n'
	fi
	return 0
}

# Compute the idempotent removal plan, mirroring plan_actions. Takes three
# presence booleans (1 = present and would be removed; 0 = already absent,
# skip) and prints one line per planned action. AppArmor profile-on-disk and
# profile-loaded share a single action line — the remove path unloads then
# deletes as one logical step. Prints nothing when nothing is left to remove.
# Always returns 0. Note: auditd is intentionally NOT touched by --remove —
# it's a general-purpose subsystem users may want for other reasons; doc'd as
# a manual step in non-nixos-linux.md.
plan_remove_actions() {
	apparmor_profile_present="$1"
	apparmor_profile_loaded="$2"
	sudoers_present="$3"

	if [ "$apparmor_profile_present" = "1" ] || [ "$apparmor_profile_loaded" = "1" ]; then
		printf 'unload and delete AppArmor profile (/etc/apparmor.d/nix-slop-dev-bwrap)\n'
	fi
	if [ "$sudoers_present" = "1" ]; then
		printf 'delete sudoers drop-in (/etc/sudoers.d/sandboxed)\n'
	fi
	return 0
}
