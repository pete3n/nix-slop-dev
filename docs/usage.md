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

### Scratch and Exchange

A Jail hides `/tmp` and the bulk of `$HOME`, so the agent's own temp lives
in its mount namespace and is unreachable from the host. Every Slop Env —
apps and templates, both platforms — therefore provisions two host-visible
per-project directories and points the agent at them via env vars:

| Dir | Env var | Purpose |
|---|---|---|
| **Scratch** | `$TMPDIR` (all agents) | Throwaway temp + intermediate files. Host-visible for inspection; treat as disposable. |
| **Exchange** | `CLAUDE_EXCHANGE_DIR` / `OPENCODE_EXCHANGE_DIR` / `PI_EXCHANGE_DIR` | Deliberate two-way handoff: you drop inputs in, the agent leaves outputs (e.g. handoff docs). Persists across runs. |

The env-var name is Agent-Profile-specific because each upstream agent has
its own convention; the directories themselves are uniform. Both sit under
the agent's per-project state root and are scoped per `projectName`:

| Agent | Scratch (`$TMPDIR`) | Exchange |
|---|---|---|
| Claude Code | `~/.local/state/claude/projects/<projectName>/tmp` | `~/.local/state/claude/projects/<projectName>/exchange` |
| opencode | `~/.local/state/opencode/projects/<projectName>/tmp` | `~/.local/state/opencode/projects/<projectName>/exchange` |
| Pi | `~/.local/state/pi/projects/<projectName>/tmp` | `~/.local/state/pi/projects/<projectName>/exchange` |

The `shellHook` prints the Exchange path on entry. On Linux these are
`tmpfs`-backed where the per-project state dir is; on macOS they are
persistent host dirs.

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

