#!/usr/bin/env bash
# macOS functional harness (ADR-0006).
#
# Runs the shared tests/oracle/slop-oracle.sh on a real Darwin host, where
# Seatbelt actually enforces. nixpkgs has no Darwin VM-test framework, so the
# mac runner itself is the host (no nested VM).
#
# Darwin has no sandbox-without-jail path (the per-jail wrapper merges
# Sandbox+Jail into one sandbox-exec profile), so the oracle's network checks
# run INSIDE the jail. curl is not in the default basePkgs, so we drive a
# probe-enabled jailed shell — the default jail-shell rebuilt with curl + the
# oracle on the jail PATH, exposed as functionalTests.<darwin>.probe-jail-shell.
# jail-shell forwards "$@" to the wrapper, so `jail-shell -q [-a host] -- -c
# '<script>'` runs the oracle in the real sandbox; `jail-shell --log` reaches
# the proxy/unified-log violation surface.
#
# Usage: bash ci/macos-functional.sh
#
# FIRST-RUN RISK POINTS (cannot be exercised without a real mac):
#   1. The stub is on 127.0.0.1 and curl is expected to honour the wrapper's
#      ALL_PROXY/HTTP_PROXY even for a localhost URL. If this curl build
#      auto-bypasses the proxy for localhost, net-deny will FAIL (it reaches
#      the stub directly, ignoring the whitelist) — switch the stub to the
#      runner's LAN IP (`ipconfig getifaddr en0`) and open the firewall.
#   2. net-deny-raw assumes Seatbelt allows only the proxy's loopback port,
#      not all of loopback. If all loopback is open it will (correctly) flag a
#      non-proxy egress leak.
#   3. net-deny-udp shares #2's loopback rationale: the Seatbelt profile is
#      `(deny network-outbound)` save the proxy port (ADR-0003), so UDP to the
#      echo stub must be dropped even with -a. It needs `timeout`+`dd` on the
#      jail PATH (as net-deny-raw needs `timeout`). The oracle counts a denied
#      send OR a missing echo as failed-closed, so it is robust to whether
#      Seatbelt blocks at sendto or silently drops the datagram.
#   4. Live OAuth creds-persist is NOT covered here (needs an interactive login
#      + real network to Anthropic); the eval check darwin-creds-persist-in-
#      cfgdir guards that wiring. The "no live effect on a RUNNING session"
#      half of the --wl-add quirk is also deferred (needs a backgrounded
#      session); we cover the persistence-applies-next-launch half.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

command -v python3 >/dev/null 2>&1 || { echo "::error::python3 required for the stub" >&2; exit 1; }

SYSTEM=$(nix eval --raw --impure --expr 'builtins.currentSystem')
echo "== building probe jail-shell ($SYSTEM) =="
nix build ".#functionalTests.${SYSTEM}.probe-jail-shell" -o "$REPO_ROOT/result-macos-probe"
JS="$REPO_ROOT/result-macos-probe/bin/jail-shell"

# Host-side oracle, for the UNCONFINED violation-logged check.
ORACLE_HOST="$REPO_ROOT/tests/oracle/slop-oracle.sh"
chmod +x "$ORACLE_HOST"

# Hermetic stub on loopback (see risk point 1). Serves a known token body.
STUB_IP=127.0.0.1
STUB_PORT=$(( (RANDOM % 2000) + 18000 ))
STUB_URL="http://${STUB_IP}:${STUB_PORT}/"
STUBDIR=$(mktemp -d)
echo SLOP_STUB_OK > "$STUBDIR/index.html"
python3 -m http.server "$STUB_PORT" --bind "$STUB_IP" --directory "$STUBDIR" \
  >"$STUBDIR/stub.log" 2>&1 &
STUB_PID=$!

# UDP echo stub on the same loopback IP, different port. The Seatbelt profile
# denies all network-outbound except the proxy's localhost port (ADR-0003), so
# a UDP datagram to this port must be dropped inside the jail; bouncing the
# payload back lets the oracle tell "dropped" (no reply) from "escaped".
UDP_PORT=$(( (RANDOM % 2000) + 20000 ))
python3 -c "
import socket
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.bind(('${STUB_IP}', ${UDP_PORT}))
while True:
    data, addr = sock.recvfrom(65535)
    sock.sendto(data, addr)
" >"$STUBDIR/udp.log" 2>&1 &
UDP_PID=$!
trap 'kill "$STUB_PID" "$UDP_PID" 2>/dev/null || true' EXIT INT TERM

# Readiness gate: the loopback stub must accept connections from the HOST
# (unconfined) before any check runs. On the aarch64 macos-26 runner it never
# came up — net-allow then fails and is misread as a boundary break, when the
# truth is "no stub". Fail fast with the cause (stub log, python, listeners,
# firewall state) instead of a misleading boundary verdict.
stub_up=0
attempt=0
while [ "$attempt" -lt 20 ]; do
  if curl -sf --max-time 2 "$STUB_URL" >/dev/null 2>&1; then stub_up=1; break; fi
  sleep 0.5
  attempt=$((attempt + 1))
done
if [ "$stub_up" -ne 1 ]; then
  echo "::error::loopback stub $STUB_URL never came up — CI infra problem, not a boundary result" >&2
  echo "## stub.log";    cat "$STUBDIR/stub.log" 2>/dev/null || true
  echo "## python3";     command -v python3 || true; python3 --version 2>&1 || true
  echo "## listeners";   { lsof -nP -iTCP:"$STUB_PORT" 2>/dev/null; netstat -an 2>/dev/null | grep -w "$STUB_PORT"; } || true
  echo "## firewall";    sudo /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate --getstealthmode 2>/dev/null || true
  exit 1
fi

