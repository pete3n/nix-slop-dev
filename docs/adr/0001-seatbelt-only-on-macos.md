# Seatbelt is the sole enforcement mechanism on macOS

macOS has no systemd or bubblewrap, so the Sandbox (network) and Jail
(filesystem) boundaries need new enforcement there. We chose Seatbelt
(`sandbox-exec` profiles) for both, rejecting a PF-firewall/Seatbelt split:
Seatbelt gives per-process scoping with zero privileges (no root, no sudoers,
no dedicated agent user), while PF can only scope rules to a socket-owning
UID, which would force the agent under a dedicated user and into TCC
permission pain. The Seatbelt API is deprecated but stable for over a decade
and underpins Nix's own build sandbox.

## Consequences

- `--wl-add` cannot update a running session on macOS — profiles are fixed at
  launch, so whitelist changes apply next session (the same semantics
  `--wl-del` already has on Linux).
- A Seatbelt-sandboxed process cannot apply a second profile, so Sandbox and
  Jail rules must merge into one profile at a single launch point: darwin
  jail wrappers carry a filesystem profile fragment that `sandboxed` merges
  with the network rules and applies via one `sandbox-exec`.
- Seatbelt cannot bind-mount or overlay paths, so config grafting (jail.nix
  `ro-bind`/`write-text`/`tmpfs`) is replaced by materializing a real config
  directory and pointing `CLAUDE_CONFIG_DIR` at it.
- Violation monitoring reads the unified log instead of auditd.

## Amendment — 2026-06-13 (Status: superseded for the host-filter mechanism by ADR-0003)

Spike 07 (see [`docs/spikes/07-seatbelt/FINDINGS.md`](../spikes/07-seatbelt/FINDINGS.md))
falsified the load-bearing claim that `(allow network-outbound (remote ip "…"))`
filters by remote IP on current macOS. On macOS 15.6.1 the SBPL parser
structurally rejects IP literals in that position with *"host must be * or
localhost in network address"*. Only port-level filtering is available at the
profile language layer.

Consequences:

- The "Seatbelt enforces the Sandbox" half of this ADR no longer stands as
  written. Seatbelt can still enforce the Jail (filesystem) and can constrain
  outbound traffic by port, direction, and socket type — but it cannot
  implement a per-host Sandbox on its own.
- The rejection of a "PF-firewall/Seatbelt split" needs to be re-weighed
  against this constraint; the cost of TCC/dedicated-user friction is now
  measured against shipping no host filtering at all, not against a Seatbelt
  implementation that works.
- ADR-0003 supersedes the host-filter mechanism with a userspace proxy
  pinned by Seatbelt to loopback. Issues 08, 09, 11, 12, 13 inherit that
  shape. Issue 10 (Seatbelt combinator library for the Jail) is unaffected,
  since the Jail is filesystem-only.
