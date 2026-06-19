## What to build

The Sandbox on macOS: the flake gains `aarch64-darwin` and `x86_64-darwin`, and the `sandboxed` package on darwin builds one Seatbelt profile per invocation — deny network by default, loopback allowed, Host Whitelist entries and `-a/--allow` hosts resolved to IPs and allowed — then execs the command via a single `sandbox-exec`. The CLI surface is identical to Linux (`-a`, `-e`, `-q`, `--wl-add/--wl-del/--wl-list`); `--wl-add` reports "(next session)" on darwin since running profiles cannot be updated. Whitelist file format and location are shared with Linux.

## Acceptance criteria

- [ ] `packages.aarch64-darwin.sandboxed` and `packages.x86_64-darwin.sandboxed` build
- [ ] Under `sandboxed -a <host> <cmd>`, the allowed host is reachable and all other destinations are blocked
- [ ] `--wl-list`/`--wl-add`/`--wl-del` operate on the same whitelist file format as Linux, with next-session messaging on add
- [ ] Help text and flag behavior match the Linux wrapper

## Blocked by

- Spike: validate Seatbelt assumptions on macOS
