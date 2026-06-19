## What to build

Make the claude-code template a single cross-platform flake: it branches on system — jail.nix combinators on Linux (unchanged behavior), the Seatbelt library on darwin. On darwin the template materializes a real config directory (settings, CLAUDE.md, skills) and points `CLAUDE_CONFIG_DIR` at it in place of bind-mount grafting. The `claude()` wrapper function and slop-env content (skills, rules, CLAUDE.md) are defined once for both platforms; shellHook setup checks are platform-aware (no auditd/sudo checks on darwin, shared credential checks).

## Acceptance criteria

- [ ] `nix develop` on macOS yields a working `claude` running under the merged Seatbelt profile
- [ ] Claude Code OAuth login works and credentials persist via the shared credentials file
- [ ] Linux template behavior is unchanged
- [ ] Skills/rules/CLAUDE.md content has a single source for both platforms

## Blocked by

- Fragment-merge composition
