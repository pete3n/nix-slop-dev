# The macOS Jail uses a deny-default baseline with a curated prelude

[`docs/spikes/10-seatbelt-filesystem/FINDINGS.md`](../spikes/10-seatbelt-filesystem/FINDINGS.md)
confirmed that the SBPL filesystem vocabulary (`(allow file-read*/file-write*
(subpath …))`, `(literal …)`) is workable for the Jail's combinator library,
with one major caveat (path canonicalization, F1) and one open design
choice: whether to confine reads in addition to writes.

We adopt **full deny-default read+write confinement**, mirroring Linux's
jail.nix isolation goal. The Jail wrapper's baseline profile is `(deny
default)` plus a curated prelude that allows the minimum process plumbing
(`process*`, `sysctl-read`, `mach-lookup`, dyld cache reads, ICU tables,
timezone data, root metadata) the agent needs to load and run. Each
combinator then layers additive `(allow file-read*/file-write* (subpath
…))` rules for its target paths. Paths outside the allow-list are
invisible to the sandboxed process for both read and write.

We rejected **write-only confinement** (`(allow default)` + `(deny
file-write*)` + selective allow-writes) on the priority order
*security > complexity > CLI parity*. Write-only confinement is simpler
to implement and the prelude wouldn't need to track each new agent's
dyld/library requirements — but the agent process would read `$HOME/.ssh`,
browser cookie stores, keychain dumps, and other secrets unrelated to
the project. A coding agent's exfiltration surface is far larger than
its write surface; locking only writes leaves the bigger door open.

## Prelude composition

The curated prelude is a property of the `jail` constructor (slice 9 of
issue 10's TDD plan), not of any individual combinator. Combinators stay
purely additive — they emit `(allow …)` SBPL fragments and preflight
shell commands, and never emit denies. The prelude is shared across every
jailed wrapper the library produces.

The minimum prelude discovered in spike 10 (probe `01h-narrow-allow-only`):

```sbpl
(allow process*)
(allow sysctl-read)
(allow mach-lookup)
(allow ipc-posix-shm*)
(allow signal)
(allow file-read-metadata (subpath "/"))
(allow file-read* (literal "/"))
(allow file-read* (subpath "/usr/lib"))
(allow file-read* (subpath "/System/Library"))
(allow file-read* (subpath "/usr/share/icu"))
(allow file-read* (subpath "/private/var/db/dyld"))
(allow file-read* (subpath "/private/var/db/timezone"))
```

This is sufficient for `cat`. The prelude WILL grow as real agents
(`claude`, `nvim`, `git`, `gh`, `node`, etc.) land in the templates —
each contributes its own dyld/Library/Mach-service requirements. The
flake-checked integration test for the `jail` constructor (slice 9) is
what surfaces missing prelude entries.

## Path canonicalization is mandatory

SBPL matches the kernel-canonical form of a path, not the user-supplied
form. `/tmp`, `/var`, `/etc` (and anything reaching them) must be
rewritten to `/private/tmp`, `/private/var`, `/private/etc` before
emission, or the rule silently matches nothing. The combinator library
exposes a `canonicalizePath` helper applied at SBPL emission time;
combinators wrap caller-supplied paths in it implicitly. Spike 10 F1.

## Consequences

- The Jail's read confinement on macOS now matches Linux's bind-mount-only
  visibility *for the paths covered by combinators*. Default-invisible
  unless explicitly allowed.
- The curated prelude is the integration moving target. Each new agent
  added to the templates may surface a missing entry as a dyld/Mach
  failure during HITL smoke. Adding to the prelude is a normal part of
  template development.
- Combinators stay simple (additive-only) — no combinator can carve a
  hole in the baseline by emitting a deny. This matches jail.nix's
  composability and rules out combinator-ordering footguns.
- The wrapper's runtime cost is unchanged — Seatbelt loads the profile
  once at `sandbox-exec` startup; prelude size is a parse-time concern
  only.
- Path canonicalization is automatic for combinator callers; the
  library README documents the well-known macOS-system symlinks and
  notes that unusual symlinks inside `$HOME` remain the caller's
  responsibility.
- `mkSandboxProfile { jailFragment = …; }` (the existing splice point
  in `modules/macos-sandbox/profile.nix`) takes the **full** Jail
  fragment, prelude included. Issue 11 wires this through; the splice
  contract is unchanged.
- The `(allow file-read* (literal "/"))` line in the prelude is needed
  for cat-and-relatives to canonicalize paths through the root — this
  allows reading `/` itself (not its children, since `literal` is exact).
  Spike 10 F4.

## Addendum (issue 15): exec narrowing

The original prelude carried `(allow process*)` lifted byte-for-byte
from spike 10 probe `01h-narrow-allow-only`. `process*` covers
`process-exec`, `process-fork`, and `process-info*` without a path
predicate. Combined with the prelude's dyld load paths (`/usr/lib`,
`/System/Library`), it let the jailed process exec any binary under
`/usr/bin`, `/bin`, `/sbin`, `/usr/sbin`, `/usr/libexec` that links
libSystem — effectively the entire macOS userland (`python3`,
`osascript`, `nscurl`, `defaults`, `launchctl`, etc.). The ADR's
threat-model paragraph argued *read* confinement; exec confinement was
never explicitly considered.

Linux bwrap does not have this gap. A fresh mount namespace means
`/usr/bin/curl` literally does not exist inside the jail unless
explicitly bound, and the Linux claude-code template binds only
`/usr/bin/env` (one file). Per the project's priority ordering
(security > complexity > CLI parity), the implicit exec surface was
the larger door the original read-confinement narrative was trying to
close.

The prelude is now:

```sbpl
(allow process-fork)
(allow process-info*)
(allow process-exec (literal "/usr/bin/env"))
```

`/usr/bin/env` is allowed because the wrapper's invocation
`sandbox-exec -f profile /usr/bin/env -i …` makes it the first exec
call inside the jail — without it no jail launches at all. Every other
exec authority is opted into per-path: each bind-style combinator
(`ro-bind`, `rw-bind`, `try-readwrite`, `tmpfs`, `mount-cwd`,
`write-text`, `add-pkg-deps`) emits `(allow process-exec …)` on the
same canonical path as its `file-read*` allow, matching bwrap's
bind-mount semantics where a bound dir is both readable AND exec'able.

Combinators that expose no filesystem (`set-env`, `try-fwd-env`,
`time-zone`, `network`, `no-new-session`) and the read-only
`host-resolve` (used for config files like `/etc/bashrc`, not
binaries) emit no `process-exec`. A template that genuinely needs to
exec a host-resolved path can compose a separate combinator.

The acceptance test for this change is the end-to-end jail assertion
in `tests/jail-lib.nix`: a default-composed jail's rendered SBPL
contains `process-exec` for `/usr/bin/env` plus the closure paths, and
explicitly NOT for `/usr/bin/curl`, `/usr/bin/python3`, `/usr/sbin/sshd`,
or any other host-binary path the old `(allow process*)` would have
silently covered.
