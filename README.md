# Nix development flake environments for AI agent coding

## Usage
### flake.nix inputs
inputs.nix-slop-dev.url = "github:pete3n/nix-slop-dev";

### NixOS config
imports = [ inputs.nix-slop-dev.nixosModules.sandboxed ];
security.sandboxed = {
  enable = true;
  users = [ "username" ];
  # stateDir = ".local/state/sandboxed";  # default
};

### Initialize template and create dev shell environment
nix flake init -t github:pete3n/nix-slop-dev#claude-code
nix develop
