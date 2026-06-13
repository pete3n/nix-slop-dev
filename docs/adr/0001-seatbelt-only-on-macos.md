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
