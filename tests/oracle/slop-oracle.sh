#!/usr/bin/env bash
# slop-oracle — the portable invariant oracle for the functional test layer.
#
# Single source of truth for "the Slop Env still enforces its boundaries"
# (ADR-0006). One assertion per invocation; the *expected* outcome is encoded
# here, not in the harness, so the harness only checks the exit code:
#
#   exit 0  -> the invariant HOLDS
#   exit 1  -> the invariant is VIOLATED (or the check could not be run)
#
# Every harness invokes this same script through a per-platform "launch a
# sandboxed command" shim:
#   - NixOS:        sandboxed -q [-a HOST] -- slop-oracle <check> ...   (nixosTest)
#   - Debian/etc:   same, on a provisioned VM after `setup-linux --apply`
#   - macOS:        the sandboxed-jailed wrapper -- slop-oracle <check> ...
#
# Checks marked (in-env) run INSIDE the confined environment. Checks marked
# (host) run OUTSIDE it, by the harness, after a confined run has happened.
#
# The six universal invariants (ADR-0006):
#   1 deny-closed        -> net-deny    (in-env)
#   2 allow-connects     -> net-allow   (in-env)
#   3 violation-recorded -> violation-logged (host)
#   4 path-hidden        -> path-hidden (in-env)
#   5 project-rw         -> path-rw     (in-env)
#   6 host-binary-absent -> no-host-bin (in-env)
#
# Portable bash. Intentionally dependency-light: curl for HTTP, plus coreutils
# / grep. No GNU-only flags so the same bytes run on a mac and on Fedora.

set -u

