# Nix Slop Dev
This repo's Nix flake and flake templates provide a convenient way to create 
contained development environments for AI agents. These agents run in a 
per-project confined shell, with outbound network traffic denied by default.

## Disclaimer
This project makes no security gaurantees. It provides a defence-in-depth layer,
but limitations and vulnerabilities still remain. Use it as one mitigation among 
several. You are responsible for the code your agent executes.

- **It is designed to mitigate**: accidental exfiltration of `$HOME/.ssh`, browser
  cookie stores, and keychain dumps; supply-chain `curl | sh` shell-outs to
  arbitrary internet hosts; package post-install scripts reading paths
  unrelated to the project, etc.
- **It is not designed to mitigate**: a kernel-level escape (bubblewrap or
  Seatbelt CVEs); prompt-injection that convinces the agent to use *allowed*
  hosts maliciously (e.g. exfil via an allowlisted GitHub Gist), or the user
  deliberately exposing hosts with `--allow *`.
- **Known platform limitations/quirks** (see [How it works](#how-it-works)):
  - macOS cannot `ping <whitelisted-ip>`: the Seatbelt profile language
    rejects per-IP rules so the userspace proxy only covers TCP via
    `CONNECT`/SOCKS5. Non-proxy-aware UDP and raw sockets fail closed.
    See [ADR-0003](docs/adr/0003-macos-sandbox-via-userspace-proxy.md).
  - On macOS, `--wl-add` does not update a running session — changes take
    effect on the next launch. Linux updates live transient units.

## Getting started
Two prerequisites apply on every platform: install Nix, and enable flakes.
The following are host specific platform setup instructions:

- **NixOS** → [docs/nixos.md](docs/nixos.md)
- **macOS with nix-darwin** → [docs/macos.md](docs/macos.md)
- **Non-NixOS Linux** (Ubuntu, Debian, Fedora) →
  [docs/non-nixos-linux.md](docs/non-nixos-linux.md)

### Tested platforms
Status badges reflect the latest `main` functional-CI run.

| OS                 | Version                          | Status |
|--------------------|----------------------------------|--------|
| NixOS              | 26.05                            | [![nixos](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/pete3n/nix-slop-dev/badges/nixos.json)](https://github.com/pete3n/nix-slop-dev/actions/workflows/functional.yml) |
| macOS (nix-darwin) | macOS 15 & 26 / nix-darwin 26.05 | [![macos](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/pete3n/nix-slop-dev/badges/macos.json)](https://github.com/pete3n/nix-slop-dev/actions/workflows/functional.yml) |
| Ubuntu             | 26.04                            | [![ubuntu](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/pete3n/nix-slop-dev/badges/ubuntu.json)](https://github.com/pete3n/nix-slop-dev/actions/workflows/functional.yml) |
| Debian             | 13                               | [![debian](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/pete3n/nix-slop-dev/badges/debian.json)](https://github.com/pete3n/nix-slop-dev/actions/workflows/functional.yml) |
| Fedora             | 44                               | [![fedora](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/pete3n/nix-slop-dev/badges/fedora.json)](https://github.com/pete3n/nix-slop-dev/actions/workflows/functional.yml) |

Templates status:
[![templates](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/pete3n/nix-slop-dev/badges/templates.json)](https://github.com/pete3n/nix-slop-dev/actions/workflows/functional.yml)

Other systemd-based Linux distributions with cgroup v2 should work —
`setup-linux` probes for what it needs and reports what is missing.
Please file an issue if `--check` passes on your distro but the wrapper
fails at runtime. See [docs/testing.md](docs/testing.md) for more information.

Once setup, you can run a jailed agent directly with:
``` sh
nix run github:pete3n/nix-slop-dev#claude
```

Or clone a development environment [template](#templates) to customize it for your needs:
``` sh
nix flake init -t github:pete3n/nix-slop-dev#claude-code-nvim-dev
nix develop
```

## Usage
The project ships the following tools. A full reference can be found at:
[docs/usage.md](docs/usage.md).

**Apps** (Can be directly run with: `nix run github:pete3n/nix-slop-dev#`):

- `claude` — launch Claude Code inside a Slop Env, using the current
  directory's basename as project identity and library-bundled defaults
  for `CLAUDE.md`, rules, and skills. Zero-touch entry point allows:
  - **Network**: `api.anthropic.com`, `platform.claude.com`, and (Linux
    only) `2607:6bc0::/32`. Everything else denied.
  - **Filesystem**: the current working directory (read/write), the
    per-project state dir under `~/.local/state/claude/projects/<basename>`,
    the shared `~/.local/state/claude/shared/.credentials.json`, and
    `~/.cache` / `~/.npm` / `~/.local/share/claude-code`. `$HOME/.ssh`,
    other projects, and everything else in `$HOME` are hidden.
  - To add hosts, use `sandboxed --wl-add <host>` (persistent) — args
    after `--` go to Claude, not the Sandbox.
- `pi` — same zero-touch entry point for Pi
  ([earendil-works/pi](https://github.com/earendil-works/pi)) instead of
  Claude Code. Selected via the `pi` Agent Profile; same Sandbox / Jail
  guarantees, with per-project session, Scratch, and Exchange dirs under
  `~/.local/state/pi/projects/<basename>`. Network allows are Pi's provider
  hosts. See [ADR-0009](docs/adr/0009-agent-profile-generalization.md).
- `opencode` — same zero-touch entry point for opencode
  ([sst/opencode](https://github.com/sst/opencode)). Selected via the
  `opencode` Agent Profile; same guarantees, with per-project Scratch and
  Exchange dirs under `~/.local/state/opencode/projects/<basename>`. See
  [ADR-0010](docs/adr/0010-opencode-zero-touch-without-placeholder.md).
- `jail-shell` — open an interactive shell inside the same Jail without
  starting an agent. Useful for inspecting what the agent will see, or
  running a build manually under the same confinement.
  - **Network**: no per-invocation allows. Only the persistent whitelist
    (`sandboxed --wl-add …`) applies.
  - **Filesystem**: identical to `claude` above.
- `setup-linux` — diagnose and configure host prerequisites
  (sudoers, auditd, AppArmor, etc.).

Full default-access matrix and how to extend it:
[docs/usage.md](docs/usage.md).

**Packages** (`nix build github:pete3n/nix-slop-dev#`):

- `sandboxed` — the wrapper that creates the Sandbox (and on macOS the
  Jail via Seatbelt). The modules install it onto PATH; see
  [docs/usage.md](docs/usage.md) for its flag reference.
- `sandbox-proxy` (macOS only) — the userspace HTTP `CONNECT` / SOCKS5
  proxy that enforces the Host Whitelist on macOS. It is created automatically
  by `sandboxed`, and is compiled from the Go source under `packages/sandbox-proxy/` 
  (one `main.go` plus in-tree subpackages — `whitelist/`, `connect/`, `socks/`,
  `listener/`, `denial/`). The `go.mod` has no `require` block: imports are pure
  stdlib, and `vendorHash = null` in `default.nix` enforces that an
  accidental external dependency becomes a build break rather than a
  silent fetch. The only build-time externals are Go itself and
  `buildGoModule`, both pinned by the flake's `nixpkgs` input.
- `prereq-guidance` (Linux only) — helper that prints distro-aware setup
  advice from a template's `shellHook` when prerequisites are missing.
- `hunk` — re-export of [modem-dev/hunk](https://github.com/modem-dev/hunk)
  (the `hunk` diff-review tool), pinned via the flake's `hunk` input so
  templates and the outer dev-shell consume one version. The package output
  also carries the `hunk-review` skill, merged into each template's skills
  bundle at build time. See
  [ADR-0007](docs/adr/0007-hunk-dual-sided-projectpkg.md).
- `worktrunk` — re-export of worktrunk (the `wt` git-worktree workflow CLI)
  from `nixpkgs-unstable`, for a newer release than the pinned 26.05 ships.
  Mirrors the hunk re-export pattern; unlike hunk its skills are not in the
  package output, so they are vendored by hand into each template's skills
  tree. See [ADR-0008](docs/adr/0008-worktrunk-nixpkgs-reexport-vendored-skills.md).

<a id="templates"></a>
**Templates** (`nix flake init -t github:pete3n/nix-slop-dev#`):

Templates are the primary mechanism for customising the Slop Env. Each
template is a standalone Nix flake you own. Edit context, rules,
skills, project packages, and Jail combinators as needed for your project.

The template's `flake.nix` declares one
[Nix dev shell](https://nix.dev/manual/nix/2.18/command-ref/new-cli/nix3-develop):

```nix
devShells.${system}.default = slop.mkShell {
  projectName = "my-project";
  agentMdFile = ./slop-env/claude-config/CLAUDE.md;
  rulesDir = ./slop-env/claude-config/rules;
  skillsDir = skills; # checked-in skills + hunk-review, merged at build time
  projectPkgs = [ hunk worktrunk ]; # shipped by default; append your own
  # projectEnv = { FOO = "bar"; };
};
```

Every template's `flake.nix` already wires `hunk` and `worktrunk` (the `wt`
worktree-workflow CLI) into `projectPkgs` and merges hunk's `hunk-review`
skill into `skillsDir`, so a freshly-initialised template ships with diff
review and worktree management on both the dev shell and the jailed agent.
The `agent` and `enableLocalAi` arguments (selecting a non-Claude Agent
Profile and a local ollama provider) are covered in
[docs/usage.md](docs/usage.md).

In the example above, `nix develop` enters the shell; the `shellHook` runs 
prereq checks and puts `claude` / `jail-shell` on PATH wired to the project's
customised Slop Env. Dev shells are Nix's standard pattern for reproducible
per-project tool environments — this project layers a Slop Env on top
so the shell's tools are also jailed.

The template's `slop-env/claude-config/` tree carries:

- `CLAUDE.md` — base context the agent always sees.
- `rules/*.md` — universal policy files concatenated onto `CLAUDE.md`
  at jail-build time.
- `skills/` — agent skills in
  [Matt Pocock's skills format](https://github.com/mattpocock/skills/blob/main/README.md):
  each subdirectory is one skill (a `SKILL.md` plus optional helper
  files) the agent can invoke on demand. The default template ships
  `diagnose`, `grill-with-docs`, `handoff`, `improve-codebase-architecture`,
  `prototype`, `tdd`, `teach`, `to-issues`, `to-prd`, `triage`, `worktrunk`,
  `wt-switch-create`, and `zoom-out`. At build time the `hunk-review` skill
  from the `hunk` package is merged into the same bundle (so it stays
  version-locked to the installed `hunk`), giving a freshly-initialised
  template diff-review and worktree-workflow skills out of the box. Add,
  remove, or replace freely. The whole tree is bind-mounted read-only into
  the Slop Env at `~/.local/state/claude/projects/<projectName>/skills/`.

Available templates:

- `claude-code` — the default Slop Env as a standalone flake, intended
  for project-scope editing of combinators, `CLAUDE.md`, rules, and
  skills.
- `claude-code-nvim-dev` — same plus `lua-language-server`, Neovim
  plugin-dev tooling, and headless test plumbing.
- `pi-agent` — Slop Env preconfigured for Pi
  ([earendil-works/pi](https://github.com/earendil-works/pi)) instead of
  Claude Code, with an `enableLocalAi` toggle for a local ollama provider.
  Same Sandbox / Jail guarantees; see [ADR-0009](docs/adr/0009-agent-profile-generalization.md)
  for the Agent Profile abstraction behind it.
- `opencode` — Slop Env preconfigured for opencode
  ([sst/opencode](https://github.com/sst/opencode)) instead of Claude Code,
  with an `enableLocalAi` toggle for a local ollama provider. Same Sandbox /
  Jail guarantees; see [ADR-0010](docs/adr/0010-opencode-zero-touch-without-placeholder.md)
  for the zero-touch divergence behind it.

Customisation recipes for combinators, project packages, and env-var
forwarding live in [docs/usage.md](docs/usage.md).

**Host-config modules**:

- `nixosModules.sandboxed` — installs `sandboxed` on NixOS with the
  sudoers and auditd integration the wrapper needs.
- `darwinModules.sandboxed` — installs `sandboxed` on nix-darwin. Thin
  by design: Seatbelt is daemonless and unprivileged, so no sudoers or
  audit machinery is required.

**Library** (`nix-slop-dev.lib`):

- `lib.slopEnv pkgs` — returns `{ defaults; jail; mkBins; mkShell; }`.
  Called by every template and by the zero-touch apps to compose a Slop
  Env. Public stability surface — see
  [ADR-0005](docs/adr/0005-slop-env-lib-extraction.md).
- `lib.jail pkgs` (macOS) — Seatbelt combinator library used to build
  the macOS Jail. Mirrors upstream
  [jail-nix](https://sr.ht/~alexdavid/jail.nix)'s combinator surface so
  templates can write cross-platform combinator code.

### Exchanging files with the agent
A Jail hides `/tmp` and most of `$HOME`, so a jailed agent cannot drop a
file where you can see it by default. Every Slop Env — both the zero-touch
apps and the templates, on Linux and macOS — provisions two host-visible
per-project directories to bridge that boundary:

- **Scratch** (`$TMPDIR`) — throwaway space for the agent's temporary and
  intermediate files. Inspect it freely, but treat it as disposable.
- **Exchange** — the deliberate two-way handoff channel: drop inputs in for
  the agent to ingest, collect outputs (e.g. handoff documents) it leaves
  for you. Persists across agent runs. Surfaced to the agent under an
  Agent-Profile-specific env var: `CLAUDE_EXCHANGE_DIR`,
  `OPENCODE_EXCHANGE_DIR`, or `PI_EXCHANGE_DIR`.

The shell prints the Exchange path when you enter the Slop Env. Both live
outside the project working tree and are scoped per `projectName`, not
shared across projects. See [CONTEXT.md](CONTEXT.md) for the precise
definitions and [docs/usage.md](docs/usage.md) for the per-agent paths.

## How it works
### Concepts
- **Jail** — the filesystem-confinement boundary built per project template
  (e.g. `jailed-claude`). The agent sees a curated view: the project
  directory, a writable config dir, and nothing else. Enforced by
  bubblewrap on Linux and by Seatbelt's filesystem rules on macOS.
- **Sandbox** — the network-confinement boundary: a per-invocation host
  whitelist plus violation alerting. Created by the `sandboxed` wrapper.
  Enforced by a systemd transient unit on Linux and by a userspace proxy
  pinned to loopback by Seatbelt on macOS.
- **Slop Env** — the dev environment a user enters when running an agent or
`jail-shell`: one Slop Env = one Jail + one Sandbox.

Full glossary: [CONTEXT.md](CONTEXT.md).

### NixOS
The **Sandbox** runs the agent inside a `systemd-run --user --pty`
transient unit with `IPAddressDeny=any` plus per-invocation
`IPAddressAllow=` properties for resolved whitelist entries. Enforcement is
the kernel's cgroup-v2 eBPF filter; auditd records denied `connect()`
syscalls so `--log` can surface violations.

The **Jail** is built by [jail-nix](https://sr.ht/~alexdavid/jail.nix)
combinators that wrap bubblewrap: a fresh mount namespace, the project
directory bind-mounted, the agent config is created via `write-text`,
and `/usr/bin/env` as the single host binary in the new mount tree.

Hardening sits in `nixosModules.sandboxed` — see
[docs/nixos.md](docs/nixos.md) for the module options.

### macOS (with nix-darwin)
macOS has no systemd and no bubblewrap, so both boundaries land on
Seatbelt (`sandbox-exec` profiles). Seatbelt is daemonless and runs as
the calling user.

The **Jail** uses `(deny default)` with a curated read+write prelude
(dyld cache, `/System/Library`, ICU, timezone data), then layers
additive `(allow file-read*/file-write* (subpath …))` rules per
combinator. Paths outside the allow list are invisible.
`process-exec` is opt-in per path so the agent cannot reach `osascript`,
`launchctl`, `defaults`, etc. just because they exist on the host. See
[ADR-0004](docs/adr/0004-jail-on-seatbelt-read-confinement.md).

The **Sandbox** cannot live in SBPL alone: the parser structurally
rejects per-IP rules (spike 07 / [ADR-0003](docs/adr/0003-macos-sandbox-via-userspace-proxy.md)).
Instead the wrapper spawns a userspace proxy (HTTP `CONNECT` + SOCKS5)
that reads the host whitelist, and pins the agent's outbound socket
authority to that proxy's loopback port via Seatbelt. The agent sees
`HTTPS_PROXY` / `HTTP_PROXY` / `ALL_PROXY` pointing at `127.0.0.1:<port>`;
anything that ignores the env vars hits Seatbelt's deny and fails closed.
Violations surface from both the unified log (Seatbelt denials) and the
proxy's own log (whitelist misses).

Module reference: [docs/macos.md](docs/macos.md).

### Other Linux distributions (Debian, Ubuntu, Fedora)
The enforcement mechanisms are identical to NixOS — same systemd
`IPAddressDeny`/`Allow`, same bubblewrap Jail, same auditd violation
recording. What differs is host configuration: outside NixOS there is no
declarative module, so the `setup-linux` app diagnoses prerequisites
(systemd ≥ 235, cgroup v2, auditd, sudoers drop-in, AppArmor on Ubuntu
24.04) and writes them with the host's absolute tool paths.

The wrapper detects NixOS at runtime and switches between embedded Nix
store paths (NixOS) and bare tool names resolved via sudo's `secure_path`
(elsewhere). See [ADR-0002](docs/adr/0002-runtime-host-tool-detection.md)
for why store-pinning everywhere would break on flake update.

Setup walkthrough: [docs/non-nixos-linux.md](docs/non-nixos-linux.md).

## Roadmap
The originally-planned multi-agent templates have shipped: `pi-agent`
([ADR-0009](docs/adr/0009-agent-profile-generalization.md)) and `opencode`
([ADR-0010](docs/adr/0010-opencode-zero-touch-without-placeholder.md)), both
delivering the same Sandbox / Jail guarantees as the default Claude Code
template. Track further work via repo issues; contributions welcome.
