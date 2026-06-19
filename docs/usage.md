# Usage reference

Common usage is covered in the [README](../README.md#usage). This page is
the full reference for users who need to script the wrapper, audit what
the Jail exposes, or build a customised template.

- [The `sandboxed` wrapper](#the-sandboxed-wrapper) — full flag list
- [Default access matrix](#default-access-matrix) — what every Slop Env
  exposes, by platform
- [Library API: `mkBins` and `mkShell`](#library-api-mkbins-and-mkshell)
  — arguments accepted by `nix-slop-dev.lib.slopEnv pkgs`
- [Customisation recipes](#customisation-recipes) — extra combinators,
  project packages, env forwarding

## The `sandboxed` wrapper

The wrapper takes the same flags on Linux and macOS. Behavioural
divergences (e.g. `--wl-add` session semantics) are called out per-flag.

| Flag | Argument | Effect |
|---|---|---|
| `-q`, `--quiet` | — | Suppress startup messages and violation alerts. Useful when the wrapper is being driven from another script. |
| `-a`, `--allow` | `<host>` | Add a host to the per-invocation whitelist. Hostnames are resolved at startup to all their A/AAAA records; IP and CIDR literals are accepted as-is. Repeatable. |
| `-e`, `--env` | `<var>` | Forward the named environment variable into the Sandbox (the wrapper otherwise scrubs the inherited env). Repeatable. |
| `--wl-add` | `<host>` | Add a host to the persistent whitelist (`$HOME/$stateDir/whitelist`). On Linux, also updates every running sandboxed unit immediately. On macOS, takes effect on next launch (the proxy reads its whitelist at startup). |
| `--wl-del` | `<host>` | Remove a host from the persistent whitelist. Next-session semantics on both platforms. |
| `--wl-list` | — | Print the current persistent whitelist. |
| `--log` | `[key-prefix] [since]` | Search the violation log. `key-prefix` defaults to `sandbox-`; `since` defaults to one hour ago and accepts any `ausearch --start` value (e.g. `today`, `yesterday`, `30 minutes ago`). |
| `--print-tools` | — | Print how each privileged tool resolves on this host. Useful for diagnosing whether the wrapper is in NixOS mode (store paths) or non-NixOS mode (bare names via sudo's `secure_path`). |

Arguments after `--` are forwarded to the inner command verbatim:

```sh
sandboxed -a github.com -- git clone https://github.com/example/repo.git
```

The wrapper exits with the inner command's exit status, except when a
prerequisite check fails (in which case it exits non-zero before
launching anything).

## Default access matrix

Every Slop Env — whether reached via `nix run …#claude` or a template's
`nix develop` — exposes the same base resources. The matrix below
covers what is visible / writable / network-reachable by default. The
`claude` app adds three per-invocation network allows on top of this
baseline (see [Per-app overlays](#per-app-overlays) below).

### Filesystem

| Path | Mode | Notes |
|---|---|---|
| `$PWD` (current working directory) | read/write | Bind-mounted via `mount-cwd`. The whole project is visible. |
| `~/.local/state/claude/projects/<projectName>/` | read/write | Per-project state. `tmpfs` on Linux, persistent host dir on macOS. Contains `CLAUDE.md`, `settings.json`, `.claude.json`, `sessions/`, `history.jsonl`, `todos/`, `shell-snapshots/`, etc. |
| `~/.local/state/claude/shared/.credentials.json` | read/write | Shared OAuth token, so login persists across Slop Envs. |
| `~/.cache` | read/write | Shared cache dir (npm, pip, ripgrep, …). |
| `~/.npm` | read/write | npm's own cache, separate from `~/.cache`. |
| `~/.local/share/claude-code` | read/write | Claude Code's binary-side state. |
| Nix store closure of `basePkgs` | read-only | The default toolbox: `bash`, `coreutils`, `git`, `gh`, `gnused`, `gnugrep`, `gnutar`, `gzip`, `jq`, `ripgrep`, `nix`, `unzip`, `which`, plus a few others. |
| `/usr/bin/env` | read-only + exec | The single host binary mounted into the Jail (Linux pulls it from `coreutils`; macOS pulls the SIP-protected host path). |
| **Everything else** in `$HOME` and `/` | denied | `$HOME/.ssh`, `$HOME/.aws`, `$HOME/.gnupg`, other projects, host config files — all invisible. |

macOS adds a small read-only set for shell startup:
`/etc/bashrc`, `/etc/zshrc`, `/etc/zprofile`, `/etc/zshenv`,
`/etc/terminfo` (host-resolved through nix-darwin's symlinks if
present), plus `/usr/bin/security` (read + exec) so Claude Code can
read its OAuth token from the macOS Keychain.

### Network

By default the Sandbox is deny-all outbound. Hosts allowed come from
two sources:

1. **Persistent whitelist** — `$HOME/$stateDir/whitelist`, edited via
   `--wl-add` / `--wl-del`. Empty by default.
2. **Per-invocation allows** — `-a <host>` flags passed to `sandboxed`
   at launch.

Inbound connections are not affected (the wrapper does not change
listen-socket behaviour); the Slop Env is a process-egress boundary.

Loopback (`127.0.0.1` / `::1`) is always allowed because Seatbelt on
macOS needs it to reach the userspace proxy. On Linux the equivalent is
implicit — cgroup `IPAddressDeny=any` does not block loopback by
default.

### Per-app overlays

`nix run …#claude` adds these per-invocation allows on top of the base
matrix:

- `api.anthropic.com`
- `platform.claude.com`
- `2607:6bc0::/32` (Anthropic's IPv6 prefix; Linux only — the macOS
  proxy filters by hostname, not CIDR)

`nix run …#jail-shell` adds **no** per-invocation allows. Only the
persistent whitelist applies.

To extend the allow list for the zero-touch `claude` app, use
`sandboxed --wl-add <host>` before the run. Args after `--` on the
`nix run` line are forwarded to Claude Code itself, not to `sandboxed`:

```sh
# WRONG: --allow goes to claude, not the Sandbox
nix run github:pete3n/nix-slop-dev#claude -- --allow github.com

# RIGHT: persist the host first
sandboxed --wl-add github.com
nix run github:pete3n/nix-slop-dev#claude
```

For project-specific allows that should not pollute the persistent
whitelist, use a template (next section) and bake the allows into the
launcher.

## Library API: `mkBins` and `mkShell`

Both templates and the zero-touch apps call
`nix-slop-dev.lib.slopEnv pkgs`, which returns:

- `mkBins { … }` — produces the `claude` / `jail-shell` PATH wrappers,
  the jailed derivations, and the prereq `shellHook`. Apps use this
  directly.
- `mkShell { … }` — wraps `mkBins` in a `pkgs.mkShell` so templates can
  expose a `devShells.default`.
- `defaults` — the lib's bundled `CLAUDE.md`, rules, base package set.
- `jail` — the initialised jail library (jail-nix on Linux, the Darwin
  Seatbelt combinator library on macOS). Used by templates that want to
  emit their own combinators via `extraCombinators`.

Both `mkBins` and `mkShell` accept the same arguments. The full list:

| Argument | Type | Default | Effect |
|---|---|---|---|
| `projectName` | string | `__SLOP_ENV_PROJECT_NAME__` (zero-touch placeholder) | Identifies the per-project state dir (`~/.local/state/claude/projects/<projectName>/`). Templates pass an explicit value; apps resolve it at runtime from `basename "$PWD"`. |
| `claudeMdFile` | path | `lib/slop-env/defaults/CLAUDE.md` | Base context file concatenated with all `rulesDir/*.md` into the agent's `CLAUDE.md`. |
| `rulesDir` | path | `lib/slop-env/defaults/rules` | Directory of `.md` rule files concatenated onto `CLAUDE.md` at jail build time. |
| `skillsDir` | path or `null` | `null` | Directory of agent skills ([Matt Pocock format](https://github.com/mattpocock/skills/blob/main/README.md)) bind-mounted at `~/.local/state/claude/projects/<projectName>/skills/`. |
| `basePkgs` | list of packages | `shared.defaultBasePkgs` | The base toolbox added to the Jail's `add-pkg-deps` combinator. Replace to slim or extend the default. |
| `projectPkgs` | list of packages | `[]` | Project-specific packages added on top of `basePkgs`. Both base and project packages are visible inside the Jail. |
| `projectEnv` | attrset of strings | `{}` | Environment variables set inside the Jail via `set-env` combinators. |
| `extraCombinators` | list | `[]` | Additional Jail combinators appended after the lib's defaults. Use for project-specific bind-mounts, host-resolve targets, etc. Last-match-wins: extras can narrow defaults. |
| `extraShellHook` | string | `""` | Appended to the `shellHook` the lib emits. Used for `mkShell` callers that need extra one-time setup (e.g. the nvim-dev template's `.luarc.json` symlinking). |
| `extraSandboxedEnvForwards` | list of strings | `[]` | Env-var names added as `-e <var>` flags to the `claude` launcher's `sandboxed` invocation. Pair with a `try-fwd-env` combinator inside the Jail to actually surface the value to the agent. |
| `name` (mkShell only) | string | `"nix-shell"` | The dev-shell's store-path name. Cosmetic. |

Calling `mkShell` with `projectPkgs` does two things: the packages
become available outside the Jail (so the dev-shell itself has them on
PATH) AND inside (so the jailed agent can use them too).

## Customisation recipes

The patterns below cover the common cases. The
[`templates/claude-code-nvim-dev`](../templates/claude-code-nvim-dev)
template combines several of them and is worth reading as a working example.

### Add project packages

```nix
devShells.${system}.default = slop.mkShell {
  projectName = "my-project";
  claudeMdFile = ./slop-env/claude-config/CLAUDE.md;
  rulesDir = ./slop-env/claude-config/rules;
  skillsDir = ./slop-env/claude-config/skills;

  projectPkgs = with pkgs; [
    lua-language-server
    stylua
    nodejs_20
  ];
};
```

The named packages are added to the Jail's `add-pkg-deps` combinator
(their full `/nix/store` closure bind-mounted read-only) and to the
outer dev-shell's `packages`.

### Set project env vars

```nix
projectEnv = {
  NODE_ENV = "development";
  RUST_LOG = "debug";
};
```

`set-env` combinators are emitted, so the agent sees these inside the
Jail without inheriting the host env. For variables that ARE
host-derived and should be forwarded as-is, use `extraSandboxedEnvForwards`
plus a `try-fwd-env` combinator instead.

### Allow extra hosts per project

The zero-touch app's network allows are baked into the launcher. To
override them in a template, write your own wrapper:

```nix
let
  slop = nix-slop-dev.lib.slopEnv pkgs;
  bins = slop.mkBins { /* … */ };
  customClaude = pkgs.writeShellScriptBin "claude" ''
    exec ${bins.jailedClaude}/bin/jailed-claude \
      "$@"
  '';
in
# ...
```

For per-invocation allows that should not change the persistent
whitelist, drive `sandboxed` directly:

```sh
sandboxed -a github.com -a registry.npmjs.org -- npm install
```

### Bind-mount extra host paths into the Jail

Use `extraCombinators` with the appropriate jail combinator:

```nix
extraCombinators = with slop.jail.combinators; [
  (ro-bind /etc/ssl/certs (noescape "/etc/ssl/certs"))
  (try-readwrite (noescape "~/.config/my-tool"))
];
```

`slop.jail` is the initialised jail library — jail-nix on Linux, the
Darwin Seatbelt combinator library on macOS. Both expose the same core
combinator names (`ro-bind`, `rw-bind`, `try-readwrite`, `tmpfs`,
`write-text`, `set-env`, `try-fwd-env`, etc.). See
[jail-nix's README](https://sr.ht/~alexdavid/jail.nix) for the full
combinator catalogue and
[ADR-0004](adr/0004-jail-on-seatbelt-read-confinement.md) for the
Darwin-specific divergences (path canonicalisation, exec narrowing,
the read+write deny-default baseline).

### Forward a runtime env var

If a project needs an env var that depends on `$PWD` or `$USER` at
launch time (e.g. `LUA_PATH` containing the cwd), forward it through
both layers:

```nix
extraSandboxedEnvForwards = [ "LUA_PATH" ];
extraCombinators = with slop.jail.combinators; [
  (try-fwd-env "LUA_PATH")
];
```

The `extraSandboxedEnvForwards` entry lets `sandboxed` pass the value
through the Sandbox boundary; the `try-fwd-env` combinator surfaces it
inside the Jail.

### Add a one-time shellHook step

```nix
extraShellHook = ''
  if [ ! -L .envrc ]; then
    ln -s ${./envrc-template} .envrc
  fi
'';
```

Appended after the lib's prereq checks. Runs once each time the user
enters `nix develop`.
