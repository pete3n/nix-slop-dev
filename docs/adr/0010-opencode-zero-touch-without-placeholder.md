# opencode's zero-touch entry resolves per-project state without the placeholder/sed

The `claude` and `pi` Agent Profiles power their zero-touch `apps.${system}.*`
entries with a `__SLOP_ENV_PROJECT_NAME__` placeholder: the jail bakes the
sentinel into per-project bind *destinations* and the wrapper resolves
`basename "$PWD"` and `sed`-substitutes it into a tempdir copy of the launch
script at invocation (ADR-0009; `lib/slop-env/linux.nix`,
`lib/slop-env/profiles/pi.nix`). The `opencode` profile deliberately does
**not** use that machinery, even though it ships the same zero-touch
`apps.${system}.opencode` user experience.

The placeholder exists for one reason: an agent that binds a *concrete*
per-project path as a bubblewrap mount destination must know the project name
at launch. pi does — it binds `~/.local/state/pi/projects/<name>/sessions` so
`PI_CODING_AGENT_SESSION_DIR` lands in a host-visible, per-project location.
opencode has no such bind. It stores sessions in a single global SQLite
database (`~/.local/share/opencode/opencode.db`) keyed by project directory
(`packages/core/src/database/database.ts`, `project/project.ts`), which the
Jail already mounts at its real path — so sessions self-isolate per project
through the global data-dir bind, with nothing to substitute. The only genuinely
per-project directories left are slop-env's own **Scratch** and **Exchange**
(`CONTEXT.md`), and those need no baked bind destination: they ride a *parent*
read-write bind (`~/.local/state/opencode`) and are created at runtime by the
launcher (`mkdir -p projects/$PROJECT_NAME/{tmp,exchange}`), with `TMPDIR` and
`OPENCODE_EXCHANGE_DIR` exported to point at them.

## Considered Options

- **Replicate pi's placeholder/sed** so every agent resolves zero-touch
  identically (same launcher shape, same `apps-*-jail-has-placeholder` check).
  Rejected: the sed only exists to rewrite a baked bind destination, and
  opencode has none — the placeholder would be ceremony that substitutes a
  sentinel appearing nowhere meaningful, plus a check asserting machinery the
  agent does not need. That contradicts the codebase's deep-module discipline
  (echoing ADR-0009's rejection of conditional-ridden shims) and adds a launch
  step (tempdir + `sed` + `trap` cleanup) for no behavioural gain.

## Consequences

- `apps.${system}.opencode` is the one zero-touch entry point with **no**
  placeholder in its launch script. A future reader comparing it to the
  `claude`/`pi` launchers will see the divergence; this ADR is why it is
  deliberate and must not be "fixed" back to the sed pattern.
- The opencode profile's apps check asserts the launcher forwards `TMPDIR` +
  `OPENCODE_EXCHANGE_DIR` through the sandboxed wrapper (the Scratch/Exchange
  parity guarantee), rather than grepping for `__SLOP_ENV_PROJECT_NAME__` as
  the claude/pi apps checks do.
- The parent bind `~/.local/state/opencode` is shared with opencode's own
  XDG state (Flock lock files); slop-env's per-project `projects/<name>/`
  subtree lives alongside it. opencode never writes under `projects/`, so the
  namespaces do not collide.
- The placeholder/sed path stays exercised by claude and pi, so removing it is
  not on the table — opencode simply opts out of it.
