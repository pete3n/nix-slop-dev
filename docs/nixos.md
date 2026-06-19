# NixOS setup

NixOS requires two configuration steps: enable flakes, and add the
`security.sandboxed` module so the host has sudoers and auditd configured for
the wrapper.

## Enable flakes

If your NixOS configuration does not already enable flakes, add this to
your system module:

```nix
nix.settings.experimental-features = [ "nix-command" "flakes" ];
```

Rebuild with `sudo nixos-rebuild switch` and the `nix run` / `nix flake
init` commands referenced in the README will work.

## Add the `security.sandboxed` module

Import the module from this flake and enable it for the users who will
run sandboxed agents:

```nix
{
  inputs.nix-slop-dev.url = "github:pete3n/nix-slop-dev";

  outputs = { nixpkgs, nix-slop-dev, ... }: {
    nixosConfigurations.<your-host> = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        nix-slop-dev.nixosModules.sandboxed
        {
          security.sandboxed = {
            enable = true;
            users = [ "alice" "bob" ];
          };
        }
        # … the rest of your configuration
      ];
    };
  };
}
```

Apply with `sudo nixos-rebuild switch`.

## Option reference

| Option                       | Type            | Default                     | Description                                                                                                  |
|------------------------------|-----------------|-----------------------------|--------------------------------------------------------------------------------------------------------------|
| `security.sandboxed.enable`  | `bool`          | `false`                     | Enable the module: install `sandboxed` system-wide, turn on auditd, add the sudoers rules.                   |
| `security.sandboxed.users`   | `listOf str`    | `[]`                        | Users permitted to run `sandboxed`. Each gets `NOPASSWD` sudo for `systemd-run`, `systemctl`, `tail`, `auditctl`, `ausearch`. |
| `security.sandboxed.stateDir`| `str`           | `.local/state/sandboxed`    | Path relative to `$HOME` where the persistent whitelist file (`whitelist`) is stored.                        |
| `security.sandboxed.package` | `package`       | flake's `sandboxed`, configured with `stateDir` | The `sandboxed` derivation to install. Override only if you are vendoring a custom build. |

## What the module does when enabled

- Sets `security.audit.enable = true` and `security.auditd.enable = true`
  — auditd records denied `connect()` syscalls so the wrapper's
  `--log` and live violation banners can report violations.
- Installs `sandboxed` into `environment.systemPackages` so the binary
  is on every login shell's PATH.
- Adds a `security.sudo.extraRules` entry per user in `users`,
  granting passwordless sudo for the five privileged tools the wrapper
  invokes. Store paths are pinned (`${pkgs.systemd}/bin/systemd-run`
  etc.) so each `nixos-rebuild` keeps the sudoers file in sync with the
  installed tools — see
  [ADR-0002](adr/0002-runtime-host-tool-detection.md) for why non-NixOS
  hosts cannot use the same approach.

The wrapper itself runs unprivileged; the sudo grants exist so it can
launch the cgroup transient unit and tail the audit log without an
interactive prompt mid-session.

## Verify

After `nixos-rebuild switch`, log in as a user listed in
`security.sandboxed.users` and run:

```sh
sandboxed --print-tools
```

This prints how each privileged tool resolves on this host. On NixOS
every entry should be a `/nix/store/...` path matching the running
system's `nixpkgs`. If any entry shows `(none)` or an unexpected path,
the module is not active for this user.

Then exercise the wrapper end-to-end:

```sh
nix run github:pete3n/nix-slop-dev#claude
```

If the Slop Env starts, the host is configured correctly. Return to the
[README](../README.md#usage) for everyday usage patterns.