PROG=${0##*/}

# How long a network probe waits before deciding the boundary acted. Kept
# short so net-deny (which is expected to time out) doesn't dominate runtime.
NET_TIMEOUT=${SLOP_NET_TIMEOUT:-5}

# How the host-side violation check queries the audit log. Overridable so the
# distro/macOS harnesses can substitute their own log surface.
LOG_CMD=${SLOP_LOG_CMD:-sandboxed --log}

# Bounded retry for the audit log: auditd flushes asynchronously, so a denied
# connect may not be searchable the instant the confined run exits.
LOG_RETRIES=${SLOP_LOG_RETRIES:-10}
LOG_RETRY_DELAY=${SLOP_LOG_RETRY_DELAY:-1}

pass() { printf 'PASS %s: %s\n' "$1" "$2"; exit 0; }
fail() { printf 'FAIL %s: %s\n' "$1" "$2" >&2; exit 1; }

usage() {
	cat >&2 <<EOF
Usage: $PROG <check> <arg>

In-env checks (run inside the Slop Env):
  net-allow    <url>         a whitelisted endpoint returns data within timeout
  net-deny     <url>         a non-whitelisted endpoint yields no data (closed)
  net-deny-raw <host> <port> a raw (non-proxy) TCP connect fails closed
  net-deny-udp <host> <port> a UDP datagram to an echo stub fails closed
  path-hidden  <path>        a confined-out path is not readable
  path-rw      <dir>         the project dir accepts create+read+delete
  no-host-bin  <name>        a host binary cannot be executed (absent, or exec-denied)

Host checks (run outside, after a confined run):
  violation-logged <pattern>   \$SLOP_LOG_CMD output contains a block for <pattern>

Env knobs: SLOP_NET_TIMEOUT, SLOP_LOG_CMD, SLOP_LOG_RETRIES, SLOP_LOG_RETRY_DELAY
EOF
	exit 2
}

# Fetch <url> with a hard timeout. Echoes the body; returns curl's exit status.
# --fail makes HTTP >=400 a failure; -sS stays quiet but surfaces errors.
fetch() {
	curl --fail --silent --show-error --max-time "$NET_TIMEOUT" "$1" 2>/dev/null
}

check_net_allow() {
	local url=$1 body
	body=$(fetch "$url") && [ -n "$body" ] \
		&& pass net-allow "reached $url (got ${#body} bytes)" \
		|| fail net-allow "whitelisted endpoint $url unreachable — allow path broken"
}

check_net_deny() {
	# A blocked endpoint must yield NO data. We require an actual transfer
	# attempt to fail, not merely connect() to fail: on some kernels
	# (Fedora) IPAddressDeny lets connect() return 0 and silently drops the
	# egress, so a body of "" with a non-zero curl status is the real
	# signal. Any non-empty body means the boundary leaked.
	local url=$1 body status
	body=$(fetch "$url"); status=$?
	if [ "$status" -eq 0 ] && [ -n "$body" ]; then
		fail net-deny "non-whitelisted endpoint $url returned data — boundary leaked"
	fi
	pass net-deny "no data from $url (curl exit $status) — failed closed"
}

check_net_deny_raw() {
	# A RAW TCP connect (bash /dev/tcp) bypasses any HTTP(S)_PROXY/ALL_PROXY.
	# On macOS the Sandbox only governs proxy-aware TCP (CONNECT/SOCKS5), so a
	# non-proxy-aware socket must be denied by Seatbelt and fail closed
	# (ADR-0003 — same reason `ping <whitelisted-ip>` cannot work). A
	# successful connect means a non-proxy egress path leaked, even to an
	# otherwise-whitelisted host. On Linux this is a bonus belt-and-suspenders
	# check (IPAddressDeny governs all egress, so it holds there too).
	local host=$1 port=$2
	[ -n "$host" ] && [ -n "$port" ] || fail net-deny-raw "usage: net-deny-raw <host> <port>"
	if timeout "$NET_TIMEOUT" bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null; then
		exec 3>&- 2>/dev/null || true
		fail net-deny-raw "raw TCP to $host:$port connected — non-proxy egress leaked"
	fi
	pass net-deny-raw "raw TCP to $host:$port refused — failed closed"
}

check_net_deny_udp() {
	# UDP fail-closed (ADR-0003 — the macOS Seatbelt profile is
	# `(deny network-outbound)` save the proxy's localhost port, so UDP to any
	# other host/port is dropped; there is no UDP allow path even with -a, the
	# same reason `ping` cannot work). UDP is connectionless, so the sender
	# cannot tell delivery from loss locally — we need an ECHO: send a token to
	# a stub that bounces it back. Silence within the timeout (or a denied
	# send) means the boundary dropped it; the token coming back means a
	# non-proxy UDP egress leaked. On Linux this also holds (IPAddressDeny
	# governs UDP), so it is a portable bonus there.
	local host=$1 port=$2 token reply
	[ -n "$host" ] && [ -n "$port" ] || fail net-deny-udp "usage: net-deny-udp <host> <port>"
	token="slop-udp-$$"
	# All socket I/O happens in a subshell, for two reasons:
	#   - a refused connect makes `exec 3<>/dev/udp/...` a *fatal* redirection
	#     error (it would kill this script even inside `if ! exec`); confining
	#     it to the subshell turns that into an empty reply == failed-closed.
	#   - UDP delivers one datagram per read(), so `dd bs=… count=1` returns the
	#     whole echo regardless of a trailing newline — unlike `read -t`, which
	#     on a newline-less datagram times out without assigning $reply.
	# `timeout` bounds the wait (already a dependency of net-deny-raw); any bytes
	# carrying the token mean the datagram escaped and was echoed back.
	# Group-redirect stderr to /dev/null: a Seatbelt-denied connect makes
	# `exec 3<>/dev/udp/...` print a fatal redirection error ("Operation not
	# permitted") that a per-command `2>/dev/null` does not fully suppress.
	reply=$(
		{
			exec 3<>"/dev/udp/$host/$port" || exit 0
			printf '%s' "$token" >&3 || exit 0
			timeout "$NET_TIMEOUT" dd bs=65535 count=1 <&3 || true
		} 2>/dev/null
	)
	case "$reply" in
		*"$token"*) fail net-deny-udp "UDP echo from $host:$port returned the token — egress leaked" ;;
	esac
	pass net-deny-udp "no UDP echo from $host:$port — failed closed"
}

