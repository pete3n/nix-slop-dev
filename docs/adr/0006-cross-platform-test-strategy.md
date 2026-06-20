# Cross-platform tests are two layers, one oracle, two harnesses

Today's suite is almost entirely pure-eval / fixture `checks` (lib-shape
contracts, the Seatbelt-profile and jail-combinator generators, Go unit tests,
and the `setup-linux-{checks,apply}` fixtures that *simulate* every
Debian/Ubuntu/Fedora branch without a host). The bugs that actually ship are
runtime ones — the `HITL 2026-06-19` Fedora SELinux `/nix` fcontext fixes, the
Darwin credential-persist and TMPDIR regressions — none of which a pure
`nix flake check` can reach: the build sandbox has no network, no privilege,
no real namespaces. We add a **functional layer** alongside the eval layer
rather than replacing it.

We assert a single **oracle** of runtime invariants, written once as a portable
script parametrized only by a per-platform "launch a sandboxed command" shim,
so an invariant cannot drift in wording or strictness across platforms. The
universal six: a denied host fails closed; an allowed host connects; the
violation is recorded (auditd `connect()` deny on Linux, proxy + unified log on
Darwin); an out-of-view path is invisible; the project dir is read/write; host
binaries are absent / `process-exec` is opt-in. Network assertions hit a
**local stub** (a second `nixosTest` node, or a loopback listener) — never a
real external host — so the suite is hermetic and never flakes on network.
Platform extras layer on top: macOS UDP/raw fail-closed and `--wl-add`
no-live-effect ([ADR-0003](0003-macos-sandbox-via-userspace-proxy.md)), the
live credential-persist and TMPDIR regression guards, the Linux `--wl-add`
*does* live-update the transient unit, and the Fedora-SELinux / Ubuntu-AppArmor
jail preconditions.

The oracle runs from **two harnesses by necessity**. NixOS and the Linux
template-functional tests (`nix flake init` → `nix develop` → oracle, inside
the guest) are `nixosTest`s that boot a KVM guest *inside* `nix build`, so they
are `checks` and gate PRs with everything else. Debian/Ubuntu/Fedora full
end-to-end (`setup-linux --apply` for real, then the oracle) and the macOS
functional run cannot be `checks` — a foreign-distro host and a real Darwin
kernel live outside the Nix sandbox — so they run from a CI-script harness on
provisioned VMs and the mac runner.

## Considered options

- **Stay eval-only / extend fixtures.** Rejected: the fixtures already prove the
  *planning logic*; they structurally cannot prove that generated sudoers /
  auditd / SELinux config loads or that enforcement holds — which is precisely
  where the HITL bugs lived.
- **Apply + re-check smoke for the distros** (run `--apply`, assert `--check`
  now passes). Rejected in favour of full end-to-end: a clean re-check does not
  prove the Sandbox blocks a host or the Jail hides a path.
- **Per-harness native assertions** (Python `testScript`, shell, shell).
  Rejected: the "same" invariant silently diverges across three
  implementations. One shared oracle is the single source of truth.

## Consequences

- **aarch64-linux is eval-everywhere, functional on x86_64 only.** The
  enforcement primitives (systemd `IPAddressDeny`, bubblewrap, auditd) are
  arch-independent; aarch64 risk concentrates at the eval/build layer. A future
  arch-specific runtime bug would justify promoting aarch64 to a functional
  smoke or full parity.
- **CI is two-cadence.** The eval/contract `nix flake check` (all four systems)
  is a required check on every PR. The functional matrix — NixOS VM, three
  distro VMs, mac runner, template-functional — runs on merge-to-main, nightly,
  and manual dispatch, and must be green before a release tag. Functional
  regressions can therefore land on `main` between a PR merge and the next
  matrix run; the nightly bounds that window and a release is never cut on red.
- **Templates are tested functionally**, not just by drv byte-equality: the two
  exported templates are init→develop→enforced (the nvim template also asserts
  its lua tooling / headless plumbing is present in the jail). The roadmap
  skeletons (`opencode`, `pi-agent`) stay guarded by a cheap "still
  un-exported / still parses" eval check until promoted.
- **The oracle script and its launch shims are a maintenance surface**: adding a
  platform means a new shim, not a new copy of the assertions; changing an
  invariant is a one-place edit that all harnesses inherit.