# Plant a host secret OUTSIDE the jail's curated view.
SECRET="$HOME/.ssh/id_secret"
mkdir -p "$HOME/.ssh"
echo TOPSECRET > "$SECRET"
chmod 600 "$SECRET"

# Run the oracle from a clean project dir — mount-cwd binds it RW (the
# path-rw target); cfgDir is fixed (concrete projectName in the probe build).
WORK=$(mktemp -d)
cd "$WORK"

fail=0
check() {
  local name=$1; shift
  printf '\n========== %s ==========\n' "$name"
  if "$@"; then echo "PASS $name"; else echo "FAIL $name"; fail=1; fi
}

# Dump runner-specific state when net-allow fails. net-allow uses ALL_PROXY
# (socks5h) for the http:// stub — curl ignores the uppercase HTTP_PROXY for
# http URLs (httpoxy), so the path is: agent -> SOCKS5 proxy -> whitelisted
# host. This is green on x86_64-darwin and on the aarch64 macos-15 runner but
# fails on the aarch64 macos-26 runner, so capture arch/OS, stub liveness, the
# jail proxy env, a verbose curl through the proxy, and the proxy's own
# forward/deny log to show which leg broke. Only runs on failure.
diagnose_allow() {
  printf '\n----- net-allow failure diagnostics -----\n'
  echo "## arch / macOS"; uname -m; sw_vers 2>/dev/null || true
  echo "## stub reachable from the host (unconfined)?"
  curl -sS --max-time 5 "$STUB_URL" || echo "(host itself cannot reach the stub)"
  echo "## stub listener"; lsof -nP -iTCP:"$STUB_PORT" -sTCP:LISTEN 2>/dev/null || true
  echo "## jail proxy env"; "$JS" -q -a "$STUB_IP" -- -c 'env | grep -iE proxy' || true
  echo "## verbose curl through the proxy (whitelisted)"
  "$JS" -q -a "$STUB_IP" -- -c "curl -v -sS --max-time 8 '$STUB_URL'" 2>&1 || true
  echo "## proxy forward/deny log"; "$JS" --log 2>&1 | tail -n 30 || true
  printf -- '----- end diagnostics -----\n'
}

# --- universal six ---
# #1 deny-closed: curl via proxy to a NON-whitelisted host → proxy refuses.
check net-deny "$JS" -q -- -c "slop-oracle net-deny '$STUB_URL'"
# #3 violation-recorded: the proxy logged the whitelist miss (run UNCONFINED).
check violation-logged env "SLOP_LOG_CMD=$JS --log" "$ORACLE_HOST" violation-logged "$STUB_IP"
# #2 allow-connects: with -a, the proxy forwards to the stub. On failure, dump
# runner-specific diagnostics (the aarch64 macos-26 case — see diagnose_allow).
fail_before=$fail
check net-allow "$JS" -q -a "$STUB_IP" -- -c "slop-oracle net-allow '$STUB_URL'"
if [ "$fail" -ne "$fail_before" ]; then diagnose_allow; fi
# #4/#5/#6 jail boundary.
check jail "$JS" -q -- -c \
  "slop-oracle path-rw '$WORK' && slop-oracle path-hidden '$SECRET' && slop-oracle no-host-bin sudo"

# --- macOS-specific extras (ADR-0006) ---
# Non-proxy egress fails closed: a RAW TCP connect to the stub is denied by
# Seatbelt even though -a whitelists it for the proxy path (ADR-0003).
check net-deny-raw "$JS" -q -a "$STUB_IP" -- -c "slop-oracle net-deny-raw '$STUB_IP' '$STUB_PORT'"

# UDP fails closed (ADR-0003 "UDP/raw"): UDP has no proxy path either, so a
# datagram to the stub must be dropped by Seatbelt even with -a whitelisting it.
# Positive control first (UNCONFINED, no Seatbelt, no host `timeout` dep): prove
# the echo stub round-trips, so the confined "failed closed" below means denial,
# not a dead stub.
if python3 -c "
import socket, sys
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); sock.settimeout(3)
sock.sendto(b'slop-udp-control', ('${STUB_IP}', ${UDP_PORT}))
try:
    data, _ = sock.recvfrom(65535)
except socket.timeout:
    sys.exit(1)
sys.exit(0 if data == b'slop-udp-control' else 1)
"; then
  echo "PASS udp-control: UDP echo stub round-trips unconfined"
else
  echo "FAIL udp-control: stub not echoing unconfined — confined result meaningless"; fail=1
fi
check net-deny-udp "$JS" -q -a "$STUB_IP" -- -c "slop-oracle net-deny-udp '$STUB_IP' '$UDP_PORT'"

# TMPDIR redirect (HITL 2026-06-19): inside the jail $TMPDIR points into the
# writable cfgDir, while /tmp is denied by (deny default). Single-quoted so
# $TMPDIR expands inside the jail. Inline (platform extra), not in the oracle.
check tmpdir-redirect "$JS" -q -- -c \
  '[ -n "$TMPDIR" ] && : > "$TMPDIR/.slop-probe" && rm -f "$TMPDIR/.slop-probe" && ! ( : > /tmp/.slop-probe-should-fail )'

# --wl-add persistence (next-launch half): a persisted host is reachable on a
# fresh launch with no -a. The "no effect on a RUNNING session" half is
# deferred (see risk point 3).
"$JS" --wl-add "$STUB_IP" >/dev/null 2>&1 || true
check wl-add-persists "$JS" -q -- -c "slop-oracle net-allow '$STUB_URL'"
"$JS" --wl-del "$STUB_IP" >/dev/null 2>&1 || true

printf '\n========== RESULT ==========\n'
if [ "$fail" -eq 0 ]; then
  echo "all macOS oracle checks passed"
else
  echo "one or more macOS oracle checks FAILED"
fi
exit "$fail"
