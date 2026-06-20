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
#   3. Live OAuth creds-persist is NOT covered here (needs an interactive login
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
trap 'kill "$STUB_PID" 2>/dev/null || true' EXIT INT TERM

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

# --- universal six ---
# #1 deny-closed: curl via proxy to a NON-whitelisted host → proxy refuses.
check net-deny "$JS" -q -- -c "slop-oracle net-deny '$STUB_URL'"
# #3 violation-recorded: the proxy logged the whitelist miss (run UNCONFINED).
check violation-logged env "SLOP_LOG_CMD=$JS --log" "$ORACLE_HOST" violation-logged "$STUB_IP"
# #2 allow-connects: with -a, the proxy forwards to the stub.
check net-allow "$JS" -q -a "$STUB_IP" -- -c "slop-oracle net-allow '$STUB_URL'"
# #4/#5/#6 jail boundary.
check jail "$JS" -q -- -c \
  "slop-oracle path-rw '$WORK' && slop-oracle path-hidden '$SECRET' && slop-oracle no-host-bin sudo"

# --- macOS-specific extras (ADR-0006) ---
# Non-proxy egress fails closed: a RAW TCP connect to the stub is denied by
# Seatbelt even though -a whitelists it for the proxy path (ADR-0003).
check net-deny-raw "$JS" -q -a "$STUB_IP" -- -c "slop-oracle net-deny-raw '$STUB_IP' '$STUB_PORT'"

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
