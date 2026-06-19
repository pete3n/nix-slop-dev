# Spike 10 — Seatbelt filesystem rule grammar (macOS 15.6.1)

**Date**: 2026-06-13
**Host**: macOS 15.6.1 (24G90), aarch64-darwin
**Tool**: `sandbox-exec -f <profile> <cmd>` (system `/usr/bin/sandbox-exec`)
**Purpose**: De-risk issue 10 (Seatbelt combinator library for the Jail) by
confirming the SBPL filesystem vocabulary the library will emit actually
behaves as expected. Spike 07 already falsified one SBPL claim for the
network side; this is the filesystem-side equivalent.

The combinators target the same shape as Linux's jail.nix (`ro-bind`,
`rw-bind`, `tmpfs`, `write-text`, `mount-cwd`, `try-readwrite`,
`add-pkg-deps`, env helpers). Seatbelt cannot bind-mount or overlay
(ADR-0001), so the combinators emit `(allow file-read*/file-write* …)`
fragments and a preflight script that materializes real directories.

## Method

Profiles under `profiles/` are the minimal SBPL needed to exercise one
question. Each profile is run with `sandbox-exec -f` against a small
fixture tree under `/tmp/spike10/`. The `cat` and `sh -c 'echo … > …'`
commands are the smoke tests: success means the rule grants access,
"Operation not permitted" means the rule blocks it. The unified log
(`log show --predicate 'process == "kernel" AND eventMessage CONTAINS
"deny"'`) gives the kernel-level confirmation when stderr is ambiguous.

## Findings

### F1 — Path canonicalization is mandatory

`(subpath …)` and `(literal …)` rules match the **kernel-canonical** form
of the path, not the user-supplied form. On macOS, the well-known
symlinks are:

| Surface path | Canonical path     |
| ------------ | ------------------ |
| `/tmp`       | `/private/tmp`     |
| `/var`       | `/private/var`     |
| `/etc`       | `/private/etc`     |
| `$TMPDIR`    | `/private/var/folders/<u>/<s>/T/` (under `/var`) |

A rule on `/tmp/foo` silently matches **nothing**; the kernel only sees
`/private/tmp/foo`. Profiles `01-subpath-read.sbpl` (before the fix) and
`04b-literal-symlink-path.sbpl` both demonstrate this. The user can
*access* via either form (the kernel resolves the user-supplied path
before rule matching), but the rule itself must name the resolved form.

**Implication**: the combinator library MUST normalize the well-known
macOS-system prefixes before emitting SBPL. A small pure-Nix helper
(`canonicalizePath`) that rewrites `^/tmp` → `/private/tmp` etc. covers
every path the templates pass today. Unusual symlinks under `$HOME` (rare
on macOS) remain the caller's responsibility — document this in the
library's README.

### F2 — Last-match-wins, same as network (spike 07)

`(allow default)` + `(deny file-read* (subpath "/private/tmp/spike10/test1"))`
+ `(allow file-read* (subpath "/private/tmp/spike10/test1/allow"))` behaves
as ordered last-match: the inner allow narrows back. See
`01-subpath-read.sbpl` (after the path fix).

Order: the more-specific rule must come *after* the more-general one.
This matches `modules/macos-sandbox/profile.nix`'s network-rule ordering
contract.

### F3 — `(subpath …)` is transitive over directory depth

`(allow file-read* (subpath "/p"))` grants read access to every file under
`/p`, at arbitrary depth. `01-subpath-read.sbpl` confirms
`/private/tmp/spike10/test1/allow/nested/deep.txt` is reachable.

### F4 — `(literal …)` is exact-file-only

`(allow file-read* (literal "/p/file.txt"))` grants access only to that
exact path. Sibling/child paths are denied. See
`04-literal-vs-subpath.sbpl`.

**Implication**: `write-text` (the combinator that materializes a single
known-content file) should emit `(literal …)` rather than `(subpath
…)` — narrower allow, exactly the contract jail.nix's `write-text` has
on Linux.

### F5 — Write rules mirror read rules

`(allow file-write* (subpath …))` works symmetrically with the read
variant: transitive, narrowable by later allows, blocks at sibling
boundaries. See `03-subpath-write.sbpl`.

### F6 — Escape vocabulary inside string literals

| Character | Escape needed inside `"…"` | Notes |
| --------- | -------------------------- | ----- |
| space     | none                       | `"with space"` parses fine |
| `(` `)`   | none                       | quoted contents are opaque |
| `"`       | `\"`                       | otherwise terminates the string early |
| `\`       | `\\`                       | TinyScheme-lineage parser |

See `05-escape-space.sbpl`, `05b-escape-paren.sbpl`,
`05c-escape-quote.sbpl`, `05d-escape-backslash.sbpl`. Negative test:
`05e-unescaped-quote-fail.sbpl` shows `sandbox-exec` returns rc=65
("unbound variable") when a string is malformed — fail-closed, but the
error is opaque.

**Implication**: the combinator library should escape `"` and `\` in
caller-supplied paths eagerly. A tiny `sbplEscape` helper, applied at
SBPL emission, suffices. Spaces and parens are no-ops but escaping them
is harmless.

