# Slop Env construction lives in a flake-level lib; templates become thin callers

The `claude-code` and `claude-code-nvim-dev` templates are full standalone
flakes consumed via `nix flake init -t …`. This drop-in model works for
non-Nix and greenfield-Nix projects but breaks for existing-Nix-flake
projects — two flakes cannot share a root, forcing project restructure. The
same templates are a three-way merge hot spot across `main` (NixOS),
`feature/non-nixos-linux-support`, and `feature/macos-nix-darwin`: each
branch rewrites overlapping regions of one monolithic `flake.nix`.

We extract the agent-harness construction into `nix-slop-dev.lib.slopEnv`
(see [`CONTEXT.md`](../../CONTEXT.md) for the *Slop Env* term) and add
`apps.${system}.{claude,jail-shell}` as a zero-touch entry point that calls
the lib with bundled defaults. The templates remain as worked examples and
call the same lib. Existing-flake users run `nix run github:pete3n/nix-slop-dev#claude`
from any project root and add zero files. Greenfield and non-Nix projects
keep the existing `nix flake init` path. Mixed-OS teams keep working from
one cross-platform `flake.nix` — per-OS template directories were rejected
because rendering a single-OS `flake.nix` would regress that case, and the
per-OS-clarity win is recovered inside the lib's file layout
(`lib/slop-env/{shared,linux,darwin}.nix` plus a small dispatcher) where it
also gives the additive three-way merge property the template currently lacks.

The lib boundary lands at L4 — `mkSlopEnvBins` returning the jailed
derivations, the per-OS sandboxed wrappers, and the `claude` / `jail-shell`
bins — with a thin L5 `mkSlopEnvShell` convenience that composes those into
a `pkgs.mkShell` for templates' `devShells.default`. Apps reuse L4 bins
directly; stopping at L3 was rejected because it duplicates L4 across
template and apps. Defaults (CLAUDE.md, rules) are duplicated between
`lib/slop-env/defaults/` (canonical, library lifecycle) and the template's
checked-in `slop-env/claude-config/` (editable starting point, project
lifecycle); a CI diff pins them equal until a deliberate divergence.

## Consequences

- `nix-slop-dev.lib.slopEnv` is a public stability surface. The arg
  signature (`projectName`, `rulesDir`, `skillsDir`, `basePkgs`,
  `projectPkgs`, `projectEnv`, `extraCombinators`) is a contract.
- The refactor lands on `main` first as a pure no-behavior-change PR;
  both open feature branches rebase onto it. Their contributions become
  additive single-file edits to `lib/slop-env/`, not the template.
- Adding a fourth supported OS is a new file plus one dispatch arm, not
  a template rewrite.
- The templates lose self-contained-ness — they now depend on
  `nix-slop-dev.lib.slopEnv`. Forks must keep the `nix-slop-dev` input
  pinned or vendor the lib.
- `extraCombinators` is the project-specific escape hatch; caller
  combinators append after lib defaults so last-match-wins lets them
  narrow defaults if needed.
- The apps' wrapper bins absorb the credential-bootstrap that today's
  `shellHook` runs (`mkdir -p` of the state dirs + `touch
  .credentials.json` is idempotent and cheap on every invocation).
- Args after `--` pass through to Claude verbatim, matching today's
  `claudeBin`. The zero-touch case uses `projectName = basename $PWD`
  and lib-bundled config; no `.agent/`-in-project discovery (deferred
  as additive if real demand surfaces).
