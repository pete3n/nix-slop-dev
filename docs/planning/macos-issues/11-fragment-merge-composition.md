## What to build

Per ADR-0001: nested `sandbox-exec` is impossible, so on darwin the Sandbox and Jail must merge into one profile at a single launch point. Jail wrappers built by the Seatbelt library carry their filesystem profile fragment (via an agreed convention, e.g. an embedded fragment path the wrapper exposes); `sandboxed` detects the fragment on its target command, merges filesystem and network rules into one profile, and execs a single `sandbox-exec`. `sandboxed` remains the universal entry point on every platform.

## Acceptance criteria

- [ ] `sandboxed jailed-shell` enforces both the network whitelist and the filesystem boundary in one session
- [ ] `sandboxed <plain-command>` (no fragment) still works with network rules only
- [ ] Invoking a jailed wrapper directly (without `sandboxed`) has defined, documented behavior — it either self-applies its filesystem profile or fails with clear guidance; it never attempts nested sandbox-exec
- [ ] Whitelist semantics come from a single code path shared with the plain darwin Sandbox

## Blocked by

- Darwin sandboxed: network Sandbox via Seatbelt
- Seatbelt combinator library (darwin Jail)
