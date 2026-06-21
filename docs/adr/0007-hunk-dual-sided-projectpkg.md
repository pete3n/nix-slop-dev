# hunk integrates as a dual-sided projectPkg, re-exported through the core flake

[hunk](https://github.com/modem-dev/hunk) is a review-first terminal diff
viewer whose agent workflow is split across the Jail boundary: the agent runs
`hunk session …` commands *inside* the Jail to drive a review, while the human
watches the interactive TUI (`hunk diff` / `hunk show`) in a separate terminal
*outside* it. The two halves rendezvous over a loopback broker (default
`127.0.0.1:47657`, `HUNK_MCP_PORT`), brokering on by default.

We add hunk to **`projectPkgs`, not `defaultBasePkgs`**, because it is the one
tool needed on both sides of the boundary. `basePkgs` flows Jail-only (via
`add-pkg-deps`); `projectPkgs` flows to both the Jail and the human dev shell
(`packages = projectPkgs ++ …`). Putting hunk in `basePkgs` — the obvious home
for a general agent capability, and where Python lives — would give the agent
`hunk session` but leave the human without the TUI. This is the deliberate
asymmetry a future reader will question: Python is agent-only so it is a
`basePkgs` default; hunk is dual-sided so it must be a `projectPkg`.

The `hunk` flake input is taken **once, in the core nix-slop-dev flake**
(`inputs.nixpkgs.follows = "nixpkgs"`, per hunk's own README) and re-exported as
`nix-slop-dev.packages.${system}.hunk`. Templates — which already depend on
nix-slop-dev — reference that re-export in `projectPkgs` and take **no `hunk`
input of their own**. A per-template `hunk` input was rejected: it gives
`nix flake init` users a second pin that `nix flake update` bumps independently
of `nix-slop-dev`, inviting skew, for no benefit (hunk builds a self-contained
`bun build --compile` binary, so the nixpkgs it is built against barely matters).

The agent skill is **taken from the package, not vendored** as a checked-in
copy like the in-repo skills. hunk is the only externally-versioned skill in
the bundle; sourcing it from `${hunk}/skills/hunk-review` keeps the documented
`hunk session` command surface locked to the installed binary so the two
cannot drift across a hunk upgrade. The original plan — a runtime
`extraCombinator` `ro-bind` of `${hunk}/skills/hunk-review` into the Jail's
`…/skills/hunk-review` — was abandoned: that destination sits *under* the
read-only `…/skills` bind, and bwrap cannot create a mountpoint inside a
read-only bind (EROFS), so the nested bind fails on Linux (Seatbelt would
tolerate it, but parity forbids a Linux-only break). Instead the consuming
flake **merges** the checked-in skills with `${hunk}/skills/hunk-review` into
one bundle at build time (`runCommand`) and binds that single directory as
`skillsDir`. Same version-locking, no runtime nesting.

## Consequences

- No Sandbox changes are needed for the broker. Linux `sandboxed` filters by
  destination IP via systemd `IPAddressAllow/Deny` in the **host** network
  namespace (not a private netns), with `127.0.0.0/8` and `::1/128` explicitly
  allowed and loopback violation-alerts suppressed; bwrap shares the host
  netns. The agent's `127.0.0.1` is the host's, so the agent reaches the TUI's
  daemon with zero whitelisting. This loopback-reachability is load-bearing —
  if either layer moved to a private netns, the integration would break.
- The broker port is not pinned. The default `47657` is shared by both halves
  automatically; running hunk in two projects at once collides on it, and the
  documented escape hatch is `HUNK_MCP_PORT`. Per-project port computation was
  deferred until that collision is felt.
- hunk is built from source (bun2nix) on first `nix develop`; no binary-cache
  substituter is configured. `nix-community.cachix.org` cannot help while
  `follows` repins hunk to our nixpkgs (its cached build is keyed to hunk's
  own nixos-unstable), so a consuming-flake substituter would always miss.
  The from-source cost was measured at ~14m on `ubuntu-latest` in the PR gate
  (mostly the npm dep fetch). Rather than drop `follows` to chase the upstream
  cache, the PR gate (`pr-checks.yml`) persists the Nix store across runs via
  `nix-community/cache-nix-action` keyed on `flake.lock`, so hunk rebuilds
  only when its pin moves; a single nixpkgs is retained. Local `nix develop`
  still pays the one-time source build.
- nix-slop-dev core now carries a third-party package input. Merely holding the
  input is cheap (lock entries); only consumers who place the re-export in
  `projectPkgs` pay the build cost.
- The skills bundle is built per consuming flake (template + outer dev-shell
  flake) rather than in the lib, keeping the ADR-0005 lib arg signature
  untouched. If a third consumer appears, promoting the merge into a lib
  `extraSkills` argument is the natural next step.
