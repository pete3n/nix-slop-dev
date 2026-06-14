# The darwin `sandboxed` wrapper (issue 08 rewritten against ADR-0003).
#
# Spawns the sandbox-proxy on a kernel-picked loopback port, substitutes
# that port into the Seatbelt profile template, then execs the target
# command under `sandbox-exec -f <profile>` with HTTPS_PROXY / HTTP_PROXY
# / ALL_PROXY pointed at the proxy. The proxy enforces the Host Whitelist
# (Linux's mechanism is systemd IPAddressAllow on resolved IPs; ADR-0003
# replaces that with hostname-level proxy enforcement).
#
# CLI parity with Linux's packages/sandboxed: -q, -a, -e, --wl-add,
# --wl-del, --wl-list. --log is wired in issue 09.
#
# Issue 11: optional `jail` parameter. When non-null and carrying `.jailData`
# (produced by `lib/jail/default.nix`'s `jail` constructor), the wrapper bakes
# the merged Sandbox+Jail SBPL profile into a single sandbox-exec invocation
# per ADR-0001 line 17-23 (no nested sandbox-exec). Templates instantiate one
# wrapper per jail via `pkgs.callPackage ./sandboxed-darwin { jail = …; }`.
# When null (the default), the wrapper produces the network-only build,
# byte-for-byte identical to the pre-issue-11 shape.
#
# Issue 12 prerequisite: `binName` lets templates name per-jail wrappers
# distinctly so two builds (jailed-claude + jailed-shell) coexist on PATH.
# Default preserves the network-only contract: the wrapper is `sandboxed`.
{
  pkgs,
  lib,
  sandbox-proxy,
  stateDir ? ".local/state/sandboxed",
  jail ? null,
  binName ? "sandboxed",
}:
let
  render = import ./render.nix { inherit lib; };
  sbplTemplate = pkgs.writeText "sandbox-profile.sbpl.tmpl"
    (render.combinedSbplTemplate { inherit jail; });
