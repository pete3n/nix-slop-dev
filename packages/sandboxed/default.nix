{
  pkgs,
  # Path relative to $HOME for persistent whitelist state.
  # $HOME is resolved at runtime by the script.
  stateDir ? ".local/state/sandboxed",
}:
pkgs.writeShellScriptBin "sandboxed" # sh
  ''
    set -eu

    BINARY=""
    STAMP=""
    AUDIT_KEY=""
    UNIT=""
    WL_DIR="''${HOME}/${stateDir}"
    WL_FILE="''${WL_DIR}/whitelist"
    wl_entry=""
    quiet=0
    allow_hosts=()
    allow_props=""
    allowed_re=""
    env_fwd=()
    watch_pid=""

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
    	"  -a, --allow <host>   Allow connections to <host> (resolved at startup," \
    	"                       repeatable for multiple hosts)" \
    	"  -e, --env <var>      Forward environment variable into the sandbox" \
    	"" \
    	"Subcommands:" \
    	"  --wl-add   Add to persistent whitelist (updates running sandboxes)" \
    	"  --wl-del   Remove from persistent whitelist (next session)" \
    	"  --wl-list  Show current whitelist" \
    	"  --log      Search audit log for sandbox violations"
    	exit 1
    }

    _wl_add() {
    	if [ $# -eq 0 ]; then
    		printf >&2 'Usage: sandboxed --wl-add <hostname|ip|cidr> ...\n'
    		exit 1
    	fi
    	mkdir -p "$WL_DIR"
    	for wl_entry in "$@"; do
    		case "$wl_entry" in
    			*://*)
    				wl_entry="''${wl_entry#*://}"
    				wl_entry="''${wl_entry%%/*}"
    				wl_entry="''${wl_entry%%:*}"
    				;;
    		esac
    		if ${pkgs.gnugrep}/bin/grep -qxF "$wl_entry" "$WL_FILE" 2>/dev/null; then
    			printf 'sandboxed: %s already in whitelist\n' "$wl_entry" >&2
    			continue
    		fi

    		_ips=""
    		case "$wl_entry" in
    			*/*) _ips="$wl_entry" ;;
    			*:*) _ips="''${wl_entry}/128" ;;
    			[0-9]*.[0-9]*.[0-9]*.[0-9]*) _ips="''${wl_entry}/32" ;;
    			*)
    				_ips=$({
    					getent ahosts "$wl_entry" 2>/dev/null \
    						| ${pkgs.gawk}/bin/awk '{print $1}'
    					${pkgs.dnsutils}/bin/dig +short A "$wl_entry" 2>/dev/null
    					${pkgs.dnsutils}/bin/dig +short AAAA "$wl_entry" 2>/dev/null
    				} | ${pkgs.coreutils}/bin/sort -u)
    				;;
    		esac

    		if [ -z "$_ips" ]; then
    			printf >&2 'sandboxed: failed to resolve %s\n' "$wl_entry"
    			continue
    		fi

    		_updated=0
    		while IFS= read -r _unit; do
    			[ -z "$_unit" ] && continue
    			while IFS= read -r _ip; do
    				[ -z "$_ip" ] && continue
    				case "$_ip" in
    					*/*) sudo ${pkgs.systemd}/bin/systemctl set-property "$_unit" IPAddressAllow="''${_ip}" ;;
    					*:*) sudo ${pkgs.systemd}/bin/systemctl set-property "$_unit" IPAddressAllow="''${_ip}/128" ;;
    					*)   sudo ${pkgs.systemd}/bin/systemctl set-property "$_unit" IPAddressAllow="''${_ip}/32" ;;
    				esac
    			done <<< "$_ips"
    			_updated=$((_updated + 1))
    		done < <(${pkgs.systemd}/bin/systemctl list-units \
    			--type=service --state=running --no-legend \
    			| ${pkgs.gnugrep}/bin/grep 'sandbox-' \
    			| ${pkgs.gawk}/bin/awk '{print $1}')

    		printf '%s\n' "$wl_entry" >> "$WL_FILE"

    		if [ "$_updated" -gt 0 ]; then
    			printf 'sandboxed: allowed %s (%d running sandboxes updated)\n' "$wl_entry" "$_updated" >&2
    		else
    			printf 'sandboxed: allowed %s (next session)\n' "$wl_entry" >&2
    		fi
    	done
    	exit 0
    }

    _wl_del() {
    	if [ $# -eq 0 ]; then
    		printf >&2 'Usage: sandboxed --wl-del <hostname|ip|cidr> ...\n'
    		exit 1
    	fi
    	if [ ! -f "$WL_FILE" ]; then
    		printf >&2 'sandboxed: no whitelist file\n'
    		exit 1
    	fi
    	for wl_entry in "$@"; do
    		if ${pkgs.gnugrep}/bin/grep -qxF "$wl_entry" "$WL_FILE"; then
    			${pkgs.gnused}/bin/sed -i \
    				"/^$(printf '%s' "$wl_entry" \
    				| ${pkgs.gnused}/bin/sed 's/[.[\*^$/]/\\&/g')$/d" \
    				"$WL_FILE"
    			printf 'sandboxed: removed %s (next session)\n' "$wl_entry" >&2
    		else
    			printf 'sandboxed: %s not in whitelist\n' "$wl_entry" >&2
    		fi
    	done
    	exit 0
    }

    _sandbox_log() {
    	_key="''${1:-sandbox-}"
    	_since="''${2:-today}"
    	sudo ${pkgs.audit}/bin/ausearch \
    		-k "$_key" \
    		--start "$_since" \
    		--raw \
    		2>/dev/null \
    	| ${pkgs.gawk}/bin/awk '
    		function emit(    _dst, _port) {
    			if (_evt_exe == "") return
    			if (_evt_exit != "-115" && _evt_exit != "-111") return
    			if (_evt_exe !~ /^\/nix\/store\//) return
    			if (_evt_saddr != "" && _evt_saddr ~ /laddr=127\.|laddr=::1|saddr_fam=local/) return
    			if (_evt_key !~ /^sandbox-[^-]+-[0-9]{8}-[0-9]{6}$/) return

    			if (_evt_saddr != "") {
    				_dst  = _evt_saddr; gsub(/.*laddr=/, "", _dst);  gsub(/ .*/,      "", _dst)
    				_port = _evt_saddr; gsub(/.*lport=/, "", _port); gsub(/[^0-9].*/, "", _port)
    			} else {
    				_dst = "unknown"; _port = "?"
    			}

    			printf "BLOCKED  %s\n  key=%s\n  pid=%-7s  comm=%s\n  dest=%s:%s\n  exe=%s\n\n",
    				_evt_time, _evt_key, _evt_pid, _evt_comm, _dst, _port, _evt_exe
    		}

    		/type=SYSCALL/ {
    			emit()
    			_evt_exe=""; _evt_comm=""; _evt_pid=""
    			_evt_exit=""; _evt_saddr=""; _evt_time=""; _evt_key=""
    			match($0, /msg=audit\(([^)]+)\)/, m); _evt_time = m[1]
    			match($0, /exit=([^ ]+)/,         m); _evt_exit = m[1]
    			match($0, /pid=([^ ]+)/,           m); _evt_pid  = m[1]
    			match($0, /comm="([^"]+)"/,        m); _evt_comm = m[1]
    			match($0, /exe="([^"]+)"/,         m); _evt_exe  = m[1]
    			match($0, /key="([^"]+)"/,         m); _evt_key  = m[1]
    		}
    		/type=SOCKADDR/ {
    			match($0, /SADDR=\{([^}]+)\}/, m); _evt_saddr = m[1]
    		}
    		END { emit() }
    	'
    	exit 0
    }

    _set_whitelist() {
    	if [ -f "$WL_FILE" ]; then
    		while IFS= read -r wl_entry; do
    			[ -z "$wl_entry" ] && continue
    			case "$wl_entry" in "#"*) continue ;; esac
    			allow_hosts+=("$wl_entry")
    		done < "$WL_FILE"
    	fi

    	for _host in ''${allow_hosts[@]+"''${allow_hosts[@]}"}; do
    		case "$_host" in
    			*://*)
    				_host="''${_host#*://}"
    				_host="''${_host%%/*}"
    				_host="''${_host%%:*}"
    				;;
    		esac

    		case "$_host" in
    			*/*)
    				allow_props="''${allow_props} --property=IPAddressAllow=''${_host}"
    				;;
    			*:*)
    				allow_props="''${allow_props} --property=IPAddressAllow=''${_host}/128"
    				;;
    			[0-9]*.[0-9]*.[0-9]*.[0-9]*)
    				allow_props="''${allow_props} --property=IPAddressAllow=''${_host}/32"
    				;;
    			*)
    				while IFS= read -r _ip; do
    					[ -z "$_ip" ] && continue
    					case "$_ip" in
    						*:*) allow_props="''${allow_props} --property=IPAddressAllow=''${_ip}/128" ;;
    						*)   allow_props="''${allow_props} --property=IPAddressAllow=''${_ip}/32" ;;
    					esac
    				done < <({
    					getent ahosts "$_host" 2>/dev/null \
    						| ${pkgs.gawk}/bin/awk '{print $1}'
    					${pkgs.dnsutils}/bin/dig +short A "$_host" 2>/dev/null
    					${pkgs.dnsutils}/bin/dig +short AAAA "$_host" 2>/dev/null
    				} | ${pkgs.coreutils}/bin/sort -u)
    				;;
    		esac
    		if [ "$quiet" -eq 0 ]; then
    			printf 'sandboxed: allowed %s\n' "$_host" >&2
    		fi
    	done
    }

    _cleanup() {
    	sudo ${pkgs.audit}/bin/auditctl \
    		-d always,exit -F arch=b64 -S connect \
    		-F uid="$(id -u)" -F auid=-1 \
    		-F key="''${AUDIT_KEY}" 2>/dev/null || true
    	sudo ${pkgs.audit}/bin/auditctl \
    		-d always,exit -F arch=b32 -S connect \
    		-F uid="$(id -u)" -F auid=-1 \
    		-F key="''${AUDIT_KEY}" 2>/dev/null || true
    	[ -n "''${watch_pid:-}" ] && kill "''${watch_pid}" 2>/dev/null || true
    }

    while [ $# -gt 0 ]; do
    	case "''${1}" in
    	--wl-add)
    		shift
    		_wl_add "$@"
    		;;
    	--wl-del)
    		shift
    		_wl_del "$@"
    		;;
    	--wl-list)
    		if [ -f "$WL_FILE" ]; then
    			cat "$WL_FILE"
    		else
    			printf >&2 'No whitelist file set.\n'
    		fi
    		exit 0
    		;;
    	--log)
    		shift
    		_sandbox_log "$@"
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
    		allow_hosts+=("''${2}")
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
    	*)
    		break
    		;;
    	esac
    done

    if [ $# -eq 0 ]; then
    	_usage
    fi

    BINARY="$(basename "$1")"
    STAMP="$(date +%Y%m%d-%H%M%S)"
    AUDIT_KEY="sandbox-''${BINARY}-''${STAMP}"
    UNIT="''${AUDIT_KEY}-$$"

    _set_whitelist

    allowed_re="laddr=127\\\\.|laddr=::1|saddr_fam=local"
    for _prop in ''${allow_props}; do
    	case "$_prop" in
    		--property=IPAddressAllow=*)
    			_ip="''${_prop#--property=IPAddressAllow=}"
    			_ip="''${_ip%/*}"
    			_escaped=$(printf '%s' "$_ip" | ${pkgs.gnused}/bin/sed 's/[.]/\\./g')
    			allowed_re="''${allowed_re}|laddr=''${_escaped}"
    			;;
    	esac
    done

    env_vars=""
    for _var in ''${env_fwd[@]+"''${env_fwd[@]}"}; do
    	_val="''${!_var:-}"
    	if [ -n "$_val" ]; then
    		env_vars="''${env_vars} --property=Environment=''${_var}=''${_val}"
    	fi
    done

    sudo ${pkgs.audit}/bin/auditctl -l 2>/dev/null \
    	| ${pkgs.gnugrep}/bin/grep 'key=sandbox-' \
    	| while IFS= read -r _rule; do
    		sudo ${pkgs.audit}/bin/auditctl -d "''${_rule#-a }" 2>/dev/null || true
    	done

    sudo ${pkgs.audit}/bin/auditctl \
    	-a always,exit -F arch=b64 -S connect \
    	-F uid="$(id -u)" -F auid=4294967295 \
    	-k "''${AUDIT_KEY}"
    sudo ${pkgs.audit}/bin/auditctl \
    	-a always,exit -F arch=b32 -S connect \
    	-F uid="$(id -u)" -F auid=4294967295 \
    	-k "''${AUDIT_KEY}"

    trap _cleanup EXIT INT TERM

    watch_pid=""
    if [ "$quiet" -eq 0 ]; then
    	sudo ${pkgs.coreutils}/bin/tail -f /var/log/audit/audit.log 2>/dev/null \
    	| ${pkgs.gawk}/bin/awk \
    			-v _key="''${AUDIT_KEY}" \
    			-v _allowed_re="''${allowed_re}" \
    		'
    		function emit(    _msg) {
    			if (_evt_key != _key) return
    			if (_evt_exit != "-115" && _evt_exit != "-111") return
    			if (_evt_exe !~ /^\/nix\/store\//) return
    			if (_evt_saddr != "" && _evt_saddr ~ _allowed_re) return

    			_msg = "\r\n\033[1;31m╔══ SANDBOX VIOLATION ══════════════════════════════════════╗\033[0m\r\n" \
    						"\033[1;31m║\033[0m  key:  " _key "\r\n" \
    						"\033[1;31m║\033[0m  time: " _evt_time "\r\n" \
    						"\033[1;31m║\033[0m  proc: " _evt_comm " (pid " _evt_pid ")\r\n" \
    						"\033[1;31m║\033[0m  exe:  " _evt_exe "\r\n" \
    						"\033[1;31m╚═══════════════════════════════════════════════════════════╝\033[0m\r\n"
    			printf "%s", _msg
    			fflush("")
    		}

    		/type=SYSCALL/ {
    			emit()
    			_evt_key=""; _evt_exit=""; _evt_pid=""; _evt_comm=""
    			_evt_exe=""; _evt_saddr=""; _evt_time=""; _evt_id=""

    			match($0, /key="([^"]+)"/, m);    _evt_key  = m[1]
    			if (_evt_key != _key) next

    			match($0, /msg=audit\(([^)]+)\)/, m); _evt_time = m[1]
    			match(_evt_time, /:([0-9]+)$/,     m); _evt_id   = m[1]
    			match($0, /exit=([^ ]+)/,         m); _evt_exit = m[1]
    			match($0, /pid=([^ ]+)/,           m); _evt_pid  = m[1]
    			match($0, /comm="([^"]+)"/,        m); _evt_comm = m[1]
    			match($0, /exe="([^"]+)"/,         m); _evt_exe  = m[1]
    		}

    		/type=SOCKADDR/ {
    			if (_evt_id == "") next
    			match($0, /msg=audit\([^:]+:([0-9]+)\)/, m)
    			if (m[1] != _evt_id) next
    			match($0, /SADDR=\{([^}]+)\}/, m)
    			if (m[1] != "") _evt_saddr = m[1]
    		}

    		END { emit() }
    	' &
    	watch_pid=$!
    fi

    printf 'sandboxed: [%s] starting %s\n' "''${AUDIT_KEY}" "''${BINARY}" >&2
    sudo ${pkgs.systemd}/bin/systemd-run \
    	--pty \
    	--same-dir \
    	--wait \
    	--collect \
    	--unit="''${UNIT}" \
    	--property="User=''${USER}" \
    	--property="IPAddressDeny=any" \
    	--property="IPAddressAllow=127.0.0.0/8" \
    	--property="IPAddressAllow=::1/128" \
    	''${allow_props} \
    	''${env_vars} \
    	--property="Environment=HOME=''${HOME}" \
    	--property="Environment=USER=''${USER}" \
    	--property="Environment=PATH=''${PATH}" \
    	--property="Environment=XDG_CONFIG_HOME=''${XDG_CONFIG_HOME:-''${HOME}/.config}" \
    	--property="Environment=XDG_DATA_HOME=''${XDG_DATA_HOME:-''${HOME}/.local/share}" \
    	--property="Environment=XDG_RUNTIME_DIR=''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" \
    	--property="Environment=DISPLAY=''${DISPLAY:-}" \
    	--property="Environment=WAYLAND_DISPLAY=''${WAYLAND_DISPLAY:-}" \
    	--property="Environment=TMUX=''${TMUX:-}" \
    	--property="Environment=TMUX_PANE=''${TMUX_PANE:-}" \
    	--property="Environment=TERM=''${TERM:-xterm-256color}" \
    	-- "$@"
  ''
