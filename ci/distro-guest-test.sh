#!/usr/bin/env bash
# Runs INSIDE the distro VM (Debian/Ubuntu/Fedora). Installs Nix, applies the
# real host configuration via `setup-linux --apply`, then runs the SAME
# tests/oracle/slop-oracle.sh as the NixOS VM across both boundaries.
#
# Invoked over SSH by ci/distro-e2e.sh. The repo is already copied to ~/src.
# Args: <stub_host> <stub_port>   (the host-side stub, reached via slirp 10.0.2.2)
#
# This is the layer the fixture sims cannot reach: it proves the generated
# sudoers / auditd / SELinux / AppArmor config actually loads, and that
# enforcement then holds — the HITL-2026-06-19 bug class.
set -euo pipefail

STUB_HOST=${1:?usage: distro-guest-test.sh <stub_host> <stub_port>}
STUB_PORT=${2:?usage: distro-guest-test.sh <stub_host> <stub_port>}
STUB_URL="http://${STUB_HOST}:${STUB_PORT}/"

SRC="$HOME/src"
ORACLE="$SRC/tests/oracle/slop-oracle.sh"
FLAKE="path:$SRC"
PROJ="$HOME/proj"
SECRET="$HOME/.ssh/id_secret"

log() { printf '\n========== %s ==========\n' "$*"; }

# --- Nix (Determinate Systems installer: multi-user + flakes on by default) ---
if ! command -v nix >/dev/null 2>&1; then
  log "installing Nix"
  curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix \
    | sh -s -- install --no-confirm
fi
# shellcheck disable=SC1091
if [ -e /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then
  . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
elif [ -e /etc/profile.d/nix.sh ]; then
  . /etc/profile.d/nix.sh
fi
export NIX_CONFIG="experimental-features = nix-command flakes"

# --- apply real host configuration. setup-linux --apply is interactive
#     (prints a plan, then read -r [y/N]); feed 'y'. It uses sudo for the
#     auditd/AppArmor/SELinux/sudoers writes — the VM user has NOPASSWD. ---
log "setup-linux --apply"
printf 'y\n' | nix run "$FLAKE#setup-linux" -- --apply

# Informational: --check should now be green. Non-fatal — the oracle below is
# the authority on whether enforcement actually holds.
log "setup-linux --check"
nix run "$FLAKE#setup-linux" -- --check || echo "WARN: --check reported unmet prerequisites"

# --- stage the sandboxed wrapper + the oracle ---
log "build sandboxed + oracle"
nix build "$FLAKE#sandboxed" -o "$HOME/sb-link"
SB="$HOME/sb-link/bin/sandboxed"

# Run the oracle from /nix/store, NOT the $HOME checkout. Under `sandboxed`
# (a systemd-run transient unit) Fedora SELinux lets init_t execve store
# binaries (bin_t, after the --apply relabel) but not a $HOME script
# (user_home_t -> status=203/EXEC). The store build matches the product (agents
# live in /nix/store) and the NixOS test's writeShellScriptBin. Overrides the
# $SRC path set at the top.
nix build "$FLAKE#slop-oracle" -o "$HOME/oracle-link"
ORACLE="$HOME/oracle-link/bin/slop-oracle"

# Jail checks reach the oracle via the bound cwd (mount-cwd), so a copy in the
# project dir is reachable as ./slop-oracle. (Inside the jail, bwrap/setpriv
# handle exec — SELinux init_t is not in that path.)
mkdir -p "$PROJ"
cp "$ORACLE" "$PROJ/slop-oracle"
chmod +x "$PROJ/slop-oracle"

# Plant a host secret OUTSIDE the jail's curated view ($HOME/.ssh is unbound).
mkdir -p "$HOME/.ssh"
echo TOPSECRET > "$SECRET"
chmod 600 "$SECRET"

fail=0
run() {
  local name=$1; shift
  log "$name"
  if "$@"; then echo "PASS $name"; else echo "FAIL $name"; fail=1; fi
}

# --- Sandbox (network) boundary. The stub lives on the qemu host, reached at
#     the slirp gateway (10.0.2.2) — non-loopback and not a resolver, so it is
#     denied by default and only reachable with an explicit allow. ---
# #1 deny-closed
run "net-deny" "$SB" -q -- "$ORACLE" net-deny "$STUB_URL"
# #3 violation-recorded (runs UNCONFINED: sandboxed --log = sudo ausearch)
run "violation-logged" env "SLOP_LOG_CMD=$SB --log" "$ORACLE" violation-logged "$STUB_HOST"
# #2 allow-connects
run "net-allow" "$SB" -q -a "$STUB_HOST" -- "$ORACLE" net-allow "$STUB_URL"

# --- Jail (filesystem) boundary via jail-shell (composes sandbox+jail, as the
#     product does). On Ubuntu this also exercises the AppArmor userns
#     precondition; on Fedora the SELinux /nix exec precondition — bwrap and
#     setpriv are /nix/store binaries, so the jail launching at all proves the
#     relabel/profile that setup-linux --apply installed actually works. ---
log "jail boundary (path-rw, path-hidden, no-host-bin)"
cd "$PROJ"
if nix run "$FLAKE#jail-shell" -- -c \
    "./slop-oracle path-rw '$PROJ' && ./slop-oracle path-hidden '$SECRET' && ./slop-oracle no-host-bin sudo"; then
  echo "PASS jail"
else
  echo "FAIL jail"; fail=1
fi

# Negative control: prove the secret really exists outside the jail, so the
# path-hidden PASS means "confined out", not "never created".
grep -q TOPSECRET "$SECRET" || { echo "FAIL negative-control: secret missing on host"; fail=1; }

log "RESULT"
if [ "$fail" -eq 0 ]; then
  echo "all oracle checks passed"
else
  echo "one or more oracle checks FAILED"
fi
exit "$fail"
