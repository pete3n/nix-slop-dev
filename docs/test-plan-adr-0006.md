# ADR-0006 Test Plan

Traceability for the [cross-platform test strategy](adr/0006-cross-platform-test-strategy.md):
every behaviour ADR-0006 names, mapped to the test that covers it, its harness,
and its status. Where a behaviour is *not yet* covered, it is listed as a TDD
slice (§4) — a red→green unit for the [tdd](../) skill.

This doc is the **what-is-covered** map. For **how to run** each layer and the
operational gate variables, see [testing.md](testing.md); this plan references
it rather than restating it.

## Legend

| Mark | Meaning |
|---|---|
| ✅ **real** | implemented, wired into a harness, and runs (hermetic — gates today) |
| 🟡 **gated** | implemented, but the harness has never executed on real infra; skipped behind a gate variable |
| 🟠 **eval-only** | covered at the eval/contract layer only; no functional assertion yet |
| 🔴 **gap** | named by ADR-0006 but **not** backed by any test |

> Scope note: ✅ here means "wired and hermetic per the repo". The three NixOS
> `nixosTest`s were not re-executed during this planning pass — see §5.

## 1. The universal six (the oracle)

One oracle (`tests/oracle/slop-oracle.sh`), one assertion per invocation, run
through a per-platform launch shim. Each invariant is asserted on every harness
that can reach it.

| # | Invariant | Oracle check | NixOS | Distro VM | macOS |
|---|---|---|---|---|---|
| 1 | deny-closed (no data transfers) | `net-deny` | ✅ | 🟡 | ✅ |
| 2 | allow-connects | `net-allow` | ✅ | 🟡 | ✅ |
| 3 | violation recorded | `violation-logged` | ✅ (auditd) | 🟡 (auditd) | ✅ (proxy/unified log) |
| 4 | confined-out path invisible | `path-hidden` | ✅ | 🟡 | ✅ |
| 5 | project dir read-write | `path-rw` | ✅ | 🟡 | ✅ |
| 6 | host binary cannot be executed | `no-host-bin` | ✅ | 🟡 | ✅ |

- **NixOS** ✅: invariants 1/2/3 in `tests/sandbox-functional.nix`; 4/5/6 in
  `tests/jail-functional.nix`. Both are `functionalTests.x86_64-linux.*`.
- **Distro VM** 🟡: all six in `ci/distro-guest-test.sh` (driven by
  `ci/distro-e2e.sh`). Implemented, never executed — gated on `DISTRO_E2E_READY`.
- **macOS** ✅: all six in `ci/macos-functional.sh`, **green on aarch64-darwin**.
  Ready to flip `MACOS_FUNCTIONAL_READY` to un-gate the CI job.

## 2. Platform extras (layer on top of the six)

These are the per-platform additions ADR-0006 calls out explicitly.

| Behaviour | Platform | Covered by | Status |
|---|---|---|---|
| Raw (non-proxy) TCP fails closed | macOS (bonus on Linux) | `net-deny-raw` in `macos-functional.sh` | ✅ verified on aarch64-darwin |
| **UDP** fails closed | macOS | `net-deny-udp` (echo stub) in `macos-functional.sh` | ✅ verified on aarch64-darwin (Seatbelt denies the UDP connect) |
| `--wl-add` **persists** to next launch | Linux | `sandbox-functional.nix` (`--wl-add` → re-probe) | ✅ |
| `--wl-add` **live-updates a running** unit | Linux | `sandbox-wl-live-update.nix` (deny-at-launch → live `set-property` → reach, same unit) | ✅ |
| `--wl-add` **persists** to next launch | macOS | `macos-functional.sh` (wl-add-persists) | ✅ verified on aarch64-darwin |
| `--wl-add` has **no live effect** on a running session | macOS | — | 🔴 **gap** — see slice 4.4 |
| TMPDIR redirected into cfgDir; `/tmp` denied | macOS | `macos-functional.sh` (tmpdir-redirect) | ✅ verified on aarch64-darwin |
| Live OAuth **creds-persist** across relaunch | macOS | — (wiring only, see §3) | 🟠 eval-only — see slice 4.5 |
| Fedora SELinux `/nix` exec precondition holds | Fedora | `distro-guest-test.sh` (jail launches ⇒ relabel worked) | 🟡 |
| Ubuntu AppArmor userns precondition holds | Ubuntu | `distro-guest-test.sh` (jail launches ⇒ profile loaded) | 🟡 |

