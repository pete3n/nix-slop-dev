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
- `$PI_EXCHANGE_DIR` — the deliberate exchange channel. Read files the
  user drops here for you to ingest, and write outputs you want the user to
  collect (e.g. handoff documents) here. It persists across sessions.

Never write a file you intend to share to `/tmp` — it will be invisible to the
user. Use `$PI_EXCHANGE_DIR`.
