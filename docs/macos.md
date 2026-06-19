# macOS setup (with nix-darwin)

macOS needs four pieces in place: Nix, nix-darwin, flakes, and the
`darwinModules.sandboxed` module. Seatbelt is the enforcement mechanism
for both the Sandbox and the Jail (see [ADR-0001](adr/0001-seatbelt-only-on-macos.md));
it ships with macOS and runs daemonless and unprivileged, so unlike the
NixOS path there is no sudoers or audit-daemon setup.

## Install Nix

Use either the [official Nix installer](https://nix.dev/install-nix)
or the [Determinate Systems installer](https://github.com/DeterminateSystems/nix-installer),
which is more forgiving about APFS volume creation on recent macOS
releases. Both result in a usable multi-user Nix that this flake will
build against.

## Install nix-darwin

Follow the [nix-darwin install guide](https://github.com/nix-darwin/nix-darwin#installing).
The short version, for a flake-based setup:

```sh
nix run nix-darwin -- switch --flake ~/.config/nix-darwin
```

(Assuming you keep your nix-darwin flake at `~/.config/nix-darwin`; any
path works.)

## Enable flakes

If your nix-darwin configuration does not already enable flakes, add
this to your darwin module:

```nix
nix.settings.experimental-features = [ "nix-command" "flakes" ];
```

Apply with `darwin-rebuild switch --flake .` from your nix-darwin
configuration directory.

## Add the `darwinModules.sandboxed` module

Import the module from this flake and enable it:

```nix
{
  inputs.nix-slop-dev.url = "github:pete3n/nix-slop-dev";

  outputs = { nix-darwin, nix-slop-dev, ... }: {
    darwinConfigurations.<your-host> = nix-darwin.lib.darwinSystem {
      system = "aarch64-darwin";  # or "x86_64-darwin"
      modules = [
        nix-slop-dev.darwinModules.sandboxed
        {
          security.sandboxed.enable = true;
        }
        # … the rest of your configuration
      ];
    };
  };
}
```

Apply with `darwin-rebuild switch --flake .`.

Note that the Darwin module deliberately has no `users` option:
Seatbelt is per-process and unprivileged, so every user on the host gets
the wrapper once the module is enabled.

## Option reference

| Option                        | Type      | Default                                          | Description                                                                                       |
|-------------------------------|-----------|--------------------------------------------------|---------------------------------------------------------------------------------------------------|
| `security.sandboxed.enable`   | `bool`    | `false`                                          | Enable the module: install `sandboxed` system-wide.                                               |
| `security.sandboxed.stateDir` | `str`     | `.local/state/sandboxed`                         | Path relative to `$HOME` where the persistent whitelist file (`whitelist`) is stored.             |
| `security.sandboxed.package`  | `package` | flake's `sandboxed`, configured with `stateDir`  | The `sandboxed-darwin` derivation to install. Override only if you are vendoring a custom build.  |

## What the module does when enabled

Only one thing: `environment.systemPackages` gains the
`sandboxed-darwin` derivation, putting the `sandboxed` binary on PATH
for every user. There is no sudoers entry, no audit configuration, no
launchd service. Seatbelt's enforcement is loaded by the wrapper itself
via `sandbox-exec` at each invocation; the userspace proxy (per
[ADR-0003](adr/0003-macos-sandbox-via-userspace-proxy.md)) is spawned
as a child of the calling process and torn down with it.

## Known macOS-specific limits

These are the divergences from Linux behaviour referenced in the
[README's Disclaimer](../README.md#disclaimer). They are inherent to
the Seatbelt / userspace-proxy design and not project bugs:

- **No `ping <whitelisted-ip>`.** The Seatbelt profile language
  structurally rejects per-IP rules (Apple's SBPL parser only accepts
  `*` or `localhost` as the host portion of `(remote ip …)`). The
  userspace proxy covers TCP via HTTP `CONNECT` and SOCKS5, so HTTP(S)
  and SSH-over-`ProxyCommand` work; ICMP, raw sockets, and
  non-proxy-aware UDP fail closed even for whitelisted destinations.
  See [ADR-0003 addendum (issue 16)](adr/0003-macos-sandbox-via-userspace-proxy.md).
- **`--wl-add` does not update a running session.** The proxy reads
  its whitelist at startup; whitelist changes take effect on the next
  launch. Linux's cgroup-eBPF approach can edit live transient units,
  so `--wl-add` is immediate there.
- **Reduced exec surface.** The Jail's `process-exec` rules are
  opt-in per path (see [ADR-0004 addendum (issue 15)](adr/0004-jail-on-seatbelt-read-confinement.md)).
  An agent inside the Jail cannot exec `osascript`, `launchctl`,
  `defaults`, or other host binaries even though they exist on the
  filesystem — only paths whose combinator emits a `process-exec`
  allow can be invoked. The default template already covers what
  Claude Code needs (`/usr/bin/env`, the Nix-store closure of the base
  toolbox, and `/usr/bin/security` for keychain-mediated OAuth).

## Verify

After `darwin-rebuild switch`, open a new terminal and run:

```sh
sandboxed --print-tools
```

On macOS the tool list is short — most of the Linux privileged-tool
plumbing has no Darwin counterpart. Then exercise the wrapper
end-to-end:

```sh
nix run github:pete3n/nix-slop-dev#claude
```

If the Slop Env starts and prompts for OAuth (first run only), the host
is configured correctly. Return to the [README](../README.md#usage) for
everyday usage patterns.
