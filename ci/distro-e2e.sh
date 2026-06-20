#!/usr/bin/env bash
# Distro end-to-end harness — Debian / Ubuntu / Fedora (ADR-0006).
#
# Host-side orchestration: boot a real distro cloud image under KVM, then run
# ci/distro-guest-test.sh inside it (Nix install -> setup-linux --apply ->
# the shared oracle). Real VMs, not containers: invariant #3 (auditd violation
# recording) is host-global and does not virtualise per-container.
#
# Network design: qemu user-mode (slirp) networking. The guest reaches the
# host at the slirp gateway 10.0.2.2 — used as the hermetic stub endpoint
# (non-loopback, not a resolver, so denied by default). SSH is host-forwarded.
# No real internet host is ever a test target.
#
# Intended to run on a GitHub-hosted ubuntu runner with /dev/kvm enabled (see
# functional.yml). Usage: bash ci/distro-e2e.sh <debian|ubuntu|fedora>
#
# First-run validation points (cannot be exercised without KVM + network):
#   - slirp 10.0.2.2 reachability of the host stub bound to 0.0.0.0,
#   - cloud image boot mode (BIOS assumed; UEFI images need OVMF, see below),
#   - disk headroom for the guest Nix store (WORKDIR prefers /mnt on runners).
set -euo pipefail

distro=${1:?usage: distro-e2e.sh <debian|ubuntu|fedora>}

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# --- host dependencies: qemu-system-x86_64, qemu-img, cloud-localds ---
# This harness drives KVM from the *host*. Provide the tools the Nix way when
# possible — apt on a Nix host is nonsensical. If any are missing and `nix` is
# available, re-exec the whole script inside
# `nix shell nixpkgs#qemu nixpkgs#cloud-utils` (qemu -> qemu-system-x86_64 +
# qemu-img; cloud-utils -> cloud-localds). Fall back to apt only on a non-Nix
# apt host (a bare ubuntu CI runner); otherwise error with guidance.
_have_host_tools() {
  command -v qemu-system-x86_64 >/dev/null 2>&1 \
    && command -v qemu-img >/dev/null 2>&1 \
    && command -v cloud-localds >/dev/null 2>&1
}
if ! _have_host_tools; then
  if command -v nix >/dev/null 2>&1 && [ -z "${_DISTRO_E2E_NIX:-}" ]; then
    echo "== providing host deps via nix shell (qemu, cloud-utils) =="
    exec env _DISTRO_E2E_NIX=1 nix \
      --extra-experimental-features 'nix-command flakes' \
      shell nixpkgs#qemu nixpkgs#cloud-utils --command bash "$0" "$@"
  elif command -v apt-get >/dev/null 2>&1; then
    echo "== installing host deps via apt =="
    sudo apt-get update -qq
    sudo apt-get install -y -qq qemu-system-x86 qemu-utils cloud-image-utils
  else
    echo "::error::missing host tools (qemu-system-x86_64 / qemu-img / cloud-localds)" >&2
    echo "  Nix:    nix shell nixpkgs#qemu nixpkgs#cloud-utils --command bash ci/distro-e2e.sh $distro" >&2
    echo "  Debian: sudo apt-get install qemu-system-x86 qemu-utils cloud-image-utils" >&2
    exit 1
  fi
fi

# Image URLs track README's "Tested platforms" table; override per distro with
# DISTRO_IMAGE_URL when a compose/point-release filename drifts (Fedora
# especially carries a build suffix that changes between composes).
case "$distro" in
  debian)
    IMAGE_URL=${DISTRO_IMAGE_URL:-https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2} ;;
  ubuntu)
    IMAGE_URL=${DISTRO_IMAGE_URL:-https://cloud-images.ubuntu.com/releases/26.04/release/ubuntu-26.04-server-cloudimg-amd64.img} ;;
  fedora)
    # NB: Fedora's compose suffix (…-44-1.7) drifts between composes; when this
    # 404s, find the live filename and override with DISTRO_IMAGE_URL (see the
    # ADR-0006 test plan's validation playbook).
    IMAGE_URL=${DISTRO_IMAGE_URL:-https://download.fedoraproject.org/pub/fedora/linux/releases/44/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-44-1.7.x86_64.qcow2} ;;
  *)
    echo "::error::unknown distro '$distro' (expected debian|ubuntu|fedora)" >&2; exit 2 ;;
esac

# Prefer the runner's big scratch disk (/mnt, ~75G) over the small root fs.
if WORKBASE=$(mktemp -d /mnt/distro-e2e.XXXXXX 2>/dev/null); then :; else
  WORKBASE=$(mktemp -d "${RUNNER_TEMP:-/tmp}/distro-e2e.XXXXXX")
fi
WORKDIR="$WORKBASE/$distro"
mkdir -p "$WORKDIR"

SSH_PORT=$(( (RANDOM % 2000) + 2200 ))
STUB_PORT=$(( (RANDOM % 2000) + 18000 ))
QEMU_PID=""
STUB_PID=""

