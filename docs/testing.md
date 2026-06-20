# Testing

The test suite has two layers (see [ADR-0006](adr/0006-cross-platform-test-strategy.md)
for the rationale and trade-offs):

- **Eval/contract layer** — fast, hermetic checks under `nix flake check`
  (lib-shape contracts, the Seatbelt-profile / jail-combinator generators, the
  Go `sandbox-proxy` unit tests, the `setup-linux` fixture sims, template drv
  byte-equality). Gates every PR, on all four systems.
- **Functional layer** — boots real systems and exercises actual enforcement
  (systemd `IPAddressDeny`, bubblewrap, auditd, Seatbelt). Does **not** gate
  PRs; runs on merge-to-main, nightly, manual dispatch, and release tags.

This page is the operational guide (how to run each layer, the CI gate
variables, the first-run playbook). For the behaviour-by-behaviour traceability
matrix — every ADR-0006 invariant mapped to its covering test and status, plus
the ordered red→green TDD slices for what's left — see the
[ADR-0006 test plan](test-plan-adr-0006.md).

Why two layers: the eval checks are cheap and run anywhere, but a pure
`nix flake check` cannot reach the runtime bugs that actually ship (a jail that
doesn't block a path, a sandbox that lets a denied host through, a `setup-linux`
config that doesn't load). Those are the functional layer's job.

## The oracle

All functional tests share one invariant oracle: [`tests/oracle/slop-oracle.sh`](../tests/oracle/slop-oracle.sh).
It is portable bash, **one assertion per invocation**, and the *expected
outcome is encoded in the oracle* — a harness only checks the exit code
(`0` = invariant holds, `1` = violated/uncheckable, `2` = usage). Every harness
(NixOS `nixosTest`, distro VM, macOS) invokes the same script through a
per-platform "launch a sandboxed command" shim, so an assertion cannot drift
between platforms.

| Check | Invariant | Runs |
|---|---|---|
| `net-allow <url>` | #2 allow-connects | in-env |
| `net-deny <url>` | #1 deny-closed (no data transfers) | in-env |
| `net-deny-raw <host> <port>` | non-proxy raw TCP fails closed (macOS; bonus on Linux) | in-env |
| `net-deny-udp <host> <port>` | non-proxy UDP fails closed, via an echo stub (macOS; bonus on Linux) | in-env |
| `violation-logged <pattern>` | #3 violation recorded | host (post-run) |
| `path-hidden <path>` | #4 confined-out path invisible | in-env |
| `path-rw <dir>` | #5 project dir read-write | in-env |
| `no-host-bin <name>` | #6 host binary cannot be executed (absent on Linux; present but exec-denied on macOS) | in-env |

Env knobs: `SLOP_NET_TIMEOUT`, `SLOP_LOG_CMD`, `SLOP_LOG_RETRIES`,
`SLOP_LOG_RETRY_DELAY`. `net-deny` deliberately requires a failed *data
transfer*, not just a failed `connect()` — Fedora's kernel lets `connect()`
return 0 and silently drops egress.

Network assertions always target a **local stub** (a second `nixosTest` node, a
loopback listener, or the qemu host at `10.0.2.2`), never a real internet host,
so the suite is hermetic and cannot flake on network.

## Running each layer

```sh
# Eval/contract — gates PRs. Run per system (builds this system's checks,
# cross-evaluates the rest). Does NOT build the functional VMs.
nix flake check -L

# Functional / NixOS — hermetic, run today on any x86_64 host with /dev/kvm.
nix build -L .#functionalTests.x86_64-linux.sandbox        # network boundary (#1/#2/#3 + wl persistence)
nix build -L .#functionalTests.x86_64-linux.wl-live-update # --wl-add live-updates a RUNNING sandbox unit
nix build -L .#functionalTests.x86_64-linux.jail           # filesystem boundary (#4/#5/#6)
nix build -L .#functionalTests.x86_64-linux.template       # both exported templates' jails

# Functional / distros — boots a real cloud-image VM (needs /dev/kvm + network).
bash ci/distro-e2e.sh fedora     # or debian | ubuntu

# Functional / macOS — runs on a real mac (the runner IS the Darwin host).
bash ci/macos-functional.sh
```

Functional coverage is **x86_64-linux only** by design; the enforcement
primitives are arch-independent, so aarch64 stays eval-level (ADR-0006).

## CI

- [`.github/workflows/pr-checks.yml`](../.github/workflows/pr-checks.yml) —
  `nix flake check` matrix (x86_64-linux, aarch64-linux, aarch64-darwin; Intel
  darwin commented). Make these required status checks for merge.
- [`.github/workflows/functional.yml`](../.github/workflows/functional.yml) —
  the heavy matrix on push-to-main / nightly / dispatch / `v*` tags. Require it
  on tags so a release can't ship red.

Per-harness gate variables (Settings → Secrets and variables → Actions →
Variables) — the distro/macOS jobs stay skipped (neither false-pass nor
false-fail) until set:

| Variable | Enables |
|---|---|
| `DISTRO_E2E_READY=true` | the Debian/Ubuntu/Fedora jobs |
| `MACOS_FUNCTIONAL_READY=true` | the macOS job |

The `nixos` jobs (sandbox/jail/template) are ungated — real and green today.

## Status

| Component | State |
|---|---|
| Eval gate (`pr-checks.yml`) | real |
| NixOS functional: `wl-live-update` | real, hermetic, **verified green on a KVM builder** |
| NixOS functional: `sandbox` | real, hermetic, **verified green on a KVM builder** (after the NAT-IP fix) |
| NixOS functional: `jail`, `template` | real, hermetic; not re-executed here (single-node, unaffected by the NAT-IP fix) |
| Distro e2e (`ci/distro-e2e.sh` + `ci/distro-guest-test.sh`) | implemented, **awaits one-time KVM validation**, gated |
| macOS functional (`ci/macos-functional.sh` + `functionalTests.<darwin>.probe-jail-shell`) | **green on aarch64-darwin** (all checks pass). Ready to flip `MACOS_FUNCTIONAL_READY=true`. |

## First-run validation playbook (for the next agent)

The distro and macOS harnesses are written but **never executed** — they need
real infra this author couldn't reach. Validate each once via `workflow_dispatch`
(or locally), shake out the flagged risk points, then flip its gate variable.
Each script's header lists its risk points; summary:

**Distro (`bash ci/distro-e2e.sh fedora` on a KVM box):**
- slirp `10.0.2.2` → host stub reachability (the deny/allow targets).
- cloud-image boot mode — BIOS by default; a UEFI-only image hangs (no SSH).
  Retry with `OVMF=/usr/share/OVMF/OVMF_CODE.fd bash ci/distro-e2e.sh fedora`
  (install `edk2-ovmf`/`ovmf` first; the path varies per host).
- cloud-image URLs — Fedora's compose suffix drifts; override with
  `DISTRO_IMAGE_URL`.
- guest disk/RAM headroom for the Nix store (`WORKDIR` prefers `/mnt`).
- Start with **Fedora** — that's where the SELinux `/nix`-label HITL bugs lived.

**macOS (`bash ci/macos-functional.sh` on a mac):**
- curl honouring the wrapper proxy for a `127.0.0.1` stub URL; if it bypasses
  the proxy for localhost, `net-deny` fails — switch the stub to the LAN IP
  (`ipconfig getifaddr en0`).
- `net-deny-raw` assumes Seatbelt allows only the proxy's loopback port.

## Open work (TDD-able units)

Framed as red→green for the [tdd](../) skill. Each is independent.

1. **Validate + green the distro harness**, then `DISTRO_E2E_READY=true`. The
   oracle assertions are the failing test; making them pass on a real
   Fedora/Debian/Ubuntu VM is the work. Resolve the playbook risk points first.
2. ~~**Validate + green the macOS harness**~~ — DONE. Green on aarch64-darwin
   (all checks pass, including `net-deny-udp` and the reworked `no-host-bin`).
   Flip `MACOS_FUNCTIONAL_READY=true` to un-gate the CI job.
3. **Deferred macOS extras** (currently documented as out-of-scope in
   `ci/macos-functional.sh`):
   - `--wl-add` has **no effect on a *running* session** (only next launch).
     Needs a backgrounded jailed session, a `--wl-add` from outside, and a
     re-probe of the running session vs. a relaunch. Add as a new oracle check
     or an inline harness step.
   - Live OAuth **creds-persist** across relaunch. Needs an automatable login;
     today the eval check `darwin-creds-persist-in-cfgdir` guards the wiring.
4. **aarch64 functional smoke** (optional) — ADR-0006 keeps aarch64 eval-only;
   promote to a single deny-closed + jail-launch smoke if an arch-specific
   runtime bug ever appears.
5. ~~**`--wl-add` live-update on Linux**~~ — DONE. `tests/sandbox-wl-live-update.nix`
   (`functionalTests.x86_64-linux.wl-live-update`) backgrounds a sandbox, runs
   `--wl-add` from outside, and re-probes the still-running unit. Green on a KVM
   builder; no production change needed (the `set-property` path already worked).
6. **Confirm `sandbox` after the NAT-IP fix** — `sandbox-functional.nix` (and the
   now-passing `wl-live-update`) selected the wrong IP on a builder whose test
   VMs get a QEMU user-mode NAT: `ip … | head -1` picked the per-VM `10.0.2.15`
   instead of the shared `192.168.x` VLAN, so the sanity anchor failed. Both are
   now fixed (`grep 192.168`); `sandbox` needs one confirming run to retire the
   "green today" caveat.

## Adding an invariant

Add the check to `tests/oracle/slop-oracle.sh` (one function, the `pass`/`fail`
exit-code contract, a dispatch arm). Every harness inherits it; wire it into
whichever harness(es) can exercise it. Keep platform-specific extras layered on
top of the universal six — see ADR-0006.
