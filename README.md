# Nix Slop Dev

This Nix flake and flake templates provide a convenient way to create and
interact with an AI agent's development environment. These agents run in a 
per-project confined shell. Outbound network traffic is denied by default.

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

Live per-platform functional-CI status (latest `main` run):

[![nixos](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/pete3n/nix-slop-dev/badges/nixos.json)](https://github.com/pete3n/nix-slop-dev/actions/workflows/functional.yml)
[![templates](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/pete3n/nix-slop-dev/badges/templates.json)](https://github.com/pete3n/nix-slop-dev/actions/workflows/functional.yml)
[![distros](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/pete3n/nix-slop-dev/badges/distros.json)](https://github.com/pete3n/nix-slop-dev/actions/workflows/functional.yml)
[![macos](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/pete3n/nix-slop-dev/badges/macos.json)](https://github.com/pete3n/nix-slop-dev/actions/workflows/functional.yml)

| OS                 | Version                     | Host setup                |
|--------------------|-----------------------------|---------------------------|
| NixOS              | 26.05                       | `nixosModules.sandboxed`  |
| macOS (nix-darwin) | macOS 15 / nix-darwin 26.05 | `darwinModules.sandboxed` |
| Ubuntu             | 26.04                       | `nix run …#setup-linux`   |
| Debian             | 13                          | `nix run …#setup-linux`   |
| Fedora             | 44                          | `nix run …#setup-linux`   |

Other systemd-based Linux distributions with cgroup v2 should work —
`setup-linux` probes for what it needs and reports what is missing.
Please file an issue if `--check` passes on your distro but the wrapper
fails at runtime.

How these platforms are tested (the two-layer suite, the shared invariant
oracle, and how to run each layer) is documented in
[docs/testing.md](docs/testing.md).

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

**Apps** (`nix run github:pete3n/nix-slop-dev#`):

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
- `jail-shell` — open an interactive shell inside the same Jail without
  starting an agent. Useful for inspecting what the agent will see, or
  running a build manually under the same confinement.
  - **Network**: no per-invocation allows. Only the persistent whitelist
    (`sandboxed --wl-add …`) applies.
  - **Filesystem**: identical to `claude` above.
- `setup-linux` — diagnose and configure host prerequisites
  (sudoers, auditd, AppArmor on Ubuntu 24.04).

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
  claudeMdFile = ./slop-env/claude-config/CLAUDE.md;
  rulesDir = ./slop-env/claude-config/rules;
  skillsDir = ./slop-env/claude-config/skills;
  # projectPkgs = with pkgs; [ lua-language-server stylua ];
  # projectEnv = { FOO = "bar"; };
};
```

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
  `diagnose`, `grill-with-docs`, `improve-codebase-architecture`,
  `prototype`, `tdd`, `to-issues`, `to-prd`, `triage`, and `zoom-out`;
  add, remove, or replace freely. The whole tree is bind-mounted
  read-only into the Slop Env at
  `~/.local/state/claude/projects/<projectName>/skills/`.

Available templates:

- `claude-code` — the default Slop Env as a standalone flake, intended
  for project-scope editing of combinators, `CLAUDE.md`, rules, and
  skills.
- `claude-code-nvim-dev` — same plus `lua-language-server`, Neovim
  plugin-dev tooling, and headless test plumbing.

Additional templates (`opencode`, `pi-agent`) are planned — see
[Roadmap](#roadmap). Customisation recipes for combinators, project
packages, and env-var forwarding live in
[docs/usage.md](docs/usage.md).

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

Planned work, not yet implemented:

- **`opencode` template** — Slop Env preconfigured for
  [opencode](https://github.com/sst/opencode) instead of Claude Code, so
  teams running a different agent get the same Sandbox / Jail guarantees.
- **`pi-agent` template** — Slop Env preconfigured for
  [Pi](https://pi.dev/) ([earendil-works/pi](https://github.com/earendil-works/pi)),
  giving that agent harness the same Sandbox / Jail guarantees as the
  Claude Code and (planned) opencode templates.

Both templates exist as skeleton files (`templates/opencode/`,
`templates/pi-agent/`) but are not exported from the flake yet. Track
progress via repo issues; contributions welcome.
