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
| 1 | deny-closed (no data transfers) | `net-deny` | ✅ | 🟡 | 🟡 |
| 2 | allow-connects | `net-allow` | ✅ | 🟡 | 🟡 |
| 3 | violation recorded | `violation-logged` | ✅ (auditd) | 🟡 (auditd) | 🟡 (proxy/unified log) |
| 4 | confined-out path invisible | `path-hidden` | ✅ | 🟡 | 🟡 |
| 5 | project dir read-write | `path-rw` | ✅ | 🟡 | 🟡 |
| 6 | host binary absent from jail PATH | `no-host-bin` | ✅ | 🟡 | 🟡 |

- **NixOS** ✅: invariants 1/2/3 in `tests/sandbox-functional.nix`; 4/5/6 in
  `tests/jail-functional.nix`. Both are `functionalTests.x86_64-linux.*`.
- **Distro VM** 🟡: all six in `ci/distro-guest-test.sh` (driven by
  `ci/distro-e2e.sh`). Implemented, never executed — gated on `DISTRO_E2E_READY`.
- **macOS** 🟡: all six in `ci/macos-functional.sh`. Gated on `MACOS_FUNCTIONAL_READY`.

## 2. Platform extras (layer on top of the six)

These are the per-platform additions ADR-0006 calls out explicitly.

| Behaviour | Platform | Covered by | Status |
|---|---|---|---|
| Raw (non-proxy) TCP fails closed | macOS (bonus on Linux) | `net-deny-raw` in `macos-functional.sh` | 🟡 |
| **UDP** fails closed | macOS | `net-deny-udp` (echo stub) in `macos-functional.sh` | 🟡 (mechanics verified on Linux; Seatbelt verdict pending a mac) |
| `--wl-add` **persists** to next launch | Linux | `sandbox-functional.nix` (`--wl-add` → re-probe) | ✅ |
| `--wl-add` **live-updates a running** unit | Linux | `sandbox-wl-live-update.nix` (deny-at-launch → live `set-property` → reach, same unit) | ✅ |
| `--wl-add` **persists** to next launch | macOS | `macos-functional.sh` (wl-add-persists) | 🟡 |
| `--wl-add` has **no live effect** on a running session | macOS | — | 🔴 **gap** — see slice 4.4 |
| TMPDIR redirected into cfgDir; `/tmp` denied | macOS | `macos-functional.sh` (tmpdir-redirect) | 🟡 |
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

### 4.2 Validate + green the distro harness  🟡 needs KVM+network
- **Behaviour**: the universal six hold on a real Debian/Ubuntu/Fedora host after
  `setup-linux --apply` — i.e. the generated sudoers/auditd/SELinux/AppArmor
  config actually loads and enforcement holds (the HITL-2026-06-19 bug class).
- **Work**: run `ci/distro-e2e.sh fedora` first, resolve the script's risk points
  (slirp reachability, boot mode, image URL drift), then `DISTRO_E2E_READY=true`.

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

### 4.6 macOS UDP fails closed  🟡 wired; Seatbelt verdict pending a mac
- **Behaviour**: a UDP datagram from inside the jail does not escape — the
  Seatbelt profile is `(deny network-outbound)` save the proxy's localhost port
  (ADR-0003), so UDP has no allow path even with `-a` (ADR said "UDP/raw"; only
  raw TCP was asserted before).
- **Covered by**: `net-deny-udp` oracle check (parallel to `net-deny-raw`) +
  harness wiring in `ci/macos-functional.sh` (loopback UDP echo stub, an
  unconfined positive control, then the confined `-a` check expecting denial).
- **Status**: the probe **mechanics are verified on Linux** — a reachable echo
  reads as "leaked" (fail), a dead/denied endpoint as "failed closed" (pass).
  The macOS Seatbelt verdict can only be observed on a real mac (gated behind
  `MACOS_FUNCTIONAL_READY`). First-run risk points are in the harness header
  (loopback openness, `timeout`/`dd` on the jail PATH).
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

- **`wl-live-update`** — ✅ executed green on a KVM builder (slice 4.1).
- **NixOS `sandbox`/`jail`/`template`** — wired into `functionalTests`. The
  `testing.md` "green today" claim is **not borne out** for the two-node
  `sandbox` test: it carried the same NAT-IP discovery bug 4.1 hit (picking the
  per-VM `10.0.2.15` user-mode NAT instead of the shared `192.168.x` VLAN), so
  its sanity anchor fails on a builder whose test VMs have a user-mode NAT. **Now
  fixed** in `sandbox-functional.nix` (same one-line `grep 192.168` selection);
  **needs a confirming run.** `jail`/`template` are single-node (no peer IP) so
  are unaffected, but have likewise not been re-executed here.
- **Distro + macOS harnesses** — fully written but **never executed on real
  infra**; both gated. Their oracle assertions *are* the failing tests; making
  them pass on real hardware is slices 4.2/4.3.
- **No ADR-named behaviour is unbacked any more.** macOS UDP (4.6) now has a
  check whose mechanics are verified on Linux; only its Seatbelt verdict awaits a
  mac. The roadmap-skeleton guard (4.7) is closed by `roadmap-skeletons-guarded`.
  What remains is *validation on real infra* (distro/macOS harnesses, slices
  4.2–4.5), not missing tests.

## 6. Adding an invariant

Add the check to `tests/oracle/slop-oracle.sh` (one function, the `pass`/`fail`
exit-code contract, one dispatch arm); every harness inherits it. Then wire it
into whichever harness(es) can exercise it, and add a row to §1/§2 here. Keep
platform extras layered on top of the universal six — never fork the six.
