## What to build

Violation monitoring parity on macOS: the `--log` subcommand and the real-time violation watcher, backed by the unified log (using the predicate validated in the spike) instead of ausearch/audit.log. Alert formatting and the `sandbox-<binary>-<timestamp>` key naming scheme match Linux so sessions are identifiable the same way on both platforms.

## Acceptance criteria

- [ ] A blocked connection attempt during a running session produces a real-time alert in the same visual format as Linux
- [ ] `--log [key-prefix] [since]` returns historical violations for past sessions
- [ ] Loopback and whitelisted traffic produce no alerts
- [ ] `-q` suppresses the watcher and startup messages

## Blocked by

- Darwin sandboxed: network Sandbox via Seatbelt