check_path_hidden() {
	local path=$1
	if cat -- "$path" >/dev/null 2>&1; then
		fail path-hidden "$path is readable inside the jail — confinement leaked"
	fi
	pass path-hidden "$path not readable inside the jail"
}

check_path_rw() {
	local dir=$1 probe
	probe="$dir/.slop-oracle-rw.$$"
	if printf 'slop' > "$probe" 2>/dev/null \
		&& [ "$(cat -- "$probe" 2>/dev/null)" = slop ]; then
		rm -f -- "$probe" 2>/dev/null
		pass path-rw "$dir is writable and readable"
	fi
	rm -f -- "$probe" 2>/dev/null
	fail path-rw "$dir is not read-write — project dir confinement is wrong"
}

check_no_host_bin() {
	# Invariant #6: a host privilege tool cannot be EXECUTED inside the jail.
	# One invariant, two enforcement models (ADR-0006, encoded once): Linux
	# bubblewrap omits the binary from the curated mounts (absent from PATH),
	# while the macOS Seatbelt jail leaves it *visible* but denies process-exec
	# for any path not opted in (ADR-0004 / issue 15). So PATH presence alone is
	# NOT a leak on macOS — actually running it must fail. We therefore test
	# executability, not mere presence.
	local name=$1 path out rc
	path=$(command -v -- "$name" 2>/dev/null || true)
	if [ -z "$path" ]; then
		pass no-host-bin "$name absent from the confined PATH — cannot execute"
	fi
	# Present on PATH: attempt a harmless exec (--version: no escalation, no
	# prompt). A refused exec — rc 126/127, or a sandbox/loader "operation not
	# permitted" / "permission denied" — is confined; the program actually
	# running is the leak. NB: no stdin redirect — the macOS jail denies reading
	# /dev/null (it grants write only), and a `</dev/null` would itself fail and
	# mask the result; a denied exec never runs, so there is no stdin to hang on.
	out=$("$path" --version 2>&1)
	rc=$?
	case "$rc" in
		126 | 127) pass no-host-bin "$name on PATH but exec refused (rc $rc) — confined" ;;
	esac
	case "$out" in
		*"peration not permitted"* | *"ermission denied"*)
			pass no-host-bin "$name on PATH but exec denied by the sandbox — confined" ;;
	esac
	fail no-host-bin "$name executed inside the jail (rc $rc) — host binary leaked"
}

check_violation_logged() {
	local pattern=$1 attempt out
	# Match on the denied target appearing in the violation surface. We
	# deliberately do NOT also require a "BLOCKED" literal: the surface differs
	# per platform (Linux ausearch -> BLOCKED lines; macOS proxy JSON denial
	# records) but in every case `$SLOP_LOG_CMD` emits ONLY denials, so the
	# target's presence is the signal.
	attempt=0
	while [ "$attempt" -lt "$LOG_RETRIES" ]; do
		out=$($LOG_CMD 2>/dev/null)
		if printf '%s' "$out" | grep -qF -- "$pattern"; then
			pass violation-logged "violation log records a block for $pattern"
		fi
		attempt=$((attempt + 1))
		sleep "$LOG_RETRY_DELAY"
	done
	fail violation-logged "no block for $pattern after ${LOG_RETRIES} tries — alerting path broken"
}

main() {
	[ $# -ge 2 ] || usage
	local check=$1; shift
	case "$check" in
		net-allow)        check_net_allow "$@" ;;
		net-deny)         check_net_deny "$@" ;;
		net-deny-raw)     check_net_deny_raw "$@" ;;
		net-deny-udp)     check_net_deny_udp "$@" ;;
		path-hidden)      check_path_hidden "$@" ;;
		path-rw)          check_path_rw "$@" ;;
		no-host-bin)      check_no_host_bin "$@" ;;
		violation-logged) check_violation_logged "$@" ;;
		*)                usage ;;
	esac
}

main "$@"
