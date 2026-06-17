# Nix Slop Dev 
Development flake environments for AI agent coding

## Usage
### flake.nix inputs
```
inputs.nix-slop-dev.url = "github:pete3n/nix-slop-dev";
```

## Quick-start

The wrapper runs on any systemd-based Linux distribution. Configure the host
one of two ways, then initialize a template.

### NixOS

Add the module to your system config:

```
imports = [ inputs.nix-slop-dev.nixosModules.sandboxed ];
security.sandboxed = {
  enable = true;
  users = [ "username" ];
  # stateDir = ".local/state/sandboxed";  # default
};
```

### Non-NixOS Linux (Ubuntu, Debian, Fedora, …)

Run the `setup-linux` app, which diagnoses and (with `--apply`) configures the
host — installing auditd and writing the sudoers drop-in after showing you the
changes and asking for confirmation:

```
nix run github:pete3n/nix-slop-dev#setup-linux            # diagnose, mutates nothing
nix run github:pete3n/nix-slop-dev#setup-linux -- --apply  # configure, with confirmation
```

Prefer to do it by hand? [docs/non-nixos-linux.md](docs/non-nixos-linux.md)
mirrors every step apply mode performs.

### Initialize template and create dev shell environment
```
nix flake init -t github:pete3n/nix-slop-dev#claude-code
nix develop
```

The template's `nix develop` shellHook checks prerequisites and prints
distro-aware guidance: on non-NixOS it points at `setup-linux`, on NixOS it
shows the `security.sandboxed` module options.