### F7 — Categorical deny over `(allow default)` is silently NO-OP for narrow subpaths only when the path doesn't resolve

This is a corollary of F1, not a separate finding: the initial
`(deny file-read* (subpath "/tmp/…"))` probe (probe 01 before fix)
appeared to silently fail. Once the path was rewritten to
`/private/tmp/…`, the deny fired correctly. **Spike 07's "documented
SBPL form is a no-op" pattern recurs here, but the root cause is path
canonicalization, not a parser bug**. Combinators must not assume the
parser will warn on rules that match nothing.

### F8 — Bare `(deny file-read*)` is too aggressive for naive `(allow default)` profiles

`(allow default) + (deny file-read*)` denies dyld cache reads,
sysctl probes, and Mach reads. Even `cat` cannot load (SIGABRT). See
`02-bare-categorical-deny.sbpl`. This rules out a "deny all reads
then re-allow what we need" pattern on top of `(allow default)`.

**Implication**: the Jail's baseline cannot be "allow default + deny
file-read*". Two viable shapes remain (see **Design question** below).

## Profile prelude required for `(deny default)` to be usable

Probe `01h-narrow-allow-only.sbpl` (final form) is the minimum prelude
discovered for `cat` to run under `(deny default)`. Roughly:

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

This prelude is incomplete for real agents (Claude, neovim, git, gh,
nvim — all need more). The full prelude belongs to the `jail`
constructor (slice 9), not to any single combinator. The spike confirms
the **rule grammar is workable**; the prelude is an integration concern
that we'll iteratively expand as we add agents in slices 9+.

## Design question raised by F8

Linux's jail.nix achieves filesystem confinement by bind-mount-only
visibility — the agent process sees a tailor-made filesystem namespace
with nothing in it except what the combinators bound in. On macOS we
can't replicate that exactly. Two options for read confinement:

- **Option A — write-only confinement**: baseline is
  `(allow default)` + `(deny file-write*)`. Combinators add
  `(allow file-write* (subpath …))` for their targets. Reads stay
  open across the whole host. **Weaker isolation than Linux**: the
  agent could read $HOME/secrets, browser cookie stores, ssh keys.
- **Option B — full deny default + curated prelude**: baseline is
  `(deny default)` + a long prelude allowing dyld/process/sysctl/etc.
  Combinators add `(allow file-read* (subpath …))` + `(allow file-write*
  (subpath …))` for their targets. **Matches Linux Jail's isolation
  goal** but the prelude is a moving target (every new agent adds
  another required allow).

The user's standing priority is **security > complexity > CLI parity**
(per [[feedback-security-priority-ordering]] and ADR-0003's
canonical application). Option B is the security-preferring choice.

This decision belongs in an ADR (proposed: ADR-0004
"Jail-on-Seatbelt read confinement model") if Option B is chosen,
or as a documented amendment to ADR-0001 if Option A is chosen.

## Conclusion

The SBPL filesystem vocabulary is workable for the combinator library
once the path-canonicalization gotcha (F1) is handled. The design tension
introduced in ONBOARDING — "Seatbelt cannot bind-mount or overlay" — is
real, and the **deeper open question is whether the Jail aims for full
read confinement on macOS or only write confinement**. Spike findings
support either, but the user input on the trade-off is required before
TDD slice 1 picks a baseline.

Recommended next step: confirm the baseline-prelude choice with the user,
then write the ADR, then start TDD slice 1 (`set-env` — pure env, baseline-
neutral, gives us cadence without committing to A or B yet).

## Files

- `profiles/01-subpath-read.sbpl` — subpath transitive read, last-match-wins
- `profiles/01b-deny-only.sbpl` — bare deny doesn't fire under allow default (because of F1)
- `profiles/01c-deny-default.sbpl` — `(deny default)` actually denies (cat can't exec)
- `profiles/01d-order-inverted.sbpl` — order inversion test
- `profiles/01e-file-read-data.sbpl` — file-read-data vs file-read* (no difference for this case)
- `profiles/01f-deny-default-allow-cat.sbpl` — first prelude attempt
- `profiles/01g-deny-default-cat-prelude.sbpl` — deny over allow file-read* (no-op, predates F1 discovery)
- `profiles/01h-narrow-allow-only.sbpl` — final minimal prelude for cat under deny default
- `profiles/02-bare-categorical-deny.sbpl` — F8: deny file-read* under allow default is too aggressive
- `profiles/03-subpath-write.sbpl` — F5: write rules mirror reads
- `profiles/04-literal-vs-subpath.sbpl` — F4: literal is exact-file-only
- `profiles/04b-literal-symlink-path.sbpl` — F1 for literal too
- `profiles/05-escape-space.sbpl` — F6: spaces inside quoted strings
- `profiles/05b-escape-paren.sbpl` — F6: parens
- `profiles/05c-escape-quote.sbpl` — F6: `\"` escape
- `profiles/05d-escape-backslash.sbpl` — F6: `\\` escape
- `profiles/05e-unescaped-quote-fail.sbpl` — F6: parser returns rc=65, fail-closed