## 3. ADR consequences → backing test

| ADR-0006 consequence | Backing test | Status |
|---|---|---|
| aarch64 is eval-everywhere, functional on x86_64 only | `functionalTests` keyed `x86_64-linux` only; eval `checks` on all four systems | ✅ |
| CI is two-cadence (eval gates PRs; functional on merge/nightly/tag) | `pr-checks.yml` (eval) + `functional.yml` (matrix) | ✅ |
| Exported templates tested functionally, not just drv byte-eq | `template-functional.nix` (both templates' jails + nvim tooling on PATH) | ✅ |
| nvim template asserts lua tooling / headless plumbing in jail | `template-functional.nix` (`lua-language-server`/`stylua`/`busted`) | ✅ |
| Template composition pinned by byte-equality | `template-claude-code-drv.nix`, `template-nvim-dev-drv.nix`, `template-default-config-matches-lib.nix` | ✅ |
| Roadmap skeletons (`opencode`, `pi-agent`) guarded by a cheap "still un-exported / still parses" eval check | `checks.*.roadmap-skeletons-guarded` (inline in `flake.nix`) | ✅ |
| Oracle + shims are a one-place maintenance surface | adding a platform = a new shim; invariant edits are one-place | ✅ (by construction) |

## 4. TDD slices (ordered red→green units)

Each is independent and framed as a behaviour, not an implementation step.
Ordering is by leverage and by what is verifiable in this hermetic environment.

### 4.1 Linux `--wl-add` live-updates a running unit  ✅ DONE (green under KVM)
- **Behaviour**: a host denied when a long-lived sandboxed unit launched becomes
  reachable *from that same running unit* after `sandboxed --wl-add <host>`, with
  no relaunch.
- **Covered by**: `tests/sandbox-wl-live-update.nix`
  (`functionalTests.x86_64-linux.wl-live-update`) — a follow-on `nixosTest` that
  backgrounds a sandboxed coordinator (deny-at-launch), runs `--wl-add` from
  outside, then re-probes the still-running unit (must now reach).
- **Result**: GREEN with no production change — `_wl_add`'s `systemctl
  set-property` path (`packages/sandboxed/default.nix:127–151`) already worked;
  this characterizes a previously-untested runtime behaviour. Verified on a
  KVM-enabled builder; the test script passes the driver type-check + lint.
- **Side finding**: exposed and fixed a latent NAT-IP bug shared with
  `sandbox-functional.nix` — see §5.

### 4.2 Validate + green the distro harness  🟡 needs KVM + network
- **Behaviour**: the universal six hold on a real Debian/Ubuntu/Fedora host after
  `setup-linux --apply` — i.e. the generated sudoers / auditd / SELinux / AppArmor
  config actually loads and enforcement then holds (the HITL-2026-06-19 bug class
  the eval fixtures structurally cannot reach).
- **Harness**: `ci/distro-e2e.sh <distro>` (host: fetch cloud image → boot KVM →
  cloud-init a NOPASSWD user → copy the repo → run the guest script over SSH) →
  `ci/distro-guest-test.sh` (guest: install Nix → `setup-linux --apply` → the
  shared oracle across both boundaries). Stub = the host on the slirp gateway
  `10.0.2.2` (non-loopback, not a resolver → denied by default).
- **Static review**: internally consistent. The stub IP is fixed at `10.0.2.2`
  (not `ip addr` discovery), so it sidesteps the NAT-IP class that bit 4.1/the
  macOS run. `no-host-bin sudo` still holds under the executability rewrite
  (sudo absent from the bubblewrap jail → PASS). `net-deny-udp`/`-raw` are not
  exercised here (macOS extras). So the failure surface is **environmental**.

**Validation playbook** (run on an x86_64 box with `/dev/kvm` + network; start
with Fedora — that is where the SELinux `/nix`-label HITL bugs lived):

0. **Host deps** are auto-provided: on a Nix host the script re-execs itself
   under `nix shell nixpkgs#qemu nixpkgs#cloud-utils` (no `apt`, no `sudo` — apt
   on a Nix host is nonsensical); a bare apt runner falls back to `apt-get`.