`nix run …#pi` adds the same three (Pi defaults to the Anthropic
provider). `nix run …#opencode` adds those three plus `models.dev` (for
opencode's model catalogue). When a template is built with
`localAi.enable = true`, the local launcher talks to ollama on loopback
(`127.0.0.1:11434`) and adds **no** outbound allows — it runs fully
offline.

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
| `projectName` | string | `__SLOP_ENV_PROJECT_NAME__` (zero-touch placeholder) | Identifies the per-project state dir (`~/.local/state/<agent>/projects/<projectName>/`). Templates pass an explicit value; apps resolve it at runtime from `basename "$PWD"`. |
| `agent` | Agent Profile | `profiles.claude` | Which coding agent the Slop Env confines. Pass `slop.profiles.pi` or `slop.profiles.opencode` to select Pi or opencode instead of Claude Code (ADR-0009 / ADR-0010). Each profile carries its own config layout, credential/session locations, provider hosts, and Exchange env-var name. |
| `localAi` | attrset | `{}` | (Pi and opencode profiles; no-op for Claude) Local AI over loopback ollama, in NixOS-module shape: `{ enable; settings = { endpoints = [...]; }; }`. **`enable`** (default `false`) is the master switch — when false, `settings` is ignored entirely, so a template can ship example endpoints that stay inert until flipped on. Each `settings.endpoints` entry is `{ name; port; models = [{ id; name?; reasoning? }]; role?; coordinator?; default? }` and emits one `ollama-<name>` provider at the **derived** loopback URL `http://127.0.0.1:<port>/v1` (port-only — never off-loopback, [ADR-0012](adr/0012-port-only-loopback-local-ai.md)). With `enable = true` and an empty `endpoints` list, the legacy single-`localhost:11434` provider is used. Marking one endpoint `coordinator = true` builds a coordinator→workers topology (B2): the coordinator is the launch model and each non-coordinator becomes a worker (opencode `mode = "subagent"`; pi a generated agent def — experimental, [ADR-0013](adr/0013-vendor-pi-subagent-extension.md)). Launch-model precedence: coordinator → a single `default = true` endpoint → anthropic; more than one coordinator or default is an eval error. Empty (the default `{}`) emits no local AI, byte-for-byte. See the recipe below and [ADR-0011](adr/0011-multi-endpoint-local-ai.md). |
| `agentMdFile` | path | `lib/slop-env/defaults/CLAUDE.md` | Base context file concatenated with all `rulesDir/*.md` into the agent's context file (Claude loads it as `CLAUDE.md`, Pi as `AGENTS.md`; the profile decides). |
| `rulesDir` | path | `lib/slop-env/defaults/rules` | Directory of `.md` rule files concatenated onto `CLAUDE.md` at jail build time. |
| `skillsDir` | path or `null` | `null` | Directory of agent skills ([Matt Pocock format](https://github.com/mattpocock/skills/blob/main/README.md)) bind-mounted at `~/.local/state/claude/projects/<projectName>/skills/`. |
| `basePkgs` | list of packages | `shared.defaultBasePkgs` | The base toolbox added to the Jail's `add-pkg-deps` combinator. Replace to slim or extend the default. |
| `projectPkgs` | list of packages | `[]` | Project-specific packages added on top of `basePkgs`. Both base and project packages are visible inside the Jail. |
| `projectEnv` | attrset of strings | `{}` | Environment variables set inside the Jail via `set-env` combinators. |
| `extraCombinators` | list | `[]` | Additional Jail combinators appended after the lib's defaults. Use for project-specific bind-mounts, host-resolve targets, etc. Last-match-wins: extras can narrow defaults. |
| `extraShellHook` | string | `""` | Appended to the `shellHook` the lib emits. Used for `mkShell` callers that need extra one-time setup (e.g. the nvim-dev template's `.luarc.json` symlinking). |
| `extraSandboxedEnvForwards` | list of strings | `[]` | Env-var names added as `-e <var>` flags to the `claude` launcher's `sandboxed` invocation. Pair with a `try-fwd-env` combinator inside the Jail to actually surface the value to the agent. |
| `accounts` | attrset | `{}` | (Linux / Claude profile only) Closed registry of authentication identities: `{ <name> = { type = "oauth" \| "apikey"; keyFile?; }; }` (`keyFile` is required for `apikey`, absent for `oauth`). A non-empty registry opts into an account-required regime — the active Account is `NIX_SLOP_DEV_ACCOUNT` (launch override) else `defaultAccount`, and an unset or unknown selection refuses to launch. Credentials live per-Account (`~/.local/state/claude/accounts/<acct>/`), session state per Account-and-project (`~/.local/state/claude/projects/<proj>/<acct>/`). Requires a concrete `projectName`; names must match `[A-Za-z0-9._-]+`; refused at eval on macOS. Declaring it with the Pi/opencode profiles on Linux is currently silently ignored (no isolation, no error). Empty (the default) keeps single-credential behaviour byte-for-byte. See [Multiple accounts](../README.md#multiple-accounts) / [ADR-0014](adr/0014-per-account-credential-isolation.md). |
| `defaultAccount` | string or `null` | `null` | The Account chosen when no `NIX_SLOP_DEV_ACCOUNT` override is set. Optional: with neither a default nor an override, a Slop Env that declares `accounts` refuses to launch until one is selected. |
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
  agentMdFile = ./slop-env/claude-config/CLAUDE.md;
  rulesDir = ./slop-env/claude-config/rules;
  skillsDir = ./slop-env/claude-config/skills;

  projectPkgs = [
    hunk
    worktrunk
    pkgs.lua-language-server
    pkgs.stylua
    pkgs.nodejs_20
  ];
};
```

The named packages are added to the Jail's `add-pkg-deps` combinator
(their full `/nix/store` closure bind-mounted read-only) and to the
outer dev-shell's `packages`.

Each shipped template already sets `projectPkgs = [ hunk worktrunk ]` (the
`hunk` diff-review tool and the `wt` worktree-workflow CLI, both re-exported
by nix-slop-dev), so they reach both the dev shell and the jailed agent.
Append your own rather than dropping them, e.g.
`projectPkgs = [ hunk worktrunk pkgs.nodejs_20 ];`.

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

### Declare multiple Accounts

(Linux / Claude Code only — full guide and verification steps in
[Multiple accounts](../README.md#multiple-accounts).) Run agents under more
than one authentication identity, with credentials and sessions isolated
per Account:

```nix
devShells.${system}.default = slop.mkShell {
  projectName = "my-project";
  # ...other args
  accounts = {
    acme   = { type = "oauth"; };
    globex = { type = "apikey"; keyFile = "/run/agenix/globex-anthropic"; };
  };
  defaultAccount = "acme";
};
```

Pick the Account per run with `NIX_SLOP_DEV_ACCOUNT` (e.g.
`NIX_SLOP_DEV_ACCOUNT=globex claude`); it falls back to `defaultAccount`,
and an unknown name refuses to launch before the Jail starts. For an
`apikey` Account, `keyFile` is required and is a runtime path (e.g.
`/run/agenix/<secret>`) read at launch — the key is forwarded only to the
single jailed exec and never enters the `/nix/store`. On a cross-platform
flake, gate the registry on `pkgs.stdenv.isLinux`, since macOS refuses a
non-empty `accounts`; and note that `accounts` is honoured only by the
Claude profile — declaring it with the Pi/opencode profiles is currently
silently ignored ([ADR-0014](adr/0014-per-account-credential-isolation.md)).

### Declare local AI endpoints (multi-provider + coordinator/workers)

(Pi and opencode profiles.) Replace the single hardcoded ollama provider with a
list of loopback endpoints — one per local model server (e.g. one per GPU). Each
is **port-only**: the provider URL `http://127.0.0.1:<port>/v1` is derived, so a
config can never point the agent off-loopback
([ADR-0012](adr/0012-port-only-loopback-local-ai.md)).

The option follows the NixOS-module idiom — `localAi = { enable; settings; }` —
so `enable = false` leaves a fully-written example inert (handy in a template):

```nix
devShells.${system}.default = slop.mkShell {
  projectName = "my-project";
  agent = slop.profiles.pi; # or slop.profiles.opencode
  localAi = {
    enable = true; # master switch; false ignores settings entirely
    settings.endpoints = [
      {
        name = "big"; # → provider ollama-big
        port = 11435; # → http://127.0.0.1:11435/v1
        coordinator = true; # launch model; delegates to the workers below
        models = [
          {
            id = "qwen3-coder:latest";
            name = "Qwen3 Coder";
            reasoning = true;
          }
        ];
      }
      {
        name = "fast"; # → provider ollama-fast, a worker subagent
        port = 11434;
        role = "Quick edits and small refactors"; # the worker's description
        models = [
          {
            id = "qwen3:8b";
            reasoning = true;
          }
        ];
      }
    ];
  };
};
```

Forward each remote (or other-host) Ollama to a distinct loopback port with your
own SSH tunnel before launching — the tunnel is out-of-band, and the agent only
ever sees `127.0.0.1:<port>`:

```sh
ssh -N -L 11434:localhost:11434 -L 11435:localhost:11434 gpubox &
```

On shell entry a warn-only liveness probe reports each endpoint's reachability
(it never blocks — start the tunnel whenever). Verify a model is actually pulled
on the server with:

```sh
curl -s localhost:11435/api/tags | jq '.models[].name'
```

**Coordinator→workers (B2).** Mark exactly one endpoint `coordinator = true` to
make it the launch model and turn every other endpoint into a worker the
coordinator delegates to (opencode uses its native `mode = "subagent"`; pi uses a
vendored subagent extension — **experimental**,
[ADR-0013](adr/0013-vendor-pi-subagent-extension.md)). Use `default = true`
instead of `coordinator` to pick a launch model without generating workers.
Launch-model precedence is coordinator → default → the built-in anthropic model;
declaring more than one coordinator or default is an eval error.

**Offline guarantee, precisely.** A local launcher (`pl` / `ocl`) adds no
Sandbox egress allows and disables the model-fetch. The guarantee is *no
agent-initiated egress*, not *no data leaves the machine*: if you have tunnelled
a remote endpoint, prompt data travels that tunnel by your explicit `ssh -L`
choice ([ADR-0012](adr/0012-port-only-loopback-local-ai.md)).

Setting `localAi.enable = false` (or omitting `localAi`) emits no local AI at
all — the `settings` are ignored, so example endpoints in a template stay inert.
With `enable = true` and an empty `settings.endpoints`, the legacy single
`localhost:11434` provider is used.
