# Nix Slop Dev

Sandboxed development environments for AI coding agents: a NixOS module and
wrapper that confine agent processes, plus flake templates that assemble
per-project jailed agent shells.

## Language

**Sandbox**:
The network-confinement boundary around a single command: a Host Whitelist
plus violation alerting, created by the `sandboxed` wrapper. Enforced by a
systemd-run transient unit on Linux and by the network rules of a Seatbelt
profile on macOS. Defined by what it confines (network), not by the OS
mechanism that enforces it.
_Avoid_: Jail (that's the filesystem boundary), container

**Jail**:
The filesystem-confinement boundary built per project template (e.g.
`jailed-claude`). Enforced by bubblewrap (jail.nix combinators) on Linux and
by the filesystem rules of a Seatbelt profile on macOS. Distinct from and
composable with a Sandbox, even where one OS mechanism enforces both.
_Avoid_: Sandbox, chroot

**Seatbelt**:
macOS's process sandboxing facility (`sandbox-exec` profiles). The single
enforcement mechanism for both the Sandbox and the Jail on macOS.
_Avoid_: sandbox (unqualified — collides with Sandbox)

**Host Whitelist**:
The set of hostnames, IPs, and CIDRs a Sandbox may connect to, supplied
per-invocation (`-a/--allow`) or persisted in the whitelist file
(`--wl-add`/`--wl-del`).
_Avoid_: allowlist