1. **Fedora first**: `bash ci/distro-e2e.sh fedora`. Then `debian`, `ubuntu`.
2. **Risk points, in likely-to-bite order** (each has a no-edit knob now):
   - *Boot mode* — BIOS is the default; a UEFI-only image hangs with no SSH. Retry
     with `OVMF=/usr/share/OVMF/OVMF_CODE.fd bash ci/distro-e2e.sh fedora` (install
     `edk2-ovmf`/`ovmf`; path varies). **(new opt-in knob)**
   - *Image URL drift* — Fedora's compose suffix (`…-44-1.7.…`) changes between
     composes; override with `DISTRO_IMAGE_URL=… bash ci/distro-e2e.sh fedora`.
   - *slirp reachability* — the guest must reach the host stub at `10.0.2.2`; if
     `net-allow` fails but the boot/SSH are fine, suspect host firewall on the
     stub port.
   - *Disk/RAM headroom* — the guest Nix store wants room; `WORKDIR` prefers
     `/mnt` (big runner scratch) over the small root fs.
3. **How to read a failure** (the guest prints `PASS/FAIL <name>` per check):
   - `net-deny` FAIL → the Sandbox let the stub through (boundary leak) — the real
     bug class. `net-allow` PASS alongside confirms the stub was live.
   - `violation-logged` FAIL → auditd not running / rules not loaded by
     `--apply` (Fedora SELinux, the HITL area).
   - `jail` FAIL → `setup-linux --apply` did not make the bubblewrap precondition
     hold (Fedora SELinux `/nix` exec label, Ubuntu AppArmor userns).
4. **On green for all three**, set `DISTRO_E2E_READY=true` to un-gate the CI jobs.

Expect first-run friction (this harness has never executed) — the macOS run took
three fix iterations; budget the same here.

### 4.3 Validate + green the macOS harness  🟡 needs a mac
- **Behaviour**: the six + macOS extras hold under real Seatbelt.
- **Work**: run `ci/macos-functional.sh`, resolve risk points (proxy-honouring for
  a loopback stub; loopback-port assumption in `net-deny-raw`), then
  `MACOS_FUNCTIONAL_READY=true`.

### 4.4 macOS `--wl-add` has no live effect on a running session  🟡 needs a mac
- **Behaviour**: `--wl-add` from outside a *running* jailed session does **not**
  change that session's reachable set; only a relaunch picks it up.
- **Interface**: backgrounded jailed session + external `--wl-add` + re-probe of
  the running session vs. a relaunch. New oracle check or inline harness step.

### 4.5 macOS live OAuth creds-persist across relaunch  🟡 needs a mac + login
- **Behaviour**: a login token written inside the jail survives a relaunch
  (regression guard for the HITL-2026-06-19 shared-symlink clobber).
- **Today**: eval check `darwin-creds-persist-in-cfgdir` guards the *wiring*
  (shellHook detects login via cfgDir; preflight has no clobbering symlink).
  Functional coverage needs an automatable login — design only until then.

### 4.6 macOS UDP fails closed  ✅ DONE (verified on aarch64-darwin)
- **Behaviour**: a UDP datagram from inside the jail does not escape — the
  Seatbelt profile is `(deny network-outbound)` save the proxy's localhost port
  (ADR-0003), so UDP has no allow path even with `-a` (ADR said "UDP/raw"; only
  raw TCP was asserted before).
- **Covered by**: `net-deny-udp` oracle check (parallel to `net-deny-raw`) +
  harness wiring in `ci/macos-functional.sh` (loopback UDP echo stub, an
  unconfined positive control, then the confined `-a` check expecting denial).
- **Status**: GREEN on aarch64-darwin. Seatbelt denies the UDP `connect` with
  "Operation not permitted"; the unconfined positive control confirms the echo
  stub was alive, so the "failed closed" is denial, not a dead stub. Probe
  mechanics were also verified on Linux (reachable → leaked; dead/denied →
  failed closed).
- **Probe design notes** (bugs found + fixed while building it): socket I/O runs
  in a subshell because a refused `exec 3<>/dev/udp/...` is a *fatal* redirection
  error; and the reply is read with `dd bs=… count=1` (one datagram per read())
  rather than `read -t`, which drops a newline-less datagram on timeout.

### 4.7 Roadmap-skeleton eval guard  ✅ DONE (green, teeth-proven)
- **Behaviour**: `opencode` and `pi-agent` skeletons stay **un-exported** (absent
  from the flake `templates` output) and **still parse** — the cheap guard ADR
  consequence #3 promised but that did not exist.
- **Covered by**: `checks.<system>.roadmap-skeletons-guarded` (inline in
  `flake.nix`, Linux branch). Asserts neither name is in `self.templates`, and
  that `import` of each `.nix` yields a builder function (`isFunction` forces a
  parse without evaluating the heavy body).
