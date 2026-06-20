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

# Multi-path variant: prints EVERY standard sudo-path location where the tool
# exists (one path per line). Sudo's secure_path may resolve a tool to a
# different absolute path than `command -v` returns — most visibly on
# merged-usr systems where /sbin → /usr/sbin → /usr/bin share the same inode
# but appear as distinct strings to sudoers Cmnd matching. Listing every
# candidate in the sudoers rule guarantees that whichever string sudo picks
# at invocation time hits a NOPASSWD entry. Returns 0 with paths on stdout
# (one per line, deduplicated), or 1 with no output if the tool is found
# nowhere. The candidate dirs default to the standard sudo secure_path set
# but may be overridden (used by tests).
detect_tool_paths() {
	tool_name="$1"
	shift
	if [ "$#" -eq 0 ]; then
		set -- /usr/local/sbin /usr/local/bin /usr/sbin /usr/bin /sbin /bin
	fi

	found=0
	# Use spaces around entries so the case match below can detect a path
	# anywhere in the seen list without false-positives on prefixes.
	seen=" "

	# The caller's PATH-resolved location is the natural first match.
	user_path="$(command -v "$tool_name" 2>/dev/null || true)"
	if [ -n "$user_path" ]; then
		printf '%s\n' "$user_path"
		seen="$seen$user_path "
		found=1
	fi

	for _dir in "$@"; do
		_candidate="$_dir/$tool_name"
		case "$seen" in
			*" $_candidate "*) continue ;;
		esac
		if [ -x "$_candidate" ]; then
			printf '%s\n' "$_candidate"
			seen="$seen$_candidate "
			found=1
		fi
	done

	[ "$found" -eq 1 ] || return 1
}

# Map an os-release distro ID to the command that installs auditd, accounting
# for the package-name difference (Debian/Ubuntu ship "auditd"; Fedora ships
# "audit"). Prints the command and returns 0, or returns 1 for an unsupported
# distro.
auditd_install_cmd() {
	distro_id="$1"
	case "$distro_id" in
		ubuntu | debian)
			# `apt-get update` first: minimal cloud images ship an empty package
			# index, so a bare `install` fails with "Unable to locate package".
			# The compound command is run via `sh -c` (see default.nix), so the
			# `&&` is honoured rather than passed as a literal argument.
			printf 'apt-get update && apt-get install -y auditd\n'
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

# Compute the idempotent change plan from satisfied-booleans (1 = already in
# place, 0 = needs action): sudoers drop-in, auditd, optional userns AppArmor
# profile, optional task,never audit-suppression rule (Fedora ships one that
# defeats sandbox observability), optional SELinux /nix fcontext equivalence
# (Fedora targeted policy labels /nix as default_t which init_t cannot exec).
# Prints one line per planned action in apply order; prints nothing when
# everything is already in place. Always returns 0.
plan_actions() {
	sudoers_ok="$1"
	auditd_ok="$2"
	# Optional: 1 = unprivileged userns permitted (no profile needed). Absent
	# defaults to satisfied, preserving the original two-argument behavior.
	userns_ok="${3:-1}"
	# Optional: 1 = no task,never rule active (good); 0 = active and must be
	# removed. Absent defaults to satisfied.
	task_never_ok="${4:-1}"
	# Optional: 1 = SELinux file-context for /nix is correct (or SELinux not
	# enforcing); 0 = Enforcing + /nix labeled default_t, must install the
	# /usr→/nix equivalence rule. Absent defaults to satisfied.
	selinux_ok="${5:-1}"

	if [ "$auditd_ok" != "1" ]; then
		printf 'install and enable auditd\n'
	fi
	if [ "$sudoers_ok" != "1" ]; then
		printf 'write /etc/sudoers.d/sandboxed\n'
	fi
	if [ "$userns_ok" != "1" ]; then
		printf 'install AppArmor profile permitting unprivileged user namespaces for bubblewrap\n'
	fi
	if [ "$task_never_ok" != "1" ]; then
		printf 'comment out `-a task,never` in /etc/audit/rules.d/audit.rules (suppresses sandbox observability) and remove from running kernel\n'
	fi
	if [ "$selinux_ok" != "1" ]; then
		printf 'add SELinux fcontext equivalence /nix → /usr and restorecon /nix (otherwise init_t cannot execve store binaries — Fedora 203/EXEC)\n'
	fi
	return 0
}

# Render the exact host commands setup-linux runs to install the SELinux
# /nix fcontext equivalence. `semanage fcontext -a -e /usr /nix` adds a
# path-substitution rule (NOT a type assignment — that's why `-e` and not
# `-t bin_t`); restorecon then applies the rule so existing files under
# /nix get relabeled. The `dnf install -y policycoreutils-python-utils`
# guard is needed because minimal Fedora installs ship the base
# policycoreutils (restorecon) but not the python tooling that provides
# `semanage`. Idempotent: re-running adds nothing (semanage detects the
# existing equivalence).
selinux_apply_cmd() {
	printf '%s\n' \
		"dnf install -y policycoreutils-python-utils" \
		"semanage fcontext -a -e /usr /nix" \
		"restorecon -R /nix"
}

# Render the symmetric `--remove` host commands. `-d -e /nix` drops the
# equivalence rule (the `-d` deletion form takes only the target path,
# not the source). restorecon then relabels /nix back to default_t.
# Idempotent: re-running after removal exits clean.
selinux_remove_cmd() {
	printf '%s\n' \
		"semanage fcontext -d -e /nix" \
		"restorecon -R /nix"
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
	# Optional: 1 if our magic marker is in /etc/audit/rules.d/audit.rules
	# (meaning apply mode previously commented out the Fedora-default
	# task,never rule and we should restore it on remove). 0 / absent = no
	# restoration needed.
	task_never_was_disabled="${4:-0}"
	# Optional: 1 if `semanage fcontext -l` carries our /nix → /usr
	# equivalence (apply mode installed it). --remove drops the rule and
	# restorecons /nix back to default_t. 0 / absent = nothing to remove.
	selinux_fcontext_present="${5:-0}"

	if [ "$apparmor_profile_present" = "1" ] || [ "$apparmor_profile_loaded" = "1" ]; then
		printf 'unload and delete AppArmor profile (/etc/apparmor.d/nix-slop-dev-bwrap)\n'
	fi
	if [ "$sudoers_present" = "1" ]; then
		printf 'delete sudoers drop-in (/etc/sudoers.d/sandboxed)\n'
	fi
	if [ "$task_never_was_disabled" = "1" ]; then
		printf 'restore `-a task,never` in /etc/audit/rules.d/audit.rules (re-enables Fedora default)\n'
	fi
	if [ "$selinux_fcontext_present" = "1" ]; then
		printf 'drop SELinux fcontext equivalence /nix → /usr and restorecon /nix back to default_t\n'
	fi
	return 0
}
