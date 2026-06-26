# Worktrunk worktrees are placed inside `.git/` via a library env var, not a committed config file

A Jail binds only the project working directory (cwd) — `mount-cwd` allows
read/write/exec on `__JAIL_CWD__` and nothing above it. Worktrunk's default
`worktree-path` is a **sibling** of the repo (`{{ repo_path }}/../{{ repo }}.{{ branch }}`),
which is outside the jail: a jailed agent that ran `wt switch --create` would
create a worktree it could not read, write, or `cd` into. So worktrunk (ADR-0008)
was reachable as a binary but non-functional for the agent it was added for.

We fix this by setting `WORKTRUNK_WORKTREE_PATH = ".git/slop-worktrees/{{branch|sanitize}}"`
as a `set-env` in each profile's jail combinator list (`shared.nix` for Claude,
`profiles/pi.nix`, `profiles/opencode.nix`), placed before the caller's
`projectEnv` merge so a project can still override it. Worktrees now land inside
`.git/`, which is under cwd (reachable by the jail) and whose contents git never
reports (so no `.gitignore` or `.git/info/exclude` is needed). The override is
**jail-scoped**: the developer's own `wt` outside the jail keeps worktrunk's
default sibling path.

## Considered Options

- **Ship `.config/wt.toml` (or `.gitignore`) in the templates.** Rejected:
  `nix flake init -t` does not overwrite existing files, so a committed config
  silently fails to land when the target directory already has one, and we never
  want to clobber a consumer's `.gitignore`/`.config/wt.toml`. Delivery through a
  copied file is unreliable; delivery through the imported flake input (the
  `set-env`) always applies.
- **Worktrees at `.worktrees/` plus a launcher-written `.git/info/exclude`.**
  Rejected once the launchers were mapped: the devShell uses a `claude()` shellHook
  function while `nix run`/apps use a `writeShellScriptBin`, so the exclude write
  would need ~8 edit sites across forked launchers, churn all four byte-equality
  drv snapshots via the shellHook, and risk tripping the macOS creds grep-check —
  all to hide a directory that `.git/` placement hides for free.

## Consequences

- The four byte-equality drv snapshots (`tests/template-*-drv.expected`) move,
  because the `set-env` becomes part of the jailed launcher derivation that feeds
  each template's devShell. Regenerated deliberately, same as ADR-0008.
- Zero-touch (`apps`/existing-flake) consumers get the in-jail worktree placement
  **automatically**, since it rides the library rather than a template file — even
  though they receive neither the vendored worktrunk skill nor the per-template
  agent instructions.
- The vendored worktrunk skill stays verbatim (ADR-0008). Its guidance that
  assumes sibling worktree paths and tmux/Zellij agent handoffs does not apply
  inside the jail; the per-template `CLAUDE.md`/`AGENTS.md` carry the jail-correct
  guidance instead (worktrees under `.git/`, the in-session sub-Agent pattern, and
  hook-approval escalation). The skill's multiplexer handoff is left
  un-authorized, so its own project-authorization gate keeps it switched off.
- `WORKTRUNK_WORKTREE_PATH` holds worktrunk template syntax (`{{branch|sanitize}}`)
  verbatim; `set-env` stores it as derivation data and the jail exports it
  literally, so worktrunk — not Nix or the shell — performs the expansion.