- **Result**: GREEN on the real repo. Both halves were verified to have teeth by
  temporarily (a) injecting an exported name → throws "unexpectedly exported",
  and (b) pointing a skeleton at a non-function `.nix` → throws "no longer parse
  as a builder function". Hermetic eval check — no VM.

### 4.8 aarch64 functional smoke  (optional, deferred by ADR)
- ADR-0006 keeps aarch64 eval-only. Promote to a single deny-closed + jail-launch
  smoke only if an arch-specific runtime bug ever appears.

## 5. What is verified vs. merely implemented

Honest status, because "implemented" ≠ "observed enforcing":

- **`wl-live-update`** + **`sandbox`** — ✅ executed green on a KVM builder
  (slice 4.1, and `sandbox` after the NAT-IP fix). The earlier `testing.md`
  "green today" claim had *not* held for the two-node `sandbox` test — it carried
  the NAT-IP bug 4.1 exposed (picking the per-VM `10.0.2.15` user-mode NAT over
  the shared `192.168.x` VLAN) — now fixed (`grep 192.168`) and confirmed.
  `jail`/`template` are single-node (no peer IP), unaffected, not re-executed here.
- **macOS harness** — ✅ **green on aarch64-darwin** (every check, including
  `net-deny-udp` and the reworked `no-host-bin`). Two bugs were found and fixed
  during validation (the UDP `exec`/`read -t` issues; the `</dev/null` exec
  probe). Ready to flip `MACOS_FUNCTIONAL_READY`.
- **Distro harness** — fully written but **not yet executed on real infra**;
  gated on `DISTRO_E2E_READY` (slice 4.2).
- **No ADR-named behaviour is unbacked, and the macOS layer is verified.** What
  remains is the distro harness (4.2) and the optional macOS slices 4.4/4.5.

## 7. Resolved finding — `no-host-bin` now tests executability, not PATH presence

First-run of `ci/macos-functional.sh` on aarch64-darwin passed every check
**except** invariant #6 (`FAIL no-host-bin: sudo is on PATH …`). Investigation
(static + on-mac probes) showed this was **not a confinement leak** but a wrong
test:

- `/usr/bin/sudo` is *visible* on PATH because the macOS jail allows
  `file-read-metadata` over `/`, but **executing it is denied** — the jail's
  `process-exec` is an opt-in per-path allowlist (only `/usr/bin/env` + bound
  combinator paths; ADR-0004 / issue 15). On-mac: `sudo` → `Operation not
  permitted`, rc 126, no escalation. `/bin/ls` likewise denied; `/usr/bin/env`
  allowed. So the macOS jail enforces its design exactly.
- The oracle's `no-host-bin` tested **PATH presence** (`command -v`), which is the
  Linux-bubblewrap shape (binary genuinely absent) and the wrong question on
  macOS. The true cross-platform invariant is *"a host privilege tool cannot be
  executed"* — satisfied two ways (Linux: absent, rc 127; macOS: exec-denied,
  rc 126).

**Resolution (Option A, implemented):** `check_no_host_bin` now asserts
**executability**, not presence — PASS if the name is absent from PATH *or*
present-but-exec-refused (rc 126/127 or a sandbox "operation not permitted" /
"permission denied"), FAIL only if the binary actually runs. Linux behaviour is
unchanged (sudo is absent → the same PASS); macOS now PASSes correctly. Validated
on Linux across all three branches (absent → PASS; runnable `env` → FAIL-leaked;
present-but-non-exec, rc 126 → PASS, mimicking the macOS denial).

**Status:** RESOLVED. `ci/macos-functional.sh` is **green on aarch64-darwin** —
every check passes, including the reworked `no-host-bin sudo` (exec-denied) and
`net-deny-udp`. `MACOS_FUNCTIONAL_READY=true` can be flipped to un-gate the CI
job. (One follow-on bug surfaced and was fixed during the confirming run: the
exec probe's `</dev/null` is denied by the jail — write-only on `/dev/null` —
so it was removed.)

## 6. Adding an invariant

Add the check to `tests/oracle/slop-oracle.sh` (one function, the `pass`/`fail`
exit-code contract, one dispatch arm); every harness inherits it. Then wire it
into whichever harness(es) can exercise it, and add a row to §1/§2 here. Keep
platform extras layered on top of the universal six — never fork the six.
