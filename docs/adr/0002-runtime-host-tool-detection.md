# Privileged tools resolve at runtime on non-NixOS Linux

The `sandboxed` wrapper invokes five privileged tools via sudo (`systemd-run`,
`systemctl`, `auditctl`, `ausearch`, `tail`). On NixOS these are Nix store
paths kept in sync with sudoers by the NixOS module. On non-NixOS distros a
store-pinned sudoers file would silently break on every flake update (the
hash changes), and a Nix-store systemd client may version-skew against the
host's systemd daemon. So the wrapper detects NixOS at runtime: on NixOS it
uses the embedded store paths; elsewhere it invokes bare tool names and lets
sudo's `secure_path` resolve the host binaries, matching a sudoers drop-in
written once by the `setup-linux` app with detected absolute paths.

This is deliberate impurity in a Nix project — do not "fix" it by pinning
store paths everywhere; installed sudoers files on non-NixOS machines depend
on the bare-name invocation surviving flake updates. Unprivileged helpers
(awk, grep, dig, ...) stay store-pinned on all platforms since they need no
sudoers entry.
