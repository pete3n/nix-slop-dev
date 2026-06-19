## What to build

A thin `darwinModules.sandboxed` for nix-darwin mirroring the NixOS module's interface (`enable`, `package`, `stateDir`) — it installs the package system-wide with the configured stateDir. Seatbelt needs no root, so there is no `users`/sudoers machinery and no daemon to enable. Update the README with the nix-darwin stanza so setup reads symmetrically across platforms.

## Acceptance criteria

- [ ] The module evaluates and builds inside a nix-darwin configuration
- [ ] The installed package honors the configured `stateDir`
- [ ] No sudo, auditd, or delegation machinery appears in the darwin module
- [ ] README shows NixOS and nix-darwin setup side by side

## Blocked by

- Darwin sandboxed: network Sandbox via Seatbelt