cleanup() {
  [ -n "$QEMU_PID" ] && kill "$QEMU_PID" 2>/dev/null || true
  [ -n "$STUB_PID" ] && kill "$STUB_PID" 2>/dev/null || true
  wait 2>/dev/null || true
}
trap cleanup EXIT INT TERM

SSH_OPTS=(
  -i "$WORKDIR/id"
  -p "$SSH_PORT"
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=5
  -o BatchMode=yes
  -o LogLevel=ERROR
)

# --- base image + copy-on-write overlay (don't mutate the cached base) ---
echo "== fetching image: $IMAGE_URL =="
BASE="$WORKDIR/base.img"
curl -fL --retry 3 -o "$BASE" "$IMAGE_URL"
OVERLAY="$WORKDIR/overlay.qcow2"
qemu-img create -f qcow2 -F qcow2 -b "$BASE" "$OVERLAY" 20G

# --- cloud-init seed: a passwordless-sudo user with our SSH key ---
ssh-keygen -t ed25519 -N "" -f "$WORKDIR/id" -q
PUBKEY=$(cat "$WORKDIR/id.pub")
cat > "$WORKDIR/meta-data" <<EOF
instance-id: distro-e2e-$distro
local-hostname: distro-e2e
EOF
cat > "$WORKDIR/user-data" <<EOF
#cloud-config
users:
  - name: tester
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - $PUBKEY
ssh_pwauth: false
EOF
cloud-localds "$WORKDIR/seed.img" "$WORKDIR/user-data" "$WORKDIR/meta-data"

# --- host-side stub HTTP endpoint (reached from the guest at 10.0.2.2) ---
STUBDIR="$WORKDIR/stub"; mkdir -p "$STUBDIR"
echo SLOP_STUB_OK > "$STUBDIR/index.html"
python3 -m http.server "$STUB_PORT" --bind 0.0.0.0 --directory "$STUBDIR" \
  >"$WORKDIR/stub.log" 2>&1 &
STUB_PID=$!

# --- boot. BIOS by default (the generic cloud images boot BIOS). For a
#     UEFI-only image, point OVMF at the firmware code — no edit needed:
#       OVMF=/usr/share/OVMF/OVMF_CODE.fd bash ci/distro-e2e.sh fedora
#     (install the `ovmf`/`edk2-ovmf` package first; the path varies per host). ---
firmware_args=()
if [ -n "${OVMF:-}" ]; then
  [ -r "$OVMF" ] || { echo "::error::OVMF=$OVMF is not readable" >&2; exit 1; }
  firmware_args=(-bios "$OVMF")
  echo "== using UEFI firmware: $OVMF =="
fi

echo "== booting $distro (ssh:$SSH_PORT stub:$STUB_PORT) =="
qemu-system-x86_64 \
  -enable-kvm -cpu host -smp 2 -m 4096 \
  ${firmware_args[@]+"${firmware_args[@]}"} \
  -drive file="$OVERLAY",if=virtio,format=qcow2 \
  -drive file="$WORKDIR/seed.img",if=virtio,format=raw \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:"$SSH_PORT"-:22 \
  -device virtio-net-pci,netdev=n0 \
  -device virtio-rng-pci \
  -display none -serial file:"$WORKDIR/console.log" \
  &
QEMU_PID=$!

# --- wait for cloud-init to create the user and sshd to come up ---
echo "== waiting for SSH =="
ready=0
for _attempt in $(seq 1 60); do
  if ssh "${SSH_OPTS[@]}" tester@127.0.0.1 true 2>/dev/null; then ready=1; break; fi
  if ! kill -0 "$QEMU_PID" 2>/dev/null; then
    echo "::error::qemu exited early; console tail:" >&2
    tail -n 50 "$WORKDIR/console.log" >&2 || true
    exit 1
  fi
  sleep 5
done
if [ "$ready" -ne 1 ]; then
  echo "::error::SSH never came up; console tail:" >&2
  tail -n 80 "$WORKDIR/console.log" >&2 || true
  exit 1
fi

# --- copy the checkout in (path: flake; .git not needed) ---
echo "== copying repo into guest =="
tar --exclude=./.git --exclude=./result --exclude='./result-*' \
    -C "$REPO_ROOT" -czf - . \
  | ssh "${SSH_OPTS[@]}" tester@127.0.0.1 'mkdir -p ~/src && tar -xzf - -C ~/src'

# --- run the in-guest test. -tt so the wrapper's `systemd-run --pty` has a
#     terminal; the guest script pipes 'y' into setup-linux itself. ---
echo "== running guest test =="
set +e
ssh -tt "${SSH_OPTS[@]}" tester@127.0.0.1 \
  "bash ~/src/ci/distro-guest-test.sh 10.0.2.2 $STUB_PORT"
rc=$?
set -e

echo "== guest test exit: $rc =="
exit "$rc"
