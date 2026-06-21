# worktrunk is re-exported from nixpkgs-unstable, but its skills are vendored by hand

[worktrunk](https://github.com/max-sixty/worktrunk) (`wt`) is a Git worktree
manager for parallel agent workflows. We add it as a dual-sided `projectPkg`
in the templates + outer dev-shell flake, exactly like hunk (ADR-0007): `wt`
reaches both the Jail (the agent drives worktrees) and the human dev shell.
Two things diverge from the hunk pattern, and both are deliberate.

**Sourced from nixpkgs, not an upstream flake input.** Unlike hunk, worktrunk
is already packaged in nixpkgs (`pkgs.worktrunk`). We take a second nixpkgs
input tracking unstable (`nixpkgs-unstable`) and re-export
`nixpkgs-unstable.legacyPackages.${system}.worktrunk` as
`packages.${system}.worktrunk` — so templates consume `wt` through
nix-slop-dev without each carrying the unstable input (same re-export rationale
as ADR-0007). Our pinned 26.05 also ships worktrunk (0.50.0 at time of
writing), but it moves fast and unstable carries a newer release; the extra
nixpkgs lock entry is the accepted cost of staying current. A
`github:max-sixty/worktrunk` input was rejected: it would build the Rust
package from source (a heavy crane build) for no benefit when nixpkgs already
caches it, and add a third-party pin that drifts independently of nixpkgs.

**Skills are vendored, not taken from the package.** This is the explicit
*exception* to ADR-0007's principle that an externally-versioned skill is
"taken from the package, not vendored ... so the two cannot drift." worktrunk's
package output carries no skills, so there is nothing to bind at build time.
We copy `skills/worktrunk` and `skills/wt-switch-create` from the upstream repo
into each consuming flake's checked-in `claude-config/skills/` and refresh them
by hand. The one external symlink in that tree (`reference/README.md` →
worktrunk's repo-root README) is dereferenced into a real file on copy, since
the link target does not exist outside the worktrunk tree.

## Consequences

- **The vendored skill docs can drift from the installed `wt` binary.** hunk's
  build-time bind made drift impossible; worktrunk's vendored copy makes it
  possible. There is no automatic lock — the `wt` version (from unstable) and
  the `reference/*.md` (a manual snapshot) advance independently. This is the
  deviation a future reader would otherwise try to "fix" back to the hunk
  pattern; it cannot be fixed without worktrunk shipping its skills in the
  package. Refreshing the vendored copy is a manual maintenance step on a
  worktrunk bump.
- An eval-only `worktrunk-reexport` check (in both the Linux and Darwin
  `checks`) asserts the re-export resolves to a derivation with
  `meta.mainProgram == "wt"`, so a dropped re-export or a worktrunk
  rename/removal in unstable fails at eval, not at template build time. It
  touches only `meta`, so it never forces a worktrunk build.
- Adding worktrunk to `projectPkgs` changes the rendered devShell derivations,
  so the byte-equality snapshots (`tests/template-claude-code-drv.expected`,
  `tests/template-nvim-dev-drv.expected`) move and are regenerated deliberately.
