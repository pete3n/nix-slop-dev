## What to build

The Jail on macOS: a Seatbelt combinator library exported from the flake's `lib` output that builds jailed wrappers, mirroring the subset of the jail.nix API the templates use (network, cwd mounting, read-only/read-write path access, env setting/forwarding, package deps). Seatbelt cannot bind-mount or overlay, so grafting combinators (`write-text`, `ro-bind`-to-different-path, `tmpfs`) are replaced by real-directory materialization the wrapper performs before applying the profile.

## Acceptance criteria

- [ ] A `jailed-shell` built with the library can read/write the working directory and explicitly allowed state paths only
- [ ] Writes outside allowed paths are denied and observable as violations
- [ ] Env combinators (set/forward) work
- [ ] The library docs map each supported jail.nix combinator to its darwin equivalent and note the unsupported ones

## Blocked by

- Spike: validate Seatbelt assumptions on macOS