in
pkgs.writeShellScriptBin binName # bash
  ''
    set -eu

    sbpl_template="${sbplTemplate}"
    proxy_bin="${sandbox-proxy}/bin/sandbox-proxy"

    state_dir="''${HOME}/${stateDir}"
    wl_dir="''${state_dir}"
    wl_file="''${wl_dir}/whitelist"
    log_dir="''${state_dir}/logs"
    quiet=0
    allow_hosts=()
    env_fwd=()

    _usage() {
    	printf >&2 '%s\n' \
    		"Usage: sandboxed [-q] [-a <host>]... [-e <var>]... <command> [args...]" \
    		"       sandboxed --wl-add <hostname|ip|cidr> ..." \
    		"       sandboxed --wl-del <hostname|ip|cidr> ..." \
    		"       sandboxed --wl-list" \
    		"       sandboxed --log [key-prefix] [since]" \
    		"" \
    		"Options:" \
    		"  -q, --quiet          Suppress startup messages and violation alerts" \
    		"  -a, --allow <host>   Allow connections to <host> (repeatable)" \
    		"  -e, --env <var>      Forward environment variable into the sandbox" \
    		"" \
    		"Subcommands:" \
    		"  --wl-add   Append to persistent whitelist (next session on darwin —" \
    		"             the running proxy reads its allowlist at startup)" \
    		"  --wl-del   Remove from persistent whitelist (next session)" \
    		"  --wl-list  Print current whitelist" \
    		"  --log      Show past sandbox violations (proxy denials + Seatbelt" \
    		"             unified-log entries). [since] default: 1 hour ago"
    	exit 1
    }

    _strip_host() {
    	# Strip URL scheme/path/port to bare hostname.
    	local entry="$1"
    	case "$entry" in
    		*://*)
    			entry="''${entry#*://}"
    			entry="''${entry%%/*}"
    			entry="''${entry%%:*}"
    			;;
    	esac
    	printf '%s' "$entry"
    }

    _wl_add() {
    	if [ $# -eq 0 ]; then
    		printf >&2 'Usage: sandboxed --wl-add <hostname|ip|cidr> ...\n'
    		exit 1
    	fi
    	mkdir -p "$wl_dir"
    	local entry
    	for entry in "$@"; do
    		entry="$(_strip_host "$entry")"
    		if [ -f "$wl_file" ] \
    			&& ${pkgs.gnugrep}/bin/grep -qxF "$entry" "$wl_file"; then
    			printf 'sandboxed: %s already in whitelist\n' "$entry" >&2
    			continue
    		fi
    		printf '%s\n' "$entry" >> "$wl_file"
    		printf 'sandboxed: allowed %s (next session)\n' "$entry" >&2
    	done
    	exit 0
    }

    _wl_del() {
    	if [ $# -eq 0 ]; then
    		printf >&2 'Usage: sandboxed --wl-del <hostname|ip|cidr> ...\n'
    		exit 1
    	fi
    	if [ ! -f "$wl_file" ]; then
    		printf >&2 'sandboxed: no whitelist file\n'
    		exit 1
    	fi
    	local entry escaped
    	for entry in "$@"; do
    		if ${pkgs.gnugrep}/bin/grep -qxF "$entry" "$wl_file"; then
    			escaped=$(printf '%s' "$entry" \
    				| ${pkgs.gnused}/bin/sed 's/[.[\*^$/]/\\&/g')
    			${pkgs.gnused}/bin/sed -i.bak \
    				"/^''${escaped}$/d" "$wl_file"
    			rm -f "''${wl_file}.bak"
    			printf 'sandboxed: removed %s (next session)\n' "$entry" >&2
    		else
    			printf 'sandboxed: %s not in whitelist\n' "$entry" >&2
    		fi
    	done
    	exit 0
    }

    _wl_list() {
    	if [ -f "$wl_file" ]; then
    		cat "$wl_file"
    	else
    		printf >&2 'No whitelist file set.\n'
    	fi
    	exit 0
    }

    _log() {
    	# Two complementary sources per ADR-0003 / spike 09:
    	#   src=proxy    — JSON-Lines records in $log_dir/<audit_key>.log,
    	#                  written by sandbox-proxy. Carries the destination
    	#                  hostname (Seatbelt can't see it). Per-attempt.
    	#   src=seatbelt — kernel unified-log entries with
    	#                  subsystem=com.apple.sandbox.reporting. Carries
    	#                  comm and pid (proxy can't see those). Deduped
    	#                  for adjacent identical denials.
    	# Output is one line per violation, sorted by time. Designed for
    	# grep/awk consumption; the live watcher (slice 6) renders the
    	# boxed visual.
    	local key_prefix="''${1:-}"
    	local since="''${2:-}"

    	# log show --start expects local time YYYY-MM-DD HH:MM:SS (spike 09).
    	# Default window: 1 hour ago. pkgs.coreutils on darwin is GNU, so
    	# we use GNU date's --date syntax (BSD `date -v-1H` would need
    	# /bin/date, but we already depend on coreutils elsewhere).
    	if [ -z "$since" ]; then
    		since="$(${pkgs.coreutils}/bin/date --date='1 hour ago' '+%Y-%m-%d %H:%M:%S')"
    	fi

    	# Build a single TIME<TAB>FORMATTED stream so the two sources can be
    	# merged and sorted by ISO time.
    	{
    		# Proxy entries (filtered by key prefix if given).
    		local pattern
    		if [ -n "$key_prefix" ]; then
    			pattern="''${log_dir}/''${key_prefix}*.log"
    		else
    			pattern="''${log_dir}/sandbox-*.log"
    		fi
    		# shellcheck disable=SC2086
    		for _f in $pattern; do
    			[ -f "$_f" ] || continue
    			# Each .log file has a startup "listening on" line followed
    			# by JSON denial records — filter to lines starting with '{'.
    			${pkgs.gnugrep}/bin/grep '^{' "$_f" 2>/dev/null \
    				| ${pkgs.jq}/bin/jq -r '
    					.time + "\t" +
    					"BLOCKED " + .time +
    					" src=" + .src +
    					" key=" + .key +
    					" protocol=" + .protocol +
    					" dest=" + .host + ":" + .port +
    					" comm=- pid=-" +
    					" reason=\"" + .reason + "\""'
    		done

    		# Seatbelt entries: parse `Sandbox: <comm>(<pid>) deny(<n>) <op> <details>`.
    		# Predicate is scoped to network-outbound denies with a remote:
    		# destination — that's the only thing our SBPL profile denies, so
    		# anything else in the unified log is Apple's app-sandbox noise
    		# from other processes and irrelevant to this wrapper's sessions.
    		# Time conversion: `log show` emits `YYYY-MM-DD HH:MM:SS.ffffff-ZZZZ`
    		# in LOCAL time (spike 09); we strip fractional + zone to keep the
    		# sort key uniform with the proxy's RFC3339 UTC. The two clocks
    		# diverge by the local UTC offset — accept that for now; the per-
    		# session correlation comes from the audit key, not the timestamp.
    		/usr/bin/log show \
    			--start "$since" \
    			--predicate 'subsystem == "com.apple.sandbox.reporting" AND eventMessage CONTAINS "deny(1) network-outbound remote:"' \
    			--info \
    			2>/dev/null \
    		| ${pkgs.gawk}/bin/awk '
    			/Sandbox:.*deny\(/ {
    				_time = $1 "T" $2
    				sub(/\..*/, "", _time)
    				# Strip `Sandbox: ` then parse `<comm>(<pid>) deny(N) <op> <rest>`.
    				match($0, /Sandbox: ([^(]+)\(([0-9]+)\) deny\([0-9]+\) ([^ ]+) (.*)$/, m)
    				_comm = m[1]; _pid = m[2]; _op = m[3]; _rest = m[4]
    				if (_comm == "") next
    				# network-outbound details are `remote:*:port`. Spike 09:
    				# destination host is NOT in the kernel record — `?` it.
    				_port = "-"
    				if (match(_rest, /remote:\*:([0-9]+)/, p)) {
    					_port = p[1]
    				}
    				printf "%s\tBLOCKED %s src=seatbelt key=- protocol=%s dest=?:%s comm=%s pid=%s reason=\"%s %s\"\n", \
    					_time, _time, _op, _port, _comm, _pid, _op, _rest
    			}
    		'
    	} \
    		| ${pkgs.coreutils}/bin/sort \
    		| ${pkgs.gnused}/bin/sed 's/^[^\t]*\t//'
    	exit 0
    }

    # Per-invocation state (filled by main flow below)
    tmp_dir=""
    proxy_pid=""
    child_pid=""
    watcher_proxy_pid=""
    watcher_seatbelt_pid=""

    _cleanup() {
    	# Kill the sandbox-exec child first so it doesn't outlive the
    	# proxy and start failing connects mid-teardown.
    	if [ -n "''${child_pid:-}" ] && kill -0 "$child_pid" 2>/dev/null; then
    		kill -TERM "$child_pid" 2>/dev/null || true
    	fi
    	# Jail cleanup runs in REVERSE of combinator merge order (LIFO),
    	# right after the jailed process is dead so the snippets see a
    	# quiescent host filesystem. The canonical case is `write-text`
    	# inside a `tmpfs` — file rm-f before parent rm-rf. The block is
    	# empty in network-only mode and for jails whose combinators
    	# contributed no cleanup (set-env, ro-bind, time-zone, …).
    	${render.mkCleanupBlock { inherit jail; }}
    	# Stop the live watchers (slice 6) before tearing down the proxy,
    	# otherwise tail -f sees the log directory disappear and prints
    	# its own error to the user's terminal.
    	if [ -n "''${watcher_proxy_pid:-}" ] && kill -0 "$watcher_proxy_pid" 2>/dev/null; then
    		kill -TERM "$watcher_proxy_pid" 2>/dev/null || true
    	fi
    	if [ -n "''${watcher_seatbelt_pid:-}" ] && kill -0 "$watcher_seatbelt_pid" 2>/dev/null; then
    		kill -TERM "$watcher_seatbelt_pid" 2>/dev/null || true
    	fi
    	if [ -n "''${proxy_pid:-}" ] && kill -0 "$proxy_pid" 2>/dev/null; then
    		kill -TERM "$proxy_pid" 2>/dev/null || true
    		sleep 0.2
    		kill -KILL "$proxy_pid" 2>/dev/null || true
    	fi
    	if [ -n "''${tmp_dir:-}" ] && [ -d "$tmp_dir" ]; then
    		rm -rf "$tmp_dir"
    	fi
    }

    # Forward TTY-independent signals to the child sandbox-exec so a
    # programmatic SIGTERM/SIGINT to the wrapper doesn't orphan it.
    # (For interactive TTY use the signal also reaches the child via the
    # foreground process group; this handler is the belt-and-braces path.)
    _signal_child() {
    	if [ -n "''${child_pid:-}" ] && kill -0 "$child_pid" 2>/dev/null; then
    		kill -TERM "$child_pid" 2>/dev/null || true
    	fi
    }

    while [ $# -gt 0 ]; do
    	case "''${1}" in
    		--help|-h)
    			_usage
    			;;
    		--wl-add)
    			shift
    			_wl_add "$@"
    			;;
    		--wl-del)
    			shift
    			_wl_del "$@"
    			;;
    		--wl-list)
    			_wl_list
    			;;
    		--log)
    			shift
    			_log "$@"
    			;;
    		-q|--quiet)
    			quiet=1
    			shift
    			;;
    		-a|--allow)
    			if [ -z "''${2:-}" ]; then
    				printf >&2 'sandboxed: --allow requires a hostname argument\n'
    				exit 1
    			fi
    			allow_hosts+=("$(_strip_host "''${2}")")
    			shift 2
    			;;
    		-e|--env)
    			if [ -z "''${2:-}" ]; then
    				printf >&2 'sandboxed: --env requires a variable name\n'
    				exit 1
    			fi
    			env_fwd+=("''${2}")
    			shift 2
    			;;
    		--)
    			# End-of-options terminator. macOS `/usr/bin/env -i` does
    			# not understand `--`, so we must consume it here rather
    			# than letting it leak into the exec args.
    			shift
    			break
    			;;
    		*)
    			break
    			;;
    	esac
    done

    ${lib.optionalString (jail == null) ''
      if [ $# -eq 0 ]; then
      	_usage
      fi
    ''}
    # Per-session audit key mirrors the Linux wrapper's
    # sandbox-<binary>-<timestamp> shape so issue 09's --log subcommand
    # can correlate proxy JSON entries with Seatbelt unified-log entries
    # (kernel logs the comm, the proxy logs the host; the audit key joins
    # them). In jail mode the binary name is baked in at Nix-eval (the
    # wrapper is per-jail) so `$1` is no longer the command — it's an
    # argument to mainBin.
    ${if jail != null && jail ? jailData then ''
      binary="${baseNameOf jail.jailData.mainBin}"
    '' else ''
      binary="$(${pkgs.coreutils}/bin/basename "$1")"
    ''}stamp="$(${pkgs.coreutils}/bin/date '+%Y%m%d-%H%M%S')"
    audit_key="sandbox-''${binary}-''${stamp}"

    # Build per-invocation whitelist file: persistent entries + -a hosts.
    tmp_dir="$(${pkgs.coreutils}/bin/mktemp -d -t sandboxed.XXXXXX)"
    wl_runtime="''${tmp_dir}/whitelist"
    : > "$wl_runtime"
    if [ -f "$wl_file" ]; then
    	cat "$wl_file" >> "$wl_runtime"
    fi
    for _host in ''${allow_hosts[@]+"''${allow_hosts[@]}"}; do
    	printf '%s\n' "$_host" >> "$wl_runtime"
    done

    # Issue 16: partition wl_runtime into IPv4 literals (→ _ip_block_file,
    # spliced into the SBPL profile so ICMP / arbitrary L4 to the IP works
    # directly via Seatbelt, matching Linux IPAddressAllow semantics) vs
    # everything else (hostnames + CIDR + IPv6 — stay in wl_runtime for
    # the proxy to handle TCP/SOCKS only). CIDR and IPv6 are deferred to
    # follow-ups; see render.mkIpAllowListBlock for the rationale.
    _ip_block_file="''${tmp_dir}/ipallows.sbpl"
    ${render.mkIpAllowListBlock { }}
    # Spawn the proxy on a kernel-picked loopback port. Read the assigned
    # address back from its stderr (main.go prints `listening on 127.0.0.1:<port>`).
    # The proxy's stderr is the canonical issue-09 log: one JSON record per
    # refused outbound, plus a startup `listening on` line we grep for.
    # Persist it under $log_dir/<audit_key>.log so --log can read past
    # sessions; the tmpdir is still cleaned up on exit but the log isn't.
    ${pkgs.coreutils}/bin/mkdir -p "$log_dir"
    proxy_log="''${log_dir}/''${audit_key}.log"
    "$proxy_bin" --listen 127.0.0.1:0 --whitelist "$wl_runtime" \
    	--key "$audit_key" \
    	2>"$proxy_log" &
    proxy_pid=$!

    trap _cleanup EXIT INT TERM

    # Poll for the listen line, bail if the proxy dies first.
    _proxy_addr=""
    for _i in $(seq 1 50); do
    	if ${pkgs.gnugrep}/bin/grep -q 'listening on' "$proxy_log" 2>/dev/null; then
    		_proxy_addr=$(${pkgs.gnugrep}/bin/grep 'listening on' "$proxy_log" \
    			| ${pkgs.gnused}/bin/sed -n 's/.*listening on //p' \
    			| ${pkgs.coreutils}/bin/head -1)
    		break
    	fi
    	if ! kill -0 "$proxy_pid" 2>/dev/null; then
    		printf >&2 'sandboxed: proxy failed to start\n'
    		cat "$proxy_log" >&2
    		exit 1
    	fi
    	sleep 0.1
    done
    if [ -z "$_proxy_addr" ]; then
    	printf >&2 'sandboxed: proxy did not announce a listening address within 5s\n'
    	exit 1
    fi
    _proxy_port="''${_proxy_addr##*:}"

    # Substitute the proxy port (and, in jail mode, the __JAIL_*
    # placeholders emitted by the Jail combinator library) into the SBPL
    # template. `realpath -s` resolves any symlinks in $PWD to the kernel-
    # canonical form sandbox-exec applies SBPL rules against (spike 10 F1
    # — /tmp → /private/tmp etc.). $HOME is forwarded verbatim because
    # macOS home directories never live under /tmp, /var, or /etc.
    profile_file="''${tmp_dir}/sandbox.sbpl"
    ${lib.optionalString (jail != null && jail ? jailData) ''
      _jail_cwd="$(${pkgs.coreutils}/bin/realpath -s "$PWD")"
    ''}${render.mkHostResolveResolutionBlock {
      inherit jail;
      readlinkBin = "${pkgs.coreutils}/bin/readlink";
    }}${pkgs.gnused}/bin/sed ${render.mkProfileSedPipeline { inherit jail; }} \
    	"$sbpl_template" > "$profile_file"

    if [ "$quiet" -eq 0 ]; then
    	printf >&2 'sandboxed: [%s] proxy on %s, profile %s\n' \
    		"$audit_key" "$_proxy_addr" "$profile_file"
    fi

    # Jail preflight: materialise the host filesystem state the merged Jail
    # profile depends on (combinator-emitted `mkdir -p` / `ln -sfn` lines —
    # ro-bind/rw-bind dst-symlinks, tmpfs directories, write-text store
    # symlinks). `set -eu` is in effect, so any preflight failure aborts the
    # wrapper and the EXIT trap (_cleanup) tears down the proxy + tmpdir.
    # Block is empty when no jail or when no combinator contributed
    # preflight (e.g., a jail of just set-env calls).
    ${render.mkPreflightBlock { inherit jail; }}
    # Live violation watchers (slice 6 / issue 09 acceptance criterion:
    # "A blocked connection attempt during a running session produces a
    # real-time alert in the same visual format as Linux"). -q suppresses
    # both watchers and the startup line above. Two sources per ADR-0003:
    #   - proxy: tail -f the JSON-Lines log (per-session, host known)
    #   - seatbelt: log stream the unified log scoped to
    #     network-outbound denies (system-wide; the only thing our SBPL
    #     denies, so cross-session noise is minimal)
    # Both render Linux's ╔══ SANDBOX VIOLATION ══╗ box to stderr.
    if [ "$quiet" -eq 0 ]; then
    	(
    		# Wait for the log file to grow past the startup line, then stream
    		# JSON denials only.
    		${pkgs.coreutils}/bin/tail -n0 -F "$proxy_log" 2>/dev/null \
    			| while IFS= read -r _line; do
    				case "$_line" in
    					"{"*) ;;
    					*) continue ;;
    				esac
    				printf '%s' "$_line" \
    					| ${pkgs.jq}/bin/jq -r '
    						"\r\n[1;31m╔══ SANDBOX VIOLATION ══════════════════════════════════════╗[0m\r\n" +
    						"[1;31m║[0m  key:    " + .key + "\r\n" +
    						"[1;31m║[0m  time:   " + .time + "\r\n" +
    						"[1;31m║[0m  src:    proxy (" + .protocol + ")\r\n" +
    						"[1;31m║[0m  dest:   " + .host + ":" + .port + "\r\n" +
    						"[1;31m║[0m  reason: " + .reason + "\r\n" +
    						"[1;31m╚═══════════════════════════════════════════════════════════╝[0m\r\n"' \
    					>&2 || true
    			done
    	) &
    	watcher_proxy_pid=$!

    	(
    		# Spike 09: real-time stream needs --type log AND both --info
    		# --debug — without --debug the kernel Error rows are filtered
    		# out of the default stream view. Also: `subsystem ==
    		# com.apple.sandbox.reporting` matches in `log show` (added
    		# during aggregation) but NOT in `log stream` (kernel logs
    		# don't carry that subsystem field at emit time). So the live
    		# stream predicate filters by process+eventMessage instead.
    		/usr/bin/log stream \
    			--type log \
    			--predicate 'process == "kernel" AND eventMessage CONTAINS "deny(1) network-outbound remote:"' \
    			--info --debug \
    			2>/dev/null \
    		| ${pkgs.gawk}/bin/awk -v key="$audit_key" '
    			/Sandbox:.*deny\(/ {
    				_time = $1 " " $2
    				sub(/\..*/, "", _time)
    				if (match($0, /Sandbox: ([^(]+)\(([0-9]+)\) deny\([0-9]+\) ([^ ]+) (.*)$/, m) == 0) next
    				_comm = m[1]; _pid = m[2]; _op = m[3]; _rest = m[4]
    				_port = "-"
    				if (match(_rest, /remote:\*:([0-9]+)/, p)) _port = p[1]
    				printf "\r\n\033[1;31m╔══ SANDBOX VIOLATION ══════════════════════════════════════╗\033[0m\r\n"
    				printf "\033[1;31m║\033[0m  key:    %s\r\n", key
    				printf "\033[1;31m║\033[0m  time:   %s\r\n", _time
    				printf "\033[1;31m║\033[0m  src:    seatbelt (%s)\r\n", _op
    				printf "\033[1;31m║\033[0m  proc:   %s (pid %s)\r\n", _comm, _pid
    				printf "\033[1;31m║\033[0m  dest:   ?:%s\r\n", _port
    				printf "\033[1;31m║\033[0m  reason: %s\r\n", _rest
    				printf "\033[1;31m╚═══════════════════════════════════════════════════════════╝\033[0m\r\n"
    				fflush("")
    			}
    		' >&2
    	) &
    	watcher_seatbelt_pid=$!
    fi

    # Forward -e <var> values explicitly. HOME, USER, PATH, TERM are always
    # forwarded since most CLI tools need them. In jail mode PATH is prefixed
    # with `jailData.binPaths` (add-pkg-deps contributions) so jail-supplied
    # binaries shadow whatever was inherited from the wrapper's $PATH.
    _env_args=(
    	"HOME=''${HOME}"
    	"USER=''${USER}"
    	"PATH=${render.mkJailPathPrefix { inherit jail; }}''${PATH}"
    	"TERM=''${TERM:-xterm-256color}"
    	"HTTPS_PROXY=http://''${_proxy_addr}"
    	"HTTP_PROXY=http://''${_proxy_addr}"
    	"ALL_PROXY=socks5h://''${_proxy_addr}"
    )
    for _var in ''${env_fwd[@]+"''${env_fwd[@]}"}; do
    	_val="''${!_var:-}"
    	if [ -n "$_val" ]; then
    		_env_args+=("''${_var}=''${_val}")
    	fi
    done
    # Jail env: unconditional set-env contributions followed by the
    # conditional try-fwd-env forward-if-set loop. Empty in network-only
    # mode and for jails with no env / envForward combinators.
    ${render.mkJailEnvBlock { inherit jail; }}

    # Run sandbox-exec as a FOREGROUND child (not via `exec` — exec would
    # replace the wrapper process and orphan the proxy on every
    # invocation; the EXIT trap below tears down the proxy + tmpdir on
    # this script's natural exit).
    #
    # Foreground (no `&`) is required for interactive use: bash without
    # job control redirects backgrounded commands' stdin to /dev/null,
    # which makes an interactive shell inside the sandbox see a non-TTY
    # stdin and exit immediately on startup. Foreground keeps the
    # controlling TTY connected; INT/TERM propagate to the child via the
    # process group (no explicit signal forwarder needed).
    set +e
    /usr/bin/sandbox-exec -f "$profile_file" \
    	/usr/bin/env -i "''${_env_args[@]}" ${render.mkExecCommand { inherit jail; }}
    exit_code=$?
    set -e
    exit "$exit_code"
  ''
