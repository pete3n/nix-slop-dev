# Environment

You are running inside a sandboxed development environment on NixOS.

## Constraints
- By default network access is restricted to your API endpoint only. All other
  connections must be requested and whitelisted before fetch will work.
- Filesystem access is limited to the current project directory and
  essential config paths. You cannot read or modify files outside the
  project.
- The Nix store is not directly accessible. Tools available to you are
  those explicitly provided in the devShell.

## Sharing files with the user

Your `/tmp` lives inside the jail's mount namespace and is **not** visible to
the user. Two per-project directories bridge the jail boundary — both are
host-visible:

- `$TMPDIR` — scratch space. Write temporary and intermediate files here, not
  to `/tmp`. The user can inspect it, but treat it as throwaway.
- `$CLAUDE_EXCHANGE_DIR` — the deliberate exchange channel. Read files the
  user drops here for you to ingest, and write outputs you want the user to
  collect (e.g. handoff documents) here. It persists across sessions.

Never write a file you intend to share to `/tmp` — it will be invisible to the
user. Use `$CLAUDE_EXCHANGE_DIR`.

## Worktrees (`wt` / worktrunk)

`wt` (worktrunk) is available — prefer it. Put any independent line of work in
its own worktree: parallel tasks, a throwaway experiment, or anything you'd
otherwise juggle with `git stash`. Each worktree is its own branch and checkout,
so work doesn't have to be serialized on one branch. The `worktrunk` and
`wt-switch-create` skills cover the commands.

Worktrees are created inside **`.git/slop-worktrees/<branch>`** — not the sibling
directory worktrunk uses by default. This is set for you automatically and is
required: the jail confines you to the project directory, so a sibling worktree
would be unreachable, and placing them under `.git/` keeps the checkouts out of
`git status`. Don't override `WORKTRUNK_WORKTREE_PATH`.

Two jail-specific caveats the skills don't account for:

- The worktrunk skill's tmux/Zellij "agent handoff" pattern does **not** apply —
  there is no terminal multiplexer inside the jail. Its "Parallel sub-Agents"
  example also shows worktrunk's default *sibling* path (`worktrunk.<branch>`),
  which doesn't exist here. To parallelize, pre-create each worktree with
  `wt switch --create <branch> --no-cd --format=json` and point your sub-agents
  at the `path` it prints — never a hardcoded sibling path.
- `wt merge`, and any `wt` command that runs project hooks, may need the user to
  approve those hook commands first. On an approval prompt, stop and ask the user
  to run `wt config approvals add` — never pass `--yes`. Commits, pushes, and
  merges stay user-authorized.
